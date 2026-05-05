using System.Windows;
using Bromure.AC.Display;
using Bromure.SandboxEngine.Wsl;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Bromure.AC.ViewModels;

/// <summary>
/// One kitty tab in a Bromure session. Owns its own
/// <see cref="WslSession"/> (one WSL distro per tab — independent
/// filesystem and process tree) and its own
/// <see cref="WslWindowHost"/> (one HwndHost reparented around the
/// WSLg-rendered kitty HWND).
///
/// <para>Multi-tab parity with the macOS port. All tabs share the
/// same profile and the same MITM proxy port (a single
/// <see cref="Bromure.AC.Mitm.Engine.MitmEngine"/> registration per
/// profile); per-tab isolation comes from the per-tab WSL distro.</para>
/// </summary>
public sealed partial class TabViewModel : ObservableObject, IAsyncDisposable
{
    private readonly WslSessionConfig _cfg;
    private WslSession? _session;
    private WslWindowHost? _host;

    [ObservableProperty] private string _label;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private bool _isRunning;
    [ObservableProperty] private string _statusDetail = "";
    [ObservableProperty] private bool _isActive;

    /// <summary>The HwndHost the SessionView's <c>ContentControl</c>
    /// renders when this tab is active. Created lazily on
    /// <see cref="StartAsync"/> so we don't burn a window handle for
    /// tabs that haven't booted yet.</summary>
    [ObservableProperty] private WslWindowHost? _windowHost;

    public string DistroName => _cfg.DistroName;

    public TabViewModel(string label, WslSessionConfig cfg)
    {
        _label = label;
        _cfg = cfg;
    }

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_session is not null) return;
        IsBusy = true;
        StatusDetail = "Importing distro…";
        try
        {
            _session = new WslSession(_cfg);
            await _session.StartAsync(ct).ConfigureAwait(true);
            IsRunning = true;
            StatusDetail = "kitty up";

            await Application.Current.Dispatcher.InvokeAsync(() =>
            {
                _host = new WslWindowHost();
                WindowHost = _host;
                _host.Loaded += (_, _) =>
                {
                    if (_host!.Attach(_cfg.DistroName, TimeSpan.FromSeconds(15)))
                    {
                        StatusDetail = "kitty embedded";
                    }
                    else
                    {
                        StatusDetail = "kitty window not found in 15 s";
                    }
                };
            });
        }
        catch (Exception ex)
        {
            StatusDetail = "boot failed: " + ex.Message;
            IsRunning = false;
            try { await DisposeAsync().ConfigureAwait(false); } catch { }
            throw;
        }
        finally
        {
            IsBusy = false;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_host is not null)
        {
            try { _host.Detach(); } catch { }
            _host = null;
            WindowHost = null;
        }
        if (_session is not null)
        {
            try { await _session.DisposeAsync().ConfigureAwait(false); } catch { }
            _session = null;
        }
        IsRunning = false;
    }
}
