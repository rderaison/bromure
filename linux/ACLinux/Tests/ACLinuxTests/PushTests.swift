import Crypto
import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// Needs-input pushes (macOS: reportPushTransition): what a transition
    /// sends, the sealed payload, and the seal itself.
    @Suite("Push notifications", .serialized)
    @MainActor
    struct PushTests {
        @Test func whatATransitionSends() {
            typealias H = LinuxSessionHost
            #expect(H.pushAction(from: .working, to: .needsInput) == .needsInput)
            #expect(H.pushAction(from: .needsInput, to: .working) == .resolved)
            #expect(H.pushAction(from: .needsInput, to: .done) == .resolved)
            #expect(H.pushAction(from: .working, to: .done) == nil)
            #expect(H.pushAction(from: .needsInput, to: .needsInput) == nil)
        }

        @Test func theRichTitleIsSealedToThePhonesKey() throws {
            let rich = try #require(LinuxSessionHost.richPushPayload(profileName: "ws", tabLabel: "claude"))
            let obj = try #require(try JSONSerialization.jsonObject(with: rich) as? [String: String])
            #expect(obj["title"] == "ws · claude" && obj["body"] == "An agent needs your input")
            let plain = try #require(LinuxSessionHost.richPushPayload(profileName: "ws", tabLabel: ""))
            #expect((try JSONSerialization.jsonObject(with: plain) as? [String: String])?["title"] == "ws")
            // Sealed to one phone: only its private key opens it.
            let phone = Curve25519.KeyAgreement.PrivateKey(), other = Curve25519.KeyAgreement.PrivateKey()
            let hex = phone.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
            let blob = try #require(PushCrypto.seal(rich, toPublicKeyHex: hex))
            #expect(PushCrypto.open(blob, privateKey: phone) == rich)
            #expect(PushCrypto.open(blob, privateKey: other) == nil)
            #expect(PushCrypto.seal(rich, toPublicKeyHex: "zz") == nil, "a bad key: nothing sealed")
        }

        /// A stand-in enrollment (its endpoint never dialled: the sender
        /// seam takes the push past the gates).
        static func enrolled() throws -> (client: ControlPlaneClient, bearer: String) {
            (ControlPlaneClient(endpoint: try ControlPlaneEndpoint(base: "https://cp.invalid")), "test-bearer")
        }

        @Test func nothingGoesWithoutRemoteAccessOrEnrollment() async throws {
            let (h, d, dir) = try await SessionListModelTests.host()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let id = UUID()
            let sent = NIOLockedValueBox(0)
            LinuxSessionHost.pushSenderForTesting = { _, k, _ in if k.contains(id.uuidString) { sent.withLockedValue { $0 += 1 } } }
            let priorEnrollment = LinuxSessionHost.enrollment
            defer { LinuxSessionHost.pushSenderForTesting = nil; LinuxSessionHost.enrollment = priorEnrollment }
            let card = try Self.enrolled()
            // No remote.json (Remote Access never turned on), though enrolled.
            LinuxSessionHost.enrollment = { card }
            h.reportPushTransition(id, index: 0, from: .working, to: .needsInput)
            #expect(sent.withLockedValue { $0 } == 0, "Remote Access off: nothing")
            // Remote Access on, not enrolled.
            var on = RemoteSettings(); on.enabled = true
            try JSONEncoder().encode(on).write(to: URL(fileURLWithPath: h.stateDir + "/remote.json"))
            LinuxSessionHost.enrollment = { nil }
            h.reportPushTransition(id, index: 0, from: .working, to: .needsInput)
            #expect(sent.withLockedValue { $0 } == 0, "not enrolled: nothing")
            // Both: it goes.
            LinuxSessionHost.enrollment = { card }
            h.reportPushTransition(id, index: 0, from: .working, to: .needsInput)
            #expect(sent.withLockedValue { $0 } == 1)
            await d.shutdown()
        }

        @Test func aNeedsInputThenItsResolution() async throws {
            let (h, d, dir) = try await SessionListModelTests.host()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let id = UUID()
            let sent = NIOLockedValueBox<[(LinuxSessionHost.PushAction, String, Data?)]>([])
            LinuxSessionHost.pushSenderForTesting = { a, k, r in if k.contains(id.uuidString) { sent.withLockedValue { $0.append((a, k, r)) } } }
            let priorEnrollment = LinuxSessionHost.enrollment
            let card = try Self.enrolled()
            LinuxSessionHost.enrollment = { card }
            var on = RemoteSettings(); on.enabled = true
            try JSONEncoder().encode(on).write(to: URL(fileURLWithPath: h.stateDir + "/remote.json"))
            defer { LinuxSessionHost.pushSenderForTesting = nil; LinuxSessionHost.enrollment = priorEnrollment }
            h.reportPushTransition(id, index: 2, from: .working, to: .needsInput)
            h.reportPushTransition(id, index: 2, from: .needsInput, to: .working)
            h.reportPushTransition(id, index: 2, from: .working, to: .done)
            let got = sent.withLockedValue { $0 }
            #expect(got.map(\.0) == [.needsInput, .resolved])
            #expect(got.allSatisfy { $0.1 == "ni-\(id.uuidString)-2" })
            #expect(got.first?.2 != nil && got.last?.2 == nil, "the rich payload goes with the question only")
            await d.shutdown()
        }
    }
}
