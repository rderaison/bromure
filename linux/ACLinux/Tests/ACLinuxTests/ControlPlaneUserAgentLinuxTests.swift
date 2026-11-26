import Foundation
import FoundationNetworking
import Testing
@testable import ACLinux

/// bromure.io reads a server's release from its User-Agent
/// (`^bromure-(ac|sidecar)/(\d+\.\d+\.\d+)`): the admin app's Connect button
/// is greyed out for a server older than 5.6.0, and for one whose version it
/// can't read. A Linux binary has no Info.plist, so the shared code would say
/// 0.0.0 here: it must say this build's version (LinuxAppVersion).
/// (macOS: Tests/AgentCodingTests/ControlPlaneUserAgentTests.swift. The
/// device channel's upgrade is checked in DeviceChannelPresenceTests.)
@Suite("Control-plane User-Agent (Linux)", .serialized)
struct ControlPlaneUserAgentLinuxTests {
    @Test func theAgentCarriesThisBuildsVersion() throws {
        let ua = ControlPlaneClient.userAgent
        #expect(ControlPlaneClient.appShortVersion == LinuxAppVersion.short)
        #expect(ua.hasPrefix("bromure-ac/\(LinuxAppVersion.short) (linux "), "\(ua)")
        // bromure.io's parser, and what it reads.
        let re = try NSRegularExpression(pattern: #"^bromure-(ac|sidecar)/(\d+\.\d+\.\d+)"#)
        let m = try #require(re.firstMatch(in: ua, range: NSRange(ua.startIndex..., in: ua)), "\(ua)")
        #expect((ua as NSString).substring(with: m.range(at: 2)) == LinuxAppVersion.short)
        #expect(LinuxAppVersion.short != "0.0.0")
    }

    @Test func versionsAreAlwaysThreeNumericParts() {
        #expect(ControlPlaneClient.userAgentVersion("5.6.0") == "5.6.0")
        #expect(ControlPlaneClient.userAgentVersion("5.6") == "5.6.0")
        #expect(ControlPlaneClient.userAgentVersion("5") == "5.0.0")
        #expect(ControlPlaneClient.userAgentVersion("5.6.0.1") == "5.6.0")
        #expect(ControlPlaneClient.userAgentVersion("dev") == "0.0.0")
        #expect(ControlPlaneClient.userAgentVersion("") == "0.0.0")
    }

    /// Answers every request with a 500 and keeps the last one's headers.
    final class Recorder: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var last: [String: String] = [:]
        static var lastHeaders: [String: String] { lock.withLock { last } }
        static func reset() { lock.withLock { last = [:] } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.withLock { Self.last = request.allHTTPHeaderFields ?? [:] }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// A control-plane call (here a connection request) carries it.
    @Test func aControlPlaneRequestCarriesIt() async throws {
        Recorder.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Recorder.self]
        let client = ControlPlaneClient(endpoint: try ControlPlaneEndpoint(base: "https://cp.invalid"),
                                        session: URLSession(configuration: cfg))
        _ = try? await client.requestConnection(bearer: "test-bearer", targetDeviceId: "d1")
        let sent = Recorder.lastHeaders
        #expect(sent["User-Agent"] == ControlPlaneClient.userAgent, "\(sent)")
        #expect(sent["Authorization"] == "Bearer test-bearer", "the request reached the recorder: \(sent)")
    }
}
