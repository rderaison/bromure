using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// UX #7. Before this fix, every appearance field on Profile (custom
/// font, custom bg/fg hex, cursor shape, window opacity) was dead
/// code — KittyConfigBuilder.Build hardcoded everything. These tests
/// pin the wiring so a regression would be loud.
/// </summary>
public class KittyConfigBuilderTests
{
    [Fact]
    public void DefaultProfile_UsesHardcodedDefaults()
    {
        var conf = KittyConfigBuilder.Build(new Profile { Color = ProfileColor.Blue });
        conf.Should().Contain($"font_family       {KittyConfigBuilder.DefaultFontFamily}");
        conf.Should().Contain($"font_size         {KittyConfigBuilder.DefaultFontSize}");
        conf.Should().Contain("background        #1B1F2A");
        conf.Should().Contain($"foreground        {KittyConfigBuilder.DefaultForeground}");
        conf.Should().Contain("cursor_shape      block");
    }

    [Fact]
    public void UseTerminalAppDefaultsFalse_HonorsCustomFields()
    {
        var p = new Profile
        {
            UseTerminalAppDefaults = false,
            CustomFontFamily = "Cascadia Code",
            CustomFontSize = 18,
            CustomBackgroundHex = "#102030",
            CustomForegroundHex = "#FAFBFC",
            CursorShape = CursorShape.Beam,
            WindowOpacity = 0.85,
        };
        var conf = KittyConfigBuilder.Build(p);
        conf.Should().Contain("font_family       Cascadia Code");
        conf.Should().Contain("font_size         18");
        conf.Should().Contain("background        #102030");
        conf.Should().Contain("foreground        #FAFBFC");
        conf.Should().Contain("cursor_shape      beam");
        conf.Should().Contain("background_opacity 0.85");
    }

    [Fact]
    public void UseTerminalAppDefaultsTrue_IgnoresCustomFields()
    {
        // macOS contract: when the "Inherit from host terminal"
        // checkbox is on, the Custom* fields are display-only — the
        // generated config goes back to bake-time defaults.
        var p = new Profile
        {
            UseTerminalAppDefaults = true,
            CustomFontFamily = "Comic Sans",
            CustomBackgroundHex = "#FF0000",
        };
        var conf = KittyConfigBuilder.Build(p);
        conf.Should().NotContain("Comic Sans");
        conf.Should().NotContain("#FF0000");
        conf.Should().Contain(KittyConfigBuilder.DefaultFontFamily);
    }

    [Fact]
    public void EmptyCustomFields_FallBackToDefaults()
    {
        // Empty/whitespace strings shouldn't shadow the defaults —
        // otherwise leaving the editor field blank would produce a
        // broken config (e.g., `background        ` with no value).
        var p = new Profile
        {
            UseTerminalAppDefaults = false,
            CustomFontFamily = "  ",
            CustomBackgroundHex = "",
            CustomForegroundHex = null,
        };
        var conf = KittyConfigBuilder.Build(p);
        conf.Should().Contain($"font_family       {KittyConfigBuilder.DefaultFontFamily}");
        conf.Should().Contain("background        #1B1F2A");
        conf.Should().Contain($"foreground        {KittyConfigBuilder.DefaultForeground}");
    }

    [Theory]
    [InlineData("#FF0000", "#FF0000")]
    [InlineData("ff0000", "#FF0000")]
    [InlineData("  #00aabb  ", "#00AABB")]
    [InlineData("#FFAABB80", "#FFAABB80")] // alpha channel — kitty accepts 8-digit
    public void NormalizeHex_AcceptsValidShapes(string input, string expected)
    {
        KittyConfigBuilder.NormalizeHex(input).Should().Be(expected);
    }

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("#")]
    [InlineData("#FFF")]            // 3-digit short form not accepted
    [InlineData("#FFFFFG")]         // non-hex char
    [InlineData("FF0000FF00")]      // 10-digit
    [InlineData("rgb(255,0,0)")]
    public void NormalizeHex_RejectsInvalidShapes(string? input)
    {
        KittyConfigBuilder.NormalizeHex(input).Should().BeNull();
    }

    [Fact]
    public void CursorShape_RoundTripsAllEnumValues()
    {
        KittyConfigBuilder.Build(new Profile { UseTerminalAppDefaults = false, CursorShape = CursorShape.Block })
            .Should().Contain("cursor_shape      block");
        KittyConfigBuilder.Build(new Profile { UseTerminalAppDefaults = false, CursorShape = CursorShape.Beam })
            .Should().Contain("cursor_shape      beam");
        KittyConfigBuilder.Build(new Profile { UseTerminalAppDefaults = false, CursorShape = CursorShape.Underline })
            .Should().Contain("cursor_shape      underline");
    }

    [Fact]
    public void WindowOpacity_OutOfRange_FallsBackToOpaque()
    {
        // The UI is supposed to clamp 0.3 ≤ opacity ≤ 1.0, but if a
        // garbage value lands in the JSON (manual edit, older format),
        // we shouldn't crash kitty by writing background_opacity 5.0.
        var p = new Profile { UseTerminalAppDefaults = false, WindowOpacity = 0.0 };
        KittyConfigBuilder.Build(p).Should().Contain("background_opacity 1.00");

        var p2 = new Profile { UseTerminalAppDefaults = false, WindowOpacity = 7.5 };
        KittyConfigBuilder.Build(p2).Should().Contain("background_opacity 1.00");
    }
}
