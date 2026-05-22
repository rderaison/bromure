// macos-source: Sources/AgentCoding/Mitm/TokenSwap.swift @ 3ab4e2544b54
using System.Collections.Concurrent;
using System.Text;

namespace Bromure.AC.Mitm.Swap;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/TokenSwap.swift</c>.
/// HTTP request inspector + token swapper. Operates on a request as raw
/// bytes (header section + body) to keep things zero-copy and preserve
/// byte-for-byte semantics of unrelated headers.
///
/// <para>Per-profile fake↔real maps; the swap path holds entries in a
/// dictionary keyed by profile so multiple sessions can run concurrently
/// without cross-contamination. Maps are mutated through
/// <see cref="SetMap"/>/<see cref="AppendEntries"/>; lookups via
/// <see cref="Swap"/> snapshot the map first to keep locks tight.</para>
///
/// <para>Consent-gated entries are awaited before substitution (the
/// hot path holds the connection until the user decides). The
/// <see cref="IConsentBroker"/> seam decouples the swapper from any
/// particular UI.</para>
/// </summary>
public sealed class TokenSwapper
{
    private static readonly byte[] HeaderEndPattern = "\r\n\r\n"u8.ToArray();

    private readonly object _gate = new();
    private readonly Dictionary<Guid, TokenMap> _maps = new();
    private readonly IConsentBroker _consent;
    private Action<CompromiseEvent>? _compromiseHandler;

    /// <summary>
    /// Fired after every per-profile map mutation (set / append /
    /// clear). The compromise detector subscribes here so the AC
    /// scanner is rebuilt whenever new fake↔real entries land —
    /// previously the rotation rewriter added new tokens but the
    /// detector kept scanning the old pattern set, missing leaks.
    /// (Audit 03 #1, CRITICAL.)
    /// </summary>
    public event Action<Guid>? MapMutated;

    public TokenSwapper(IConsentBroker consent) => _consent = consent;

    public void SetMap(TokenMap map, Guid profileId)
    {
        lock (_gate) _maps[profileId] = map;
        try { MapMutated?.Invoke(profileId); } catch { /* handlers must not break the swap path */ }
    }

    public void ClearMap(Guid profileId)
    {
        lock (_gate) _maps.Remove(profileId);
        try { MapMutated?.Invoke(profileId); } catch { }
    }

    /// <summary>
    /// Append new entries without clobbering existing ones (kubeconfigs,
    /// manual tokens, etc.). Used by the subscription-token coordinator
    /// and the OAuth rotation rewriter — both stream new pairs in after
    /// the initial <see cref="SetMap"/>.
    /// </summary>
    public void AppendEntries(IEnumerable<TokenMap.Entry> newEntries, Guid profileId)
    {
        lock (_gate)
        {
            var existing = _maps.TryGetValue(profileId, out var m) ? m.Entries : Array.Empty<TokenMap.Entry>();
            _maps[profileId] = new TokenMap(existing.Concat(newEntries).ToArray());
        }
        try { MapMutated?.Invoke(profileId); } catch { }
    }

    public IReadOnlyList<TokenMap.Entry> EntriesFor(Guid profileId)
    {
        lock (_gate) return _maps.TryGetValue(profileId, out var m) ? m.Entries : Array.Empty<TokenMap.Entry>();
    }

    /// <summary>
    /// Direct port of <c>TokenSwap.detectSubscriptionAccessToken</c>:
    /// look at the outgoing request's <c>Authorization: Bearer …</c>
    /// header and return the cleartext token if it's a clean
    /// <c>sk-ant-oat01-…</c> token (NOT a brm-fake, NOT already in the
    /// swap map). Caller is expected to have already gated on the
    /// host being anthropic.com.
    /// </summary>
    public string? DetectSubscriptionAccessToken(byte[] rawRequest, Guid profileId)
    {
        var (knownFakes, knownReals) = SnapshotKnownTokens(profileId);
        return ExtractBearer(rawRequest) is { } tok
               && tok.StartsWith("sk-ant-oat01-", StringComparison.Ordinal)
               && !tok.StartsWith("sk-ant-oat01-brm-", StringComparison.Ordinal)
               && !knownFakes.Contains(tok)
               && !knownReals.Contains(tok)
            ? tok
            : null;
    }

    /// <summary>
    /// Direct port of <c>TokenSwap.detectCodexAccessToken</c>. Codex
    /// tokens are JWT-shaped (<c>eyJ…</c>); we skip our minted fakes
    /// (whose signature segment is replaced by a <c>brm-cdX-sig</c>
    /// marker) and tokens already known to the swap map.
    /// </summary>
    public string? DetectCodexAccessToken(byte[] rawRequest, Guid profileId)
    {
        var (knownFakes, knownReals) = SnapshotKnownTokens(profileId);
        var tok = ExtractBearer(rawRequest);
        if (tok is null) return null;
        if (!tok.StartsWith("eyJ", StringComparison.Ordinal) || tok.Length < 32) return null;
        if (SubscriptionFakeMint.IsJwtFake(tok)) return null;
        if (knownFakes.Contains(tok) || knownReals.Contains(tok)) return null;
        return tok;
    }

    private (HashSet<string> Fakes, HashSet<string> Reals) SnapshotKnownTokens(Guid profileId)
    {
        lock (_gate)
        {
            if (!_maps.TryGetValue(profileId, out var map))
            {
                return (new HashSet<string>(StringComparer.Ordinal), new HashSet<string>(StringComparer.Ordinal));
            }
            var fakes = new HashSet<string>(map.Entries.Select(e => e.Fake), StringComparer.Ordinal);
            var reals = new HashSet<string>(map.Entries.Select(e => e.Real), StringComparer.Ordinal);
            return (fakes, reals);
        }
    }

    private static string? ExtractBearer(byte[] rawRequest)
    {
        var headerEndIdx = IndexOf(rawRequest, HeaderEndPattern);
        if (headerEndIdx < 0) return null;
        string headerStr;
        try { headerStr = Encoding.ASCII.GetString(rawRequest, 0, headerEndIdx); }
        catch { return null; }
        foreach (var line in headerStr.Split("\r\n"))
        {
            var colon = line.IndexOf(':');
            if (colon < 0) continue;
            var name = line[..colon].Trim();
            if (!name.Equals("authorization", StringComparison.OrdinalIgnoreCase)) continue;
            var value = line[(colon + 1)..].Trim();
            var space = value.IndexOf(' ');
            if (space < 0) continue;
            var scheme = value[..space];
            if (!scheme.Equals("bearer", StringComparison.OrdinalIgnoreCase)) continue;
            return value[(space + 1)..].Trim();
        }
        return null;
    }

    public void SetCompromiseHandler(Action<CompromiseEvent>? handler)
    {
        lock (_gate) _compromiseHandler = handler;
    }

    /// <summary>
    /// Surface a compromise event to whatever handler the engine
    /// registered via <see cref="SetCompromiseHandler"/>. The
    /// caller (proxy hot path or the body-scan detector) builds
    /// the event with all the context it has; the swapper only
    /// fans it out.
    /// </summary>
    public void FireCompromise(CompromiseEvent evt)
    {
        Action<CompromiseEvent>? handler;
        lock (_gate) handler = _compromiseHandler;
        try { handler?.Invoke(evt); }
        catch { /* handler is host-side; the swap path must never propagate */ }
    }

    private TokenMap? SnapshotMap(Guid profileId)
    {
        lock (_gate) return _maps.TryGetValue(profileId, out var m) ? m : null;
    }

    /// <summary>
    /// Returns the (modified bytes, swap report) for <paramref name="rawRequest"/>.
    /// If no swap applied, the original buffer is returned untouched.
    /// </summary>
    public async Task<SwapResult> SwapAsync(
        byte[] rawRequest, string host, Guid profileId,
        CancellationToken ct = default)
    {
        var map = SnapshotMap(profileId);
        if (map is null || map.IsEmpty) return new SwapResult(rawRequest, Array.Empty<SwapRecord>());

        var headerEndIdx = IndexOf(rawRequest, HeaderEndPattern);
        if (headerEndIdx < 0) return new SwapResult(rawRequest, Array.Empty<SwapRecord>());

        // ASCII for headers — non-ASCII bytes get rejected, matching the
        // macOS behaviour. Body slice excludes the \r\n\r\n separator so
        // any Content-Length we patch later reflects the message body
        // strictly (the macOS port has a 4-byte off-by-one here that
        // we're intentionally diverging from — RFC 9110 says
        // Content-Length is the body, not body+separator).
        var headerStr = Encoding.ASCII.GetString(rawRequest, 0, headerEndIdx);
        var bodyStart = headerEndIdx + HeaderEndPattern.Length;
        var bodyBytes = new byte[rawRequest.Length - bodyStart];
        Buffer.BlockCopy(rawRequest, bodyStart, bodyBytes, 0, bodyBytes.Length);

        var swaps = new List<SwapRecord>();
        var bodyDirty = false;

        foreach (var entry in map.Entries)
        {
            if (!string.IsNullOrEmpty(entry.Host))
            {
                var matched = entry.AcceptSiblings
                    ? HostMatcher.HostMatchesScopeFamily(host, entry.Host)
                    : HostMatcher.HostMatchesScope(host, entry.Host);
                if (!matched) continue;
            }

            var inHeader = headerStr.Contains(entry.Fake, StringComparison.Ordinal);
            var fakeBytes = Encoding.UTF8.GetBytes(entry.Fake);
            var inBody = entry.Body && IndexOf(bodyBytes, fakeBytes) >= 0;
            if (!inHeader && !inBody) continue;

            if (entry.ConsentCredentialId is not null)
            {
                var allowed = await _consent.RequestConsentAsync(
                    profileId,
                    entry.ConsentCredentialId,
                    entry.ConsentDisplayName ?? entry.ConsentCredentialId,
                    scopeHint: entry.Host is { } h ? $"for any *.{h} request" : "for outbound requests",
                    ct).ConfigureAwait(false);
                if (!allowed) continue;
            }

            // Header sweep: same fake might appear in multiple headers.
            while (true)
            {
                var idx = headerStr.IndexOf(entry.Fake, StringComparison.Ordinal);
                if (idx < 0) break;
                headerStr = headerStr.Remove(idx, entry.Fake.Length).Insert(idx, entry.Real);
                swaps.Add(new SwapRecord(Preview(entry.Fake), Preview(entry.Real), host));
            }

            if (inBody)
            {
                bodyBytes = ReplaceAll(bodyBytes, fakeBytes, Encoding.UTF8.GetBytes(entry.Real),
                    out var bodyHits);
                if (bodyHits > 0)
                {
                    bodyDirty = true;
                    for (var i = 0; i < bodyHits; i++)
                    {
                        swaps.Add(new SwapRecord(Preview(entry.Fake), Preview(entry.Real), host));
                    }
                }
            }
        }

        if (swaps.Count == 0) return new SwapResult(rawRequest, Array.Empty<SwapRecord>());

        if (bodyDirty)
        {
            // Body-mutated requests need Content-Length patched if the
            // header was present; a stale length truncates the upstream's
            // view of the body. Header-only swaps preserve length because
            // fake and real are length-matched.
            headerStr = ReplaceContentLength(headerStr, bodyBytes.Length);
        }

        var headerBytes = Encoding.ASCII.GetBytes(headerStr);
        var output = new byte[headerBytes.Length + HeaderEndPattern.Length + bodyBytes.Length];
        Buffer.BlockCopy(headerBytes, 0, output, 0, headerBytes.Length);
        Buffer.BlockCopy(HeaderEndPattern, 0, output, headerBytes.Length, HeaderEndPattern.Length);
        Buffer.BlockCopy(bodyBytes, 0, output, headerBytes.Length + HeaderEndPattern.Length, bodyBytes.Length);
        return new SwapResult(output, swaps);
    }

    /// <summary>
    /// Scan a pre-swap request for <c>Authorization: Bearer …</c> and
    /// <c>*-api-key: …</c> values that <i>aren't</i> in the profile's
    /// fake map — i.e. either a real secret the user pasted directly into
    /// the VM (bypassing bromure's vault) or some other opaque token
    /// bromure doesn't manage. The Trace Inspector flags these prominently.
    /// </summary>
    public IReadOnlyList<LeakReport> DetectLeaks(byte[] rawRequest, Guid profileId)
    {
        HashSet<string> knownFakes;
        lock (_gate)
        {
            knownFakes = _maps.TryGetValue(profileId, out var m)
                ? m.Entries.Select(e => e.Fake).ToHashSet(StringComparer.Ordinal)
                : new HashSet<string>(StringComparer.Ordinal);
        }

        var headerEndIdx = IndexOf(rawRequest, HeaderEndPattern);
        if (headerEndIdx < 0) return Array.Empty<LeakReport>();

        var headerStr = Encoding.ASCII.GetString(rawRequest, 0, headerEndIdx);
        var leaks = new List<LeakReport>();
        foreach (var rawLine in headerStr.Split("\r\n"))
        {
            var colon = rawLine.IndexOf(':');
            if (colon < 0) continue;
            var name = rawLine[..colon].Trim();
            var value = rawLine[(colon + 1)..].Trim();
            var lname = name.ToLowerInvariant();

            string? token = null;
            if (lname == "authorization")
            {
                var sp = value.IndexOf(' ');
                if (sp > 0)
                {
                    var scheme = value[..sp].ToLowerInvariant();
                    if (scheme is "bearer" or "token") token = value[(sp + 1)..];
                }
            }
            else if (lname == "x-api-key" || lname.EndsWith("-api-key", StringComparison.Ordinal) || lname == "api-key")
            {
                token = value;
            }
            if (string.IsNullOrEmpty(token)) continue;
            if (knownFakes.Contains(token!)) continue;

            // Heuristic: known secret prefixes are almost certainly real.
            string[] knownPrefixes =
            {
                "sk-ant-", "sk-", "ghp_", "ghu_", "ghs_", "gho_",
                "github_pat_", "glpat-", "xoxp-", "xoxb-", "AIza", "AKIA",
            };
            var lowerTok = token!.ToLowerInvariant();
            if (knownPrefixes.Any(p => lowerTok.StartsWith(p.ToLowerInvariant(), StringComparison.Ordinal)))
            {
                leaks.Add(new LeakReport(name, Preview(token), LeakSuspicionKind.KnownPrefix));
                continue;
            }
            if (token.Length >= 20)
            {
                leaks.Add(new LeakReport(name, Preview(token), LeakSuspicionKind.OpaqueToken));
            }
        }
        return leaks;
    }

    /// <summary>
    /// Patch the Content-Length header in a CRLF-delimited HTTP header
    /// block. Idempotent — adds a header when none was present.
    /// </summary>
    internal static string ReplaceContentLength(string headerStr, int newLength)
    {
        var lines = headerStr.Split("\r\n").ToList();
        var saw = false;
        for (var i = 0; i < lines.Count; i++)
        {
            if (lines[i].StartsWith("content-length:", StringComparison.OrdinalIgnoreCase))
            {
                lines[i] = "Content-Length: " + newLength;
                saw = true;
            }
        }
        if (!saw)
        {
            // Insert before the trailing empty line so we don't push the
            // header/body delimiter.
            if (lines.Count > 0 && lines[^1].Length == 0)
            {
                lines.Insert(lines.Count - 1, "Content-Length: " + newLength);
            }
            else
            {
                lines.Add("Content-Length: " + newLength);
            }
        }
        return string.Join("\r\n", lines);
    }

    internal static string Preview(string s)
    {
        if (s.Length <= 8) return "***";
        return string.Concat(s.AsSpan(0, 4), "…", s.AsSpan(s.Length - 4, 4));
    }

    // -- byte search + replace helpers ---------------------------------

    private static int IndexOf(byte[] haystack, byte[] needle)
    {
        if (needle.Length == 0 || haystack.Length < needle.Length) return -1;
        for (var i = 0; i <= haystack.Length - needle.Length; i++)
        {
            var ok = true;
            for (var j = 0; j < needle.Length; j++)
            {
                if (haystack[i + j] != needle[j]) { ok = false; break; }
            }
            if (ok) return i;
        }
        return -1;
    }

    private static byte[] ReplaceAll(byte[] haystack, byte[] needle, byte[] replacement, out int hits)
    {
        hits = 0;
        if (needle.Length == 0) return haystack;
        var output = new MemoryStream();
        var i = 0;
        while (i <= haystack.Length - needle.Length)
        {
            var match = true;
            for (var j = 0; j < needle.Length; j++)
            {
                if (haystack[i + j] != needle[j]) { match = false; break; }
            }
            if (match)
            {
                output.Write(replacement, 0, replacement.Length);
                i += needle.Length;
                hits++;
            }
            else
            {
                output.WriteByte(haystack[i]);
                i++;
            }
        }
        output.Write(haystack, i, haystack.Length - i);
        return output.ToArray();
    }
}

/// <summary>
/// Decouples the swapper from any particular consent UI. Production
/// implementation calls into the WinUI 3 shell; tests pass an
/// auto-allow / auto-deny stub.
/// </summary>
public interface IConsentBroker
{
    Task<bool> RequestConsentAsync(
        Guid profileId,
        string credentialId,
        string credentialDisplayName,
        string scopeHint,
        CancellationToken ct);
}

/// <summary>Trivial broker that always allows. Used by tests.</summary>
public sealed class AlwaysAllowConsentBroker : IConsentBroker
{
    public Task<bool> RequestConsentAsync(Guid profileId, string credentialId,
        string credentialDisplayName, string scopeHint, CancellationToken ct)
        => Task.FromResult(true);
}

/// <summary>Trivial broker that always denies. Used by tests.</summary>
public sealed class AlwaysDenyConsentBroker : IConsentBroker
{
    public Task<bool> RequestConsentAsync(Guid profileId, string credentialId,
        string credentialDisplayName, string scopeHint, CancellationToken ct)
        => Task.FromResult(false);
}
