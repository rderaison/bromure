import Foundation

// MARK: - Signaling payloads (opaque to the control plane)

/// The bromure-defined body carried inside a signaling frame's `payload`
/// object. The server relays it verbatim between the two paired peers and never
/// inspects it (REMOTE_P2P_PLAN.md §"The server never sees SSH bytes"), so its
/// shape is entirely ours.
///
/// - `offer` / `answer`: a bulk candidate list a peer is advertising up front.
/// - `candidate`: one trickled candidate discovered after the initial exchange.
///
/// Kept small on purpose: the whole frame (connectionId + seq + kind + this)
/// must stay under the gateway's 4096-byte cap, so trickle uses single
/// candidates rather than re-sending the whole list.
struct P2PSignalPayload: Codable, Equatable {
    var v: Int = 1
    /// Bulk set (offer/answer).
    var candidates: [P2PCandidate]?
    /// Single trickled candidate.
    var candidate: P2PCandidate?
    /// Free-form hint, e.g. "end-of-candidates" or "no-relay".
    var note: String?

    init(v: Int = 1, candidates: [P2PCandidate]? = nil,
         candidate: P2PCandidate? = nil, note: String? = nil) {
        self.v = v
        self.candidates = candidates
        self.candidate = candidate
        self.note = note
    }

    /// All candidates this payload carries, bulk + single, in one list.
    var allCandidates: [P2PCandidate] {
        (candidates ?? []) + (candidate.map { [$0] } ?? [])
    }
}

/// The three signaling verbs. Matches the gateway's `kind` enum exactly
/// (device-channel.js): a frame with any other kind is rejected `bad_frame`.
enum SignalKind: String, Codable {
    case offer
    case answer
    case candidate
}

// MARK: - Frame wire model

/// A client → server signaling frame: `{connectionId, seq, kind, payload}`.
/// `seq` is strictly increasing per sender; the gateway enforces it and drops
/// replays/rewinds as `stale_seq`. The caller (P2PSession) owns the counter.
struct OutgoingSignalFrame: Encodable {
    let connectionId: String
    let seq: Int
    let kind: SignalKind
    let payload: P2PSignalPayload

    /// JSON bytes for the WebSocket `.string` message. Throws if the encoded
    /// frame would exceed the gateway's `MAX_FRAME_BYTES` (4096) — the caller
    /// must split an oversized candidate list into trickle frames instead.
    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 4096 else {
            throw P2PSignalError.frameTooLarge(data.count)
        }
        return data
    }
}

/// A server → client frame. The gateway tags every message with `type`; we
/// decode leniently (unknown types are ignored, not fatal) so a forward-
/// compatible server can add message kinds without breaking old clients.
enum IncomingServerFrame {
    /// A signal relayed from the peer. `from` is the peer's session-scoped
    /// signalId (durable device ids never appear on the wire in signal frames).
    case signal(connectionId: String, seq: Int, kind: SignalKind,
                from: String, payload: P2PSignalPayload)
    /// The listener is told a client was granted a connection to it.
    case connection(ConnectionGrant)
    /// A protocol/policy rejection: bad_frame, rate_limited, unknown_connection,
    /// connection_closed, stale_seq, frame_cap, candidate_cap, peer_offline.
    case error(code: String, connectionId: String?)
    /// A `type` we don't recognise — carried through for logging, never fatal.
    case unknown(type: String)

    /// Decode one WebSocket text frame. Returns nil only when the bytes aren't
    /// a JSON object at all.
    static func decode(_ data: Data) -> IncomingServerFrame? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "signal":
            guard let connId = obj["connectionId"] as? String,
                  let seq = obj["seq"] as? Int,
                  let kindRaw = obj["kind"] as? String,
                  let kind = SignalKind(rawValue: kindRaw),
                  let from = obj["from"] as? String else { return .unknown(type: type) }
            let payload = decodePayload(obj["payload"])
            return .signal(connectionId: connId, seq: seq, kind: kind, from: from, payload: payload)
        case "connection":
            guard let connObj = obj["connection"],
                  let sub = try? JSONSerialization.data(withJSONObject: connObj),
                  let grant = try? JSONDecoder().decode(ConnectionGrant.self, from: sub)
            else { return .unknown(type: type) }
            return .connection(grant)
        case "error":
            return .error(code: obj["error"] as? String ?? "unknown",
                          connectionId: obj["connectionId"] as? String)
        default:
            return .unknown(type: type)
        }
    }

    private static func decodePayload(_ raw: Any?) -> P2PSignalPayload {
        guard let raw,
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let payload = try? JSONDecoder().decode(P2PSignalPayload.self, from: data)
        else { return P2PSignalPayload() }
        return payload
    }
}

enum P2PSignalError: Error, Equatable {
    case frameTooLarge(Int)
}
