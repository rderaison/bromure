using System.Text;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Bromure.AC.ViewModels;

/// <summary>
/// Direct port of the observable model behind <c>InitializingView</c>
/// in <c>Sources/AgentCoding/SetupViews.swift</c>. Holds the running
/// status, a rolling console buffer, and an optional error.
/// </summary>
public sealed partial class InitProgressViewModel : ObservableObject
{
    [ObservableProperty] private string _status = "Preparing…";
    [ObservableProperty] private string _consoleLog = "";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError))]
    private string? _error;
    [ObservableProperty] private bool _isRunning;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ProgressPercent))]
    private double _progress;

    public bool HasError => Error is not null;
    public string ProgressPercent => string.Format(
        System.Globalization.CultureInfo.InvariantCulture, "{0:F1}%", Progress * 100);

    private const int MaxLines = 100;
    private readonly List<string> _lines = new();
    private string _trailing = "";

    public void Reset()
    {
        Status = "Preparing…";
        ConsoleLog = "";
        Error = null;
        IsRunning = true;
        Progress = 0.0;
        _lines.Clear();
        _trailing = "";
    }

    /// <summary>Move the bar to at least <paramref name="value"/>; never regress.</summary>
    public void BumpProgress(double value)
    {
        var v = Math.Clamp(value, 0.0, 1.0);
        if (v > Progress) Progress = v;
    }

    public void AppendLog(string chunk)
    {
        // Normalise CRLF / CR to LF — installer serial consoles often
        // emit CR. Same fix the macOS port applies.
        var normalized = chunk.Replace("\r\n", "\n").Replace('\r', '\n');
        var buf = _trailing + normalized;
        _trailing = "";
        var newlineIdx = buf.IndexOf('\n');
        while (newlineIdx >= 0)
        {
            _lines.Add(buf[..newlineIdx]);
            buf = buf[(newlineIdx + 1)..];
            newlineIdx = buf.IndexOf('\n');
        }
        _trailing = buf;
        if (_lines.Count > MaxLines) _lines.RemoveRange(0, _lines.Count - MaxLines);

        var sb = new StringBuilder(_lines.Sum(l => l.Length + 1) + _trailing.Length);
        foreach (var line in _lines) sb.Append(line).Append('\n');
        sb.Append(_trailing);
        ConsoleLog = sb.ToString();
    }
}
