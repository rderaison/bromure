import Foundation

/// Preset accent colors for visual identification in the profile picker.
public enum ProfileColor: String, Codable, CaseIterable, Equatable, Sendable {
    case blue, red, green, orange, purple, pink, teal, gray
    public var label: String { rawValue.capitalized }
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

    public init(id: UUID = UUID(),
                label: String,
                filename: String,
                publicKeyText: String = "",
                hasPassphrase: Bool = false) {
        self.id = id
        self.label = label
        self.filename = filename
        self.publicKeyText = publicKeyText
        self.hasPassphrase = hasPassphrase
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
    /// Optional host substring filter. Empty = swap on any host where
    /// the fake appears. Useful when the fake might leak to a third
    /// party we don't want quietly rewriting (rare but possible).
    public var hostFilter: String

    public init(id: UUID = UUID(), name: String = "", realValue: String = "",
                envVarName: String = "", hostFilter: String = "") {
        self.id = id
        self.name = name
        self.realValue = realValue
        self.envVarName = envVarName
        self.hostFilter = hostFilter
    }

    public var isUsable: Bool {
        !realValue.isEmpty
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

    public init(id: UUID = UUID(), host: String = "github.com", username: String = "", token: String = "") {
        self.id = id
        self.host = host
        self.username = username
        self.token = token
    }

    /// True if this entry has enough to be written to ~/.git-credentials.
    public var isUsable: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !token.isEmpty
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

        public var id: Tool { tool }

        public init(tool: Tool, authMode: AuthMode = .token, apiKey: String? = nil) {
            self.tool = tool
            self.authMode = authMode
            self.apiKey = apiKey
        }
    }

    public let id: UUID
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
        windowOpacity: Double = 0.97
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
        self.gitUserName = gitUserName
        self.gitUserEmail = gitUserEmail
        self.useTerminalAppDefaults = useTerminalAppDefaults
        self.customFontFamily = customFontFamily
        self.customFontSize = customFontSize
        self.customBackgroundHex = customBackgroundHex
        self.customForegroundHex = customForegroundHex
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
        case cursorShape, windowOpacity
        case gitHTTPSCredentials
        case additionalTools
        case manualTokens
        case importedSSHKeys
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

    var isEmpty: Bool {
        (apiKey?.isEmpty ?? true)
            && additionalToolApiKeys.isEmpty
            && gitHTTPSTokens.isEmpty
            && manualTokenValues.isEmpty
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
    }

    /// Wipe the per-profile disk so the next launch re-clones from base.
    /// The home dir (mounted as /home/ubuntu) is intentionally untouched
    /// so settings, history, and installed tools survive a reset.
    public func resetDisk(for profile: Profile) throws {
        let disk = diskURL(for: profile)
        if fm.fileExists(atPath: disk.path) {
            try fm.removeItem(at: disk)
        }
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
                                     tokenPlan: SessionTokenPlan? = nil) throws {
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
    # or ~/.local/bin (where the codex binary install drops things).
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
                # Codex CLI is a static Rust binary published on
                # github.com/openai/codex. Skip npm — that path goes
                # through @openai/codex which has had postinstall
                # flakiness behind the proxy. Direct binary download
                # is the reliable path.
                echo "[bromure-ac] codex not found — fetching the latest GitHub release…"
                local arch target tag url tmpdir bin
                arch=$(uname -m)
                case "$arch" in
                    aarch64|arm64) target=aarch64-unknown-linux-musl ;;
                    x86_64)        target=x86_64-unknown-linux-musl  ;;
                    *) echo "[bromure-ac] unsupported arch $arch"; return 1 ;;
                esac
                tag=$(curl -fsSL https://api.github.com/repos/openai/codex/releases/latest \\
                      2>>/tmp/bromure-tool-install.log \\
                      | grep -m1 '"tag_name"' | cut -d'"' -f4)
                if [ -z "$tag" ]; then
                    echo "[bromure-ac] couldn't resolve codex release tag"
                    return 1
                fi
                url="https://github.com/openai/codex/releases/download/${tag}/codex-${target}.tar.gz"
                tmpdir=$(mktemp -d)
                if ! curl -fsSL "$url" -o "$tmpdir/codex.tar.gz" \\
                        2>>/tmp/bromure-tool-install.log; then
                    echo "[bromure-ac] failed to download $url"
                    rm -rf "$tmpdir"
                    return 1
                fi
                tar -xzf "$tmpdir/codex.tar.gz" -C "$tmpdir" 2>>/tmp/bromure-tool-install.log
                bin=$(find "$tmpdir" -type f -name 'codex-*' ! -name '*.tar.gz' | head -1)
                [ -z "$bin" ] && bin=$(find "$tmpdir" -type f -name 'codex' | head -1)
                if [ -z "$bin" ]; then
                    echo "[bromure-ac] codex binary not found in tarball"
                    rm -rf "$tmpdir"
                    return 1
                fi
                mkdir -p "$HOME/.local/bin"
                install -m 755 "$bin" "$HOME/.local/bin/codex"
                rm -rf "$tmpdir"
                echo "[bromure-ac] installed codex $tag → ~/.local/bin/codex"
                return 0
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
    # SSH KEX_ECDH_REPLY, npm tarball chunks) blackhole. 1400 is the
    # commonly-recommended safe value behind virtual interfaces.
    NIC=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -n "$NIC" ]; then
        sudo ip link set dev "$NIC" mtu 1400 2>/dev/null || true
        echo "[xinit] set $NIC mtu 1400" >> /tmp/xinitrc.log
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

    # Start the in-VM bridge daemon: 127.0.0.1:8080 + /tmp/bromure-agent.sock
    # both relay over vsock to the host's MITM engine. Foregrounding to
    # /tmp/bromure-vm-bridge.log helps debugging when the env-var
    # approach inevitably hits an edge case.
    if [ -r /mnt/bromure-meta/bromure-vm-bridge.py ]; then
        python3 /mnt/bromure-meta/bromure-vm-bridge.py &
        echo "[xinit] bromure-vm-bridge pid $!" >> /tmp/xinitrc.log
    fi

    openbox &
    sleep 0.3
    spice-vdagent &
    sleep 0.2

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
