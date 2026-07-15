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
    /// a stale value means nobody is listening. Kept in a lock-protected static
    /// (not just on the main actor) because the MITM consent brokers ask,
    /// off-main from their actors, whether a fat client is watching — see
    /// `hasLiveListener()`.
    private static let pollLock = NSLock()
    nonisolated(unsafe) private static var lastPollAt: Date?
    /// A recent `/state` poll means a fat client is watching, so consent
    /// prompts should route to its NSAlert. Window matches `ask`'s own guard.
    private static let listenerWindow: TimeInterval = 10

    private static func recordPoll() {
        pollLock.lock(); lastPollAt = Date(); pollLock.unlock()
    }

    /// True when a fat client polled `/state` within the last few seconds — a
    /// rich GUI client is connected and can render a consent NSAlert on its
    /// own screen. Thread-safe: the MITM consent brokers call this from their
    /// actors to decide between a fat-client alert and a tmux popup.
    nonisolated static func hasLiveListener() -> Bool {
        pollLock.lock(); defer { pollLock.unlock() }
        guard let t = lastPollAt else { return false }
        return Date().timeIntervalSince(t) < listenerWindow
    }

    /// Unanswered prompts, for `/state`. Also records the poll so `ask` and
    /// `hasLiveListener` know a client is listening.
    func pendingList() -> [[String: Any]] {
        Self.recordPoll()
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
        guard Self.hasLiveListener() else { return fallback }
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

    /// Async twin of `ask`, for the MITM consent path where prompts fire
    /// autonomously and CONCURRENTLY (four independent broker actors). It waits
    /// by suspending on `Task.sleep` rather than pumping `RunLoop.main.run`, so:
    ///  • concurrent consents don't nest main-thread run loops (the sync `ask`
    ///    pump can only unwind LIFO, which would withhold an already-answered
    ///    prompt behind an unrelated open one); each `askAsync` yields the main
    ///    actor between polls, so every waiter observes its own answer at once.
    ///  • it fails fast (~within the listener window) if the fat client stops
    ///    polling `/state` — the client disconnected — instead of stalling the
    ///    whole timeout, mirroring how the tmux consent gate denies on detach.
    /// The sync `ask` above stays for the lifecycle prompts, which are user-
    /// initiated, sequential, and called from synchronous @MainActor code.
    func askAsync(profileID: UUID?, title: String, message: String,
                  buttons: [String], fallback: Int, timeout: TimeInterval = 120) async -> Int {
        guard Self.hasLiveListener() else { return fallback }
        let id = UUID()
        prompts[id] = Prompt(id: id, profileID: profileID, title: title,
                             message: message, buttons: buttons, fallback: fallback)
        defer { prompts[id] = nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let a = prompts[id]?.answer { return a }
            if !Self.hasLiveListener() { return fallback }   // client gone → fail fast
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s; yields the main actor
        }
        return fallback
    }
}
