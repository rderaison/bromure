using System.Collections.ObjectModel;
using System.Globalization;
using System.Windows.Data;

namespace Bromure.AC.Common;

/// <summary>
/// Two-way binds an <see cref="ObservableCollection{T}"/> of string
/// against a multi-line TextBox so the editor can present "one item
/// per line" lists without needing per-row UI. Empty lines are
/// dropped on write so a trailing newline doesn't turn into a stray
/// blank arg / env entry. Audit 09 §A6 (stdio Arguments list).
/// </summary>
public sealed class StringListConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is IEnumerable<string> items)
        {
            return string.Join("\n", items);
        }
        return "";
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var text = value as string ?? "";
        var lines = text.Replace("\r\n", "\n").Split('\n')
            .Where(s => !string.IsNullOrEmpty(s))
            .ToList();
        // Caller bound against an ObservableCollection<string>; preserve
        // identity so any UI subscribing to CollectionChanged stays
        // attached. Compare first to avoid spurious reset events.
        if (parameter is ObservableCollection<string> existing)
        {
            existing.Clear();
            foreach (var s in lines) existing.Add(s);
            return existing;
        }
        return new ObservableCollection<string>(lines);
    }
}
