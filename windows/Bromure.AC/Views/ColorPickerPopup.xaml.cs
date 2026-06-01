using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Bromure.AC.Views;

/// <summary>
/// Minimal color picker for the profile editor's Appearance pane.
/// Curated palette of programmer-terminal-friendly colours (matches
/// macOS Terminal's "Solid Colors" preset set) plus a hex input for
/// power-users. WPF doesn't ship a ColorDialog and pulling WinForms
/// in globally clashes with WPF type names — this is the lighter
/// alternative.
/// </summary>
public partial class ColorPickerPopup : Window
{
    /// <summary>Returns "#RRGGBB" on OK, null otherwise.</summary>
    public string? PickedHex { get; private set; }

    /// <summary>Programmer-terminal palette: row 1 backgrounds (dark
    /// to light), row 2 foregrounds + accents. Hand-picked so users
    /// can't accidentally land on fg=bg by clicking adjacent swatches.</summary>
    private static readonly string[] Presets =
    {
        // Row 1 — backgrounds: pitch black, github-dark, slate (the
        // macOS canonical default), navy, forest, plum, retro amber.
        "#000000", "#0d1117", "#212734", "#0E1A2B", "#0F2A1A", "#291B33", "#2B1B0E",
        // Row 2 — foregrounds + accents: bone (macOS canonical
        // foreground), silver, lime, cyan, amber, magenta, red.
        "#c9d1d9", "#C7C7CC", "#A0E078", "#7CC0E0", "#FFC857", "#E069B0", "#FF5050",
    };

    public ColorPickerPopup()
    {
        InitializeComponent();
        BuildPresets();
    }

    private void BuildPresets()
    {
        foreach (var hex in Presets)
        {
            var btn = new Button
            {
                Background = HexToBrush(hex),
                BorderThickness = new Thickness(1),
                BorderBrush = (SolidColorBrush)FindResource("BorderBrush"),
                Margin = new Thickness(2),
                Width = 36,
                Height = 36,
                Padding = new Thickness(0),
                Tag = hex,
                ToolTip = hex,
                Cursor = Cursors.Hand,
            };
            btn.Click += OnPresetClick;
            PresetGrid.Children.Add(btn);
        }
    }

    private void OnPresetClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button b && b.Tag is string hex)
        {
            HexBox.Text = hex;
        }
    }

    private void OnHexTextChanged(object sender, TextChangedEventArgs e)
    {
        var brush = HexToBrush(HexBox.Text);
        if (brush is not null) LivePreview.Background = brush;
    }

    private void OnAcceptClick(object sender, RoutedEventArgs e)
    {
        var normalized = NormalizeHex(HexBox.Text);
        if (normalized is null)
        {
            MessageBox.Show(this,
                "That doesn't look like a valid #RRGGBB color. Try again or click a preset.",
                "Color picker",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        PickedHex = normalized;
        DialogResult = true;
        Close();
    }

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private static SolidColorBrush? HexToBrush(string? hex)
    {
        var n = NormalizeHex(hex);
        if (n is null) return null;
        try
        {
            return (SolidColorBrush)new BrushConverter().ConvertFrom(n)!;
        }
        catch { return null; }
    }

    private static string? NormalizeHex(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var s = raw.Trim();
        if (s.StartsWith('#')) s = s[1..];
        if (s.Length != 6) return null;
        foreach (var c in s)
        {
            if (!char.IsAsciiHexDigit(c)) return null;
        }
        return "#" + s.ToUpperInvariant();
    }
}
