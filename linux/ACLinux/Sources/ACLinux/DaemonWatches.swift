import Foundation

/// The repository watches and their findings, on the shared RepoWatchEngine
/// (macOS: RepoWatchWiring.swift, the app delegate's glue). Same routes,
/// same JSON: the fat client's hub writes through them and mirrors /state's
/// `watches` / `findings`.

/// The engine's host: the daemon's stores and engines (macOS: the app
/// delegate). Made once every engine exists (startSessionEngine); the engine
/// holds it weakly, SessionStores keeps it.
// @port-skip linux-only: the daemon's RepoWatchHost (macOS: ACAppDelegate)
@MainActor
final class LinuxRepoWatchHost: RepoWatchHost {
    let scheduledAutomationStore: ScheduledAutomationStore
    let scheduledAutomationEngine: ScheduledAutomationEngine
    let codingTaskStore: CodingTaskStore
    let codingTaskEngine: CodingTaskEngine
    let taskDispatcher: TaskDispatcher
    let delegationEngine: DelegationEngine
    private let host: LinuxSessionHost

    // @port-skip linux-only: daemon wiring
    init(stores: SessionStores, automations: ScheduledAutomationEngine, tasks: CodingTaskEngine,
         dispatcher: TaskDispatcher, delegations: DelegationEngine, host: LinuxSessionHost) {
        scheduledAutomationStore = stores.automations
        scheduledAutomationEngine = automations
        codingTaskStore = stores.codingTasks
        codingTaskEngine = tasks
        taskDispatcher = dispatcher
        delegationEngine = delegations
        self.host = host
    }

    // @port-skip linux-only: forwards to the session host
    func profile(for id: Profile.ID) -> Profile? { host.profile(for: id) }

    // @port-skip linux-only: forwards to SessionStores.saveAutomation
    func saveAutomation(_ automation: ScheduledAutomation) { SessionStores.shared?.saveAutomation(automation) }

    /// The workspace's github.com token.
    // @port ACAppDelegate.githubToken(profileID: UUID) h=667b6014a591be75 @32c80445
    func githubToken(profileID: UUID) -> String? {
        profile(for: profileID)?.gitHTTPSCredentials.first(where: { cred in
            guard cred.isUsable else { return false }
            let h = cred.host.lowercased()
            return h == "github.com" || h.hasSuffix(".github.com")
        })?.token
    }
}

/// The watches' notices: a server has no notification center, so they go
/// to the daemon log; the client's hub shows the findings themselves.
// @port-skip linux-only: RepoWatchNotifier's stand-in (macOS: UNUserNotificationCenter)
@MainActor
final class RepoWatchNotifier {
    static let shared = RepoWatchNotifier()

    // partial: logged (a Linux server has no notification center)
    // @port RepoWatchNotifier.notifyScanFinished(watch: WatchedRepo, run: AutomationRunRecord, newFindings: [RepoFinding], reported: Int) h=c1f3f5d804978898 @1bdb47dc
    func notifyScanFinished(watch: WatchedRepo, run: AutomationRunRecord,
                            newFindings: [RepoFinding], reported: Int) {
        guard !newFindings.isEmpty else { return }
        let worst = newFindings.sortedForTriage().first
        FileHandle.standardError.write(Data(
            "[watch] \(newFindings.count) new finding(s) in \(watch.repo)\(worst.map { " — \($0.severity.rawValue): \($0.title)" } ?? "")\n".utf8))
    }

    // partial: logged (a Linux server has no notification center)
    // @port RepoWatchNotifier.notifyCritical(_: RepoFinding) h=e7021cdfe5cb3df0 @1bdb47dc
    func notifyCritical(_ f: RepoFinding) {
        FileHandle.standardError.write(Data(
            "[watch] critical finding in \(f.repo): \(f.title)\(f.location.isEmpty ? "" : " — " + f.location)\n".utf8))
    }
}

extension SessionStores {
    /// The watch engine over the daemon's engines, its automation hooks
    /// wired (macOS: the app delegate's lazy repoWatchEngine, started at
    /// launch).
    // @port ACAppDelegate.applicationDidFinishLaunching(_: Notification) / scheduledAutomationEngine.onRunCompleted h=928a01bb8e1dc065 @d3ebbda2
    // @port ACAppDelegate.applicationDidFinishLaunching(_: Notification) / scheduledAutomationEngine.prepareWatchRun h=ef6f8034340f1e1b @d3ebbda2
    func startWatches(host: LinuxSessionHost) {
        guard let automations = automationEngine, let tasks = codingTaskEngine,
              let dispatcher = taskDispatcher, let delegations = delegationEngine else { return }
        let watchHost = LinuxRepoWatchHost(stores: self, automations: automations, tasks: tasks,
                                           dispatcher: dispatcher, delegations: delegations, host: host)
        self.watchHost = watchHost
        let engine = RepoWatchEngine(store: findings, delegate: watchHost)
        watchEngine = engine
        // Follow fix tasks, count each finished scan's findings; a watch's
        // scheduled review decides at fire time what it covers.
        automations.onRunCompleted = { run in SessionStores.shared?.watchEngine?.runCompleted(run) }
        automations.prepareWatchRun = { a, baseline in
            await SessionStores.shared?.watchEngine?.prepareRun(a, forceBaseline: baseline)
        }
        engine.start()
    }

    /// `/watches…` and `/findings…`: the fat client's write path for the
    /// hub (macOS: the app delegate's, same paths and bodies). Returns the
    /// response body; "error" set = failure.
    // @port ACAppDelegate.watchesCommand(method: String, path: String, body: [String:Any]) h=43b69ba1786f52f5 @32c80445
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onWatchesCommand h=102422d4d1e202d5 @d3ebbda2
    func watchesCommand(method: String, path: String, body: [String: Any]) async -> [String: Any] {
        guard let engine = watchEngine, let watchHost else { return ["error": "no watch engine"] }
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
                  watchHost.profile(for: w.profileID) != nil else {
                return ["error": "invalid watch"]
            }
            let saved = engine.saveWatch(w)
            if (body["scanNow"] as? Bool) == true { engine.scanNow(saved.id) }
            return ["ok": true, "id": saved.id.uuidString]
        case ("watches", _, _):
            guard let id, findings.watch(id) != nil else { return ["error": "unknown watch"] }
            switch (method, action) {
            case ("POST", "scan"):   engine.scanNow(id)
            case ("POST", "baseline"): engine.scanNow(id, baseline: true)
            case ("POST", "toggle"): engine.toggleWatch(id)
            case ("DELETE", ""):     engine.removeWatch(id, removeFindings: true)
            default: return ["error": "not found"]
            }
            return ["ok": true]
        case ("findings", "POST", _) where parts.count == 2 && parts[1] == "report":
            guard let pidStr = body["profileID"] as? String, let pid = UUID(uuidString: pidStr),
                  watchHost.profile(for: pid) != nil else { return ["error": "profileID required"] }
            let reports = ((body["findings"] as? [[String: Any]]) ?? []).compactMap(FindingReport.parse)
            guard !reports.isEmpty else { return ["error": "findings required"] }
            switch await engine.report(
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
            guard let id, let finding = findings.finding(id) else { return ["error": "unknown finding"] }
            if method == "POST", ["fix", "switchboard", "session"].contains(action),
               let refusal = finding.handOverRefusal(confirmed: (body["confirmed"] as? Bool) == true) {
                return ["error": refusal, "flagged": true, "warning": finding.screenWarning ?? ""]
            }
            switch (method, action) {
            case ("POST", "fix"):
                guard let tid = engine.fix(id) else { return ["error": "couldn't start the fix"] }
                return ["ok": true, "taskID": tid.uuidString]
            case ("POST", "status"):
                guard let raw = body["status"] as? String,
                      let status = RepoFinding.Status(rawValue: raw) else { return ["error": "status?"] }
                findings.setStatus(id, status, note: body["note"] as? String)
            case ("POST", "switchboard"):
                let room = (body["room"] as? String).flatMap(UUID.init(uuidString:))
                guard routeFindingToSwitchboard(id, room: room, confirmed: true) else {
                    return ["error": "no Switchboard could be started"]
                }
            case ("POST", "session"):
                guard let sid = (body["session"] as? String).flatMap(UUID.init(uuidString:)) else {
                    return ["error": "unknown session"]
                }
                if let why = routeFindingToSession(id, session: sid, confirmed: true) {
                    return ["error": why]
                }
            case ("POST", "duplicate"):
                guard let of = (body["of"] as? String).flatMap(UUID.init(uuidString:)) else {
                    return ["error": "of?"]
                }
                findings.markDuplicate(id, of: of)
            case ("DELETE", ""):
                findings.removeFinding(id)
            default:
                return ["error": "not found"]
            }
            return ["ok": true]
        default:
            return ["error": "not found"]
        }
    }

    /// "Ask @foo to fix it": a backlog task on the board, queued for that
    /// session (RepoWatchEngine.fix(_:by:)). Returns why it didn't get
    /// there (nil = queued). A flagged finding goes only once the user
    /// `confirmed` it.
    /// "Ask the Switchboard": the global Switchboard (room nil) or a room's
    /// proposes who fixes the finding. A flagged finding goes only once the
    /// user `confirmed` it.
    // partial: nothing to show (no window)
    // @port ACAppDelegate.routeFindingToSwitchboard(_: UUID, room: UUID?, show: Bool, confirmed: Bool) h=af93d97118cb37c2 @977cc122
    @discardableResult
    func routeFindingToSwitchboard(_ findingID: UUID, room roomID: UUID?, confirmed: Bool) -> Bool {
        guard let f = findings.finding(findingID), f.handOverRefusal(confirmed: confirmed) == nil,
              let sb = switchboardEngine else { return false }
        let room = roomID.flatMap { rooms.room($0) }
        let brief = RepoWatchPrompts.fixTask(f)
        let store = findings
        let generation = UUID()
        guard sb.routeFinding(
            id: f.id, severity: f.severity.rawValue, repo: f.repo,
            brief: "## \(brief.title)\n\nFinding id: \(f.id.uuidString)\n\n\(brief.details)",
            preferredWorkspace: f.profileID, room: room,
            delivered: { store.handOverDelivered(findingID, generation: generation) },
            failed: { why in
                // The note said "Sent to the Switchboard": say it didn't get
                // there — unless a later hand-over or the user moved it since.
                store.handOverFailed(findingID, generation: generation, note: String(
                    format: NSLocalizedString("Couldn't hand it to the Switchboard: %@",
                                              comment: "finding status note"), why))
            }) != nil else { return false }
        findings.markHandedOver(findingID, note: room.map {
            String(format: NSLocalizedString("Sent to the “%@” room's Switchboard to find who fixes it",
                                             comment: "finding status note"), $0.name)
        } ?? NSLocalizedString("Sent to the Switchboard to find who fixes it", comment: "finding status note"),
            generation: generation)
        return true
    }

    // @port ACAppDelegate.routeFindingToSession(_: UUID, session: UUID, confirmed: Bool) h=c9393fdcd37420d9 @32c80445
    func routeFindingToSession(_ findingID: UUID, session sessionID: UUID, confirmed: Bool) -> String? {
        guard let f = findings.finding(findingID),
              let s = sessions.sessions.first(where: { $0.id == sessionID && !$0.isDeleted }) else {
            return NSLocalizedString("that session is gone", comment: "finding → session failure")
        }
        if let refusal = f.handOverRefusal(confirmed: confirmed) { return refusal }
        guard let tid = watchEngine?.fix(findingID, by: s) else {
            return NSLocalizedString("couldn't put it on the board", comment: "finding → session failure")
        }
        BACDebug.log("watch", "finding \(findingID) → task \(tid) for session \(sessionID)")
        return nil
    }

    /// `POST /automation-sources` {profile, kind, repo?, branch?}: what a
    /// fat client's editor would have fetched with the workspace's token.
    /// {items: […]} (dirs: also `truncated`), or {error, code} (code 401: the
    /// GitHub token was refused).
    // @port ACAppDelegate.automationSources(_: [String:Any]) h=d307a4bd8fc10bd1 @32c80445
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onAutomationSources h=1ff1d0f916522573 @d3ebbda2
    func automationSources(_ body: [String: Any]) async -> [String: Any] {
        guard let pid = (body["profile"] as? String).flatMap(UUID.init(uuidString:)),
              let kind = body["kind"] as? String else { return ["error": "profile and kind required"] }
        guard let watchHost else { return ["error": "no watch engine"] }
        let repo = body["repo"] as? String ?? ""
        let branch = body["branch"] as? String ?? ""
        do {
            switch kind {
            case "repos", "branches", "dirs":
                guard let token = watchHost.githubToken(profileID: pid), !token.isEmpty else {
                    return ["error": NSLocalizedString("This workspace has no github.com token.", comment: "automation editor")]
                }
                if kind == "repos" { return ["items": try await GitHubPRPoller.fetchRepos(token: token)] }
                guard GitHubPRPoller.isValidRepoSlug(repo) else { return ["error": "Bad repository"] }
                if kind == "branches" {
                    return ["items": try await GitHubPRPoller.fetchBranches(repo: repo, token: token)]
                }
                let dirs = try await GitHubPRPoller.fetchDirectories(repo: repo, token: token, branch: branch)
                return ["items": dirs ?? [], "truncated": dirs == nil]
            case "teams", "projects":
                guard let key = watchHost.profile(for: pid)?.linearToken, !key.isEmpty else {
                    return ["error": NSLocalizedString("This workspace has no Linear key.", comment: "automation editor")]
                }
                if kind == "teams" {
                    return ["items": try await LinearPoller.fetchTeams(token: key).map { ["key": $0.key, "name": $0.name] }]
                }
                return ["items": try await LinearPoller.fetchProjects(token: key).map { ["id": $0.id, "name": $0.name] }]
            default:
                return ["error": "Unknown kind"]
            }
        } catch {
            let ns = error as NSError
            return ["error": ns.localizedDescription, "code": ns.domain == "GitHubPoller" ? ns.code : 0]
        }
    }
}
