import Foundation

/// Guardrails: strips destructive operations from the protocols the agent
/// speaks, enforced **host-side in the MITM** so a misbehaving (or compromised)
/// agent in the VM can't bypass it. Per-profile; surfaced in the Settings
/// "Guardrails" panel.
///
/// Kubernetes is the first protocol: kubectl/client-go honor `HTTPS_PROXY`, so
/// the kube API already flows through the MITM as TLS-terminated REST, and
/// destructive operations map onto HTTP methods (DELETE = destructive; any
/// non-GET = a write). Databases (Postgres, MySQL, …) come later via a
/// separate protocol-aware proxy but reuse this same policy/mode model.
public struct GuardrailsPolicy: Codable, Equatable, Sendable {
    /// How aggressively to filter a protocol's mutating operations.
    /// The cases are listed in the order they should appear in the
    /// settings picker (least to most automation, with `.promptOnWrite`
    /// the default for new profiles).
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// No filtering — traffic passes through untouched.
        case off
        /// Reads pass through; any write (destructive or otherwise)
        /// triggers a host-side modal asking the user to allow or
        /// deny *that specific write*. The dialog shows the exact
        /// query / verb / resource, with timer options (Allow once /
        /// 15 min / for the session). Default for new profiles.
        case promptOnWrite
        /// Block only destructive ops (delete / drop / truncate).
        /// Creates and updates still go through, so the agent can
        /// do normal work.
        case destructive
        /// Block every mutation — the agent can only read.
        case readOnly

        // Localized at the source: these are rendered via `Text(String)` /
        // `Picker`, which SwiftUI shows verbatim — so the String must already
        // be in the user's language by the time it leaves here.
        public var displayName: String {
            switch self {
            case .off:            return NSLocalizedString("Off", comment: "")
            case .promptOnWrite:  return NSLocalizedString("Prompt before write", comment: "")
            case .destructive:    return NSLocalizedString("Block destructive", comment: "")
            case .readOnly:       return NSLocalizedString("Read-only", comment: "")
            }
        }

        public var detail: String {
            switch self {
            case .off:           return NSLocalizedString("No filtering.", comment: "")
            case .promptOnWrite: return NSLocalizedString("Reads pass through; writes ask you each time.", comment: "")
            case .destructive:   return NSLocalizedString("Block deletes/drops; allow creates and updates.", comment: "")
            case .readOnly:      return NSLocalizedString("Block every change; reads only.", comment: "")
            }
        }

        /// Whether this mode ever needs the host to ask the user
        /// before forwarding. The HTTPProxy uses this to skip the
        /// broker hop for modes that decide purely sync.
        public var needsConsent: Bool {
            self == .promptOnWrite
        }
    }

    /// Kubernetes API verb filtering.
    public var kubernetes: Mode
    /// AWS API action filtering (any *.amazonaws.com endpoint).
    public var aws: Mode
    /// DigitalOcean API (api.digitalocean.com) — HTTP-method filtering.
    public var digitalOcean: Mode
    /// Docker registries the profile has credentials for — pull/push/delete
    /// map to GET/PUT/DELETE.
    public var docker: Mode
    /// GitHub (github.com + API) — REST verbs + git push.
    public var github: Mode
    /// GitLab (gitlab.com + API).
    public var gitlab: Mode
    /// Bitbucket (bitbucket.org + API).
    public var bitbucket: Mode

    public init(kubernetes: Mode = .off, aws: Mode = .off,
                digitalOcean: Mode = .off, docker: Mode = .off,
                github: Mode = .off, gitlab: Mode = .off, bitbucket: Mode = .off) {
        self.kubernetes = kubernetes
        self.aws = aws
        self.digitalOcean = digitalOcean
        self.docker = docker
        self.github = github
        self.gitlab = gitlab
        self.bitbucket = bitbucket
    }

    /// Construction default used when creating a *new* profile.
    /// Distinct from `GuardrailsPolicy()` (all-off, kept for backward-
    /// compat decoding of old JSON that omits every field). New
    /// profiles get prompt-on-write across the board — the safest
    /// non-blocking default for an agent we don't yet trust.
    public static func defaultForNewProfile() -> GuardrailsPolicy {
        GuardrailsPolicy(
            kubernetes:   .promptOnWrite,
            aws:          .promptOnWrite,
            digitalOcean: .promptOnWrite,
            docker:       .promptOnWrite,
            github:       .promptOnWrite,
            gitlab:       .promptOnWrite,
            bitbucket:    .promptOnWrite
        )
    }

    public var isActive: Bool {
        [kubernetes, aws, digitalOcean, docker, github, gitlab, bitbucket]
            .contains { $0 != .off }
    }

    // Tolerant Codable — every field defaults to .off so older/newer profile
    // JSON loads cleanly, and only non-default modes are persisted.
    enum CodingKeys: String, CodingKey {
        case kubernetes, aws, digitalOcean, docker, github, gitlab, bitbucket
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func mode(_ k: CodingKeys) throws -> Mode {
            try c.decodeIfPresent(Mode.self, forKey: k) ?? .off
        }
        kubernetes   = try mode(.kubernetes)
        aws          = try mode(.aws)
        digitalOcean = try mode(.digitalOcean)
        docker       = try mode(.docker)
        github       = try mode(.github)
        gitlab       = try mode(.gitlab)
        bitbucket    = try mode(.bitbucket)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if kubernetes   != .off { try c.encode(kubernetes,   forKey: .kubernetes) }
        if aws          != .off { try c.encode(aws,          forKey: .aws) }
        if digitalOcean != .off { try c.encode(digitalOcean, forKey: .digitalOcean) }
        if docker       != .off { try c.encode(docker,       forKey: .docker) }
        if github       != .off { try c.encode(github,       forKey: .github) }
        if gitlab       != .off { try c.encode(gitlab,       forKey: .gitlab) }
        if bitbucket    != .off { try c.encode(bitbucket,    forKey: .bitbucket) }
    }
}

/// Resolved, runtime form of a profile's `GuardrailsPolicy` handed to the MITM:
/// the policy plus the concrete hosts each protocol's filtering applies to
/// (e.g. the kube API servers pulled from the profile's kubeconfigs).
public struct GuardrailsConfig: Sendable {
    public let kubernetes: GuardrailsPolicy.Mode
    /// Lowercased hostnames of the kube API servers this profile talks to.
    public let kubeHosts: Set<String>

    public let aws: GuardrailsPolicy.Mode
    public let digitalOcean: GuardrailsPolicy.Mode
    public let docker: GuardrailsPolicy.Mode
    /// Lowercased registry hosts the Docker guardrail applies to (from the
    /// profile's configured registries, plus Docker Hub's real endpoints).
    public let dockerHosts: Set<String>
    public let github: GuardrailsPolicy.Mode
    public let gitlab: GuardrailsPolicy.Mode
    public let bitbucket: GuardrailsPolicy.Mode

    /// One resolved HTTPS-database guardrail: which engine the host speaks and
    /// the mode to apply. Host is lowercased and exact (user-specified, so
    /// self-hosted instances work without a wildcard list).
    public struct DBGuardrail: Sendable {
        public let engine: HTTPDatabaseEndpoint.Engine
        public let host: String
        public let mode: GuardrailsPolicy.Mode
        public init(engine: HTTPDatabaseEndpoint.Engine, host: String,
                    mode: GuardrailsPolicy.Mode) {
            self.engine = engine; self.host = host.lowercased(); self.mode = mode
        }
    }
    /// Per-endpoint database guardrails (Mongo Data API / ClickHouse / Elastic).
    public let databases: [DBGuardrail]

    public init(kubernetes: GuardrailsPolicy.Mode, kubeHosts: Set<String>,
                aws: GuardrailsPolicy.Mode = .off,
                digitalOcean: GuardrailsPolicy.Mode = .off,
                docker: GuardrailsPolicy.Mode = .off, dockerHosts: Set<String> = [],
                github: GuardrailsPolicy.Mode = .off,
                gitlab: GuardrailsPolicy.Mode = .off,
                bitbucket: GuardrailsPolicy.Mode = .off,
                databases: [DBGuardrail] = []) {
        self.kubernetes = kubernetes
        self.kubeHosts = kubeHosts
        self.aws = aws
        self.digitalOcean = digitalOcean
        self.docker = docker
        self.dockerHosts = dockerHosts
        self.github = github
        self.gitlab = gitlab
        self.bitbucket = bitbucket
        self.databases = databases
    }

    public var isActive: Bool {
        (kubernetes != .off && !kubeHosts.isEmpty) || aws != .off
            || digitalOcean != .off || (docker != .off && !dockerHosts.isEmpty)
            || github != .off || gitlab != .off || bitbucket != .off
            || databases.contains { $0.mode != .off }
    }

    /// Whether any configured database endpoint needs the request body / query
    /// parameter inspected (only ClickHouse, whose verb lives in the SQL text).
    /// Lets the proxy skip the body read for Mongo/Elastic.
    public func dbNeedsQuery(host: String) -> Bool {
        let h = host.lowercased()
        return databases.contains {
            $0.mode != .off && $0.engine == .clickHouse && $0.host == h
        }
    }

    /// Whether a Kubernetes API request to `host` with `method` should be
    /// blocked, and the human-readable reason (surfaced in the 403 the agent
    /// sees). Returns nil to allow.
    ///
    /// `.promptOnWrite` mode collapses to "block on any non-read" here —
    /// the actual prompt happens in the async `deny()` wrapper, which
    /// uses this as the "would this be blocked?" predicate.
    public func kubeBlockReason(host: String, method: String) -> String? {
        guard kubernetes != .off,
              kubeHosts.contains(host.lowercased()) else { return nil }
        let m = method.uppercased()
        switch kubernetes {
        case .off:
            return nil
        case .readOnly, .promptOnWrite:
            if ["GET", "HEAD", "OPTIONS"].contains(m) { return nil }
            return "Kubernetes \(m) blocked by Bromure Guardrails"
        case .destructive:
            // In the kube REST API, resource destruction is the DELETE verb
            // (single object and deletecollection both use it). Creates/updates
            // (POST/PUT/PATCH) are allowed in this mode.
            if m == "DELETE" {
                return "Kubernetes delete blocked by Bromure Guardrails"
            }
            return nil
        }
    }

    /// A Kubernetes `Status` error body for a blocked request. kubectl renders
    /// the `message` field, so the user sees why it failed.
    public static func kubeForbiddenBody(reason: String) -> String {
        let escaped = reason.replacingOccurrences(of: "\"", with: "'")
        return "{\"kind\":\"Status\",\"apiVersion\":\"v1\",\"metadata\":{},"
            + "\"status\":\"Failure\",\"message\":\"\(escaped)\","
            + "\"reason\":\"Forbidden\",\"details\":{},\"code\":403}"
    }

    // MARK: - AWS

    public enum AWSKind { case read, destructive, otherWrite }

    /// Any AWS endpoint. AWS uses well-known `*.amazonaws.com` hosts, so —
    /// unlike kube — there's no per-profile host list to maintain.
    public static func isAWSHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "amazonaws.com" || h.hasSuffix(".amazonaws.com")
    }

    /// Classify an AWS action name by prefix. Read-ish prefixes mirror the
    /// AWS managed `ReadOnlyAccess` convention; the destructive set is the
    /// clearly resource/data-destroying verbs (not merely disruptive ones
    /// like Stop/Disable, which are only blocked in read-only mode).
    public static func classifyAWS(action: String) -> AWSKind {
        let destructive = ["Delete", "Terminate", "Remove", "Purge",
                           "Destroy", "Deregister", "Revoke"]
        let read = ["Get", "List", "Describe", "Head", "Select", "Query",
                    "Scan", "BatchGet", "Lookup", "Search", "Retrieve",
                    "View", "Estimate", "Detect", "Test"]
        for p in destructive where action.hasPrefix(p) { return .destructive }
        for p in read where action.hasPrefix(p) { return .read }
        return .otherWrite
    }

    /// Classify an S3 / REST-style request (no action name) by HTTP method.
    static func classifyAWSByMethod(_ method: String) -> AWSKind {
        switch method.uppercased() {
        case "GET", "HEAD", "OPTIONS": return .read
        case "DELETE":                 return .destructive
        default:                       return .otherWrite   // PUT/POST/PATCH
        }
    }

    /// Whether an AWS request should be blocked. `amzTarget` is the
    /// `X-Amz-Target` header (JSON-protocol services like DynamoDB/Lambda),
    /// `formAction` is the `Action=` parameter (query-protocol services like
    /// EC2/IAM/SQS); when both are nil we fall back to the HTTP method (S3 /
    /// REST). Returns the block reason, or nil to allow.
    public func awsBlockReason(host: String, method: String,
                               amzTarget: String?, formAction: String?) -> String? {
        guard aws != .off, Self.isAWSHost(host) else { return nil }

        var actionName: String?
        if let t = amzTarget, !t.isEmpty {
            // "DynamoDB_20120810.DeleteTable" → "DeleteTable"
            actionName = t.split(separator: ".").last.map(String.init) ?? t
        } else if let a = formAction, !a.isEmpty {
            actionName = a
        }

        let kind = actionName.map(Self.classifyAWS(action:))
            ?? Self.classifyAWSByMethod(method)
        let what = actionName ?? method

        switch aws {
        case .off:
            return nil
        case .readOnly, .promptOnWrite:
            if kind == .read { return nil }
            return "AWS \(what) blocked by Bromure Guardrails"
        case .destructive:
            if kind == .destructive {
                return "AWS \(what) blocked by Bromure Guardrails"
            }
            return nil
        }
    }

    /// Error body for a blocked AWS call. A 403 with `__type` is what the
    /// JSON-protocol SDKs parse; query/S3 (XML) SDKs still surface the 403 as
    /// a hard client error.
    public static func awsForbiddenBody(reason: String) -> String {
        let escaped = reason.replacingOccurrences(of: "\"", with: "'")
        return "{\"__type\":\"AccessDeniedException\",\"message\":\"\(escaped)\"}"
    }

    // MARK: - Generic HTTP-method protocols (DigitalOcean, Docker, REST APIs)

    /// Verb-based filtering shared by the REST/registry protocols:
    /// GET/HEAD/OPTIONS = read, DELETE = destructive, everything else = write.
    static func methodBlockReason(mode: GuardrailsPolicy.Mode,
                                  method: String, label: String) -> String? {
        let m = method.uppercased()
        switch mode {
        case .off:
            return nil
        case .readOnly, .promptOnWrite:
            if ["GET", "HEAD", "OPTIONS"].contains(m) { return nil }
            return "\(label) \(m) blocked by Bromure Guardrails"
        case .destructive:
            if m == "DELETE" { return "\(label) \(m) blocked by Bromure Guardrails" }
            return nil
        }
    }

    public static func isDigitalOceanHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "api.digitalocean.com" || h.hasSuffix(".digitalocean.com")
    }

    // MARK: - Git forges (GitHub / GitLab / Bitbucket)

    /// Git-forge filtering: the REST API is verb-based, but git-over-HTTPS
    /// rides POST for *both* fetch and push, distinguished by path. We treat a
    /// push (`git-receive-pack`) as a write (blocked only in read-only — normal
    /// pushes add commits; force-push/branch-delete can't be told apart on the
    /// wire, so destructive mode relies on the REST DELETE block for explicit
    /// deletions). `git-upload-pack` (fetch) is a read.
    func gitForgeBlockReason(host: String, method: String, path: String) -> String? {
        let mode: GuardrailsPolicy.Mode
        let label: String
        if github != .off, host == "github.com" || host.hasSuffix(".github.com")
            || host.hasSuffix("githubusercontent.com") {
            mode = github; label = "GitHub"
        } else if gitlab != .off, host == "gitlab.com" || host.hasSuffix(".gitlab.com") {
            mode = gitlab; label = "GitLab"
        } else if bitbucket != .off, host == "bitbucket.org" || host.hasSuffix(".bitbucket.org") {
            mode = bitbucket; label = "Bitbucket"
        } else {
            return nil
        }
        if path.contains("git-receive-pack") {
            return (mode == .readOnly || mode == .promptOnWrite)
                ? "\(label) git push blocked by Bromure Guardrails"
                : nil
        }
        if path.contains("git-upload-pack") { return nil }   // fetch = read
        return Self.methodBlockReason(mode: mode, method: method, label: label)
    }

    /// The host-side mode that applies to a request to `host`. Used by
    /// the async `deny()` wrapper to decide whether to consult the
    /// broker; the sync block-reason helpers already encode this mode
    /// internally. Returns `.off` if no protocol claims the host.
    func protocolMode(host: String, method _: String, path _: String)
            -> (mode: GuardrailsPolicy.Mode, scopeKey: String, scopeLabel: String)? {
        let h = host.lowercased()
        if let db = databases.first(where: { $0.mode != .off && $0.host == h }) {
            let label: String
            switch db.engine {
            case .mongoDataAPI:   label = "MongoDB"
            case .clickHouse:     label = "ClickHouse"
            case .elasticsearch:  label = "Elasticsearch"
            }
            return (db.mode, "db:\(h)", "\(label) \(h)")
        }
        if kubernetes != .off, kubeHosts.contains(h) {
            return (kubernetes, "kube:\(h)", "Kubernetes (\(h))")
        }
        if aws != .off, Self.isAWSHost(h) {
            return (aws, "aws", "AWS")
        }
        if digitalOcean != .off, Self.isDigitalOceanHost(h) {
            return (digitalOcean, "do", "DigitalOcean")
        }
        if docker != .off, dockerHosts.contains(h) {
            return (docker, "docker:\(h)", "Docker registry \(h)")
        }
        if github != .off,
           h == "github.com" || h.hasSuffix(".github.com")
            || h.hasSuffix("githubusercontent.com") {
            return (github, "github", "GitHub")
        }
        if gitlab != .off, h == "gitlab.com" || h.hasSuffix(".gitlab.com") {
            return (gitlab, "gitlab", "GitLab")
        }
        if bitbucket != .off, h == "bitbucket.org" || h.hasSuffix(".bitbucket.org") {
            return (bitbucket, "bitbucket", "Bitbucket")
        }
        return nil
    }

    // MARK: - HTTPS databases (Mongo Data API / ClickHouse / Elasticsearch)

    /// Reuse the read/destructive/otherWrite trichotomy. `readOnly` and
    /// `promptOnWrite` both block anything not `.read` (the promptOnWrite
    /// mode lets the async `deny()` wrapper re-admit blocked requests
    /// via broker consent); `destructive` blocks only `.destructive`.
    static func kindBlockReason(mode: GuardrailsPolicy.Mode, kind: AWSKind,
                                label: String, what: String) -> String? {
        switch mode {
        case .off:
            return nil
        case .readOnly, .promptOnWrite:
            if kind == .read { return nil }
            return "\(label) \(what) blocked by Bromure Guardrails"
        case .destructive:
            if kind == .destructive {
                return "\(label) \(what) blocked by Bromure Guardrails"
            }
            return nil
        }
    }

    /// MongoDB Atlas Data API: the operation is the trailing path segment under
    /// `/action/` (find, insertOne, updateMany, deleteMany, …).
    static func classifyMongoDataAPI(path: String) -> (AWSKind, String) {
        let noQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let action = (noQuery.split(separator: "/").last.map(String.init) ?? "").lowercased()
        switch action {
        case "find", "findone", "aggregate":
            return (.read, action)
        case "deleteone", "deletemany":
            return (.destructive, action)
        case "":
            return (.otherWrite, "request")
        default:
            return (.otherWrite, action)   // insertOne/Many, updateOne/Many, replaceOne
        }
    }

    /// ClickHouse HTTP interface: the verb lives in the SQL text (URL `query=`
    /// param or request body). Classify by the leading keyword. Returns nil
    /// when no SQL was visible — the caller decides (read-only still blocks the
    /// request as a non-read; destructive errs open since it can't confirm).
    static func classifyClickHouseSQL(_ sql: String) -> (AWSKind, String)? {
        // Strip leading line (`-- …`) and block (`/* … */`) comments + space.
        var s = Substring(sql)
        while true {
            let t = s.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            if t.hasPrefix("--") {
                if let nl = t.firstIndex(of: "\n") { s = t[t.index(after: nl)...] }
                else { return nil }
            } else if t.hasPrefix("/*") {
                if let end = t.range(of: "*/") { s = t[end.upperBound...] }
                else { return nil }
            } else { s = t; break }
        }
        var kw = ""
        for ch in s {
            if ch.isLetter { kw.append(ch) }
            else if kw.isEmpty && ch == "(" { continue }   // leading "(SELECT …)"
            else { break }
        }
        if kw.isEmpty { return nil }
        let k = kw.uppercased()
        let upper = sql.uppercased()
        switch k {
        case "SELECT", "SHOW", "DESCRIBE", "DESC", "EXISTS", "EXPLAIN",
             "WITH", "CHECK", "USE", "VALUES":
            return (.read, k.lowercased())
        case "DROP", "TRUNCATE", "DELETE":
            return (.destructive, k.lowercased())
        case "ALTER":
            // ClickHouse mutations: `ALTER TABLE … DELETE/DROP/CLEAR …`.
            if upper.contains(" DELETE") || upper.contains("DROP COLUMN")
                || upper.contains("DROP PARTITION") || upper.contains("CLEAR COLUMN")
                || upper.contains("CLEAR INDEX") {
                return (.destructive, "alter…delete")
            }
            return (.otherWrite, "alter")
        default:
            return (.otherWrite, k.lowercased())   // INSERT/CREATE/RENAME/OPTIMIZE/SET…
        }
    }

    /// Elasticsearch: method + path. DELETE (and `_delete_by_query`) destroy;
    /// the search/read endpoints are reads even over POST; everything else
    /// (index/_bulk/_update/mappings) is a write.
    static func classifyElasticsearch(method: String, path: String) -> (AWSKind, String) {
        let m = method.uppercased()
        let p = (path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path).lowercased()
        if p.contains("_delete_by_query") { return (.destructive, "_delete_by_query") }
        if m == "DELETE" { return (.destructive, "DELETE \(p)") }
        if m == "GET" || m == "HEAD" || m == "OPTIONS" { return (.read, "\(m) \(p)") }
        let readEndpoints = ["_search", "_msearch", "_count", "_mget", "_field_caps",
                             "_sql", "_explain", "_validate", "_terms_enum", "_eql",
                             "_pit", "_render", "_analyze", "/scroll"]
        for e in readEndpoints where p.contains(e) { return (.read, "\(m) \(p)") }
        return (.otherWrite, "\(m) \(p)")   // _bulk, _update, index, mappings…
    }

    private func mongoErrorBody(_ reason: String) -> String {
        "{\"error\":\"\(reason.replacingOccurrences(of: "\"", with: "'"))\"}"
    }
    private func elasticErrorBody(_ reason: String) -> String {
        let escaped = reason.replacingOccurrences(of: "\"", with: "'")
        return "{\"error\":{\"type\":\"security_exception\",\"reason\":\"\(escaped)\"},\"status\":403}"
    }

    /// Decide a database request. `query` is the ClickHouse SQL (URL param or
    /// body) the proxy extracted; nil/empty for Mongo & Elastic. Returns a
    /// `Denial` or nil to forward.
    func dbDenial(host: String, method: String, path: String, query: String?) -> Denial? {
        let h = host.lowercased()
        for db in databases where db.mode != .off && db.host == h {
            switch db.engine {
            case .mongoDataAPI:
                let (kind, what) = Self.classifyMongoDataAPI(path: path)
                if let reason = Self.kindBlockReason(mode: db.mode, kind: kind,
                                                     label: "MongoDB", what: what) {
                    return Denial(reason: reason, body: mongoErrorBody(reason),
                                  contentType: "application/json", amzErrorType: nil)
                }
            case .clickHouse:
                let sql = query ?? ""
                let classified = Self.classifyClickHouseSQL(sql)
                let kind: AWSKind
                let what: String
                if let c = classified { kind = c.0; what = c.1 }
                else {
                    // No SQL visible: read-only blocks (can't prove it's a read),
                    // destructive errs open.
                    kind = .otherWrite; what = "query"
                }
                if let reason = Self.kindBlockReason(mode: db.mode, kind: kind,
                                                     label: "ClickHouse", what: what) {
                    return Denial(reason: reason, body: reason,
                                  contentType: "text/plain; charset=UTF-8", amzErrorType: nil)
                }
            case .elasticsearch:
                let (kind, what) = Self.classifyElasticsearch(method: method, path: path)
                if let reason = Self.kindBlockReason(mode: db.mode, kind: kind,
                                                     label: "Elasticsearch", what: what) {
                    return Denial(reason: reason, body: elasticErrorBody(reason),
                                  contentType: "application/json", amzErrorType: nil)
                }
            }
        }
        return nil
    }

    // MARK: - Unified entry point

    /// A blocked request: the reason plus the ready-to-send 403 body and its
    /// content type (and the AWS error-type header when applicable).
    public struct Denial: Sendable {
        public let reason: String
        public let body: String
        public let contentType: String
        public let amzErrorType: String?
    }

    private func jsonMessageBody(_ reason: String) -> String {
        "{\"message\":\"\(reason.replacingOccurrences(of: "\"", with: "'"))\"}"
    }
    private func dockerErrorBody(_ reason: String) -> String {
        "{\"errors\":[{\"code\":\"DENIED\",\"message\":\"\(reason.replacingOccurrences(of: "\"", with: "'"))\"}]}"
    }

    /// Async wrapper around `deny()` that resolves `.promptOnWrite`
    /// via the broker before reporting a final decision. For modes
    /// that decide synchronously (off / destructive / readOnly) this
    /// is identical to `deny()`; for `.promptOnWrite` it intercepts
    /// the sync block decision and asks the user instead.
    ///
    /// The caller passes the broker, the profile's ID (for grant
    /// scoping), and a short pre-built operation description (e.g.
    /// `"DROP TABLE users"`, `"DELETE /api/v1/namespaces/default/pods/foo"`).
    /// We can't reconstruct the operation description here from
    /// (host, method, path) alone for ClickHouse — the SQL has
    /// already been extracted by the caller for `dbQuery`.
#if os(macOS)
    public func denyAsync(host: String, method: String, path: String,
                          amzTarget: String?, formAction: String?,
                          dbQuery: String? = nil,
                          broker: GuardrailsConsentBroker,
                          profileID: UUID) async -> Denial? {
        guard let denial = deny(host: host, method: method, path: path,
                                amzTarget: amzTarget, formAction: formAction,
                                dbQuery: dbQuery) else {
            return nil
        }
        // The sync layer block would fire. If the underlying mode for
        // this host is `.promptOnWrite`, escalate to the broker — on
        // user approval we let the request through; on denial we
        // forward the same Denial sync would have produced.
        guard let route = protocolMode(host: host, method: method, path: path),
              route.mode == .promptOnWrite else {
            return denial
        }
        // Build an operation description: prefer the actual SQL when
        // we have it (ClickHouse), otherwise compose verb + path. The
        // reason string from `deny()` already encodes verb + resource
        // for REST protocols.
        let operation: String
        if let q = dbQuery, !q.isEmpty {
            operation = q
        } else {
            operation = "\(method.uppercased()) \(path)"
        }
        let allowed = await broker.consent(profileID: profileID,
                                            scope: route.scopeKey,
                                            scopeDisplayName: route.scopeLabel,
                                            operation: operation)
        return allowed ? nil : denial
    }
#endif

    /// Single host-side decision for every guardrailed protocol. Returns a
    /// `Denial` (the caller sends a 403) or nil to forward. `amzTarget` /
    /// `formAction` need only be supplied for AWS hosts.
    ///
    /// `.promptOnWrite` mode collapses to "block any non-read" in this
    /// sync call — the async `denyAsync()` wrapper is what actually
    /// asks the user.
    public func deny(host: String, method: String, path: String,
                     amzTarget: String?, formAction: String?,
                     dbQuery: String? = nil) -> Denial? {
        let h = host.lowercased()
        if let denial = dbDenial(host: h, method: method, path: path, query: dbQuery) {
            return denial
        }
        if let reason = kubeBlockReason(host: h, method: method) {
            return Denial(reason: reason, body: Self.kubeForbiddenBody(reason: reason),
                          contentType: "application/json", amzErrorType: nil)
        }
        if let reason = awsBlockReason(host: h, method: method,
                                       amzTarget: amzTarget, formAction: formAction) {
            return Denial(reason: reason, body: Self.awsForbiddenBody(reason: reason),
                          contentType: "application/x-amz-json-1.0",
                          amzErrorType: "AccessDeniedException")
        }
        if digitalOcean != .off, Self.isDigitalOceanHost(h),
           let reason = Self.methodBlockReason(mode: digitalOcean, method: method,
                                               label: "DigitalOcean") {
            return Denial(reason: reason, body: jsonMessageBody(reason),
                          contentType: "application/json", amzErrorType: nil)
        }
        if docker != .off, dockerHosts.contains(h),
           let reason = Self.methodBlockReason(mode: docker, method: method,
                                               label: "Docker registry") {
            return Denial(reason: reason, body: dockerErrorBody(reason),
                          contentType: "application/json", amzErrorType: nil)
        }
        if let reason = gitForgeBlockReason(host: h, method: method, path: path) {
            return Denial(reason: reason, body: jsonMessageBody(reason),
                          contentType: "application/json", amzErrorType: nil)
        }
        return nil
    }
}
