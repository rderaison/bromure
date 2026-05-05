namespace Bromure.AC.Mitm.Swap;

/// <summary>
/// Host-vs-scope matching helpers — the cornerstone of the swap engine's
/// security model. See the comment on <see cref="TokenMap.Entry.Host"/>
/// for why substring matching is forbidden.
/// </summary>
public static class HostMatcher
{
    /// <summary>
    /// Cookie-style domain match: <paramref name="host"/> belongs to
    /// <paramref name="scope"/> if it equals <paramref name="scope"/> or
    /// is a proper subdomain (<c>host.EndsWith("." + scope)</c>).
    /// Case-insensitive. Substring matching is intentionally NOT used.
    /// </summary>
    public static bool HostMatchesScope(string host, string scope)
    {
        var h = host.ToLowerInvariant();
        var s = scope.ToLowerInvariant();
        return h == s || h.EndsWith("." + s, StringComparison.Ordinal);
    }

    /// <summary>
    /// Relaxed <see cref="HostMatchesScope"/> for compromise detection
    /// only. Returns true when <paramref name="host"/> is a sibling of
    /// <paramref name="scope"/> under the same registered domain (e.g.
    /// <c>mcp-tools.anthropic.com</c> is a sibling of
    /// <c>api.anthropic.com</c>). Strips one leading label off
    /// <paramref name="scope"/> and re-runs the suffix match. Refuses to
    /// strip below three labels so <c>example.com</c> → <c>com</c>
    /// doesn't match every .com host.
    ///
    /// <para><b>Only</b> used by compromise detection / sibling-aware
    /// swap paths. The strict swap path always calls
    /// <see cref="HostMatchesScope"/>.</para>
    /// </summary>
    public static bool HostMatchesScopeFamily(string host, string scope)
    {
        if (HostMatchesScope(host, scope)) return true;
        var labels = scope.ToLowerInvariant().Split('.');
        if (labels.Length < 3) return false;
        var parent = string.Join('.', labels.Skip(1));
        var h = host.ToLowerInvariant();
        return h == parent || h.EndsWith("." + parent, StringComparison.Ordinal);
    }
}
