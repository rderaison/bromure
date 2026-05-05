using System.Collections.ObjectModel;
using System.IO;
using System.Reflection;
using Bromure.AC.Consent;
using Bromure.AC.Core.Enrollment;
using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.Engine;
using Bromure.SandboxEngine.Image;
using Bromure.SandboxEngine.Wsl;
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
    /// <summary>
    /// Bake driver — null for the WSL2 path until we wire a Settings
    /// button to <see cref="RootfsBaker"/>. The QEMU+Alpine baker
    /// (<c>AlpineInstaller</c>) is preserved at commit 86be3d1.
    /// </summary>
    public object? Baker { get; }
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

        // The QEMU+Alpine bake path is gone; WSL2 uses RootfsBaker via
        // bromure-spike for the time being. Wiring a UI button for the
        // WSL2 bake is a follow-up. Settings sees a null baker → its
        // "Bake base image" UI surfaces a "use the spike CLI" hint.
        Baker = null;
        BakeOverlay = null;

        ProfilesPane = new ProfilesViewModel(profileStore);
        TraceInspectorPane = new TraceInspectorViewModel(_engine.TraceStore);
        ApprovalsPane = new ApprovalsViewModel(_engine.Consent);
        SettingsPane = new SettingsViewModel(_services.Paths, enrollment, _engine, _services.Settings, baker: null)
        {
            BakeOverlay = null,
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
        // For the WSL2 path the only artefact that gates Session phase
        // is a baked bromure-base.tar.gz. No more Alpine ISO cache
        // fallback — without a baked rootfs the user must run the bake
        // first (currently via bromure-spike, UI button is a follow-up).
        var rootfsBaked = File.Exists(
            Path.Combine(_services.Paths.ImagesDirectory, RootfsBaker.OutputBaseFileName));
        Phase = rootfsBaked ? ShellPhase.Session : ShellPhase.Welcome;
        if (Phase == ShellPhase.Session) PrepareSessionSync();
    }

    [RelayCommand]
    private Task StartAsync()
    {
        // Welcome → Session: nothing to download for WSL2 — the bake is
        // a separate flow. This command just transitions the phase if
        // a rootfs already exists; otherwise stays on Welcome with a
        // hint about running the bake.
        var rootfsBaked = File.Exists(
            Path.Combine(_services.Paths.ImagesDirectory, RootfsBaker.OutputBaseFileName));
        if (rootfsBaked)
        {
            UpdateImageInfoLine();
            PrepareSessionSync();
            Phase = ShellPhase.Session;
        }
        else
        {
            Progress.Error =
                "No baked rootfs found at " +
                Path.Combine(_services.Paths.ImagesDirectory, RootfsBaker.OutputBaseFileName) +
                ".\n\nRun the bake first:\n" +
                "  bromure-spike bake-wsl <source-rootfs.tar.gz> <output>";
        }
        return Task.CompletedTask;
    }

    [RelayCommand]
    private void Cancel()
    {
        var rootfsBaked = File.Exists(
            Path.Combine(_services.Paths.ImagesDirectory, RootfsBaker.OutputBaseFileName));
        Phase = rootfsBaked ? ShellPhase.Session : ShellPhase.Welcome;
    }

    private void PrepareSessionSync()
    {
        if (Session is not null) return;

        var sessionRoot = Path.Combine(_services.Paths.SessionsDirectory, "default-session");
        Directory.CreateDirectory(sessionRoot);

        // The bromure-base.tar.gz is what RootfsBaker produces. If the
        // user hasn't baked yet, build a preflight-failed session that
        // surfaces a clear "run bake first" message instead of letting
        // them click Boot into a path that NREs.
        var profileId = Guid.Parse("00000000-0000-0000-0000-000000000001");
        var rootfsPath = Path.Combine(_services.Paths.ImagesDirectory, RootfsBaker.OutputBaseFileName);
        if (!File.Exists(rootfsPath))
        {
            var stubCfg = new WslSessionConfig
            {
                BaseRootfsPath = rootfsPath,
                DistroName = "bromure-not-baked",
                InstallPath = sessionRoot,
            };
            Session = new SessionViewModel(profileId, "Default Profile (rootfs not baked)",
                _engine, stubCfg);
            Session.PreflightError =
                $"WSL2 base rootfs not found at {rootfsPath}.\n\n" +
                "Run the bake from Settings → Bake base image, or via\n" +
                "  bromure-spike bake-wsl <source-rootfs> " + rootfsPath;
            return;
        }

        // Profile-derived per-session inputs. The MITM proxy port is
        // allocated by SessionViewModel.StartAsync (port 0 → OS picks)
        // because we want to bind only when the user actually clicks
        // Boot — pre-allocating means a stale port leak if they never
        // boot.
        var activeProfile = _profileStore.LoadAll().FirstOrDefault();
        var envVars = activeProfile is not null
            ? new Dictionary<string, string>(ProfileEnvExports.ForProfile(activeProfile), StringComparer.Ordinal)
            : new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["BROMURE_PROFILE_ID"] = profileId.ToString(),
                ["BROMURE_SESSION_HOST"] = "windows",
            };

        // The home overlay: kitty.conf, .bashrc, .bash_profile, plus
        // anything else SessionHomeBuilder grows over time (gh, glab,
        // aws, kube, doctl, docker, gitconfig …). Dropped directly
        // into the distro's home dir at session start via
        // \\wsl$\<distro>\home\bromure\…
        var homeFiles = SessionHomeBuilder.Build(activeProfile);

        // Per-session distro name. GUID-derived so concurrent sessions
        // don't collide and orphan-cleanup can list-and-match.
        var distroName = "bromure-ses-" + Guid.NewGuid().ToString("N")[..8];
        var installPath = Path.Combine(sessionRoot, distroName);

        var cfg = new WslSessionConfig
        {
            BaseRootfsPath = rootfsPath,
            DistroName = distroName,
            InstallPath = installPath,
            HomeFiles = homeFiles,
            EnvVars = envVars,
            // kitty --title <distro-name> so WslWindowHost can find
            // exactly this session's WSLg-rendered HWND.
            GuestArgv = new[]
            {
                "kitty",
                "--title", distroName,
                "--start-as=fullscreen",
            },
            // BromureCaPem is set by SessionViewModel.StartAsync once
            // the per-tab MITM proxy is up — same lifetime as the
            // proxy itself.
        };

        Session = new SessionViewModel(profileId, activeProfile?.Name ?? "Default Profile",
            _engine, cfg);
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

}

public partial class InitProgressViewModel
{
    public string ProgressPercent => string.Format(System.Globalization.CultureInfo.InvariantCulture,
        "{0:F1}%", Progress * 100);
    public bool HasError => Error is not null;
}
