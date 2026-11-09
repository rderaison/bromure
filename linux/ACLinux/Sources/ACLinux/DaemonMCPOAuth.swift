import Foundation
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

    /// Resolution off the cooperative pool, given up after `timeout`.
    nonisolated(unsafe) static var resolver: @Sendable (String, Int) -> [OpenShellPolicy.IPAddress] = { MitmProxy.resolve($0, port: $1) }

    // @port-skip linux-only: a shared server's check on a user-supplied endpoint
    static func checkEndpoint(_ url: URL, _ policy: EndpointPolicy, timeout: Duration = .seconds(5)) async -> String? {
        guard policy.multiUser else { return nil }
        guard url.scheme?.lowercased() == "https" else { return "the token endpoint isn't https" }
        guard let host = url.host, !host.isEmpty else { return "the token endpoint has no host" }
        let port = url.port ?? 443
        let resolve = resolver
        let ips: [OpenShellPolicy.IPAddress] = await withTaskGroup(of: [OpenShellPolicy.IPAddress]?.self) { g in
            g.addTask { await SecureDir.offPool { resolve(host, port) } }
            g.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first ?? []
        }
        guard !ips.isEmpty else { return "the token endpoint's host doesn't resolve (or took over \(timeout))" }
        for ip in ips {
            if OpenShellPolicy.isAlwaysBlocked(ip) || MitmProxy.v4(ip).map({ OpenShellPolicy.isAlwaysBlocked(.v4($0)) }) == true {
                return "the token endpoint resolves to a loopback, link-local or unspecified address (\(ip))"
            }
        }
        for ip in ips where OpenShellPolicy.isInternal(ip) {
            let v4: UInt32? = { if case .v4(let v) = ip { return v } else { return MitmProxy.v4(ip) } }()
            if policy.egress.verdict(ip: v4, hostnames: [host], proto: .tcp, port: UInt16(clamping: port)) == .deny
                || MitmProxy.openShellDenial(policy.egress.openShell, host: host, port: port, resolved: [ip],
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
    // @port ACAppDelegate.populateMCPBearerTokens(in: inoutProfile) h=049de67ef199bfa8 @4bd8405e
    static func populateMCPBearerTokens(_ profile: Profile, multiUser: Bool = false) async -> Profile {
        var profile = profile
        let policy = MCPOAuthBroker.EndpointPolicy(multiUser: multiUser, egress: profile.resolvedEgressPolicy)
        for i in profile.mcpServers.indices {
            guard profile.mcpServers[i].enabled,
                  profile.mcpServers[i].transport == .http,
                  var oauth = profile.mcpServers[i].oauthState else { continue }
            guard !oauth.accessToken.isEmpty else { continue }
            if let exp = oauth.expiresAt, exp.timeIntervalSinceNow < 60, oauth.refreshToken != nil {
                let current = oauth, name = profile.mcpServers[i].name, ws = profile.name
                oauth = await withTaskGroup(of: MCPOAuthState?.self) { g in
                    g.addTask {
                        do { return try await MCPOAuthBroker.refresh(state: current, policy: policy) }
                        catch {
                            // Said, never silent (no token in the message).
                            FileHandle.standardError.write(Data(
                                "bromure-ac daemon: '\(ws)': MCP server '\(name)': token refresh failed, the old token kept: \(error)\n".utf8))
                            return nil
                        }
                    }
                    g.addTask {
                        try? await Task.sleep(for: .seconds(10))
                        if !Task.isCancelled {
                            FileHandle.standardError.write(Data(
                                "bromure-ac daemon: '\(ws)': MCP server '\(name)': token refresh took over 10 s, the old token kept\n".utf8))
                        }
                        return nil
                    }
                    let first = await g.next() ?? nil
                    g.cancelAll()
                    return first ?? current
                }
                profile.mcpServers[i].oauthState = oauth
            }
            profile.mcpServers[i].bearerToken = oauth.accessToken
        }
        return profile
    }
}
