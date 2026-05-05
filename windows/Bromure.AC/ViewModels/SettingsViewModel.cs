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
        if (BakeOverlay is null) return;
        BakeOverlay.Completed -= OnBakeCompleted;
        BakeOverlay.Completed += OnBakeCompleted;
        await BakeOverlay.RunCommand.ExecuteAsync(null);
    }

    [RelayCommand]
    private void DeleteUbuntuBase()
    {
        if (_baker is null) return;
        if (!_baker.IsBaked) return;
        try { File.Delete(_baker.ResultPath); }
        catch (IOException) { }
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
        if (_baker is null) return "QEMU not found — install required first.";
        if (!_baker.IsBaked) return "Not built yet.";
        var fi = new FileInfo(_baker.ResultPath);
        var sizeMb = fi.Length / (1024.0 * 1024.0);
        return $"Ready ({sizeMb:F0} MB at {fi.LastWriteTime:yyyy-MM-dd HH:mm})";
    }
}

public sealed record DisplayModeOption(DisplayMode Mode, string Label)
{
    public override string ToString() => Label;
}
