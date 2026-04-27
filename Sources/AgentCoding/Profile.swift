import Foundation

/// Preset accent colors for visual identification in the profile picker.
public enum ProfileColor: String, Codable, CaseIterable, Equatable, Sendable {
    case blue, red, green, orange, purple, pink, teal, gray
    public var label: String { rawValue.capitalized }
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
/// agent so the in-VM ssh client sees it via the multiplex.
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
    /// Optional host scope. Empty = swap on any host where the fake
    /// appears. Non-empty = exact-or-subdomain match: a scope of
    /// `example.com` swaps on requests to `example.com` and any
    /// `*.example.com`, but not on `example.com.evil.com`. Match is
    /// case-insensitive. Substring matching is deliberately NOT used.
    public var hostFilter: String
    /// When true, every fake→real substitution for this token prompts
    /// the user on the host. See `ConsentBroker`.
    public var requireApproval: Bool

    public init(id: UUID = UUID(), name: String = "", realValue: String = "",
                envVarName: String = "", hostFilter: String = "",
                requireApproval: Bool = false) {
        self.id = id
        self.name = name
        self.realValue = realValue
        self.envVarName = envVarName
        self.hostFilter = hostFilter
        self.requireApproval = requireApproval
    }

    public var isUsable: Bool {
        !realValue.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, realValue, envVarName, hostFilter, requireApproval
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        name            = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        realValue       = try c.decodeIfPresent(String.self, forKey: .realValue) ?? ""
        envVarName      = try c.decodeIfPresent(String.self, forKey: .envVarName) ?? ""
        hostFilter      = try c.decodeIfPresent(String.self, forKey: .hostFilter) ?? ""
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(realValue, forKey: .realValue)
        try c.encode(envVarName, forKey: .envVarName)
        try c.encode(hostFilter, forKey: .hostFilter)
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
public struct AWSCredentials: Codable, Equatable, Sendable {
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

    public init(accessKeyID: String = "",
                secretAccessKey: String = "",
                sessionToken: String = "",
                region: String = "",
                requireApproval: Bool = false) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
        self.requireApproval = requireApproval
    }

    /// True when at least the access-key + secret pair is set — the
    /// minimum for a signing-capable profile.
    public var isUsable: Bool {
        !accessKeyID.trimmingCharacters(in: .whitespaces).isEmpty
            && !secretAccessKey.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case accessKeyID, secretAccessKey, sessionToken, region, requireApproval
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessKeyID     = try c.decodeIfPresent(String.self, forKey: .accessKeyID) ?? ""
        secretAccessKey = try c.decodeIfPresent(String.self, forKey: .secretAccessKey) ?? ""
        sessionToken    = try c.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
        region          = try c.decodeIfPresent(String.self, forKey: .region) ?? ""
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessKeyID, forKey: .accessKeyID)
        try c.encode(secretAccessKey, forKey: .secretAccessKey)
        try c.encode(sessionToken, forKey: .sessionToken)
        try c.encode(region, forKey: .region)
        if requireApproval { try c.encode(true, forKey: .requireApproval) }
    }
}

/// One agentic-coding profile: which tool, how it auths, what folder it
/// works against, and where its persistent disk lives.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public enum Tool: String, Codable, CaseIterable, Sendable {
        case claude
        case codex
        public var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex:  return "Codex"
            }
        }
        /// Env-var name the in-VM init script writes the API key to when
        /// auth mode is .token.
        public var apiKeyEnvVar: String {
            switch self {
            case .claude: return "ANTHROPIC_API_KEY"
            case .codex:  return "OPENAI_API_KEY"
            }
        }
    }

    public enum AuthMode: String, Codable, CaseIterable, Sendable {
        case token         // user-supplied API key, injected as env var
        case subscription  // user runs `claude login` / `codex login` in the VM

        public var displayName: String {
            switch self {
            case .token:        return "API token"
            case .subscription: return "Subscription (interactive login)"
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
        /// When true, every fake→real swap of this tool's API key
        /// prompts on the host. See `ConsentBroker`.
        public var requireApproval: Bool

        public var id: Tool { tool }

        public init(tool: Tool, authMode: AuthMode = .token,
                    apiKey: String? = nil, requireApproval: Bool = false) {
            self.tool = tool
            self.authMode = authMode
            self.apiKey = apiKey
            self.requireApproval = requireApproval
        }

        private enum CodingKeys: String, CodingKey {
            case tool, authMode, apiKey, requireApproval
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tool            = try c.decode(Tool.self, forKey: .tool)
            authMode        = try c.decodeIfPresent(AuthMode.self, forKey: .authMode) ?? .token
            apiKey          = try c.decodeIfPresent(String.self, forKey: .apiKey)
            requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tool, forKey: .tool)
            try c.encode(authMode, forKey: .authMode)
            try c.encodeIfPresent(apiKey, forKey: .apiKey)
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

    /// Plaintext API token. Only stored on disk inside the profile dir
    /// (which is in the user's library), not in the keychain — the
    /// agentic-coding base image is the only consumer and it lives on
    /// the same Mac. Phase B+ moves this to the keychain.
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

    /// User-defined manual swap rules for the MITM proxy. Real values
    /// stay on the host; the VM's env carries fakes. See ManualToken.
    public var manualTokens: [ManualToken]

    /// Pre-existing SSH private keys the user has pointed at this
    /// profile. Loaded into the bromure ssh-agent at every session
    /// launch alongside the auto-generated key.
    public var importedSSHKeys: [ImportedSSHKey]

    /// How aggressively the proxy records traffic for this profile.
    /// Default `.off` — opt-in because higher levels write request/
    /// response bodies (encrypted) to disk.
    public var traceLevel: TraceLevel

    /// Pre-configured Kubernetes contexts. At session prep we
    /// generate a synthetic ~/.kube/config in the VM and register the
    /// real credentials with the proxy for upstream substitution.
    public var kubeconfigs: [KubeconfigEntry]

    /// DigitalOcean Personal Access Token. Injected as
    /// DIGITALOCEAN_ACCESS_TOKEN env + ~/.config/doctl/config.yaml in
    /// the VM as a fake; proxy swaps to the real value on
    /// api.digitalocean.com requests. Empty = not configured.
    public var digitalOceanToken: String

    /// AWS credentials injected into ~/.aws/credentials + environment
    /// for the AWS CLI / SDKs. See `AWSCredentials` for the SigV4
    /// reasoning. Empty struct (`isUsable == false`) = not configured.
    public var awsCredentials: AWSCredentials

    /// Container-registry credentials. One entry per host. Materialized
    /// as ~/.docker/config.json `auths` entries (with FAKE base64 auth
    /// strings); the proxy swaps fake → real on the wire when the
    /// request hits the matching registry host.
    public var dockerRegistries: [DockerRegistryCredential]

    /// Gate the primary tool's API key behind a consent prompt. See
    /// `ConsentBroker`. Default false.
    public var apiKeyRequiresApproval: Bool

    /// Gate the DigitalOcean PAT behind a consent prompt. Default false.
    public var digitalOceanTokenRequiresApproval: Bool

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

    /// What to do with the VM when the user closes the session window.
    /// `.suspend` saves RAM to disk and resumes instantly next launch.
    /// `.shutdown` does a clean ACPI poweroff. `.ask` prompts each time.
    public enum CloseAction: String, Codable, CaseIterable, Sendable {
        case suspend
        case shutdown
        case ask

        public var displayName: String {
            switch self {
            case .suspend:  return NSLocalizedString("Suspend", comment: "")
            case .shutdown: return NSLocalizedString("Shut down", comment: "")
            case .ask:      return NSLocalizedString("Ask", comment: "")
            }
        }
    }

    /// What happens when the user closes a session window. Defaults to
    /// `.suspend` so closing a window feels instant on next launch.
    public var closeAction: CloseAction

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
    /// works everywhere). Bridged uses VZBridgedNetworkDeviceAttachment
    /// against the chosen host interface so the VM gets a LAN-routable IP.
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
        traceLevel: TraceLevel = .off,
        kubeconfigs: [KubeconfigEntry] = [],
        digitalOceanToken: String = "",
        awsCredentials: AWSCredentials = AWSCredentials(),
        dockerRegistries: [DockerRegistryCredential] = [],
        apiKeyRequiresApproval: Bool = false,
        digitalOceanTokenRequiresApproval: Bool = false,
        sshKeyRequiresApproval: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        baseImageVersionAtClone: String? = nil,
        color: ProfileColor = .blue,
        comments: String = "",
        memoryGB: Int = Profile.defaultMemoryGB(),
        networkMode: NetworkMode = .nat,
        bridgedInterfaceID: String? = nil,
        gitUserName: String = "",
        gitUserEmail: String = "",
        useTerminalAppDefaults: Bool = false,
        customFontFamily: String? = nil,
        customFontSize: Int? = nil,
        customBackgroundHex: String? = nil,
        customForegroundHex: String? = nil,
        cursorShape: CursorShape = .block,
        windowOpacity: Double = 0.97,
        keyboardLayoutOverride: String? = nil,
        keyRepeatDelayMs: Int? = nil,
        keyRepeatRateHz: Int? = nil,
        closeAction: CloseAction = .suspend
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
        self.traceLevel = traceLevel
        self.kubeconfigs = kubeconfigs
        self.digitalOceanToken = digitalOceanToken
        self.awsCredentials = awsCredentials
        self.dockerRegistries = dockerRegistries
        self.apiKeyRequiresApproval = apiKeyRequiresApproval
        self.digitalOceanTokenRequiresApproval = digitalOceanTokenRequiresApproval
        self.sshKeyRequiresApproval = sshKeyRequiresApproval
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.baseImageVersionAtClone = baseImageVersionAtClone
        self.color = color
        self.comments = comments
        self.memoryGB = memoryGB
        self.networkMode = networkMode
        self.bridgedInterfaceID = bridgedInterfaceID
        self.cursorShape = cursorShape
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
        self.closeAction = closeAction
    }

    /// Default-tolerant decoder so old JSON files (missing newer fields) load.
    enum CodingKeys: String, CodingKey {
        case id, name, tool, authMode, apiKey, sshPublicKey
        case folderPath  // legacy: single folder, migrated to folderPaths
        case folderPaths
        case createdAt, lastUsedAt, baseImageVersionAtClone, color, comments
        case memoryGB, gitUserName, gitUserEmail
        case useTerminalAppDefaults, customFontFamily, customFontSize
        case customBackgroundHex, customForegroundHex
        case networkMode, bridgedInterfaceID
        case cursorShape, windowOpacity, keyboardLayoutOverride
        case keyRepeatDelayMs, keyRepeatRateHz
        case gitHTTPSCredentials
        case additionalTools
        case manualTokens
        case importedSSHKeys
        case traceLevel
        case kubeconfigs
        case digitalOceanToken
        case awsCredentials
        case dockerRegistries
        case apiKeyRequiresApproval
        case digitalOceanTokenRequiresApproval
        case sshKeyRequiresApproval
        case closeAction
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
        gitUserName     = try c.decodeIfPresent(String.self, forKey: .gitUserName) ?? ""
        gitUserEmail    = try c.decodeIfPresent(String.self, forKey: .gitUserEmail) ?? ""
        useTerminalAppDefaults = try c.decodeIfPresent(Bool.self, forKey: .useTerminalAppDefaults) ?? true
        customFontFamily       = try c.decodeIfPresent(String.self, forKey: .customFontFamily)
        customFontSize         = try c.decodeIfPresent(Int.self, forKey: .customFontSize)
        customBackgroundHex    = try c.decodeIfPresent(String.self, forKey: .customBackgroundHex)
        customForegroundHex    = try c.decodeIfPresent(String.self, forKey: .customForegroundHex)
        networkMode            = try c.decodeIfPresent(NetworkMode.self, forKey: .networkMode) ?? .nat
        bridgedInterfaceID     = try c.decodeIfPresent(String.self, forKey: .bridgedInterfaceID)
        cursorShape            = try c.decodeIfPresent(CursorShape.self, forKey: .cursorShape) ?? .beam
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
        traceLevel = try c.decodeIfPresent(TraceLevel.self, forKey: .traceLevel) ?? .off
        kubeconfigs = try c.decodeIfPresent([KubeconfigEntry].self, forKey: .kubeconfigs) ?? []
        digitalOceanToken = try c.decodeIfPresent(String.self, forKey: .digitalOceanToken) ?? ""
        awsCredentials = try c.decodeIfPresent(AWSCredentials.self, forKey: .awsCredentials) ?? AWSCredentials()
        dockerRegistries = try c.decodeIfPresent([DockerRegistryCredential].self, forKey: .dockerRegistries) ?? []
        apiKeyRequiresApproval = try c.decodeIfPresent(Bool.self, forKey: .apiKeyRequiresApproval) ?? false
        digitalOceanTokenRequiresApproval = try c.decodeIfPresent(Bool.self, forKey: .digitalOceanTokenRequiresApproval) ?? false
        sshKeyRequiresApproval = try c.decodeIfPresent(Bool.self, forKey: .sshKeyRequiresApproval) ?? false
        closeAction = try c.decodeIfPresent(CloseAction.self, forKey: .closeAction) ?? .suspend
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
        try c.encode(gitUserName, forKey: .gitUserName)
        try c.encode(gitUserEmail, forKey: .gitUserEmail)
        try c.encode(useTerminalAppDefaults, forKey: .useTerminalAppDefaults)
        try c.encodeIfPresent(customFontFamily, forKey: .customFontFamily)
        try c.encodeIfPresent(customFontSize, forKey: .customFontSize)
        try c.encodeIfPresent(customBackgroundHex, forKey: .customBackgroundHex)
        try c.encodeIfPresent(customForegroundHex, forKey: .customForegroundHex)
        try c.encode(networkMode, forKey: .networkMode)
        try c.encodeIfPresent(bridgedInterfaceID, forKey: .bridgedInterfaceID)
        try c.encode(cursorShape, forKey: .cursorShape)
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
        if traceLevel != .off {
            try c.encode(traceLevel, forKey: .traceLevel)
        }
        if !kubeconfigs.isEmpty {
            try c.encode(kubeconfigs, forKey: .kubeconfigs)
        }
        if !digitalOceanToken.isEmpty {
            try c.encode(digitalOceanToken, forKey: .digitalOceanToken)
        }
        if awsCredentials.isUsable
            || !awsCredentials.region.isEmpty
            || !awsCredentials.accessKeyID.isEmpty {
            try c.encode(awsCredentials, forKey: .awsCredentials)
        }
        if !dockerRegistries.isEmpty {
            try c.encode(dockerRegistries, forKey: .dockerRegistries)
        }
        if apiKeyRequiresApproval { try c.encode(true, forKey: .apiKeyRequiresApproval) }
        if digitalOceanTokenRequiresApproval {
            try c.encode(true, forKey: .digitalOceanTokenRequiresApproval)
        }
        if sshKeyRequiresApproval { try c.encode(true, forKey: .sshKeyRequiresApproval) }
        try c.encode(closeAction, forKey: .closeAction)
    }

    /// Every tool configured on this profile, primary first. Each entry
    /// is a self-contained ToolSpec — sites that need to enumerate every
    /// agent (e.g. SessionDisk's api_key.env writer, the welcome message)
    /// can iterate this without caring which one is "primary".
    public var allToolSpecs: [ToolSpec] {
        var specs = [ToolSpec(tool: tool, authMode: authMode, apiKey: apiKey)]
        // Defensive: filter out any duplicate of the primary in case the
        // editor's invariant slipped (or a JSON edit bypassed the decoder).
        for s in additionalTools where s.tool != tool {
            specs.append(s)
        }
        return specs
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

    var isEmpty: Bool {
        (apiKey?.isEmpty ?? true)
            && additionalToolApiKeys.isEmpty
            && gitHTTPSTokens.isEmpty
            && manualTokenValues.isEmpty
            && (kubeconfigs?.isEmpty ?? true)
            && (digitalOceanToken?.isEmpty ?? true)
            && (awsSecretAccessKey?.isEmpty ?? true)
            && (awsSessionToken?.isEmpty ?? true)
            && (dockerRegistryPasswords?.isEmpty ?? true)
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
        if let sk = awsSecretAccessKey { profile.awsCredentials.secretAccessKey = sk }
        if let st = awsSessionToken { profile.awsCredentials.sessionToken = st }
        if let map = dockerRegistryPasswords {
            for (i, reg) in profile.dockerRegistries.enumerated() {
                if let p = map[reg.id.uuidString] {
                    profile.dockerRegistries[i].password = p
                }
            }
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

    public func profileDirectory(for profile: Profile) -> URL {
        rootDir.appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }

    public func diskURL(for profile: Profile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("disk.img")
    }

    /// The host-side dir mounted as /home/ubuntu in the guest. Persistent
    /// across `Reset disk` — anything the user installs into their home
    /// (npm-global, cargo, .ssh, .bash_history, etc.) survives.
    public func homeDirectory(for profile: Profile) -> URL {
        profileDirectory(for: profile).appendingPathComponent("home", isDirectory: true)
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
    /// blob), the per-profile system disk, the persistent home dir,
    /// and the host-only `agent/` + `ssh/` dirs.
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

        // Persistent home dir. clonefile() recurses, so one call
        // duplicates the whole tree as APFS CoW.
        let srcHome = srcDir.appendingPathComponent("home", isDirectory: true)
        if fm.fileExists(atPath: srcHome.path) {
            let dstHome = dstDir.appendingPathComponent("home", isDirectory: true)
            try? fm.removeItem(at: dstHome)
            try Self.cloneItem(at: srcHome, to: dstHome)
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
    }

    /// Logical size of a per-profile disk image (sparse — what it
    /// actually occupies on disk, not the 24 GB allocation). Returns 0
    /// if the file doesn't exist yet.
    public func diskSizeBytes(for profile: Profile) -> Int64 {
        Self.allocatedBytes(at: diskURL(for: profile))
    }

    /// Recursive sum of every regular file under the profile's home
    /// directory. Walks lazily; suitable for backgrounding via Task.
    /// Returns 0 if the directory doesn't exist.
    public func homeSizeBytes(for profile: Profile) -> Int64 {
        Self.directoryBytes(at: homeDirectory(for: profile))
    }

    /// Last-modified timestamp of the profile's home directory, or nil
    /// if it doesn't exist. Used by the storage stack to show "active
    /// X minutes ago" labels.
    public func homeLastModified(for profile: Profile) -> Date? {
        let url = homeDirectory(for: profile)
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

        // Managed dotfiles — always rewrite. (.xinitrc lives here too so
        // we can iterate on the X session / terminal launch without
        // bumping the base-image version.)
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
        let xinitrc = home.appendingPathComponent(".xinitrc")
        try Self.xinitrcContent.write(to: xinitrc, atomically: true, encoding: .utf8)
        // ~/.xinitrc must be executable for startx to run it directly.
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: xinitrc.path)

        // Tab agent: long-running shell script that polls
        // /mnt/bromure-outbox/cmd-*.txt for tab commands sent by the host
        // and runs the corresponding kitty / wmctrl-equivalent action in
        // the guest. Always rewritten so we can iterate the protocol.
        let agent = home.appendingPathComponent(".bromure-tab-agent.sh")
        try Self.tabAgentContent.write(to: agent, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: agent.path)

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

        // Per-user kitty.conf, derived from this profile's resolved style
        // (Terminal.app inheritance OR per-profile overrides). Always
        // rewritten so style edits in the profile editor take effect on
        // the next launch.
        let kittyConfigDir = home.appendingPathComponent(".config/kitty", isDirectory: true)
        try fm.createDirectory(at: kittyConfigDir, withIntermediateDirectories: true)
        let kittyConfig = kittyConfigDir.appendingPathComponent("kitty.conf")
        try TerminalAppDefaults
            .kittyConfig(for: profile, terminalDefaults: terminalDefaults)
            .write(to: kittyConfig, atomically: true, encoding: .utf8)

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

        // Migrate legacy SSH keys: profiles/<id>/ssh → home/.ssh
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
    if [ "$SHLVL" = "1" ] \\
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

    # Auto-start X on tty1 (the agetty autologin terminal). On any other
    # tty (e.g. a dropped-back console), just behave like a normal login.
    if [ -z "${DISPLAY-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
        exec startx
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

    /// ~/.xinitrc: startx runs this when present (falls back to
    /// /etc/X11/xinit/xinitrc otherwise). Lives on the host so we can
    /// iterate on the X session without bumping the base-image version.
    ///
    /// The agent is the long-running foreground process — it never
    /// returns (loops forever), so xinit keeps X alive. Kittys are
    /// spawned on demand by the host via outbox commands.
    private static let xinitrcContent = #"""
    #!/bin/sh
    exec > /tmp/xinitrc.log 2>&1
    set -x

    xsetroot -solid '#0d1117'
    xset s off -dpms

    # Key-repeat feel — match macOS's InitialKeyRepeat + KeyRepeat so
    # typing in kitty is identical to typing in Terminal.app on the
    # host. The host writes "<delay_ms> <rate_hz>" into the meta share
    # at session prep.
    if [ -r /mnt/bromure-meta/key_repeat ]; then
        KR=$(cat /mnt/bromure-meta/key_repeat)
        # shellcheck disable=SC2086 # intentional word split: "<delay> <rate>"
        xset r rate $KR 2>/dev/null && \
            echo "[xinit] key repeat $KR" >> /tmp/xinitrc.log
    fi

    # Force mesa software rendering — virtio-gpu's GL stack under VZ isn't
    # reliable enough for kitty's 3.3 core profile requirement.
    export LIBGL_ALWAYS_SOFTWARE=1

    # NB: hostname is applied in .bash_profile BEFORE `exec startx`,
    # not here. Doing it here breaks xauth — the MIT-MAGIC-COOKIE is
    # keyed by hostname at xinit time, so changing it mid-X-session
    # locks every X client out of the display and the VM unwinds.

    # Lower MTU on the primary NIC. VZ NAT reports MTU 1500 but the
    # actual host path can be smaller (Wi-Fi, VPN, corp firewall) and
    # PMTUD doesn't always recover — large packets (TLS handshakes,
    # SSH KEX_ECDH_REPLY, npm tarball chunks) blackhole. The host
    # writes its preferred value to /mnt/bromure-meta/mtu (default 1400,
    # overridable via `defaults write io.bromure.agentic-coding vm.mtu`).
    MTU=1400
    [ -r /mnt/bromure-meta/mtu ] && MTU=$(tr -dc '0-9' < /mnt/bromure-meta/mtu)
    [ -z "$MTU" ] && MTU=1400
    NIC=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -n "$NIC" ]; then
        sudo ip link set dev "$NIC" mtu "$MTU" 2>/dev/null || true
        echo "[xinit] set $NIC mtu $MTU" >> /tmp/xinitrc.log
    fi

    # Install the host's MITM CA into the system trust store so the
    # forged per-host leaves the proxy presents are trusted by every
    # TLS client in the VM (curl, gh, glab, node fetch, python requests,
    # etc.). update-ca-certificates rebuilds /etc/ssl/certs/ca-certificates.crt
    # — that's the bundle every language ecosystem above ends up reading.
    if [ -r /mnt/bromure-meta/bromure-ca.pem ]; then
        sudo install -m 0644 /mnt/bromure-meta/bromure-ca.pem \
            /usr/local/share/ca-certificates/bromure-ca.crt
        sudo update-ca-certificates >/dev/null
        # node respects NODE_EXTRA_CA_CERTS pointing at the raw PEM, so
        # also drop the original PEM where /mnt/bromure-meta won't be
        # available at the time node forks (different envvars).
        sudo install -m 0644 /mnt/bromure-meta/bromure-ca.pem \
            /etc/ssl/certs/bromure-ca.pem
    fi

    # Resume-time clock sync. VZ freezes CLOCK_REALTIME during
    # saveMachineState, so on resume the wall clock is N minutes/hours
    # behind real time until systemd-timesyncd notices. The host
    # writes the current Unix timestamp into
    # /mnt/bromure-meta/.resume-signal right after vm.resume(); a
    # long-running watcher daemon polls that file and, on change,
    # sets the clock to whatever the host wrote.
    #
    # We use polling instead of systemd PathChanged= because virtiofs
    # doesn't reliably deliver inotify events for host-side file
    # writes — the path-unit approach silently never fires. 2 s
    # polling on a 64-byte file is cheap.
    sudo tee /usr/local/bin/bromure-resume-watcher.sh \
        >/dev/null <<'WATCHER'
    #!/bin/bash
    # Managed by Bromure Agentic Coding — rewritten on every launch.
    set -u
    LOG=/tmp/bromure-resume.log
    SIGNAL=/mnt/bromure-meta/.resume-signal
    echo "--- $(date -u +%FT%TZ) bromure-resume-watcher started ---" >> "$LOG"
    # Skip whatever stale value is sitting in the signal file at
    # daemon-start: only react to *changes*. Otherwise a cold boot
    # would set the clock to the previous resume's timestamp.
    LAST=""
    if [ -r "$SIGNAL" ]; then
        LAST=$(cat "$SIGNAL" 2>/dev/null | tr -d '[:space:]')
        echo "$(date -u +%FT%TZ) ignoring stale boot value: '$LAST'" >> "$LOG"
    fi
    while true; do
        if [ -r "$SIGNAL" ]; then
            ts=$(cat "$SIGNAL" 2>/dev/null | tr -d '[:space:]')
            if [ -n "$ts" ] && [ "$ts" != "$LAST" ]; then
                case "$ts" in
                    *[!0-9]*)
                        echo "$(date -u +%FT%TZ) signal not numeric: '$ts'" >> "$LOG"
                        ;;
                    *)
                        before=$(date -u +%FT%TZ)
                        if date -u -s "@$ts" >/dev/null; then
                            after=$(date -u +%FT%TZ)
                            echo "$(date -u +%FT%TZ) clock set: was $before → now $after (target ts=$ts)" >> "$LOG"
                        else
                            echo "$(date -u +%FT%TZ) date -s failed (rc=$?)" >> "$LOG"
                        fi
                        ;;
                esac
                LAST="$ts"
            fi
        fi
        sleep 2
    done
    WATCHER
    sudo chmod +x /usr/local/bin/bromure-resume-watcher.sh

    # Drop the (broken) path-unit-based wiring from earlier builds.
    sudo systemctl disable --now bromure-resume.path >/dev/null 2>&1 || true
    sudo rm -f /etc/systemd/system/bromure-resume.path

    sudo tee /etc/systemd/system/bromure-resume.service \
        >/dev/null <<'SVCU'
    [Unit]
    Description=Watch for Bromure VM resume signal and re-sync the clock
    After=mnt-bromure\x2dmeta.mount

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/bromure-resume-watcher.sh
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    SVCU
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    sudo systemctl enable --now bromure-resume.service >/dev/null 2>&1 \
        && echo "[xinit] bromure-resume watcher running" >> /tmp/xinitrc.log \
        || echo "[xinit] bromure-resume watcher enable failed (non-fatal)" \
            >> /tmp/xinitrc.log

    # Start the in-VM bridge daemon: 127.0.0.1:8080 + /tmp/bromure-agent.sock
    # both relay over vsock to the host's MITM engine. Foregrounding to
    # /tmp/bromure-vm-bridge.log helps debugging when the env-var
    # approach inevitably hits an edge case.
    if [ -r /mnt/bromure-meta/bromure-vm-bridge.py ]; then
        python3 /mnt/bromure-meta/bromure-vm-bridge.py &
        echo "[xinit] bromure-vm-bridge pid $!" >> /tmp/xinitrc.log
    fi

    # Wire dockerd through the bridge.
    #
    # dockerd is launched by systemd at boot, BEFORE this xinitrc runs.
    # That means: (a) the CA pool it cached predates our update-ca-
    # certificates install above (so registry certs forged by Bromure
    # CA fail TLS verify), and (b) shell HTTPS_PROXY env doesn't reach
    # dockerd (systemd doesn't import the user session env).
    #
    # Drop in a systemd unit fragment that sets the proxy + restart
    # docker. Restart picks up both the freshly-installed CA pool and
    # the proxy env in one shot. Best-effort — failures don't break
    # the rest of the session.
    if [ -r /mnt/bromure-meta/bromure-vm-bridge.py ] \
       && command -v docker >/dev/null 2>&1; then
        sudo mkdir -p /etc/systemd/system/docker.service.d
        sudo tee /etc/systemd/system/docker.service.d/bromure-proxy.conf \
            >/dev/null <<'CONF'
    # Managed by Bromure Agentic Coding — rewritten on every launch.
    [Service]
    Environment="HTTP_PROXY=http://127.0.0.1:8080"
    Environment="HTTPS_PROXY=http://127.0.0.1:8080"
    Environment="NO_PROXY=localhost,127.0.0.1,::1"
    CONF
        sudo systemctl daemon-reload >/dev/null 2>&1
        sudo systemctl restart docker >/dev/null 2>&1 \
            && echo "[xinit] docker restarted with bromure proxy + CA" \
                >> /tmp/xinitrc.log \
            || echo "[xinit] docker restart failed (non-fatal)" \
                >> /tmp/xinitrc.log
    fi

    # Keyboard layout agent — listens on vsock 5006 for layout pushes
    # from the macOS host (KeyboardBridge). Initial layout arrives
    # before the user can type; subsequent macOS layout switches
    # propagate live (debounced 200ms host-side).
    if [ -r /mnt/bromure-meta/keyboard-agent.py ]; then
        python3 /mnt/bromure-meta/keyboard-agent.py &
        echo "[xinit] keyboard-agent pid $!" >> /tmp/xinitrc.log
    fi

    # Natural scrolling is handled at the kitty level via
    # wheel_scroll_multiplier / touch_scroll_multiplier in the
    # generated kitty.conf — see TerminalAppDefaults.scrollDirectionStanza.
    # That's the only layer we control reliably given the base image
    # doesn't ship xinput and we don't want to rebuild it.

    # Timezone — match macOS at session start so date / journal /
    # commit timestamps line up with what the user sees on the host.
    # Re-applied per session (the meta share is rebuilt each launch),
    # so DST transitions and travel are picked up without an image
    # rebuild.
    if [ -r /mnt/bromure-meta/tz ]; then
        TZID=""
        read -r TZID < /mnt/bromure-meta/tz || true
        if [ -n "$TZID" ] && [ -e "/usr/share/zoneinfo/$TZID" ]; then
            sudo timedatectl set-timezone "$TZID" 2>/dev/null || sudo ln -sf "/usr/share/zoneinfo/$TZID" /etc/localtime
            export TZ="$TZID"
            echo "[xinit] timezone set to $TZID" >> /tmp/xinitrc.log
        fi
    fi

    openbox &
    sleep 0.3
    spice-vdagent &
    sleep 0.2

    # spice-vdagent loses its virtio-console handle to spice-vdagentd
    # whenever the VM is paused/resumed (VZSpiceAgentPortAttachment
    # doesn't gracefully reconnect on the guest side), which kills
    # macOS clipboard ↔ X CLIPBOARD bridging until the agent is
    # respawned. This watcher runs as the X-session user, polls the
    # host's resume-signal file the root watcher already uses, and
    # kicks spice-vdagent on every change.
    (
        LAST=""
        if [ -r /mnt/bromure-meta/.resume-signal ]; then
            LAST=$(cat /mnt/bromure-meta/.resume-signal 2>/dev/null | tr -d '[:space:]')
        fi
        while true; do
            if [ -r /mnt/bromure-meta/.resume-signal ]; then
                ts=$(cat /mnt/bromure-meta/.resume-signal 2>/dev/null | tr -d '[:space:]')
                if [ -n "$ts" ] && [ "$ts" != "$LAST" ]; then
                    pkill -u "$USER" spice-vdagent 2>/dev/null
                    sleep 0.3
                    spice-vdagent &
                    echo "[xinit] respawned spice-vdagent after resume (ts=$ts)" \
                        >> /tmp/xinitrc.log
                    LAST="$ts"
                fi
            fi
            sleep 2
        done
    ) >/dev/null 2>&1 &
    echo "[xinit] spice-vdagent resume-restarter pid $!" >> /tmp/xinitrc.log

    # (We used to set xrandr --dpi based on host scale here; ditched
    # because the kittyConfig generator now scales font_size by 1.5×
    # directly, which gives a visually-matched-to-Terminal.app result at
    # the default X DPI. One knob is enough.)

    # IP reporter: every 5s, write the primary IPv4 address to the outbox.
    # Host polls + surfaces it in the toolbar.
    (
        while true; do
            ip=$(hostname -I 2>/dev/null | awk '{print $1}')
            [ -n "$ip" ] && echo "$ip" > /mnt/bromure-outbox/ip.txt
            sleep 5
        done
    ) >/dev/null 2>&1 &

    # Materialize per-profile folder shares as symlinks under ~. Each
    # entry in /mnt/bromure-meta/shares.txt is "<slot-index> <basename>";
    # the matching virtiofs slot is mounted at /mnt/bromure-share-<N>.
    #
    # /home/ubuntu is the persistent virtiofs home, so symlinks created
    # by a previous launch survive into this one. Sweep any top-level
    # symlinks that point at our share slots before recreating, so a
    # config change that drops or renames a share doesn't leave the old
    # ~/<basename> behind. -lname is precise: only symlinks whose target
    # matches /mnt/bromure-share-* get removed; user files and unrelated
    # symlinks are untouched.
    find "$HOME" -maxdepth 1 -type l -lname '/mnt/bromure-share-*' -delete \
        2>>/tmp/xinitrc.log
    {
        echo "--- shares debug at $(date +%T) ---"
        echo "shares.txt exists: $([ -r /mnt/bromure-meta/shares.txt ] && echo yes || echo no)"
        echo "shares.txt contents:"
        cat /mnt/bromure-meta/shares.txt 2>/dev/null
        echo "share mount points:"
        ls -la /mnt/bromure-share-* 2>/dev/null
        echo "mount table:"
        mount | grep -E 'virtiofs|share|bromure' 2>/dev/null
    } >> /tmp/xinitrc.log
    if [ -r /mnt/bromure-meta/shares.txt ]; then
        while IFS=' ' read -r idx name; do
            [ -z "$idx" ] && continue
            [ -z "$name" ] && continue
            src="/mnt/bromure-share-$idx"
            dst="$HOME/$name"
            echo "[shares] try idx=$idx name=$name src=$src dst=$dst src_exists=$([ -d "$src" ] && echo yes || echo no) dst_exists=$([ -e "$dst" ] && echo yes || echo no)" >> /tmp/xinitrc.log
            if [ -d "$src" ] && [ ! -e "$dst" ]; then
                if ln -s "$src" "$dst" 2>>/tmp/xinitrc.log; then
                    echo "[shares] symlinked ~/$name → $src" >> /tmp/xinitrc.log
                else
                    echo "[shares] FAILED ln -s for ~/$name" >> /tmp/xinitrc.log
                fi
            fi
        done < /mnt/bromure-meta/shares.txt
    fi

    # Resize watcher: polls xrandr every 1s. When the macOS host window
    # changes size, VZ (with automaticallyReconfiguresDisplay = true) adds
    # the new resolution as an xrandr mode. We then activate it so kitty
    # gets more / fewer cols+rows instead of the framebuffer just being
    # scaled. Same approach the browser uses for Chromium.
    (
        while true; do
            OUTPUT=$(xrandr 2>/dev/null | grep " connected" | cut -d" " -f1 | head -1)
            [ -z "$OUTPUT" ] && OUTPUT="Virtual-1"
            CUR=$(xrandr 2>/dev/null | grep "^$OUTPUT " \
                | grep -o "[0-9]*x[0-9]*+[0-9]*+[0-9]*" | head -1 | cut -d+ -f1)
            BEST=$(xrandr 2>/dev/null | grep -A1 "^$OUTPUT " | tail -1 \
                | sed "s/^ *//" | cut -d" " -f1)
            if [ -n "$BEST" ] && [ "$BEST" != "$CUR" ]; then
                xrandr --output "$OUTPUT" --mode "$BEST" 2>/dev/null
            fi
            sleep 1
        done
    ) >/dev/null 2>&1 &

    # The tab agent is the foreground process. It loops forever polling
    # /mnt/bromure-outbox/cmd-*.txt and spawning / raising / closing kitty
    # windows in response to host commands. Killing it ends the X session.
    exec bash "$HOME/.bromure-tab-agent.sh"
    """#

    /// ~/.bromure-tab-agent.sh: runs inside the VM as the X session
    /// foreground process. Polls /mnt/bromure-outbox for cmd-*.txt files
    /// and dispatches them. One file per command, single line, format:
    ///     spawn-kitty <UUID>
    ///     raise-kitty <UUID>
    ///     close-kitty <UUID>
    /// The UUID becomes the kitty's WM_CLASS so we can target it via
    /// xdotool (when available) or `kill` for close.
    private static let tabAgentContent = #"""
    #!/bin/bash
    # Bromure AC tab agent. Generated by the host — rewritten on every launch.
    INBOX=/mnt/bromure-outbox
    LOG=/tmp/bromure-agent.log

    log() { printf '%s [agent] %s\n' "$(date +%T)" "$*" >> "$LOG"; }

    log "starting"

    have_xdotool=0
    command -v xdotool >/dev/null 2>&1 && have_xdotool=1
    log "xdotool=$have_xdotool"

    spawn_kitty() {
        local id="$1"
        local closed_file="$INBOX/closed-${id}.txt"
        local kitty_log="/tmp/kitty-${id}.log"
        local kitty_conf="$HOME/.config/kitty/kitty.conf"
        log "spawn id=$id conf=$kitty_conf closed=$closed_file"
        (
            # --config forces this exact file — without it kitty has
            # been observed picking up a stale system /etc/xdg/kitty
            # one in some environments, ignoring the per-profile values.
            kitty --config "$kitty_conf" --start-as=fullscreen \
                  --class "bromure-${id}" \
                  >"$kitty_log" 2>&1
            rc=$?
            echo "$(date +%T) [agent] kitty rc=$rc id=$id" >> "$LOG"
            printf 'closed\n' > "$closed_file"
            wrc=$?
            echo "$(date +%T) [agent] wrote $closed_file rc=$wrc exists=$([ -e "$closed_file" ] && echo yes || echo no)" >> "$LOG"
        ) &
    }

    raise_kitty() {
        local id="$1"
        log "raise id=$id"
        if [ "$have_xdotool" = "1" ]; then
            local wid
            wid=$(xdotool search --class "bromure-${id}" 2>/dev/null | head -1)
            [ -n "$wid" ] && xdotool windowactivate "$wid" 2>/dev/null
        fi
    }

    close_kitty() {
        local id="$1"
        log "close id=$id"
        if [ "$have_xdotool" = "1" ]; then
            local wid
            wid=$(xdotool search --class "bromure-${id}" 2>/dev/null | head -1)
            [ -n "$wid" ] && xdotool windowclose "$wid" 2>/dev/null
        else
            pkill -f "kitty --start-as=fullscreen --class bromure-${id}" 2>/dev/null || true
        fi
    }

    # Title reporter: every 1.5s, walk every running kitty (matched by
    # its `--class bromure-<UUID>` argument), find the foreground
    # process of its child shell's controlling tty, write
    # /mnt/bromure-outbox/title-<UUID>.txt with that process name.
    # The host's outbox poller uses these to drive the tab labels —
    # claude / codex / vim / bash / etc. instead of "Session N".
    title_loop() {
        while :; do
            for entry in /proc/*/cmdline; do
                [ -r "$entry" ] || continue
                cmd=$(tr '\0' ' ' < "$entry" 2>/dev/null)
                case "$cmd" in
                    *"--class bromure-"*) ;;
                    *) continue ;;
                esac
                pid=$(basename "$(dirname "$entry")")
                # Pull the UUID out of "--class bromure-<uuid>".
                uuid=$(printf '%s' "$cmd" | sed -n 's/.*--class bromure-\([^ ]*\).*/\1/p')
                [ -z "$uuid" ] && continue
                # Kitty's child = the shell. Then the shell's tty
                # foreground PG = whatever the user is running.
                shell=$(pgrep -P "$pid" 2>/dev/null | head -1)
                [ -z "$shell" ] && continue
                fg_pgid=$(ps -o tpgid= -p "$shell" 2>/dev/null | tr -d ' ')
                [ -z "$fg_pgid" ] && continue
                title=$(ps -p "$fg_pgid" -o comm= 2>/dev/null | tr -d ' \n')
                [ -z "$title" ] && continue
                printf '%s\n' "$title" > "$INBOX/title-${uuid}.txt" 2>/dev/null
            done
            sleep 1.5
        done
    }
    title_loop &

    while :; do
        if [ -d "$INBOX" ]; then
            for f in "$INBOX"/cmd-*.txt; do
                [ -e "$f" ] || continue
                line=$(head -1 "$f" 2>/dev/null)
                rm -f "$f"
                action="${line%% *}"
                arg="${line#* }"
                log "got cmd action=$action arg=$arg"
                case "$action" in
                    spawn-kitty)  spawn_kitty "$arg" ;;
                    raise-kitty)  raise_kitty "$arg" ;;
                    close-kitty)  close_kitty "$arg" ;;
                    soft-reboot)  log "soft-reboot triggered"; sudo reboot ;;
                    *)            log "unknown action '$action'" ;;
                esac
            done
        fi
        sleep 0.2
    done
    """#
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
