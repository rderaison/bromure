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

    // Finding (CWE-918): "Loopback gate skips UTS46 mappings, so a
    // compatibility-dot host still opens on the Mac". The browser's host
    // parser runs UTS #46 over the percent-decoded host before the IPv4
    // parser; `URL` maps a raw host but only decodes an encoded one, so
    // `127%E3%80%820%E3%80%820%E3%80%821` read as a public name.
    @Test("compatibility dots and digits, raw or percent-encoded, read as the address the browser dials",
          arguments: ["http://127%E3%80%820%E3%80%820%E3%80%821:631/", "http://%EF%BC%90%EF%BD%98:631/",
                      "http://127。0。0。1:631/", "http://127．0．0．1/", "http://127｡0｡0｡1/", "http://０ｘ/",
                      "http://⑫⑦.0.0.1/", "http://%E2%91%AB%E2%91%A6.0.0.1/", "http://%EF%BC%91%EF%BC%92%EF%BC%97.1/",
                      "http://%F0%9D%9F%8F%F0%9D%9F%90%F0%9D%9F%95.0.0.1/", "http://%EF%BC%AC%EF%BC%AF%EF%BC%A3%EF%BC%A1%EF%BC%AC%EF%BC%A8%EF%BC%AF%EF%BC%B3%EF%BC%B4/"])
    func compatibilityLoopback(_ s: String) throws {
        let url = try #require(URL(string: s))
        let host = try #require(url.host)
        #expect(ACAppDelegate.reachesLoopback(host), "\(s) → \(host)")
        #expect(ACAppDelegate.hostIsLocalOrPrivate(host), "\(s)")
        #expect(!ACAppDelegate.opensInRealBrowser(url), "\(s)")
    }

    @Test("an encoded private address is private too", arguments: ["http://10%E3%80%820%E3%80%820%E3%80%821/",
                                                                     "http://192%EF%BC%8E168%EF%BC%8E1%EF%BC%8E1/"])
    func compatibilityPrivate(_ s: String) throws {
        let url = try #require(URL(string: s))
        #expect(ACAppDelegate.hostIsLocalOrPrivate(try #require(url.host)), "\(s)")
        #expect(!ACAppDelegate.opensInRealBrowser(url))
    }

    @MainActor
    @Test("a sign-in redirect to such a host is a callback port, so its owner is checked",
          arguments: ["http://127%E3%80%820%E3%80%820%E3%80%821:1455/cb", "http://127。0。0。1:1455/cb",
                      "http://⑫⑦.0.0.1:1455/cb", "http://%EF%BC%90%EF%BD%98:1455/cb"])
    func compatibilityRedirect(_ redirect: String) throws {
        var c = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        c.queryItems = [URLQueryItem(name: "redirect_uri", value: redirect)]
        #expect(ACAppDelegate.loopbackCallbackPort(from: try #require(c.url)) == 1455, "\(redirect)")
    }

    @Test("a host the browser's parser refuses opens nothing",
          arguments: ["http://ab%EF%BF%BD.com/", "http://evil.com%2F@127.0.0.1/", "http://a%20b.com/", "http://x%3A80/"])
    func refusedHosts(_ s: String) throws {
        let url = try #require(URL(string: s))
        #expect(!ACAppDelegate.opensInRealBrowser(url), "\(s) → \(url.host ?? "-")")
    }

    @Test("public names, Unicode or encoded, still open",
          arguments: ["https://bücher.de/", "https://b%C3%BCcher.de/", "https://☃.com/", "https://ＥＸＡＭＰＬＥ.com/",
                      "https://%EF%BC%A5%EF%BC%B8%EF%BC%A1%EF%BC%AD%EF%BC%B0%EF%BC%AC%EF%BC%A5.com/", "https://example.com/"])
    func publicUnicode(_ s: String) throws {
        #expect(ACAppDelegate.opensInRealBrowser(try #require(URL(string: s))), "\(s)")
    }

    @Test("a guest's sign-in URL for a fat client passes the same gate before it is published")
    func remoteRegistrationGated() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let r = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/ClaudeRegistrationCoordinator.swift"), encoding: .utf8)
        let gate = try #require(r.range(of: "guard ACAppDelegate.opensInRealBrowser(url) else {"))
        let publish = try #require(r.range(of: "url: url.absoluteString, callbackPort:"))
        #expect(gate.lowerBound < publish.lowerBound)
        // And the client checks again before it opens (an older server).
        let f = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/FatClientController.swift"), encoding: .utf8)
        let open = try #require(f.range(of: "remote registration: opening sign-in page locally"))
        let clientGate = try #require(f[open.upperBound...].range(of: "guard ACAppDelegate.opensInRealBrowser(url) else {"))
        let opened = try #require(f[open.upperBound...].range(of: "NSWorkspace.shared.open(url)"))
        #expect(clientGate.lowerBound < opened.lowerBound)
    }
}
