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
