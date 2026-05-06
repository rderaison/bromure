// macos-source: Sources/AgentCoding/Mitm/CompromiseDetector.swift @ d0c48f35f503
using System.Text;

namespace Bromure.AC.Mitm.Swap;

/// <summary>
/// Direct port of the compromise-detection half of
/// <c>Sources/AgentCoding/Mitm/CompromiseDetector.swift</c>. Uses the
/// pre-built <see cref="AhoCorasick"/> over a profile's fake tokens to
/// scan an outbound request bytes stream — and, when matches fire on
/// hosts outside the entry's declared scope, flags the leak.
///
/// <para>The compromise detector runs ALONGSIDE the swapper: the
/// swapper substitutes when the host matches strict scope; the detector
/// fires when a fake token is observed leaving the VM bound for a host
/// the entry was NOT scoped for. That second case means a guest-side
/// process has copied the fake somewhere (env vars, config files,
/// leaked logs) and is now sending it to a third party — at which point
/// the host should suspend the VM and surface a compromise alert.</para>
/// </summary>
public sealed class CompromiseDetector
{
    private readonly TokenSwapper _swapper;
    private AhoCorasick? _scanner;
    private List<TokenMap.Entry> _patterns = new();
    private Guid _scopeProfileId = Guid.Empty;
    private readonly object _gate = new();

    public CompromiseDetector(TokenSwapper swapper) => _swapper = swapper;

    /// <summary>
    /// Rebuild the scanner against the given profile's current map.
    /// Call after any <see cref="TokenSwapper.SetMap"/> /
    /// <see cref="TokenSwapper.AppendEntries"/> for that profile.
    /// </summary>
    public void Rebuild(Guid profileId)
    {
        var entries = _swapper.EntriesFor(profileId).ToList();
        var patterns = new List<byte[]>(entries.Count);
        foreach (var e in entries)
        {
            patterns.Add(Encoding.UTF8.GetBytes(e.Fake));
        }
        var scanner = new AhoCorasick(patterns);
        lock (_gate)
        {
            _scanner = scanner;
            _patterns = entries;
            _scopeProfileId = profileId;
        }
    }

    /// <summary>
    /// Scan <paramref name="rawBytes"/> for any fake leaving for a host
    /// outside its declared scope. Returns the leaks (one per matched
    /// fake the entry's host doesn't authorise sending to).
    /// </summary>
    public IReadOnlyList<CompromiseLeak> Scan(Guid profileId, ReadOnlySpan<byte> rawBytes, string observedHost)
    {
        AhoCorasick? scanner;
        List<TokenMap.Entry> patterns;
        lock (_gate)
        {
            if (_scopeProfileId != profileId || _scanner is null)
            {
                return Array.Empty<CompromiseLeak>();
            }
            scanner = _scanner;
            patterns = _patterns;
        }

        var hits = scanner.Scan(rawBytes);
        if (hits.Count == 0) return Array.Empty<CompromiseLeak>();

        var output = new List<CompromiseLeak>(hits.Count);
        foreach (var idx in hits)
        {
            if (idx >= patterns.Count) continue;
            var entry = patterns[idx];
            // No declared host = no scope-violation possible.
            if (string.IsNullOrEmpty(entry.Host)) continue;
            // Strict-scope match: this is the swap path's authorised
            // case. We use scope-FAMILY here since the compromise check
            // is about "the user's first-party provider's tokens
            // leaking to unrelated services" — sibling subdomains under
            // the same registered domain stay legitimate.
            if (HostMatcher.HostMatchesScopeFamily(observedHost, entry.Host)) continue;

            output.Add(new CompromiseLeak(
                FakeTokenPreview: TokenSwapper.Preview(entry.Fake),
                CredentialDisplayName: entry.ConsentDisplayName ?? "session token",
                DeclaredHost: entry.Host,
                ObservedHost: observedHost));
        }
        return output;
    }
}

public sealed record CompromiseLeak(
    string FakeTokenPreview,
    string CredentialDisplayName,
    string DeclaredHost,
    string ObservedHost);
