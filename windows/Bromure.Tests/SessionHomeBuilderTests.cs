using System.Text;
using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class SessionHomeBuilderTests
{
    [Fact]
    public void Always_includes_kitty_conf()
    {
        var files = SessionHomeBuilder.Build(profile: null);
        files.Should().ContainKey(".config/kitty/kitty.conf");
        Encoding.UTF8.GetString(files[".config/kitty/kitty.conf"])
            .Should().Contain("font_size");
    }

    [Fact]
    public void Always_includes_bashrc_that_sources_api_key_env()
    {
        var files = SessionHomeBuilder.Build(profile: null);
        files.Should().ContainKey(".bashrc");
        var bashrc = Encoding.UTF8.GetString(files[".bashrc"]);
        bashrc.Should().Contain("/mnt/bromure-meta/api_key.env");
    }

    [Fact]
    public void Bash_profile_triggers_startx_on_tty1()
    {
        var files = SessionHomeBuilder.Build(profile: null);
        files.Should().ContainKey(".bash_profile");
        var profile = Encoding.UTF8.GetString(files[".bash_profile"]);
        profile.Should().Contain("/dev/tty1");
        profile.Should().Contain("startx");
    }

    [Fact]
    public void Output_uses_lf_line_endings()
    {
        var files = SessionHomeBuilder.Build(profile: null);
        foreach (var (_, bytes) in files)
        {
            var text = Encoding.UTF8.GetString(bytes);
            text.Should().NotContain("\r\n");
        }
    }

    [Fact]
    public void NpmGlobal_directory_marker_always_emitted()
    {
        SessionHomeBuilder.Build(profile: null).Should().ContainKey(".npm-global/.gitkeep");
    }

    [Fact]
    public void GitConfig_emitted_when_user_identity_present()
    {
        var p = new Profile
        {
            GitUserName = "Renaud Deraison",
            GitUserEmail = "renaud@example.com",
        };
        var files = SessionHomeBuilder.Build(p);
        files.Should().ContainKey(".gitconfig");
        var gc = Encoding.UTF8.GetString(files[".gitconfig"]);
        gc.Should().Contain("[user]")
                  .And.Contain("Renaud Deraison")
                  .And.Contain("renaud@example.com");
        gc.Should().NotContain("[credential]", "no usable HTTPS creds → no helper line");
    }

    [Fact]
    public void GitCredentials_emitted_with_userinfo_percent_encoded()
    {
        var p = new Profile();
        p.GitHttpsCredentials.Add(new GitHttpsCredential
        {
            Host = "github.com",
            Username = "name@org.com",
            Token = "ghp_abc:xyz",
        });
        var files = SessionHomeBuilder.Build(p);
        files.Should().ContainKey(".git-credentials");
        var line = Encoding.UTF8.GetString(files[".git-credentials"]).TrimEnd('\n');
        line.Should().Be("https://name%40org.com:ghp_abc%3Axyz@github.com");
    }

    [Fact]
    public void GhConfig_emitted_for_github_creds_only()
    {
        var p = new Profile();
        p.GitHttpsCredentials.Add(new GitHttpsCredential
        { Host = "github.com", Username = "u", Token = "t" });
        p.GitHttpsCredentials.Add(new GitHttpsCredential
        { Host = "gitlab.com", Username = "u2", Token = "t2" });
        var files = SessionHomeBuilder.Build(p);
        files.Should().ContainKey(".config/gh/hosts.yml");
        var gh = Encoding.UTF8.GetString(files[".config/gh/hosts.yml"]);
        gh.Should().Contain("github.com").And.Contain("oauth_token: t");
        gh.Should().NotContain("gitlab");
    }

    [Fact]
    public void GlabConfig_emitted_for_gitlab_creds_only()
    {
        var p = new Profile();
        p.GitHttpsCredentials.Add(new GitHttpsCredential
        { Host = "github.com", Username = "u", Token = "t" });
        p.GitHttpsCredentials.Add(new GitHttpsCredential
        { Host = "gitlab.com", Username = "u2", Token = "t2" });
        var files = SessionHomeBuilder.Build(p);
        files.Should().ContainKey(".config/glab-cli/config.yml");
        var glab = Encoding.UTF8.GetString(files[".config/glab-cli/config.yml"]);
        glab.Should().Contain("gitlab.com").And.Contain("token: t2");
        glab.Should().NotContain("github");
    }

    [Fact]
    public void Doctl_config_emitted_when_DigitalOceanToken_set()
    {
        var p = new Profile { DigitalOceanToken = "dop_v1_123" };
        var files = SessionHomeBuilder.Build(p);
        files.Should().ContainKey(".config/doctl/config.yaml");
        Encoding.UTF8.GetString(files[".config/doctl/config.yaml"])
            .Should().Contain("access-token: dop_v1_123");
    }

    [Fact]
    public void Docker_config_uses_canonical_dockerHub_key()
    {
        var p = new Profile();
        p.DockerRegistries.Add(new DockerRegistryCredential
        { Host = "docker.io", Username = "renaud", Password = "pwd" });
        p.DockerRegistries.Add(new DockerRegistryCredential
        { Host = "ghcr.io", Username = "renaud", Password = "pwd2" });
        var files = SessionHomeBuilder.Build(p);
        files.Should().ContainKey(".docker/config.json");
        var json = Encoding.UTF8.GetString(files[".docker/config.json"]);
        json.Should().Contain("https://index.docker.io/v1/", "Docker Hub canonical key");
        json.Should().Contain("ghcr.io");
        json.Should().Contain("_bromureManaged");
    }

    [Fact]
    public void Aws_config_emitted_for_static_keys()
    {
        var p = new Profile
        {
            Aws = new AwsCredentialsConfig
            {
                AuthMode = AwsAuthMode.StaticKeys,
                AccessKeyId = "AKIAEXAMPLE",
                SecretAccessKey = "secretkeyexample",
                Region = "us-west-2",
            },
        };
        var files = SessionHomeBuilder.Build(p);
        files.Should().ContainKey(".aws/config")
            .And.ContainKey(".aws/credentials");
        Encoding.UTF8.GetString(files[".aws/config"])
            .Should().Contain("region = us-west-2");
        // Credentials file must NOT carry the real material — that's
        // the audit-04 security regression we closed. The proxy
        // resigns on the wire with the real key the host holds.
        var creds = Encoding.UTF8.GetString(files[".aws/credentials"]);
        creds.Should().Contain("[default]");
        creds.Should().Contain("aws_access_key_id");
        creds.Should().Contain("aws_secret_access_key");
        creds.Should().NotContain("AKIAEXAMPLE");
        creds.Should().NotContain("secretkeyexample");
    }

    [Fact]
    public void Aws_config_emitted_for_sso_skips_credentials_file()
    {
        var p = new Profile
        {
            Aws = new AwsCredentialsConfig
            {
                AuthMode = AwsAuthMode.Sso,
                SsoProfile = "engineering",
                Region = "us-east-1",
            },
        };
        var files = SessionHomeBuilder.Build(p);
        files.Should().ContainKey(".aws/config")
            .And.NotContainKey(".aws/credentials");
        Encoding.UTF8.GetString(files[".aws/config"])
            .Should().Contain("sso_session = engineering");
    }

    [Fact]
    public void Aws_config_includes_credential_process_directive()
    {
        // Audit 04 §25: the in-guest credential helper is installed
        // at /usr/local/bin/bromure-aws-credentials. ~/.aws/config
        // must point the SDK at it via credential_process so the
        // SDK actually calls into the host on every signing pass.
        var p = new Profile
        {
            Aws = new AwsCredentialsConfig
            {
                AuthMode = AwsAuthMode.StaticKeys,
                AccessKeyId = "AKIATEST",
                SecretAccessKey = "secrettest",
                Region = "eu-west-1",
            },
        };
        var files = SessionHomeBuilder.Build(p);
        var config = Encoding.UTF8.GetString(files[".aws/config"]);
        config.Should().Contain("credential_process = /usr/local/bin/bromure-aws-credentials");
        // The directive should land UNDER [default], not above.
        var defaultIdx = config.IndexOf("[default]", StringComparison.Ordinal);
        var procIdx = config.IndexOf("credential_process", StringComparison.Ordinal);
        defaultIdx.Should().BeLessThan(procIdx, "credential_process belongs inside the [default] section");
    }

    [Fact]
    public void Empty_profile_emits_only_baseline_files()
    {
        var p = new Profile();
        var files = SessionHomeBuilder.Build(p).Keys.OrderBy(k => k).ToArray();
        // Baseline + per-session profile-id marker (consumed by the
        // in-VM bromure-aws-credentials helper).
        files.Should().Equal(
            ".bash_profile",
            ".bashrc",
            ".bromure-profile-id",
            ".config/kitty/kitty.conf",
            ".npm-global/.gitkeep");
    }

    [Fact]
    public void Bedrock_settings_emitted_when_enabled()
    {
        var p = new Profile
        {
            BedrockEnabled = true,
            BedrockModelID = "anthropic.claude-3-5-sonnet-20241022-v2:0",
            Aws = new AwsCredentialsConfig { Region = "us-west-2" },
        };
        var files = SessionHomeBuilder.Build(p);
        files.Should().ContainKey(".claude/settings.json");
        var json = Encoding.UTF8.GetString(files[".claude/settings.json"]);
        json.Should().Contain("\"CLAUDE_CODE_USE_BEDROCK\": \"1\"")
            .And.Contain("\"AWS_REGION\": \"us-west-2\"")
            .And.Contain("anthropic.claude-3-5-sonnet-20241022-v2:0");
    }

    [Fact]
    public void Bedrock_settings_skipped_when_disabled()
    {
        var p = new Profile { BedrockEnabled = false };
        var files = SessionHomeBuilder.Build(p);
        files.Should().NotContainKey(".claude/settings.json");
    }

    [Fact]
    public void Aws_credentials_file_never_carries_the_real_secret()
    {
        // Master audit gap #5 (CRITICAL): the previous build wrote the
        // real aws_secret_access_key + session token into the guest's
        // .aws/credentials file, defeating the entire fail-closed
        // threat model. The fix writes a fake — the proxy re-signs on
        // the wire with the real material that lives only on the host.
        const string realSecret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
        const string realSession = "AQoDYXdzEPT//////////wEXAMPLEt";
        var p = new Profile
        {
            Aws = new AwsCredentialsConfig
            {
                AuthMode = AwsAuthMode.StaticKeys,
                AccessKeyId = "AKIAIOSFODNN7EXAMPLE",
                SecretAccessKey = realSecret,
                SessionToken = realSession,
            },
        };
        var files = SessionHomeBuilder.Build(p);
        files.Should().ContainKey(".aws/credentials");
        var text = Encoding.UTF8.GetString(files[".aws/credentials"]);
        text.Should().NotContain(realSecret, "the real secret must never reach the guest");
        text.Should().NotContain(realSession, "the real session token must never reach the guest");
        // Sanity: the file still looks like a credentials file the SDK
        // will accept.
        text.Should().Contain("[default]");
        text.Should().Contain("aws_access_key_id");
        text.Should().Contain("aws_secret_access_key");
    }

    [Fact]
    public void Aws_credentials_file_carries_documentation_pointing_at_host_proxy()
    {
        // Anyone opening ~/.aws/credentials inside the VM needs to
        // understand why these AKID/secret values look bogus and why
        // signed requests work anyway. Future-them shouldn't have to
        // grep the host source.
        var p = new Profile
        {
            Aws = new AwsCredentialsConfig
            {
                AuthMode = AwsAuthMode.StaticKeys,
                AccessKeyId = "AKIAIOSFODNN7EXAMPLE",
                SecretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            },
        };
        var files = SessionHomeBuilder.Build(p);
        var text = Encoding.UTF8.GetString(files[".aws/credentials"]);
        text.Should().Contain("Bromure");
        text.Should().Contain("fake");
        text.Should().Contain("proxy");
    }

    [Fact]
    public void Aws_credentials_omitted_in_sso_mode()
    {
        var p = new Profile
        {
            Aws = new AwsCredentialsConfig
            {
                AuthMode = AwsAuthMode.Sso,
                SsoProfile = "ops-admin",
            },
        };
        var files = SessionHomeBuilder.Build(p);
        files.Should().NotContainKey(".aws/credentials",
            "SSO mode writes config only; credential_process is the credential delivery channel");
        files.Should().ContainKey(".aws/config");
    }
}
