import AppKit
import SwiftUI
import Testing
@testable import bromure_ac

/// Board: a coding task's question opened in an alert — a sliver of the
/// question and a one-line field to answer in. It's now a sheet: the whole
/// question (markdown, selectable, scrolling) above a multi-line editor.
@Suite("Coding tasks: the answer sheet has room to read and write", .serialized)
@MainActor
struct TaskAnswerSheetTests {
    private func question() -> String {
        """
        Before I change the retry policy I need two decisions:

        - Should a 429 from the upstream count toward the circuit breaker, or only 5xx?
        - The current backoff caps at 30 s. Keep it, or raise it to 120 s for the batch jobs?

        Context: the batch importer retries 40 times in a burst and trips the breaker for every \
        other client. I can make the breaker per-client instead, which is a larger change.
        """
    }

    private func task() -> CodingTask {
        var t = CodingTask(title: "Retry policy for the importer", profileID: UUID(), tool: .claude)
        t.assignment = TaskAssignment(kind: .session, id: UUID(), label: "@importer")
        t.pendingQuestion = question()
        return t
    }

    @Test("the sheet is a roomy window with a multi-line editor")
    func roomySheet() throws {
        _ = NSApplication.shared
        var sent: [String] = []
        var reply = ""
        let binding = Binding(get: { reply }, set: { reply = $0 })
        let host = NSHostingView(rootView: TaskAnswerSheet(task: task(), reply: binding,
                                                           onSend: { sent.append($0) }, onCancel: {}))
        let size = host.fittingSize
        #expect(size.width >= 560, "sheet \(size.width) wide")
        #expect(size.height >= 480, "sheet \(size.height) tall")

        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let editors = textViews(in: host).filter(\.isEditable)
        let editor = try #require(editors.first)
        #expect(editor.frame.height >= 120, "answer editor \(editor.frame.height) tall")
        #expect(editor.frame.width >= 480, "answer editor \(editor.frame.width) wide")

        if let out = ProcessInfo.processInfo.environment["TASK_ANSWER_SHOT"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        #expect(sent.isEmpty)
    }

    /// Finding (CWE-670): "Coding-task answer draft is delivered to a later
    /// question" — a draft kept after Esc (or typed while the agent's ask
    /// timed out and it asked again) went to whatever question the card had
    /// when Send was clicked.
    @Test("a draft written for one question isn't sent to the next")
    func draftFollowsItsQuestion() {
        let first = UUID(), second = UUID()
        var draft = TaskAnswerDraft()
        #expect(!draft.canSend(to: first))
        draft.edit("Only 5xx; keep 30 s.", for: first)
        #expect(draft.canSend(to: first) && !draft.isStale(for: first))
        // The agent asks again: the draft is for the earlier question.
        #expect(draft.isStale(for: second))
        #expect(!draft.canSend(to: second))
        #expect(draft.askID == first)
        // Edited with the new question on screen, it's an answer to it.
        draft.edit("Only 5xx; keep 30 s. Per-client breaker: yes.", for: second)
        #expect(draft.canSend(to: second) && draft.askID == second)
        // Nothing asked any more: nothing to send to.
        #expect(!draft.canSend(to: nil))
    }

    /// Finding (CWE-670): "A successful task answer leaves the stale-ask
    /// error on the card" — the answer that then went cleared the question
    /// but not the note, and the card (saved) kept saying it didn't go.
    @Test("an answer that goes clears what an earlier try put on the card, and nothing else")
    func answerClearsItsOwnError() {
        var t = task()
        t.lastError = TaskDispatcher.staleAnswerText
        TaskDispatcher.clearAnswerError(&t)
        #expect(t.lastError == nil)
        // A refused delivery's reason, saved with the task — after a
        // relaunch too (the task round-trips through its file).
        t.lastError = "No question is waiting for an answer."
        t.answerRefusal = t.lastError
        var saved = try! JSONDecoder().decode(CodingTask.self, from: JSONEncoder().encode(t))
        TaskDispatcher.clearAnswerError(&saved)
        #expect(saved.lastError == nil && saved.answerRefusal == nil)
        // The assignee's own trouble stays, also when it replaced a refusal.
        t.lastError = "@importer's session went away."
        TaskDispatcher.clearAnswerError(&t)
        #expect(t.lastError == "@importer's session went away.")
        #expect(t.answerRefusal == nil)
        // A task file from before the field: decodes, nothing to clear.
        var legacy = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(task())) as! [String: Any]
        legacy.removeValue(forKey: "answerRefusal")
        let old = try! JSONDecoder().decode(CodingTask.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.answerRefusal == nil)
    }

    /// Finding (CWE-362): "A later task-answer success clears a newer
    /// attempt's refusal". An older answer still being delivered finished
    /// after a newer one was withheld, and erased that refusal.
    @Test("a success clears only what was on the card when it started")
    func successKeepsANewerRefusal() {
        var t = task()
        t.lastError = TaskDispatcher.staleAnswerText          // an earlier try's note
        let seen = TaskDispatcher.AnswerErrorSnapshot(t)
        // While this answer is delivered, a newer one is withheld.
        let withheld = "Your message was withheld: it reads like a prompt injection (“ignore all previous”)."
        t.lastError = withheld
        t.answerRefusal = withheld
        TaskDispatcher.clearAnswerError(&t, seen: seen)
        #expect(t.lastError == withheld && t.answerRefusal == withheld)
        // The refusal this try saw goes; one stored since stays.
        t.lastError = "No question is waiting for an answer."
        t.answerRefusal = t.lastError
        let seen2 = TaskDispatcher.AnswerErrorSnapshot(t)
        t.answerRefusal = withheld; t.lastError = withheld
        TaskDispatcher.clearAnswerError(&t, seen: seen2)
        #expect(t.lastError == withheld && t.answerRefusal == withheld)
        // Unchanged since it started: cleared, as before.
        TaskDispatcher.clearAnswerError(&t, seen: TaskDispatcher.AnswerErrorSnapshot(t))
        #expect(t.lastError == nil && t.answerRefusal == nil)
    }

    @Test("the board answers only the question the answer was written for, and clears only that one")
    func answerTargetsItsAsk() {
        let first = UUID(), second = UUID()
        var t = task()
        t.pendingAskID = second                       // asked again since
        #expect(TaskDispatcher.answerTarget(t, writtenFor: first) == nil)
        #expect(TaskDispatcher.answerTarget(t, writtenFor: second) == second)
        #expect(TaskDispatcher.answerTarget(t, writtenFor: nil) == second)
        // The answer to the first came back after the second was asked.
        TaskDispatcher.clearAnswered(&t, ask: first)
        #expect(t.pendingAskID == second && t.pendingQuestion != nil)
        TaskDispatcher.clearAnswered(&t, ask: second)
        #expect(t.pendingAskID == nil && t.pendingQuestion == nil)
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews(in:))
    }
}

/// Finding (CWE-362): "Sending a task answer drops the draft before the
/// dispatcher accepts it" — Send cleared the draft and closed the sheet,
/// then the answer was handed over (a scheduled Task here, a POST answered
/// `ok` before its Task ran over the fat client); a refusal (the agent asked
/// again in the gap, the question was gone) lost the text.
@Suite("Coding tasks: an answer is gone only once the board took it")
struct TaskAnswerSendTests {
    @Test("a refused answer keeps its text; a taken one clears, unless edited meanwhile")
    func draftAfterSend() {
        let ask = UUID()
        var draft = TaskAnswerDraft()
        draft.edit("Only 5xx.", for: ask)
        let sent = draft
        #expect(draft.afterSend(sent, accepted: false) == sent)
        #expect(draft.afterSend(sent, accepted: true) == TaskAnswerDraft())
        draft.edit("Only 5xx. And keep 30 s.", for: ask)          // typed on while it went
        #expect(draft.afterSend(sent, accepted: true) == draft)
    }

    @Test("the answer route replies with the board's verdict, after it has one")
    func routeWaitsForTheVerdict() {
        let t0 = Date()
        let refused = ACAutomationServer.awaitTaskAnswer({ _, body in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return ["ok": false, "error": "The agent asked a new question before your answer went."]
        }, id: UUID(), body: ["text": "x"])
        #expect(Date().timeIntervalSince(t0) >= 0.25)
        #expect(refused["ok"] as? Bool == false)
        #expect(RemoteHostController.answerAccepted(refused) == false)
        let taken = ACAutomationServer.awaitTaskAnswer({ _, _ in ["ok": true] }, id: UUID(), body: [:])
        #expect(RemoteHostController.answerAccepted(taken))
        // The link failed: not taken. A server from before the wait: `{ok: true}`, as ever.
        #expect(!RemoteHostController.answerAccepted(nil))
        #expect(RemoteHostController.answerAccepted(["ok": true]))
        #expect(RemoteHostController.answerAccepted(["ok": true, "stage": "working"]))
        // Finding (CWE-754): a 200 whose body was lost or cut off is `[:]` —
        // the verdict is unknown, the draft stays. So does any reply without
        // a boolean `ok`.
        #expect(!RemoteHostController.answerAccepted([:]))
        #expect(!RemoteHostController.answerAccepted(["stage": "working"]))
        #expect(!RemoteHostController.answerAccepted(["ok": "true"]))
        #expect(!RemoteHostController.answerAccepted(["ok": 1]))
    }

    /// Finding (CWE-362): "Refused task answers read the task store off the
    /// main actor". The route's handler is typed @MainActor now, so it runs
    /// there whatever context the closure is written in; the store read for a
    /// refusal's reason can't leave it.
    @Test("the answer handler runs on the main actor, called from a connection thread")
    func answerHandlerIsMainActor() async {
        final class Seen: @unchecked Sendable { var main = false; var error: String? }
        let seen = Seen()
        let handler: @MainActor (UUID, [String: Any]) async -> [String: Any] = { _, _ in
            await Task.yield()
            seen.main = Thread.isMainThread
            return ["ok": false, "error": "refused"]
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                seen.error = ACAutomationServer.awaitTaskAnswer(handler, id: UUID(), body: ["text": "x"])["error"] as? String
                done.resume()
            }
        }
        #expect(seen.main)
        #expect(seen.error == "refused")
    }
}
