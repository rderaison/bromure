using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;

namespace Bromure.AC.Common;

/// <summary>
/// Renders a #RRGGBB / #AARRGGBB hex string as a SolidColorBrush for
/// the appearance pane's inline color swatch next to the foreground /
/// background hex inputs. Mistyped values fall back to a neutral
/// gray so the swatch never disappears silently — that's a clearer
/// signal than a transparent box.
/// </summary>
public sealed class HexToBrushConverter : IValueConverter
{
    private static readonly SolidColorBrush Fallback = NewFrozen(Color.FromRgb(0x55, 0x55, 0x55));

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var hex = (value as string)?.Trim();
        if (string.IsNullOrEmpty(hex)) return Fallback;
        try
        {
            var converted = ColorConverter.ConvertFromString(hex);
            if (converted is Color c)
            {
                return NewFrozen(c);
            }
        }
        catch (FormatException) { }
        catch (NotSupportedException) { }
        return Fallback;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();

    private static SolidColorBrush NewFrozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}
