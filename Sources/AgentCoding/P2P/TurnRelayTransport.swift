import Foundation

// MARK: - TURN relay (Rung 4 — the metered fallback)

/// The relay leg of the candidate ladder. When neither peer can offer a
/// reachable direct candidate (symmetric×symmetric NAT, UDP-blocked corporate
/// networks), the session relays through coturn (REMOTE_P2P_PLAN.md §"Rung 4 —
/// TURN relay (fallback)"): the LISTENER allocates a TCP relay (RFC 6062, see
/// `TurnRelayListener`) and advertises the relayed transport address as a
/// `relay` candidate; the dialer then makes an ordinary TCP connection to it
/// (§"dialer's ssh connects to the public endpoint with zero new transport
/// code"), coturn splices the two legs, and the listener binds its half into
/// the local sshd. SSH stays end-to-end — the relay moves opaque bytes.
///
/// This enum holds the small pure pieces: credential fetch
/// (`POST /v1/connections/:id/turn-credentials`) and URL parsing/selection,
/// unit-testable without a relay.
enum TurnRelayTransport {
    /// Fetch short-lived REST credentials for this grant. These outlive the 45 s
    /// grant (they bound the relayed session, not the rendez-vous); the username
    /// is `<unix-expiry>:<connectionId>` and stops working at its timestamp.
    static func credentials(client: ControlPlaneClient, bearer: String,
                            connectionId: String) async -> TurnCredentials? {
        try? await client.turnCredentials(bearer: bearer, connectionId: connectionId)
    }

    /// Pick the endpoint for the TURN-TCP client leg: the first
    /// `turn:…?transport=tcp` URL (RFC 6062 requires a TCP client leg). `turns:`
    /// (TLS, 5349) is not spoken yet — plain 3478 carries only the TURN
    /// envelope; the payload is SSH, encrypted end-to-end regardless.
    static func preferredTCPEndpoint(_ urls: [String]) -> (host: String, port: Int, transport: String?)? {
        for url in urls where url.hasPrefix("turn:") {
            if let parsed = parseHostPort(fromURL: url), parsed.transport == "tcp" {
                return parsed
            }
        }
        return nil
    }

    /// The STUN endpoint (Binding needs no credentials): the `stun:` URL if
    /// present, else any TURN host — coturn answers Binding on the same port.
    static func stunEndpoint(_ urls: [String]) -> (host: String, port: Int, transport: String?)? {
        for url in urls where url.hasPrefix("stun:") {
            if let parsed = parseHostPort(fromURL: url) { return parsed }
        }
        return preferredTCPEndpoint(urls)
    }

    /// Parse the STUN/TURN host:port out of a coturn `urls` entry
    /// (`turn:host:3478?transport=tcp`) — small, pure, and unit-testable ahead
    /// of the data path so the credential wiring is verified end to end.
    static func parseHostPort(fromURL url: String) -> (host: String, port: Int, transport: String?)? {
        // Strip the scheme (stun:/turn:/turns:).
        guard let schemeEnd = url.firstIndex(of: ":") else { return nil }
        var rest = String(url[url.index(after: schemeEnd)...])
        var transport: String?
        if let q = rest.firstIndex(of: "?") {
            let query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "transport" { transport = String(kv[1]) }
            }
        }
        // rest is host[:port]; a bare host defaults to 3478.
        if let colon = rest.lastIndex(of: ":"),
           let port = Int(rest[rest.index(after: colon)...]) {
            return (String(rest[..<colon]), port, transport)
        }
        return (rest, 3478, transport)
    }
}
