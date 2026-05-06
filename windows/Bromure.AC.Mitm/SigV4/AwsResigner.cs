// macos-source: Sources/AgentCoding/Mitm/AWSResigner.swift @ ef724e93cadc
using System.Text;
using Bromure.AC.Mitm.Aws;

namespace Bromure.AC.Mitm.SigV4;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/AWSResigner.swift</c>.
/// Detects AWS-bound HTTPS requests, strips the guest's signature, and
/// re-signs with credentials that only ever live in this process's
/// address space.
///
/// <para><b>Threat model.</b> The AWS SDK in the VM signs every request
/// with a fake secret vended by <see cref="IAwsCredentialServer"/>. The
/// signature is bound to fail. The resigner intercepts the proxied
/// request, replaces the guest's <c>Authorization</c> (and adds the real
/// <c>X-Amz-Security-Token</c> when the profile carries STS material),
/// and recomputes the SigV4 signature using the real secret. If a
/// request bypasses the proxy, AWS rejects it with
/// <c>InvalidSignatureException</c> — fail-closed.</para>
/// </summary>
public sealed class AwsResigner
{
    private readonly IAwsCredentialServer _credServer;

    public AwsResigner(IAwsCredentialServer credServer) => _credServer = credServer;

    public abstract record Outcome
    {
        public sealed record Unchanged : Outcome;
        public sealed record Resigned(byte[] Bytes) : Outcome;
        public sealed record Denied(byte[] Response) : Outcome;
        public sealed record Failed(string Reason, byte[] Response) : Outcome;
    }

    /// <summary>Match <c>*.amazonaws.com</c> and <c>*.amazonaws.com.cn</c>.</summary>
    public static bool IsAwsHost(string host)
    {
        var h = host.ToLowerInvariant();
        return h is "amazonaws.com" or "amazonaws.com.cn"
            || h.EndsWith(".amazonaws.com", StringComparison.Ordinal)
            || h.EndsWith(".amazonaws.com.cn", StringComparison.Ordinal);
    }

    public async Task<Outcome> ResignAsync(byte[] rawRequest, string host, Guid profileId,
        CancellationToken ct = default)
    {
        if (!IsAwsHost(host)) return new Outcome.Unchanged();
        if (!ParsedHttpRequest.TryParse(rawRequest, out var parsed) || parsed is null)
        {
            return new Outcome.Unchanged();
        }
        var oldAuth = parsed.HeaderValue("Authorization");
        if (oldAuth is null || !oldAuth.StartsWith("AWS4-HMAC-SHA256", StringComparison.Ordinal))
        {
            return new Outcome.Unchanged();
        }
        var scope = ParseScope(oldAuth);
        if (scope is null)
        {
            return new Outcome.Failed("malformed AWS Authorization header",
                ErrorResponse(502, "Bad Gateway",
                    "bromure: could not parse AWS Authorization\n"));
        }

        // STREAMING-AWS4-HMAC-SHA256-PAYLOAD: chunk-by-chunk signing
        // can't be reproduced without the original secret (each chunk's
        // signature chains off the previous). Bail with a clear error.
        var originalContentSha = parsed.HeaderValue("X-Amz-Content-SHA256") ?? "";
        if (originalContentSha == "STREAMING-AWS4-HMAC-SHA256-PAYLOAD")
        {
            return new Outcome.Failed("streaming chunked uploads not supported",
                ErrorResponse(501, "Not Implemented",
                    "bromure: aws-chunked uploads not supported by the host signer\n"));
        }

        var mat = await _credServer.SigningMaterialAsync(
            profileId,
            scopeHint: "for any AWS API call (SigV4 signing on the host)",
            ct).ConfigureAwait(false);
        SigV4Signer.Credentials creds;
        switch (mat)
        {
            case SigningMaterial.Material m:
                creds = m.Credentials;
                break;
            case SigningMaterial.Denied:
                return new Outcome.Denied(ErrorResponse(403, "Forbidden",
                    "bromure: AWS API call denied by user consent\n"));
            case SigningMaterial.Missing:
                return new Outcome.Unchanged();
            default:
                return new Outcome.Unchanged();
        }

        // Drop headers we override / regenerate.
        var keep = new List<(string Name, string Value)>();
        foreach (var (n, v) in parsed.Headers)
        {
            switch (n.ToLowerInvariant())
            {
                case "authorization":
                case "x-amz-date":
                case "x-amz-content-sha256":
                case "x-amz-security-token":
                case "host":
                case "content-length":
                case "connection":
                case "proxy-connection":
                case "transfer-encoding":
                case "keep-alive":
                case "te":
                case "upgrade":
                case "proxy-authorization":
                    continue;
                default:
                    keep.Add((n, v));
                    break;
            }
        }

        var now = DateTime.UtcNow;
        var amzDate = SigV4Signer.IsoBasic(now);
        var dateOnly = amzDate[..8];
        var unsignedPayload = originalContentSha == "UNSIGNED-PAYLOAD";
        var payloadHash = unsignedPayload
            ? "UNSIGNED-PAYLOAD"
            : SigV4Signer.HexSha256(parsed.Body);

        // Append generated headers. Order doesn't matter for canonicalisation
        // (signer sorts) but does for wire consistency.
        var signed = new List<(string Name, string Value)>(keep)
        {
            ("Host", host),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Content-SHA256", payloadHash),
        };
        if (!string.IsNullOrEmpty(creds.SessionToken))
        {
            signed.Add(("X-Amz-Security-Token", creds.SessionToken!));
        }

        var req = new SigV4Signer.Request(
            Method: parsed.Method,
            Path: string.IsNullOrEmpty(parsed.Path) ? "/" : parsed.Path,
            Query: parsed.Query,
            Headers: signed,
            Body: parsed.Body);

        var output = SigV4Signer.Sign(
            request: req,
            credentials: creds,
            scope: new SigV4Signer.Scope(dateOnly, scope.Value.Region, scope.Value.Service),
            date: now,
            unsignedPayload: unsignedPayload);

        // Drop our synthetic Host before reassembly; URLSession-equivalent
        // will derive Host from the URL on the wire.
        var onWire = signed.Where(h => !string.Equals(h.Name, "Host", StringComparison.OrdinalIgnoreCase))
            .Append(("Authorization", output.Authorization))
            .ToList();

        return new Outcome.Resigned(Assemble(parsed.RequestLine, onWire, parsed.Body));
    }

    /// <summary>
    /// Extract <c>(date, region, service)</c> from a SigV4 Authorization
    /// header. Format:
    /// <c>AWS4-HMAC-SHA256 Credential=AKID/DATE/REGION/SERVICE/aws4_request, ...</c>
    /// </summary>
    public static (string Date, string Region, string Service)? ParseScope(string auth)
    {
        const string marker = "Credential=";
        var idx = auth.IndexOf(marker, StringComparison.Ordinal);
        if (idx < 0) return null;
        var after = auth[(idx + marker.Length)..];
        var end = 0;
        while (end < after.Length && after[end] != ',' && !char.IsWhiteSpace(after[end])) end++;
        var parts = after[..end].Split('/');
        if (parts.Length != 5 || parts[4] != "aws4_request") return null;
        return (parts[1], parts[2], parts[3]);
    }

    public static string MaskAccessKey(string akid)
    {
        if (akid.Length <= 6) return "***";
        return string.Concat(akid.AsSpan(0, 4), "…", akid.AsSpan(akid.Length - 4, 4));
    }

    private static byte[] Assemble(string requestLine, IReadOnlyList<(string Name, string Value)> headers,
        ReadOnlyMemory<byte> body)
    {
        var sb = new StringBuilder();
        sb.Append(requestLine).Append("\r\n");
        foreach (var (n, v) in headers) sb.Append(n).Append(": ").Append(v).Append("\r\n");
        sb.Append("\r\n");
        var head = Encoding.ASCII.GetBytes(sb.ToString());
        var output = new byte[head.Length + body.Length];
        Buffer.BlockCopy(head, 0, output, 0, head.Length);
        body.Span.CopyTo(output.AsSpan(head.Length));
        return output;
    }

    private static byte[] ErrorResponse(int status, string reason, string body)
    {
        var bodyBytes = Encoding.UTF8.GetBytes(body);
        var head = $"HTTP/1.1 {status} {reason}\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + $"Content-Length: {bodyBytes.Length}\r\n"
            + "Connection: close\r\n"
            + "\r\n";
        var headBytes = Encoding.ASCII.GetBytes(head);
        var output = new byte[headBytes.Length + bodyBytes.Length];
        Buffer.BlockCopy(headBytes, 0, output, 0, headBytes.Length);
        Buffer.BlockCopy(bodyBytes, 0, output, headBytes.Length, bodyBytes.Length);
        return output;
    }
}

/// <summary>
/// Tiny request parser sized for the resigner's needs. No validation —
/// the proxy's already accepted these bytes from the SDK and we trust
/// the SDK's framing.
/// </summary>
public sealed record ParsedHttpRequest(
    string RequestLine,
    string Method,
    string Path,
    string Query,
    IReadOnlyList<(string Name, string Value)> Headers,
    byte[] Body)
{
    public string? HeaderValue(string name)
    {
        foreach (var (n, v) in Headers)
        {
            if (string.Equals(n, name, StringComparison.OrdinalIgnoreCase)) return v;
        }
        return null;
    }

    public static bool TryParse(byte[] rawRequest, out ParsedHttpRequest? parsed)
    {
        parsed = null;
        var headerEndIdx = IndexOf(rawRequest, "\r\n\r\n"u8);
        if (headerEndIdx < 0) return false;
        var headerStr = Encoding.ASCII.GetString(rawRequest, 0, headerEndIdx);
        var bodyStart = headerEndIdx + 4;
        var body = new byte[rawRequest.Length - bodyStart];
        Buffer.BlockCopy(rawRequest, bodyStart, body, 0, body.Length);

        var lines = headerStr.Split("\r\n");
        if (lines.Length == 0) return false;
        var first = lines[0];
        var parts = first.Split(' ');
        if (parts.Length < 2) return false;
        var method = parts[0];
        var target = parts[1];
        string path, query;
        var q = target.IndexOf('?');
        if (q >= 0) { path = target[..q]; query = target[(q + 1)..]; }
        else { path = target; query = ""; }

        var headers = new List<(string, string)>();
        for (var i = 1; i < lines.Length; i++)
        {
            var ln = lines[i];
            if (ln.Length == 0) continue;
            var colon = ln.IndexOf(':');
            if (colon < 0) continue;
            var n = ln[..colon].Trim();
            var v = ln[(colon + 1)..].Trim();
            headers.Add((n, v));
        }

        parsed = new ParsedHttpRequest(first, method, path, query, headers, body);
        return true;
    }

    private static int IndexOf(byte[] haystack, ReadOnlySpan<byte> needle)
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
