import Foundation

/// Where a MITM connection's task runs.
///
/// A connection does blocking socket and SecureTransport I/O inside an async
/// task (the TLS reads, the WebSocket relay's pump loops). On the default
/// executor that pins one of Swift concurrency's cooperative threads — one per
/// CPU core — for as long as the connection lives. Codex keeps a model
/// WebSocket open for its whole session (plus side sockets, plus a reconnect
/// loop when the upstream stalls), so a handful of Codex tabs took EVERY
/// cooperative thread, and the whole app's async work stopped: the agent
/// status reader (no tab ever showed "working"), the control socket the CLI
/// and the fat client use ("the bromure-ac agent isn't running"), timers.
///
/// This executor gives each job a thread of its own from an elastic pool —
/// idle threads are reused, a new one starts when none is free, an idle one
/// exits after a while — so a connection blocking for an hour costs one
/// thread and nothing else. Child tasks (the relay's two pumps) inherit it.
@available(macOS 15.0, *)
final class MitmBlockingExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = MitmBlockingExecutor()

    private let lock = NSCondition()
    private var jobs: [UnownedJob] = []
    /// Threads waiting for a job, and how many of them a signal is already
    /// on its way to. A job only waits for a thread that is free — never for
    /// one that may be blocked for an hour — so when no waiting thread is
    /// unclaimed, a new one starts.
    private var idle = 0
    private var wakeups = 0
    private static let idleExit: TimeInterval = 30

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        lock.lock()
        jobs.append(job)
        let spawn = idle <= wakeups
        if !spawn { wakeups += 1; lock.signal() }
        lock.unlock()
        if spawn {
            let t = Thread { [unowned self] in self.work() }
            t.name = "mitm-io"
            t.stackSize = 2 << 20        // TLS + regex-heavy policy code
            t.qualityOfService = .userInitiated
            t.start()
        }
    }

    private func work() {
        let me = asUnownedTaskExecutor()
        lock.lock()
        while true {
            if !jobs.isEmpty {
                let job = jobs.removeFirst()
                lock.unlock()
                job.runSynchronously(on: me)
                lock.lock()
                continue
            }
            idle += 1
            let woke = lock.wait(until: Date().addingTimeInterval(Self.idleExit))
            idle -= 1
            if woke, wakeups > 0 { wakeups -= 1 }
            if !woke, jobs.isEmpty { lock.unlock(); return }
        }
    }
}

enum MitmTasks {
    /// Start a MITM connection's work off the cooperative pool (see
    /// `MitmBlockingExecutor`). macOS 14 has no task executors: there it
    /// runs as before.
    static func spawn(_ body: @escaping @Sendable () async -> Void) {
        if #available(macOS 15.0, *) {
            Task.detached(executorPreference: MitmBlockingExecutor.shared, priority: .userInitiated) {
                await body()
            }
        } else {
            Task.detached(priority: .userInitiated) { await body() }
        }
    }
}
