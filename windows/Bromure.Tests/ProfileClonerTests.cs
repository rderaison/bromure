using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit 08 §2.4 Duplicate command. The cloner is a small pure
/// helper — tests pin the contract: new Id, " (copy)" suffix,
/// fresh lifecycle fields, no shared collection refs.
/// </summary>
public class ProfileClonerTests
{
    [Fact]
    public void Clone_GeneratesNewId()
    {
        var src = new Profile { Name = "p1" };
        var clone = ProfileCloner.Clone(src);
        clone.Id.Should().NotBe(src.Id);
        clone.Id.Should().NotBe(Guid.Empty);
    }

    [Fact]
    public void Clone_AppendsCopySuffix()
    {
        var src = new Profile { Name = "Production" };
        var clone = ProfileCloner.Clone(src);
        clone.Name.Should().Be("Production (copy)");
    }

    [Fact]
    public void Clone_ResetsLifecycleFields()
    {
        var src = new Profile
        {
            Name = "p1",
            CreatedAt = DateTimeOffset.UtcNow.AddDays(-30),
            LastUsedAt = DateTimeOffset.UtcNow.AddHours(-1),
            BaseImageVersionAtClone = "100:abcd",
            SshPublicKey = "ssh-ed25519 AAAA test",
        };
        var clone = ProfileCloner.Clone(src);

        clone.CreatedAt.Should().BeAfter(src.CreatedAt);
        clone.LastUsedAt.Should().BeNull();
        clone.BaseImageVersionAtClone.Should().BeNull();
        clone.SshPublicKey.Should().BeNull();
    }

    [Fact]
    public void Clone_PreservesSettingsFields()
    {
        var src = new Profile
        {
            Name = "p1",
            Tool = AgentTool.Codex,
            AuthMode = AuthMode.Subscription,
            Color = ProfileColor.Purple,
            MemoryGB = 16,
            ApiKey = "sk-xxx",
            WindowOpacity = 0.85,
            CustomFontFamily = "Fira Code",
        };
        var clone = ProfileCloner.Clone(src);

        clone.Tool.Should().Be(AgentTool.Codex);
        clone.AuthMode.Should().Be(AuthMode.Subscription);
        clone.Color.Should().Be(ProfileColor.Purple);
        clone.MemoryGB.Should().Be(16);
        clone.ApiKey.Should().Be("sk-xxx");
        clone.WindowOpacity.Should().Be(0.85);
        clone.CustomFontFamily.Should().Be("Fira Code");
    }

    [Fact]
    public void Clone_DoesNotShareObservableCollections()
    {
        var src = new Profile { Name = "p1" };
        src.FolderPaths.Add(@"C:\original\path");

        var clone = ProfileCloner.Clone(src);
        clone.FolderPaths.Should().Equal(@"C:\original\path");

        // Mutating either side must not affect the other.
        src.FolderPaths.Add(@"C:\added\to\source");
        clone.FolderPaths.Should().HaveCount(1, "the clone owns its own FolderPaths instance");

        clone.FolderPaths.Add(@"C:\added\to\clone");
        src.FolderPaths.Should().NotContain(@"C:\added\to\clone");
    }

    [Fact]
    public void Clone_DoesNotShareMcpServers()
    {
        var src = new Profile { Name = "p1" };
        src.McpServers.Add(new McpServer { Name = "stripe", Url = "https://mcp.stripe.com" });

        var clone = ProfileCloner.Clone(src);
        clone.McpServers.Should().HaveCount(1);

        src.McpServers.RemoveAt(0);
        clone.McpServers.Should().HaveCount(1,
            "the duplicate keeps its own MCP servers even after the original drops one");
    }
}
