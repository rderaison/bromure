import Foundation
import CryptoKit

/// Strict credential mode ("only credentials Bromure injected"): blocks an
/// outbound request that carries a credential Bromure didn't put there — a
/// token the agent found in a file, an env dump, a git config, or guessed.
///
/// The swap path already guarantees Bromure's own credentials only reach
/// their bound hosts (and `detectCompromise` catches a fake heading
/// elsewhere). This closes the other half: a REAL secret in the guest never
/// goes through the swap map at all, so without this it leaves unnoticed.
///
/// A secret in an outbound request is allowed when it is:
///  - a Bromure fake (swapped or leak-checked by `TokenSwapper`),
///  - the workspace's own AWS access key id in a SigV4 header (the resigner
///    replaces the signature; the guest only ever holds a fake secret),
///  - issued to the guest by the same site earlier in the session
///    (`Set-Cookie`, or an `access_token` / `refresh_token` / `id_token` /
///    `token` field in a response) — logins inside the VM keep working,
///  - approved for this session from the alert.
/// Everything else is reported (and, while strict mode is on, blocked).
public final class UnmanagedCredentialGuard: @unchecked Sendable {
    public static let shared = UnmanagedCredentialGuard()

    public struct Finding: Sendable, Equatable {
        /// What kind of secret (`github-token`, `aws-access-key`, `bearer`…).
        public let kind: String
        /// Where in the request (`header authorization`, `query api_key`, `body`).
        public let location: String
        /// SHA-256 prefix of the secret — the identity used for allowlisting;
        /// the secret itself is never stored or logged.
        public let fingerprint: String
        /// First 4 + last 4 characters.
        public let preview: String
    }

    private let lock = NSLock()
    private var enabled: Set<UUID> = []
    /// Fingerprints of secrets a site issued to the guest, per registrable domain.
    private var issued: [UUID: [String: Set<String>]] = [:]
    private var sessionAllowed: [UUID: Set<String>] = [:]
    private static let issuedCap = 4096

    public func setEnabled(_ on: Bool, for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        if on { enabled.insert(profileID) } else { enabled.remove(profileID) }
    }

    public func isEnabled(for profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled.contains(profileID)
    }

    /// Forget a session's learned tokens and approvals (VM teardown).
    public func reset(profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        issued[profileID] = nil
        sessionAllowed[profileID] = nil
    }

    public func allowForSession(_ fingerprints: [String], profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        sessionAllowed[profileID, default: []].formUnion(fingerprints)
    }

    /// Unmanaged credentials in a guest request bound for `host`. Empty when
    /// strict mode is off for the workspace.
    public func check(rawRequest: Data, host: String, profileID: UUID,
                      fakes: [String], awsAccessKeyID: String?,
                      isPlaceholder: (String) -> Bool = { _ in false }) -> [Finding] {
        guard isEnabled(for: profileID) else { return [] }
        let findings = Self.scan(rawRequest: rawRequest, excluding: fakes, isPlaceholder: isPlaceholder)
        guard !findings.isEmpty else { return [] }
        let domain = Self.registrableDomain(host)
        lock.lock()
        let issuedHere = issued[profileID]?[domain] ?? []
        let approved = sessionAllowed[profileID] ?? []
        lock.unlock()
        return findings.filter { f in
            if issuedHere.contains(f.fingerprint) || approved.contains(f.fingerprint) { return false }
            if f.kind == "aws-access-key", let own = awsAccessKeyID, f.fingerprint == Self.fingerprint(own) {
                return false
            }
            return true
        }
    }

    /// Learn secrets a site hands the guest, from a relayed response
    /// (header section + as much body as was buffered).
    public func learn(response: Data, host: String, profileID: UUID) {
        guard isEnabled(for: profileID), !response.isEmpty else { return }
        let fps = Self.issuedSecrets(in: response).map(Self.fingerprint)
        guard !fps.isEmpty else { return }
        let domain = Self.registrableDomain(host)
        lock.lock(); defer { lock.unlock() }
        var byDomain = issued[profileID] ?? [:]
        var set = byDomain[domain] ?? []
        if set.count > Self.issuedCap { set.removeAll() }
        set.formUnion(fps)
        byDomain[domain] = set
        issued[profileID] = byDomain
    }

    // MARK: - Scanning

    /// Known credential formats (gitleaks-style). Matched anywhere in the
    /// request: headers, target, and the first 256 KiB of the body.
    static let patterns: [(kind: String, regex: NSRegularExpression)] = [
        ("github-token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"#),
        ("github-token", #"\bgithub_pat_[A-Za-z0-9_]{60,}\b"#),
        ("gitlab-token", #"\bglpat-[A-Za-z0-9_\-]{20,}\b"#),
        ("anthropic-key", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
        ("openai-key", #"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{32,}"#),
        ("xai-key", #"\bxai-[A-Za-z0-9]{40,}\b"#),
        ("aws-access-key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("slack-token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
        ("digitalocean-token", #"\bdo[pro]_v1_[a-f0-9]{64}\b"#),
        ("linear-key", #"\blin_api_[A-Za-z0-9]{40}\b"#),
        ("google-api-key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        ("huggingface-token", #"\bhf_[A-Za-z0-9]{30,}\b"#),
        ("npm-token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
        ("pypi-token", #"\bpypi-AgEIcHlwaS5vcmc[A-Za-z0-9_\-]{50,}"#),
        ("stripe-key", #"\b(?:sk|rk)_live_[0-9A-Za-z]{24,}\b"#),
        ("sendgrid-key", #"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"#),
        ("twilio-key", #"\bSK[0-9a-f]{32}\b"#),
        ("private-key", #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"#),
        ("jwt", #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// Headers whose whole value is a credential (any high-entropy value counts).
    static let credentialHeaders: Set<String> = [
        "authorization", "proxy-authorization", "x-api-key", "api-key", "x-auth-token",
        "private-token", "x-goog-api-key", "x-access-token", "x-amz-security-token",
        "anthropic-api-key", "openai-api-key", "x-functions-key", "ocp-apim-subscription-key",
    ]
    /// Query parameters that carry credentials.
    static let credentialParams: Set<String> = [
        "api_key", "apikey", "key", "token", "access_token", "auth", "auth_token",
        "private_token", "client_secret", "secret", "password", "sig", "x-amz-security-token",
    ]

    /// Every credential-looking value in a request. A value containing one
    /// of `fakes` (a Bromure stand-in, possibly wrapped, e.g. `Basic` user:fake)
    /// is Bromure's own and skipped, as is a host-minted subscription
    /// placeholder (`isPlaceholder`).
    static func scan(rawRequest: Data, excluding fakes: [String] = [],
                     isPlaceholder: (String) -> Bool = { _ in false }) -> [Finding] {
        let headerEnd = rawRequest.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? rawRequest.endIndex
        let head = String(decoding: rawRequest[rawRequest.startIndex..<headerEnd], as: UTF8.self)
        let bodyStart = min(headerEnd + 4, rawRequest.endIndex)
        let bodyEnd = min(bodyStart + 256 * 1024, rawRequest.endIndex)
        let body = String(decoding: rawRequest[bodyStart..<bodyEnd], as: UTF8.self)

        var out: [Finding] = []
        var seen = Set<String>()
        func add(_ kind: String, _ location: String, _ secret: String) {
            let s = secret.trimmingCharacters(in: .whitespaces)
            guard s.count >= 8, !fakes.contains(where: { !$0.isEmpty && s.contains($0) }),
                  !isPlaceholder(s) else { return }
            let fp = fingerprint(s)
            guard seen.insert(fp).inserted else { return }
            out.append(Finding(kind: kind, location: location, fingerprint: fp, preview: preview(s)))
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        // Query parameters on the request target.
        let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        if let q = target.firstIndex(of: "?") {
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let key = (String(kv[0]).removingPercentEncoding ?? String(kv[0])).lowercased()
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                if credentialParams.contains(key), looksSecret(value) {
                    add(knownKind(value) ?? "api-key", "query \(key)", value)
                }
            }
        }
        // Headers.
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "authorization" || name == "proxy-authorization" {
                let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
                let scheme = parts.first?.lowercased() ?? ""
                let cred = parts.count > 1 ? parts[1] : value
                switch scheme {
                case "aws4-hmac-sha256":
                    if let r = cred.range(of: #"Credential=([A-Z0-9]{16,128})/"#, options: .regularExpression) {
                        let akid = cred[r].dropFirst("Credential=".count).dropLast()
                        add("aws-access-key", "header \(name)", String(akid))
                    }
                case "basic":
                    if let d = Data(base64Encoded: cred), let pair = String(data: d, encoding: .utf8),
                       let c = pair.firstIndex(of: ":") {
                        let pass = String(pair[pair.index(after: c)...])
                        if looksSecret(pass) { add(knownKind(pass) ?? "basic-password", "header \(name)", pass) }
                    }
                default:
                    if looksSecret(cred) { add(knownKind(cred) ?? "bearer", "header \(name)", cred) }
                }
                continue
            }
            if credentialHeaders.contains(name) {
                if looksSecret(value) { add(knownKind(value) ?? "api-key", "header \(name)", value) }
                continue
            }
            for (kind, re) in patterns {
                for m in re.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                    if let r = Range(m.range, in: value) { add(kind, "header \(name)", String(value[r])) }
                }
            }
        }
        // Known formats anywhere else in the target or body.
        for (text, location) in [(target, "target"), (body, "body")] where !text.isEmpty {
            for (kind, re) in patterns {
                for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let r = Range(m.range, in: text) { add(kind, location, String(text[r])) }
                }
            }
        }
        return out
    }

    static func knownKind(_ s: String) -> String? {
        patterns.first { $0.regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }?.kind
    }

    /// A value that plausibly is a secret: long enough and random-looking.
    static func looksSecret(_ s: String) -> Bool {
        if knownKind(s) != nil { return true }
        guard s.count >= 20, !s.contains(" ") else { return false }
        return entropy(s) >= 3.5
    }

    static func entropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }

    /// Secrets a response hands the client: cookie values and token-shaped
    /// JSON / form fields.
    static func issuedSecrets(in response: Data) -> [String] {
        let headerEnd = response.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? response.endIndex
        let head = String(decoding: response[response.startIndex..<headerEnd], as: UTF8.self)
        var out: [String] = []
        for line in head.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "set-cookie" else { continue }
            let cookie = line[line.index(after: colon)...].split(separator: ";").first ?? ""
            if let eq = cookie.firstIndex(of: "=") {
                out.append(String(cookie[cookie.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        let bodyStart = min(headerEnd + 4, response.endIndex)
        let body = response[bodyStart..<min(bodyStart + 256 * 1024, response.endIndex)]
        if let obj = try? JSONSerialization.jsonObject(with: body) {
            collectTokens(obj, into: &out)
        } else {
            // application/x-www-form-urlencoded (GitHub's device flow).
            for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, tokenFieldNames.contains(String(kv[0])) {
                    out.append(String(kv[1]).removingPercentEncoding ?? String(kv[1]))
                }
            }
        }
        return out.filter { $0.count >= 8 }
    }

    private static let tokenFieldNames: Set<String> = [
        "access_token", "refresh_token", "id_token", "token", "api_key", "session_token", "sessionToken",
        "accessToken", "refreshToken", "idToken", "SessionToken", "AccessKeyId",
    ]

    private static func collectTokens(_ obj: Any, into out: inout [String], depth: Int = 0) {
        guard depth < 6 else { return }
        if let d = obj as? [String: Any] {
            for (k, v) in d {
                if tokenFieldNames.contains(k), let s = v as? String { out.append(s) }
                else { collectTokens(v, into: &out, depth: depth + 1) }
            }
        } else if let a = obj as? [Any] {
            for v in a.prefix(64) { collectTokens(v, into: &out, depth: depth + 1) }
        }
    }

    static func fingerprint(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func preview(_ s: String) -> String {
        s.count > 12 ? "\(s.prefix(4))…\(s.suffix(4))" : "***"
    }

    /// Registrable domain: the last two labels, or three under a two-part
    /// public suffix (`co.uk`, `com.au`, …). Good enough to scope "issued by
    /// this site"; not a full public-suffix list.
    static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let twoPart: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au",
                                    "co.jp", "ne.jp", "or.jp", "co.nz", "com.br", "com.cn", "com.mx",
                                    "co.in", "co.kr", "com.sg", "com.tw", "co.za", "com.tr"]
        return twoPart.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }
}
