import CACLinuxShims
import Foundation
import NIOConcurrencyHelpers

/// A supervised child process (QEMU, virtiofsd, passt, qemu-img): output to
/// a log file, and an awaitable exit status.
///
/// Spawned with posix_spawn (every inherited descriptor but stdio closed)
/// and reaped by a thread blocked in waitpid() for that pid. Foundation's
/// Process lost exits of short-lived children started concurrently (they
/// stayed zombies and terminationHandler never ran).
// @port-skip linux-only: QEMU and virtiofsd are separate processes; VZ runs in-process
final class ChildProcess: Sendable {
    let name: String
    private let executable: String
    private let arguments: [String]
    private let logPath: String?
    private let stdinFD: Int32?
    private let state = NIOLockedValueBox<(pid: Int32, status: Int32?, waiters: [CheckedContinuation<Int32, Never>])>(
        (0, nil, []))

    // @port-skip linux-only: process supervision
    init(name: String, executable: String, arguments: [String], logPath: String?,
         standardInput: Int32? = nil) throws {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.logPath = logPath
        self.stdinFD = standardInput
    }

    // @port-skip linux-only: process supervision
    func start() throws {
        var logFD: Int32 = -1
        if let logPath {
            logFD = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
            if logFD < 0 { throw MachineError.io("open \(logPath)", errno) }
        }
        defer { if logFD >= 0 { close(logFD) } }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for a in argv { free(a) } }
        var pid: Int32 = 0
        let r = argv.withUnsafeBufferPointer { a in
            acl_spawn(executable, a.baseAddress, stdinFD ?? -1, logFD, logFD, &pid)
        }
        guard r == 0 else { throw MachineError.io("spawn \(executable)", r) }
        let child = pid
        state.withLockedValue { $0.pid = child }
        let t = Thread { [state] in
            // Exited but not reaped: the zombie still holds the pid, so a
            // signal() racing this can't hit a recycled pid. The status is
            // recorded under the lock (from then on signal() is a no-op) and
            // only then is the child reaped.
            let status = acl_wait_exited(child)
            if let pause = ChildProcess.reapPauseForTesting.withLockedValue({ $0 }) {
                Thread.sleep(forTimeInterval: pause)
            }
            let waiters = state.withLockedValue { s -> [CheckedContinuation<Int32, Never>] in
                s.status = status
                defer { s.waiters = [] }
                return s.waiters
            }
            acl_reap(child)
            for w in waiters { w.resume(returning: status) }
        }
        t.name = "wait-\(name)-\(child)"
        t.start()
    }

    /// Tests only: a pause between the child's exit and recording it.
    static let reapPauseForTesting = NIOLockedValueBox<Double?>(nil)

    // @port-skip linux-only: process supervision
    var pid: Int32 { state.withLockedValue { $0.pid } }

    // @port-skip linux-only: process supervision
    var exitStatus: Int32? { state.withLockedValue { $0.status } }

    // @port-skip linux-only: process supervision
    var isRunning: Bool { state.withLockedValue { $0.pid != 0 && $0.status == nil } }

    // @port-skip linux-only: process supervision
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { cont in
            let done = state.withLockedValue { s -> Int32? in
                if let st = s.status { return st }
                s.waiters.append(cont)
                return nil
            }
            if let done { cont.resume(returning: done) }
        }
    }

    /// The exit status, or nil if it's still running after `timeout`.
    // @port-skip linux-only: process supervision
    func waitForExit(timeout: Duration) async -> Int32? {
        await withTaskGroup(of: Int32?.self) { g in
            g.addTask { await self.waitForExit() }
            g.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first ?? exitStatus
        }
    }

    /// Signals the child while it can't have been reaped: its exit status is
    /// recorded (under this lock) before the reaper reaps, so the pid is
    /// never a recycled one. Returns whether kill() delivered it.
    // @port-skip linux-only: process supervision
    @discardableResult
    func signal(_ sig: Int32) -> Bool {
        state.withLockedValue { s in
            guard s.pid != 0, s.status == nil else { return false }
            return kill(s.pid, sig) == 0
        }
    }

    /// Runs a short-lived tool to completion; throws with its output on failure.
    // @port-skip linux-only: process supervision
    static func run(_ executable: String, _ arguments: [String]) async throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("acl-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: log) }
        let p = try ChildProcess(name: (executable as NSString).lastPathComponent,
                                 executable: executable, arguments: arguments, logPath: log)
        try p.start()
        let status = await p.waitForExit()
        if status != 0 {
            let out = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            throw MachineError.toolFailed(p.name, status, out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
