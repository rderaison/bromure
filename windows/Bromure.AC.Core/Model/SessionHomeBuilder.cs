// macos-source: Sources/AgentCoding/Profile.swift @ 5feff2fd78b5
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Materialises the per-session <c>/home/bromure</c> overlay from a
/// <see cref="Profile"/>: every dotfile / config / token the agent CLIs
/// need at runtime.
///
/// <para>Mirror of macOS <c>Profile.materialize(into:)</c>. On macOS the
/// host writes the files directly into a virtiofs-shared
/// <c>bromure-home</c> dir; on Windows we drop the same set via 9p
/// (<c>\\wsl$\&lt;distro&gt;\home\bromure\</c>). Either way:
/// <b>everything profile-derived is regenerated on each session
/// launch</b>, so a profile edit takes effect on the next boot without
/// re-baking the base image.</para>
///
/// <para>Returns paths relative to <c>/home/bromure</c>, slash-separated.
/// Caller decides how to deliver them (tar / direct 9p write / virtiofs).</para>
///
/// <para><b>Token plan deferred.</b> macOS substitutes fake tokens here
/// and lets MitmEngine swap them on the wire. The Windows port writes
/// REAL tokens for v1 and lets the proxy forward them unchanged.
/// Token-fake substitution is a defensive feature we'll layer on once
/// the swap-map plumbing is end-to-end exercised.</para>
/// </summary>
public static class SessionHomeBuilder
{
    /// <summary>
    /// Compose the full home tree for <paramref name="profile"/>.
    /// <paramref name="bromureCaPem"/> is the MITM CA's PEM — needed
    /// only to materialise <c>~/.kube/config</c> with the cluster trust
    /// store pointed at our forged leaves. Pass null to skip the
    /// kubeconfig drop.
    /// </summary>
    public static Dictionary<string, byte[]> Build(Profile? profile, string? bromureCaPem = null)
    {
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);

        // Always-on baseline.
        files[".config/kitty/kitty.conf"] = Utf8(KittyConfigBuilder.Build(profile));
        files[".bashrc"] = Utf8(BuildBashrc());
        files[".bash_profile"] = Utf8(BuildBashProfile());
        // Stake out the npm-global dir so `npm i -g` lands there
        // (PATH already includes it via .bashrc).
        files[".npm-global/.gitkeep"] = Array.Empty<byte>();

        if (profile is null) return files;

        // -- Git ----------------------------------------------------------

        var gitCreds = profile.GitHttpsCredentials
            .Where(c => !string.IsNullOrWhiteSpace(c.Token)
                        && !string.IsNullOrWhiteSpace(c.Host)
                        && !string.IsNullOrWhiteSpace(c.Username))
            .ToList();

        var hasIdentity = !string.IsNullOrWhiteSpace(profile.GitUserName)
                          || !string.IsNullOrWhiteSpace(profile.GitUserEmail);
        if (hasIdentity || gitCreds.Count > 0)
        {
            files[".gitconfig"] = Utf8(BuildGitConfig(profile, gitCreds.Count > 0));
        }
        if (gitCreds.Count > 0)
        {
            files[".git-credentials"] = Utf8(BuildGitCredentials(gitCreds));
        }

        // -- gh / glab CLI hosts ------------------------------------------

        var ghCreds = gitCreds.Where(c => IsGitHubHost(c.Host)).ToList();
        if (ghCreds.Count > 0)
        {
            files[".config/gh/hosts.yml"] = Utf8(BuildGhHostsYaml(ghCreds));
        }
        var glabCreds = gitCreds.Where(c => IsGitLabHost(c.Host)).ToList();
        if (glabCreds.Count > 0)
        {
            files[".config/glab-cli/config.yml"] = Utf8(BuildGlabConfigYaml(glabCreds));
        }

        // -- DigitalOcean -------------------------------------------------

        if (!string.IsNullOrWhiteSpace(profile.DigitalOceanToken))
        {
            files[".config/doctl/config.yaml"] = Utf8(
                "# Managed by Bromure Agentic Coding.\n" +
                $"access-token: {profile.DigitalOceanToken}\n");
        }

        // -- Docker -------------------------------------------------------

        var dockerRegs = profile.DockerRegistries
            .Where(r => !string.IsNullOrWhiteSpace(r.Host)
                        && !string.IsNullOrWhiteSpace(r.Username)
                        && !string.IsNullOrWhiteSpace(r.Password))
            .ToList();
        if (dockerRegs.Count > 0)
        {
            files[".docker/config.json"] = Utf8(BuildDockerConfigJson(dockerRegs));
        }

        // -- AWS ----------------------------------------------------------

        if (IsAwsUsable(profile.Aws))
        {
            files[".aws/config"] = Utf8(BuildAwsConfig(profile.Aws));
            // Static-keys mode also writes ~/.aws/credentials so the
            // SDK can find the AKID/secret without our credential_process
            // helper (which the macOS port uses but isn't ported yet).
            if (profile.Aws.AuthMode == AwsAuthMode.StaticKeys)
            {
                files[".aws/credentials"] = Utf8(BuildAwsCredentials(profile.Aws));
            }
        }

        // -- Bedrock for Claude Code --------------------------------------

        if (profile.BedrockEnabled)
        {
            files[".claude/settings.json"] = Utf8(BuildClaudeBedrockSettings(profile));
        }

        // -- Kubernetes ---------------------------------------------------
        // Skipped when there's no CA PEM available — the materializer
        // signs cluster trust with the Bromure CA so kubectl accepts
        // the proxy's MITM leaves.
        // Note: the actual KubeconfigMaterializer port lives in
        // Bromure.AC.Mitm.Pki (it has dependencies we don't want here).
        // SessionViewModel calls into it and merges the result.
        // (No-op here — caller is responsible for adding ".kube/config")

        return files;
    }

    // -- Builders ---------------------------------------------------------

    private static string BuildGitConfig(Profile profile, bool hasUsableCreds)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Managed by Bromure Agentic Coding.");
        var name = profile.GitUserName.Trim();
        var email = profile.GitUserEmail.Trim();
        if (name.Length > 0 || email.Length > 0)
        {
            sb.AppendLine("[user]");
            if (name.Length > 0) sb.AppendLine($"    name  = {name}");
            if (email.Length > 0) sb.AppendLine($"    email = {email}");
        }
        if (hasUsableCreds)
        {
            sb.AppendLine("[credential]");
            sb.AppendLine("    helper = store");
        }
        return sb.ToString();
    }

    private static string BuildGitCredentials(IEnumerable<GitHttpsCredential> creds)
    {
        // git's `store` helper expects: https://USER:TOKEN@HOST per line,
        // with userinfo percent-encoded.
        var sb = new StringBuilder();
        foreach (var c in creds)
        {
            var user = PercentEncodeUserInfo(c.Username);
            var token = PercentEncodeUserInfo(c.Token);
            var host = c.Host.Trim();
            sb.Append("https://").Append(user).Append(':').Append(token)
              .Append('@').Append(host).Append('\n');
        }
        return sb.ToString();
    }

    private static string BuildGhHostsYaml(IEnumerable<GitHttpsCredential> creds)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Managed by Bromure Agentic Coding.");
        foreach (var c in creds)
        {
            sb.AppendLine($"{c.Host}:");
            sb.AppendLine($"    user: {c.Username}");
            sb.AppendLine($"    oauth_token: {c.Token}");
            sb.AppendLine($"    git_protocol: https");
        }
        return sb.ToString();
    }

    private static string BuildGlabConfigYaml(IEnumerable<GitHttpsCredential> creds)
    {
        // glab's config.yml: top-level `hosts:` then per-host blocks.
        var sb = new StringBuilder();
        sb.AppendLine("# Managed by Bromure Agentic Coding.");
        sb.AppendLine("hosts:");
        foreach (var c in creds)
        {
            sb.AppendLine($"    {c.Host}:");
            sb.AppendLine($"        username: {c.Username}");
            sb.AppendLine($"        token: {c.Token}");
            sb.AppendLine($"        api_protocol: https");
            sb.AppendLine($"        git_protocol: https");
        }
        return sb.ToString();
    }

    private static string BuildDockerConfigJson(IEnumerable<DockerRegistryCredential> regs)
    {
        // ~/.docker/config.json:
        //   { "_bromureManaged": "...", "auths": { "<key>": { "auth": "<b64>" } } }
        // The sentinel key lets cleanup logic detect "ours" vs a hand-edited
        // file. Docker Hub gets the canonical https://index.docker.io/v1/ key.
        var auths = new JsonObject();
        foreach (var r in regs)
        {
            var raw = $"{r.Username}:{r.Password}";
            var b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(raw));
            auths[DockerConfigKey(r.Host)] = new JsonObject { ["auth"] = b64 };
        }
        var root = new JsonObject
        {
            ["_bromureManaged"] = "Managed by Bromure Agentic Coding.",
            ["auths"] = auths,
        };
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>Translate a registry hostname to the key Docker stores it
    /// under in <c>~/.docker/config.json</c>. Docker Hub's canonical key
    /// is the full URL, not the bare hostname.</summary>
    private static string DockerConfigKey(string host)
    {
        var h = host.Trim().ToLowerInvariant();
        return h switch
        {
            "docker.io" or "index.docker.io" or "registry-1.docker.io"
                => "https://index.docker.io/v1/",
            _ => host,
        };
    }

    private static bool IsAwsUsable(AwsCredentialsConfig aws) => aws.AuthMode switch
    {
        AwsAuthMode.Sso => !string.IsNullOrWhiteSpace(aws.SsoProfile),
        AwsAuthMode.StaticKeys => !string.IsNullOrWhiteSpace(aws.AccessKeyId)
                                  && !string.IsNullOrWhiteSpace(aws.SecretAccessKey),
        _ => false,
    };

    private static string BuildAwsConfig(AwsCredentialsConfig aws)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Managed by Bromure Agentic Coding.");
        sb.AppendLine("[default]");
        if (aws.AuthMode == AwsAuthMode.Sso && !string.IsNullOrWhiteSpace(aws.SsoProfile))
        {
            sb.AppendLine($"sso_session = {aws.SsoProfile}");
        }
        var region = aws.Region.Trim();
        if (region.Length > 0) sb.AppendLine($"region = {region}");
        return sb.ToString();
    }

    /// <summary>
    /// Build the JSON for <c>~/.claude/settings.json</c> when the
    /// profile routes Claude Code through AWS Bedrock instead of
    /// Anthropic. Same shape macOS Profile.materialize emits.
    /// </summary>
    private static string BuildClaudeBedrockSettings(Profile profile)
    {
        var env = new JsonObject
        {
            ["CLAUDE_CODE_USE_BEDROCK"] = "1",
            ["AWS_PROFILE"] = "default",
        };
        var region = profile.Aws.Region.Trim();
        if (region.Length > 0) env["AWS_REGION"] = region;
        var model = profile.BedrockModelID.Trim();
        if (model.Length > 0) env["ANTHROPIC_MODEL"] = model;
        var root = new JsonObject { ["env"] = env };
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    private static string BuildAwsCredentials(AwsCredentialsConfig aws)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Managed by Bromure Agentic Coding.");
        sb.AppendLine("[default]");
        sb.AppendLine($"aws_access_key_id = {aws.AccessKeyId}");
        sb.AppendLine($"aws_secret_access_key = {aws.SecretAccessKey}");
        if (!string.IsNullOrWhiteSpace(aws.SessionToken))
        {
            sb.AppendLine($"aws_session_token = {aws.SessionToken}");
        }
        return sb.ToString();
    }

    /// Percent-encode a string for the userinfo section of a URL. RFC 3986:
    /// anything outside the unreserved set must be encoded; <c>:</c> and
    /// <c>@</c> definitely have to be.
    private static string PercentEncodeUserInfo(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
        {
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                || c == '-' || c == '.' || c == '_' || c == '~')
            {
                sb.Append(c);
                continue;
            }
            foreach (var b in Encoding.UTF8.GetBytes(c.ToString()))
            {
                sb.Append('%').Append(b.ToString("X2"));
            }
        }
        return sb.ToString();
    }

    private static bool IsGitHubHost(string host)
    {
        var h = host.Trim().ToLowerInvariant();
        return h == "github.com" || h.EndsWith(".github.com")
            || h == "ghe.io" || h.EndsWith(".ghe.io");  // GHE.io is GitHub's enterprise sandbox
    }

    private static bool IsGitLabHost(string host)
    {
        var h = host.Trim().ToLowerInvariant();
        return h == "gitlab.com" || h.EndsWith(".gitlab.com")
            || h.StartsWith("gitlab.") || h.Contains(".gitlab.");
    }

    private static string BuildBashrc() => """
        # Generated by Bromure Agentic Coding — overwritten each session.
        # Edit the profile in BromureAC, not this file.

        # Defensive PATH: include the locations our installer puts
        # node_modules/.bin into so `claude`, `codex`, etc. resolve.
        export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

        # Source per-session API keys / env exports the host generated
        # from this profile.
        [ -f /mnt/bromure-meta/api_key.env ] && . /mnt/bromure-meta/api_key.env

        # Standard interactive niceties.
        case $- in
            *i*) ;;
            *) return;;
        esac
        export HISTSIZE=10000
        export HISTFILESIZE=20000
        shopt -s histappend checkwinsize
        alias ls='ls --color=auto'
        alias ll='ls -lah'
        """;

    private static string BuildBashProfile() => """
        # Generated by Bromure Agentic Coding — overwritten each session.
        [ -f ~/.bashrc ] && . ~/.bashrc

        # Auto-start X on tty1 (where autologin lands) so the user
        # boots straight into kitty fullscreen. Same trigger macOS
        # uses on the virtiofs-overlaid persistent home.
        if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
            exec startx
        fi
        """;

    private static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s.Replace("\r\n", "\n"));
}
