import Foundation

/// Who goes first on a fat client's bulk lane: the one SSH connection that
/// carries every transcript read, for the chat on screen as for the ones
/// fetched in the background (preloads, chats kept warm off stage). They
/// share its bandwidth, so on a thin link a preload's 1.5 MB window could
/// stretch the read of the conversation the user just opened to tens of
/// seconds. Background reads now wait while one for the user is on the wire.
@MainActor
final class BulkLanePriority {
    /// Reads for the user under way.
    private(set) var foregroundInFlight = 0
    private var lastForegroundEnd: Date = .distantPast

    /// A chat's read is two requests (locate, then fetch) with a hop to the
    /// main actor between them: that gap isn't a quiet lane.
    nonisolated static let settle: TimeInterval = 0.25
    /// However busy the foreground, a background read goes after this long:
    /// a working agent's chat reads every 0.4 s, and the chats kept warm
    /// mustn't go stale for good.
    nonisolated static let maxWait: TimeInterval = 20
    nonisolated static let pollInterval: UInt64 = 100_000_000

    /// Below this rate a preload (a 1.5 MB window) takes over 6 s, all of it
    /// in the way of whatever the user opens next: none then.
    nonisolated static let preloadMinBytesPerSecond: Double = 256 * 1024

    var foregroundBusy: Bool { Self.busy(inFlight: foregroundInFlight, lastEnd: lastForegroundEnd, now: Date()) }

    nonisolated static func busy(inFlight: Int, lastEnd: Date, now: Date) -> Bool {
        inFlight > 0 || now.timeIntervalSince(lastEnd) < settle
    }

    /// Whether a link measured at `bytesPerSecond` can spare a preload. No
    /// measurement yet: yes, as before.
    nonisolated static func preloadAffordable(bytesPerSecond: Double?) -> Bool {
        guard let bytesPerSecond else { return true }
        return bytesPerSecond >= preloadMinBytesPerSecond
    }

    /// Run a read for the user.
    func foreground<T>(_ work: () async -> T) async -> T {
        foregroundInFlight += 1
        defer {
            foregroundInFlight -= 1
            lastForegroundEnd = Date()
        }
        return await work()
    }

    /// Wait for the lane to be free of the user's reads (or `maxWait`), before
    /// a background read. Throws `CancellationError` when the reader was
    /// cancelled (its chat reopened or gone), before or during the wait: it
    /// returned normally, and the read it held back then went out anyway --
    /// a transcript window over the lane for a chat nobody was reading.
    func waitForQuiet() async throws {
        let start = Date()
        try Task.checkCancellation()
        while foregroundBusy, Date().timeIntervalSince(start) < Self.maxWait {
            try await Task.sleep(nanoseconds: Self.pollInterval)
        }
        try Task.checkCancellation()
    }
}
