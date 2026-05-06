// macos-source: Sources/AgentCoding/Mitm/SubscriptionFakeMint.swift @ d3fa6f532b8a
namespace Bromure.AC.Mitm.Swap;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/SubscriptionFakeMint.swift</c>.
/// Helpers for minting fake replacements for OAuth subscription tokens
/// that preserve the *structure* of the real value:
///
/// <list type="bullet">
///   <item>JWT-shaped tokens (<c>id_token</c> / <c>access_token</c> in
///   Codex) — keep the real header + payload segments, replace only the
///   signature with same-length pseudo-random chars carrying a marker
///   prefix. Codex CLI can still split on <c>.</c>, base64url-decode
///   the payload, and read claims; the cryptographic signature only
///   matters server-side, where the proxy swaps in the real token before
///   the request leaves the host.</item>
///   <item>Opaque tokens with internal separators (refresh_token in
///   Codex: <c>rt_&lt;a&gt;.&lt;b&gt;</c>) — preserve the positions of
///   <c>_</c>, <c>.</c>, <c>-</c> and replace each alphanumeric run with
///   deterministic pseudo-random chars, embedding a marker so the agent
///   and wire-detector can identify our own fakes.</item>
/// </list>
/// </summary>
public static class SubscriptionFakeMint
{
    /// <summary>Marker that goes at the start of a fake JWT signature.</summary>
    public const string JwtSignatureMarker = "brm-cdX-sig";

    /// <summary>Marker embedded in a fake Codex refresh token.</summary>
    public const string RefreshMarker = "brm-cdX-rfs";

    /// <summary>
    /// Mint a fake JWT by keeping the header + payload from <paramref name="realJwt"/>
    /// verbatim and replacing the signature with same-length deterministic
    /// pseudo-random chars prefixed with <see cref="JwtSignatureMarker"/>.
    ///
    /// Returns null if <paramref name="realJwt"/> isn't shaped like a JWT.
    /// Caller should fall back to passing the real token through unchanged.
    /// </summary>
    public static string? MintJwtFake(string realJwt, byte[] salt)
    {
        var parts = realJwt.Split('.');
        if (parts.Length != 3) return null;
        var realSig = parts[2];
        var fakeSig = SessionTokenPlan.DeriveFake(
            prefix: JwtSignatureMarker,
            real: realSig,
            salt: salt,
            targetLength: realSig.Length);
        return $"{parts[0]}.{parts[1]}.{fakeSig}";
    }

    /// <summary>
    /// Returns true if <paramref name="tok"/> looks like one of our JWT
    /// fakes — i.e. its signature segment starts with
    /// <see cref="JwtSignatureMarker"/>.
    /// </summary>
    public static bool IsJwtFake(string tok)
    {
        var parts = tok.Split('.');
        return parts.Length == 3 && parts[2].StartsWith(JwtSignatureMarker, StringComparison.Ordinal);
    }

    /// <summary>
    /// Mint a fake Codex refresh token. Real shape is <c>rt_&lt;43chars&gt;.&lt;43chars&gt;</c>.
    /// Length-preserving.
    /// </summary>
    public static string MintCodexRefreshFake(string real, byte[] salt) =>
        SessionTokenPlan.DeriveFake(
            prefix: $"rt_{RefreshMarker}-",
            real: real,
            salt: salt,
            targetLength: real.Length);

    public static bool IsCodexRefreshFake(string tok) =>
        tok.StartsWith($"rt_{RefreshMarker}-", StringComparison.Ordinal);
}
