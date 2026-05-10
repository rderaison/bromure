using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class ProfileEnvExportsTests
{
    [Fact]
    public void Claude_profile_with_api_key_emits_ANTHROPIC_API_KEY()
    {
        var p = new Profile
        {
            Id = Guid.Parse("11111111-1111-1111-1111-111111111111"),
            Name = "Claude profile",
            Tool = AgentTool.Claude,
            ApiKey = "sk-ant-test",
        };
        var env = ProfileEnvExports.ForProfile(p);
        env["ANTHROPIC_API_KEY"].Should().Be("sk-ant-test");
        env.Should().NotContainKey("OPENAI_API_KEY");
        env["BROMURE_PROFILE_NAME"].Should().Be("Claude profile");
    }

    [Fact]
    public void Codex_profile_with_api_key_emits_OPENAI_API_KEY()
    {
        var p = new Profile
        {
            Tool = AgentTool.Codex,
            ApiKey = "sk-test",
        };
        var env = ProfileEnvExports.ForProfile(p);
        env["OPENAI_API_KEY"].Should().Be("sk-test");
        env.Should().NotContainKey("ANTHROPIC_API_KEY");
    }

    [Fact]
    public void Manual_tokens_with_envvarname_export()
    {
        var p = new Profile
        {
            Tool = AgentTool.Claude,
            ManualTokens =
            {
                CredentialFactory.Manual(Guid.NewGuid(), "DO PAT", "do-secret",
                    envVar: "DIGITALOCEAN_TOKEN"),
                CredentialFactory.Manual(Guid.NewGuid(), "Stripe", "sk-stripe",
                    envVar: "STRIPE_API_KEY"),
            },
        };
        var env = ProfileEnvExports.ForProfile(p);
        env["DIGITALOCEAN_TOKEN"].Should().Be("do-secret");
        env["STRIPE_API_KEY"].Should().Be("sk-stripe");
    }

    [Fact]
    public void Manual_tokens_marked_require_approval_are_skipped()
    {
        var p = new Profile
        {
            Tool = AgentTool.Claude,
            ManualTokens =
            {
                CredentialFactory.Manual(Guid.NewGuid(), "Sensitive", "very-secret",
                    envVar: "SENSITIVE_TOKEN", require: true),
            },
        };
        var env = ProfileEnvExports.ForProfile(p);
        env.Should().NotContainKey("SENSITIVE_TOKEN");
    }

    [Fact]
    public void EnvironmentVariables_pass_through()
    {
        var p = new Profile
        {
            Tool = AgentTool.Claude,
            EnvironmentVariables =
            {
                CredentialFactory.Env(Guid.NewGuid(), "MY_VAR", "value with spaces"),
                CredentialFactory.Env(Guid.NewGuid(), "ANOTHER", "x"),
            },
        };
        var env = ProfileEnvExports.ForProfile(p);
        env["MY_VAR"].Should().Be("value with spaces");
        env["ANOTHER"].Should().Be("x");
    }

    [Fact]
    public void Additional_tools_override_primary_when_their_key_present()
    {
        var p = new Profile
        {
            Tool = AgentTool.Claude,
            ApiKey = "claude-primary",
            AdditionalTools = new()
            {
                new() { Tool = AgentTool.Codex, ApiKey = "codex-secondary" },
            },
        };
        var env = ProfileEnvExports.ForProfile(p);
        env["ANTHROPIC_API_KEY"].Should().Be("claude-primary");
        env["OPENAI_API_KEY"].Should().Be("codex-secondary");
    }

    [Fact]
    public void DigitalOceanToken_top_level_field_exports()
    {
        var p = new Profile
        {
            Tool = AgentTool.Claude,
            DigitalOceanToken = "do-pat-from-top-level",
        };
        var env = ProfileEnvExports.ForProfile(p);
        env["DIGITALOCEAN_TOKEN"].Should().Be("do-pat-from-top-level");
    }

    [Fact]
    public void DigitalOceanToken_skips_when_require_approval()
    {
        var p = new Profile
        {
            Tool = AgentTool.Claude,
            DigitalOceanToken = "do-pat",
            DigitalOceanRequiresApproval = true,
        };
        var env = ProfileEnvExports.ForProfile(p);
        env.Should().NotContainKey("DIGITALOCEAN_TOKEN");
    }
}
