using System.Collections.ObjectModel;
using System.Text;
using System.Windows.Threading;
using Bromure.AC.Mitm.Trace;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

/// <summary>
/// Replaces the macOS <c>TraceInspectorView.swift</c> live-tail of the
/// MITM proxy's per-request log. Pulls from the SQLite-backed
/// <see cref="TraceStore"/> on a 2 s timer (the macOS port pushes via
/// <c>@Observable</c>; here we poll because the proxy hot path lives
/// in a different VM lifetime than the UI thread).
/// </summary>
public sealed partial class TraceInspectorViewModel : ObservableObject
{
    private readonly TraceStore _store;
    private readonly IBodyEncryptor? _encryptor;
    private readonly DispatcherTimer _timer;

    public ObservableCollection<TraceRowViewModel> Rows { get; } = new();
    [ObservableProperty] private string _filter = "";
    /// <summary>Method substring filter (GET, POST, etc.). Empty = all.</summary>
    [ObservableProperty] private string _methodFilter = "";
    /// <summary>Status-code filter. "2xx"/"3xx"/"4xx"/"5xx" match by hundreds;
    /// numeric value matches exact. Empty = all.</summary>
    [ObservableProperty] private string _statusFilter = "";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SelectedRequestBody))]
    [NotifyPropertyChangedFor(nameof(SelectedResponseBody))]
    [NotifyPropertyChangedFor(nameof(SelectedBodyStored))]
    private TraceRowViewModel? _selected;

    public TraceInspectorViewModel(TraceStore store, IBodyEncryptor? encryptor = null)
    {
        _store = store;
        _encryptor = encryptor;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
        Refresh();
    }

    /// <summary>True iff the selected trace has bodies captured.
    /// Drives the visibility of the request/response body panes.</summary>
    public bool SelectedBodyStored => Selected?.Record.BodyStored == true;

    /// <summary>Request body for the selected trace, decrypted on
    /// demand through the engine's vault. Empty when no body was
    /// stored or the file is missing.</summary>
    public string SelectedRequestBody => LoadBodyAsText(TraceStore.BodyKind.Request);

    /// <summary>Response body for the selected trace.</summary>
    public string SelectedResponseBody => LoadBodyAsText(TraceStore.BodyKind.Response);

    private string LoadBodyAsText(TraceStore.BodyKind kind)
    {
        if (Selected is null || !Selected.Record.BodyStored) return "";
        try
        {
            var bytes = _store.LoadBody(Selected.Record, kind, _encryptor);
            if (bytes is null || bytes.Length == 0) return "";
            return Encoding.UTF8.GetString(bytes);
        }
        catch (Exception ex)
        {
            return $"<failed to load: {ex.Message}>";
        }
    }

    [RelayCommand]
    private void Refresh()
    {
        var recent = _store.Recent(limit: 200);
        Rows.Clear();
        foreach (var r in recent)
        {
            if (!MatchesHostPath(r) || !MatchesMethod(r) || !MatchesStatus(r)) continue;
            Rows.Add(new TraceRowViewModel(r));
        }
    }

    private bool MatchesHostPath(Bromure.AC.Mitm.Trace.TraceRecord r)
        => string.IsNullOrEmpty(Filter)
           || r.Host.Contains(Filter, StringComparison.OrdinalIgnoreCase)
           || r.Path.Contains(Filter, StringComparison.OrdinalIgnoreCase);

    private bool MatchesMethod(Bromure.AC.Mitm.Trace.TraceRecord r)
        => string.IsNullOrEmpty(MethodFilter)
           || r.Method.Equals(MethodFilter, StringComparison.OrdinalIgnoreCase);

    /// <summary>Status filter parser: empty matches all; a bare number
    /// matches the exact status; "Nxx" matches the hundreds-bucket
    /// (e.g. "4xx" matches 400-499). Anything else is treated as a
    /// no-match so a typo doesn't silently surface every row.</summary>
    private bool MatchesStatus(Bromure.AC.Mitm.Trace.TraceRecord r)
    {
        if (string.IsNullOrEmpty(StatusFilter)) return true;
        var s = StatusFilter.Trim();
        if (int.TryParse(s, out var exact)) return r.StatusCode == exact;
        if (s.Length == 3 && (s[1] == 'x' || s[1] == 'X')
                          && (s[2] == 'x' || s[2] == 'X')
                          && char.IsDigit(s[0]))
        {
            var bucket = (s[0] - '0') * 100;
            return r.StatusCode >= bucket && r.StatusCode < bucket + 100;
        }
        return false;
    }

    [RelayCommand]
    private void CopyRequestBody()
    {
        var body = SelectedRequestBody;
        if (!string.IsNullOrEmpty(body))
        {
            try { System.Windows.Clipboard.SetText(body); } catch { }
        }
    }

    [RelayCommand]
    private void CopyResponseBody()
    {
        var body = SelectedResponseBody;
        if (!string.IsNullOrEmpty(body))
        {
            try { System.Windows.Clipboard.SetText(body); } catch { }
        }
    }
}

public sealed class TraceRowViewModel
{
    public TraceRowViewModel(TraceRecord r)
    {
        Record = r;
        TimestampLocal = r.Timestamp.ToLocalTime().ToString("HH:mm:ss.fff");
        StatusLabel = r.StatusCode == 0 ? "—" : r.StatusCode.ToString();
        Latency = $"{r.LatencyMs:F0} ms";
        SwapsLabel = r.Swaps.Count == 0 ? "—" : $"{r.Swaps.Count} swap(s)";
        LeaksLabel = r.Leaks.Count == 0 ? "" : $"⚠ {r.Leaks.Count} leak(s)";
    }
    public TraceRecord Record { get; }
    public string TimestampLocal { get; }
    public string StatusLabel { get; }
    public string Latency { get; }
    public string SwapsLabel { get; }
    public string LeaksLabel { get; }
    public string Host => Record.Host;
    public string Method => Record.Method;
    public string Path => Record.Path;
}
