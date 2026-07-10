import Foundation
import Observation

// MARK: - Model

/// One scheduled automation: a recurring, unattended agent run in a workspace.
///
/// Fires on the host clock. Each run creates a fresh git worktree in the
/// workspace's repo and launches the chosen agent there with the prompt — the
/// same guest path as the GUI's "New worktree…" (worktree-create), so runs
/// land as ordinary worktree tabs: attachable, mergeable, visible in the
/// sidebar with the usual agent-status dot.
///
/// Named "scheduled" to stay clear of the HTTP remote-control surface, which
/// already owns the bare `Automation*` prefix (AutomationServer, the
/// `automation.*` defaults keys).
struct ScheduledAutomation: Codable, Identifiable, Equatable, Sendable {
    /// What starts a run. Schedules fire on the host clock; the GitHub
    /// triggers poll the repo from the host with the workspace's github.com
    /// token (never a webhook — no inbound network surface).
    enum TriggerKind: String, Codable, CaseIterable, Sendable {
        case schedule
        case githubPullRequest
        case githubIssue
    }

    enum Frequency: String, Codable, CaseIterable, Sendable {
        case daily
        case weekdays
        case weekly

        var displayName: String {
            switch self {
            case .daily:    return NSLocalizedString("Every day", comment: "automation frequency")
            case .weekdays: return NSLocalizedString("Weekdays", comment: "automation frequency")
            case .weekly:   return NSLocalizedString("Weekly", comment: "automation frequency")
            }
        }
    }

    /// What to do with a fire time that passed while the Mac was asleep or
    /// the app wasn't running. Skip is the default — a 9:00 standup prompt
    /// run at 15:40 is rarely what the user meant. Skipped fires still get a
    /// run record, so they're visible rather than silently missing.
    enum MissedRunPolicy: String, Codable, CaseIterable, Sendable {
        case skip
        case runOnWake

        var displayName: String {
            switch self {
            case .skip:      return NSLocalizedString("Skip the run", comment: "missed-run policy")
            case .runOnWake: return NSLocalizedString("Run when the Mac wakes", comment: "missed-run policy")
            }
        }
    }

    var id: UUID
    var name: String
    /// Owning workspace: the run executes in this profile's VM, under its
    /// credentials, guardrails, and supply-chain policy.
    var profileID: UUID
    var enabled: Bool

    var trigger: TriggerKind
    /// "owner/repo" watched by the GitHub PR trigger. Ignored for schedules.
    var githubRepo: String

    var frequency: Frequency
    /// Calendar weekday (1 = Sunday … 7 = Saturday). Only used for `.weekly`.
    var weekday: Int
    var hour: Int
    var minute: Int
    var missedRunPolicy: MissedRunPolicy

    /// Agent launched in the worktree tab. Must be one the workspace has
    /// configured (primary or additional); the editor only offers those.
    var tool: Profile.Tool
    /// The agent's initial message.
    var prompt: String
    /// Guest path of the repo to worktree off. "~" is the guest home
    /// (/home/ubuntu); relative paths are taken from there.
    var repoPath: String

    var createdAt: Date

    init(id: UUID = UUID(),
         name: String = "",
         profileID: UUID,
         enabled: Bool = true,
         trigger: TriggerKind = .schedule,
         githubRepo: String = "",
         frequency: Frequency = .weekdays,
         weekday: Int = 2,
         hour: Int = 9,
         minute: Int = 0,
         missedRunPolicy: MissedRunPolicy = .skip,
         tool: Profile.Tool = .claude,
         prompt: String = "",
         repoPath: String = "~",
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.enabled = enabled
        self.trigger = trigger
        self.githubRepo = githubRepo
        self.frequency = frequency
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
        self.missedRunPolicy = missedRunPolicy
        self.tool = tool
        self.prompt = prompt
        self.repoPath = repoPath
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, profileID, enabled, trigger, githubRepo
        case frequency, weekday, hour, minute
        case missedRunPolicy, tool, prompt, repoPath, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        name            = try c.decode(String.self, forKey: .name)
        profileID       = try c.decode(UUID.self, forKey: .profileID)
        enabled         = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trigger         = try c.decodeIfPresent(TriggerKind.self, forKey: .trigger) ?? .schedule
        githubRepo      = try c.decodeIfPresent(String.self, forKey: .githubRepo) ?? ""
        frequency       = try c.decodeIfPresent(Frequency.self, forKey: .frequency) ?? .weekdays
        weekday         = try c.decodeIfPresent(Int.self, forKey: .weekday) ?? 2
        hour            = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        minute          = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        missedRunPolicy = try c.decodeIfPresent(MissedRunPolicy.self, forKey: .missedRunPolicy) ?? .skip
        tool            = try c.decodeIfPresent(Profile.Tool.self, forKey: .tool) ?? .claude
        prompt          = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        repoPath        = try c.decodeIfPresent(String.self, forKey: .repoPath) ?? "~"
        createdAt       = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Outcome of one fire. Live agent progress (working / done / needs-input)
/// stays on the worktree tab's status dot — a record only says whether the
/// run got off the ground.
struct AutomationRunRecord: Codable, Identifiable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case launched   // worktree-create queued to the guest
        case skipped    // fire time passed while asleep/quit, policy = skip
        case failed     // couldn't launch (workspace gone, boot timeout, …)
    }

    var id: UUID
    var automationID: UUID
    var firedAt: Date
    var outcome: Outcome
    /// Branch slug for launched runs; a human-readable reason otherwise.
    var detail: String

    init(id: UUID = UUID(), automationID: UUID, firedAt: Date,
         outcome: Outcome, detail: String) {
        self.id = id
        self.automationID = automationID
        self.firedAt = firedAt
        self.outcome = outcome
        self.detail = detail
    }
}

// MARK: - Schedule math

/// Pure next-fire computation, separated from the engine for testability.
enum AutomationSchedule {
    /// The next fire strictly after `date` for the automation's recurrence.
    static func nextFire(for a: ScheduledAutomation, after date: Date,
                         calendar: Calendar = .current) -> Date {
        var comps = DateComponents()
        comps.hour = a.hour
        comps.minute = a.minute
        comps.second = 0
        if a.frequency == .weekly {
            comps.weekday = min(max(a.weekday, 1), 7)
        }
        let fallback = date.addingTimeInterval(24 * 3600)
        var candidate = calendar.nextDate(after: date, matching: comps,
                                          matchingPolicy: .nextTime) ?? fallback
        if a.frequency == .weekdays {
            var hops = 0
            while calendar.isDateInWeekend(candidate), hops < 8 {
                candidate = calendar.nextDate(after: candidate, matching: comps,
                                              matchingPolicy: .nextTime)
                    ?? candidate.addingTimeInterval(24 * 3600)
                hops += 1
            }
        }
        return candidate
    }
}

// MARK: - Store

/// Reads / writes automations + run history as one JSON blob at
/// ~/Library/Application Support/BromureAC/automations.json (next to the
/// profiles dir, same conventions as ProfileStore: iso8601 dates, atomic
/// writes, excluded from backup). Run history is capped so the file can't
/// grow unbounded.
@MainActor
@Observable
final class ScheduledAutomationStore {
    private(set) var automations: [ScheduledAutomation] = []
    private(set) var runs: [AutomationRunRecord] = []
    /// Next planned fire per automation id. Persisted so a relaunch can tell
    /// "missed while the app was quit" (fire time in the past) from "not due
    /// yet" — without this, every relaunch would either double-fire or
    /// silently forget.
    private var nextFires: [String: Date] = [:]
    /// GitHub PR polling high-water marks per automation id. Persisted so a
    /// relaunch doesn't re-fire for PRs already handled.
    private var pollStates: [String: PRPollState] = [:]

    /// State of one automation's GitHub PR polling loop.
    struct PRPollState: Codable, Equatable, Sendable {
        /// When the repo was last polled (successfully or not).
        var lastPolledAt: Date?
        /// createdAt of the newest PR already seen — only strictly newer PRs
        /// fire. nil until the first (baseline) poll completes.
        var highWater: Date?
    }

    private let fileURL: URL
    private static let maxRuns = 200

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            self.fileURL = appSupport
                .appendingPathComponent("BromureAC", isDirectory: true)
                .appendingPathComponent("automations.json")
        }
        load()
    }

    func automation(_ id: UUID) -> ScheduledAutomation? {
        automations.first { $0.id == id }
    }

    /// Insert or replace. Any recorded next fire is dropped — the engine
    /// reschedules from the (possibly changed) recurrence on its next tick.
    func upsert(_ automation: ScheduledAutomation) {
        if let i = automations.firstIndex(where: { $0.id == automation.id }) {
            automations[i] = automation
        } else {
            automations.append(automation)
        }
        nextFires[automation.id.uuidString] = nil
        // Re-baseline PR polling too: an edit may have pointed the trigger
        // at a different repo, and a stale high-water mark from the old one
        // could replay or swallow events.
        pollStates[automation.id.uuidString] = nil
        save()
    }

    func remove(_ id: UUID) {
        automations.removeAll { $0.id == id }
        runs.removeAll { $0.automationID == id }
        nextFires[id.uuidString] = nil
        pollStates[id.uuidString] = nil
        save()
    }

    func record(_ run: AutomationRunRecord) {
        runs.insert(run, at: 0)
        if runs.count > Self.maxRuns { runs.removeLast(runs.count - Self.maxRuns) }
        save()
    }

    func runs(for id: UUID) -> [AutomationRunRecord] {
        runs.filter { $0.automationID == id }
    }

    func lastRun(for id: UUID) -> AutomationRunRecord? {
        runs.first { $0.automationID == id }
    }

    func nextFire(for id: UUID) -> Date? {
        nextFires[id.uuidString]
    }

    func setNextFire(_ date: Date?, for id: UUID) {
        nextFires[id.uuidString] = date
        save()
    }

    func pollState(for id: UUID) -> PRPollState? {
        pollStates[id.uuidString]
    }

    func setPollState(_ state: PRPollState?, for id: UUID) {
        pollStates[id.uuidString] = state
        save()
    }

    // MARK: Persistence

    private struct FilePayload: Codable {
        var automations: [ScheduledAutomation]
        var runs: [AutomationRunRecord]
        var nextFires: [String: Date]?
        var pollStates: [String: PRPollState]?
    }

    // Profile.swift's iso8601() factories are fileprivate; the store keeps
    // its own to match the same on-disk date format.
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? Self.decoder().decode(FilePayload.self, from: data)
        else { return }
        automations = payload.automations
        runs = payload.runs
        nextFires = payload.nextFires ?? [:]
        pollStates = payload.pollStates ?? [:]
    }

    private func save() {
        let payload = FilePayload(automations: automations, runs: runs,
                                  nextFires: nextFires, pollStates: pollStates)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - GitHub polling

/// One open pull request or issue, as much of it as the triggers need.
/// `branch` is empty for issues.
struct GitHubItem: Equatable, Sendable {
    var number: Int
    var title: String
    var url: String
    var branch: String
    var author: String
    var body: String
    var createdAt: Date
}

/// Host-side GitHub polling for the PR / Issue triggers. The request runs on
/// the Mac with the workspace's real github.com token — consistent with the
/// security model (the host owns real credentials; the VM never sees them),
/// and no inbound webhook surface.
enum GitHubPRPoller {
    /// "owner/repo" — permissive on characters GitHub allows, strict on shape.
    nonisolated static func isValidRepoSlug(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let ok = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return parts.allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.allSatisfy(ok.contains)
        }
    }

    /// Items strictly newer than the high-water mark, oldest first, plus the
    /// new mark. A nil mark is the baseline poll: nothing fires — the repo's
    /// pre-existing open PRs/issues are not "events".
    nonisolated static func newItems(fetched: [GitHubItem], highWater: Date?)
        -> (fire: [GitHubItem], newHighWater: Date?) {
        let newest = fetched.map(\.createdAt).max() ?? highWater
        guard let highWater else { return ([], newest) }
        let fresh = fetched.filter { $0.createdAt > highWater }
            .sorted { $0.createdAt < $1.createdAt }
        return (fresh, newest ?? highWater)
    }

    /// The template namespace for a trigger kind: `{{pr.*}}` or `{{issue.*}}`.
    nonisolated static func namespace(for kind: ScheduledAutomation.TriggerKind) -> String {
        kind == .githubIssue ? "issue" : "pr"
    }

    /// Fill `{{pr.*}}` / `{{issue.*}}` variables into the prompt. Prompts
    /// that use none of them get a context block appended instead, so a plain
    /// prompt still reaches the agent with the item's number, title, and body.
    nonisolated static func substitute(_ template: String, item: GitHubItem,
                                       kind: ScheduledAutomation.TriggerKind) -> String {
        // The body is agent context, not gospel — cap it so a pathological
        // PR/issue description can't balloon the guest command.
        let body = item.body.count > 6000
            ? String(item.body.prefix(6000)) + "\n[…truncated]"
            : item.body
        let ns = namespace(for: kind)
        if template.contains("{{\(ns).") {
            return template
                .replacingOccurrences(of: "{{\(ns).number}}", with: String(item.number))
                .replacingOccurrences(of: "{{\(ns).title}}", with: item.title)
                .replacingOccurrences(of: "{{\(ns).url}}", with: item.url)
                .replacingOccurrences(of: "{{\(ns).branch}}", with: item.branch)
                .replacingOccurrences(of: "{{\(ns).author}}", with: item.author)
                .replacingOccurrences(of: "{{\(ns).body}}", with: body)
        }
        let label = kind == .githubIssue ? "Issue" : "PR"
        var out = template
        out += "\n\n---\nGitHub \(label) #\(item.number): \(item.title)\n"
        out += "Author: \(item.author)"
        if !item.branch.isEmpty { out += " · Branch: \(item.branch)" }
        out += "\n\(item.url)\n"
        if !body.isEmpty { out += "\n\(body)\n" }
        return out
    }

    private struct APIItem: Decodable {
        struct Head: Decodable { var ref: String }
        struct User: Decodable { var login: String }
        /// Present on entries of /issues that are actually pull requests.
        struct PRStub: Decodable { var url: String? }
        var number: Int
        var title: String
        var html_url: String
        var head: Head?
        var user: User?
        var body: String?
        var created_at: Date
        var pull_request: PRStub?
    }

    /// Open PRs or issues, newest first (GitHub caps this page at 30 —
    /// plenty between polls). The /issues endpoint also returns PRs; those
    /// are dropped for the issue trigger. Throws on network/auth/decode
    /// failure; the engine treats any throw as "try again next interval".
    nonisolated static func fetchOpenItems(kind: ScheduledAutomation.TriggerKind,
                                           repo: String, token: String) async throws -> [GitHubItem] {
        let path = kind == .githubIssue ? "issues" : "pulls"
        var comps = URLComponents(string: "https://api.github.com/repos/\(repo)/\(path)")!
        comps.queryItems = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "sort", value: "created"),
            URLQueryItem(name: "direction", value: "desc"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([APIItem].self, from: data)
            .filter { kind != .githubIssue || $0.pull_request == nil }
            .map {
                GitHubItem(number: $0.number, title: $0.title, url: $0.html_url,
                           branch: $0.head?.ref ?? "", author: $0.user?.login ?? "",
                           body: $0.body ?? "", createdAt: $0.created_at)
            }
    }
}

// MARK: - Engine

/// Fires due automations. Owns a 30-second wall-clock tick — a Timer doesn't
/// fire during sleep, so a very late tick is exactly how missed fires are
/// detected and routed through the missed-run policy.
@MainActor
final class ScheduledAutomationEngine {
    private weak var delegate: ACAppDelegate?
    let store: ScheduledAutomationStore

    private var timer: Timer?
    /// Profiles this engine has asked to boot and is still waiting on, so two
    /// automations due on the same workspace don't race a double launch.
    private var pendingBoots: Set<UUID> = []
    /// Automations with a GitHub poll in flight — one at a time per automation.
    private var pollsInFlight: Set<UUID> = []
    /// Launched Claude runs awaiting completion, keyed by branch slug. When
    /// the tab's Stop hook reports .done, the guest saves the transcript into
    /// the worktree and closes the tab so runs don't pile up. In-memory: a
    /// relaunch orphans the watch and the tab simply stays open.
    private var completionWatch: [String: UUID] = [:]

    /// A fire more than this far past its time means the Mac was asleep or
    /// the app wasn't running — not merely a slow tick.
    static let lateGrace: TimeInterval = 180
    private static let bootTimeout: TimeInterval = 180
    private static let bootPollInterval: UInt64 = 5_000_000_000  // 5s in ns
    /// GitHub PR polling cadence. Generous for the API quota, and PR-review
    /// latency doesn't need better.
    static let prPollInterval: TimeInterval = 180

    init(store: ScheduledAutomationStore, delegate: ACAppDelegate?) {
        self.store = store
        self.delegate = delegate
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        BACDebug.log("automation", "engine started — \(store.automations.count) automation(s)")
        tick()   // catch up fires missed while the app was quit
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick(now: Date = Date()) {
        for a in store.automations where a.enabled {
            switch a.trigger {
            case .schedule:
                scheduleTick(a, now: now)
            case .githubPullRequest, .githubIssue:
                githubTick(a, now: now)
            }
        }
    }

    private func scheduleTick(_ a: ScheduledAutomation, now: Date) {
        guard let due = store.nextFire(for: a.id) else {
            // New, edited, or first-seen automation: plant the next fire.
            let next = AutomationSchedule.nextFire(for: a, after: now)
            BACDebug.log("automation", "planted next fire for “\(a.name)” at \(next)")
            store.setNextFire(next, for: a.id)
            return
        }
        guard due <= now else { return }
        let missed = now.timeIntervalSince(due) > Self.lateGrace
        if missed && a.missedRunPolicy == .skip {
            BACDebug.log("automation", "skipping “\(a.name)” — fire time \(due) missed")
            store.record(AutomationRunRecord(
                automationID: a.id, firedAt: due, outcome: .skipped,
                detail: NSLocalizedString(
                    "Fire time passed while the Mac was asleep or the app wasn't running",
                    comment: "skipped automation run")))
        } else {
            fire(a, now: now)
        }
        store.setNextFire(AutomationSchedule.nextFire(for: a, after: now), for: a.id)
    }

    private func githubTick(_ a: ScheduledAutomation, now: Date) {
        let state = store.pollState(for: a.id)
        if let last = state?.lastPolledAt,
           now.timeIntervalSince(last) < Self.prPollInterval { return }
        guard !pollsInFlight.contains(a.id) else { return }
        pollsInFlight.insert(a.id)
        Task { [weak self] in
            await self?.pollGitHub(a, now: now)
            self?.pollsInFlight.remove(a.id)
        }
    }

    /// One poll of the automation's repo. Any failure (bad repo, no token,
    /// network, auth) just advances lastPolledAt — the next interval retries;
    /// run records are reserved for actual fires and skips.
    private func pollGitHub(_ a: ScheduledAutomation, now: Date) async {
        let previous = store.pollState(for: a.id)
        var next = ScheduledAutomationStore.PRPollState(
            lastPolledAt: now, highWater: previous?.highWater)
        defer { store.setPollState(next, for: a.id) }

        guard let delegate,
              let profile = delegate.profile(for: a.profileID),
              GitHubPRPoller.isValidRepoSlug(a.githubRepo) else { return }
        guard let token = profile.gitHTTPSCredentials.first(where: { cred in
            guard cred.isUsable else { return false }
            let h = cred.host.lowercased()
            return h == "github.com" || h.hasSuffix(".github.com")
        })?.token, !token.isEmpty else {
            BACDebug.log("automation", "“\(a.name)”: no usable github.com token — poll skipped")
            return
        }

        do {
            let items = try await GitHubPRPoller.fetchOpenItems(
                kind: a.trigger, repo: a.githubRepo, token: token)
            let (fresh, newHighWater) = GitHubPRPoller.newItems(
                fetched: items, highWater: previous?.highWater)
            next.highWater = newHighWater
            if previous?.highWater == nil {
                BACDebug.log("automation", "“\(a.name)”: baseline poll of \(a.githubRepo), \(items.count) open item(s)")
                return
            }
            let label = a.trigger == .githubIssue ? "Issue" : "PR"
            for item in fresh {
                BACDebug.log("automation", "“\(a.name)”: firing for \(label) #\(item.number)")
                fire(a, now: Date(),
                     promptOverride: GitHubPRPoller.substitute(a.prompt, item: item,
                                                               kind: a.trigger),
                     detailOverride: "\(label) #\(item.number): \(item.title)",
                     slugSuffix: "\(label.lowercased())\(item.number)")
            }
        } catch {
            BACDebug.log("automation", "“\(a.name)”: poll of \(a.githubRepo) failed — \(error)")
        }
    }

    /// Manual "Run now" — the same path as a scheduled fire; the schedule is
    /// left untouched.
    func runNow(_ automation: ScheduledAutomation) {
        fire(automation, now: Date())
    }

    // MARK: Firing

    private func fire(_ a: ScheduledAutomation, now: Date,
                      promptOverride: String? = nil,
                      detailOverride: String? = nil,
                      slugSuffix: String? = nil) {
        guard let delegate else { return }
        guard delegate.profile(for: a.profileID) != nil else {
            store.record(AutomationRunRecord(
                automationID: a.id, firedAt: now, outcome: .failed,
                detail: NSLocalizedString("The workspace no longer exists",
                                          comment: "failed automation run")))
            return
        }

        var slug = Self.branchSlug(for: a.name, at: now)
        if let slugSuffix { slug += "-" + slugSuffix }
        let detail = detailOverride ?? slug
        // "run", not "create": the guest makes a worktree when the path is a
        // git repo and falls back to a plain agent tab when it isn't.
        let args = [Self.guestPath(a.repoPath), slug, a.name,
                    a.tool.rawValue, promptOverride ?? a.prompt]

        // Running workspace: queue straight to the session outbox (the same
        // detached path the CLI/SSH surface uses — no window or pane needed).
        if delegate.automationWorktreeCommand(
            profileNameOrID: a.profileID.uuidString, action: "run", args: args) {
            BACDebug.log("automation", "launched “\(a.name)” → \(slug)")
            noteLaunched(a, slug: slug)
            store.record(AutomationRunRecord(
                automationID: a.id, firedAt: now, outcome: .launched, detail: detail))
            return
        }

        // Workspace off/suspended: boot it, then queue once the outbox exists.
        BACDebug.log("automation", "“\(a.name)”: workspace off — booting")
        if !pendingBoots.contains(a.profileID) {
            pendingBoots.insert(a.profileID)
            delegate.startProfile(a.profileID)
        }
        let deadline = now.addingTimeInterval(Self.bootTimeout)
        Task { [weak self] in
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: Self.bootPollInterval)
                guard let self, let delegate = self.delegate else { return }
                if delegate.automationWorktreeCommand(
                    profileNameOrID: a.profileID.uuidString, action: "run", args: args) {
                    self.pendingBoots.remove(a.profileID)
                    BACDebug.log("automation", "launched “\(a.name)” → \(slug) (after boot)")
                    self.noteLaunched(a, slug: slug)
                    self.store.record(AutomationRunRecord(
                        automationID: a.id, firedAt: now, outcome: .launched, detail: detail))
                    return
                }
            }
            guard let self else { return }
            self.pendingBoots.remove(a.profileID)
            self.store.record(AutomationRunRecord(
                automationID: a.id, firedAt: now, outcome: .failed,
                detail: NSLocalizedString("The workspace did not boot in time",
                                          comment: "failed automation run")))
        }
    }

    // MARK: Run completion (transcript + tab close)

    /// Track a launched run for auto-finish. Claude only: its per-window Stop
    /// hook is the one reliable "done" signal — the Codex/Grok proxy
    /// heuristic can report .done during a long silent stretch, and closing
    /// a tab on a false positive would kill live work.
    private func noteLaunched(_ a: ScheduledAutomation, slug: String) {
        guard a.tool == .claude else { return }
        completionWatch[slug] = a.id
    }

    /// Delegate callback: a Claude tab flipped to .done. If it's a watched
    /// automation worktree (branch "wt/<slug>" with an optional -N dedup
    /// suffix), ask the guest to save the transcript into the worktree and
    /// close the tab. Runs that pause on .needsInput keep their watch — they
    /// finish whenever the user unblocks them.
    func agentFinished(profileID: UUID, worktreeBranch: String?) {
        guard let branch = worktreeBranch, branch.hasPrefix("wt/") else { return }
        let slugPart = String(branch.dropFirst(3))
        let matched = completionWatch.first { slug, _ in
            slugPart == slug || (slugPart.hasPrefix(slug + "-")
                && Int(slugPart.dropFirst(slug.count + 1)) != nil)
        }
        guard let (slug, automationID) = matched,
              store.automation(automationID)?.profileID == profileID else { return }
        completionWatch[slug] = nil
        BACDebug.log("automation", "run done — saving transcript and closing tab for \(branch)")
        // Small delay so the Stop hook's final transcript lines land on disk
        // before the guest copies the file.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, let delegate = self.delegate else { return }
            _ = delegate.automationWorktreeCommand(
                profileNameOrID: profileID.uuidString, action: "finish", args: [branch])
        }
    }

    // MARK: Helpers

    /// A filesystem/branch-safe slug from the automation name, timestamped so
    /// repeated fires don't collide on the branch name.
    nonisolated static func branchSlug(for name: String, at date: Date) -> String {
        var out = ""
        var lastDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        let base = out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(30)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyMMdd-HHmm"
        let stamp = fmt.string(from: date)
        return (base.isEmpty ? "automation" : String(base)) + "-" + stamp
    }

    /// Expand the user's repo path to an absolute guest path. The guest home
    /// is fixed at /home/ubuntu in the AC image.
    nonisolated static func guestPath(_ path: String) -> String {
        let home = "/home/ubuntu"
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + String(trimmed.dropFirst(1)) }
        if trimmed.hasPrefix("/") { return trimmed }
        return home + "/" + trimmed
    }
}

// MARK: - Unattended-run warnings

extension Profile {
    /// Labels of credentials whose fake→real swap prompts on the host
    /// ("Ask before use"). An unattended run that needs one stalls in the
    /// consent dialog until a human answers — the automation editor surfaces
    /// this up front rather than letting a 3 a.m. run hang.
    var askBeforeUseCredentialLabels: [String] {
        var out: [String] = []
        for spec in allToolSpecs where spec.requireApproval {
            out.append("\(spec.tool.displayName) API key")
        }
        for cred in gitHTTPSCredentials where cred.requireApproval {
            out.append("Git token (\(cred.host))")
        }
        for token in manualTokens where token.requireApproval {
            out.append(token.name)
        }
        for key in importedSSHKeys where key.requireApproval {
            out.append("SSH key “\(key.label)”")
        }
        for kube in kubeconfigs where kube.requireApproval {
            out.append("Kubernetes (\(kube.name))")
        }
        for reg in dockerRegistries where reg.requireApproval {
            out.append("Registry (\(reg.host))")
        }
        for db in httpDatabases where db.requireApproval {
            out.append(db.name)
        }
        return out
    }
}
