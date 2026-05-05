using System.Text;
using Bromure.SandboxEngine.Image;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

/// <summary>
/// Drives the Ubuntu base image bake overlay. Reuses the
/// <see cref="InitializingView"/> shape (progress bar + console)
/// because the user experience is the same: a thing is happening, here's
/// the bar, here's the live output, hit Cancel if you must.
/// </summary>
public sealed partial class BakeOverlayViewModel : ObservableObject
{
    private readonly AlpineInstaller _baker;
    private CancellationTokenSource? _cts;

    [ObservableProperty] private bool _isVisible;
    [ObservableProperty] private string _status = "Preparing…";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ProgressPercent))]
    private double _progress;
    [ObservableProperty] private bool _isRunning;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError))]
    private string? _error;
    [ObservableProperty] private string _consoleLog = "";

    /// Same 256 KiB rolling buffer we use for the regular session
    /// console — bake produces many KB of apt output.
    private const int ConsoleBufferMaxBytes = 256 * 1024;

    /// Fired when the bake finishes successfully so the caller (Settings
    /// pane) can refresh the "Ubuntu base: ready" indicator.
    public event Action? Completed;

    public bool HasError => Error is not null;

    public BakeOverlayViewModel(AlpineInstaller baker)
    {
        _baker = baker;
    }

    public void Show()
    {
        Status = "Preparing…";
        Progress = 0;
        Error = null;
        ConsoleLog = "";
        IsRunning = true;
        IsVisible = true;
    }

    [RelayCommand]
    private async Task RunAsync()
    {
        Show();
        _cts = new CancellationTokenSource();
        try
        {
            await _baker.BakeAsync(new Progress<AlpineInstaller.BakeProgress>(OnProgress), _cts.Token)
                .ConfigureAwait(true);
            IsRunning = false;
            Status = "Ubuntu base image ready.";
            Progress = 1.0;
            Completed?.Invoke();
        }
        catch (OperationCanceledException)
        {
            IsRunning = false;
            Error = "Cancelled.";
        }
        catch (Exception ex)
        {
            IsRunning = false;
            Error = ex.Message;
            AppendLog("\n[bake] " + ex + "\n");
        }
        finally
        {
            _cts?.Dispose();
            _cts = null;
        }
    }

    [RelayCommand]
    private void Cancel()
    {
        _cts?.Cancel();
    }

    [RelayCommand]
    private void Dismiss()
    {
        IsVisible = false;
        Error = null;
    }

    private void OnProgress(AlpineInstaller.BakeProgress p)
    {
        Status = p.Message;
        if (p.Fraction > Progress) Progress = p.Fraction;
        if (!string.IsNullOrEmpty(p.ConsoleAppend)) AppendLog(p.ConsoleAppend);
    }

    private void AppendLog(string chunk)
    {
        var combined = ConsoleLog + chunk;
        if (combined.Length > ConsoleBufferMaxBytes)
        {
            combined = "…" + combined[^ConsoleBufferMaxBytes..];
        }
        ConsoleLog = combined;
    }

    public string ProgressPercent => string.Format(
        System.Globalization.CultureInfo.InvariantCulture, "{0:F1}%", Progress * 100);
}
