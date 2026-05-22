using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class McpFakeMintTests
{
    private static readonly byte[] TestSalt = new byte[]
    {
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
    };

    [Fact]
    public void Build_skips_stdio_servers()
    {
        var stdio = new McpServer { Name = "mem", Transport = McpTransport.Stdio, Command = "npx" };
        var plan = McpFakeMint.Build(new[] { stdio }, TestSalt);
        plan.Entries.Should().BeEmpty();
        plan.Fakes.Should().BeEmpty();
    }

    [Fact]
    public void Build_skips_disabled_servers()
    {
        var server = new McpServer
        {
            Name = "api",
            Transport = McpTransport.Http,
            Url = "https://api.example.com/mcp",
            BearerToken = "real",
            Enabled = false,
        };
        var plan = McpFakeMint.Build(new[] { server }, TestSalt);
        plan.Entries.Should().BeEmpty();
    }

    [Fact]
    public void Build_mints_fake_for_http_server_with_bearer()
    {
        var server = new McpServer
        {
            Name = "api",
            Transport = McpTransport.Http,
            Url = "https://api.example.com/mcp",
            BearerTokenEnvVar = "API_TOKEN",
            BearerToken = "real-token-12345",
        };
        var plan = McpFakeMint.Build(new[] { server }, TestSalt);
        plan.Entries.Should().HaveCount(1);
        plan.Entries[0].Fake.Should().StartWith(McpFakeMint.FakePrefix);
        plan.Entries[0].Real.Should().Be("real-token-12345");
        plan.Entries[0].Host.Should().Be("api.example.com");
        plan.Entries[0].Header.Should().Be(EntryHeader.Authorization);
        plan.Fakes.Should().HaveCount(1);
        plan.Fakes[0].ServerName.Should().Be("api");
        plan.Fakes[0].EnvVarName.Should().Be("API_TOKEN");
    }

    [Fact]
    public void Build_prefers_oauth_access_token_over_static_bearer()
    {
        var server = new McpServer
        {
            Name = "fellow",
            Transport = McpTransport.Http,
            Url = "https://fellow.app/mcp",
            BearerToken = "stale-static",
            OAuthState = new McpOAuthState
            {
                ClientId = "c",
                AuthorizationEndpoint = "https://a",
                TokenEndpoint = "https://t",
                AccessToken = "live-oauth-token",
            },
        };
        var plan = McpFakeMint.Build(new[] { server }, TestSalt);
        plan.Entries.Should().HaveCount(1);
        plan.Entries[0].Real.Should().Be("live-oauth-token");
    }

    [Fact]
    public void Build_skips_servers_with_empty_bearer()
    {
        var server = new McpServer
        {
            Name = "no-token-yet",
            Transport = McpTransport.Http,
            Url = "https://example.com/mcp",
        };
        var plan = McpFakeMint.Build(new[] { server }, TestSalt);
        plan.Entries.Should().BeEmpty();
    }

    [Fact]
    public void Fakes_are_deterministic_for_same_salt_and_real()
    {
        var server = new McpServer
        {
            Name = "api",
            Transport = McpTransport.Http,
            Url = "https://api.example.com",
            BearerToken = "real-token",
        };
        var first = McpFakeMint.Build(new[] { server }, TestSalt);
        var second = McpFakeMint.Build(new[] { server }, TestSalt);
        first.Entries[0].Fake.Should().Be(second.Entries[0].Fake);
    }

    [Fact]
    public void ToConfigFakes_projects_to_serverName_envVar_fake_dict()
    {
        var server = new McpServer
        {
            Name = "Fellow",
            Transport = McpTransport.Http,
            Url = "https://fellow.app/mcp",
            BearerTokenEnvVar = "FELLOW_TOKEN",
            BearerToken = "real",
        };
        var plan = McpFakeMint.Build(new[] { server }, TestSalt);
        var dict = McpFakeMint.ToConfigFakes(plan);
        dict.Should().ContainKey("Fellow");
        dict["Fellow"].EnvVar.Should().Be("FELLOW_TOKEN");
        dict["Fellow"].Fake.Should().StartWith(McpFakeMint.FakePrefix);
    }
}
