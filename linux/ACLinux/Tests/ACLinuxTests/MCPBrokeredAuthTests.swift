import Foundation
import Testing
@testable import ACLinux

/// A brokered MCP server (its `brm-mcp_` stand-in in the token map): its
/// OAuth discovery is "not found", and its requests get the real bearer
/// (macOS: driveTLS's 4a and 5b).
@Suite("Brokered MCP auth on the proxy")
struct MCPBrokeredAuthTests {
    static let host = "mcp.example.test"
    static let real = "the-brokered-oauth-access-token"

    static func proxy(_ dir: String, _ pid: UUID) throws -> MitmProxy {
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: "brm-mcp_0123456789abcdef", real: real, host: host)]), for: pid)
        return proxy
    }

    static func plan(_ proxy: MitmProxy, _ pid: UUID, _ req: String, host: String = host) async -> RequestReader.Plan {
        var trace: RequestReader.Trace?
        return await RequestReader.rewrite(Data(req.utf8), proxy: proxy, profileID: pid, host: host, port: 443,
                                           tls: true, session: proxy.strictSession(of: pid), trace: &trace)
    }

    @Test func discoveryIsNotFoundForABrokeredHostOnly() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let pid = UUID()
        let proxy = try Self.proxy(dir, pid)
        for path in ["/.well-known/oauth-authorization-server", "/.well-known/oauth-protected-resource/mcp",
                     "/.well-known/openid-configuration"] {
            guard case .answer(let a) = await Self.plan(proxy, pid, "GET \(path) HTTP/1.1\r\nHost: \(Self.host)\r\n\r\n") else {
                Issue.record("\(path) went upstream"); continue
            }
            #expect(String(decoding: a, as: UTF8.self).hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        }
        // Another host's discovery, or this host's other paths: on to upstream.
        if case .answer = await Self.plan(proxy, pid, "GET /.well-known/openid-configuration HTTP/1.1\r\nHost: other.example.test\r\n\r\n",
                                          host: "other.example.test") {
            Issue.record("a host with no broker token was answered")
        }
        if case .answer = await Self.plan(proxy, pid, "POST /mcp HTTP/1.1\r\nHost: \(Self.host)\r\nContent-Length: 2\r\n\r\n{}") {
            Issue.record("an MCP call was answered")
        }
    }

    @Test func theRealBearerIsAddedUnlessTheRequestHasOne() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let pid = UUID()
        let proxy = try Self.proxy(dir, pid)
        guard case .forward(let out, _, _, _, _, _, _, _, _, _, _, _, _) =
                await Self.plan(proxy, pid, "POST /mcp HTTP/1.1\r\nHost: \(Self.host)\r\nContent-Length: 2\r\n\r\n{}") else {
            Issue.record("not forwarded"); return
        }
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("\r\nAuthorization: Bearer \(Self.real)\r\n"), "\(text)")
        #expect(text.hasSuffix("\r\n\r\n{}"), "the body intact")
        guard case .forward(let kept, _, _, _, _, _, _, _, _, _, _, _, _) =
                await Self.plan(proxy, pid, "GET /mcp HTTP/1.1\r\nHost: \(Self.host)\r\nAuthorization: Bearer theirs\r\n\r\n") else {
            Issue.record("not forwarded"); return
        }
        let k = String(decoding: kept, as: UTF8.self)
        #expect(k.contains("Authorization: Bearer theirs") && !k.contains(Self.real), "the request's own header stands")
    }
}

/// An OpenShell credential placeholder left after the swap (its credential
/// bound to another host): refused, never sent literally (macOS: driveTLS's
/// credential_endpoint_mismatch).
@Suite("OpenShell placeholders on the proxy")
struct OpenShellPlaceholderProxyTests {
    @Test func aPlaceholderGoesOnlyToItsHostResolved() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let pid = UUID()
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let ph = TokenSwapper.openShellPlaceholderPrefix + "GH_TOKEN"
        proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: ph, real: "the-real-github-token", host: "api.github.com")]), for: pid)
        func plan(_ host: String) async -> RequestReader.Plan {
            var trace: RequestReader.Trace?
            let req = "GET /user/repos?x=1 HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(ph)\r\n\r\n"
            return await RequestReader.rewrite(Data(req.utf8), proxy: proxy, profileID: pid, host: host, port: 443,
                                               tls: true, session: proxy.strictSession(of: pid), trace: &trace)
        }
        // To another host: refused, never sent literally (the compromise
        // check answers first, as on macOS, where it also runs before the
        // placeholder check).
        guard case .answer(let refused) = await plan("evil.example.test") else { Issue.record("sent"); return }
        #expect(!String(decoding: refused, as: UTF8.self).contains(ph))
        guard case .forward(let out, _, _, _, _, _, _, _, _, _, _, _, _) = await plan("api.github.com") else {
            Issue.record("refused on its own host"); return
        }
        #expect(String(decoding: out, as: UTF8.self).contains("Bearer the-real-github-token"))
    }

    @Test func theBodyCountsOnlyWhereTheEndpointResolvesIt() {
        let ph = TokenSwapper.openShellPlaceholderPrefix + "X"
        let req = Data("POST / HTTP/1.1\r\nHost: h\r\n\r\n{\"k\":\"\(ph)\"}".utf8)
        #expect(RequestReader.unresolvedPlaceholder(in: req, checkBody: false, known: [ph]) == nil)
        #expect(RequestReader.unresolvedPlaceholder(in: req, checkBody: true, known: [ph]) == ph)
        #expect(RequestReader.unresolvedPlaceholder(in: req, checkBody: true, known: ["brm-other"]) == nil)
    }
}
