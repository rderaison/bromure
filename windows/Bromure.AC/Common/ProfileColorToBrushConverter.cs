using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;
using Bromure.AC.Core.Model;

namespace Bromure.AC.Common;

/// <summary>
/// Maps the eight <see cref="ProfileColor"/> presets to the saturated
/// solid-color brushes the picker / chip / sidebar use. Mirrors the
/// macOS NSColor presets so a profile that picked "Teal" on Mac
/// shows the same hue on Windows. Audit 09 §A1.
/// </summary>
public sealed class ProfileColorToBrushConverter : IValueConverter
{
    private static readonly Dictionary<ProfileColor, SolidColorBrush> Brushes = new()
    {
        [ProfileColor.Blue]   = New(0x0A, 0x84, 0xFF),
        [ProfileColor.Red]    = New(0xFF, 0x3B, 0x30),
        [ProfileColor.Green]  = New(0x34, 0xC7, 0x59),
        [ProfileColor.Orange] = New(0xFF, 0x95, 0x00),
        [ProfileColor.Purple] = New(0xAF, 0x52, 0xDE),
        [ProfileColor.Pink]   = New(0xFF, 0x2D, 0x55),
        [ProfileColor.Teal]   = New(0x32, 0xAD, 0xE6),
        [ProfileColor.Gray]   = New(0x8E, 0x8E, 0x93),
    };

    private static SolidColorBrush New(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();  // shared cross-thread, doesn't change
        return brush;
    }

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is ProfileColor pc && Brushes.TryGetValue(pc, out var b)) return b;
        return Brushes[ProfileColor.Blue];
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
