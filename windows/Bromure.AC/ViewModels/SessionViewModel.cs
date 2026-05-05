using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Windows;
using System.Windows.Media;
using Bromure.AC.Display;
using Bromure.AC.Mitm.Engine;
using Bromure.SandboxEngine.Disk;
using Bromure.SandboxEngine.Image;
using Bromure.SandboxEngine.Qemu;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

/// <summary>
/// Lightweight equivalent of the macOS <c>TabsModel</c> + the bits of
/// <c>TabbedSessionWindow</c> that aren't AppKit-specific. Each session
/// holds the QEMU supervisor lifetime, the per-profile MITM proxy, and
/// a small UI-facing state.
/// </summary>
public sealed partial class SessionViewModel : ObservableObject, IAsyncDisposable
{
    private readonly MitmEngine _engine;
    private readonly ImageManager _images;
    private readonly QemuConfig _qemuConfig;
    private QemuSupervisor? _supervisor;

    [ObservableProperty] private string _profileName = "Default Profile";
    [ObservableProperty] private string _vmStatus = "Idle";
    [ObservableProperty] private string _vmStatusDetail = "";
    [ObservableProperty] private string _ipAddress = "—";
    [ObservableProperty] private bool _isRunning;
    [ObservableProperty] private bool _isBusy;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsIdle))]
    [NotifyPropertyChangedFor(nameof(IsShowingSerial))]
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
    [ObservableProperty] private string _serialBuffer = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsIdle))]
    [NotifyPropertyChangedFor(nameof(IsShowingSerial))]
    private bool _hasSerialConsole;

    /// True iff neither the embedded display nor the serial pane is up.
    /// Drives the placeholder "Running…" StackPanel so it doesn't
    /// occlude the serial console pane.
    public bool IsIdle => !HasDisplay && !HasSerialConsole && !HasFailure;
    /// True iff serial console is attached but no embedded display.
    public bool IsShowingSerial => !HasDisplay && HasSerialConsole;
    private SerialConsoleClient? _serial;
    /// 256 KiB rolling buffer — long enough for boot + a few interactive
    /// minutes; short enough that the WPF TextBlock layout stays cheap.
    private const int SerialBufferMaxBytes = 256 * 1024;

    /// <summary>
    /// Set by the shell when a hard precondition (e.g. QEMU not installed)
    /// rules the session out. Renders as a permanent failure overlay
    /// instead of letting the user click Boot into an NRE.
    /// </summary>
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
        MitmEngine engine, ImageManager images, QemuConfig qemuConfig)
    {
        ProfileId = profileId;
        ProfileName = profileName;
        _engine = engine;
        _images = images;
        _qemuConfig = qemuConfig;
    }

    /// <summary>
    /// Optional resources whose lifetime matches this session — e.g.
    /// the per-session <see cref="Bromure.SandboxEngine.Sharing.FolderShareServer"/>
    /// (sshd lifecycle) — disposed when the session shuts down. Set
    /// by the shell after construction.
    /// </summary>
    public List<IAsyncDisposable> SessionResources { get; } = new();

    public Brush StatusBrush => IsRunning
        ? (Brush)new SolidColorBrush(Color.FromRgb(0x4C, 0xC9, 0x90))
        : (Brush)new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x99));

    /// <summary>
    /// Boot the VM. Mirrors what <c>BromureAC.swift</c> does in
    /// <c>launchSession</c>: register MITM hooks for the profile, spawn
    /// QEMU under WHPX, hand the VM display surface to the view.
    /// </summary>
    [RelayCommand]
    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_supervisor is not null) return;
        IsBusy = true;
        VmStatus = "Booting…";
        VmStatusDetail = "Spawning QEMU under WHPX. First boot of an Alpine ISO takes a few seconds.";

        try
        {
            _supervisor = new QemuSupervisor(_qemuConfig);
            _supervisor.GuestShutdown += () =>
            {
                LastEvent = "Guest sent ACPI shutdown";
                IsRunning = false;
            };
            _supervisor.Crashed += ex =>
            {
                LastEvent = "QEMU crashed: " + ex.Message;
                IsRunning = false;
            };
            await _supervisor.StartAsync(ct).ConfigureAwait(false);
            IsRunning = true;
            VmStatus = "Running";
            LastEvent = $"QEMU PID {_supervisor.Process.Id}";

            // Embedded display only makes sense when QEMU is actually
            // drawing a window. In headless (DisplayMode.None) there's
            // no SDL/GTK window to find, so attempting to attach
            // produced a confusing "window not found" footer message
            // for the working case.
            switch (_qemuConfig.Display)
            {
                case DisplayMode.LocalSdl:
                case DisplayMode.LocalGtk:
                    await AttachEmbeddedDisplayAsync(_supervisor.Process.Id);
                    VmStatusDetail = "QMP handshake complete. QEMU window embedded.";
                    break;
                default:
                    HasDisplay = false;
                    DisplaySurface = null;
                    VmStatusDetail = "Running headless. QMP + serial console active.";
                    break;
            }

            // Attach the host-side serial reader so the user sees boot
            // output / login prompt / dmesg in the SessionView's console
            // pane without needing fb-agent. QEMU's `-serial tcp:` opens
            // its listener slightly after process start; same connect
            // backoff pattern as QMP.
            if (!string.IsNullOrEmpty(_qemuConfig.SerialEndpoint))
            {
                try
                {
                    _serial = new SerialConsoleClient(_qemuConfig.SerialEndpoint!,
                        chunk => Application.Current.Dispatcher.BeginInvoke(() => AppendSerial(chunk)));
                    await _serial.StartAsync(TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
                    HasSerialConsole = true;
                    LastEvent = $"QEMU PID {_supervisor.Process.Id} · serial attached";
                }
                catch (Exception ex)
                {
                    // Non-fatal — the VM is still running, the user just
                    // doesn't get the live console. Surface as a status
                    // line, not a failure overlay.
                    HasSerialConsole = false;
                    LastEvent = "Serial console not attached: " + ex.Message;
                }
            }
        }
        catch (QemuStartException qex)
        {
            VmStatus = "Boot failed";
            VmStatusDetail = "QEMU exited before opening the QMP control socket.";
            FailureDetail = string.IsNullOrEmpty(qex.StderrTail)
                ? qex.Message
                : qex.StderrTail;
            StderrLogPath = qex.StderrLogPath;
            HasFailure = true;
            LastEvent = "Boot failed (see log)";
            IsRunning = false;
            try { await DisposeSupervisorAsync().ConfigureAwait(false); } catch { }
        }
        catch (Exception ex)
        {
            VmStatus = "Failed";
            VmStatusDetail = ex.Message;
            FailureDetail = ex.ToString();
            HasFailure = true;
            LastEvent = "Boot failed";
            IsRunning = false;
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand]
    public async Task ShutdownAsync()
    {
        if (_supervisor is null) return;
        IsBusy = true;
        VmStatus = "Shutting down…";
        try { await _supervisor.ShutdownAsync().ConfigureAwait(false); }
        catch { }
        IsRunning = false;
        IsBusy = false;
        VmStatus = "Stopped";
        HasDisplay = false;
        if (DisplaySurface is QemuWindowHost host) host.Detach();
        DisplaySurface = null;
        await DisposeSupervisorAsync().ConfigureAwait(false);
        // Tear down per-session resources (sshd, etc).
        foreach (var r in SessionResources)
        {
            try { await r.DisposeAsync().ConfigureAwait(false); } catch { }
        }
        SessionResources.Clear();
    }

    [RelayCommand]
    private void OpenLog()
    {
        if (string.IsNullOrEmpty(StderrLogPath) || !File.Exists(StderrLogPath)) return;
        try
        {
            Process.Start(new ProcessStartInfo
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

    [RelayCommand]
    private void DismissFailure()
    {
        HasFailure = false;
        FailureDetail = "";
    }

    private void AppendSerial(string chunk)
    {
        // Drop ANSI cursor-positioning escapes minimally — the kernel
        // ring + most boot output is printable ASCII; keeping things
        // simple here. A full VT100 emulator is overkill for a debug
        // console, and Alpine's BIOS+kernel boot output is mostly clean.
        var combined = SerialBuffer + chunk;
        if (combined.Length > SerialBufferMaxBytes)
        {
            combined = combined[^SerialBufferMaxBytes..];
        }
        SerialBuffer = combined;
    }

    private Task AttachEmbeddedDisplayAsync(int pid)
        => Application.Current.Dispatcher.InvokeAsync(() =>
        {
            var hostControl = new QemuWindowHost
            {
                // Inject keystrokes via QMP — WPF eats WM_KEYDOWN before
                // GTK can see it.
                Qmp = _supervisor?.Qmp,
            };
            DisplaySurface = hostControl;
            HasDisplay = true;
            // Defer the Attach until the host has been laid out so its
            // HWND exists. Loaded fires before the first render.
            hostControl.Loaded += (_, _) =>
            {
                if (hostControl.Attach(pid, TimeSpan.FromSeconds(5)))
                {
                    LastEvent = "QEMU display attached";
                }
                else
                {
                    LastEvent = "QEMU display attach failed (window not found in 5s)";
                }
            };
        }).Task;

    private async Task DisposeSupervisorAsync()
    {
        if (_serial is not null)
        {
            try { await _serial.DisposeAsync().ConfigureAwait(false); } catch { }
            _serial = null;
            HasSerialConsole = false;
        }
        if (_supervisor is not null)
        {
            try { await _supervisor.DisposeAsync().ConfigureAwait(false); } catch { }
            _supervisor = null;
        }
    }

    public string? ProgressPercent => null; // unused on the session view

    public ValueTask DisposeAsync() => new(DisposeSupervisorAsync());
}

public sealed partial class TabModel : ObservableObject
{
    [ObservableProperty] private string _label;
    public TabModel(string label) { _label = label; }
}
