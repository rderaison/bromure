// macos-source: Sources/AgentCoding/Mitm/OAuthRotationRewriter.swift @ d8b52768dec5
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Bromure.AC.Mitm.Swap;

namespace Bromure.AC.Mitm.OAuth;

/// <summary>Provider tag for OAuth-rotation handling.</summary>
public enum OAuthRotationProvider
{
    Claude,
    Codex,
}

/// <summary>
/// Result of an in-flight rewrite. <see cref="Bytes"/> is what gets
/// shipped down to the VM; <see cref="NewReals"/> carries the upstream's
/// freshly-issued real tokens (so the host can update its stored
/// defaults / template without re-parsing). Null = nothing rotated this
/// hop, response is being passed through unchanged.
/// </summary>
public sealed record OAuthRotationResult(byte[] Bytes, StoredOAuthTokens? NewReals);

public sealed record StoredOAuthTokens(string AccessToken, string RefreshToken, string? IdToken);

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/OAuthRotationRewriter.swift</c>.
/// Response-body rewriter for OAuth <c>/oauth/token</c> endpoints.
///
/// <para>Both Anthropic and OpenAI rotate the refresh token on every
/// refresh: a <c>POST /oauth/token</c> returns JSON with fresh
/// <c>access_token</c> + <c>refresh_token</c> (+ <c>id_token</c> for
/// Codex). If we let those reach the VM verbatim, the on-disk write
/// would clobber the fakes we put there during initial swap, and the
/// next request would carry the real token — defeating the whole
/// point. This rewriter sits on the host's response path: parses the
/// JSON, mints fresh fakes, registers the new fake↔real pairs with the
/// <see cref="TokenSwapper"/>, and substitutes the fakes into the
/// response body before it reaches TLS.</para>
/// </summary>
public static class OAuthRotationRewriter
{
    private static readonly byte[] HeaderEnd = "\r\n\r\n"u8.ToArray();

    public static OAuthRotationProvider? ProviderFor(string host, string path)
    {
        var h = host.ToLowerInvariant();
        if ((h == "console.anthropic.com" || h.EndsWith(".anthropic.com", StringComparison.Ordinal))
            && path.Contains("/oauth/token", StringComparison.Ordinal))
        {
            return OAuthRotationProvider.Claude;
        }
        if ((h == "auth.openai.com" || h == "chatgpt.com"
             || h.EndsWith(".chatgpt.com", StringComparison.Ordinal)
             || h.EndsWith(".openai.com", StringComparison.Ordinal))
            && path.Contains("/oauth/token", StringComparison.Ordinal))
        {
            return OAuthRotationProvider.Codex;
        }
        return null;
    }

    public static bool IsOAuthTokenEndpoint(string host, string path) =>
        ProviderFor(host, path) is not null;

    public static OAuthRotationResult Rewrite(byte[] raw, OAuthRotationProvider provider,
        Guid profileId, TokenSwapper swapper)
    {
        return provider switch
        {
            OAuthRotationProvider.Claude => RewriteClaude(raw, profileId, swapper),
            OAuthRotationProvider.Codex => RewriteCodex(raw, profileId, swapper),
            _ => new OAuthRotationResult(raw, null),
        };
    }

    private static OAuthRotationResult RewriteClaude(byte[] raw, Guid profileId, TokenSwapper swapper)
    {
        if (!TrySplit(raw, out var headerBytes, out var bodyBytes))
            return new OAuthRotationResult(raw, null);
        if (bodyBytes.Length == 0) return new OAuthRotationResult(raw, null);

        // Decompress the body if upstream applied Content-Encoding.
        // Anthropic sometimes serves the OAuth refresh response gzipped;
        // skipping this step would have us regex-fail on opaque bytes
        // and silently no-op rotation.
        var encoding = ParseContentEncoding(headerBytes);
        var parseable = TryDecompress(bodyBytes, encoding);
        if (parseable is null) return new OAuthRotationResult(raw, null);

        JsonNode? root;
        try { root = JsonNode.Parse(parseable); }
        catch (JsonException) { return new OAuthRotationResult(raw, null); }
        if (root is not JsonObject json) return new OAuthRotationResult(raw, null);

        var realAccess = json["access_token"]?.GetValue<string>();
        var realRefresh = json["refresh_token"]?.GetValue<string>();
        if (realAccess is null || realRefresh is null) return new OAuthRotationResult(raw, null);
        if (!realAccess.StartsWith("sk-ant-oat01-", StringComparison.Ordinal)) return new OAuthRotationResult(raw, null);
        if (!realRefresh.StartsWith("sk-ant-ort01-", StringComparison.Ordinal)) return new OAuthRotationResult(raw, null);
        if (realAccess.StartsWith("sk-ant-oat01-brm-", StringComparison.Ordinal)) return new OAuthRotationResult(raw, null);
        if (realRefresh.StartsWith("sk-ant-ort01-brm-", StringComparison.Ordinal)) return new OAuthRotationResult(raw, null);

        var saltAccess = Encoding.UTF8.GetBytes($"anthropic-oauth-access:{profileId:D}");
        var saltRefresh = Encoding.UTF8.GetBytes($"anthropic-oauth-refresh:{profileId:D}");
        var fakeAccess = SessionTokenPlan.DeriveFake("sk-ant-oat01-brm-", realAccess, saltAccess, realAccess.Length);
        var fakeRefresh = SessionTokenPlan.DeriveFake("sk-ant-ort01-brm-", realRefresh, saltRefresh, realRefresh.Length);

        // acceptSiblings: true for parity with the initial seed/consent
        // path — these tokens stay scoped to first-party *.anthropic.com.
        swapper.AppendEntries(new[]
        {
            new TokenMap.Entry(fakeAccess, realAccess,
                Host: "api.anthropic.com",
                Header: EntryHeader.Authorization,
                AcceptSiblings: true),
            new TokenMap.Entry(fakeRefresh, realRefresh,
                Host: "console.anthropic.com",
                Header: EntryHeader.Authorization,
                Body: true,
                AcceptSiblings: true),
        }, profileId);

        json["access_token"] = fakeAccess;
        json["refresh_token"] = fakeRefresh;
        var rewritten = Encoding.UTF8.GetBytes(json.ToJsonString());
        return new OAuthRotationResult(
            Reassemble(headerBytes, rewritten),
            new StoredOAuthTokens(realAccess, realRefresh, IdToken: null));
    }

    private static OAuthRotationResult RewriteCodex(byte[] raw, Guid profileId, TokenSwapper swapper)
    {
        if (!TrySplit(raw, out var headerBytes, out var bodyBytes))
            return new OAuthRotationResult(raw, null);
        if (bodyBytes.Length == 0) return new OAuthRotationResult(raw, null);

        var encoding = ParseContentEncoding(headerBytes);
        var parseable = TryDecompress(bodyBytes, encoding);
        if (parseable is null) return new OAuthRotationResult(raw, null);

        JsonNode? root;
        try { root = JsonNode.Parse(parseable); }
        catch (JsonException) { return new OAuthRotationResult(raw, null); }
        if (root is not JsonObject json) return new OAuthRotationResult(raw, null);

        var realAccess = json["access_token"]?.GetValue<string>();
        var realRefresh = json["refresh_token"]?.GetValue<string>();
        if (realAccess is null || realRefresh is null) return new OAuthRotationResult(raw, null);
        if (!realAccess.StartsWith("eyJ", StringComparison.Ordinal)) return new OAuthRotationResult(raw, null);
        if (SubscriptionFakeMint.IsJwtFake(realAccess)) return new OAuthRotationResult(raw, null);
        var realId = json["id_token"]?.GetValue<string>();

        var saltAccess = Encoding.UTF8.GetBytes($"codex-oauth-access:{profileId:D}");
        var saltRefresh = Encoding.UTF8.GetBytes($"codex-oauth-refresh:{profileId:D}");
        var saltId = Encoding.UTF8.GetBytes($"codex-oauth-id:{profileId:D}");

        var fakeAccess = SubscriptionFakeMint.MintJwtFake(realAccess, saltAccess);
        if (fakeAccess is null) return new OAuthRotationResult(raw, null);
        var fakeRefresh = SubscriptionFakeMint.MintCodexRefreshFake(realRefresh, saltRefresh);

        string? fakeId = null;
        if (realId is not null && realId.StartsWith("eyJ", StringComparison.Ordinal)
            && !SubscriptionFakeMint.IsJwtFake(realId))
        {
            fakeId = SubscriptionFakeMint.MintJwtFake(realId, saltId);
        }

        var entries = new List<TokenMap.Entry>
        {
            new(fakeAccess, realAccess, Host: "chatgpt.com",
                Header: EntryHeader.Authorization, AcceptSiblings: true),
            new(fakeAccess, realAccess, Host: "api.openai.com",
                Header: EntryHeader.Authorization, AcceptSiblings: true),
            new(fakeRefresh, realRefresh, Host: "auth.openai.com",
                Header: EntryHeader.Authorization, Body: true, AcceptSiblings: true),
            new(fakeRefresh, realRefresh, Host: "chatgpt.com",
                Header: EntryHeader.Authorization, Body: true, AcceptSiblings: true),
        };
        if (realId is not null && fakeId is not null)
        {
            entries.Add(new TokenMap.Entry(fakeId, realId, Host: "chatgpt.com",
                Header: EntryHeader.Authorization, AcceptSiblings: true));
            entries.Add(new TokenMap.Entry(fakeId, realId, Host: "auth.openai.com",
                Header: EntryHeader.Authorization, AcceptSiblings: true));
        }
        swapper.AppendEntries(entries, profileId);

        json["access_token"] = fakeAccess;
        json["refresh_token"] = fakeRefresh;
        if (realId is not null && fakeId is not null && json.ContainsKey("id_token"))
        {
            json["id_token"] = fakeId;
        }
        var rewritten = Encoding.UTF8.GetBytes(json.ToJsonString());
        return new OAuthRotationResult(
            Reassemble(headerBytes, rewritten),
            new StoredOAuthTokens(realAccess, realRefresh, realId));
    }

    private static bool TrySplit(byte[] raw, out byte[] header, out byte[] body)
    {
        header = Array.Empty<byte>();
        body = Array.Empty<byte>();
        var idx = IndexOf(raw, HeaderEnd);
        if (idx < 0) return false;
        header = raw[..idx];
        body = raw[(idx + 4)..];
        return true;
    }

    private static byte[] Reassemble(byte[] headerBytes, byte[] body)
    {
        // We write the rewritten body uncompressed, so drop any
        // Content-Encoding header. Update Content-Length to the new
        // body size. Both header munges happen in a single pass.
        var headerStr = Encoding.ASCII.GetString(headerBytes);
        var lines = headerStr.Split("\r\n").ToList();
        var sawCl = false;
        for (var i = lines.Count - 1; i >= 0; i--)
        {
            if (lines[i].StartsWith("content-length:", StringComparison.OrdinalIgnoreCase))
            {
                lines[i] = "Content-Length: " + body.Length;
                sawCl = true;
            }
            else if (lines[i].StartsWith("content-encoding:", StringComparison.OrdinalIgnoreCase))
            {
                lines.RemoveAt(i);
            }
        }
        var patchedHead = sawCl
            ? Encoding.ASCII.GetBytes(string.Join("\r\n", lines))
            : headerBytes;

        var output = new byte[patchedHead.Length + 4 + body.Length];
        Buffer.BlockCopy(patchedHead, 0, output, 0, patchedHead.Length);
        Buffer.BlockCopy(HeaderEnd, 0, output, patchedHead.Length, 4);
        Buffer.BlockCopy(body, 0, output, patchedHead.Length + 4, body.Length);
        return output;
    }

    /// <summary>
    /// Read the response's <c>Content-Encoding</c> header (case-insensitive,
    /// last-wins). Empty string when absent or identity-encoded.
    /// </summary>
    private static string ParseContentEncoding(byte[] headerBytes)
    {
        var headerStr = Encoding.ASCII.GetString(headerBytes);
        foreach (var raw in headerStr.Split("\r\n"))
        {
            if (!raw.StartsWith("content-encoding:", StringComparison.OrdinalIgnoreCase)) continue;
            var v = raw.Substring("content-encoding:".Length).Trim().ToLowerInvariant();
            if (v == "identity") return "";
            return v;
        }
        return "";
    }

    /// <summary>
    /// Decompress <paramref name="body"/> according to
    /// <paramref name="encoding"/> (gzip / deflate / br / empty).
    /// Returns the original bytes when no encoding applies, or null
    /// when decompression fails — caller treats null as "give up".
    /// </summary>
    private static byte[]? TryDecompress(byte[] body, string encoding)
    {
        if (string.IsNullOrEmpty(encoding)) return body;
        try
        {
            using var input = new MemoryStream(body);
            using var output = new MemoryStream();
            switch (encoding)
            {
                case "gzip":
                    {
                        using var gz = new System.IO.Compression.GZipStream(input,
                            System.IO.Compression.CompressionMode.Decompress);
                        gz.CopyTo(output);
                        break;
                    }
                case "deflate":
                    {
                        using var df = new System.IO.Compression.DeflateStream(input,
                            System.IO.Compression.CompressionMode.Decompress);
                        df.CopyTo(output);
                        break;
                    }
                case "br":
                    {
                        using var br = new System.IO.Compression.BrotliStream(input,
                            System.IO.Compression.CompressionMode.Decompress);
                        br.CopyTo(output);
                        break;
                    }
                default:
                    // Unknown encoding (e.g., "zstd" — not in BCL).
                    // Better to bail than corrupt the body.
                    return null;
            }
            return output.ToArray();
        }
        catch (System.IO.InvalidDataException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    private static int IndexOf(byte[] haystack, byte[] needle)
    {
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
}
