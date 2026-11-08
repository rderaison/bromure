import Foundation
import Testing
@testable import bromure_ac
import SandboxEngine

/// The switch's identity gate: a decision belongs to one SYN (its ISN) and
/// stands for that SYN's retransmits; the verdict is computed against the
/// policy at use; a VM's pending flows and questions are bounded, the
/// waiting ones asked in order. And the attestor's secret is created 0600,
/// on disk before it's used, and an empty one pins nothing.
@Suite("Binary identity gate")
struct BinaryIdentityGateTests {
    static let yaml = """
    version: 1
    network_policies:
      github:
        endpoints: [{ host: api.github.com, port: 443 }]
        binaries: [{ path: /usr/bin/gh }]
    """
    static let ip = EgressPolicy.parseIPv4Address("140.82.112.3")!

    static func policy(_ yaml: String = yaml) throws -> EgressPolicy {
        var p = EgressPolicy(openShell: try OpenShellPolicy.parse(yaml))
        p.enforceBinaries = true
        return p
    }

    static func service(exe: String, asked: NIOLockedCounter? = nil) -> BinaryIdentityService {
        let svc = BinaryIdentityService()
        svc.queryOverride = { _, _ in
            asked?.bump()
            return ["ok": true, "exe": exe, "sha256": "aaa", "ancestors": []]
        }
        return svc
    }

    /// Gate until decided (the first call asks; nil while it's asked).
    static func decide(_ svc: BinaryIdentityService, _ pid: UUID, sport: UInt16 = 4000, isn: UInt32?,
                       policy: EgressPolicy) async throws -> (verdict: EgressPolicy.Verdict, exe: String?)? {
        for _ in 0..<200 {
            if let d = svc.gate(profileID: pid, sport: sport, dstIP: ip, dport: 443, isn: isn,
                                hostnames: ["api.github.com"], policy: policy) { return d }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    /// A movable clock for the gate.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 0
        func advance(_ s: TimeInterval) { lock.lock(); offset += s; lock.unlock() }
        var now: Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(offset) }
    }

    static func clocked(_ svc: BinaryIdentityService) -> Clock {
        let c = Clock()
        svc.clock = { c.now }
        return c
    }

    static func once(_ svc: BinaryIdentityService, _ pid: UUID, sport: UInt16, isn: UInt32?, policy: EgressPolicy,
                     hostnames: [String] = ["api.github.com"]) -> (verdict: EgressPolicy.Verdict, exe: String?)? {
        svc.gate(profileID: pid, sport: sport, dstIP: ip, dport: 443, isn: isn, hostnames: hostnames, policy: policy)
    }

    @Test func aDecisionIsTiedToItsSYN() async throws {
        let asked = NIOLockedCounter()
        let svc = Self.service(exe: "/usr/bin/gh", asked: asked), pid = UUID(), p = try Self.policy()
        #expect(try await Self.decide(svc, pid, isn: 1000, policy: p)?.verdict == .allow)
        // Same 4-tuple, another SYN (another socket bound the port): asked again.
        let before = asked.value
        #expect(Self.once(svc, pid, sport: 4000, isn: 2000, policy: p) == nil, "not inherited")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(asked.value == before + 1)
    }

    /// The SYN-ACK is lost: the guest retransmits the same SYN at +3 s and
    /// +7 s, and each is still allowed on the one answer.
    @Test func aRetransmittedSYNKeepsItsAnswer() async throws {
        let asked = NIOLockedCounter()
        let svc = Self.service(exe: "/usr/bin/gh", asked: asked), pid = UUID(), p = try Self.policy()
        let clock = Self.clocked(svc)
        #expect(try await Self.decide(svc, pid, sport: 4010, isn: 55, policy: p)?.verdict == .allow)
        for wait in [3.0, 4.0, 25.0, 90.0] {                       // +3, +7, +32, +122 s
            clock.advance(wait)
            #expect(Self.once(svc, pid, sport: 4010, isn: 55, policy: p)?.verdict == .allow, "+\(wait) s")
        }
        #expect(asked.value == 1, "asked once")
    }

    @Test func anAnswerExpiresAfterTheRetryHorizon() async throws {
        let asked = NIOLockedCounter()
        let svc = Self.service(exe: "/usr/bin/gh", asked: asked), pid = UUID(), p = try Self.policy()
        let clock = Self.clocked(svc)
        #expect(try await Self.decide(svc, pid, sport: 4001, isn: 7, policy: p)?.verdict == .allow)
        clock.advance(BinaryIdentityService.gateDecidedTTL + 1)
        #expect(Self.once(svc, pid, sport: 4001, isn: 7, policy: p) == nil, "stale: asked again, not used")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(asked.value == 2)
    }

    @Test func theVerdictIsMadeAgainstThePolicyAtUse() async throws {
        let svc = Self.service(exe: "/usr/bin/gh"), pid = UUID()
        let allows = try Self.policy()
        let denies = try Self.policy(Self.yaml.replacingOccurrences(of: "/usr/bin/gh", with: "/usr/bin/other"))
        #expect(Self.once(svc, pid, sport: 4002, isn: 9, policy: allows) == nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        // The policy changed while the attestor answered: the new one decides.
        let d = Self.once(svc, pid, sport: 4002, isn: 9, policy: denies)
        #expect(d?.verdict == .deny && d?.exe == "/usr/bin/gh")
        #expect(Self.once(svc, pid, sport: 4002, isn: 9, policy: allows)?.verdict == .allow, "and again at the next use")
    }

    /// Past the question cap, flows wait their turn and are asked in arrival
    /// order as slots free, with no retransmit needed.
    @Test func waitingFlowsAreAskedInOrder() async throws {
        let svc = BinaryIdentityService(), pid = UUID(), p = try Self.policy()
        let order = NIOLockedValueList()
        let tickets = Tickets()
        svc.queryOverride = { _, req in
            order.append(req["sport"] as? Int ?? -1)
            await tickets.take()
            return ["ok": true, "exe": "/usr/bin/gh", "sha256": "aaa", "ancestors": []]
        }
        let n = BinaryIdentityService.maxGateQueries
        for i in 0..<(n + 3) { #expect(Self.once(svc, pid, sport: UInt16(5000 + i), isn: 1, policy: p) == nil) }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(order.values.count == n, "the cap holds")
        #expect(Self.once(svc, pid, sport: UInt16(5000 + n), isn: 1, policy: p) == nil, "a waiting flow's retransmit is held")
        // Each answer frees a slot for the oldest waiting flow, no retransmit needed.
        for k in 0..<3 {
            tickets.give()
            for _ in 0..<100 where order.values.count < n + k + 1 { try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(order.values.last == 5000 + n + k, "slot \(k) went to the next in line")
        }
        tickets.give(1000)
        for _ in 0..<100 where Self.once(svc, pid, sport: UInt16(5000 + n + 2), isn: 1, policy: p) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(Self.once(svc, pid, sport: UInt16(5000 + n + 2), isn: 1, policy: p)?.verdict == .allow)
    }

    /// Answers released one at a time.
    final class Tickets: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func give(_ k: Int = 1) { lock.lock(); n += k; lock.unlock() }
        private func tryTake() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard n > 0 else { return false }
            n -= 1
            return true
        }
        func take() async {
            while !tryTake() { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
    }

    @Test func aFullTableHoldsRatherThanRefuses() async throws {
        let svc = BinaryIdentityService(), pid = UUID(), p = try Self.policy()
        // Questions that never come back keep every flow undecided.
        svc.queryOverride = { _, _ in try? await Task.sleep(nanoseconds: 5_000_000_000); return nil }
        for i in 0..<BinaryIdentityService.maxGateEntries {
            _ = Self.once(svc, pid, sport: UInt16(10_000 + i), isn: 1, policy: p, hostnames: [])
        }
        #expect(Self.once(svc, pid, sport: 60_000, isn: 1, policy: p, hostnames: []) == nil, "held: no RST, no event")
        // Another VM isn't affected.
        #expect(Self.once(svc, UUID(), sport: 1, isn: 1, policy: p) == nil)
    }

    /// A full table makes room one answer at a time, least recently used
    /// first, and one the switch already remembers (handed out as an allow)
    /// before one it doesn't; answers stand their whole TTL while there's room.
    @Test func aFullTableEvictsTheLeastRecentlyUsedAnswer() async throws {
        let svc = Self.service(exe: "/usr/bin/gh"), pid = UUID(), p = try Self.policy()
        let denies = try Self.policy(Self.yaml.replacingOccurrences(of: "/usr/bin/gh", with: "/usr/bin/other"))
        let clock = Self.clocked(svc)
        let n = BinaryIdentityService.maxGateEntries
        for i in 0..<n { _ = Self.once(svc, pid, sport: UInt16(10_000 + i), isn: 1, policy: p, hostnames: []) }
        for _ in 0..<200 where Self.once(svc, pid, sport: UInt16(10_000 + n - 1), isn: 1, policy: denies) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // All answered. Each used once, oldest first; flow 0 handed out as an
        // allow (the switch has it), the rest as denies.
        clock.advance(1)
        #expect(Self.once(svc, pid, sport: 10_000, isn: 1, policy: p)?.verdict == .allow)
        for i in 1..<n { clock.advance(0.01); _ = Self.once(svc, pid, sport: UInt16(10_000 + i), isn: 1, policy: denies) }
        // A new flow: the allowed one gives way, though it's used more recently than flow 1.
        clock.advance(1)
        #expect(Self.once(svc, pid, sport: 60_001, isn: 1, policy: p) == nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        let asked = NIOLockedCounter()
        svc.queryOverride = { _, _ in asked.bump(); return ["ok": true, "exe": "/usr/bin/gh", "sha256": "aaa", "ancestors": []] }
        #expect(Self.once(svc, pid, sport: 10_001, isn: 1, policy: denies) != nil, "flow 1's answer still stands")
        #expect(Self.once(svc, pid, sport: 10_000, isn: 1, policy: p) == nil, "flow 0's was evicted: asked again")
        // That made room the LRU way (flow 1 was just used: flow 2 went),
        // and only as far as needed (flow 3 stands).
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(Self.once(svc, pid, sport: 10_003, isn: 1, policy: denies) != nil, "only as far as needed")
        #expect(Self.once(svc, pid, sport: 10_002, isn: 1, policy: denies) == nil, "the least recently used went")
    }

    @Test func theSecretIsCreatedPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attestor-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("attestor.secret")
        let old = umask(0)
        defer { umask(old) }
        #expect(AttestorBridge.writeSecret(String(repeating: "a", count: 64), to: file))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == String(repeating: "a", count: 64))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["attestor.secret"], "no temp left")
    }

    @Test func anEmptySecretPinsNothingAndTempLeftoversGo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attestor-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("attestor.secret")
        try Data().write(to: file)                                       // a save cut short
        let leftover = dir.appendingPathComponent("attestor.secret" + AttestorBridge.tempMarker + "x")
        try Data("half".utf8).write(to: leftover)
        let other = dir.appendingPathComponent("unrelated.tmp-x")
        try Data().write(to: other)
        let b = AttestorBridge(profileID: UUID(), secretFile: file, mayPin: true)
        // Unpinned: the first hello pins.
        var fds: [Int32] = [0, 0]
        _ = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, Self.streamSocketType, 0, $0.baseAddress!) }
        defer { close(fds[0]) }
        let secret = String(repeating: "cd", count: 32)
        _ = "{\"hello\":\"attestd\",\"version\":1,\"secret\":\"\(secret)\"}\n".withCString { write(fds[0], $0, strlen($0)) }
        let hostFD = fds[1]
        Thread.detachNewThread { b.handshakeAndServe(hostFD, connection: nil) }
        for _ in 0..<50 where !b.isConnected { usleep(20_000) }
        #expect(b.isConnected)
        #expect(try String(contentsOf: file, encoding: .utf8) == secret)
        #expect(!FileManager.default.fileExists(atPath: leftover.path), "the cut-short temp is gone")
        #expect(FileManager.default.fileExists(atPath: other.path), "nothing else touched")
        b.closeChannel()
    }

    /// A VM taken back with no valid pin on disk (deleted, or empty) refuses
    /// every hello: only a fresh boot may pin.
    @Test(arguments: [false, true])
    func aRestoredVMWithoutAPinRefusesEveryHello(emptyFile: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attestor-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("attestor.secret")
        if emptyFile { try Data().write(to: file) }
        let b = AttestorBridge(profileID: UUID(), secretFile: file, mayPin: false)
        var fds: [Int32] = [0, 0]
        _ = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, Self.streamSocketType, 0, $0.baseAddress!) }
        defer { close(fds[0]) }
        _ = "{\"hello\":\"attestd\",\"version\":1,\"secret\":\"\(String(repeating: "ee", count: 32))\"}\n".withCString { write(fds[0], $0, strlen($0)) }
        let hostFD = fds[1]
        b.handshakeAndServe(hostFD, connection: nil)                     // returns: refused
        var byte: UInt8 = 0
        #expect(read(fds[0], &byte, 1) == 0, "closed by the host")
        #expect(!b.isConnected)
        #expect((try? String(contentsOf: file, encoding: .utf8)) ?? "" == "", "nothing pinned")
    }

    static var streamSocketType: Int32 { SOCK_STREAM }
}

/// A thread-safe list of what the query overrides were asked.
final class NIOLockedValueList: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Int] = []
    func append(_ x: Int) { lock.lock(); v.append(x); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return v }
}

/// A thread-safe counter for the query overrides.
final class NIOLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
