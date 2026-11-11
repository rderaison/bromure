import Foundation

// MARK: - Sign-in capture at the proxy
//
// A workspace's own CLI runs its login (the browser opens on this Mac as for
// any guest URL, the localhost callback is forwarded back in), and the one
// request that matters — the exchange of the authorization or device code
// for tokens — is answered by the host instead of the provider: the real
// credential goes to the host's subscription store, and the guest hears what
// the host decides. No throwaway machine, and the machine never holds a
// real token.

/// One armed capture: which workspace, which token endpoint, and what to do
/// with the provider's reply.
struct SignInCapture: Sendable {
    let profileID: UUID
    /// Token endpoints, by host, that count as this sign-in's exchange.
    let hosts: Set<String>
    let pathPrefix: String
    /// The upstream's reply (status, body) → what the guest gets instead, as
    /// a complete HTTP/1.1 response — or nil to pass the real reply through
    /// (a device-code poll still pending, an error).
    let handle: @Sendable (Int, Data) async -> Data?
    /// The sign-in simulator's canned provider reply (a complete HTTP
    /// response): the proxy answers the exchange with it instead of
    /// contacting the provider. nil for every real sign-in.
    var simulatedReply: Data? = nil
    /// A sign-in that ended (finished, refused, timed out): its CLI may
    /// still exchange a code the user completes late in the browser, and
    /// that exchange would bring real tokens to the guest with nothing left
    /// to keep them. A spent capture answers it with `notKeptReply` without
    /// contacting the provider (the code is never redeemed), until
    /// `expiresAt`.
    var spent = false
    var expiresAt: Date? = nil

    /// How long an ended sign-in still turns its exchange away: past the
    /// sign-in's own 5 minutes plus a device code's usual lifetime.
    static let spentFor: TimeInterval = 30 * 60

    /// Other ended sign-ins of this workspace still turned away (another
    /// agent's, or this one's before a retry): kept apart from the live
    /// capture so arming one never lifts them (SignInCaptureRegistry).
    var spentEndpoints: [SpentEndpoint] = []

    /// A token exchange no host keeps: an ended sign-in's (this capture
    /// spent, or any of `spentEndpoints`). Answered with `notKeptReply`.
    func refusesExchange(host: String, method: String, path: String, body: Data) -> Bool {
        (spent && matches(host: host, method: method, path: path, body: body))
            || spentEndpoints.contains { $0.capture.matches(host: host, method: method, path: path, body: body) }
    }

    /// What the guest hears for a token exchange the host doesn't keep.
    static var notKeptReply: Data {
        response(status: 400, reason: "Bad Request", json: [
            "error": "bromure_not_kept",
            "error_description": "Bromure didn't keep this sign-in. Start it again from the session's sign-in card.",
        ])
    }

    /// The errors a device-code token poll answers while it's still pending
    /// or once it's over (RFC 8628 3.5). A lenient provider may send them
    /// with a 200.
    static let pollErrors: Set<String> = ["authorization_pending", "slow_down", "expired_token", "access_denied"]

    /// For a 200 the host kept nothing from: the guest's reply when it is
    /// plainly a device-code poll's error, rebuilt from its allowed fields
    /// alone (never the provider's bytes or headers); nil for anything else
    /// -- a token, any other field, a body that can't be read -- which is
    /// answered `notKeptReply`.
    static func pollErrorReply(_ body: Data) -> Data? {
        guard body.count <= 4096,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = json["error"] as? String, pollErrors.contains(error),
              Set(json.keys).isSubset(of: ["error", "error_description", "error_uri", "interval"]) else { return nil }
        var out: [String: Any] = ["error": error]
        for key in ["error_description", "error_uri"] {
            guard let v = json[key] else { continue }
            guard let s = v as? String else { return nil }
            out[key] = s
        }
        if let v = json["interval"] {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            out["interval"] = n.intValue
        }
        return response(status: 200, reason: "OK", json: out)
    }

    /// The marker an ended sign-in leaves on its endpoint.
    static func spentMarker(profileID: UUID, hosts: Set<String>, pathPrefix: String,
                            now: Date = Date()) -> SignInCapture {
        var c = SignInCapture(profileID: profileID, hosts: hosts, pathPrefix: pathPrefix,
                              handle: { _, _ in nil })
        c.spent = true
        c.expiresAt = now.addingTimeInterval(spentFor)
        return c
    }

    /// The token exchange — not a refresh, which the guest never needs in
    /// subscription mode and which must not be swallowed if it happens.
    func matches(host: String, method: String, path: String, body: Data) -> Bool {
        guard method.uppercased() == "POST", hosts.contains(host.lowercased()),
              path.hasPrefix(pathPrefix) else { return false }
        let b = String(decoding: body, as: UTF8.self).lowercased()
            .replacingOccurrences(of: " ", with: "")
        return !b.contains("grant_type=refresh_token") && !b.contains("\"grant_type\":\"refresh_token\"")
    }

    /// A complete JSON response the proxy can write to the guest.
    static func response(status: Int, reason: String, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}

/// An ended sign-in's token endpoint, turned away until it expires.
struct SpentEndpoint: Sendable {
    let capture: SignInCapture
    var expiresAt: Date { capture.expiresAt ?? .distantPast }
}

/// The captures in flight, one per workspace, consulted by every proxied
/// request (from the connection tasks, hence the lock) -- and the ended
/// ones each workspace still turns away, kept apart so arming a new
/// sign-in (another agent's) never lifts them.
final class SignInCaptureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [UUID: SignInCapture] = [:]
    private var spent: [UUID: [SpentEndpoint]] = [:]

    /// A live capture replaces the workspace's live one and lifts only the
    /// spent markers on its own endpoint (a retry); a spent marker joins
    /// the list, replacing one on the same endpoint.
    func arm(_ capture: SignInCapture) {
        lock.lock(); defer { lock.unlock() }
        func sameEndpoint(_ e: SpentEndpoint) -> Bool {
            e.capture.hosts == capture.hosts && e.capture.pathPrefix == capture.pathPrefix
        }
        if capture.spent {
            spent[capture.profileID, default: []].removeAll(where: sameEndpoint)
            spent[capture.profileID, default: []].append(SpentEndpoint(capture: capture))
        } else {
            spent[capture.profileID]?.removeAll(where: sameEndpoint)
            captures[capture.profileID] = capture
        }
    }

    /// The live capture goes; spent markers stay until they expire.
    func disarm(profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        captures[profileID] = nil
    }

    /// The workspace's live capture, carrying its spent markers -- or, with
    /// none live, a spent capture of the first marker carrying the rest.
    func capture(for profileID: UUID, now: Date = Date()) -> SignInCapture? {
        lock.lock(); defer { lock.unlock() }
        spent[profileID]?.removeAll { now >= $0.expiresAt }
        if spent[profileID]?.isEmpty == true { spent[profileID] = nil }
        let markers = spent[profileID] ?? []
        if var live = captures[profileID] {
            live.spentEndpoints = markers
            return live
        }
        guard var first = markers.first?.capture else { return nil }
        first.spentEndpoints = Array(markers.dropFirst())
        return first
    }
}
