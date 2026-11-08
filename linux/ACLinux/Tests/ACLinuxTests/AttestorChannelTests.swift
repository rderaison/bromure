import Foundation
import Glibc
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// The guest attestor's channel on the daemon (macOS: attachIdentityBridge
    /// and AttestorBridge): a sandboxed workspace's listener on vsock 5840
    /// takes the attestor's hello, pins its secret, and relays the guest
    /// sandbox's status to the host (a degraded one reaches the Timeline);
    /// another connection without that secret is refused.
    @Suite("Attestor channel", .serialized)
    struct AttestorChannelTests {
        static func send(_ fd: Int32, _ obj: [String: Any]) {
            var d = try! JSONSerialization.data(withJSONObject: obj); d.append(0x0A)
            _ = d.withUnsafeBytes { Glibc.write(fd, $0.baseAddress, d.count) }
        }

        @Test func aStrictWorkspacesStatusReachesTheHost() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            var p = Profile(name: "attested", tool: .claude, authMode: .token)
            p.strictSandbox = true
            p = try ProfileStore().save(p)
            let rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            let uds = dir + "/v.sock"
            let l = try #require(await d.serveAttestor(rec, profile: p, udsPath: uds, stored: nil, restoring: false))
            defer { l.stop(); BinaryIdentityService.shared.dropBridge(p.id)?.stop() }
            // A plain workspace has none.
            #expect(await d.serveAttestor(rec, profile: Profile(name: "plain", tool: .claude, authMode: .token),
                                          udsPath: dir + "/w.sock", stored: nil, restoring: false) == nil)

            let fd = try ControlClient.connect(to: uds + "_\(BinaryIdentityService.vsockPort)")
            defer { close(fd) }
            let secret = String(repeating: "ab", count: 32)
            Self.send(fd, ["hello": "attestd", "secret": secret])
            for _ in 0..<100 where !BinaryIdentityService.shared.isAttestorConnected(p.id) { try await Task.sleep(for: .milliseconds(20)) }
            #expect(BinaryIdentityService.shared.isAttestorConnected(p.id), "the attestor is connected")
            let pinned = ProfileStore().profileDirectory(for: p).appendingPathComponent("attestor.secret")
            #expect((try? String(contentsOf: pinned, encoding: .utf8)) == secret, "its secret pinned host-side")

            Self.send(fd, ["event": "sandbox_status", "filesystem": "failed",
                           "degraded_reason": "landlock unavailable on this kernel", "strict_applied": true])
            var status: GuestSandboxStatusStore.Status?
            for _ in 0..<100 {
                status = GuestSandboxStatusStore.shared.status(for: p.id)
                if status != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(status?.filesystem == "failed" && status?.degradedReason == "landlock unavailable on this kernel")
            var onTimeline = false
            for _ in 0..<100 where !onTimeline {
                onTimeline = await MainActor.run { SecurityTimeline.shared.allEvents.contains { $0.profileID == p.id } }
                if !onTimeline { try await Task.sleep(for: .milliseconds(20)) }
            }
            #expect(onTimeline, "the degraded sandbox is on the Security Timeline")

            // Another connection, a different secret: refused (closed at once).
            let other = try ControlClient.connect(to: uds + "_\(BinaryIdentityService.vsockPort)")
            defer { close(other) }
            Self.send(other, ["hello": "attestd", "secret": String(repeating: "cd", count: 32)])
            var buf = [UInt8](repeating: 0, count: 16)
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(other, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            #expect(read(other, &buf, buf.count) == 0, "closed by the host")
            #expect(BinaryIdentityService.shared.isAttestorConnected(p.id), "the pinned channel stays")
            await d.shutdown()
        }
    }
}
