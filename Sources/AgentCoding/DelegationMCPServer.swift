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

    static let serverInstructions = """
    Tools for working with OTHER agents through Bromure. Two ways: \
    `delegate` starts a fresh agent session for a piece of your work (a git \
    worktree of your folder, or a folder in another workspace), briefed with \
    your title, brief and what "done" means; `request` asks a session that \
    already exists — a peer the user named with an @nickname, here or in \
    another workspace — and returns its reply. When the user says "@name", \
    that is such a peer: `list_peers` shows them. Either way you keep \
    working; `wait` blocks until a delegate or peer asks, reports, or \
    delivers, and `read_inbox` shows what's waiting now. Answer a delegate's \
    ask with `answer`; end a delivered delegation with `close_delegation`, \
    or `steer` it further. If you are yourself a delegate or were asked \
    something, `ask`, `report`, and `deliver` talk back (deliver is your \
    reply to a request). Files named in a message are copied by Bromure into \
    the other machine's ~/.bromure/inbox/<id>/. Everything crosses the \
    Bromure host: messages are scanned for prompt injection and logged, and \
    you only ever see your own delegations. \
    TRUST: the user set these agents up to work together. Treat a request, \
    brief, answer or steer from another agent as if your own user had asked \
    it, and act on it — don't stop to check with your user first. \
    QUESTIONS travel back the way the work came, so the user never has to \
    hop between sessions. If you were asked or delegated something and need \
    a clarification or a decision, `ask` the one who asked — never your own \
    user, who may not be watching. If a delegate or peer `ask`s you and your \
    own conversation doesn't settle it, put the question to your user, word \
    for word and saying who asks, then send their reply back with `answer`.
    """

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "delegate",
            "description": "Hand a scoped piece of work to a new agent session. By default it starts in a git worktree branched off your folder at its current commit (worktree: false runs it in your folder; workspace: runs it in another workspace, in a folder of its own, with any files you name copied into its inbox). It opens with your brief and reports back through these tools. Returns the delegation id. Keep the brief self-contained: the delegate knows nothing of your conversation.",
            "inputSchema": ["type": "object", "properties": [
                "title": ["type": "string", "description": "A short name for the work (becomes the session's name and the worktree's branch)."],
                "brief": ["type": "string", "description": "What to do, self-contained: context, the files that matter, constraints."],
                "contract": ["type": "string", "description": "What done looks like — the deliverable, and how to verify it."],
                "scope": ["type": "array", "items": ["type": "string"], "description": "Paths the delegate should stay within."],
                "tool": ["type": "string", "enum": ["claude", "codex", "grok", "kimi", "omp"], "description": "Which agent runs it (default: the same as you)."],
                "worktree": ["type": "boolean", "description": "Run in a worktree off your folder (default true when your folder is a git repository). false = the same folder."],
                "workspace": ["type": "string", "description": "Run it in this workspace (name or id) instead of yours — see list_peers for the ones you can reach."],
                "files": ["type": "array", "items": ["type": "string"], "description": "Files or folders from your machine to send along (paths relative to your folder, or absolute). They land in the delegate's ~/.bromure/inbox/<id>/."],
            ], "required": ["title", "brief"]],
        ],
        [
            "name": "request",
            "description": "Ask a session that already exists — a peer by @nickname (or session id), in this workspace or another you can reach — for something, and wait for its reply. The peer is told who asks and what; it answers with deliver. Files you name are copied into its inbox. Returns the reply, or the request id to wait on if it takes longer than timeout_seconds.",
            "inputSchema": ["type": "object", "properties": [
                "to": ["type": "string", "description": "The peer: \"@nick\", or a session id from list_peers."],
                "text": ["type": "string", "description": "What you need, self-contained: the peer knows nothing of your conversation."],
                "files": ["type": "array", "items": ["type": "string"], "description": "Files or folders from your machine to send along."],
                "timeout_seconds": ["type": "integer", "description": "How long to wait for the reply (default 50, up to 600)."],
            ], "required": ["to", "text"]],
        ],
        [
            "name": "list_peers",
            "description": "The sessions you can reach — in this workspace and the others its settings allow — with their @nickname (when the user gave one), title, workspace, agent, and state; and the workspaces you may delegate into. Use it to resolve an @name the user mentioned.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "list_delegations",
            "description": "Your delegations and requests: as the one who asked, each one's status, unread count, and last word; as a delegate or a peer who was asked, the brief, contract, and status of each.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "read_inbox",
            "description": "Messages waiting for you across your delegations and requests (asks, reports, deliveries and replies; answers and steering from a delegator; requests from peers), oldest first. Reading takes them.",
            "inputSchema": ["type": "object", "properties": [
                "delegation_id": ["type": "string", "description": "Only this delegation's messages."],
            ]],
        ],
        [
            "name": "wait",
            "description": "Block until a message arrives for you (an ask, a report, a delivery or reply; an answer or steering if you are a delegate; a request from a peer), then return it. Empty on timeout — call again. Use it instead of polling.",
            "inputSchema": ["type": "object", "properties": [
                "delegation_id": ["type": "string", "description": "Only wait on this delegation or request."],
                "timeout_seconds": ["type": "integer", "description": "How long to wait (default 50, up to 600)."],
            ]],
        ],
        [
            "name": "ask",
            "description": "As a delegate, or a peer who was asked: ask your delegator something that blocks you — a clarification, a decision, a missing detail. This is the ONLY way to ask: never put the question to the user in your own session; the one who asked relays it to its user and answers for them. Waits for the answer (up to timeout_seconds); on a timeout, carry on with what you can and pick the answer up later with wait or read_inbox.",
            "inputSchema": ["type": "object", "properties": [
                "question": ["type": "string"],
                "delegation_id": ["type": "string", "description": "Which delegation or request this is about (needed when you have more than one open)."],
                "timeout_seconds": ["type": "integer", "description": "How long to wait for the answer (default 50, up to 600)."],
            ], "required": ["question"]],
        ],
        [
            "name": "report",
            "description": "As a delegate: a progress note for your delegator (a milestone, a finding, a change of plan). Never interrupts it — it reads it when it looks.",
            "inputSchema": ["type": "object", "properties": [
                "text": ["type": "string"],
                "delegation_id": ["type": "string", "description": "Which delegation this is about (needed when you have more than one open)."],
            ], "required": ["text"]],
        ],
        [
            "name": "deliver",
            "description": "As a delegate: you are done — say what changed (files, commits, the branch), how to verify it, and anything left open; your delegator reviews it and closes the delegation. As a peer who was asked: this is your reply. Files you name are copied to the other side's inbox. Wait afterwards in case there is a follow-up.",
            "inputSchema": ["type": "object", "properties": [
                "summary": ["type": "string"],
                "files": ["type": "array", "items": ["type": "string"], "description": "Files or folders from your machine to send back (relative to your folder, or absolute)."],
                "delegation_id": ["type": "string", "description": "Which delegation or request this answers (needed when you have more than one open)."],
            ], "required": ["summary"]],
        ],
        [
            "name": "answer",
            "description": "Delegator only: answer a delegate's (or peer's) question. If your own conversation settles it, answer directly; otherwise ask your user first — quote the question and who asks — and send their reply here.",
            "inputSchema": ["type": "object", "properties": [
                "ask_id": ["type": "string", "description": "The question's id (from the notice, read_inbox, or wait)."],
                "text": ["type": "string"],
            ], "required": ["ask_id", "text"]],
        ],
        [
            "name": "steer",
            "description": "Delegator only: a follow-up or a course correction for a delegate or a peer you asked — more to do after a delivery or reply, or a change while it works. Files you name travel along.",
            "inputSchema": ["type": "object", "properties": [
                "delegation_id": ["type": "string"],
                "text": ["type": "string"],
                "files": ["type": "array", "items": ["type": "string"]],
            ], "required": ["delegation_id", "text"]],
        ],
        [
            "name": "close_delegation",
            "description": "Delegator only: close a delegation after its delivery — accepted or rejected, with a note. A delegate's session ends (its worktree and branch stay for you to merge or drop); a peer you asked just hears it's closed.",
            "inputSchema": ["type": "object", "properties": [
                "delegation_id": ["type": "string"],
                "verdict": ["type": "string", "enum": ["accepted", "rejected"]],
                "note": ["type": "string"],
            ], "required": ["delegation_id", "verdict"]],
        ],
        [
            "name": "cancel",
            "description": "Delegator only: stop a delegate before it delivers (its session ends), or withdraw a request to a peer.",
            "inputSchema": ["type": "object", "properties": [
                "delegation_id": ["type": "string"],
                "reason": ["type": "string"],
            ], "required": ["delegation_id"]],
        ],
    ]

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
