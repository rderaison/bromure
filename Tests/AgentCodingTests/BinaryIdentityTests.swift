import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

@Suite("Strict sandbox binary identity")
struct BinaryIdentityTests {
    static let policyYAML = """
    version: 1
    network_policies:
      github:
        endpoints:
          - { host: api.github.com, port: 443, protocol: rest, enforcement: enforce, access: read-only }
        binaries: [{ path: /usr/bin/gh }]
      pypi:
        endpoints: [{ host: pypi.org, port: 443 }]
        binaries: [{ path: "/usr/bin/python3*" }]
      nobody:
        endpoints: [{ host: nobody.example.com, port: 443 }]
    """

    private func id(_ exe: String, _ parents: [String] = []) -> OpenShellPolicy.BinaryIdentity {
        .init(exe: exe, sha256: "h-" + exe, ancestors: parents.map { .init(exe: $0, sha256: "h-" + $0) })
    }

    @Test("Rules apply to their binaries, globs, and processes they start")
    func binaryMatching() throws {
        let p = try OpenShellPolicy.parse(Self.policyYAML).withProviderLayer([("claude", [.init(host: "api.anthropic.com")])])
        func allowed(_ host: String, _ identity: OpenShellPolicy.BinaryIdentity?) -> Bool {
            if case .allow = p.evaluateConnect(hostnames: [host], ip: nil, port: 443,
                                               identity: identity, enforceBinaries: true) { return true }
            return false
        }
        #expect(allowed("api.github.com", id("/usr/bin/gh")))
        #expect(!allowed("api.github.com", id("/usr/bin/curl")))
        #expect(allowed("api.github.com", id("/usr/lib/git-core/git-remote-https", ["/usr/bin/gh", "/usr/bin/bash"])))
        #expect(allowed("pypi.org", id("/usr/bin/python3.12")))
        #expect(!allowed("pypi.org", id("/usr/local/bin/python3.12")))
        #expect(!allowed("nobody.example.com", id("/usr/bin/curl")))          // empty binaries = nothing
        #expect(!allowed("api.github.com", nil))                              // no identity
        #expect(allowed("api.anthropic.com", nil))                            // provider rules: any binary
        // Without enforcement, binaries stay advisory.
        if case .deny = p.evaluateConnect(hostnames: ["nobody.example.com"], ip: nil, port: 443) {
            Issue.record("advisory mode must ignore binaries")
        }
    }

    @Test("L7 rules are scoped to the rules that apply to the binary")
    func l7Scoped() throws {
        let p = try OpenShellPolicy.parse(Self.policyYAML)
        #expect(p.evaluateRequest(host: "api.github.com", port: 443, method: "GET", target: "/user",
                                  identity: id("/usr/bin/gh"), enforceBinaries: true) == .allow)
        // Another binary on the same host: no applicable rule → nothing inspects → allowed at L7
        // (the connection layer has already refused it).
        if case .deny = p.evaluateConnect(hostnames: ["api.github.com"], ip: nil, port: 443,
                                          identity: id("/usr/bin/curl"), enforceBinaries: true) {} else {
            Issue.record("curl must not connect")
        }
    }

    @Test("EgressPolicy carries enforcement into verdicts")
    func egressBridge() throws {
        var e = EgressPolicy(openShell: try OpenShellPolicy.parse(Self.policyYAML))
        e.enforceBinaries = true
        #expect(e.verdict(ip: nil, hostnames: ["api.github.com"], proto: .tcp, port: 443, identity: id("/usr/bin/gh")) == .mitm)
        #expect(e.verdict(ip: nil, hostnames: ["api.github.com"], proto: .tcp, port: 443, identity: nil) == .deny)
    }

    @Test("Hashes are pinned on first use; a changed binary loses its identity")
    func tofu() async {
        let svc = BinaryIdentityService()
        let pid = UUID()
        var hash = "aaa"
        svc.queryOverride = { _, _ in
            ["ok": true, "exe": "/usr/bin/gh", "sha256": hash,
             "ancestors": [["exe": "/usr/bin/bash", "sha256": "bash1"]]]
        }
        let first = await svc.identity(profileID: pid, sport: 1000, dst: "1.2.3.4", dport: 443)
        #expect(first?.exe == "/usr/bin/gh")
        #expect(first?.chain == ["/usr/bin/gh", "/usr/bin/bash"])
        hash = "bbb"
        let second = await svc.identity(profileID: pid, sport: 1001, dst: "1.2.3.4", dport: 443)
        #expect(second == nil)
        svc.queryOverride = { _, _ in ["ok": false, "reason": "ambiguous"] }
        #expect(await svc.identity(profileID: pid, sport: 1002, dst: "1.2.3.4", dport: 443) == nil)
    }

    @Test("A strict revocation that didn't fully apply withholds every identity (binary rules fail closed)")
    func strictNotApplied() async {
        let svc = BinaryIdentityService()
        let pid = UUID()
        svc.queryOverride = { _, _ in ["ok": true, "exe": "/usr/bin/gh", "sha256": "aaa", "ancestors": []] }
        defer { GuestSandboxStatusStore.shared.reset(profileID: pid) }
        GuestSandboxStatusStore.shared.update(profileID: pid, report: ["event": "sandbox_status", "strict_applied": false])
        #expect(await svc.identity(profileID: pid, sport: 1000, dst: "1.2.3.4", dport: 443) == nil)
        GuestSandboxStatusStore.shared.update(profileID: pid, report: ["event": "sandbox_status", "strict_applied": true])
        #expect(await svc.identity(profileID: pid, sport: 1001, dst: "1.2.3.4", dport: 443)?.exe == "/usr/bin/gh")
    }

    @Test("The attestor channel pins the first secret and refuses impostors")
    func secretPinning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attest-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secretFile = dir.appendingPathComponent("attestor.secret")
        let bridge = AttestorBridge(profileID: UUID(), secretFile: secretFile)
        let secret = String(repeating: "ab", count: 32)

        func connect(_ s: String) -> (Int32, Thread) {
            var fds: [Int32] = [0, 0]
            _ = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!) }
            let hello = "{\"hello\":\"attestd\",\"version\":1,\"secret\":\"\(s)\"}\n"
            _ = hello.withCString { write(fds[0], $0, strlen($0)) }
            let t = Thread { bridge.handshakeAndServe(fds[1], connection: nil) }
            t.start()
            return (fds[0], t)
        }
        let (a, _) = connect(secret)
        for _ in 0..<50 where !bridge.isConnected { usleep(20_000) }
        #expect(bridge.isConnected)
        #expect((try? String(contentsOf: secretFile, encoding: .utf8)) == secret)
        // A second connection is refused while the channel is taken…
        let (b, _) = connect(String(repeating: "cd", count: 32))
        var byte: UInt8 = 0
        #expect(read(b, &byte, 1) == 0)                                  // closed by the host
        close(b)
        // …and after the real attestor drops, only its secret may reattach.
        close(a)
        for _ in 0..<50 where bridge.isConnected { usleep(20_000) }
        let (c, _) = connect(String(repeating: "ef", count: 32))
        #expect(read(c, &byte, 1) == 0)
        close(c)
        let (d, _) = connect(secret)
        for _ in 0..<50 where !bridge.isConnected { usleep(20_000) }
        #expect(bridge.isConnected)
        close(d)
    }
}
