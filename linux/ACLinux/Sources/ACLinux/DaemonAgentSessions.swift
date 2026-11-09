import Foundation

/// The agent-session routes, over the shared AgentSessionEngine with the
/// daemon as its host (LinuxSessionHost). macOS: ACAutomationServer's
/// /agent-sessions routes and the app delegate's onAgentSessionCommand.
extension Daemon {
    /// The engine, its host and stores: made once, at daemon start.
    // @port-skip linux-only: daemon wiring (macOS: the app delegate's properties)
    func startSessionEngine() async {
        let me = self, state = config.stateDir
        // Account features on (macOS: a Preferences switch a server has no
        // window for): Claude signs in with the OAuth stand-in.
        UserDefaults.standard.register(defaults: [ClaudeStandIn.enabledDefaultsKey: true])
        await MainActor.run {
            let stores = SessionStores(stateDir: state)
            SessionStores.shared = stores
            let host = LinuxSessionHost(daemon: me, stateDir: state)
            LinuxSessionHost.shared = host
            // Security Timeline rows (and the OCSF export) carry the
            // workspace's name: the session list's, which every reconcile
            // takes from the store (a rename too), else the store's now.
            SecurityTimeline.shared.workspaceName = { [weak host] id in
                host?.listModel.profileRows.first { $0.id == id }?.name ?? host?.profile(for: id)?.name
            }
            stores.engine = AgentSessionEngine(store: stores.sessions, delegate: host)
            // The coding board and the scheduled automations (macOS: the app
            // delegate's lazy engines, started at launch); the repository
            // watches over them once the dispatcher exists.
            let tasks = CodingTaskEngine(store: stores.codingTasks, delegate: host)
            let automations = ScheduledAutomationEngine(store: stores.automations, delegate: host)
            stores.codingTaskEngine = tasks
            stores.automationEngine = automations
            automations.start()
            tasks.resumePlanningWatchdogs()
            tasks.startHousekeeping()
            // Delegations between agents, and the board's dispatcher (tasks
            // handed to a session or a room come back through them).
            let delegations = DelegationEngine(store: stores.delegations, sessions: stores.sessions,
                                               sessionEngine: stores.engine!, delegate: host)
            delegations.profiles = { ProfileStore().loadAll() }
            delegations.hostLabel = { ProcessInfo.processInfo.hostName }
            delegations.scan = { text in Daemon.heuristicScan(text) }
            // Machines attached here: their sessions are delegation parties
            // like ours (macOS: agentHostLinks, its attached machines).
            LinuxMachines.shared = LinuxMachines(stateDir: state)
            delegations.agentHostLinks = { LinuxMachines.shared?.attached.values.filter(\.connected) ?? [] }
            stores.delegationEngine = delegations
            let dispatcher = TaskDispatcher(delegate: host)
            stores.taskDispatcher = dispatcher
            delegations.onBoardMessage = { d, m in SessionStores.shared?.taskDispatcher?.handle(d, m) }
            delegations.boardWantsRevival = { d in SessionStores.shared?.taskDispatcher?.wantsRevival(d) ?? true }
            stores.startWatches(host: host)
            // Clusters, registries and the connector, their machines this
            // daemon's VMs (macOS: the app delegate's lazy kubeClusterEngine).
            let kubeHost = LinuxKubeHost(daemon: me, session: host)
            LinuxKubeHost.shared = kubeHost
            stores.kubeHost = kubeHost
            let kube = KubeClusterEngine(host: kubeHost, store: stores.kube,
                                         rootDirectory: URL(fileURLWithPath: state, isDirectory: true)
                                            .appendingPathComponent("kube", isDirectory: true))
            stores.kubeEngine = kube
            Daemon.kubeEngineReady(kube)
            // The Switchboard (macOS: the app delegate's lazy switchboardEngine);
            // the user's phone and Slack (the messaging connector) talk to it.
            if let engine = stores.engine {
                let sb = SwitchboardEngine(sessions: stores.sessions, sessionEngine: engine, delegate: host)
                sb.profiles = { ProfileStore().loadAll() }
                sb.listModel = { LinuxSessionHost.shared?.listModel }
                sb.sendToPhone = { text, kind in await SessionStores.shared?.kubeEngine?.sendToUser(text, via: kind) ?? false }
                sb.phoneLinked = { !(SessionStores.shared?.kube.connector?.channels.isEmpty ?? true) }
                sb.roomName = { id in SessionStores.shared?.rooms.room(id)?.name }
                stores.switchboardEngine = sb
                kube.onConnectorMessage = { kind, text in SessionStores.shared?.switchboardEngine?.phoneMessage(kind, text) }
            }
            // Machines of a cluster, registry or connector that's gone.
            let owned = stores.kube.clusters.map(\.id) + stores.kube.registries.map(\.id)
                + stores.kube.connectors.map(\.id)
            let owners = Set(owned.map { $0.uuidString.lowercased() })
            let storeFile = state + "/kube/clusters.json"
            Task { await me.sweepKubeOrphans(owners: owners, storeFile: storeFile, loadedCounts: owned.count) }
            kube.startAutoStartClusters()
            // Their timers are on RunLoop.main, which an async daemon never
            // runs: the same ticks, from here (30 s and 5 min, as macOS's).
            Task { @MainActor in
                var n = 0
                while true {
                    try? await Task.sleep(for: .seconds(30))
                    SessionStores.shared?.automationEngine?.tick()
                    // The watches follow their fix tasks (macOS: every 15 s).
                    SessionStores.shared?.watchEngine?.tick()
                    n += 1
                    if n % 10 == 0 { SessionStores.shared?.codingTaskEngine?.sweepIdleReview() }
                }
            }
            // The dispatcher's 10 s sync (its Timer is on RunLoop.main too).
            Task { @MainActor in
                while true {
                    try? await Task.sleep(for: .seconds(10))
                    SessionStores.shared?.taskDispatcher?.sync()
                }
            }
            // The rosters and the sessions bound to them, kept current (macOS:
            // its session list's refresh), with or without a client watching;
            // then the Switchboard's events from them (its 2 s Timer is on
            // RunLoop.main too).
            Task { @MainActor in
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    LinuxSessionHost.shared?.reconcileSessions()
                    SessionStores.shared?.switchboardEngine?.tick()
                }
            }
            // The guests' hook reports, read as they come (macOS polls 40 ms).
            Task { @MainActor in
                while true {
                    try? await Task.sleep(for: .milliseconds(500))
                    LinuxSessionHost.shared?.readAgentStatus()
                    LinuxSessionHost.shared?.readAgentToolCalls()
                    LinuxSessionHost.shared?.readGuestURLs()
                    // A guest going down for a reboot (its outbox marker).
                    // Neither waits on a VM's end: ticks never pile up.
                    await me.readGuestRebootIntents()
                    // One powered off: its VM ended, as macOS's stops.
                    await me.endPoweredOffGuests()
                    await me.clearBootFailuresOnRoster()
                }
            }
        }
        // Temporary firewall rules: the expired ones switched off (and
        // saved), and the previous run's "until the workspace stops" ones
        // ended (macOS: launch's startFirewallExpirySweep).
        startFirewallExpirySweep()
        // Cluster nodes answer for their cluster's LoadBalancer range once
        // the engine has reserved it.
        startLoadBalancerClaimRefresh()
    }

    /// `GET /agent-sessions/<id>/pending`: what the session waits on (the
    /// Switchboard's pending_question, for a client).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onAgentSessionPending h=aec4eb30e141e85f @d2db8346
    func agentSessionPending(_ id: UUID) async -> ControlResponse {
        let v: JSONValue? = await Task { @MainActor in
            guard let sb = SessionStores.shared?.switchboardEngine, let s = SessionStores.shared?.sessions.session(id) else { return nil }
            return JSONValue(foundation: await sb.pending(s))
        }.value
        guard let v else { return .error(404, "Unknown session") }
        return ControlResponse(200, v)
    }

    /// `POST /agent-sessions/start` and `POST /agent-sessions/<id>/<action>`.
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
            case (nil, "switchboard"):
                // The Switchboard, started (or woken) for a client that
                // clicked its row: {profile?} picks the workspace.
                let preferred = (doc["profile"] as? String).flatMap { key in
                    ProfileStore().loadAll().first { $0.id.uuidString == key || $0.name.lowercased() == key.lowercased() }?.id
                }
                guard let sb = stores.switchboardEngine,
                      let cid = sb.ensureSwitchboard(preferred: preferred, remotely: true)
                else { return ["error": "no workspace to run the Switchboard in"] }
                return ["ok": true, "id": cid.uuidString]
            case (let sid?, "send"):
                // {text}: typed into the live prompt (long text lands in
                // the session's inbox with a pointer), or a resume with it.
                guard let s = store.session(sid) else { return ["error": "unknown session"] }
                guard let text = doc["text"] as? String, !text.isEmpty else { return ["error": "text required"] }
                guard let sb = stores.switchboardEngine else { return ["error": "no session host"] }
                Task { try? await sb.send(s, text) }
                return ["ok": true]
            case (let sid?, "keys"):
                // {keys: [...]}: named keys only (SwitchboardEngine.allowedKeys).
                guard let s = store.session(sid) else { return ["error": "unknown session"] }
                let keys = (doc["keys"] as? [String]) ?? []
                guard !keys.isEmpty, keys.allSatisfy(SwitchboardEngine.allowedKeys.contains), keys.count <= 12 else {
                    return ["error": "keys must be 1–12 of " + SwitchboardEngine.allowedKeys.sorted().joined(separator: " ")]
                }
                guard let sb = stores.switchboardEngine else { return ["error": "no session host"] }
                Task { try? await sb.press(s, keys) }
                return ["ok": true]
            case (nil, "worktree-open"):
                // A fat client's Branches window: {profile, entry fields, tool?}.
                guard let pid = (doc["profile"] as? String).flatMap(UUID.init(uuidString:)),
                      let dir = doc["dir"] as? String, let branch = doc["branch"] as? String
                else { return ["error": "profile, dir and branch required"] }
                let e = WorktreeEntry(dir: dir, root: doc["root"] as? String ?? "", branch: branch,
                                      parent: doc["parent"] as? String ?? "", ahead: 0, changed: 0,
                                      lastCommit: nil, display: doc["display"] as? String ?? "")
                let tool = (doc["tool"] as? String).flatMap(Profile.Tool.init(rawValue:))
                    ?? LinuxSessionHost.shared?.profile(for: pid)?.tool ?? .claude
                let id = engine.openBranchSession(profileID: pid, entry: e, tool: tool, remotely: true)
                return ["ok": true, "id": id.uuidString]
            case (nil, "worktree-discard"):
                guard let pid = (doc["profile"] as? String).flatMap(UUID.init(uuidString:)),
                      let root = doc["root"] as? String, let branch = doc["branch"] as? String
                else { return ["error": "profile, root and branch required"] }
                let e = WorktreeEntry(dir: "", root: root, branch: branch, parent: "", ahead: 0, changed: 0,
                                      lastCommit: nil, display: "")
                engine.discardWorktree(profileID: pid, entry: e,
                                       session: (doc["session"] as? String).flatMap(UUID.init(uuidString:)))
                return ["ok": true]
            case (let sid?, "signin"):
                // The card's sign-in: the registration machine, its page
                // published for the client (LinuxSessionHost.remoteSignIn).
                guard let host = LinuxSessionHost.shared else { return ["error": "no session host"] }
                return host.remoteSignIn(sid)
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
            case (let sid?, "read"):
                // {seen?}: the reply count the client's screen showed (macOS:
                // markSessionRead). A machine's session: its count lives on
                // the machine, so the read goes there (until it confirms).
                if let m = LinuxMachines.shared?.machine(forSession: sid) {
                    if m.unreadOnMachine(sid), let n = m.machineSessions.first(where: { $0.id == sid })?.replies {
                        m.markRead(sid, upTo: min((doc["seen"] as? Int) ?? n, n))
                    }
                    return ["ok": true]
                }
                guard store.session(sid) != nil else { return ["error": "unknown session"] }
                _ = store.markRead(sid, upTo: doc["seen"] as? Int)
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

    /// The Linux stand-in for the on-device prompt-injection classifier
    /// (no ONNX runtime on the server): every message between agents is
    /// screened by the instruction heuristics, and withheld only on a
    /// high-severity hit (hidden Unicode, instruction content). The return
    /// is the classifier's shape: the flagged section with some context,
    /// at most 4000 characters, or nil.
    // @port-skip linux-only: the Linux screen for DelegationEngine.scan (macOS: PromptInjectionClassifier)
    static func heuristicScan(_ text: String) -> String? {
        let findings = InstructionHeuristics.scanHiddenUnicode(text) + InstructionHeuristics.scanInstructionContent(text)
        guard let hit = findings.first(where: { $0.severity == .high }) else { return nil }
        var flagged = text
        if let r = hit.range {
            let lo = text.index(r.lowerBound, offsetBy: -200, limitedBy: text.startIndex) ?? text.startIndex
            let hi = text.index(r.upperBound, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
            flagged = String(text[lo..<hi])
        }
        BACDebug.log("delegation", "withheld (\(hit.signal)): \(hit.detail)")
        return flagged.count > 4000 ? String(flagged.prefix(4000)) + "\n…(truncated)" : flagged
    }

    /// `POST /agent-sessions/git-state {id}`: whether the session's folder
    /// is a git repository (the new-worktree sheet offers `git init` if not).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onAgentSessionGitState h=cbf91830d3252fa3 @b10aa434
    func agentSessionGitState(_ body: JSONValue) async -> ControlResponse {
        guard let sid = body["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return .error(400, "id required") }
        let st: GitFolderState? = await { @MainActor in
            guard let stores = SessionStores.shared, let engine = stores.engine, let s = stores.sessions.session(sid) else { return nil }
            return await engine.gitState(profileID: s.profileID, cwd: s.cwd)
        }()
        guard let st, let v = JSONValue(foundation: st.json) else { return .error(404, "The machine can't be asked right now") }
        return ControlResponse(200, v)
    }
}
