using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace Bromure.AC.Common;

/// <summary>
/// Reusable enum→Visibility converter. Use as
/// <c>{Binding Phase, Converter={StaticResource EnumToVis}, ConverterParameter=Welcome}</c>.
///
/// <para><b>Why this exists.</b> WPF's <c>ContentTemplateSelector</c>
/// is only re-evaluated when <c>Content</c> itself changes — a
/// property change on the bound object does NOT re-fire it. We were
/// using a selector to dispatch on <c>Phase</c>, which meant clicking
/// Get Started flipped <c>Phase</c> to <c>Initializing</c> in the
/// view-model but the UI stayed on Welcome. Visibility-based overlay
/// re-evaluates every binding update — bulletproof.</para>
/// </summary>
public sealed class EnumToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is null || parameter is null) return Visibility.Collapsed;
        // Compare by name; tolerant of either ToString("G") or the literal enum.
        var name = value.ToString();
        return string.Equals(name, parameter.ToString(), StringComparison.Ordinal)
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => Binding.DoNothing;
}
