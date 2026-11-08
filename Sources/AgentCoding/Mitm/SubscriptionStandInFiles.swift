import Foundation

/// The stand-in credential files a subscription workspace's guest starts
/// with, for the CLIs that read their sign-in from a file (Grok's, Kimi's):
/// the captured record's shape, its secrets swapped for stand-ins the proxy
/// recognises. Written into a home before boot or on a live refresh, by
/// either platform's launch.
enum SubscriptionStandInFiles {
    /// Grok subscription mode: write a bogus `~/.grok/auth.json` into the
    /// profile's home so the guest runs Grok without
    /// logging in. The bogus token carries a far-future `expires_at` so the
    /// guest never refreshes; the host owns refresh and the proxy swaps the
    /// bogus Bearer for the live one on cli-chat-proxy.grok.com.
    /// `homeRoot`: the home it's written into (the host-mounted one, or a
    /// seed's files).
    static func seedGrok(store: GrokSubscriptionStore, profileID: UUID, homeRoot: URL) {
        guard let real = store.record(for: profileID) else { return }
        // JWT-shaped stand-ins (real claims, far-future exp, Bromure-marked
        // signature) — the proxy recognises them by that mark even after an
        // app restart emptied its registry.
        let standIn = GrokStandIn.mint(real, profileID: profileID)
        let bogusAccess = standIn.access, bogusRefresh = standIn.refresh
        store.registerBogusKey(bogusAccess, for: profileID)

        // Rebuild grok's scope entry from the captured template (which carries
        // the account-specific fields grok's strict serde requires —
        // auth_mode, team_name, subscription_tier, …) and inject bogus secrets.
        // `expires_at` must be an RFC 3339 STRING (serde rejects a bare epoch
        // integer, making the file unreadable). Push it ~10y out.
        let farFuture = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(10 * 365 * 24 * 3600))
        var entry: [String: Any] = (real.templateJSON.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }) ?? [:]
        entry["key"] = bogusAccess
        entry["refresh_token"] = bogusRefresh
        entry["expires_at"] = farFuture
        let doc: [String: Any] = [real.scopeKey: entry]
        let dir = homeRoot.appendingPathComponent(".grok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        }
    }

    /// Kimi subscription mode: write a bogus
    /// `~/.kimi-code/credentials/<name>.json` (plus, if captured, the managed
    /// `config.toml` the CLI's own `/login` writes) into the profile's home
    /// so the guest runs Kimi Code without logging in. The bogus token
    /// carries a far-future `expires_at` so the guest never refreshes; the
    /// host owns refresh and the proxy swaps the bogus Bearer for the live
    /// one on api.kimi.ai. `homeRoot`: see seedGrok.
    static func seedKimi(store: KimiSubscriptionStore, profileID: UUID, homeRoot: URL) {
        guard let real = store.record(for: profileID) else { return }
        // Derived through the shared helper so the proxy's bearer swap AND its
        // answer to a guest refresh (KimiRefreshAnswer) see the same strings.
        let bogusAccess = KimiStandIn.access(realAccess: real.accessToken, profileID: profileID)
        let bogusRefresh = KimiStandIn.refresh(realRefresh: real.refreshToken, profileID: profileID)
        store.registerBogusKey(bogusAccess, for: profileID)

        // Rebuild the credentials entry from the captured template (scope /
        // token_type / expires_in as the server issued them) and inject the
        // bogus secrets. `expires_at` is unix SECONDS in kimi's wire format
        // (see packages/oauth types.ts) — push it ~10y out.
        let farFuture = Date().addingTimeInterval(10 * 365 * 24 * 3600).timeIntervalSince1970
        var entry: [String: Any] = (real.templateJSON.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }) ?? ["scope": "", "token_type": "Bearer", "expires_in": 3600]
        entry["access_token"] = bogusAccess
        entry["refresh_token"] = bogusRefresh
        entry["expires_at"] = Int(farFuture)
        // The captured template carries the SERVER's short `expires_in` (900s).
        // kimi's refresh threshold is `expiresAt − now < max(300, expiresIn/2)`,
        // which the far-future expires_at already clears — but keep the two
        // fields consistent so nothing reads the token as short-lived.
        entry["expires_in"] = Int(KimiStandIn.lifetime)

        let kimiHome = homeRoot.appendingPathComponent(".kimi-code", isDirectory: true)
        let credDir = kimiHome.appendingPathComponent("credentials", isDirectory: true)
        try? FileManager.default.createDirectory(at: credDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: credDir.path)
        let url = credDir.appendingPathComponent("\(real.credentialName).json")
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        }
        // The managed provider + model list `/login` wrote in the registration
        // VM. Create-if-missing: the guest's own config.toml (and the marker
        // block the .bashrc appends) owns the file from then on.
        if let toml = real.configTOML, KimiProvisioner.isProvisioned(toml) {
            let cfg = kimiHome.appendingPathComponent("config.toml")
            // Write when missing — OR when what's there has no managed
            // provider: the guest's hooks merge creates a hooks-only
            // config.toml on first boot, and a re-registration (e.g. after
            // the switch to the .ai region) must land its provider block
            // even though a file exists. The hooks block is re-merged by
            // the guest on every shell (marker-guarded), so overwriting
            // loses nothing Bromure doesn't put back.
            let existing = (try? String(contentsOf: cfg, encoding: .utf8)) ?? ""
            if existing.isEmpty || !KimiProvisioner.isProvisioned(existing) {
                try? toml.write(to: cfg, atomically: true, encoding: .utf8)
            }
        }
    }
}
