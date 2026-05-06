// macos-source: Sources/AgentCoding/Mitm/SigV4Signer.swift @ d9041f7dd0b1
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Bromure.AC.Mitm.SigV4;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/SigV4Signer.swift</c>.
/// Pure SigV4 signing primitives — no HTTP I/O. <c>AwsResigner</c> calls
/// <see cref="Sign"/> to compute fresh signing material from credentials
/// that only ever live in this process's address space.
///
/// <para>References:
/// <list type="bullet">
///   <item>https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html</item>
///   <item>https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html</item>
/// </list>
/// </para>
///
/// The "get-vanilla" reference vector is reproduced step-by-step in the
/// trailing comments so the canonical-request shape, key-derivation
/// chain, and final signature can be checked by inspection. Mirrors the
/// vector cited in the macOS source.
/// </summary>
public static class SigV4Signer
{
    public sealed record Credentials(string AccessKeyId, string SecretAccessKey, string? SessionToken = null);

    public sealed record Scope(string Date, string Region, string Service)
    {
        public string CredentialScope => $"{Date}/{Region}/{Service}/aws4_request";
    }

    public sealed record Request(
        string Method,
        string Path,
        string Query,
        IReadOnlyList<(string Name, string Value)> Headers,
        ReadOnlyMemory<byte> Body);

    public sealed record SignedOutput(
        string Authorization,
        string PayloadHash,
        string AmzDate,
        string SignedHeaders);

    public static SignedOutput Sign(
        Request request,
        Credentials credentials,
        Scope scope,
        DateTime? date = null,
        bool unsignedPayload = false)
    {
        var amzDate = IsoBasic(date ?? DateTime.UtcNow);

        var payloadHash = unsignedPayload ? "UNSIGNED-PAYLOAD" : HexSha256(request.Body.Span);

        // Canonicalize headers. Values get whitespace-trimmed; runs of
        // internal whitespace outside of double-quoted strings are
        // collapsed to a single space. Names lowercased and sorted.
        var byName = new SortedDictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var (k, v) in request.Headers)
        {
            var key = k.ToLowerInvariant();
            if (!byName.TryGetValue(key, out var list))
            {
                list = new List<string>();
                byName[key] = list;
            }
            list.Add(CanonicalHeaderValue(v));
        }
        var sb = new StringBuilder();
        foreach (var (n, vs) in byName)
        {
            sb.Append(n).Append(':').Append(string.Join(',', vs)).Append('\n');
        }
        var canonicalHeaders = sb.ToString();
        var signedHeaders = string.Join(';', byName.Keys);

        var canonicalRequest = string.Join('\n',
            request.Method.ToUpperInvariant(),
            CanonicalPath(request.Path, scope.Service),
            CanonicalQueryString(request.Query),
            canonicalHeaders,
            signedHeaders,
            payloadHash);

        var stringToSign = string.Join('\n',
            "AWS4-HMAC-SHA256",
            amzDate,
            scope.CredentialScope,
            HexSha256(Encoding.UTF8.GetBytes(canonicalRequest)));

        var kSecret = Encoding.UTF8.GetBytes("AWS4" + credentials.SecretAccessKey);
        var kDate = Hmac(kSecret, Encoding.UTF8.GetBytes(scope.Date));
        var kRegion = Hmac(kDate, Encoding.UTF8.GetBytes(scope.Region));
        var kService = Hmac(kRegion, Encoding.UTF8.GetBytes(scope.Service));
        var kSigning = Hmac(kService, Encoding.UTF8.GetBytes("aws4_request"));

        var signature = ToHex(Hmac(kSigning, Encoding.UTF8.GetBytes(stringToSign)));

        var authorization = "AWS4-HMAC-SHA256 "
            + $"Credential={credentials.AccessKeyId}/{scope.CredentialScope}, "
            + $"SignedHeaders={signedHeaders}, "
            + $"Signature={signature}";

        return new SignedOutput(authorization, payloadHash, amzDate, signedHeaders);
    }

    public static string HexSha256(ReadOnlySpan<byte> data)
    {
        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(data, hash);
        return ToHex(hash);
    }

    private static byte[] Hmac(byte[] key, byte[] msg) => HMACSHA256.HashData(key, msg);

    private static string ToHex(ReadOnlySpan<byte> data)
    {
        var sb = new StringBuilder(data.Length * 2);
        foreach (var b in data) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
        return sb.ToString();
    }

    /// <summary><c>YYYYMMDDTHHMMSSZ</c> in UTC.</summary>
    public static string IsoBasic(DateTime date)
    {
        var d = date.Kind == DateTimeKind.Utc ? date : date.ToUniversalTime();
        return d.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Canonical path per SigV4. For most services the wire path is
    /// URI-encoded once for the canonical request (so a literal <c>:</c>
    /// becomes <c>%3A</c>, and a wire <c>%20</c> becomes <c>%2520</c>).
    /// S3 is the documented exception that passes the path through
    /// untouched.
    ///
    /// <para>Bedrock model IDs (<c>global.anthropic.claude-sonnet-4-5-…-v1:0</c>)
    /// always carry a <c>:</c>, which is exactly the kind of char this
    /// rule exists for — without re-encoding, every Bedrock call signs
    /// against a canonical that diverges from AWS's by one byte per
    /// <c>:</c> and AWS rejects with InvalidSignatureException.</para>
    /// </summary>
    public static string CanonicalPath(string path, string service)
    {
        if (string.IsNullOrEmpty(path)) return "/";
        if (string.Equals(service, "s3", StringComparison.OrdinalIgnoreCase)) return path;
        var parts = path.Split('/');
        var encoded = parts.Select(UriEncodeSegment);
        return string.Join('/', encoded);
    }

    /// <summary>
    /// Percent-encode every byte that isn't in RFC 3986 unreserved
    /// (<c>A-Z a-z 0-9 - . _ ~</c>). Encodes <c>%</c> itself, which
    /// produces SigV4's expected double-encoding when the SDK has
    /// already pre-encoded a path char on the wire.
    /// </summary>
    public static string UriEncodeSegment(string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        var sb = new StringBuilder(bytes.Length);
        foreach (var c in bytes)
        {
            var unreserved =
                (c >= 0x41 && c <= 0x5A) ||
                (c >= 0x61 && c <= 0x7A) ||
                (c >= 0x30 && c <= 0x39) ||
                c == 0x2D || c == 0x2E ||
                c == 0x5F || c == 0x7E;
            if (unreserved) sb.Append((char)c);
            else sb.AppendFormat(CultureInfo.InvariantCulture, "%{0:X2}", c);
        }
        return sb.ToString();
    }

    public static string CanonicalQueryString(string query)
    {
        if (string.IsNullOrEmpty(query)) return "";
        var pairs = query.Split('&').Select(p =>
        {
            var eq = p.IndexOf('=');
            if (eq < 0) return (Key: p, Value: "");
            return (Key: p[..eq], Value: p[(eq + 1)..]);
        }).ToList();
        pairs.Sort((a, b) =>
        {
            var c = string.CompareOrdinal(a.Key, b.Key);
            return c != 0 ? c : string.CompareOrdinal(a.Value, b.Value);
        });
        return string.Join('&', pairs.Select(p => $"{p.Key}={p.Value}"));
    }

    public static string CanonicalHeaderValue(string s)
    {
        var trimmed = s.Trim();
        var sb = new StringBuilder(trimmed.Length);
        var inQuotes = false;
        var lastWasSpace = false;
        foreach (var c in trimmed)
        {
            if (c == '"')
            {
                inQuotes = !inQuotes;
                sb.Append(c);
                lastWasSpace = false;
                continue;
            }
            if (!inQuotes && (c == ' ' || c == '\t'))
            {
                if (!lastWasSpace) { sb.Append(' '); lastWasSpace = true; }
            }
            else
            {
                sb.Append(c);
                lastWasSpace = false;
            }
        }
        return sb.ToString();
    }
}

// Reference: AWS "get-vanilla" SigV4 test (paraphrased)
//
//   Method: GET, Path: /, Query: (empty)
//   Headers: Host: example.amazonaws.com, X-Amz-Date: 20150830T123600Z
//   Body: (empty)
//   AccessKey: AKIDEXAMPLE
//   Secret:    wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY
//   Region:    us-east-1, Service: service, Date: 20150830T123600Z
//
// Expected signature: 5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31
// Expected auth:
//   AWS4-HMAC-SHA256
//   Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request,
//   SignedHeaders=host;x-amz-date,
//   Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31
