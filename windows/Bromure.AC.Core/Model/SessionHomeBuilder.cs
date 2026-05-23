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
    public static Dictionary<string, byte[]> Build(
        Profile? profile,
        string? bromureCaPem = null,
        IReadOnlyDictionary<string, (string EnvVar, string Fake)>? mcpFakes = null,
        string? digitalOceanFake = null)
    {
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);

        // Always-on baseline.
        files[".config/kitty/kitty.conf"] = Utf8(KittyConfigBuilder.Build(profile));
        files[".bashrc"] = Utf8(BuildBashrc(profile?.Name));
        files[".bash_profile"] = Utf8(BuildBashProfile());
        // Stake out the npm-global dir so `npm i -g` lands there
        // (PATH already includes it via .bashrc).
        files[".npm-global/.gitkeep"] = Array.Empty<byte>();

        if (profile is null) return files;

        // Per-session profile-id marker. The in-VM
        // bromure-aws-credentials helper reads this to figure out
        // which profile to ask the host for credentials on.
        files[".bromure-profile-id"] = Utf8(profile.Id.ToString("D") + "\n");

        // Host timezone → IANA zone name → ~/.bromure-tz. .bashrc
        // sources it as TZ env. Windows uses its own zone IDs
        // ("Pacific Standard Time"); .NET 6+ ships the Unicode CLDR
        // mapping so we can convert. Falls back silently if the
        // current zone is custom / unmapped — guest stays on UTC.
        var ianaTz = TryGetHostIanaTimeZone();
        if (!string.IsNullOrEmpty(ianaTz))
        {
            files[".bromure-tz"] = Utf8(ianaTz + "\n");
        }

        // Audit 10 §1.6 — share the host's custom font into the guest
        // when the profile pinned one in CustomFontFamily. We don't
        // ship every Windows font (the System fonts dir is 100s of
        // MiB and most are display fonts kitty wouldn't pick up
        // anyway); we copy ONLY the requested family from the user's
        // installed-fonts dir, so a user who installed JetBrains Mono
        // and selected it in the profile editor gets it inside the VM
        // without the ~100ms overlay-tar penalty for fonts they didn't
        // ask for. fontconfig auto-discovers anything in ~/.fonts/.
        TryDropRequestedFont(profile, files);

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
            // Audit 03 #2: previously this file received the real
            // PAT. The proxy now swaps a fake on the wire so the
            // VM only ever sees a doomed-by-construction token —
            // identical fail-closed shape as the AWS .aws/credentials
            // path. When no fake was minted (host didn't pass one in)
            // we fall back to the real token rather than break the
            // tooling outright, but the WPF host wires the fake on
            // every launch when DigitalOceanToken is non-empty.
            var doToken = digitalOceanFake ?? profile.DigitalOceanToken;
            files[".config/doctl/config.yaml"] = Utf8(
                "# Managed by Bromure Agentic Coding.\n" +
                $"access-token: {doToken}\n");
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
            // Static-keys mode writes ~/.aws/credentials with FAKE
            // material — the host's AwsResigner strips the doomed
            // signature and re-signs with the real key on the wire.
            // The real secret never reaches the VM. Same fail-closed
            // story the macOS port documents in Localizable.strings:
            // anything that bypasses the proxy gets
            // InvalidSignatureException from AWS.
            if (profile.Aws.AuthMode == AwsAuthMode.StaticKeys)
            {
                files[".aws/credentials"] = Utf8(BuildFakeAwsCredentials());
            }
        }

        // -- MCP servers --------------------------------------------------
        // Enabled MCP servers materialize into the agent's config file at
        // boot. Bearer tokens get replaced with proxy-side fakes
        // (registered by the caller into TokenSwapper); the MITM swaps
        // them on the wire. Direct port of macOS SessionDisk's MCP write.
        var enabledMcp = profile.McpServers.Where(s => s.Enabled).ToList();
        if (enabledMcp.Count > 0)
        {
            files[".claude.json"] = Utf8(McpConfigBuilder.ClaudeCodeJson(enabledMcp, mcpFakes));
            files[".codex/config.toml"] = Utf8(McpConfigBuilder.CodexToml(enabledMcp, mcpFakes));
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
        // Audit 04 §25: point the SDK at the in-guest credential
        // helper. The helper reads ~/.bromure-profile-id and dials
        // AF_VSOCK CID_HOST:8445 to fetch a fresh credential_process
        // JSON document from the host — letting the host rotate fake
        // material per call without re-writing the credentials file.
        // macOS uses the same shape; the path differs because the
        // Windows port installs the helper into /usr/local/bin via
        // setup.sh rather than /mnt/bromure-meta.
        sb.AppendLine("credential_process = /usr/local/bin/bromure-aws-credentials");
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

    /// <summary>
    /// Build a credentials file whose AKID + secret are FAKES the
    /// AWS SDK accepts (right shape, right length) but which produce
    /// signatures the AWS service will reject. The host's MITM
    /// resigner strips the doomed signature and replaces it with one
    /// minted from the real material, which lives only on the host.
    ///
    /// <para>Same fail-closed model the macOS port describes verbatim
    /// in the AWS-credentials onboarding string: if the guest sends an
    /// AWS request that bypasses the proxy, AWS rejects with
    /// InvalidSignatureException. Real secret material never touches
    /// the VM file system.</para>
    /// </summary>
    internal static string BuildFakeAwsCredentials()
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Managed by Bromure Agentic Coding.");
        sb.AppendLine("# These credentials are intentional fakes — the real");
        sb.AppendLine("# AKID + secret live on the host and never reach this VM.");
        sb.AppendLine("# AWS will reject any signed request that bypasses the");
        sb.AppendLine("# Bromure proxy with InvalidSignatureException. The");
        sb.AppendLine("# proxy strips the doomed signature and re-signs with");
        sb.AppendLine("# the real material before the request leaves your host.");
        sb.AppendLine("[default]");
        // AKID format: 20 chars, ASIA prefix (temporary-creds shape so
        // the SDK accepts the session token line that follows).
        sb.AppendLine("aws_access_key_id = ASIABROMUREFAKEFAKE0");
        // Secret: 40 chars base64-ish — enough to pass SDK length checks.
        sb.AppendLine("aws_secret_access_key = BROMUREFAKEsecretBROMUREFAKEsecret0000000");
        // Session token: any string the SDK will accept. Without it
        // the SDK won't pass through ASIA-prefixed AKIDs to STS-aware
        // services. The proxy strips this header before forwarding.
        sb.AppendLine("aws_session_token = BROMUREFAKEsessionTokenForRedirectionThroughHostProxy");
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

    private static string BuildBashrc(string? profileName)
    {
        // Filter the profile name to a shell-safe prompt segment: keep
        // letters, digits, dash and underscore, replace runs of
        // anything else with a single dash, cap at 24 chars. Avoids
        // breaking the PS1 string with quote / backslash chars from a
        // user-typed name.
        var safe = string.IsNullOrWhiteSpace(profileName) ? "bromure" : profileName.Trim();
        var sb = new System.Text.StringBuilder(safe.Length);
        bool lastDash = false;
        foreach (var c in safe)
        {
            if (char.IsLetterOrDigit(c) || c == '-' || c == '_')
            {
                sb.Append(c);
                lastDash = false;
            }
            else if (!lastDash)
            {
                sb.Append('-');
                lastDash = true;
            }
        }
        var promptSegment = sb.ToString().Trim('-');
        if (promptSegment.Length == 0) promptSegment = "bromure";
        if (promptSegment.Length > 24) promptSegment = promptSegment.Substring(0, 24);

        return $$"""
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

            # Bromure prompt: profile name in cyan + cwd in green, so a
            # user with three concurrent sessions can tell at a glance
            # which profile they're typing into. Profile name filtered
            # at session-overlay time to shell-safe chars.
            PS1='\[\033[1;36m\]{{promptSegment}}\[\033[0m\]:\[\033[1;32m\]\W\[\033[0m\]\$ '

            # Audit 10 §3.7 — host-side timezone propagation. Without
            # this, `date` / log timestamps inside the VM are UTC; the
            # user sees journal lines they thought happened "an hour ago"
            # but the timestamp is offset by their local TZ. Sourcing
            # the host's IANA zone via TZ env lets glibc time functions
            # localise the display without us touching /etc/localtime
            # (which would need root, and would conflict with any
            # guest-side override).
            [ -f "$HOME/.bromure-tz" ] && export TZ="$(cat "$HOME/.bromure-tz")"
            """;
    }

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

    /// <summary>Drop the requested font family (if any) from the
    /// user's installed-fonts dir into the home overlay. Best-effort:
    /// matches by case-insensitive substring against the font file
    /// name. If we can't find it or the profile doesn't pin a family,
    /// we leave fontconfig to its own defaults inside the guest.</summary>
    private static void TryDropRequestedFont(Profile? profile, Dictionary<string, byte[]> files)
    {
        try
        {
            if (profile is null) return;
            var family = profile.CustomFontFamily?.Trim();
            if (string.IsNullOrEmpty(family)) return;
            // %LOCALAPPDATA%\Microsoft\Windows\Fonts is the user-installed
            // fonts dir; readable without elevation. The system dir at
            // C:\Windows\Fonts is technically accessible but full of
            // unrelated UI fonts and adds size without value.
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrEmpty(localAppData)) return;
            var fontsDir = System.IO.Path.Combine(localAppData, "Microsoft", "Windows", "Fonts");
            if (!Directory.Exists(fontsDir)) return;
            // Case-insensitive contains is forgiving: "JetBrains Mono"
            // matches "JetBrainsMono-Regular.ttf" / "JetBrainsMonoNL-
            // Bold.ttf". We push every variant we find so kitty's
            // weight/style requests resolve.
            var simplified = new string(family.Where(char.IsLetterOrDigit).ToArray());
            if (simplified.Length < 3) return;  // refuse "Co" / "JB" — too noisy
            foreach (var path in Directory.EnumerateFiles(fontsDir))
            {
                var ext = System.IO.Path.GetExtension(path).ToLowerInvariant();
                if (ext != ".ttf" && ext != ".otf") continue;
                var fileName = System.IO.Path.GetFileNameWithoutExtension(path);
                var fileSimplified = new string(fileName.Where(char.IsLetterOrDigit).ToArray());
                if (!fileSimplified.Contains(simplified, StringComparison.OrdinalIgnoreCase)) continue;
                try
                {
                    var bytes = File.ReadAllBytes(path);
                    if (bytes.Length > 8 * 1024 * 1024) continue;  // skip outliers >8MiB
                    files[".fonts/" + System.IO.Path.GetFileName(path)] = bytes;
                }
                catch (IOException) { /* in-use, skip */ }
            }
        }
        catch { /* never break session boot over fonts */ }
    }

    /// <summary>Best-effort lookup of the host's IANA timezone name
    /// (e.g. "Europe/Paris"). On Linux/macOS <see cref="TimeZoneInfo.Local.Id"/>
    /// already IS the IANA name. On Windows it's a Microsoft zone id
    /// ("Romance Standard Time") which .NET 6+ can translate via
    /// <see cref="TimeZoneInfo.TryConvertWindowsIdToIanaId"/>. Returns
    /// null if the host's zone has no IANA equivalent — the guest
    /// then keeps UTC display, no harm done.</summary>
    private static string? TryGetHostIanaTimeZone()
    {
        try
        {
            var local = TimeZoneInfo.Local;
            // Linux/macOS: Id is already IANA.
            if (local.HasIanaId) return local.Id;
            // Windows: translate via CLDR map.
            return TimeZoneInfo.TryConvertWindowsIdToIanaId(local.Id, out var iana) ? iana : null;
        }
        catch { return null; }
    }

    private static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s.Replace("\r\n", "\n"));
}
