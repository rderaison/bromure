import Foundation

// MARK: - Delegation MCP (per workspace)
//
// The tools an agent uses to hand work to another agent and to hear back
// from it — the `bromure-delegation` server every agent tab in a workspace
// gets. Same transport as the board MCP: a stdio shim in the guest
// (bromure-delegation-mcp.py) pipes JSON-RPC lines over vsock (port 5835)
// to this handler, one bridge per machine. The shim announces the tmux
// window it runs in ("bromure-hello w<index>", read from its own
// $TMUX_PANE), and the profile is fixed by which VM the connection came
// from — so the caller's identity is the session bound to that window,
// never anything the agent says. A session only ever sees the delegations
// it is one end of. Peers in other workspaces are reachable as far as the
// workspace's reach policy allows; files a message names are copied by the
// host into the other machine's inbox.

@MainActor
final class DelegationMCPServer: MCPLineHandler {
    private let profileID: Profile.ID
    private let sessions: () -> AgentSessionStore?
    private let engine: () -> DelegationEngine?

    init(profileID: Profile.ID,
         sessions: @escaping () -> AgentSessionStore?,
         engine: @escaping () -> DelegationEngine?) {
        self.profileID = profileID
        self.sessions = sessions
        self.engine = engine
    }

    // MARK: JSON-RPC

    func handle(line: String, branch: String?) async -> String? {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return respond(id: id, result: [
                "protocolVersion": "2025-03-26",
                "serverInfo": ["name": "bromure-delegation", "version": "1.1.0"],
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": Self.serverInstructions,
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return respond(id: id, result: [:])
        case "tools/list":
            return respond(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return respond(id: id, result: await callTool(name: name, args: args, hello: branch))
        default:
            guard id != nil else { return nil }
            return respondError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Identity

    /// "w<index>" → the session bound to that tmux window of this workspace.
    static func windowIndex(fromHello hello: String?) -> Int? {
        guard let hello = hello?.trimmingCharacters(in: .whitespaces), hello.hasPrefix("w"),
              let n = Int(hello.dropFirst()), n >= 0 else { return nil }
        return n
    }

    private func me(_ hello: String?) -> AgentSession? {
        guard let w = Self.windowIndex(fromHello: hello) else { return nil }
        return sessions()?.session(profileID: profileID, windowIndex: w)
    }

    // MARK: Tools

    static var serverInstructions: String { DelegationMCPCatalog.instructions }
    static var toolDefinitions: [[String: Any]] { DelegationMCPCatalog.tools }

    private func callTool(name: String, args: [String: Any], hello: String?) async -> [String: Any] {
        let t0 = Date()
        let result = await callToolTimed(name: name, args: args, hello: hello)
        BACDebug.log("delegation", "tool \(name) took=\(BACDebug.ms(t0))")
        return result
    }

    private func callToolTimed(name: String, args: [String: Any], hello: String?) async -> [String: Any] {
        guard let engine = engine() else { return errorResult("Delegations aren't available on this host.") }
        guard let me = me(hello) else {
            return errorResult("This agent isn't running in a Bromure session tab, so it has no identity here — the delegation tools need one.")
        }
        let iso = ISO8601DateFormatter()
        func timeout(_ v: Any?) -> TimeInterval {
            if let n = v as? Int { return TimeInterval(n) }
            if let n = v as? Double { return n }
            return DelegationEngine.defaultWait
        }
        func strings(_ v: Any?) -> [String] {
            ((v as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        /// The `nickname` argument, normalized and checked BEFORE anything is
        /// started, so a taken name fails the call rather than leaving an
        /// unnamed session behind.
        func requestedNickname(_ args: [String: Any]) throws -> String? {
            guard let raw = (args["nickname"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty else { return nil }
            guard let nick = DelegationNotice.normalizeNickname(raw) else {
                throw DelegationRefusal("“\(raw)” isn't a usable nickname: letters, digits, - _ . only, up to 32.")
            }
            if case .refused(let why) = engine.sessions.checkNickname(UUID(), nick) {
                throw DelegationRefusal(why)
            }
            return nick
        }
        /// Name the new session. A child on another host isn't in this
        /// store: say so rather than pretend.
        func applyNickname(_ nick: String, to child: UUID, into out: inout [String: Any]) {
            guard engine.sessions.session(child) != nil else {
                out["nickname_note"] = "Not applied: the new session runs on another host."
                return
            }
            if let why = engine.sessions.setNickname(child, nick, reclaim: true) {
                out["nickname_note"] = why
            } else {
                out["nickname"] = "@" + nick
            }
        }
        func item(_ d: Delegation, _ m: DelegationMessage) -> [String: Any] {
            var o: [String: Any] = [
                "delegation_id": d.id.uuidString, "delegation": d.title,
                "request": d.isRequest,
                "kind": m.kind.rawValue, "from": m.from.rawValue,
                "time": iso.string(from: m.at), "text": m.text,
            ]
            if m.kind == .ask { o["ask_id"] = m.id.uuidString }
            if let a = m.answers { o["answers"] = a.uuidString }
            if let f = m.files, !f.isEmpty { o["files"] = f }
            if m.to == .child, let who = d.parentLabel { o["from_label"] = who }
            if m.to == .parent, let who = d.childLabel { o["from_label"] = who }
            return o
        }
        func messages(_ items: [(Delegation, DelegationMessage)], empty: String) -> [String: Any] {
            guard !items.isEmpty else { return textResult(empty) }
            return textResult(jsonString(["messages": items.map { item($0.0, $0.1) }]))
        }
        /// Blocks for a reply of `kind` on `d`, up to `t`; what else arrived
        /// meanwhile is reported instead of silently taken.
        func awaitReply(on d: Delegation, kind: DelegationMessage.Kind, answering: UUID? = nil,
                        timeout t: TimeInterval, idKey: String, idValue: String,
                        found: (DelegationMessage) -> [String: Any]) async -> [String: Any] {
            let deadline = Date().addingTimeInterval(min(max(t, 1), DelegationEngine.waitCap))
            while Date() < deadline {
                let got = await engine.wait(for: me.id, in: d.id, timeout: max(1, deadline.timeIntervalSinceNow))
                if let hit = got.first(where: { $0.1.kind == kind && (answering == nil || $0.1.answers == answering) }) {
                    return textResult(jsonString(found(hit.1).merging([idKey: idValue]) { a, _ in a }))
                }
                if !got.isEmpty {
                    return textResult(jsonString([
                        idKey: idValue, "replied": false,
                        "messages": got.map { item($0.0, $0.1) },
                        "next": "No reply yet — carry on with what you can; wait or read_inbox later.",
                    ]))
                }
            }
            return textResult(jsonString([
                idKey: idValue, "replied": false,
                "next": "No reply yet — carry on with what you can; wait(delegation_id: \"\(d.id.uuidString)\") or read_inbox later. The other side has been told (and woken if it was asleep).",
            ]))
        }
        do {
            switch name {
            case "delegate":
                guard let title = args["title"] as? String, let brief = args["brief"] as? String else {
                    return errorResult("title and brief are required")
                }
                let nickname = try requestedNickname(args)
                let tool = (args["tool"] as? String).flatMap(Profile.Tool.init(rawValue:))
                let d = try await engine.delegate(
                    from: me.id, title: title, brief: brief,
                    contract: args["contract"] as? String,
                    scope: strings(args["scope"]),
                    tool: tool, worktree: args["worktree"] as? Bool,
                    workspace: (args["workspace"] as? String)?.trimmingCharacters(in: .whitespaces).isEmpty == false
                        ? args["workspace"] as? String : nil,
                    files: strings(args["files"]))
                var out: [String: Any] = [
                    "delegation_id": d.id.uuidString,
                    "child_session": d.childSessionID.uuidString,
                    "status": d.status.rawValue,
                    "next": "Keep working; call wait (or read_inbox) when you need its result. It may ask you something first.",
                ]
                if let nickname { applyNickname(nickname, to: d.childSessionID, into: &out) }
                if let f = d.messages.first?.files, !f.isEmpty { out["files_landed"] = f }
                if let ws = engine.sessions.session(d.childSessionID)?.profileID {
                    out["workspace"] = engine.workspaceName(ws)
                }
                return textResult(jsonString(out))

            case "request":
                guard let to = args["to"] as? String, let text = args["text"] as? String else {
                    return errorResult("to and text are required")
                }
                let d = try await engine.request(from: me.id, to: to, text: text, files: strings(args["files"]))
                return await awaitReply(on: d, kind: .deliver, timeout: timeout(args["timeout_seconds"]),
                                        idKey: "request_id", idValue: d.id.uuidString) { m in
                    var o: [String: Any] = ["replied": true, "peer": d.childLabel ?? "", "reply": m.text]
                    if let f = m.files, !f.isEmpty { o["files"] = f }
                    o["next"] = "steer(delegation_id) to follow up, close_delegation(delegation_id, verdict) when you're done with it."
                    return o
                }

            case "worktree_create":
                guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { return errorResult("title is required") }
                let se = engine.sessionEngine
                guard SessionHome.hasFolder(me) else {
                    return errorResult("Your session runs in the home folder, which can't be branched — only a project folder can.")
                }
                let nickname = try requestedNickname(args)
                let initGit = args["init_git"] as? Bool ?? false
                let host = engine.sessions.host(for: me.profileID)
                let state = host != nil ? await host!.hostGitState(me.id) : await se.gitState(profileID: me.profileID, cwd: me.cwd)
                if !initGit, let st = state, !st.isRepo {
                    return errorResult("\(me.cwd) isn't a git repository. Pass init_git: true to make it one (git init + a first commit) — ask your user first.")
                }
                let tool = (args["tool"] as? String).flatMap(Profile.Tool.init(rawValue:)) ?? me.tool
                let prompt = (args["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let base = (args["base"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let sid: UUID
                if let host {
                    switch await host.hostStartWorktree(from: me.id, name: title, tool: tool,
                                                        message: prompt?.isEmpty == false ? prompt : nil,
                                                        initGit: initGit, base: base) {
                    case .success(let id): sid = id
                    case .failure(let why): return errorResult("Couldn't start it: \(why.message)")
                    }
                } else {
                    guard let id = se.startWorktree(from: me.id, name: title, tool: tool,
                                                    message: prompt?.isEmpty == false ? prompt : nil,
                                                    initGit: initGit, base: base)
                    else { return errorResult("Couldn't start it.") }
                    sid = id
                }
                // The branch and checkout are known once its tab reports in.
                let deadline = Date().addingTimeInterval(45)
                while Date() < deadline {
                    if let s = engine.sessions.session(sid), s.worktreeBranch != nil || s.lastError != nil { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                let s = engine.sessions.session(sid)
                if let err = s?.lastError, s?.worktreeBranch == nil { return errorResult(err) }
                var out: [String: Any] = ["session_id": sid.uuidString, "title": s?.title ?? title,
                                          "tool": tool.rawValue]
                if let nickname { applyNickname(nickname, to: sid, into: &out) }
                if let b = s?.worktreeBranch { out["branch"] = b; out["path"] = s?.cwd ?? "" }
                else { out["note"] = "Still starting — worktree_status shows its branch and path in a moment." }
                out["next"] = "It runs on its own; worktree_status shows its progress, worktree_merge asks the user to merge it."
                return textResult(jsonString(out))

            case "worktree_status":
                let se = engine.sessionEngine
                let all = engine.sessions.sessions.filter { !$0.isDeleted }
                var mine = all.filter { $0.id != me.id && SessionHome.isBranch($0) && AgentSession.origin(of: $0) == me.id }
                if SessionHome.isBranch(me) { mine.insert(me, at: 0) }
                guard !mine.isEmpty else {
                    return textResult("No branches: you aren't in a worktree and haven't started any. worktree_create starts one.")
                }
                // A native machine probes its own branches (every 20 s).
                if engine.sessions.host(for: me.profileID) == nil {
                    await se.probeBranchesNow(profileID: me.profileID, sessions: mine.filter { $0.profileID == me.profileID })
                }
                let rows = mine.compactMap { engine.sessions.session($0.id) }.map { s -> [String: Any] in
                    var o: [String: Any] = [
                        "session_id": s.id.uuidString, "title": s.title,
                        "you": s.id == me.id,
                        "branch": s.worktreeBranch ?? "", "path": s.cwd,
                        "agent": s.tool.rawValue,
                        "running": s.windowIndex != nil && !s.hasEnded && s.agentAlive != false,
                        "archived": s.isArchived,
                    ]
                    if let p = s.branchParent { o["from"] = p }
                    if let i = s.branchInfo {
                        o["commits_ahead"] = i.ahead; o["commits_behind"] = i.behind; o["uncommitted_files"] = i.changed
                    }
                    if let m = s.branchMerge {
                        var mm: [String: Any] = ["into": m.target, "state": m.phase.rawValue, "squash": m.squash]
                        if m.phase == .requested { mm["state"] = "awaiting the user's approval" }
                        if let d = m.detail { mm["detail"] = d }
                        o["merge"] = mm
                    }
                    return o
                }
                return textResult(jsonString(["branches": rows]))

            case "worktree_merge":
                let target: AgentSession
                if let key = (args["session_id"] as? String)?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
                    guard let s = UUID(uuidString: key).flatMap({ engine.sessions.session($0) })
                            ?? engine.sessions.sessions.first(where: { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }),
                          s.id == me.id || AgentSession.origin(of: s) == me.id
                    else { return errorResult("No branch session “\(key)” of yours — worktree_status lists them.") }
                    target = s
                } else {
                    target = me
                }
                guard SessionHome.isBranch(target) else {
                    return errorResult(target.id == me.id
                                       ? "You aren't running in a worktree. Pass the session_id of a branch session (worktree_status lists them)."
                                       : "That session isn't on a branch of its own.")
                }
                let into = (args["into"] as? String)?.trimmingCharacters(in: .whitespaces)
                if let host = engine.sessions.host(for: target.profileID) {
                    var body: [String: Any] = ["squash": args["squash"] as? Bool ?? false, "askedBy": me.id.uuidString]
                    if let into, !into.isEmpty { body["into"] = into }
                    guard let r = await host.hostControl("POST", "/agent-sessions/\(target.id.uuidString)/branch-request", body)
                    else { return errorResult("\(host.hostName) didn't answer.") }
                    if let why = r.json["error"] as? String { return errorResult(why) }
                    // The mirror carries the request on its next poll.
                    let deadline = Date().addingTimeInterval(5)
                    while Date() < deadline, engine.sessions.session(target.id)?.branchMerge == nil {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                } else if let why = await engine.sessionEngine.requestMerge(
                    target.id, into: into?.isEmpty == false ? into : nil,
                    squash: args["squash"] as? Bool ?? false, askedBy: me.id) {
                    return errorResult(why)
                }
                let m = engine.sessions.session(target.id)?.branchMerge
                return textResult(jsonString([
                    "requested": true, "branch": target.worktreeBranch ?? "", "into": m?.target ?? "",
                    "next": "The user has been asked in Bromure. Carry on; worktree_status shows whether it was approved and has landed\(target.id == me.id ? " (once it lands, this session is archived)" : "; you'll be told when it's in").",
                ]))

            case "list_peers":
                let peers = engine.reachableSessions(from: me).map { s -> [String: Any] in
                    let state: String
                    if s.windowIndex != nil, s.agentAlive != false, !s.hasEnded { state = "live" }
                    else if s.hasEnded || s.agentAlive == false { state = "ended (a request wakes it)" }
                    else { state = "asleep (a request wakes it)" }
                    var o: [String: Any] = [
                        "session_id": s.id.uuidString, "title": s.title,
                        "workspace": engine.workspaceName(s.profileID),
                        "agent": s.tool.rawValue, "state": state, "folder": s.cwd,
                    ]
                    if let n = s.nickname { o["nickname"] = "@" + n }
                    return o
                }
                let workspaces = engine.profiles()
                    .filter { engine.canReach(from: me.profileID, to: $0.id) }
                    .map { ["name": $0.name, "id": $0.id.uuidString, "this_one": $0.id == me.profileID] }
                // Sessions on the remote hosts this Mac is connected to, when
                // the workspace's reach allows other hosts at all.
                let far = engine.remotePeers(from: me).map { pair -> [String: Any] in
                    let (link, s) = pair
                    let state: String
                    if s.windowIndex != nil, s.agentAlive != false, !s.hasEnded { state = "live" }
                    else if s.hasEnded || s.agentAlive == false { state = "ended (a request wakes it)" }
                    else { state = "asleep (a request wakes it)" }
                    var o: [String: Any] = [
                        "session_id": s.id.uuidString, "title": s.title, "host": link.hostName,
                        "workspace": link.remoteWorkspaceName(s.profileID),
                        "agent": s.tool.rawValue, "state": state, "folder": s.cwd,
                    ]
                    if let n = s.nickname { o["nickname"] = "@" + n }
                    return o
                }
                var out: [String: Any] = ["peers": peers + far, "workspaces": workspaces]
                let hosts = engine.remoteLinks().map(\.hostName)
                if !hosts.isEmpty {
                    out["hosts"] = hosts
                    out["note"] = engine.remotePeersAllowed(from: me)
                        ? "Peers with a host are on another Mac, reached through this one; request works the same, files travel through the tunnel."
                        : "Other hosts are out of reach: this workspace's settings name the only workspaces its agents may reach."
                }
                return textResult(jsonString(out))

            case "list_delegations":
                let mine = engine.delegationsAsParent(me.id).map { pair -> [String: Any] in
                    let (d, host) = pair
                    var o: [String: Any] = [
                        "delegation_id": d.id.uuidString, "title": d.title, "request": d.isRequest,
                        "status": d.status.rawValue, "created": iso.string(from: d.createdAt),
                        "unread": d.unread(for: .parent).count,
                        "other": d.childLabel ?? "",
                        "agent": engine.sessions.session(d.childSessionID)?.tool.rawValue ?? "",
                    ]
                    if let host { o["host"] = host }
                    if let ws = engine.sessions.session(d.childSessionID)?.profileID { o["workspace"] = engine.workspaceName(ws) }
                    if let b = engine.sessions.session(d.childSessionID)?.worktreeBranch { o["branch"] = b }
                    if let v = d.verdict { o["verdict"] = v }
                    if let f = d.failure { o["failure"] = f }
                    if let ask = d.pendingAsk { o["pending_ask"] = ["ask_id": ask.id.uuidString, "text": ask.text] }
                    if let last = d.lastMessage { o["last"] = item(d, last) }
                    return o
                }
                let theirs = engine.store.delegations(child: me.id).map { d -> [String: Any] in
                    var o: [String: Any] = [
                        "delegation_id": d.id.uuidString, "title": d.title, "request": d.isRequest,
                        "status": d.status.rawValue, "brief": d.brief, "scope": d.scope,
                        "unread": d.unread(for: .child).count,
                        "from": d.parentLabel ?? engine.sessions.session(d.parentSessionID)?.title ?? "",
                    ]
                    if let c = d.contract { o["contract"] = c }
                    if let f = d.messages.first?.files, !f.isEmpty { o["files"] = f }
                    return o
                }
                return textResult(jsonString(["as_delegator": mine, "as_delegate": theirs]))

            case "read_inbox":
                let only = try scopedID(args["delegation_id"], engine: engine, me: me)
                return messages(engine.inbox(for: me.id, in: only), empty: "Nothing waiting.")

            case "wait":
                let only = try scopedID(args["delegation_id"], engine: engine, me: me)
                let items = await engine.wait(for: me.id, in: only, timeout: timeout(args["timeout_seconds"]))
                return messages(items, empty: "Nothing arrived in time — call wait again, or carry on and check read_inbox later.")

            case "ask":
                guard let q = args["question"] as? String else { return errorResult("question is required") }
                let d = try engine.childDelegation(args["delegation_id"] as? String, for: me.id)
                let ask = try await engine.post(d.id, from: .child, kind: .ask, text: q)
                return await awaitReply(on: d, kind: .answer, answering: ask.id, timeout: timeout(args["timeout_seconds"]),
                                        idKey: "ask_id", idValue: ask.id.uuidString) { m in
                    ["answered": true, "answer": m.text]
                }

            case "report":
                guard let text = args["text"] as? String else { return errorResult("text is required") }
                let d = try engine.childDelegation(args["delegation_id"] as? String, for: me.id)
                try await engine.post(d.id, from: .child, kind: .report, text: text)
                return textResult("Noted for your delegator.")

            case "deliver":
                guard let summary = args["summary"] as? String else { return errorResult("summary is required") }
                let d = try engine.childDelegation(args["delegation_id"] as? String, for: me.id)
                let m = try await engine.post(d.id, from: .child, kind: .deliver, text: summary, files: strings(args["files"]))
                var out: [String: Any] = ["delivered": true, "delegation_id": d.id.uuidString]
                if let f = m.files, !f.isEmpty { out["files_landed"] = f }
                out["next"] = d.isRequest
                    ? "Your reply is on its way. Call wait in case of a follow-up."
                    : "Call wait in case your delegator steers you; the delegation closes when it accepts or rejects."
                return textResult(jsonString(out))

            case "answer":
                guard let key = args["ask_id"] as? String, let text = args["text"] as? String else {
                    return errorResult("ask_id and text are required")
                }
                try await engine.answer(from: me.id, askKey: key, text: text)
                return textResult("Answered.")

            case "steer":
                guard let key = args["delegation_id"] as? String, let text = args["text"] as? String else {
                    return errorResult("delegation_id and text are required")
                }
                try await engine.steer(from: me.id, delegationKey: key, text: text, files: strings(args["files"]))
                return textResult("Sent.")

            case "close_delegation":
                guard let key = args["delegation_id"] as? String, let verdict = args["verdict"] as? String else {
                    return errorResult("delegation_id and verdict are required")
                }
                let d = try engine.parentHandle(key, for: me.id).0
                try await engine.close(from: me.id, delegationKey: key, verdict: verdict, note: args["note"] as? String)
                let v = verdict.lowercased() == "rejected" ? "rejected" : "accepted"
                return textResult(d.isRequest
                                  ? "Closed (\(v))."
                                  : "Closed (\(v)). The delegate's session has ended; its branch is still there.")

            case "cancel":
                guard let key = args["delegation_id"] as? String else { return errorResult("delegation_id is required") }
                let d = try engine.parentHandle(key, for: me.id).0
                try await engine.cancel(from: me.id, delegationKey: key, reason: (args["reason"] as? String) ?? "")
                return textResult(d.isRequest ? "Withdrawn." : "Cancelled. The delegate's session has ended.")

            default:
                return errorResult("Unknown tool: \(name)")
            }
        } catch let r as DelegationRefusal {
            return errorResult(r.why)
        } catch {
            return errorResult(error.localizedDescription)
        }
    }

    /// An optional delegation_id argument, checked to be one of the caller's
    /// (either end) — a foreign id is simply not found.
    private func scopedID(_ v: Any?, engine: DelegationEngine, me: AgentSession) throws -> UUID? {
        guard let key = v as? String, !key.isEmpty else { return nil }
        if let d = engine.store.delegation(matching: key), d.party(of: me.id) != nil { return d.id }
        for link in engine.remoteLinks() {
            if let d = link.remoteDelegations.delegation(matching: key), d.parentSessionID == me.id { return d.id }
        }
        throw DelegationRefusal("No delegation “\(key)” of yours.")
    }

    // MARK: JSON helpers (board MCP conventions)

    private func textResult(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]]]
    }

    private func errorResult(_ msg: String) -> [String: Any] {
        ["content": [["type": "text", "text": "Error: \(msg)"]], "isError": true]
    }

    private func jsonString(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .prettyPrinted]),
              let s = String(data: data, encoding: .utf8) else { return "\(v)" }
        return s
    }

    private func respond(id: Any?, result: [String: Any]) -> String? {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id } else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func respondError(id: Any?, code: Int, message: String) -> String? {
        var msg: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { msg["id"] = id } else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
