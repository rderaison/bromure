import Foundation

/// Preset accent colors for visual identification in the profile picker.
public enum ProfileColor: String, Codable, CaseIterable, Equatable, Sendable {
    case blue, red, green, orange, purple, pink, teal, gray
    public var label: String {
        switch self {
        case .blue:   return NSLocalizedString("Blue", comment: "Profile color name")
        case .red:    return NSLocalizedString("Red", comment: "Profile color name")
        case .green:  return NSLocalizedString("Green", comment: "Profile color name")
        case .orange: return NSLocalizedString("Orange", comment: "Profile color name")
        case .purple: return NSLocalizedString("Purple", comment: "Profile color name")
        case .pink:   return NSLocalizedString("Pink", comment: "Profile color name")
        case .teal:   return NSLocalizedString("Teal", comment: "Profile color name")
        case .gray:   return NSLocalizedString("Gray", comment: "Profile color name")
        }
    }
}

/// One Kubernetes context (cluster + auth) the user pointed bromure
/// at. The full kubeconfig is materialized in the VM at session prep
/// using only the synthetic credentials we generate; the real cert /
/// token / exec-output stays on the host and the proxy substitutes it
/// on the wire.
public struct KubeconfigEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Display name (and YAML context name) — e.g. "prod-east".
    public var name: String
    /// Full server URL with scheme + port, e.g. https://k8s.example.com:6443.
    public var serverURL: String
    /// PEM-encoded API server CA. Optional but recommended — when
    /// blank we fall back to the Bromure CA, which kubectl will
    /// trust because we've already installed it system-wide in the VM.
    public var caCertPEM: String
    /// Optional default namespace.
    public var namespace: String
    /// Auth flavour for this context. Type-safe enum + Codable
    /// support via a discriminator field.
    public var auth: Auth

    /// A kubeconfig is configured once it names a server to talk to.
    public var isUsable: Bool { !serverURL.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A copy with the secret material (auth token/cert/command + CA PEM) blanked
    /// but the identity (name, server, namespace, guardrail flags) intact — what
    /// the remote profile export ships so the guardrails pane can list the context
    /// without the secret crossing the wire. `ProfileSecrets.overlay` treats the
    /// blank auth as "keep the stored secret" on the save round-trip.
    public func redactedIdentity() -> KubeconfigEntry {
        var e = self
        e.caCertPEM = ""
        // Blank the secret material but keep the auth *kind*, so the editor shows a
        // clientCert / exec context as such (not an empty bearer row) and
        // `Auth.isBlank` still reads it as untouched on the save round-trip.
        switch auth {
        case .bearerToken:                e.auth = .bearerToken("")
        case .clientCert:                 e.auth = .clientCert(certPEM: "", keyPEM: "")
        case .execPlugin(_, _, let secs): e.auth = .execPlugin(command: "", args: [], refreshSeconds: secs)
        }
        return e
    }

    public enum Auth: Codable, Equatable, Sendable {
        /// Static bearer token (rotated rarely).
        case bearerToken(String)
        /// mTLS client cert + key (PEM).
        case clientCert(certPEM: String, keyPEM: String)
        /// External command + args producing an ExecCredential JSON
        /// (the kubectl client-go exec plugin contract). Output is
        /// polled on the host every `refreshSeconds`; the resulting
        /// token gets piped into the swap map.
        case execPlugin(command: String, args: [String], refreshSeconds: Int)

        // Custom Codable: JSON-tagged form so we can evolve cases
        // without breaking older profile.json files.
        private enum CodingKeys: String, CodingKey {
            case kind, token, cert, key, command, args, refreshSeconds
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "bearerToken":
                self = .bearerToken(try c.decode(String.self, forKey: .token))
            case "clientCert":
                self = .clientCert(
                    certPEM: try c.decode(String.self, forKey: .cert),
                    keyPEM:  try c.decode(String.self, forKey: .key))
            case "execPlugin":
                self = .execPlugin(
                    command: try c.decode(String.self, forKey: .command),
                    args:    try c.decodeIfPresent([String].self, forKey: .args) ?? [],
                    refreshSeconds: try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 600)
            default:
                self = .bearerToken("")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .bearerToken(let t):
                try c.encode("bearerToken", forKey: .kind)
                try c.encode(t, forKey: .token)
            case .clientCert(let cert, let key):
                try c.encode("clientCert", forKey: .kind)
                try c.encode(cert, forKey: .cert)
                try c.encode(key, forKey: .key)
            case .execPlugin(let cmd, let args, let secs):
                try c.encode("execPlugin", forKey: .kind)
                try c.encode(cmd, forKey: .command)
                try c.encode(args, forKey: .args)
                try c.encode(secs, forKey: .refreshSeconds)
            }
        }

        /// True when this auth carries no secret material — the shape a redacted
        /// export round-trips (so a save can tell "unchanged" from a real edit).
        public var isBlank: Bool {
            switch self {
            case .bearerToken(let t):        return t.isEmpty
            case .clientCert(let c, let k):  return c.isEmpty && k.isEmpty
            case .execPlugin(let cmd, _, _): return cmd.isEmpty
            }
        }
    }

    /// When true, every fake→real swap involving this context's
    /// bearer / exec token prompts on the host. See `ConsentBroker`.
    public var requireApproval: Bool

    public init(id: UUID = UUID(), name: String = "", serverURL: String = "",
                caCertPEM: String = "", namespace: String = "",
                auth: Auth = .bearerToken(""),
                requireApproval: Bool = false) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.caCertPEM = caCertPEM
        self.namespace = namespace
        self.auth = auth
        self.requireApproval = requireApproval
    }

    /// Bare host[:port] used as the proxy's routing key when
    /// registering client identities or scoped token swaps.
    public var hostPattern: String {
        guard let url = URL(string: serverURL), let host = url.host else { return "" }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, serverURL, caCertPEM, namespace, auth, requireApproval
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        name            = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        serverURL       = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        caCertPEM       = try c.decodeIfPresent(String.self, forKey: .caCertPEM) ?? ""
        namespace       = try c.decodeIfPresent(String.self, forKey: .namespace) ?? ""
        auth            = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .bearerToken("")
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(serverURL, forKey: .serverURL)
        try c.encode(caCertPEM, forKey: .caCertPEM)
        try c.encode(namespace, forKey: .namespace)
        try c.encode(auth, forKey: .auth)
        if requireApproval { try c.encode(true, forKey: .requireApproval) }
    }
}

/// One existing SSH private key the user pointed bromure at. We copy
/// the encrypted bytes onto the host (under `agent/imported/`) and
/// stash the decryption passphrase (if any) in the macOS Keychain.
/// At session launch we ssh-add each one into the private bromure
/// agent so the in-VM ssh client can sign with it through the
/// vsock-bridged agent socket.
public struct ImportedSSHKey: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// User-supplied display name shown in the editor row
    /// ("personal", "work-cluster", etc.).
    public var label: String
    /// Basename of the file under `profiles/<id>/agent/imported/`.
    /// We rename on import to avoid collisions; original filename
    /// would also be a leak source if the user happened to encode
    /// secrets in it.
    public var filename: String
    /// Cached public-key text (read from the matching `.pub` if it
    /// existed at import). Optional — purely for the editor display.
    public var publicKeyText: String
    /// Hint for the UI; the actual passphrase lives in Keychain.
    public var hasPassphrase: Bool
    /// When true, every SSH sign request using this key prompts for
    /// user consent on the host. See `ConsentBroker`.
    public var requireApproval: Bool

    public init(id: UUID = UUID(),
                label: String,
                filename: String,
                publicKeyText: String = "",
                hasPassphrase: Bool = false,
                requireApproval: Bool = false) {
        self.id = id
        self.label = label
        self.filename = filename
        self.publicKeyText = publicKeyText
        self.hasPassphrase = hasPassphrase
        self.requireApproval = requireApproval
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, filename, publicKeyText, hasPassphrase, requireApproval
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        label           = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        filename        = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        publicKeyText   = try c.decodeIfPresent(String.self, forKey: .publicKeyText) ?? ""
        hasPassphrase   = try c.decodeIfPresent(Bool.self, forKey: .hasPassphrase) ?? false
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(filename, forKey: .filename)
        try c.encode(publicKeyText, forKey: .publicKeyText)
        try c.encode(hasPassphrase, forKey: .hasPassphrase)
        if requireApproval { try c.encode(true, forKey: .requireApproval) }
    }
}

/// One arbitrary token-swap rule, beyond the auto-derived Claude /
/// Codex / git PAT entries. The user adds these in the editor's
/// Advanced section for any other API the VM might call (Stripe,
/// Google Maps, internal APIs, etc.). The real value never crosses
/// vsock — at session launch the host mints a fake (`brm_<random>`),
/// puts the fake in the named env var, and configures the MITM
/// engine to swap fake→real on the wire.
public struct ManualToken: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Display label shown in the editor row ("Stripe sandbox").
    public var name: String
    /// The real secret. Stored in profile.json; never written into the VM.
    public var realValue: String
    /// Env var name to inject the fake under (e.g. "STRIPE_API_KEY").
    /// Empty = inject nothing, the user has to copy-paste manually.
    public var envVarName: String
    /// Host scopes. Empty = swap on any host where the fake appears. Each
    /// non-empty entry is an exact-or-subdomain match: a scope of
    /// `example.com` swaps on requests to `example.com` and any
    /// `*.example.com`, but not on `example.com.evil.com`. Match is
    /// case-insensitive; substring matching is deliberately NOT used. One
    /// token may authenticate to several hosts (each becomes its own swap
    /// scope, sharing the token's single deterministic fake).
    public var hostFilters: [String]
    /// When true, every fake→real substitution for this token prompts
    /// the user on the host. See `ConsentBroker`.
    public var requireApproval: Bool

    public init(id: UUID = UUID(), name: String = "", realValue: String = "",
                envVarName: String = "", hostFilters: [String] = [],
                requireApproval: Bool = false) {
        self.id = id
        self.name = name
        self.realValue = realValue
        self.envVarName = envVarName
        self.hostFilters = hostFilters
        self.requireApproval = requireApproval
    }

    public var isUsable: Bool {
        !realValue.isEmpty
    }

    /// The scopes that produce a swap: the non-empty host filters, or a
    /// single "any host" (empty string) sentinel when none are set.
    public var effectiveHostScopes: [String] {
        let hosts = hostFilters.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return hosts.isEmpty ? [""] : hosts
    }

    private enum CodingKeys: String, CodingKey {
        // `hostFilter` (singular) is the legacy pre-multi-host key, decoded for
        // migration only; new profiles write `hostFilters`.
        case id, name, realValue, envVarName, hostFilter, hostFilters, requireApproval
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        name            = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        realValue       = try c.decodeIfPresent(String.self, forKey: .realValue) ?? ""
        envVarName      = try c.decodeIfPresent(String.self, forKey: .envVarName) ?? ""
        if let list = try c.decodeIfPresent([String].self, forKey: .hostFilters) {
            hostFilters = list
        } else if let single = try c.decodeIfPresent(String.self, forKey: .hostFilter), !single.isEmpty {
            hostFilters = [single]           // migrate legacy single-host profiles
        } else {
            hostFilters = []
        }
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(realValue, forKey: .realValue)
        try c.encode(envVarName, forKey: .envVarName)
        if !hostFilters.isEmpty { try c.encode(hostFilters, forKey: .hostFilters) }
        if requireApproval { try c.encode(true, forKey: .requireApproval) }
    }
}

/// One HTTPS-token Git credential for a single forge host. Materializes
/// as a line in ~/.git-credentials inside the VM and (for known hosts)
/// as a `gh` / `glab` CLI config entry so those tools auth without an
/// extra `gh auth login` step.
public struct GitHTTPSCredential: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Bare host, no scheme — "github.com", "gitlab.com", "git.example.com".
    public var host: String
    public var username: String
    /// Personal access token (or fine-grained token, OAuth token, etc.).
    /// Stored in profile.json alongside the API key — same trust boundary.
    public var token: String
    /// When true, every fake→real swap for this token prompts on the
    /// host. See `ConsentBroker`.
    public var requireApproval: Bool

    public init(id: UUID = UUID(), host: String = "github.com",
                username: String = "", token: String = "",
                requireApproval: Bool = false) {
        self.id = id
        self.host = host
        self.username = username
        self.token = token
        self.requireApproval = requireApproval
    }

    /// True if this entry has enough to be written to ~/.git-credentials.
    public var isUsable: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !token.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, host, username, token, requireApproval
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        host            = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        username        = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        token           = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(host, forKey: .host)
        try c.encode(username, forKey: .username)
        try c.encode(token, forKey: .token)
        if requireApproval { try c.encode(true, forKey: .requireApproval) }
    }
}

/// One container-registry credential — Docker Hub, GHCR, GitLab CR,
/// a private registry, etc. Materializes as an entry in
/// ~/.docker/config.json's `auths` dict so `docker pull` / `docker
/// push` / `docker login` (skipped) just work.
///
/// Docker auth is HTTP Basic: the value stored in config.json is
/// `base64("<user>:<password>")`, sent as `Authorization: Basic <b64>`
/// to the registry's auth endpoint. We mint a fake password (HKDF) and
/// write `base64("<user>:<fake>")` into the VM. The proxy substitutes
/// the fake base64 string with the real one on the wire — scoped to
/// the registry host so a stray copy of the base64 string sent to a
/// third-party host is left alone.
public struct DockerRegistryCredential: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Registry hostname — "ghcr.io", "docker.io", "registry.gitlab.com",
    /// "myregistry.example.com". For Docker Hub, "docker.io" is the
    /// expected input; we rewrite it to the canonical
    /// `https://index.docker.io/v1/` key when writing config.json so
    /// the Docker CLI picks it up.
    public var host: String
    public var username: String
    /// Personal access token / password. Stored in the encrypted
    /// secrets.enc next to the rest of the profile's secrets.
    public var password: String
    /// When true, every fake→real swap of the registry's Basic-auth
    /// blob prompts on the host. See `ConsentBroker`.
    public var requireApproval: Bool

    public init(id: UUID = UUID(),
                host: String = "",
                username: String = "",
                password: String = "",
                requireApproval: Bool = false) {
        self.id = id
        self.host = host
        self.username = username
        self.password = password
        self.requireApproval = requireApproval
    }

    public var isUsable: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, host, username, password, requireApproval
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        host            = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        username        = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password        = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(host, forKey: .host)
        try c.encode(username, forKey: .username)
        try c.encode(password, forKey: .password)
        if requireApproval { try c.encode(true, forKey: .requireApproval) }
    }
}

/// An HTTPS-accessible database the agent talks to over the MITM (Mongo Atlas
/// Data API, ClickHouse HTTP interface, Elasticsearch). Carries both the
/// credential (swapped fake→real on the wire, like docker/git creds) and the
/// per-endpoint Guardrails mode (the host + engine drive the classifier).
public struct HTTPDatabaseEndpoint: Codable, Equatable, Sendable, Identifiable {
    public enum Engine: String, Codable, CaseIterable, Sendable {
        case mongoDataAPI, clickHouse, elasticsearch
        public var displayName: String {
            switch self {
            case .mongoDataAPI:  return "MongoDB (Data API)"
            case .clickHouse:    return "ClickHouse"
            case .elasticsearch: return "Elasticsearch"
            }
        }
    }
    /// How the real secret is presented on the wire — drives which swap
    /// entries we mint. All are raw-string swaps except `basic`, which also
    /// needs the base64(user:pass) blob swapped.
    public enum AuthKind: String, Codable, CaseIterable, Sendable {
        case basic     // Authorization: Basic base64(user:secret)  (+ raw secret)
        case apiKey    // a header / param carrying the raw secret (Mongo api-key, X-ClickHouse-Key, …)
        case bearer    // Authorization: Bearer <secret> / ApiKey <secret>
        public var displayName: String {
            switch self {
            case .basic:  return "Username + password"
            case .apiKey: return "API key"
            case .bearer: return "Bearer token"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var engine: Engine
    /// Bare host (no scheme/port) the endpoint lives on — user-specified, so
    /// self-hosted instances work. Both the swap and the guardrail scope to it.
    public var host: String
    public var auth: AuthKind
    public var username: String       // basic only
    /// Real secret (password / API key / bearer). Stored in profile.json; a
    /// fake is what ever reaches the VM.
    public var secret: String
    /// Env var name(s) the fake secret is injected under (user-named, like
    /// manual tokens) so the agent can reference it.
    public var envVars: [String]
    /// Guardrails mode for this endpoint. See `GuardrailsPolicy.Mode`
    /// for the four states (Off / Prompt before write / Block
    /// destructive / Read-only).
    public var guardrail: GuardrailsPolicy.Mode
    public var requireApproval: Bool

    public init(id: UUID = UUID(), name: String = "", engine: Engine = .clickHouse,
                host: String = "", auth: AuthKind = .basic, username: String = "",
                secret: String = "", envVars: [String] = [],
                guardrail: GuardrailsPolicy.Mode = .promptOnWrite, requireApproval: Bool = false) {
        self.id = id; self.name = name; self.engine = engine; self.host = host
        self.auth = auth; self.username = username; self.secret = secret
        self.envVars = envVars; self.guardrail = guardrail; self.requireApproval = requireApproval
    }

    public var isUsable: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !secret.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, engine, host, auth, username, secret, envVars, guardrail, requireApproval
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .clickHouse
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        auth = try c.decodeIfPresent(AuthKind.self, forKey: .auth) ?? .basic
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        envVars = try c.decodeIfPresent([String].self, forKey: .envVars) ?? []
        guardrail = try c.decodeIfPresent(GuardrailsPolicy.Mode.self, forKey: .guardrail) ?? .off
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(engine, forKey: .engine)
        try c.encode(host, forKey: .host)
        try c.encode(auth, forKey: .auth)
        if !username.isEmpty { try c.encode(username, forKey: .username) }
        try c.encode(secret, forKey: .secret)
        if !envVars.isEmpty { try c.encode(envVars, forKey: .envVars) }
        if guardrail != .off { try c.encode(guardrail, forKey: .guardrail) }
        if requireApproval { try c.encode(true, forKey: .requireApproval) }
    }
}

/// AWS API credentials for `aws` CLI / SDKs inside the VM.
///
/// Unlike the simple Bearer-token APIs (DigitalOcean, OpenAI, etc.)
/// AWS signs each request with SigV4 — the secret key is consumed
/// locally to compute an HMAC over the canonical request, then the
/// signature (not the secret) crosses the wire. So we can't fake →
/// real swap on the wire the way it does for Bearer tokens.
///
/// Instead the real access key + secret live on the host (in the
/// MitmEngine's `AWSCredentialServer`). The guest's `credential_process`
/// helper gets the real `AccessKeyId` paired with a *fake* secret, so
/// the SDK signs a request whose signature is bound to fail. The host
/// `AWSResigner` intercepts the proxied request, strips the doomed
/// signature, and recomputes SigV4 with the real material that never
/// enters the VM's address space. If the proxy is bypassed, AWS
/// rejects with `InvalidSignatureException` — fail-closed.

public enum AWSAuthMode: String, Codable, CaseIterable, Sendable {
    case staticKeys
    case ssoProfile
}

public struct AWSCredentials: Codable, Equatable, Sendable {
    /// How the credentials are sourced: static IAM keys or SSO profile.
    public var authMode: AWSAuthMode
    /// e.g. `AKIAIOSFODNN7EXAMPLE`. Identity-only on the wire.
    public var accessKeyID: String
    /// Secret signing key. Stored encrypted in the secrets vault.
    public var secretAccessKey: String
    /// Optional STS session token for temporary credentials. Adds
    /// `aws_session_token` to the credentials file + `AWS_SESSION_TOKEN`
    /// env. Stored encrypted alongside the secret.
    public var sessionToken: String
    /// Default region for the SDK (`AWS_DEFAULT_REGION` + ~/.aws/config).
    public var region: String
    /// When true, every host-side SigV4 signing call (one per AWS
    /// API request) prompts for user consent until a time-bounded
    /// grant covers the request. See `ConsentBroker`.
    public var requireApproval: Bool

    /// The `[profile <name>]` from `~/.aws/config` when `authMode == .ssoProfile`.
    public var ssoProfileName: String
    /// Read-only, populated from config discovery.
    public var ssoAccountId: String
    /// Read-only, populated from config discovery.
    public var ssoRoleName: String

    public init(accessKeyID: String = "",
                secretAccessKey: String = "",
                sessionToken: String = "",
                region: String = "",
                requireApproval: Bool = false,
                authMode: AWSAuthMode = .staticKeys,
                ssoProfileName: String = "",
                ssoAccountId: String = "",
                ssoRoleName: String = "") {
        self.authMode = authMode
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
        self.requireApproval = requireApproval
        self.ssoProfileName = ssoProfileName
        self.ssoAccountId = ssoAccountId
        self.ssoRoleName = ssoRoleName
    }

    /// True when credentials are configured enough to attempt signing.
    public var isUsable: Bool {
        switch authMode {
        case .staticKeys:
            return !accessKeyID.trimmingCharacters(in: .whitespaces).isEmpty
                && !secretAccessKey.isEmpty
        case .ssoProfile:
            return !ssoProfileName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private enum CodingKeys: String, CodingKey {
        case authMode, accessKeyID, secretAccessKey, sessionToken, region
        case requireApproval, ssoProfileName, ssoAccountId, ssoRoleName
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authMode        = try c.decodeIfPresent(AWSAuthMode.self, forKey: .authMode) ?? .staticKeys
        accessKeyID     = try c.decodeIfPresent(String.self, forKey: .accessKeyID) ?? ""
        secretAccessKey = try c.decodeIfPresent(String.self, forKey: .secretAccessKey) ?? ""
        sessionToken    = try c.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
        region          = try c.decodeIfPresent(String.self, forKey: .region) ?? ""
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
        ssoProfileName  = try c.decodeIfPresent(String.self, forKey: .ssoProfileName) ?? ""
        ssoAccountId    = try c.decodeIfPresent(String.self, forKey: .ssoAccountId) ?? ""
        ssoRoleName     = try c.decodeIfPresent(String.self, forKey: .ssoRoleName) ?? ""
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if authMode != .staticKeys { try c.encode(authMode, forKey: .authMode) }
        try c.encode(accessKeyID, forKey: .accessKeyID)
        try c.encode(secretAccessKey, forKey: .secretAccessKey)
        try c.encode(sessionToken, forKey: .sessionToken)
        try c.encode(region, forKey: .region)
        if requireApproval { try c.encode(true, forKey: .requireApproval) }
        if !ssoProfileName.isEmpty { try c.encode(ssoProfileName, forKey: .ssoProfileName) }
        if !ssoAccountId.isEmpty { try c.encode(ssoAccountId, forKey: .ssoAccountId) }
        if !ssoRoleName.isEmpty { try c.encode(ssoRoleName, forKey: .ssoRoleName) }
    }
}

/// One user-defined environment variable exported into the VM at
/// session prepare time. No proxy substitution — the value is written
/// verbatim into `proxy.env` (which `.bashrc` sources), so anything
/// the user doesn't want on the VM disk should NOT go here. Useful
/// for non-secret toggles like `MY_FEATURE_FLAG=1`, `RUST_LOG=debug`,
/// `DEBUG=app:*`, etc.
public struct EnvironmentVariable: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// POSIX env-var name. Anything outside `[A-Za-z_][A-Za-z0-9_]*`
    /// is stripped at materialization time so a stray space or `-`
    /// doesn't produce an unsourceable shell line.
    public var name: String
    /// Value. Shell-quoted on the way into `proxy.env`, so spaces,
    /// quotes, dollar signs etc. are safe.
    public var value: String

    public init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    /// True when the entry has a non-empty, syntactically-valid name.
    /// Empty values are allowed (`export FOO=` clears the variable).
    public var isUsable: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return EnvironmentVariable.isValidName(trimmed)
    }

    /// POSIX env-var name regex: leading [A-Za-z_], rest [A-Za-z0-9_].
    public static func isValidName(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        if !(first.isLetter || first == "_") { return false }
        for c in s.dropFirst() {
            if !(c.isLetter || c.isNumber || c == "_") { return false }
        }
        return true
    }
}

/// An MCP server configured in a profile. At VM boot time the host
/// serializes these into the agent-appropriate config file (Claude Code
/// JSON or Codex TOML) and injects them into the guest.
public struct MCPServer: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID

    public var name: String

    public enum Transport: String, Codable, CaseIterable, Sendable {
        case http
        case stdio
    }
    public var transport: Transport

    public var command: String
    public var arguments: [String]

    public var url: String

    public var environment: [EnvironmentVariable]

    public var bearerTokenEnvVar: String

    public var bearerToken: String

    public var enabled: Bool

    /// When non-empty, this raw JSON is used as the server config
    /// instead of the structured fields above. Allows arbitrary
    /// MCP config shapes (OAuth blocks, custom fields, etc.).
    public var rawJSON: String

    public var startupTimeoutSec: Int?
    public var toolTimeoutSec: Int?

    /// OAuth state obtained by the host-side broker. When non-nil the
    /// bearer token is managed — the broker populates `bearerToken`
    /// from `oauthState.accessToken` and refreshes it on launch.
    public var oauthState: MCPOAuthState?

    public init(
        id: UUID = UUID(),
        name: String = "",
        transport: Transport = .http,
        command: String = "",
        arguments: [String] = [],
        url: String = "",
        environment: [EnvironmentVariable] = [],
        bearerTokenEnvVar: String = "",
        bearerToken: String = "",
        enabled: Bool = true,
        rawJSON: String = "",
        startupTimeoutSec: Int? = nil,
        toolTimeoutSec: Int? = nil,
        oauthState: MCPOAuthState? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.environment = environment
        self.bearerTokenEnvVar = bearerTokenEnvVar
        self.bearerToken = bearerToken
        self.enabled = enabled
        self.rawJSON = rawJSON
        self.startupTimeoutSec = startupTimeoutSec
        self.toolTimeoutSec = toolTimeoutSec
        self.oauthState = oauthState
    }

    public var urlHost: String? {
        guard transport == .http, let parsed = URL(string: url) else { return nil }
        return parsed.host
    }

    public var isUsable: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        switch transport {
        case .stdio: return hasName && !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http:  return hasName && !url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

/// OAuth tokens and client registration obtained by the host-side broker
/// for an HTTP MCP server. Persisted in the profile so the access token
/// can be refreshed across sessions without re-authorizing.
public struct MCPOAuthState: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String?
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var registrationEndpoint: String?
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var authorizedAt: Date
    public var callbackPort: UInt16?

    public init(
        clientID: String,
        clientSecret: String? = nil,
        authorizationEndpoint: String,
        tokenEndpoint: String,
        registrationEndpoint: String? = nil,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        authorizedAt: Date = Date(),
        callbackPort: UInt16? = nil
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.authorizedAt = authorizedAt
        self.callbackPort = callbackPort
    }
}

/// One agentic-coding profile: which tool, how it auths, what folder it
/// works against, and where its persistent disk lives.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public enum Tool: String, Codable, CaseIterable, Sendable {
        case claude
        case codex
        case grok
        public var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex:  return "Codex"
            case .grok:   return "Grok Build"
            }
        }
        /// Env-var name the in-VM init script writes the API key to when
        /// auth mode is .token.
        public var apiKeyEnvVar: String {
            switch self {
            case .claude: return "ANTHROPIC_API_KEY"
            case .codex:  return "OPENAI_API_KEY"
            case .grok:   return "XAI_API_KEY"
            }
        }

        /// Env exports that pin this tool at the local engine serving
        /// `model`. The model name must match what the engine reports in
        /// `/v1/models` (we launch it with `--model <repo>`, so it's the
        /// repo). Keys are dummies — the engine ignores them.
        ///
        /// Claude Code resolves *several* model slots (main + small/fast +
        /// the opus/sonnet/haiku aliases the `/model` picker maps to); we
        /// point every slot at the one local model so no slot falls back to
        /// a cloud model the engine doesn't serve.
        public func localEnvExports(model: String, key: String) -> [(name: String, value: String)] {
            // Target the MITM sentinel host (not loopback): the request goes
            // through the proxy, so local inference gets the same prompt-injection
            // detection + trace capture as cloud. The MITM forwards to the on-host
            // engine. (Codex configures its base URL via config.toml separately.)
            let base = "https://\(InferenceService.localMitmHost)"
            switch self {
            case .claude:
                // ANTHROPIC_AUTH_TOKEN (sent as `Authorization: Bearer`),
                // NOT ANTHROPIC_API_KEY (`x-api-key`): vllm-mlx's --api-key
                // only checks Bearer, so x-api-key 401s. Use only one of them
                // — setting both makes Claude Code warn about conflicting auth.
                // Disable non-essential traffic so telemetry / bootstrap /
                // mcp-registry don't spray the engine with 404s (and don't
                // carry the key off to api.anthropic.com).
                return [
                    ("ANTHROPIC_BASE_URL", base),
                    ("ANTHROPIC_AUTH_TOKEN", key),
                    ("ANTHROPIC_MODEL", model),
                    ("ANTHROPIC_SMALL_FAST_MODEL", model),
                    ("ANTHROPIC_DEFAULT_OPUS_MODEL", model),
                    ("ANTHROPIC_DEFAULT_SONNET_MODEL", model),
                    ("ANTHROPIC_DEFAULT_HAIKU_MODEL", model),
                    ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"),
                ]
            case .codex:
                // Codex doesn't redirect via env — it uses the Responses API
                // and a config-file provider. The real wiring is a
                // `~/.codex/config.toml` model_provider with wire_api="chat"
                // (written by SessionDisk). We still export the dummy key the
                // provider's env_key points at.
                return [
                    ("OPENAI_API_KEY", key),
                ]
            case .grok:
                // The grok CLI's "Custom Models Endpoint" (verified against
                // grok 0.2.x README): GROK_MODELS_BASE_URL + XAI_API_KEY.
                // Setting models_base_url switches grok to API-key auth
                // (Authorization: Bearer), so it never triggers the browser
                // login. The model list is fetched from {base}/models.
                // (The older GROK_BASE_URL/GROK_API_KEY are ignored by this
                // CLI — they're what left grok stuck on the OAuth screen.)
                return [
                    ("GROK_MODELS_BASE_URL", "\(base)/v1"),
                    ("XAI_API_KEY", key),
                ]
            }
        }
    }

    public enum AuthMode: String, Codable, CaseIterable, Sendable {
        case token         // user-supplied API key, injected as env var
        case subscription  // user runs `claude login` / `codex login` in the VM
        case bedrock       // AWS Bedrock via SSO or static IAM keys
        case local         // on-host vllm-mlx engine; tool pinned via base-URL env

        public var displayName: String {
            switch self {
            case .token:        return "API token"
            case .subscription: return "Subscription (interactive login)"
            case .bedrock:      return "Bedrock (AWS)"
            case .local:        return "Local model"
            }
        }
    }

    /// Configuration for one coding agent inside a profile. The `tool`
    /// field is the discriminator. Used both for the profile's primary
    /// agent (the one auto-launched in the first kitty) and any
    /// additional agents the user wants pre-configured.
    public struct ToolSpec: Codable, Equatable, Sendable, Identifiable {
        public var tool: Tool
        public var authMode: AuthMode
        /// Cleartext API key. Only honored when `authMode == .token`.
        public var apiKey: String?
        /// Catalog id (or HF repo) of the local model to serve this tool.
        /// Only honored when `authMode == .local`.
        public var localModelID: String?
        /// When true, every fake→real swap of this tool's API key
        /// prompts on the host. See `ConsentBroker`.
        public var requireApproval: Bool

        public var id: Tool { tool }

        public init(tool: Tool, authMode: AuthMode = .token,
                    apiKey: String? = nil, localModelID: String? = nil,
                    requireApproval: Bool = false) {
            self.tool = tool
            self.authMode = authMode
            self.apiKey = apiKey
            self.localModelID = localModelID
            self.requireApproval = requireApproval
        }

        private enum CodingKeys: String, CodingKey {
            case tool, authMode, apiKey, localModelID, requireApproval
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tool            = try c.decode(Tool.self, forKey: .tool)
            authMode        = try c.decodeIfPresent(AuthMode.self, forKey: .authMode) ?? .token
            apiKey          = try c.decodeIfPresent(String.self, forKey: .apiKey)
            localModelID    = try c.decodeIfPresent(String.self, forKey: .localModelID)
            requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tool, forKey: .tool)
            try c.encode(authMode, forKey: .authMode)
            try c.encodeIfPresent(apiKey, forKey: .apiKey)
            try c.encodeIfPresent(localModelID, forKey: .localModelID)
            if requireApproval { try c.encode(true, forKey: .requireApproval) }
        }
    }

    public var id: UUID
    public var name: String
    /// **Primary** coding agent — the one auto-launched in the first
    /// kitty tab when the session opens. Additional pre-configured
    /// agents live in `additionalTools`.
    public var tool: Tool
    public var authMode: AuthMode

    /// Plaintext API token. Stored encrypted in the profile dir (via
    /// ProfileSecrets), not in the keychain — the agentic-coding base image is
    /// the only consumer and it lives on the same Mac.
    public var apiKey: String?

    /// Other coding agents the user wants available in this profile.
    /// Each gets its env var exported (token mode) and its `<tool>
    /// login` flow callable (subscription mode), but is not
    /// auto-launched — the user runs it manually from a new tab.
    /// Cannot contain the primary tool; uniqued on save.
    public var additionalTools: [ToolSpec]

    /// Absolute host paths of folders shared into the VM. Each folder is
    /// mounted at /home/ubuntu/<basename>. Empty → no folder mounts.
    /// Capped at 8 by the base image's fstab pre-allocation.
    public var folderPaths: [String]

    /// Public half of the SSH key generated for this profile, for the user
    /// to paste into github.com/settings/keys. nil if the user opted out.
    public var sshPublicKey: String?

    /// HTTPS personal-access tokens, one per forge host. Each one is
    /// written to ~/.git-credentials in the VM so plain `git clone https://…`
    /// just works, and (for github.com / gitlab.com) into the matching CLI
    /// config so `gh` / `glab` auth without a separate login step.
    public var gitHTTPSCredentials: [GitHTTPSCredential]

    /// True when a usable github.com credential is present — the VM's `gh`
    /// is then authenticated (GH_TOKEN + ~/.git-credentials, see
    /// SessionDisk), so PR flows like `gh pr create` work. Host matching
    /// mirrors SessionDisk's GH_TOKEN rule.
    public var hasGitHubCredential: Bool {
        gitHTTPSCredentials.contains { cred in
            guard cred.isUsable else { return false }
            let h = cred.host.lowercased()
            return h == "github.com" || h.hasSuffix(".github.com")
        }
    }

    /// User-defined manual swap rules for the MITM proxy. Real values
    /// stay on the host; the VM's env carries fakes. See ManualToken.
    public var manualTokens: [ManualToken]

    /// Pre-existing SSH private keys the user has pointed at this
    /// profile. Loaded into the bromure ssh-agent at every session
    /// launch alongside the auto-generated key.
    public var importedSSHKeys: [ImportedSSHKey]

    /// Plain key=value environment variables exported into the VM via
    /// `proxy.env`. No proxy substitution — meant for non-secret
    /// toggles, log levels, feature flags, etc. Empty by default.
    public var environmentVariables: [EnvironmentVariable]

    /// How aggressively the proxy records traffic for this profile.
    /// Default `.off` — opt-in because higher levels write request/
    /// response bodies (encrypted) to disk.
    public var traceLevel: TraceLevel

    /// When true, sessions running under this profile do NOT stream
    /// metadata to bromure.io even if the Mac is enrolled. The trace
    /// inspector still records locally per `traceLevel`. Default
    /// false — managed mode (= enrolled) implies streaming on; this
    /// flag is the per-profile escape hatch ("I'm prototyping
    /// against my personal Anthropic key, my admin doesn't need to
    /// see this"). Mirrors a similar opt-out on Bromure Web.
    public var privateMode: Bool

    /// When true, the workspace's embedded browser keeps its Chromium profile
    /// (cookies, logins, history) on an encrypted per-workspace disk between
    /// sessions, so the agent stays signed in to sites. Default false — the
    /// browser is fully ephemeral (a clean profile discarded on close).
    public var browserPersistent: Bool

    /// Whether the embedded browser may upload files via the in-page file
    /// picker (and the host file-transfer bridge). Default true.
    public var browserAllowUploads: Bool
    /// Whether the embedded browser may download files. Default true.
    public var browserAllowDownloads: Bool
    /// Whether the embedded browser may use the camera (getUserMedia video).
    /// Default false — the host camera is never exposed unless you opt in.
    public var browserWebcam: Bool
    /// Whether the embedded browser may use the microphone. Default false.
    public var browserMicrophone: Bool

    /// True when a setting that only applies at browser boot differs from
    /// `other`; a live browser must be restarted to pick the change up.
    public func browserBootSettingsDiffer(from other: Profile) -> Bool {
        browserPersistent != other.browserPersistent
            || browserAllowUploads != other.browserAllowUploads
            || browserAllowDownloads != other.browserAllowDownloads
            || browserWebcam != other.browserWebcam
            || browserMicrophone != other.browserMicrophone
    }

    /// **Fusion** configuration. The agents whose answers are fused on a
    /// Claude-Code text turn (any subset of the configured providers, 1–3).
    /// Fusion engages per-session from the title-bar toggle; it's only
    /// engageable when `fusionConfigurable` (≥2 of these have a usable
    /// credential). Empty = nothing selected yet.
    public var fusionLegs: Set<Tool>
    /// Provider whose model judges + synthesizes the fused answer.
    public var fusionJudgeProvider: Tool?
    /// The judge model id (e.g. "claude-opus-4-8", or a local model id when
    /// `fusionJudgeLocal`). nil → engine default.
    public var fusionJudgeModel: String?

    /// **Local Fusion leg** — a local model fused in alongside the cloud
    /// legs (Fusion calls it host-side on the loopback engine). A catalog
    /// id; nil = no local leg. Independent of the per-tool `.local` agent
    /// auth — this is purely "also fuse this local model's answer".
    public var fusionLocalLeg: String?
    /// When true, the Fusion judge runs on the local engine (the model is
    /// `fusionJudgeModel`, a local catalog id) instead of a cloud provider.
    public var fusionJudgeLocal: Bool

    /// **Routing** — top-level, per-profile backend selection for the
    /// coding agent's LLM traffic. Orthogonal to Fusion (which is an
    /// *identity* concern). Selecting `.local` or `.hybrid` auto-engages
    /// MITM interception; the user never flips a separate "mitm on" switch.
    public enum Routing: String, Codable, CaseIterable, Sendable {
        /// Pass-through to the real cloud upstream (today's behaviour).
        case cloud
        /// Always serve from the local on-host inference engine.
        case local
        /// Cloud by default, fall back to local on failure / budget /
        /// split-ratio — the only mode where the policy engine runs.
        case hybrid

        public var displayName: String {
            switch self {
            case .cloud:  return "Cloud"
            case .local:  return "Local"
            case .hybrid: return "Hybrid"
            }
        }
    }

    /// Backend routing for this profile's agent LLM calls. Default `.cloud`.
    public var modelRouting: Routing

    /// Catalog id (or raw HF repo) of the model the local engine should
    /// serve when routing is `.local`/`.hybrid`. nil → engine default /
    /// no model selected yet.
    public var activeModelID: String?

    /// Hybrid-only policy knobs (ignored unless `modelRouting == .hybrid`).
    /// Cloud token budget over a rolling 24 h wall-clock window; `0` =
    /// unlimited. Once exceeded, new sessions route local until the
    /// window slides back under cap.
    public var hybridCloudTokenBudget: Int
    /// Soft fallback threshold: if the cloud upstream emits no first
    /// token within this many seconds, cancel and replay local. Default 5.
    public var hybridSoftTTFTSeconds: Double
    /// Percentage (0–100) of *new sessions* proactively pinned to local
    /// even when cloud is healthy. Applied at session granularity so it
    /// never swaps models mid-trajectory. Default 0.
    public var hybridLocalSplitPercent: Int

    /// Whether the user has consented to swap the Claude subscription
    /// OAuth tokens (access + refresh) on disk for proxy-side fakes.
    /// `unset` = haven't asked yet (proxy will prompt on first clean
    /// `sk-ant-oat01-…` it sees on anthropic.com). `accepted` = swap
    /// is active; the proxy keeps the real tokens and the VM holds
    /// fakes. `declined` = user said "Never for this profile" — proxy
    /// must not prompt or call into the VM agent again for this
    /// profile.
    public var subscriptionTokenSwap: SubscriptionTokenSwapState

    /// Same three-state swap consent as `subscriptionTokenSwap`, but
    /// scoped to the Codex / ChatGPT OAuth tokens (`~/.codex/auth.json`
    /// — access, refresh, id_token). Independent of the Claude one
    /// because a profile may use either or both providers via
    /// `additionalTools`.
    public var codexTokenSwap: SubscriptionTokenSwapState

    /// When set, the host already holds the user's real Claude OAuth
    /// access + refresh tokens — typically because the user said
    /// "save as default" after a swap on a previous profile (or saved
    /// them in Preferences). New sessions for this profile mint fakes
    /// from these reals at boot, register the swap, and seed the VM's
    /// credentials file without prompting. Stored encrypted on disk
    /// alongside the rest of the profile's secrets.
    public var defaultClaudeTokens: StoredOAuthTokens?

    /// Codex equivalent of `defaultClaudeTokens` — access + refresh +
    /// id_token. Same auto-seed-at-boot semantics.
    public var defaultCodexTokens: StoredOAuthTokens?

    /// Pre-configured Kubernetes contexts. At session prep we
    /// generate a synthetic ~/.kube/config in the VM and register the
    /// real credentials with the proxy for upstream substitution.
    public var kubeconfigs: [KubeconfigEntry]

    /// "Guardrails" guard — strips destructive operations from protocols the agent
    /// speaks (Kubernetes first), enforced host-side in the MITM.
    public var guardrails: GuardrailsPolicy

    /// Supply-chain security policy — age-gate package installs,
    /// look up OSV / socket.dev for known-bad versions, strip
    /// install scripts. Enforced host-side in the MITM; the in-VM
    /// `.npmrc` / `pip.conf` can only further restrict, never loosen.
    public var supplyChain: SupplyChainPolicy

    /// Prompt-injection / rogue-instruction detection policy — local
    /// PromptGuard scan of tool_result content + ModernBERT/heuristic scan
    /// of CLAUDE.md authority context. Enforced host-side in the MITM.
    public var promptInjection: PromptInjectionPolicy

    /// DigitalOcean Personal Access Token. Injected as
    /// DIGITALOCEAN_ACCESS_TOKEN env + ~/.config/doctl/config.yaml in
    /// the VM as a fake; proxy swaps to the real value on
    /// api.digitalocean.com requests. Empty = not configured.
    public var digitalOceanToken: String

    /// Linear personal API key (`lin_api_…`). Injected as LINEAR_API_KEY
    /// env in the VM as a fake — SDKs, MCP servers and CLI tools that
    /// honour that variable are authenticated automatically; the proxy
    /// swaps to the real value on linear.app requests (api.linear.app,
    /// mcp.linear.app). Empty = not configured.
    public var linearToken: String

    /// AWS credentials injected into ~/.aws/credentials + environment
    /// for the AWS CLI / SDKs. See `AWSCredentials` for the SigV4
    /// reasoning. Empty struct (`isUsable == false`) = not configured.
    public var awsCredentials: AWSCredentials

    /// When true and the Claude tool is configured, write Bedrock env
    /// vars into `~/.claude/settings.json` so Claude Code uses the AWS
    /// credential chain instead of an Anthropic API key.
    public var bedrockEnabled: Bool

    /// Bedrock model ID, e.g. `us.anthropic.claude-sonnet-4-6-v1:0`.
    /// Empty string uses Claude Code's default.
    public var bedrockModelID: String

    /// Container-registry credentials. One entry per host. Materialized
    /// as ~/.docker/config.json `auths` entries (with FAKE base64 auth
    /// strings); the proxy swaps fake → real on the wire when the
    /// request hits the matching registry host.
    public var dockerRegistries: [DockerRegistryCredential]

    /// HTTPS-accessible databases (Mongo Data API, ClickHouse, Elasticsearch).
    /// Each carries a fake-swapped credential plus a per-endpoint Guardrails
    /// mode so destructive queries can be blocked on the host.
    public var httpDatabases: [HTTPDatabaseEndpoint]

    /// Gate the primary tool's API key behind a consent prompt. See
    /// `ConsentBroker`. Default false.
    public var apiKeyRequiresApproval: Bool

    /// Gate the DigitalOcean PAT behind a consent prompt. Default false.
    public var digitalOceanTokenRequiresApproval: Bool

    /// Gate the Linear API key behind a consent prompt. Default false.
    public var linearTokenRequiresApproval: Bool

    /// Gate the auto-generated bromure SSH key behind a consent prompt
    /// (per-sign). Imported keys carry their own flag on the struct.
    /// Default false.
    public var sshKeyRequiresApproval: Bool

    public var createdAt: Date
    public var lastUsedAt: Date?

    /// The base-image version stamp captured the moment this profile's
    /// disk was clonefile()'d from base.img. Used to detect when the base
    /// has been rebuilt since the clone (so we can offer to reset).
    public var baseImageVersionAtClone: String?

    /// Visual color in the picker sidebar. Optional in JSON for forward
    /// compat — older profile files don't have this field.
    public var color: ProfileColor

    /// Free-form notes the user can attach to a profile (e.g. "work — uses
    /// the staging API key").
    public var comments: String

    /// VM RAM allocation in GB. New profiles default via
    /// `Profile.defaultMemoryGB()` (sized to the host); user can bump
    /// up to 32 in the editor for memory-hungry agents/builds.
    public var memoryGB: Int

    /// Sensible default RAM for a new profile, scaled to host memory.
    /// Same tier idea as the browser, bumped one notch since agent
    /// loads (npm, rust, model context windows) eat more than Chromium:
    ///   <18 GB host → 4 GB VM
    ///   <36 GB host → 6 GB VM
    ///   ≥36 GB host → 8 GB VM
    public static func defaultMemoryGB() -> Int {
        let hostGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        if hostGB < 18 { return 4 }
        if hostGB < 36 { return 6 }
        return 8
    }

    /// Render this workspace's terminal natively on the host (libghostty
    /// surface fed by a PTY over vsock) instead of the guest framebuffer.
    /// Default for new workspaces since plan phase 3; existing profiles
    /// keep whatever they had (decode default false) until edited. Both
    /// paths are views of the same tmux session, so the toggle is safe to
    /// flip between launches. See NATIVE_TERMINAL_PLAN.md.
    public var nativeTerminal: Bool

    /// What to do with the VM when the user closes the session window.
    /// `.suspend` saves RAM to disk and resumes instantly next launch.
    /// `.shutdown` does a clean ACPI poweroff. `.ask` prompts each time.
    public enum CloseAction: String, Codable, CaseIterable, Sendable {
        /// Keep the VM running in the background, detached — reattach later.
        case background
        case suspend
        case shutdown
        case ask

        public var displayName: String {
            switch self {
            case .background: return NSLocalizedString("Run in the background", comment: "")
            case .suspend:    return NSLocalizedString("Suspend", comment: "")
            case .shutdown:   return NSLocalizedString("Shut down", comment: "")
            case .ask:        return NSLocalizedString("Ask", comment: "")
            }
        }
    }

    /// What happens when the user closes a session window: run in the
    /// background (detach, VM keeps running), suspend, shut down, or ask each
    /// time. Defaults to `.ask`.
    public var closeAction: CloseAction

    /// Boot a VM for this profile automatically when the agent starts (at login,
    /// via the LaunchAgent installed while any profile has this on). Default off.
    public var bootAtStartup: Bool

    public enum NetworkMode: String, Codable, CaseIterable, Sendable {
        case nat
        case bridged
        public var displayName: String {
            switch self {
            case .nat:     return "NAT"
            case .bridged: return "Bridged"
            }
        }
    }

    /// Network attachment style. NAT uses VZ's built-in NAT (default,
    /// works everywhere). Bridged puts the VM on the chosen host interface
    /// (LAN-routable IP) via vmnet's bridged mode — entitled by
    /// com.apple.developer.networking.vmnet, not the restricted
    /// com.apple.vm.networking — so it needs a Developer-ID-signed build.
    public var networkMode: NetworkMode

    /// Host interface identifier when `networkMode == .bridged`. nil falls
    /// back to the first available bridged interface at launch time.
    public var bridgedInterfaceID: String?

    public enum CursorShape: String, Codable, CaseIterable, Sendable {
        case block, beam, underline
        public var displayName: String {
            switch self {
            case .block:     return "Block"
            case .beam:      return "Beam (I-cursor)"
            case .underline: return "Underline"
            }
        }
    }

    /// Cursor shape passed to kitty. Default beam matches Terminal.app.
    public var cursorShape: CursorShape

    /// Blinking cursor. Off by default — matches the guest kitty config,
    /// which pins cursor_blink_interval 0. Native terminal surfaces map
    /// this to ghostty's cursor-style-blink.
    public var cursorBlink: Bool

    /// XKB keyboard layout to force inside the VM. nil = auto-match
    /// macOS's currently-selected layout (default), with live updates
    /// when the user switches layouts on the host. Set to e.g. `"fr"`
    /// or `"ch:fr"` to pin a specific layout regardless of macOS state.
    public var keyboardLayoutOverride: String?

    /// X11 `xset r rate` overrides for this profile. nil = match the
    /// host's macOS settings (read live from NSEvent / IOHIDSystem).
    /// Useful when the X-server pipeline makes the host's cadence
    /// feel laggier than typing in a Cocoa app — the typical fix is
    /// to bump the rate ~2× the macOS value. Both clamped at session
    /// launch (`detectKeyRepeat`) so out-of-range values still work.
    public var keyRepeatDelayMs: Int?
    public var keyRepeatRateHz: Int?

    /// Combined window/terminal opacity (0.3–1.0). Applied as both kitty's
    /// `background_opacity` (needs a compositor in the VM to fully take
    /// effect) and the macOS `NSWindow.alphaValue` (works always — gives
    /// the rad see-through-to-the-desktop effect).
    public var windowOpacity: Double

    /// Git identity written to ~/.gitconfig at session prepare time.
    /// Empty → no .gitconfig is generated (system git defaults apply).
    public var gitUserName: String
    public var gitUserEmail: String

    /// Terminal styling. When `useTerminalAppDefaults` is true (default),
    /// kitty inherits the Terminal.app default-profile font + colors
    /// captured at app startup. When false, the four `customX` overrides
    /// are used (with per-field fallback to Terminal defaults if nil).
    public var useTerminalAppDefaults: Bool
    public var customFontFamily: String?
    public var customFontSize: Int?
    public var customBackgroundHex: String?
    public var customForegroundHex: String?

    /// Deprecated: a kitty-era `disable_ligatures` toggle. The native ghostty
    /// path doesn't use it and the editor no longer shows it. Kept for
    /// Codable back-compat with existing profile JSON.
    public var fontLigatures: Bool

    public var mcpServers: [MCPServer]

    /// Where /home/ubuntu lives.
    /// - `.virtiofs` (legacy): a host directory (`profiles/<id>/home`)
    ///   shared into the guest. Inodes churn across suspend/restore and
    ///   git-over-virtiofs is fragile — kept only so existing workspaces
    ///   keep working until the user opts into the upgrade.
    /// - `.ext4`: a sparse raw image (`profiles/<id>/home.img`) attached
    ///   as a second virtio-blk device; the guest agent formats, mounts
    ///   and seeds it. Stable inodes across suspend/restore, real POSIX
    ///   semantics, and the host file shrinks back via fstrim/discard.
    public enum HomeModel: String, Codable, Sendable {
        case virtiofs
        case ext4
    }

    /// Missing in pre-upgrade JSON → decoder defaults to `.virtiofs`.
    /// New profiles are created `.ext4`.
    public var homeModel: HomeModel

    public init(
        id: UUID = UUID(),
        name: String,
        tool: Tool,
        authMode: AuthMode,
        apiKey: String? = nil,
        additionalTools: [ToolSpec] = [],
        folderPaths: [String] = [],
        sshPublicKey: String? = nil,
        gitHTTPSCredentials: [GitHTTPSCredential] = [],
        manualTokens: [ManualToken] = [],
        importedSSHKeys: [ImportedSSHKey] = [],
        environmentVariables: [EnvironmentVariable] = [],
        // .aiDetails by default for new profiles: captures request +
        // response bodies for the well-known LLM hosts (Anthropic,
        // OpenAI, …) so the Trace Inspector has something to show out
        // of the box. Non-AI traffic stays metadata-only; bodies are
        // AES-GCM-sealed at rest. Old profiles loaded from disk keep
        // their stored value (the decoder fallback at TraceLevel.off
        // preserves prior behaviour for pre-field profiles).
        traceLevel: TraceLevel = .aiDetails,
        privateMode: Bool = false,
        browserPersistent: Bool = false,
        browserAllowUploads: Bool = true,
        browserAllowDownloads: Bool = true,
        browserWebcam: Bool = false,
        browserMicrophone: Bool = false,
        fusionLegs: Set<Tool> = [],
        fusionJudgeProvider: Tool? = nil,
        fusionJudgeModel: String? = nil,
        fusionLocalLeg: String? = nil,
        fusionJudgeLocal: Bool = false,
        modelRouting: Routing = .cloud,
        activeModelID: String? = nil,
        hybridCloudTokenBudget: Int = 0,
        hybridSoftTTFTSeconds: Double = 5,
        hybridLocalSplitPercent: Int = 0,
        subscriptionTokenSwap: SubscriptionTokenSwapState = .unset,
        codexTokenSwap: SubscriptionTokenSwapState = .unset,
        defaultClaudeTokens: StoredOAuthTokens? = nil,
        defaultCodexTokens: StoredOAuthTokens? = nil,
        kubeconfigs: [KubeconfigEntry] = [],
        guardrails: GuardrailsPolicy = GuardrailsPolicy(),
        supplyChain: SupplyChainPolicy = SupplyChainPolicy(),
        promptInjection: PromptInjectionPolicy = PromptInjectionPolicy(),
        digitalOceanToken: String = "",
        linearToken: String = "",
        awsCredentials: AWSCredentials = AWSCredentials(),
        bedrockEnabled: Bool = false,
        bedrockModelID: String = "",
        dockerRegistries: [DockerRegistryCredential] = [],
        httpDatabases: [HTTPDatabaseEndpoint] = [],
        apiKeyRequiresApproval: Bool = false,
        digitalOceanTokenRequiresApproval: Bool = false,
        linearTokenRequiresApproval: Bool = false,
        sshKeyRequiresApproval: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        baseImageVersionAtClone: String? = nil,
        color: ProfileColor = .blue,
        comments: String = "",
        memoryGB: Int = Profile.defaultMemoryGB(),
        nativeTerminal: Bool = true,
        networkMode: NetworkMode = .nat,
        bridgedInterfaceID: String? = nil,
        gitUserName: String = "",
        gitUserEmail: String = "",
        useTerminalAppDefaults: Bool = false,
        customFontFamily: String? = nil,
        customFontSize: Int? = nil,
        customBackgroundHex: String? = nil,
        customForegroundHex: String? = nil,
        fontLigatures: Bool = false,
        cursorShape: CursorShape = .block,
        cursorBlink: Bool = false,
        windowOpacity: Double = 0.97,
        keyboardLayoutOverride: String? = nil,
        keyRepeatDelayMs: Int? = nil,
        keyRepeatRateHz: Int? = nil,
        closeAction: CloseAction = .ask,
        bootAtStartup: Bool = false,
        mcpServers: [MCPServer] = [],
        // New profiles get the ext4 home image; only the decoder (old
        // JSON) and the registration scratch profile use .virtiofs.
        homeModel: HomeModel = .ext4
    ) {
        self.id = id
        self.name = name
        self.tool = tool
        self.authMode = authMode
        self.apiKey = apiKey
        self.additionalTools = additionalTools
        self.folderPaths = folderPaths
        self.sshPublicKey = sshPublicKey
        self.gitHTTPSCredentials = gitHTTPSCredentials
        self.manualTokens = manualTokens
        self.importedSSHKeys = importedSSHKeys
        self.environmentVariables = environmentVariables
        self.traceLevel = traceLevel
        self.privateMode = privateMode
        self.browserPersistent = browserPersistent
        self.browserAllowUploads = browserAllowUploads
        self.browserAllowDownloads = browserAllowDownloads
        self.browserWebcam = browserWebcam
        self.browserMicrophone = browserMicrophone
        self.fusionLegs = fusionLegs
        self.fusionJudgeProvider = fusionJudgeProvider
        self.fusionJudgeModel = fusionJudgeModel
        self.fusionLocalLeg = fusionLocalLeg
        self.fusionJudgeLocal = fusionJudgeLocal
        self.modelRouting = modelRouting
        self.activeModelID = activeModelID
        self.hybridCloudTokenBudget = hybridCloudTokenBudget
        self.hybridSoftTTFTSeconds = hybridSoftTTFTSeconds
        self.hybridLocalSplitPercent = hybridLocalSplitPercent
        self.subscriptionTokenSwap = subscriptionTokenSwap
        self.codexTokenSwap = codexTokenSwap
        self.defaultClaudeTokens = defaultClaudeTokens
        self.defaultCodexTokens = defaultCodexTokens
        self.kubeconfigs = kubeconfigs
        self.guardrails = guardrails
        self.supplyChain = supplyChain
        self.promptInjection = promptInjection
        self.digitalOceanToken = digitalOceanToken
        self.linearToken = linearToken
        self.awsCredentials = awsCredentials
        self.bedrockEnabled = bedrockEnabled
        self.bedrockModelID = bedrockModelID
        self.dockerRegistries = dockerRegistries
        self.httpDatabases = httpDatabases
        self.apiKeyRequiresApproval = apiKeyRequiresApproval
        self.digitalOceanTokenRequiresApproval = digitalOceanTokenRequiresApproval
        self.linearTokenRequiresApproval = linearTokenRequiresApproval
        self.sshKeyRequiresApproval = sshKeyRequiresApproval
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.baseImageVersionAtClone = baseImageVersionAtClone
        self.color = color
        self.comments = comments
        self.memoryGB = memoryGB
        self.nativeTerminal = nativeTerminal
        self.networkMode = networkMode
        self.bridgedInterfaceID = bridgedInterfaceID
        self.cursorShape = cursorShape
        self.cursorBlink = cursorBlink
        self.windowOpacity = windowOpacity
        self.keyboardLayoutOverride = keyboardLayoutOverride
        self.keyRepeatDelayMs = keyRepeatDelayMs
        self.keyRepeatRateHz = keyRepeatRateHz
        self.gitUserName = gitUserName
        self.gitUserEmail = gitUserEmail
        self.useTerminalAppDefaults = useTerminalAppDefaults
        self.customFontFamily = customFontFamily
        self.customFontSize = customFontSize
        self.customBackgroundHex = customBackgroundHex
        self.customForegroundHex = customForegroundHex
        self.fontLigatures = fontLigatures
        self.closeAction = closeAction
        self.bootAtStartup = bootAtStartup
        self.mcpServers = mcpServers
        self.homeModel = homeModel
    }

    /// Default-tolerant decoder so old JSON files (missing newer fields) load.
    enum CodingKeys: String, CodingKey {
        case id, name, tool, authMode, apiKey, sshPublicKey
        case folderPath  // legacy: single folder, migrated to folderPaths
        case folderPaths
        case createdAt, lastUsedAt, baseImageVersionAtClone, color, comments
        case memoryGB, nativeTerminal, gitUserName, gitUserEmail
        case useTerminalAppDefaults, customFontFamily, customFontSize
        case customBackgroundHex, customForegroundHex, fontLigatures
        case networkMode, bridgedInterfaceID
        case cursorShape, cursorBlink, windowOpacity, keyboardLayoutOverride
        case keyRepeatDelayMs, keyRepeatRateHz
        case gitHTTPSCredentials
        case additionalTools
        case manualTokens
        case importedSSHKeys
        case environmentVariables
        case traceLevel
        case privateMode
        case browserPersistent
        case browserAllowUploads
        case browserAllowDownloads
        case browserWebcam
        case browserMicrophone
        case fusionEnabled   // legacy; decoded for migration, never encoded
        case fusionLegs
        case fusionJudgeProvider
        case fusionJudgeModel
        case fusionLocalLeg
        case fusionJudgeLocal
        case modelRouting
        case activeModelID
        case hybridCloudTokenBudget
        case hybridSoftTTFTSeconds
        case hybridLocalSplitPercent
        case subscriptionTokenSwap
        case codexTokenSwap
        case kubeconfigs
        case guardrails
        case supplyChain
        case promptInjection
        case digitalOceanToken
        case linearToken
        case awsCredentials
        case bedrockEnabled, bedrockModelID
        case dockerRegistries
        case httpDatabases
        case apiKeyRequiresApproval
        case digitalOceanTokenRequiresApproval
        case linearTokenRequiresApproval
        case sshKeyRequiresApproval
        case closeAction
        case bootAtStartup
        case mcpServers
        case homeModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        name            = try c.decode(String.self, forKey: .name)
        tool            = try c.decode(Tool.self, forKey: .tool)
        authMode        = try c.decode(AuthMode.self, forKey: .authMode)
        apiKey          = try c.decodeIfPresent(String.self, forKey: .apiKey)
        // Migration: old profiles had a single `folderPath`; promote to
        // a one-element folderPaths array.
        if let many = try c.decodeIfPresent([String].self, forKey: .folderPaths) {
            folderPaths = many
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .folderPath),
                  !legacy.isEmpty {
            folderPaths = [legacy]
        } else {
            folderPaths = []
        }
        sshPublicKey    = try c.decodeIfPresent(String.self, forKey: .sshPublicKey)

        createdAt       = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt      = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        baseImageVersionAtClone = try c.decodeIfPresent(String.self, forKey: .baseImageVersionAtClone)
        color           = try c.decodeIfPresent(ProfileColor.self, forKey: .color) ?? .blue
        comments        = try c.decodeIfPresent(String.self, forKey: .comments) ?? ""
        memoryGB        = try c.decodeIfPresent(Int.self, forKey: .memoryGB) ?? 8
        nativeTerminal  = try c.decodeIfPresent(Bool.self, forKey: .nativeTerminal) ?? false
        gitUserName     = try c.decodeIfPresent(String.self, forKey: .gitUserName) ?? ""
        gitUserEmail    = try c.decodeIfPresent(String.self, forKey: .gitUserEmail) ?? ""
        useTerminalAppDefaults = try c.decodeIfPresent(Bool.self, forKey: .useTerminalAppDefaults) ?? true
        customFontFamily       = try c.decodeIfPresent(String.self, forKey: .customFontFamily)
        customFontSize         = try c.decodeIfPresent(Int.self, forKey: .customFontSize)
        customBackgroundHex    = try c.decodeIfPresent(String.self, forKey: .customBackgroundHex)
        customForegroundHex    = try c.decodeIfPresent(String.self, forKey: .customForegroundHex)
        fontLigatures          = try c.decodeIfPresent(Bool.self, forKey: .fontLigatures) ?? false
        networkMode            = try c.decodeIfPresent(NetworkMode.self, forKey: .networkMode) ?? .nat
        bridgedInterfaceID     = try c.decodeIfPresent(String.self, forKey: .bridgedInterfaceID)
        cursorShape            = try c.decodeIfPresent(CursorShape.self, forKey: .cursorShape) ?? .beam
        cursorBlink            = try c.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? false
        windowOpacity          = try c.decodeIfPresent(Double.self, forKey: .windowOpacity) ?? 1.0
        keyboardLayoutOverride = try c.decodeIfPresent(String.self, forKey: .keyboardLayoutOverride)
        keyRepeatDelayMs       = try c.decodeIfPresent(Int.self, forKey: .keyRepeatDelayMs)
        keyRepeatRateHz        = try c.decodeIfPresent(Int.self, forKey: .keyRepeatRateHz)
        gitHTTPSCredentials    = try c.decodeIfPresent([GitHTTPSCredential].self, forKey: .gitHTTPSCredentials) ?? []
        // Strip out any entry that duplicates the primary tool — same
        // tool can't appear twice. Decoder is the right place to enforce
        // since older profiles never had this field, and a manual JSON
        // edit could violate the invariant.
        let rawAdditional = try c.decodeIfPresent([ToolSpec].self, forKey: .additionalTools) ?? []
        var seen: Set<Tool> = [tool]
        var dedup: [ToolSpec] = []
        for spec in rawAdditional where !seen.contains(spec.tool) {
            dedup.append(spec)
            seen.insert(spec.tool)
        }
        additionalTools = dedup
        manualTokens = try c.decodeIfPresent([ManualToken].self, forKey: .manualTokens) ?? []
        importedSSHKeys = try c.decodeIfPresent([ImportedSSHKey].self, forKey: .importedSSHKeys) ?? []
        environmentVariables = try c.decodeIfPresent([EnvironmentVariable].self,
                                                     forKey: .environmentVariables) ?? []
        traceLevel = try c.decodeIfPresent(TraceLevel.self, forKey: .traceLevel) ?? .off
        privateMode = try c.decodeIfPresent(Bool.self, forKey: .privateMode) ?? false
        browserPersistent = try c.decodeIfPresent(Bool.self, forKey: .browserPersistent) ?? false
        browserAllowUploads = try c.decodeIfPresent(Bool.self, forKey: .browserAllowUploads) ?? true
        browserAllowDownloads = try c.decodeIfPresent(Bool.self, forKey: .browserAllowDownloads) ?? true
        browserWebcam = try c.decodeIfPresent(Bool.self, forKey: .browserWebcam) ?? false
        browserMicrophone = try c.decodeIfPresent(Bool.self, forKey: .browserMicrophone) ?? false
        // Fusion config. New keys default to empty/nil. Legacy profiles that
        // had `fusionEnabled == true` migrate to fusing whatever providers they
        // had credentials for — resolved lazily by `fusionConfigurable`, so we
        // just leave legs empty here and let the user pick in the new panel.
        fusionLegs = try c.decodeIfPresent(Set<Tool>.self, forKey: .fusionLegs) ?? []
        fusionJudgeProvider = try c.decodeIfPresent(Tool.self, forKey: .fusionJudgeProvider)
        fusionJudgeModel = try c.decodeIfPresent(String.self, forKey: .fusionJudgeModel)
        fusionLocalLeg = try c.decodeIfPresent(String.self, forKey: .fusionLocalLeg)
        fusionJudgeLocal = try c.decodeIfPresent(Bool.self, forKey: .fusionJudgeLocal) ?? false
        modelRouting = try c.decodeIfPresent(Routing.self, forKey: .modelRouting) ?? .cloud
        activeModelID = try c.decodeIfPresent(String.self, forKey: .activeModelID)
        hybridCloudTokenBudget = try c.decodeIfPresent(Int.self, forKey: .hybridCloudTokenBudget) ?? 0
        hybridSoftTTFTSeconds = try c.decodeIfPresent(Double.self, forKey: .hybridSoftTTFTSeconds) ?? 5
        hybridLocalSplitPercent = try c.decodeIfPresent(Int.self, forKey: .hybridLocalSplitPercent) ?? 0
        subscriptionTokenSwap = try c.decodeIfPresent(SubscriptionTokenSwapState.self,
                                                      forKey: .subscriptionTokenSwap) ?? .unset
        codexTokenSwap = try c.decodeIfPresent(SubscriptionTokenSwapState.self,
                                               forKey: .codexTokenSwap) ?? .unset
        kubeconfigs = try c.decodeIfPresent([KubeconfigEntry].self, forKey: .kubeconfigs) ?? []
        guardrails = try c.decodeIfPresent(GuardrailsPolicy.self, forKey: .guardrails) ?? GuardrailsPolicy()
        supplyChain = try c.decodeIfPresent(SupplyChainPolicy.self, forKey: .supplyChain) ?? SupplyChainPolicy()
        promptInjection = try c.decodeIfPresent(PromptInjectionPolicy.self, forKey: .promptInjection) ?? PromptInjectionPolicy()
        digitalOceanToken = try c.decodeIfPresent(String.self, forKey: .digitalOceanToken) ?? ""
        linearToken = try c.decodeIfPresent(String.self, forKey: .linearToken) ?? ""
        awsCredentials = try c.decodeIfPresent(AWSCredentials.self, forKey: .awsCredentials) ?? AWSCredentials()
        bedrockEnabled = try c.decodeIfPresent(Bool.self, forKey: .bedrockEnabled) ?? false
        bedrockModelID = try c.decodeIfPresent(String.self, forKey: .bedrockModelID) ?? ""
        dockerRegistries = try c.decodeIfPresent([DockerRegistryCredential].self, forKey: .dockerRegistries) ?? []
        httpDatabases = try c.decodeIfPresent([HTTPDatabaseEndpoint].self, forKey: .httpDatabases) ?? []
        apiKeyRequiresApproval = try c.decodeIfPresent(Bool.self, forKey: .apiKeyRequiresApproval) ?? false
        digitalOceanTokenRequiresApproval = try c.decodeIfPresent(Bool.self, forKey: .digitalOceanTokenRequiresApproval) ?? false
        linearTokenRequiresApproval = try c.decodeIfPresent(Bool.self, forKey: .linearTokenRequiresApproval) ?? false
        sshKeyRequiresApproval = try c.decodeIfPresent(Bool.self, forKey: .sshKeyRequiresApproval) ?? false
        closeAction = try c.decodeIfPresent(CloseAction.self, forKey: .closeAction) ?? .ask
        bootAtStartup = try c.decodeIfPresent(Bool.self, forKey: .bootAtStartup) ?? false
        mcpServers = try c.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
        // Pre-upgrade profiles have no homeModel key → they stay on the
        // legacy virtiofs home until the user accepts the migration.
        homeModel = try c.decodeIfPresent(HomeModel.self, forKey: .homeModel) ?? .virtiofs
    }

    /// Explicit encoder — skips the legacy `folderPath` key (we only ever
    /// read it during migration), so the JSON only carries `folderPaths`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(tool, forKey: .tool)
        try c.encode(authMode, forKey: .authMode)
        try c.encodeIfPresent(apiKey, forKey: .apiKey)
        try c.encode(folderPaths, forKey: .folderPaths)
        try c.encodeIfPresent(sshPublicKey, forKey: .sshPublicKey)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try c.encodeIfPresent(baseImageVersionAtClone, forKey: .baseImageVersionAtClone)
        try c.encode(color, forKey: .color)
        try c.encode(comments, forKey: .comments)
        try c.encode(memoryGB, forKey: .memoryGB)
        try c.encode(nativeTerminal, forKey: .nativeTerminal)
        try c.encode(gitUserName, forKey: .gitUserName)
        try c.encode(gitUserEmail, forKey: .gitUserEmail)
        try c.encode(useTerminalAppDefaults, forKey: .useTerminalAppDefaults)
        try c.encodeIfPresent(customFontFamily, forKey: .customFontFamily)
        try c.encodeIfPresent(customFontSize, forKey: .customFontSize)
        try c.encodeIfPresent(customBackgroundHex, forKey: .customBackgroundHex)
        try c.encodeIfPresent(customForegroundHex, forKey: .customForegroundHex)
        try c.encode(fontLigatures, forKey: .fontLigatures)
        try c.encode(networkMode, forKey: .networkMode)
        try c.encodeIfPresent(bridgedInterfaceID, forKey: .bridgedInterfaceID)
        try c.encode(cursorShape, forKey: .cursorShape)
        try c.encode(cursorBlink, forKey: .cursorBlink)
        try c.encode(windowOpacity, forKey: .windowOpacity)
        try c.encodeIfPresent(keyboardLayoutOverride, forKey: .keyboardLayoutOverride)
        try c.encodeIfPresent(keyRepeatDelayMs, forKey: .keyRepeatDelayMs)
        try c.encodeIfPresent(keyRepeatRateHz, forKey: .keyRepeatRateHz)
        if !gitHTTPSCredentials.isEmpty {
            try c.encode(gitHTTPSCredentials, forKey: .gitHTTPSCredentials)
        }
        if !additionalTools.isEmpty {
            try c.encode(additionalTools, forKey: .additionalTools)
        }
        if !manualTokens.isEmpty {
            try c.encode(manualTokens, forKey: .manualTokens)
        }
        if !importedSSHKeys.isEmpty {
            try c.encode(importedSSHKeys, forKey: .importedSSHKeys)
        }
        if !environmentVariables.isEmpty {
            try c.encode(environmentVariables, forKey: .environmentVariables)
        }
        if traceLevel != .off {
            try c.encode(traceLevel, forKey: .traceLevel)
        }
        if browserPersistent {
            try c.encode(browserPersistent, forKey: .browserPersistent)
        }
        // Encode only when non-default so existing profiles stay compact and
        // migrate to the right defaults (uploads/downloads on, media off).
        if !browserAllowUploads { try c.encode(browserAllowUploads, forKey: .browserAllowUploads) }
        if !browserAllowDownloads { try c.encode(browserAllowDownloads, forKey: .browserAllowDownloads) }
        if browserWebcam { try c.encode(browserWebcam, forKey: .browserWebcam) }
        if browserMicrophone { try c.encode(browserMicrophone, forKey: .browserMicrophone) }
        // Only emit privateMode when true — keeps default-config JSON
        // small for the common (managed-mode-streaming) case.
        if privateMode {
            try c.encode(privateMode, forKey: .privateMode)
        }
        // Only emit Fusion config when set, so profiles that never touch
        // Fusion serialize compactly (no spurious diffs). Legacy `fusionEnabled`
        // is intentionally never written back.
        if !fusionLegs.isEmpty {
            try c.encode(fusionLegs, forKey: .fusionLegs)
        }
        if let fusionJudgeProvider {
            try c.encode(fusionJudgeProvider, forKey: .fusionJudgeProvider)
        }
        if let fusionJudgeModel {
            try c.encode(fusionJudgeModel, forKey: .fusionJudgeModel)
        }
        if let fusionLocalLeg, !fusionLocalLeg.isEmpty {
            try c.encode(fusionLocalLeg, forKey: .fusionLocalLeg)
        }
        if fusionJudgeLocal {
            try c.encode(fusionJudgeLocal, forKey: .fusionJudgeLocal)
        }
        // Routing: only emit when non-default so cloud-only profiles stay compact.
        if modelRouting != .cloud {
            try c.encode(modelRouting, forKey: .modelRouting)
        }
        if let activeModelID, !activeModelID.isEmpty {
            try c.encode(activeModelID, forKey: .activeModelID)
        }
        if hybridCloudTokenBudget != 0 {
            try c.encode(hybridCloudTokenBudget, forKey: .hybridCloudTokenBudget)
        }
        if hybridSoftTTFTSeconds != 5 {
            try c.encode(hybridSoftTTFTSeconds, forKey: .hybridSoftTTFTSeconds)
        }
        if hybridLocalSplitPercent != 0 {
            try c.encode(hybridLocalSplitPercent, forKey: .hybridLocalSplitPercent)
        }
        if subscriptionTokenSwap != .unset {
            try c.encode(subscriptionTokenSwap, forKey: .subscriptionTokenSwap)
        }
        if codexTokenSwap != .unset {
            try c.encode(codexTokenSwap, forKey: .codexTokenSwap)
        }
        if !kubeconfigs.isEmpty {
            try c.encode(kubeconfigs, forKey: .kubeconfigs)
        }
        if guardrails.isActive {
            try c.encode(guardrails, forKey: .guardrails)
        }
        // Encode supply-chain unconditionally: its empty/default form
        // already represents "all defaults" via the inner encode()
        // which only emits non-default fields. This means a profile
        // with all-default supply chain (the new-profile state) gets
        // an empty `supplyChain: {}` blob, but adding any non-default
        // toggle gets persisted automatically.
        try c.encode(supplyChain, forKey: .supplyChain)
        try c.encode(promptInjection, forKey: .promptInjection)
        if !digitalOceanToken.isEmpty {
            try c.encode(digitalOceanToken, forKey: .digitalOceanToken)
        }
        if !linearToken.isEmpty {
            try c.encode(linearToken, forKey: .linearToken)
        }
        if awsCredentials.isUsable
            || !awsCredentials.region.isEmpty
            || !awsCredentials.accessKeyID.isEmpty
            || awsCredentials.authMode != .staticKeys {
            try c.encode(awsCredentials, forKey: .awsCredentials)
        }
        if bedrockEnabled { try c.encode(true, forKey: .bedrockEnabled) }
        if !bedrockModelID.isEmpty { try c.encode(bedrockModelID, forKey: .bedrockModelID) }
        if !dockerRegistries.isEmpty {
            try c.encode(dockerRegistries, forKey: .dockerRegistries)
        }
        if !httpDatabases.isEmpty {
            try c.encode(httpDatabases, forKey: .httpDatabases)
        }
        if apiKeyRequiresApproval { try c.encode(true, forKey: .apiKeyRequiresApproval) }
        if digitalOceanTokenRequiresApproval {
            try c.encode(true, forKey: .digitalOceanTokenRequiresApproval)
        }
        if linearTokenRequiresApproval {
            try c.encode(true, forKey: .linearTokenRequiresApproval)
        }
        if sshKeyRequiresApproval { try c.encode(true, forKey: .sshKeyRequiresApproval) }
        try c.encode(closeAction, forKey: .closeAction)
        if bootAtStartup { try c.encode(bootAtStartup, forKey: .bootAtStartup) }
        // Encode homeModel unconditionally: its ABSENCE is what marks a
        // pre-upgrade profile (decoder defaults to .virtiofs), so a new
        // ext4 profile must always carry the key explicitly.
        try c.encode(homeModel, forKey: .homeModel)
        if !mcpServers.isEmpty {
            try c.encode(mcpServers, forKey: .mcpServers)
        }
    }

    /// Every tool configured on this profile, primary first. Each entry
    /// is a self-contained ToolSpec — sites that need to enumerate every
    /// agent (e.g. SessionDisk's api_key.env writer, the welcome message)
    /// can iterate this without caring which one is "primary".
    public var allToolSpecs: [ToolSpec] {
        // The primary tool's local model is the profile-level activeModelID.
        var specs = [ToolSpec(tool: tool, authMode: authMode, apiKey: apiKey,
                              localModelID: activeModelID)]
        // Defensive: filter out any duplicate of the primary in case the
        // editor's invariant slipped (or a JSON edit bypassed the decoder).
        for s in additionalTools where s.tool != tool {
            specs.append(s)
        }
        return specs
    }

    // MARK: - Local Models ↔ Agents sync (Bug#6)

    /// Pin every agent (primary + additional) at the on-host engine. Called when
    /// the user turns on local mode and picks a model in "Local Models", so that
    /// one action configures the workspace's agents — no second trip to the
    /// "Agents" pane. Each `.local` agent serves the profile's `activeModelID`.
    public mutating func setAllAgentsLocal() {
        authMode = .local
        for i in additionalTools.indices { additionalTools[i].authMode = .local }
    }

    /// Undo `setAllAgentsLocal` when local mode is turned off (routing leaves
    /// `.local`): restore each agent's pre-local auth from `prior` so a
    /// subscription isn't clobbered, falling back to `.token`. Only touches
    /// agents currently in `.local` mode, so a manually cloud-configured agent
    /// is left alone.
    public mutating func clearAgentsLocal(restoring prior: [Tool: AuthMode] = [:]) {
        if authMode == .local { authMode = prior[tool] ?? .token }
        for i in additionalTools.indices where additionalTools[i].authMode == .local {
            additionalTools[i].authMode = prior[additionalTools[i].tool] ?? .token
        }
    }

    // MARK: - Fusion eligibility

    /// True when `tool` is enabled in this profile AND has a credential Fusion
    /// can drive as a leg: an API key (token mode), Bedrock (Claude only), or a
    /// subscription (host-side — assumed registered; the leg call fails
    /// gracefully if not). Used for the panel's leg checkboxes + judge picker.
    public func hasUsableCredential(for tool: Tool) -> Bool {
        guard let s = allToolSpecs.first(where: { $0.tool == tool }) else { return false }
        switch s.authMode {
        case .token:
            return !(s.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .bedrock:
            return tool == .claude && awsCredentials.isUsable
        case .subscription:
            return true
        case .local:
            // A tool in local mode has no *cloud* identity, so it isn't a
            // cloud Fusion leg. The local Fusion leg/judge is a standalone
            // backend (`fusionLocalLeg` / `fusionJudgeLocal`), not tied to a
            // tool's credential.
            return false
        }
    }

    /// Providers that can participate in Fusion (enabled + credentialed).
    public var fusionUsableProviders: [Tool] {
        Tool.allCases.filter { hasUsableCredential(for: $0) }
    }

    /// `modelRouting`, but a *pure*-`.local` route with no agent actually in
    /// `.local` auth mode is downgraded to `.cloud`.
    ///
    /// `modelRouting == .local` is the mechanism that reroutes a cloud-auth
    /// agent's LLM calls (e.g. to `api.anthropic.com`) onto the on-host MLX
    /// engine. That only makes sense when an agent is genuinely meant to run
    /// locally. If a profile is flagged `.local` yet **no** tool is in `.local`
    /// auth mode — e.g. a subscription Claude that still has a model selected —
    /// honoring it would short-circuit the agent's management calls and reroute
    /// `/v1/messages` into the engine, returning empty/garbled 200s instead of
    /// the real subscription response. Treat that as cloud. `.hybrid` (a
    /// deliberate cloud+local split for a cloud-auth agent) is left untouched.
    public var effectiveModelRouting: Routing {
        if modelRouting == .local,
           !allToolSpecs.contains(where: { $0.authMode == .local }) {
            return .cloud
        }
        return modelRouting
    }

    /// Base domains of the cloud providers whose agent is in `.local` auth
    /// mode. The proxy uses this to keep routing *per-agent* in a mixed
    /// profile: only a host owned by a genuinely-local agent gets short-
    /// circuited / rerouted to the engine, so a subscription Claude sharing a
    /// VM with a local Codex still reaches `api.anthropic.com`.
    public var localProviderCloudHosts: Set<String> {
        var hosts: Set<String> = []
        for spec in allToolSpecs where spec.authMode == .local {
            switch spec.tool {
            case .claude: hosts.insert("anthropic.com")
            case .codex:  hosts.formUnion(["openai.com", "chatgpt.com"])
            case .grok:   hosts.formUnion(["x.ai", "grok.com"])
            }
        }
        return hosts
    }

    /// The model id the on-host engine should serve for this profile, or
    /// nil if no local inference is needed. Single-engine phase: one model.
    /// A tool explicitly in `.local` mode wins (primary first); otherwise
    /// Local/Hybrid routing needs the active model served too.
    public var localEngineModelID: String? {
        // Any agent in `.local` mode serves the profile's single active model.
        if allToolSpecs.contains(where: { $0.authMode == .local }),
           let m = activeModelID, !m.isEmpty { return m }
        // A local Fusion leg or judge also needs the engine serving its model.
        if let m = fusionLocalLeg, !m.isEmpty { return m }
        if fusionJudgeLocal, let m = fusionJudgeModel, !m.isEmpty { return m }
        if effectiveModelRouting != .cloud, let m = activeModelID, !m.isEmpty { return m }
        return nil
    }

    /// Every distinct local model this profile would load — per-tool `.local`
    /// agents, the Fusion local leg + judge, and the active/routing model.
    /// Used to warn when their combined memory approaches the host's, since
    /// the engine can serve several at once (parallel models).
    public var distinctLocalModelIDs: [String] {
        var ids = Set<String>()
        // Every `.local` agent (primary or additional) serves activeModelID.
        if allToolSpecs.contains(where: { $0.authMode == .local }),
           let m = activeModelID { ids.insert(m) }
        if let m = fusionLocalLeg { ids.insert(m) }
        if fusionJudgeLocal, let m = fusionJudgeModel { ids.insert(m) }
        if effectiveModelRouting != .cloud, let m = activeModelID { ids.insert(m) }
        return ids.filter { !$0.isEmpty }.sorted()
    }

    /// Whether Fusion can be engaged for this profile: at least two providers
    /// have a usable credential. Gates the title-bar toggle; the actual legs
    /// used are `fusionLegs` (intersected with usable providers) at runtime.
    public var fusionConfigurable: Bool {
        // Cloud providers with creds, plus the local leg if one is selected.
        fusionUsableProviders.count + ((fusionLocalLeg?.isEmpty == false) ? 1 : 0) >= 2
    }

    /// Resolve the final styling for this profile. Each `customX` field
    /// overrides Terminal.app's value; missing fields fall through to the
    /// Terminal default. The legacy `useTerminalAppDefaults` flag is no
    /// longer consulted — it's preserved on disk for backward compat
    /// only, since older profiles with that flag set true used to make
    /// `customX` get silently ignored (the bug that ate font picks).
    ///
    /// Font names starting with `.` (e.g. `.AppleSystemUIFont`) are
    /// macOS-internal identifiers that Linux fontconfig cannot resolve;
    /// kitty silently falls back when handed one. We rewrite to the
    /// always-installed JetBrains Mono instead.
    public func resolveStyle(against terminalDefaults: TerminalAppDefaults) -> TerminalAppDefaults {
        let raw = customFontFamily ?? terminalDefaults.fontFamily
        let safeFamily = (raw.hasPrefix(".") || raw.isEmpty) ? "JetBrains Mono" : raw
        return TerminalAppDefaults(
            fontFamily:     safeFamily,
            fontSize:       customFontSize     ?? terminalDefaults.fontSize,
            backgroundHex:  customBackgroundHex ?? terminalDefaults.backgroundHex,
            foregroundHex:  customForegroundHex ?? terminalDefaults.foregroundHex
        )
    }
}

/// Real OAuth tokens captured from a `claude login` / `codex login`
/// flow inside the VM, stored on the host so the proxy can swap them
/// onto the wire and so future sessions don't require re-login.
/// Always lives in the encrypted secrets blob, never in profile.json.
public struct StoredOAuthTokens: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// Codex carries an `id_token` alongside access/refresh; Claude
    /// doesn't. Optional so one struct serves both providers.
    public let idToken: String?
    public let savedAt: Date

    public init(accessToken: String, refreshToken: String,
                idToken: String? = nil, savedAt: Date = Date()) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.savedAt = savedAt
    }
}

/// At-rest secret payload — everything that should never appear on
/// disk in plaintext. ProfileStore extracts these out of the in-memory
/// Profile before serialising profile.json, AES-GCM-encrypts the
/// JSON-encoded form with the keychain master key, and writes
/// `secrets.enc` next to it.
///
/// Every field is keyed by the parent collection's stable id (the
/// `additionalTools[].tool.rawValue`, the `gitHTTPSCredentials[].id`,
/// etc.) so editor reorderings don't desync secrets from their slots.
struct ProfileSecrets: Codable {
    var apiKey: String?
    /// Keyed by `Tool.rawValue` ("claude", "codex").
    var additionalToolApiKeys: [String: String]
    /// Keyed by `GitHTTPSCredential.id.uuidString`.
    var gitHTTPSTokens: [String: String]
    /// Keyed by `ManualToken.id.uuidString`.
    var manualTokenValues: [String: String]
    /// Whole kubeconfig entries, in their entirety. Cert PEMs, exec
    /// commands, tokens — too sensitive to ever sit in profile.json.
    var kubeconfigs: [KubeconfigEntry]?
    /// DigitalOcean PAT.
    var digitalOceanToken: String?
    /// Linear personal API key. Optional so older `secrets.enc` blobs
    /// (written before this field existed) keep decoding cleanly.
    var linearToken: String?
    /// AWS secret access key + session token (the two real secrets in
    /// an AWS credential set — accessKeyID is identity-only).
    var awsSecretAccessKey: String?
    var awsSessionToken: String?
    /// Keyed by `DockerRegistryCredential.id.uuidString`. Holds the
    /// raw registry password / access token; the host + username live
    /// in profile.json since they're identity, not secret. Optional so
    /// older `secrets.enc` blobs (written before this field existed)
    /// keep decoding cleanly.
    var dockerRegistryPasswords: [String: String]?
    /// HTTPS-database real secrets. Keyed by HTTPDatabaseEndpoint.id.uuidString.
    /// Optional for forward-compat with older `secrets.enc` blobs.
    var httpDatabaseSecrets: [String: String]?
    /// Real OAuth bearer pairs for the subscription-token swap path.
    /// When set, new sessions for this profile auto-seed the VM's
    /// credentials file with proxy-side fakes derived from these
    /// reals; on the wire the proxy swaps fakes back to reals.
    var defaultClaudeTokens: StoredOAuthTokens?
    var defaultCodexTokens: StoredOAuthTokens?
    /// MCP server bearer tokens. Keyed by MCPServer.id.uuidString.
    var mcpBearerTokens: [String: String]?
    /// MCP OAuth state blobs. Keyed by MCPServer.id.uuidString.
    var mcpOAuthStates: [String: MCPOAuthState]?
    /// MCP server environment-variable values (commonly API keys).
    /// Keyed by "<serverID>/<variableID>". Optional for forward-compat.
    var mcpEnvironmentValues: [String: String]?
    /// MCP raw-JSON config blobs (free-form — can embed OAuth blocks and
    /// tokens, so treated as secret wholesale). Keyed by MCPServer.id.
    var mcpRawJSONs: [String: String]?
    /// Profile-level environment-variable values. Documented as non-secret,
    /// but nothing stops a user from putting a key in one — so they're
    /// write-only over the remote export path like everything else here.
    /// Keyed by EnvironmentVariable.id.uuidString.
    var environmentVariableValues: [String: String]?

    var isEmpty: Bool {
        (apiKey?.isEmpty ?? true)
            && additionalToolApiKeys.isEmpty
            && gitHTTPSTokens.isEmpty
            && manualTokenValues.isEmpty
            && (kubeconfigs?.isEmpty ?? true)
            && (digitalOceanToken?.isEmpty ?? true)
            && (linearToken?.isEmpty ?? true)
            && (awsSecretAccessKey?.isEmpty ?? true)
            && (awsSessionToken?.isEmpty ?? true)
            && (dockerRegistryPasswords?.isEmpty ?? true)
            && defaultClaudeTokens == nil
            && defaultCodexTokens == nil
            && (mcpBearerTokens?.isEmpty ?? true)
            && (mcpOAuthStates?.isEmpty ?? true)
            && (mcpEnvironmentValues?.isEmpty ?? true)
            && (mcpRawJSONs?.isEmpty ?? true)
            && (environmentVariableValues?.isEmpty ?? true)
    }

    /// Pull every secret string out of the profile, replacing them
    /// with empty placeholders, and return the harvested set.
    static func extract(stripping profile: inout Profile) -> ProfileSecrets {
        var s = ProfileSecrets(apiKey: nil,
                               additionalToolApiKeys: [:],
                               gitHTTPSTokens: [:],
                               manualTokenValues: [:])

        if let k = profile.apiKey, !k.isEmpty {
            s.apiKey = k
            profile.apiKey = nil
        }

        for (i, spec) in profile.additionalTools.enumerated() {
            if let k = spec.apiKey, !k.isEmpty {
                s.additionalToolApiKeys[spec.tool.rawValue] = k
                profile.additionalTools[i].apiKey = nil
            }
        }

        for (i, cred) in profile.gitHTTPSCredentials.enumerated() {
            if !cred.token.isEmpty {
                s.gitHTTPSTokens[cred.id.uuidString] = cred.token
                profile.gitHTTPSCredentials[i].token = ""
            }
        }

        for (i, t) in profile.manualTokens.enumerated() {
            if !t.realValue.isEmpty {
                s.manualTokenValues[t.id.uuidString] = t.realValue
                profile.manualTokens[i].realValue = ""
            }
        }

        if !profile.kubeconfigs.isEmpty {
            s.kubeconfigs = profile.kubeconfigs
            profile.kubeconfigs = []
        }
        if !profile.digitalOceanToken.isEmpty {
            s.digitalOceanToken = profile.digitalOceanToken
            profile.digitalOceanToken = ""
        }
        if !profile.linearToken.isEmpty {
            s.linearToken = profile.linearToken
            profile.linearToken = ""
        }
        if !profile.awsCredentials.secretAccessKey.isEmpty {
            s.awsSecretAccessKey = profile.awsCredentials.secretAccessKey
            profile.awsCredentials.secretAccessKey = ""
        }
        if !profile.awsCredentials.sessionToken.isEmpty {
            s.awsSessionToken = profile.awsCredentials.sessionToken
            profile.awsCredentials.sessionToken = ""
        }

        for (i, reg) in profile.dockerRegistries.enumerated() {
            if !reg.password.isEmpty {
                if s.dockerRegistryPasswords == nil { s.dockerRegistryPasswords = [:] }
                s.dockerRegistryPasswords?[reg.id.uuidString] = reg.password
                profile.dockerRegistries[i].password = ""
            }
        }

        for (i, db) in profile.httpDatabases.enumerated() {
            if !db.secret.isEmpty {
                if s.httpDatabaseSecrets == nil { s.httpDatabaseSecrets = [:] }
                s.httpDatabaseSecrets?[db.id.uuidString] = db.secret
                profile.httpDatabases[i].secret = ""
            }
        }

        if let t = profile.defaultClaudeTokens {
            s.defaultClaudeTokens = t
            profile.defaultClaudeTokens = nil
        }
        if let t = profile.defaultCodexTokens {
            s.defaultCodexTokens = t
            profile.defaultCodexTokens = nil
        }

        for (i, server) in profile.mcpServers.enumerated() {
            if !server.bearerToken.isEmpty {
                if s.mcpBearerTokens == nil { s.mcpBearerTokens = [:] }
                s.mcpBearerTokens?[server.id.uuidString] = server.bearerToken
                profile.mcpServers[i].bearerToken = ""
            }
            if let oauth = server.oauthState {
                if s.mcpOAuthStates == nil { s.mcpOAuthStates = [:] }
                s.mcpOAuthStates?[server.id.uuidString] = oauth
                profile.mcpServers[i].oauthState = nil
            }
            for (j, env) in server.environment.enumerated() where !env.value.isEmpty {
                if s.mcpEnvironmentValues == nil { s.mcpEnvironmentValues = [:] }
                s.mcpEnvironmentValues?["\(server.id.uuidString)/\(env.id.uuidString)"] = env.value
                profile.mcpServers[i].environment[j].value = ""
            }
            if !server.rawJSON.isEmpty {
                if s.mcpRawJSONs == nil { s.mcpRawJSONs = [:] }
                s.mcpRawJSONs?[server.id.uuidString] = server.rawJSON
                profile.mcpServers[i].rawJSON = ""
            }
        }

        for (i, env) in profile.environmentVariables.enumerated() where !env.value.isEmpty {
            if s.environmentVariableValues == nil { s.environmentVariableValues = [:] }
            s.environmentVariableValues?[env.id.uuidString] = env.value
            profile.environmentVariables[i].value = ""
        }

        return s
    }

    /// Mutates the profile to restore secrets onto the matching
    /// fields. Missing keys are tolerated — they leave the field
    /// empty, which the editor will surface as "needs re-entry".
    func apply(to profile: inout Profile) {
        if let k = apiKey { profile.apiKey = k }

        for (i, spec) in profile.additionalTools.enumerated() {
            if let k = additionalToolApiKeys[spec.tool.rawValue] {
                profile.additionalTools[i].apiKey = k
            }
        }

        for (i, cred) in profile.gitHTTPSCredentials.enumerated() {
            if let t = gitHTTPSTokens[cred.id.uuidString] {
                profile.gitHTTPSCredentials[i].token = t
            }
        }

        for (i, t) in profile.manualTokens.enumerated() {
            if let v = manualTokenValues[t.id.uuidString] {
                profile.manualTokens[i].realValue = v
            }
        }

        if let kcs = kubeconfigs { profile.kubeconfigs = kcs }
        if let do_ = digitalOceanToken { profile.digitalOceanToken = do_ }
        if let lin = linearToken { profile.linearToken = lin }
        if let sk = awsSecretAccessKey { profile.awsCredentials.secretAccessKey = sk }
        if let st = awsSessionToken { profile.awsCredentials.sessionToken = st }
        if let map = dockerRegistryPasswords {
            for (i, reg) in profile.dockerRegistries.enumerated() {
                if let p = map[reg.id.uuidString] {
                    profile.dockerRegistries[i].password = p
                }
            }
        }
        if let map = httpDatabaseSecrets {
            for (i, db) in profile.httpDatabases.enumerated() {
                if let sec = map[db.id.uuidString] {
                    profile.httpDatabases[i].secret = sec
                }
            }
        }
        if let t = defaultClaudeTokens { profile.defaultClaudeTokens = t }
        if let t = defaultCodexTokens { profile.defaultCodexTokens = t }
        if let map = mcpBearerTokens {
            for (i, server) in profile.mcpServers.enumerated() {
                if let t = map[server.id.uuidString] {
                    profile.mcpServers[i].bearerToken = t
                }
            }
        }
        if let map = mcpOAuthStates {
            for (i, server) in profile.mcpServers.enumerated() {
                if let state = map[server.id.uuidString] {
                    profile.mcpServers[i].oauthState = state
                }
            }
        }
        if let map = mcpEnvironmentValues {
            for (i, server) in profile.mcpServers.enumerated() {
                for (j, env) in server.environment.enumerated() {
                    if let v = map["\(server.id.uuidString)/\(env.id.uuidString)"] {
                        profile.mcpServers[i].environment[j].value = v
                    }
                }
            }
        }
        if let map = mcpRawJSONs {
            for (i, server) in profile.mcpServers.enumerated() {
                if let raw = map[server.id.uuidString] {
                    profile.mcpServers[i].rawJSON = raw
                }
            }
        }
        if let map = environmentVariableValues {
            for (i, env) in profile.environmentVariables.enumerated() {
                if let v = map[env.id.uuidString] {
                    profile.environmentVariables[i].value = v
                }
            }
        }
    }

    /// Overlay the non-empty secrets from `newer` on top of `self`.
    /// `self` is the workspace's *existing* on-disk secret set; `newer`
    /// is whatever the caller actually supplied in an edit (harvested via
    /// `extract`, so it only ever holds values the caller typed). Used by
    /// the headless update path: a profile document round-tripped through
    /// `describe`/export comes back with blank secrets, so without this a
    /// save would wipe every stored secret. Keys the caller left blank
    /// keep their existing value; keys the caller set are replaced.
    mutating func overlay(with newer: ProfileSecrets) {
        if let v = newer.apiKey { apiKey = v }
        additionalToolApiKeys.merge(newer.additionalToolApiKeys) { _, n in n }
        gitHTTPSTokens.merge(newer.gitHTTPSTokens) { _, n in n }
        manualTokenValues.merge(newer.manualTokenValues) { _, n in n }
        // Kube round-trips through the redacted export with blank auth. Merge per
        // id so an identity/guardrail edit (name, requireApproval, …) applies while
        // a blank auth keeps the stored cert/token; a real incoming auth still wins.
        // (Only the redacted round-trip paths call overlay; local saves persist the
        // full profile directly, so this never suppresses a local deletion.)
        if let incoming = newer.kubeconfigs, !incoming.isEmpty {
            var merged = kubeconfigs ?? []
            for e in incoming {
                if let i = merged.firstIndex(where: { $0.id == e.id }) {
                    let stored = merged[i]
                    merged[i] = e                    // identity + guardrail edits from the caller
                    // Auth and CA are both redacted on the wire (redactedIdentity):
                    // keep whatever the caller didn't re-enter, so an unrelated edit
                    // (or a token change) can't silently drop the stored cert/token.
                    if e.auth.isBlank      { merged[i].auth = stored.auth }
                    if e.caCertPEM.isEmpty { merged[i].caCertPEM = stored.caCertPEM }
                } else {
                    merged.append(e)
                }
            }
            kubeconfigs = merged
        }
        if let v = newer.digitalOceanToken { digitalOceanToken = v }
        if let v = newer.linearToken { linearToken = v }
        if let v = newer.awsSecretAccessKey { awsSecretAccessKey = v }
        if let v = newer.awsSessionToken { awsSessionToken = v }
        if let m = newer.dockerRegistryPasswords {
            dockerRegistryPasswords = (dockerRegistryPasswords ?? [:]).merging(m) { _, n in n }
        }
        if let m = newer.httpDatabaseSecrets {
            httpDatabaseSecrets = (httpDatabaseSecrets ?? [:]).merging(m) { _, n in n }
        }
        if let v = newer.defaultClaudeTokens { defaultClaudeTokens = v }
        if let v = newer.defaultCodexTokens { defaultCodexTokens = v }
        if let m = newer.mcpBearerTokens {
            mcpBearerTokens = (mcpBearerTokens ?? [:]).merging(m) { _, n in n }
        }
        if let m = newer.mcpOAuthStates {
            mcpOAuthStates = (mcpOAuthStates ?? [:]).merging(m) { _, n in n }
        }
        if let m = newer.mcpEnvironmentValues {
            mcpEnvironmentValues = (mcpEnvironmentValues ?? [:]).merging(m) { _, n in n }
        }
        if let m = newer.mcpRawJSONs {
            mcpRawJSONs = (mcpRawJSONs ?? [:]).merging(m) { _, n in n }
        }
        if let m = newer.environmentVariableValues {
            environmentVariableValues = (environmentVariableValues ?? [:]).merging(m) { _, n in n }
        }
    }
}

/// Centralized profile-UUID → MAC-address mapping, persisted as
/// `profile-macs.json` under the AC application-support root. Each
/// profile gets one stable MAC the first time it launches and keeps
/// it forever — that's what makes `restoreMachineStateFrom` work
/// across launches (VZ rejects mismatched MACs) and keeps vmnet's
/// DHCP lease table stable per profile.
///
/// File layout:
///   ```
///   { "<uuid>": "02:ab:cd:ef:01:02", ... }
///   ```
///
/// One file per host, NSLock-guarded for concurrent access from
/// multiple AC sessions in the same app run. Profile deletion drops
/// the entry via `release(profileID:)`.
public final class MACBindings: @unchecked Sendable {
    public static let shared = MACBindings()

    private let fileURL: URL
    private let lock = NSLock()
    private var bindings: [String: String] = [:]
    private var loaded = false

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("profile-macs.json")
    }

    /// Look up the MAC for `profileID`, minting a fresh one (and
    /// persisting it) on first call. Locally-administered unicast
    /// (`02:` prefix) so it never collides with a real OUI.
    public func macAddress(for profileID: UUID) -> String {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        let key = profileID.uuidString
        if let existing = bindings[key] { return existing }
        let mac = Self.generate()
        bindings[key] = mac
        saveLocked()
        return mac
    }

    /// Drop the mapping for a profile that's being deleted. No-op if
    /// no entry exists.
    public func release(profileID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        if bindings.removeValue(forKey: profileID.uuidString) != nil {
            saveLocked()
        }
    }

    private func loadLocked() {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        bindings = dict
    }

    private func saveLocked() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bindings) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // Local-only — exclude from iCloud / Time Machine.
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func generate() -> String {
        let b1 = UInt8.random(in: 0...255)
        let b2 = UInt8.random(in: 0...255)
        let b3 = UInt8.random(in: 0...255)
        let b4 = UInt8.random(in: 0...255)
        let b5 = UInt8.random(in: 0...255)
        return String(format: "02:%02x:%02x:%02x:%02x:%02x", b1, b2, b3, b4, b5)
    }
}

/// Reads / writes profiles under ~/Library/Application Support/BromureAC/profiles/<id>/.
/// Each profile dir holds:
///   profile.json   — the Profile struct
///   disk.img       — CoW clone of base.img, written by the VM
///   ssh/id_ed25519, ssh/id_ed25519.pub  — the profile's SSH keypair (if any)
public final class ProfileStore {
    private let rootDir: URL
    private let fm = FileManager.default

    public init(rootDir: URL? = nil) {
        if let rootDir {
            self.rootDir = rootDir
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            self.rootDir = appSupport
                .appendingPathComponent("BromureAC", isDirectory: true)
                .appendingPathComponent("profiles", isDirectory: true)
        }
    }

    public var profilesDirectory: URL { rootDir }

    /// Unix-domain control socket for the CLI ↔ agent control plane. Sits at
    /// ~/Library/Application Support/BromureAC/control.sock (next to the
    /// profiles dir), owner-only (chmod 0600) — reaching it proves local
    /// ownership, which is the access gate for `exec` / `vm` operations.
    public var controlSocketURL: URL {
        rootDir.deletingLastPathComponent()
            .appendingPathComponent("control.sock")
    }

    /// Where the templated "default profile" (Bromure → Preferences…)
    /// is persisted. Sits next to the profiles dir, not inside it, so
    /// `loadAll()` doesn't surface it as a real profile in the picker.
    public var templateURL: URL {
        rootDir.deletingLastPathComponent()
            .appendingPathComponent("profile-template.json")
    }
    /// Encrypted secrets blob for the template (default OAuth tokens
    /// + any other secrets the user pre-set in Preferences). Same
    /// AES-GCM layout as a regular profile's `secrets.enc`.
    public var templateSecretsURL: URL {
        rootDir.deletingLastPathComponent()
            .appendingPathComponent("profile-template.enc")
    }

    /// Stable identity of the template Profile. Picked deliberately
    /// out of the random-UUID space so any code path that filters
    /// `profile.id == .templateID` can route to template-specific
    /// behaviour without ambiguity.
    public static let templateID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    /// Load the user's preferences template, or a factory default if
    /// none has been saved yet. Always returns a valid Profile —
    /// downstream code can treat the template like any other profile.
    public func loadTemplate() -> Profile {
        var template: Profile
        if let data = try? Data(contentsOf: templateURL),
           let decoded = try? JSONDecoder.iso8601().decode(Profile.self, from: data) {
            template = decoded
        } else {
            template = Profile(
                id: Self.templateID,
                name: "Defaults",
                tool: .claude,
                authMode: .subscription,
                guardrails: GuardrailsPolicy.defaultForNewProfile())
        }
        // Force the canonical id/name so the user can't accidentally
        // shadow a real profile by saving over the template.
        template.id = Self.templateID
        template.name = "Defaults"
        // The template never has a home of its own, and profiles derived
        // from it must get the modern ext4 home — a template persisted
        // before the upgrade would otherwise decode as .virtiofs and
        // stamp every NEW workspace legacy.
        template.homeModel = .ext4
        // Merge the encrypted secrets blob (default OAuth tokens etc).
        let blobURL = templateSecretsURL
        if let cipher = try? Data(contentsOf: blobURL),
           let plain = try? SecretsVault.decrypt(cipher),
           let secrets = try? JSONDecoder().decode(ProfileSecrets.self, from: plain) {
            secrets.apply(to: &template)
        }
        return template
    }

    /// Persist the user's preferences template. Splits secrets the
    /// same way regular profiles do.
    public func saveTemplate(_ template: Profile) throws {
        var stripped = template
        stripped.id = Self.templateID
        stripped.name = "Defaults"
        let secrets = ProfileSecrets.extract(stripping: &stripped)
        let data = try JSONEncoder.iso8601().encode(stripped)
        try fm.createDirectory(at: templateURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try data.write(to: templateURL, options: .atomic)
        let blobURL = templateSecretsURL
        if secrets.isEmpty {
            try? fm.removeItem(at: blobURL)
        } else {
            let plain = try JSONEncoder().encode(secrets)
            let cipher = try SecretsVault.encrypt(plain)
            try cipher.write(to: blobURL, options: .atomic)
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: blobURL.path)
        }
    }

    /// Fork a fresh, save-ready Profile from the user's template.
    /// Generates a new UUID + createdAt; everything else (settings,
    /// default OAuth tokens, kubeconfigs, etc.) is copied through
    /// from the template — including the template's primary agent and
    /// its auth mode, so a new profile honors the user's Preferences
    /// default (e.g. Claude in subscription mode). `tool`/`authMode`
    /// are optional overrides; leave them nil to keep the template's.
    public func newProfileFromTemplate(name: String,
                                        tool: Profile.Tool? = nil,
                                        authMode: Profile.AuthMode? = nil) -> Profile {
        var p = loadTemplate()
        p.id = UUID()
        p.name = name
        if let tool { p.tool = tool }
        if let authMode { p.authMode = authMode }
        p.createdAt = Date()
        p.lastUsedAt = nil
        p.baseImageVersionAtClone = nil
        return p
    }

    public func profileDirectory(for profile: Profile) -> URL {
        rootDir.appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }

    public func diskURL(for profile: Profile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("disk.img")
    }

    /// The host-side dir mounted as /home/ubuntu in the guest (legacy
    /// `.virtiofs` home model). Persistent across `Reset disk` — anything
    /// the user installs into their home (npm-global, cargo, .ssh,
    /// .bash_history, etc.) survives.
    public func homeDirectory(for profile: Profile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("home", isDirectory: true)
    }

    /// Sparse raw ext4 image backing /home/ubuntu for `.ext4`-model
    /// profiles. Created as an all-holes file (apparent size fixed,
    /// allocated size ~0); the guest agent formats it on first boot and
    /// fstrim/discard punches freed blocks back out of the host file.
    public func homeImageURL(for profile: Profile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("home.img")
    }

    /// Tiny host dir attached as the `bromure-home` virtiofs tag for
    /// `.ext4`-model profiles. Existing base images' fstab mounts that tag
    /// at /home/ubuntu, and tty1's autologin shell sources its
    /// `.bash_profile` — which is how the guest agent gets bootstrapped on
    /// a freshly-cloned system disk (nothing else Bromure controls runs
    /// that early). The agent then mounts the ext4 home image OVER
    /// /home/ubuntu, shadowing this dir for the rest of the boot.
    public func bootstrapHomeDirectory(for profile: Profile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("boot-home", isDirectory: true)
    }

    /// Where the pre-migration virtiofs home is parked after a successful
    /// move into home.img. Kept so a migration the user regrets (or a bug)
    /// loses nothing; surfaced in the storage UI for deletion.
    public func homeBackupDirectory(for profile: Profile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("home.pre-ext4", isDirectory: true)
    }

    /// Write the bootstrap home for an `.ext4` profile: just the managed
    /// `.bash_profile` (hostname + agentd bootstrap). No `.bashrc` — the
    /// real dotfiles live in the ext4 image, seeded by the guest agent.
    public func prepareBootstrapHomeDirectory(for profile: Profile) throws {
        let dir = bootstrapHomeDirectory(for: profile)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o755)])
        try Self.bashProfileContent.write(
            to: dir.appendingPathComponent(".bash_profile"),
            atomically: true, encoding: .utf8)
    }

    /// Legacy SSH dir (pre-home-mount profiles). Kept so we can migrate.
    public func sshDirectory(for profile: Profile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("ssh", isDirectory: true)
    }

    public func loadAll() -> [Profile] {
        guard let entries = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var profiles: [Profile] = []
        for entry in entries where entry.hasDirectoryPath {
            let json = entry.appendingPathComponent("profile.json")
            let blobURL = entry.appendingPathComponent("secrets.enc")
            guard fm.fileExists(atPath: json.path),
                  let data = try? Data(contentsOf: json),
                  var profile = try? JSONDecoder.iso8601().decode(Profile.self, from: data) else {
                continue
            }

            // Migration: pre-encryption profile.json carried tokens
            // in plaintext. If the encrypted blob doesn't exist and
            // the in-memory profile has secrets, re-save once now.
            // That writes secrets.enc + a scrubbed profile.json,
            // leaving disk in the new format with no plaintext.
            let needsMigration = !fm.fileExists(atPath: blobURL.path)
                && hasInlineSecrets(profile)
            if !needsMigration {
                mergeSecrets(into: &profile, dir: entry)
            }
            profiles.append(profile)

            if needsMigration {
                do {
                    try save(profile)
                    FileHandle.standardError.write(Data(
                        "[vault] migrated profile '\(profile.name)' to encrypted secrets store\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data(
                        "[vault] migration failed for '\(profile.name)': \(error)\n".utf8))
                }
            }
        }
        return profiles.sorted { (a, b) in
            (a.lastUsedAt ?? a.createdAt) > (b.lastUsedAt ?? b.createdAt)
        }
    }

    private func hasInlineSecrets(_ profile: Profile) -> Bool {
        if let k = profile.apiKey, !k.isEmpty { return true }
        if profile.additionalTools.contains(where: { ($0.apiKey ?? "").isEmpty == false }) {
            return true
        }
        if profile.gitHTTPSCredentials.contains(where: { !$0.token.isEmpty }) {
            return true
        }
        if profile.manualTokens.contains(where: { !$0.realValue.isEmpty }) {
            return true
        }
        if !profile.awsCredentials.secretAccessKey.isEmpty
            || !profile.awsCredentials.sessionToken.isEmpty {
            return true
        }
        if profile.httpDatabases.contains(where: { !$0.secret.isEmpty }) {
            return true
        }
        return false
    }

    public func save(_ profile: Profile) throws {
        let dir = profileDirectory(for: profile)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Split secrets out. The Profile in memory keeps every field;
        // on disk we write profile.json (no secrets) + secrets.enc
        // (AES-GCM with the keychain master key).
        var stripped = profile
        let secrets = ProfileSecrets.extract(stripping: &stripped)

        let data = try JSONEncoder.iso8601().encode(stripped)
        try data.write(to: dir.appendingPathComponent("profile.json"), options: .atomic)

        try writeSecretsBlob(secrets, dir: dir)
    }

    /// Drop the encrypted blob (and best-effort delete any plaintext
    /// remnants if migration left them) when a profile is removed.
    /// Called from `delete(_:)` via the existing removeItem on the
    /// directory, so this is mostly a belt-and-braces helper.
    private func writeSecretsBlob(_ secrets: ProfileSecrets, dir: URL) throws {
        let blobURL = dir.appendingPathComponent("secrets.enc")
        if secrets.isEmpty {
            // No secrets at all — nothing to store. Drop any prior
            // blob so the file system reflects current truth.
            try? fm.removeItem(at: blobURL)
            return
        }
        let plain = try JSONEncoder().encode(secrets)
        let cipher = try SecretsVault.encrypt(plain)
        try cipher.write(to: blobURL, options: .atomic)
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: blobURL.path)
    }

    private func mergeSecrets(into profile: inout Profile, dir: URL) {
        let blobURL = dir.appendingPathComponent("secrets.enc")
        guard fm.fileExists(atPath: blobURL.path),
              let cipher = try? Data(contentsOf: blobURL),
              let plain  = try? SecretsVault.decrypt(cipher),
              let secrets = try? JSONDecoder().decode(ProfileSecrets.self, from: plain)
        else { return }
        secrets.apply(to: &profile)
    }

    public func touch(_ profile: Profile) throws {
        var p = profile
        p.lastUsedAt = Date()
        try save(p)
    }

    public func delete(_ profile: Profile) throws {
        try fm.removeItem(at: profileDirectory(for: profile))
        MACBindings.shared.release(profileID: profile.id)
    }

    /// Deep-copy a profile under a new identity. Everything that
    /// matters carries over: profile fields (incl. credentials, since
    /// they're already in `source` after `loadAll` merged the secrets
    /// blob), the per-profile system disk, the persistent home (the
    /// virtiofs dir and/or the ext4 home.img), and the host-only
    /// `agent/` + `ssh/` dirs.
    ///
    /// Skipped on purpose:
    ///   - `vm.state` / `tabs.json` — a RAM snapshot saved against the
    ///     source profile's MAC + UUID would diverge on the duplicate
    ///     instantly. Cold boot.
    ///   - MAC binding — `MACBindings` mints a fresh MAC on first
    ///     launch keyed by the new UUID, so vmnet's lease table stays
    ///     stable per-profile.
    ///
    /// Disk.img, home/, agent/ are copied via `clonefile(2)` — APFS
    /// CoW makes the duplicate instant and zero additional disk space
    /// until the two diverge, even when the home directory is large.
    public func duplicate(_ source: Profile, named newName: String) throws -> Profile {
        var fresh = source
        fresh.id = UUID()
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        fresh.name = trimmed.isEmpty ? source.name + " copy" : trimmed
        fresh.lastUsedAt = nil
        // createdAt stamps the duplicate — sorting in the picker uses
        // (lastUsedAt ?? createdAt), so leaving the source's createdAt
        // would file the copy under wherever the original sits in the
        // list, which is confusing.
        fresh.createdAt = Date()

        // First, write the new profile.json + encrypted secrets blob to
        // the new dir. Doing this before the data clones means a clone
        // failure mid-way leaves us with a directory that at least has
        // a valid metadata layer (the user can still see + delete it).
        try save(fresh)

        let srcDir = profileDirectory(for: source)
        let dstDir = profileDirectory(for: fresh)

        // Per-profile disk image (system layer). May not exist yet if
        // the source was created but never launched.
        let srcDisk = srcDir.appendingPathComponent("disk.img")
        if fm.fileExists(atPath: srcDisk.path) {
            let dstDisk = dstDir.appendingPathComponent("disk.img")
            try? fm.removeItem(at: dstDisk)
            try Self.cloneItem(at: srcDisk, to: dstDisk)
        }

        // Persistent home dir (virtiofs model). clonefile() recurses, so
        // one call duplicates the whole tree as APFS CoW.
        let srcHome = srcDir.appendingPathComponent("home", isDirectory: true)
        if fm.fileExists(atPath: srcHome.path) {
            let dstHome = dstDir.appendingPathComponent("home", isDirectory: true)
            try? fm.removeItem(at: dstHome)
            try Self.cloneItem(at: srcHome, to: dstHome)
        }

        // Home image (ext4 model). clonefile shares the extent map, so
        // the duplicate is instant, costs no additional space until the
        // two diverge, and stays sparse — existing holes (and future
        // fstrim punches on either copy) never materialize on the other.
        // NOT cloned: boot-home/ (regenerated every launch) and
        // home.pre-ext4/ (the source's own pre-migration backup).
        let srcHomeImg = srcDir.appendingPathComponent("home.img")
        if fm.fileExists(atPath: srcHomeImg.path) {
            let dstHomeImg = dstDir.appendingPathComponent("home.img")
            try? fm.removeItem(at: dstHomeImg)
            try Self.cloneItem(at: srcHomeImg, to: dstHomeImg)
        }

        // Host-only ssh material — auto-generated keypair seed under
        // agent/, plus any imported keys under agent/imported/, plus
        // the legacy ssh/ dir (still present for migration).
        for sub in ["agent", "ssh"] {
            let srcSub = srcDir.appendingPathComponent(sub, isDirectory: true)
            guard fm.fileExists(atPath: srcSub.path) else { continue }
            let dstSub = dstDir.appendingPathComponent(sub, isDirectory: true)
            try? fm.removeItem(at: dstSub)
            try Self.cloneItem(at: srcSub, to: dstSub)
        }

        return fresh
    }

    /// Try `clonefile(2)` first (APFS CoW, instant, zero space) and
    /// fall back to a recursive plain copy if the kernel rejects it.
    /// `clonefile()` is fussy about cross-volume paths, missing
    /// destination parents, and a handful of edge cases — the
    /// fallback keeps duplicate working even when the fast path
    /// can't.
    private static func cloneItem(at src: URL, to dst: URL) throws {
        let fm = FileManager.default
        // Belt-and-braces: ensure the destination's parent exists.
        // `save(fresh)` creates the top-level profile dir, but if a
        // future caller hands in a deeper destination this catches it
        // before clonefile's terse ENOENT.
        let parent = dst.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let srcPath = src.path(percentEncoded: false)
        let dstPath = dst.path(percentEncoded: false)

        let result = clonefile(srcPath, dstPath, 0)
        if result == 0 { return }

        let cloneErrno = errno
        let cloneErr = String(cString: strerror(cloneErrno))
        FileHandle.standardError.write(Data(
            "[duplicate] clonefile \(srcPath) → \(dstPath) failed (\(cloneErr)) — falling back to plain copy\n".utf8))

        // Plain recursive copy. Slower (no CoW) but works across
        // volumes and on whatever edge case got us here. Wipe any
        // partial result clonefile may have left.
        try? fm.removeItem(at: dst)
        do {
            try fm.copyItem(at: src, to: dst)
        } catch {
            throw NSError(domain: "BromureAC.duplicate", code: Int(cloneErrno),
                          userInfo: [NSLocalizedDescriptionKey:
                            "duplicate \(srcPath) → \(dstPath): clonefile (\(cloneErr)) and copy (\(error.localizedDescription)) both failed"])
        }
    }

    /// Wipe the per-profile disk so the next launch re-clones from base.
    /// The home dir (mounted as /home/ubuntu) is intentionally untouched
    /// so settings, history, and installed tools survive a reset.
    ///
    /// Also drops any saved VM state — a RAM snapshot paired with a
    /// fresh disk would diverge instantly (the kernel's view of the
    /// block device wouldn't match what's on disk).
    public func resetDisk(for profile: Profile) throws {
        let disk = diskURL(for: profile)
        if fm.fileExists(atPath: disk.path) {
            try fm.removeItem(at: disk)
        }
        let dir = profileDirectory(for: profile)
        try? fm.removeItem(at: dir.appendingPathComponent("vm.state"))
        try? fm.removeItem(at: dir.appendingPathComponent("tabs.json"))
    }

    // MARK: - Disk checkpoints (rollback points)

    /// A point-in-time clone of a profile's disk, taken after a successful boot
    /// (so it's proven bootable). Lets the user roll back a session that corrupted
    /// the disk to a recent good state instead of a full reset to base.
    public struct DiskCheckpoint: Identifiable, Sendable {
        public let id: String        // unix timestamp (seconds) — the filename stem
        public let createdAt: Date
        public let url: URL
        public let allocatedBytes: Int64
    }

    public func checkpointsDirectory(for profile: Profile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("checkpoints")
    }

    /// Home (ext4 home.img) rollback points, kept apart from the disk's so
    /// either can be reverted without touching the other.
    public func homeCheckpointsDirectory(for profile: Profile) -> URL {
        checkpointsDirectory(for: profile).appendingPathComponent("home")
    }

    /// The tiered "go back in time" ladder: which of `dates` to KEEP.
    /// The newest `boots` stay unconditionally (the last few sessions), then
    /// the newest checkpoint of each calendar day for `days` days, then the
    /// newest of each calendar week for `weeks` weeks; everything older is
    /// pruned. Worst case boots+days+weeks images — in practice the tiers
    /// overlap and it's fewer, and clonefile copies only cost the blocks
    /// that have since diverged.
    public static func checkpointRetention(_ dates: [Date], now: Date,
                                           boots: Int = 3, days: Int = 7,
                                           weeks: Int = 4,
                                           calendar: Calendar = .current) -> Set<Date> {
        let sorted = dates.sorted(by: >)
        var keep = Set(sorted.prefix(max(0, boots)))
        if let dayCut = calendar.date(byAdding: .day, value: -days, to: now) {
            var seen = Set<DateComponents>()
            for d in sorted where d >= dayCut {
                let day = calendar.dateComponents([.year, .month, .day], from: d)
                if seen.insert(day).inserted { keep.insert(d) }
            }
        }
        if let weekCut = calendar.date(byAdding: .weekOfYear, value: -weeks, to: now) {
            var seen = Set<DateComponents>()
            for d in sorted where d >= weekCut {
                let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
                if seen.insert(week).inserted { keep.insert(d) }
            }
        }
        return keep
    }

    /// CoW-clone the current disk into `checkpoints/<ts>.img` and prune to
    /// the tiered ladder. clonefile is instant + near-zero space (shares
    /// blocks with the live disk until they diverge), so this is cheap to do
    /// every boot. Cloning a live disk yields a crash-consistent image (ext4
    /// journal replays on restore) — acceptable for a rollback point, and
    /// the source just booted.
    @discardableResult
    public func snapshotDisk(for profile: Profile, at date: Date) throws -> DiskCheckpoint? {
        try snapshotImage(diskURL(for: profile),
                          into: checkpointsDirectory(for: profile), at: date)
    }

    /// Same rollback ladder for the ext4 home image — the "my agent trashed
    /// my code an hour ago" recovery path. No-op for legacy virtiofs homes
    /// (no home.img to clone).
    @discardableResult
    public func snapshotHomeImage(for profile: Profile, at date: Date) throws -> DiskCheckpoint? {
        try snapshotImage(homeImageURL(for: profile),
                          into: homeCheckpointsDirectory(for: profile), at: date)
    }

    private func snapshotImage(_ image: URL, into dir: URL,
                               at date: Date) throws -> DiskCheckpoint? {
        guard fm.fileExists(atPath: image.path) else { return nil }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = Int(date.timeIntervalSince1970)
        let dst = dir.appendingPathComponent("\(ts).img")
        guard !fm.fileExists(atPath: dst.path) else { return nil }   // one per second
        try Self.cloneItem(at: image, to: dst)
        prune(in: dir, now: date)
        return list(in: dir).first { $0.id == String(ts) }
    }

    /// Newest first.
    public func listCheckpoints(for profile: Profile) -> [DiskCheckpoint] {
        list(in: checkpointsDirectory(for: profile))
    }

    /// Newest first.
    public func listHomeCheckpoints(for profile: Profile) -> [DiskCheckpoint] {
        list(in: homeCheckpointsDirectory(for: profile))
    }

    private func list(in dir: URL) -> [DiskCheckpoint] {
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        return urls.compactMap { url -> DiskCheckpoint? in
            guard url.pathExtension == "img",
                  let ts = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
            let bytes = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
                .flatMap { Int64($0) } ?? 0
            return DiskCheckpoint(id: String(ts), createdAt: Date(timeIntervalSince1970: TimeInterval(ts)),
                                  url: url, allocatedBytes: bytes)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func prune(in dir: URL, now: Date) {
        let all = list(in: dir)
        let keep = Self.checkpointRetention(all.map(\.createdAt), now: now)
        for cp in all where !keep.contains(cp.createdAt) {
            try? fm.removeItem(at: cp.url)
        }
    }

    /// Restore a checkpoint over the live disk. The VM MUST be stopped first (the
    /// caller enforces this) — replacing an open disk image would corrupt it.
    /// Clears saved RAM state so the kernel's block-device view matches the disk.
    public func revertDisk(for profile: Profile, to checkpointID: String) throws {
        try revertImage(fromCheckpoint: checkpointID,
                        in: checkpointsDirectory(for: profile),
                        over: diskURL(for: profile), profile: profile)
    }

    /// Restore a home checkpoint over the live home.img. Same rules: the VM
    /// must be stopped, and saved RAM state is cleared (a resumed kernel
    /// would hold stale ext4 state for the replaced device). Only the home
    /// rolls back — the system disk is untouched.
    public func revertHomeImage(for profile: Profile, to checkpointID: String) throws {
        try revertImage(fromCheckpoint: checkpointID,
                        in: homeCheckpointsDirectory(for: profile),
                        over: homeImageURL(for: profile), profile: profile)
    }

    private func revertImage(fromCheckpoint checkpointID: String, in dir: URL,
                             over image: URL, profile: Profile) throws {
        let src = dir.appendingPathComponent("\(checkpointID).img")
        guard fm.fileExists(atPath: src.path) else {
            throw NSError(domain: "BromureAC.checkpoint", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Checkpoint \(checkpointID) not found"])
        }
        if fm.fileExists(atPath: image.path) { try fm.removeItem(at: image) }
        try Self.cloneItem(at: src, to: image)
        let profileDir = profileDirectory(for: profile)
        try? fm.removeItem(at: profileDir.appendingPathComponent("vm.state"))
        try? fm.removeItem(at: profileDir.appendingPathComponent("tabs.json"))
    }

    /// Wipe the per-profile **home** directory. Inverse of resetDisk:
    /// the profile's system disk is left alone (so apt-installed tools
    /// remain), but everything under /home/ubuntu — projects, .ssh,
    /// .bash_history, npm-global, .cargo, .bashrc.local — is gone.
    /// The next launch's `prepareHomeDirectory` rebuilds the managed
    /// dotfiles + Bromure-owned config from the saved profile.
    public func resetHome(for profile: Profile) throws {
        let home = homeDirectory(for: profile)
        if fm.fileExists(atPath: home.path) {
            try fm.removeItem(at: home)
        }
        // ext4 model: the home IS the image. Delete it — the next launch
        // creates a blank sparse image and the guest agent re-formats +
        // re-seeds it.
        let img = homeImageURL(for: profile)
        if fm.fileExists(atPath: img.path) {
            try fm.removeItem(at: img)
        }
        // Erased means erased: the home's rollback checkpoints hold the
        // same data and must not survive the wipe.
        try? fm.removeItem(at: homeCheckpointsDirectory(for: profile))
    }

    /// Logical size of a per-profile disk image (sparse — what it
    /// actually occupies on disk, not the 24 GB allocation). Returns 0
    /// if the file doesn't exist yet.
    public func diskSizeBytes(for profile: Profile) -> Int64 {
        Self.allocatedBytes(at: diskURL(for: profile))
    }

    /// Bytes the profile's home occupies on the host. ext4 model: the
    /// image's *allocated* size (sparse-aware, O(1)) plus any leftover
    /// pre-migration backup. virtiofs model: recursive walk of the home
    /// dir (lazily; suitable for backgrounding via Task). Returns 0 if
    /// nothing exists yet.
    public func homeSizeBytes(for profile: Profile) -> Int64 {
        let img = homeImageURL(for: profile)
        if fm.fileExists(atPath: img.path) {
            return Self.allocatedBytes(at: img)
                + Self.directoryBytes(at: homeBackupDirectory(for: profile))
        }
        return Self.directoryBytes(at: homeDirectory(for: profile))
    }

    /// Last-modified timestamp of the profile's home (the image file for
    /// ext4 profiles, the home dir otherwise), or nil if it doesn't
    /// exist. Used by the storage stack to show "active X minutes ago"
    /// labels.
    public func homeLastModified(for profile: Profile) -> Date? {
        let img = homeImageURL(for: profile)
        let url = fm.fileExists(atPath: img.path) ? img : homeDirectory(for: profile)
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    /// Bytes the file actually occupies on disk (st_blocks * 512), via
    /// Foundation's fileAllocatedSizeKey. For sparse images this is way
    /// smaller than the apparent file size.
    private static func allocatedBytes(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        if let v = values?.totalFileAllocatedSize { return Int64(v) }
        if let v = values?.fileAllocatedSize { return Int64(v) }
        // Fallback: stat'd size (may overstate for sparse files).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let n = attrs[.size] as? NSNumber {
            return n.int64Value
        }
        return 0
    }

    /// Recursive walk summing st_blocks*512 of every regular file.
    /// Symlinks are not followed; directories themselves contribute the
    /// inode block. Bounded by the file system — caller should call from
    /// a Task to avoid blocking the UI on huge home dirs.
    private static func directoryBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        // Don't skip hidden files — we want .ssh, .config, .bashrc etc.
        // counted, since they're a real part of the user's footprint.
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: keys,
                                             options: [],
                                             errorHandler: nil) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let v = try? fileURL.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile == true {
                if let n = v?.totalFileAllocatedSize { total &+= Int64(n) }
                else if let n = v?.fileAllocatedSize { total &+= Int64(n) }
            }
        }
        return total
    }

    /// Make sure the host-side /home/ubuntu mirror exists with the dotfiles
    /// the in-VM agent expects.
    ///
    /// `terminalDefaults` is the snapshot of Terminal.app's default profile
    /// captured at app startup — passed in so we use a stable value across
    /// the session (Terminal.app prefs may change while AC is running).
    ///
    /// **Managed files** (.bashrc, .bash_profile, .profile, .npmrc,
    /// .config/kitty/kitty.conf) are **always overwritten** so changes to
    /// the agent-launch logic ship without any per-profile migration.
    /// User customizations belong in ~/.bashrc.local, which we source from
    /// the managed .bashrc and never touch.
    ///
    /// Migrates legacy SSH keys from profiles/<id>/ssh into
    /// profiles/<id>/home/.ssh on first run.
    public func prepareHomeDirectory(for profile: Profile,
                                     terminalDefaults: TerminalAppDefaults,
                                     tokenPlan: SessionTokenPlan? = nil,
                                     kubeconfigYAML: String? = nil) throws {
        let home = homeDirectory(for: profile)
        if !fm.fileExists(atPath: home.path) {
            try fm.createDirectory(
                at: home,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o755)]
            )
        }
        try populateManagedHome(in: home, profile: profile,
                                tokenPlan: tokenPlan,
                                kubeconfigYAML: kubeconfigYAML,
                                seedMode: false)
    }

    /// Write the managed home files into `home`. Two callers:
    /// - `prepareHomeDirectory` (virtiofs model): `home` is the live
    ///   host-side /home/ubuntu mirror. Read-modify-write against the
    ///   guest's actual state is fine here (`seedMode == false`).
    /// - `writeHomeSeedFiles` (ext4 model): `home` is the `home-seed/files`
    ///   staging dir inside the meta share. The guest agent copies these
    ///   into the ext4 home per `manifest.tsv`. Anything that must merge
    ///   with the guest's *current* state (`.claude/settings.json`) or
    ///   that touches other host dirs (legacy ssh migration) is skipped
    ///   (`seedMode == true`) and handled by the agent from
    ///   `claude-settings.spec.json` instead.
    private func populateManagedHome(in home: URL,
                                     profile: Profile,
                                     tokenPlan: SessionTokenPlan?,
                                     kubeconfigYAML: String?,
                                     seedMode: Bool) throws {
        // Managed dotfiles — always rewrite.
        try Self.bashrcContent.write(
            to: home.appendingPathComponent(".bashrc"),
            atomically: true, encoding: .utf8)
        try Self.bashProfileContent.write(
            to: home.appendingPathComponent(".bash_profile"),
            atomically: true, encoding: .utf8)
        try Self.profileContent.write(
            to: home.appendingPathComponent(".profile"),
            atomically: true, encoding: .utf8)
        try "prefix=/home/ubuntu/.npm-global\n".write(
            to: home.appendingPathComponent(".npmrc"),
            atomically: true, encoding: .utf8)
        // Stale X-era dotfiles from previous sessions: the persistent home
        // survives upgrades, so sweep the launchers that would otherwise
        // linger (nothing reads them anymore — boot is headless and
        // bromure-agentd owns the session).
        try? fm.removeItem(at: home.appendingPathComponent(".xinitrc"))
        try? fm.removeItem(at: home.appendingPathComponent(".bromure-tab-agent.sh"))

        // .bashrc.local: user customizations. Created empty on first run,
        // never overwritten thereafter.
        let local = home.appendingPathComponent(".bashrc.local")
        if !fm.fileExists(atPath: local.path) {
            try Self.bashrcLocalSeed.write(to: local, atomically: true, encoding: .utf8)
        }

        // HTTPS Git credentials: write ~/.git-credentials in the format
        // git's `store` helper expects. One line per usable cred. File is
        // chmod 600 because it carries cleartext tokens.
        //
        // When a tokenPlan is provided, the value written is the FAKE
        // — the real value lives only in the host's MITM swap map.
        let gitCredsURL = home.appendingPathComponent(".git-credentials")
        let usableCreds = profile.gitHTTPSCredentials.filter { $0.isUsable }
        if !usableCreds.isEmpty {
            let lines = usableCreds.map { c -> String in
                let user = Self.percentEncode(c.username)
                let useToken = tokenPlan?.fakeForGitHTTPS(host: c.host, username: c.username) ?? c.token
                let tok  = Self.percentEncode(useToken)
                let host = c.host.trimmingCharacters(in: .whitespaces)
                return "https://\(user):\(tok)@\(host)"
            }
            try (lines.joined(separator: "\n") + "\n")
                .write(to: gitCredsURL, atomically: true, encoding: .utf8)
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: gitCredsURL.path)
        } else if fm.fileExists(atPath: gitCredsURL.path) {
            // We previously wrote one — drop it so cleared-out tokens
            // don't keep working in the VM.
            try? fm.removeItem(at: gitCredsURL)
        }

        // .gitconfig: generated when there's a user identity OR HTTPS
        // creds (so we can install the credential helper). Skipping
        // entirely leaves the system git defaults intact.
        let gitconfig = home.appendingPathComponent(".gitconfig")
        let name = profile.gitUserName.trimmingCharacters(in: .whitespaces)
        let email = profile.gitUserEmail.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty || !email.isEmpty || !usableCreds.isEmpty {
            var lines = ["# Managed by Bromure Agentic Coding."]
            if !name.isEmpty || !email.isEmpty {
                lines.append("[user]")
                if !name.isEmpty { lines.append("    name  = \(name)") }
                if !email.isEmpty { lines.append("    email = \(email)") }
            }
            if !usableCreds.isEmpty {
                lines.append("[credential]")
                lines.append("    helper = store")
            }
            try lines.joined(separator: "\n")
                .appending("\n")
                .write(to: gitconfig, atomically: true, encoding: .utf8)
        } else {
            // Cleanly remove a previously-managed .gitconfig if the user
            // blanked the fields out — but only if it was OURS.
            if let contents = try? String(contentsOf: gitconfig, encoding: .utf8),
               contents.hasPrefix("# Managed by Bromure Agentic Coding.") {
                try? fm.removeItem(at: gitconfig)
            }
        }

        // gh / glab CLI configs for known hosts. Lets `gh pr create` and
        // `glab mr create` use the same token without a separate `gh auth
        // login` step. Files are chmod 600 (tokens in plaintext).
        // When a tokenPlan is provided, fakes are written here too —
        // the gh CLI sends the fake as a Bearer header, and the MITM
        // engine swaps it on the way upstream.
        try writeGHConfig(in: home, creds: usableCreds, tokenPlan: tokenPlan)
        try writeGLabConfig(in: home, creds: usableCreds, tokenPlan: tokenPlan)

        let npmGlobal = home.appendingPathComponent(".npm-global", isDirectory: true)
        if !fm.fileExists(atPath: npmGlobal.path) {
            try fm.createDirectory(at: npmGlobal, withIntermediateDirectories: true)
        }

        // (kitty.conf generation removed with the framebuffer: appearance
        // now flows into the native surfaces via TerminalAppDefaults
        // .ghosttyConfig on the host. A stale ~/.config/kitty/kitty.conf in
        // the persistent home is harmless — nothing launches kitty.)

        // ~/.tmux.conf — ONE tmux session per VM; each tab is a tmux window.
        // The native terminal views attach as grouped clients of this
        // session. Base config here:
        // - mouse OFF: tmux doesn't capture the mouse, so a plain drag is
        //   ghostty's own native selection (select never copies, ⌘C copies)
        //   and the wheel scrolls the native scrollback. tmux still forwards
        //   mouse to apps that request it (Claude/vim), so TUI clicks work.
        // - renumber-windows OFF: a window's index must be STABLE for its
        //   lifetime. Native terminal surfaces bind to a window index
        //   (grouped view session + select-window), and the controller
        //   caches surfaces by index — so renumbering on close would swap
        //   which window a cached surface shows (killing an early tab shifted
        //   e.g. logs↔sh). The host tracks tabs by model position and maps to
        //   the (now gap-tolerant) index via model.tabs[i].index, so the tab
        //   bar stays contiguous regardless.
        try """
        set -g status off
        set -g mouse off
        set -g escape-time 10
        set -g history-limit 100000
        set -g default-terminal "screen-256color"
        set -g window-size latest
        set -g base-index 0
        set -g renumber-windows off
        set -g set-clipboard on
        """.write(to: home.appendingPathComponent(".tmux.conf"),
                  atomically: true, encoding: .utf8)

        // ~/.kube/config — synthetic kubeconfig with throwaway client
        // certs / fake bearer tokens. Real credentials live on the
        // host; the proxy substitutes them on the wire.
        if let kube = kubeconfigYAML, !kube.isEmpty {
            let kubeDir = home.appendingPathComponent(".kube", isDirectory: true)
            try fm.createDirectory(at: kubeDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: 0o700)])
            let kubeFile = kubeDir.appendingPathComponent("config")
            try kube.write(to: kubeFile, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                 ofItemAtPath: kubeFile.path)
        }

        // ~/.config/doctl/config.yaml — DigitalOcean CLI config
        // with the FAKE PAT. doctl reads access-token from this file
        // (or DIGITALOCEAN_ACCESS_TOKEN env, also set in proxy.env).
        if let plan = tokenPlan, let doFake = plan.fakeForDigitalOcean() {
            let doctlDir = home.appendingPathComponent(".config/doctl",
                                                       isDirectory: true)
            try fm.createDirectory(at: doctlDir, withIntermediateDirectories: true)
            let yaml = """
            # Managed by Bromure Agentic Coding.
            access-token: \(doFake)
            """
            let url = doctlDir.appendingPathComponent("config.yaml")
            try yaml.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                 ofItemAtPath: url.path)
        }

        // ~/.aws/config — points the SDK at our credential_process
        // helper, which reads short-lived JSON from a vsock-bridged
        // Unix socket. The real access key + secret never land on the
        // guest disk OR in the SDK's process memory: the helper hands
        // out the real AccessKeyId paired with a *fake* SecretAccessKey,
        // so the SDK signs a doomed request. The host MitmEngine's
        // AWSResigner strips that signature and re-signs with the real
        // material before the request leaves the box. If the proxy is
        // bypassed somehow, AWS rejects the request — fail-closed.
        //
        // ~/.aws/credentials is always nuked if we previously wrote
        // one, even when no creds are configured for this profile —
        // we never want a stale secret left behind.
        let awsCreds = profile.awsCredentials
        let awsDir = home.appendingPathComponent(".aws", isDirectory: true)
        let awsCredsURL = awsDir.appendingPathComponent("credentials")
        let awsConfigURL = awsDir.appendingPathComponent("config")
        if let contents = try? String(contentsOf: awsCredsURL, encoding: .utf8),
           contents.hasPrefix("# Managed by Bromure Agentic Coding.") {
            try? fm.removeItem(at: awsCredsURL)
        }
        if awsCreds.isUsable {
            try fm.createDirectory(at: awsDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: 0o700)])
            var lines = [
                "# Managed by Bromure Agentic Coding.",
                "[default]",
                "credential_process = /mnt/bromure-meta/bromure-aws-creds.py",
            ]
            let region = awsCreds.region.trimmingCharacters(in: .whitespaces)
            if !region.isEmpty {
                lines.append("region = \(region)")
            }
            try (lines.joined(separator: "\n") + "\n")
                .write(to: awsConfigURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                 ofItemAtPath: awsConfigURL.path)
        } else if let contents = try? String(contentsOf: awsConfigURL, encoding: .utf8),
                  contents.hasPrefix("# Managed by Bromure Agentic Coding.") {
            try? fm.removeItem(at: awsConfigURL)
        }

        // ~/.claude/settings.json — Bedrock configuration for Claude Code.
        // Seed mode: the merge below reads the guest's CURRENT settings,
        // which the host can't see inside an ext4 image — the guest agent
        // does the equivalent merge from `claude-settings.spec.json`
        // (written by finalizeHomeSeed). Only the RMW parts are skipped;
        // the plain status-script file is emitted in both modes.
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let claudeSettingsURL = claudeDir.appendingPathComponent("settings.json")
        if seedMode {
            // fallthrough to the usesClaude block below
        } else if profile.bedrockEnabled {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: 0o700)])
            var env: [String: String] = [
                "CLAUDE_CODE_USE_BEDROCK": "1",
                "AWS_PROFILE": "default",
            ]
            let region = awsCreds.region.trimmingCharacters(in: .whitespaces)
            if !region.isEmpty {
                env["AWS_REGION"] = region
            }
            let modelID = profile.bedrockModelID.trimmingCharacters(in: .whitespaces)
            if !modelID.isEmpty {
                env["ANTHROPIC_MODEL"] = modelID
            }
            let settings: [String: Any] = ["env": env]
            let data = try JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: claudeSettingsURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                 ofItemAtPath: claudeSettingsURL.path)
        } else if fm.fileExists(atPath: claudeSettingsURL.path),
                  let data = try? Data(contentsOf: claudeSettingsURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let env = json["env"] as? [String: Any],
                  env["CLAUDE_CODE_USE_BEDROCK"] != nil {
            try? fm.removeItem(at: claudeSettingsURL)
        }

        // Default Claude Code to the `auto` permission mode so the agent runs
        // autonomously inside the disposable VM (the VM + MITM proxy ARE the
        // sandbox, so per-action prompts are mostly friction here). Seeded into
        // ~/.claude/settings.json only when `permissions.defaultMode` is unset,
        // via read-modify-write — so we never clobber the Bedrock `env` written
        // just above or any other user settings, and a user who later picks a
        // different mode is respected. Only for workspaces that actually use
        // Claude Code (primary or additional tool).
        let usesClaude = profile.tool == .claude
            || profile.additionalTools.contains { $0.tool == .claude }
        if usesClaude && !seedMode {
            try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            var settings: [String: Any] = [:]
            if let data = try? Data(contentsOf: claudeSettingsURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = json
            }
            // Seed the permission mode only when unset (respect a user change).
            var perms = settings["permissions"] as? [String: Any] ?? [:]
            if perms["defaultMode"] == nil {
                perms["defaultMode"] = "auto"
                settings["permissions"] = perms
            }
            // We used to seed CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1 because the
            // framebuffer kitty and Claude Code's fullscreen-TUI mouse capture
            // fought over click-drag selection. tmux now owns the mouse (the
            // native terminal views enable mouse mode; selection copies via
            // OSC 52), so clicks can flow to the TUI again. Strip the stale
            // seed — but only our exact value, so a user who set it on
            // purpose keeps it.
            var claudeEnv = settings["env"] as? [String: Any] ?? [:]
            if claudeEnv["CLAUDE_CODE_DISABLE_MOUSE_CLICKS"] as? String == "1" {
                claudeEnv.removeValue(forKey: "CLAUDE_CODE_DISABLE_MOUSE_CLICKS")
                settings["env"] = claudeEnv
            }
            // Selection is the terminal/tmux's job (mouse-release already
            // copies); Claude Code's own copy-on-select double-copies and
            // clobbers the clipboard. Forced off at every session start —
            // Claude Code's own default is true and it persists it into
            // settings.json, so seed-only-if-unset never wins. Flipping it
            // back mid-session (/config) works but resets next session.
            settings["copyOnSelect"] = false
            // Managed status hooks — report working/done/needsInput to the host
            // for the sidebar status dot. Overwrite just these four events
            // (other user hooks + settings are preserved by the read above).
            let hookScript = "/home/ubuntu/.bromure/agent-status.sh"
            func hookCmd(_ arg: String) -> [[String: Any]] {
                [["hooks": [["type": "command", "command": "\(hookScript) \(arg)"]]]]
            }
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            hooks["UserPromptSubmit"] = hookCmd("working")
            hooks["PreToolUse"] = hookCmd("working")
            hooks["Stop"] = hookCmd("done")
            hooks["Notification"] = hookCmd("needsInput")
            settings["hooks"] = hooks

            let data = try JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: claudeSettingsURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                  ofItemAtPath: claudeSettingsURL.path)

            // Pre-approve the session's ANTHROPIC_API_KEY in ~/.claude.json
            // (customApiKeyResponses stores the key's last-20 suffix) so the
            // "use this API key from your environment?" prompt never blocks a
            // first launch or a cloned workspace, whose per-profile bogus key
            // differs from the approval the base's home carries. Guest-side
            // twin for the ext4 model: agentd's _approve_claude_api_key.
            let envKey = tokenPlan?.fakeForAnthropic()
                ?? tokenPlan?.claudeSubscriptionBogusKey
            if let envKey, !envKey.isEmpty {
                let claudeJSONURL = home.appendingPathComponent(".claude.json")
                var cfg: [String: Any] = [:]
                if let data = try? Data(contentsOf: claudeJSONURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    cfg = json
                }
                var responses = cfg["customApiKeyResponses"] as? [String: Any] ?? [:]
                var approved = responses["approved"] as? [String] ?? []
                let suffix = String(envKey.suffix(20))
                if !approved.contains(suffix) {
                    approved.append(suffix)
                    responses["approved"] = approved
                    cfg["customApiKeyResponses"] = responses
                    if let out = try? JSONSerialization.data(
                        withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
                        try? out.write(to: claudeJSONURL, options: .atomic)
                    }
                }
            }
        }
        if usesClaude {
            // The reporter script the hooks call (idempotent overwrite).
            // Written in BOTH modes — it's a plain managed file, no merge.
            let bromureDir = home.appendingPathComponent(".bromure", isDirectory: true)
            try? fm.createDirectory(at: bromureDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: NSNumber(value: 0o755)])
            let statusScript = #"""
            #!/bin/sh
            # Bromure Claude-hook status reporter → per-tab sidebar dot.
            # $1 = working|done|needsInput. The hook runs inside the agent's tmux
            # window, so $TMUX_PANE resolves this tab's window index — reported in
            # the filename so each tab's dot is independent.
            d=/mnt/bromure-outbox
            [ -d "$d" ] || exit 0
            # No TMUX_PANE → bail. An empty -t target resolves to the ACTIVE
            # window, which stamps this signal onto whatever tab the user is
            # looking at (a task's "done" once killed the plan interview).
            [ -n "${TMUX_PANE:-}" ] || exit 0
            idx=$(tmux display-message -p -t "$TMUX_PANE" '#{window_index}' 2>/dev/null)
            [ -n "$idx" ] || exit 0
            printf '%s' "${1:-}" > "$d/.agent-status-$idx.tmp" 2>/dev/null \
              && mv -f "$d/.agent-status-$idx.tmp" "$d/agent-status-$idx.txt" 2>/dev/null || true
            exit 0
            """#
            let scriptURL = bromureDir.appendingPathComponent("agent-status.sh")
            try? statusScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                  ofItemAtPath: scriptURL.path)
        }

        // ~/.docker/config.json — Docker stores per-registry HTTP Basic
        // creds here as `auths.<key>.auth = base64("<user>:<password>")`.
        // We write FAKE base64 strings; the proxy substitutes the real
        // values on the wire when the request hits the matching
        // registry host.
        //
        // To coexist with `docker login` run from inside the VM, our
        // file carries a sentinel top-level key that Docker ignores.
        // Cleanup only deletes a previously-managed file (sentinel
        // present); a hand-managed config.json is left alone.
        let dockerDir = home.appendingPathComponent(".docker", isDirectory: true)
        let dockerConfigURL = dockerDir.appendingPathComponent("config.json")
        let usableRegs = profile.dockerRegistries.filter { $0.isUsable }
        let bromureSentinel = "_bromureManaged"
        if !usableRegs.isEmpty {
            try fm.createDirectory(at: dockerDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: 0o700)])
            var auths: [String: [String: String]] = [:]
            for reg in usableRegs {
                let useB64: String
                if let plan = tokenPlan,
                   let fake = plan.fakeForDockerRegistry(host: reg.host,
                                                        username: reg.username) {
                    useB64 = fake
                } else {
                    // Plan-less path (no MitmEngine): fall back to the
                    // real base64. Won't be reached in practice since
                    // every session has a token plan, but keeps the
                    // file useful if someone runs prepareHomeDirectory
                    // directly.
                    let raw = "\(reg.username):\(reg.password)"
                    useB64 = Data(raw.utf8).base64EncodedString()
                }
                auths[Self.dockerConfigKey(for: reg.host)] = ["auth": useB64]
            }
            let payload: [String: Any] = [
                bromureSentinel: "Managed by Bromure Agentic Coding.",
                "auths": auths,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dockerConfigURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                 ofItemAtPath: dockerConfigURL.path)
        } else if let data = try? Data(contentsOf: dockerConfigURL),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let dict = json as? [String: Any],
                  dict[bromureSentinel] != nil {
            try? fm.removeItem(at: dockerConfigURL)
        }

        // Migrate legacy SSH keys: profiles/<id>/ssh → home/.ssh. Host-dir
        // move — meaningless (and destructive) against a seed staging dir,
        // so virtiofs mode only. Seed mode ships the public key explicitly
        // (writeHomeSeedFiles) and tombstones the private key in the
        // manifest instead.
        if !seedMode {
            let legacySSH = sshDirectory(for: profile)
            let newSSH = home.appendingPathComponent(".ssh", isDirectory: true)
            if fm.fileExists(atPath: legacySSH.path) && !fm.fileExists(atPath: newSSH.path) {
                try fm.moveItem(at: legacySSH, to: newSSH)
            }

            // Enforce the no-private-key-in-the-VM rule: any private key
            // file Bromure may have written here in the past is removed
            // every launch. The agent-forwarded key (held only on host)
            // takes over via SSH_AUTH_SOCK.
            let privateKeyFile = newSSH.appendingPathComponent("id_ed25519")
            try? fm.removeItem(at: privateKeyFile)
        }
    }

    // MARK: - Home seed (ext4 home model)
    //
    // For `.ext4`-model profiles the host can't write /home/ubuntu directly
    // (it lives inside home.img). Instead each launch stages the SAME
    // managed files under `<meta-share>/home-seed/`:
    //
    //   home-seed/
    //     files/<relpath>              payloads, mirroring $HOME layout
    //     manifest.tsv                 how to apply each entry (below)
    //     claude-settings.spec.json    inputs for the guest-side settings merge
    //
    // manifest.tsv — one entry per line, tab-separated:
    //   D <perms> <relpath>            mkdir -p with perms
    //   o <perms> <relpath>            copy from files/, always overwrite
    //   m <perms> <relpath>            copy from files/ only if missing
    //   d -      <relpath>             delete
    //   p -      <relpath> <prefix>    delete if file starts with <prefix>
    //   j -      <relpath> <key>       delete if JSON object has top-level <key>
    //
    // The guest agent (bromure-agentd.py, apply_home_seed) executes it at
    // boot before the tmux session starts, and again whenever
    // seed.generation bumps (live credential/env refresh).

    /// Sentinel prefix shared by every "ours, safe to delete" text config.
    static let managedSentinel = "# Managed by Bromure Agentic Coding."

    /// Relpaths applied create-if-missing instead of overwrite.
    private static let seedIfMissing: Set<String> = [".bashrc.local"]
    /// Relpaths chmod 600 (everything else is 644).
    private static let seed600: Set<String> = [
        ".git-credentials", ".kube/config", ".config/doctl/config.yaml",
        ".aws/config", ".docker/config.json", ".config/gh/hosts.yml",
        ".config/glab-cli/config.yml", ".codex/auth.json", ".grok/auth.json",
    ]
    /// Relpaths chmod 755 (scripts).
    private static let seed755: Set<String> = [".bromure/agent-status.sh"]
    /// Directories created 0700 (everything else 0755).
    private static let seedDir700: Set<String> = [
        ".kube", ".aws", ".claude", ".docker", ".ssh", ".codex", ".grok",
    ]

    /// Stage the managed dotfiles into `<seedDir>/files`. Clears previous
    /// seed contents in place (never removes `seedDir` itself — same
    /// virtiofs inode-preservation rule as the meta share it lives in).
    /// Call `finalizeHomeSeed` after any extra files (codex/grok auth
    /// seeds) have been added, to emit the manifest + merge spec.
    public func writeHomeSeedFiles(for profile: Profile,
                                   into seedDir: URL,
                                   terminalDefaults: TerminalAppDefaults,
                                   tokenPlan: SessionTokenPlan? = nil,
                                   kubeconfigYAML: String? = nil) throws {
        try fm.createDirectory(at: seedDir, withIntermediateDirectories: true)
        if let entries = try? fm.contentsOfDirectory(at: seedDir,
                                                     includingPropertiesForKeys: nil) {
            for entry in entries { try? fm.removeItem(at: entry) }
        }
        let files = seedDir.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        try populateManagedHome(in: files, profile: profile,
                                tokenPlan: tokenPlan,
                                kubeconfigYAML: kubeconfigYAML,
                                seedMode: true)

        // Public half of the profile's generated SSH key, for the user's
        // reference (`cat ~/.ssh/id_ed25519.pub`). The private half never
        // enters the VM — signing goes through the vsock-bridged agent.
        if let pub = profile.sshPublicKey, !pub.isEmpty {
            let sshDir = files.appendingPathComponent(".ssh", isDirectory: true)
            try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
            try (pub.hasSuffix("\n") ? pub : pub + "\n").write(
                to: sshDir.appendingPathComponent("id_ed25519.pub"),
                atomically: true, encoding: .utf8)
        }
    }

    /// Emit `manifest.tsv` + `claude-settings.spec.json` for the staged
    /// seed. Walks `files/` so late additions (codex/grok auth seeds) are
    /// picked up; then appends the cleanup entries for the conditional
    /// files that were NOT generated this launch (mirroring the
    /// delete-if-managed logic of the virtiofs path).
    /// `anthropicEnvKey` — the exact ANTHROPIC_API_KEY this session exports
    /// (token-mode fake or subscription bogus). Its last-20 suffix rides in
    /// the spec so the guest pre-approves it in ~/.claude.json
    /// (customApiKeyResponses) — otherwise Claude's "use this API key from
    /// your environment?" prompt blocks first launches and cloned
    /// workspaces (whose per-profile bogus key differs from the approval
    /// the base workspace's home carries).
    public func finalizeHomeSeed(for profile: Profile, seedDir: URL,
                                 anthropicEnvKey: String? = nil) throws {
        let files = seedDir.appendingPathComponent("files", isDirectory: true)
        var dirLines: [String] = []
        var fileLines: [String] = []
        var present: Set<String> = []

        let keys: [URLResourceKey] = [.isDirectoryKey]
        if let walker = fm.enumerator(at: files, includingPropertiesForKeys: keys,
                                      options: [], errorHandler: nil) {
            let rootPath = files.standardizedFileURL.path
            for case let url as URL in walker {
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(rootPath + "/") else { continue }
                let rel = String(full.dropFirst(rootPath.count + 1))
                let isDir = (try? url.resourceValues(forKeys: Set(keys)))?.isDirectory ?? false
                if isDir {
                    let perms = Self.seedDir700.contains(rel) ? "700" : "755"
                    dirLines.append("D\t\(perms)\t\(rel)")
                } else {
                    present.insert(rel)
                    let mode = Self.seedIfMissing.contains(rel) ? "m" : "o"
                    let perms = Self.seed600.contains(rel) ? "600"
                        : Self.seed755.contains(rel) ? "755" : "644"
                    fileLines.append("\(mode)\t\(perms)\t\(rel)")
                }
            }
        }

        // Unconditional sweeps, mirroring the virtiofs path.
        var cleanupLines: [String] = [
            "d\t-\t.xinitrc",
            "d\t-\t.bromure-tab-agent.sh",
            "d\t-\t.ssh/id_ed25519",
            // ~/.aws/credentials is nuked whenever it's ours — we never
            // want a stale secret left behind (see populateManagedHome).
            "p\t-\t.aws/credentials\t\(Self.managedSentinel)",
        ]
        // Conditional cleanups: only when the file was NOT staged this
        // launch (the user cleared the creds / config that produced it).
        if !present.contains(".git-credentials") {
            cleanupLines.append("d\t-\t.git-credentials")
        }
        if !present.contains(".gitconfig") {
            cleanupLines.append("p\t-\t.gitconfig\t\(Self.managedSentinel)")
        }
        if !present.contains(".aws/config") {
            cleanupLines.append("p\t-\t.aws/config\t\(Self.managedSentinel)")
        }
        if !present.contains(".docker/config.json") {
            cleanupLines.append("j\t-\t.docker/config.json\t_bromureManaged")
        }

        let manifest = (dirLines.sorted() + fileLines.sorted() + cleanupLines)
            .joined(separator: "\n") + "\n"
        try manifest.write(to: seedDir.appendingPathComponent("manifest.tsv"),
                           atomically: true, encoding: .utf8)

        // Inputs for the guest-side ~/.claude/settings.json merge — the
        // one managed file that must be reconciled with the guest's
        // current content rather than overwritten. Mirrors the virtiofs
        // branch of populateManagedHome; the python side lives in
        // bromure-agentd.py (_seed_claude_settings).
        let usesClaude = profile.tool == .claude
            || profile.additionalTools.contains { $0.tool == .claude }
        var spec: [String: Any] = ["usesClaude": usesClaude]
        if usesClaude, let key = anthropicEnvKey, !key.isEmpty {
            // Claude Code stores approvals as the key's last 20 characters.
            spec["approvedApiKeySuffix"] = String(key.suffix(20))
        }
        if profile.bedrockEnabled {
            var env: [String: String] = [
                "CLAUDE_CODE_USE_BEDROCK": "1",
                "AWS_PROFILE": "default",
            ]
            let region = profile.awsCredentials.region.trimmingCharacters(in: .whitespaces)
            if !region.isEmpty { env["AWS_REGION"] = region }
            let modelID = profile.bedrockModelID.trimmingCharacters(in: .whitespaces)
            if !modelID.isEmpty { env["ANTHROPIC_MODEL"] = modelID }
            spec["bedrockEnv"] = env
        }
        let specData = try JSONSerialization.data(
            withJSONObject: spec, options: [.prettyPrinted, .sortedKeys])
        try specData.write(to: seedDir.appendingPathComponent("claude-settings.spec.json"),
                           options: .atomic)
    }

    /// Percent-encode a string for use in the userinfo portion of a URL
    /// (`https://<user>:<token>@host`). RFC 3986: anything outside the
    /// unreserved set must be encoded; `:` and `@` definitely have to be.
    private static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Translate a registry hostname to the key Docker stores it under
    /// in `~/.docker/config.json`. Docker Hub is the special case: its
    /// canonical key is the URL `https://index.docker.io/v1/` rather
    /// than the bare hostname. Everything else uses the host as-is.
    static func dockerConfigKey(for host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if h == "docker.io" || h == "index.docker.io" || h == "registry-1.docker.io" {
            return "https://index.docker.io/v1/"
        }
        return host
    }

    /// Write ~/.config/gh/hosts.yml entries for any github.com (or GHE-host)
    /// creds. Only managed if we have at least one matching cred — otherwise
    /// any existing config is left alone (user might have run `gh auth
    /// login` themselves inside the VM).
    private func writeGHConfig(in home: URL,
                               creds: [GitHTTPSCredential],
                               tokenPlan: SessionTokenPlan? = nil) throws {
        let ghHosts = creds.filter { isGitHubHost($0.host) }
        guard !ghHosts.isEmpty else { return }
        let dir = home.appendingPathComponent(".config/gh", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var yaml = "# Managed by Bromure Agentic Coding.\n"
        for cred in ghHosts {
            let token = tokenPlan?.fakeForGitHTTPS(host: cred.host, username: cred.username) ?? cred.token
            yaml += "\(cred.host):\n"
            yaml += "    user: \(cred.username)\n"
            yaml += "    oauth_token: \(token)\n"
            yaml += "    git_protocol: https\n"
        }
        let url = dir.appendingPathComponent("hosts.yml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path)
    }

    /// Write ~/.config/glab-cli/config.yml entries for any gitlab.com (or
    /// self-hosted GitLab) creds. Same management rules as gh's hosts.yml.
    private func writeGLabConfig(in home: URL,
                                 creds: [GitHTTPSCredential],
                                 tokenPlan: SessionTokenPlan? = nil) throws {
        let glHosts = creds.filter { isGitLabHost($0.host) }
        guard !glHosts.isEmpty else { return }
        let dir = home.appendingPathComponent(".config/glab-cli", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var yaml = "# Managed by Bromure Agentic Coding.\n"
        yaml += "hosts:\n"
        for cred in glHosts {
            let token = tokenPlan?.fakeForGitHTTPS(host: cred.host, username: cred.username) ?? cred.token
            yaml += "    \(cred.host):\n"
            yaml += "        token: \(token)\n"
            yaml += "        username: \(cred.username)\n"
            yaml += "        api_protocol: https\n"
            yaml += "        api_host: \(cred.host)\n"
            yaml += "        git_protocol: https\n"
        }
        let url = dir.appendingPathComponent("config.yml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path)
    }

    private func isGitHubHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "github.com" || h.hasSuffix(".github.com") || h.contains("ghe.")
    }

    private func isGitLabHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "gitlab.com" || h.hasPrefix("gitlab.") || h.contains(".gitlab.")
    }

    private static let bashrcContent = """
    # ─── Managed by Bromure Agentic Coding — REWRITTEN ON EVERY LAUNCH ───
    # Add your own customizations to ~/.bashrc.local instead. That file is
    # sourced at the end and is never touched.

    # Interactive only.
    case $- in *i*) ;; *) return;; esac

    HISTSIZE=10000
    HISTFILESIZE=20000

    # User-level installs land in ~/.npm-global/bin, ~/.cargo/bin,
    # or ~/.local/bin.
    export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.cargo/bin:$PATH"

    # MITM proxy env (HTTPS_PROXY + per-language CA bundles + ssh-agent
    # socket). Sourced before api_key.env so the fake API keys are
    # picked up alongside the proxy that swaps them.
    if [ -r /mnt/bromure-meta/proxy.env ]; then
        set -a
        . /mnt/bromure-meta/proxy.env
        set +a
    fi

    # Per-session env (api keys, tool name) from the bromure-meta share.
    if [ -r /mnt/bromure-meta/api_key.env ]; then
        set -a
        . /mnt/bromure-meta/api_key.env
        set +a
    fi

    # Live env refresh. When the user edits env vars / credentials /
    # guardrails on a *running* session, the host rewrites proxy.env +
    # api_key.env in place and bumps /mnt/bromure-meta/env.generation
    # rather than rebooting the VM. This PROMPT_COMMAND hook re-sources
    # both files the next time any shell draws a prompt after the counter
    # changes, so freshly typed commands (and their children) see the new
    # values. A long-running foreground agent keeps its launch-time env
    # until it exits — Unix environments are frozen at exec.
    _bromure_env_gen() { cat /mnt/bromure-meta/env.generation 2>/dev/null || echo 0; }
    _BROMURE_ENV_GEN="$(_bromure_env_gen)"
    _bromure_reload_env() {
        local _cur
        _cur="$(_bromure_env_gen)"
        [ "$_cur" = "$_BROMURE_ENV_GEN" ] && return
        _BROMURE_ENV_GEN="$_cur"
        set -a
        [ -r /mnt/bromure-meta/proxy.env ] && . /mnt/bromure-meta/proxy.env
        [ -r /mnt/bromure-meta/api_key.env ] && . /mnt/bromure-meta/api_key.env
        set +a
        printf '\\033[2m[bromure-ac] environment refreshed\\033[0m\\n'
    }
    case "${PROMPT_COMMAND:-}" in
        *_bromure_reload_env*) ;;
        *) PROMPT_COMMAND="_bromure_reload_env${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
    esac

    # virtiofs cwd heal. Restoring a suspended VM rebuilds VZ's virtiofs
    # backend, which hands the guest fresh inode handles — so the kernel's
    # cached handle for whatever directory a process is *sitting in* goes
    # stale, and a shell parked in a shared dir (home or a project mount) gets
    # ENOENT on its own cwd after resume. Absolute-path access re-resolves on
    # its own; a held cwd can't, so nudge it: if "." has gone stale, re-chdir
    # to the absolute $PWD (a fresh walk from the mount root). One stat per
    # prompt, a no-op unless actually stale. Same exec-freeze caveat as the env
    # refresh above — a long-running foreground agent that spanned the resume
    # keeps its own stale cwd until it exits, and the very first command after
    # a resume still runs before this fires (a bare Enter re-syncs the prompt).
    _bromure_cwd_guard() {
        [ -d . ] 2>/dev/null || builtin cd -- "$PWD" 2>/dev/null \
            || builtin cd "$HOME" 2>/dev/null
    }
    case "${PROMPT_COMMAND:-}" in
        *_bromure_cwd_guard*) ;;
        *) PROMPT_COMMAND="_bromure_cwd_guard${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
    esac

    # Codex local-inference provider. Points Codex at the on-host engine via
    # a model_provider (wire_api="chat"). Laid down BEFORE the MCP block so
    # its top-level keys (model / model_provider) precede any [mcp_servers.*]
    # tables — TOML requires top-level keys before table headers.
    # NOTE on the .tmp.$$ + mv dance in the blocks below: this rc runs in
    # EVERY shell, and at boot tmux starts several panes' shells at once —
    # a shared tmp path made them race each other (one shell mv'd the tmp
    # away, the loser printed "mv: cannot stat …tmp"). Per-PID tmps + one
    # atomic rename make each writer land a complete file; since every
    # shell renders identical content, last-writer-wins is stable.
    if [ -r /mnt/bromure-meta/codex-local.toml ]; then
        mkdir -p "$HOME/.codex"
        cat /mnt/bromure-meta/codex-local.toml > "$HOME/.codex/config.toml.tmp.$$" \
            && mv -f "$HOME/.codex/config.toml.tmp.$$" "$HOME/.codex/config.toml"
    fi

    # Grok local-inference. The grok CLI defaults its model id to "grok-build";
    # without a map the engine 404s (it only serves the repo name). A
    # [model.grok-build] override rewrites what's sent to the API. We APPEND
    # (grok's config.toml already has [cli]/[ui]) and strip any prior bromure
    # block first so re-boots stay idempotent.
    if [ -r /mnt/bromure-meta/grok-local.toml ]; then
        mkdir -p "$HOME/.grok"
        touch "$HOME/.grok/config.toml"
        # Strip our prior block AND any stray [model.grok-build] section (older
        # builds — or grok itself — may leave an unmarked one, which collides
        # with ours as a duplicate TOML key and breaks config parsing).
        if awk '
            /^\\[model\\.grok-build\\]/ { drop=1; next }
            /^\\[/ { drop=0 }
            /^# >>> bromure-local$/ { next }
            /^# <<< bromure-local$/ { next }
            drop { next }
            { print }
        ' "$HOME/.grok/config.toml" > "$HOME/.grok/config.toml.tmp.$$" 2>/dev/null; then
            cat /mnt/bromure-meta/grok-local.toml >> "$HOME/.grok/config.toml.tmp.$$"
            mv -f "$HOME/.grok/config.toml.tmp.$$" "$HOME/.grok/config.toml"
        else
            rm -f "$HOME/.grok/config.toml.tmp.$$"
        fi
    fi

    # MCP server configs. Installed for EVERY agent (claude/codex/grok), not
    # just the primary tool — the built-in `browser` server (plus any user
    # servers) must reach whichever agent the user runs. Each install is
    # idempotent so re-boots don't duplicate.
    if [ -d /mnt/bromure-meta/mcp ]; then
        # Claude Code — dict-merge mcpServers into ~/.claude.json.
        if [ -r /mnt/bromure-meta/mcp/claude.json ]; then
            mkdir -p "$HOME/.claude"
            if [ -f "$HOME/.claude.json" ]; then
                python3 -c "import json,os,sys;e=json.load(open(sys.argv[1]));m=json.load(open(sys.argv[2]));e['mcpServers']={**e.get('mcpServers',{}),**m.get('mcpServers',{})};t=sys.argv[1]+'.tmp.'+str(os.getpid());json.dump(e,open(t,'w'),indent=2);os.replace(t,sys.argv[1])" "$HOME/.claude.json" /mnt/bromure-meta/mcp/claude.json 2>/dev/null
            else
                cp /mnt/bromure-meta/mcp/claude.json "$HOME/.claude.json"
            fi
        fi
        # Grok CLI — same mcpServers JSON shape, merged into its settings.
        # Best-effort: the exact grok settings path can vary by version.
        if [ -r /mnt/bromure-meta/mcp/claude.json ]; then
            mkdir -p "$HOME/.grok"
            python3 -c "import json,os,sys;p=os.path.expanduser('~/.grok/user-settings.json');e=(json.load(open(p)) if os.path.exists(p) else {});m=json.load(open(sys.argv[1]));e['mcpServers']={**e.get('mcpServers',{}),**m.get('mcpServers',{})};t=p+'.tmp.'+str(os.getpid());json.dump(e,open(t,'w'),indent=2);os.replace(t,p)" /mnt/bromure-meta/mcp/claude.json 2>/dev/null || true
        fi
        # Codex — marker-guarded install into config.toml (strip a prior
        # bromure block, then append) so [mcp_servers.*] tables don't stack up.
        if [ -r /mnt/bromure-meta/mcp/codex.toml ]; then
            mkdir -p "$HOME/.codex"
            touch "$HOME/.codex/config.toml"
            if sed '/# >>> bromure-mcp/,/# <<< bromure-mcp/d' "$HOME/.codex/config.toml" > "$HOME/.codex/config.toml.tmp.$$" 2>/dev/null; then
                { echo "# >>> bromure-mcp"; cat /mnt/bromure-meta/mcp/codex.toml; echo "# <<< bromure-mcp"; } >> "$HOME/.codex/config.toml.tmp.$$"
                mv -f "$HOME/.codex/config.toml.tmp.$$" "$HOME/.codex/config.toml"
            else
                rm -f "$HOME/.codex/config.toml.tmp.$$"
            fi
        fi
    fi

    # Stay in $HOME (~ubuntu) on shell start. Shared folders are
    # available as ~/<basename> symlinks if you want them.

    # If the tool isn't on PATH, try a one-shot install. Logs to
    # /tmp/bromure-tool-install.log so the user can dig if it fails.
    _bromure_install_tool() {
        local tool="$1"
        case "$tool" in
            claude)
                # Claude Code ships only via npm. Wrapped through
                # socket.dev per project policy.
                echo "[bromure-ac] claude not found — installing @anthropic-ai/claude-code…"
                if npx --yes @socketsecurity/cli npm install -g --silent @anthropic-ai/claude-code \\
                        >>/tmp/bromure-tool-install.log 2>&1; then
                    echo "[bromure-ac] installed @anthropic-ai/claude-code"
                    return 0
                fi
                echo "[bromure-ac] install failed (see /tmp/bromure-tool-install.log)"
                return 1
                ;;
            codex)
                # Codex CLI ships via npm as @openai/codex. Wrapped
                # through socket.dev per project policy.
                echo "[bromure-ac] codex not found — installing @openai/codex…"
                if npx --yes @socketsecurity/cli npm install -g --silent @openai/codex \\
                        >>/tmp/bromure-tool-install.log 2>&1; then
                    echo "[bromure-ac] installed @openai/codex"
                    return 0
                fi
                echo "[bromure-ac] install failed (see /tmp/bromure-tool-install.log)"
                return 1
                ;;
            grok)
                # Grok ships via x.ai's shell installer (not npm). Fallback
                # only — normally baked into the base image. The installer
                # drops it under ~/.grok/bin, so add that to PATH.
                echo "[bromure-ac] grok not found — installing via x.ai…"
                if curl -fsSL https://x.ai/cli/install.sh | bash >>/tmp/bromure-tool-install.log 2>&1; then
                    [ -d "$HOME/.grok/bin" ] && export PATH="$HOME/.grok/bin:$PATH"
                    echo "[bromure-ac] installed grok"
                    return 0
                fi
                echo "[bromure-ac] install failed (see /tmp/bromure-tool-install.log)"
                return 1
                ;;
            *)
                return 1
                ;;
        esac
    }

    # Auto-launch the agent on the FIRST interactive shell of this VM
    # session only. Subsequent kitty tabs / new windows / nested shells
    # all skip the launch and land at plain bash. The marker lives in
    # /tmp so it resets across reboots.
    _bromure_marker=/tmp/.bromure-ac-agent-launched
    # Auto-launch the agent ONLY in a registration VM (BROMURE_AC_REGISTER=1),
    # so a throwaway login VM kicks off `claude`/`codex` automatically. Normal
    # sessions intentionally land at a plain shell — the user starts the agent
    # themselves. Gated to once per boot by the marker; `-t 1` (interactive
    # terminal) is used instead of `$SHLVL=1` because the kitty's bash runs at
    # SHLVL 2 (login shell → startx → openbox → kitty adds a level).
    # Worktree tab: the host opens this window with BROMURE_AC_WT_TOOL set (see
    # `worktree-create`). Run that tool here — this branch runs regardless of
    # the primary-tab marker, so a worktree sub-agent always starts even though
    # the first tab already claimed the marker. All the env/MCP/token setup
    # above has already run for this interactive shell.
    if [ -n "${BROMURE_AC_WT_TOOL:-}" ] && [ -t 1 ]; then
        _wt_tool="$BROMURE_AC_WT_TOOL"; unset BROMURE_AC_WT_TOOL
        # Pin the agent's start dir to the checkout root the guest agent
        # chose. tmux already opens the window there (-c), but the agent
        # must never inherit a drifted $PWD — an agent started in a
        # subfolder scopes itself to that subfolder.
        _wt_dir="${BROMURE_AC_WT_DIR:-}"; unset BROMURE_AC_WT_DIR
        if [ -n "$_wt_dir" ] && [ -d "$_wt_dir" ]; then
            cd -- "$_wt_dir" 2>/dev/null || true
        fi
        # Extra CLI flags for THIS launch only, decided host-side by agentd
        # (empty for manual worktrees; the unattended-automation path passes
        # each tool's skip-confirmation flag so the "trust this folder" /
        # permission prompt can't hang the run). Captured and unset before the
        # tool runs, so it never leaks to the agent, a subshell, or the next
        # command — and .bashrc holds no knowledge of what the flags mean.
        # Flags have no spaces, so $_wt_flags is left unquoted to word-split
        # (empty → nothing).
        _wt_flags="${BROMURE_AC_WT_FLAGS:-}"; unset BROMURE_AC_WT_FLAGS
        if ! command -v "$_wt_tool" >/dev/null 2>&1; then
            _bromure_install_tool "$_wt_tool" || true
            hash -r 2>/dev/null || true
        fi
        if command -v "$_wt_tool" >/dev/null 2>&1; then
            printf '\\033[2m[bromure-ac] starting %s in worktree…\\033[0m\\n' "$_wt_tool"
            if [ -n "${BROMURE_AC_WT_PROMPT:-}" ]; then
                _wt_prompt=$(printf '%s' "$BROMURE_AC_WT_PROMPT" | base64 -d 2>/dev/null)
                unset BROMURE_AC_WT_PROMPT
                "$_wt_tool" $_wt_flags "$_wt_prompt"
            else
                "$_wt_tool" $_wt_flags
            fi
            # A nonzero exit means the agent DIED (bad flag, config error,
            # crash) rather than finishing — flag the tab needs-input so the
            # board card turns red instead of sitting "in progress" forever;
            # the error is on screen in this terminal.
            _wt_rc=$?
            if [ "$_wt_rc" -ne 0 ]; then
                printf '\033[31m[bromure-ac] %s exited with status %s\033[0m\n' "$_wt_tool" "$_wt_rc"
                sh "$HOME/.bromure/agent-status.sh" needsInput 2>/dev/null || true
            fi
        fi
        unset _wt_tool _wt_prompt _wt_flags _wt_dir
    fi

    if [ "$BROMURE_AC_REGISTER" = "1" ] \\
       && [ -t 1 ] \\
       && [ ! -e "$_bromure_marker" ] \\
       && [ -n "$BROMURE_AC_TOOL" ]; then
        if ! command -v "$BROMURE_AC_TOOL" >/dev/null 2>&1; then
            _bromure_install_tool "$BROMURE_AC_TOOL" || true
            # Re-source PATH-affecting bits in case install added bins.
            hash -r 2>/dev/null || true
        fi
        if command -v "$BROMURE_AC_TOOL" >/dev/null 2>&1; then
            : > "$_bromure_marker"
            # Visible breadcrumb so a slow-starting agent doesn't
            # look like a hung black terminal — particularly after
            # a reboot, when /tmp is fresh and this auto-launch
            # path runs again from scratch.
            printf '\\033[2m[bromure-ac] starting %s…\\033[0m\\n' "$BROMURE_AC_TOOL"
            "$BROMURE_AC_TOOL"
        fi
    fi
    unset _bromure_marker

    # User customizations.
    [ -f "$HOME/.bashrc.local" ] && . "$HOME/.bashrc.local"
    """

    private static let bashrcLocalSeed = """
    # ~/.bashrc.local — your customizations live here. Anything in this
    # file is sourced at the end of the managed .bashrc and is preserved
    # across Bromure AC updates.
    #
    # Examples:
    #   alias ll='ls -lah'
    #   export EDITOR=nvim
    """

    /// .bash_profile: bash sources this on login shells (agetty autologin
    /// gives us one). On tty1 we exec startx so the user lands in kitty;
    /// any other login shell just sources .bashrc.
    ///
    /// **Hostname change happens here, before startx**, because xauth's
    /// MIT-MAGIC-COOKIE is keyed by the hostname at the moment the X
    /// server initializes. Changing it from xinitrc (after the X server
    /// is up) makes every later X client (openbox, kitty) fail to
    /// authenticate, which collapses the session.
    private static let bashProfileContent = #"""
    # Apply per-profile hostname BEFORE startx — see comment above.
    if [ -r /mnt/bromure-meta/hostname.txt ]; then
        NEW_HOST=$(head -1 /mnt/bromure-meta/hostname.txt | tr -d '[:space:]')
        if [ -n "$NEW_HOST" ]; then
            # /etc/hosts first, so subsequent sudo calls can resolve.
            NEW_HOSTS=$(mktemp 2>/dev/null || echo /tmp/hosts.new)
            {
                printf '127.0.0.1\tlocalhost %s\n'  "$NEW_HOST"
                printf '::1\tlocalhost %s\n'         "$NEW_HOST"
                printf '127.0.1.1\t%s\n'             "$NEW_HOST"
                printf '\n# Bromure AC: managed at session boot.\n'
            } > "$NEW_HOSTS"
            sudo install -m 644 "$NEW_HOSTS" /etc/hosts >/dev/null 2>&1 || true
            rm -f "$NEW_HOSTS"
            sudo hostname "$NEW_HOST" >/dev/null 2>&1 || true
            echo "$NEW_HOST" | sudo tee /etc/hostname >/dev/null 2>&1 || true
        fi
    fi

    # Headless boot (plan phase 3): on tty1 (the agetty autologin terminal)
    # bootstrap the bromure-agentd systemd unit and hand the session to it —
    # X11/kitty stay on disk but never start. Rewritten whenever the marker
    # line is missing, so existing images converge without a rebuild (agentd's
    # task_fix_systemd_unit is the twin for images that don't reboot — keep
    # the unit text byte-identical with _UNIT_CONTENT there). KillMode=process
    # is the load-bearing line: the tmux server and every agent in it live in
    # this service's cgroup, and the default control-group kill made the
    # hot-upgrade exit(0) SIGTERM the whole session and stall the respawn for
    # TimeoutStopSec (default 90s) — a frozen, then emptied, workspace.
    # StartLimitIntervalSec=0: the daemon must respawn forever; the default
    # 5-in-10s limit permanently failed the unit on a crash loop even after
    # the host restaged a fixed source.
    if [ "$(tty)" = "/dev/tty1" ] && [ -r /mnt/bromure-meta/bromure-agentd.py ]; then
        if ! grep -sq "KillMode=process" /etc/systemd/system/bromure-agentd.service; then
            sudo tee /etc/systemd/system/bromure-agentd.service >/dev/null <<'UNIT'
    [Unit]
    Description=Bromure guest agent daemon
    After=mnt-bromure\x2dmeta.mount network.target
    StartLimitIntervalSec=0
    [Service]
    Type=simple
    User=ubuntu
    ExecStart=/usr/bin/python3 /mnt/bromure-meta/bromure-agentd.py
    Restart=always
    RestartSec=1
    KillMode=process
    TimeoutStopSec=5
    [Install]
    WantedBy=multi-user.target
    UNIT
            sudo systemctl daemon-reload >/dev/null 2>&1 || true
            sudo systemctl enable bromure-agentd.service >/dev/null 2>&1 || true
        fi
        sudo systemctl start bromure-agentd.service >/dev/null 2>&1 || true
    fi
    [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
    """#

    /// .profile: fallback for shells that read .profile (sh login shells,
    /// some cron contexts). Just hands off to .bashrc.
    private static let profileContent = """
    if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
    """


}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

// MARK: - Configured-credential enumeration (Credentials + Guardrails panes)

/// Category buckets for the Credentials pane's grouped, configured-only list.
public enum CredentialCategory: Int, CaseIterable, Sendable {
    case agents, git, cloud, databases, ssh, other
    public var title: String {
        switch self {
        case .agents:    return "Agents"
        case .git:       return "Git"
        case .cloud:     return "Cloud"
        case .databases: return "Databases"
        case .ssh:       return "SSH"
        case .other:     return "Other"
        }
    }
    public var symbol: String {
        switch self {
        case .agents:    return "sparkles"
        case .git:       return "arrow.triangle.branch"
        case .cloud:     return "cloud.fill"
        case .databases: return "cylinder.split.1x2.fill"
        case .ssh:       return "key.fill"
        case .other:     return "ellipsis.curlybraces"
        }
    }
}

/// A stable reference to one configured credential on a `Profile`. Both the
/// Credentials pane (shows only configured credentials) and the Guardrails pane
/// (approval + write-mode per credential) enumerate these so the two stay in
/// lockstep with what actually produces a swap at session launch.
public enum CredentialRef: Hashable, Sendable, Identifiable {
    case primaryToolKey
    case additionalTool(Profile.Tool)
    case git(UUID)
    case manual(UUID)
    case docker(UUID)
    case database(UUID)
    case kube(UUID)
    case aws
    case digitalOcean
    case linear
    case managedSSHKey
    case importedSSHKey(UUID)

    public var id: String {
        switch self {
        case .primaryToolKey:        return "primaryToolKey"
        case .additionalTool(let u): return "tool:\(u.rawValue)"
        case .git(let u):            return "git:\(u.uuidString)"
        case .manual(let u):         return "manual:\(u.uuidString)"
        case .docker(let u):         return "docker:\(u.uuidString)"
        case .database(let u):       return "db:\(u.uuidString)"
        case .kube(let u):           return "kube:\(u.uuidString)"
        case .aws:                   return "aws"
        case .digitalOcean:          return "do"
        case .linear:                return "linear"
        case .managedSSHKey:         return "ssh-managed"
        case .importedSSHKey(let u): return "ssh:\(u.uuidString)"
        }
    }

    /// Parse the stable `id` wire form back into a ref — lets the server ship the
    /// configured-credential list (computed from the real profile, before secrets
    /// are blanked) to a remote guardrails pane.
    public init?(wireID: String) {
        switch wireID {
        case "primaryToolKey": self = .primaryToolKey
        case "aws":            self = .aws
        case "do":             self = .digitalOcean
        case "linear":         self = .linear
        case "ssh-managed":    self = .managedSSHKey
        default:
            let parts = wireID.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "tool":
                guard let t = Profile.Tool(rawValue: parts[1]) else { return nil }
                self = .additionalTool(t)
            case "git":    guard let u = UUID(uuidString: parts[1]) else { return nil }; self = .git(u)
            case "manual": guard let u = UUID(uuidString: parts[1]) else { return nil }; self = .manual(u)
            case "docker": guard let u = UUID(uuidString: parts[1]) else { return nil }; self = .docker(u)
            case "db":     guard let u = UUID(uuidString: parts[1]) else { return nil }; self = .database(u)
            case "kube":   guard let u = UUID(uuidString: parts[1]) else { return nil }; self = .kube(u)
            case "ssh":    guard let u = UUID(uuidString: parts[1]) else { return nil }; self = .importedSSHKey(u)
            default: return nil
            }
        }
    }

    public var category: CredentialCategory {
        switch self {
        case .primaryToolKey, .additionalTool:              return .agents
        case .git:                                          return .git
        case .aws, .digitalOcean, .docker, .kube, .linear:  return .cloud
        case .database:                                     return .databases
        case .managedSSHKey, .importedSSHKey:               return .ssh
        case .manual:                                       return .other
        }
    }

    public var symbol: String {
        switch self {
        case .primaryToolKey, .additionalTool: return "sparkles"
        case .git:                             return "arrow.triangle.branch"
        case .manual:                          return "key.horizontal.fill"
        case .docker:                          return "shippingbox.fill"
        case .database:                        return "cylinder.split.1x2.fill"
        case .kube:                            return "shippingbox.fill"
        case .aws:                             return "server.rack"
        case .digitalOcean:                    return "cloud.fill"
        case .linear:                          return "line.diagonal"
        case .managedSSHKey, .importedSSHKey:  return "key.fill"
        }
    }

    /// Which credential-editor type this ref belongs to (drives the edit sheet).
    public var editorType: CredentialEditorType {
        switch self {
        case .primaryToolKey, .additionalTool: return .agents
        case .git:                             return .git
        case .manual:                          return .manual
        case .docker:                          return .docker
        case .database:                        return .database
        case .kube:                            return .kubernetes
        case .aws:                             return .aws
        case .digitalOcean:                    return .digitalOcean
        case .linear:                          return .linear
        case .managedSSHKey, .importedSSHKey:  return .ssh
        }
    }
}

/// The distinct credential kinds the "Add credential" picker offers; also the
/// editor page a Credentials-pane row opens.
public enum CredentialEditorType: String, CaseIterable, Identifiable, Sendable {
    case agents, git, ssh, aws, digitalOcean, linear, kubernetes, docker, database, manual
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .agents:       return "Agent API key"
        case .git:          return "Git token"
        case .ssh:          return "SSH key"
        case .aws:          return "AWS credentials"
        case .digitalOcean: return "DigitalOcean token"
        case .linear:       return "Linear API key"
        case .kubernetes:   return "Kubernetes"
        case .docker:       return "Container registry"
        case .database:     return "Database"
        case .manual:       return "Other API key"
        }
    }
    public var symbol: String {
        switch self {
        case .agents:       return "sparkles"
        case .git:          return "arrow.triangle.branch"
        case .ssh:          return "key.fill"
        case .aws:          return "server.rack"
        case .digitalOcean: return "cloud.fill"
        case .linear:       return "line.diagonal"
        case .kubernetes:   return "shippingbox.fill"
        case .docker:       return "shippingbox.fill"
        case .database:     return "cylinder.split.1x2.fill"
        case .manual:       return "key.horizontal.fill"
        }
    }
    public var subtitle: String {
        switch self {
        case .agents:       return "Anthropic, OpenAI, or xAI API key for a coding agent"
        case .git:          return "Personal access token for GitHub, GitLab, or Bitbucket"
        case .ssh:          return "Import a private key, or use the per-workspace key"
        case .aws:          return "Static IAM keys or SSO — SigV4-signed on the wire"
        case .digitalOcean: return "doctl / API personal access token"
        case .linear:       return "Linear personal API key"
        case .kubernetes:   return "A cluster context (token, client cert, or exec plugin)"
        case .docker:       return "Registry login for Docker Hub, ghcr.io, and others"
        case .database:     return "MongoDB Data API, ClickHouse, or Elasticsearch"
        case .manual:       return "Any other token — you choose the env var and host(s)"
        }
    }
}

public extension Profile {
    /// Every credential that is actually configured (produces a swap), in
    /// category order. The single list the Credentials and Guardrails panes
    /// consume, using the same usability predicates as `makeTokenPlan`.
    func configuredCredentials() -> [CredentialRef] {
        var refs: [CredentialRef] = []
        // Agents
        if authMode == .token, !(apiKey ?? "").isEmpty { refs.append(.primaryToolKey) }
        for spec in additionalTools where spec.authMode == .token && !(spec.apiKey ?? "").isEmpty {
            refs.append(.additionalTool(spec.id))
        }
        // Git
        for c in gitHTTPSCredentials where c.isUsable { refs.append(.git(c.id)) }
        // Cloud
        if awsCredentials.isUsable { refs.append(.aws) }
        if !digitalOceanToken.isEmpty { refs.append(.digitalOcean) }
        if !linearToken.isEmpty { refs.append(.linear) }
        for r in dockerRegistries where r.isUsable { refs.append(.docker(r.id)) }
        for k in kubeconfigs where k.isUsable { refs.append(.kube(k.id)) }
        // Databases
        for d in httpDatabases where d.isUsable { refs.append(.database(d.id)) }
        // SSH
        if sshPublicKey != nil { refs.append(.managedSSHKey) }
        for k in importedSSHKeys { refs.append(.importedSSHKey(k.id)) }
        // Other
        for m in manualTokens where m.isUsable { refs.append(.manual(m.id)) }
        return refs
    }

    /// Configured credentials grouped by category (only non-empty categories),
    /// in display order.
    func configuredCredentialsByCategory() -> [(CredentialCategory, [CredentialRef])] {
        credentialsByCategory(configuredCredentials())
    }

    /// Group an explicit ref list by category (only non-empty categories), in
    /// display order. Used with a server-supplied list when a remote profile's
    /// blanked secrets would otherwise hide creds from `configuredCredentials()`.
    func credentialsByCategory(_ all: [CredentialRef]) -> [(CredentialCategory, [CredentialRef])] {
        CredentialCategory.allCases.compactMap { cat in
            let items = all.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    /// A short human title for a credential row.
    func credentialTitle(_ ref: CredentialRef) -> String {
        switch ref {
        case .primaryToolKey:
            return "\(tool.displayName) API key"
        case .additionalTool(let u):
            return (additionalTools.first { $0.id == u }?.tool.displayName ?? "Agent") + " API key"
        case .git(let u):
            guard let c = gitHTTPSCredentials.first(where: { $0.id == u }) else { return "Git token" }
            return c.username.isEmpty ? "Git token (\(c.host))" : "\(c.username)@\(c.host)"
        case .manual(let u):
            let m = manualTokens.first { $0.id == u }
            if let n = m?.name, !n.isEmpty { return n }
            if let e = m?.envVarName, !e.isEmpty { return e }
            return "Manual token"
        case .docker(let u):
            return dockerRegistries.first { $0.id == u }?.host ?? "Registry"
        case .database(let u):
            guard let d = httpDatabases.first(where: { $0.id == u }) else { return "Database" }
            return d.name.isEmpty ? d.engine.displayName : d.name
        case .kube(let u):
            return kubeconfigs.first { $0.id == u }?.name ?? "Kubernetes"
        case .aws:            return "AWS credentials"
        case .digitalOcean:   return "DigitalOcean token"
        case .linear:         return "Linear API key"
        case .managedSSHKey:  return "Workspace SSH key"
        case .importedSSHKey(let u):
            return importedSSHKeys.first { $0.id == u }?.label ?? "SSH key"
        }
    }

    /// The destination host(s) shown under a credential row (informational).
    func credentialHosts(_ ref: CredentialRef) -> [String] {
        func toolHosts(_ t: Tool) -> [String] {
            switch t {
            case .claude: return ["anthropic.com"]
            case .codex:  return ["openai.com"]
            case .grok:   return ["x.ai"]
            }
        }
        switch ref {
        case .primaryToolKey: return toolHosts(tool)
        case .additionalTool(let u): return toolHosts(additionalTools.first { $0.id == u }?.tool ?? tool)
        case .git(let u): return gitHTTPSCredentials.first { $0.id == u }.map { [$0.host] } ?? []
        case .manual(let u):
            return manualTokens.first { $0.id == u }?.hostFilters.filter { !$0.isEmpty } ?? []
        case .docker(let u): return dockerRegistries.first { $0.id == u }.map { [$0.host] } ?? []
        case .database(let u): return httpDatabases.first { $0.id == u }.map { [$0.host] } ?? []
        case .kube(let u):
            guard let k = kubeconfigs.first(where: { $0.id == u }) else { return [] }
            return [URL(string: k.serverURL)?.host ?? k.serverURL]
        case .aws:          return ["amazonaws.com"]
        case .digitalOcean: return ["digitalocean.com"]
        case .linear:       return ["linear.app"]
        case .managedSSHKey, .importedSSHKey: return []
        }
    }
}
