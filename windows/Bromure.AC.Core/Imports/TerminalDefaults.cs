using System.Text.Json;

namespace Bromure.AC.Core.Imports;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/TerminalAppDefaults.swift</c>
/// — adapted for Windows Terminal.
///
/// <para>macOS reads Terminal.app's plist (NSKeyedArchiver-encoded NSFont
/// + NSColor). Windows Terminal stores user prefs as JSON at
/// <c>%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_*\LocalState\settings.json</c>.
/// We read the active theme + font + colors and seed kitty with them so
/// moving from the user's daily-driver terminal into Bromure AC's
/// kitty feels visually continuous.</para>
/// </summary>
public sealed record TerminalDefaults(
    string FontFamily,
    int FontSize,
    string BackgroundHex,
    string ForegroundHex)
{
    /// <summary>Used when Windows Terminal isn't installed or the prefs are unreadable.</summary>
    public static readonly TerminalDefaults Fallback = new(
        FontFamily: "JetBrains Mono",
        FontSize: 14,
        BackgroundHex: "#0d1117",
        ForegroundHex: "#c9d1d9");

    public static TerminalDefaults Load()
    {
        var path = ResolveSettingsPath();
        if (path is null || !File.Exists(path)) return Fallback;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            return ParseSettings(doc.RootElement);
        }
        catch (JsonException) { return Fallback; }
        catch (IOException) { return Fallback; }
    }

    private static string? ResolveSettingsPath()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var packages = Path.Combine(localAppData, "Packages");
        if (!Directory.Exists(packages)) return null;
        // Look for Microsoft.WindowsTerminal_*\LocalState\settings.json
        // and Microsoft.WindowsTerminalPreview_*\LocalState\settings.json.
        foreach (var dir in Directory.EnumerateDirectories(packages, "Microsoft.WindowsTerminal*"))
        {
            var candidate = Path.Combine(dir, "LocalState", "settings.json");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static TerminalDefaults ParseSettings(JsonElement root)
    {
        // Resolve the active default profile.
        var defaultGuid = root.TryGetProperty("defaultProfile", out var dp) ? dp.GetString() : null;
        if (!root.TryGetProperty("profiles", out var profiles)) return Fallback;

        // profiles can be either a list (older versions) or {"defaults":{...},"list":[...]}.
        JsonElement profilesList;
        if (profiles.ValueKind == JsonValueKind.Array)
        {
            profilesList = profiles;
        }
        else if (profiles.ValueKind == JsonValueKind.Object && profiles.TryGetProperty("list", out var l))
        {
            profilesList = l;
        }
        else
        {
            return Fallback;
        }

        JsonElement? matched = null;
        foreach (var p in profilesList.EnumerateArray())
        {
            if (defaultGuid is not null
                && p.TryGetProperty("guid", out var g)
                && string.Equals(g.GetString(), defaultGuid, StringComparison.OrdinalIgnoreCase))
            {
                matched = p; break;
            }
        }
        var profile = matched ?? (profilesList.GetArrayLength() > 0 ? profilesList[0] : (JsonElement?)null);
        if (profile is null) return Fallback;

        var face = profile.Value.TryGetProperty("font", out var font) && font.TryGetProperty("face", out var f)
            ? f.GetString() ?? Fallback.FontFamily
            : Fallback.FontFamily;
        var size = font.ValueKind == JsonValueKind.Object && font.TryGetProperty("size", out var s)
            ? (s.ValueKind == JsonValueKind.Number ? (int)s.GetDouble() : Fallback.FontSize)
            : Fallback.FontSize;

        // Color scheme lookup. profile["colorScheme"] -> root["schemes"][].name
        var schemeName = profile.Value.TryGetProperty("colorScheme", out var cs) ? cs.GetString() : null;
        var background = Fallback.BackgroundHex;
        var foreground = Fallback.ForegroundHex;
        if (schemeName is not null && root.TryGetProperty("schemes", out var schemes))
        {
            foreach (var sc in schemes.EnumerateArray())
            {
                if (sc.TryGetProperty("name", out var n)
                    && string.Equals(n.GetString(), schemeName, StringComparison.Ordinal))
                {
                    background = sc.TryGetProperty("background", out var b) ? b.GetString() ?? background : background;
                    foreground = sc.TryGetProperty("foreground", out var fg) ? fg.GetString() ?? foreground : foreground;
                    break;
                }
            }
        }

        return new TerminalDefaults(face, Math.Max(8, size), background, foreground);
    }
}
