import Foundation

/// Helpers for minting fake replacements for OAuth subscription
/// tokens that preserve the *structure* of the real value:
///
///   • JWT-shaped tokens (id_token / access_token in Codex)  →
///     keep the real header + payload segments, replace only the
///     signature with same-length pseudo-random chars carrying a
///     marker prefix. Codex CLI can still split on `.`, base64url-
///     decode the payload, and read claims; the cryptographic
///     signature only matters server-side, where the proxy swaps in
///     the real token before the request leaves the Mac.
///
///   • Opaque tokens with internal separators (refresh_token in
///     Codex: `rt_<a>.<b>`) → preserve the positions of `_`, `.`,
///     `-` and replace each alphanumeric run with deterministic
///     pseudo-random chars, embedding a marker so the agent and
///     wire-detector can identify our own fakes.
///
/// "Marker" strings are surfaced both in the agent's write-time
/// validator (it refuses anything that doesn't carry the marker —
/// a defense-in-depth check against a buggy host) and in the
/// proxy's `detectCodexAccessToken` (so we never re-prompt on a
/// fake that already swapped through).
enum SubscriptionFakeMint {
    /// Marker that goes at the start of a fake JWT signature.
    static let jwtSignatureMarker = "brm-cdX-sig"
    /// Marker embedded in a fake Codex refresh token.
    static let refreshMarker = "brm-cdX-rfs"

    /// Mint a fake JWT by keeping the header + payload from `real`
    /// verbatim and replacing the signature with same-length
    /// deterministic pseudo-random chars prefixed with
    /// `jwtSignatureMarker`.
    ///
    /// Returns nil if `real` isn't shaped like a JWT (3 segments
    /// joined by `.`). Caller should fall back to passing the real
    /// token through unchanged in that case — at worst we leak the
    /// access bearer to the VM, which is the pre-existing behavior.
    static func mintJWTFake(realJWT: String, salt: Data) -> String? {
        let parts = realJWT.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let realSig = String(parts[2])
        let fakeSig = SessionTokenPlan.deriveFake(
            prefix: jwtSignatureMarker,
            real: realSig,
            salt: salt,
            targetLength: realSig.count)
        return "\(parts[0]).\(parts[1]).\(fakeSig)"
    }

    /// Returns true if `tok` looks like one of our JWT fakes — i.e.
    /// its signature segment starts with `jwtSignatureMarker`. Used
    /// by `TokenSwapper.detectCodexAccessToken` to avoid re-prompting
    /// on tokens we already swapped through.
    static func isJWTFake(_ tok: String) -> Bool {
        let parts = tok.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return String(parts[2]).hasPrefix(jwtSignatureMarker)
    }

    /// Mint a fake Codex refresh token. Real shape is
    /// `rt_<43chars>.<43chars>`; we preserve the literal `rt_` prefix
    /// and the `.` at its original position, embed `refreshMarker`
    /// after the prefix, then fill the remaining alphanumeric slots
    /// with deterministic pseudo-random chars from a base64url-safe
    /// alphabet so the resulting string still looks plausible.
    ///
    /// Length-preserving: returns a string of the same length as
    /// `real`. If `real` is shorter than the marker + prefix, we
    /// fall back to a non-marker derive (length-preserved still).
    static func mintCodexRefreshFake(real: String, salt: Data) -> String {
        return SessionTokenPlan.deriveFake(
            prefix: "rt_\(refreshMarker)-",
            real: real,
            salt: salt,
            targetLength: real.count)
    }

    /// Returns true if `tok` looks like one of our Codex refresh fakes.
    static func isCodexRefreshFake(_ tok: String) -> Bool {
        return tok.hasPrefix("rt_\(refreshMarker)-")
    }
}
