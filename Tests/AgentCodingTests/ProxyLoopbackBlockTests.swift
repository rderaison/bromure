import Foundation
import Testing
@testable import SandboxEngine
@testable import bromure_ac

/// The proxy runs on the user's Mac: with no OpenShell policy it used to
/// fetch whatever a guest named, the Mac's own loopback included (dev
/// servers, the automation API). Every workspace now gets OpenShell's
/// always-blocked set refused.
@Suite("Proxy never reaches the Mac's own loopback")
struct ProxyLoopbackBlockTests {
    typealias IP = OpenShellPolicy.IPAddress

    private func check(_ host: String, _ answers: [String] = []) -> Result<Void, OpenShellPolicy.DestinationDenial> {
        UpstreamPinning.defaultCheck(host: host, port: 80) { _, _ in answers.compactMap { IP($0) } }
    }
    private func denied(_ host: String, _ answers: [String] = []) -> Bool {
        if case .failure = check(host, answers) { return true }
        return false
    }

    @Test("loopback, link-local and unspecified literals are refused, in every form")
    func literals() {
        for h in ["127.0.0.1", "127.9.9.9", "169.254.169.254", "0.0.0.0", "[::1]", "::1", "[::]",
                  "[fe80::1]", "[::ffff:127.0.0.1]", "[::127.0.0.1]", "[64:ff9b::7f00:1]",
                  "[64:ff9b:1::7f00:1]", "[2002:7f00:1::1]", "[::ffff:169.254.169.254]", "127.0.0.1."] {
            #expect(denied(h), "\(h) should be refused")
        }
    }

    @Test("a name is refused when any of its answers is always-blocked")
    func names() {
        #expect(denied("localhost", ["127.0.0.1", "::1"]))
        #expect(denied("rebind.example", ["93.184.215.14", "127.0.0.1"]))
        #expect(denied("meta.example", ["169.254.169.254"]))
        if case .failure(let d) = check("localhost", ["127.0.0.1"]) {
            #expect(d.reason.contains("always-blocked address 127.0.0.1"))
        }
    }

    @Test("public and LAN destinations stay reachable")
    func allowed() {
        #expect(!denied("example.com", ["93.184.215.14", "2606:2800:21f:cb07:6820:80da:af6b:8b2c"]))
        for h in ["10.163.12.85", "192.168.64.3", "172.29.126.2", "[fd00::1]", "8.8.8.8"] {
            #expect(!denied(h), "\(h) should stay reachable")
        }
        #expect(!denied("registry.lan", ["192.168.1.20"]))
    }

    @Test("the local-model sentinel and names that don't resolve are left to the proxy")
    func sentinelAndUnresolved() {
        var looked = false
        let r = UpstreamPinning.defaultCheck(host: InferenceService.localMitmHost, port: 443) { _, _ in
            looked = true; return [IP("127.0.0.1")!]
        }
        if case .failure = r { Issue.record("bromure.llm must stay routable") }
        #expect(!looked)
        #expect(!denied("no-such-host.invalid", []))
    }

    @Test("with no policy, pin checks and still pins nothing")
    func pinWithoutPolicy() {
        let blocked = UpstreamPinning.pin(policy: nil, host: "127.0.0.1", port: 9223, identity: nil, enforceBinaries: false)
        if case .success = blocked { Issue.record("loopback must be refused without a policy") }
        let ok = UpstreamPinning.pin(policy: nil, host: "10.0.0.5", port: 80, identity: nil, enforceBinaries: false)
        if case .success(let addrs) = ok { #expect(addrs == nil) } else { Issue.record("LAN must pass") }
    }

    @Test("IPv6 forms carrying an IPv4 address are judged by it")
    func embedded() {
        #expect(UpstreamPinning.embeddedV4(IP("::ffff:10.1.2.3")!) == 0x0A01_0203)
        #expect(UpstreamPinning.embeddedV4(IP("64:ff9b::a01:203")!) == 0x0A01_0203)
        #expect(UpstreamPinning.embeddedV4(IP("2002:a01:203::1")!) == 0x0A01_0203)
        #expect(UpstreamPinning.embeddedV4(IP("::1")!) == nil)
        #expect(UpstreamPinning.embeddedV4(IP("2606:2800::1")!) == nil)
        #expect(UpstreamPinning.embeddedV4(IP("10.1.2.3")!) == nil)
    }
}
