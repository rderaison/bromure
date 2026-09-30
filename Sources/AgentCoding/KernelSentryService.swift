import Foundation
@preconcurrency import Virtualization
import SandboxEngine
import CryptoKit

/// Host side of the guest's kernel sentry (vsock 5841).
///
/// Inside the VM, eBPF programs capture security-relevant kernel events and a
/// small kernel module streams them to the host from kernel space — no
/// userland process in the path, so the agent can't silence it by killing
/// something; after load the guest raises kernel lockdown, so not even guest
/// root can load another module to interfere. The host's part:
///  - accept exactly one sentry per VM start, pinned by the secret its first
///    hello carries (minted per module load, never visible to userland);
///  - watch liveness: heartbeats every second carry a sequence number shared
///    with events, so silence, a gap, or a second sentry is detected;
///  - turn events into Security Timeline entries / OCSF and watchdog signals.
/// High-volume kinds (exec, connect) are only counted: they'd otherwise ship
/// every command the user runs to the timeline (and, when enrolled, the cloud).
public final class KernelSentryService: @unchecked Sendable {
    public static let shared = KernelSentryService()
    public static var vsockPort: UInt32 { OpenShellSandboxSpec.sentryVsockPort }

    /// Seconds of silence before a warning, and before it's treated as
    /// tampering (a watchdog signal that trips on its own).
    public static let silenceWarning: TimeInterval = 5
    public static let silenceTamper: TimeInterval = 15
    /// How long a freshly started VM may take to bring the sentry up.
    public static let bootBudget: TimeInterval = 90
    public static let shutdownBudget: TimeInterval = 20

    private let lock = NSLock()
    private var bridges: [UUID: SentryBridge] = [:]
    private var timer: DispatchSourceTimer?

    /// Whether the VM is actually running (not paused / suspended / stopping);
    /// set by the app. A VM that isn't running sends nothing, and that isn't
    /// silence.
    public var vmRunningProvider: (@Sendable (UUID) -> Bool) = { _ in true }
    /// The workspace's directory, where the sentry pin survives a host restart.
    @MainActor public var pinDirectory: ((Profile) -> URL?)?

    // MARK: Lifecycle

    @MainActor
    public func attach(profile: Profile, socketDevice: VZVirtioSocketDevice, restoring: Bool) {
        let requirement = profile.effectiveKernelSentry
        detach(profileID: profile.id, socketDevice: socketDevice)
        guard requirement != .off else { return }
        let bridge = SentryBridge(profileID: profile.id, requirement: requirement, restoring: restoring,
                                  strict: profile.effectiveStrictSandbox,
                                  pinFile: pinDirectory?(profile)?.appendingPathComponent("sentry.pin"))
        bridge.listen(on: socketDevice)
        lock.lock()
        bridges[profile.id] = bridge
        if timer == nil { startMonitor() }
        lock.unlock()
    }

    @MainActor
    public func detach(profileID: UUID, socketDevice: VZVirtioSocketDevice?) {
        lock.lock()
        let b = bridges.removeValue(forKey: profileID)
        lock.unlock()
        b?.stop(socketDevice: socketDevice)
    }

    /// The guest's root attestor independently reports whether the sentry
    /// runs and a digest of its secret; a live connection that doesn't match
    /// is an impostor (a userland process that got to the port first).
    func crossCheck(profileID: UUID, guestSentry: String?, digest: String?) {
        lock.lock(); let b = bridges[profileID]; lock.unlock()
        b?.crossCheck(guestSentry: guestSentry, digest: digest)
    }

    public func snapshot(_ profileID: UUID) -> SentryBridge.Snapshot? {
        lock.lock(); let b = bridges[profileID]; lock.unlock()
        return b?.snapshot()
    }

    private func startMonitor() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func tick(now: Date = Date()) {
        lock.lock(); let all = bridges; lock.unlock()
        for (pid, bridge) in all {
            bridge.checkLiveness(now: now, running: vmRunningProvider(pid))
        }
    }

    // MARK: Event → signal mapping

    /// Watchdog weight and timeline category for a sentry event; nil =
    /// counted only (tallied, never a timeline row or a watchdog signal).
    ///
    /// Events are judged by what they mean, not by which syscall fired:
    /// root dropping privileges, Bromure's own boot-time helpers and
    /// distro-signed modules (docker's overlay, netfilter) are routine, and
    /// a false alarm in the first minute is how users learn to ignore the
    /// real ones. `strict` = the workspace runs the strict sandbox, where the
    /// agent has no legitimate path to root at all.
    static func classify(_ kind: String, _ f: [String: Any] = [:], strict: Bool = false) -> (weight: Int, category: String)? {
        // Before the session starts it's Bromure's own root helpers; at
        // poweroff it's systemd tearing the VM down.
        let phase = f["phase"] as? String
        if phase == "boot" || phase == "shutdown" { return nil }
        // pid 1 is systemd: its unit BPF and its mounts are routine.
        let fromInit = (f["pid"] as? Int) == 1
        switch kind {
        case "cred_gain":
            // A gain of uid 0 or capabilities. Without strict the agent has
            // sudo, so it's a visible fact, not a signal. Under strict it
            // can't legitimately happen inside the sandbox (no_new_privs, no
            // sudo); outside it (Bromure's own helpers) it's visible only.
            guard strict else { return (0, "privilege") }
            return (f["sandboxed"] as? Bool) == false ? (0, "privilege") : (20, "tampering")
        case "module_load":
            // Signed in-tree modules load all the time; an unsigned load can't
            // succeed under lockdown, so even the attempt means someone tried.
            if (f["signed"] as? Bool) == true { return nil }
            return (10, "tampering")
        case "lockdown_change_attempt":
            // Lockdown only ever rises; the loader's own raise is expected.
            // An attempt to lower it, or a refused write, is the signal.
            let lowering = (f["lowering"] as? Bool) == true
            let refused = ((f["result"] as? Int) ?? 0) < 0
            return lowering || refused ? (10, "tampering") : nil
        case "bpf_load":
            return fromInit ? nil : (10, "tampering")
        case "kexec_attempt":
            return (10, "tampering")
        case "ptrace":
            return (3, "privilege")
        case "mount", "unshare", "setns":
            return fromInit ? nil : (2, "namespace")
        case "landlock_denied", "file_open_denied", "sandbox_denied":
            // A filesystem operation the sandbox refused. Each alone is small
            // (agents probe paths innocently); a burst from one program is
            // raised separately as probing.
            return (1, "sandbox_denial")
        case "seccomp_denied":
            // A syscall the process layer blocks (mount, unshare, bpf, …):
            // rarely innocent inside a sandbox.
            return (3, "sandbox_denial")
        default:
            // exec, connect, and raw setuid / setgid / capset calls (which
            // fire for every privilege drop and every refused attempt).
            return nil
        }
    }
}

/// One VM's sentry channel: u32 big-endian length + JSON frames.
public final class SentryBridge: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var connected: Bool
        public var kernel: String?
        public var module: String?
        public var landlockABI: Int?
        public var lastFrameAt: Date?
        public var eventsSeen: Int
        public var countedOnly: [String: Int]
        public var dropped: Int
        public var alarms: Int
    }

    let profileID: UUID
    let requirement: KernelSentryMode
    private let lock = NSLock()
    private var listener: VZVirtioSocketListener?
    private var fd: Int32 = -1
    private var pinnedSecret: String?
    private var lastSeq: UInt64?
    private var attachedAt = Date()
    private var reportedStuckBoot = false
    private var shutdownSeenAt: Date?
    /// Who last declared the sentry's phase (from heartbeats).
    private var phaseSetBy: String?
    private var reportedStuckShutdown = false
    /// Tests: pretend the first shutdown-phase frame came `seconds` earlier.
    func backdateShutdown(by seconds: TimeInterval) {
        lock.lock(); shutdownSeenAt = (shutdownSeenAt ?? Date()) - seconds; lock.unlock()
    }
    /// Tests: pretend the VM started `seconds` earlier.
    func backdateAttach(by seconds: TimeInterval) { lock.lock(); attachedAt -= seconds; lock.unlock() }
    private var lastFrameAt: Date?
    private var warnedSilence = false
    private var trippedSilence = false
    private var reportedAbsent = false
    private var info: (kernel: String?, module: String?, abi: Int?) = (nil, nil, nil)
    private var eventsSeen = 0
    private var counted: [String: Int] = [:]
    private var dropped = 0
    private var alarms = 0
    private var probesDisarmed = false
    /// Tests: sees every event the bridge emits (type, data).
    var tap: ((String, [String: AnyJSON]) -> Void)?

    /// The workspace runs the strict sandbox (no legitimate path to root).
    let strict: Bool

    /// Where the pin survives a host restart (0600, in the workspace's
    /// directory): a restored VM's module reconnects with a proof only,
    /// which the host can check only if it still knows the secret.
    private let pinFile: URL?
    private var pinnedBootID: String?
    private var lastConn = 0

    init(profileID: UUID, requirement: KernelSentryMode, restoring: Bool, strict: Bool = false,
         pinFile: URL? = nil) {
        self.profileID = profileID
        self.requirement = requirement
        self.strict = strict
        self.pinFile = pinFile
        super.init()
        guard let pinFile else { return }
        if restoring {
            // Same VM, same module load: keep verifying against its secret.
            if let d = try? Data(contentsOf: pinFile),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                pinnedSecret = o["secret"] as? String
                pinnedBootID = o["boot_id"] as? String
                lastConn = o["conn"] as? Int ?? 0
            }
        } else {
            // A fresh boot loads a fresh module with a fresh secret.
            try? FileManager.default.removeItem(at: pinFile)
        }
    }

    private func persistPin() {
        guard let pinFile, let secret = pinnedSecret else { return }
        let o: [String: Any] = ["secret": secret, "boot_id": pinnedBootID ?? "", "conn": lastConn]
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? d.write(to: pinFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: pinFile.path)
    }

    /// The reconnect proof: sha256(secret-hex || boot_id || decimal conn), hex.
    static func reconnectProof(secret: String, bootID: String, conn: Int) -> String {
        sha256Hex(secret + bootID + String(conn))
    }

    @MainActor func listen(on device: VZVirtioSocketDevice) {
        let l = VZVirtioSocketListener()
        l.delegate = self
        listener = l
        device.setSocketListener(l, forPort: KernelSentryService.vsockPort)
    }

    @MainActor func stop(socketDevice: VZVirtioSocketDevice?) {
        socketDevice?.removeSocketListener(forPort: KernelSentryService.vsockPort)
        lock.lock(); let f = fd; fd = -1; lock.unlock()
        if f >= 0 { close(f) }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(connected: fd >= 0, kernel: info.kernel, module: info.module, landlockABI: info.abi,
                        lastFrameAt: lastFrameAt, eventsSeen: eventsSeen, countedOnly: counted,
                        dropped: dropped, alarms: alarms)
    }

    public func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                         from socketDevice: VZVirtioSocketDevice) -> Bool {
        let cfd = dup(connection.fileDescriptor)
        guard cfd >= 0 else { return false }
        Thread.detachNewThread { [weak self] in
            autoreleasepool { self?.serve(cfd) }
        }
        return true
    }

    // MARK: Framing

    static let maxFrame = 1 << 20

    /// Read one frame; nil on EOF / error / oversize.
    static func readFrame(_ fd: Int32) -> [String: Any]? {
        var header = [UInt8](repeating: 0, count: 4)
        guard readExactly(fd, &header, 4) else { return nil }
        let n = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard n > 0, n <= maxFrame else { return nil }
        var body = [UInt8](repeating: 0, count: n)
        guard readExactly(fd, &body, n) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }

    private static func readExactly(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + off, n - off) }
            if r > 0 { off += r } else if r < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    // MARK: Session

    func serve(_ cfd: Int32) {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let hello = Self.readFrame(cfd), hello["type"] as? String == "hello",
              hello["v"] as? Int == 1 else {
            close(cfd)
            alarm("tampering", "a connection on the sentry port didn't open with a valid sentry hello", weight: 10)
            return
        }
        // First hello (conn 0) carries the secret; a reconnect (conn > 0)
        // carries only a proof, so a secret read from memory after the first
        // hello can't open a new connection.
        let conn = hello["conn"] as? Int ?? 0
        let offered = hello["secret"] as? String
        let proof = (hello["proof"] as? String)?.lowercased()
        let bootID = hello["boot_id"] as? String ?? ""
        lock.lock()
        let busy = fd >= 0
        let pinned = pinnedSecret
        let pinnedBoot = pinnedBootID
        let last = lastConn
        var refusal: (String, Int)?
        if busy {
            refusal = ("a second kernel sentry tried to connect while the pinned one is live", 20)
        } else if conn == 0 {
            if let offered, offered.count == 64, offered.allSatisfy({ $0.isHexDigit }) {
                if pinned != nil {
                    refusal = pinned == offered
                        ? ("the sentry's first hello was replayed (a reconnect must carry a proof, not the secret)", 20)
                        : ("a kernel sentry connection with the wrong secret (impersonation attempt)", 20)
                }
            } else {
                refusal = ("a connection on the sentry port didn't open with a valid sentry hello", 10)
            }
        } else if offered != nil {
            refusal = ("a sentry reconnect carried the secret in the clear", 20)
        } else if let pinned {
            if conn <= last {
                refusal = ("a sentry reconnect reused connection index \(conn) (last \(last))", 20)
            } else if bootID != (pinnedBoot ?? bootID)
                        || proof != Self.reconnectProof(secret: pinned, bootID: pinnedBoot ?? bootID, conn: conn) {
                refusal = ("a sentry reconnect with a wrong proof (impersonation attempt)", 20)
            }
        } else {
            // Nothing pinned (no record of this VM's first hello): a proof
            // can't be checked, so it can't be trusted.
            refusal = ("a sentry reconnect the host can't verify (no pinned secret for this VM)", 20)
        }
        if refusal == nil {
            fd = cfd
            if conn == 0 { pinnedSecret = offered; pinnedBootID = bootID }
            lastConn = conn
            info = (hello["kernel"] as? String, hello["module"] as? String, hello["landlock_abi"] as? Int)
            lastFrameAt = Date()
            warnedSilence = false
            trippedSilence = false
        }
        lock.unlock()
        if let (reason, weight) = refusal {
            close(cfd)
            alarm("tampering", reason, weight: weight)
            return
        }
        persistPin()
        var data: [String: AnyJSON] = ["state": .string("connected")]
        if let k = info.kernel { data["kernel"] = .string(k) }
        if let m = info.module { data["module"] = .string(m) }
        emit("sentry.state", data)

        tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while let frame = Self.readFrame(cfd) {
            handle(frame)
        }
        lock.lock()
        let wasOurs = fd == cfd
        if wasOurs { fd = -1 }
        lock.unlock()
        close(cfd)
        if wasOurs {
            emit("sentry.state", ["state": .string("disconnected")])
        }
    }

    func handle(_ frame: [String: Any], now: Date = Date()) {
        let type = frame["type"] as? String ?? ""
        guard type == "heartbeat" || type == "event" else { return }
        guard let seqNum = (frame["seq"] as? NSNumber)?.uint64Value else {
            alarm("tampering", "a sentry frame without a sequence number", weight: 10)
            return
        }
        lock.lock()
        let expected = lastSeq.map { $0 &+ 1 }
        lastSeq = seqNum
        lastFrameAt = now
        warnedSilence = false
        trippedSilence = false
        // Ring-full drops and token-bucket rate limiting: both are events the
        // host didn't see, both reported (never silent).
        let newDrops = ((frame["dropped"] as? Int) ?? 0) + ((frame["rate_limited"] as? Int) ?? 0)
        dropped += max(0, newDrops)
        lock.unlock()
        if let expected, seqNum != expected {
            alarm("tampering", "sentry sequence jumped from \(expected &- 1) to \(seqNum) — frames went missing", weight: 20)
        }
        if newDrops > 0 {
            alarm("sentry_overflow", "the kernel sentry dropped \(newDrops) event(s) under load", weight: 2)
        }
        // Probe health: every kernel probe must stay armed. Root disabling
        // kprobes (debugfs / ftrace) would blind the sentry while heartbeats
        // keep flowing.
        if let sb = frame["sandbox"] as? [String: Any] { noteTallies(sb) }
        flushDenialRepeats(now: now)
        if let by = frame["phase_set_by"] as? [String: Any] {
            let who = "\(by["comm"] as? String ?? "?") (pid \(by["pid"] as? Int ?? 0))"
            lock.lock(); phaseSetBy = who; lock.unlock()
        }
        if let probes = frame["probes"] as? [String: Any] {
            // `canary: false` = the module's own canary probe didn't fire:
            // kprobes are disarmed globally even if every flag looks armed.
            let canaryDead = (probes["canary"] as? Bool) == false
            let total = (probes["total"] as? Int) ?? 0
            let armed = canaryDead ? 0 : ((probes["armed"] as? Int) ?? 0)
            let missed = (probes["missed"] as? Int) ?? 0
            lock.lock()
            let wasDisarmed = probesDisarmed
            probesDisarmed = total > 0 && armed < total
            let nowDisarmed = probesDisarmed
            lock.unlock()
            if nowDisarmed, !wasDisarmed {
                alarm("tampering", "\(total - armed) of the kernel sentry's \(total) probes were disarmed", weight: 20)
            }
            if missed > 0 {
                alarm("sentry_overflow", "kernel probes missed \(missed) hit(s)", weight: 2)
            }
        }
        guard type == "event", let kind = frame["kind"] as? String else { return }
        lock.lock(); eventsSeen += 1; lock.unlock()
        // `phase: boot` (Bromure's own helpers still assembling the VM) is
        // honoured only within the boot budget: past it, a boot label is
        // judged like any session event, and its persistence is reported.
        var fields = frame
        lock.lock(); let sinceAttach = Date().timeIntervalSince(attachedAt); lock.unlock()
        if (frame["phase"] as? String) == "shutdown" {
            // Honoured only briefly: a VM that keeps talking long after
            // "shutting down" is using the label to hide.
            lock.lock()
            let since = Date().timeIntervalSince(shutdownSeenAt ?? Date())
            if shutdownSeenAt == nil { shutdownSeenAt = Date() }
            let stale = since > KernelSentryService.shutdownBudget
            let first = stale && !reportedStuckShutdown
            if first { reportedStuckShutdown = true }
            let setBy = phaseSetBy
            lock.unlock()
            if stale { fields["phase"] = "session" }
            if first {
                alarm("sentry_shutdown_phase", "the kernel sentry still labels events as shutdown-time \(Int(KernelSentryService.shutdownBudget))s after the VM began shutting down" + (setBy.map { " (declared by \($0))" } ?? ""), weight: 0)
            }
        }
        if (frame["phase"] as? String) == "boot", sinceAttach > KernelSentryService.bootBudget {
            fields["phase"] = "session"
            lock.lock(); let first = !reportedStuckBoot; reportedStuckBoot = true; lock.unlock()
            if first {
                alarm("sentry_boot_phase", "the kernel sentry still labels events as boot-time \(Int(KernelSentryService.bootBudget))s after the VM started", weight: 0)
            }
        }
        guard let (weight, category) = KernelSentryService.classify(kind, fields, strict: strict) else {
            lock.lock(); counted[kind, default: 0] += 1; lock.unlock()
            return
        }
        var data: [String: AnyJSON] = ["kind": .string(kind), "category": .string(category), "weight": .int(weight)]
        for (k, v) in frame where !["type", "seq", "t", "kind", "dropped", "rate_limited"].contains(k) {
            switch v {
            case let s as String: data[k] = .string(String(s.prefix(512)))
            case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): data[k] = .int(n.intValue)
            case let b as Bool: data[k] = .bool(b)
            default: break
            }
        }
        if category == "sandbox_denial" {
            noteDenial(frame, now: now)
            guard admitDenialRow(frame, data, now: now) else { return }
        }
        emit("sentry.event", data)
    }

    // MARK: Sandbox denials

    /// Denials per program in the last `probingWindow`; a program that keeps
    /// hitting the sandbox's walls is probing for a way out.
    private var recentDenials: [String: [Date]] = [:]
    private var probingReported: [String: Date] = [:]
    /// The sandbox's allowed / denied tallies (from heartbeats) and when a
    /// summary was last put on the timeline.
    private var tallies: (allowed: Int, deniedFiles: Int, deniedSyscalls: Int) = (0, 0, 0)
    private var talliesReported: (allowed: Int, deniedFiles: Int, deniedSyscalls: Int) = (0, 0, 0)
    private var talliesReportedAt = Date.distantPast

    static let probingWindow: TimeInterval = 60
    static let probingThreshold = 20
    static let tallyInterval: TimeInterval = 300

    private func noteDenial(_ frame: [String: Any], now: Date = Date()) {
        let who = (frame["exe"] as? String)
            ?? ((frame["kind"] as? String) == "seccomp_denied" ? frame["path"] as? String : nil)
            ?? (frame["comm"] as? String) ?? "?"
        let count = max(1, frame["count"] as? Int ?? 1)
        lock.lock()
        var times = (recentDenials[who] ?? []).filter { now.timeIntervalSince($0) < Self.probingWindow }
        times.append(contentsOf: Array(repeating: now, count: min(count, 1000)))
        recentDenials[who] = times
        let fire = times.count >= Self.probingThreshold
            && now.timeIntervalSince(probingReported[who] ?? .distantPast) > Self.probingWindow * 5
        if fire { probingReported[who] = now }
        let n = times.count
        lock.unlock()
        if fire {
            alarm("sandbox_probing", "\(who) hit the sandbox's limits \(n) times in \(Int(Self.probingWindow))s — probing for a way out?",
                  weight: 10)
        }
    }

    /// Identical denials (same program, operation and target) inside
    /// `repeatWindow` share one timeline row: the first shows at once, the
    /// rest are summed and put on the timeline as one "×N" row when the window
    /// closes. The guest folds repeats per process; a shell loop spawns a new
    /// process each time, so the host folds across them.
    private var denialRepeats: [String: (firstAt: Date, count: Int, pids: Set<Int>, data: [String: AnyJSON])] = [:]
    static let repeatWindow: TimeInterval = 60

    static func denialKey(_ f: [String: Any]) -> String {
        let who = (f["exe"] as? String)
            ?? ((f["kind"] as? String) == "seccomp_denied" ? f["path"] as? String : nil)
            ?? (f["comm"] as? String) ?? "?"
        let what = (f["kind"] as? String) == "seccomp_denied"
            ? "sys:\((f["syscall"] as? NSNumber)?.intValue ?? -1)"
            : "\(f["op"] as? String ?? "")|\(f["path"] as? String ?? "")"
        return "\(f["kind"] as? String ?? "")|\(who)|\(what)"
    }

    /// True if this denial gets its own row now; false if it was folded into
    /// the row already shown for the same denial.
    private func admitDenialRow(_ f: [String: Any], _ data: [String: AnyJSON], now: Date) -> Bool {
        let key = Self.denialKey(f)
        let n = max(1, f["count"] as? Int ?? 1)
        let pid = f["pid"] as? Int ?? 0
        flushDenialRepeats(now: now)
        lock.lock(); defer { lock.unlock() }
        if var r = denialRepeats[key] {
            r.count += n; r.pids.insert(pid); r.data = data
            denialRepeats[key] = r
            return false
        }
        denialRepeats[key] = (now, 0, [], data)
        return true
    }

    /// Put each closed window's folded repeats on the timeline as one row.
    private func flushDenialRepeats(now: Date) {
        lock.lock()
        var out: [[String: AnyJSON]] = []
        for (key, r) in denialRepeats where now.timeIntervalSince(r.firstAt) >= Self.repeatWindow {
            denialRepeats[key] = nil
            guard r.count > 0 else { continue }
            var d = r.data
            d["count"] = .int(r.count)
            d["repeat"] = .bool(true)
            d["processes"] = .int(r.pids.count)
            d["pid"] = nil
            out.append(d)
        }
        lock.unlock()
        for d in out { emit("sentry.event", d) }
    }

    /// Tests: feed a denial event's fields as if received at `now`.
    func _testDenial(_ f: [String: Any], now: Date) {
        noteDenial(f, now: now)
        var data: [String: AnyJSON] = ["kind": .string(f["kind"] as? String ?? ""), "category": .string("sandbox_denial")]
        for (k, v) in f { if let s = v as? String { data[k] = .string(s) } else if let i = v as? Int { data[k] = .int(i) } }
        if admitDenialRow(f, data, now: now) { emit("sentry.event", data) }
    }
    func _testFlush(now: Date) { flushDenialRepeats(now: now) }

    private func noteTallies(_ sb: [String: Any], now: Date = Date()) {
        let t = (allowed: sb["allowed_file_ops"] as? Int ?? 0,
                 deniedFiles: sb["denied_file_ops"] as? Int ?? 0,
                 deniedSyscalls: sb["denied_syscalls"] as? Int ?? 0)
        lock.lock()
        tallies = t
        let changed = t != talliesReported
        let due = now.timeIntervalSince(talliesReportedAt) >= Self.tallyInterval
        let denialsGrew = t.deniedFiles > talliesReported.deniedFiles || t.deniedSyscalls > talliesReported.deniedSyscalls
        let report = changed && (due || (denialsGrew && now.timeIntervalSince(talliesReportedAt) >= 30))
        if report { talliesReported = t; talliesReportedAt = now }
        lock.unlock()
        if report {
            emit("sandbox.activity", ["allowed_file_ops": .int(t.allowed), "denied_file_ops": .int(t.deniedFiles),
                                      "denied_syscalls": .int(t.deniedSyscalls)])
        }
    }

    /// Tests: feed a heartbeat's sandbox tallies / a denial as if received.
    func _testTallies(_ sb: [String: Any], now: Date) { noteTallies(sb, now: now) }

    func checkLiveness(now: Date, running: Bool) {
        lock.lock()
        guard running else {
            // Paused / suspended: nothing is expected; restart the clocks.
            if lastFrameAt != nil { lastFrameAt = now }
            attachedAt = max(attachedAt, now.addingTimeInterval(-1))
            lock.unlock()
            return
        }
        var warn = false, trip = false, absent = false
        if let last = lastFrameAt {
            let silence = now.timeIntervalSince(last)
            if silence >= KernelSentryService.silenceTamper, !trippedSilence { trippedSilence = true; trip = true }
            else if silence >= KernelSentryService.silenceWarning, !warnedSilence { warnedSilence = true; warn = true }
        } else if now.timeIntervalSince(attachedAt) >= KernelSentryService.bootBudget, !reportedAbsent,
                  GuestSandboxStatusStore.shared.status(for: profileID)?.sentry != "pending" {
            // (Still pending = the guest is building a module; judge it once
            // it settles, as running, unavailable, or silent.)
            reportedAbsent = true
            absent = true
        }
        let silence = lastFrameAt.map { Int(now.timeIntervalSince($0)) } ?? 0
        lock.unlock()
        if trip {
            alarm("tampering", "the kernel sentry has been silent for \(silence)s", weight: 20)
        } else if warn {
            alarm("sentry_silent", "no heartbeat from the kernel sentry for \(silence)s", weight: 0)
        }
        if absent {
            // The guest's root side saying it couldn't load the module (a
            // kernel without a matching build, say) is a failure to report,
            // not an attack: only an unexplained absence is tampering, and
            // only when the sentry is required.
            let guest = GuestSandboxStatusStore.shared.status(for: profileID)
            if guest?.sentry == "unavailable" {
                alarm("sentry_unavailable",
                      "the kernel sentry couldn't start" + (guest?.sentryReason.map { ": \($0)" } ?? ""),
                      weight: 0)
            } else {
                alarm(requirement == .hard ? "tampering" : "sentry_unavailable",
                      "the kernel sentry never connected after boot", weight: requirement == .hard ? 20 : 0)
            }
        }
    }

    func crossCheck(guestSentry: String?, digest: String?) {
        lock.lock()
        let connected = fd >= 0
        let secret = pinnedSecret
        lock.unlock()
        guard connected, let secret, guestSentry != "pending" else { return }
        if guestSentry == "unavailable" || guestSentry == "off" {
            alarm("tampering", "something is connected on the sentry port while the guest reports the sentry \(guestSentry!) (impersonation)", weight: 20)
            return
        }
        if let digest, !digest.isEmpty,
           digest.lowercased() != Self.sha256Hex(secret) {
            alarm("tampering", "the connected sentry's secret doesn't match the one the guest kernel holds (impersonation)", weight: 20)
        }
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func alarm(_ kind: String, _ reason: String, weight: Int) {
        lock.lock(); alarms += 1; lock.unlock()
        FileHandle.standardError.write(Data("[sentry] \(profileID.uuidString.prefix(8)) \(kind): \(reason)\n".utf8))
        emit("sentry.alarm", ["kind": .string(kind), "reason": .string(reason), "weight": .int(weight)])
    }

    private func emit(_ type: String, _ data: [String: AnyJSON]) {
        tap?(type, data)
        BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: type, eventData: data)
    }
}

/// Which workspaces' VMs are running right now, published from the main
/// actor for the sentry's background liveness check.
final class KernelSentryRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Set<UUID> = []
    func set(_ s: Set<UUID>) { lock.lock(); running = s; lock.unlock() }
    func isRunning(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return running.contains(id) }
}
