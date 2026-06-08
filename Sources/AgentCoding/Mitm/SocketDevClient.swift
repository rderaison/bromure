import Foundation

/// Thin client for socket.dev's REST API. Looks up package issues
/// keyed by (ecosystem, package, version) and reports two distinct
/// categories the proxy filters on:
///   - `supplyChainRisk`: rogue install scripts, malware-flagged,
///     typosquats, suspicious telemetry, sketchy network access at
///     install time.
///   - `vulnerability`: known CVEs / GHSAs.
///
/// API authentication: HTTP Basic auth with the API key as the
/// username and an empty password (socket.dev's documented scheme
/// for the REST API).
public actor SocketDevClient {
    public enum Severity: String, Sendable {
        case low, middle, high, critical, unknown

        public static func from(string s: String) -> Severity {
            switch s.lowercased() {
            case "low":      return .low
            case "middle", "medium": return .middle
            case "high":     return .high
            case "critical": return .critical
            default:         return .unknown
            }
        }

        public var rank: Int {
            switch self {
            case .low:      return 0
            case .middle:   return 1
            case .high:     return 2
            case .critical: return 3
            case .unknown:  return -1
            }
        }
    }

    public struct Issue: Sendable {
        public let type: String      // socket.dev category identifier
        public let severity: Severity
        public let summary: String   // short human-readable
    }

    public struct CheckResult: Sendable {
        public let compromised: [Issue]   // supplyChainRisk bucket
        public let vulnerabilities: [Issue]  // CVE bucket
    }

    private struct CacheKey: Hashable {
        let ecosystem: String
        let name: String
        let version: String
    }

    private var cache: [CacheKey: CheckResult] = [:]
    private static let cacheCap = 10_000

    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
    }

    /// socket.dev path component for an ecosystem; nil = unsupported.
    public static func socketEcosystem(_ e: String) -> String? {
        switch e {
        case "npm":       return "npm"
        case "pypi":      return "pypi"
        case "go":        return "golang"
        case "maven":     return "maven"
        case "rubygems":  return "rubygems"
        case "nuget":     return "nuget"
        case "packagist": return "packagist"
        default:          return nil
        }
    }

    /// socket.dev issue types that we treat as definitively
    /// malicious — block on any severity. These are the named
    /// "this thing is bad" signals, not quality/attribute metadata.
    private static let alwaysBlockTypes: Set<String> = [
        "malware",
        "knownMalware",
        "gptMalware",
        "troll",
        "compromisedSSHKey",
    ]

    /// socket.dev issue types that smell like an attack but also
    /// fire on legitimate packages at low/middle severity. We block
    /// only when socket.dev itself rates them high or critical.
    /// Example: `installScripts` fires on every package with a
    /// postinstall hook (severity low/middle); a *suspicious*
    /// postinstall is rated high.
    private static let highSeverityBlockTypes: Set<String> = [
        "obfuscatedFile",
        "obfuscatedRequire",
        "suspiciousString",
        "installScripts",
        "gptSecurity",
        "typeSquatting",
        "didYouMean",
        "shellAccess",
        "unusualHTTPS",
        "criticalCVE",
    ]

    /// Issue types we deliberately do NOT treat as compromise
    /// signals, even though socket.dev classifies them under
    /// "supplyChainRisk". Listed for documentation; the loop below
    /// drops anything not in the two sets above.
    ///   newAuthor, envVars, networkAccess, filesystemAccess,
    ///   telemetry, unstableOwnership, newAuthor, deprecated,
    ///   suspiciousStarActivity, hasNativeCode,
    ///   potentialVulnerability
    /// These describe what a package does or who publishes it —
    /// signal for human review, not a programmatic block.

    /// Issue-type prefixes that socket.dev classifies as known CVE.
    private static let cveTypes: Set<String> = [
        "cve", "highCVE", "mediumCVE", "lowCVE", "criticalCVE",
        "vulnerableDependency",
    ]

    public func check(ecosystem: String, name: String, version: String,
                      apiKey: String) async -> CheckResult? {
        if apiKey.isEmpty { return nil }
        let key = CacheKey(ecosystem: ecosystem,
                            name: name.lowercased(),
                            version: version)
        if let cached = cache[key] { return cached }

        guard let eco = Self.socketEcosystem(ecosystem) else { return nil }
        // URL-encode the package name (npm scoped packages contain
        // `/` which must be percent-encoded).
        guard let encName = name.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed)?
                .replacingOccurrences(of: "/", with: "%2F"),
              let encVer = version.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        let urlStr = "https://api.socket.dev/v0/\(eco)/\(encName)/\(encVer)/issues"
        guard let url = URL(string: urlStr) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("bromure-ac/2.0", forHTTPHeaderField: "User-Agent")
        // Basic auth: key as username, empty password.
        let basic = "\(apiKey):".data(using: .utf8)!.base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        SupplyChainLog.shared.record("[socket.dev] →  GET \(urlStr)")
        let response: (Data, URLResponse)
        do {
            response = try await session.data(for: req)
        } catch {
            SupplyChainLog.shared.record(
                "[socket.dev] ✗  \(ecosystem)/\(name)@\(version) — network error: \(error.localizedDescription)")
            return nil
        }
        let (data, resp) = response
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status != 200 {
            // Surface auth errors etc. explicitly so a typo'd API
            // key doesn't fail silently. socket.dev returns JSON
            // error bodies for auth failures; include the first
            // 200 bytes of the body for the user to copy.
            let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            SupplyChainLog.shared.record(
                "[socket.dev] ✗  \(ecosystem)/\(name)@\(version) — HTTP \(status): \(bodyPreview)")
            return nil
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            SupplyChainLog.shared.record(
                "[socket.dev] ✗  \(ecosystem)/\(name)@\(version) — couldn't parse response JSON")
            return nil
        }

        var compromised: [Issue] = []
        var vulns: [Issue] = []
        let highBar = Severity.high.rank
        for entry in arr {
            let type = (entry["type"] as? String) ?? ""
            let summary = ((entry["value"] as? [String: Any])?["description"] as? String)
                ?? type
            let sevStr = ((entry["value"] as? [String: Any])?["severity"] as? String)
                ?? "unknown"
            let severity = Severity.from(string: sevStr)
            let issue = Issue(type: type, severity: severity, summary: summary)
            // CVE bucket: anything in cveTypes OR a string match on
            // "cve" — the CVE check applies its own severity gate.
            if Self.cveTypes.contains(type) || type.lowercased().contains("cve") {
                vulns.append(issue)
                continue
            }
            // Compromise bucket: only fires for actual attack-shaped
            // types. Quality/attribute signals (newAuthor, envVars,
            // networkAccess, filesystemAccess, …) deliberately don't
            // count, since they describe what most legitimate
            // packages do.
            if Self.alwaysBlockTypes.contains(type) {
                compromised.append(issue)
            } else if Self.highSeverityBlockTypes.contains(type),
                      severity.rank >= highBar {
                compromised.append(issue)
            }
        }

        let result = CheckResult(compromised: compromised, vulnerabilities: vulns)
        SupplyChainLog.shared.record(
            "[socket.dev] ✓  \(ecosystem)/\(name)@\(version) — \(compromised.count) compromise, \(vulns.count) CVE")
        cache[key] = result
        if cache.count > Self.cacheCap {
            let toDrop = cache.count - Self.cacheCap
            for k in cache.keys.prefix(toDrop) {
                cache.removeValue(forKey: k)
            }
        }
        return result
    }
}
