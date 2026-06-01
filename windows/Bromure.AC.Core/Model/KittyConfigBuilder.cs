// macos-source: Sources/AgentCoding/TerminalAppDefaults.swift @ 7e499111f7db
using Bromure.AC.Core.Imports;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Generates a per-session <c>~/.config/kitty/kitty.conf</c> for the
/// guest. Mirrors <c>TerminalAppDefaults.kittyConfig(for:)</c> on the
/// macOS port — kitty config is a session-time artefact derived from
/// the profile, never baked into the image.
///
/// <para>Why per-session and not at bake time: the user can edit the
/// active profile's appearance and have it take effect on the next
/// session launch without re-running the 20-minute base-image bake.
/// The bake-time <c>/etc/xdg/kitty/kitty.conf</c> stays as a fallback
/// for the rare case where the metadata mount fails.</para>
/// </summary>
public static class KittyConfigBuilder
{
    /// Default font size in points. Matches Windows Terminal's stock
    /// 14pt — same physical readability the user gets in their
    /// daily-driver shell. macOS Terminal.app's default is 14 too,
    /// rendered at Retina ×2; on Windows the Xvnc framebuffer is 1:1
    /// with the WPF window pixels (no compositor upscale), so 14pt
    /// stays in the comfortable-to-read band on both standard 1080p
    /// monitors and high-DPI laptops.
    public const int DefaultFontSize = 14;
    public const string DefaultFontFamily = "JetBrains Mono";
    // macOS canonical defaults from TerminalAppDefaults.swift:
    //   - background: Profile.seedAppearance() hardcodes "#212734"
    //   - foreground: TerminalAppDefaults.fallback.foregroundHex = "#c9d1d9"
    //   - font family / cursor: matches below
    // Keep Windows in lockstep so a user moving between platforms
    // sees the same dark-slate terminal.
    // Stored uppercase so they match NormalizeHex's output and round-trip
    // cleanly into the kitty.conf — keeps tests' "contains" assertions
    // matching the literal text we emit.
    public const string DefaultBackground = "#212734";
    public const string DefaultForeground = "#C9D1D9";
    public const string DefaultCursorShape = "block";

    public static string Build(Profile? profile, TerminalDefaults? terminalDefaults = null)
    {
        // macOS-parity resolveStyle:
        //   customX ?? terminalDefaults.X ?? hardcodedDefault
        // The UseTerminalAppDefaults flag is intentionally NOT consulted
        // — macOS keeps it on disk for backward compat but ignores it
        // in resolveStyle (Profile.swift:1311), because older profiles
        // that flipped it true had their Custom fields silently dropped
        // and the resulting "fall through to whatever the user's
        // terminal looks like" produced unreadable terminals when the
        // user themed their daily-driver dark. We match: a Profile's
        // Custom* fields ALWAYS win when set; null falls through to the
        // host terminal's prefs; the hardcoded constants are the last
        // resort if the host terminal isn't installed / unreadable.
        //
        // Reads from Terminal.app on macOS via TerminalAppDefaults.load();
        // Windows Terminal on Windows via TerminalDefaults.Load() from
        // %LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_*\LocalState\settings.json.
        var td = terminalDefaults ?? TerminalDefaults.Load();
        // Font family DOES NOT fall through to td.FontFamily — that's
        // a deliberate divergence from macOS resolveStyle. macOS reads
        // Terminal.app's font face, which is reliably monospaced (users
        // don't pick Times for a shell). Windows Terminal's `face` JSON
        // is just whatever string is in settings.json; we've seen real
        // user configs that pin a proportional system font there, and
        // routing that straight into kitty produces an unreadable
        // terminal (proportional metrics + no glyph file copied into
        // the guest ⇒ fontconfig fallback with broken cell math).
        // Profile.CustomFontFamily comes from a host-side mono filter
        // (ProfilesViewModel.FontFamilyOptions) when set, and otherwise
        // we land on DefaultFontFamily which is baked into the guest.
        var fontFamily = !string.IsNullOrWhiteSpace(profile?.CustomFontFamily)
            ? profile!.CustomFontFamily!
            : DefaultFontFamily;
        var fontSize = profile?.CustomFontSize is int cf && cf > 0
            ? cf
            : (td.FontSize > 0 ? td.FontSize : DefaultFontSize);
        var foreground = NormalizeHex(profile?.CustomForegroundHex)
            ?? NormalizeHex(td.ForegroundHex)
            ?? DefaultForeground;
        var bgPreview = NormalizeHex(profile?.CustomBackgroundHex)
            ?? NormalizeHex(td.BackgroundHex)
            ?? DefaultBackground;
        // Safety net: if fg and bg resolve to the same colour (easy to
        // do when one is empty and the other resolves to the same
        // default, or when the user's terminal scheme happens to use
        // identical fg/bg, or when both were typed manually), the
        // terminal renders text invisibly. Force fg back to the default
        // so the user sees something instead of a black framebuffer
        // they can't explain.
        if (string.Equals(foreground, bgPreview, StringComparison.OrdinalIgnoreCase))
        {
            foreground = DefaultForeground;
        }
        var cursorShape = (profile?.CursorShape ?? CursorShape.Block) switch
        {
            CursorShape.Beam => "beam",
            CursorShape.Underline => "underline",
            _ => "block",
        };
        var profileName = profile?.Name ?? "default";

        // Profile colour tints the tab bar + cursor, so each session
        // is visually identifiable when the user has multiple kitty
        // windows alt-tabbing (one per profile in the macOS-parity
        // shape we now ship). The terminal text background stays a
        // neutral dark slate so colour text stays legible UNLESS the
        // user picks a custom one.
        var (accent, accentDim) = AccentForProfile(profile?.Color ?? ProfileColor.Blue);
        var background = bgPreview;
        var tabBg = accentDim;
        var tabActiveBg = accent;
        var cursorColor = accent;
        // background_opacity under Xvnc (no X compositor) doesn't
        // render alpha — kitty disables some text-rendering paths
        // when the value is < 1.0 and the framebuffer goes black.
        // Profile.WindowOpacity stays as a stored field for the
        // future (e.g. when we layer a compositor into the guest
        // image), but for now we force-emit 1.0 so a slider drag
        // can't blank the terminal.
        var windowOpacity = 1.0;
        _ = profile?.WindowOpacity;  // referenced to suppress "unused" warning if profile is non-null

        return $"""
        # Generated by Bromure Agentic Coding from this profile's appearance.
        # Profile: {profileName}
        # font_family={fontFamily}  font_size={fontSize}  cursor={cursorShape}
        # accent={accent}

        font_family       {fontFamily}
        font_size         {fontSize}
        background        {background}
        foreground        {foreground}
        cursor            {cursorColor}
        cursor_shape      {cursorShape}
        cursor_blink_interval 0
        cursor_beam_thickness 1.0
        cursor_underline_thickness 1.5
        background_opacity {windowOpacity:0.00}
        # Disable shell integration's cursor management — it injects
        # bash hooks that toggle the cursor (beam during input, block
        # while a command runs), overriding cursor_shape.
        shell_integration no-cursor
        window_padding_width 8
        enable_audio_bell no
        remember_window_size no

        sync_to_monitor yes
        repaint_delay 16
        input_delay 10
        update_check_interval 0

        # Tab bar tinted with the profile's colour — same intent as
        # macOS NSWindow tabbed-window accenting. Visible when kitty
        # has more than one tab.
        tab_bar_style                  fade
        tab_bar_edge                   top
        tab_bar_background             {tabBg}
        active_tab_background          {tabActiveBg}
        active_tab_foreground          #FFFFFF
        active_tab_font_style          bold
        inactive_tab_background        {tabBg}
        inactive_tab_foreground        #C9D1D9

        # Windows/Cmd-style clipboard shortcuts. copy_or_interrupt
        # preserves Ctrl+C's SIGINT behaviour when there's no
        # selection — copies if you've highlighted text, sends ^C
        # otherwise. Same convention macOS Terminal uses.
        map ctrl+c          copy_or_interrupt
        map ctrl+v          paste_from_clipboard
        map ctrl+a          select_all
        map ctrl+plus       change_font_size all +2.0
        map ctrl+minus      change_font_size all -2.0
        map ctrl+0          change_font_size all 0

        # Send URL clicks to the host's default browser.
        open_url_with /usr/local/bin/bromure-open

        # Remote control on an abstract Unix socket — lets the
        # automation /sessions/SID/exec path call `kitty @ get-text`
        # / `kitty @ ls` etc. for the MCP vm_screenshot tool. The
        # abstract namespace (@) means there's no file in /run to
        # clean up across sessions, and the socket is scoped to this
        # ubuntu user so non-bromure processes can't dial it.
        allow_remote_control yes
        listen_on             unix:@bromure-kitty
        """;
    }

    /// <summary>
    /// Port of macOS <c>Profile.seedAppearance(from:)</c>
    /// (TerminalAppDefaults.swift:236). Run ONCE at new-profile creation
    /// to fill the Custom* fields with sensible starting values so the
    /// editor opens on something useful AND the first launch lands on a
    /// readable terminal (without it, brand-new profiles inherit
    /// whatever the user's Windows Terminal happens to be — which is
    /// often a low-contrast dark-on-dark scheme that renders as a black
    /// kitty window).
    ///
    /// <para>Idempotent on each field — only fills when null/empty,
    /// preserves anything the user already typed. Background is hard-
    /// coded to the canonical Bromure dark slate (#212734); foreground
    /// is sourced from the host terminal so colour-themed users
    /// inherit their text colour.</para>
    /// </summary>
    public static void SeedAppearance(Profile profile, TerminalDefaults? terminalDefaults = null)
    {
        var td = terminalDefaults ?? TerminalDefaults.Load();
        if (string.IsNullOrWhiteSpace(profile.CustomFontFamily))
            profile.CustomFontFamily = DefaultFontFamily;
        if (profile.CustomFontSize is null or 0)
            profile.CustomFontSize = DefaultFontSize;
        if (string.IsNullOrWhiteSpace(profile.CustomBackgroundHex))
            profile.CustomBackgroundHex = DefaultBackground;
        if (string.IsNullOrWhiteSpace(profile.CustomForegroundHex))
            profile.CustomForegroundHex = NormalizeHex(td.ForegroundHex) ?? DefaultForeground;
    }

    /// <summary>Strip leading/trailing whitespace, prepend `#` if
    /// missing, and accept only 6- or 8-digit hex (kitty allows alpha).
    /// Returns null for unparseable input so the caller can fall back
    /// to the default. macOS uses NSColor parsing which is more
    /// forgiving — this is intentionally strict so a typo doesn't
    /// silently produce a black terminal.</summary>
    public static string? NormalizeHex(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var s = raw.Trim();
        if (s.StartsWith('#')) s = s[1..];
        if (s.Length != 6 && s.Length != 8) return null;
        foreach (var c in s)
        {
            if (!char.IsAsciiHexDigit(c)) return null;
        }
        return "#" + s.ToUpperInvariant();
    }

    /// <summary>
    /// Profile colour → (accent, dimmed accent) hex pair used for the
    /// kitty tab bar tint + cursor. Kept in sync with the WPF palette
    /// in <c>SessionRowViewModel.ProfileColorToWpf</c>.
    /// </summary>
    private static (string Accent, string Dim) AccentForProfile(ProfileColor c) => c switch
    {
        ProfileColor.Red    => ("#FF4D4F", "#5A1F22"),
        ProfileColor.Orange => ("#FF9C33", "#5A381A"),
        ProfileColor.Green  => ("#4CC990", "#1F4A3A"),
        ProfileColor.Teal   => ("#33B0B8", "#1A4146"),
        ProfileColor.Blue   => ("#4C8BF5", "#1F345A"),
        ProfileColor.Purple => ("#A86EE0", "#3F2954"),
        ProfileColor.Pink   => ("#E06EA8", "#54293F"),
        ProfileColor.Gray   => ("#888899", "#33333A"),
        _                   => ("#4C8BF5", "#1F345A"),
    };
}
