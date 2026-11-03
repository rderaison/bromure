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

    /// Why a lookup gave no verdict — said in the "unverified package"
    /// prompt instead of a blanket "couldn't reach socket.dev" (a refused
    /// key, a version socket.dev hasn't analysed yet and a network failure
    /// call for different answers).
    public enum Unavailable: Sendable, Equatable {
        /// No answer: the network, a timeout.
        case unreachable
        /// 401/403: the API key is wrong, revoked or lacks the scope.
        case keyRefused(status: Int)
        /// 429: socket.dev's quota.
        case rateLimited
        /// socket.dev is still analysing this version (`pendingScan`).
        case notAnalyzedYet
        /// socket.dev doesn't know this package or version (`notFound`,
        /// a non-retryable `purlError`).
        case unknownPackage
        /// Any other refusal or an unreadable reply.
        case failed(status: Int)

        static func from(status: Int) -> Unavailable {
            switch status {
            case 401, 403: return .keyRefused(status: status)
            case 429: return .rateLimited
            default: return .failed(status: status)
            }
        }

        /// The sentence after "Bromure couldn't vet <pkg>:".
        public var explanation: String {
            switch self {
            case .unreachable:
                return NSLocalizedString("socket.dev didn't answer.", comment: "supply chain: why a package has no verdict")
            case .keyRefused(let status):
                return String(format: NSLocalizedString("socket.dev refused the API key (HTTP %d) — check it in the workspace's Supply Chain settings.", comment: "supply chain: why a package has no verdict"), status)
            case .rateLimited:
                return NSLocalizedString("socket.dev is rate-limiting this API key.", comment: "supply chain: why a package has no verdict")
            case .notAnalyzedYet:
                return NSLocalizedString("socket.dev hasn't finished analysing this version yet.", comment: "supply chain: why a package has no verdict")
            case .unknownPackage:
                return NSLocalizedString("socket.dev doesn't know this version (it may be very new).", comment: "supply chain: why a package has no verdict")
            case .failed(let status):
                return status == 0
                    ? NSLocalizedString("socket.dev's reply couldn't be read.", comment: "supply chain: why a package has no verdict")
                    : String(format: NSLocalizedString("socket.dev answered HTTP %d.", comment: "supply chain: why a package has no verdict"), status)
            }
        }
    }

    private struct CacheKey: Hashable {
        let ecosystem: String
        let name: String
        let version: String
    }

    private var cache: [CacheKey: CheckResult] = [:]
    private static let cacheCap = 10_000

    // Cap concurrent in-flight calls to socket.dev. The number is a
    // balance: too low starves a big install graph (each tarball
    // waits for a slot, install becomes serial); too high triggers
    // socket.dev rate-limiting and timeouts. 16 keeps a 50-package
    // transitive graph moving without overwhelming the API.
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
        // Be generous on timeouts — socket.dev computes analysis
        // on-demand for less-popular packages on first lookup. A
        // stuck install is more disruptive than a slow check.
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        // We self-throttle to maxParallel above, so the URLSession's
        // per-host cap need not be high. Leave at the default.
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

    /// A socket.dev type that is a malware verdict, which the user can't
    /// override per package (everything else in the compromise bucket —
    /// install scripts, shell access, typosquat suspicions — they can).
    static func isMalwareVerdict(_ type: String) -> Bool { alwaysBlockTypes.contains(type) }

    /// The compromise issue a block reports: a malware verdict when there is
    /// one (it can't be overridden, so it must not hide behind an install-
    /// script alert that can), else the first.
    static func blockingIssue(_ compromised: [Issue]) -> Issue? {
        compromised.first(where: { isMalwareVerdict($0.type) }) ?? compromised.first
    }

    /// Sorts socket.dev's issues into the two buckets the proxy filters on.
    static func classify(_ issues: [Issue]) -> CheckResult {
        var compromised: [Issue] = []
        var vulns: [Issue] = []
        let highBar = Severity.high.rank
        for issue in issues {
            let type = issue.type
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
                      issue.severity.rank >= highBar {
                compromised.append(issue)
            }
        }
        return CheckResult(compromised: compromised, vulnerabilities: vulns)
    }

    public func check(ecosystem: String, name: String, version: String,
                      apiKey: String) async -> CheckResult? {
        try? await lookup(ecosystem: ecosystem, name: name, version: version, apiKey: apiKey).get()
    }

    /// The verdict, or why there is none.
    public func lookup(ecosystem: String, name: String, version: String,
                       apiKey: String) async -> Result<CheckResult, UnavailableError> {
        if apiKey.isEmpty { return .failure(.init(.keyRefused(status: 0))) }
        let key = CacheKey(ecosystem: ecosystem,
                            name: name.lowercased(),
                            version: version)
        if let cached = cache[key] { return .success(cached) }

        // Only npm has the per-package `issues` route: every other
        // ecosystem got "API route not found" (404), so every PyPI, Go,
        // Maven… install read as "couldn't reach socket.dev" and asked.
        // Those go through the package-URL lookup instead.
        if ecosystem != "npm" {
            guard let purl = Self.purl(ecosystem: ecosystem, name: name, version: version) else {
                return .failure(.init(.unknownPackage))
            }
            let r = await checkPURL(purl, label: "\(ecosystem)/\(name)@\(version)", apiKey: apiKey)
            if case .success(let result) = r { remember(key, result) }
            return r
        }
        guard let eco = Self.socketEcosystem(ecosystem) else { return .failure(.init(.unknownPackage)) }
        // URL-encode the package name (npm scoped packages contain
        // `/` which must be percent-encoded).
        guard let encName = name.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed)?
                .replacingOccurrences(of: "/", with: "%2F"),
              let encVer = version.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed)
        else { return .failure(.init(.unknownPackage)) }
        let urlStr = "https://api.socket.dev/v0/\(eco)/\(encName)/\(encVer)/issues"
        guard let url = URL(string: urlStr) else { return .failure(.init(.unknownPackage)) }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("bromure-ac/2.0", forHTTPHeaderField: "User-Agent")
        // Basic auth: key as username, empty password.
        let basic = "\(apiKey):".data(using: .utf8)!.base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        // Throttle: at most maxParallel checks in flight. Cache
        // hits above don't consume a slot.
        await acquireSlot()
        defer { releaseSlot() }

        SupplyChainLog.shared.record("[socket.dev] →  GET \(urlStr)")
        var response: (Data, URLResponse)?
        var lastError: Error?
        for attempt in 1...Self.maxRetries {
            do {
                response = try await session.data(for: req)
                lastError = nil
                break
            } catch {
                lastError = error
                // Only retry on transient network errors; surface
                // everything else (bad URL, cancelled, etc.) on the
                // first try.
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
                    "[socket.dev] ↻  \(ecosystem)/\(name)@\(version) — retry \(attempt)/\(Self.maxRetries - 1) after \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
            }
        }
        guard let response else {
            let msg = lastError?.localizedDescription ?? "unknown"
            SupplyChainLog.shared.record(
                "[socket.dev] ✗  \(ecosystem)/\(name)@\(version) — network error after retries: \(msg)")
            return .failure(.init(.unreachable))
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
            // npm's route answers 404 for a package (version) it doesn't know.
            return .failure(.init(status == 404 ? .unknownPackage : .from(status: status)))
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            SupplyChainLog.shared.record(
                "[socket.dev] ✗  \(ecosystem)/\(name)@\(version) — couldn't parse response JSON")
            return .failure(.init(.failed(status: 0)))
        }

        let result = Self.classify(arr.map { entry in
            let value = entry["value"] as? [String: Any]
            let type = (entry["type"] as? String) ?? ""
            return Issue(type: type,
                         severity: Severity.from(string: (value?["severity"] as? String) ?? "unknown"),
                         summary: (value?["description"] as? String) ?? type)
        })
        SupplyChainLog.shared.record(
            "[socket.dev] ✓  \(ecosystem)/\(name)@\(version) — \(result.compromised.count) compromise, \(result.vulnerabilities.count) CVE")
        remember(key, result)
        return .success(result)
    }

    /// `Unavailable` as an Error, for `Result`.
    public struct UnavailableError: Error, Sendable, Equatable {
        public let reason: Unavailable
        public init(_ reason: Unavailable) { self.reason = reason }
    }

    private func remember(_ key: CacheKey, _ result: CheckResult) {
        cache[key] = result
        if cache.count > Self.cacheCap {
            let toDrop = cache.count - Self.cacheCap
            for k in cache.keys.prefix(toDrop) {
                cache.removeValue(forKey: k)
            }
        }
    }

    // MARK: Package-URL lookup (every ecosystem but npm)

    /// The package URL socket.dev looks a package up by
    /// (`pkg:<type>/<namespace>/<name>@<version>`), from the names the
    /// proxy reads off registry URLs. nil: an ecosystem it doesn't cover.
    static func purl(ecosystem: String, name: String, version: String) -> String? {
        func enc(_ s: String) -> String? {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: ".-_~+")
            return s.addingPercentEncoding(withAllowedCharacters: allowed)
        }
        guard !name.isEmpty, !version.isEmpty, let v = enc(version) else { return nil }
        func path(_ parts: [String]) -> String? {
            let e = parts.compactMap(enc)
            return e.count == parts.count && !parts.contains(where: \.isEmpty) ? e.joined(separator: "/") : nil
        }
        let type: String, segments: [String]
        switch ecosystem {
        case "pypi":
            // PEP 503 normalization, as the PURL spec has it for PyPI.
            type = "pypi"
            segments = [name.lowercased().replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: ".", with: "-")]
        case "cargo":     type = "cargo"; segments = [name]
        case "rubygems":  type = "gem"; segments = [name]
        case "nuget":     type = "nuget"; segments = [name]
        case "maven":
            // "group:artifact" → group/artifact
            let ga = name.split(separator: ":", maxSplits: 1).map(String.init)
            guard ga.count == 2 else { return nil }
            type = "maven"; segments = ga
        case "packagist":
            let vn = name.split(separator: "/", maxSplits: 1).map(String.init)
            guard vn.count == 2 else { return nil }
            type = "composer"; segments = vn
        case "go":
            // proxy.golang.org case-encodes capitals ("!x" → "X"), and only
            // ASCII ones: "!" before anything but a-z (or at the end) isn't a
            // module path. Never `Character(ch.uppercased())` — the name is off
            // the guest's request line, and "ß" uppercases to "SS", two
            // characters, which traps (and took the host down with it).
            var module = ""
            var bang = false
            for ch in name {
                if bang {
                    guard ch.isASCII, ch.isLowercase else { return nil }
                    module += ch.uppercased()
                    bang = false
                } else if ch == "!" {
                    bang = true
                } else {
                    module.append(ch)
                }
            }
            guard !bang else { return nil }
            type = "golang"; segments = module.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { return nil }
        default:
            return nil
        }
        guard let p = path(segments) else { return nil }
        return "pkg:\(type)/\(p)@\(v)"
    }

    /// Org slugs, by API key: the org-scoped lookup is the current one;
    /// the plain /v0/purl is deprecated (still served).
    private var orgSlugs: [String: String?] = [:]

    private func orgSlug(apiKey: String) async -> String? {
        if let known = orgSlugs[apiKey] { return known }
        guard let url = URL(string: "https://api.socket.dev/v0/organizations") else { return nil }
        var req = URLRequest(url: url)
        Self.authorize(&req, apiKey: apiKey)
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let orgs = obj["organizations"] as? [String: Any] else {
            return nil   // not remembered: asked again next time
        }
        let slug = orgs.values.compactMap { ($0 as? [String: Any])?["slug"] as? String }.sorted().first
        orgSlugs[apiKey] = .some(slug)
        return slug
    }

    private static func authorize(_ req: inout URLRequest, apiKey: String) {
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("bromure-ac/2.0", forHTTPHeaderField: "User-Agent")
        // Basic auth: key as username, empty password.
        let basic = "\(apiKey):".data(using: .utf8)!.base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
    }

    /// One package by its package URL. Waits (poll) up to 20 s for an
    /// analysis socket.dev hasn't finished; one still pending is no
    /// verdict (nil), like a failed lookup.
    private func checkPURL(_ purl: String, label: String, apiKey: String) async -> Result<CheckResult, UnavailableError> {
        await acquireSlot()
        defer { releaseSlot() }
        let query = "alerts=true&compact=true&poll=true&timeoutSec=20"
        var endpoints: [String] = []
        if let slug = await orgSlug(apiKey: apiKey),
           let s = slug.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_."))) {
            endpoints.append("https://api.socket.dev/v0/orgs/\(s)/purl?\(query)")
        }
        endpoints.append("https://api.socket.dev/v0/purl?\(query)")
        let body = (try? JSONSerialization.data(withJSONObject: ["components": [["purl": purl]]])) ?? Data()
        var lastFailure = Unavailable.unreachable
        for (i, urlStr) in endpoints.enumerated() {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            Self.authorize(&req, apiKey: apiKey)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
            req.httpBody = body
            req.timeoutInterval = 45
            SupplyChainLog.shared.record("[socket.dev] →  POST \(urlStr) \(purl)")
            var response: (Data, URLResponse)?
            for attempt in 1...Self.maxRetries {
                do { response = try await session.data(for: req); break }
                catch {
                    let code = (error as? URLError)?.code
                    let retriable = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                     .dnsLookupFailed, .resourceUnavailable].contains(code)
                    if !retriable || attempt == Self.maxRetries {
                        SupplyChainLog.shared.record("[socket.dev] ✗  \(label) — network error: \(error.localizedDescription)")
                        break
                    }
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
                }
            }
            guard let (data, resp) = response else { return .failure(.init(.unreachable)) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? ""
                SupplyChainLog.shared.record("[socket.dev] ✗  \(label) — HTTP \(status): \(bodyPreview)")
                lastFailure = .from(status: status)
                // The org-scoped route refused (scope, plan): the plain one.
                if i < endpoints.count - 1, [401, 403, 404].contains(status) { continue }
                return .failure(.init(lastFailure))
            }
            switch Self.parsePURLOutcome(data, purl: purl) {
            case .success(let result):
                SupplyChainLog.shared.record(
                    "[socket.dev] ✓  \(label) — \(result.compromised.count) compromise, \(result.vulnerabilities.count) CVE")
                return .success(result)
            case .failure(let why):
                SupplyChainLog.shared.record("[socket.dev] ✗  \(label) — no verdict: \(why.reason.explanation)")
                return .failure(why)
            }
        }
        return .failure(.init(lastFailure))
    }

    /// Alerts that mean socket.dev has no verdict on the package: an
    /// analysis still under way, or a package it can't resolve (a new
    /// upload, a name it doesn't know). Read as clean, such a package was
    /// let through — and remembered so for the rest of the run.
    static let noVerdictAlerts: Set<String> = ["pendingScan", "notFound"]

    /// The /purl response (NDJSON: artifacts, purlError, summary lines;
    /// a JSON array of the same is read too): the verdict for the one
    /// package asked about, or nil (an error line, no artifact, or a
    /// no-verdict alert).
    static func parsePURLResponse(_ data: Data, purl: String) -> CheckResult? {
        try? parsePURLOutcome(data, purl: purl).get()
    }

    /// `parsePURLResponse`, with why there is no verdict.
    static func parsePURLOutcome(_ data: Data, purl: String) -> Result<CheckResult, UnavailableError> {
        var objects: [[String: Any]] = []
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            objects = arr
        } else {
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                    objects.append(obj)
                }
            }
        }
        var why = Unavailable.failed(status: 0)
        for obj in objects {
            if obj["_type"] as? String == "purlError" {
                // A retryable one is socket.dev still working on it.
                let retryable = ((obj["value"] as? [String: Any])?["retryable"] as? Bool) ?? false
                why = retryable ? .notAnalyzedYet : .unknownPackage
                continue
            }
            guard obj["_type"] == nil,   // summary lines
                  obj["name"] != nil || obj["inputPurl"] != nil else { continue }
            let alerts = (obj["alerts"] as? [[String: Any]]) ?? []
            let types = Set(alerts.compactMap { $0["type"] as? String })
            if types.contains("pendingScan") { return .failure(.init(.notAnalyzedYet)) }
            if types.contains("notFound") { return .failure(.init(.unknownPackage)) }
            return .success(classify(alerts.map { a in
                let type = (a["type"] as? String) ?? ""
                let props = a["props"] as? [String: Any]
                let summary = (props?["title"] as? String) ?? (props?["description"] as? String)
                    ?? (props?["cveId"] as? String) ?? type
                return Issue(type: type, severity: Severity.from(string: (a["severity"] as? String) ?? "unknown"),
                             summary: summary)
            }))
        }
        return .failure(.init(why))
    }
}
