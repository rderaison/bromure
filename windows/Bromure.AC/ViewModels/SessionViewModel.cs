using System.Collections.ObjectModel;
using System.IO;
using System.Net;
using System.Windows.Media;
using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Engine;
using Bromure.AC.Mitm.Proxy;
using Bromure.SandboxEngine.Wsl;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

/// <summary>
/// One Bromure session. Replaces the macOS-port <c>TabsModel</c> +
/// <c>TabbedSessionWindow</c> for the WSL2 implementation. Holds the
/// per-profile MITM proxy lifetime and a collection of
/// <see cref="TabViewModel"/>s (one WSL distro per tab).
/// </summary>
public sealed partial class SessionViewModel : ObservableObject, IAsyncDisposable
{
    private readonly MitmEngine _engine;
    private readonly Profile? _activeProfile;
    private readonly string _baseRootfsPath;
    private readonly string _sessionRoot;
    private HttpMitmProxy? _mitm;

    [ObservableProperty] private string _profileName = "Default Profile";
    [ObservableProperty] private string _vmStatus = "Idle";
    [ObservableProperty] private string _vmStatusDetail = "";
    [ObservableProperty] private string _ipAddress = "—";

    /// <summary>True iff at least one tab is running.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusBrush))]
    private bool _isRunning;

    [ObservableProperty] private bool _isBusy;

    /// <summary>True iff at least one tab has its WSLg embed up.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsIdle))]
    private bool _hasDisplay;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsIdle))]
    private bool _hasFailure;

    [ObservableProperty] private string _failureDetail = "";
    [ObservableProperty] private string? _stderrLogPath;

    public bool IsIdle => !HasDisplay && !HasFailure;

    public string? PreflightError
    {
        get => _preflightError;
        set
        {
            SetProperty(ref _preflightError, value);
            if (!string.IsNullOrEmpty(value))
            {
                FailureDetail = value;
                VmStatusDetail = "Pre-flight check failed.";
                HasFailure = true;
            }
        }
    }
    private string? _preflightError;

    public Guid ProfileId { get; }

    public ObservableCollection<TabViewModel> Tabs { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ActiveDisplaySurface))]
    private TabViewModel? _activeTab;

    /// <summary>The display the SessionView's <c>ContentControl</c> binds to —
    /// the active tab's <see cref="WslWindowHost"/>. Switches when
    /// the user clicks a different tab.</summary>
    public object? ActiveDisplaySurface => ActiveTab?.WindowHost;

    public List<IAsyncDisposable> SessionResources { get; } = new();

    public Brush StatusBrush => IsRunning
        ? (Brush)new SolidColorBrush(Color.FromRgb(0x4C, 0xC9, 0x90))
        : (Brush)new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x99));

    public SessionViewModel(Guid profileId, string profileName,
        MitmEngine engine, Profile? activeProfile,
        string baseRootfsPath, string sessionRoot)
    {
        ProfileId = profileId;
        ProfileName = profileName;
        _engine = engine;
        _activeProfile = activeProfile;
        _baseRootfsPath = baseRootfsPath;
        _sessionRoot = sessionRoot;
    }

    /// <summary>
    /// Boot session = bring up the per-profile MITM proxy + create
    /// the first tab. Subsequent tabs are added via NewTabCommand.
    /// </summary>
    [RelayCommand]
    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_mitm is not null) return;
        IsBusy = true;
        VmStatus = "Booting…";
        VmStatusDetail = "Bringing up MITM proxy…";

        try
        {
            // Per-profile MITM proxy on a unique loopback port. All
            // tabs in this session share the same proxy — the swap
            // map is keyed by profile, not by tab, so tokens issued
            // via this profile are recognised across tabs.
            _mitm = await _engine.RegisterAsync(ProfileId,
                new IPEndPoint(IPAddress.Loopback, 0), ct).ConfigureAwait(true);
            var proxyPort = _mitm.LocalEndpoint!.Port;
            VmStatusDetail = $"MITM proxy on 127.0.0.1:{proxyPort}";

            await NewTabAsyncCore(proxyPort, ct).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            VmStatus = "Boot failed";
            VmStatusDetail = ex.Message;
            FailureDetail = ex.ToString();
            HasFailure = true;
            IsRunning = false;
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Add another tab — same profile, fresh distro.</summary>
    [RelayCommand]
    public async Task NewTabAsync(CancellationToken ct = default)
    {
        if (_mitm is null)
        {
            await StartAsync(ct).ConfigureAwait(false);
            return;
        }
        IsBusy = true;
        try { await NewTabAsyncCore(_mitm.LocalEndpoint!.Port, ct).ConfigureAwait(true); }
        finally { IsBusy = false; }
    }

    private async Task NewTabAsyncCore(int proxyPort, CancellationToken ct)
    {
        var tabId = Tabs.Count + 1;
        var distroName = "bromure-ses-" + Guid.NewGuid().ToString("N")[..8];
        var installPath = Path.Combine(_sessionRoot, distroName);

        var envVars = _activeProfile is not null
            ? new Dictionary<string, string>(ProfileEnvExports.ForProfile(_activeProfile), StringComparer.Ordinal)
            : new Dictionary<string, string>(StringComparer.Ordinal);
        envVars["HTTP_PROXY"] = $"http://127.0.0.1:{proxyPort}";
        envVars["HTTPS_PROXY"] = $"http://127.0.0.1:{proxyPort}";
        envVars["http_proxy"] = $"http://127.0.0.1:{proxyPort}";
        envVars["https_proxy"] = $"http://127.0.0.1:{proxyPort}";
        envVars["SSL_CERT_FILE"] = "/etc/ssl/certs/ca-certificates.crt";
        envVars["NODE_EXTRA_CA_CERTS"] = "/usr/local/share/ca-certificates/bromure/bromure-ca.crt";

        var cfg = new WslSessionConfig
        {
            BaseRootfsPath = _baseRootfsPath,
            DistroName = distroName,
            InstallPath = installPath,
            HomeFiles = SessionHomeBuilder.Build(_activeProfile),
            EnvVars = envVars,
            GuestArgv = new[]
            {
                "kitty", "--title", distroName, "--start-as=fullscreen",
            },
            BromureCaPem = System.Text.Encoding.ASCII.GetBytes(_engine.Ca.CertificatePem),
        };

        var tab = new TabViewModel($"tab {tabId}", cfg);
        Tabs.Add(tab);
        ActiveTab = tab;

        try { await tab.StartAsync(ct).ConfigureAwait(true); }
        catch
        {
            Tabs.Remove(tab);
            if (ActiveTab == tab) ActiveTab = Tabs.Count > 0 ? Tabs[^1] : null;
            throw;
        }

        // Re-fire ActiveDisplaySurface change in case Tab's WindowHost
        // landed during StartAsync after we set ActiveTab.
        OnPropertyChanged(nameof(ActiveDisplaySurface));
        IsRunning = true;
        HasDisplay = true;
        VmStatus = "Running";
    }

    /// <summary>Close a tab — disposes its WSL distro and removes
    /// it from the strip. If it was the active tab, focus shifts
    /// to the previous tab (or none).</summary>
    [RelayCommand]
    public async Task CloseTabAsync(TabViewModel? tab)
    {
        if (tab is null) return;
        var idx = Tabs.IndexOf(tab);
        if (idx < 0) return;
        await tab.DisposeAsync().ConfigureAwait(true);
        Tabs.Remove(tab);
        if (Tabs.Count == 0)
        {
            ActiveTab = null;
            HasDisplay = false;
            IsRunning = false;
            VmStatus = "Stopped";
        }
        else
        {
            ActiveTab = Tabs[Math.Max(0, idx - 1)];
        }
        OnPropertyChanged(nameof(ActiveDisplaySurface));
    }

    /// <summary>Activate a tab (clicked from the strip).</summary>
    [RelayCommand]
    private void ActivateTab(TabViewModel? tab)
    {
        if (tab is null) return;
        ActiveTab = tab;
        foreach (var t in Tabs) t.IsActive = ReferenceEquals(t, tab);
    }

    [RelayCommand]
    public async Task ShutdownAsync()
    {
        IsBusy = true;
        VmStatus = "Shutting down…";
        // Close all tabs first (each disposes its distro).
        var snapshot = Tabs.ToArray();
        foreach (var tab in snapshot)
        {
            try { await tab.DisposeAsync().ConfigureAwait(true); } catch { }
        }
        Tabs.Clear();
        ActiveTab = null;
        HasDisplay = false;
        IsRunning = false;

        if (_mitm is not null)
        {
            try { await _engine.UnregisterAsync(ProfileId).ConfigureAwait(false); } catch { }
            _mitm = null;
        }

        foreach (var r in SessionResources)
        {
            try { await r.DisposeAsync().ConfigureAwait(false); } catch { }
        }
        SessionResources.Clear();

        IsBusy = false;
        VmStatus = "Stopped";
        OnPropertyChanged(nameof(ActiveDisplaySurface));
    }

    [RelayCommand]
    private void DismissFailure()
    {
        HasFailure = false;
        FailureDetail = "";
    }

    [RelayCommand]
    private void OpenLog()
    {
        if (string.IsNullOrEmpty(StderrLogPath) || !File.Exists(StderrLogPath)) return;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "notepad.exe",
                Arguments = $"\"{StderrLogPath}\"",
                UseShellExecute = true,
            });
        }
        catch { /* best-effort */ }
    }

    [RelayCommand]
    private void CopyLog()
    {
        if (string.IsNullOrEmpty(FailureDetail)) return;
        try { System.Windows.Clipboard.SetText(FailureDetail); }
        catch { }
    }

    public string? ProgressPercent => null;

    public ValueTask DisposeAsync() => new(ShutdownAsync());
}
