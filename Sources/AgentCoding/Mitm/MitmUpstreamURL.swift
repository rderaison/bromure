import Foundation

/// Lowercase, strip IPv6 brackets and trailing root dots so a host
/// string and a URL-parsed host compare on equal footing.
func mitmNormalizeHost(_ s: String) -> String {
    var h = s.lowercased()
    if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
    while h.hasSuffix(".") { h.removeLast() }
    return h
}

/// Build the upstream URL from the CONNECT authority and the inner
/// request-target — the single place where the proxy decides where a
/// tunneled request is actually sent.
///
/// Security invariant: the credential scope checks (`TokenSwapper.swap`
/// / `detectCompromise`) ran against the CONNECT `host`, so the URL the
/// request is replayed to MUST resolve to that same host. Naive
/// concatenation `"https://\(host)\(portStr)\(path)"` breaks that when
/// the guest sends a request-target that isn't origin-form: a target
/// like `"@evil.com/"` turns the string into
/// `"https://scoped.host@evil.com/"`, which RFC 1808 userinfo parsing
/// resolves to `evil.com` — the scope checks pass on `scoped.host`
/// while the swapped real credential is delivered to the attacker.
/// We therefore require origin-form (`"/…"`) and assert the parsed
/// URL's host equals the CONNECT host; anything else is rejected
/// before a single byte leaves the host.
func mitmUpstreamURL(scheme: String, host: String, port: Int, path: String) throws -> URL {
    guard path.hasPrefix("/") else {
        throw MitmError.upstreamTargetRejected(
            "non-origin-form request target \(path.debugDescription) on \(host)")
    }
    let isDefaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    let portStr = isDefaultPort ? "" : ":\(port)"
    guard let url = URL(string: "\(scheme)://\(host)\(portStr)\(path)") else {
        throw MitmError.malformedHTTPRequest
    }
    guard let resolved = url.host,
          mitmNormalizeHost(resolved) == mitmNormalizeHost(host) else {
        throw MitmError.upstreamTargetRejected(
            "CONNECT host \(host) but upstream URL resolves to \(url.host ?? "nil")")
    }
    return url
}
