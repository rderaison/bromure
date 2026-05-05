using System.Collections.ObjectModel;
using System.IO;
using System.Net;
using System.Windows;
using System.Windows.Media;
using Bromure.AC.Display;
using Bromure.AC.Mitm.Engine;
using Bromure.AC.Mitm.Proxy;
using Bromure.SandboxEngine.Wsl;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

/// <summary>
/// Lightweight equivalent of the macOS <c>TabsModel</c> + the bits of
/// <c>TabbedSessionWindow</c> that aren't AppKit-specific. Each session
/// holds the WSL distro lifetime, the per-profile MITM proxy, and a
/// small UI-facing state.
///
/// <para>This is the WSL2 implementation. The QEMU+WHPX equivalent is
/// preserved at commit <c>86be3d1</c> on the windows branch — see
/// <c>WSL2_PIVOT.md</c> for context on why we switched.</para>
/// </summary>
public sealed partial class SessionViewModel : ObservableObject, IAsyncDisposable
{
    private readonly MitmEngine _engine;
    private readonly WslSessionConfig _wslConfig;
    private WslSession? _session;
    private HttpMitmProxy? _mitm;

    [ObservableProperty] private string _profileName = "Default Profile";
    [ObservableProperty] private string _vmStatus = "Idle";
    [ObservableProperty] private string _vmStatusDetail = "";
    [ObservableProperty] private string _ipAddress = "—";
    [ObservableProperty] private bool _isRunning;
    [ObservableProperty] private bool _isBusy;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsIdle))]
    private bool _hasDisplay;

    [ObservableProperty] private bool _showCompromiseOverlay;
    [ObservableProperty] private object? _displaySurface;
    [ObservableProperty] private string _lastEvent = "Ready";
    [ObservableProperty] private int _traceCount;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsIdle))]
    private bool _hasFailure;

    [ObservableProperty] private string _failureDetail = "";
    [ObservableProperty] private string? _stderrLogPath;

    /// <summary>True iff neither the embedded display nor a failure overlay is up.</summary>
    public bool IsIdle => !HasDisplay && !HasFailure;

    /// <summary>Set by the shell when a hard precondition (e.g. WSL2 not installed)
    /// rules the session out. Renders as a permanent failure overlay
    /// instead of letting the user click Boot into an NRE.</summary>
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

    public ObservableCollection<TabModel> Tabs { get; } = new()
    {
        new TabModel("kitty"),
    };

    public SessionViewModel(Guid profileId, string profileName,
        MitmEngine engine, WslSessionConfig wslConfig)
    {
        ProfileId = profileId;
        ProfileName = profileName;
        _engine = engine;
        _wslConfig = wslConfig;
    }

    /// <summary>
    /// Optional resources whose lifetime matches this session — disposed
    /// when the session shuts down. Set by the shell after construction.
    /// </summary>
    public List<IAsyncDisposable> SessionResources { get; } = new();

    public Brush StatusBrush => IsRunning
        ? (Brush)new SolidColorBrush(Color.FromRgb(0x4C, 0xC9, 0x90))
        : (Brush)new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x99));

    /// <summary>
    /// Boot the session. Mirrors what <c>BromureAC.swift</c> does in
    /// <c>launchSession</c>: register the per-profile MITM proxy on a
    /// loopback port, import the WSL distro, drop home overlay, spawn
    /// kitty in the distro pointed at the proxy, embed the kitty HWND.
    /// </summary>
    [RelayCommand]
    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_session is not null) return;
        IsBusy = true;
        VmStatus = "Booting…";
        VmStatusDetail = "Spawning WSL distro from base rootfs…";

        try
        {
            // 1) Per-tab MITM proxy on a unique loopback port.
            // The user's profile id keys MitmEngine's per-session
            // bookkeeping (token plan, trace bucket, etc.). Bind to
            // 127.0.0.1 with port 0 → OS picks; we read it back for the
            // HTTPS_PROXY env we'll inject into the distro.
            _mitm = await _engine.RegisterAsync(ProfileId,
                new IPEndPoint(IPAddress.Loopback, 0), ct).ConfigureAwait(false);
            var proxyPort = _mitm.LocalEndpoint!.Port;

            // 2) Splice the proxy URL + Bromure CA into the session env
            // so curl/git/node trust the MITM-signed certs that come
            // back from upstream.
            var envVars = new Dictionary<string, string>(_wslConfig.EnvVars, StringComparer.Ordinal)
            {
                ["HTTP_PROXY"] = $"http://127.0.0.1:{proxyPort}",
                ["HTTPS_PROXY"] = $"http://127.0.0.1:{proxyPort}",
                ["http_proxy"] = $"http://127.0.0.1:{proxyPort}",
                ["https_proxy"] = $"http://127.0.0.1:{proxyPort}",
                // Some tools honour SSL_CERT_FILE over the system trust
                // store. The path matches where setup-wsl.sh reserves
                // the bromure CA dir; update-ca-certificates also writes
                // /etc/ssl/certs/ca-certificates.crt which most tools
                // pick up automatically.
                ["SSL_CERT_FILE"] = "/etc/ssl/certs/ca-certificates.crt",
                ["NODE_EXTRA_CA_CERTS"] = "/usr/local/share/ca-certificates/bromure/bromure-ca.crt",
            };
            var caPem = System.Text.Encoding.ASCII.GetBytes(_engine.Ca.CertificatePem);
            var perSessionConfig = _wslConfig with
            {
                EnvVars = envVars,
                BromureCaPem = caPem,
            };

            // 3) Import distro + drop home overlay + spawn kitty.
            _session = new WslSession(perSessionConfig);
            await _session.StartAsync(ct).ConfigureAwait(false);
            IsRunning = true;
            VmStatus = "Running";
            LastEvent = $"distro {_wslConfig.DistroName} up · MITM {proxyPort}";

            // 4) Embed the kitty window. Title prefix is the distro name
            // (we asked kitty to use it via --title). Polls up to 10 s
            // for the WSLg-rendered HWND to appear.
            await AttachEmbeddedDisplayAsync().ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            VmStatus = "Boot failed";
            VmStatusDetail = ex.Message;
            FailureDetail = ex.ToString();
            HasFailure = true;
            LastEvent = "Boot failed";
            IsRunning = false;
            try { await DisposeSessionAsync().ConfigureAwait(false); } catch { }
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand]
    public async Task ShutdownAsync()
    {
        if (_session is null) return;
        IsBusy = true;
        VmStatus = "Shutting down…";
        try { await _session.ShutdownAsync().ConfigureAwait(false); }
        catch { }
        IsRunning = false;
        IsBusy = false;
        VmStatus = "Stopped";
        HasDisplay = false;
        if (DisplaySurface is WslWindowHost host) host.Detach();
        DisplaySurface = null;
        await DisposeSessionAsync().ConfigureAwait(false);
        // Tear down per-session resources.
        foreach (var r in SessionResources)
        {
            try { await r.DisposeAsync().ConfigureAwait(false); } catch { }
        }
        SessionResources.Clear();
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

    private Task AttachEmbeddedDisplayAsync()
        => Application.Current.Dispatcher.InvokeAsync(() =>
        {
            var hostControl = new WslWindowHost();
            DisplaySurface = hostControl;
            HasDisplay = true;
            hostControl.Loaded += (_, _) =>
            {
                // The kitty window's title carries the distro name as
                // a prefix because we set --title bromure-ses-... when
                // spawning. Match on that to disambiguate concurrent
                // sessions.
                var titlePrefix = _wslConfig.DistroName;
                if (hostControl.Attach(titlePrefix, TimeSpan.FromSeconds(15)))
                {
                    LastEvent = "kitty window embedded";
                }
                else
                {
                    LastEvent = "kitty window not found in 15 s — WSLg may need a moment, click Reboot to retry";
                }
            };
        }).Task;

    private async Task DisposeSessionAsync()
    {
        if (_mitm is not null)
        {
            try { await _engine.UnregisterAsync(ProfileId).ConfigureAwait(false); } catch { }
            _mitm = null;
        }
        if (_session is not null)
        {
            try { await _session.DisposeAsync().ConfigureAwait(false); } catch { }
            _session = null;
        }
    }

    public string? ProgressPercent => null; // unused on the session view

    public ValueTask DisposeAsync() => new(DisposeSessionAsync());
}

public sealed partial class TabModel : ObservableObject
{
    [ObservableProperty] private string _label;
    public TabModel(string label) { _label = label; }
}
