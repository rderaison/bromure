namespace Bromure.AC.Core.Imports;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/AWSConfigParser.swift</c>.
/// Reads <c>~/.aws/config</c> and surfaces every SSO-capable profile,
/// resolving <c>sso_session</c> indirection.
/// </summary>
public sealed record DiscoveredSsoProfile(
    string Name,
    string SsoStartUrl,
    string SsoAccountId,
    string SsoRoleName,
    string SsoRegion,
    string Region,
    string? SsoSessionName);

public static class AwsConfigParser
{
    public static IReadOnlyList<DiscoveredSsoProfile> Discover(string? configPath = null)
    {
        var path = configPath ?? DefaultConfigPath();
        if (!File.Exists(path)) return Array.Empty<DiscoveredSsoProfile>();
        var contents = File.ReadAllText(path);
        return Parse(contents);
    }

    public static IReadOnlyList<DiscoveredSsoProfile> Parse(string contents)
    {
        var (profiles, ssoSessions) = ParseSections(contents);
        var output = new List<DiscoveredSsoProfile>();
        foreach (var p in profiles)
        {
            if (Resolve(p, ssoSessions) is { } resolved) output.Add(resolved);
        }
        return output;
    }

    private static string DefaultConfigPath()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".aws", "config");
    }

    private sealed class RawSection
    {
        public string Name = "";
        public Dictionary<string, string> Fields = new(StringComparer.Ordinal);
    }

    private static (List<RawSection> profiles, Dictionary<string, RawSection> ssoSessions) ParseSections(string text)
    {
        var profiles = new List<RawSection>();
        var ssoSessions = new Dictionary<string, RawSection>(StringComparer.Ordinal);
        RawSection? current = null;
        string? currentKind = null;

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            var trimmed = line.Trim();
            if (trimmed.Length == 0 || trimmed.StartsWith('#') || trimmed.StartsWith(';'))
            {
                continue;
            }

            if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
            {
                if (current is not null) Store(current, currentKind, profiles, ssoSessions);
                var header = trimmed[1..^1].Trim();
                if (header.StartsWith("profile ", StringComparison.Ordinal))
                {
                    var name = header["profile ".Length..].Trim();
                    current = new RawSection { Name = name };
                    currentKind = "profile";
                }
                else if (header.StartsWith("sso-session ", StringComparison.Ordinal))
                {
                    var name = header["sso-session ".Length..].Trim();
                    current = new RawSection { Name = name };
                    currentKind = "sso-session";
                }
                else if (header == "default")
                {
                    current = new RawSection { Name = "default" };
                    currentKind = "profile";
                }
                else
                {
                    current = null;
                    currentKind = null;
                }
                continue;
            }

            if (current is null) continue;
            var eq = trimmed.IndexOf('=');
            if (eq < 0) continue;
            var key = trimmed[..eq].Trim();
            var value = trimmed[(eq + 1)..].Trim();
            current.Fields[key] = value;
        }
        if (current is not null) Store(current, currentKind, profiles, ssoSessions);
        return (profiles, ssoSessions);
    }

    private static void Store(RawSection section, string? kind, List<RawSection> profiles,
        Dictionary<string, RawSection> ssoSessions)
    {
        switch (kind)
        {
            case "profile": profiles.Add(section); break;
            case "sso-session": ssoSessions[section.Name] = section; break;
        }
    }

    private static DiscoveredSsoProfile? Resolve(RawSection section, Dictionary<string, RawSection> ssoSessions)
    {
        var fields = new Dictionary<string, string>(section.Fields, StringComparer.Ordinal);
        if (fields.TryGetValue("sso_session", out var sessionName)
            && ssoSessions.TryGetValue(sessionName, out var session))
        {
            foreach (var (k, v) in session.Fields)
            {
                if (!fields.ContainsKey(k)) fields[k] = v;
            }
        }
        if (!fields.TryGetValue("sso_start_url", out var startUrl)
            || !fields.TryGetValue("sso_account_id", out var accountId)
            || !fields.TryGetValue("sso_role_name", out var roleName))
        {
            return null;
        }
        var ssoRegion = fields.GetValueOrDefault("sso_region")
                        ?? fields.GetValueOrDefault("region")
                        ?? "";
        var region = fields.GetValueOrDefault("region") ?? ssoRegion;

        return new DiscoveredSsoProfile(
            Name: section.Name,
            SsoStartUrl: startUrl,
            SsoAccountId: accountId,
            SsoRoleName: roleName,
            SsoRegion: ssoRegion,
            Region: region,
            SsoSessionName: fields.GetValueOrDefault("sso_session"));
    }
}
