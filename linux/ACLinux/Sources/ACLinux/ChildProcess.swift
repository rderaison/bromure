import CACLinuxShims
import Foundation
import NIOConcurrencyHelpers

/// Runs every spawn on one thread that lives as long as the process.
/// PR_SET_PDEATHSIG (QEMU's `-run-with exit-with-parent=on`) fires when the
/// *thread* that forked the child exits, not the process: spawned from a
/// Swift-concurrency or Dispatch worker that's later reaped, QEMU got SIGTERM
/// mid-run (it showed up as `.virtiofsdExited`, virtiofsd following QEMU).
// @port-skip linux-only: process supervision
final class Spawner: @unchecked Sendable {
    static let shared = Spawner()
    private let lock = NSCondition()
    private var job: (() -> Void)?
    private var done = false

    // @port-skip linux-only: process supervision
    private init() {
        let t = Thread { [unowned self] in self.loop() }
        t.name = "acl-spawner"
        t.start()
    }

    // @port-skip linux-only: process supervision
    private func loop() {
        while true {
            lock.lock()
            while job == nil { lock.wait() }
            let j = job!
            lock.unlock()
            j()
            lock.lock()
            job = nil
            done = true
            lock.broadcast()
            lock.unlock()
        }
    }

    /// Runs `body` on the spawner thread and returns its result (one at a time).
    // @port-skip linux-only: process supervision
    func run<T>(_ body: @escaping () -> T) -> T {
        var result: T?
        lock.lock()
        while job != nil { lock.wait() }
        done = false
        job = { result = body() }
        lock.broadcast()
        while !done { lock.wait() }
        lock.unlock()
        return result!
    }
}

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
    private let stdoutFD: Int32?
    private let state = NIOLockedValueBox<(pid: Int32, status: Int32?, waiters: [CheckedContinuation<Int32, Never>])>(
        (0, nil, []))

    // @port-skip linux-only: process supervision
    init(name: String, executable: String, arguments: [String], logPath: String?,
         standardInput: Int32? = nil, standardOutput: Int32? = nil) throws {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.logPath = logPath
        self.stdinFD = standardInput
        self.stdoutFD = standardOutput
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
        let exe = executable, inFD = stdinFD ?? -1, outFD = stdoutFD ?? logFD, errFD = logFD
        let r = Spawner.shared.run {
            argv.withUnsafeBufferPointer { a in acl_spawn(exe, a.baseAddress, inFD, outFD, errFD, &pid) }
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

    /// Runs a short-lived tool synchronously with `input` on its stdin;
    /// returns its stdout (stderr goes to a temp log, included in the error).
    /// Data travels over pipes only, never argv or a file.
    ///
    /// All of `input` is written before stdout is read: fine for a key's 32
    /// bytes, but input or output larger than a pipe buffer (64 KiB) would
    /// deadlock. Not for bulk data.
    // @port-skip linux-only: process supervision
    static func capture(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        var inP: [Int32] = [-1, -1], outP: [Int32] = [-1, -1]
        guard acl_pipe_cloexec(&inP) == 0 else { throw MachineError.io("pipe", errno) }
        guard acl_pipe_cloexec(&outP) == 0 else { close(inP[0]); close(inP[1]); throw MachineError.io("pipe", errno) }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("acl-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: log) }
        let p = try ChildProcess(name: (executable as NSString).lastPathComponent, executable: executable,
                                 arguments: arguments, logPath: log, standardInput: inP[0], standardOutput: outP[1])
        do { try p.start() } catch {
            for fd in inP + outP { close(fd) }
            throw error
        }
        close(inP[0]); close(outP[1])
        if let input {
            input.withUnsafeBytes { b in
                var off = 0
                while off < b.count {
                    let n = write(inP[1], b.baseAddress! + off, b.count - off)
                    if n <= 0 { if errno == EINTR { continue }; break }
                    off += n
                }
            }
        }
        close(inP[1])
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { read(outP[0], $0.baseAddress, $0.count) }
            if n > 0 { out.append(contentsOf: buf[0..<n]) } else if n < 0 && errno == EINTR { continue } else { break }
        }
        close(outP[0])
        while p.exitStatus == nil { usleep(1000) }
        if p.exitStatus != 0 {
            let err = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            throw MachineError.toolFailed(p.name, p.exitStatus ?? -1, err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
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
