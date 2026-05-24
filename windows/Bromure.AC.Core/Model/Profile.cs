// macos-source: Sources/AgentCoding/Profile.swift @ 5feff2fd78b5
using System.Collections.ObjectModel;
using System.Text.Json.Serialization;
using Bromure.AC.Core.Vault;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Direct port (lightweight subset) of <c>Profile</c> from
/// <c>Sources/AgentCoding/Profile.swift</c>. Captures the on-disk JSON
/// schema's primary fields. The 2985-line Swift definition includes a
/// host of mutation helpers + macOS-specific bindings; we ship the data
/// model first and add helpers on demand from view-models.
///
/// <para>Persisted as JSON in <see cref="Bromure.Platform.IAppPaths.ProfilesDirectory"/>
/// — same shape and field names as the macOS file so a profile.json
/// dropped from a Mac into the same folder reads correctly.</para>
/// </summary>
public sealed class Profile
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public ProfileColor Color { get; set; } = ProfileColor.Blue;

    /// <summary>Primary coding agent — auto-launched in the first tab.</summary>
    public AgentTool Tool { get; set; } = AgentTool.Claude;
    public AuthMode AuthMode { get; set; } = AuthMode.Token;

    /// <summary>
    /// Primary-tool API token. Encrypted at rest via the
    /// <see cref="EncryptedStringConverter"/> when the host has wired
    /// the vault gateway; the on-disk value carries a "vault:v1:"
    /// prefix in profile.json. Legacy plaintext from pre-vault saves
    /// round-trips on first read and gets re-encrypted on next save.
    /// </summary>
    [JsonConverter(typeof(EncryptedStringConverter))]
    public string? ApiKey { get; set; }
    public bool ApiKeyRequiresApproval { get; set; }

    /// <summary>Other coding agents pre-configured but not auto-launched.</summary>
    public ObservableCollection<ToolSpec> AdditionalTools { get; set; } = new();

    /// <summary>Absolute host paths shared into the VM (capped at 8).</summary>
    public ObservableCollection<string> FolderPaths { get; set; } = new();

    /// <summary>
    /// Public half of the SSH key generated for this profile, for the
    /// user to paste into github.com/settings/keys. Null = user opted out.
    /// </summary>
    public string? SshPublicKey { get; set; }

    /// <summary>Git identity written to ~/.gitconfig at session start.
    /// Empty string → that field is omitted from the generated file.</summary>
    public string GitUserName { get; set; } = "";
    public string GitUserEmail { get; set; } = "";

    // Observable so the editor's ItemsControls re-render when the
    // Add* commands push a new entry. Plain List<T> doesn't fire
    // CollectionChanged → buttons appeared broken because the new
    // row never showed.
    public ObservableCollection<GitHttpsCredential> GitHttpsCredentials { get; set; } = new();
    public ObservableCollection<ManualToken> ManualTokens { get; set; } = new();
    public ObservableCollection<ImportedSshKey> ImportedSshKeys { get; set; } = new();
    public ObservableCollection<KubeconfigEntry> Kubeconfigs { get; set; } = new();
    public ObservableCollection<DockerRegistryCredential> DockerRegistries { get; set; } = new();
    public ObservableCollection<EnvironmentVariable> EnvironmentVariables { get; set; } = new();

    /// <summary>
    /// MCP (Model Context Protocol) servers configured for this profile.
    /// At session boot the host serializes enabled entries into
    /// <c>~/.claude.json</c> and <c>~/.codex/config.toml</c> inside the
    /// guest, with bearer tokens replaced by fakes that the proxy swaps
    /// on the wire. Direct port of macOS <c>Profile.mcpServers</c>.
    /// </summary>
    public ObservableCollection<McpServer> McpServers { get; set; } = new();

    /// <summary>
    /// Always non-null — the editor's AWS tab two-way-binds against
    /// the leaf fields, so a null instance would mean the bindings
    /// can't write back. The persisted JSON simply carries an empty
    /// SSO/static-keys block when AWS isn't configured.
    /// </summary>
    public AwsCredentialsConfig Aws { get; set; } = new();
    [JsonConverter(typeof(EncryptedStringConverter))]
    public string? DigitalOceanToken { get; set; }
    public bool DigitalOceanRequiresApproval { get; set; }

    /// <summary>
    /// Route Claude Code through AWS Bedrock instead of Anthropic
    /// directly. Mirrors the macOS port. When true, the session
    /// drops a ~/.claude/settings.json that sets
    /// <c>CLAUDE_CODE_USE_BEDROCK=1</c> + AWS_PROFILE/AWS_REGION/
    /// ANTHROPIC_MODEL.
    /// </summary>
    public bool BedrockEnabled { get; set; }
    public string BedrockModelID { get; set; } = "";

    /// <summary>
    /// "Real" OAuth tokens we previously pulled out of the VM via the
    /// SubscriptionTokenBridge. Re-seeded on launch so users don't have
    /// to re-login every fresh session.
    /// </summary>
    public StoredOAuthTokens? DefaultClaudeTokens { get; set; }
    public StoredOAuthTokens? DefaultCodexTokens { get; set; }

    /// <summary>
    /// When true, this profile's traffic is excluded from cloud
    /// telemetry. Phase 3c flag. Per-profile, persisted.
    /// </summary>
    public bool PrivateMode { get; set; }

    /// <summary>How aggressively the proxy records traffic.</summary>
    public TraceLevel TraceLevel { get; set; } = TraceLevel.Off;

    // --- Lifecycle metadata (macOS Profile.swift:870-876) ---

    /// <summary>UTC timestamp the profile was first created. Drives
    /// "newest first" sort + "created X ago" display.</summary>
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>UTC timestamp of the most recent session that used this
    /// profile. Drives the "last used X ago" UX. <c>ProfileStore.Touch</c>
    /// updates this on every successful session start. Null = never used.</summary>
    public DateTimeOffset? LastUsedAt { get; set; }

    /// <summary>The base-image version this profile's session disk was
    /// cloned from. Stamped at clone time. When the engine's current
    /// image version differs, the app surfaces the "Reset and launch /
    /// Launch as-is / Cancel" image-versioning alert. Null = no clone
    /// yet (first session).</summary>
    public string? BaseImageVersionAtClone { get; set; }

    // --- VM resources (macOS Profile.swift:889-939) ---

    /// <summary>RAM allocated to this profile's VM, in GiB. 0 = let the
    /// engine pick a sensible default that scales to the host.</summary>
    public int MemoryGB { get; set; }

    /// <summary>Network mode for this profile's VM.</summary>
    public NetworkMode NetworkMode { get; set; } = NetworkMode.Nat;
    public string? BridgedInterfaceID { get; set; }

    /// <summary>What happens when the session window's close button
    /// is clicked. macOS exposes the same three choices.</summary>
    public CloseAction CloseAction { get; set; } = CloseAction.Ask;

    // --- Appearance (macOS Profile.swift:945-993) ---

    public CursorShape CursorShape { get; set; } = CursorShape.Block;

    /// <summary>Window opacity 0.3–1.0. Applied to both the kitty
    /// config and the WPF session window's background.</summary>
    public double WindowOpacity { get; set; } = 1.0;

    /// <summary>XKB layout override, e.g. "fr", "ch:fr". Null = inherit
    /// from the host (live sync).</summary>
    public string? KeyboardLayoutOverride { get; set; }

    /// <summary>X-server <c>xset r rate</c> overrides. Null = engine default.</summary>
    public int? KeyRepeatDelayMs { get; set; }
    public int? KeyRepeatRateHz { get; set; }

    /// <summary>When true, the kitty font / color fields are filled in
    /// from the host terminal's defaults at session start. Per-profile
    /// overrides (<see cref="CustomFontFamily"/> etc.) win when set.</summary>
    public bool UseTerminalAppDefaults { get; set; } = true;

    public string? CustomFontFamily { get; set; }
    public int? CustomFontSize { get; set; }
    public string? CustomBackgroundHex { get; set; }
    public string? CustomForegroundHex { get; set; }

    // --- SSH agent consent (macOS Profile.swift:868) ---

    /// <summary>Per-sign consent gate for the auto-generated bromure
    /// SSH key. When true, every SIGN_REQUEST prompts the user.</summary>
    public bool SshKeyRequiresApproval { get; set; }

    // --- Subscription token swap consent (macOS Profile.swift:805/812) ---

    public SubscriptionTokenSwapState SubscriptionTokenSwap { get; set; } = SubscriptionTokenSwapState.Unset;
    public SubscriptionTokenSwapState CodexTokenSwap { get; set; } = SubscriptionTokenSwapState.Unset;

    /// <summary>Free-form notes shown in the profile editor.</summary>
    public string Comments { get; set; } = "";

    /// <summary>All tool specs (primary + additional). Convenience.</summary>
    [JsonIgnore]
    public IEnumerable<ToolSpec> AllToolSpecs
    {
        get
        {
            yield return new ToolSpec
            {
                Tool = Tool,
                AuthMode = AuthMode,
                ApiKey = ApiKey,
                RequireApproval = ApiKeyRequiresApproval,
            };
            foreach (var t in AdditionalTools) yield return t;
        }
    }
}

public sealed class ToolSpec
{
    public AgentTool Tool { get; set; }
    public AuthMode AuthMode { get; set; } = AuthMode.Token;
    [JsonConverter(typeof(EncryptedStringConverter))]
    public string? ApiKey { get; set; }
    public bool RequireApproval { get; set; }
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum TraceLevel
{
    /// Nothing recorded.
    Off,
    /// Per-request metadata only.
    Activity,
    /// Activity + AI hosts' request/response bodies.
    AiDetails,
    /// Bodies for every host.
    All,
}
