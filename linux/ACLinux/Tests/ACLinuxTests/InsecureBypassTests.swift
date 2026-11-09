import Foundation
import NIOSSL
import Testing
@testable import ACLinux

/// `X-bromure-insecure: yes` (macOS: driveTLS's insecure-upstream opt-out):
/// where the workspace allows it, no validation of that request's upstream
/// certificate and no real credential on it; the header never goes upstream.
@Suite("Insecure-upstream opt-out")
struct InsecureBypassTests {
    static let host = "selfsigned.example.test"
    static let fake = "brm-standin-for-the-insecure-test"

    static func proxy(_ dir: String, _ pid: UUID, allow: Bool) throws -> MitmProxy {
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "the-real-secret", host: host),
                                                TokenMap.Entry(fake: "brm-mcp_0123456789abcdef", real: "the-mcp-bearer", host: host)]),
                             for: pid)
        proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [], allowInsecureBypass: allow), for: pid)
        return proxy
    }

    static func forward(_ proxy: MitmProxy, _ pid: UUID, _ value: String) async -> (String, Bool)? {
        var trace: RequestReader.Trace?
        let req = "GET /api HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(fake)\r\nX-bromure-insecure: \(value)\r\n\r\n"
        guard case .forward(let out, _, _, _, _, _, _, _, _, _, _, _, let insecure) =
                await RequestReader.rewrite(Data(req.utf8), proxy: proxy, profileID: pid, host: host, port: 443,
                                            tls: true, session: proxy.strictSession(of: pid), trace: &trace) else { return nil }
        return (String(decoding: out, as: UTF8.self), insecure)
    }

    @Test func allowedItSkipsValidationAndEveryRealCredential() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let pid = UUID()
        let proxy = try Self.proxy(dir, pid, allow: true)
        for v in ["yes", "TRUE", " 1 "] {
            let (out, insecure) = try #require(await Self.forward(proxy, pid, v))
            #expect(insecure, "\(v)")
            #expect(out.contains("Bearer \(Self.fake)") && !out.contains("the-real-secret"), "the fake, never the real one")
            #expect(!out.contains("the-mcp-bearer"), "no MCP bearer either")
            #expect(!out.lowercased().contains("x-bromure-insecure"), "the control header stays here")
        }
        // Any other value: an ordinary request.
        let (out, insecure) = try #require(await Self.forward(proxy, pid, "no"))
        #expect(!insecure && out.contains("the-real-secret") && !out.lowercased().contains("x-bromure-insecure"))
    }

    @Test func notAllowedTheHeaderIsIgnored() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let pid = UUID()
        let proxy = try Self.proxy(dir, pid, allow: false)
        let (out, insecure) = try #require(await Self.forward(proxy, pid, "yes"))
        #expect(!insecure && out.contains("the-real-secret"))
        #expect(!out.lowercased().contains("x-bromure-insecure"))
    }

    @Test func theUntrustedCertificate502OffersItWhereAllowed() throws {
        let untrusted: Error = NIOSSLExtraError.failedToValidateHostname
        let withHint = describeUpstreamError(untrusted, host: Self.host, allowInsecureHint: true)
        let without = describeUpstreamError(untrusted, host: Self.host, allowInsecureHint: false)
        #expect(withHint.isTrust)
        #expect(withHint.body.contains("`X-bromure-insecure: yes`") && !without.body.contains("X-bromure-insecure"))
        #expect(UpstreamFailure(untrusted).urlErrorCode == -1202)
    }
}
