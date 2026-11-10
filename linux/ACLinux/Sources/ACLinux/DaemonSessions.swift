import Foundation

/// The automation API's sessions (macOS: a workspace's window, attached to
/// its running VM): on a server with no screen, a session is a running
/// workspace, its window id 0 and never visible. `bromure-ac mcp` and the
/// API's scripts list, open, close and exec in them as they do on a Mac.
extension Daemon {
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case (let m, let p) where p.hasPrefix("/sessions/"): h=b445bd8b8be2e1cb @f127f8ab
    func sessionsRoute(_ method: String, _ path: String, _ body: JSONValue) async -> ControlResponse? {
        switch (method, path) {
        case ("GET", "/sessions"): return listSessions()
        case ("POST", "/sessions"): return await createSession(body)
        case ("GET", "/workspaces"): return listWorkspaces()
        case ("GET", "/app/state"): return appState()
        case (_, let p) where p.hasPrefix("/sessions/"): return await sessionRoute(method, String(p.dropFirst("/sessions/".count)), body)
        default: return nil
        }
    }

    /// A running workspace as a session (macOS: ACAutomationSessionInfo).
    // partial: no window on a server: windowId 0, never visible
    // @port ACAutomationSessionInfo.toDict() h=ffe6eda5df3fe91c @f127f8ab
    static func sessionInfo(_ p: Profile) -> JSONValue {
        ["profileId": .string(p.id.uuidString), "profileName": .string(p.name), "windowId": 0, "visible": false]
    }

    /// The running workspaces (not a cluster's or a registry's machines).
    // @port-skip linux-only: the running workspaces, as macOS's runningSessions
    func runningWorkspaces() -> [Profile] {
        records.filter { !$0.managed && ($0.state == .running || $0.state == .starting) }.compactMap { existingProfile(for: $0) }
    }

    // partial: the running workspaces
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/sessions"): h=f55eefa10cd15af7 @f127f8ab
    // partial: windowID/visible meaningless
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListSessions h=bbcb6c6a79d51cc4 @d3ebbda2
    func listSessions() -> ControlResponse {
        ControlResponse(200, ["sessions": .array(runningWorkspaces().map(Self.sessionInfo))])
    }

    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("POST", "/sessions"): h=ed84615f7b55066b @f127f8ab
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onCreateSession h=45ab1d9bbcf7f17c @d3ebbda2
    func createSession(_ body: JSONValue) async -> ControlResponse {
        guard let key = body["profile"]?.stringValue ?? body["profileId"]?.stringValue, !key.isEmpty else {
            return .error(400, "Missing 'profile' field")
        }
        guard let info = await automationCreateSession(key) else { return .error(500, "Failed to create session") }
        return ControlResponse(201, info)
    }

    /// The workspace started if it isn't running (decision prompts through
    /// the client, as a control-socket start), then waited for (30 s).
    // partial: "attached" is "running" on a server
    // @port ACAppDelegate.automationCreateSession(profileNameOrID: String) h=721b966f09fb9e07 @d3ebbda2
    func automationCreateSession(_ key: String) async -> JSONValue? {
        guard let p = Self.workspace(key), let rec = registry.find(p.id.uuidString.lowercased()) else { return nil }
        if live[rec.id] == nil {
            let r = await start(rec)
            guard r.status < 300 else { return nil }
        }
        for _ in 0..<300 {
            if registry.find(rec.id)?.state == .running { return Self.sessionInfo(p) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    // @port ACAutomationServer.handleSessionRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) h=24480c6ac1efef19 @f127f8ab
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onDestroySession h=9afbba69593bee80 @d3ebbda2
    func sessionRoute(_ method: String, _ rest: String, _ body: JSONValue) async -> ControlResponse {
        if rest.hasSuffix("/exec") {
            guard method == "POST" else { return .error(405, "Method not allowed") }
            let key = Self.segment(String(rest.dropLast("/exec".count)))
            guard let p = Self.workspace(key), let rec = registry.find(p.id.uuidString.lowercased()) else {
                return .error(404, "Session not found")
            }
            return await exec(rec, body)
        }
        let key = Self.segment(rest)
        switch method {
        case "GET":
            guard let p = runningWorkspaces().first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name == key })
            else { return .error(404, "Session not found") }
            return ControlResponse(200, Self.sessionInfo(p))
        case "DELETE":
            return await automationDestroySession(key) ? ControlResponse(200, ["status": "closed"]) : .error(404, "Session not found")
        default:
            return .error(405, "Method not allowed")
        }
    }

    /// A path segment, its %XX decoded (`bromure-ac mcp` encodes names).
    // @port-skip linux-only: see sessionRoute
    static func segment(_ s: String) -> String { s.removingPercentEncoding ?? s }

    /// Closed as the workspace says (its close action; Ask asks through the
    /// client): run in the background keeps the VM (the session goes on),
    /// suspend and shut down end it.
    // partial: no window to detach: Run in the Background leaves the VM running
    // @port ACAppDelegate.automationDestroySession(profileNameOrID: String) h=3d799687ae7afa9c @d3ebbda2
    // partial: background = leave the VM running (no window to detach)
    // @port ACAppDelegate.applyCloseAction(_: Profile.CloseAction, to: Profile.ID) h=566bec7e97cff836 @d3ebbda2
    func automationDestroySession(_ key: String) async -> Bool {
        guard let p = Self.workspace(key), let rec = registry.find(p.id.uuidString.lowercased()), live[rec.id] != nil else { return false }
        var action = p.closeAction
        if action == .ask {
            guard let chosen = await Self.promptCloseAction(forName: p.name) else { return false }
            action = chosen
        }
        switch action {
        case .background, .ask: return true
        case .suspend: return await deleteVM(rec, action: "suspend").status < 300
        case .shutdown: return await deleteVM(rec, action: "shutdown").status < 300
        }
    }

    /// macOS's close question, through the client: its words and buttons;
    /// nobody answering is Suspend, Cancel nil.
    // partial: through the fat client only (no screen here)
    // @port ACAppDelegate.promptCloseActionAsync(forName: String) h=0ab4b2f71acb333d @d3ebbda2
    // partial: async, asks only through the fat client (PendingPromptBroker)
    // @port ACAppDelegate.promptCloseAction(forName: String) h=b42b23f24d96536b @d3ebbda2
    static func promptCloseAction(forName name: String) async -> Profile.CloseAction? {
        let (title, message, buttons) = closePromptParts(name: name)
        return closeAction(forChoice: await PendingPromptBroker.shared.askAsync(
            profileID: nil, title: title, message: message, buttons: buttons, fallback: 1))
    }

    // @port ACAppDelegate.static closePromptParts(name: String) h=65a3df034664c2cc @d3ebbda2
    static func closePromptParts(name: String) -> (title: String, message: String, buttons: [String]) {
        (String(format: NSLocalizedString("Close “%@”?", comment: ""), name),
         NSLocalizedString(
            "Run in the background keeps the VM running so you can reattach later. Suspend saves its state to disk. Shut down powers it off.",
            comment: ""),
         [NSLocalizedString("Run in the Background", comment: ""),
          NSLocalizedString("Suspend", comment: ""),
          NSLocalizedString("Shut Down", comment: ""),
          NSLocalizedString("Cancel", comment: "")])
    }

    // @port ACAppDelegate.static closeAction(forChoice: Int) h=94c11e77953dfe64 @d3ebbda2
    static func closeAction(forChoice choice: Int) -> Profile.CloseAction? {
        switch choice {
        case 0: return .background
        case 1: return .suspend
        case 2: return .shutdown
        default: return nil
        }
    }

    // partial: every workspace this daemon has (its workspace rows, as /state's)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/workspaces"): h=1abca9f46bf2d854 @f127f8ab
    // partial: rows are thin (see C automationWorkspaceList)
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListWorkspaces h=2941378ab44054f9 @d3ebbda2
    func listWorkspaces() -> ControlResponse {
        ControlResponse(200, ["workspaces": .array(records.filter { !$0.managed }.map(compromisedRow))])
    }

    // partial: no windows on a server (mainWindowOpen/editorOpen false), and the control socket is the trusted local caller
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/app/state"): h=10a6ac728f1b5c3d @f127f8ab
    // partial: window flags false; locale from LANG
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onGetAppState h=9b1ebc5a4003e418 @d3ebbda2
    func appState() -> ControlResponse {
        let locale = ProcessInfo.processInfo.environment["LANG"].map { String($0.prefix { $0 != "." }) } ?? "system"
        return ControlResponse(200, [
            "locale": .string(locale), "mainWindowOpen": false, "editorOpen": false,
            "profileCount": .number(Double(ProfileStore().loadAll().count)),
            "sessionCount": .number(Double(runningWorkspaces().count)),
            "hasBaseImage": .bool((try? config.checkedImage()) != nil && Self.hasImageFiles(config.imageDir)),
            "debugEnabled": true,
        ])
    }

    // @port-skip linux-only: see appState
    static func hasImageFiles(_ dir: String) -> Bool { FileManager.default.fileExists(atPath: dir + "/base.img") }
}
