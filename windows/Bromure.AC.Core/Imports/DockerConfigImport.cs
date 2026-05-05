using System.Text;
using System.Text.Json;

namespace Bromure.AC.Core.Imports;

/// <summary>
/// Port of <c>Sources/AgentCoding/DockerConfigImport.swift</c>.
/// Reads <c>~/.docker/config.json</c>, decodes <c>auths.&lt;key&gt;.auth</c>
/// (base64 of <c>"&lt;user&gt;:&lt;password&gt;"</c>), and surfaces one entry
/// per registry. Helper-managed entries (no <c>auth</c> field, or
/// <c>credHelpers</c>/<c>credsStore</c>) are counted as skipped.
/// </summary>
public static class DockerConfigImport
{
    public sealed record Entry(string Host, string Username, string Password);
    public sealed record Result(IReadOnlyList<Entry> Entries, int SkippedHelper);

    public sealed class ImportException : Exception
    {
        public ImportException(string message) : base(message) { }
    }

    public static Result Parse(ReadOnlySpan<byte> data)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(data.ToArray()); }
        catch (JsonException) { throw new ImportException("The file isn't valid JSON."); }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new ImportException("The file isn't valid JSON.");
            }

            if (!root.TryGetProperty("auths", out var auths) || auths.ValueKind != JsonValueKind.Object)
            {
                var helpers = CountHelperEntries(root);
                if (helpers > 0)
                {
                    return new Result(Array.Empty<Entry>(), helpers);
                }
                throw new ImportException("No `auths` object found at the top level.");
            }

            var helperFromHelpers = CountHelperEntries(root);
            var entries = new List<Entry>();
            var skipped = helperFromHelpers;

            foreach (var prop in auths.EnumerateObject())
            {
                if (prop.Value.ValueKind != JsonValueKind.Object) continue;
                if (!prop.Value.TryGetProperty("auth", out var authNode)
                    || authNode.ValueKind != JsonValueKind.String
                    || string.IsNullOrEmpty(authNode.GetString()))
                {
                    skipped++;
                    continue;
                }
                var decoded = DecodeAuth(authNode.GetString()!);
                if (decoded is null) continue;
                entries.Add(new Entry(
                    Host: HostnameFromKey(prop.Name),
                    Username: decoded.Value.user,
                    Password: decoded.Value.password));
            }
            return new Result(entries, skipped);
        }
    }

    private static (string user, string password)? DecodeAuth(string b64)
    {
        var trimmed = b64.Trim();
        try
        {
            var bytes = Convert.FromBase64String(trimmed);
            var s = Encoding.UTF8.GetString(bytes);
            var colon = s.IndexOf(':');
            if (colon < 0) return null;
            var user = s[..colon];
            var pass = s[(colon + 1)..];
            if (user.Length == 0 || pass.Length == 0) return null;
            return (user, pass);
        }
        catch (FormatException) { return null; }
    }

    private static string HostnameFromKey(string key)
    {
        var s = key;
        var schemeIdx = s.IndexOf("://", StringComparison.Ordinal);
        if (schemeIdx >= 0) s = s[(schemeIdx + 3)..];
        var slash = s.IndexOf('/');
        if (slash >= 0) s = s[..slash];
        var colon = s.IndexOf(':');
        if (colon >= 0) s = s[..colon];
        var lower = s.ToLowerInvariant();
        if (lower is "index.docker.io" or "registry-1.docker.io") return "docker.io";
        return s;
    }

    private static int CountHelperEntries(JsonElement root)
    {
        if (root.TryGetProperty("credHelpers", out var helpers) && helpers.ValueKind == JsonValueKind.Object)
        {
            var n = 0;
            foreach (var _ in helpers.EnumerateObject()) n++;
            return n;
        }
        return 0;
    }
}
