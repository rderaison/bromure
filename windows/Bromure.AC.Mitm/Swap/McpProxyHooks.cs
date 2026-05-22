// macos-source: Sources/AgentCoding/Mitm/HTTPProxy.swift @ 875b644e56b1  (steps 4a + 5b)
using System.Text;
using System.Text.RegularExpressions;

namespace Bromure.AC.Mitm.Swap;

/// <summary>
/// Helpers for the MCP-specific request rewrites the MITM proxy applies:
/// blocking OAuth/OIDC discovery probes from leaking out of the VM, and
/// injecting the real bearer token on the wire when the agent issued
/// the request without an Authorization header (OAuth-brokered servers).
/// </summary>
public static class McpProxyHooks
{
    /// <summary>True if any swap entry for this host carries the MCP
    /// fake prefix — i.e. this host is an MCP server we're brokering.</summary>
    public static bool HostHasMcpBearer(this TokenSwapper swapper, string host, Guid profileId)
        => swapper.RealForMcpHost(host, profileId) is not null;

    /// <summary>The real bearer for this MCP host, or null if none.</summary>
    public static string? RealForMcpHost(this TokenSwapper swapper, string host, Guid profileId)
    {
        foreach (var entry in swapper.EntriesFor(profileId))
        {
            if (!string.Equals(entry.Host, host, StringComparison.OrdinalIgnoreCase)) continue;
            if (!entry.Fake.StartsWith(McpFakeMint.FakePrefix, StringComparison.Ordinal)) continue;
            return entry.Real;
        }
        return null;
    }

    /// <summary>OAuth discovery / metadata paths the MCP-aware proxy
    /// blocks (returns 404) so an in-VM client doesn't discover the
    /// real OAuth endpoints and try to bypass our broker.</summary>
    public static bool IsOauthDiscoveryPath(string path)
        => path.StartsWith("/.well-known/oauth-authorization-server", StringComparison.Ordinal)
            || path.StartsWith("/.well-known/oauth-protected-resource", StringComparison.Ordinal)
            || path.StartsWith("/.well-known/openid-configuration", StringComparison.Ordinal);

    /// <summary>Canonical 404 response body for blocked discovery paths.</summary>
    public static byte[] BuildDiscoveryBlockedResponse()
    {
        const string body = "{\"error\":\"not_found\"}";
        var head = $"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n";
        return Encoding.ASCII.GetBytes(head + body);
    }

    /// <summary>
    /// If the request has no Authorization header, inject
    /// <c>Authorization: Bearer &lt;real&gt;</c>. Returns the (possibly
    /// rewritten) bytes; the caller compares lengths to know if it
    /// must patch Content-Length (we don't — header section only).
    /// </summary>
    public static byte[] InjectMcpBearer(byte[] request, string real)
    {
        var headerEnd = FindHeaderEnd(request);
        if (headerEnd < 0) return request;
        var headerStr = Encoding.ASCII.GetString(request, 0, headerEnd);
        // Already has any Authorization header — leave it alone (the
        // swap pass either matched and substituted, or the caller
        // explicitly chose a different scheme).
        if (Regex.IsMatch(headerStr, @"(?im)^Authorization:\s")) return request;

        // Insert before the trailing blank line that ends the headers.
        // headerStr ends with "...\r\n\r\n"; chop the last 2 bytes,
        // append our line, then the original trailing CRLF.
        var insert = $"Authorization: Bearer {real}\r\n";
        var newHeader = headerStr[..^2] + insert + "\r\n";
        var headBytes = Encoding.ASCII.GetBytes(newHeader);
        var bodyLen = request.Length - headerEnd;
        var output = new byte[headBytes.Length + bodyLen];
        Buffer.BlockCopy(headBytes, 0, output, 0, headBytes.Length);
        Buffer.BlockCopy(request, headerEnd, output, headBytes.Length, bodyLen);
        return output;
    }

    private static int FindHeaderEnd(byte[] buf)
    {
        for (var i = 0; i <= buf.Length - 4; i++)
        {
            if (buf[i] == 0x0D && buf[i + 1] == 0x0A
                && buf[i + 2] == 0x0D && buf[i + 3] == 0x0A) return i + 4;
        }
        return -1;
    }
}
