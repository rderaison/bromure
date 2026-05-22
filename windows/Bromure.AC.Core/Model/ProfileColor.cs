// macos-source: Sources/AgentCoding/Profile.swift @ 5feff2fd78b5
using System.Text.Json.Serialization;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Direct port of <c>ProfileColor</c> from <c>Profile.swift</c>.
/// Preset accent colors for visual identification in the profile picker.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ProfileColor
{
    Blue, Red, Green, Orange, Purple, Pink, Teal, Gray,
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum AgentTool
{
    /// Claude Code
    Claude,
    /// OpenAI Codex
    Codex,
}

public static class AgentToolExtensions
{
    public static string DisplayName(this AgentTool tool) => tool switch
    {
        AgentTool.Claude => "Claude Code",
        AgentTool.Codex => "Codex",
        _ => "?",
    };

    public static string ApiKeyEnvVar(this AgentTool tool) => tool switch
    {
        AgentTool.Claude => "ANTHROPIC_API_KEY",
        AgentTool.Codex => "OPENAI_API_KEY",
        _ => "",
    };
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum AuthMode
{
    /// User-supplied API key, injected as env var.
    Token,
    /// User runs `claude login` / `codex login` in the VM.
    Subscription,
    /// AWS Bedrock via SSO or static IAM keys.
    Bedrock,
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum AwsAuthMode
{
    Sso,
    StaticKeys,
}

/// <summary>
/// Network attachment mode for a profile's VM. Mirrors the macOS port
/// (<c>Profile.swift:925-939</c>): NAT (default — engine picks the
/// internal switch) or Bridged (forward a specific host interface).
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum NetworkMode
{
    Nat,
    Bridged,
}

/// <summary>
/// What happens when the user clicks the session window's close
/// button. macOS exposes the same three values (Profile.swift:907-923).
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum CloseAction
{
    /// Suspend the VM and stash its state to disk so the next launch
    /// resumes in-place.
    Suspend,
    /// Shut the VM down cleanly.
    Shutdown,
    /// Show a chooser the first time per session.
    Ask,
}

/// <summary>
/// Terminal cursor shape inside the guest. Threaded into kitty.conf.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum CursorShape
{
    Block,
    Beam,
    Underline,
}

/// <summary>
/// Three-state consent for the Claude / Codex subscription-token
/// fake↔real swap (Profile.swift:805/812). <c>Unset</c> means
/// "prompt next time"; the other two are explicit user choices that
/// stick across sessions.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum SubscriptionTokenSwapState
{
    Unset,
    Accepted,
    Declined,
}
