using System.Globalization;
using System.Resources;

namespace Bromure.AC.Localization;

/// <summary>
/// Strongly-typed accessor over the localized .resx files at
/// <c>Bromure.AC/Localization/Strings.*.resx</c>. Audit 08 §F.
///
/// <para>The macOS port carries 8 <c>.lproj</c> directories
/// (de / en / es / fr / ja / pt / zh-Hans / zh-Hant). The Windows
/// port translates English by default and falls back to English for
/// any locale where a translation is missing. <see cref="ResourceManager"/>
/// handles the locale chain via <see cref="CultureInfo.CurrentUICulture"/>.</para>
///
/// <para><b>Adding a new string</b>: add it to <c>Strings.resx</c>
/// (English baseline) and to every <c>Strings.&lt;locale&gt;.resx</c>
/// that ships. Add a static property on this class that calls
/// <see cref="ResourceManager.GetString(string)"/>; the fallback to
/// English happens automatically when a locale .resx omits the key.</para>
///
/// <para><b>Translating</b>: edit the per-locale .resx files. The
/// machine-translated stubs we ship initially are clearly marked
/// <c>[MT]</c> in the comments so a human translator can sweep.</para>
/// </summary>
public static class Strings
{
    private static readonly ResourceManager _rm = new(
        "Bromure.AC.Localization.Strings",
        typeof(Strings).Assembly);

    private static string Get(string key, string fallback)
        => _rm.GetString(key, CultureInfo.CurrentUICulture) ?? fallback;

    // ----- Main menu bar -----
    public static string MenuFile             => Get("MenuFile", "_File");
    public static string MenuFileNewSession   => Get("MenuFileNewSession", "_New Session");
    public static string MenuFileRebuildBase  => Get("MenuFileRebuildBase", "_Rebuild Base Image…");
    public static string MenuFileCloseWindow  => Get("MenuFileCloseWindow", "_Close Window");
    public static string MenuFileExit         => Get("MenuFileExit", "E_xit");

    public static string MenuEdit             => Get("MenuEdit", "_Edit");
    public static string MenuEditCut          => Get("MenuEditCut", "Cu_t");
    public static string MenuEditCopy         => Get("MenuEditCopy", "_Copy");
    public static string MenuEditPaste        => Get("MenuEditPaste", "_Paste");
    public static string MenuEditSelectAll    => Get("MenuEditSelectAll", "Select _All");

    public static string MenuView             => Get("MenuView", "_View");
    public static string MenuViewSessions     => Get("MenuViewSessions", "_Sessions");
    public static string MenuViewProfiles     => Get("MenuViewProfiles", "_Profiles");
    public static string MenuViewTrace        => Get("MenuViewTrace", "_Trace Inspector");
    public static string MenuViewApprovals    => Get("MenuViewApprovals", "_Approvals");
    public static string MenuViewPreferences  => Get("MenuViewPreferences", "_Preferences…");

    public static string MenuHelp             => Get("MenuHelp", "_Help");
    public static string MenuHelpDocs         => Get("MenuHelpDocs", "_Documentation");
    public static string MenuHelpUpdates      => Get("MenuHelpUpdates", "Check for _Updates…");
    public static string MenuHelpAbout        => Get("MenuHelpAbout", "_About Bromure…");
}
