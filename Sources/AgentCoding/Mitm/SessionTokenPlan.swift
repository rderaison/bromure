import Foundation
import Crypto

/// Built once per session launch from a Profile's saved tokens. Pairs
/// every real token with a freshly-minted fake — the real values stay
/// on the host (fed to MitmEngine.swapper); the fakes get written into
/// the VM's env vars + .git-credentials. The VM never holds a real
/// secret in any file or env var.
public struct SessionTokenPlan: Sendable {
    public struct Entry: Sendable {
        public let realValue: String
        public let fakeValue: String
        public let purpose: Purpose
        /// Stable consent ID for the source credential. nil = the
        /// credential isn't gated. Multiple entries may share the
        /// same ID (e.g. a docker registry's primary + auth-realm
        /// rows both come from the same registry credential).
        public let consentCredentialID: String?
        /// Display name shown in the consent prompt.
        public let consentDisplayName: String
        public init(realValue: String, fakeValue: String, purpose: Purpose,
                    consentCredentialID: String? = nil,
                    consentDisplayName: String = "") {
            self.realValue = realValue
            self.fakeValue = fakeValue
            self.purpose = purpose
            self.consentCredentialID = consentCredentialID
            self.consentDisplayName = consentDisplayName
        }
    }

    public enum Purpose: Sendable {
        /// ANTHROPIC_API_KEY env var — Claude Code reads this.
        case anthropicAPIKey
        /// OPENAI_API_KEY env var — Codex reads this.
        case openaiAPIKey
        /// HTTPS git credential. Materialized in ~/.git-credentials and
        /// the gh / glab configs.
        case gitHTTPS(host: String, username: String)
        /// User-defined entry from the editor's Advanced section.
        /// `envVarName` may be empty (then nothing is exported and the
        /// user copy-pastes the fake from the welcome banner).
        case manual(name: String, envVarName: String, hostFilter: String)
        /// DigitalOcean PAT. Injected as DIGITALOCEAN_ACCESS_TOKEN env
        /// + ~/.config/doctl/config.yaml in the VM.
        case digitalOcean
        /// Container-registry Basic auth. The realValue / fakeValue are
        /// the full `base64("<user>:<password>")` strings — that's what
        /// docker writes in `~/.docker/config.json` and sends as
        /// `Authorization: Basic <…>`. host is the registry hostname.
        case dockerRegistry(host: String, username: String)
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Build the proxy's swap map. Each entry becomes one fake→real
    /// replacement, scoped to the host the real token belongs to (so a
    /// stray fake leaking to a third-party host is left alone, not
    /// quietly rewritten with the wrong value).
    public func tokenMap() -> TokenMap {
        let mapped = entries.map { e in
            TokenMap.Entry(
                fake: e.fakeValue,
                real: e.realValue,
                host: hostScope(for: e.purpose),
                consentCredentialID: e.consentCredentialID,
                consentDisplayName: e.consentCredentialID != nil
                    ? e.consentDisplayName : nil
            )
        }
        return TokenMap(entries: mapped)
    }

    /// Look up a fake token to use in place of a tool's real API key.
    public func fakeForAnthropic() -> String? {
        for e in entries {
            if case .anthropicAPIKey = e.purpose { return e.fakeValue }
        }
        return nil
    }

    public func fakeForOpenAI() -> String? {
        for e in entries {
            if case .openaiAPIKey = e.purpose { return e.fakeValue }
        }
        return nil
    }

    /// Fake to embed into ~/.git-credentials for the matching host.
    public func fakeForGitHTTPS(host: String, username: String) -> String? {
        for e in entries {
            if case .gitHTTPS(let h, let u) = e.purpose,
               h == host, u == username {
                return e.fakeValue
            }
        }
        return nil
    }

    private func hostScope(for purpose: Purpose) -> String? {
        switch purpose {
        case .anthropicAPIKey:        return "anthropic.com"
        case .openaiAPIKey:           return "openai.com"
        case .gitHTTPS(let host, _):  return host
        case .manual(_, _, let host): return host.isEmpty ? nil : host
        case .digitalOcean:           return "digitalocean.com"
        case .dockerRegistry(let host, _): return host
        }
    }

    /// Look up the fake base64 auth blob for a given (host, username)
    /// pair so Profile.prepareHomeDirectory can write it into the VM's
    /// ~/.docker/config.json. Returns nil if no docker entry matches.
    public func fakeForDockerRegistry(host: String, username: String) -> String? {
        for e in entries {
            if case .dockerRegistry(let h, let u) = e.purpose,
               h == host, u == username {
                return e.fakeValue
            }
        }
        return nil
    }

    /// Hardcoded list of cloud registries whose distribution-spec auth
    /// challenge points at a different hostname than the registry
    /// itself. Each docker-registry credential gets a duplicate swap
    /// entry per realm, so the Basic-auth check on the realm host
    /// substitutes correctly.
    static func dockerAuthRealms(for host: String) -> [String] {
        let h = host.lowercased().trimmingCharacters(in: .whitespaces)
        switch h {
        case "registry.digitalocean.com":
            return ["api.digitalocean.com"]
        case "docker.io", "registry-1.docker.io", "index.docker.io":
            return ["auth.docker.io"]
        case "public.ecr.aws":
            return ["public.ecr.aws"]
        default:
            return []
        }
    }

    /// Fake to expose to the VM as DIGITALOCEAN_ACCESS_TOKEN and in
    /// ~/.config/doctl/config.yaml. nil = no DO token configured.
    public func fakeForDigitalOcean() -> String? {
        for e in entries {
            if case .digitalOcean = e.purpose { return e.fakeValue }
        }
        return nil
    }

    /// Manual entries that have an env var name set, formatted as
    /// `[(envName, fake)]` for SessionDisk to materialize in the meta
    /// share's manual_tokens.env file.
    public var manualEnvExports: [(String, String)] {
        var out: [(String, String)] = []
        for e in entries {
            if case .manual(_, let envName, _) = e.purpose, !envName.isEmpty {
                out.append((envName, e.fakeValue))
            }
        }
        return out
    }

    /// All manual entries with their (display name, env var, fake)
    /// triple. Used for the welcome message so the user knows which
    /// fakes are live in the VM.
    public var manualEntries: [(name: String, envVarName: String, fake: String)] {
        var out: [(String, String, String)] = []
        for e in entries {
            if case .manual(let name, let envName, _) = e.purpose {
                out.append((name, envName, e.fakeValue))
            }
        }
        return out
    }
}

public extension Profile {
    /// Build the swap plan for this session. Pure function of
    /// `(profile state, salt)` — same inputs always produce the same
    /// fakes, so Claude Code's "API key fingerprint changed" warning
    /// stays quiet across launches. Rotating either the real value
    /// (user pasted a new key) or the salt (user deleted
    /// `~/Library/Application Support/BromureAC/fake-salt.bin`) is the
    /// only way fakes change.
    func makeTokenPlan(salt: Data) -> SessionTokenPlan {
        var entries: [SessionTokenPlan.Entry] = []

        // Primary tool API key gating: the primary tool's flag lives
        // on Profile (apiKeyRequiresApproval); each entry in
        // additionalTools carries its own `requireApproval`.
        for spec in allToolSpecs where spec.authMode == .token {
            guard let raw = spec.apiKey else { continue }
            let real = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if real.isEmpty { continue }
            let isPrimary = (spec.tool == self.tool)
            let gated = isPrimary ? apiKeyRequiresApproval : spec.requireApproval
            let consentID: String? = gated
                ? ConsentCredentialID.primaryToolAPIKey(tool: spec.tool.rawValue)
                : nil
            let displayName = "\(spec.tool.displayName) API key"
            switch spec.tool {
            case .claude:
                entries.append(.init(
                    realValue: real,
                    fakeValue: SessionTokenPlan.deriveFake(prefix: "sk-ant-api03-brm-",
                                                           real: real, salt: salt),
                    purpose: .anthropicAPIKey,
                    consentCredentialID: consentID,
                    consentDisplayName: displayName))
            case .codex:
                entries.append(.init(
                    realValue: real,
                    fakeValue: SessionTokenPlan.deriveFake(prefix: "sk-brm-",
                                                           real: real, salt: salt),
                    purpose: .openaiAPIKey,
                    consentCredentialID: consentID,
                    consentDisplayName: displayName))
            }
        }

        for entry in manualTokens where entry.isUsable {
            let real = entry.realValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if real.isEmpty { continue }
            let consentID: String? = entry.requireApproval
                ? ConsentCredentialID.manualToken(entry.id) : nil
            entries.append(.init(
                realValue: real,
                fakeValue: SessionTokenPlan.deriveFake(prefix: "brm_",
                                                       real: real, salt: salt),
                purpose: .manual(name: entry.name,
                                 envVarName: entry.envVarName,
                                 hostFilter: entry.hostFilter),
                consentCredentialID: consentID,
                consentDisplayName: entry.name.isEmpty
                    ? "manual token" : "“\(entry.name)” token"))
        }

        // DigitalOcean PAT.
        let doRaw = digitalOceanToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !doRaw.isEmpty {
            let doFake = SessionTokenPlan.deriveFake(prefix: "dop_v1_",
                                                      real: doRaw, salt: salt,
                                                      targetLength: 64)
            let doConsentID: String? = digitalOceanTokenRequiresApproval
                ? ConsentCredentialID.digitalOcean() : nil
            let doDisplay = "DigitalOcean PAT"
            entries.append(.init(
                realValue: doRaw,
                // Real DO PATs are 64 chars — `dop_v1_<hex>`.
                // Match the prefix + length so client validators
                // (doctl, terraform-provider-digitalocean) accept.
                fakeValue: doFake,
                purpose: .digitalOcean,
                consentCredentialID: doConsentID,
                consentDisplayName: doDisplay))
            // `doctl registry login` / `docker login -u $TOKEN -p $TOKEN
            // registry.digitalocean.com` wraps the PAT in HTTP Basic
            // auth — the wire form is `Authorization: Basic
            // base64("<token>:<token>")`. The naked-token swap above
            // can't see through the base64 transform, so add an
            // explicit pair for the encoded blob. Scope tracks the
            // .digitalOcean entry (digitalocean.com).
            let realB64 = Data("\(doRaw):\(doRaw)".utf8).base64EncodedString()
            let fakeB64 = Data("\(doFake):\(doFake)".utf8).base64EncodedString()
            entries.append(.init(
                realValue: realB64,
                fakeValue: fakeB64,
                purpose: .digitalOcean,
                consentCredentialID: doConsentID,
                consentDisplayName: doDisplay))
        }

        for reg in dockerRegistries where reg.isUsable {
            let realPass = reg.password.trimmingCharacters(in: .whitespacesAndNewlines)
            if realPass.isEmpty { continue }
            // Mint a fake password derived from the real one (HKDF over
            // the real value + salt) so the same input always produces
            // the same fake — clients that cache `auth` blobs don't see
            // the value rotate session-to-session.
            //
            // Both the real and fake `auth` strings are
            // base64("<user>:<password>"). The proxy substitutes the
            // fake base64 with the real base64 on the wire, scoped to
            // the registry host (so a stray copy of the fake leaking to
            // a third-party host is left alone, not rewritten).
            let fakePass = SessionTokenPlan.deriveFake(
                prefix: "brm-docker-",
                real: realPass,
                salt: salt,
                targetLength: max(40, realPass.count))
            let realB64 = Data("\(reg.username):\(realPass)".utf8).base64EncodedString()
            let fakeB64 = Data("\(reg.username):\(fakePass)".utf8).base64EncodedString()
            let regConsentID: String? = reg.requireApproval
                ? ConsentCredentialID.dockerRegistry(reg.id) : nil
            let regDisplay = "registry “\(reg.host)” (\(reg.username))"
            entries.append(.init(
                realValue: realB64,
                fakeValue: fakeB64,
                purpose: .dockerRegistry(host: reg.host, username: reg.username),
                consentCredentialID: regConsentID,
                consentDisplayName: regDisplay))
            // Distribution-spec auth flow: GET /v2/ returns 401 with
            // a `WWW-Authenticate: Bearer realm="https://<auth-host>/…"`.
            // For multi-host providers (DO: api.digitalocean.com,
            // Docker Hub: auth.docker.io) the realm lives on a
            // different hostname than the registry, so an entry
            // scoped to the registry host alone never fires on the
            // auth call. Add one swap entry per known auth realm with
            // the same fake/real base64 pair.
            for realm in SessionTokenPlan.dockerAuthRealms(for: reg.host) {
                entries.append(.init(
                    realValue: realB64,
                    fakeValue: fakeB64,
                    // Reuse .dockerRegistry purpose; only the host
                    // scope differs. Carry the realm in the host slot.
                    purpose: .dockerRegistry(host: realm, username: reg.username),
                    consentCredentialID: regConsentID,
                    consentDisplayName: regDisplay))
            }
        }

        for cred in gitHTTPSCredentials where cred.isUsable {
            let real = cred.token.trimmingCharacters(in: .whitespacesAndNewlines)
            if real.isEmpty { continue }
            let h = cred.host.lowercased()
            let prefix: String
            // Match exact lengths so client-side prefix-and-length
            // validators (gh, glab) don't reject. Real GitHub classic
            // PAT = 40 chars (ghp_ + 36). GitLab PAT = "glpat-" + 20.
            let target: Int?
            if h == "github.com" || h.hasSuffix(".github.com") {
                prefix = "ghp_"
                target = 40
            } else if h == "gitlab.com" || h.hasPrefix("gitlab.") {
                prefix = "glpat-"
                target = 26
            } else {
                prefix = "brm_"
                target = nil
            }
            let credConsentID: String? = cred.requireApproval
                ? ConsentCredentialID.gitHTTPS(cred.id) : nil
            entries.append(.init(
                realValue: real,
                fakeValue: SessionTokenPlan.deriveFake(prefix: prefix,
                                                       real: real, salt: salt,
                                                       targetLength: target),
                purpose: .gitHTTPS(host: cred.host, username: cred.username),
                consentCredentialID: credConsentID,
                consentDisplayName: "git token (\(cred.username)@\(cred.host))"))
        }

        return SessionTokenPlan(entries: entries)
    }
}

extension SessionTokenPlan {
    /// HKDF-SHA256 derivation: `prefix || base62(HKDF(real, salt))`,
    /// truncated to a target total length.
    ///
    /// Stable across launches for a given (real, salt) pair so cached
    /// API-key identity in clients (Claude Code etc.) doesn't see the
    /// fake rotate session-to-session.
    ///
    /// `targetLength` lets us match the exact format clients validate.
    /// GitHub PATs are 40 chars. Anthropic / OpenAI accept arbitrary
    /// lengths so we leave them at the default. Base62 keeps us inside
    /// the alphabet GitHub uses, so `gh` / curl don't reject on
    /// "looks-wrong" character checks.
    static func deriveFake(prefix: String,
                           real: String,
                           salt: Data,
                           targetLength: Int? = nil) -> String {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(real.utf8)),
            salt: salt,
            info: Data("bromure-ac-fake-token-v2".utf8),
            outputByteCount: 32
        )
        let bytes: [UInt8] = derived.withUnsafeBytes { Array($0) }
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let suffixLen: Int
        if let total = targetLength {
            suffixLen = max(0, total - prefix.count)
        } else {
            suffixLen = 32
        }
        var suffix = ""
        for i in 0..<suffixLen {
            suffix.append(alphabet[Int(bytes[i % bytes.count]) % alphabet.count])
        }
        return prefix + suffix
    }
}
