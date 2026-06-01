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
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// No filtering — traffic passes through untouched.
        case off
        /// Block only destructive ops (delete / drop / truncate). Creates and
        /// updates still go through, so the agent can do normal work.
        case destructive
        /// Block every mutation — the agent can only read.
        case readOnly

        public var displayName: String {
            switch self {
            case .off:         return "Off"
            case .destructive: return "Block destructive"
            case .readOnly:    return "Read-only"
            }
        }

        public var detail: String {
            switch self {
            case .off:         return "No filtering."
            case .destructive: return "Block deletes/drops; allow creates and updates."
            case .readOnly:    return "Block every change; reads only."
            }
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

    public init(kubernetes: GuardrailsPolicy.Mode, kubeHosts: Set<String>,
                aws: GuardrailsPolicy.Mode = .off,
                digitalOcean: GuardrailsPolicy.Mode = .off,
                docker: GuardrailsPolicy.Mode = .off, dockerHosts: Set<String> = [],
                github: GuardrailsPolicy.Mode = .off,
                gitlab: GuardrailsPolicy.Mode = .off,
                bitbucket: GuardrailsPolicy.Mode = .off) {
        self.kubernetes = kubernetes
        self.kubeHosts = kubeHosts
        self.aws = aws
        self.digitalOcean = digitalOcean
        self.docker = docker
        self.dockerHosts = dockerHosts
        self.github = github
        self.gitlab = gitlab
        self.bitbucket = bitbucket
    }

    public var isActive: Bool {
        (kubernetes != .off && !kubeHosts.isEmpty) || aws != .off
            || digitalOcean != .off || (docker != .off && !dockerHosts.isEmpty)
            || github != .off || gitlab != .off || bitbucket != .off
    }

    /// Whether a Kubernetes API request to `host` with `method` should be
    /// blocked, and the human-readable reason (surfaced in the 403 the agent
    /// sees). Returns nil to allow.
    public func kubeBlockReason(host: String, method: String) -> String? {
        guard kubernetes != .off,
              kubeHosts.contains(host.lowercased()) else { return nil }
        let m = method.uppercased()
        switch kubernetes {
        case .off:
            return nil
        case .readOnly:
            if ["GET", "HEAD", "OPTIONS"].contains(m) { return nil }
            return "Kubernetes is read-only — \(m) blocked by Bromure Guardrails"
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
        case .readOnly:
            if kind == .read { return nil }
            return "AWS is read-only — \(what) blocked by Bromure Guardrails"
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
        case .readOnly:
            if ["GET", "HEAD", "OPTIONS"].contains(m) { return nil }
            return "\(label) is read-only — \(m) blocked by Bromure Guardrails"
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
            return mode == .readOnly
                ? "\(label) is read-only — git push blocked by Bromure Guardrails"
                : nil
        }
        if path.contains("git-upload-pack") { return nil }   // fetch = read
        return Self.methodBlockReason(mode: mode, method: method, label: label)
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

    /// Single host-side decision for every guardrailed protocol. Returns a
    /// `Denial` (the caller sends a 403) or nil to forward. `amzTarget` /
    /// `formAction` need only be supplied for AWS hosts.
    public func deny(host: String, method: String, path: String,
                     amzTarget: String?, formAction: String?) -> Denial? {
        let h = host.lowercased()
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
