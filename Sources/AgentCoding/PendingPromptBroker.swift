import AppKit

// MARK: - Remote decision prompts (fat client)

/// Routes lifecycle decision prompts (storage upgrade, drift reset, compromise
/// wipe, …) to the interface that initiated the action. A locally-initiated
/// launch keeps its NSAlert; a remote-initiated one (fat client, over the
/// control socket) queues the prompt here instead — the client sees it in
/// `/state`'s `pendingPrompts`, renders it as a local alert, and answers via
/// `POST /prompts/{id}/answer`.
///
/// The asking code waits by pumping the main run loop, the same semantics as
/// `NSAlert.runModal()` — dispatch-main work (including the control-socket
/// handler delivering the answer) keeps running. On timeout the prompt
/// resolves to its `fallback` — always the SAFE choice (cancel / not-now),
/// never the destructive one.
@MainActor
final class PendingPromptBroker {
    static let shared = PendingPromptBroker()

    struct Prompt {
        let id: UUID
        let profileID: UUID?
        let title: String
        let message: String
        /// Button labels; the answer is an index into this array.
        let buttons: [String]
        /// Index returned when nobody answers before the timeout.
        let fallback: Int
        var answer: Int?
    }

    private(set) var prompts: [UUID: Prompt] = [:]
    /// When `/state` was last polled — a live fat client polls sub-second, so
    /// a stale value means nobody is listening and `ask` should not wait.
    private var lastPollAt: Date?

    /// Unanswered prompts, for `/state`. Also records the poll so `ask` knows
    /// a client is listening.
    func pendingList() -> [[String: Any]] {
        lastPollAt = Date()
        return prompts.values.filter { $0.answer == nil }.map {
            [
                "id": $0.id.uuidString,
                "profileID": $0.profileID?.uuidString ?? "",
                "title": $0.title,
                "message": $0.message,
                "buttons": $0.buttons,
            ]
        }
    }

    /// Deliver a client's answer. False for unknown/expired prompts or an
    /// out-of-range choice.
    func answer(id: String, choice: Int) -> Bool {
        guard let uuid = UUID(uuidString: id), var p = prompts[uuid], p.answer == nil,
              choice >= 0, choice < p.buttons.count else { return false }
        p.answer = choice
        prompts[uuid] = p
        return true
    }

    /// Queue a prompt and wait for a remote answer. Returns the chosen button
    /// index, or `fallback` after `timeout`. When no client has polled `/state`
    /// recently (nobody is listening — e.g. a local CLI drove the action),
    /// returns `fallback` immediately instead of stalling the caller.
    func ask(profileID: UUID?, title: String, message: String,
             buttons: [String], fallback: Int, timeout: TimeInterval = 180) -> Int {
        guard let poll = lastPollAt, Date().timeIntervalSince(poll) < 10 else { return fallback }
        let p = Prompt(id: UUID(), profileID: profileID, title: title,
                       message: message, buttons: buttons, fallback: fallback)
        prompts[p.id] = p
        defer { prompts[p.id] = nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let a = prompts[p.id]?.answer { return a }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return fallback
    }
}
