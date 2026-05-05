namespace Bromure.AC.Mitm.Swap;

/// <summary>
/// Direct port of the data layer of <c>TokenSwap.swift</c>.
/// Per-profile fake→real map. Built each session from the profile's
/// saved tools + git creds + manual entries. Lives only in memory on
/// the host — the VM never sees the real values.
/// </summary>
public sealed class TokenMap
{
    public IReadOnlyList<Entry> Entries { get; }

    public TokenMap(IReadOnlyList<Entry> entries) => Entries = entries;

    public bool IsEmpty => Entries.Count == 0;

    public sealed record Entry(
        string Fake,
        string Real,
        /// <summary>
        /// Optional host scope. Null/empty = swap on any host.
        /// <para><b>Matching is exact-or-subdomain</b>: <c>host == scope</c>
        /// OR <c>host.EndsWith("." + scope)</c>. NOT substring — substring
        /// matching would be a security hole, since a malicious VM-internal
        /// client could <c>CONNECT openai.com.evil.com:443</c> and the
        /// proxy would happily swap the real OpenAI key. Case-insensitive.</para>
        /// </summary>
        string? Host = null,
        EntryHeader Header = EntryHeader.Authorization,
        /// <summary>
        /// When true, the swapper also sweeps the request <i>body</i> for
        /// <see cref="Fake"/> (in addition to the header section). Off by
        /// default — keeps multipart/binary uploads untouched. Turn on
        /// for OAuth refresh tokens that ride in JSON bodies.
        /// </summary>
        bool Body = false,
        /// <summary>
        /// When true, the swap also fires on hosts that share the
        /// registered domain with <see cref="Host"/> (cookie-style
        /// sibling match). Off by default; opt in only for first-party
        /// providers fanning a single auth credential across multiple
        /// subdomains. AWS / kubeconfigs / manual stay strict so a token
        /// minted for s3 can't be injected into a lambda call.
        /// </summary>
        bool AcceptSiblings = false,
        string? ConsentCredentialId = null,
        string? ConsentDisplayName = null);
}

public enum EntryHeader
{
    /// <summary>Authorization: Bearer &lt;token&gt;</summary>
    Authorization,
    /// <summary>x-api-key: &lt;token&gt;</summary>
    XApiKey,
    /// <summary>x-api-key: &lt;token&gt; (Anthropic-shaped).</summary>
    AnthropicApiKey,
    /// <summary>Authorization: Bearer &lt;token&gt; (OpenAI-shaped).</summary>
    OpenAiApiKey,
}

public sealed record SwapResult(byte[] Modified, IReadOnlyList<SwapRecord> Swaps);

public sealed record SwapRecord(string FakePreview, string RealPreview, string Host);

public sealed record CompromiseEvent(
    Guid ProfileId,
    string ObservedHost,
    IReadOnlyList<LeakReport> Leaks,
    DateTimeOffset Timestamp);

public sealed record LeakReport(string Header, string ValuePreview, LeakSuspicionKind Suspicion);

public enum LeakSuspicionKind
{
    KnownPrefix,
    OpaqueToken,
}
