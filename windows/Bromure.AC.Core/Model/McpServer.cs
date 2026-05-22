// macos-source: Sources/AgentCoding/Profile.swift @ 5feff2fd78b5  (MCPServer / MCPOAuthState)
using System.Collections.ObjectModel;
using System.Text.Json.Serialization;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Direct port of Swift <c>MCPServer</c>. One MCP (Model Context Protocol)
/// server configured in a profile. At VM boot the host serializes enabled
/// entries into the agent-appropriate config file (Claude Code JSON,
/// Codex TOML) and writes them into the guest's home overlay.
/// </summary>
public sealed class McpServer
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public McpTransport Transport { get; set; } = McpTransport.Http;

    /// <summary>Stdio servers only.</summary>
    public string Command { get; set; } = "";
    public ObservableCollection<string> Arguments { get; set; } = new();

    /// <summary>HTTP servers only.</summary>
    public string Url { get; set; } = "";

    public ObservableCollection<EnvironmentVariable> Environment { get; set; } = new();

    /// <summary>Env var name Claude Code / Codex looks up for the bearer
    /// token. When set, the proxy swaps a fake value here on the wire.</summary>
    public string BearerTokenEnvVar { get; set; } = "";

    /// <summary>Plaintext bearer (or last OAuth-issued access_token). Held
    /// inline for parity with how ApiKey is stored on the Windows port
    /// today. Phase B+ moves both to <see cref="Bromure.Platform.ISecretStore"/>.</summary>
    public string BearerToken { get; set; } = "";

    public bool Enabled { get; set; } = true;

    /// <summary>When non-empty, this raw JSON is used as the server config
    /// instead of the structured fields. Allows arbitrary MCP shapes
    /// (OAuth blocks, custom fields). Bypassed when a fake token is
    /// available — the structured path handles token injection.</summary>
    public string RawJson { get; set; } = "";

    public int? StartupTimeoutSec { get; set; }
    public int? ToolTimeoutSec { get; set; }

    /// <summary>OAuth state obtained by the host-side broker. When non-null
    /// <see cref="BearerToken"/> is set from <see cref="McpOAuthState.AccessToken"/>
    /// and refreshed at session launch.</summary>
    public McpOAuthState? OAuthState { get; set; }

    [JsonIgnore]
    public string? UrlHost
    {
        get
        {
            if (Transport != McpTransport.Http) return null;
            return Uri.TryCreate(Url, UriKind.Absolute, out var u) ? u.Host : null;
        }
    }

    [JsonIgnore]
    public bool IsUsable
    {
        get
        {
            var hasName = !string.IsNullOrWhiteSpace(Name);
            return Transport switch
            {
                McpTransport.Stdio => hasName && !string.IsNullOrWhiteSpace(Command),
                McpTransport.Http => hasName && !string.IsNullOrWhiteSpace(Url),
                _ => false,
            };
        }
    }
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum McpTransport
{
    Http,
    Stdio,
}

/// <summary>
/// OAuth tokens + client registration obtained by <c>McpOAuthBroker</c>
/// for an HTTP MCP server. Persisted with the profile so the access
/// token can be refreshed across sessions without re-authorizing.
/// </summary>
public sealed class McpOAuthState
{
    public string ClientId { get; set; } = "";
    public string? ClientSecret { get; set; }
    public string AuthorizationEndpoint { get; set; } = "";
    public string TokenEndpoint { get; set; } = "";
    public string? RegistrationEndpoint { get; set; }
    public string AccessToken { get; set; } = "";
    public string? RefreshToken { get; set; }
    public DateTimeOffset? ExpiresAt { get; set; }
    public DateTimeOffset AuthorizedAt { get; set; } = DateTimeOffset.UtcNow;
    public ushort? CallbackPort { get; set; }
}
