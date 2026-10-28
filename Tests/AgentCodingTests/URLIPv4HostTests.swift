import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-918): "Loopback check misses the 0x spelling of 0.0.0.0, so a
/// guest URL still opens on the host". inet_aton refuses a part that is a
/// bare `0x`; a browser reads it as 0, so `http://0x:631/` is 0.0.0.0 -- this
/// Mac's loopback -- and went to the real browser as a public name.
@Suite("URL-standard IPv4 hosts")
struct URLIPv4HostTests {
    private static func addr(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }

    @Test("the hosts a browser reads as an IPv4 address",
          arguments: [("0x", 0), ("0X", 0), ("0x.0", 0), ("0x.0.0", 0), ("0x.0.0.0", 0), ("0x.", 0), ("0X.0.0.0.", 0),
                      ("0", 0), ("0x0", 0), ("0.0.0.0", 0),
                      ("127.1", 0x7F00_0001), ("0x7f000001", 0x7F00_0001), ("2130706433", 0x7F00_0001),
                      ("0177.0.0.1", 0x7F00_0001), ("0x7f.1", 0x7F00_0001), ("127.0.0.1", 0x7F00_0001),
                      ("192.168.0x1.010", 0xC0A8_0108), ("8.8.8.8", 0x0808_0808), ("4294967295", 0xFFFF_FFFF)] as [(String, UInt32)])
    func parses(host: String, expected: UInt32) {
        guard case .address(let a) = ACAppDelegate.urlIPv4(host) else {
            Issue.record("\(host) did not parse"); return
        }
        #expect(a == expected, "\(host)")
    }

    @Test("names stay names", arguments: ["example.com", "0xg", "a.0x7g", "localhost", "1.2.3.example", "0a", ""])
    func names(host: String) {
        guard case .notIPv4 = ACAppDelegate.urlIPv4(host) else {
            Issue.record("\(host) read as IPv4"); return
        }
    }

    @Test("a host ending in a number that doesn't parse is no URL a browser opens",
          arguments: ["1.2.3.4.5", "256.0.0.1", "1.2.3.256", "08", "4294967296", "0x100000000", "1..2", "1.0x.1.256"])
    func invalid(host: String) {
        guard case .invalid = ACAppDelegate.urlIPv4(host) else {
            Issue.record("\(host) not refused"); return
        }
    }

    @Test("every bare-0x spelling of 0.0.0.0 reaches loopback and never opens in the real browser",
          arguments: ["0x", "0X", "0x.", "0x.0", "0x.0.0", "0x.0.0.0", "0X.0.0.0."])
    func bareHexIsLoopback(host: String) throws {
        #expect(ACAppDelegate.reachesLoopback(host), "\(host)")
        #expect(ACAppDelegate.hostIsLocalOrPrivate(host), "\(host)")
        #expect(!ACAppDelegate.opensInRealBrowser(try #require(URL(string: "http://\(host):631/"))), "\(host)")
    }

    @MainActor
    @Test("a 0x redirect is a callback port, so its owner is checked",
          arguments: ["http://0x:1455/cb", "http://0x.:1455/cb", "http://0x.0.0.0:1455/cb"])
    func bareHexRedirect(redirect: String) throws {
        var c = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        c.queryItems = [URLQueryItem(name: "redirect_uri", value: redirect)]
        #expect(ACAppDelegate.loopbackCallbackPort(from: try #require(c.url)) == 1455, "\(redirect)")
    }

    @Test("private IPv4 in any spelling, v4-mapped IPv6 included, is local",
          arguments: ["10.1", "0xa000001", "192.168.1.4", "0300.0250.1.4", "172.16.0.1", "169.254.1.1", "100.64.0.1",
                      "::ffff:10.0.0.1", "[::ffff:192.168.1.1]", "::ffff:169.254.0.1", "1.2.3.4.5"])
    func privateIsLocal(host: String) {
        #expect(ACAppDelegate.hostIsLocalOrPrivate(host), "\(host)")
        #expect(!ACAppDelegate.reachesLoopback(host), "\(host)")
    }

    @Test("public hosts still open", arguments: ["8.8.8.8", "0x8080808", "::ffff:8.8.8.8", "example.com", "0xg.com", "172.32.0.1"])
    func publicOpens(host: String) {
        #expect(!ACAppDelegate.hostIsLocalOrPrivate(host), "\(host)")
    }
}
