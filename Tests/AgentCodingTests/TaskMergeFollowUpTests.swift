import Foundation
import Testing
@testable import bromure_ac

/// "Coding tasks → Merge: 3 issues": a merge from a fat client that did
/// nothing, a question asked while landing that couldn't be answered from
/// the card, and checkouts left behind after a merge.
@Suite("Merging a task: the request, the question, the checkout")
struct TaskMergeFollowUpTests {
    // MARK: The checkout and branch after a verified merge

    private func sh(_ c: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", c]
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@t"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@t"
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// A repository with a task worktree on `wt/fix` at `<tmp>/wt fix` (a
    /// space in the path on purpose), its commit merged into main.
    private func repo() -> (root: String, wt: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-followup-\(UUID().uuidString)").path
        let root = base + "/repo", wt = base + "/wt fix"
        _ = sh("mkdir -p '\(root)' && cd '\(root)' && git init -q -b main && echo a > a && git add a "
               + "&& git commit -qm a && git worktree add -q -b wt/fix '\(wt)' && cd '\(wt)' && echo b > b "
               + "&& git add b && git commit -qm b && cd '\(root)' && git merge -q --ff-only wt/fix")
        return (root, wt)
    }

    private func branchExists(_ root: String, _ b: String) -> Bool {
        sh("git -C '\(root)' rev-parse -q --verify 'refs/heads/\(b)' >/dev/null && echo yes").contains("yes")
    }

    @Test("a clean checkout and its branch are removed")
    func removesClean() {
        let (root, wt) = repo()
        let out = sh(CodingTaskEngine.removeCheckoutCommand(root: root, branch: "wt/fix"))
        #expect(out.contains("REMOVED"))
        #expect(!FileManager.default.fileExists(atPath: wt))
        #expect(!branchExists(root, "wt/fix"))
        #expect(sh(CodingTaskEngine.branchGoneCommand(root: root, branch: "wt/fix")).contains("GONE"))
    }

    @Test("a locked checkout holding only build litter is removed too")
    func removesLockedWithLitter() {
        let (root, wt) = repo()
        _ = sh("git -C '\(root)' worktree lock '\(wt)' && mkdir -p '\(wt)/__pycache__' && touch '\(wt)/__pycache__/x.pyc'")
        let out = sh(CodingTaskEngine.removeCheckoutCommand(root: root, branch: "wt/fix"))
        #expect(out.contains("REMOVED"))
        #expect(!FileManager.default.fileExists(atPath: wt))
    }

    @Test("work written after the landing keeps the checkout and the branch")
    func keepsDirty() {
        let (root, wt) = repo()
        _ = sh("echo late > '\(wt)/late.txt'")
        let out = sh(CodingTaskEngine.removeCheckoutCommand(root: root, branch: "wt/fix"))
        #expect(out.contains("KEPT-DIRTY"))
        #expect(FileManager.default.fileExists(atPath: wt + "/late.txt"))
        #expect(branchExists(root, "wt/fix"))
        #expect(sh(CodingTaskEngine.branchGoneCommand(root: root, branch: "wt/fix")).isEmpty)
    }

    @Test("a branch checked out in the main checkout is never removed")
    func keepsMain() {
        let (root, wt) = repo()
        _ = sh("git -C '\(root)' worktree remove --force '\(wt)' && git -C '\(root)' checkout -q wt/fix")
        let out = sh(CodingTaskEngine.removeCheckoutCommand(root: root, branch: "wt/fix"))
        #expect(out.contains("KEPT-MAIN"))
        #expect(FileManager.default.fileExists(atPath: root + "/a"))
        #expect(branchExists(root, "wt/fix"))
    }

    @Test("a checkout already gone: the branch still goes")
    func branchOnly() {
        let (root, wt) = repo()
        _ = sh("git -C '\(root)' worktree remove --force '\(wt)'")
        #expect(sh(CodingTaskEngine.removeCheckoutCommand(root: root, branch: "wt/fix")).contains("REMOVED"))
        #expect(!branchExists(root, "wt/fix"))
    }

    @Test("a verified merge removes the checkout — a delegated task's too; kept, a PR or unverified: not")
    func removesCheckoutPolicy() {
        let merge = TaskLanding(mode: .merge, target: "main", phase: .landed, startedAt: Date())
        #expect(CodingTaskEngine.removesCheckout(merge, verified: true))
        #expect(!CodingTaskEngine.removesCheckout(merge, verified: false))
        var kept = merge; kept.keepBranch = true
        #expect(!CodingTaskEngine.removesCheckout(kept, verified: true))
        let pr = TaskLanding(mode: .pr, target: "main", phase: .landed, startedAt: Date())
        #expect(!CodingTaskEngine.removesCheckout(pr, verified: true))
    }

    @Test("the Done card says what became of the branch and checkout")
    func doneSuffix() {
        var t = CodingTask(title: "x", profileID: UUID())
        t.stage = .done
        t.completion = .merged(target: "main", verified: true, by: nil)
        #expect(TaskLandingText.done(t) == "Merged into main")
        t.checkoutRemoved = true
        #expect(TaskLandingText.done(t) == "Merged into main · branch and checkout removed")
        t.checkoutRemoved = false
        #expect(TaskLandingText.done(t) == "Merged into main · branch and checkout kept")
    }

    // MARK: A question asked while landing

    private func landing(_ t: inout CodingTask, detail: String, lead: UUID? = nil) {
        t.stage = .testing
        var l = TaskLanding(mode: .merge, target: "main", phase: .needsYou,
                            startedAt: Date(timeIntervalSinceNow: -3600))
        l.detail = detail
        l.batchLead = lead
        t.landing = l
    }

    @Test("answering the landing's question puts it back to landing, its stall clock restarted")
    func answerResumes() {
        var t = CodingTask(title: "x", profileID: UUID())
        landing(&t, detail: "Which remote?")
        let now = Date()
        #expect(CodingTaskEngine.resumeAfterAnswer(&t, question: "Which remote?", lead: t.id, now: now))
        #expect(t.landing?.phase == .agentLanding)
        #expect(t.landing?.detail == nil)
        #expect(t.landing?.startedAt == now)
    }

    @Test("a card stuck for another reason, or another batch's, stays on Needs you")
    func answerLeavesOthers() {
        var stalled = CodingTask(title: "x", profileID: UUID())
        landing(&stalled, detail: "The agent stopped.")
        #expect(!CodingTaskEngine.resumeAfterAnswer(&stalled, question: "Which remote?", lead: stalled.id))
        #expect(stalled.landing?.phase == .needsYou)

        let lead = UUID()
        var peer = CodingTask(title: "y", profileID: UUID())
        landing(&peer, detail: "Which remote?", lead: lead)
        var stranger = CodingTask(title: "z", profileID: UUID())
        landing(&stranger, detail: "Which remote?", lead: UUID())
        #expect(CodingTaskEngine.resumeAfterAnswer(&peer, question: "Which remote?", lead: lead))
        #expect(!CodingTaskEngine.resumeAfterAnswer(&stranger, question: "Which remote?", lead: lead))
        #expect(stranger.landing?.phase == .needsYou)
    }

    // MARK: The Merge request from a client

    @Test("the host refuses a Merge only when nothing would start; a resend of one that did is fine")
    func landRefusal() {
        var review = CodingTask(title: "x", profileID: UUID()); review.stage = .testing
        var merged = CodingTask(title: "x", profileID: UUID()); merged.stage = .done
        merged.completion = .merged(target: "main", verified: true, by: nil)
        var closed = CodingTask(title: "x", profileID: UUID()); closed.stage = .done
        closed.completion = .closedWithoutMerge
        var backlog = CodingTask(title: "x", profileID: UUID()); backlog.stage = .backlog
        #expect(CodingTaskEngine.landRefusal([review]) == nil)
        #expect(CodingTaskEngine.landRefusal([merged]) == nil)
        #expect(CodingTaskEngine.landRefusal([backlog, review]) == nil)
        #expect(CodingTaskEngine.landRefusal([closed]) != nil)
        #expect(CodingTaskEngine.landRefusal([backlog]) != nil)
        #expect(CodingTaskEngine.landRefusal([nil]) != nil)
    }

    #if os(macOS)
    @Test("the client tells the user when a Merge didn't go, or was refused")
    @MainActor
    func landingFailure() {
        #expect(RemoteHostWindow.landingFailure(status: 200, json: ["ok": true]) == nil)
        #expect(RemoteHostWindow.landingFailure(status: 200, json: [:]) == nil)
        #expect(RemoteHostWindow.landingFailure(status: nil, json: [:]) != nil)
        #expect(RemoteHostWindow.landingFailure(status: 400, json: ["ok": false, "error": "nope"]) == "nope")
        #expect(RemoteHostWindow.landingFailure(status: 200, json: ["ok": false, "error": "nope"]) == "nope")
        #expect(RemoteHostWindow.landingFailure(status: 500, json: [:])?.contains("500") == true)
    }

    @Test("a sent landing request that got no answer is sent once more")
    func resendsUnanswered() {
        var calls = 0
        let r: Int? = RemoteHostController.sendResendingUnanswered(true, label: "t", delay: 0) {
            calls += 1; return calls == 2 ? 200 : nil
        }
        #expect(r == 200)
        #expect(calls == 2)
    }
    #endif

    @Test("a card's own items go first in its menu, ids by position")
    func menuPrepending() {
        let menu = CardMenuItem.list([.init(title: "A"), .divider, .init(title: "B")])
        let all = CardMenuItem.prepending([.init(title: "Answer…"), .divider], to: menu)
        #expect(all.map(\.title) == ["Answer…", "", "A", "", "B"])
        #expect(all.map(\.id) == Array(0..<5))
    }
}
