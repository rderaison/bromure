import Foundation
import Virtualization
import SandboxEngine

/// Host side of strict-sandbox binary identity (OpenShell RFC 0012): one
/// vsock channel per VM to the guest's root attestor (`bromure-attestd.py`),
/// which names the executable behind each outbound connection from kernel
/// state. Identity is only as trustworthy as the channel, so:
///
///  - the channel is the FIRST connection on vsock 5840, made by the attestor
///    before agentd drops the agent user's root paths; its hello carries a
///    secret that lives only in root-owned guest memory / `/run`, which the
///    host pins (persisted host-side, never in the guest-visible share). A
///    later connection without that secret — something the agent opened — is
///    refused and logged;
///  - every executable path's hash is pinned on first use (OpenShell's
///    trust-on-first-use): a changed binary at a known path is refused;
///  - any failure (no attestor, timeout, ambiguous answer) yields no identity,
///    and the policy then matches only Bromure's provider rules — fail closed.
public final class BinaryIdentityService: @unchecked Sendable {
    public static let shared = BinaryIdentityService()
    public static let vsockPort: UInt32 = 5840

    private let lock = NSLock()
    private var bridges: [UUID: AttestorBridge] = [:]
    /// Per profile: exe path → first-seen sha256 (OpenShell's TOFU rules).
    private var pinnedHashes: [UUID: OpenShellPolicy.BinaryPinStore] = [:]
    /// L4 decisions in flight / made, keyed by flow, for the switch gate.
    private var gateResults: [GateKey: (EgressPolicy.Verdict?, Date)] = [:]

    struct GateKey: Hashable { let pid: UUID; let sport: UInt16; let dstIP: UInt32; let dport: UInt16 }

    /// Tests: answer attestor queries without a VM.
    var queryOverride: ((UUID, [String: Any]) async -> [String: Any]?)?

    /// Start listening for a VM's attestor. `secretFile` is host-side storage
    /// for the pinned secret (survives a suspend / restore of the VM).
    @MainActor
    public func attach(profileID: UUID, socketDevice: VZVirtioSocketDevice, secretFile: URL) {
        let bridge = AttestorBridge(profileID: profileID, secretFile: secretFile)
        bridge.listen(on: socketDevice)
        lock.lock(); bridges[profileID] = bridge; lock.unlock()
    }

    @MainActor
    public func detach(profileID: UUID, socketDevice: VZVirtioSocketDevice?) {
        lock.lock()
        let b = bridges.removeValue(forKey: profileID)
        pinnedHashes[profileID] = nil
        gateResults = gateResults.filter { $0.key.pid != profileID }
        lock.unlock()
        b?.stop(socketDevice: socketDevice)
    }

    public func isAttestorConnected(_ profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bridges[profileID]?.isConnected ?? false
    }

    /// The attested identity of the guest socket `sport → dst:dport`, or nil.
    public func identity(profileID: UUID, sport: UInt16, dst: String, dport: UInt16) async
        -> OpenShellPolicy.BinaryIdentity? {
        // A strict revocation that didn't fully land leaves the agent a path
        // to root, so the attestor's answers can't be trusted: no identity,
        // and binary-scoped rules fail closed.
        if GuestSandboxStatusStore.shared.status(for: profileID)?.strictApplied == false {
            BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall", eventData: [
                "action": .string("deny"), "layer": .string("identity"), "host": .string(dst), "port": .int(Int(dport)),
                "reason": .string("the strict sandbox didn't fully apply in the VM, so binary identity can't be trusted")])
            return nil
        }
        let req: [String: Any] = ["op": "who", "sport": Int(sport), "dst": dst, "dport": Int(dport)]
        lock.lock(); let bridge = bridges[profileID]; lock.unlock()
        // Early in a boot the guest's attestor may not have connected yet;
        // wait briefly for it rather than failing binary rules closed on a
        // connection that raced it. (An attestor that never comes up still
        // fails closed after the wait.)
        if queryOverride == nil, let bridge, !bridge.isConnected,
           Date().timeIntervalSince(bridge.attachedAt) < 60 {
            for _ in 0..<40 where !bridge.isConnected {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let answer: [String: Any]?
        if let queryOverride { answer = await queryOverride(profileID, req) }
        else { answer = await bridge?.query(req) }
        guard let reply = answer,
              reply["ok"] as? Bool == true,
              let exe = reply["exe"] as? String, let sha = reply["sha256"] as? String else {
            return nil
        }
        let rawAncestors = reply["ancestors"] as? [[String: Any]] ?? []
        // OpenShell refuses an identity with a missing digest or a relative
        // path anywhere in the chain — so do we, rather than dropping links.
        let links: [(exe: String, sha256: String?)] = [(exe, sha)]
            + rawAncestors.map { ($0["exe"] as? String ?? "", $0["sha256"] as? String) }
        lock.lock()
        var store = pinnedHashes[profileID] ?? OpenShellPolicy.BinaryPinStore()
        let refusal = store.verifyOrPin(links)
        if refusal == nil { pinnedHashes[profileID] = store }
        lock.unlock()
        if let refusal {
            BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall", eventData: [
                "action": .string("deny"), "layer": .string("identity"), "host": .string(dst), "port": .int(Int(dport)),
                "reason": .string(refusal)])
            return nil
        }
        let identity = OpenShellPolicy.BinaryIdentity(
            exe: exe, sha256: sha,
            ancestors: links.dropFirst().map { .init(exe: $0.exe, sha256: $0.sha256 ?? "") })
        return identity
    }

    /// `VMNetSwitch.identityGate`: decide a non-intercepted TCP connection for
    /// its attested binary. Returns nil (hold the SYN) while the attestor is
    /// being asked; the retransmitted SYN picks up the decision.
    public func gate(profileID: UUID, sport: UInt16, dstIP: UInt32, dport: UInt16,
                     hostnames: [String], policy: EgressPolicy) -> EgressPolicy.Verdict? {
        let key = GateKey(pid: profileID, sport: sport, dstIP: dstIP, dport: dport)
        lock.lock()
        if let (v, at) = gateResults[key] {
            if let v { gateResults[key] = nil; lock.unlock(); return v }
            if Date().timeIntervalSince(at) < 5 { lock.unlock(); return nil }   // still asking
        }
        gateResults[key] = (nil, Date())
        if gateResults.count > 4096 {
            let cutoff = Date().addingTimeInterval(-30)
            gateResults = gateResults.filter { $0.value.1 > cutoff }
        }
        lock.unlock()
        let dst = EgressPolicy.ipv4String(dstIP)
        Task {
            let id = await self.identity(profileID: profileID, sport: sport, dst: dst, dport: dport)
            let v = policy.verdict(ip: dstIP, hostnames: hostnames, proto: .tcp, port: dport, identity: id)
            self.lock.lock(); self.gateResults[key] = (v == .deny ? .deny : .allow, Date()); self.lock.unlock()
        }
        return nil
    }
}

/// One VM's attestor channel (newline-delimited JSON over vsock).
final class AttestorBridge: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    let profileID: UUID
    let secretFile: URL
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var connection: VZVirtioSocketConnection?
    private var pinnedSecret: String?
    private var nextID = 1
    private var waiters: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]
    private var listener: VZVirtioSocketListener?

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }
    /// When this bridge started listening (the VM's boot, for a fresh start).
    let attachedAt = Date()

    init(profileID: UUID, secretFile: URL) {
        self.profileID = profileID
        self.secretFile = secretFile
        self.pinnedSecret = (try? String(contentsOf: secretFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        super.init()
    }

    @MainActor func listen(on device: VZVirtioSocketDevice) {
        let l = VZVirtioSocketListener()
        l.delegate = self
        listener = l
        device.setSocketListener(l, forPort: BinaryIdentityService.vsockPort)
    }

    @MainActor func stop(socketDevice: VZVirtioSocketDevice?) {
        socketDevice?.removeSocketListener(forPort: BinaryIdentityService.vsockPort)
        closeChannel()
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let cfd = dup(connection.fileDescriptor)
        guard cfd >= 0 else { return false }
        Thread.detachNewThread { [weak self] in self?.handshakeAndServe(cfd, connection: connection) }
        return true
    }

    /// Validate the attestor's hello (secret pinning), then serve replies
    /// until the channel closes. Blocking; runs on its own thread.
    func handshakeAndServe(_ cfd: Int32, connection: VZVirtioSocketConnection?) {
        var reader = LineReader(fd: cfd)
        // The hello must come promptly and carry the attestor's secret.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let helloLine = reader.next(),
              let hello = try? JSONSerialization.jsonObject(with: helloLine) as? [String: Any],
              hello["hello"] as? String == "attestd",
              let secret = hello["secret"] as? String, secret.count == 64 else {
            close(cfd); return
        }
        lock.lock()
        let pinned = pinnedSecret
        let busy = fd >= 0
        let accept = !busy && (pinned == nil || pinned == secret)
        if accept {
            fd = cfd
            self.connection = connection
            if pinned == nil {
                pinnedSecret = secret
                try? secret.write(to: secretFile, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretFile.path)
            }
        }
        lock.unlock()
        guard accept else {
            close(cfd)
            FileHandle.standardError.write(Data("[identity] refused an attestor connection for \(profileID) (\(busy ? "channel taken" : "wrong secret"))\n".utf8))
            BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall", eventData: [
                "action": .string("deny"), "layer": .string("identity"), "host": .string("attestor"), "port": .int(Int(BinaryIdentityService.vsockPort)),
                "reason": .string("refused an attestor connection that isn't the pinned one — possible impersonation attempt")])
            return
        }
        FileHandle.standardError.write(Data("[identity] attestor connected for \(profileID)\n".utf8))
        tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while let line = reader.next() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            // Unsolicited guest reports (no id): the sandbox launcher's status.
            if obj["id"] == nil, let event = obj["event"] as? String {
                if event == "sandbox_status" { GuestSandboxStatusStore.shared.update(profileID: profileID, report: obj) }
                continue
            }
            guard let id = obj["id"] as? Int else { continue }
            lock.lock(); let w = waiters.removeValue(forKey: id); lock.unlock()
            w?.resume(returning: obj)
        }
        closeChannel()
    }

    private func closeChannel() {
        lock.lock()
        let f = fd
        fd = -1
        connection = nil
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        if f >= 0 { close(f) }
        for (_, w) in pending { w.resume(returning: nil) }
    }

    /// One request/response, nil on no channel or a 1 s timeout.
    func query(_ req: [String: Any]) async -> [String: Any]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            lock.lock()
            guard fd >= 0 else { lock.unlock(); cont.resume(returning: nil); return }
            let id = nextID
            nextID += 1
            waiters[id] = cont
            let f = fd
            lock.unlock()
            var body = req
            body["id"] = id
            var line = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            line.append(0x0A)
            let ok = line.withUnsafeBytes { raw -> Bool in
                var off = 0
                while off < line.count {
                    let n = write(f, raw.baseAddress! + off, line.count - off)
                    if n <= 0 { return false }
                    off += n
                }
                return true
            }
            if !ok { finish(id, nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.finish(id, nil) }
        }
    }

    private func finish(_ id: Int, _ value: [String: Any]?) {
        lock.lock(); let w = waiters.removeValue(forKey: id); lock.unlock()
        w?.resume(returning: value)
    }
}

/// Blocking newline reader over a raw fd.
private struct LineReader {
    let fd: Int32
    var buffer = Data()
    init(fd: Int32) { self.fd = fd }

    mutating func next() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 4 * 1024 * 1024 { return nil }
        }
    }
}

// MARK: - Guest sandbox status

/// What the guest's root launcher reported about OpenShell's
/// filesystem_policy / landlock / process enforcement (on the attestor
/// channel, `{"event":"sandbox_status",…}`), per workspace. A change is
/// recorded on the Security Timeline (and so in OCSF), and a sandbox that
/// failed or degraded is a watchdog signal.
public final class GuestSandboxStatusStore: @unchecked Sendable {
    public static let shared = GuestSandboxStatusStore()

    public struct Status: Equatable, Sendable {
        public var filesystem: String          // enforced / degraded / failed / off
        public var degradedReason: String?
        public var landlockABI: Int?
        public var seccomp: String?
        public var runAsUser: String?
        public var runAsUID: Int?
        public var sentry: String?             // running / unavailable / off
        /// Why the sentry is unavailable (kernel mismatch, no headers, …).
        public var sentryReason: String?
        /// The strict revocation: true = every privilege path removed,
        /// false = attempted but not fully applied, nil = not a strict boot.
        public var strictApplied: Bool?
        public var additionsReadWrite: [String]
        public var additionsReadOnly: [String]
        /// Guest-side caveats (e.g. the run_as uid can't write a workdir).
        public var warnings: [String]
        /// The supervisor restarted the sandboxed session server this many
        /// times (kill-server, last window closed, …).
        public var serverRestarts: Int
        public var receivedAt: Date
    }

    private let lock = NSLock()
    private var statuses: [UUID: Status] = [:]
    /// Fired on every change (UI refresh).
    public var onChange: (@Sendable (UUID) -> Void)?

    public func status(for profileID: UUID) -> Status? {
        lock.lock(); defer { lock.unlock() }
        return statuses[profileID]
    }

    public func reset(profileID: UUID) {
        lock.lock(); statuses[profileID] = nil; lock.unlock()
        onChange?(profileID)
    }

    func update(profileID: UUID, report r: [String: Any], now: Date = Date()) {
        // The guest hasn't assembled its sandbox yet: nothing to record, and
        // nothing to cross-check (an early "off" would read as an impostor).
        if r["filesystem"] as? String == "pending" { return }
        let runAs = r["run_as"] as? [String: Any]
        let additions = r["additions"] as? [String: Any]
        let st = Status(
            filesystem: r["filesystem"] as? String ?? "off",
            degradedReason: r["degraded_reason"] as? String,
            landlockABI: r["landlock_abi"] as? Int,
            seccomp: r["seccomp"] as? String,
            runAsUser: runAs?["user"] as? String,
            runAsUID: runAs?["uid"] as? Int,
            sentry: r["sentry"] as? String,
            sentryReason: r["sentry_reason"] as? String,
            strictApplied: r["strict_applied"] as? Bool,
            additionsReadWrite: additions?["read_write"] as? [String] ?? [],
            additionsReadOnly: additions?["read_only"] as? [String] ?? [],
            warnings: r["warnings"] as? [String] ?? [],
            serverRestarts: r["server_restarts"] as? Int ?? 0,
            receivedAt: now)
        lock.lock()
        let previous = statuses[profileID]
        statuses[profileID] = st
        lock.unlock()
        KernelSentryService.shared.crossCheck(profileID: profileID, guestSentry: st.sentry,
                                              digest: r["sentry_digest"] as? String)
        // Restarts of the sandboxed session server: a burst means something
        // keeps killing it (the first step of trying to get an unsandboxed
        // replacement) — a watchdog signal.
        let restartDelta = st.serverRestarts - (previous?.serverRestarts ?? 0)
        if restartDelta >= 3 {
            BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "sentry.alarm", eventData: [
                "kind": .string("tampering"), "weight": .int(10),
                "reason": .string("the sandboxed session server was restarted \(restartDelta) times"),
            ])
        }
        var comparable = st; comparable.receivedAt = previous?.receivedAt ?? now
        guard previous != comparable else { return }
        // Into the app log too (tee'd to bromure-ac.log): when a sandboxed
        // workspace has no session, the guest's own explanation is here.
        let tag = profileID.uuidString.prefix(8)
        var line = "[sandbox] \(tag) filesystem=\(st.filesystem) seccomp=\(st.seccomp ?? "-") run_as=\(st.runAsUser ?? "-") sentry=\(st.sentry ?? "-")"
        if let v = st.strictApplied { line += " strict_applied=\(v)" }
        if let v = st.degradedReason { line += " reason=\(v)" }
        // Which guest code produced this (short script hashes), so a run can't
        // be mistaken for one of a different delivery.
        if let build = r["build"] as? [String: Any], !build.isEmpty {
            line += " build=" + build.keys.sorted().map { "\($0):\(build[$0].map { "\($0)" } ?? "?")" }.joined(separator: ",")
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        for w in st.warnings where !(previous?.warnings.contains(w) ?? false) {
            FileHandle.standardError.write(Data("[sandbox] \(tag) warning: \(w)\n".utf8))
        }
        var data: [String: AnyJSON] = [
            "filesystem": .string(st.filesystem),
            "action": .string(st.filesystem == "failed" || st.filesystem == "degraded" ? "degraded"
                              : st.filesystem == "off" ? "off" : "enforced"),
        ]
        if let v = st.degradedReason { data["reason"] = .string(v) }
        if let v = st.landlockABI { data["landlock_abi"] = .int(v) }
        if let v = st.seccomp { data["seccomp"] = .string(v) }
        if let v = st.runAsUser { data["run_as"] = .string(v) }
        if let v = st.sentry { data["sentry"] = .string(v) }
        if let v = st.sentryReason { data["sentry_reason"] = .string(v) }
        if let v = st.strictApplied { data["strict_applied"] = .bool(v) }
        if !st.additionsReadWrite.isEmpty { data["additions_rw"] = .array(st.additionsReadWrite.map { .string($0) }) }
        if !st.additionsReadOnly.isEmpty { data["additions_ro"] = .array(st.additionsReadOnly.map { .string($0) }) }
        if !st.warnings.isEmpty { data["warnings"] = .array(st.warnings.map { .string($0) }) }
        BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "sandbox.status", eventData: data)
        onChange?(profileID)
    }
}
