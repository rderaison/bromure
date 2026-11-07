import Foundation

/// The coding board's and the scheduled automations' routes, over the shared
/// engines with the daemon as their host (LinuxTaskHost). macOS: the
/// automation server's /tasks, /automations and /automation-runs routes and
/// the app delegate's callbacks behind them; same paths, same JSON.
extension Daemon {
    /// `/tasks…`, `/automations…`, `/automation-runs/…`; nil for any other path.
    // @port-skip linux-only: the Linux router's share of ACAutomationServer.handleRequest
    func boardRoute(_ method: String, _ path: String, _ body: JSONValue) async -> ControlResponse? {
        let doc = (body.foundationObject as? [String: Any]) ?? [:]
        switch (method, path) {
        case ("GET", "/tasks"): return await reply { $0.taskList() }
        case ("POST", "/tasks"): return await okReply { $0.upsertTask(doc) }
        case ("GET", let p) where p.hasPrefix("/tasks/") && p.hasSuffix("/transcript"):
            guard let id = UUID(uuidString: Self.segment(p.dropFirst("/tasks/".count).dropLast("/transcript".count)))
            else { return .error(400, "Bad task id") }
            return await taskTranscript(id)
        case (let m, let p) where p.hasPrefix("/tasks/"):
            let parts = p.dropFirst("/tasks/".count).split(separator: "/", maxSplits: 1).map(String.init)
            guard let id = parts.first.map(Self.segment).flatMap(UUID.init(uuidString:)) else { return .error(400, "Bad task id") }
            let action = m == "DELETE" ? "delete" : (parts.count > 1 ? parts[1] : "")
            if action == "answer" { return await taskAnswer(id, doc) }
            let r = await MainActor.run { SessionStores.shared?.taskCommand(id, action, doc) ?? ["error": "no task engine"] }
            return ControlResponse(r["error"] == nil ? 200 : 400, JSONValue(foundation: r) ?? .object([:]))
        case ("GET", "/automations"): return await reply { $0.automationList() }
        case ("POST", "/automations"): return await okReply { $0.upsertAutomation(doc) }
        case ("POST", "/automation-sources"):
            let r = await MainActor.run { () -> SessionStores? in SessionStores.shared }
            guard let stores = r else { return .error(503, "no session engine") }
            let out = await stores.automationSources(doc)
            return ControlResponse(out["error"] == nil ? 200 : 400, JSONValue(foundation: out) ?? .object([:]))
        case (let m, let p) where p == "/watches" || p.hasPrefix("/watches/") || p.hasPrefix("/findings/"):
            let r = await MainActor.run { () -> SessionStores? in SessionStores.shared }
            guard let stores = r else { return .error(503, "no session engine") }
            let out = await stores.watchesCommand(method: m, path: String(p.dropFirst()), body: doc)
            return ControlResponse(out["error"] == nil ? 200 : 400, JSONValue(foundation: out) ?? .object([:]))
        case (let m, let p) where p.hasPrefix("/automations/"):
            let parts = p.dropFirst("/automations/".count).split(separator: "/", maxSplits: 1).map(String.init)
            let id = parts.first.map(Self.segment).flatMap(UUID.init(uuidString:))
            let action = parts.count > 1 ? parts[1] : ""
            guard ["DELETE": [""], "POST": ["run", "toggle"]][m]?.contains(action) == true else {
                return .error(404, "Not found", ["path": .string(path)])
            }
            let ok = await MainActor.run { () -> Bool in
                guard let id, let stores = SessionStores.shared else { return false }
                switch action {
                case "run": return stores.runAutomationNow(id)
                case "toggle": return stores.toggleAutomation(id)
                default: stores.automations.remove(id); return true
                }
            }
            return ControlResponse(ok ? 200 : 400, ["ok": .bool(ok)])
        case (let m, let p) where p.hasPrefix("/automation-runs/"):
            let parts = p.dropFirst("/automation-runs/".count).split(separator: "/", maxSplits: 1).map(String.init)
            guard let runID = parts.first.map(Self.segment).flatMap(UUID.init(uuidString:)) else {
                return .error(400, "Bad run id")
            }
            switch (m, parts.count > 1 ? parts[1] : "") {
            case ("POST", "acknowledge"):
                let ok = await MainActor.run { SessionStores.shared?.acknowledgeRun(runID) ?? false }
                return ControlResponse(ok ? 200 : 404, ["ok": .bool(ok)])
            case ("GET", "transcript"):
                guard let data = try? Data(contentsOf: AutomationRunArchive.transcriptURL(for: runID)) else {
                    return .error(404, "No transcript")
                }
                return ControlResponse(200, ["transcript": .string(data.base64EncodedString())])
            default:
                return .error(404, "Not found", ["path": .string(path)])
            }
        default:
            return nil
        }
    }

    /// `POST /tasks/<id>/answer`: answered once the board actually took the
    /// answer (or refused it, with why).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onTaskAnswer h=b83ac739078242b6 @dd7ba30d
    private func taskAnswer(_ id: UUID, _ body: [String: Any]) async -> ControlResponse {
        let r: [String: Any] = await { @MainActor in
            guard let stores = SessionStores.shared, let dispatcher = stores.taskDispatcher else {
                return ["ok": false, "error": "no dispatcher"]
            }
            guard let text = body["text"] as? String, !text.isEmpty else { return ["ok": false, "error": "text required"] }
            let ask = (body["ask"] as? String).flatMap(UUID.init(uuidString:))
            if await dispatcher.answer(id, askID: ask, text: text) { return ["ok": true] }
            return ["ok": false, "error": stores.codingTasks.task(id)?.lastError
                        ?? NSLocalizedString("The answer couldn't be sent.", comment: "coding task: answer refused")]
        }()
        return ControlResponse(200, JSONValue(foundation: r) ?? .object([:]))
    }

    /// `GET /tasks/<id>/transcript`: base64, from the archive or the guest.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onTaskTranscript h=32bdca5276ead99b @9936e30c
    private func taskTranscript(_ id: UUID) async -> ControlResponse {
        let found: (LinuxSessionHost, CodingTask)? = await MainActor.run {
            guard let host = LinuxSessionHost.shared, let t = SessionStores.shared?.codingTasks.task(id) else { return nil }
            return (host, t)
        }
        guard let (host, task) = found, let raw = await host.fetchTaskTranscriptRaw(task) else {
            return .error(404, "No transcript")
        }
        return ControlResponse(200, ["transcript": .string(Data(raw.utf8).base64EncodedString())])
    }

    // @port-skip linux-only: daemon route plumbing
    private func reply(_ body: @MainActor @escaping (SessionStores) -> [String: Any]) async -> ControlResponse {
        let r = await MainActor.run { SessionStores.shared.map(body) ?? [:] }
        return ControlResponse(200, JSONValue(foundation: r) ?? .object([:]))
    }

    // @port-skip linux-only: daemon route plumbing
    private func okReply(_ body: @MainActor @escaping (SessionStores) -> Bool) async -> ControlResponse {
        let ok = await MainActor.run { SessionStores.shared.map(body) ?? false }
        return ControlResponse(ok ? 200 : 400, ["ok": .bool(ok)])
    }

    // @port-skip linux-only: daemon route plumbing
    private static func segment<S: StringProtocol>(_ s: S) -> String {
        String(s).removingPercentEncoding ?? String(s)
    }
}

extension SessionStores {
    // MARK: The coding board

    // partial: no encoded-row memo (EncodedRowMemo): each request encodes the rows

    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListTasks h=14bbb26eb97daa18 @b41d9876
    func taskList() -> [String: Any] {
        ["tasks": codingTasks.tasks.compactMap(Self.dict)]
    }

    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onUpsertTask h=92a11244437cb76e @9936e30c
    func upsertTask(_ doc: [String: Any]) -> Bool {
        guard let task = Self.decode(CodingTask.self, doc) else { return false }
        codingTasks.upsert(task)
        return true
    }

    /// One coding-board verb on one task (`POST /tasks/<id>/<action>`,
    /// `DELETE /tasks/<id>`): macOS's, less what needs its task dispatcher
    /// (assign, answer, recall, locate); the plan stream's relay is
    /// DaemonPlanStreams.swift's.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onTaskCommand h=09891b7729777755 @9936e30c
    func taskCommand(_ id: UUID, _ action: String, _ body: [String: Any]) -> [String: Any] {
        guard let engine = codingTaskEngine else { return ["error": "no task engine"] }
        guard codingTasks.task(id) != nil else { return ["error": "unknown task"] }
        switch action {
        case "start":
            engine.start(id)
        case "assign":
            // Queue it for a session, a room, or new agents ({kind, id,
            // label}); kind "none" takes it off its queue.
            guard let dispatcher = taskDispatcher else { return ["error": "no dispatcher"] }
            if body["kind"] as? String == "none" {
                dispatcher.assign(id, to: nil)
            } else if let kind = (body["kind"] as? String).flatMap(TaskAssignment.Kind.init(rawValue:)) {
                let a = kind == .worktree ? TaskAssignment.newAgent : kind == .switchboard ? TaskAssignment.switchboard : TaskAssignment(
                    kind: kind, id: (body["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    label: body["label"] as? String ?? "")
                dispatcher.assign(id, to: a)
            } else {
                return ["error": "kind required"]
            }
        case "answer":
            guard let text = body["text"] as? String, !text.isEmpty else { return ["error": "text required"] }
            let ask = (body["ask"] as? String).flatMap(UUID.init(uuidString:))
            Task { @MainActor [weak self] in _ = await self?.taskDispatcher?.answer(id, askID: ask, text: text) }
        case "recall":
            taskDispatcher?.recall(id)
        case "locate":
            Task { @MainActor [weak self] in _ = await self?.taskDispatcher?.relocateDelivery(id) }
        case "plan", "plan-start":   // plan-start: legacy alias
            engine.plan(id)
        case "send-back":
            Task { @MainActor in await engine.sendBack(id) }
        case "merge", "land":
            // {mode: merge|squash|pr, target?, keepBranch?, push?}; the
            // legacy merge body ({squash, cleanup}) still works.
            let mode = (body["mode"] as? String).flatMap(TaskLanding.Mode.init(rawValue:))
                ?? ((body["squash"] as? Bool ?? false) ? .squash : .merge)
            let keep = body["keepBranch"] as? Bool ?? !(body["cleanup"] as? Bool ?? true)
            engine.land(id, mode: mode, target: body["target"] as? String,
                        keepBranch: keep, push: body["push"] as? Bool ?? false)
        case "merge-batch":
            let others = ((body["with"] as? [String]) ?? []).compactMap(UUID.init(uuidString:))
            engine.landBatch([id] + others, keepBranch: body["keepBranch"] as? Bool ?? false,
                             push: body["push"] as? Bool ?? false)
        case "open-pr":
            engine.land(id, mode: .pr, target: body["target"] as? String)
        case "retry-landing":
            engine.retryLanding(id)
        case "cancel-landing":
            engine.cancelLanding(id)
        case "mark-merged":
            engine.markMerged(id)
        case "stop":
            if let why = engine.stopToBacklog(id) { return ["ok": false, "error": why] }
        case "report-landing":
            let status = body["status"] as? String ?? ""
            let summary = body["summary"] as? String ?? ""
            let pr = body["prURL"] as? String
            Task { @MainActor in _ = await engine.reportLanding(id, status: status, summary: summary, prURL: pr) }
        case "validate":
            engine.validate(id)
        case "to-testing":
            engine.moveToTesting(id)
        case "to-in-progress":
            engine.moveToInProgress(id)
        case "resume":
            engine.resumeSession(id)
        case "start-over":
            engine.startOver(id)
        case "close-no-merge":
            engine.closeWithoutMerge(id)
        case "mark-done":
            engine.markDone(id)
        case "rank":
            guard let rank = (body["rank"] as? NSNumber)?.doubleValue, rank.isFinite
            else { return ["error": "rank required"] }
            codingTasks.mutate(id) { $0.queueRank = rank }
        case "comment-remove":
            guard let cid = (body["comment"] as? String).flatMap(UUID.init(uuidString:))
            else { return ["error": "comment required"] }
            codingTasks.mutate(id) { t in t.comments.removeAll { $0.id == cid && $0.sentAt == nil } }
        case "viewed":
            guard let path = body["path"] as? String else { return ["error": "path required"] }
            let fp = body["fingerprint"] as? String
            codingTasks.mutate(id) { t in
                var v = t.reviewViewed ?? [:]
                v[path] = fp
                t.reviewViewed = v.isEmpty ? nil : v
            }
        case "comment":
            guard let text = body["text"] as? String, !text.isEmpty else { return ["error": "text required"] }
            codingTasks.mutate(id) {
                $0.comments.append(ReviewComment(text: text, file: body["file"] as? String, line: body["line"] as? Int))
            }
        case "delete":
            codingTasks.remove(id)
            engine.pumpQueue()
        case "destroy":
            engine.destroy(id)
        case "plan-events":
            return planEvents(id, body)
        case "plan-cmd":
            return planCommand(id, body)
        default:
            return ["error": "unknown action", "action": action]
        }
        return ["ok": true, "stage": codingTasks.task(id)?.stage.rawValue ?? "deleted"]
    }

    // MARK: Scheduled automations

    /// Automations, their runs and next fires, with the repository watches
    /// and their findings riding along for the fat client.
    // partial: no encoded-row memo (EncodedRowMemo): each request encodes the rows
    // @port ACAppDelegate.automationScheduledList() h=7100e2d62c0f78c0 @b41d9876
    func automationList() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "automations": automations.automations.compactMap(Self.dict),
            "runs": automations.runs.compactMap(Self.dict),
            "nextFires": automations.allNextFires().mapValues { iso.string(from: $0) },
            "timeZone": TimeZone.current.identifier,
            "watches": findings.watches.compactMap(Self.dict),
            "findings": findings.findings.compactMap(Self.dict),
        ]
    }

    // @port ACAppDelegate.automationUpsertScheduled(_: [String:Any]) h=24dffafecafc02ac @9936e30c
    func upsertAutomation(_ doc: [String: Any]) -> Bool {
        guard let automation = Self.decode(ScheduledAutomation.self, doc) else { return false }
        saveAutomation(automation)
        return true
    }

    // @port ACAppDelegate.saveAutomation(_: ScheduledAutomation) h=5dffd494bcb2b4b8 @9936e30c
    func saveAutomation(_ automation: ScheduledAutomation) {
        automations.upsert(automation)
        automationEngine?.tick()
    }

    // @port ACAppDelegate.runAutomationNow(_: UUID) h=2291ec6040bd9444 @9936e30c
    func runAutomationNow(_ id: UUID) -> Bool {
        guard let automation = automations.automation(id), let engine = automationEngine else { return false }
        engine.runNow(automation)
        return true
    }

    // @port ACAppDelegate.toggleAutomation(_: UUID) h=dcbba8fa59b171f2 @9936e30c
    func toggleAutomation(_ id: UUID) -> Bool {
        guard var automation = automations.automation(id) else { return false }
        automation.enabled.toggle()
        saveAutomation(automation)
        return true
    }

    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onAcknowledgeRun h=c536b1d7ceb3979a @9936e30c
    func acknowledgeRun(_ runID: UUID) -> Bool {
        guard automations.runs.contains(where: { $0.id == runID }) else { return false }
        automations.acknowledge(runID)
        return true
    }

    /// The /state keys of the board and the automations.
    // @port-skip linux-only: daemon /state plumbing (macOS: ACAutomationServer's state snapshot)
    func boardStateEntries() -> [String: JSONValue] {
        [
            "automations": JSONValue(foundation: automationList()) ?? .object([:]),
            "tasks": JSONValue(foundation: taskList()) ?? .object([:]),
        ]
    }

    // @port-skip linux-only: ACAppDelegate.codableToDict
    private static func dict<T: Encodable>(_ value: T) -> [String: Any]? {
        JSONValue.encoding(value)?.foundationObject as? [String: Any]
    }

    // @port-skip linux-only: the JSON decoding macOS's callbacks do inline
    private static func decode<T: Decodable>(_ type: T.Type, _ doc: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: doc) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }
}

extension Daemon {
    /// The workspace's MCP sockets for its agents (macOS: the board's and the
    /// automations' TaskMCPVsockBridge per VM): the coding board on 5831,
    /// the workspace's own automations and its findings on 5833, the
    /// clusters and registries it may use on 5834, delegations between
    /// agents on 5835, the Switchboard's tools on 5836 (its own MCP: only
    /// the Switchboard session may use them). `stored`: a restarted
    /// daemon's listeners, by fd-store prefix. One that can't listen is
    /// left out (its tools then fail in the guest), logged.
    // @port-skip linux-only: the per-VM MCP listeners (macOS: in ACAppDelegate's VM start, on the VZ socket device)
    func serveMCP(_ rec: VMRecord, udsPath: String, stored: [String: Int32]) async -> [MCPLineListener] {
        let pid = UUID(uuidString: rec.id) ?? UUID()
        let short = rec.shortId, name = rec.name
        return await MainActor.run {
            var out: [MCPLineListener] = []
            let board = TaskBoardMCPServer(profileID: pid,
                                           store: { SessionStores.shared?.codingTasks },
                                           engine: { SessionStores.shared?.codingTaskEngine })
            let automations = AutomationMCPServer(
                profileID: pid,
                store: { SessionStores.shared?.automations },
                profile: { ProfileStore().loadAll().first { $0.id == pid } },
                save: { a in SessionStores.shared?.saveAutomation(a) },
                remove: { id in SessionStores.shared?.automations.remove(id) },
                runNow: { id in _ = SessionStores.shared?.runAutomationNow(id) },
                watches: { SessionStores.shared?.watchEngine })
            let infra = KubeMCPServer(profileID: pid,
                                      store: { SessionStores.shared?.kube },
                                      engine: { SessionStores.shared?.kubeEngine })
            let delegation = DelegationMCPServer(profileID: pid,
                                                 sessions: { SessionStores.shared?.sessions },
                                                 engine: { SessionStores.shared?.delegationEngine })
            let switchboard = SwitchboardMCPServer(profileID: pid, engine: { SessionStores.shared?.switchboardEngine })
            for (prefix, port, server) in [("tbmcp-", GuestPorts.taskBoardMCPVsockPort, board as any MCPLineHandler),
                                           ("amcp-", GuestPorts.automationMCPVsockPort, automations as any MCPLineHandler),
                                           ("kmcp-", GuestPorts.kubeMCPVsockPort, infra as any MCPLineHandler),
                                           ("dmcp-", GuestPorts.delegationMCPVsockPort, delegation as any MCPLineHandler),
                                           ("sbmcp-", GuestPorts.switchboardMCPVsockPort, switchboard as any MCPLineHandler)] {
                do {
                    out.append(try MCPLineListener(udsPath: udsPath, port: port, server: server,
                                                   fdStoreName: prefix + short, stored: stored[prefix]))
                } catch {
                    FileHandle.standardError.write(Data("bromure-ac daemon: '\(name)': no MCP listener on \(port): \(error)\n".utf8))
                }
            }
            return out
        }
    }
}
