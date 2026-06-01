using System.Collections;
using System.Globalization;
using System.Windows.Data;

namespace Bromure.AC.Common;

/// <summary>
/// Bool-returning converter used by the credentials drawers to decide
/// whether to auto-open. Truthy for: <c>int &gt; 0</c>, non-empty
/// strings, non-null reference values, and non-empty <see cref="ICollection"/>.
/// Falsy otherwise. Powers the "open the AWS / Git HTTPS / Docker /
/// ... expander when the profile already has something configured for
/// that section, leave it collapsed otherwise" UX.
/// </summary>
public sealed class HasContentConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value switch
        {
            null            => false,
            bool b          => b,
            int i           => i > 0,
            string s        => !string.IsNullOrWhiteSpace(s),
            ICollection col => col.Count > 0,
            _               => true,
        };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => Binding.DoNothing;
}
