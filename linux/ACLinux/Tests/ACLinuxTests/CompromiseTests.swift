import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

/// A stand-in on its way to a host it isn't bound to (macOS: HTTPProxy's
/// detectCompromise step): refused, recorded, the compromise raised; and
/// the mark that keeps a workspace from booting until it's cleared.
@Suite("Compromise detection", .serialized)
struct CompromiseTests {
    @Test func aStandInSentToTheWrongHostIsRefusedAndRaised() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let pid = UUID()
        let fake = "sk_" + "live_FAKEstandin0123456789abcdef"
        proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "sk_" + "live_REAL-not-for-anyone", host: "api.stripe.com")]),
                             for: pid)
        let raised = NIOLockedValueBox<[CompromiseEvent]>([])
        proxy.swapper.setCompromiseHandler { e in raised.withLockedValue { $0.append(e) } }
        // To its own host: on to the rest of the chain.
        let ok = Data("GET /v1/balance HTTP/1.1\r\nHost: api.stripe.com\r\nAuthorization: Bearer \(fake)\r\n\r\n".utf8)
        #expect(RequestReader.compromiseAnswer(ok, proxy: proxy, profileID: pid, host: "api.stripe.com") == nil)
        #expect(raised.withLockedValue { $0 }.isEmpty)
        // Elsewhere (in a header, then in a body): refused, raised.
        for req in ["GET / HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(fake)\r\n\r\n",
                    "POST /x HTTP/1.1\r\nHost: evil.example\r\nContent-Length: \(fake.count + 4)\r\n\r\nkey=\(fake)"] {
            let answer = try #require(RequestReader.compromiseAnswer(Data(req.utf8), proxy: proxy, profileID: pid, host: "evil.example"))
            let text = String(decoding: answer, as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 451 ") && text.contains("leaked credential"), "\(text)")
            #expect(!text.contains(fake) && !text.contains("REAL"), "the reply carries neither value")
        }
        let events = raised.withLockedValue { $0 }
        #expect(events.count == 2 && events.allSatisfy { $0.profileID == pid && $0.observedHost == "evil.example" })
        #expect(events.first?.leaks.first?.declaredHost == "api.stripe.com")
        // Once the user allowed the host for the session: through, not raised.
        proxy.swapper.allowSessionHosts(["evil.example"], for: pid)
        #expect(RequestReader.compromiseAnswer(Data("GET / HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(fake)\r\n\r\n".utf8),
                                               proxy: proxy, profileID: pid, host: "evil.example") == nil)
    }

    /// "Allow" lasts the session: a stop takes it, with the swap map.
    @Test func anAllowedDestinationEndsWithTheSession() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try #require(await d.mitm)
        let pid = UUID(), fake = "sk_" + "live_FAKEstandin0123456789abcdef"
        proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "sk_" + "live_REAL-x", host: "api.stripe.com")]), for: pid)
        proxy.swapper.allowSessionHosts(["evil.example"], for: pid)
        let req = Data("GET / HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(fake)\r\n\r\n".utf8)
        #expect(RequestReader.compromiseAnswer(req, proxy: proxy, profileID: pid, host: "evil.example") == nil, "allowed this session")
        await d.clearWorkspaceProxyState(pid)
        #expect(proxy.swapper.entries(for: pid).isEmpty, "the swap map went with the session")
        proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "sk_" + "live_REAL-x", host: "api.stripe.com")]), for: pid)
        #expect(RequestReader.compromiseAnswer(req, proxy: proxy, profileID: pid, host: "evil.example") != nil, "the next session asks again")
        await d.shutdown()
    }

    @Test func aMarkedWorkspaceDoesntBootUntilTheMarkIsCleared() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prior = ProfileStore.defaultRootDir
        ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
        defer { ProfileStore.defaultRootDir = prior }
        let p = try ProfileStore().save(Profile(name: "marked", tool: .claude, authMode: .token))
        let rec = RepairMarksTests.stopped(p.id.uuidString)
        try await d.registerForTesting(rec)
        Daemon.markCompromised(p, store: ProfileStore())
        #expect(Daemon.isCompromised(p, store: ProfileStore()))
        let refused = await d.start(rec)
        #expect(refused.status == 409 && "\(refused.body)".contains("compromised"), "\(refused.body)")
        #expect(await d.resolveCompromise(p.name, action: "wipe").status == 501, "no wipe on Linux yet: said so")
        #expect(await d.resolveCompromise(p.name, action: "clear").status == 200)
        #expect(!Daemon.isCompromised(p, store: ProfileStore()))
        let resolved = ProfileStore().profileDirectory(for: p).appendingPathComponent("compromise.resolved")
        #expect((try? String(contentsOf: resolved, encoding: .utf8)) == "clear", "recorded as a false alarm")
        // Cleared: the start goes on (to the launch, which the hook stops here).
        Daemon.launchHookForTesting.withLockedValue { $0 = { _ in throw CancellationError() } }
        defer { Daemon.launchHookForTesting.withLockedValue { $0 = nil } }
        let again = await d.start(rec)
        #expect(!"\(again.body)".contains("compromised"), "\(again.body)")
        await d.shutdown()
    }
}
