import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
        /// Runs before each reply (on the server's thread): a test holds it there.
        init(status: Int, body: String, extraHeaders: String = "", beforeReply: (@Sendable () -> Void)? = nil) throws {
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
                    beforeReply?()
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
        let prior = MCPOAuthBroker.endpointCheck
        MCPOAuthBroker.endpointCheck = { _, _ in .unchecked }
        defer { MCPOAuthBroker.endpointCheck = prior }
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

    /// On a multi-user server the MITM's own refusals apply too, public
    /// answers included: this server's addresses (another user's service may
    /// listen there) and every account's LAN pool.
    @Test func theServersOwnAddressesAreRefused() async throws {
        let priorR = MCPOAuthBroker.resolver, priorH = MCPOAuthBroker.hostOwn
        MCPOAuthBroker.resolver = { _, _ in [OpenShellPolicy.IPAddress("203.0.113.9")!] }
        MCPOAuthBroker.hostOwn = { $0 == OpenShellPolicy.IPAddress("203.0.113.9")! }
        defer { MCPOAuthBroker.resolver = priorR; MCPOAuthBroker.hostOwn = priorH }
        let why = await MCPOAuthBroker.checkEndpoint(URL(string: "https://my-server.example/token")!, .init(multiUser: true, egress: .allowAll))
        #expect(why?.contains("this server's own address") == true, "\(why ?? "allowed")")
        MCPOAuthBroker.hostOwn = { _ in false }
        #expect(await MCPOAuthBroker.checkEndpoint(URL(string: "https://my-server.example/token")!, .init(multiUser: true, egress: .allowAll)) == nil)
    }

    /// The caps bound the wait: a resolver that hangs is given up on time
    /// (it ends on its own thread), and its late answer goes to `late`.
    @Test func aHungResolverIsGivenUpOnTime() async throws {
        let late = NIOLockedValueBox<Int?>(nil)
        let start = Date()
        let r = await MCPOAuthBroker.firstOf(timeout: .milliseconds(200), { () async -> Int? in
            await SecureDir.offPool { Thread.sleep(forTimeInterval: 1.0); return 7 }
        }, late: { v in late.withLockedValue { $0 = v } })
        #expect(r == nil && Date().timeIntervalSince(start) < 0.8, "given up at 200 ms")
        for _ in 0..<30 where late.withLockedValue({ $0 }) == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(late.withLockedValue { $0 } == 7, "the late answer handed on")
        #expect(await MCPOAuthBroker.firstOf(timeout: .seconds(5), { () async -> Int? in 3 }) == 3)
    }

    /// A refreshed state is kept (the shared persistRefreshedMCPOAuth): only
    /// that server's, only while the stored state is still the one refreshed.
    @Test func aRefreshedTokenIsSaved() async throws { try await Self.onLoopback {
        let ep = try TokenEndpoint(status: 200, body: #"{"access_token":"NEW","refresh_token":"ROTATED","expires_in":3600}"#)
        defer { ep.stop() }
        let old = MCPOAuthState(clientID: "cid", authorizationEndpoint: "https://x/a", tokenEndpoint: "http://127.0.0.1:\(ep.port)/t",
                                accessToken: "OLD", refreshToken: "SPENT", expiresAt: Date().addingTimeInterval(20))
        var p = Profile(name: "keep", tool: .claude, authMode: .token)
        p.mcpServers = [Self.server("rotating", oauth: old)]
        let kept = NIOLockedValueBox<[(MCPOAuthState, MCPOAuthState, UUID, UUID)]>([])
        let out = await Daemon.populateMCPBearerTokens(p, keep: { n, o, s, pid in kept.withLockedValue { $0.append((n, o, s, pid)) } })
        #expect(out.mcpServers[0].bearerToken == "NEW")
        let k = try #require(kept.withLockedValue { $0 }.first)
        #expect(k.0.refreshToken == "ROTATED" && k.1.refreshToken == "SPENT" && k.2 == p.mcpServers[0].id && k.3 == p.id)
        // And the shared store writes it only over the state it came from.
        var stored = p
        #expect(ProfileStore.mergeRefreshedMCPOAuth(k.0, from: k.1, serverID: k.2, into: &stored))
        #expect(stored.mcpServers[0].oauthState?.refreshToken == "ROTATED")
        var reauthorized = p
        reauthorized.mcpServers[0].oauthState?.refreshToken = "FROM-A-NEW-AUTHORIZATION"
        #expect(!ProfileStore.mergeRefreshedMCPOAuth(k.0, from: k.1, serverID: k.2, into: &reauthorized), "a re-authorization wins")
    } }

    /// DNS rebinding: the request goes to an address that was checked; the
    /// name isn't looked up a second time (a later answer, say 127.0.0.1,
    /// never reaches the connect).
    @Test func theRefreshConnectsOnlyToACheckedAddress() async throws {
        let priorR = MCPOAuthBroker.resolver, priorS = MCPOAuthBroker.pinnedSend, priorH = MCPOAuthBroker.hostOwn
        let lookups = NIOLockedValueBox(0), dialed = NIOLockedValueBox<[String]>([])
        MCPOAuthBroker.resolver = { _, _ in
            let n = lookups.withLockedValue { $0 += 1; return $0 }
            return [OpenShellPolicy.IPAddress(n == 1 ? "93.184.216.34" : "127.0.0.1")!]
        }
        MCPOAuthBroker.hostOwn = { _ in false }
        MCPOAuthBroker.pinnedSend = { req, ip in
            dialed.withLockedValue { $0.append("\(ip)") }
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (r, Data(#"{"access_token":"PINNED"}"#.utf8))
        }
        defer { MCPOAuthBroker.resolver = priorR; MCPOAuthBroker.pinnedSend = priorS; MCPOAuthBroker.hostOwn = priorH }
        let state = MCPOAuthState(clientID: "c", authorizationEndpoint: "https://x/a", tokenEndpoint: "https://idp.example/token",
                                  accessToken: "A", refreshToken: "R")
        let out = try await MCPOAuthBroker.refresh(state: state, policy: .init(multiUser: true, egress: .allowAll))
        #expect(out.accessToken == "PINNED")
        #expect(dialed.withLockedValue { $0 } == ["93.184.216.34"], "the checked answer, not a second one")
        #expect(lookups.withLockedValue { $0 } == 1, "looked up once")
    }

    /// The next address only when the connection itself failed: after any
    /// other error the refresh token may have reached the server, and it
    /// isn't sent again.
    @Test func anotherAddressOnlyWhenNothingWasSent() async throws {
        let priorR = MCPOAuthBroker.resolver, priorS = MCPOAuthBroker.pinnedSend, priorH = MCPOAuthBroker.hostOwn
        defer { MCPOAuthBroker.resolver = priorR; MCPOAuthBroker.pinnedSend = priorS; MCPOAuthBroker.hostOwn = priorH }
        MCPOAuthBroker.resolver = { _, _ in ["93.184.216.34", "93.184.216.35"].map { OpenShellPolicy.IPAddress($0)! } }
        MCPOAuthBroker.hostOwn = { _ in false }
        let state = MCPOAuthState(clientID: "c", authorizationEndpoint: "https://x/a", tokenEndpoint: "https://idp.example/token",
                                  accessToken: "A", refreshToken: "R")
        for connectFails in [true, false] {
            let dialed = NIOLockedValueBox<[String]>([])
            MCPOAuthBroker.pinnedSend = { req, ip in
                let n = dialed.withLockedValue { $0.append("\(ip)"); return $0.count }
                if n == 1 {
                    if connectFails { throw PinnedHTTPS.ConnectFailed(underlying: URLError(.cannotConnectToHost)) }
                    throw URLError(.networkConnectionLost)   // after the request went out
                }
                let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (r, Data(#"{"access_token":"SECOND"}"#.utf8))
            }
            let out = try? await MCPOAuthBroker.refresh(state: state, policy: .init(multiUser: true, egress: .allowAll))
            if connectFails {
                #expect(out?.accessToken == "SECOND" && dialed.withLockedValue { $0 }.count == 2, "a failed connect: the next address")
            } else {
                #expect(out == nil && dialed.withLockedValue { $0 } == ["93.184.216.34"], "a lost connection: not sent again")
            }
        }
    }

    /// The pinned request itself: TCP to the given address, the URL's name
    /// as the TLS server name and what the certificate must match.
    @Test func aPinnedRequestVerifiesTheNameAtTheGivenAddress() async throws {
        let ca = try TestCA("pinned test CA")
        let server = try MTLSServer(host: "127.0.0.1", leaf: try ca.leaf("token.test", dns: ["token.test"], client: false), clientCA: nil,
                                    reply: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 20\r\nConnection: close\r\n\r\n{\"access_token\":\"T\"}")
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "https://token.test:\(server.port)/token")!)
        req.httpMethod = "POST"
        req.httpBody = Data("grant_type=refresh_token".utf8)
        let lo = OpenShellPolicy.IPAddress("127.0.0.1")!
        let (resp, body) = try await PinnedHTTPS.send(req, to: lo, extraRoots: [ca.nio], timeout: 5)
        #expect(resp.statusCode == 200 && String(decoding: body, as: UTF8.self).contains("access_token"))
        #expect(server.lastRequest.value.hasPrefix("POST /token HTTP/1.1"), "\(server.lastRequest.value.prefix(60))")
        // Another name at that address: the certificate doesn't match it.
        var wrong = req
        wrong.url = URL(string: "https://other.test:\(server.port)/token")!
        await #expect(throws: (any Error).self) { _ = try await PinnedHTTPS.send(wrong, to: lo, extraRoots: [ca.nio], timeout: 5) }
        // Nor without the test CA (the system's roots only).
        await #expect(throws: (any Error).self) { _ = try await PinnedHTTPS.send(req, to: lo, timeout: 5) }
    }

    /// One refresh per server and refresh token: concurrent stagings wait for
    /// the one under way, which saves its result once.
    @Test func concurrentStagingsShareOneRefresh() async throws { try await Self.onLoopback {
        // The reply held until the second staging has joined the first's
        // refresh (at most 10 s): the two overlap for sure.
        let flights = MCPOAuthBroker.Flights()
        let ep = try TokenEndpoint(status: 200, body: #"{"access_token":"ONCE","refresh_token":"NEXT","expires_in":3600}"#) {
            for _ in 0..<1000 where flights.joined.withLockedValue({ $0 }) == 0 { usleep(10_000) }
        }
        defer { ep.stop() }
        let old = MCPOAuthState(clientID: "cid", authorizationEndpoint: "https://x/a", tokenEndpoint: "http://127.0.0.1:\(ep.port)/t",
                                accessToken: "OLD", refreshToken: "SINGLE-\(UUID().uuidString)", expiresAt: Date().addingTimeInterval(5))
        var p = Profile(name: "flight", tool: .claude, authMode: .token)
        p.mcpServers = [Self.server("s", oauth: old)]
        let kept = NIOLockedValueBox(0)
        let keep: @Sendable (MCPOAuthState, MCPOAuthState, UUID, UUID) async -> Void = { _, _, _, _ in kept.withLockedValue { $0 += 1 } }
        async let a = Daemon.populateMCPBearerTokens(p, keep: keep, flights: flights)
        async let b = Daemon.populateMCPBearerTokens(p, keep: keep, flights: flights)
        let (ra, rb) = await (a, b)
        #expect(ra.mcpServers[0].bearerToken == "ONCE" && rb.mcpServers[0].bearerToken == "ONCE")
        #expect(ep.requests.withLockedValue { $0.count } == 1, "one request to the token endpoint")
        #expect(kept.withLockedValue { $0 } == 1, "saved once")
        #expect(flights.joined.withLockedValue { $0 } == 1, "the second joined the first")
        #expect(flights.count == 0, "nothing left in flight")
    } }

    /// A staging that loaded its copy before a refresh was saved (and comes
    /// after that refresh is over) uses the saved state: the spent refresh
    /// token isn't sent again.
    @Test func aStaleCopyUsesTheSavedState() async throws { try await Self.onLoopback {
        let ep = try TokenEndpoint(status: 400, body: #"{"error":"invalid_grant"}"#)
        defer { ep.stop() }
        let spent = MCPOAuthState(clientID: "cid", authorizationEndpoint: "https://x/a", tokenEndpoint: "http://127.0.0.1:\(ep.port)/t",
                                  accessToken: "OLD", refreshToken: "SPENT-\(UUID().uuidString)", expiresAt: Date().addingTimeInterval(5))
        var saved = spent
        saved.accessToken = "SAVED"; saved.refreshToken = "LIVE"; saved.expiresAt = Date().addingTimeInterval(3600)
        var p = Profile(name: "stale", tool: .claude, authMode: .token)
        p.mcpServers = [Self.server("s", oauth: spent)]
        let now = saved
        let out = await Daemon.populateMCPBearerTokens(p, keep: { _, _, _, _ in }, stored: { _, _ in now })
        #expect(out.mcpServers[0].bearerToken == "SAVED" && out.mcpServers[0].oauthState?.refreshToken == "LIVE")
        #expect(ep.requests.withLockedValue { $0 }.isEmpty, "no refresh with the spent token")
    } }

    /// A clone shares its source's servers and their state: both stagings
    /// share one refresh, and each workspace keeps its result.
    @Test func aCloneKeepsTheSharedRefresh() async throws { try await Self.onLoopback {
        let flights = MCPOAuthBroker.Flights()
        let ep = try TokenEndpoint(status: 200, body: #"{"access_token":"BOTH","refresh_token":"NEXT","expires_in":3600}"#) {
            for _ in 0..<1000 where flights.joined.withLockedValue({ $0 }) == 0 { usleep(10_000) }
        }
        defer { ep.stop() }
        let old = MCPOAuthState(clientID: "cid", authorizationEndpoint: "https://x/a", tokenEndpoint: "http://127.0.0.1:\(ep.port)/t",
                                accessToken: "OLD", refreshToken: "CLONED-\(UUID().uuidString)", expiresAt: Date().addingTimeInterval(5))
        var a = Profile(name: "source", tool: .claude, authMode: .token)
        a.mcpServers = [Self.server("s", oauth: old)]
        var b = a
        b.id = UUID(); b.name = "clone"
        let kept = NIOLockedValueBox<[UUID]>([])
        let keep: @Sendable (MCPOAuthState, MCPOAuthState, UUID, UUID) async -> Void = { _, _, _, pid in kept.withLockedValue { $0.append(pid) } }
        async let ra = Daemon.populateMCPBearerTokens(a, keep: keep, flights: flights)
        async let rb = Daemon.populateMCPBearerTokens(b, keep: keep, flights: flights)
        let (oa, ob) = await (ra, rb)
        #expect(oa.mcpServers[0].bearerToken == "BOTH" && ob.mcpServers[0].bearerToken == "BOTH")
        #expect(ep.requests.withLockedValue { $0.count } == 1, "one refresh")
        #expect(Set(kept.withLockedValue { $0 }) == [a.id, b.id] && kept.withLockedValue { $0 }.count == 2, "kept by each workspace once")
    } }

    /// The flight saves its result for every workspace that joined it, one
    /// that gave up waiting too, and before it leaves the table.
    @Test func theFlightSavesForEveryoneWhoJoined() async throws {
        let flights = MCPOAuthBroker.Flights()
        let gate = NIOLockedValueBox(false)
        let saved = NIOLockedValueBox<[UUID: String]>([:])
        let lead = UUID(), clone = UUID()
        func keep(_ pid: UUID) -> MCPOAuthBroker.Flights.Keep {
            { state in
                #expect(flights.count == 1, "saved while the flight is still in the table")
                saved.withLockedValue { $0[pid] = state.accessToken }
            }
        }
        let work: @Sendable () async -> MCPOAuthBroker.RefreshOutcome = {
            while !gate.withLockedValue({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
            return .refreshed(MCPOAuthState(clientID: "c", authorizationEndpoint: "https://x/a", tokenEndpoint: "https://x/t", accessToken: "FRESH"))
        }
        let t = flights.flight("k", profileID: lead, keep: keep(lead), work)
        // The clone joins, then gives up on the result (it never awaits it).
        _ = flights.flight("k", profileID: clone, keep: keep(clone)) { Issue.record("a second refresh"); return .failed }
        gate.withLockedValue { $0 = true }
        if case .refreshed = await t.value {} else { Issue.record("no refresh") }
        #expect(saved.withLockedValue { $0 } == [lead: "FRESH", clone: "FRESH"], "both saved, once each")
        #expect(flights.count == 0 && flights.joined.withLockedValue { $0 } == 1)
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
