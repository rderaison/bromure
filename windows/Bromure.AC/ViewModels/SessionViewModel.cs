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
/// One running session = one kitty WSLg window for a profile. The
/// kitty window is a free-floating WSLg-rendered Windows window
/// (NOT embedded). BromureAC is the control panel; the user
/// alt-tabs to kitty for the actual terminal. Tab management is
/// kitty's job — it has a built-in tab strip via Ctrl+Shift+T.
///
/// <para>This shape mirrors the macOS port: <c>ACAppDelegate</c>
/// shows a profile picker; clicking a profile opens a
/// <c>TabbedSessionWindow</c> that lives as a separate top-level
/// window. We have the same separation, just without the in-process
/// embedding.</para>
/// </summary>
public sealed partial class SessionViewModel : ObservableObject, IAsyncDisposable
{
    private readonly MitmEngine _engine;
    private readonly Profile? _activeProfile;
    private readonly string _baseRootfsPath;
    private readonly string _sessionRoot;
    private HttpMitmProxy? _mitm;
    private WslSession? _session;

    [ObservableProperty] private string _profileName = "Default Profile";
    [ObservableProperty] private string _vmStatus = "Idle";
    [ObservableProperty] private string _vmStatusDetail = "";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusBrush))]
    private bool _isRunning;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private bool _hasFailure;
    [ObservableProperty] private string _failureDetail = "";
    [ObservableProperty] private string? _stderrLogPath;

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
    /// Boot session = bring up the per-profile MITM proxy + import a
    /// fresh WSL distro + spawn kitty via WSLg as a separate Windows
    /// window. Kitty's own tab UI handles multi-pane work — the user
    /// gets a real OS window they can move, alt-tab to, etc.
    /// </summary>
    [RelayCommand]
    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_session is not null) return;
        IsBusy = true;
        VmStatus = "Booting…";
        VmStatusDetail = "Bringing up MITM proxy…";

        try
        {
            _mitm = await _engine.RegisterAsync(ProfileId,
                new IPEndPoint(IPAddress.Loopback, 0), ct).ConfigureAwait(true);
            var proxyPort = _mitm.LocalEndpoint!.Port;
            VmStatusDetail = $"Importing WSL distro… (proxy 127.0.0.1:{proxyPort})";

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
                // No --start-as=fullscreen and no --title-prefix-matching
                // logic. Kitty surfaces as a free-floating WSLg-rendered
                // RAIL_WINDOW; the user manages it like any OS window.
                // The title carries the profile name so the taskbar
                // entry is recognisable.
                GuestArgv = new[]
                {
                    "kitty",
                    "--title", $"{ProfileName} — Bromure",
                },
                BromureCaPem = System.Text.Encoding.ASCII.GetBytes(_engine.Ca.CertificatePem),
            };

            _session = new WslSession(cfg);
            await _session.StartAsync(ct).ConfigureAwait(true);
            IsRunning = true;
            VmStatus = "Running";
            VmStatusDetail = $"kitty up · MITM 127.0.0.1:{proxyPort}";
        }
        catch (Exception ex)
        {
            VmStatus = "Boot failed";
            VmStatusDetail = ex.Message;
            FailureDetail = ex.ToString();
            HasFailure = true;
            IsRunning = false;
            try { await DisposeInternalsAsync().ConfigureAwait(false); } catch { }
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand]
    public async Task ShutdownAsync()
    {
        IsBusy = true;
        VmStatus = "Shutting down…";
        await DisposeInternalsAsync().ConfigureAwait(true);
        IsRunning = false;
        IsBusy = false;
        VmStatus = "Stopped";
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

    private async Task DisposeInternalsAsync()
    {
        if (_session is not null)
        {
            try { await _session.DisposeAsync().ConfigureAwait(false); } catch { }
            _session = null;
        }
        if (_mitm is not null)
        {
            try { await _engine.UnregisterAsync(ProfileId).ConfigureAwait(false); } catch { }
            _mitm = null;
        }
    }

    public ValueTask DisposeAsync() => new(ShutdownAsync());
}
