namespace Bromure.AC.Core.Model;

/// <summary>
/// Translates a <see cref="Profile"/> into the dictionary of env exports
/// that lands in <c>/mnt/bromure-meta/api_key.env</c> at session start.
/// The guest's <c>.bashrc</c> sources that file, so anything emitted
/// here becomes a real environment variable for claude / codex / shell
/// commands inside the VM.
///
/// <para>This mirrors what the macOS port writes into
/// <c>SessionDisk.metaShare</c> (see
/// <c>Sources/AgentCoding/SessionDisk.swift</c>); on Windows we have no
/// virtiofs share at runtime, so the values flow through the per-session
/// ISO instead.</para>
/// </summary>
public static class ProfileEnvExports
{
    /// <summary>
    /// Build the env-var map. Returns a fresh dictionary; callers are
    /// free to add/override entries before passing to
    /// <c>SessionMetadataIso.Write</c>.
    /// </summary>
    public static Dictionary<string, string> ForProfile(Profile profile)
    {
        var env = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["BROMURE_PROFILE_ID"] = profile.Id.ToString(),
            ["BROMURE_PROFILE_NAME"] = profile.Name,
            ["BROMURE_SESSION_HOST"] = "windows",
        };

        // Primary tool's token. AgentTool determines which env name the
        // CLI looks for. Both tools also accept their own files
        // (~/.config/claude/auth.json etc) but the env name is the
        // canonical override.
        if (!string.IsNullOrEmpty(profile.ApiKey))
        {
            var primaryEnv = profile.Tool switch
            {
                AgentTool.Claude => "ANTHROPIC_API_KEY",
                AgentTool.Codex => "OPENAI_API_KEY",
                _ => null,
            };
            if (primaryEnv is not null)
            {
                env[primaryEnv] = profile.ApiKey;
            }
        }

        // Additional tools — same env-name mapping, only override the
        // primary's choice if the user actually populated a separate key.
        foreach (var spec in profile.AdditionalTools)
        {
            if (string.IsNullOrEmpty(spec.ApiKey)) continue;
            var name = spec.Tool switch
            {
                AgentTool.Claude => "ANTHROPIC_API_KEY",
                AgentTool.Codex => "OPENAI_API_KEY",
                _ => null,
            };
            if (name is null) continue;
            env[name] = spec.ApiKey;
        }

        // Manual tokens with an EnvVarName field — explicit user intent
        // to expose via env. Skip the ones marked require-approval; the
        // approvals UI hands those to the guest at use-time, not at
        // session boot.
        foreach (var token in profile.ManualTokens)
        {
            if (string.IsNullOrEmpty(token.EnvVarName)) continue;
            if (token.RequireApproval) continue;
            env[token.EnvVarName] = token.Value;
        }

        // Plain environment variables. Same require-approval gate.
        foreach (var ev in profile.EnvironmentVariables)
        {
            if (string.IsNullOrEmpty(ev.Name)) continue;
            // EnvironmentVariable doesn't carry a per-row require-approval
            // flag in the current model — the per-profile editor exposes
            // a global "treat as secret" affordance. Pass them all through.
            env[ev.Name] = ev.Value;
        }

        // Convenience: DIGITALOCEAN_TOKEN for the "I just pasted a token"
        // top-level field. Same pattern macOS follows.
        if (!string.IsNullOrEmpty(profile.DigitalOceanToken)
            && !profile.DigitalOceanRequiresApproval)
        {
            env["DIGITALOCEAN_TOKEN"] = profile.DigitalOceanToken;
        }

        return env;
    }
}
