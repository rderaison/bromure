import Foundation
import Testing
import Security
@testable import bromure_ac

/// The root tunnel helper used to route whatever `SETUP <cidr>` named into a
/// utun whose fd it handed to any process of the console user — so anything
/// running as that user could pull the Mac's traffic (0.0.0.0/1 + 128.0.0.0/1)
/// into a tunnel it reads, with no admin prompt, and a remote could advertise
/// such a "subnet" too. Now: a private /24 nothing else routes, a caller
/// signed like the helper, and at most 16 tunnels.
@Suite("Tunnel helper: what it routes, for whom, and how many", .serialized)
struct FatClientTunnelAdmissionTests {
    static let viaDefault = (ok: true, output: """
       route to: 192.168.64.0
    destination: default
           mask: default
        gateway: 192.168.1.1
      interface: en0
    """)

    static func admit(_ line: String?, _ lookup: (ok: Bool, output: String) = viaDefault) -> Result<String, FatClientTunnelDaemon.Refusal> {
        FatClientTunnelDaemon.admit(line, routeGet: { _ in lookup })
    }

    @Test("a workspace subnet or a fleet alias is routed")
    func admitsSlash24() {
        #expect(Self.admit("SETUP 192.168.64.0/24") == .success("192.168.64.0/24"))
        #expect(Self.admit("SETUP 100.64.3.0/24") == .success("100.64.3.0/24"))
        #expect(Self.admit("SETUP 10.0.0.0/24 ") == .success("10.0.0.0/24"))
        #expect(Self.admit("SETUP 172.31.9.0/24") == .success("172.31.9.0/24"))
        // Nothing routes it at all (no default route either): still free.
        #expect(Self.admit("SETUP 192.168.64.0/24", (false, "route: writing to routing socket: not in table"))
                == .success("192.168.64.0/24"))
    }

    @Test("anything wider, public, or oddly spelled is refused",
          arguments: ["0.0.0.0/1", "128.0.0.0/1", "0.0.0.0/0", "default", "192.168.0.0/16", "10.0.0.0/8",
                      "8.8.8.0/24", "1.1.1.1/32", "192.168.64.5/24", "192.168.064.0/24", "172.32.0.0/24",
                      "100.128.0.0/24", "192.168.64.0/24 -ifscope en0", "-inet6", "192.168.64.0", "",
                      "１92.168.64.0/24"])
    func refusesOthers(cidr: String) {
        guard case .failure(let r) = Self.admit("SETUP \(cidr)") else {
            Issue.record("\(cidr) was admitted"); return
        }
        #expect(r.reason.hasPrefix("cidr "))
    }

    @Test("a /24 another route already covers (LAN, VPN, earlier tunnel) is refused")
    func refusesCovered() {
        let vpn = (ok: true, output: """
           route to: 192.168.64.0
        destination: 192.168.0.0
               mask: 255.255.0.0
          interface: utun4
        """)
        guard case .failure(let r) = Self.admit("SETUP 192.168.64.0/24", vpn) else {
            Issue.record("covered /24 admitted"); return
        }
        #expect(r.reason == "route taken: 192.168.64.0/24 is already routed to 192.168.0.0 mask 255.255.0.0 on utun4")
        let why = FatClientTunnelDiagnosis.explainSetupError("ERR " + r.reason + "\n", cidr: "192.168.64.0/24")
        #expect(why.contains("already routes 192.168.64.0/24") && why.contains("utun4"))
        #expect(Self.admit("GET / HTTP/1.1") == .failure(.init(reason: "bad request")))
        #expect(Self.admit(nil) == .failure(.init(reason: "bad request")))
    }

    @Test("no more than 16 tunnels at once")
    func slots() {
        var held = 0
        while FatClientTunnelDaemon.reserveSlot() { held += 1; if held > 100 { break } }
        #expect(held == FatClientTunnelDaemon.maxTunnels)
        FatClientTunnelDaemon.releaseSlot()
        #expect(FatClientTunnelDaemon.reserveSlot())
        #expect(!FatClientTunnelDaemon.reserveSlot())
        for _ in 0..<held { FatClientTunnelDaemon.releaseSlot() }
    }

    @Test("refusals say why")
    func explanations() {
        let e = FatClientTunnelDiagnosis.explainSetupError
        #expect(e("ERR cidr 0.0.0.0/1: not a private /24 network\n", "0.0.0.0/1").contains("0.0.0.0/1"))
        #expect(e("ERR unsigned: the caller isn't signed like this helper\n", "10.0.0.0/24").contains("Login Items"))
        #expect(e("ERR busy: 16 tunnels already open\n", "10.0.0.0/24").contains("16"))
    }

    /// A socket we accept on, with /usr/bin/nc (Apple-signed, not us) connected.
    static func withNCPeer(_ body: (Int32) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tun-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s").path
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(lfd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strcpy($0, src) } }
        }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0 && listen(lfd, 1) == 0)
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-U", path]
        nc.standardInput = Pipe()          // held open: nc stays connected
        nc.standardOutput = FileHandle.nullDevice
        try nc.run()
        defer { nc.terminate() }
        let cfd = accept(lfd, nil, nil)
        #expect(cfd >= 0)
        defer { close(cfd) }
        try body(cfd)
    }

    static func peerToken(_ fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        return getsockopt(fd, 0, 0x006, &token, &len) == 0 ? token : nil
    }

    @Test("a caller signed like the helper is served; another program isn't")
    func signature() throws {
        // Ourselves, over a socketpair: the same code as the "helper".
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        #expect(FatClientTunnelDaemon.peerSignedLikeSelf(fds[0]))
        try Self.withNCPeer { #expect(!FatClientTunnelDaemon.peerSignedLikeSelf($0)) }
    }

    @Test("the requirement is pinned once, and the pin — not the file on disk — decides")
    func pinnedRequirement() throws {
        // One object for the process's lifetime: never re-read from the bundle,
        // where a console user may have swapped in an ad-hoc binary.
        let pin = try #require(FatClientTunnelDaemon.selfRequirement)
        #expect(FatClientTunnelDaemon.selfRequirement === pin)
        var ncReq: SecRequirement?
        #expect(SecRequirementCreateWithString("identifier \"com.apple.nc\" and anchor apple" as CFString, [], &ncReq) == errSecSuccess)
        let nc = try #require(ncReq)
        try Self.withNCPeer { fd in
            let token = try #require(Self.peerToken(fd))
            #expect(FatClientTunnelDaemon.signed(auditToken: token, satisfying: nc))
            #expect(!FatClientTunnelDaemon.signed(auditToken: token, satisfying: pin))
        }
    }
}
