import Foundation
import Testing
@testable import bromure_ac

@Suite("FatClientPAC")
struct FatClientPACTests {
    @Test("parseCIDR converts prefix to dotted netmask")
    func cidr() {
        #expect(FatClientPAC.parseCIDR("192.168.64.0/24").map { "\($0.network) \($0.netmask)" }
            == "192.168.64.0 255.255.255.0")
        #expect(FatClientPAC.parseCIDR("10.0.0.0/8")?.netmask == "255.0.0.0")
        #expect(FatClientPAC.parseCIDR("100.64.3.0/23")?.netmask == "255.255.254.0")
        #expect(FatClientPAC.parseCIDR("0.0.0.0/0")?.netmask == "0.0.0.0")
    }

    @Test("parseCIDR rejects malformed / injection input")
    func cidrRejects() {
        #expect(FatClientPAC.parseCIDR("192.168.64.0") == nil)          // no prefix
        #expect(FatClientPAC.parseCIDR("192.168.64.0/33") == nil)       // prefix too big
        #expect(FatClientPAC.parseCIDR("192.168.999.0/24") == nil)      // octet > 255
        #expect(FatClientPAC.parseCIDR("evil\";}/24") == nil)           // JS injection attempt
        #expect(FatClientPAC.parseCIDR("192.168.64.0/24/8") == nil)     // extra segment
    }

    @Test("script routes the subnet through SOCKS and everything else DIRECT")
    func single() throws {
        let pac = try #require(FatClientPAC.script(routes: [
            .init(cidr: "192.168.64.0/24", proxyHost: "192.168.127.1", proxyPort: 51234)
        ]))
        #expect(pac.contains("function FindProxyForURL(url, host)"))
        #expect(pac.contains(#"isInNet(host, "192.168.64.0", "255.255.255.0")"#))
        #expect(pac.contains(#"return "SOCKS5 192.168.127.1:51234";"#))
        #expect(pac.contains(#"return "DIRECT";"#))
    }

    @Test("script emits one clause per fleet host")
    func fleet() throws {
        let pac = try #require(FatClientPAC.script(routes: [
            .init(cidr: "192.168.64.0/24", proxyHost: "192.168.127.1", proxyPort: 5001),
            .init(cidr: "100.64.1.0/24", proxyHost: "192.168.127.1", proxyPort: 5002),
        ]))
        #expect(pac.contains(#""192.168.64.0", "255.255.255.0""#))
        #expect(pac.contains(#""100.64.1.0", "255.255.255.0""#))
        #expect(pac.contains("5001"))
        #expect(pac.contains("5002"))
    }

    @Test("script returns nil when no route is usable")
    func empty() {
        #expect(FatClientPAC.script(routes: []) == nil)
        #expect(FatClientPAC.script(routes: [
            .init(cidr: "garbage", proxyHost: "127.0.0.1", proxyPort: 5000)]) == nil)
        // Bad proxy host / port are dropped too.
        #expect(FatClientPAC.script(routes: [
            .init(cidr: "192.168.64.0/24", proxyHost: "not-an-ip", proxyPort: 5000)]) == nil)
        #expect(FatClientPAC.script(routes: [
            .init(cidr: "192.168.64.0/24", proxyHost: "127.0.0.1", proxyPort: 0)]) == nil)
    }
}
