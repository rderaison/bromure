import Foundation
import Testing
@testable import bromure_ac

/// Pure logic behind the dashboard's Cloudflare quick-tunnel exposure: the
/// hostname banner parse, the which-ports-get-a-globe filter, and the
/// pinned-download invariants. Process supervision and the actual
/// download/verify path need the network + a live app, so they're exercised
/// by hand, not here.
@Suite("Cloudflare tunnel")
struct CloudflareTunnelTests {

    // Real shape of cloudflared's quick-tunnel banner (logs go to stderr,
    // ANSI-free under a pipe).
    let banner = """
    2026-07-02T09:00:01Z INF Thank you for trying Cloudflare Tunnel. Doing so, without a Cloudflare account, is a quick way to experiment and try it out. However, be aware that these account-less Tunnels have no uptime guarantee...
    2026-07-02T09:00:01Z INF Requesting new quick Tunnel on trycloudflare.com...
    2026-07-02T09:00:02Z INF +--------------------------------------------------------------------------------------------+
    2026-07-02T09:00:02Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
    2026-07-02T09:00:02Z INF |  https://random-words-here-1234.trycloudflare.com                                          |
    2026-07-02T09:00:02Z INF +--------------------------------------------------------------------------------------------+
    """

    @Test("Quick-tunnel hostname parsed out of the startup banner")
    func bannerParse() {
        let host = CloudflareTunnelSupervisor.firstQuickTunnelHostname(in: banner)
        #expect(host == "random-words-here-1234.trycloudflare.com")
    }

    @Test("Bare 'trycloudflare.com' mentions without a scheme+subdomain don't match")
    func bannerNegative() {
        #expect(CloudflareTunnelSupervisor.firstQuickTunnelHostname(
            in: "INF Requesting new quick Tunnel on trycloudflare.com...") == nil)
        #expect(CloudflareTunnelSupervisor.firstQuickTunnelHostname(in: "") == nil)
        // Split across chunks mid-URL: no match until the whole URL arrives.
        #expect(CloudflareTunnelSupervisor.firstQuickTunnelHostname(
            in: "https://random-words-here-1234.trycloudf") == nil)
    }

    @Test("Globe filter: web-ish ports yes; sshd, ssh port, and database ports no")
    func webServiceFilter() {
        #expect(CloudflareTunnelSupervisor.isLikelyWebService(port: 3000, process: "node"))
        #expect(CloudflareTunnelSupervisor.isLikelyWebService(port: 8080, process: ""))
        #expect(CloudflareTunnelSupervisor.isLikelyWebService(port: 80, process: "nginx"))
        #expect(!CloudflareTunnelSupervisor.isLikelyWebService(port: 22, process: "sshd"))
        #expect(!CloudflareTunnelSupervisor.isLikelyWebService(port: 2022, process: "sshd"))
        #expect(!CloudflareTunnelSupervisor.isLikelyWebService(port: 5432, process: "postgres"))
        #expect(!CloudflareTunnelSupervisor.isLikelyWebService(port: 6379, process: "redis-server"))
    }

    @Test("Pin: download URL is the arm64 GitHub release asset for the pinned version")
    func pinURL() {
        let url = CloudflaredPin.downloadURL.absoluteString
        #expect(url == "https://github.com/cloudflare/cloudflared/releases/download/"
                + "\(CloudflaredPin.version)/cloudflared-darwin-arm64.tgz")
        // A malformed pin (empty / wrong-length hash) would silently reject
        // every download; catch it at test time.
        #expect(CloudflaredPin.archiveSHA256.count == 64)
        #expect(CloudflaredPin.archiveSHA256.allSatisfy { $0.isHexDigit })
        #expect(CloudflaredPin.teamID.count == 10)
    }
}
