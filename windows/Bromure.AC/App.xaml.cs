using System.Windows;
using Bromure.Platform;

namespace Bromure.AC;

/// <summary>
/// Replacement for the macOS <c>BromureAC.swift</c> NSApplicationDelegate.
/// Hosts the platform seam (<see cref="IAppPaths"/>, <see cref="ISecretStore"/>,
/// <see cref="ISettingsStore"/>) so views/view-models can resolve via
/// <see cref="Services"/>.
/// </summary>
public partial class App : Application
{
    public static AppServices Services { get; private set; } = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var paths = new WindowsAppPaths();
        paths.EnsureDirectory(paths.AppDataRoot);
        var settings = new JsonSettingsStore(System.IO.Path.Combine(paths.AppDataRoot, "settings.json"));
        var secrets = new WindowsSecretStore(paths);
        Services = new AppServices(paths, settings, secrets);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Services.Settings.Save();
        base.OnExit(e);
    }
}

/// <summary>Tiny service locator. Wired in <see cref="App.OnStartup"/>.</summary>
public sealed record AppServices(
    IAppPaths Paths,
    ISettingsStore Settings,
    ISecretStore Secrets);
