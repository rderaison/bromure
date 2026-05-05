using System.Collections.ObjectModel;
using System.IO;
using System.Reflection;
using Bromure.AC.Consent;
using Bromure.AC.Core.Enrollment;
using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.Engine;
using Bromure.SandboxEngine.Image;
using Bromure.SandboxEngine.Qemu;
using Bromure.SandboxEngine.Sharing;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

public enum ShellPhase
{
    Welcome,
    Initializing,
    Session,
}

/// <summary>
/// Top-level state machine for the host shell. Mirrors what the macOS
/// <c>BromureAC.swift</c> NSApplicationDelegate does:
/// <list type="bullet">
///   <item>If no base image is on disk → <see cref="ShellPhase.Welcome"/>.</item>
///   <item>Click "Get Started" → <see cref="ShellPhase.Initializing"/>
///   while the image downloads.</item>
///   <item>Image ready → <see cref="ShellPhase.Session"/>; the QEMU
///   supervisor + MITM stack come up on demand.</item>
/// </list>
/// </summary>
public sealed partial class ShellViewModel : ObservableObject
{
    private readonly AppServices _services;
    private readonly ImageManager _images;
    private readonly MitmEngine _engine;
    private readonly ProfileStore _profileStore;

    [ObservableProperty] private ShellPhase _phase = ShellPhase.Welcome;
    [ObservableProperty] private InitProgressViewModel _progress = new();
    [ObservableProperty] private SessionViewModel? _session;
    [ObservableProperty] private string _imageInfoLine = "";

    [ObservableProperty] private NavigationItem _selectedNavigation;
    public ObservableCollection<NavigationItem> Navigation { get; } = new()
    {
        new NavigationItem("Sessions", "◆", NavigationKind.Sessions, selected: true),
        new NavigationItem("Profiles", "◇", NavigationKind.Profiles),
        new NavigationItem("Trace inspector", "◇", NavigationKind.TraceInspector),
        new NavigationItem("Approvals", "◇", NavigationKind.Approvals),
        new NavigationItem("Settings", "◇", NavigationKind.Settings),
    };

    public ProfilesViewModel ProfilesPane { get; }
    public TraceInspectorViewModel TraceInspectorPane { get; }
    public ApprovalsViewModel ApprovalsPane { get; }
    public SettingsViewModel SettingsPane { get; }
    public AlpineInstaller? Baker { get; }
    public BakeOverlayViewModel? BakeOverlay { get; }

    public ShellViewModel(AppServices services)
    {
        _services = services;
        _services.Paths.EnsureDirectory(_services.Paths.ImagesDirectory);
        _services.Paths.EnsureDirectory(_services.Paths.SessionsDirectory);
        _services.Paths.EnsureDirectory(_services.Paths.AppDataRoot);

        _images = new ImageManager(_services.Paths);
        var presenter = new WpfConsentPresenter();
        _engine = new MitmEngine(_services.Paths, _services.Secrets, presenter);

        _profileStore = new ProfileStore(_services.Paths.ProfilesDirectory);
        var profileStore = _profileStore;
        var enrollment = new EnrollmentStore(_services.Paths, _services.Secrets);

        // QEMU resolution may fail (no QEMU installed); the baker is null
        // in that case and the Settings pane disables the bake button.
        AlpineInstaller? baker = null;
        try
        {
            var qemu = QemuPaths.Resolve();
            var alpine = new AlpineNetboot(_services.Paths);
            baker = new AlpineInstaller(_services.Paths, alpine, qemu);
        }
        catch (FileNotFoundException) { /* surfaced elsewhere */ }
        Baker = baker;
        BakeOverlay = baker is null ? null : new BakeOverlayViewModel(baker);

        ProfilesPane = new ProfilesViewModel(profileStore);
        TraceInspectorPane = new TraceInspectorViewModel(_engine.TraceStore);
        ApprovalsPane = new ApprovalsViewModel(_engine.Consent);
        SettingsPane = new SettingsViewModel(_services.Paths, enrollment, _engine, _services.Settings, baker)
        {
            BakeOverlay = BakeOverlay,
        };

        _selectedNavigation = Navigation[0];

        UpdateImageInfoLine();
        ResolvePhaseFromCache();
    }

    partial void OnSelectedNavigationChanged(NavigationItem value)
    {
        foreach (var n in Navigation) n.IsSelected = n == value;
    }

    public MitmEngine Engine => _engine;
    public ImageManager Images => _images;
    public bool HasError => Progress.Error is not null;

    private void ResolvePhaseFromCache()
    {
        // We can land in Session phase if *either* a baked Ubuntu base
        // exists (preferred) or Alpine virt ISO is cached (fallback).
        // PrepareSessionSync picks the right disk regardless.
        var ubuntuBaked = File.Exists(Path.Combine(_services.Paths.ImagesDirectory, AlpineInstaller.OutputBaseFileName));
        var alpineCached = _images.IsCached(ImageManager.AlpineVirt);
        Phase = (ubuntuBaked || alpineCached) ? ShellPhase.Session : ShellPhase.Welcome;
        if (Phase == ShellPhase.Session) PrepareSessionSync();
    }

    [RelayCommand]
    private async Task StartAsync()
    {
        Phase = ShellPhase.Initializing;
        Progress.Reset();
        Progress.Status = "Downloading Alpine virt 3.20.3…";

        var progressReporter = new Progress<DownloadProgress>(report =>
        {
            Progress.BumpProgress(report.Fraction);
            Progress.Status = report.IsDone
                ? $"Downloaded {report.BytesCopiedHuman}. Finalising…"
                : $"{report.BytesCopiedHuman} / {report.TotalBytesHuman} ({report.SpeedHuman})";
            if (!report.IsDone)
            {
                Progress.AppendLog($"  {report.BytesCopiedHuman} / {report.TotalBytesHuman} @ {report.SpeedHuman}\n");
            }
        });

        try
        {
            await _images.EnsureAvailableAsync(ImageManager.AlpineVirt, progressReporter).ConfigureAwait(true);
            Progress.Status = "Image ready.";
            Progress.IsRunning = false;
            Progress.BumpProgress(1.0);
            Progress.AppendLog("\nbase image staged at " + _images.LocalPath(ImageManager.AlpineVirt) + "\n");
            UpdateImageInfoLine();
            PrepareSessionSync();
            Phase = ShellPhase.Session;
        }
        catch (Exception ex)
        {
            Progress.Error = ex.Message;
            Progress.IsRunning = false;
        }
    }

    [RelayCommand]
    private void Cancel()
    {
        var ubuntuBaked = File.Exists(Path.Combine(_services.Paths.ImagesDirectory, AlpineInstaller.OutputBaseFileName));
        var alpineCached = _images.IsCached(ImageManager.AlpineVirt);
        Phase = (ubuntuBaked || alpineCached) ? ShellPhase.Session : ShellPhase.Welcome;
    }

    private void PrepareSessionSync()
    {
        if (Session is not null) return;

        var sessionRoot = Path.Combine(_services.Paths.SessionsDirectory, "default-session");
        Directory.CreateDirectory(sessionRoot);

        // QemuPaths picks (in order) bundled-with-installer / winget /
        // PATH so the host is identical at dev time vs ship time.
        QemuPaths.Resolution paths;
        try { paths = QemuPaths.Resolve(); }
        catch (FileNotFoundException ex)
        {
            // No QEMU at all. Build a stub session VM that surfaces the
            // missing-dependency error rather than NRE'ing later.
            var stubCfg = new QemuConfig
            {
                QemuExecutable = "qemu-system-x86_64.exe",
                QmpEndpoint = "tcp:127.0.0.1:0",
            };
            Session = new SessionViewModel(
                Guid.Parse("00000000-0000-0000-0000-000000000001"),
                "Default Profile (no QEMU)", _engine, _images, stubCfg);
            Session.PreflightError = ex.Message;
            return;
        }

        // Per-session NVRAM file copied from the firmware's vars
        // template. UEFI only used when both code+vars are available
        // AND the user picked a graphical display mode. Headless boot
        // skips OVMF: Alpine's UEFI grub config doesn't route kernel
        // logs to ttyS0, so the serial console would be blank. The
        // legacy SeaBIOS + ISOLINUX path that fires when we omit
        // OVMF passes `console=ttyS0,115200n8` and lights up the
        // serial pane. Same trade-off as `-cpu max` warnings: we
        // pick reliability over feature parity in headless mode.
        var displayMode = ResolveDisplayMode();
        var useUefi = displayMode != DisplayMode.None
                      && paths.OvmfCodePath is not null && File.Exists(paths.OvmfCodePath)
                      && paths.OvmfVarsPath is not null && File.Exists(paths.OvmfVarsPath);
        string? ovmfCode = useUefi ? paths.OvmfCodePath : null;
        string? ovmfVars = null;
        if (useUefi && paths.OvmfVarsPath is not null)
        {
            ovmfVars = Path.Combine(sessionRoot, "OVMF_VARS.fd");
            try { File.Copy(paths.OvmfVarsPath, ovmfVars, overwrite: true); }
            catch (IOException) { ovmfVars = null; ovmfCode = null; }
        }

        var qmpPort = 4444 + Random.Shared.Next(0, 100);
        var serialPort = 5555 + Random.Shared.Next(0, 100);
        var stderrLogPath = Path.Combine(sessionRoot, "qemu.log");

        // Disk choice:
        //   1) If ubuntu-base.qcow2 exists (the user has run the Ubuntu
        //      bake via Settings), we boot a per-session CoW overlay
        //      over it — same shape macOS gets via APFS clonefile.
        //   2) Otherwise fall back to Alpine virt ISO so the user can
        //      still kick the tyres without first sitting through the
        //      5–10 minute bake. Phase-0 quality of life.
        // Overlay creation is a header-only qcow2 op (~50 ms) so doing
        // it synchronously here is fine; we avoid a fire-and-forget
        // race with QEMU launching.
        string? sessionDiskPath = null;
        string? bootIso = null;
        var ubuntuBasePath = Path.Combine(_services.Paths.ImagesDirectory, AlpineInstaller.OutputBaseFileName);
        if (File.Exists(ubuntuBasePath))
        {
            sessionDiskPath = Path.Combine(sessionRoot, "session.qcow2");
            try { File.Delete(sessionDiskPath); } catch (IOException) { }
            CreateQcow2Overlay(paths.ExecutablePath, ubuntuBasePath, sessionDiskPath);
        }
        else
        {
            bootIso = _images.LocalPath(ImageManager.AlpineVirt);
        }

        // Per-session metadata ISO. Replaces macOS's virtiofs
        // bromure-meta share (see windows/SHARING_INVESTIGATION.md).
        // Contains api_key.env, plus — when the profile has folder
        // paths to share — shares.json and a per-session SSH private
        // key the guest uses to sshfs-mount the host's project
        // folders via slirp NAT.
        var metaIso = Path.Combine(sessionRoot, "bromure-meta.iso");
        try { File.Delete(metaIso); } catch (IOException) { }
        var activeProfile = _profileStore.LoadAll().FirstOrDefault();
        var envExports = activeProfile is not null
            ? ProfileEnvExports.ForProfile(activeProfile)
            : new Dictionary<string, string>
            {
                ["BROMURE_PROFILE_ID"] = "00000000-0000-0000-0000-000000000001",
                ["BROMURE_SESSION_HOST"] = "windows",
            };

        // Folder share — only if the active profile has paths to share
        // and MSYS2 sshd is on the box. Failure here is non-fatal: the
        // session still boots, just without project folders mounted.
        string? sharesJson = null;
        string? sshPrivateKey = null;
        FolderShareServer? folderShare = null;
        if (activeProfile is { FolderPaths.Count: > 0 })
        {
            folderShare = new FolderShareServer(_services.Paths, sessionRoot);
            if (folderShare.IsAvailable)
            {
                try
                {
                    var shares = activeProfile.FolderPaths
                        .Select((path, i) => new FolderShareServer.FolderShare(
                            GuestMountPoint: $"/mnt/bromure-share-{i + 1}",
                            HostPath: path))
                        .ToList();
                    var auth = folderShare.StartAsync(shares).GetAwaiter().GetResult();
                    sshPrivateKey = auth.GuestPrivateKey;
                    sharesJson = BuildSharesJson(auth, shares);
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine("FolderShareServer start failed: " + ex);
                    folderShare.DisposeAsync().AsTask().GetAwaiter().GetResult();
                    folderShare = null;
                }
            }
            else
            {
                folderShare = null;   // no MSYS2 sshd — fall through, no shares this session
            }
        }
        // Materialise the per-session /home/ubuntu overlay. Today this
        // packs kitty.conf + .bashrc + .bash_profile; the entries grow
        // as more macOS-port materialisers (gh/glab/aws/kube/...) land
        // in SessionHomeBuilder. The guest extracts home.tar over
        // /home/ubuntu on each boot.
        var homeFiles = SessionHomeBuilder.Build(activeProfile);
        var homeArchive = SessionHomeArchive.Build(homeFiles);

        SessionMetadataIso.Write(metaIso, envExports,
            shareConfigJson: sharesJson,
            sshPrivateKey: sshPrivateKey,
            homeArchive: homeArchive);

        var cfg = new QemuConfig
        {
            QemuExecutable = paths.ExecutablePath,
            OvmfCode = ovmfCode,
            OvmfVars = ovmfVars,
            SerialEndpoint = $"127.0.0.1:{serialPort}",
            DiskPath = sessionDiskPath,
            BootIsoPath = bootIso,
            AuxIsoPath = metaIso,
            VCpus = 2,
            MemoryMib = 2048,
            QmpEndpoint = $"tcp:127.0.0.1:{qmpPort}",
            Display = displayMode,
            Network = NetworkMode.UserNat,
            StderrLogFile = stderrLogPath,
        };

        var profileId = Guid.Parse("00000000-0000-0000-0000-000000000001");
        var session = new SessionViewModel(profileId, "Default Profile", _engine, _images, cfg);
        if (folderShare is not null) session.SessionResources.Add(folderShare);
        Session = session;
    }

    private void UpdateImageInfoLine()
    {
        var path = _images.LocalPath(ImageManager.AlpineVirt);
        ImageInfoLine = _images.IsCached(ImageManager.AlpineVirt)
            ? $"Alpine virt cached at {path}"
            : "Alpine virt will be downloaded on first launch (~62 MB)";
    }

    /// <summary>
    /// Creates a fresh CoW overlay layered over <paramref name="basePath"/>.
    /// Equivalent of <c>qemu-img create -f qcow2 -F qcow2 -b base overlay</c>.
    /// Synchronous — header-only writes complete in milliseconds. Bubbles
    /// any qemu-img failure as <see cref="InvalidOperationException"/>.
    /// </summary>
    private static void CreateQcow2Overlay(string qemuExe, string basePath, string overlayPath)
    {
        var qemuImg = Path.Combine(Path.GetDirectoryName(qemuExe)!, "qemu-img.exe");
        if (!File.Exists(qemuImg))
        {
            throw new FileNotFoundException("qemu-img.exe not found alongside qemu-system-x86_64.exe", qemuImg);
        }
        var psi = new System.Diagnostics.ProcessStartInfo
        {
            FileName = qemuImg,
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
        };
        psi.ArgumentList.Add("create");
        psi.ArgumentList.Add("-f"); psi.ArgumentList.Add("qcow2");
        psi.ArgumentList.Add("-F"); psi.ArgumentList.Add("qcow2");
        psi.ArgumentList.Add("-b"); psi.ArgumentList.Add(basePath);
        psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("cluster_size=65536");
        psi.ArgumentList.Add(overlayPath);
        using var p = System.Diagnostics.Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start qemu-img");
        var stderr = p.StandardError.ReadToEnd();
        _ = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"qemu-img create failed (exit {p.ExitCode}): {stderr}");
        }
    }

    /// <summary>
    /// Build the <c>shares.json</c> payload the guest's
    /// <c>bromure-mount-meta</c> script consumes. Translates Windows
    /// paths into the MSYS2-style <c>/c/Users/...</c> form sshd's
    /// sftp-server understands.
    /// </summary>
    private static string BuildSharesJson(FolderShareServer.SessionAuth auth,
        IReadOnlyList<FolderShareServer.FolderShare> shares)
    {
        var sb = new System.Text.StringBuilder();
        sb.Append("{\n  \"ssh\": {\n");
        sb.Append($"    \"host\": \"10.0.2.2\",\n");          // QEMU slirp gateway
        sb.Append($"    \"port\": {auth.Port},\n");
        sb.Append($"    \"user\": \"{Environment.UserName}\"\n");
        sb.Append("  },\n  \"shares\": [\n");
        for (var i = 0; i < shares.Count; i++)
        {
            var s = shares[i];
            sb.Append("    {");
            sb.Append($"\"guest_path\": \"{s.GuestMountPoint}\", ");
            sb.Append($"\"host_path\": \"{Bromure.SandboxEngine.Sharing.Msys2Path.From(s.HostPath)}\", ");
            sb.Append($"\"read_only\": {(s.ReadOnly ? "true" : "false")}");
            sb.Append('}');
            if (i + 1 < shares.Count) sb.Append(',');
            sb.Append('\n');
        }
        sb.Append("  ]\n}\n");
        return sb.ToString();
    }

    private DisplayMode ResolveDisplayMode()
    {
        if (_services.Settings.TryGet<string>("display.mode", out var raw)
            && !string.IsNullOrEmpty(raw)
            && Enum.TryParse<DisplayMode>(raw, ignoreCase: true, out var parsed))
        {
            return parsed;
        }
        // Default depends on the host session.
        //   * Local desktop → SDL: lower latency, smaller dependency
        //     surface, keystrokes feel snappier.
        //   * Remote Desktop → GTK: SDL2's Windows backend probes D3D
        //     /GL on init and access-violates against RDP's virtualised
        //     GPU surface (confirmed by direct manual repro:
        //     `qemu-system-x86_64 -display sdl` segfaults pre-boot under
        //     RDP, GTK is fine). Same family of bug as OpenTK#35.
        return IsRemoteDesktopSession() ? DisplayMode.LocalGtk : DisplayMode.LocalSdl;
    }

    /// <summary>
    /// True when this process is running inside a Windows Terminal
    /// Services / Remote Desktop / xrdp session. <c>SM_REMOTESESSION</c>
    /// is the canonical Win32 check: non-zero = RDP, zero = console.
    /// </summary>
    private static bool IsRemoteDesktopSession()
    {
        const int SM_REMOTESESSION = 0x1000;
        try { return GetSystemMetrics(SM_REMOTESESSION) != 0; }
        catch { return false; }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);
}

public partial class InitProgressViewModel
{
    public string ProgressPercent => string.Format(System.Globalization.CultureInfo.InvariantCulture,
        "{0:F1}%", Progress * 100);
    public bool HasError => Error is not null;
}
