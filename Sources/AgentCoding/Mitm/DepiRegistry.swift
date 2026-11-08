import Foundation

/// Depi secure npm registry (Lupin & Holmes / landh.tech). Unlike
/// socket.dev — a reputation API the proxy *consults* before letting
/// a fetch through — Depi is a drop-in npm registry replacement
/// that serves already-vetted packages. When the profile selects
/// Depi (`SupplyChainPolicy.depiActive`), the MITM proxy re-routes
/// every registry.npmjs.org request to `host` and attaches the
/// user's API key as `Authorization: Bearer`.
///
/// Two request shapes reach the proxy:
///   - registry.npmjs.org/… — npm's default registry. Its reads
///     (metadata, tarballs, search, audit scans: `isReadOnlyLookup`) are
///     re-routed, same paths: Depi mirrors the npm registry API at its
///     root. Anything else (a publish, a login, a token…) goes where the
///     guest sent it, as without Depi: the key only ever vouches for
///     lookups.
///   - depi-npm-proxy.landh.tech/… — Depi rewrites `dist.tarball`
///     URLs in the packuments it serves to point at itself, so the
///     guest's tarball fetches arrive addressed to Depi directly.
///     Those get the Bearer key injected too (the key never enters
///     the VM, so the guest can't send it itself) — lookups only, here
///     too.
///
/// The key is held host-side only — same rule as the socket.dev key.
enum DepiRegistry {
    /// Depi's npm-compatible registry endpoint.
    static let host = "depi-npm-proxy.landh.tech"
    static let port = 443

    /// npm registry hosts to re-route. Mirrors the recogniser in
    /// `SupplyChainRegistry.classify`.
    static func isNpmRegistryHost(_ h: String) -> Bool {
        let lower = h.lowercased()
        return lower == "registry.npmjs.org" || lower.hasSuffix(".npmjs.org")
    }

    /// True when a request to `host` must be re-routed / authorized
    /// for Depi: npm's registry (re-route + key) or Depi itself
    /// (key only — it's already the destination).
    static func shouldRoute(host h: String) -> Bool {
        isNpmRegistryHost(h) || h.lowercased() == host
    }

    /// The requests the Depi key goes with (and that are re-routed): the
    /// registry's reads — package documents, versions and tarballs
    /// (GET/HEAD outside npm's `/-/` API), the search, a package's
    /// dist-tags — and npm's audit scans (POST). Anything else — a
    /// publish, unpublish, login, token, whoami, owner, team, org or
    /// dist-tag change — gets neither: a guest can't act on the workspace
    /// owner's Depi account with its key. The path is judged decoded (as
    /// the registry reads it), its query aside; a malformed one is never a
    /// lookup.
    static func isReadOnlyLookup(method: String, path rawPath: String) -> Bool {
        guard !isMalformedPath(rawPath) else { return false }
        let path = String(rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let lower = (path.removingPercentEncoding ?? path).lowercased()
        switch method.uppercased() {
        case "GET", "HEAD":
            if !lower.hasPrefix("/-/") { return true }
            return lower == "/-/v1/search" || (lower.hasPrefix("/-/package/") && lower.hasSuffix("/dist-tags"))
        case "POST":
            return ["/-/npm/v1/security/advisories/bulk", "/-/npm/v1/security/audits/quick",
                    "/-/npm/v1/security/audits"].contains(lower)
        default:
            return false
        }
    }

    /// A path an upstream might normalise into another one: it doesn't
    /// decode, or has a `.`, `..` or empty segment (a single trailing slash
    /// aside), or a NUL. `/./-/whoami` or `//-/npm/v1/tokens` would read as
    /// lookups and be answered on the owner's account; such a request on an
    /// npm or Depi host is refused (400) while Depi is on, never forwarded
    /// unscanned.
    static func isMalformedPath(_ rawPath: String) -> Bool {
        let path = String(rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard let decoded = path.removingPercentEncoding, decoded.hasPrefix("/"), !decoded.contains("\0") else { return true }
        var segments = decoded.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        if segments == [""] { return false }                       // "/"
        if segments.count > 1, segments.last == "" { segments.removeLast() }
        return segments.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// The answer to a malformed path on an npm or Depi host.
    static let malformedPathDetail = "Bromure: a registry path with '.', '..', empty or undecodable segments is refused while Depi screens this workspace's npm traffic."

    /// Attach the Depi key as `Authorization: Bearer`, replacing any
    /// Authorization header the guest sent (a guest npm token means
    /// nothing to Depi and must not leak there).
    static func authorize(rawRequest: Data, apiKey: String) -> Data {
        SubscriptionAuthRewrite.replaceAuthorizationBearer(rawRequest: rawRequest, token: apiKey)
    }

    /// Guest-facing response substituted when Depi rejects our API
    /// key. Keeps the upstream status code (401/403) so npm still
    /// fails the install, but swaps the body for a message the
    /// package manager surfaces verbatim — pointing the user at the
    /// actual fix instead of a bare "401 Unauthorized".
    static func authFailureResponse(status: Int) -> Data {
        let body = "Bromure: the Depi registry rejected the configured API key " +
            "(HTTP \(status)). npm installs are re-routed to Depi for this " +
            "workspace — fix or remove the Depi API key in the workspace's " +
            "Supply Chain settings.\n"
        var resp = "HTTP/1.1 \(status) \(status == 401 ? "Unauthorized" : "Forbidden")\r\n"
        resp += "Content-Type: text/plain; charset=utf-8\r\n"
        resp += "X-Bromure-Block: depi-auth\r\n"
        resp += "Content-Length: \(body.utf8.count)\r\n"
        resp += "Connection: close\r\n\r\n"
        resp += body
        return Data(resp.utf8)
    }

    // MARK: - Host-side auth-error surfacing

    private static let alertLock = NSLock()
    /// Profiles that already got an alert for the currently stored
    /// key, so a 200-tarball install burst doesn't stack 200 modal
    /// alerts. Keyed on a key digest: entering a *different* key
    /// re-arms the alert.
    nonisolated(unsafe) private static var alerted: Set<String> = []

    /// Record a Depi auth failure to the Security Log and raise a
    /// one-shot alert (per profile + key) in the GUI so the user
    /// finds out even when they're not watching the agent's output.
    static func reportAuthFailure(status: Int, apiKey: String,
                                  profileID: UUID, path: String) {
        SupplyChainLog.shared.record(
            "[depi] ✗ HTTP \(status) from \(host)\(path) — API key rejected; " +
            "npm installs will fail until the key is fixed in Supply Chain settings")

        let dedupKey = "\(profileID.uuidString)|\(apiKey.hashValue)"
        alertLock.lock()
        let firstTime = alerted.insert(dedupKey).inserted
        alertLock.unlock()
        guard firstTime else { return }

        let title = NSLocalizedString(
            "Depi rejected your API key", comment: "Depi auth failure alert title")
        let body = String(format: NSLocalizedString(
            "The Depi registry answered HTTP %d. npm installs in this workspace are routed through Depi and will fail until the API key is corrected in Settings → Supply Chain.",
            comment: "Depi auth failure alert body"), status)

        // Headless (SSH/TUI) sessions get no notice; the log line above plus
        // the rewritten npm error keep them informed.
        ConsentPrompt.notice(profileID: profileID, title: title, message: body)
    }
}
