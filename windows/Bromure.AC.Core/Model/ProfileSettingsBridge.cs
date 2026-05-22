using System.Globalization;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Read / write a single named Profile field by string key. Used by
/// the automation HTTP server's
/// <c>/profiles/{id}/settings/{key}</c> endpoint and through it the
/// MCP <c>bromure_ac_get_profile_setting</c> /
/// <c>bromure_ac_set_profile_setting</c> tools. The macOS port
/// exposes nearly every Profile field via AppleScript handlers; the
/// audit (06) flagged Windows as having a much smaller subset.
/// This class brings Windows up to parity and makes the supported-
/// key set unit-testable from <see cref="Bromure.Tests"/>.
/// </summary>
public static class ProfileSettingsBridge
{
    /// <summary>Read one named Profile field. Returns null when the
    /// key is unknown.</summary>
    public static string? Read(Profile p, string key) => key switch
    {
        // Identity + presentation.
        "name" => p.Name,
        "color" => p.Color.ToString(),
        "comments" => p.Comments,
        // Tool / auth.
        "tool" => p.Tool.ToString(),
        "authMode" => p.AuthMode.ToString(),
        "apiKey" => p.ApiKey ?? "",
        "apiKeyRequiresApproval" => p.ApiKeyRequiresApproval.ToString().ToLowerInvariant(),
        // Cosmetic.
        "useTerminalAppDefaults" => p.UseTerminalAppDefaults.ToString().ToLowerInvariant(),
        "customFontFamily" => p.CustomFontFamily ?? "",
        "customFontSize" => p.CustomFontSize?.ToString() ?? "",
        "customBackgroundHex" => p.CustomBackgroundHex ?? "",
        "customForegroundHex" => p.CustomForegroundHex ?? "",
        "cursorShape" => p.CursorShape.ToString(),
        "windowOpacity" => p.WindowOpacity.ToString(CultureInfo.InvariantCulture),
        "keyboardLayoutOverride" => p.KeyboardLayoutOverride ?? "",
        // VM resources.
        "memoryGB" => p.MemoryGB.ToString(),
        "networkMode" => p.NetworkMode.ToString(),
        "bridgedInterfaceID" => p.BridgedInterfaceID ?? "",
        "closeAction" => p.CloseAction.ToString(),
        // Git identity.
        "gitUserName" => p.GitUserName,
        "gitUserEmail" => p.GitUserEmail,
        // SSH.
        "sshPublicKey" => p.SshPublicKey ?? "",
        "sshKeyRequiresApproval" => p.SshKeyRequiresApproval.ToString().ToLowerInvariant(),
        // Misc tokens.
        "digitalOceanToken" => p.DigitalOceanToken ?? "",
        "digitalOceanRequiresApproval" => p.DigitalOceanRequiresApproval.ToString().ToLowerInvariant(),
        // Bedrock.
        "bedrockEnabled" => p.BedrockEnabled.ToString().ToLowerInvariant(),
        "bedrockModelID" => p.BedrockModelID,
        // Lifecycle.
        "createdAt" => p.CreatedAt.ToString("O"),
        "lastUsedAt" => p.LastUsedAt?.ToString("O") ?? "",
        "baseImageVersionAtClone" => p.BaseImageVersionAtClone ?? "",
        // Subscription token consent state.
        "subscriptionTokenSwap" => p.SubscriptionTokenSwap.ToString(),
        "codexTokenSwap" => p.CodexTokenSwap.ToString(),
        // Counts (read-only, useful for assertions).
        "folderPathsCount" => p.FolderPaths.Count.ToString(),
        "mcpServerCount" => p.McpServers.Count.ToString(),
        "kubeconfigCount" => p.Kubeconfigs.Count.ToString(),
        "dockerRegistryCount" => p.DockerRegistries.Count.ToString(),
        "manualTokenCount" => p.ManualTokens.Count.ToString(),
        "importedSshKeyCount" => p.ImportedSshKeys.Count.ToString(),
        "environmentVariableCount" => p.EnvironmentVariables.Count.ToString(),
        // Privacy / tracing.
        "privateMode" => p.PrivateMode.ToString().ToLowerInvariant(),
        "traceLevel" => p.TraceLevel.ToString(),
        _ => null,
    };

    /// <summary>Write one named Profile field. Returns false when
    /// the key is unknown or the value can't be parsed for that
    /// field's type. Read-only keys (counts, lifecycle timestamps,
    /// SSH public key) are intentionally not writable.</summary>
    public static bool Write(Profile p, string key, string value)
    {
        var inv = CultureInfo.InvariantCulture;
        switch (key)
        {
            case "name": p.Name = value; return true;
            case "comments": p.Comments = value; return true;
            case "color":
                if (!Enum.TryParse<ProfileColor>(value, ignoreCase: true, out var c)) return false;
                p.Color = c; return true;
            case "tool":
                if (!Enum.TryParse<AgentTool>(value, ignoreCase: true, out var t)) return false;
                p.Tool = t; return true;
            case "authMode":
                if (!Enum.TryParse<AuthMode>(value, ignoreCase: true, out var a)) return false;
                p.AuthMode = a; return true;
            case "apiKey": p.ApiKey = value; return true;
            case "apiKeyRequiresApproval":
                if (!bool.TryParse(value, out var akra)) return false;
                p.ApiKeyRequiresApproval = akra; return true;
            // Cosmetic.
            case "useTerminalAppDefaults":
                if (!bool.TryParse(value, out var utd)) return false;
                p.UseTerminalAppDefaults = utd; return true;
            case "customFontFamily":
                p.CustomFontFamily = string.IsNullOrEmpty(value) ? null : value; return true;
            case "customFontSize":
                if (string.IsNullOrEmpty(value)) { p.CustomFontSize = null; return true; }
                if (!int.TryParse(value, NumberStyles.Integer, inv, out var cfs)) return false;
                p.CustomFontSize = cfs; return true;
            case "customBackgroundHex":
                p.CustomBackgroundHex = string.IsNullOrEmpty(value) ? null : value; return true;
            case "customForegroundHex":
                p.CustomForegroundHex = string.IsNullOrEmpty(value) ? null : value; return true;
            case "cursorShape":
                if (!Enum.TryParse<CursorShape>(value, ignoreCase: true, out var cs)) return false;
                p.CursorShape = cs; return true;
            case "windowOpacity":
                if (!double.TryParse(value, NumberStyles.Float, inv, out var wo)) return false;
                if (wo < 0.3 || wo > 1.0) return false;
                p.WindowOpacity = wo; return true;
            case "keyboardLayoutOverride":
                p.KeyboardLayoutOverride = string.IsNullOrEmpty(value) ? null : value; return true;
            // VM resources.
            case "memoryGB":
                if (!int.TryParse(value, NumberStyles.Integer, inv, out var mg)) return false;
                if (mg < 0 || mg > 1024) return false;
                p.MemoryGB = mg; return true;
            case "networkMode":
                if (!Enum.TryParse<NetworkMode>(value, ignoreCase: true, out var nm)) return false;
                p.NetworkMode = nm; return true;
            case "bridgedInterfaceID":
                p.BridgedInterfaceID = string.IsNullOrEmpty(value) ? null : value; return true;
            case "closeAction":
                if (!Enum.TryParse<CloseAction>(value, ignoreCase: true, out var ca)) return false;
                p.CloseAction = ca; return true;
            // Git identity.
            case "gitUserName": p.GitUserName = value; return true;
            case "gitUserEmail": p.GitUserEmail = value; return true;
            // SSH.
            case "sshKeyRequiresApproval":
                if (!bool.TryParse(value, out var skra)) return false;
                p.SshKeyRequiresApproval = skra; return true;
            // Misc tokens.
            case "digitalOceanToken":
                p.DigitalOceanToken = string.IsNullOrEmpty(value) ? null : value; return true;
            case "digitalOceanRequiresApproval":
                if (!bool.TryParse(value, out var dora)) return false;
                p.DigitalOceanRequiresApproval = dora; return true;
            // Bedrock.
            case "bedrockEnabled":
                if (!bool.TryParse(value, out var be)) return false;
                p.BedrockEnabled = be; return true;
            case "bedrockModelID": p.BedrockModelID = value; return true;
            // Subscription consent state.
            case "subscriptionTokenSwap":
                if (!Enum.TryParse<SubscriptionTokenSwapState>(value, ignoreCase: true, out var ss)) return false;
                p.SubscriptionTokenSwap = ss; return true;
            case "codexTokenSwap":
                if (!Enum.TryParse<SubscriptionTokenSwapState>(value, ignoreCase: true, out var cxs)) return false;
                p.CodexTokenSwap = cxs; return true;
            // Privacy / tracing.
            case "privateMode":
                if (!bool.TryParse(value, out var pm)) return false;
                p.PrivateMode = pm; return true;
            case "traceLevel":
                if (!Enum.TryParse<TraceLevel>(value, ignoreCase: true, out var tl)) return false;
                p.TraceLevel = tl; return true;
            default: return false;
        }
    }
}
