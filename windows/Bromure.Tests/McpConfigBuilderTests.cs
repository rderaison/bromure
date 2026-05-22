// macos-source: Tests/AgentCodingTests/MCPTests.swift @ 5feff2fd78b5
using System.Collections.ObjectModel;
using System.Text.Json;
using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class McpConfigBuilderTests
{
    private static McpServer NewServer(string name, McpTransport transport, string url = "",
        string command = "", string[]? args = null, string bearerEnvVar = "", string bearerToken = "",
        McpOAuthState? oauth = null, string rawJson = "", bool enabled = true)
    {
        var s = new McpServer
        {
            Name = name,
            Transport = transport,
            Url = url,
            Command = command,
            BearerTokenEnvVar = bearerEnvVar,
            BearerToken = bearerToken,
            OAuthState = oauth,
            RawJson = rawJson,
            Enabled = enabled,
        };
        if (args is not null) s.Arguments = new ObservableCollection<string>(args);
        return s;
    }

    [Fact]
    public void OAuth_server_emits_no_auth_fields_in_claude_code_config()
    {
        var server = NewServer("fellow", McpTransport.Http, url: "https://fellow.app/mcp",
            bearerEnvVar: "MCP_OAUTH_FELLOW", bearerToken: "real-token",
            oauth: new McpOAuthState
            {
                ClientId = "c",
                AuthorizationEndpoint = "https://a",
                TokenEndpoint = "https://t",
                AccessToken = "real-token",
            });
        var fakes = new Dictionary<string, (string, string)>
        {
            ["fellow"] = ("MCP_OAUTH_FELLOW", "brm-mcp_fake123"),
        };
        var json = McpConfigBuilder.ClaudeCodeJson(new[] { server }, fakes);
        json.Should().NotContain("bearerTokenEnvVar");
        json.Should().NotContain("brm-mcp_fake123");
        json.Should().Contain("fellow.app");
    }

    [Fact]
    public void Static_bearer_token_emits_bearerTokenEnvVar_and_fake_in_env()
    {
        var server = NewServer("my-api", McpTransport.Http, url: "https://api.example.com/mcp",
            bearerEnvVar: "MY_API_TOKEN", bearerToken: "real-static-token");
        var fakes = new Dictionary<string, (string, string)>
        {
            ["my-api"] = ("MY_API_TOKEN", "brm-mcp_staticfake"),
        };
        var json = McpConfigBuilder.ClaudeCodeJson(new[] { server }, fakes);
        json.Should().Contain("bearerTokenEnvVar");
        json.Should().Contain("MY_API_TOKEN");
        json.Should().Contain("brm-mcp_staticfake");
        json.Should().NotContain("real-static-token");
    }

    [Fact]
    public void Claude_code_json_generates_valid_multi_server_config()
    {
        var http = NewServer("My API", McpTransport.Http, url: "https://api.example.com/mcp",
            bearerEnvVar: "MY_API_TOKEN");
        http.Environment.Add(new EnvironmentVariable { Name = "REGION", Value = "us-east-1" });
        var stdio = NewServer("memory", McpTransport.Stdio, command: "npx",
            args: new[] { "-y", "@modelcontextprotocol/server-memory" });
        var fakes = new Dictionary<string, (string, string)>
        {
            ["My API"] = ("MY_API_TOKEN", "brm-mcp_fake123"),
        };
        var json = McpConfigBuilder.ClaudeCodeJson(new[] { http, stdio }, fakes);
        using var doc = JsonDocument.Parse(json);
        var servers = doc.RootElement.GetProperty("mcpServers");

        var api = servers.GetProperty("My API");
        api.GetProperty("type").GetString().Should().Be("http");
        api.GetProperty("url").GetString().Should().Be("https://api.example.com/mcp");
        api.GetProperty("bearerTokenEnvVar").GetString().Should().Be("MY_API_TOKEN");
        api.GetProperty("env").GetProperty("MY_API_TOKEN").GetString().Should().Be("brm-mcp_fake123");
        api.GetProperty("env").GetProperty("REGION").GetString().Should().Be("us-east-1");

        var mem = servers.GetProperty("memory");
        mem.GetProperty("command").GetString().Should().Be("npx");
        mem.GetProperty("args").EnumerateArray().Select(e => e.GetString()).Should()
            .ContainInOrder("-y", "@modelcontextprotocol/server-memory");
        mem.TryGetProperty("type", out _).Should().BeFalse();
        mem.TryGetProperty("url", out _).Should().BeFalse();
    }

    [Fact]
    public void Disabled_server_excluded_from_config()
    {
        var server = NewServer("disabled-one", McpTransport.Http, url: "https://example.com/mcp",
            enabled: false);
        var json = McpConfigBuilder.ClaudeCodeJson(new[] { server }.Where(s => s.Enabled));
        json.Should().NotContain("disabled-one");
    }

    [Fact]
    public void Stdio_server_emits_command_and_args()
    {
        var server = NewServer("local-tool", McpTransport.Stdio, command: "npx",
            args: new[] { "-y", "@example/mcp-server" });
        var json = McpConfigBuilder.ClaudeCodeJson(new[] { server });
        json.Should().Contain("npx");
        json.Should().Contain("@example/mcp-server");
        json.Should().NotContain("\"type\"");
    }

    [Fact]
    public void Raw_json_passes_through_when_no_fake_token()
    {
        var server = NewServer("custom", McpTransport.Http, url: "https://example.com",
            rawJson: "{\"type\":\"http\",\"url\":\"https://example.com\",\"custom_field\":true}");
        var json = McpConfigBuilder.ClaudeCodeJson(new[] { server });
        json.Should().Contain("custom_field");
    }

    [Fact]
    public void Raw_json_bypassed_when_fake_token_available()
    {
        var server = NewServer("custom", McpTransport.Http, url: "https://example.com",
            bearerEnvVar: "TOKEN",
            rawJson: "{\"type\":\"http\",\"url\":\"https://example.com\"}");
        var fakes = new Dictionary<string, (string, string)> { ["custom"] = ("TOKEN", "brm-mcp_fake") };
        var json = McpConfigBuilder.ClaudeCodeJson(new[] { server }, fakes);
        json.Should().Contain("bearerTokenEnvVar");
        json.Should().Contain("brm-mcp_fake");
    }

    [Fact]
    public void Codex_toml_emits_correct_format_for_http_server()
    {
        var server = NewServer("my-server", McpTransport.Http, url: "https://api.example.com/mcp",
            bearerEnvVar: "MY_TOKEN", bearerToken: "real");
        var fakes = new Dictionary<string, (string, string)>
        {
            ["my-server"] = ("MY_TOKEN", "brm-mcp_fake"),
        };
        var toml = McpConfigBuilder.CodexToml(new[] { server }, fakes);
        toml.Should().Contain("[mcp_servers.my-server]");
        toml.Should().Contain("url = ");
        toml.Should().Contain("bearer_token_env_var");
    }

    [Fact]
    public void Codex_toml_omits_bearer_for_oauth_brokered_servers()
    {
        var server = NewServer("fellow", McpTransport.Http, url: "https://fellow.app/mcp",
            bearerEnvVar: "MCP_OAUTH_FELLOW");
        server.OAuthState = new McpOAuthState
        {
            ClientId = "test-client",
            AuthorizationEndpoint = "https://fellow.app/oauth/authorize",
            TokenEndpoint = "https://fellow.app/oauth/token",
            AccessToken = "at_live",
        };
        var toml = McpConfigBuilder.CodexToml(new[] { server });
        toml.Should().Contain("url = ");
        toml.Should().NotContain("bearer_token_env_var");
    }

    [Fact]
    public void Codex_toml_generates_valid_multi_server_config()
    {
        var http = NewServer("My API", McpTransport.Http, url: "https://api.example.com/mcp",
            bearerEnvVar: "MY_API_TOKEN");
        http.Environment.Add(new EnvironmentVariable { Name = "REGION", Value = "us-east-1" });
        var stdio = NewServer("memory", McpTransport.Stdio, command: "npx",
            args: new[] { "-y", "@modelcontextprotocol/server-memory" });
        var fakes = new Dictionary<string, (string, string)>
        {
            ["My API"] = ("MY_API_TOKEN", "brm-mcp_fake123"),
        };
        var toml = McpConfigBuilder.CodexToml(new[] { http, stdio }, fakes);
        toml.Should().Contain("[mcp_servers.my-api]");
        toml.Should().Contain("url = \"https://api.example.com/mcp\"");
        toml.Should().Contain("bearer_token_env_var = \"MY_API_TOKEN\"");
        toml.Should().Contain("REGION = \"us-east-1\"");
        toml.Should().Contain("MY_API_TOKEN = \"brm-mcp_fake123\"");
        toml.Should().Contain("[mcp_servers.memory]");
        toml.Should().Contain("command = \"npx\"");
        toml.Should().Contain("args = [\"-y\", \"@modelcontextprotocol/server-memory\"]");
        toml.Should().StartWith("# Generated by Bromure AC");
        toml.Should().EndWith("\n");
    }

    [Fact]
    public void Codex_toml_skips_raw_json_servers()
    {
        var server = NewServer("raw-only", McpTransport.Http, url: "https://example.com",
            rawJson: "{\"type\":\"http\"}");
        var toml = McpConfigBuilder.CodexToml(new[] { server });
        toml.Should().NotContain("raw-only");
    }
}

public class McpProxyHooksTests
{
    [Fact]
    public void IsOauthDiscoveryPath_recognises_well_known_paths()
    {
        Bromure.AC.Mitm.Swap.McpProxyHooks.IsOauthDiscoveryPath("/.well-known/oauth-authorization-server").Should().BeTrue();
        Bromure.AC.Mitm.Swap.McpProxyHooks.IsOauthDiscoveryPath("/.well-known/oauth-authorization-server/mcp").Should().BeTrue();
        Bromure.AC.Mitm.Swap.McpProxyHooks.IsOauthDiscoveryPath("/.well-known/oauth-protected-resource").Should().BeTrue();
        Bromure.AC.Mitm.Swap.McpProxyHooks.IsOauthDiscoveryPath("/.well-known/openid-configuration").Should().BeTrue();
        Bromure.AC.Mitm.Swap.McpProxyHooks.IsOauthDiscoveryPath("/.well-known/openid-configuration/mcp").Should().BeTrue();
    }

    [Fact]
    public void IsOauthDiscoveryPath_passes_other_well_known()
    {
        Bromure.AC.Mitm.Swap.McpProxyHooks.IsOauthDiscoveryPath("/.well-known/acme-challenge").Should().BeFalse();
        Bromure.AC.Mitm.Swap.McpProxyHooks.IsOauthDiscoveryPath("/.well-known/security.txt").Should().BeFalse();
    }

    [Fact]
    public void IsOauthDiscoveryPath_passes_regular_paths()
    {
        Bromure.AC.Mitm.Swap.McpProxyHooks.IsOauthDiscoveryPath("/mcp").Should().BeFalse();
        Bromure.AC.Mitm.Swap.McpProxyHooks.IsOauthDiscoveryPath("/oauth/authorize").Should().BeFalse();
    }

    [Fact]
    public void InjectMcpBearer_adds_header_when_missing()
    {
        const string raw = "GET /mcp HTTP/1.1\r\nHost: fellow.app\r\nUser-Agent: claude\r\n\r\n";
        var bytes = System.Text.Encoding.ASCII.GetBytes(raw);
        var injected = Bromure.AC.Mitm.Swap.McpProxyHooks.InjectMcpBearer(bytes, "real-token-xyz");
        var text = System.Text.Encoding.ASCII.GetString(injected);
        text.Should().Contain("Authorization: Bearer real-token-xyz\r\n");
        text.Should().Contain("Host: fellow.app");
        text.Should().Contain("User-Agent: claude");
    }

    [Fact]
    public void InjectMcpBearer_leaves_request_unchanged_when_authorization_present()
    {
        const string raw = "GET /mcp HTTP/1.1\r\nHost: fellow.app\r\nAuthorization: Bearer existing\r\n\r\n";
        var bytes = System.Text.Encoding.ASCII.GetBytes(raw);
        var result = Bromure.AC.Mitm.Swap.McpProxyHooks.InjectMcpBearer(bytes, "should-not-appear");
        var text = System.Text.Encoding.ASCII.GetString(result);
        text.Should().NotContain("should-not-appear");
        text.Should().Contain("Authorization: Bearer existing");
    }
}
