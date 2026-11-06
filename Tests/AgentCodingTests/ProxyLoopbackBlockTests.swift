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

    @Test("with no policy, pin refuses loopback and pins the answers it checked")
    func pinWithoutPolicy() {
        let blocked = UpstreamPinning.pin(policy: nil, host: "127.0.0.1", port: 9223, identity: nil, enforceBinaries: false)
        if case .success = blocked { Issue.record("loopback must be refused without a policy") }
        let ok = UpstreamPinning.pin(policy: nil, host: "10.0.0.5", port: 80, identity: nil, enforceBinaries: false)
        if case .success(let addrs) = ok { #expect(addrs == [IP("10.0.0.5")!]) } else { Issue.record("LAN must pass") }
        let checked = UpstreamPinning.checkedAddresses(host: "rebind.example", port: 443) { _, _ in [IP("93.184.215.14")!] }
        if case .success(let addrs) = checked { #expect(addrs == [IP("93.184.215.14")!]) } else { Issue.record("public must pass") }
        if case .success(let addrs) = UpstreamPinning.checkedAddresses(host: InferenceService.localMitmHost, port: 443) {
            #expect(addrs == nil)
        }
    }

    @Test("a dial to an unchecked destination is checked and pinned at the dial")
    func checkedForDial() {
        #expect(UpstreamPinning.checkedForDial(host: "127.0.0.1", port: 80) == nil)
        #expect(UpstreamPinning.checkedForDial(host: "[::ffff:127.0.0.1]", port: 80) == nil)
        #expect(UpstreamPinning.checkedForDial(host: "10.0.0.5", port: 80) == [IP("10.0.0.5")!])
        #expect(UpstreamPinning.checkedForDial(host: InferenceService.localMitmHost, port: 443) == nil)
    }

    /// The session's dialer connects where the check said, never where a
    /// second lookup would: the names here can't resolve at all, so a dial by
    /// name would fail.
    @Test("the dialer connects to the checked addresses, never by name")
    func dialerPins() throws {
        let server = try LoopbackServer()
        defer { server.close() }
        let ip = IP("127.0.0.1")!
        let dialer = try PinnedUpstreamDialer(host: "pinned.invalid", port: server.port, addresses: [ip],
                                              others: { h, _ in h == "redirect.invalid" ? [ip] : nil })
        defer { dialer.shutdownListener() }
        #expect(try connectStatus(dialer, "pinned.invalid:\(server.port)") == 200)
        #expect(try connectStatus(dialer, "redirect.invalid:\(server.port)") == 200)
        #expect(try connectStatus(dialer, "refused.invalid:\(server.port)") == 403)

        let strict = try PinnedUpstreamDialer(host: "pinned.invalid", port: server.port, addresses: [ip])
        defer { strict.shutdownListener() }
        #expect(try connectStatus(strict, "redirect.invalid:\(server.port)") == 403)

        let unresolved = try PinnedUpstreamDialer(host: "pinned.invalid", port: server.port, addresses: [],
                                                  others: { _, _ in nil })
        defer { unresolved.shutdownListener() }
        #expect(try connectStatus(unresolved, "pinned.invalid:\(server.port)") == 403)
    }

    private func connectStatus(_ dialer: PinnedUpstreamDialer, _ authority: String) throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        defer { close(fd) }
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_addr.s_addr = inet_addr("127.0.0.1")
        sa.sin_port = in_port_t(UInt16(dialer.port)).bigEndian
        let rc = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let req = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n"
        _ = req.withCString { write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return 0 }
        let line = String(decoding: buf[0..<n], as: UTF8.self)
        return Int(line.split(separator: " ").dropFirst().first ?? "") ?? 0
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

/// A loopback listener that accepts and holds connections.
private final class LoopbackServer: @unchecked Sendable {
    let fd: Int32
    let port: Int
    init() throws {
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0 && listen(s, 8) == 0
        guard ok else { Darwin.close(s); throw POSIXError(.EADDRINUSE) }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        fd = s
        port = Int(UInt16(bigEndian: got.sin_port))
    }
    func close() { Darwin.close(fd) }
}
