// macos-source: Sources/AgentCoding/Profile.swift @ 5feff2fd78b5
using System.Text.Json.Serialization;

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
    /// Plaintext API token. Only stored on disk inside the profile dir.
    /// Phase B+ moves this to <see cref="Bromure.Platform.ISecretStore"/>.
    /// </summary>
    public string? ApiKey { get; set; }
    public bool ApiKeyRequiresApproval { get; set; }

    /// <summary>Other coding agents pre-configured but not auto-launched.</summary>
    public List<ToolSpec> AdditionalTools { get; set; } = new();

    /// <summary>Absolute host paths shared into the VM (capped at 8).</summary>
    public List<string> FolderPaths { get; set; } = new();

    /// <summary>
    /// Public half of the SSH key generated for this profile, for the
    /// user to paste into github.com/settings/keys. Null = user opted out.
    /// </summary>
    public string? SshPublicKey { get; set; }

    /// <summary>Git identity written to ~/.gitconfig at session start.
    /// Empty string → that field is omitted from the generated file.</summary>
    public string GitUserName { get; set; } = "";
    public string GitUserEmail { get; set; } = "";

    public List<GitHttpsCredential> GitHttpsCredentials { get; set; } = new();
    public List<ManualToken> ManualTokens { get; set; } = new();
    public List<ImportedSshKey> ImportedSshKeys { get; set; } = new();
    public List<KubeconfigEntry> Kubeconfigs { get; set; } = new();
    public List<DockerRegistryCredential> DockerRegistries { get; set; } = new();
    public List<EnvironmentVariable> EnvironmentVariables { get; set; } = new();

    /// <summary>
    /// Always non-null — the editor's AWS tab two-way-binds against
    /// the leaf fields, so a null instance would mean the bindings
    /// can't write back. The persisted JSON simply carries an empty
    /// SSO/static-keys block when AWS isn't configured.
    /// </summary>
    public AwsCredentialsConfig Aws { get; set; } = new();
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
