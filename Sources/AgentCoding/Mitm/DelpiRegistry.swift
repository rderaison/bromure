import Foundation
import AppKit

/// Delpi secure npm registry (Lupin & Holmes / landh.tech). Unlike
/// socket.dev — a reputation API the proxy *consults* before letting
/// a fetch through — Delpi is a drop-in npm registry replacement
/// that serves already-vetted packages. When the profile selects
/// Delpi (`SupplyChainPolicy.delpiActive`), the MITM proxy re-routes
/// every registry.npmjs.org request to `host` and attaches the
/// user's API key as `Authorization: Bearer`.
///
/// Two request shapes reach the proxy:
///   - registry.npmjs.org/… — npm's default registry. Re-routed
///     wholesale (metadata, tarballs, audit, everything), same paths:
///     Delpi mirrors the npm registry API at its root.
///   - depi-npm-proxy.landh.tech/… — Delpi rewrites `dist.tarball`
///     URLs in the packuments it serves to point at itself, so the
///     guest's tarball fetches arrive addressed to Delpi directly.
///     Those get the Bearer key injected too (the key never enters
///     the VM, so the guest can't send it itself).
///
/// The key is held host-side only — same rule as the socket.dev key.
enum DelpiRegistry {
    /// Delpi's npm-compatible registry endpoint.
    static let host = "depi-npm-proxy.landh.tech"
    static let port = 443

    /// npm registry hosts to re-route. Mirrors the recogniser in
    /// `SupplyChainRegistry.classify`.
    static func isNpmRegistryHost(_ h: String) -> Bool {
        let lower = h.lowercased()
        return lower == "registry.npmjs.org" || lower.hasSuffix(".npmjs.org")
    }

    /// True when a request to `host` must be re-routed / authorized
    /// for Delpi: npm's registry (re-route + key) or Delpi itself
    /// (key only — it's already the destination).
    static func shouldRoute(host h: String) -> Bool {
        isNpmRegistryHost(h) || h.lowercased() == host
    }

    /// Attach the Delpi key as `Authorization: Bearer`, replacing any
    /// Authorization header the guest sent (a guest npm token means
    /// nothing to Delpi and must not leak there).
    static func authorize(rawRequest: Data, apiKey: String) -> Data {
        HTTPMitmConnection.replaceAuthorizationBearer(rawRequest: rawRequest, token: apiKey)
    }

    /// Guest-facing response substituted when Delpi rejects our API
    /// key. Keeps the upstream status code (401/403) so npm still
    /// fails the install, but swaps the body for a message the
    /// package manager surfaces verbatim — pointing the user at the
    /// actual fix instead of a bare "401 Unauthorized".
    static func authFailureResponse(status: Int) -> Data {
        let body = "Bromure: the Delpi registry rejected the configured API key " +
            "(HTTP \(status)). npm installs are re-routed to Delpi for this " +
            "workspace — fix or remove the Delpi API key in the workspace's " +
            "Supply Chain settings.\n"
        var resp = "HTTP/1.1 \(status) \(status == 401 ? "Unauthorized" : "Forbidden")\r\n"
        resp += "Content-Type: text/plain; charset=utf-8\r\n"
        resp += "X-Bromure-Block: delpi-auth\r\n"
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

    /// Record a Delpi auth failure to the Security Log and raise a
    /// one-shot alert (per profile + key) in the GUI so the user
    /// finds out even when they're not watching the agent's output.
    static func reportAuthFailure(status: Int, apiKey: String,
                                  profileID: UUID, path: String) {
        SupplyChainLog.shared.record(
            "[delpi] ✗ HTTP \(status) from \(host)\(path) — API key rejected; " +
            "npm installs will fail until the key is fixed in Supply Chain settings")

        let dedupKey = "\(profileID.uuidString)|\(apiKey.hashValue)"
        alertLock.lock()
        let firstTime = alerted.insert(dedupKey).inserted
        alertLock.unlock()
        guard firstTime else { return }

        let title = NSLocalizedString(
            "Delpi rejected your API key", comment: "Delpi auth failure alert title")
        let body = String(format: NSLocalizedString(
            "The Delpi registry answered HTTP %d. npm installs in this workspace are routed through Delpi and will fail until the API key is corrected in Settings → Supply Chain.",
            comment: "Delpi auth failure alert body"), status)

        switch RemoteConsent.route(for: profileID) {
        case .localAlert:
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = body
                alert.alertStyle = .warning
                alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        case .fatClient:
            // Surface it on the connected fat client's Mac (over the tunnel).
            // Fire-and-forget: a one-button acknowledgement, no decision needed.
            Task { @MainActor in
                _ = await PendingPromptBroker.shared.askAsync(
                    profileID: profileID, title: title, message: body,
                    buttons: [NSLocalizedString("OK", comment: "")],
                    fallback: 0, timeout: 120)
            }
        case .terminalPump:
            // Headless (SSH/TUI) sessions have no GUI to alert; the log line
            // above plus the rewritten npm error keep them informed.
            break
        }
    }
}
