import CryptoKit
import Foundation

/// How a credential is named anywhere it's recorded — the app log, the
/// Security Timeline (and its CSV export), trace records: its kind plus a
/// short keyed fingerprint ("Anthropic key #3f9a1c2e"). Never any of its
/// characters: the old "first 4 … last 4" previews put 8 characters of every
/// real secret in plaintext on disk.
///
/// The fingerprint is an HMAC-SHA256 under a per-install key, truncated to 32
/// bits: stable (the same credential reads the same everywhere, so rows still
/// coalesce and can be correlated) but useless for recovering or confirming
/// the secret off this Mac.
enum SecretFingerprint {
    /// "Anthropic key #3f9a1c2e".
    static func label(_ secret: String) -> String {
        "\(kind(of: secret)) #\(fingerprint(secret))"
    }

    /// 8 hex characters of HMAC-SHA256(per-install key, secret).
    static func fingerprint(_ secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(secret.utf8), using: key)
        return mac.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The credential's kind, from its PUBLIC scheme prefix only (the part
    /// every key of that provider shares).
    static func kind(of secret: String) -> String {
        for (prefix, name) in kinds where secret.hasPrefix(prefix) { return name }
        return "credential"
    }

    private static let kinds: [(String, String)] = [
        ("brm_", "stand-in"), ("bromure-", "stand-in"),
        ("sk-ant-oat", "Claude subscription token"), ("sk-ant-", "Anthropic key"),
        ("sk-proj-", "OpenAI key"), ("sk-svcacct-", "OpenAI key"), ("sk-or-", "OpenRouter key"),
        ("xai-", "xAI key"), ("gsk_", "Groq key"), ("AIza", "Google API key"),
        ("ghp_", "GitHub token"), ("gho_", "GitHub token"), ("ghu_", "GitHub token"),
        ("ghs_", "GitHub token"), ("github_pat_", "GitHub token"), ("glpat-", "GitLab token"),
        ("xoxb-", "Slack token"), ("xoxp-", "Slack token"), ("xapp-", "Slack token"),
        ("AKIA", "AWS access key"), ("ASIA", "AWS session key"),
        ("dop_v1_", "DigitalOcean token"), ("npm_", "npm token"), ("pypi-", "PyPI token"),
        ("hf_", "Hugging Face token"), ("eyJ", "JWT"), ("sk-", "API key"),
    ]

    // MARK: Key

    private static let key: SymmetricKey = {
        let testing = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if testing { return SymmetricKey(size: .bits256) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC", isDirectory: true)
        let file = dir.appendingPathComponent("fingerprint.key")
        if let d = try? Data(contentsOf: file), d.count == 32 { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        let d = k.withUnsafeBytes { Data($0) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: file.path, contents: d, attributes: [.posixPermissions: 0o600])
        return k
    }()

    // MARK: Legacy redaction

    /// "sk-a…kUyU"-style previews written before fingerprints: up to 8 chars,
    /// an ellipsis, 3–8 chars, as one token.
    private static let legacyPreview = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_\-])([A-Za-z0-9_\-]{2,8})…([A-Za-z0-9_\-]{3,8})(?![A-Za-z0-9_\-])"#)

    /// Replace legacy secret previews in `text` with their kind and
    /// "(redacted)". The full secret is gone, so no fingerprint can be
    /// computed; the kind comes from the public prefix that survived.
    static func redactLegacy(_ text: String) -> String {
        guard text.contains("…") else { return text }
        let ns = text as NSString
        let matches = legacyPreview.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for m in matches.reversed() {
            let head = ns.substring(with: m.range(at: 1))
            out.replaceCharacters(in: m.range, with: "\(legacyKind(head)) (redacted)")
        }
        return out as String
    }

    private static func legacyKind(_ head: String) -> String {
        // The surviving head is ≤ 4 chars of the prefix: match providers whose
        // scheme starts with it.
        let heads: [String: String] = ["sk-a": "Anthropic key", "sk-p": "OpenAI key", "sk-o": "OpenRouter key",
                                       "xai-": "xAI key", "brm_": "stand-in", "ghp_": "GitHub token",
                                       "gith": "GitHub token", "glpa": "GitLab token", "AKIA": "AWS access key",
                                       "ASIA": "AWS session key", "xoxb": "Slack token", "AIza": "Google API key"]
        if let k = heads[String(head.prefix(4))] { return k }
        for (prefix, name) in kinds where prefix.hasPrefix(head) || head.hasPrefix(prefix) { return name }
        return "credential"
    }
}
