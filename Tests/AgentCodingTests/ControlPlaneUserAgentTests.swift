import Testing
import Foundation
@testable import bromure_ac

/// bromure.io reads a server's release from its User-Agent
/// (`^bromure-(ac|sidecar)/(\d+\.\d+\.\d+…)`) to enable the admin app's
/// Connect button; a two-part or build-number version would read as unknown.
@Suite("Control-plane User-Agent")
struct ControlPlaneUserAgentTests {
    @Test("Versions are always three numeric parts")
    func threeParts() {
        #expect(ControlPlaneClient.userAgentVersion("5.6.0") == "5.6.0")
        #expect(ControlPlaneClient.userAgentVersion("5.6") == "5.6.0")
        #expect(ControlPlaneClient.userAgentVersion("5") == "5.0.0")
        #expect(ControlPlaneClient.userAgentVersion("5.6.0.1") == "5.6.0")
        #expect(ControlPlaneClient.userAgentVersion("dev") == "0.0.0")
        #expect(ControlPlaneClient.userAgentVersion("") == "0.0.0")
    }

    @Test("The agent matches bromure.io's parser")
    func matchesParser() throws {
        let ua = ControlPlaneClient.userAgent
        let re = try NSRegularExpression(pattern: #"^bromure-(ac|sidecar)/(\d+\.\d+\.\d+)"#)
        #expect(re.firstMatch(in: ua, range: NSRange(ua.startIndex..., in: ua)) != nil, "\(ua)")
    }
}
