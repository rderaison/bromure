import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "Kube bearer and exec tokens are scoped to host:port,
/// so the proxy never injects them". A kubeconfig server on `https://h:6443`
/// registered its bearer / exec stand-in under the scope `h:6443`, while the
/// swap was handed the connection's bare host (CONNECT's host, or the SNI):
/// `h` neither equals nor is a subdomain of `h:6443`, so the guest's fake
/// went upstream and the API server answered 401. Now the host and the
/// dialed port are compared separately.
@Suite("Kube tokens on a non-443 API port are swapped, on that port only")
@MainActor
struct KubeTokenPortScopeTests {
    static func request(_ token: String) -> Data {
        Data("GET /api/v1/namespaces HTTP/1.1\r\nhost: k8s.example.com:6443\r\nauthorization: Bearer \(token)\r\n\r\n".utf8)
    }

    static func sent(_ swap: SwapResult) -> String { String(decoding: swap.modified, as: UTF8.self) }

    /// The workspace's swap map, built the way the app builds it from the material.
    static func install(_ mat: KubeconfigMaterializer.Materialized, _ swapper: TokenSwapper, _ pid: UUID) {
        swapper.setMap(TokenMap(entries: mat.bearerSwaps.map {
            TokenMap.Entry(fake: $0.fakeToken, real: $0.realToken, host: $0.host,
                           consentCredentialID: $0.consentCredentialID, consentDisplayName: $0.consentDisplayName)
        }), for: pid)
    }

    @Test("a bearer for h:6443 is swapped on a connection to h port 6443, not on 443")
    func bearerOnAPIPort() async throws {
        var p = Profile(name: "k", tool: .claude, authMode: .token)
        p.kubeconfigs = [
            KubeconfigEntry(name: "api", serverURL: "https://k8s.example.com:6443", caCertPEM: "",
                            auth: .bearerToken("REAL-6443")),
            KubeconfigEntry(name: "ingress", serverURL: "https://k8s.example.com", caCertPEM: "",
                            auth: .bearerToken("REAL-443")),
        ]
        let mat = KubeconfigMaterializer().materialize(profile: p, bromureCAPEM: "PEM")
        let swapper = TokenSwapper(consent: ConsentBroker()), pid = UUID()
        Self.install(mat, swapper, pid)
        let f6443 = try #require(mat.bearerSwaps.first { $0.realToken == "REAL-6443" }).fakeToken
        let f443 = try #require(mat.bearerSwaps.first { $0.realToken == "REAL-443" }).fakeToken

        let onAPI = await swapper.swap(rawRequest: Self.request(f6443), host: "k8s.example.com", port: 6443, profileID: pid)
        #expect(Self.sent(onAPI).contains("Bearer REAL-6443"))
        // Same name, the other context's port: each keeps its own token.
        let cross = await swapper.swap(rawRequest: Self.request(f6443), host: "k8s.example.com", port: 443, profileID: pid)
        #expect(!Self.sent(cross).contains("REAL-"))
        let bare = await swapper.swap(rawRequest: Self.request(f443), host: "k8s.example.com", port: 443, profileID: pid)
        #expect(Self.sent(bare).contains("Bearer REAL-443"))
        let bareOnAPI = await swapper.swap(rawRequest: Self.request(f443), host: "k8s.example.com", port: 6443, profileID: pid)
        #expect(!Self.sent(bareOnAPI).contains("REAL-"))
        // No port known: a port-scoped token stays out.
        let unknown = await swapper.swap(rawRequest: Self.request(f6443), host: "k8s.example.com", profileID: pid)
        #expect(!Self.sent(unknown).contains("REAL-"))

        // Its own host on its own port is the swap firing, not exfiltration;
        // on the other port the fake goes out useless, not a leak either.
        #expect(swapper.detectCompromise(rawRequest: Self.request(f6443), host: "k8s.example.com", profileID: pid).isEmpty)
        #expect(swapper.detectCompromise(rawRequest: Self.request(f6443), host: "evil.example", profileID: pid).count == 1)
    }

    @Test("an exec plugin's token, refreshed by the poller, reaches h:6443")
    func execOnAPIPort() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kexec-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plugin = dir.appendingPathComponent("plugin.sh")
        try """
        #!/bin/sh
        echo '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"REAL-EXEC"}}'
        """.write(to: plugin, atomically: true, encoding: .utf8)
        chmod(plugin.path, 0o755)

        var p = Profile(name: "k", tool: .claude, authMode: .token)
        p.kubeconfigs = [KubeconfigEntry(name: "eks", serverURL: "https://k8s.example.com:6443", caCertPEM: "",
                                         auth: .execPlugin(command: plugin.path, args: [], refreshSeconds: 3600))]
        let mat = KubeconfigMaterializer().materialize(profile: p, bromureCAPEM: "PEM")
        let ctx = try #require(mat.execContexts.first)
        #expect(ctx.host == mat.bearerSwaps.first?.host)   // the poller writes onto the swap's own entry
        let swapper = TokenSwapper(consent: ConsentBroker()), pid = UUID()
        Self.install(mat, swapper, pid)
        let poller = ExecCredentialPoller()
        poller.start(mat.execContexts, profileID: pid, swapper: swapper)
        defer { poller.stopAll() }
        for _ in 0..<100 where swapper.entries(for: pid).first?.real != "REAL-EXEC" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let swap = await swapper.swap(rawRequest: Self.request(ctx.fakeToken), host: "k8s.example.com", port: 6443, profileID: pid)
        #expect(Self.sent(swap).contains("Bearer REAL-EXEC"))
    }

    @Test("scopes split host from port; IPv6 literals and bare hosts keep any port")
    func scopes() {
        let m = TokenSwapper.hostMatchesScope(host:port:scope:)
        #expect(m("registry.example.com", 5000, "registry.example.com:5000"))
        #expect(!m("registry.example.com", 443, "registry.example.com:5000"))
        #expect(m("api.openai.com", 8443, "openai.com"))           // bare scope: as before
        #expect(!m("k8s.example.com.evil", 6443, "k8s.example.com:6443"))
        #expect(TokenSwapper.splitScope("fd00::1").port == nil)
        #expect(TokenSwapper.splitScope("h:6443") == ("h", 6443))
        #expect(TokenSwapper.splitScope("h:0").port == nil)
        #expect(KubeconfigEntry(name: "", serverURL: "https://h", caCertPEM: "", auth: .bearerToken("")).tokenScope == "h:443")
        #expect(KubeconfigEntry(name: "", serverURL: "http://h", caCertPEM: "", auth: .bearerToken("")).tokenScope == "h:80")
    }
}
