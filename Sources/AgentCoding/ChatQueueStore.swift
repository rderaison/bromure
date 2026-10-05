import Combine
import Foundation

/// The messages a chat holds while its agent is busy (`QueuedMessage`),
/// kept apart from the chat's view model: a session switch tears the model
/// down and builds a fresh one on the way back, and the queue used to go
/// with the old one — a held message was never typed, and nothing said so.
///
/// Keyed like the composer drafts (`BeautifiedSessionModel.draftKey`: the
/// machine and tab the chat is for). Every chat showing a key reads the
/// same list; the most recent one shown delivers (its richer idle signal
/// and its echo). With none shown, the store delivers on its own: it
/// watches the agent's status through the last chat's provider and types
/// the held messages in once the agent has been idle a moment — through
/// the guarded path (window identity, an agent in front, no menu open). A
/// message that can't be typed there stays, marked with why, until the
/// user edits or drops it. Persisted, so a relaunch doesn't drop it either.
@MainActor
final class ChatQueueStore: ObservableObject {
    /// What one delivery attempt did.
    enum Outcome: Equatable {
        case typed
        /// A menu or dialog is up in the tab: try again later.
        case held
        /// The machine didn't answer: try again later.
        case unreachable
        /// The tab is gone or someone else's, or no agent holds it: nothing
        /// was typed, and the message is marked with why.
        case refused(PaneRefusal)
        /// The typing command ran but didn't go through (tmux refused it):
        /// marked "Not sent", for the user to edit or drop.
        case failed

        /// What a guarded type's output (`PaneTypeGuard.typeCommand`) says.
        /// Only its success marker counts as typed.
        static func of(_ out: String?) -> Outcome {
            guard let out else { return .unreachable }
            if let r = PaneTypeGuard.refusal(in: out) { return .refused(r) }
            if PaneTypeGuard.held(in: out) { return .held }
            return PaneTypeGuard.typed(in: out) ? .typed : .failed
        }
    }

    /// A message whose typing failed.
    nonisolated static var notTypedText: String {
        NSLocalizedString("Not sent — typing it into the session failed. Edit it or send it again.",
                          comment: "queued message: the typing command failed")
    }

    /// How the store reaches a chat's agent while no chat is shown.
    struct Driver {
        /// Whether the agent is working (nil: can't tell right now).
        var isWorking: @MainActor () -> Bool?
        /// Type `text` into `target`, guarded.
        var deliver: @MainActor (_ text: String, _ target: PaneTarget) async -> Outcome
    }

    static let shared = ChatQueueStore(fileURL: ChatQueueStore.defaultFileURL())

    @Published private(set) var queues: [String: [QueuedMessage]] = [:]

    /// Seconds between status checks while delivering in the background.
    var pollInterval: TimeInterval = 1.0
    /// How long the agent must have been idle before a held message is typed
    /// (the status can blink idle between two requests of one turn).
    var idleBeforeDelivery: TimeInterval = 3.0
    /// A background delivery that can't read the agent's status this long
    /// stops; the messages stay (persisted) for the chat to deliver.
    var giveUpAfter: TimeInterval = 600

    private let fileURL: URL?
    /// The chats showing each key, newest last (weak: a chat dropped
    /// without `detach` doesn't hold the key forever).
    private final class Owner { weak var object: AnyObject?; init(_ o: AnyObject) { object = o } }
    private var ownerLists: [String: [Owner]] = [:]
    private func liveOwners(_ key: String) -> [Owner] {
        let live = (ownerLists[key] ?? []).filter { $0.object != nil }
        ownerLists[key] = live.isEmpty ? nil : live
        return live
    }
    private var drivers: [String: Driver] = [:]
    private var drains: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    /// The app's queue file — none in a test run, which must never write
    /// the user's.
    private static func defaultFileURL() -> URL? {
        let testing = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !testing else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("chat-queue.json")
    }

    // MARK: The lists

    func messages(_ key: String) -> [QueuedMessage] { queues[key] ?? [] }

    func update(_ key: String, _ change: (inout [QueuedMessage]) -> Void) {
        var list = messages(key)
        let before = list
        change(&list)
        guard list != before else { return }
        queues[key] = list.isEmpty ? nil : list
        if list.isEmpty, liveOwners(key).isEmpty { drivers[key] = nil }
        save()
        considerDrain(key)
    }

    /// Held here, not typed yet, nothing wrong with it, nobody typing it.
    nonisolated static func deliverable(_ q: QueuedMessage) -> Bool {
        q.held && q.failure == nil && !q.sending
    }

    /// The held message to type next: the oldest deliverable one, and
    /// none while an earlier one is still being typed (order is kept).
    nonisolated static func nextHeld(_ list: [QueuedMessage]) -> QueuedMessage? {
        guard !list.contains(where: { $0.held && $0.sending }) else { return nil }
        return list.first(where: deliverable)
    }

    /// Every message written in session `id`, wherever it's keyed (a
    /// paused session's view lists them).
    func messages(session id: UUID) -> [(key: String, message: QueuedMessage)] {
        queues.keys.sorted().flatMap { key in
            (queues[key] ?? []).filter { $0.sessionID == id }.map { (key, $0) }
        }
    }

    /// Drop one message, wherever it's keyed.
    func remove(_ messageID: UUID) {
        for key in queues.keys where queues[key]?.contains(where: { $0.id == messageID }) == true {
            update(key) { $0.removeAll { $0.id == messageID } }
        }
    }

    /// The session's chat is `key` now (it came back, maybe in another
    /// tab): its messages kept under other keys move here, aimed at the
    /// chat's window — and a "the tab is gone" mark from the old one goes.
    func adopt(session id: UUID, into key: String, target: PaneTarget) {
        let mine: (QueuedMessage) -> Bool = { $0.sessionID == id && !$0.sending && ($0.held || $0.failure != nil) }
        let others = queues.keys.filter { k in k != key && queues[k]?.contains(where: mine) == true }
        guard !others.isEmpty else { return }
        let stale = Set([PaneRefusal.gone, .identity, .shell, .agent].map(Self.failureText))
        var moved: [QueuedMessage] = []
        for k in others.sorted() {
            update(k) { l in
                moved += l.filter(mine)
                l.removeAll(where: mine)
            }
        }
        update(key) { l in
            for var q in moved.sorted(by: { $0.queuedAt < $1.queuedAt }) {
                q.target = target
                q.held = true
                q.editable = true
                if let f = q.failure, stale.contains(f) { q.failure = nil }
                l.append(q)
            }
        }
    }

    // MARK: Who delivers

    /// A chat shows `key`: it delivers from now on (the newest shown wins)
    /// and the background delivery stands down. `driver` is kept for when
    /// no chat shows the key any more.
    func attach(_ key: String, owner: AnyObject, driver: Driver?) {
        var list = liveOwners(key).filter { $0.object !== owner }
        list.append(Owner(owner))
        ownerLists[key] = list
        if let driver { drivers[key] = driver }
        if let d = drains.removeValue(forKey: key) { d.task.cancel() }
    }

    /// The chat's driver changed (its window became known).
    func setDriver(_ key: String, _ driver: Driver) {
        drivers[key] = driver
    }

    /// The chat is gone (switched away, closed): another one showing the key
    /// takes over, else the store delivers in the background.
    func detach(_ key: String, owner: AnyObject) {
        let list = liveOwners(key).filter { $0.object !== owner }
        ownerLists[key] = list.isEmpty ? nil : list
        considerDrain(key)
    }

    func isOwner(_ key: String, _ owner: AnyObject) -> Bool {
        liveOwners(key).last?.object === owner
    }

    /// Whether the store is delivering `key` in the background (debug/tests).
    func isDraining(_ key: String) -> Bool { drains[key] != nil }

    // MARK: Delivery

    /// Type the oldest deliverable held message of `key` into the agent —
    /// ONE message: each is its own turn, as the user wrote it (two held
    /// ones used to go in merged, "3\n\n4"). The next waits for the agent
    /// to be done with this one (the callers' idle guard). The target is
    /// the one captured when it was queued, else `fallback`. Typed: it
    /// leaves the queue. Refused: it stays, marked with why. Held or
    /// unreachable: it stays for the next try. nil: nothing to deliver.
    @discardableResult
    func deliverHeld(_ key: String, driver: Driver, fallback: PaneTarget?) async -> Outcome? {
        let batch = Self.nextHeld(messages(key)).map { [$0] } ?? []
        guard let target = batch.first?.target ?? fallback else { return nil }
        let ids = Set(batch.map(\.id))
        update(key) { l in for i in l.indices where ids.contains(l[i].id) { l[i].sending = true } }
        let outcome = await driver.deliver(batch.map(\.text).joined(separator: "\n\n"), target)
        update(key) { l in
            switch outcome {
            case .typed:
                l.removeAll { ids.contains($0.id) }
            case .held:
                // A menu or dialog is up in the tab: it waits for the user
                // to answer it (said on its row).
                for i in l.indices where ids.contains(l[i].id) {
                    l[i].sending = false
                    l[i].awaitingAnswer = true
                }
            case .unreachable:
                for i in l.indices where ids.contains(l[i].id) { l[i].sending = false }
            case .failed:
                for i in l.indices where ids.contains(l[i].id) {
                    l[i].sending = false
                    l[i].failure = Self.notTypedText
                }
            case .refused(let r):
                for i in l.indices where ids.contains(l[i].id) {
                    l[i].sending = false
                    l[i].failure = Self.failureText(r)
                }
            }
        }
        return outcome
    }

    /// Why a held message wasn't typed, for its row in the queue strip.
    nonisolated static func failureText(_ r: PaneRefusal) -> String {
        switch r {
        case .gone, .identity:
            return NSLocalizedString(
                "Not sent — the session's tab is gone or now belongs to something else.",
                comment: "queued message: delivery refused")
        case .shell, .agent:
            return NSLocalizedString(
                "Not sent — the agent isn't running in the session's tab any more.",
                comment: "queued message: delivery refused")
        }
    }

    private func considerDrain(_ key: String) {
        guard liveOwners(key).isEmpty, drains[key] == nil, drivers[key] != nil,
              messages(key).contains(where: Self.deliverable) else { return }
        let token = UUID()
        let task = Task { [weak self] in
            await self?.drain(key)
            guard let self, self.drains[key]?.token == token else { return }
            self.drains[key] = nil
        }
        drains[key] = (token, task)
    }

    /// Off screen: wait for the agent to go idle, then type the held
    /// messages in — until none is left, a chat shows the key again, or the
    /// status can't be read for `giveUpAfter`.
    private func drain(_ key: String) async {
        var idleSince: Date?
        var blindSince: Date?
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, pollInterval) * 1_000_000_000))
            if Task.isCancelled || !liveOwners(key).isEmpty { return }
            guard messages(key).contains(where: Self.deliverable), let driver = drivers[key] else { return }
            let now = Date()
            guard let working = driver.isWorking() else {
                idleSince = nil
                if blindSince == nil { blindSince = now }
                if now.timeIntervalSince(blindSince!) > giveUpAfter { return }
                continue
            }
            blindSince = nil
            if working { idleSince = nil; continue }
            if idleSince == nil { idleSince = now }
            guard now.timeIntervalSince(idleSince!) >= idleBeforeDelivery else { continue }
            let outcome = await deliverHeld(key, driver: driver, fallback: nil)
            if case .refused? = outcome { return }
            if outcome == .failed { return }
            // Typed: the next batch (if any came in) waits for the next idle.
            if outcome == .typed { idleSince = nil }
        }
    }

    // MARK: Persistence

    private struct Saved: Codable { var queues: [String: [QueuedMessage]] }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        queues = Self.restored(saved.queues)
    }

    /// What survives a relaunch: held messages (and failed ones, to be seen)
    /// up to a week old; a message in the agent's own queue only shortly —
    /// it is the agent's by then. Nothing is mid-send after a relaunch.
    nonisolated static func restored(_ queues: [String: [QueuedMessage]], now: Date = Date())
        -> [String: [QueuedMessage]] {
        var out: [String: [QueuedMessage]] = [:]
        for (key, list) in queues {
            let kept = list.compactMap { q -> QueuedMessage? in
                let age = now.timeIntervalSince(q.queuedAt)
                guard age < 7 * 86_400, q.held || age < 3_600 else { return nil }
                var q = q
                q.sending = false
                return q
            }
            if !kept.isEmpty { out[key] = kept }
        }
        return out
    }

    private func save() {
        guard let fileURL else { return }
        // A chat with no home (demo, bench) keeps its queue in memory only.
        let persisted = queues.filter { !$0.key.hasPrefix(Self.ephemeralPrefix) }
        guard let data = try? JSONEncoder().encode(Saved(queues: persisted)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Keys under this prefix are never written to disk.
    nonisolated static let ephemeralPrefix = "ephemeral:"
}
