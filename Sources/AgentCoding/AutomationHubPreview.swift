#if os(macOS)
import AppKit
import SwiftUI

/// Sample data for the Automations hub, rendered offline by
/// `bromure-ac __shot-ui hub-<overview|findings|repositories|board|editor|empty>`
/// — design iteration and doc screenshots without a live app, VMs or GitHub.
@MainActor
enum AutomationHubPreview {
    static func view(_ which: String) -> (AnyView, NSSize) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hub-preview-\(UUID().uuidString)", isDirectory: true)
        let autoStore = ScheduledAutomationStore(fileURL: tmp.appendingPathComponent("a.json"))
        let findingStore = FindingStore(fileURL: tmp.appendingPathComponent("f.json"), persists: false)
        let taskStore = CodingTaskStore(fileURL: tmp.appendingPathComponent("t.json"))
        let model = SessionListModel()
        let hub = AutomationHubModel()
        let ws1 = UUID(), ws2 = UUID()
        model.profileRows = [
            .init(id: ws1, name: "Platform", accentHex: "#3B82F6", state: .running, compromised: false),
            .init(id: ws2, name: "Payments", accentHex: "#10B981", state: .off, compromised: false),
        ]
        let choices = [
            WatchWorkspaceChoice(id: ws1, name: "Platform", tools: [.claude, .codex], defaultTool: .claude,
                                 hasGitHubToken: true, askBeforeUseLabels: []),
            WatchWorkspaceChoice(id: ws2, name: "Payments", tools: [.claude], defaultTool: .claude,
                                 hasGitHubToken: true, askBeforeUseLabels: ["Git token (github.com)"]),
        ]

        if which != "hub-empty" {
            populate(autoStore: autoStore, findingStore: findingStore, taskStore: taskStore,
                     ws1: ws1, ws2: ws2)
        }
        switch which {
        case "hub-findings":
            hub.showSecurity(.findings)
            hub.selectedFindingID = findingStore.findings
                .first { $0.title.hasPrefix("SQL injection") }?.id
        case "hub-findings-list":   hub.showSecurity(.findings)
        case "hub-repositories":    hub.showSecurity(.repositories)
        case "hub-security":        hub.showSecurity(.overview)
        case "hub-board", "hub-runs": hub.tab = .runs
        default:                    hub.tab = .automations
        }
        let demoChoices = TaskAssigneeChoices(
            sessions: [.init(id: UUID(), label: "@hotfixes", workspace: "Platform", busy: false),
                       .init(id: UUID(), label: "@api-refactor", workspace: "Platform", busy: true),
                       .init(id: UUID(), label: "@refunds", workspace: "Payments", busy: false)],
            rooms: [.init(id: UUID(), name: "payments")])
        if which == "hub-quick-task" {
            let here = TaskAssignment(kind: .session, id: demoChoices.sessions[0].id, label: "@hotfixes")
            return (AnyView(QuickTaskView(choices: demoChoices, here: here, folder: "~/storefront",
                                          workspaceName: "Platform", initialAssignment: here,
                                          onAdd: { _, _, _, _ in }, onClose: {})
                .padding(30)
                .background(BoardBackdrop())), NSSize(width: 680, height: 230))
        }
        if which == "hub-task-editor" || which == "hub-task-editor-glass" {
            let profiles = [Profile(id: ws1, name: "Platform", tool: .claude, authMode: .token),
                            Profile(id: ws2, name: "Payments", tool: .claude, authMode: .token)]
            var t = CodingTask(title: "Checkout button misaligned on Safari",
                               details: "On Safari 19 the **Pay** button drops below the total.\n\n- Repro: iPhone width\n- Expected: inline",
                               profileID: ws1, repoPath: "~/storefront")
            t.assignment = TaskAssignment(kind: .session, id: demoChoices.sessions[0].id, label: "@hotfixes")
            let glass = which.hasSuffix("glass")
            return (AnyView(TaskEditorSheet(task: t, profiles: profiles, siblings: [], isNew: true,
                                            onSave: { _ in }, onPlan: { _ in }, onDelete: { _ in },
                                            onCancel: {}, assignees: demoChoices, canAssign: true,
                                            glass: glass)
                .padding(glass ? 20 : 0)
                .background(glass ? AnyView(BoardBackdrop()) : AnyView(Color.clear))),
                    NSSize(width: glass ? 800 : 720, height: glass ? 680 : 620))
        }
        if which == "hub-assign" {
            let t = CodingTask(title: "Checkout button misaligned on Safari", profileID: ws1)
            return (AnyView(AssignTaskSheet(task: t, choices: demoChoices, onPick: { _ in },
                                            onStartNow: {}, onCancel: {})), NSSize(width: 440, height: 480))
        }
        if which == "hub-chooser" {
            return (AnyView(NewAutomationChooser(onChoose: { _ in }, onCancel: {})), NSSize(width: 900, height: 560))
        }

        let size = NSSize(width: 1320, height: 860)
        if which == "hub-editor" {
            let w = findingStore.watches.first!
            return (AnyView(WatchEditorSheet(
                draft: w, isNew: false, workspaces: choices, promptGuardInstalled: false,
                fetchRepos: { _ in ["acme/storefront", "acme/payments-api", "acme/infra"] },
                onEditWorkspace: { _ in }, onCancel: {}, onSave: { _, _ in })),
                    NSSize(width: 580, height: 720))
        }
        if which == "hub-editor-new" {
            return (AnyView(WatchEditorSheet(
                draft: WatchedRepo(repo: "", profileID: ws1), isNew: true, workspaces: choices,
                promptGuardInstalled: true,
                fetchRepos: { _ in ["acme/storefront", "acme/payments-api", "acme/infra"] },
                onEditWorkspace: { _ in }, onCancel: {}, onSave: { _, _ in })),
                    NSSize(width: 580, height: 720))
        }
        let view = AutomationHubView(
            automationStore: autoStore, findingStore: findingStore, taskStore: taskStore,
            model: model, hub: hub, workspaces: { choices },
            promptGuardInstalled: { true }, actions: AutomationHubView.Actions(
                askSession: { _, _, _, done in done(.done) },
                sessionChoices: {
                    [PeerMention(sessionID: UUID(), nick: "hotfixes", title: "Checkout hotfixes", workspace: "Platform"),
                     PeerMention(sessionID: UUID(), nick: "refunds", title: "Refund flow", workspace: "Payments")]
                }))
        return (AnyView(view), size)
    }

    private static func populate(autoStore: ScheduledAutomationStore, findingStore: FindingStore,
                                 taskStore: CodingTaskStore, ws1: UUID, ws2: UUID) {
        let now = Date()
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }

        var store = WatchedRepo(repo: "acme/storefront", profileID: ws1, focus: .both,
                                fullScanWeekday: 2, fullScanHour: 3, commitBranch: "main",
                                autoFixMinSeverity: .critical,
                                reviewedThrough: ["main": .init(sha: "4f9c2e1a7b3d5c6e8f0a1b2c3d4e5f6a7b8c9d0e",
                                                                at: ago(30))])
        var pay = WatchedRepo(repo: "acme/payments-api", profileID: ws2,
                              scans: [.fullScan, .pullRequests], scheduledScope: .baseline)
        for scan in WatchedRepo.Scan.allCases {
            for w in [store, pay] where scan == .fullScan || w.scans.contains(scan) {
                let a = RepoWatchEngine.automation(for: scan, of: w, id: UUID(), createdAt: ago(200))
                autoStore.upsert(a)
                if w.id == store.id { store.automationIDs[scan.rawValue] = a.id }
                else { pay.automationIDs[scan.rawValue] = a.id }
            }
        }
        findingStore.upsertWatch(store)
        findingStore.upsertWatch(pay)
        let nightly = ScheduledAutomation(name: "Dependency digest", profileID: ws1, frequency: .weekdays,
                                          hour: 8, prompt: "Summarize outdated deps", createdAt: ago(400))
        autoStore.upsert(nightly)
        var review = ScheduledAutomation(name: "Review new pull requests", profileID: ws1,
                                         trigger: .githubPullRequest, githubRepo: "acme/storefront",
                                         prompt: "Review {{pr.title}} and leave notes", repoPath: "~/storefront",
                                         createdAt: ago(300))
        review.filters.baseBranch = "main"
        autoStore.upsert(review)
        autoStore.setPollState(.init(lastPolledAt: ago(0.05), highWater: ago(100)), for: review.id)
        let triage = ScheduledAutomation(name: "Triage Linear bugs", profileID: ws2, enabled: false,
                                         trigger: .linearIssue, linearTeam: "pay",
                                         prompt: "Reproduce and label", createdAt: ago(350))
        autoStore.upsert(triage)
        autoStore.record(AutomationRunRecord(automationID: review.id, firedAt: ago(4), outcome: .launched,
                                             detail: "PR #88: Checkout redesign", branchSlug: "review-pr88",
                                             itemKey: "pr:88", completedAt: ago(3.8)))
        autoStore.setNextFire(now.addingTimeInterval(16 * 3600), for: nightly.id)
        autoStore.setNextFire(now.addingTimeInterval(4 * 86400), for: store.automationIDs["fullScan"]!)
        autoStore.setNextFire(now.addingTimeInterval(2 * 86400), for: pay.automationIDs["fullScan"]!)

        let fullRun = AutomationRunRecord(automationID: store.automationIDs["fullScan"]!, firedAt: ago(26),
                                          outcome: .launched, detail: "storefront-full-scan-260929-0300",
                                          branchSlug: "storefront-full-scan-260929-0300", completedAt: ago(25))
        let commitRun = AutomationRunRecord(automationID: store.automationIDs["commits"]!, firedAt: ago(3),
                                            outcome: .launched,
                                            detail: "Commit 9f2c1ab: Add CSV export to orders",
                                            branchSlug: "storefront-commits-260930-0612-commit-9f2c1ab",
                                            itemKey: "commit:9f2c1ab", completedAt: ago(2.6))
        let prRun = AutomationRunRecord(automationID: pay.automationIDs["pullRequests"]!, firedAt: ago(1),
                                        outcome: .launched, detail: "PR #412: Refund webhooks",
                                        branchSlug: "payments-pr412", itemKey: "pr:412",
                                        completedAt: ago(0.7))
        let blocked = AutomationRunRecord(automationID: pay.automationIDs["pullRequests"]!, firedAt: ago(5),
                                          outcome: .blocked,
                                          detail: "PR #409 — PromptGuard flagged the text as prompt injection",
                                          itemKey: "pr:409")
        let digest = AutomationRunRecord(automationID: nightly.id, firedAt: ago(10), outcome: .launched,
                                         detail: "dependency-digest-260930-0800", completedAt: ago(9.8))
        for r in [digest, fullRun, blocked, commitRun, prRun] { autoStore.record(r) }

        func add(_ title: String, _ sev: RepoFinding.Severity, _ cat: RepoFinding.Category,
                 _ cwe: String?, _ file: String, _ line: Int, repo: WatchedRepo, run: AutomationRunRecord,
                 seen: Int = 1, age: Double, status: RepoFinding.Status = .new,
                 summary: String? = nil, evidence: String? = nil, rec: String? = nil) -> UUID {
            let r = FindingReport(
                title: title, severity: sev, category: cat, cwe: cwe, file: file, line: line, endLine: nil,
                summary: summary ?? "The value flows from the request into the sink without validation.",
                evidence: evidence, recommendation: rec, fingerprintHint: title, duplicateOf: nil)
            let f = findingStore.ingest(r, watchID: repo.id, profileID: repo.profileID, repo: repo.repo,
                                        runID: run.id, commit: "9f2c1ab4e0", now: ago(age)).finding
            findingStore.mutate(f.id) {
                $0.seenCount = seen
                $0.status = status
                $0.firstSeenAt = ago(age + Double(seen) * 30)
            }
            return f.id
        }
        _ = add("SQL injection in order search", .critical, .security, "CWE-89",
                "src/orders/search.ts", 48, repo: store, run: commitRun, seen: 3, age: 2.6,
                summary: "`GET /api/orders?q=` builds its `WHERE` clause by concatenating `q` into the query string. Any authenticated customer can read **every** order, including other customers' addresses, and the same injection point allows `UNION` reads of the `users` table.",
                evidence: "const rows = await db.query(\n  `SELECT * FROM orders WHERE customer_id = ${user.id} AND note LIKE '%${q}%'`\n);",
                rec: "Use a parameterized query (`db.query(sql, [user.id, `%${q}%`])`) and add a test that a `'` in `q` returns no extra rows.")
        let fixing = add("Stripe webhook signature not verified", .high, .security, "CWE-345",
                         "src/payments/webhook.ts", 12, repo: pay, run: prRun, age: 0.7)
        let task = CodingTask(title: "Fix: Stripe webhook signature not verified", profileID: ws2,
                              stage: .testing)
        taskStore.upsert(task)
        findingStore.mutate(fixing) { $0.taskID = task.id; $0.status = .inReview }
        _ = add("Open redirect after login", .high, .security, "CWE-601",
                "src/auth/callback.ts", 77, repo: store, run: fullRun, seen: 2, age: 25)
        _ = add("Session cookie missing Secure flag", .medium, .security, "CWE-614",
                "src/server/session.ts", 20, repo: store, run: fullRun, age: 25, status: .triaged)
        _ = add("Race on inventory decrement allows overselling", .medium, .bug, nil,
                "src/inventory/reserve.ts", 131, repo: store, run: fullRun, age: 25, status: .inProgress)
        _ = add("Unbounded retry loop on refund failures", .low, .bug, nil,
                "src/payments/refund.ts", 64, repo: pay, run: prRun, age: 0.7)
        _ = add("Hardcoded test API key in fixtures", .low, .security, "CWE-798",
                "test/fixtures/stripe.ts", 3, repo: pay, run: prRun, age: 30, status: .dismissed)
        for (i, t) in ["Path traversal in invoice download", "XSS in product review body",
                       "JWT accepted with alg=none", "Missing rate limit on password reset"].enumerated() {
            _ = add(t, i == 2 ? .critical : .high, .security, nil, "src/legacy/\(i).ts", 10 + i,
                    repo: store, run: fullRun, age: 200 + Double(i) * 20, status: .fixed)
        }
        _ = add("Debug endpoint exposed in production", .medium, .security, "CWE-489",
                "src/routes/debug.ts", 5, repo: store, run: fullRun, age: 25, status: .duplicate)
    }
}
#endif
