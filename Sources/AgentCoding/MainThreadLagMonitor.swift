import Foundation

/// Measures how late the main queue runs a job, and logs the stalls.
///
/// The main queue is where Virtualization.framework delivers every guest's
/// vsock connections (the proxy, ssh-agent, AWS credentials): a main thread
/// busy for a second is a second every new guest connection waits to be
/// accepted, and agentd's bridge in the guest gives up on a connect after
/// its deadline. A stall here is the host-side half of a guest's "slow
/// connect" line in /tmp/bromure-vm-bridge.log; both carry UTC timestamps.
///
/// A background timer posts a job to main every `interval` and times how
/// long it waited. Stalls at or over `threshold` are summarized at most once
/// per `reportEvery` (count and worst), so a wedged main thread logs a line,
/// not a flood.
final class MainThreadLagMonitor: @unchecked Sendable {
    static let shared = MainThreadLagMonitor()

    let interval: TimeInterval
    let threshold: TimeInterval
    let reportEvery: TimeInterval

    private let queue = DispatchQueue(label: "io.bromure.ac.main-lag", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// One probe in flight at a time: a wedged main thread is one long
    /// stall, measured when it ends, not a pile of queued probes.
    private var probing = false
    private var stats = Stats()
    private var lastReport = Date.distantPast
    private static let utc: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Stalls seen since the last report. Queue-confined.
    struct Stats: Equatable {
        var count = 0
        var worst: TimeInterval = 0
        /// When the first of them ended.
        var since: Date?

        mutating func note(_ lag: TimeInterval, threshold: TimeInterval, at now: Date) {
            guard lag >= threshold else { return }
            count += 1
            worst = max(worst, lag)
            if since == nil { since = now }
        }
    }

    init(interval: TimeInterval = 0.25, threshold: TimeInterval = 0.5,
         reportEvery: TimeInterval = 10) {
        self.interval = interval
        self.threshold = threshold
        self.reportEvery = reportEvery
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.interval, repeating: self.interval,
                       leeway: .milliseconds(50))
            // The process-long `shared` monitor: holding it is fine.
            t.setEventHandler { self.probe() }
            self.timer = t
            t.resume()
        }
    }

    private func probe() {
        guard !probing else { return }
        probing = true
        let posted = DispatchTime.now()
        DispatchQueue.main.async { [weak self] in
            let lag = Double(DispatchTime.now().uptimeNanoseconds - posted.uptimeNanoseconds) / 1e9
            self?.queue.async { self?.finish(lag) }
        }
    }

    private func finish(_ lag: TimeInterval) {
        probing = false
        let now = Date()
        stats.note(lag, threshold: threshold, at: now)
        guard let since = stats.since, now.timeIntervalSince(lastReport) >= reportEvery else { return }
        // UTC, like the guest bridge log's lines, so the two line up.
        NSLog("[bromure-ac] %@ main thread stalled %d time(s) over %.0f ms in the last %.0f s, "
              + "worst %.0f ms (guest vsock accepts wait on it)",
              Self.utc.string(from: now), stats.count, threshold * 1000,
              max(1, now.timeIntervalSince(since)), stats.worst * 1000)
        stats = Stats()
        lastReport = now
    }
}
