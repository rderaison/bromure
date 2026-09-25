#if os(macOS)
import Foundation

// MARK: - Conductor MCP (vsock 5836)
//
// The Conductor's tools (Conductor.swift). Same transport as the delegation
// MCP — a stdio shim in the guest announces the tmux window it runs in, the
// VM the connection came from fixes the workspace — but only the Conductor
// session gets the shim on its command line (--mcp-config), and every call
// is refused unless the caller IS the Conductor: any other tab that found
// the shim on the meta share would be turned away here.

@MainActor
final class ConductorMCPServer: MCPLineHandler {
    private let profileID: Profile.ID
    private let engine: () -> ConductorEngine?

    init(profileID: Profile.ID, engine: @escaping () -> ConductorEngine?) {
        self.profileID = profileID
        self.engine = engine
    }

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
                "serverInfo": ["name": "bromure-conductor", "version": "1.0.0"],
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

    static let serverInstructions = """
    The Conductor's tools: see and drive every agent session on this Mac. \
    Your brief (CLAUDE.md in your folder) says how to use them. Answering a \
    blocked session, pressing keys at its prompt, and archiving need \
    on_behalf_of — the user's own words asking for it, quoted verbatim.
    """

    private static let sessionArg: [String: Any] = [
        "type": "string", "description": "The session: its handle from list_sessions (or @nickname, or id).",
    ]
    private static let provenanceArg: [String: Any] = [
        "type": "string",
        "description": "The user's words that ask for this, quoted verbatim from their message to you. Checked by the host.",
    ]

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_sessions",
            "description": "Every agent session on this Mac (but you): handle, workspace, agent, folder, state (needs_you / working / ready / asleep / ended), last activity, and the last thing its agent said. Start here.",
            "inputSchema": ["type": "object", "properties": [
                "include_ended": ["type": "boolean", "description": "Also list ended, asleep and archived sessions (default false)."],
            ]],
        ],
        [
            "name": "read_session",
            "description": "What a session has been doing. mode \"recent\" (default): its last turns as text (user, agent, tool calls, questions). mode \"screen\": the last lines of its terminal — shows permission prompts and dialogs no transcript records.",
            "inputSchema": ["type": "object", "properties": [
                "session": sessionArg,
                "mode": ["type": "string", "enum": ["recent", "screen"]],
                "turns": ["type": "integer", "description": "How many user turns back (recent; default 6)."],
                "max_chars": ["type": "integer", "description": "Cap on the text returned (default 6000)."],
            ], "required": ["session"]],
        ],
        [
            "name": "pending_question",
            "description": "What a session that needs the user is waiting on: its question and numbered options when it asked one (AskUserQuestion), plus its screen, which shows a permission prompt or any other dialog.",
            "inputSchema": ["type": "object", "properties": ["session": sessionArg], "required": ["session"]],
        ],
        [
            "name": "list_workspaces",
            "description": "The workspaces sessions can run in (for start_session).",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "next_events",
            "description": "What happened since you last looked: sessions that started, finished a turn, ended, or need the user, and model calls refused (a bad API key, no credit). Returns at once (timeout_seconds waits up to 60 for one when there's none — rarely useful).",
            "inputSchema": ["type": "object", "properties": [
                "cursor": ["type": "integer", "description": "Events after this seq (default: the ones you haven't seen)."],
                "timeout_seconds": ["type": "integer"],
            ]],
        ],
        [
            "name": "send_to_session",
            "description": "Say something to a session: typed into its prompt when it's running, or it's woken up with it. Long or multi-line text is left in a file in its inbox with a one-line pointer. on_behalf_of is required when the session needs the user (that's answering it).",
            "inputSchema": ["type": "object", "properties": [
                "session": sessionArg,
                "text": ["type": "string"],
                "on_behalf_of": provenanceArg,
            ], "required": ["session", "text"]],
        ],
        [
            "name": "answer_question",
            "description": "Answer a session's pending question or prompt for the user: option (1-based number of the choice) presses that number; text types a free answer and Enter. Returns the screen afterwards so you can check it took. Requires on_behalf_of.",
            "inputSchema": ["type": "object", "properties": [
                "session": sessionArg,
                "option": ["type": "integer"],
                "text": ["type": "string"],
                "on_behalf_of": provenanceArg,
            ], "required": ["session", "on_behalf_of"]],
        ],
        [
            "name": "press_keys",
            "description": "Press keys in a session's terminal, for prompts answer_question can't handle: any of Enter Escape Tab BTab Space BSpace Up Down Left Right C-c y n a 0-9 (1–12 keys). Returns the screen afterwards. Requires on_behalf_of.",
            "inputSchema": ["type": "object", "properties": [
                "session": sessionArg,
                "keys": ["type": "array", "items": ["type": "string"]],
                "on_behalf_of": provenanceArg,
            ], "required": ["session", "keys", "on_behalf_of"]],
        ],
        [
            "name": "start_session",
            "description": "Start a new agent session for the user: in a workspace (list_workspaces), optionally in a folder, opening with a self-contained message (it knows nothing of your conversation). Returns its handle.",
            "inputSchema": ["type": "object", "properties": [
                "workspace": ["type": "string", "description": "Workspace name or id."],
                "message": ["type": "string"],
                "agent": ["type": "string", "enum": ["claude", "codex", "grok", "kimi", "omp"], "description": "Default claude."],
                "folder": ["type": "string", "description": "Guest folder (e.g. ~/src/app). Default: a fresh folder of its own."],
                "title": ["type": "string"],
            ], "required": ["workspace", "message"]],
        ],
        [
            "name": "resume_session",
            "description": "Wake an asleep or ended session (its conversation picks up where it left off), optionally with a message.",
            "inputSchema": ["type": "object", "properties": [
                "session": sessionArg,
                "message": ["type": "string"],
            ], "required": ["session"]],
        ],
        [
            "name": "archive_session",
            "description": "Put a session away for the user: its agent stops, the conversation stays readable. Requires on_behalf_of.",
            "inputSchema": ["type": "object", "properties": [
                "session": sessionArg,
                "on_behalf_of": provenanceArg,
            ], "required": ["session", "on_behalf_of"]],
        ],
    ]

    private func callTool(name: String, args: [String: Any], hello: String?) async -> [String: Any] {
        guard let engine = engine() else { return errorResult("The Conductor isn't available on this host.") }
        guard let w = DelegationMCPServer.windowIndex(fromHello: hello),
              let me = engine.sessions.session(profileID: profileID, windowIndex: w), me.isConductor else {
            return errorResult("These tools belong to the Conductor session only.")
        }
        let iso = ISO8601DateFormatter()
        func session(_ key: String = "session") -> AgentSession? {
            (args[key] as? String).flatMap(engine.resolve)
        }
        func unknown() -> [String: Any] {
            errorResult("No such session “\(args["session"] as? String ?? "")” — see list_sessions.")
        }
        func state(_ s: AgentSession) -> String {
            if s.isArchived { return "archived" }
            switch engine.bucket(s) {
            case .needsYou: return "needs_you"
            case .working: return "working"
            case .idle: return "ready"
            case .asleep: return "asleep"
            case .ended, nil: return "ended"
            }
        }
        /// The screen a beat after keys were pressed, so the caller sees
        /// whether they took.
        func screenAfter(_ s: AgentSession) async -> [String: Any] {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let fresh = engine.sessions.session(s.id) ?? s
            return ["ok": true, "screen": await engine.screen(fresh, lines: 25) ?? "(no screen)"]
        }

        do {
            switch name {
            case "list_sessions":
                let all = (args["include_ended"] as? Bool) ?? false
                let handles = engine.handles()
                let list = engine.sessions.sessions
                    .filter { !$0.isConductor && !$0.isDeleted }
                    .filter { s in
                        all || (!s.isArchived && ["needs_you", "working", "ready"].contains(state(s)))
                    }
                    .sorted { SessionHome.lastActivity($0) > SessionHome.lastActivity($1) }
                var out: [[String: Any]] = []
                for s in list {
                    var o: [String: Any] = [
                        "handle": handles[s.id] ?? s.title, "title": s.title,
                        "workspace": engine.workspaceName(s.profileID),
                        "agent": s.tool.rawValue, "folder": s.cwd, "state": state(s),
                        "last_activity": iso.string(from: SessionHome.lastActivity(s)),
                    ]
                    if let n = s.nickname { o["nickname"] = "@" + n }
                    if let b = s.worktreeBranch { o["branch"] = b }
                    if s.needsSignIn == true { o["note"] = "waiting for the user to sign the agent in" }
                    if let refused = engine.recentRefusal(for: s) { o["api_error"] = refused }
                    // The last words only for sessions in flight — reading
                    // every transcript of every asleep session is slow.
                    if ["needs_you", "working", "ready"].contains(state(s)),
                       let last = ConductorEngine.lastWords(await engine.transcript(s)) {
                        o["last_said"] = last
                    }
                    out.append(o)
                }
                let hidden = all ? 0 : engine.sessions.sessions
                    .filter { !$0.isConductor && !$0.isDeleted }.count - list.count
                engine.markAllSeen()
                var res: [String: Any] = ["sessions": out]
                if hidden > 0 { res["not_shown"] = "\(hidden) asleep, ended or archived — include_ended: true lists them" }
                return textResult(jsonString(res))

            case "read_session":
                guard let s = session() else { return unknown() }
                if (args["mode"] as? String) == "screen" {
                    return textResult(await engine.screen(s) ?? "(no live screen — the session isn't running)")
                }
                let items = await engine.transcript(s)
                guard !items.isEmpty else { return textResult("(no transcript yet)") }
                let text = ConductorEngine.render(items, turns: (args["turns"] as? Int) ?? 6,
                                                  maxChars: (args["max_chars"] as? Int) ?? 6000)
                return textResult("\(engine.label(s)) — \(state(s))\n\n" + text)

            case "pending_question":
                guard let s = session() else { return unknown() }
                var o = await engine.pending(s)
                o["session"] = engine.handles()[s.id] ?? s.title
                o["state"] = state(s)
                return textResult(jsonString(o))

            case "list_workspaces":
                let ws = engine.profiles().map { ["name": $0.name, "id": $0.id.uuidString] }
                return textResult(jsonString(["workspaces": ws]))

            case "next_events":
                let t = TimeInterval((args["timeout_seconds"] as? Int) ?? 0)
                let got = await engine.nextEvents(after: args["cursor"] as? Int, timeout: t)
                guard !got.isEmpty else { return textResult("Nothing new.") }
                let handles = engine.handles()
                return textResult(jsonString(["events": got.map { e -> [String: Any] in
                    var o: [String: Any] = ["seq": e.seq, "time": iso.string(from: e.at),
                                            "kind": e.kind.rawValue, "text": e.text]
                    if let sid = e.sessionID { o["session"] = handles[sid] ?? sid.uuidString }
                    return o
                }]))

            case "send_to_session":
                guard let s = session() else { return unknown() }
                guard let text = args["text"] as? String else { return errorResult("text is required") }
                if engine.bucket(s) == .needsYou,
                   let why = await engine.verifyProvenance(args["on_behalf_of"] as? String) {
                    return errorResult("\(engine.label(s)) is waiting on the user, so this is answering it. " + why)
                }
                try await engine.send(s, text)
                return textResult("Sent to \(engine.label(s)).")

            case "answer_question":
                guard let s = session() else { return unknown() }
                if let why = await engine.verifyProvenance(args["on_behalf_of"] as? String) { return errorResult(why) }
                if let n = args["option"] as? Int {
                    guard (1...9).contains(n) else { return errorResult("option must be 1–9") }
                    try await engine.press(s, [String(n)])
                } else if let text = args["text"] as? String, !text.isEmpty {
                    try await engine.send(s, text)
                } else {
                    return errorResult("Give option or text.")
                }
                return textResult(jsonString(await screenAfter(s)))

            case "press_keys":
                guard let s = session() else { return unknown() }
                if let why = await engine.verifyProvenance(args["on_behalf_of"] as? String) { return errorResult(why) }
                try await engine.press(s, (args["keys"] as? [String]) ?? [])
                return textResult(jsonString(await screenAfter(s)))

            case "start_session":
                guard let key = args["workspace"] as? String,
                      let p = engine.profiles().first(where: {
                          $0.id.uuidString == key || $0.name.lowercased() == key.lowercased() })
                else { return errorResult("Unknown workspace — see list_workspaces.") }
                guard let message = (args["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !message.isEmpty else { return errorResult("message is required") }
                let tool = (args["agent"] as? String).flatMap(Profile.Tool.init(rawValue:)) ?? .claude
                let id = engine.sessionEngine.start(.init(
                    profileID: p.id, tool: tool,
                    cwd: (args["folder"] as? String) ?? "~",
                    openingMessage: message,
                    title: (args["title"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }
                        .flatMap { $0.isEmpty ? nil : $0 }))
                engine.markTouched(id)
                return textResult(jsonString([
                    "started": true, "handle": engine.handles()[id] ?? "",
                    "next": "It's booting; you'll get a notice when it needs the user or finishes its first turn.",
                ]))

            case "resume_session":
                guard let s = session() else { return unknown() }
                engine.markTouched(s.id)
                engine.sessionEngine.resume(s.id, message: args["message"] as? String, quietly: true)
                return textResult("Resuming \(engine.label(s)).")

            case "archive_session":
                guard let s = session() else { return unknown() }
                if let why = await engine.verifyProvenance(args["on_behalf_of"] as? String) { return errorResult(why) }
                engine.sessionEngine.archive(s.id)
                return textResult("Archived \(engine.label(s)).")

            default:
                return errorResult("Unknown tool: \(name)")
            }
        } catch ConductorEngine.ActError.refused(let why) {
            return errorResult(why)
        } catch {
            return errorResult(error.localizedDescription)
        }
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
#endif
