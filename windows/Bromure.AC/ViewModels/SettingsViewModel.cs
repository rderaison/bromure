using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using Bromure.AC.Core.Enrollment;
using Bromure.AC.Mitm.Engine;
using Bromure.Platform;
using Bromure.SandboxEngine.Image;
using Bromure.SandboxEngine.Qemu;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly IAppPaths _paths;
    private readonly EnrollmentStore _enrollment;
    private readonly MitmEngine _engine;
    private readonly ISettingsStore _settings;
    private readonly AlpineInstaller? _baker;

    [ObservableProperty] private string _appDataRoot;
    [ObservableProperty] private string _machineDataRoot;
    [ObservableProperty] private string _imagesDirectory;
    [ObservableProperty] private string _enrollmentStatus;
    [ObservableProperty] private string _caFingerprint;
    [ObservableProperty] private string _ubuntuBaseStatus;

    public ObservableCollection<DisplayModeOption> DisplayModeOptions { get; } = new()
    {
        new(DisplayMode.None,             "Headless (default; no QEMU window)"),
        new(DisplayMode.LocalSdl,         "QEMU SDL window — fastest, but some hosts segfault on init"),
        new(DisplayMode.LocalGtk,         "QEMU GTK window — slower, more compatible"),
    };

    [ObservableProperty] private DisplayModeOption _selectedDisplayMode;

    /// <summary>
    /// Set by the shell. The Settings pane just calls Show() on it
    /// when the user clicks "Build Ubuntu base image".
    /// </summary>
    public BakeOverlayViewModel? BakeOverlay { get; set; }

    public SettingsViewModel(IAppPaths paths, EnrollmentStore enrollment, MitmEngine engine,
        ISettingsStore settings, AlpineInstaller? baker)
    {
        _paths = paths;
        _enrollment = enrollment;
        _engine = engine;
        _settings = settings;
        _baker = baker;
        _appDataRoot = paths.AppDataRoot;
        _machineDataRoot = paths.MachineDataRoot;
        _imagesDirectory = paths.ImagesDirectory;
        _enrollmentStatus = enrollment.IsEnrolled ? "Enrolled" : "Not enrolled";
        _caFingerprint = ComputeCaFingerprint();
        _ubuntuBaseStatus = ComputeUbuntuStatus();

        var current = _settings.TryGet<string>("display.mode", out var raw) && !string.IsNullOrEmpty(raw)
            && Enum.TryParse<DisplayMode>(raw, ignoreCase: true, out var parsed)
            ? parsed
            : DisplayMode.None;
        _selectedDisplayMode = DisplayModeOptions.FirstOrDefault(o => o.Mode == current)
            ?? DisplayModeOptions[0];
    }

    partial void OnSelectedDisplayModeChanged(DisplayModeOption value)
    {
        _settings.Set("display.mode", value.Mode.ToString());
        _settings.Save();
    }

    [RelayCommand]
    private void OpenAppDataFolder()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"\"{_paths.AppDataRoot}\"",
            UseShellExecute = true,
        });
    }

    [RelayCommand]
    private void OpenImagesFolder()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"\"{_paths.ImagesDirectory}\"",
            UseShellExecute = true,
        });
    }

    [RelayCommand]
    private void Enroll()
    {
        var vm = new EnrollmentSheetViewModel(_enrollment);
        var sheet = new Views.EnrollmentSheet(vm)
        {
            Owner = System.Windows.Application.Current.MainWindow,
        };
        if (sheet.ShowDialog() == true)
        {
            EnrollmentStatus = "Enrolled as " + (vm.Result?.UserEmail ?? "(unknown)");
        }
    }

    [RelayCommand]
    private void Unenroll()
    {
        _enrollment.Destroy();
        EnrollmentStatus = "Not enrolled";
    }

    [RelayCommand]
    private async Task BuildUbuntuBaseAsync()
    {
        // The QEMU+Alpine bake (BakeOverlayViewModel + AlpineInstaller)
        // is gone for the WSL2 path. Driving the WSL bake from the
        // Settings UI requires a source rootfs (currently produced by
        // exporting the user's existing Ubuntu distro), which we do
        // synchronously here. Long-running — runs on a background
        // thread to avoid hanging the UI.
        if (BakeOverlay is not null)
        {
            BakeOverlay.Completed -= OnBakeCompleted;
            BakeOverlay.Completed += OnBakeCompleted;
            await BakeOverlay.RunCommand.ExecuteAsync(null);
            return;
        }

        UbuntuBaseStatus = "Building base rootfs via WSL2…";
        try
        {
            await Task.Run(() => RunWslBakeAsync()).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            UbuntuBaseStatus = "Bake failed: " + ex.Message;
            return;
        }
        UbuntuBaseStatus = ComputeUbuntuStatus();
    }

    private async Task RunWslBakeAsync()
    {
        // Pick a source rootfs: the user's existing default WSL
        // distro (we export it once to a temp tarball), or a hard
        // error pointing them at `wsl --install Ubuntu` if they
        // have nothing yet.
        var distros = await Bromure.SandboxEngine.Wsl.WslDistro.ListAsync().ConfigureAwait(false);
        var source = distros.FirstOrDefault(d =>
            !d.Name.StartsWith("bromure-", StringComparison.Ordinal));
        if (source is null)
        {
            throw new InvalidOperationException(
                "No source WSL distro found. Run `wsl --install Ubuntu` first to install a base distro.");
        }

        var tempSource = Path.Combine(Path.GetTempPath(), "bromure-bake-source.tar.gz");
        try { File.Delete(tempSource); } catch (IOException) { }

        var export = await Bromure.SandboxEngine.Wsl.WslCli.RunAsync(
            new[] { "--export", source.Name, tempSource, "--format", "tar.gz" }).ConfigureAwait(false);
        export.ThrowIfFailed($"wsl --export {source.Name}");

        var output = Path.Combine(_paths.ImagesDirectory,
            Bromure.SandboxEngine.Wsl.RootfsBaker.OutputBaseFileName);
        var baker = new Bromure.SandboxEngine.Wsl.RootfsBaker();
        var progress = new Progress<Bromure.SandboxEngine.Wsl.RootfsBaker.BakeProgress>(p =>
        {
            // Marshal back to UI thread for the status update.
            System.Windows.Application.Current.Dispatcher.BeginInvoke(() =>
                UbuntuBaseStatus = $"{p.Stage}: {p.Message} ({p.Fraction:P0})");
        });
        await baker.BakeAsync(tempSource, output, progress).ConfigureAwait(false);
        try { File.Delete(tempSource); } catch (IOException) { }
    }

    [RelayCommand]
    private void DeleteUbuntuBase()
    {
        if (_baker is not null && _baker.IsBaked)
        {
            try { File.Delete(_baker.ResultPath); }
            catch (IOException) { }
        }
        // Also handle the WSL2-path artefact.
        var rootfsPath = Path.Combine(_paths.ImagesDirectory,
            Bromure.SandboxEngine.Wsl.RootfsBaker.OutputBaseFileName);
        if (File.Exists(rootfsPath))
        {
            try { File.Delete(rootfsPath); }
            catch (IOException) { }
        }
        UbuntuBaseStatus = ComputeUbuntuStatus();
    }

    private void OnBakeCompleted()
    {
        UbuntuBaseStatus = ComputeUbuntuStatus();
    }

    private string ComputeCaFingerprint()
    {
        try
        {
            var thumbprint = _engine.Ca.ServerCertificate.Thumbprint;
            return thumbprint.Length > 16
                ? $"{thumbprint[..8]}…{thumbprint[^8..]}"
                : thumbprint;
        }
        catch (Exception ex)
        {
            return "(unavailable: " + ex.Message + ")";
        }
    }

    private string ComputeUbuntuStatus()
    {
        // First check the WSL2 artefact since that's the active path.
        var rootfsPath = Path.Combine(_paths.ImagesDirectory,
            Bromure.SandboxEngine.Wsl.RootfsBaker.OutputBaseFileName);
        if (File.Exists(rootfsPath))
        {
            var fi = new FileInfo(rootfsPath);
            var sizeMb = fi.Length / (1024.0 * 1024.0);
            return $"Ready (WSL2 — {sizeMb:F0} MB at {fi.LastWriteTime:yyyy-MM-dd HH:mm})";
        }
        // Fall through to legacy QEMU bake artefact (kept for users
        // upgrading from the QEMU baseline at commit 86be3d1).
        if (_baker is not null && _baker.IsBaked)
        {
            var fi = new FileInfo(_baker.ResultPath);
            var sizeMb = fi.Length / (1024.0 * 1024.0);
            return $"Ready (legacy QEMU — {sizeMb:F0} MB at {fi.LastWriteTime:yyyy-MM-dd HH:mm})";
        }
        return "Not built yet — click Build to bake the WSL2 rootfs.";
    }
}

public sealed record DisplayModeOption(DisplayMode Mode, string Label)
{
    public override string ToString() => Label;
}
