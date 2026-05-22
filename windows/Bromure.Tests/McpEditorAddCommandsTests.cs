using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for the MCP-server template additions that the editor's
/// "Add stdio server" / "Add HTTP server" buttons produce. Verifies
/// the new entries pass the IsUsable predicate so the proxy's fake-
/// mint + config-builder pipeline picks them up.
/// </summary>
public class McpEditorAddCommandsTests
{
    [Fact]
    public void StdioTemplate_IsUsable_AfterDefaultAdd()
    {
        // Same shape ProfilesViewModel.AddMcpStdio mints.
        var s = new McpServer
        {
            Name = "new-stdio-server",
            Transport = McpTransport.Stdio,
            Command = "node",
            Enabled = true,
        };
        s.Arguments.Add("server.js");
        s.IsUsable.Should().BeTrue();
        s.Transport.Should().Be(McpTransport.Stdio);
    }

    [Fact]
    public void HttpTemplate_IsUsable_AfterDefaultAdd()
    {
        var s = new McpServer
        {
            Name = "new-http-server",
            Transport = McpTransport.Http,
            Url = "https://example.com/mcp",
            BearerTokenEnvVar = "MCP_BEARER",
            Enabled = true,
        };
        s.IsUsable.Should().BeTrue();
        s.UrlHost.Should().Be("example.com");
    }

    [Fact]
    public void EmptyName_FailsIsUsable()
    {
        var s = new McpServer
        {
            Name = "",
            Transport = McpTransport.Stdio,
            Command = "node",
        };
        s.IsUsable.Should().BeFalse();
    }

    [Fact]
    public void StdioMissingCommand_FailsIsUsable()
    {
        var s = new McpServer
        {
            Name = "x",
            Transport = McpTransport.Stdio,
            Command = "",
        };
        s.IsUsable.Should().BeFalse();
    }

    [Fact]
    public void HttpMissingUrl_FailsIsUsable()
    {
        var s = new McpServer
        {
            Name = "x",
            Transport = McpTransport.Http,
            Url = "",
        };
        s.IsUsable.Should().BeFalse();
    }
}
