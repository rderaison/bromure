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
                host: hostScope(for: e.purpose)
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
        }
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

        for spec in allToolSpecs where spec.authMode == .token {
            guard let raw = spec.apiKey else { continue }
            let real = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if real.isEmpty { continue }
            switch spec.tool {
            case .claude:
                entries.append(.init(
                    realValue: real,
                    fakeValue: SessionTokenPlan.deriveFake(prefix: "sk-ant-api03-brm-",
                                                           real: real, salt: salt),
                    purpose: .anthropicAPIKey))
            case .codex:
                entries.append(.init(
                    realValue: real,
                    fakeValue: SessionTokenPlan.deriveFake(prefix: "sk-brm-",
                                                           real: real, salt: salt),
                    purpose: .openaiAPIKey))
            }
        }

        for entry in manualTokens where entry.isUsable {
            let real = entry.realValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if real.isEmpty { continue }
            entries.append(.init(
                realValue: real,
                fakeValue: SessionTokenPlan.deriveFake(prefix: "brm_",
                                                       real: real, salt: salt),
                purpose: .manual(name: entry.name,
                                 envVarName: entry.envVarName,
                                 hostFilter: entry.hostFilter)))
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
            entries.append(.init(
                realValue: real,
                fakeValue: SessionTokenPlan.deriveFake(prefix: prefix,
                                                       real: real, salt: salt,
                                                       targetLength: target),
                purpose: .gitHTTPS(host: cred.host, username: cred.username)))
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
