import Foundation

/// Truly bounded waits for the quit path.
///
/// The obvious "race the work against a sleep in a task group" does NOT bound
/// anything: `withTaskGroup` implicitly awaits every child before it returns,
/// and `cancelAll()` only *requests* cancellation. A child awaiting
/// `vm.stop`/`vm.pause` (a checked continuation, which ignores cancellation)
/// keeps the group — and therefore quit, parked in `.terminateLater` — waiting
/// forever. That was QH-1: a wedged browser-VM stop held the "15 s" teardown
/// race open indefinitely, `NSApp.reply(toApplicationShouldTerminate:)` was
/// never reached, and every later Quit Apple Event failed with -128.
///
/// Here the work runs in an unstructured `Task` that is simply abandoned on
/// timeout (it keeps running and finishes or not on its own); the caller
/// resumes at the deadline regardless.
enum QuitDeadline {
    /// Run `operation`, returning its value — or `timeoutValue` once `seconds`
    /// elapse first. The losing operation is not awaited.
    static func run<T: Sendable>(
        seconds: Double, label: String, timeoutValue: T,
        log: @escaping @Sendable (String) -> Void = QuitDeadline.stderrLog,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        let gate = Gate<T>()
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            gate.arm(cont)
            Task {
                let value = await operation()
                gate.finish(value)
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.finish(timeoutValue) {
                    log("[quit] \(label) did not finish within \(Int(seconds.rounded()))s — proceeding without it")
                }
            }
            gate.onFinish = { timer.cancel() }
        }
    }

    /// Void convenience: true when `operation` finished in time.
    @discardableResult
    static func run(
        seconds: Double, label: String,
        log: @escaping @Sendable (String) -> Void = QuitDeadline.stderrLog,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await run(seconds: seconds, label: label, timeoutValue: false, log: log) {
            await operation()
            return true
        }
    }

    static let stderrLog: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Resume-exactly-once latch shared by the work and the timer.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Never>?
        private var done = false
        /// Set once, right after both tasks are spawned; fires at finish (or
        /// immediately when the work already won).
        var onFinish: (() -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _onFinish }
            set {
                lock.lock()
                let fire = done
                _onFinish = fire ? nil : newValue
                lock.unlock()
                if fire { newValue?() }
            }
        }
        private var _onFinish: (() -> Void)?

        func arm(_ c: CheckedContinuation<T, Never>) {
            lock.lock(); cont = c; lock.unlock()
        }

        /// True for the call that won (resumed the caller).
        @discardableResult
        func finish(_ value: T) -> Bool {
            lock.lock()
            guard !done, let c = cont else { lock.unlock(); return false }
            done = true
            cont = nil
            let hook = _onFinish
            _onFinish = nil
            lock.unlock()
            hook?()
            c.resume(returning: value)
            return true
        }
    }
}
