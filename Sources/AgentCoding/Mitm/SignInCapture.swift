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

    /// How long an ended sign-in still turns its exchange away.
    static let spentFor: TimeInterval = 15 * 60

    /// What the guest hears for a token exchange the host doesn't keep.
    static var notKeptReply: Data {
        response(status: 400, reason: "Bad Request", json: [
            "error": "bromure_not_kept",
            "error_description": "Bromure didn't keep this sign-in. Start it again from the session's sign-in card.",
        ])
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

/// The captures in flight, one per workspace, consulted by every proxied
/// request (from the connection tasks, hence the lock).
final class SignInCaptureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [UUID: SignInCapture] = [:]

    func arm(_ capture: SignInCapture) {
        lock.lock(); defer { lock.unlock() }
        captures[capture.profileID] = capture
    }

    func disarm(profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        captures[profileID] = nil
    }

    func capture(for profileID: UUID, now: Date = Date()) -> SignInCapture? {
        lock.lock(); defer { lock.unlock() }
        if let c = captures[profileID], let until = c.expiresAt, now >= until {
            captures[profileID] = nil
            return nil
        }
        return captures[profileID]
    }
}
