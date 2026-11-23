@testable import ACLinux
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

/// The device grant against a scripted bromure.io (no network): what is
/// sent, how each answer is read, how polling paces itself and stops.
@Suite("Device grant sign-in")
struct DeviceGrantTests {
    /// Answers in order; records each request's path and JSON body.
    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var answers: [(Int, String)]
        var sent: [(String, [String: Any])] = []
        init(_ answers: [(Int, String)]) { self.answers = answers }
        var transport: DeviceGrantClient.Transport {
            { req in self.answer(req) }
        }
        func answer(_ req: URLRequest) -> (Int, Data) {
            lock.withLock {
                let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                sent.append((req.url?.path ?? "", body))
                let (s, j) = answers.isEmpty ? (500, "{}") : answers.removeFirst()
                return (s, Data(j.utf8))
            }
        }
    }

    final class Sleeps: @unchecked Sendable {
        let lock = NSLock()
        var seconds: [Int] = []
        func record(_ s: Int) { lock.lock(); seconds.append(s); lock.unlock() }
    }

    let started = """
        {"deviceCode":"dc-secret","userCode":"BCDF-GHJK","verificationUri":"https://bromure.io/app/enroll/approve",
         "verificationUriComplete":"https://bromure.io/app/enroll/approve?user_code=BCDF-GHJK","interval":5,"expiresIn":900}
        """

    func grant(interval: Int = 5, expiresIn: Int = 900) -> DeviceGrant {
        DeviceGrant(deviceCode: "dc-secret", userCode: "BCDF-GHJK", verificationURI: "https://x/approve",
                    verificationURIComplete: "https://x/approve?user_code=BCDF-GHJK", interval: interval, expiresIn: expiresIn)
    }

    @Test func startSendsTheMachineAndReadsTheGrant() async throws {
        let s = Script([(201, started)])
        let c = try #require(DeviceGrantClient(base: "https://bromure.io/api", transport: s.transport))
        let g = try await c.start(deviceName: "lnx-ntv")
        #expect(g.deviceCode == "dc-secret" && g.userCode == "BCDF-GHJK" && g.interval == 5 && g.expiresIn == 900)
        #expect(g.verificationURIComplete.hasSuffix("?user_code=BCDF-GHJK"))
        #expect(s.sent.first?.0 == "/api/v1/device-grants")
        #expect(s.sent.first?.1["deviceName"] as? String == "lnx-ntv")
        #expect(s.sent.first?.1["platform"] as? String == "linux")
        #expect(s.sent.first?.1["capability"] as? String == "server")
    }

    @Test func noDeviceGrantsThereIsUnavailable() async throws {
        let c = try #require(DeviceGrantClient(base: "https://bromure.io/api", transport: Script([(404, "{}")]).transport))
        await #expect(throws: DeviceGrantError.unavailable) { try await c.start(deviceName: "h") }
    }

    @Test func aLongNameIsCut() async throws {
        let s = Script([(201, started)])
        let c = try #require(DeviceGrantClient(base: "https://bromure.io/api", transport: s.transport))
        _ = try await c.start(deviceName: String(repeating: "n", count: 300))
        #expect((s.sent.first?.1["deviceName"] as? String)?.count == 120)
    }

    @Test func pollsUntilApprovedAndBacksOffOnSlowDown() async throws {
        let s = Script([(200, #"{"status":"pending","interval":5}"#),
                        (200, #"{"status":"slow_down","interval":10}"#),
                        (429, #"{}"#),
                        (200, #"{"status":"approved","code":"one-time-code","codeExpiresIn":600}"#)])
        let c = try #require(DeviceGrantClient(base: "https://bromure.io/api", transport: s.transport))
        let sleeps = Sleeps()
        let code = try await c.waitForApproval(grant(), sleep: { sleeps.record($0) })
        #expect(code == "one-time-code")
        // 5, then 5 (pending), then the slow_down's 10, then 10 + 5 after a bare 429.
        #expect(sleeps.seconds == [5, 5, 10, 15])
        #expect(s.sent.allSatisfy { $0.0 == "/api/v1/device-grants/token" && $0.1["deviceCode"] as? String == "dc-secret" })
    }

    @Test func deniedAndExpiredStop() async throws {
        for (answer, error) in [((200, #"{"status":"denied"}"#), DeviceGrantError.denied),
                                ((200, #"{"status":"expired"}"#), .expired),
                                ((404, #"{}"#), .expired)] {
            let s = Script([(200, #"{"status":"pending"}"#), answer, (200, #"{"status":"approved","code":"late"}"#)])
            let c = try #require(DeviceGrantClient(base: "https://bromure.io/api", transport: s.transport))
            await #expect(throws: error) { try await c.waitForApproval(grant(), sleep: { _ in }) }
            #expect(s.sent.count == 2)
        }
    }

    @Test func noLongerThanTheGrantLives() async throws {
        let s = Script(Array(repeating: (200, #"{"status":"pending","interval":5}"#), count: 50))
        let c = try #require(DeviceGrantClient(base: "https://bromure.io/api", transport: s.transport))
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        await #expect(throws: DeviceGrantError.expired) {
            try await c.waitForApproval(grant(expiresIn: 20), sleep: { clock.t += TimeInterval($0) }, now: { clock.t })
        }
        #expect(s.sent.count == 4)
    }

    @Test func approvedWithoutACodeIsAnError() async throws {
        let c = try #require(DeviceGrantClient(base: "https://bromure.io/api",
                                               transport: Script([(200, #"{"status":"approved"}"#)]).transport))
        await #expect(throws: DeviceGrantError.badResponse("approved without a code")) { try await c.poll("dc") }
    }

    @Test func theCodeGoesToTheDaemonAsALinkToTheSameAPI() throws {
        let c = try #require(DeviceGrantClient(base: "http://127.0.0.1:8080/api", transport: Script([]).transport))
        let link = try #require(EnrollLink(parsing: c.enrollLink(code: "abc-DEF_123")))
        #expect(link.code == "abc-DEF_123" && link.apiBase == "http://127.0.0.1:8080/api")
        let prod = try #require(DeviceGrantClient(base: DeviceGrantClient.defaultAPIBase, transport: Script([]).transport))
        #expect(try #require(EnrollLink(parsing: prod.enrollLink(code: "x"))).apiBase == "https://bromure.io/api")
    }
}
