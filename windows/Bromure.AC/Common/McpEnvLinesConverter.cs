using System.Collections.ObjectModel;
using System.Globalization;
using System.Windows.Data;
using Bromure.AC.Core.Model;

namespace Bromure.AC.Common;

/// <summary>
/// Two-way binding between an <see cref="ObservableCollection{EnvironmentVariable}"/>
/// (per <see cref="McpServer.Environment"/>) and a NAME=VALUE-per-line
/// TextBox in the editor. Empty lines are dropped on write. Audit 09 §A6.
/// </summary>
public sealed class McpEnvLinesConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not IEnumerable<EnvironmentVariable> envs) return "";
        var lines = new List<string>();
        foreach (var e in envs)
        {
            lines.Add($"{e.Name}={e.Value}");
        }
        return string.Join("\n", lines);
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var text = value as string ?? "";
        var result = new ObservableCollection<EnvironmentVariable>();
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            var eq = line.IndexOf('=');
            if (eq <= 0) continue;  // skip rows without a name=value shape
            result.Add(new EnvironmentVariable
            {
                Name = line[..eq].Trim(),
                Value = line[(eq + 1)..],
            });
        }
        return result;
    }
}
