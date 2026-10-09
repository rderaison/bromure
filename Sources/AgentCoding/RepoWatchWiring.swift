#if os(macOS)
import AppKit
import Foundation

// App-delegate glue for the repository watches: the hub's actions, the
// control-socket routes (the fat client's and the debug hooks'), and the
// workspace list the watch editor offers.
extension ACAppDelegate {
    /// Workspaces as the watch editor needs them. `tools` = the agents
    /// ready to run unattended there (set up in the workspace, or reachable
    /// through the Models settings / a shared sign-in) — the same set a new
    /// session counts as ready. The editor offers every agent and warns
    /// about the others.
    func watchWorkspaceChoices() -> [WatchWorkspaceChoice] {
        profiles.map { p in
            let ready = p.agentsReadyToStart(ModelSettingsStore.shared.effective(for: p),
                                             subscribed: subscribedProviders(for: p))
            let tools = Profile.Tool.allCases.filter { ready.contains($0) }
            return WatchWorkspaceChoice(
                id: p.id, name: p.name, tools: tools,
                defaultTool: WatchWorkspaceChoice.defaultTool(primary: p.tool, ready: tools),
                hasGitHubToken: p.hasGitHubCredential,
                askBeforeUseLabels: p.askBeforeUseCredentialLabels)
        }
    }

    func saveWatch(_ w: WatchedRepo, scanNow: Bool) {
        let saved = repoWatchEngine.saveWatch(w)
        if scanNow { repoWatchEngine.scanNow(saved.id) }
    }

    /// The workspace's github.com token.
    func githubToken(profileID: UUID) -> String? {
        profile(for: profileID)?.gitHTTPSCredentials.first(where: { cred in
            guard cred.isUsable else { return false }
            let h = cred.host.lowercased()
            return h == "github.com" || h.hasSuffix(".github.com")
        })?.token
    }

    func fetchGitHubRepos(profileID: UUID) async throws -> [String] {
        guard let token = githubToken(profileID: profileID), !token.isEmpty else { return [] }
        return try await GitHubPRPoller.fetchRepos(token: token)
    }

    /// A fix task's click target: its review once there's something to
    /// review, otherwise the task board.
    func openFixTask(_ taskID: UUID) {
        guard let task = codingTaskStore.task(taskID) else { return }
        if task.stage == .testing || (task.stage == .done && task.branch != nil) {
            taskReviewWindows.open(taskID: taskID)
        } else {
            ensureUnifiedWindow().showTaskBoard()
        }
    }

    /// Rooms whose Switchboard can take a finding.
    func switchboardRoomChoices() -> [FindingRouting.Room] {
        agentRoomStore.rooms.filter { $0.archivedAt == nil }
            .map { FindingRouting.Room(id: $0.id, name: $0.name, colorHex: $0.colorHex) }
    }

    /// "Ask the Switchboard": the global Switchboard (room nil) or a room's
    /// proposes who fixes the finding. Shows that Switchboard when `show`.
    @discardableResult
    func routeFindingToSwitchboard(_ findingID: UUID, room roomID: UUID?, show: Bool = true) -> Bool {
        guard let f = findingStore.finding(findingID) else { return false }
        let room = roomID.flatMap { agentRoomStore.room($0) }
        let brief = RepoWatchPrompts.fixTask(f)
        let store = findingStore
        let before = f.status
        guard let sid = switchboardEngine.routeFinding(
            id: f.id, severity: f.severity.rawValue, repo: f.repo,
            brief: "## \(brief.title)\n\nFinding id: \(f.id.uuidString)\n\n\(brief.details)",
            preferredWorkspace: f.profileID, room: room,
            failed: { why in
                // The note said "Sent to the Switchboard": say it didn't get there.
                store.mutate(findingID) {
                    if before == .new, $0.status == .triaged { $0.status = .new }
                    $0.statusNote = String(format: NSLocalizedString("Couldn't hand it to the Switchboard: %@",
                                                                     comment: "finding status note"), why)
                }
            }) else { return false }
        findingStore.mutate(findingID) {
            if $0.status == .new { $0.status = .triaged }
            $0.statusNote = room.map {
                String(format: NSLocalizedString("Sent to the “%@” room's Switchboard to find who fixes it",
                                                 comment: "finding status note"), $0.name)
            } ?? NSLocalizedString("Sent to the Switchboard to find who fixes it", comment: "finding status note")
        }
        if show {
            let w = ensureUnifiedWindow()
            if let room { w.showRoom(room.id) } else { w.selectSession(sid) }
        }
        return true
    }

    /// The sessions a finding can be handed to directly ("Ask @foo").
    func findingSessionChoices() -> [PeerMention] {
        PeerMention.candidates(allSessionRecords.filter { !$0.isSwitchboard }, excluding: nil,
                               workspace: { [weak self] pid in
            self?.profile(for: pid)?.name ?? self?.attachedMachines[pid]?.name ?? ""
        })
    }

    /// "Ask @foo to fix it": hand the finding to that session. Shows it
    /// when `show`. Returns why it didn't get there (nil = staged and on
    /// its way; a later typing failure rewrites the finding's note).
    func routeFindingToSession(_ findingID: UUID, session sessionID: UUID, show: Bool = true) async -> String? {
        guard let f = findingStore.finding(findingID),
              let s = allSessionRecords.first(where: { $0.id == sessionID && !$0.isDeleted }) else {
            return NSLocalizedString("that session is gone", comment: "finding → session failure")
        }
        let brief = RepoWatchPrompts.fixTask(f)
        let engine = switchboardEngine
        let name = s.nickname.map { "@" + $0 } ?? "“\(s.title)”"
        let failure = await findingStore.handOver(findingID, to: name, stage: {
            try await engine.stageFinding(
                id: f.id, severity: f.severity.rawValue, repo: f.repo,
                brief: "## \(brief.title)\n\nFinding id: \(f.id.uuidString)\n\n\(brief.details)", to: s)
        }, deliver: { line in
            try await engine.deliverFinding(line, findingID: findingID, to: s)
        }, why: { error in
            BACDebug.log("switchboard", "finding \(findingID) → session \(sessionID) failed — \(error)")
            if case SwitchboardEngine.ActError.refused(let r) = error { return r }
            return error.localizedDescription
        })
        if failure == nil, show { ensureUnifiedWindow().selectSession(sessionID) }
        return failure
    }

    /// Bring up the hub — on a finding when given one.
    func showAutomationHub(finding: UUID?) {
        let w = ensureUnifiedWindow()
        w.showAutomationBoard()
        w.automationHub.showFinding(finding)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Control-socket routes

    /// `/watches…` and `/findings…` on the control socket — the fat client's
    /// write path for the hub, and the debug hooks. Returns the response
    /// body; "error" set = failure.
    ///
    ///   POST   /watches                    upsert (body: a WatchedRepo doc)
    ///   POST   /watches/{id}/scan          scheduled review now (its scope)
    ///   POST   /watches/{id}/baseline      one-off full-repository review
    ///   POST   /watches/{id}/toggle        pause / resume
    ///   DELETE /watches/{id}               stop watching (findings removed)
    ///   POST   /findings/{id}/fix          start a fix task
    ///   POST   /findings/{id}/status       {"status": …, "note": …}
    ///   POST   /findings/{id}/duplicate    {"of": id}
    ///   POST   /findings/{id}/switchboard  {"room": id?} — ask a Switchboard
    ///   POST   /findings/{id}/session      {"session": id} — ask that session
    ///   DELETE /findings/{id}
    ///   POST   /findings/report            {"profileID", "repo", "branch"?,
    ///                                       "commit"?, "findings": [...]} —
    ///                                       what the MCP tool does (debug)
    func watchesCommand(method: String, path: String, body: [String: Any]) async -> [String: Any] {
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let root = parts.first else { return ["error": "not found"] }
        let id = parts.count > 1 ? UUID(uuidString: parts[1]) : nil
        let action = parts.count > 2 ? parts[2] : ""
        switch (root, method, action) {
        case ("watches", "POST", "") where parts.count == 1:
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                return ["error": "invalid body"]
            }
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            guard let w = try? d.decode(WatchedRepo.self, from: data),
                  GitHubPRPoller.isValidRepoSlug(w.repo),
                  profile(for: w.profileID) != nil else {
                return ["error": "invalid watch"]
            }
            let saved = repoWatchEngine.saveWatch(w)
            if (body["scanNow"] as? Bool) == true { repoWatchEngine.scanNow(saved.id) }
            return ["ok": true, "id": saved.id.uuidString]
        case ("watches", _, _):
            guard let id, findingStore.watch(id) != nil else { return ["error": "unknown watch"] }
            switch (method, action) {
            case ("POST", "scan"):   repoWatchEngine.scanNow(id)
            case ("POST", "baseline"): repoWatchEngine.scanNow(id, baseline: true)
            case ("POST", "toggle"): repoWatchEngine.toggleWatch(id)
            case ("DELETE", ""):     repoWatchEngine.removeWatch(id, removeFindings: true)
            default: return ["error": "not found"]
            }
            return ["ok": true]
        case ("findings", "POST", _) where parts.count == 2 && parts[1] == "report":
            guard let pidStr = body["profileID"] as? String, let pid = UUID(uuidString: pidStr),
                  profile(for: pid) != nil else { return ["error": "profileID required"] }
            let reports = ((body["findings"] as? [[String: Any]]) ?? []).compactMap(FindingReport.parse)
            guard !reports.isEmpty else { return ["error": "findings required"] }
            switch await repoWatchEngine.report(
                reports, profileID: pid, branch: body["branch"] as? String,
                repo: body["repo"] as? String, commit: body["commit"] as? String) {
            case .failure: return ["error": "repo required (owner/name)"]
            case .success(let out):
                return ["ok": true,
                        "created": out.created.map(\.id.uuidString),
                        "updated": out.updated.map(\.id.uuidString),
                        "reopened": out.reopened.map(\.id.uuidString)]
            }
        case ("findings", _, _):
            guard let id, findingStore.finding(id) != nil else { return ["error": "unknown finding"] }
            switch (method, action) {
            case ("POST", "fix"):
                guard let tid = repoWatchEngine.fix(id) else { return ["error": "couldn't start the fix"] }
                return ["ok": true, "taskID": tid.uuidString]
            case ("POST", "status"):
                guard let raw = body["status"] as? String,
                      let status = RepoFinding.Status(rawValue: raw) else { return ["error": "status?"] }
                findingStore.setStatus(id, status, note: body["note"] as? String)
            case ("POST", "switchboard"):
                let room = (body["room"] as? String).flatMap(UUID.init(uuidString:))
                guard routeFindingToSwitchboard(id, room: room, show: false) else {
                    return ["error": "no Switchboard could be started"]
                }
            case ("POST", "session"):
                guard let sid = (body["session"] as? String).flatMap(UUID.init(uuidString:)) else {
                    return ["error": "unknown session"]
                }
                if let why = await routeFindingToSession(id, session: sid, show: false) {
                    return ["error": why]
                }
            case ("POST", "duplicate"):
                guard let of = (body["of"] as? String).flatMap(UUID.init(uuidString:)) else {
                    return ["error": "of?"]
                }
                findingStore.markDuplicate(id, of: of)
            case ("DELETE", ""):
                findingStore.removeFinding(id)
            default:
                return ["error": "not found"]
            }
            return ["ok": true]
        default:
            return ["error": "not found"]
        }
    }
}
#endif
