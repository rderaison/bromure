import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A remote MCP server's OAuth tokens on the server: refreshed when they
/// are about to expire and handed to the guest as its bearer token at each
/// staging (launch, live refresh, reboot), as macOS's
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

    /// The transport (tests answer from a local server).
    nonisolated(unsafe) static var session: URLSession = .shared

    // @port MCPOAuthBroker.static refresh(state: MCPOAuthState) h=4a873148d744f90e @55adf953
    static func refresh(state: MCPOAuthState) async throws -> MCPOAuthState {
        guard let refreshToken = state.refreshToken,
              let tokenURL = URL(string: state.tokenEndpoint) else {
            throw BrokerError.refreshFailed("No refresh token or invalid token endpoint")
        }
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
    static func populateMCPBearerTokens(_ profile: Profile) async -> Profile {
        var profile = profile
        for i in profile.mcpServers.indices {
            guard profile.mcpServers[i].enabled,
                  profile.mcpServers[i].transport == .http,
                  var oauth = profile.mcpServers[i].oauthState else { continue }
            guard !oauth.accessToken.isEmpty else { continue }
            if let exp = oauth.expiresAt, exp.timeIntervalSinceNow < 60, oauth.refreshToken != nil {
                let current = oauth
                oauth = await withTaskGroup(of: MCPOAuthState?.self) { g in
                    g.addTask { try? await MCPOAuthBroker.refresh(state: current) }
                    g.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
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
