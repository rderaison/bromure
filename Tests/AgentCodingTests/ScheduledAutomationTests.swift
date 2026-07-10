import Foundation
import Testing
@testable import bromure_ac

@Suite("ScheduledAutomations")
struct ScheduledAutomationTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: y, month: mo, day: d,
                                              hour: h, minute: mi))!
    }

    private func automation(frequency: ScheduledAutomation.Frequency,
                            weekday: Int = 2, hour: Int, minute: Int) -> ScheduledAutomation {
        ScheduledAutomation(profileID: UUID(), frequency: frequency,
                            weekday: weekday, hour: hour, minute: minute)
    }

    // MARK: Schedule math

    @Test("Daily fires later the same day when the time hasn't passed")
    func dailySameDay() {
        let a = automation(frequency: .daily, hour: 9, minute: 0)
        // Wed Jul 8 2026, 08:00 UTC → Wed 09:00.
        let next = AutomationSchedule.nextFire(for: a, after: date(2026, 7, 8, 8, 0),
                                               calendar: utcCalendar)
        #expect(next == date(2026, 7, 8, 9, 0))
    }

    @Test("Daily rolls to tomorrow when the time has passed")
    func dailyTomorrow() {
        let a = automation(frequency: .daily, hour: 9, minute: 0)
        let next = AutomationSchedule.nextFire(for: a, after: date(2026, 7, 8, 10, 0),
                                               calendar: utcCalendar)
        #expect(next == date(2026, 7, 9, 9, 0))
    }

    @Test("Weekdays skips the weekend")
    func weekdaysSkipsWeekend() {
        let a = automation(frequency: .weekdays, hour: 9, minute: 30)
        // Sat Jul 11 2026, noon → Mon Jul 13, 09:30.
        let next = AutomationSchedule.nextFire(for: a, after: date(2026, 7, 11, 12, 0),
                                               calendar: utcCalendar)
        #expect(next == date(2026, 7, 13, 9, 30))
    }

    @Test("Weekdays fires Friday when due Friday")
    func weekdaysFriday() {
        let a = automation(frequency: .weekdays, hour: 9, minute: 0)
        // Fri Jul 10 2026, 08:00 → Fri 09:00 (not Monday).
        let next = AutomationSchedule.nextFire(for: a, after: date(2026, 7, 10, 8, 0),
                                               calendar: utcCalendar)
        #expect(next == date(2026, 7, 10, 9, 0))
    }

    @Test("Weekly lands on the chosen weekday")
    func weeklyWeekday() {
        // weekday 6 = Friday in the Gregorian calendar (1 = Sunday).
        let a = automation(frequency: .weekly, weekday: 6, hour: 17, minute: 0)
        // Wed Jul 8 2026 → Fri Jul 10, 17:00.
        let next = AutomationSchedule.nextFire(for: a, after: date(2026, 7, 8, 12, 0),
                                               calendar: utcCalendar)
        #expect(next == date(2026, 7, 10, 17, 0))
    }

    @Test("Next fire is strictly in the future")
    func strictlyFuture() {
        let a = automation(frequency: .daily, hour: 9, minute: 0)
        // Exactly at fire time → tomorrow, not "now".
        let next = AutomationSchedule.nextFire(for: a, after: date(2026, 7, 8, 9, 0),
                                               calendar: utcCalendar)
        #expect(next == date(2026, 7, 9, 9, 0))
    }

    // MARK: Slug + guest path

    @Test("Branch slug is filesystem-safe and timestamped")
    func slug() {
        let s = ScheduledAutomationEngine.branchSlug(
            for: "Nightly dependency audit!", at: date(2026, 7, 8, 9, 5))
        #expect(s.hasPrefix("nightly-dependency-audit-"))
        #expect(!s.contains(" "))
        #expect(!s.contains("!"))
    }

    @Test("Empty name still yields a usable slug")
    func slugEmpty() {
        let s = ScheduledAutomationEngine.branchSlug(for: "  ", at: date(2026, 7, 8, 9, 5))
        #expect(s.hasPrefix("automation-"))
    }

    @Test("Guest paths expand to the fixed guest home")
    func guestPaths() {
        #expect(ScheduledAutomationEngine.guestPath("~") == "/home/ubuntu")
        #expect(ScheduledAutomationEngine.guestPath("") == "/home/ubuntu")
        #expect(ScheduledAutomationEngine.guestPath("~/repo") == "/home/ubuntu/repo")
        #expect(ScheduledAutomationEngine.guestPath("repo") == "/home/ubuntu/repo")
        #expect(ScheduledAutomationEngine.guestPath("/opt/x") == "/opt/x")
    }

    // MARK: Store persistence

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-test-\(UUID().uuidString)")
            .appendingPathComponent("automations.json")
    }

    @MainActor
    @Test("Store round-trips automations, runs, and planned fires")
    func storeRoundTrip() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ScheduledAutomationStore(fileURL: url)
        var a = ScheduledAutomation(profileID: UUID(), tool: .codex, prompt: "audit deps")
        a.name = "Nightly audit"
        a.frequency = .daily
        // ISO-8601 storage is whole-second; a fractional createdAt would
        // make the reloaded copy compare unequal.
        a.createdAt = date(2026, 7, 8, 12, 0)
        store.upsert(a)
        let fire = date(2026, 7, 9, 9, 0)
        store.setNextFire(fire, for: a.id)
        store.record(AutomationRunRecord(automationID: a.id, firedAt: Date(),
                                         outcome: .launched, detail: "slug-1"))

        let reloaded = ScheduledAutomationStore(fileURL: url)
        #expect(reloaded.automations == [a])
        #expect(reloaded.nextFire(for: a.id) == fire)
        #expect(reloaded.runs(for: a.id).count == 1)
        #expect(reloaded.runs(for: a.id).first?.outcome == .launched)
    }

    @MainActor
    @Test("Editing an automation drops its planned fire for rescheduling")
    func upsertClearsNextFire() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ScheduledAutomationStore(fileURL: url)
        let a = ScheduledAutomation(profileID: UUID())
        store.upsert(a)
        store.setNextFire(date(2026, 7, 9, 9, 0), for: a.id)
        store.upsert(a)   // edit-and-save
        #expect(store.nextFire(for: a.id) == nil)
    }

    // MARK: Engine tick semantics

    @MainActor
    @Test("First tick plants a next fire without firing")
    func tickPlants() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ScheduledAutomationStore(fileURL: url)
        store.upsert(ScheduledAutomation(profileID: UUID()))
        let engine = ScheduledAutomationEngine(store: store, delegate: nil)
        let now = Date()
        engine.tick(now: now)
        let a = store.automations[0]
        #expect(store.nextFire(for: a.id) != nil)
        #expect(store.nextFire(for: a.id)! > now)
        #expect(store.runs.isEmpty)
    }

    @MainActor
    @Test("A fire missed beyond the grace window is skipped and recorded")
    func missedFireSkips() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ScheduledAutomationStore(fileURL: url)
        let a = ScheduledAutomation(profileID: UUID())   // policy .skip by default
        store.upsert(a)
        let now = Date()
        // The fire time passed 2 hours ago — well beyond the grace window.
        store.setNextFire(now.addingTimeInterval(-7200), for: a.id)

        let engine = ScheduledAutomationEngine(store: store, delegate: nil)
        engine.tick(now: now)

        #expect(store.runs(for: a.id).first?.outcome == .skipped)
        #expect(store.nextFire(for: a.id)! > now)
    }

    @MainActor
    @Test("Disabled automations never fire or advance")
    func disabledInert() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ScheduledAutomationStore(fileURL: url)
        var a = ScheduledAutomation(profileID: UUID())
        a.enabled = false
        store.upsert(a)
        let engine = ScheduledAutomationEngine(store: store, delegate: nil)
        engine.tick(now: Date())
        #expect(store.nextFire(for: a.id) == nil)
        #expect(store.runs.isEmpty)
    }

    // MARK: GitHub PR trigger

    private func item(_ number: Int, createdAt: Date, title: String = "t",
                      body: String = "") -> TriggerItem {
        TriggerItem(number: number, title: title, url: "https://github.com/o/r/pull/\(number)",
                   branch: "feat", author: "alice", body: body, createdAt: createdAt)
    }

    @Test("Event keys are stable and namespaced per trigger kind")
    func eventKeys() {
        var i = item(123, createdAt: date(2026, 7, 8, 10, 0))
        #expect(GitHubPRPoller.eventKey(i, kind: .githubPullRequest) == "pr:123")
        #expect(GitHubPRPoller.eventKey(i, kind: .githubIssue) == "issue:123")
        i.identifier = "abc1234"
        #expect(GitHubPRPoller.eventKey(i, kind: .githubCommit) == "commit:abc1234")
        i.identifier = "ENG-7"
        #expect(GitHubPRPoller.eventKey(i, kind: .linearIssue) == "linear:ENG-7")
    }

    @Test("PR prompt variables are substituted")
    func prSubstitution() {
        let p = item(7, createdAt: date(2026, 7, 8, 10, 0), title: "Fix leak",
                     body: "Repro steps here")
        let out = GitHubPRPoller.substitute(
            "Review PR #{{pr.number}} ({{pr.title}}): {{pr.body}}", item: p,
            kind: .githubPullRequest)
        #expect(out == "Review PR #7 (Fix leak): Repro steps here")
    }

    @Test("Issue prompt variables use the issue namespace")
    func issueSubstitution() {
        let p = item(9, createdAt: date(2026, 7, 8, 10, 0), title: "Crash on quit",
                     body: "Stack trace")
        let out = GitHubPRPoller.substitute(
            "Triage issue {{issue.number}}: {{issue.title}} — {{issue.body}}",
            item: p, kind: .githubIssue)
        #expect(out == "Triage issue 9: Crash on quit — Stack trace")
    }

    @Test("Prompts without variables get the item context appended")
    func prAutoAppend() {
        let p = item(7, createdAt: date(2026, 7, 8, 10, 0), title: "Fix leak",
                     body: "Repro steps here")
        let out = GitHubPRPoller.substitute("Review this PR.", item: p,
                                            kind: .githubPullRequest)
        #expect(out.hasPrefix("Review this PR."))
        #expect(out.contains("PR #7"))
        #expect(out.contains("Fix leak"))
        #expect(out.contains("Repro steps here"))
    }

    @Test("Issue auto-append labels the context as an issue")
    func issueAutoAppend() {
        var p = item(9, createdAt: date(2026, 7, 8, 10, 0), title: "Crash on quit",
                     body: "Stack trace")
        p.branch = ""
        let out = GitHubPRPoller.substitute("Fix this.", item: p, kind: .githubIssue)
        #expect(out.contains("Issue #9"))
        #expect(!out.contains("Branch:"))
    }

    @Test("Repo slug validation")
    func repoSlug() {
        #expect(GitHubPRPoller.isValidRepoSlug("rderaison/bromure"))
        #expect(GitHubPRPoller.isValidRepoSlug("a-b.c_d/x.y-z_w"))
        #expect(!GitHubPRPoller.isValidRepoSlug("bromure"))
        #expect(!GitHubPRPoller.isValidRepoSlug("a/b/c"))
        #expect(!GitHubPRPoller.isValidRepoSlug("/b"))
        #expect(!GitHubPRPoller.isValidRepoSlug("a/"))
        #expect(!GitHubPRPoller.isValidRepoSlug("a b/c"))
    }

    @Test("Automations saved before triggers existed decode as schedules")
    func triggerDecodeDefault() throws {
        let json = """
        {"id":"6B29FC40-CA47-1067-B31D-00DD010662DA",
         "name":"old","profileID":"6B29FC40-CA47-1067-B31D-00DD010662DB"}
        """
        let a = try JSONDecoder().decode(ScheduledAutomation.self, from: Data(json.utf8))
        #expect(a.trigger == .schedule)
        #expect(a.githubRepo.isEmpty)
    }

    // MARK: Trigger filters

    @Test("Label filter is any-of and case-insensitive")
    func labelFilter() {
        var f = ScheduledAutomation.TriggerFilters()
        f.labels = ["Bug", "agent-ok"]
        var i = item(1, createdAt: date(2026, 7, 8, 10, 0))
        i.labels = ["BUG", "docs"]
        #expect(f.matches(i, kind: .githubIssue))
        i.labels = ["docs"]
        #expect(!f.matches(i, kind: .githubIssue))
        i.labels = []
        #expect(!f.matches(i, kind: .githubIssue))
    }

    @Test("Draft PRs are excluded by default, but only for the PR trigger")
    func draftFilter() {
        let f = ScheduledAutomation.TriggerFilters()
        var i = item(2, createdAt: date(2026, 7, 8, 10, 0))
        i.isDraft = true
        #expect(!f.matches(i, kind: .githubPullRequest))
        #expect(f.matches(i, kind: .githubIssue))
        var allow = f
        allow.excludeDrafts = false
        #expect(allow.matches(i, kind: .githubPullRequest))
    }

    @Test("Bot authors are kept by default and dropped when ignored")
    func botFilter() {
        var i = item(3, createdAt: date(2026, 7, 8, 10, 0))
        i.isBot = true
        let keep = ScheduledAutomation.TriggerFilters()
        #expect(keep.matches(i, kind: .githubIssue))
        var drop = keep
        drop.ignoreBots = true
        #expect(!drop.matches(i, kind: .githubIssue))
    }

    @Test("Title filter is case-insensitive substring")
    func titleFilter() {
        var f = ScheduledAutomation.TriggerFilters()
        f.titleContains = "crash"
        var i = item(4, createdAt: date(2026, 7, 8, 10, 0), title: "Fix CRASH on quit")
        #expect(f.matches(i, kind: .githubIssue))
        i.title = "Improve docs"
        #expect(!f.matches(i, kind: .githubIssue))
    }

    @Test("Default filters pass everything non-draft")
    func defaultFilters() {
        let f = ScheduledAutomation.TriggerFilters()
        let i = item(5, createdAt: date(2026, 7, 8, 10, 0))
        #expect(f.matches(i, kind: .githubPullRequest))
        #expect(f.matches(i, kind: .githubIssue))
        #expect(f.matches(i, kind: .linearIssue))
    }

    @Test("Automations saved before filters existed decode with defaults")
    func filtersDecodeDefault() throws {
        let json = """
        {"id":"6B29FC40-CA47-1067-B31D-00DD010662DA",
         "name":"old","profileID":"6B29FC40-CA47-1067-B31D-00DD010662DB",
         "trigger":"githubIssue"}
        """
        let a = try JSONDecoder().decode(ScheduledAutomation.self, from: Data(json.utf8))
        #expect(a.filters == ScheduledAutomation.TriggerFilters())
        #expect(a.filters.excludeDrafts)
    }

    // MARK: Workspace-at-fire-time + clone flags

    @Test("Automations saved before the run-placement flags decode with defaults")
    func placementFlagsDecodeDefault() throws {
        let json = """
        {"id":"6B29FC40-CA47-1067-B31D-00DD010662DA",
         "name":"old","profileID":"6B29FC40-CA47-1067-B31D-00DD010662DB"}
        """
        let a = try JSONDecoder().decode(ScheduledAutomation.self, from: Data(json.utf8))
        #expect(a.startWorkspaceIfNeeded)          // boot-if-needed stays the default
        #expect(!a.cloneWorkspaceFirst)            // cloning is opt-in
        #expect(a.chainedAutomationID == nil)
    }

    @Test("Placement flags and the chain link round-trip through Codable")
    func placementFlagsRoundTrip() throws {
        var a = ScheduledAutomation(profileID: UUID())
        a.startWorkspaceIfNeeded = false
        a.cloneWorkspaceFirst = true
        a.trigger = .afterAutomation
        a.chainedAutomationID = UUID()
        let decoded = try JSONDecoder().decode(
            ScheduledAutomation.self, from: JSONEncoder().encode(a))
        #expect(decoded.startWorkspaceIfNeeded == false)
        #expect(decoded.cloneWorkspaceFirst == true)
        #expect(decoded.trigger == .afterAutomation)
        #expect(decoded.chainedAutomationID == a.chainedAutomationID)
    }

    // MARK: Chaining

    @Test("Chain cycle detection catches self, 2-cycles, and long loops")
    func chainCycles() {
        let pid = UUID()
        var a = ScheduledAutomation(profileID: pid)
        var b = ScheduledAutomation(profileID: pid)
        var c = ScheduledAutomation(profileID: pid)

        // Linear chain a ← b ← c: no cycle anywhere.
        b.chainedAutomationID = a.id
        c.chainedAutomationID = b.id
        #expect(!ScheduledAutomation.chainCycles(from: a.id, in: [a, b, c]))
        #expect(!ScheduledAutomation.chainCycles(from: c.id, in: [a, b, c]))

        // Self-chain.
        var s = ScheduledAutomation(profileID: pid)
        s.chainedAutomationID = s.id
        #expect(ScheduledAutomation.chainCycles(from: s.id, in: [s]))

        // Closing the loop a → c makes every member cyclic.
        a.chainedAutomationID = c.id
        #expect(ScheduledAutomation.chainCycles(from: a.id, in: [a, b, c]))
        #expect(ScheduledAutomation.chainCycles(from: b.id, in: [a, b, c]))

        // A dangling link (upstream deleted) is not a cycle.
        var d = ScheduledAutomation(profileID: pid)
        d.chainedAutomationID = UUID()
        #expect(!ScheduledAutomation.chainCycles(from: d.id, in: [d]))
    }

    @Test("Chain prompt variables are substituted")
    func chainSubstitution() {
        let out = ScheduledAutomationEngine.substituteChain(
            "Review {{chain.branch}} produced by {{chain.automation}}.",
            upstreamName: "Nightly refactor", branch: "wt/nightly-0709")
        #expect(out == "Review wt/nightly-0709 produced by Nightly refactor.")
    }

    @Test("Chain prompts without variables get the upstream context appended")
    func chainAutoAppend() {
        let out = ScheduledAutomationEngine.substituteChain(
            "Write the changelog.",
            upstreamName: "Nightly refactor", branch: "wt/nightly-0709")
        #expect(out.hasPrefix("Write the changelog."))
        #expect(out.contains("Nightly refactor"))
        #expect(out.contains("wt/nightly-0709"))
    }

    // MARK: Unattended-run warnings

    @MainActor
    @Test("Ask-before-use credentials surface in the warning labels")
    func askLabels() {
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        #expect(p.askBeforeUseCredentialLabels.isEmpty)
        p.gitHTTPSCredentials = [
            GitHTTPSCredential(host: "github.com", username: "u", token: "t",
                               requireApproval: true)
        ]
        #expect(p.askBeforeUseCredentialLabels == ["Git token (github.com)"])
    }
}
