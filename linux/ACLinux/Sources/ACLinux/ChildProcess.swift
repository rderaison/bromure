import Foundation
import NIOConcurrencyHelpers

/// A supervised child process (QEMU, virtiofsd, qemu-img): output to a log
/// file, and an awaitable exit status.
// @port-skip linux-only: QEMU and virtiofsd are separate processes; VZ runs in-process
final class ChildProcess: Sendable {
    let name: String
    private let process: Process
    private let state = NIOLockedValueBox<(status: Int32?, waiters: [CheckedContinuation<Int32, Never>])>((nil, []))

    // @port-skip linux-only: process supervision
    init(name: String, executable: String, arguments: [String], logPath: String?) throws {
        self.name = name
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        if let logPath {
            _ = FileManager.default.createFile(atPath: logPath, contents: nil)
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        self.process = p
        p.terminationHandler = { [state] proc in
            let status = proc.terminationStatus
            let waiters = state.withLockedValue { s -> [CheckedContinuation<Int32, Never>] in
                s.status = status
                defer { s.waiters = [] }
                return s.waiters
            }
            for w in waiters { w.resume(returning: status) }
        }
    }

    // @port-skip linux-only: process supervision
    func start() throws { try process.run() }

    // @port-skip linux-only: process supervision
    var pid: Int32 { process.processIdentifier }

    // @port-skip linux-only: process supervision
    var exitStatus: Int32? { state.withLockedValue { $0.status } }

    // @port-skip linux-only: process supervision
    var isRunning: Bool { exitStatus == nil }

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

    // @port-skip linux-only: process supervision
    func signal(_ sig: Int32) {
        guard isRunning else { return }
        kill(process.processIdentifier, sig)
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
