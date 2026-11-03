import Foundation

/// The agent-session routes, over the shared AgentSessionEngine with the
/// daemon as its host (LinuxSessionHost). macOS: ACAutomationServer's
/// /agent-sessions routes and the app delegate's onAgentSessionCommand.
extension Daemon {
    /// The engine, its host and stores: made once, at daemon start.
    // @port-skip linux-only: daemon wiring (macOS: the app delegate's properties)
    func startSessionEngine() async {
        let me = self, state = config.stateDir
        await MainActor.run {
            let stores = SessionStores(stateDir: state)
            SessionStores.shared = stores
            let host = LinuxSessionHost(daemon: me, stateDir: state)
            LinuxSessionHost.shared = host
            stores.engine = AgentSessionEngine(store: stores.sessions, delegate: host)
            // The rosters and the sessions bound to them, kept current (macOS:
            // its session list's refresh), with or without a client watching.
            Task { @MainActor in
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    LinuxSessionHost.shared?.reconcileSessions()
                }
            }
        }
    }

    /// `POST /agent-sessions/start` and `POST /agent-sessions/<id>/<action>`.
    // partial: no switchboard, read, worktree-open/-discard yet; signin refuses (no MITM stand-in)
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onAgentSessionCommand h=bf7e30bfb1cc500a @9936e30c
    func agentSessionCommand(_ id: UUID?, _ action: String, _ body: JSONValue) async -> ControlResponse {
        let doc = (body.foundationObject as? [String: Any]) ?? [:]
        let r: [String: Any] = await MainActor.run {
            guard let stores = SessionStores.shared, let engine = stores.engine else { return ["error": "no session engine"] }
            let store = stores.sessions
            switch (id, action) {
            case (nil, "start"):
                guard let key = doc["profile"] as? String,
                      let profile = ProfileStore().loadAll().first(where: {
                          $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.lowercased() == key.lowercased() }),
                      let toolRaw = doc["tool"] as? String, let tool = Profile.Tool(rawValue: toolRaw)
                else { return ["error": "profile and tool required"] }
                let attachments = ((doc["attachments"] as? [[String: Any]]) ?? []).compactMap(DroppedFile.init(wire:))
                let room = (doc["room"] as? String).flatMap(UUID.init(uuidString:)).flatMap { stores.rooms.room($0)?.id }
                let req = AgentSessionEngine.NewSessionRequest(
                    profileID: profile.id, tool: tool, cwd: doc["cwd"] as? String ?? "~",
                    cloneURL: doc["cloneURL"] as? String, openingMessage: doc["message"] as? String,
                    attachments: attachments, roomID: room, instructions: doc["instructions"] as? String)
                // Send clicked again while the reply crossed a slow link: the
                // session already started, not another one.
                return SessionStartCoalescer.shared.run(SessionStartCoalescer.key(req)) {
                    ["ok": true, "id": engine.start(req, remotely: true).uuidString]
                }
            case (let sid?, "send"):
                // {text}: typed into the live prompt when it's free (long text
                // lands in the session's inbox with a pointer), or a resume
                // with it, as SwitchboardEngine.send does on macOS.
                guard let s = store.session(sid) else { return ["error": "unknown session"] }
                guard let text = (doc["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { return ["error": "text required"] }
                guard let host = LinuxSessionHost.shared else { return ["error": "no session host"] }
                Task { @MainActor in
                    var line = text
                    if text.contains("\n") || text.count > 400 {
                        let dir = "/home/ubuntu/.bromure/inbox/switchboard-\(Int(Date().timeIntervalSince1970))"
                        let b64 = Data(text.utf8).base64EncodedString()
                        _ = try? await host.guestExec(profileID: s.profileID,
                                                      command: "mkdir -p \(dir) && echo \(b64) | base64 -d > \(dir)/message.md", timeout: 20)
                        line = "A message from the user (relayed by the Switchboard) is in \(dir)/message.md — read it and act on it."
                    }
                    if let w = s.windowIndex, !s.hasEnded, s.agentAlive != false {
                        _ = await CodingTaskEngine.typeWhenFreeResult(exec: { cmd in
                            try await host.guestExec(profileID: s.profileID, command: cmd, timeout: 20)
                        }, target: AgentSessionEngine.paneTarget(s) ?? .index(w), text: line)
                    } else {
                        engine.resume(sid, message: line, remotely: true)
                    }
                }
                return ["ok": true]
            case (let sid?, "keys"):
                // {keys: [...]}: named keys only, into the session's own window
                // (SwitchboardEngine.press).
                guard let s = store.session(sid) else { return ["error": "unknown session"] }
                let keys = (doc["keys"] as? [String]) ?? []
                guard !keys.isEmpty, keys.count <= 12, keys.allSatisfy(Self.allowedKeys.contains) else {
                    return ["error": "keys must be 1–12 of " + Self.allowedKeys.sorted().joined(separator: " ")]
                }
                guard let w = s.windowIndex, !s.hasEnded else { return ["error": "That session has no live tab to type into."] }
                guard let host = LinuxSessionHost.shared else { return ["error": "no session host"] }
                let target = AgentSessionEngine.paneTarget(s) ?? .index(w)
                let cmd = PaneTypeGuard.prelude(target) + "if _bg; then "
                    + keys.map { "tmux send-keys -t \"$_bt\" \($0)" }.joined(separator: " && sleep 0.15 && ") + "; fi"
                Task { @MainActor in _ = try? await host.guestExec(profileID: s.profileID, command: cmd, timeout: 15) }
                return ["ok": true]
            case (_?, "signin"):
                // macOS signs in on a throwaway VM and swaps in a stand-in
                // credential through its MITM proxy, which bromure-ac hasn't yet.
                return ["error": "Sign the agent in inside the workspace's terminal for now: this server can't do it for you yet."]
            case (let sid?, "resume"):
                guard store.session(sid) != nil else { return ["error": "unknown session"] }
                engine.resume(sid, message: doc["message"] as? String, remotely: true)
                return ["ok": true]
            case (let sid?, "close"):
                guard store.session(sid) != nil else { return ["error": "unknown session"] }
                engine.close(sid)
                return ["ok": true]
            case (let sid?, "worktree"):
                guard let parent = store.session(sid) else { return ["error": "unknown session"] }
                let name = (doc["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let tool = (doc["tool"] as? String).flatMap(Profile.Tool.init(rawValue:)) ?? parent.tool
                guard let newID = engine.startWorktree(
                    from: sid, name: name, tool: tool, message: doc["message"] as? String,
                    initGit: doc["initGit"] as? Bool ?? false,
                    base: (doc["base"] as? String).flatMap { $0.isEmpty ? nil : $0 }, remotely: true)
                else { return ["error": "the session has no folder to branch"] }
                return ["ok": true, "id": newID.uuidString]
            case (let sid?, "branch-merge"):
                guard store.session(sid)?.worktreeBranch != nil else { return ["error": "not a branch session"] }
                engine.mergeBranch(sid, into: doc["into"] as? String, squash: doc["squash"] as? Bool ?? false,
                                   removeAfter: doc["removeAfter"] as? Bool ?? true)
                return ["ok": true]
            case (let sid?, "branch-pr"):
                guard store.session(sid)?.worktreeBranch != nil else { return ["error": "not a branch session"] }
                engine.branchPullRequest(sid, into: doc["into"] as? String)
                return ["ok": true]
            case (let sid?, "branch-discard"):
                guard store.session(sid)?.worktreeBranch != nil else { return ["error": "not a branch session"] }
                engine.discardBranch(sid)
                return ["ok": true]
            case (let sid?, "branch-decline"):
                guard store.session(sid) != nil else { return ["error": "unknown session"] }
                engine.declineMerge(sid)
                return ["ok": true]
            case (let sid?, "branch-keep"):
                guard store.session(sid)?.worktreeBranch != nil else { return ["error": "not a branch session"] }
                engine.keepBranchQuietly(sid)
                return ["ok": true]
            case (let sid?, "review"):
                guard store.session(sid) != nil else { return ["error": "unknown session"] }
                switch doc["op"] as? String {
                case "add":
                    guard let text = doc["text"] as? String else { return ["error": "text required"] }
                    engine.addReviewComment(sid, text: text, file: doc["file"] as? String, line: doc["line"] as? Int)
                case "remove":
                    guard let cid = (doc["comment"] as? String).flatMap(UUID.init(uuidString:)) else { return ["error": "comment required"] }
                    engine.removeReviewComment(sid, commentID: cid)
                case "viewed":
                    guard let path = doc["path"] as? String else { return ["error": "path required"] }
                    engine.setReviewViewed(sid, path: path, fingerprint: doc["fingerprint"] as? String)
                case "send":
                    return ["ok": true, "sent": engine.sendReview(sid)]
                default:
                    return ["error": "op must be add, remove, viewed or send"]
                }
                return ["ok": true]
            case (let sid?, "rename"):
                guard store.session(sid) != nil, let title = doc["title"] as? String else { return ["error": "unknown session or no title"] }
                engine.rename(sid, to: title)
                return ["ok": true]
            case (let sid?, "nickname"):
                guard store.session(sid) != nil else { return ["error": "unknown session"] }
                if let why = store.setNickname(sid, doc["nickname"] as? String, reclaim: doc["reclaim"] as? Bool ?? false) {
                    return ["error": why]
                }
                return ["ok": true]
            case (let sid?, "forget"):
                guard store.session(sid) != nil else { return ["error": "unknown session"] }
                engine.transcripts.remove(sid)
                store.remove(sid)
                return ["ok": true]
            case (let sid?, "archive"):
                guard store.session(sid) != nil else { return ["error": "unknown session"] }
                engine.archive(sid)
                return ["ok": true]
            case (let sid?, "unarchive"):
                guard store.session(sid) != nil else { return ["error": "unknown session"] }
                engine.unarchive(sid)
                return ["ok": true]
            case (let sid?, "delete"):
                guard store.session(sid) != nil else { return ["error": "unknown session"] }
                engine.delete(sid)
                return ["ok": true]
            default:
                return ["error": "unknown action \(action)"]
            }
        }
        return ControlResponse(r["error"] == nil ? 200 : 400, JSONValue(foundation: r) ?? .object([:]))
    }

    /// The keys a session may be sent by name (SwitchboardEngine.allowedKeys,
    /// in a macOS-only file): enough to answer a TUI prompt, nothing that can
    /// smuggle text or escape sequences.
    static let allowedKeys: Set<String> = [
        "Enter", "Escape", "Tab", "BTab", "Space", "BSpace", "Up", "Down", "Left", "Right",
        "C-c", "y", "n", "a", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    ]

    /// `GET /agent-sessions/<id>/transcript`: the readable transcript
    /// (base64, as macOS sends it), 404 when there is none.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onAgentSessionTranscript h=2afc6fc0b1ecb35b @9936e30c
    func agentSessionTranscript(_ id: UUID) async -> ControlResponse {
        let data: Data? = await {
            guard let (engine, s) = await MainActor.run(body: { () -> (AgentSessionEngine, AgentSession)? in
                guard let st = SessionStores.shared, let e = st.engine, let s = st.sessions.session(id) else { return nil }
                return (e, s)
            }) else { return nil }
            return await engine.readableTranscript(s)
        }()
        guard let data else { return .error(404, "No transcript") }
        return ControlResponse(200, ["transcript": .string(data.base64EncodedString())])
    }
}
