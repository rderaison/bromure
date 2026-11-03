import Foundation

// The registration machine's portable pieces -- what a throwaway sign-in
// VM's captured credential is, how it's read and where it's saved -- for the
// macOS app (ClaudeRegistrationCoordinator.swift) and the Linux server,
// which runs the same flow on its own machines.

enum ClaudeRegistrationTeardownReason {
    case success, cancelled, failure, timeout, windowClosed

    /// What a run that ended this way says when its caller had nothing more
    /// specific: a fat client's Register button only hears this sentence.
    var endedMessage: String? {
        switch self {
        case .success: return nil
        case .cancelled: return NSLocalizedString("The sign-in was cancelled.", comment: "sign-in")
        case .windowClosed: return NSLocalizedString("The sign-in window was closed.", comment: "sign-in")
        case .failure, .timeout:
            return NSLocalizedString("The sign-in didn't complete. You can try again.", comment: "sign-in")
        }
    }
}

/// Captured-token payload, shaped per provider.
enum CapturedSubscription {
    case claude(access: String, refresh: String)
    case codex(access: String, refresh: String, idToken: String)
    case grok(access: String, refresh: String, scopeKey: String, template: Data)
    case kimi(access: String, refresh: String, name: String, template: Data,
              configTOML: String?)
}

enum RegistrationCapture {
    /// Persist a captured credential: the workspace's own sign-in when
    /// `overrideProfile`, else the shared one. distantPast expiry → the proxy
    /// refreshes on first use, which both establishes the real expiry and
    /// proves the refresh path immediately.
    @MainActor
    static func save(_ captured: CapturedSubscription, overrideProfile: UUID?,
                     into stores: ProxySignInBackend) throws {
        switch captured {
        case .claude(let access, let refresh):
            let rec = ClaudeSubscriptionRecord(
                accessToken: access, refreshToken: refresh,
                expiresAt: .distantPast, savedAt: Date())
            if let pid = overrideProfile { try stores.claude.setOverride(rec, for: pid) }
            else { try stores.claude.setShared(rec) }
        case .codex(let access, let refresh, let idToken):
            let rec = CodexSubscriptionRecord(
                accessToken: access, refreshToken: refresh, idToken: idToken,
                expiresAt: .distantPast, savedAt: Date())
            if let pid = overrideProfile { try stores.codex.setOverride(rec, for: pid) }
            else { try stores.codex.setShared(rec) }
        case .kimi(let access, let refresh, let name, let template, let configTOML):
            // Same forced-refresh-on-first-use rationale as Grok below.
            let rec = KimiSubscriptionRecord(
                accessToken: access, refreshToken: refresh,
                expiresAt: .distantPast, savedAt: Date(),
                credentialName: name, templateJSON: template,
                configTOML: configTOML)
            if let pid = overrideProfile { try stores.kimi.setOverride(rec, for: pid) }
            else { try stores.kimi.setShared(rec) }
        case .grok(let access, let refresh, let scopeKey, let template):
            // Force an immediate proactive refresh on first use to establish
            // the real expiry + prove the refresh path.
            let rec = GrokSubscriptionRecord(
                accessToken: access, refreshToken: refresh,
                expiresAt: .distantPast, savedAt: Date(),
                scopeKey: scopeKey, templateJSON: template)
            if let pid = overrideProfile { try stores.grok.setOverride(rec, for: pid) }
            else { try stores.grok.setShared(rec) }
        }
    }

    /// Drop every workspace's own sign-in for `provider`, so a login the user
    /// just chose to share is the one every workspace reads.
    @MainActor
    static func forgetOverrides(_ provider: SubscriptionProvider, for profileIDs: [UUID],
                                in stores: ProxySignInBackend) {
        for id in profileIDs {
            switch provider {
            case .claude: if stores.claude.hasProfileRecord(id) { try? stores.claude.forget(for: id) }
            case .codex:  if stores.codex.hasProfileRecord(id) { try? stores.codex.forget(for: id) }
            case .grok:   if stores.grok.hasProfileRecord(id) { try? stores.grok.forget(for: id) }
            case .kimi:   if stores.kimi.hasProfileRecord(id) { try? stores.kimi.forget(for: id) }
            }
        }
    }

    static func parseGrokAuth(_ data: Data)
        -> (access: String, refresh: String, expiresAt: Date, scopeKey: String, template: Data)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let scopes = [grokOIDCScope] + obj.keys.filter { $0 != grokOIDCScope }
        for scope in scopes {
            guard var entry = obj[scope] as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty,
                  !key.hasPrefix("grok-brm-") else { continue }   // skip our own bogus
            let refresh = (entry["refresh_token"] as? String) ?? ""
            let exp: Date
            if let s = entry["expires_at"] as? String,
               let d = ISO8601DateFormatter().date(from: s) { exp = d }
            else if let e = entry["expires_at"] as? Double { exp = Date(timeIntervalSince1970: e) }
            else if let e = entry["expires_at"] as? Int { exp = Date(timeIntervalSince1970: Double(e)) }
            else { exp = .distantPast }
            // Stash a template that keeps the account fields but drops the live
            // secrets (re-injected, as bogus, at seed time).
            entry.removeValue(forKey: "key")
            entry.removeValue(forKey: "refresh_token")
            entry.removeValue(forKey: "expires_at")
            let template = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
            return (key, refresh, exp, scope, template)
        }
        return nil
    }

    /// Kimi's credentials from `~/.kimi-code/credentials/<name>.json` (each
    /// file's name without .json, and its bytes) and its `config.toml`, or
    /// nil until the user has signed in and the managed provider is
    /// provisioned. See ACAppDelegate.readKimiCredentials.
    static func parseKimiCredentials(files: [(name: String, data: Data)], configTOML toml: String?)
        -> (access: String, refresh: String, name: String, template: Data,
            configTOML: String?)? {
        // Managed flow first, then any other provider the user logged into.
        let ordered = files.sorted { a, _ in a.name == kimiManagedCredentialName }
        for file in ordered {
            guard var obj = (try? JSONSerialization.jsonObject(with: file.data)) as? [String: Any],
                  let access = obj["access_token"] as? String, !access.isEmpty,
                  // Skip our own bogus seed (both the JWT-mint and the
                  // deriveFake fallback shapes).
                  !access.hasPrefix("kimi-brm-") else { continue }
            let refresh = (obj["refresh_token"] as? String) ?? ""
            obj.removeValue(forKey: "access_token")
            obj.removeValue(forKey: "refresh_token")
            obj.removeValue(forKey: "expires_at")
            let template = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            // The credential lands FIRST; `kimi login` then provisions the
            // managed models over the network and only after that writes the
            // provider + models + default_model into config.toml. Accepting
            // the instant the credential appears captured an empty config
            // (and tore the VM down mid-provisioning), so every session that
            // re-seeded it died at "No model configured". Keep polling until
            // the managed provider is on disk; the caller's budget covers it.
            guard let toml, KimiProvisioner.isProvisioned(toml) else { continue }
            return (access, refresh, file.name, template, toml)
        }
        return nil
    }
}
