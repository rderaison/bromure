using System.Globalization;
using System.Windows.Data;
using Bromure.AC.Core.Model;

namespace Bromure.AC.Common;

/// <summary>
/// Renders an <see cref="McpOAuthState"/> as a one-liner the editor
/// shows under the Authorize button. Audit 09 §A6.
/// </summary>
public sealed class McpOAuthStatusConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not McpOAuthState s)
        {
            return "Not authorized.";
        }
        if (s.ExpiresAt is { } exp)
        {
            var remaining = exp - DateTimeOffset.UtcNow;
            if (remaining <= TimeSpan.Zero)
            {
                return $"Authorized {Format(s.AuthorizedAt)} — token EXPIRED (will refresh on next session).";
            }
            return $"Authorized {Format(s.AuthorizedAt)} — token valid for {FormatDuration(remaining)}.";
        }
        return $"Authorized {Format(s.AuthorizedAt)}.";
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();

    private static string Format(DateTimeOffset dt)
    {
        var ago = DateTimeOffset.UtcNow - dt;
        if (ago.TotalMinutes < 60) return $"{(int)ago.TotalMinutes} min ago";
        if (ago.TotalHours < 24) return $"{(int)ago.TotalHours} h ago";
        return $"{(int)ago.TotalDays} d ago";
    }

    private static string FormatDuration(TimeSpan ts)
    {
        if (ts.TotalMinutes < 60) return $"{(int)ts.TotalMinutes} min";
        if (ts.TotalHours < 24) return $"{(int)ts.TotalHours} h";
        return $"{(int)ts.TotalDays} d";
    }
}
