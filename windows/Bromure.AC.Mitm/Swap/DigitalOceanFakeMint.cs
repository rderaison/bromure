// macos-source: Sources/AgentCoding/Mitm/SessionTokenPlan.swift @ a663f52551c3
using System.Text;

namespace Bromure.AC.Mitm.Swap;

/// <summary>
/// HKDF-derived fake for a DigitalOcean Personal Access Token.
///
/// <para><b>Wire shape that matters.</b> Real DO PATs are
/// <c>dop_v1_</c> + 64 hex chars. <c>doctl</c>, terraform-provider-
/// digitalocean, and the <c>doctl registry login</c> path all
/// validate this shape before they even send the request, so the
/// fake must match it byte-for-byte.</para>
///
/// <para>The Docker-registry login path is the audit-flagged corner
/// case (03 #2): <c>doctl registry login</c> turns the PAT into HTTP
/// Basic credentials with the wire form
/// <c>Authorization: Basic base64("&lt;token&gt;:&lt;token&gt;")</c>.
/// Naked-token swap can't see through the base64 transform, so we
/// register a SECOND swap entry for the encoded pair scoped to the
/// same digitalocean.com family.</para>
/// </summary>
public static class DigitalOceanFakeMint
{
    /// <summary>
    /// Derive the fake PAT for <paramref name="realPat"/>. Returns
    /// null when the real value is empty.
    ///
    /// <para>HKDF-SHA256 over (real, salt) → 64 hex chars, prefixed
    /// with <c>dop_v1_</c>. Same (real, salt) always yields the same
    /// fake — clients caching fingerprints don't see the value
    /// rotate session-to-session.</para>
    /// </summary>
    public static string? MintFake(string realPat, byte[] salt)
    {
        if (string.IsNullOrWhiteSpace(realPat)) return null;
        const string prefix = "dop_v1_";
        // Total length 71 (7-char prefix + 64-hex suffix). The mint
        // helper in SessionTokenPlan emits base62; we re-derive
        // here so we can lock to the all-lowercase-hex alphabet DO
        // PATs use.
        var derivedB62 = SessionTokenPlan.DeriveFake(
            prefix: prefix,
            real: realPat,
            salt: salt,
            targetLength: 71);
        // Re-bucket each base62 char into [0-9a-f] so the wire shape
        // is a valid DO PAT. The hash output stays uniform-ish.
        var sb = new StringBuilder(derivedB62.Length);
        foreach (var c in derivedB62)
        {
            if (c == '_' || c == '-' || (c >= '0' && c <= '9')
                || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
            {
                if (sb.Length < prefix.Length)
                {
                    // Preserve the prefix verbatim.
                    sb.Append(c);
                    continue;
                }
                sb.Append("0123456789abcdef"[(byte)c & 0x0F]);
            }
        }
        return sb.ToString();
    }

    /// <summary>
    /// Build the (fake, real) swap entries to register with
    /// <see cref="TokenSwapper.AppendEntries"/>. Two entries:
    /// the naked token and the base64("token:token") Basic-auth
    /// form. Both scoped to <c>digitalocean.com</c> so subdomains
    /// (registry.digitalocean.com, api.digitalocean.com) match
    /// without listing each explicitly.
    /// </summary>
    public static IReadOnlyList<TokenMap.Entry> BuildSwapEntries(
        string realPat, string fakePat,
        string? consentCredentialId = null)
    {
        var realPair = Convert.ToBase64String(Encoding.ASCII.GetBytes(realPat + ":" + realPat));
        var fakePair = Convert.ToBase64String(Encoding.ASCII.GetBytes(fakePat + ":" + fakePat));
        return new[]
        {
            new TokenMap.Entry(
                Fake: fakePat,
                Real: realPat,
                Host: "digitalocean.com",
                Header: EntryHeader.Authorization,
                Body: true,             // doctl puts PAT in JSON body for some calls
                AcceptSiblings: true,
                ConsentCredentialId: consentCredentialId,
                ConsentDisplayName: consentCredentialId is null ? null : "DigitalOcean PAT"),
            new TokenMap.Entry(
                Fake: fakePair,
                Real: realPair,
                Host: "digitalocean.com",
                Header: EntryHeader.Authorization,  // Basic <base64> lives in Authorization
                Body: true,
                AcceptSiblings: true,
                ConsentCredentialId: consentCredentialId,
                ConsentDisplayName: consentCredentialId is null ? null : "DigitalOcean PAT (Basic-auth pair)"),
        };
    }
}
