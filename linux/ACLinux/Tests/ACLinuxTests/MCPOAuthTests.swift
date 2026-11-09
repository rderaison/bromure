import Foundation
import NIOConcurrencyHelpers
import SandboxEngine
import Testing
@testable import ACLinux

/// A remote MCP server's OAuth tokens at staging (macOS:
/// populateMCPBearerTokens, MCPOAuthBroker.refresh), against a token
/// endpoint on loopback.
@Suite("MCP OAuth tokens at staging", .serialized)
struct MCPOAuthTests {
    /// One-shot-per-connection HTTP server on 127.0.0.1: answers `reply`
    /// (status, body) and records each request it read.
    final class TokenEndpoint: @unchecked Sendable {
        let port: UInt16
        let requests = NIOLockedValueBox<[String]>([])
        private let fd: Int32
        init(status: Int, body: String, extraHeaders: String = "") throws {
            let lfd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            var one: Int32 = 1
            setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, len) } }
            listen(lfd, 8)
            _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(lfd, $0, &len) } }
            fd = lfd
            port = UInt16(bigEndian: a.sin_port)
            let reqs = requests
            let t = Thread {
                while true {
                    let c = accept(lfd, nil, nil)
                    if c < 0 { return }
                    var buf = [UInt8](repeating: 0, count: 65536)
                    var got = Data()
                    while true {
                        let n = read(c, &buf, buf.count)
                        if n <= 0 { break }
                        got.append(contentsOf: buf[0..<n])
                        if let r = got.range(of: Data("\r\n\r\n".utf8)) {
                            let head = String(decoding: got[..<r.lowerBound], as: UTF8.self)
                            let cl = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                            if got.count - r.upperBound >= cl { break }
                        }
                    }
                    reqs.withLockedValue { $0.append(String(decoding: got, as: UTF8.self)) }
                    let resp = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n\(extraHeaders)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    _ = resp.withCString { write(c, $0, strlen($0)) }
                    close(c)
                }
            }
            t.start()
        }
        func stop() { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
    }

    static func server(_ name: String, oauth: MCPOAuthState?, transport: MCPServer.Transport = .http,
                       enabled: Bool = true) -> MCPServer {
        var s = MCPServer(name: name, transport: transport, url: "https://mcp.example/\(name)", enabled: enabled)
        s.oauthState = oauth
        return s
    }

    /// The loopback endpoints below: only the endpoint check is relaxed (the
    /// transport, with its no-redirect rule, stays the daemon's).
    static func onLoopback<T>(_ body: () async throws -> T) async rethrows -> T {
        let prior = MCPOAuthBroker.endpointRefusal
        MCPOAuthBroker.endpointRefusal = { _, _ in nil }
        defer { MCPOAuthBroker.endpointRefusal = prior }
        return try await body()
    }

    @Test func aTokenAboutToExpireIsRefreshedAndHandedOn() async throws { try await Self.onLoopback {
        let ep = try TokenEndpoint(status: 200, body: #"{"access_token":"NEW-ACCESS","refresh_token":"NEW-REFRESH","expires_in":3600}"#)
        defer { ep.stop() }
        let endpoint = "http://127.0.0.1:\(ep.port)/token"
        func state(_ access: String, expires: TimeInterval?) -> MCPOAuthState {
            MCPOAuthState(clientID: "cid", clientSecret: "s&s", authorizationEndpoint: "https://x/auth", tokenEndpoint: endpoint,
                          accessToken: access, refreshToken: "OLD-REFRESH", expiresAt: expires.map { Date().addingTimeInterval($0) })
        }
        var p = Profile(name: "mcp", tool: .claude, authMode: .token)
        p.mcpServers = [Self.server("soon", oauth: state("OLD-ACCESS", expires: 30)),
                        Self.server("fresh", oauth: state("FRESH-ACCESS", expires: 7200)),
                        Self.server("none", oauth: nil),
                        Self.server("stdio", oauth: state("STDIO", expires: 30), transport: .stdio),
                        Self.server("off", oauth: state("OFF", expires: 30), enabled: false)]
        let out = await Daemon.populateMCPBearerTokens(p)
        #expect(out.mcpServers[0].bearerToken == "NEW-ACCESS")
        #expect(out.mcpServers[0].oauthState?.refreshToken == "NEW-REFRESH")
        #expect((out.mcpServers[0].oauthState?.expiresAt?.timeIntervalSinceNow ?? 0) > 3000)
        #expect(out.mcpServers[1].bearerToken == "FRESH-ACCESS", "not due: used as is")
        #expect(out.mcpServers[2].bearerToken == "" && out.mcpServers[3].bearerToken == "" && out.mcpServers[4].bearerToken == "",
                "no OAuth, stdio and disabled servers untouched")
        let reqs = ep.requests.withLockedValue { $0 }
        #expect(reqs.count == 1, "only the due one refreshed")
        #expect(reqs.first?.contains("grant_type=refresh_token&refresh_token=OLD-REFRESH&client_id=cid&client_secret=s%26s") == true,
                "\(reqs.first ?? "")")
    } }

    /// The client authorizes (macOS's editor runs the OAuth flow) and PUTs
    /// the profile: the shared merge keeps each server's oauthState, the
    /// shared secret split moves it out of the profile JSON into the
    /// encrypted secrets (as on macOS), and it comes back for staging.
    @Test func anOAuthStateSentByTheClientIsKeptAsASecret() async throws {
        var base = Profile(name: "mcp", tool: .claude, authMode: .token)
        let server = Self.server("remote", oauth: nil)
        base.mcpServers = [server]
        let state = MCPOAuthState(clientID: "cid", authorizationEndpoint: "https://x/auth", tokenEndpoint: "https://x/token",
                                  accessToken: "CLIENT-ACCESS", refreshToken: "CLIENT-REFRESH",
                                  expiresAt: Date().addingTimeInterval(7200))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var withState = server; withState.oauthState = state
        let doc: [String: Any] = ["mcpServers": [try JSONSerialization.jsonObject(with: enc.encode(withState))]]
        guard case .success(var merged) = ProfileDocument.merge(doc, over: base) else { Issue.record("merge failed"); return }
        #expect(merged.mcpServers.first?.oauthState?.accessToken == "CLIENT-ACCESS", "the PUT keeps it")
        let secrets = ProfileSecrets.extract(stripping: &merged)
        #expect(merged.mcpServers.first?.oauthState == nil, "not in the profile's JSON")
        #expect(!String(decoding: try enc.encode(merged), as: UTF8.self).contains("CLIENT-REFRESH"))
        var back = merged
        secrets.apply(to: &back)
        #expect(back.mcpServers.first?.oauthState?.refreshToken == "CLIENT-REFRESH", "restored from the secrets")
        let staged = await Daemon.populateMCPBearerTokens(back)
        #expect(staged.mcpServers.first?.bearerToken == "CLIENT-ACCESS", "and handed to the guest at staging")
    }

    @Test func aFailedRefreshKeepsTheStaleToken() async throws { try await Self.onLoopback {
        let ep = try TokenEndpoint(status: 400, body: #"{"error":"invalid_grant"}"#)
        defer { ep.stop() }
        var p = Profile(name: "mcp", tool: .claude, authMode: .token)
        p.mcpServers = [Self.server("soon", oauth: MCPOAuthState(
            clientID: "cid", authorizationEndpoint: "https://x/auth", tokenEndpoint: "http://127.0.0.1:\(ep.port)/token",
            accessToken: "STALE", refreshToken: "R", expiresAt: Date().addingTimeInterval(10)))]
        let out = await Daemon.populateMCPBearerTokens(p)
        #expect(out.mcpServers[0].bearerToken == "STALE")
        #expect(out.mcpServers[0].oauthState?.refreshToken == "R")
    } }

    /// A single-user server checks nothing (as macOS). On a multi-user one
    /// the endpoint is the user's and the POST goes out past the MITM: https,
    /// never loopback / link-local / unspecified, and a private address only
    /// when the workspace's own egress policy allows it. Names resolve through
    /// a stub: nothing is looked up for real.
    @Test func theTokenEndpointRulesFollowTheServerAndTheWorkspace() async throws {
        let prior = MCPOAuthBroker.resolver
        MCPOAuthBroker.resolver = { host, _ in
            switch host {
            case "idp.corp": return [OpenShellPolicy.IPAddress("10.2.3.4")!]
            case "split.example": return [OpenShellPolicy.IPAddress("93.184.216.34")!, OpenShellPolicy.IPAddress("fd00::1")!]
            case "public.example": return [OpenShellPolicy.IPAddress("93.184.216.34")!]
            case "meta.example": return [OpenShellPolicy.IPAddress("169.254.169.254")!]
            default: return OpenShellPolicy.IPAddress(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))).map { [$0] } ?? []
            }
        }
        defer { MCPOAuthBroker.resolver = prior }
        func refusal(_ url: String, multi: Bool = true, egress: EgressPolicy = .allowAll) async -> String? {
            await MCPOAuthBroker.checkEndpoint(URL(string: url)!, .init(multiUser: multi, egress: egress))
        }
        // Single-user: no check, as macOS.
        #expect(await refusal("http://127.0.0.1/token", multi: false) == nil)
        // Multi-user: always refused.
        for url in ["http://public.example/token", "https://127.0.0.1/token", "https://meta.example/latest",
                    "https://169.254.169.254/latest", "https://[::1]/token", "https://[fe80::1]/token",
                    "https://0.0.0.0/token", "https://unresolvable.example/token", "https:///token"] {
            #expect(await refusal(url) != nil, "\(url)")
        }
        #expect(await refusal("https://public.example/token") == nil)
        // Private (an in-house IdP; a ULA next to a public A): as the workspace's egress policy says.
        #expect(await refusal("https://idp.corp/token") == nil, "default allow lets the workspace reach it")
        let closed = try EgressPolicy.parse("allow tcp public.example:443\ndefault deny")
        #expect(await refusal("https://idp.corp/token", egress: closed) != nil)
        #expect(await refusal("https://split.example/token", egress: closed) != nil)
        let opened = try EgressPolicy.parse("allow tcp idp.corp:443\ndefault deny")
        #expect(await refusal("https://idp.corp/token", egress: opened) == nil)
        let denied = try EgressPolicy.parse("deny any 10.0.0.0/8\ndefault allow")
        #expect(await refusal("https://idp.corp/token", egress: denied) != nil)
        // And a refusal sends nothing.
        let ep = try TokenEndpoint(status: 200, body: #"{"access_token":"X"}"#)
        defer { ep.stop() }
        let state = MCPOAuthState(clientID: "c", authorizationEndpoint: "https://x/a", tokenEndpoint: "http://127.0.0.1:\(ep.port)/t",
                                  accessToken: "A", refreshToken: "R")
        await #expect(throws: MCPOAuthBroker.BrokerError.self) {
            _ = try await MCPOAuthBroker.refresh(state: state, policy: .init(multiUser: true, egress: .allowAll))
        }
        #expect(ep.requests.withLockedValue { $0 }.isEmpty, "nothing was sent")
    }

    /// A redirect from the token endpoint isn't followed.
    @Test func aRedirectIsNotFollowed() async throws { try await Self.onLoopback {
        let target = try TokenEndpoint(status: 200, body: #"{"access_token":"REDIRECTED"}"#)
        defer { target.stop() }
        let ep = try TokenEndpoint(status: 307, body: "", extraHeaders: "Location: http://127.0.0.1:\(target.port)/t\r\n")
        defer { ep.stop() }
        let state = MCPOAuthState(clientID: "c", authorizationEndpoint: "https://x/a", tokenEndpoint: "http://127.0.0.1:\(ep.port)/t",
                                  accessToken: "A", refreshToken: "R")
        await #expect(throws: MCPOAuthBroker.BrokerError.self) { _ = try await MCPOAuthBroker.refresh(state: state) }
        #expect(target.requests.withLockedValue { $0 }.isEmpty, "the redirect target got nothing")
    } }
}
