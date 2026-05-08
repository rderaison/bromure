// macos-source: Sources/AgentCoding/Mitm/HTTPProxy.swift @ 875b644e56b1
using System.Text;

namespace Bromure.AC.Mitm.Trace;

/// <summary>
/// Pre-storage filters for raw HTTP frames the proxy is about to
/// hand to <see cref="TraceStore"/>: redact sensitive headers,
/// gate body capture by size + Content-Type. Direct port of the
/// macOS <c>HTTPProxy.redactSensitiveHeaders</c> /
/// <c>HTTPProxy.bodyForTrace</c> static helpers.
///
/// <para><b>Why redact at the trace boundary, not at the wire.</b>
/// The proxy needs the real Authorization header on the wire
/// (token swap, MITM forwarding); only the persisted trace record
/// must hide it. Redacting at this layer keeps the swap path simple
/// and ensures a forensic trace archive can ship to the inspector
/// without leaking secrets.</para>
/// </summary>
public static class TraceBodyRedactor
{
    /// <summary>Cap per body record. Anything bigger is presumed to
    /// be a binary upload/download and is dropped from the trace
    /// store — the per-session disk budget would fill on a single
    /// 100 MB request otherwise.</summary>
    public const int PerRecordCap = 5 * 1024 * 1024;

    private static readonly byte[] HeaderEnd = new byte[] { 0x0D, 0x0A, 0x0D, 0x0A };

    /// <summary>
    /// Replace the value of every sensitive header
    /// (<c>Authorization</c>, <c>Cookie</c>, <c>*-api-key</c>, etc.)
    /// with <c>&lt;redacted&gt;</c>. Returns the input unchanged when
    /// the buffer doesn't contain a header section.
    /// </summary>
    public static byte[] RedactSensitiveHeaders(byte[] raw)
    {
        var headerEnd = IndexOf(raw, HeaderEnd);
        if (headerEnd < 0) return raw;
        var headerBytes = raw[..headerEnd];
        var bodyBytes = raw[headerEnd..];  // includes the \r\n\r\n separator

        var headerStr = Encoding.ASCII.GetString(headerBytes);
        var lines = headerStr.Split("\r\n").ToList();
        for (var i = 0; i < lines.Count; i++)
        {
            var colon = lines[i].IndexOf(':');
            if (colon < 0) continue;
            var name = lines[i][..colon].Trim().ToLowerInvariant();
            if (IsSensitiveHeader(name))
            {
                lines[i] = lines[i][..colon] + ": <redacted>";
            }
        }
        var rebuilt = string.Join("\r\n", lines);
        var rebuiltBytes = Encoding.ASCII.GetBytes(rebuilt);
        var output = new byte[rebuiltBytes.Length + bodyBytes.Length];
        Buffer.BlockCopy(rebuiltBytes, 0, output, 0, rebuiltBytes.Length);
        Buffer.BlockCopy(bodyBytes, 0, output, rebuiltBytes.Length, bodyBytes.Length);
        return output;
    }

    public static bool IsSensitiveHeader(string lowered)
    {
        if (lowered is "authorization" or "proxy-authorization"
                    or "cookie" or "set-cookie"
                    or "x-amz-security-token"
                    or "x-goog-iap-jwt-assertion")
        {
            return true;
        }
        // x-api-key, anthropic-api-key, openai-api-key, etc.
        if (lowered == "api-key" || lowered.EndsWith("-api-key", StringComparison.Ordinal))
        {
            return true;
        }
        return false;
    }

    /// <summary>
    /// Returns the buffer when it's safe to store as a trace body
    /// (size under <see cref="PerRecordCap"/>, Content-Type either
    /// missing or in the text/json/xml/SSE/form whitelist), null
    /// otherwise so the caller skips the body write.
    /// </summary>
    public static byte[]? BodyForTrace(byte[] raw)
    {
        if (raw.Length == 0) return null;
        if (raw.Length > PerRecordCap) return null;
        var headerEnd = IndexOf(raw, HeaderEnd);
        if (headerEnd < 0)
        {
            // Not an HTTP frame — keep verbatim for whatever the
            // caller wants to do with it.
            return raw;
        }
        var headerStr = Encoding.ASCII.GetString(raw, 0, headerEnd);
        var lines = headerStr.Split("\r\n");
        string? ct = null;
        foreach (var line in lines)
        {
            if (!line.StartsWith("content-type:", StringComparison.OrdinalIgnoreCase)) continue;
            var v = line[(line.IndexOf(':') + 1)..].Trim().ToLowerInvariant();
            ct = v;
            break;
        }
        if (string.IsNullOrEmpty(ct)) return raw;  // no Content-Type → keep
        if (IsTextLike(ct)) return raw;
        return null;
    }

    private static bool IsTextLike(string ct)
    {
        // Whitelist of "we'd want to read this in the inspector"
        // content types. Mirrors macOS HTTPProxy.bodyForTrace.
        if (ct.StartsWith("text/", StringComparison.Ordinal)) return true;
        if (ct.StartsWith("application/json", StringComparison.Ordinal)) return true;
        if (ct.StartsWith("application/xml", StringComparison.Ordinal)) return true;
        if (ct.StartsWith("application/javascript", StringComparison.Ordinal)) return true;
        if (ct.StartsWith("application/x-www-form-urlencoded", StringComparison.Ordinal)) return true;
        if (ct.StartsWith("application/x-ndjson", StringComparison.Ordinal)) return true;
        if (ct.StartsWith("application/ld+json", StringComparison.Ordinal)) return true;
        if (ct.StartsWith("application/graphql", StringComparison.Ordinal)) return true;
        if (ct.StartsWith("application/yaml", StringComparison.Ordinal)
            || ct.StartsWith("application/x-yaml", StringComparison.Ordinal)) return true;
        if (ct.StartsWith("application/problem+json", StringComparison.Ordinal)) return true;
        if (ct.StartsWith("multipart/form-data", StringComparison.Ordinal)) return true;
        // RFC 6839: application/* with +json or +xml suffix.
        if (ct.StartsWith("application/", StringComparison.Ordinal)
            && (ct.Contains("+json") || ct.Contains("+xml"))) return true;
        if (ct.StartsWith("text/event-stream", StringComparison.Ordinal)) return true;
        return false;
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
