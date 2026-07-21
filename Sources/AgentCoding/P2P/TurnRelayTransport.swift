import Foundation

// MARK: - TURN relay (Rung 4 — the metered fallback)

/// The relay leg of the candidate ladder. When neither peer can offer a
/// reachable direct candidate (symmetric×symmetric NAT, UDP-blocked corporate
/// networks), the session relays through coturn (REMOTE_P2P_PLAN.md §"Rung 4 —
/// TURN relay (fallback)"). This holds the credential-minting half — which is
/// real and exercised — and a documented seam for the RFC 6062 TCP-allocation
/// data path, which the plan says to ADOPT (libjuice / pion) rather than
/// hand-roll (§"Build vs. adopt": "This is the Tailscale disco+DERP /
/// WebRTC-data-channel problem; don't re-derive it").
///
/// Status: credential fetch works against the infra
/// `POST /v1/connections/:id/turn-credentials`; the data path is intentionally
/// not hand-implemented here. Until the adopted ICE/TURN helper lands,
/// `allocateRelayCandidate` returns nil, so `P2PDirectDialer` is the whole
/// working transport and dual-NAT sessions fail honestly rather than via a
/// half-correct STUN/TURN stack that can't be verified without a live two-NAT
/// rig + coturn.
enum TurnRelayTransport {
    /// Fetch short-lived REST credentials for this grant. These outlive the 45 s
    /// grant (they bound the relayed session, not the rendez-vous); the username
    /// is `<unix-expiry>:<connectionId>` and stops working at its timestamp.
    static func credentials(client: ControlPlaneClient, bearer: String,
                            connectionId: String) async -> TurnCredentials? {
        try? await client.turnCredentials(bearer: bearer, connectionId: connectionId)
    }

    /// The LISTENER allocates a TURN TCP relay (RFC 6062) and advertises the
    /// relayed transport address as a `relay` candidate; the dialer then makes an
    /// ordinary TCP connection to it (§"dialer's ssh connects to the public
    /// endpoint with zero new transport code"), coturn splices the two legs, and
    /// the listener binds its half into `127.0.0.1:2222`.
    ///
    /// Not implemented in this build — see the type doc. Returns nil ⇒ no relay
    /// candidate is advertised, so a session that can't go direct fails cleanly.
    static func allocateRelayCandidate(creds: TurnCredentials,
                                       permitPeerIP: String?) -> P2PCandidate? {
        // TODO(p2p-relay): Allocate(requested-transport=TCP) → CreatePermission
        // for `permitPeerIP` → on ConnectionAttempt, ConnectionBind on a second
        // TCP leg, then splice that leg into 127.0.0.1:2222. Deferred to the
        // adopted ICE/TURN helper (libjuice/pion) per the plan's Phase 2.
        _ = creds
        _ = permitPeerIP
        return nil
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
