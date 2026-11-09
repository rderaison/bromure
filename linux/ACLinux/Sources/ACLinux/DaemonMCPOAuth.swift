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
    nonisolated(unsafe) static var endpointCheck: @Sendable (URL, EndpointPolicy) async -> EndpointCheck = { url, policy in
        await endpointAddresses(url, policy)
    }

    enum RefreshOutcome: Sendable { case refreshed(MCPOAuthState), failed }

    /// The refreshes under way, one per server and refresh token.
    // @port-skip linux-only: single-flight refreshes (macOS refreshes in its one launch path)
    final class Flights: @unchecked Sendable {
        /// How a workspace that joined saves the result.
        typealias Keep = @Sendable (MCPOAuthState) async -> Void
        private struct Entry { let task: Task<RefreshOutcome, Never>; var keeps: [UUID: Keep] }
        private let running = NIOLockedValueBox<[String: Entry]>([:])
        /// Callers that joined one under way (tests).
        let joined = NIOLockedValueBox(0)
        /// The refresh under way for `key`, or a new one running `work`.
        /// The flight itself saves the result for every workspace that
        /// joined (`keep`: how `profileID` does; a clone shares the server
        /// and its state), each once, whether or not it still waits -- and
        /// before it leaves the table, so a staging after it reads the
        /// saved state.
        // @port-skip linux-only: see Flights
        func flight(_ key: String, profileID: UUID, keep: Keep?,
                    _ work: @escaping @Sendable () async -> RefreshOutcome) -> Task<RefreshOutcome, Never> {
            running.withLockedValue { all in
                if var e = all[key] {
                    joined.withLockedValue { $0 += 1 }
                    if let keep, e.keeps[profileID] == nil { e.keeps[profileID] = keep; all[key] = e }
                    return e.task
                }
                let t = Task { [running] in
                    let r = await work()
                    var saved = Set<UUID>()
                    while true {
                        // Those that joined and aren't saved yet; none left:
                        // the flight is over.
                        let pending: [UUID: Keep] = running.withLockedValue { all in
                            guard case .refreshed = r else { all.removeValue(forKey: key); return [:] }
                            let ks = (all[key]?.keeps ?? [:]).filter { !saved.contains($0.key) }
                            if ks.isEmpty { all.removeValue(forKey: key) }
                            return ks
                        }
                        guard !pending.isEmpty, case .refreshed(let state) = r else { break }
                        for (pid, k) in pending { await k(state); saved.insert(pid) }
                    }
                    return r
                }
                all[key] = Entry(task: t, keeps: keep.map { [profileID: $0] } ?? [:])
                return t
            }
        }
        // @port-skip linux-only: see Flights
        var count: Int { running.withLockedValue { $0.count } }
    }
    static let flights = Flights()

    /// What a refresh may connect to.
    enum EndpointCheck: Sendable, Equatable {
        /// A single-user server: as macOS, the name as URLSession looks it up.
        case unchecked
        /// Only these addresses, checked (the name isn't looked up again).
        case pinned([OpenShellPolicy.IPAddress])
        case refused(String)
    }

    /// How a pinned request is sent (tests answer it themselves).
    nonisolated(unsafe) static var pinnedSend: @Sendable (URLRequest, OpenShellPolicy.IPAddress) async throws -> (HTTPURLResponse, Data) = { req, ip in
        try await PinnedHTTPS.send(req, to: ip)
    }

    /// Why the daemon won't POST to `url`, or nil (endpointAddresses' verdict).
    // @port-skip linux-only: a shared server's check on a user-supplied endpoint
    static func checkEndpoint(_ url: URL, _ policy: EndpointPolicy, timeout: Duration = .seconds(5)) async -> String? {
        if case .refused(let why) = await endpointAddresses(url, policy, timeout: timeout) { return why }
        return nil
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
    static func endpointAddresses(_ url: URL, _ policy: EndpointPolicy, timeout: Duration = .seconds(5)) async -> EndpointCheck {
        guard policy.multiUser else { return .unchecked }
        guard url.scheme?.lowercased() == "https" else { return .refused("the token endpoint isn't https") }
        guard let host = url.host, !host.isEmpty else { return .refused("the token endpoint has no host") }
        let port = url.port ?? 443
        let resolve = resolver
        let ips = await firstOf(timeout: timeout, { await SecureDir.offPool { resolve(host, port) } }) ?? []
        guard !ips.isEmpty else { return .refused("the token endpoint's host doesn't resolve (or took over \(timeout))") }
        for ip in ips {
            if OpenShellPolicy.isAlwaysBlocked(ip) || MitmProxy.v4(ip).map({ OpenShellPolicy.isAlwaysBlocked(.v4($0)) }) == true {
                return .refused("the token endpoint resolves to a loopback, link-local or unspecified address (\(ip))")
            }
        }
        // What the MITM refuses every workspace on a multi-user server, public
        // answers too: this server's own addresses (another user's service may
        // listen there) and every account's LAN pool.
        if let why = MitmProxy.destinationDenial(host: host, resolved: ips, hostAddresses: true, hostOwn: hostOwn) {
            return .refused("the token endpoint: \(why)")
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
                return .refused("the token endpoint resolves to a private address (\(ip)) the workspace's egress policy doesn't allow")
            }
        }
        return .pinned(ips)
    }

    // @port MCPOAuthBroker.static refresh(state: MCPOAuthState) h=4a873148d744f90e @55adf953
    static func refresh(state: MCPOAuthState, policy: EndpointPolicy = .singleUser) async throws -> MCPOAuthState {
        guard let refreshToken = state.refreshToken,
              let tokenURL = URL(string: state.tokenEndpoint) else {
            throw BrokerError.refreshFailed("No refresh token or invalid token endpoint")
        }
        let check = await endpointCheck(tokenURL, policy)
        if case .refused(let why) = check { throw BrokerError.refreshFailed(why) }
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
        let data: Data, response: URLResponse
        switch check {
        case .pinned(let ips):
            // Only to an address that was checked; the next one only when the
            // connection to this one failed (nothing sent: a refresh token
            // that may have reached the server isn't sent again).
            var last: Error = BrokerError.refreshFailed("no address to connect to")
            var got: (HTTPURLResponse, Data)?
            for ip in ips {
                do { got = try await pinnedSend(request, ip); break }
                catch let e as PinnedHTTPS.ConnectFailed { last = e }
            }
            guard let got else { throw last }
            (response, data) = got
        default:
            (data, response) = try await session.data(for: request)
        }
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
    /// `stored`: the saved workspace's state for a server now (profile id,
    /// server id), read again before a refresh: one saved since `profile`
    /// was loaded is used instead (its refresh token is the live one).
    // @port ACAppDelegate.populateMCPBearerTokens(in: inoutProfile) h=11cb4a0e133dab98 @4237c02e
    static func populateMCPBearerTokens(_ profile: Profile, multiUser: Bool = false,
                                        keep: (@Sendable (MCPOAuthState, MCPOAuthState, UUID, UUID) async -> Void)? = nil,
                                        stored: (@Sendable (UUID, UUID) async -> MCPOAuthState?)? = nil,
                                        flights: MCPOAuthBroker.Flights = MCPOAuthBroker.flights) async -> Profile {
        var profile = profile
        let policy = MCPOAuthBroker.EndpointPolicy(multiUser: multiUser, egress: profile.resolvedEgressPolicy)
        for i in profile.mcpServers.indices {
            guard profile.mcpServers[i].enabled,
                  profile.mcpServers[i].transport == .http,
                  let oauth = profile.mcpServers[i].oauthState else { continue }
            guard !oauth.accessToken.isEmpty else { continue }
            var use = oauth
            func due(_ s: MCPOAuthState) -> Bool { (s.expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false) && s.refreshToken != nil }
            // Refreshed and saved since this copy was loaded: that one.
            if due(oauth), let stored, let now = await stored(profile.id, profile.mcpServers[i].id), now != oauth, !now.accessToken.isEmpty {
                use = now
                profile.mcpServers[i].oauthState = now
            }
            if due(use), let refreshToken = use.refreshToken {
                let old = use, name = profile.mcpServers[i].name, ws = profile.name
                let serverID = profile.mcpServers[i].id, profileID = profile.id
                // One refresh per server and refresh token: a launch, a live
                // push or a relaunch meanwhile waits for the one under way
                // (spending the token twice gets a rotating server's grant
                // revoked). The flight saves the result for every workspace
                // that joined (macOS: persistRefreshedMCPOAuth), even after
                // this wait: it spent the stored token.
                let save: MCPOAuthBroker.Flights.Keep? = keep.map { keep in { await keep($0, old, serverID, profileID) } }
                let flight = flights.flight("\(serverID)|\(refreshToken)", profileID: profileID, keep: save) {
                    do {
                        let refreshed = try await MCPOAuthBroker.refresh(state: old, policy: policy)
                        return .refreshed(refreshed)
                    } catch {
                        // Said, never silent (no token in the message).
                        FileHandle.standardError.write(Data(
                            "bromure-ac daemon: '\(ws)': MCP server '\(name)': token refresh failed, the old token kept: \(error)\n".utf8))
                        return .failed
                    }
                }
                switch await MCPOAuthBroker.firstOf(timeout: .seconds(10), { await flight.value }) {
                case .refreshed(let refreshed)?:
                    use = refreshed
                    profile.mcpServers[i].oauthState = refreshed
                case .failed?:
                    break
                case nil:
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
        do { try ProfileWrites.locked { try store.persistRefreshedMCPOAuth(refreshed, from: old, serverID: serverID, profileID: profileID) } }
        catch { FileHandle.standardError.write(Data("bromure-ac daemon: MCP OAuth: couldn't save the refreshed token: \(error)\n".utf8)) }
    }
}
