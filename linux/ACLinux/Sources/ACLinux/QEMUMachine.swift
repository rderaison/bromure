import Foundation

// @port-skip linux-only: errors of the QEMU backend
public enum MachineError: Error, CustomStringConvertible, Equatable {
    case socketPathTooLong(String)
    case invalidConfig(String)
    case toolFailed(String, Int32, String)
    case io(String, Int32)
    case notRunning
    case alreadyStarted
    case exitedDuringStart(Int32, String)
    case migrationFailed(String)
    case snapshotMissing(String)
    case snapshotMismatch(state: String, overlay: String)
    case virtiofsdNotReady(String)

    // @port-skip linux-only: error text
    public var description: String {
        switch self {
        case .socketPathTooLong(let p): return "unix socket path over 107 bytes: \(p)"
        case .invalidConfig(let m): return "invalid VM config: \(m)"
        case .toolFailed(let t, let s, let o): return "\(t) exited \(s): \(o)"
        case .io(let what, let e): return "\(what): \(String(cString: strerror(e)))"
        case .notRunning: return "VM is not running"
        case .alreadyStarted: return "VM was already started"
        case .exitedDuringStart(let s, let log): return "QEMU exited \(s) during start: \(log)"
        case .migrationFailed(let m): return "migration failed: \(m)"
        case .snapshotMissing(let p): return "no snapshot identity at \(p)"
        case .snapshotMismatch(let s, let o): return "\(s) was not saved with \(o) as it is now; refusing to restore"
        case .virtiofsdNotReady(let tag): return "virtiofsd for '\(tag)' did not come up"
        }
    }
}

/// One QEMU/KVM VM: its QEMU process, a virtiofsd per share, and QMP.
///
/// Single-use like a VZVirtualMachine: `start()` or `restore(from:)` once,
/// then it ends in `stopped`. Suspend ends it too; restore the state into a
/// new `QEMUMachine` with the same config.
// @port-skip linux-only: QEMU backend (macOS: UbuntuSandboxVM on Virtualization.framework)
public actor QEMUMachine {
    // @port-skip linux-only: QEMU backend
    public enum StopReason: Sendable, Equatable {
        /// The guest powered itself off.
        case guestShutdown
        /// `stop()`: ACPI powerdown, with `quit` if the guest ignored it.
        case stopped
        case killed
        /// `suspend(to:)`: the state was saved to this file.
        case suspended(String)
        /// A share's virtiofsd died; the VM was taken down with it.
        case virtiofsdExited(tag: String)
        /// QEMU exited on its own with a failure.
        case crashed
    }

    // @port-skip linux-only: QEMU backend
    public struct StopInfo: Sendable, Equatable {
        public let reason: StopReason
        /// QEMU's exit status (128 + signal when killed by one).
        public let exitStatus: Int32
    }

    // @port-skip linux-only: QEMU backend
    public enum State: Sendable, Equatable {
        case idle, starting, running, stopping, stopped(StopInfo)
    }

    // @port-skip linux-only: QEMU backend
    public struct SuspendTimings: Sendable {
        /// `stop` + mapped-ram migration to the file.
        public let save: Duration
        /// Up to QEMU's exit.
        public let total: Duration
        public let stateBytes: UInt64
    }

    // @port-skip linux-only: QEMU backend
    public struct RestoreTimings: Sendable {
        /// QEMU exec until QMP answers.
        public let launch: Duration
        /// `migrate-incoming` until completed.
        public let load: Duration
        /// Through `cont`.
        public let total: Duration
    }

    public nonisolated let config: QEMUMachineConfig
    public private(set) var state: State = .idle
    public private(set) var qmp: QMPClient?
    private var onStopped: (@Sendable (StopInfo) -> Void)?
    private var qemu: ChildProcess?
    private var daemons: [(tag: String, process: ChildProcess)] = []
    private var pendingReason: StopReason?
    private var stopWaiters: [CheckedContinuation<StopInfo, Never>] = []

    // @port-skip linux-only: QEMU backend
    public init(config: QEMUMachineConfig) {
        self.config = config
    }

    /// Called once, when the VM has stopped for any reason.
    // @port-skip linux-only: QEMU backend
    public func setOnStopped(_ handler: @escaping @Sendable (StopInfo) -> Void) {
        onStopped = handler
    }

    // @port-skip linux-only: QEMU backend
    public var pid: Int32? { qemu?.pid }

    // MARK: lifecycle

    /// Creates the overlay if needed, starts the virtiofsds and QEMU, and
    /// connects QMP. Returns once QMP answers (the guest is booting).
    // @port-skip linux-only: QEMU backend
    public func start() async throws {
        try await launch(incoming: false)
    }

    /// Graceful stop: ACPI powerdown, `quit` after `timeout`, SIGKILL after
    /// 5 s more.
    // @port-skip linux-only: QEMU backend
    @discardableResult
    public func stop(timeout: Duration = .seconds(30)) async -> StopInfo {
        if case .stopped(let info) = state { return info }
        guard let qemu else { return finishIdle(.stopped) }
        state = .stopping
        pendingReason = pendingReason ?? .stopped
        _ = try? await qmp?.execute("system_powerdown", timeout: .seconds(5))
        if await qemu.waitForExit(timeout: timeout) == nil {
            _ = try? await qmp?.execute("quit", timeout: .seconds(5))
            if await qemu.waitForExit(timeout: .seconds(5)) == nil { qemu.signal(SIGKILL) }
        }
        return await waitUntilStopped()
    }

    // @port-skip linux-only: QEMU backend
    @discardableResult
    public func kill() async -> StopInfo {
        if case .stopped(let info) = state { return info }
        guard let qemu else { return finishIdle(.killed) }
        pendingReason = .killed
        qemu.signal(SIGKILL)
        return await waitUntilStopped()
    }

    // @port-skip linux-only: QEMU backend
    public func waitUntilStopped() async -> StopInfo {
        if case .stopped(let info) = state { return info }
        return await withCheckedContinuation { stopWaiters.append($0) }
    }

    // MARK: suspend / resume

    /// Pauses the guest, saves its state to `statePath` with mapped-ram (a
    /// sparse file of RAM at fixed offsets: ~0.2 s restores that don't fault
    /// all of RAM in), quits QEMU, and records the overlay's identity next to
    /// the state. The VM ends `stopped(.suspended)`.
    // @port-skip linux-only: QEMU backend (macOS: VZVirtualMachine.saveMachineStateTo)
    @discardableResult
    public func suspend(to statePath: String) async throws -> SuspendTimings {
        guard state == .running, let qmp, let qemu else { throw MachineError.notRunning }
        let t0 = ContinuousClock.now
        try? FileManager.default.removeItem(atPath: statePath)
        try? FileManager.default.removeItem(atPath: SnapshotIdentity.sidecarPath(forState: statePath))
        try await qmp.execute("migrate-set-capabilities", arguments: Self.mappedRam)
        // QEMU's default cap (128 MiB/s) makes a 2 GiB save take ~3.5 s.
        try await qmp.execute("migrate-set-parameters", arguments: ["max-bandwidth": .number(100e9)])
        try await qmp.execute("stop")
        try await qmp.execute("migrate", arguments: ["uri": .string("file:" + statePath)])
        do {
            try await Self.awaitMigration(qmp, timeout: .seconds(120))
        } catch {
            _ = try? await qmp.execute("cont")
            throw error
        }
        let saved = ContinuousClock.now
        state = .stopping
        pendingReason = .suspended(statePath)
        _ = try? await qmp.execute("quit", timeout: .seconds(5))
        if await qemu.waitForExit(timeout: .seconds(10)) == nil { qemu.signal(SIGKILL) }
        _ = await waitUntilStopped()
        // After QEMU's exit: it flushes the overlay on close.
        try SnapshotIdentity.of(overlay: config.overlay).write(forState: statePath)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: statePath)[.size] as? UInt64) ?? 0
        return SuspendTimings(save: saved - t0, total: ContinuousClock.now - t0, stateBytes: bytes)
    }

    /// Starts QEMU with `-incoming defer`, loads `statePath` and resumes the
    /// guest. Refuses a state whose overlay has changed since it was saved.
    // @port-skip linux-only: QEMU backend (macOS: VZVirtualMachine.restoreMachineStateFrom)
    @discardableResult
    public func restore(from statePath: String) async throws -> RestoreTimings {
        try SnapshotIdentity.verify(state: statePath, overlay: config.overlay)
        let t0 = ContinuousClock.now
        try await launch(incoming: true)
        guard let qmp else { throw MachineError.notRunning }
        let launched = ContinuousClock.now
        do {
            try await qmp.execute("migrate-set-capabilities", arguments: Self.mappedRam)
            try await qmp.execute("migrate-incoming", arguments: ["uri": .string("file:" + statePath)])
            try await Self.awaitMigration(qmp, timeout: .seconds(120))
            let loaded = ContinuousClock.now
            try await qmp.execute("cont")
            return RestoreTimings(launch: launched - t0, load: loaded - launched,
                                  total: ContinuousClock.now - t0)
        } catch {
            await kill()
            throw error
        }
    }

    // MARK: internals

    // @port-skip linux-only: QEMU backend
    private static let mappedRam: JSONValue =
        ["capabilities": [["capability": "mapped-ram", "state": true]]]

    // @port-skip linux-only: QEMU backend
    private static func awaitMigration(_ qmp: QMPClient, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let r = try await qmp.execute("query-migrate")
            switch r["status"]?.stringValue {
            case "completed": return
            case "failed", "cancelled":
                throw MachineError.migrationFailed(r["error-desc"]?.stringValue ?? "status \(r["status"]?.stringValue ?? "?")")
            default: try await Task.sleep(for: .milliseconds(5))
            }
        }
        throw MachineError.migrationFailed("timed out")
    }

    // @port-skip linux-only: QEMU backend
    private func launch(incoming: Bool) async throws {
        guard state == .idle else { throw MachineError.alreadyStarted }
        try config.validate()
        state = .starting
        do {
            try FileManager.default.createDirectory(atPath: config.runDirectory, withIntermediateDirectories: true)
            if !config.writeBaseInPlace, !FileManager.default.fileExists(atPath: config.overlay) {
                try await ChildProcess.run(config.qemuImg, [
                    "create", "-q", "-f", "qcow2", "-F", config.baseFormat.rawValue,
                    "-b", config.baseImage, config.overlay])
            }
            try await startDaemons()
            let log = (config.runDirectory as NSString).appendingPathComponent("qemu.log")
            try? FileManager.default.removeItem(atPath: config.qmpSocketPath)
            let q = try ChildProcess(name: "qemu", executable: config.qemuBinary,
                                     arguments: config.arguments(incoming: incoming), logPath: log)
            try q.start()
            qemu = q
            Task { [weak self] in
                let status = await q.waitForExit()
                await self?.qemuExited(status)
            }
            qmp = try await connectQMP(q, log: log)
            state = .running
        } catch {
            if let q = qemu, q.isRunning { q.signal(SIGKILL); _ = await q.waitForExit() }
            stopDaemons()
            if state == .starting { state = .idle }
            throw error
        }
    }

    // @port-skip linux-only: QEMU backend
    private func connectQMP(_ q: ChildProcess, log: String) async throws -> QMPClient {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            if let status = q.exitStatus {
                let out = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
                throw MachineError.exitedDuringStart(status, out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if FileManager.default.fileExists(atPath: config.qmpSocketPath),
               let c = try? await QMPClient.connect(socketPath: config.qmpSocketPath, timeout: .seconds(5)) {
                return c
            }
            if ContinuousClock.now > deadline { throw QMPError.timeout("QMP socket \(config.qmpSocketPath)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // @port-skip linux-only: virtiofsd supervision
    private func startDaemons() async throws {
        for (i, share) in config.shares.enumerated() {
            let sock = config.shareSocketPath(i)
            try? FileManager.default.removeItem(atPath: sock)
            let log = (config.runDirectory as NSString).appendingPathComponent("virtiofsd-\(share.tag).log")
            let d = try ChildProcess(name: "virtiofsd[\(share.tag)]", executable: config.virtiofsd,
                                     arguments: config.virtiofsdArguments(i), logPath: log)
            try d.start()
            daemons.append((share.tag, d))
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: sock) {
                if !d.isRunning || ContinuousClock.now > deadline { throw MachineError.virtiofsdNotReady(share.tag) }
                try await Task.sleep(for: .milliseconds(5))
            }
            let tag = share.tag
            Task { [weak self] in
                _ = await d.waitForExit()
                await self?.daemonExited(tag)
            }
        }
    }

    // @port-skip linux-only: virtiofsd supervision
    private func daemonExited(_ tag: String) {
        // Expected once QEMU is gone; otherwise the guest just lost a
        // filesystem it can't get back (vhost-user-fs has no reconnect).
        // A stop/kill/suspend in progress already explains it: QEMU going away
        // is what makes virtiofsd exit, and its exit may be reaped first.
        guard state == .running || state == .starting, pendingReason == nil, let qemu else { return }
        pendingReason = .virtiofsdExited(tag: tag)
        qemu.signal(SIGKILL)
    }

    // @port-skip linux-only: virtiofsd supervision
    private func stopDaemons() {
        for d in daemons { d.process.signal(SIGTERM) }
        daemons = []
    }

    // @port-skip linux-only: QEMU backend
    private func qemuExited(_ status: Int32) {
        stopDaemons()
        Task { await qmp?.close() }
        let reason = pendingReason ?? (status == 0 ? .guestShutdown : .crashed)
        finish(StopInfo(reason: reason, exitStatus: status))
    }

    // @port-skip linux-only: QEMU backend
    private func finishIdle(_ reason: StopReason) -> StopInfo {
        let info = StopInfo(reason: reason, exitStatus: 0)
        finish(info)
        return info
    }

    // @port-skip linux-only: QEMU backend
    private func finish(_ info: StopInfo) {
        if case .stopped = state { return }
        state = .stopped(info)
        for w in stopWaiters { w.resume(returning: info) }
        stopWaiters = []
        onStopped?(info)
    }
}
