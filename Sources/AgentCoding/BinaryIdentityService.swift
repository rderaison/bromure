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
    /// L4 attestations queued / in flight / made, per profile, keyed by
    /// flow, for the switch gate. Bounded: `maxGateEntries` per profile, and
    /// at most `maxGateQueries` attestor questions in flight for one; the
    /// flows waiting for a slot are asked in arrival order.
    private var gateResults: [UUID: [GateKey: GateEntry]] = [:]
    private var gateQueries: [UUID: Int] = [:]
    private var gateQueue: [UUID: [GateKey]] = [:]

    /// A flow: its 4-tuple and the SYN's initial sequence number, so a
    /// decision can't be inherited by another socket that later binds the
    /// same source port (nil: a policy change re-deciding an open flow).
    struct GateKey: Hashable { let sport: UInt16; let dstIP: UInt32; let dport: UInt16; let isn: UInt32? }
    struct GateEntry {
        enum State { case queued, asking, answered }
        var state: State
        /// The attested identity once answered (nil: none); the verdict is
        /// computed from it against the policy at use.
        var identity: OpenShellPolicy.BinaryIdentity?
        var at: Date
        /// The DNS names cached for the address (a guess at what it's for),
        /// at most `maxGateHostnames`, kept only until the flow is asked.
        var hostnames: [String]
        /// Last handed to the switch.
        var lastUse: Date
        /// Handed to the switch as an allow: the switch remembers the flow
        /// itself, so this is the first answer to give way when full.
        var allowed = false
    }
    /// How long an answer stands for its SYN: the guest's whole SYN retry
    /// horizon (Linux: +1, 2, 4, 8, 16, 32 s, ~127 s in all), so a lost
    /// SYN-ACK or a slow answer never times an allowed connection out.
    static let gateDecidedTTL: TimeInterval = 130
    /// A question unanswered this long is asked again.
    static let gateAskWindow: TimeInterval = 15
    static let maxGateEntries = 1024
    static let maxGateHostnames = 16
    static let maxGateQueries = 32
    /// The gate's clock (tests move it).
    var clock: @Sendable () -> Date = { Date() }

    /// Tests: answer attestor queries without a VM.
    var queryOverride: ((UUID, [String: Any]) async -> [String: Any]?)?

    /// Start listening for a VM's attestor. `secretFile` is host-side storage
    /// for the pinned secret (survives a suspend / restore of the VM).
    @MainActor
    /// `restoring`: a VM taken back, whose attestor must present the
    /// secret pinned on disk (none: refused).
    public func attach(profileID: UUID, socketDevice: VZVirtioSocketDevice, secretFile: URL,
                       restoring: Bool, strict: Bool) {
        let bridge = AttestorBridge(profileID: profileID, secretFile: secretFile, mayPin: !restoring, strict: strict)
        bridge.listen(on: socketDevice)
        adoptBridge(bridge, for: profileID)
    }

    /// A VM's attestor channel, listening (tests adopt one with no VM).
    func adoptBridge(_ bridge: AttestorBridge, for profileID: UUID) {
        lock.lock(); bridges[profileID] = bridge; lock.unlock()
    }

    @MainActor
    public func detach(profileID: UUID, socketDevice: VZVirtioSocketDevice?) {
        lock.lock()
        let b = bridges.removeValue(forKey: profileID)
        pinnedHashes[profileID] = nil
        gateResults[profileID] = nil
        gateQueue[profileID] = nil
        lock.unlock()
        b?.stop(socketDevice: socketDevice)
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
        if case .identity(let id) = await attest(profileID: profileID, sport: sport, dst: dst, dport: dport) { return id }
        return nil
    }

    /// An attestation: the identity (nil: none, decided), or not yet
    /// decidable (a strict workspace whose sandbox status isn't known:
    /// asked again later, never remembered as a deny).
    enum Attestation { case identity(OpenShellPolicy.BinaryIdentity?), notYet }

    func attest(profileID: UUID, sport: UInt16, dst: String, dport: UInt16) async -> Attestation {
        lock.lock(); let bridge = bridges[profileID]; lock.unlock()
        // Early in a boot the guest's attestor may not have connected yet;
        // wait briefly for it rather than failing binary rules closed on a
        // connection that raced it. (An attestor that never comes up still
        // fails closed after the wait.)
        if queryOverride == nil, let bridge, !bridge.isConnected,
           Date().timeIntervalSince(bridge.attachedAt) < AttestorBridge.statusGrace {
            for _ in 0..<40 where !bridge.isConnected {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        // A strict workspace's status not heard yet (a VM taken back, whose
        // store starts empty, or one just booted): ask the guest for it
        // before trusting any answer. Stored only if nothing newer came
        // pushed meanwhile.
        if queryOverride == nil, let bridge, bridge.strict,
           GuestSandboxStatusStore.shared.status(for: profileID) == nil {
            await bridge.askSandboxStatus()
        }
        // A strict revocation that didn't fully land leaves the agent a path
        // to root, so the attestor's answers can't be trusted: no identity,
        // and binary-scoped rules fail closed.
        let status = GuestSandboxStatusStore.shared.status(for: profileID)
        if status?.strictApplied == false {
            BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall", eventData: [
                "action": .string("deny"), "layer": .string("identity"), "host": .string(dst), "port": .int(Int(dport)),
                "reason": .string("the strict sandbox didn't fully apply in the VM, so binary identity can't be trusted")])
            return .identity(nil)
        }
        // A strict workspace counts only once the guest has said its
        // revocation applied. Not said yet (no status, or one without
        // `strict_applied`: the guest's status module can come up to ~80 s
        // after its attestor on a spec-less strict boot): not yet, while the
        // channel is up or the VM just attached. With no channel past that
        // (a VM taken back that can't pin, an attestor that died): no
        // identity, so the deny, its event and the RST happen.
        if queryOverride == nil, let bridge, bridge.strict, status?.strictApplied != true {
            if bridge.isConnected || Date().timeIntervalSince(bridge.attachedAt) < AttestorBridge.statusGrace {
                return .notYet
            }
            if bridge.noteStatusOverdue() {
                BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "sandbox.status", eventData: [
                    "state": .string("unknown"),
                    "reason": .string("the strict VM's sandbox status never reached the host (no attestor channel): binary rules fail closed")])
            }
            return .identity(nil)
        }
        let req: [String: Any] = ["op": "who", "sport": Int(sport), "dst": dst, "dport": Int(dport)]
        let answer: [String: Any]?
        if let queryOverride { answer = await queryOverride(profileID, req) }
        else { answer = await bridge?.query(req) }
        guard let reply = answer,
              reply["ok"] as? Bool == true,
              let exe = reply["exe"] as? String, let sha = reply["sha256"] as? String else {
            return .identity(nil)
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
            return .identity(nil)
        }
        let identity = OpenShellPolicy.BinaryIdentity(
            exe: exe, sha256: sha,
            ancestors: links.dropFirst().map { .init(exe: $0.exe, sha256: $0.sha256 ?? "") })
        noteExe(exe, profileID: profileID, destinations: [dst], port: Int(dport))
        return .identity(identity)
    }

    /// `VMNetSwitch.identityGate`: decide a non-intercepted TCP connection for
    /// its attested binary. Returns nil (hold the SYN) while the attestor is
    /// being asked; a retransmitted SYN picks up the answer, decided against
    /// the policy it's checked under then. `isn`: the SYN's initial sequence
    /// number (nil for an open flow re-decided after a policy change). A
    /// profile whose table is full of flows still being decided holds more.
    public func gate(profileID: UUID, sport: UInt16, dstIP: UInt32, dport: UInt16, isn: UInt32?,
                     hostnames: [String], policy: EgressPolicy) -> (verdict: EgressPolicy.Verdict, exe: String?)? {
        let key = GateKey(sport: sport, dstIP: dstIP, dport: dport, isn: isn)
        let now = clock()
        lock.lock()
        if let held = gateResults[profileID]?[key] {
            let age = now.timeIntervalSince(held.at)
            switch held.state {
            case .answered where age <= Self.gateDecidedTTL:
                // Reusable by this SYN's retransmits until it expires.
                lock.unlock()
                let v = policy.verdict(ip: dstIP, hostnames: hostnames, proto: .tcp, port: dport, identity: held.identity)
                lock.lock()
                gateResults[profileID]?[key]?.lastUse = now
                if v != .deny { gateResults[profileID]?[key]?.allowed = true }
                lock.unlock()
                // The deny reports the program on its own event (the switch's
                // `EgressEvent.exe`): that event is the drawer row Allow acts on.
                return (v == .deny ? .deny : .allow, held.identity?.exe)
            case .queued:
                lock.unlock(); return nil                         // waiting its turn
            case .asking where age < Self.gateAskWindow:
                lock.unlock(); return nil                         // still asking
            default:
                gateResults[profileID]?[key] = nil                // expired: asked again
            }
        }
        if gateResults[profileID, default: [:]].count >= Self.maxGateEntries {
            // Expired answers and abandoned questions go; then, only as far
            // as needed, the least recently used answer, one the switch
            // already remembers first. (Only when full: the table is
            // otherwise changed in place.)
            var table = gateResults.removeValue(forKey: profileID) ?? [:]
            table = table.filter {
                let age = now.timeIntervalSince($0.value.at)
                switch $0.value.state {
                case .answered: return age <= Self.gateDecidedTTL
                case .asking: return age < Self.gateAskWindow
                case .queued: return true
                }
            }
            if table.count >= Self.maxGateEntries,
               let victim = table.filter({ $0.value.state == .answered }).min(by: {
                   $0.value.allowed != $1.value.allowed ? $0.value.allowed : $0.value.lastUse < $1.value.lastUse
               }) {
                table[victim.key] = nil
            }
            let full = table.count >= Self.maxGateEntries
            gateResults[profileID] = table
            // Full of flows still being decided: hold it (fail closed, no RST).
            guard !full else { lock.unlock(); return nil }
        }
        let ask = gateQueries[profileID, default: 0] < Self.maxGateQueries
        let names = Array(hostnames.prefix(Self.maxGateHostnames))
        gateResults[profileID, default: [:]][key] = GateEntry(state: ask ? .asking : .queued, identity: nil, at: now,
                                                              hostnames: ask ? [] : names, lastUse: now)
        if ask { gateQueries[profileID, default: 0] += 1 } else { gateQueue[profileID, default: []].append(key) }
        lock.unlock()
        if ask { startQuery(profileID, key, hostnames: names) }
        return nil
    }

    /// Ask the attestor about `key`'s flow; when it answers, the next flow
    /// waiting for a slot is asked.
    private func startQuery(_ profileID: UUID, _ key: GateKey, hostnames: [String]) {
        Task {
            let answer = await self.attest(profileID: profileID, sport: key.sport,
                                           dst: EgressPolicy.ipv4String(key.dstIP), dport: key.dport)
            let id: OpenShellPolicy.BinaryIdentity?
            if case .identity(let i) = answer { id = i } else { id = nil }
            // The names are every one cached for this IP — a guess at what
            // the connection was for (a shared CDN address has many): they
            // don't replace the program attested for any of them.
            if let id { self.noteExe(id.exe, profileID: profileID, destinations: hostnames, port: Int(key.dport), replace: false) }
            self.lock.lock()
            // Only into a question still pending (not pruned, nor the VM gone).
            if self.gateResults[profileID]?[key]?.state == .asking {
                if case .notYet = answer {
                    // Not decidable yet: forgotten, so the SYN's retransmit
                    // asks again; never a remembered deny.
                    self.gateResults[profileID]?[key] = nil
                } else {
                    self.gateResults[profileID]?[key]?.state = .answered
                    self.gateResults[profileID]?[key]?.identity = id
                    self.gateResults[profileID]?[key]?.at = self.clock()
                }
            }
            // The slot passes to the oldest flow still waiting, if any.
            var next: (GateKey, [String])?
            while next == nil, var queue = self.gateQueue[profileID], !queue.isEmpty {
                let k = queue.removeFirst()
                self.gateQueue[profileID] = queue.isEmpty ? nil : queue
                if self.gateResults[profileID]?[k]?.state == .queued {
                    self.gateResults[profileID]?[k]?.state = .asking
                    self.gateResults[profileID]?[k]?.at = self.clock()
                    next = (k, self.gateResults[profileID]?[k]?.hostnames ?? [])
                    self.gateResults[profileID]?[k]?.hostnames = []
                }
            }
            if next == nil {
                let left = self.gateQueries[profileID, default: 1] - 1
                self.gateQueries[profileID] = left > 0 ? left : nil
            }
            self.lock.unlock()
            if let (k, names) = next { self.startQuery(profileID, k, hostnames: names) }
        }
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
    /// Bumped on each accepted channel: a close for an older one is a no-op.
    private(set) var generation: UInt64 = 0
    /// Serialises writes, and closes against them.
    private let writeLock = NSLock()
    private var lastRefusalReport = Date.distantPast
    static let refusalReportEvery: TimeInterval = 30
    /// How long after attaching a strict VM may stay undecided with no channel.
    static let statusGrace: TimeInterval = 30
    private var statusOverdueSaid = false
    private var statusAsk: Task<Void, Never>?

    /// True the first time: the strict status is overdue (said once).
    func noteStatusOverdue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if statusOverdueSaid { return false }
        statusOverdueSaid = true
        return true
    }

    /// Ask the guest for its sandbox status (stored only if nothing newer
    /// came pushed meanwhile); concurrent asks share one question.
    func askSandboxStatus() async {
        lock.lock()
        let task: Task<Void, Never>
        if let running = statusAsk { task = running } else {
            task = Task { [weak self] in
                guard let self else { return }
                if let reply = await self.query(["op": "sandbox_status"]),
                   reply["ok"] as? Bool == true, let report = reply["status"] as? [String: Any] {
                    GuestSandboxStatusStore.shared.update(profileID: self.profileID, report: report, onlyIfAbsent: true)
                }
                self.lock.lock(); self.statusAsk = nil; self.lock.unlock()
            }
            statusAsk = task
        }
        lock.unlock()
        await task.value
    }
    /// A strict-sandbox workspace: its attestor's answers count only once
    /// the guest has reported the revocation applied.
    let strict: Bool
    /// Connections waiting for their hello (each holds a thread), oldest
    /// first.
    private var pendingHandshakes: [(fd: Int32, at: Date)] = []
    static let maxPendingHandshakes = 4
    /// The hello: whole, within this long, and at most this size (attestd
    /// says it the moment it connects).
    static let helloDeadline: TimeInterval = 1
    static let maxHelloBytes = 4096

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }
    /// When this bridge started listening (the VM's boot, for a fresh start).
    var attachedAt = Date()

    /// `mayPin`: a fresh boot, whose attestor says hello before any agent
    /// code runs, pins the first secret it hears. A VM taken back (or
    /// restored) has its agent running already: without a valid pin on
    /// disk it refuses every hello, rather than let whoever connects first
    /// be trusted.
    init(profileID: UUID, secretFile: URL, mayPin: Bool, strict: Bool) {
        self.profileID = profileID
        self.secretFile = secretFile
        self.strict = strict
        // An empty file (a write cut short by a power loss) is no pin.
        let saved = (try? String(contentsOf: secretFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.pinnedSecret = saved?.isEmpty == false ? saved : nil
        self.mayPin = mayPin
        super.init()
        Self.removeTempLeftovers(of: secretFile)
    }

    private let mayPin: Bool
    private var saidUnpinnable = false

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
        guard admitHandshake(cfd) else { close(cfd); return false }
        Thread.detachNewThread { [weak self] in self?.handshakeAndServe(cfd, connection: connection) }
        return true
    }

    /// A new connection `fd` starts its handshake (handshakeAndServe next).
    /// At most `maxPendingHandshakes` wait for their hello at once: past
    /// that the OLDEST is cut off, so connections that never say hello
    /// can't keep the real attestor (which says it at once) out.
    /// Only one that has had `minPendingAge` to say hello is cut off; past
    /// that, the newcomer waits its turn (refused). False: refused (the
    /// caller closes it).
    @discardableResult
    func admitHandshake(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if pendingHandshakes.count >= Self.maxPendingHandshakes {
            guard now.timeIntervalSince(pendingHandshakes[0].at) >= Self.minPendingAge else { return false }
            // Its thread's poll wakes and gives up; it closes the fd.
            shutdown(pendingHandshakes.removeFirst().fd, Int32(SHUT_RDWR))
            evictions.append(now)
            evictions.removeAll { now.timeIntervalSince($0) > 10 }
            if evictions.count >= Self.evictionStorm, now.timeIntervalSince(lastStormReport) > 10 {
                lastStormReport = now
                FileHandle.standardError.write(Data("[identity] \(evictions.count) silent attestor connections cut off in 10 s for \(profileID): something in the VM is flooding vsock \(BinaryIdentityService.vsockPort)\n".utf8))
                BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall", eventData: [
                    "action": .string("deny"), "layer": .string("identity"), "host": .string("attestor"), "port": .int(Int(BinaryIdentityService.vsockPort)),
                    "reason": .string("many connections to the attestor's port that never said hello: something in the VM may be trying to crowd the attestor out")])
            }
        }
        pendingHandshakes.append((fd, now))
        return true
    }
    private var evictions: [Date] = []
    private var lastStormReport = Date.distantPast
    static let minPendingAge: TimeInterval = 0.1
    static let evictionStorm = 20

    /// Validate the attestor's hello (secret pinning), then serve replies
    /// until the channel closes. Blocking; runs on its own thread. The
    /// connection was admitted (admitHandshake).
    func handshakeAndServe(_ cfd: Int32, connection: VZVirtioSocketConnection?) {
        var reader = LineReader(fd: cfd)
        // The hello must come whole and promptly, small, and carry the
        // attestor's secret.
        let helloLine = Self.readHello(cfd, into: &reader)
        // Out of the pending list before the fd can be closed (and reused).
        lock.lock(); pendingHandshakes.removeAll { $0.fd == cfd }; lock.unlock()
        guard let helloLine,
              let hello = try? JSONSerialization.jsonObject(with: helloLine) as? [String: Any],
              hello["hello"] as? String == "attestd",
              let secret = hello["secret"] as? String, secret.count == 64 else {
            close(cfd); return
        }
        lock.lock()
        let pinned = pinnedSecret
        let busy = fd >= 0
        let unpinnable = pinned == nil && !mayPin
        // attestd retries every second: said once, not every time.
        let quiet = unpinnable && saidUnpinnable
        if unpinnable { saidUnpinnable = true }
        let accept = !busy && !unpinnable && (pinned == nil || pinned == secret)
        let quietRefusal = !accept && !unpinnable && Date().timeIntervalSince(lastRefusalReport) < Self.refusalReportEvery
        if !accept, !unpinnable, !quietRefusal { lastRefusalReport = Date() }
        if accept {
            fd = cfd
            generation &+= 1
            self.connection = connection
            // A query's write never blocks for long on a stalled guest, nor
            // raises SIGPIPE when the guest has gone (Darwin; the Linux
            // daemon ignores SIGPIPE process-wide).
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            if pinned == nil {
                // Pinned for this run either way; only a saved pin survives
                // a restart of the host, so a failed save is said.
                pinnedSecret = secret
                if !Self.writeSecret(secret, to: secretFile) {
                    FileHandle.standardError.write(Data("[identity] couldn't save the attestor's pinned secret for \(profileID) (\(String(cString: strerror(errno)))); pinned until the host restarts\n".utf8))
                }
            }
        }
        lock.unlock()
        guard accept else {
            close(cfd)
            if quiet { return }
            if unpinnable {
                FileHandle.standardError.write(Data("[identity] refused an attestor connection for \(profileID) (no pinned secret for a VM taken back); every later one is refused too\n".utf8))
                BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall", eventData: [
                    "action": .string("deny"), "layer": .string("identity"), "host": .string("attestor"), "port": .int(Int(BinaryIdentityService.vsockPort)),
                    "reason": .string("the VM was taken back without its attestor's pinned secret: binary identity stays off (binary rules fail closed) until it restarts")])
                return
            }
            if quietRefusal { return }                          // reported once per refusalReportEvery
            let why = busy ? "channel taken" : unpinnable ? "no pinned secret for a VM taken back" : "wrong secret"
            FileHandle.standardError.write(Data("[identity] refused an attestor connection for \(profileID) (\(why))\n".utf8))
            BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall", eventData: [
                "action": .string("deny"), "layer": .string("identity"), "host": .string("attestor"), "port": .int(Int(BinaryIdentityService.vsockPort)),
                "reason": .string("refused an attestor connection that isn't the pinned one — possible impersonation attempt")])
            return
        }
        lock.lock(); let myGeneration = generation; lock.unlock()
        FileHandle.standardError.write(Data("[identity] attestor connected for \(profileID)\n".utf8))
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
        closeChannel(generation: myGeneration)
    }

    /// The first line, within `helloDeadline` overall (a trickle doesn't
    /// extend it) and `maxHelloBytes`; what follows it stays in `reader`.
    static func readHello(_ fd: Int32, into reader: inout LineReader) -> Data? {
        let deadline = Date().addingTimeInterval(helloDeadline)
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: maxHelloBytes)
        while true {
            if let nl = buf.firstIndex(of: 0x0A) {
                reader.buffer = buf.subdata(in: buf.index(after: nl)..<buf.endIndex)
                return buf.subdata(in: buf.startIndex..<nl)
            }
            guard buf.count < maxHelloBytes else { return nil }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, Int32(max(1, min(left * 1000, 60_000))))
            if r < 0, errno == EINTR { continue }
            guard r > 0 else { return nil }
            let n = read(fd, &chunk, maxHelloBytes - buf.count)
            guard n > 0 else { return nil }
            buf.append(contentsOf: chunk[0..<n])
        }
    }

    /// The pinned secret, created 0600 (never readable in between), on
    /// disk before it's renamed into place.
    static func writeSecret(_ secret: String, to url: URL) -> Bool {
        let tmp = url.path + tempMarker + UUID().uuidString
        let f = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard f >= 0 else { return false }
        let bytes = Array(secret.utf8)
        let ok = bytes.withUnsafeBytes { write(f, $0.baseAddress, $0.count) } == bytes.count && fsync(f) == 0
        close(f)
        guard ok, rename(tmp, url.path) == 0 else { unlink(tmp); return false }
        // The rename itself on disk too.
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { return false }
        defer { close(dir) }
        return fsync(dir) == 0
    }

    static let tempMarker = ".tmp-"

    /// Temp files a save cut short left beside the secret.
    static func removeTempLeftovers(of url: URL) {
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + tempMarker
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Hand each JSON line to `handle` until EOF. One pool per line: this
    /// runs on a raw Thread for the VM's lifetime, whose pool never drains,
    /// and every line's objects would stay alive until the VM stopped.
    static func serveLines(_ reader: inout LineReader, _ handle: ([String: Any]) -> Void) {
        while autoreleasepool(invoking: { () -> Bool in
            guard let line = reader.next() else { return false }
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(obj) }
            return true
        }) {}
    }

    /// Close the channel, if it's still the one of `generation` (nil: any).
    /// Takes the write lock, so no query is mid-write on the fd it closes.
    func closeChannel(generation gen: UInt64? = nil, writeLocked: Bool = false) {
        if !writeLocked { writeLock.lock() }
        defer { if !writeLocked { writeLock.unlock() } }
        lock.lock()
        if let gen, gen != generation || fd < 0 { lock.unlock(); return }
        let f = fd
        fd = -1
        connection = nil
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        // shutdown first: it wakes the serving thread's blocked read, which
        // a bare close from this thread doesn't reliably do.
        if f >= 0 { shutdown(f, Int32(SHUT_RDWR)); close(f) }
        for (_, w) in pending { w.resume(returning: nil) }
    }

    /// One request/response, nil on no channel or a 1 s timeout.
    func query(_ req: [String: Any]) async -> [String: Any]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            // One write at a time, and the fd can't be closed (nor reused)
            // under it: closeChannel takes the same lock.
            writeLock.lock()
            defer { writeLock.unlock() }
            lock.lock()
            guard fd >= 0 else { lock.unlock(); cont.resume(returning: nil); return }
            let id = nextID
            nextID += 1
            waiters[id] = cont
            let f = fd, gen = generation
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
            if !ok {
                // A write cut short leaves half a line on the channel: drop
                // it (the attestor reconnects with its secret).
                finish(id, nil)
                closeChannel(generation: gen, writeLocked: true)
            }
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
        /// The booted spec asked for a filesystem ruleset (`requested.filesystem`).
        public var filesystemRequested: Bool? = nil

        /// The filesystem sandbox isn't doing what was asked: Landlock failed
        /// (an unreadable spec, an unsafe socket layout, a crashed supervisor)
        /// or best effort degraded to nothing — the session may run
        /// unconfined, and only these two fields say so.
        public var filesystemFailed: Bool { filesystem == "failed" || filesystem == "degraded" }

        /// `off` because nothing was asked of the filesystem: no spec, no
        /// filesystem_policy (a process-only policy), or one with no paths.
        static let filesystemOffAsAsked: Set<String> = ["filesystem_policy not configured", "no paths configured"]

        /// The filesystem sandbox is off for a reason that isn't the policy's
        /// own: a run_as identity that couldn't be provisioned or resolved
        /// (off, with that reason), or any reason not known to be intended.
        public var filesystemOffUnasked: Bool {
            guard filesystem == "off", let reason = degradedReason, !reason.isEmpty else { return false }
            return !Self.filesystemOffAsAsked.contains(reason)
        }

        /// The booted policy asked for a ruleset and none is in force yet,
        /// with no failure said: the sandbox is still being assembled (held
        /// for a required sentry). Not a fault, but not "off" either.
        public var filesystemNotYetApplied: Bool {
            filesystem == "off" && (degradedReason ?? "").isEmpty && filesystemRequested == true
        }

        /// Anything the sandbox reported as not working as asked. The
        /// sentry counts only when the workspace wants one. A filesystem
        /// sandbox reported `off` counts only when the guest's own reason
        /// says the apply failed (Finding CWE-451, "Sandbox card warns when
        /// a process-only policy correctly leaves the filesystem off"): it
        /// was judged against the editor's unsaved draft, and a `process`
        /// section — or a filesystem_policy with no paths — warned forever.
        public func needsAttention(sentryExpected: Bool) -> Bool {
            filesystemFailed || strictApplied == false || !warnings.isEmpty
                || (sentry == "unavailable" && sentryExpected)
                || filesystemOffUnasked
        }
    }

    private let lock = NSLock()

    /// Serialises update(): a report applies whole.

    private let updating = NSLock()
    private var statuses: [UUID: Status] = [:]
    /// Fired on every change (UI refresh).
    public var onChange: (@Sendable (UUID) -> Void)?
    /// The kernels the guest reports (running first, then every installed
    /// one) and whether its sentry is waiting for a module: the host fetches
    /// and stages them (SentryModuleStore).
    public var onKernels: (@Sendable (UUID, [String], Bool) -> Void)?

    public func status(for profileID: UUID) -> Status? {
        lock.lock(); defer { lock.unlock() }
        return statuses[profileID]
    }

    /// The sentry's own state from the latest report, including one sent while
    /// the sandbox was still `pending` (and so not recorded as a Status): a
    /// required sentry is loaded before the supervisor publishes, and its
    /// `waiting` must still be seen.
    private var sentryStates: [UUID: (state: String, reason: String?)] = [:]
    public func sentryState(for profileID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return statuses[profileID]?.sentry ?? sentryStates[profileID]?.state
    }
    /// Why the sentry is unavailable, from the same latest report.
    public func sentryReason(for profileID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return statuses[profileID]?.sentryReason ?? sentryStates[profileID]?.reason
    }

    public func reset(profileID: UUID) {
        lock.lock(); statuses[profileID] = nil; sentryStates[profileID] = nil; lock.unlock()
        onChange?(profileID)
    }

    /// `onlyIfAbsent`: an answer the host asked for, not stored over a status
    /// the guest pushed meanwhile.
    func update(profileID: UUID, report r: [String: Any], now: Date = Date(), onlyIfAbsent: Bool = false) {
        // One report at a time, whole: an asked-for one checks and applies
        // (its kernels, sentry state and status) with no pushed one between.
        updating.lock(); defer { updating.unlock() }
        if onlyIfAbsent, status(for: profileID) != nil { return }
        // Kernels first, even while the sandbox is still `pending`: the sentry
        // loads before the sandbox is assembled, and may be waiting for the
        // host to fetch its module.
        let kernels = [r["sentry_kernel"] as? String].compactMap { $0 } + (r["installed_kernels"] as? [String] ?? [])
        if !kernels.isEmpty { onKernels?(profileID, kernels, r["sentry"] as? String == "waiting") }
        if let sentry = r["sentry"] as? String {
            lock.lock(); sentryStates[profileID] = (sentry, r["sentry_reason"] as? String); lock.unlock()
        }
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
            receivedAt: now,
            filesystemRequested: (r["requested"] as? [String: Any])?["filesystem"] as? Bool)
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
        if let v = st.filesystemRequested { data["requested_filesystem"] = .bool(v) }
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
