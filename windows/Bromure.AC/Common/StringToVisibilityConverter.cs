using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace Bromure.AC.Common;

/// <summary>
/// Visible when the bound string is non-empty; Collapsed otherwise.
/// Used by SessionsView to hide a row's status-detail line when there
/// is nothing to say (idle / running steady states).
/// </summary>
public sealed class StringToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => string.IsNullOrEmpty(value as string) ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
