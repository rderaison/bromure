using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Pin the supported-key set exposed by
/// <see cref="ProfileSettingsBridge"/> — the table the MCP
/// <c>bromure_ac_get_profile_setting</c> /
/// <c>bromure_ac_set_profile_setting</c> tools hand the user.
/// Audit 06 flagged Windows as having drifted to a much smaller
/// set than macOS; these tests keep the table from regressing.
/// </summary>
public class ProfileSettingsBridgeTests
{
    [Theory]
    // Identity
    [InlineData("name", "p1")]
    [InlineData("comments", "anything here")]
    [InlineData("color", "Purple")]
    // Tool / auth
    [InlineData("tool", "Codex")]
    [InlineData("authMode", "Subscription")]
    [InlineData("apiKey", "sk-xyz")]
    [InlineData("apiKeyRequiresApproval", "true")]
    // Cosmetic
    [InlineData("useTerminalAppDefaults", "false")]
    [InlineData("customFontFamily", "Fira Code")]
    [InlineData("customFontSize", "14")]
    [InlineData("customBackgroundHex", "#101010")]
    [InlineData("customForegroundHex", "#FFFFFF")]
    [InlineData("cursorShape", "Beam")]
    [InlineData("windowOpacity", "0.85")]
    [InlineData("keyboardLayoutOverride", "fr")]
    // VM resources
    [InlineData("memoryGB", "16")]
    [InlineData("networkMode", "Bridged")]
    [InlineData("bridgedInterfaceID", "eth0")]
    [InlineData("closeAction", "Suspend")]
    // Git
    [InlineData("gitUserName", "Alice")]
    [InlineData("gitUserEmail", "alice@x")]
    // SSH
    [InlineData("sshKeyRequiresApproval", "true")]
    // Misc tokens
    [InlineData("digitalOceanToken", "dop_v1_xxxx")]
    [InlineData("digitalOceanRequiresApproval", "true")]
    // Bedrock
    [InlineData("bedrockEnabled", "true")]
    [InlineData("bedrockModelID", "anthropic.claude-3-sonnet")]
    // Subscription state
    [InlineData("subscriptionTokenSwap", "Accepted")]
    [InlineData("codexTokenSwap", "Declined")]
    // Privacy / tracing
    [InlineData("privateMode", "true")]
    [InlineData("traceLevel", "All")]
    public void Write_Then_Read_RoundTrips(string key, string value)
    {
        var p = new Profile();
        ProfileSettingsBridge.Write(p, key, value).Should().BeTrue();
        var read = ProfileSettingsBridge.Read(p, key);
        read.Should().NotBeNull();
        // Enum / bool values may round-trip in lowercase / different
        // casing; equality check uses InvariantCultureIgnoreCase.
        read!.Equals(value, StringComparison.OrdinalIgnoreCase).Should().BeTrue(
            $"key={key} expected={value} actual={read}");
    }

    [Fact]
    public void Read_UnknownKey_ReturnsNull()
    {
        ProfileSettingsBridge.Read(new Profile(), "nonsensekey").Should().BeNull();
    }

    [Fact]
    public void Write_UnknownKey_ReturnsFalse()
    {
        ProfileSettingsBridge.Write(new Profile(), "nonsensekey", "v").Should().BeFalse();
    }

    [Theory]
    [InlineData("color", "Mauve")]               // not a ProfileColor
    [InlineData("tool", "Bard")]                 // not an AgentTool
    [InlineData("authMode", "Magic")]            // not an AuthMode
    [InlineData("apiKeyRequiresApproval", "x")]  // not a bool
    [InlineData("customFontSize", "x")]          // not an int
    [InlineData("windowOpacity", "5.0")]          // out of range
    [InlineData("windowOpacity", "0.1")]          // out of range
    [InlineData("memoryGB", "-1")]
    [InlineData("memoryGB", "9999")]
    [InlineData("memoryGB", "abc")]
    [InlineData("networkMode", "Floating")]
    [InlineData("closeAction", "Yeet")]
    [InlineData("cursorShape", "Spiral")]
    [InlineData("traceLevel", "ExtraSpicy")]
    [InlineData("subscriptionTokenSwap", "Maybe")]
    public void Write_GarbageValue_ReturnsFalse_LeavesProfileUnchanged(string key, string value)
    {
        var p = new Profile { Name = "before", MemoryGB = 8, WindowOpacity = 1.0 };
        ProfileSettingsBridge.Write(p, key, value).Should().BeFalse();
        p.Name.Should().Be("before");
        p.MemoryGB.Should().Be(8);
        p.WindowOpacity.Should().Be(1.0);
    }

    [Fact]
    public void ReadOnly_Keys_ExposeData_NotWritable()
    {
        var p = new Profile
        {
            CreatedAt = DateTimeOffset.UtcNow.AddDays(-1),
            LastUsedAt = DateTimeOffset.UtcNow.AddHours(-3),
            BaseImageVersionAtClone = "100:abcd",
            SshPublicKey = "ssh-ed25519 AAAAxxx test",
        };
        ProfileSettingsBridge.Read(p, "createdAt").Should().Contain("T");
        ProfileSettingsBridge.Read(p, "lastUsedAt").Should().Contain("T");
        ProfileSettingsBridge.Read(p, "baseImageVersionAtClone").Should().Be("100:abcd");
        ProfileSettingsBridge.Read(p, "sshPublicKey").Should().Contain("ssh-ed25519");

        // Writes for these keys must fail — they're either lifecycle
        // metadata or derived material.
        ProfileSettingsBridge.Write(p, "createdAt", "2099-01-01T00:00:00Z").Should().BeFalse();
        ProfileSettingsBridge.Write(p, "lastUsedAt", "2099-01-01T00:00:00Z").Should().BeFalse();
        ProfileSettingsBridge.Write(p, "sshPublicKey", "ssh-ed25519 attacker").Should().BeFalse();
        ProfileSettingsBridge.Write(p, "baseImageVersionAtClone", "999").Should().BeFalse();
    }

    [Fact]
    public void CountKeys_ReflectAddCollections()
    {
        var p = new Profile();
        ProfileSettingsBridge.Read(p, "mcpServerCount").Should().Be("0");
        p.McpServers.Add(new McpServer { Name = "x", Url = "https://x" });
        ProfileSettingsBridge.Read(p, "mcpServerCount").Should().Be("1");
    }
}
