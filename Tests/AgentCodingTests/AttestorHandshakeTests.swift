import Foundation
import Testing
#if canImport(ACLinux)
@testable import ACLinux
#else
@testable import bromure_ac
#endif
import SandboxEngine

/// The attestor channel's handshake is bounded (the whole hello within a
/// deadline, at most 4 KB, a few connections waiting at once, the oldest
/// cut off past that), and a strict workspace's answers count only once
/// the guest has said the revocation applied: it's asked for its status
/// first, and until it's known nothing is decided (nor remembered).
@Suite("Attestor handshake and strict status", .serialized)
struct AttestorHandshakeTests {
    static func bridge(strict: Bool = false) -> (AttestorBridge, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attest-hs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (AttestorBridge(profileID: UUID(), secretFile: dir.appendingPathComponent("attestor.secret"), mayPin: true, strict: strict), dir)
    }

    static func pair() -> (guest: Int32, host: Int32) {
        var fds: [Int32] = [0, 0]
        _ = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, streamSocketType, 0, $0.baseAddress!) }
        return (fds[0], fds[1])
    }

    /// SOCK_STREAM is an Int32 in Darwin, an enum in Glibc.
    static var streamSocketType: Int32 {
        #if canImport(Glibc)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }

    static func send(_ fd: Int32, _ s: String) { _ = s.withCString { write(fd, $0, strlen($0)) } }

    static let hello = "{\"hello\":\"attestd\",\"version\":1,\"secret\":\"\(String(repeating: "ab", count: 32))\"}\n"

    /// Run the handshake on its own thread; true once it has returned.
    static func serve(_ bridge: AttestorBridge, _ fd: Int32) -> NIOLockedCounter {
        let done = NIOLockedCounter()
        Thread.detachNewThread { bridge.handshakeAndServe(fd, connection: nil); done.bump() }
        return done
    }

    @Test func aTrickledHelloIsCutAtTheDeadline() throws {
        let (b, dir) = Self.bridge(); defer { try? FileManager.default.removeItem(at: dir) }
        let (g, h) = Self.pair(); defer { close(g) }
        b.admitHandshake(h)
        let start = Date()
        let done = Self.serve(b, h)
        // A byte a second never finishes the line: refused at the deadline,
        // not kept alive by each byte.
        for ch in Self.hello.prefix(Int(AttestorBridge.helloDeadline) + 3) where done.value == 0 {
            Self.send(g, String(ch)); sleep(1)
        }
        for _ in 0..<50 where done.value == 0 { usleep(100_000) }
        #expect(done.value == 1 && !b.isConnected)
        #expect(Date().timeIntervalSince(start) < AttestorBridge.helloDeadline + 2)
    }

    @Test func anOversizedHelloIsRefused() throws {
        let (b, dir) = Self.bridge(); defer { try? FileManager.default.removeItem(at: dir) }
        let (g, h) = Self.pair(); defer { close(g) }
        b.admitHandshake(h)
        let done = Self.serve(b, h)
        Self.send(g, String(repeating: "x", count: AttestorBridge.maxHelloBytes + 100))
        for _ in 0..<20 where done.value == 0 { usleep(50_000) }
        #expect(done.value == 1 && !b.isConnected, "refused without waiting for the deadline")
    }

    /// Past `maxPendingHandshakes` waiting, the OLDEST is cut off: silent
    /// connections can't keep the real attestor (which says hello at once)
    /// out.
    @Test func theOldestWaitingHandshakeIsCutOff() throws {
        let (b, dir) = Self.bridge(); defer { try? FileManager.default.removeItem(at: dir) }
        var guests: [Int32] = []
        defer { guests.forEach { close($0) } }
        for _ in 0..<AttestorBridge.maxPendingHandshakes {
            let (g, h) = Self.pair(); guests.append(g)
            b.admitHandshake(h)
            _ = Self.serve(b, h)
        }
        // The real attestor arrives: admitted, and the oldest silent one goes.
        let (g, h) = Self.pair(); guests.append(g)
        b.admitHandshake(h)
        _ = Self.serve(b, h)
        Self.send(g, Self.hello)
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(guests[0], SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        #expect(read(guests[0], &byte, 1) == 0, "the oldest was closed at once, not at the deadline")
        for _ in 0..<50 where !b.isConnected { usleep(20_000) }
        #expect(b.isConnected, "the real attestor got in")
        b.stop()
    }

    /// A fake attestd on `fd`: answers `who` with /usr/bin/gh, and
    /// `sandbox_status` with `status` (or unavailable). Counts status asks.
    static func fakeAttestd(_ fd: Int32, status: [String: Any]?, asked: NIOLockedCounter) {
        let statusJSON = status.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        Thread.detachNewThread {
            let status = statusJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            var reader = LineReader(fd: fd)
            while let line = reader.next() {
                guard let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                var reply: [String: Any] = ["id": req["id"] ?? 0]
                switch req["op"] as? String {
                case "who": reply.merge(["ok": true, "exe": "/usr/bin/gh", "sha256": "aaa", "ancestors": []]) { $1 }
                case "sandbox_status":
                    asked.bump()
                    if let status { reply.merge(["ok": true, "status": status]) { $1 } } else { reply["ok"] = false }
                default: reply["ok"] = false
                }
                var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
                data.append(0x0A)
                _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            }
        }
    }

    @Test(arguments: [true, false])
    func aStrictWorkspaceIsAskedForItsStatusFirst(guestAnswers: Bool) async throws {
        let (b, dir) = Self.bridge(strict: true); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = BinaryIdentityService()
        svc.adoptBridge(b, for: b.profileID)
        defer { GuestSandboxStatusStore.shared.reset(profileID: b.profileID); b.stop() }
        GuestSandboxStatusStore.shared.reset(profileID: b.profileID)
        let (g, h) = Self.pair(); defer { close(g) }
        let asked = NIOLockedCounter()
        // Asked BEFORE the attestor has connected (a fresh boot): the
        // question waits for the channel, then asks for the status.
        let pending = Task { await svc.attest(profileID: b.profileID, sport: 1000, dst: "1.2.3.4", dport: 443) }
        try await Task.sleep(nanoseconds: 300_000_000)
        b.admitHandshake(h)
        _ = Self.serve(b, h)
        Self.send(g, Self.hello)
        Self.fakeAttestd(g, status: guestAnswers ? ["event": "sandbox_status", "filesystem": "off", "strict_applied": true] : nil,
                         asked: asked)
        let answer = await pending.value
        #expect(asked.value == 1, "asked for the status before trusting an answer")
        if guestAnswers {
            guard case .identity(let id) = answer else { Issue.record("not decided"); return }
            #expect(id?.exe == "/usr/bin/gh")
            #expect(GuestSandboxStatusStore.shared.status(for: b.profileID)?.strictApplied == true)
        } else {
            guard case .notYet = answer else { Issue.record("decided while unknown"); return }
            // Through the gate: held, never a remembered deny; once the
            // guest's status is known, the retransmit is allowed.
            var policy = EgressPolicy(openShell: try OpenShellPolicy.parse(BinaryIdentityGateTests.yaml))
            policy.enforceBinaries = true
            let ip = BinaryIdentityGateTests.ip
            func gate() -> (verdict: EgressPolicy.Verdict, exe: String?)? {
                svc.gate(profileID: b.profileID, sport: 1001, dstIP: ip, dport: 443, isn: 9, hostnames: ["api.github.com"], policy: policy)
            }
            #expect(gate() == nil)
            for _ in 0..<50 where asked.value < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(gate() == nil, "unknown: asked again, not denied")
            GuestSandboxStatusStore.shared.update(profileID: b.profileID,
                                                  report: ["event": "sandbox_status", "filesystem": "off", "strict_applied": true])
            var decided: (verdict: EgressPolicy.Verdict, exe: String?)?
            for _ in 0..<100 where decided == nil { decided = gate(); try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(decided?.verdict == .allow)
        }
    }

    /// The status the host asked for doesn't overwrite one the guest pushed
    /// meanwhile.
    @Test func anAskedStatusDoesntOverwriteAPushedOne() {
        let pid = UUID()
        defer { GuestSandboxStatusStore.shared.reset(profileID: pid) }
        GuestSandboxStatusStore.shared.update(profileID: pid, report: ["event": "sandbox_status", "filesystem": "off", "strict_applied": false])
        GuestSandboxStatusStore.shared.update(profileID: pid, report: ["event": "sandbox_status", "filesystem": "off", "strict_applied": true],
                                              onlyIfAbsent: true)
        #expect(GuestSandboxStatusStore.shared.status(for: pid)?.strictApplied == false)
    }
}
