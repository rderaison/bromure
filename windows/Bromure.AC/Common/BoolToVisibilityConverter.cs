using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace Bromure.AC.Common;

/// <summary>
/// Replacement for the macOS source's implicit
/// <c>.opacity(model.error == nil ? 1 : 0)</c> idiom — XAML uses an
/// IValueConverter for the bool→Visibility mapping.
/// </summary>
public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is bool b && b ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is Visibility v && v == Visibility.Visible;
}

public sealed class InverseBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is bool b && !b ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is Visibility v && v != Visibility.Visible;
}
