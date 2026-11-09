import Foundation
import NIOConcurrencyHelpers
import SandboxEngine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A remote MCP server's OAuth tokens on the server: refreshed when they
/// are about to expire and handed to the guest as its bearer token where
/// macOS does it (the launch's staging, the live credential push), as macOS's
/// populateMCPBearerTokens. The interactive authorization (macOS's
/// MCPOAuthBroker.authorizeServer, a browser on the host) isn't here.
// @port-skip linux-only: the namespace (macOS's MCPOAuthBroker also authorizes, through a local browser)
enum MCPOAuthBroker {
    enum BrokerError: Error, CustomStringConvertible {
        case refreshFailed(String)
        // partial: the refresh failure only (no authorization flow here)
        // @port MCPOAuthBroker.BrokerError.var errorDescription h=e73f51f646a3aca2 @55adf953
        var description: String { switch self { case .refreshFailed(let m): return "Token refresh failed: \(m)" } }
    }

    /// The transport: no redirect is followed (the token endpoint came from
    /// a client's PUT), and 10 s at most.
    nonisolated(unsafe) static var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    // @port-skip linux-only: see session
    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        // @port-skip linux-only: see session
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Whose endpoint rules a refresh follows.
    // @port-skip linux-only: a shared server's check on a user-supplied endpoint
    struct EndpointPolicy: Sendable {
        /// A multi-user server: the endpoint is checked (single-user: none, as macOS).
        var multiUser: Bool
        /// The workspace's own egress policy, which decides a private address.
        var egress: EgressPolicy
        static let singleUser = EndpointPolicy(multiUser: false, egress: .allowAll)
    }

    /// Why the daemon won't POST to `url`, or nil. A single-user server
    /// checks nothing (as macOS). On a multi-user one the token endpoint is
    /// the user's (their PUT) and the daemon's request goes out past the
    /// MITM: https only; never loopback, link-local (the cloud metadata
    /// address too) or unspecified; a private, CGNAT or ULA address only
    /// when the workspace's own egress policy allows that destination (an
    /// in-house identity provider). Tests on loopback swap it.
    nonisolated(unsafe) static var endpointRefusal: @Sendable (URL, EndpointPolicy) async -> String? = { url, policy in
        await checkEndpoint(url, policy)
    }

    /// `work`'s result, or nil once `timeout` passes first: one continuation
    /// resumed by whichever ends first (a resolver thread or a request that
    /// ignores cancellation goes on alone, its late result to `late`).
    // @port-skip linux-only: a bounded wait (macOS: a semaphore with a timeout)
    static func firstOf<T: Sendable>(timeout: Duration, _ work: @escaping @Sendable () async -> T?,
                                      late: (@Sendable (T) -> Void)? = nil) async -> T? {
        let done = NIOLockedValueBox(false)
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            Task.detached {
                let r = await work()
                let first = done.withLockedValue { d -> Bool in defer { d = true }; return !d }
                if first { c.resume(returning: r) } else if let r { late?(r) }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                let first = done.withLockedValue { d -> Bool in defer { d = true }; return !d }
                if first { c.resume(returning: nil) }
            }
        }
    }

    /// This server's own addresses and LAN pools (tests swap it).
    nonisolated(unsafe) static var hostOwn: @Sendable (OpenShellPolicy.IPAddress) -> Bool = { MitmProxy.isHostOwn($0) }

    /// Resolution off the cooperative pool, given up after `timeout`.
    nonisolated(unsafe) static var resolver: @Sendable (String, Int) -> [OpenShellPolicy.IPAddress] = { MitmProxy.resolve($0, port: $1) }

    // @port-skip linux-only: a shared server's check on a user-supplied endpoint
    static func checkEndpoint(_ url: URL, _ policy: EndpointPolicy, timeout: Duration = .seconds(5)) async -> String? {
        guard policy.multiUser else { return nil }
        guard url.scheme?.lowercased() == "https" else { return "the token endpoint isn't https" }
        guard let host = url.host, !host.isEmpty else { return "the token endpoint has no host" }
        let port = url.port ?? 443
        let resolve = resolver
        let ips = await firstOf(timeout: timeout, { await SecureDir.offPool { resolve(host, port) } }) ?? []
        guard !ips.isEmpty else { return "the token endpoint's host doesn't resolve (or took over \(timeout))" }
        for ip in ips {
            if OpenShellPolicy.isAlwaysBlocked(ip) || MitmProxy.v4(ip).map({ OpenShellPolicy.isAlwaysBlocked(.v4($0)) }) == true {
                return "the token endpoint resolves to a loopback, link-local or unspecified address (\(ip))"
            }
        }
        // What the MITM refuses every workspace on a multi-user server, public
        // answers too: this server's own addresses (another user's service may
        // listen there) and every account's LAN pool.
        if let why = MitmProxy.destinationDenial(host: host, resolved: ips, hostAddresses: true, hostOwn: hostOwn) {
            return "the token endpoint: \(why)"
        }
        // No binary identity here (the daemon's own request): neither check
        // enforces the policy's binaries.
        var egress = policy.egress
        egress.enforceBinaries = false
        for ip in ips where OpenShellPolicy.isInternal(ip) {
            let v4: UInt32? = { if case .v4(let v) = ip { return v } else { return MitmProxy.v4(ip) } }()
            if egress.verdict(ip: v4, hostnames: [host], proto: .tcp, port: UInt16(clamping: port)) == .deny
                || MitmProxy.openShellDenial(egress.openShell, host: host, port: port, resolved: [ip],
                                            identity: nil, enforceBinaries: false) != nil {
                return "the token endpoint resolves to a private address (\(ip)) the workspace's egress policy doesn't allow"
            }
        }
        return nil
    }

    // @port MCPOAuthBroker.static refresh(state: MCPOAuthState) h=4a873148d744f90e @55adf953
    static func refresh(state: MCPOAuthState, policy: EndpointPolicy = .singleUser) async throws -> MCPOAuthState {
        guard let refreshToken = state.refreshToken,
              let tokenURL = URL(string: state.tokenEndpoint) else {
            throw BrokerError.refreshFailed("No refresh token or invalid token endpoint")
        }
        if let why = await endpointRefusal(tokenURL, policy) { throw BrokerError.refreshFailed(why) }
        var body = [
            "grant_type=refresh_token",
            "refresh_token=\(formEncode(refreshToken))",
            "client_id=\(formEncode(state.clientID))",
        ]
        if let secret = state.clientSecret {
            body.append("client_secret=\(formEncode(secret))")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.joined(separator: "&").utf8)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BrokerError.refreshFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw BrokerError.refreshFailed("Missing access_token in response")
        }
        var updated = state
        updated.accessToken = accessToken
        if let rt = json["refresh_token"] as? String {
            updated.refreshToken = rt
        }
        if let exp = json["expires_in"] as? Int {
            updated.expiresAt = Date().addingTimeInterval(TimeInterval(exp))
        }
        return updated
    }

    private static let formSafeCharacters: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    // @port MCPOAuthBroker.static formEncode(_: String) h=c5e780b0cac686c4 @55adf953
    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formSafeCharacters) ?? value
    }
}

extension Daemon {
    /// Each enabled HTTP MCP server's OAuth access token as its bearer token,
    /// refreshed first when it expires within a minute (the stale one kept
    /// when the refresh fails or takes over 10 s). The refreshed state lives
    /// in the staged copy only, as on macOS.
    // @port ACAppDelegate.populateMCPBearerTokens(in: inoutProfile) h=11cb4a0e133dab98 @4237c02e
    static func populateMCPBearerTokens(_ profile: Profile, multiUser: Bool = false,
                                        keep: (@Sendable (MCPOAuthState, MCPOAuthState, UUID, UUID) -> Void)? = nil) async -> Profile {
        var profile = profile
        let policy = MCPOAuthBroker.EndpointPolicy(multiUser: multiUser, egress: profile.resolvedEgressPolicy)
        for i in profile.mcpServers.indices {
            guard profile.mcpServers[i].enabled,
                  profile.mcpServers[i].transport == .http,
                  let oauth = profile.mcpServers[i].oauthState else { continue }
            guard !oauth.accessToken.isEmpty else { continue }
            var use = oauth
            if let exp = oauth.expiresAt, exp.timeIntervalSinceNow < 60, oauth.refreshToken != nil {
                let old = oauth, name = profile.mcpServers[i].name, ws = profile.name
                let serverID = profile.mcpServers[i].id, profileID = profile.id
                // The refreshed state is saved (macOS: persistRefreshedMCPOAuth),
                // even one that comes after this boot stopped waiting: it spent
                // the stored refresh token on a rotating server.
                let refreshed = await MCPOAuthBroker.firstOf(timeout: .seconds(10), { () async -> MCPOAuthState? in
                    do { return try await MCPOAuthBroker.refresh(state: old, policy: policy) }
                    catch {
                        // Said, never silent (no token in the message).
                        FileHandle.standardError.write(Data(
                            "bromure-ac daemon: '\(ws)': MCP server '\(name)': token refresh failed, the old token kept: \(error)\n".utf8))
                        return nil
                    }
                }, late: { late in keep?(late, old, serverID, profileID) })
                if let refreshed {
                    use = refreshed
                    profile.mcpServers[i].oauthState = refreshed
                    keep?(refreshed, old, serverID, profileID)
                } else {
                    FileHandle.standardError.write(Data(
                        "bromure-ac daemon: '\(ws)': MCP server '\(name)': no refreshed token within 10 s, the old one kept\n".utf8))
                }
            }
            profile.mcpServers[i].bearerToken = use.accessToken
        }
        return profile
    }

    /// A refreshed MCP OAuth state kept in the saved workspace: only that
    /// server's, only while the stored state is still the one refreshed from
    /// (the shared ProfileStore.persistRefreshedMCPOAuth). The daemon keeps
    /// no in-memory copy a later save writes back whole.
    // partial: the stored workspace only (no app-side copies on a server)
    // @port ACAppDelegate.keepRefreshedMCPOAuth(_: MCPOAuthState, from: MCPOAuthState, serverID: UUID, profileID: Profile.ID) h=49a7019d29c33622 @4237c02e
    static func keepRefreshedMCPOAuth(_ refreshed: MCPOAuthState, from old: MCPOAuthState, serverID: UUID,
                                      profileID: UUID, store: ProfileStore) {
        do { try store.persistRefreshedMCPOAuth(refreshed, from: old, serverID: serverID, profileID: profileID) }
        catch { FileHandle.standardError.write(Data("bromure-ac daemon: MCP OAuth: couldn't save the refreshed token: \(error)\n".utf8)) }
    }
}
