#if os(macOS)
import AppKit
import Foundation
import UserNotifications

/// Drives the repository watches (RepoWatch.swift): keeps each watch's
/// automations in line with it, takes findings from the MCP, turns findings
/// into fix tasks, follows those tasks, and tells the user when a scan
/// turned something up.
@MainActor
final class RepoWatchEngine {
    let store: FindingStore
    private weak var delegate: ACAppDelegate?
    private var timer: Timer?
    /// Fix tasks started automatically per watch, still running — the
    /// auto-fix cap keys off it.
    static let maxConcurrentAutoFixes = 3

    init(store: FindingStore, delegate: ACAppDelegate?) {
        self.store = store
        self.delegate = delegate
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// Follow the fix tasks.
    func tick() {
        guard let delegate else { return }
        store.syncWithTasks(delegate.codingTaskStore.tasks)
    }

    // MARK: Watches → automations

    /// Save a watch and bring its automations in line: one per scan kind.
    /// The full scan always has one (disabled when its schedule is off) so
    /// "Scan now" works for every watch.
    @discardableResult
    func saveWatch(_ input: WatchedRepo) -> WatchedRepo {
        guard let delegate else { return input }
        var w = input
        // How far the reviews got is the engine's to write: an editor (or a
        // fat client) saving a copy it opened before a review finished must
        // not wind the mark back.
        if let current = store.watch(w.id) { w.reviewedThrough = current.reviewedThrough }
        let autoStore = delegate.scheduledAutomationStore
        for scan in WatchedRepo.Scan.allCases {
            let wanted = scan == .fullScan || w.scans.contains(scan)
            let existingID = w.automationID(for: scan)
            guard wanted else {
                if let id = existingID {
                    autoStore.remove(id)
                    w.automationIDs[scan.rawValue] = nil
                }
                continue
            }
            let desired = Self.automation(for: scan, of: w,
                                          id: existingID ?? UUID(),
                                          createdAt: existingID
                                            .flatMap { autoStore.automation($0)?.createdAt })
            // Only write when something changed: an upsert re-baselines the
            // event trigger's polling.
            if autoStore.automation(desired.id) != desired {
                delegate.saveAutomation(desired)
            }
            w.automationIDs[scan.rawValue] = desired.id
        }
        store.upsertWatch(w)
        // Event scans are refused without the injection screen's model.
        if w.scans.contains(.commits) || w.scans.contains(.pullRequests) {
            PromptInjectionModels.ensureInstalledInBackground(.promptGuard)
        }
        BACDebug.log("watch", "saved watch on \(w.repo) — scans: \(w.scans.map(\.rawValue))")
        return w
    }

    /// The automation behind one scan kind of a watch. Pure.
    nonisolated static func automation(for scan: WatchedRepo.Scan, of w: WatchedRepo,
                                       id: UUID, createdAt: Date?) -> ScheduledAutomation {
        var a = ScheduledAutomation(
            id: id,
            name: "\(w.repoName) · \(w.scanShortName(scan))",
            profileID: w.profileID,
            enabled: w.enabled && w.scans.contains(scan),
            githubRepo: w.repo,
            ignoreBacklog: true,
            tool: w.tool,
            prompt: RepoWatchPrompts.prompt(for: scan, w),
            repoPath: w.repoPath,
            closeWhenDone: true,
            startWorkspaceIfNeeded: true,
            cloneWorkspaceFirst: false,
            watchID: w.id,
            cloneURL: w.cloneURL,
            createdAt: createdAt ?? w.createdAt)
        switch scan {
        case .fullScan:
            a.trigger = .schedule
            a.frequency = .weekly
            a.weekday = min(max(w.fullScanWeekday, 1), 7)
            a.hour = min(max(w.fullScanHour, 0), 23)
            a.minute = 0
            a.missedRunPolicy = .runOnWake
        case .commits:
            a.trigger = .githubCommit
            a.filters.commitBranch = w.commitBranch
        case .pullRequests:
            a.trigger = .githubPullRequest
            a.filters.excludeDrafts = true
        }
        return a
    }

    func removeWatch(_ id: UUID, removeFindings: Bool) {
        guard let w = store.watch(id) else { return }
        for aid in w.automationIDs.values {
            delegate?.scheduledAutomationStore.remove(aid)
        }
        store.removeWatch(id, removeFindings: removeFindings)
    }

    func toggleWatch(_ id: UUID) {
        guard var w = store.watch(id) else { return }
        w.enabled.toggle()
        saveWatch(w)
    }

    /// Fire the scheduled review now — what it covers follows the watch's
    /// scope; `baseline` forces a one-off full-repository review.
    func scanNow(_ id: UUID, baseline: Bool = false) {
        guard var w = store.watch(id) else { return }
        if w.automationID(for: .fullScan) == nil
            || delegate?.scheduledAutomationStore.automation(w.automationID(for: .fullScan)!) == nil {
            w.automationIDs[WatchedRepo.Scan.fullScan.rawValue] = nil
            w = saveWatch(w)
        }
        guard let aid = w.automationID(for: .fullScan) else { return }
        BACDebug.log("watch", "scan now: \(w.repo)\(baseline ? " (baseline)" : "")")
        guard let delegate, let automation = delegate.scheduledAutomationStore.automation(aid) else { return }
        delegate.scheduledAutomationEngine.runNow(automation, forceBaseline: baseline)
    }

    // MARK: Fire-time planning

    /// Plan a watch's scheduled review as it fires: ask GitHub for the
    /// branch tip, decide what the run covers (`ReviewPlan`), and write
    /// the prompt for the watch's agent. A run with nothing new to review
    /// is skipped. nil = not a watch's scheduled review.
    func prepareRun(_ a: ScheduledAutomation, forceBaseline: Bool) async
        -> ScheduledAutomationEngine.WatchRunPreparation? {
        guard let wid = a.watchID, let w = store.watch(wid),
              w.automationID(for: .fullScan) == a.id else { return nil }
        var head: String?
        if let delegate, let token = delegate.githubToken(profileID: w.profileID), !token.isEmpty {
            do {
                head = try await GitHubPRPoller.fetchHeadSHA(repo: w.repo, token: token,
                                                             branch: w.reviewBranchKey)
            } catch {
                BACDebug.log("watch", "\(w.repo): couldn't read the branch tip — \(error.localizedDescription); the agent resolves it")
            }
        }
        // The watch may have been edited while GitHub answered.
        let current = store.watch(wid) ?? w
        return Self.preparation(for: current, automation: a, forceBaseline: forceBaseline, head: head)
    }

    /// The pure half of `prepareRun`.
    nonisolated static func preparation(for w: WatchedRepo, automation a: ScheduledAutomation,
                                        forceBaseline: Bool, head: String?)
        -> ScheduledAutomationEngine.WatchRunPreparation {
        let plan = ReviewPlan.make(for: w, forceBaseline: forceBaseline, head: head)
        let info = AutomationRunRecord.ReviewInfo(
            scope: plan.scope.rawValue, branch: w.reviewBranchKey,
            base: plan.base, head: plan.head)
        let remoteRef = w.reviewBranchKey.isEmpty ? "origin/HEAD" : "origin/\(w.reviewBranchKey)"
        var prep = ScheduledAutomationEngine.WatchRunPreparation(
            prompt: RepoWatchPrompts.scheduledReview(w, plan: plan, tool: a.tool),
            detail: plan.runDetail,
            base: plan.head ?? remoteRef,
            review: info)
        if case .upToDate = plan { prep.skipReason = plan.runDetail }
        return prep
    }

    /// Runs of the watch's automations, newest first.
    func runs(for w: WatchedRepo) -> [AutomationRunRecord] {
        guard let autoStore = delegate?.scheduledAutomationStore else { return [] }
        let ids = Set(w.automationIDs.values)
        return autoStore.runs.filter { ids.contains($0.automationID) }
    }

    // MARK: Reporting (from the MCP)

    /// Who is reporting: the run (and so the watch) behind the agent's
    /// worktree branch, when it's a watch scan.
    struct Binding {
        var run: AutomationRunRecord?
        var watch: WatchedRepo?
    }

    func binding(profileID: UUID, branch: String?) -> Binding {
        guard let delegate, let branch, branch.hasPrefix("wt/") else { return Binding() }
        let slugPart = String(branch.dropFirst(3))
        let autoStore = delegate.scheduledAutomationStore
        guard let run = autoStore.runs.first(where: { run in
            guard run.outcome == .launched, let slug = run.branchSlug else { return false }
            return slugPart == slug || (slugPart.hasPrefix(slug + "-")
                && Int(slugPart.dropFirst(slug.count + 1)) != nil)
        }), let automation = autoStore.automation(run.automationID),
              (run.runProfileID ?? automation.profileID) == profileID
        else { return Binding() }
        let watch = automation.watchID.flatMap { store.watch($0) }
        return Binding(run: run, watch: watch)
    }

    struct ReportOutcome {
        var created: [RepoFinding] = []
        var updated: [RepoFinding] = []
        var reopened: [RepoFinding] = []
        var rejected: [String] = []
    }

    /// Fold reports into the store. `repo` is required when the session
    /// isn't a watch scan; it must then be a repo this workspace watches or
    /// a well-formed owner/name.
    func report(_ reports: [FindingReport], profileID: UUID, branch: String?,
                repo: String?, commit: String?) async -> Result<ReportOutcome, ReportError> {
        let b = binding(profileID: profileID, branch: branch)
        let watch = b.watch ?? repo.flatMap { r in
            store.watches.first { $0.profileID == profileID
                && $0.repo.caseInsensitiveCompare(r) == .orderedSame }
        }
        guard let targetRepo = watch?.repo ?? repo.flatMap({
            GitHubPRPoller.isValidRepoSlug($0) ? $0 : nil
        }) else {
            return .failure(.noRepo)
        }
        var out = ReportOutcome()
        for r in reports {
            let warning = await Self.screen(r)
            let res = store.ingest(r, watchID: watch?.id, profileID: profileID,
                                   repo: targetRepo, runID: b.run?.id,
                                   commit: commit, screenWarning: warning)
            if res.isNew { out.created.append(res.finding) }
            else if res.reopened { out.reopened.append(res.finding) }
            else { out.updated.append(res.finding) }
        }
        BACDebug.log("watch", "\(targetRepo): \(out.created.count) new, \(out.updated.count) known, \(out.reopened.count) reopened")
        // A paused watch reports but never starts work on its own.
        if let watch, watch.enabled { autoFix(watch, candidates: out.created + out.reopened) }
        for f in out.created + out.reopened where f.severity == .critical {
            RepoWatchNotifier.shared.notifyCritical(f)
        }
        return .success(out)
    }

    enum ReportError: Error {
        case noRepo
    }

    /// The prompt-injection screen over a finding's text. The finding came
    /// out of an agent reading repository content — the text will be put in
    /// front of a fix agent, so a hit is recorded on the finding (and "Fix"
    /// asks first). Deterministic scanners always; PromptGuard when present.
    nonisolated static func screen(_ r: FindingReport) async -> String? {
        let text = [r.title, r.summary, r.evidence ?? "", r.recommendation ?? ""]
            .joined(separator: "\n")
        let hits = RulesFileScanner.scanHiddenUnicode(text)
            + RulesFileScanner.scanInstructionContent(text)
        if let hit = hits.first { return "\(hit.signal) — \(hit.detail)" }
        if PromptInjectionModels.isInstalled(.promptGuard),
           await PromptInjectionClassifier.shared.detect(spans: [(id: nil, content: text)]) != nil {
            return NSLocalizedString("PromptGuard flagged the text as prompt injection",
                                     comment: "finding screen warning")
        }
        return nil
    }

    /// An agent says a finding is gone. Only open findings of this
    /// workspace, only to Fixed.
    func resolve(_ id: UUID, profileID: UUID, reason: String) -> Bool {
        guard let f = store.finding(id), f.profileID == profileID,
              f.status.isOpen, f.taskID == nil else { return false }
        store.setStatus(id, .fixed, note: String(
            format: NSLocalizedString("Resolved by a scan: %@", comment: "finding status note"),
            reason))
        return true
    }

    // MARK: Fixes

    /// Start a fix: a coding task seeded with the finding, launched at once.
    /// Returns the task id.
    @discardableResult
    func fix(_ findingID: UUID) -> UUID? {
        guard let delegate, let f = store.finding(findingID) else { return nil }
        if let tid = f.taskID, let existing = delegate.codingTaskStore.task(tid) {
            // A fix whose start failed (still in Backlog): try it again.
            if existing.stage == .backlog {
                store.mutate(findingID) { $0.status = .inProgress }
                delegate.codingTaskEngine.start(tid)
            }
            return tid
        }
        let task = fixTask(f, delegate: delegate)
        delegate.codingTaskStore.upsert(task)
        store.mutate(findingID) {
            $0.taskID = task.id
            $0.status = .inProgress
        }
        delegate.codingTaskEngine.start(task.id)
        BACDebug.log("watch", "fix started for “\(f.title)” → task \(task.id)")
        return task.id
    }

    /// "Ask @foo to fix it": the fix as a backlog task queued for that
    /// session — on the board like any task (its progress, review and
    /// landing), picked up as soon as the session has no board task in
    /// progress. A finding whose task hasn't started yet is re-queued for
    /// it; one already under way stays where it is. Returns the task id.
    @discardableResult
    func fix(_ findingID: UUID, by session: AgentSession) -> UUID? {
        guard let delegate, let f = store.finding(findingID) else { return nil }
        let assignee = TaskAssignment(kind: .session, id: session.id,
                                      label: delegate.delegationEngine.label(session))
        if let tid = f.taskID, let existing = delegate.codingTaskStore.task(tid), existing.stage != .done {
            guard existing.stage == .backlog || existing.stage == .planning else { return tid }
            delegate.taskDispatcher.assign(tid, to: assignee)
            store.mutate(findingID) { $0.status = .inProgress }
            return tid
        }
        var task = fixTask(f, delegate: delegate)
        task.assignment = assignee
        delegate.codingTaskStore.upsert(task)
        store.mutate(findingID) {
            $0.taskID = task.id
            $0.status = .inProgress
        }
        delegate.taskDispatcher.assign(task.id, to: assignee)
        BACDebug.log("watch", "fix of “\(f.title)” queued for \(assignee.label) → task \(task.id)")
        return task.id
    }

    /// The coding task that fixes `f`, in Backlog.
    private func fixTask(_ f: RepoFinding, delegate: ACAppDelegate) -> CodingTask {
        let watch = f.watchID.flatMap { store.watch($0) }
        let brief = RepoWatchPrompts.fixTask(f)
        return CodingTask(
            title: brief.title,
            details: brief.details,
            profileID: watch?.profileID ?? f.profileID,
            repoPath: watch?.repoPath ?? WatchedRepo.defaultRepoPath(for: f.repo),
            tool: watch?.tool ?? delegate.profile(for: f.profileID)?.tool ?? .claude,
            stage: .backlog,
            cloneURL: "https://github.com/\(f.repo).git")
    }

    private func autoFix(_ w: WatchedRepo, candidates: [RepoFinding]) {
        guard let threshold = w.autoFixMinSeverity, let delegate else { return }
        let running = store.findings(forWatch: w.id).filter {
            guard let tid = $0.taskID, let t = delegate.codingTaskStore.task(tid) else { return false }
            return t.stage != .done
        }.count
        var budget = Self.maxConcurrentAutoFixes - running
        for f in candidates.sortedForTriage()
        where budget > 0 && f.severity.rank <= threshold.rank
            && f.screenWarning == nil && f.taskID == nil {
            fix(f.id)
            budget -= 1
        }
    }

    // MARK: Scan completion

    /// findings_done: the scanning agent says it's finished. Records the
    /// commit it reviewed when the run didn't know it yet, and completes
    /// the run — the one done signal every agent can give (Codex, Grok and
    /// omp have no completion hook). false = not a watch scan's session.
    func scanDone(profileID: UUID, branch: String?, commit: String?, summary: String) -> Bool {
        let b = binding(profileID: profileID, branch: branch)
        guard let delegate, let run = b.run, b.watch != nil else { return false }
        if let c = commit?.trimmingCharacters(in: .whitespaces), RepoWatchPrompts.isSHA(c) {
            delegate.scheduledAutomationStore.setReviewHead(run.id, sha: c.lowercased())
        }
        BACDebug.log("watch", "scan done (agent): \(branch ?? "?") — \(summary.prefix(200))")
        return delegate.scheduledAutomationEngine.runDeclaredDone(profileID: profileID,
                                                                 worktreeBranch: branch)
    }

    func runCompleted(_ run: AutomationRunRecord) {
        guard let delegate,
              let automation = delegate.scheduledAutomationStore.automation(run.automationID),
              let wid = automation.watchID, let w = store.watch(wid) else { return }
        // A finished scheduled review moves the branch's mark to what it
        // covered — the next incremental review starts after it.
        if let review = run.review, let head = run.review?.head,
           store.advanceReviewMark(watchID: wid, branch: review.branch, sha: head, at: run.firedAt) {
            BACDebug.log("watch", "\(w.repo): reviewed through \(head.prefix(7))")
        }
        let fresh = store.findings(firstReportedBy: run.id)
        let seen = store.findings(forWatch: wid).filter { $0.runIDs.contains(run.id) }
        BACDebug.log("watch", "scan done on \(w.repo): \(fresh.count) new, \(seen.count) reported")
        RepoWatchNotifier.shared.notifyScanFinished(watch: w, run: run,
                                                    newFindings: fresh,
                                                    reported: seen.count)
    }
}

// MARK: - Notifications

/// macOS notifications for the watches: a scan that found something, and
/// every new critical finding. Clicking one opens the Automations hub.
@MainActor
final class RepoWatchNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RepoWatchNotifier()

    /// Where a click lands: the hub, on a finding when there is one.
    var onOpen: ((UUID?) -> Void)?

    private var authorized: Bool?
    private var installed = false

    /// Notifications need a real bundle (not the raw build binary).
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func install() {
        guard available, !installed else { return }
        installed = true
        UNUserNotificationCenter.current().delegate = self
    }

    private func post(title: String, body: String, findingID: UUID?) {
        guard available else { return }
        install()
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let findingID { content.userInfo = ["findingID": findingID.uuidString] }
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        Task {
            if self.authorized == nil {
                self.authorized = (try? await center.requestAuthorization(
                    options: [.alert, .sound, .badge])) ?? false
            }
            guard self.authorized == true else { return }
            try? await center.add(req)
        }
    }

    func notifyScanFinished(watch: WatchedRepo, run: AutomationRunRecord,
                            newFindings: [RepoFinding], reported: Int) {
        guard !newFindings.isEmpty else { return }
        let worst = newFindings.sortedForTriage().first
        let title = String(format: NSLocalizedString("%1$d new finding(s) in %2$@",
                                                     comment: "scan notification title"),
                           newFindings.count, watch.repo)
        var body = worst.map { "\($0.severity.displayName): \($0.title)" } ?? ""
        if newFindings.count > 1 {
            body += "\n" + String(format: NSLocalizedString("…and %d more", comment: "scan notification"),
                                  newFindings.count - 1)
        }
        post(title: title, body: body, findingID: worst?.id)
    }

    func notifyCritical(_ f: RepoFinding) {
        post(title: String(format: NSLocalizedString("Critical finding in %@", comment: "notification title"),
                           f.repo),
             body: f.title + (f.location.isEmpty ? "" : " — " + f.location),
             findingID: f.id)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["findingID"] as? String)
            .flatMap(UUID.init(uuidString:))
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            self.onOpen?(id)
        }
    }
}
#endif
