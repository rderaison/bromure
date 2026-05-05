using System.Security.Cryptography;
using System.Text;

namespace Bromure.AC.Mitm.Swap;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/SessionTokenPlan.swift</c>.
/// Built once per session launch from a Profile's saved tokens. Pairs
/// every real token with a freshly-minted fake — the real values stay
/// on the host (fed to <see cref="TokenSwap"/>); the fakes get written
/// into the VM's env vars + <c>~/.git-credentials</c>. The VM never
/// holds a real secret in any file or env var.
/// </summary>
public sealed class SessionTokenPlan
{
    public IReadOnlyList<Entry> Entries { get; }

    public SessionTokenPlan(IReadOnlyList<Entry> entries)
    {
        Entries = entries;
    }

    public sealed record Entry(
        string RealValue,
        string FakeValue,
        Purpose Purpose,
        string? ConsentCredentialId = null,
        string ConsentDisplayName = "");

    /// <summary>
    /// Discriminated union covering every token shape the proxy swaps.
    /// Mirrors the Swift enum 1:1.
    /// </summary>
    public abstract record Purpose
    {
        public sealed record AnthropicApiKey : Purpose;
        public sealed record OpenAiApiKey : Purpose;
        public sealed record GitHttps(string Host, string Username) : Purpose;
        public sealed record Manual(string Name, string EnvVarName, string HostFilter) : Purpose;
        public sealed record DigitalOcean : Purpose;
        public sealed record DockerRegistry(string Host, string Username) : Purpose;
    }

    /// <summary>
    /// Build the proxy's swap map. Each entry becomes one fake→real
    /// replacement, scoped to the host the real token belongs to.
    /// </summary>
    public TokenMap BuildTokenMap()
    {
        var entries = Entries.Select(e => new TokenMap.Entry(
            Fake: e.FakeValue,
            Real: e.RealValue,
            Host: HostScopeFor(e.Purpose),
            ConsentCredentialId: e.ConsentCredentialId,
            ConsentDisplayName: e.ConsentCredentialId is null ? null : e.ConsentDisplayName));
        return new TokenMap(entries.ToArray());
    }

    public string? FakeForAnthropic() =>
        Entries.FirstOrDefault(e => e.Purpose is Purpose.AnthropicApiKey)?.FakeValue;

    public string? FakeForOpenAi() =>
        Entries.FirstOrDefault(e => e.Purpose is Purpose.OpenAiApiKey)?.FakeValue;

    public string? FakeForDigitalOcean() =>
        Entries.FirstOrDefault(e => e.Purpose is Purpose.DigitalOcean)?.FakeValue;

    public string? FakeForGitHttps(string host, string username) =>
        Entries.FirstOrDefault(e =>
            e.Purpose is Purpose.GitHttps g && g.Host == host && g.Username == username)?.FakeValue;

    public string? FakeForDockerRegistry(string host, string username) =>
        Entries.FirstOrDefault(e =>
            e.Purpose is Purpose.DockerRegistry d && d.Host == host && d.Username == username)?.FakeValue;

    /// <summary>Manual entries with an env var name set, as <c>(envName, fake)</c> pairs.</summary>
    public IEnumerable<(string EnvName, string Fake)> ManualEnvExports()
    {
        foreach (var e in Entries)
        {
            if (e.Purpose is Purpose.Manual m && !string.IsNullOrEmpty(m.EnvVarName))
            {
                yield return (m.EnvVarName, e.FakeValue);
            }
        }
    }

    private static string? HostScopeFor(Purpose purpose) => purpose switch
    {
        Purpose.AnthropicApiKey => "anthropic.com",
        Purpose.OpenAiApiKey => "openai.com",
        Purpose.GitHttps g => g.Host,
        Purpose.Manual m => string.IsNullOrEmpty(m.HostFilter) ? null : m.HostFilter,
        Purpose.DigitalOcean => "digitalocean.com",
        Purpose.DockerRegistry d => d.Host,
        _ => null,
    };

    /// <summary>
    /// Cloud registries whose distribution-spec auth challenge points at
    /// a different hostname than the registry itself. Each docker-registry
    /// credential gets a duplicate swap entry per realm so the Basic-auth
    /// check on the realm host substitutes correctly.
    /// </summary>
    public static IReadOnlyList<string> DockerAuthRealmsFor(string host)
    {
        var h = host.Trim().ToLowerInvariant();
        return h switch
        {
            "registry.digitalocean.com" => new[] { "api.digitalocean.com" },
            "docker.io" or "registry-1.docker.io" or "index.docker.io" => new[] { "auth.docker.io" },
            "public.ecr.aws" => new[] { "public.ecr.aws" },
            _ => Array.Empty<string>(),
        };
    }

    // -- Fake derivation -------------------------------------------------

    private const string Alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    private static readonly byte[] DeriveInfo = Encoding.UTF8.GetBytes("bromure-ac-fake-token-v2");

    /// <summary>
    /// Deterministic fake-from-real derivation via HKDF-SHA256.
    /// Same <c>(real, salt)</c> pair always produces the same fake, so
    /// "API key fingerprint changed" warnings stay quiet across launches.
    /// Rotating either the real value or the salt is the only way fakes change.
    /// <para><paramref name="targetLength"/> lets us match the exact format
    /// clients validate. GitHub PATs are 40 chars; Anthropic / OpenAI
    /// accept arbitrary lengths so we leave the default. Base62 keeps us
    /// inside the alphabet GitHub uses so <c>gh</c> / curl don't reject on
    /// "looks-wrong" character checks.</para>
    /// </summary>
    public static string DeriveFake(string prefix, string real, byte[] salt, int? targetLength = null)
    {
        var derived = new byte[32];
        HKDF.DeriveKey(
            HashAlgorithmName.SHA256,
            ikm: Encoding.UTF8.GetBytes(real),
            output: derived,
            salt: salt,
            info: DeriveInfo);

        var suffixLen = targetLength is { } tl ? Math.Max(0, tl - prefix.Length) : 32;
        var suffix = new char[suffixLen];
        for (var i = 0; i < suffixLen; i++)
        {
            suffix[i] = Alphabet[derived[i % derived.Length] % Alphabet.Length];
        }
        return prefix + new string(suffix);
    }
}
