import Foundation

/// Thin client for `api.osv.dev/v1/query`. One POST per
/// (ecosystem, package, version); results cached in-memory keyed by
/// the same tuple. OSV's database is updated continuously but for
/// a given (pkg, version) the set of advisories that ever applied
/// only grows — so caching the most recent answer for a few hours
/// is safe.
public actor OSVClient {
    public enum Severity: String, Sendable {
        case low, medium, high, critical, unknown

        public var rank: Int {
            switch self {
            case .low:      return 0
            case .medium:   return 1
            case .high:     return 2
            case .critical: return 3
            case .unknown:  return -1   // treat as "best-effort" only
            }
        }

        /// Map an OSV severity entry to our enum. OSV gives us
        /// CVSS vectors and the GHSA-style label; we parse the
        /// label first (cheaper), then fall back to the CVSS base
        /// score if present.
        static func fromOSV(_ severities: [[String: Any]]?,
                            ghsaSeverityLabel: String?) -> Severity {
            // GHSA label is the most reliable signal when present.
            if let label = ghsaSeverityLabel?.uppercased() {
                switch label {
                case "LOW":      return .low
                case "MODERATE", "MEDIUM": return .medium
                case "HIGH":     return .high
                case "CRITICAL": return .critical
                default: break
                }
            }
            // Fall back to highest CVSS base score across the
            // severities array.
            guard let arr = severities else { return .unknown }
            var maxScore: Double = 0
            for entry in arr {
                if let v = entry["score"] as? String,
                   let dot = v.lastIndex(of: "/") {
                    // CVSS vector format — pluck the BaseScore by
                    // computing from the vector is complex; fall
                    // back to parsing a literal number if present.
                    let _ = dot
                }
                if let s = entry["score"] as? Double {
                    maxScore = max(maxScore, s)
                }
            }
            switch maxScore {
            case 0..<0.1:   return .unknown
            case 0.1..<4.0: return .low
            case 4.0..<7.0: return .medium
            case 7.0..<9.0: return .high
            default:        return .critical
            }
        }
    }

    public struct Vulnerability: Sendable {
        public let id: String        // CVE-… or GHSA-…
        public let summary: String   // one-line description
        public let severity: Severity
    }

    public struct CheckResult: Sendable {
        public let vulnerabilities: [Vulnerability]
        public var isClean: Bool { vulnerabilities.isEmpty }
    }

    private struct CacheKey: Hashable {
        let ecosystem: String
        let name: String
        let version: String
    }

    private var cache: [CacheKey: CheckResult] = [:]
    private static let cacheCap = 10_000

    // Same self-throttle as SocketDevClient: cap parallel API calls
    // so a big install fan-out doesn't trip OSV's rate limits. 16 is
    // the balance between throughput on a big install graph and not
    // overwhelming the API.
    private static let maxParallel = 16
    /// Total attempts (initial + retries) on transient network
    /// errors. Linear backoff between attempts.
    private static let maxRetries = 5
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquireSlot() async {
        while inFlight >= Self.maxParallel {
            await withCheckedContinuation { c in
                waiters.append(c)
            }
        }
        inFlight += 1
    }

    private func releaseSlot() {
        inFlight -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }

    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        // Match SocketDevClient's window — same reasoning, OSV's
        // per-package POST is generally faster but a big install
        // fan-out can still trip tighter limits.
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        // Self-throttling above keeps in-flight calls small; no
        // need to override the URLSession default.
        self.session = URLSession(configuration: cfg)
    }

    /// Map our internal ecosystem string to OSV's ecosystem name.
    /// OSV's ecosystem strings are case-sensitive.
    public static func osvEcosystem(_ e: String) -> String? {
        switch e {
        case "npm":       return "npm"
        case "pypi":      return "PyPI"
        case "cargo":     return "crates.io"
        case "rubygems":  return "RubyGems"
        case "maven":     return "Maven"
        case "nuget":     return "NuGet"
        case "go":        return "Go"
        case "packagist": return "Packagist"
        default:          return nil
        }
    }

    public func check(ecosystem: String, name: String, version: String)
            async -> CheckResult? {
        let key = CacheKey(ecosystem: ecosystem,
                            name: name.lowercased(),
                            version: version)
        if let cached = cache[key] { return cached }

        guard let osvEco = Self.osvEcosystem(ecosystem) else { return nil }
        let body: [String: Any] = [
            "package": ["name": name, "ecosystem": osvEco],
            "version": version,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        var req = URLRequest(url: URL(string: "https://api.osv.dev/v1/query")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("bromure-ac/2.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = bodyData

        // Throttle: at most maxParallel checks in flight. Cache
        // hits above don't consume a slot.
        await acquireSlot()
        defer { releaseSlot() }

        SupplyChainLog.shared.record(
            "[osv] →  POST \(osvEco)/\(name)@\(version)")
        var response: (Data, URLResponse)?
        var lastError: Error?
        for attempt in 1...Self.maxRetries {
            do {
                response = try await session.data(for: req)
                lastError = nil
                break
            } catch {
                lastError = error
                let urlErr = error as? URLError
                let retriable: Bool = {
                    guard let urlErr else { return false }
                    switch urlErr.code {
                    case .timedOut, .networkConnectionLost,
                         .cannotConnectToHost, .dnsLookupFailed,
                         .resourceUnavailable:
                        return true
                    default:
                        return false
                    }
                }()
                if !retriable || attempt == Self.maxRetries { break }
                SupplyChainLog.shared.record(
                    "[osv] ↻  \(ecosystem)/\(name)@\(version) — retry \(attempt)/\(Self.maxRetries - 1) after \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
            }
        }
        guard let response else {
            let msg = lastError?.localizedDescription ?? "unknown"
            SupplyChainLog.shared.record(
                "[osv] ✗  \(ecosystem)/\(name)@\(version) — network error after retries: \(msg)")
            return nil
        }
        let (data, resp) = response
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            SupplyChainLog.shared.record(
                "[osv] ✗  \(ecosystem)/\(name)@\(version) — HTTP \(status): \(bodyPreview)")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            SupplyChainLog.shared.record(
                "[osv] ✗  \(ecosystem)/\(name)@\(version) — couldn't parse response JSON")
            return nil
        }

        let rawVulns = (json["vulns"] as? [[String: Any]]) ?? []
        let parsed: [Vulnerability] = rawVulns.compactMap { v in
            let id = (v["id"] as? String) ?? ""
            let summary = (v["summary"] as? String) ?? id
            let ghsaLabel = (v["database_specific"] as? [String: Any])?["severity"] as? String
            let sev = Severity.fromOSV(v["severity"] as? [[String: Any]],
                                        ghsaSeverityLabel: ghsaLabel)
            if id.isEmpty { return nil }
            return Vulnerability(id: id, summary: summary, severity: sev)
        }

        let result = CheckResult(vulnerabilities: parsed)
        SupplyChainLog.shared.record(
            "[osv] ✓  \(ecosystem)/\(name)@\(version) — \(parsed.count) vuln")
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
