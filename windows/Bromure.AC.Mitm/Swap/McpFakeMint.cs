// macos-source: Sources/AgentCoding/Mitm/SessionTokenPlan.swift @ a663f52551c3  (mcpBearerFakes)
using Bromure.AC.Core.Model;

namespace Bromure.AC.Mitm.Swap;

/// <summary>
/// Per-session translation of a profile's enabled MCP servers into:
/// (a) <see cref="TokenMap.Entry"/> records the proxy uses to swap fake
/// bearers on the wire, and (b) (serverName, envVarName, fake) trios
/// the config builder writes into the agent's MCP config file.
///
/// <para>Fakes are derived deterministically via HKDF-SHA256 (see
/// <see cref="SessionTokenPlan.DeriveFake"/>) so the same profile +
/// install salt always produces the same fake — no spurious "API key
/// changed" warnings across launches.</para>
/// </summary>
public static class McpFakeMint
{
    /// <summary>Prefix for MCP bearer fakes. Used by the proxy to
    /// identify MCP hosts (so it can block OAuth discovery + inject the
    /// real bearer) without having to consult the profile config.</summary>
    public const string FakePrefix = "brm-mcp_";

    public sealed record Fake(string ServerName, string EnvVarName, string FakeToken, string RealToken, string Host);

    public sealed record Plan(IReadOnlyList<TokenMap.Entry> Entries, IReadOnlyList<Fake> Fakes);

    /// <summary>
    /// Build the per-session token plan for an enabled MCP server set.
    /// </summary>
    /// <param name="servers">Enabled HTTP MCP servers (stdio servers
    /// have no bearer/wire surface, so they're filtered here).</param>
    /// <param name="salt">Per-install HKDF salt (from <see cref="Engine.MitmEngine.FakeTokenSalt"/>).</param>
    public static Plan Build(IEnumerable<McpServer> servers, byte[] salt)
    {
        var entries = new List<TokenMap.Entry>();
        var fakes = new List<Fake>();
        foreach (var server in servers)
        {
            if (!server.Enabled) continue;
            if (server.Transport != McpTransport.Http) continue;
            if (server.UrlHost is not { Length: > 0 } host) continue;

            // Real bearer: OAuth access token if present, else static
            // bearer the user pasted. Empty bearers → no fake / no entry.
            var real = server.OAuthState?.AccessToken;
            if (string.IsNullOrEmpty(real)) real = server.BearerToken;
            if (string.IsNullOrEmpty(real)) continue;

            var fake = SessionTokenPlan.DeriveFake(
                prefix: FakePrefix,
                real: real,
                salt: salt);

            entries.Add(new TokenMap.Entry(
                Fake: fake,
                Real: real,
                Host: host,
                Header: EntryHeader.Authorization));

            fakes.Add(new Fake(
                ServerName: server.Name,
                EnvVarName: server.BearerTokenEnvVar,
                FakeToken: fake,
                RealToken: real,
                Host: host));
        }
        return new Plan(entries, fakes);
    }

    /// <summary>
    /// Project the plan's fakes into the form
    /// <see cref="Bromure.AC.Core.Model.McpConfigBuilder"/> expects:
    /// serverName → (envVarName, fake).
    /// </summary>
    public static Dictionary<string, (string EnvVar, string Fake)> ToConfigFakes(this Plan plan)
    {
        var result = new Dictionary<string, (string, string)>(StringComparer.Ordinal);
        foreach (var f in plan.Fakes)
        {
            result[f.ServerName] = (f.EnvVarName, f.FakeToken);
        }
        return result;
    }
}
