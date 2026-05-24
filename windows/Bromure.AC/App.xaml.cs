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
    public static HttpAppUpdater? Updater { get; private set; }
    private SingleInstanceGuard? _instanceGuard;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Audit 08 §1.2: refuse to launch a second instance for the
        // SAME Windows user — racing two processes against the same
        // profile's VHDX clone risks disk.vhdx corruption (HCS doesn't
        // lock the parent during diff-disk creation). Signal the
        // existing instance to surface its window, then exit cleanly.
        _instanceGuard = SingleInstanceGuard.Acquire();
        if (!_instanceGuard.IsFirstInstance)
        {
            SingleInstanceGuard.SignalExisting(TimeSpan.FromSeconds(2));
            _instanceGuard.Dispose();
            _instanceGuard = null;
            // Exit synchronously — Shutdown() doesn't actually leave
            // OnStartup, so the rest of the method would still run.
            Environment.Exit(0);
            return;
        }
        _instanceGuard.StartActivationServer(BringMainWindowToFront);
        var paths = new WindowsAppPaths();
        paths.EnsureDirectory(paths.AppDataRoot);
        var settings = new JsonSettingsStore(System.IO.Path.Combine(paths.AppDataRoot, "settings.json"));
        var secrets = new WindowsSecretStore(paths);
        Services = new AppServices(paths, settings, secrets);

        // Audit 01 §1 / §10 §13 — wire the vault crypto gateway BEFORE
        // any profile.json is read. The EncryptedStringConverter
        // (Bromure.AC.Core) reaches into the vault via these delegates
        // to wrap/unwrap secret fields at-rest, without taking a
        // project reference on Bromure.AC.Mitm. Any profile read
        // happening before this line treats encrypted fields as
        // opaque empty strings — which is why the bind has to come
        // before ShellViewModel construction.
        var vault = new Bromure.AC.Mitm.Vault.SecretsVault(secrets);
        Bromure.AC.Core.Vault.SecretsCryptoGateway.Encrypt = p => vault.Encrypt(p);
        Bromure.AC.Core.Vault.SecretsCryptoGateway.Decrypt = p => vault.Decrypt(p);
        // Bring the guest-event vsock listeners up at app launch so
        // they're ALWAYS ready before any VM boots. Otherwise the
        // guest's bromure-overlay-fetch.service (which runs early in
        // multi-user.target, before our SessionViewModel registers
        // the listener post-boot-signal) races ahead and gets
        // "connection refused", silently dropping the overlay.
        Bromure.AC.Display.GuestEventServer.Instance.EnsureStarted();

        // Set SSH_AUTH_SOCK for THIS process and its children
        // (e.g. a terminal launched from inside the app) so
        // `ssh-add -l` finds the Bromure agent's named pipe
        // without the user having to set it manually. Win32
        // OpenSSH 8.x+ honours SSH_AUTH_SOCK pointing at a
        // named pipe; older builds use the hardcoded
        // openssh-ssh-agent name which we don't take over
        // (Microsoft owns it).
        Environment.SetEnvironmentVariable(
            "SSH_AUTH_SOCK",
            @"\\.\pipe\bromure-ac-ssh-agent",
            EnvironmentVariableTarget.Process);

        // Bundled Win32-OpenSSH: prepend our openssh\ subdirectory
        // to PATH so child shells launched from inside the app find
        // ssh.exe / ssh-add.exe / ssh-keygen.exe without depending
        // on the Windows OpenSSH Optional Feature. Novice users get
        // working `ssh-add -l` out of the box.
        try
        {
            var appDir = System.IO.Path.GetDirectoryName(
                System.Reflection.Assembly.GetEntryAssembly()?.Location ?? "") ?? "";
            var bundledSsh = System.IO.Path.Combine(appDir, "openssh");
            if (System.IO.Directory.Exists(bundledSsh))
            {
                var current = Environment.GetEnvironmentVariable("PATH",
                    EnvironmentVariableTarget.Process) ?? "";
                if (!current.Split(System.IO.Path.PathSeparator)
                    .Any(p => string.Equals(p, bundledSsh, StringComparison.OrdinalIgnoreCase)))
                {
                    Environment.SetEnvironmentVariable("PATH",
                        bundledSsh + System.IO.Path.PathSeparator + current,
                        EnvironmentVariableTarget.Process);
                }
            }
        }
        catch { /* PATH-mutation is best-effort, never fail launch */ }

        // Audit 08 — auto-update check. Fires a non-blocking GET
        // against the appcast manifest a few seconds after launch
        // (delay so it doesn't fight the welcome / session boot path
        // for HTTP fan-out). The URL is settings-driven; users on
        // dev builds can clear it to opt out.
        try
        {
            var appcast = Services.Settings.Get<string>("appcastUrl")
                          ?? "https://bromure.io/api/version/ac-windows";
            var version = System.Reflection.Assembly.GetEntryAssembly()?
                .GetName().Version?.ToString() ?? "0.0.0";
            Updater = new HttpAppUpdater();
            Updater.Initialize(appcast, "Bromure", "Bromure AC", version);
            _ = Task.Delay(TimeSpan.FromSeconds(8))
                .ContinueWith(_ => Updater.CheckSilently());
        }
        catch { /* never fail launch over the update check */ }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Services.Settings.Save();
        try { _instanceGuard?.Dispose(); } catch { }
        _instanceGuard = null;
        base.OnExit(e);
    }

    /// <summary>Activation hook fired when a second
    /// <c>Bromure.AC.exe</c> launches and signals our pipe. Marshals
    /// to the UI thread, then brings the main window forward + un-minimizes.</summary>
    private void BringMainWindowToFront()
    {
        Dispatcher.InvokeAsync(() =>
        {
            var w = MainWindow;
            if (w is null) return;
            if (w.WindowState == WindowState.Minimized) w.WindowState = WindowState.Normal;
            w.Show();
            w.Activate();
            w.Topmost = true;
            w.Topmost = false;
            w.Focus();
        });
    }
}

/// <summary>Tiny service locator. Wired in <see cref="App.OnStartup"/>.</summary>
public sealed record AppServices(
    IAppPaths Paths,
    ISettingsStore Settings,
    ISecretStore Secrets);
