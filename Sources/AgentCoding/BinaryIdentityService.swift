import Foundation
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
    private var gateResults: [GateKey: (verdict: EgressPolicy.Verdict?, exe: String?, at: Date)] = [:]

    struct GateKey: Hashable { let pid: UUID; let sport: UInt16; let dstIP: UInt32; let dport: UInt16 }

    /// Tests: answer attestor queries without a VM.
    var queryOverride: ((UUID, [String: Any]) async -> [String: Any]?)?

    /// A VM's attestor channel, listening (the host's vsock listener feeds
    /// it: BinaryIdentityService+VZ.swift on macOS).
    func adoptBridge(_ bridge: AttestorBridge, for profileID: UUID) {
        lock.lock(); bridges[profileID] = bridge; lock.unlock()
    }

    /// A VM's attestor channel gone, with what was pinned and gated for it.
    func dropBridge(_ profileID: UUID) -> AttestorBridge? {
        lock.lock()
        let b = bridges.removeValue(forKey: profileID)
        pinnedHashes[profileID] = nil
        gateResults = gateResults.filter { $0.key.pid != profileID }
        lock.unlock()
        return b
    }

    public func isAttestorConnected(_ profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bridges[profileID]?.isConnected ?? false
    }

    /// The program each recent connection was attested to, by destination
    /// ("pid|host-or-ip|port"): an Allow under Enforce binaries names it in the
    /// rule it adds, so the rule works at once and stays narrow.
    /// `guess`: filed under a name the connection was only guessed to be for
    /// (a DNS name cached for its IP), not one the flow itself named.
    private var recentExes: [String: (exe: String, at: Date, guess: Bool)] = [:]

    /// `replace: false` files the destinations as GUESSES (every DNS name
    /// cached for the connection's IP): a guess never displaces a program
    /// attested for that name within the hour, and a newer guess replaces an
    /// older one. (A first guess used to hold every name for the hour, so on
    /// a port the MiTM doesn't see, Allow named the first program to dial a
    /// shared CDN address, not the one just blocked — Finding CWE-284,
    /// "Drawer Allow keeps the first L4 program on a shared DNS name and
    /// ignores the program just blocked".)
    func noteExe(_ exe: String, profileID: UUID, destinations: [String], port: Int, replace: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-3600)
        for d in destinations where !d.isEmpty {
            let key = "\(profileID.uuidString)|\(d.lowercased())|\(port)"
            if !replace, let held = recentExes[key], held.at > cutoff, !held.guess {
                // Attested: kept (and stays attested when it's this program).
                if held.exe == exe { recentExes[key] = (exe, Date(), false) }
                continue
            }
            recentExes[key] = (exe, Date(), !replace)
        }
        if recentExes.count > 2048 {
            let cutoff = Date().addingTimeInterval(-3600)
            recentExes = recentExes.filter { $0.value.at > cutoff }
        }
    }

    /// The MiTM learned the flow's name (SNI or Host header) after asking
    /// by IP: file the attested program under the name as well, which is
    /// what the blocked row shows and what Allow looks it up by.
    public func noteHost(_ identity: OpenShellPolicy.BinaryIdentity?, profileID: UUID, host: String?, port: Int) {
        guard let identity, let host, !host.isEmpty, EgressPolicy.parseIPv4Address(host) == nil else { return }
        noteExe(identity.exe, profileID: profileID, destinations: [host], port: port)
    }

    /// The program that connected to `destinations` on `port` within the
    /// hour, as the attestor reported it — the FIRST destination with one, in
    /// the order given (a hostname, then its IP), a guessed name included.
    /// Not the newest across them: an IP is shared (a CDN address, or any
    /// guest process that dials it after a deny), so a later program there
    /// must not replace the one filed for the name on the row (Finding
    /// CWE-284, "Drawer Allow names whichever program last used the
    /// destination IP"; and "Drawer Allow on an L4 port names whoever last
    /// dialed the destination IP" for a name guessed from the DNS cache).
    public func recentExe(profileID: UUID, destinations: [String], port: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-3600)
        for d in destinations {
            if let r = recentExes["\(profileID.uuidString)|\(d.lowercased())|\(port)"], r.at > cutoff { return r.exe }
        }
        return nil
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
        noteExe(exe, profileID: profileID, destinations: [dst], port: Int(dport))
        return identity
    }

    /// `VMNetSwitch.identityGate`: decide a non-intercepted TCP connection for
    /// its attested binary. Returns nil (hold the SYN) while the attestor is
    /// being asked; the retransmitted SYN picks up the decision.
    public func gate(profileID: UUID, sport: UInt16, dstIP: UInt32, dport: UInt16,
                     hostnames: [String], policy: EgressPolicy) -> (verdict: EgressPolicy.Verdict, exe: String?)? {
        let key = GateKey(pid: profileID, sport: sport, dstIP: dstIP, dport: dport)
        lock.lock()
        if let (v, exe, at) = gateResults[key] {
            if let v { gateResults[key] = nil; lock.unlock(); return (v, exe) }
            if Date().timeIntervalSince(at) < 5 { lock.unlock(); return nil }   // still asking
        }
        gateResults[key] = (nil, nil, Date())
        if gateResults.count > 4096 {
            let cutoff = Date().addingTimeInterval(-30)
            gateResults = gateResults.filter { $0.value.at > cutoff }
        }
        lock.unlock()
        let dst = EgressPolicy.ipv4String(dstIP)
        Task {
            let id = await self.identity(profileID: profileID, sport: sport, dst: dst, dport: dport)
            // The names are every one cached for this IP — a guess at what
            // the connection was for (a shared CDN address has many): they
            // don't replace the program attested for any of them.
            if let id { self.noteExe(id.exe, profileID: profileID, destinations: hostnames, port: Int(dport), replace: false) }
            let v = policy.verdict(ip: dstIP, hostnames: hostnames, proto: .tcp, port: dport, identity: id)
            // The deny reports the program on its own event (the switch's
            // `EgressEvent.exe`): that event is the drawer row Allow acts on.
            self.lock.lock(); self.gateResults[key] = (v == .deny ? .deny : .allow, id?.exe, Date()); self.lock.unlock()
        }
        return nil
    }
}

/// One VM's attestor channel (newline-delimited JSON over vsock).
final class AttestorBridge: NSObject, @unchecked Sendable {
    let profileID: UUID
    let secretFile: URL
    private let lock = NSLock()
    private var fd: Int32 = -1
    /// What keeps the accepted connection alive while it serves (macOS's
    /// VZVirtioSocketConnection), if anything.
    private var connection: AnyObject?
    private var pinnedSecret: String?
    private var nextID = 1
    private var waiters: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]
    /// The host's listener feeding this channel (retained with it).
    var listener: AnyObject?

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

    /// The channel closed (the VM went).
    func stop() { closeChannel() }

    /// Validate the attestor's hello (secret pinning), then serve replies
    /// until the channel closes. Blocking; runs on its own thread.
    func handshakeAndServe(_ cfd: Int32, connection: AnyObject?) {
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
        Self.serveLines(&reader) { obj in
            // Unsolicited guest reports (no id): the sandbox launcher's status.
            if obj["id"] == nil, let event = obj["event"] as? String {
                if event == "sandbox_status" { GuestSandboxStatusStore.shared.update(profileID: profileID, report: obj) }
                return
            }
            guard let id = obj["id"] as? Int else { return }
            lock.lock(); let w = waiters.removeValue(forKey: id); lock.unlock()
            w?.resume(returning: obj)
        }
        closeChannel()
    }

    /// Hand each JSON line to `handle` until EOF. One pool per line: this
    /// runs on a raw Thread for the VM's lifetime, whose pool never drains,
    /// and every line's objects would stay alive until the VM stopped.
    static func serveLines(_ reader: inout LineReader, _ handle: ([String: Any]) -> Void) {
        while withAutoreleasePool({ () -> Bool in
            guard let line = reader.next() else { return false }
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(obj) }
            return true
        }) {}
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
struct LineReader {
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
