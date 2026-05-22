using System.Collections.ObjectModel;
using System.IO;
using System.Reflection;
using Bromure.AC.Automation;
using Bromure.AC.Cloud;
using Bromure.AC.Consent;
using Bromure.AC.Core.Enrollment;
using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.Engine;
using Bromure.Cloud;
using Bromure.SandboxEngine.Hcs;
using Bromure.SandboxEngine.Image;
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
    private readonly EnrollmentStore _enrollment;
    private readonly EnrollmentCoordinator _enrollmentCoord;
    private readonly EnrollmentCloudMtlsIdentity _cloudIdentity;
    private readonly SessionTracker _cloudSessions = new();
    private readonly CloudEventEmitter _cloudEmitter;
    private CloudUploader? _cloudUploader;
    private AutomationServer? _automation;
    // No warm pool. AC uses cold create for every session — the
    // VHDX-clone + HCS-create cost is sub-second, not worth the
    // parent-VHDX-lock and orphan-leak hazards a pool brings.
    // The macOS port of AC made the same call (Web has a pool
    // because browser tabs really do need <1 s spawn; AC doesn't).

    [ObservableProperty] private ShellPhase _phase = ShellPhase.Welcome;
    [ObservableProperty] private InitProgressViewModel _progress = new();
    [ObservableProperty] private SessionViewModel? _session;
    [ObservableProperty] private string _imageInfoLine = "";

    // UX #2 — Hyper-V enable flow. Set by HyperVPreflight at startup
    // when the OS is missing the Microsoft-Hyper-V feature. The
    // welcome view binds to these to surface a Copy button + an
    // Enable-now button (UAC-elevated dism call).
    [ObservableProperty] private string _hyperVMessage = "";
    [ObservableProperty] private string _hyperVFixCommand = "";

    [ObservableProperty] private NavigationItem _selectedNavigation;
    public ObservableCollection<NavigationItem> Navigation { get; } = new()
    {
        // UX #6: sidebar gone from MainWindow.xaml. This collection
        // backs the View-menu items + keyboard shortcuts.
        // Conversations dropped entirely (folded into Trace Inspector).
        // Sessions is the default; everything else lives behind a
        // View-menu item or chord.
        new NavigationItem("Sessions", "", NavigationKind.Sessions, selected: true),
        new NavigationItem("Profiles", "", NavigationKind.Profiles),
        new NavigationItem("Trace inspector", "", NavigationKind.TraceInspector),
        new NavigationItem("Approvals", "", NavigationKind.Approvals),
        new NavigationItem("Settings", "", NavigationKind.Settings),
    };

    public SessionsViewModel SessionsPane { get; }
    public ProfilesViewModel ProfilesPane { get; }
    public TraceInspectorViewModel TraceInspectorPane { get; }
    // UX #6: ConversationsPane removed. The conversation view was a
    // grouped-by-session render of llm.request trace rows; the Trace
    // Inspector covers the same data set + more, so the standalone
    // pane was redundant.
    public ApprovalsViewModel ApprovalsPane { get; }
    public SettingsViewModel SettingsPane { get; }
    /// <summary>
    /// Bake driver — null until <see cref="VmBaker"/> grows an
    /// in-process driver path (currently the bake is interactive on
    /// first run; see VmBaker docs). The legacy QEMU+Alpine baker is
    /// preserved at commit 86be3d1; the WSL2 baseline at 9185fc6.
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
        // Start the engine's long-running host services NOW so the
        // ssh-agent named pipe + compromise handler are live before
        // any session boots — and, importantly, before the user types
        // `ssh-add -l`. Previously this was never called from the
        // WPF host, so the pipe at \\.\pipe\bromure-ac-ssh-agent
        // never existed.
        _ = _engine.StartAsync();

        _profileStore = new ProfileStore(_services.Paths.ProfilesDirectory);
        var profileStore = _profileStore;
        _enrollment = new EnrollmentStore(_services.Paths, _services.Secrets);
        var enrollment = _enrollment;
        _cloudIdentity = new EnrollmentCloudMtlsIdentity(_enrollment);
        _cloudEmitter = new CloudEventEmitter(_cloudSessions, () => _enrollment.IsEnrolled);
        AttachCloudUploaderIfEnrolled();

        // Heartbeat: 10-min ping so the dashboard shows
        // "last seen N minutes ago". No-op until the user enrolls.
        _enrollmentCoord = new EnrollmentCoordinator(new EnrollmentClient(), _enrollment);
        _enrollmentCoord.StartHeartbeat();
        // Best-effort fan-out from the Mitm engine into the cloud
        // emitter. Detached so a slow uploader can't back-pressure
        // the proxy hot path.
        _engine.OnCloudEvent = (profileId, type, data) =>
        {
            _ = _cloudEmitter.EmitAsync(profileId, type, data);
        };

        // HCS bake driver is interactive on first run (see VmBaker
        // docs) — the in-process driver is a follow-up that requires
        // a small init-shipped agent inside the source rootfs.
        // Settings sees a null baker → "use the spike CLI" hint.
        Baker = null;
        BakeOverlay = null;

        // Hook restart-required prompts: when the user saves a
        // running profile and any field that's baked into the VM at
        // boot has changed, surface the "Restart now / Later" alert.
        // Mirrors the macOS port's promptRestartForChanges at
        // BromureAC.swift:1876-1897. Direct port of the diff lives
        // in RestartRequiringChanges; here we wire the runtime
        // "is profile running?" check + the WPF MessageBox.
        Func<Guid, bool> isProfileRunning = profileId =>
            SessionsPane?.Rows.Any(r => r.Profile.Id == profileId && r.IsRunning) ?? false;
        Action<Profile, IReadOnlyList<RestartRequiringChanges.Kind>> onRestartRequired =
            (profile, changes) =>
            {
                var labels = string.Join("\n", changes.Select(c =>
                    "• " + RestartRequiringChanges.DisplayLabel(c)));
                var msg = $"Restart \"{profile.Name}\" to apply these changes?\n\n"
                          + "These settings are baked into the VM at boot, so the running "
                          + "session won't pick them up until it restarts:\n\n" + labels;
                var result = System.Windows.MessageBox.Show(
                    msg, "Bromure AC — restart required",
                    System.Windows.MessageBoxButton.YesNo,
                    System.Windows.MessageBoxImage.Information,
                    System.Windows.MessageBoxResult.No);
                if (result == System.Windows.MessageBoxResult.Yes)
                {
                    // Defer the actual reboot to SessionsPane —
                    // it owns the close/relaunch dance. For now,
                    // just shut the current session; the user
                    // can re-click to launch with new settings.
                    var row = SessionsPane?.Rows.FirstOrDefault(r => r.Profile.Id == profile.Id);
                    if (row?.Session is { } sv) _ = sv.ShutdownAsync();
                }
            };

        ProfilesPane = new ProfilesViewModel(profileStore, _services.Paths,
            isProfileRunning, onRestartRequired);
        TraceInspectorPane = new TraceInspectorViewModel(_engine.TraceStore, _engine.Vault);
        ApprovalsPane = new ApprovalsViewModel(_engine.Consent);
        SettingsPane = new SettingsViewModel(_services.Paths, enrollment, _engine, _services.Settings, baker: null)
        {
            BakeOverlay = null,
            OpenTemplateEditor = () => OpenTemplateProfileEditor(),
        };
        Func<BakeArtefacts> artefactsProvider =
            () => BakeArtefacts.InDirectory(_services.Paths.ImagesDirectory);

        // Read the bake-time version stamp lazily — the file appears
        // after the first successful bake, so we re-read on each
        // launch to catch newly-baked bases without restarting the app.
        var imageManager = new Bromure.SandboxEngine.Image.ImageManager(_services.Paths);
        Func<string?> installedBaseVersion = () =>
            imageManager.ReadInstalledImageVersion() ?? Bromure.SandboxEngine.Image.ImageManager.ImageVersion;

        Func<Guid, string> sessionRootForProfile = profileId =>
            Path.Combine(_services.Paths.ProfilesDirectory, profileId.ToString("N"), "session");

        // Wire the MitmEngine's compromise sink to the per-profile
        // flag file the launcher gates on. Direct port of macOS
        // BromureAC.swift: when the proxy sees a fake going to a host
        // outside its scope, drop a `compromised.flag` so the next
        // launch refuses to boot without explicit wipe-and-launch.
        _engine.OnCompromiseDetected = evt =>
        {
            try { Bromure.AC.Core.Model.CompromiseGate.Mark(sessionRootForProfile(evt.ProfileId)); }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine("CompromiseGate.Mark failed: " + ex);
            }
            // Update the picker badge for this profile (audit 08 §2.2).
            // Has to hop to the UI thread — the proxy fires this from
            // its own connection-handling task.
            try
            {
                System.Windows.Application.Current?.Dispatcher.InvokeAsync(() =>
                {
                    var row = SessionsPane?.Rows.FirstOrDefault(r => r.Profile.Id == evt.ProfileId);
                    row?.RefreshCompromiseFlag();
                });
            }
            catch { }
        };

        // Subscription token coordinator: when the proxy spots a
        // clean Claude / Codex OAuth token outbound, the coordinator
        // owns the consent prompt + the swap-registration. Direct
        // port of macOS SubscriptionTokenCoordinator.swift's
        // ACAppDelegate wiring. Without this the host's detection
        // hooks fire but nothing acts on them.
        var subscriptionPrompt = new Bromure.AC.Consent.SubscriptionConsentPrompt(profileStore);
        var subscriptionCoord = new Bromure.AC.Mitm.Engine.SubscriptionTokenCoordinator(_engine.Swapper, subscriptionPrompt);
        _engine.SubscriptionTokenSeen = (profileId, realToken) =>
        {
            _ = subscriptionCoord.HandleCleanClaudeAccessTokenAsync(
                profileId, realToken, _engine.FakeTokenSalt, CancellationToken.None);
        };
        _engine.CodexTokenSeen = (profileId, realToken) =>
        {
            _ = subscriptionCoord.HandleCleanCodexAccessTokenAsync(
                profileId, realToken, _engine.FakeTokenSalt, CancellationToken.None);
        };
        // Audit 07 §4 recordRotation: persist freshly-rotated real
        // tokens back onto the profile so the next session boot can
        // auto-seed them into the guest credentials file. Without
        // this, every OAuth refresh forces a manual re-login on the
        // next session start.
        _engine.OAuthRotated = (profileId, provider, reals) =>
        {
            try
            {
                var profile = _profileStore.Load(profileId);
                if (profile is null) return;
                var stored = new Bromure.AC.Core.Model.StoredOAuthTokens
                {
                    AccessToken = reals.AccessToken,
                    RefreshToken = reals.RefreshToken,
                    IdToken = reals.IdToken,
                    SavedAt = DateTimeOffset.UtcNow,
                };
                if (provider == Bromure.AC.Mitm.OAuth.OAuthRotationProvider.Claude)
                {
                    profile.DefaultClaudeTokens = stored;
                }
                else
                {
                    profile.DefaultCodexTokens = stored;
                }
                _profileStore.Save(profile);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"OAuthRotated persist failed: {ex}");
            }
        };

        SessionsPane = new SessionsViewModel(profileStore, _engine,
            artefactsProvider: artefactsProvider,
            // Per-profile persistent root. The disposable-session
            // model (clone base every launch) is wrong for AC —
            // users expect installed tools + shell history to
            // survive. profiles/<id>/disk.vhdx is created once
            // (idempotent in VhdxDisk) and reused on every launch.
            sessionRootProvider: profileId =>
                Path.Combine(_services.Paths.ProfilesDirectory, profileId.ToString("N"), "session"),
            // No warm pool for AC — sessions cold-create on demand
            // (sub-second on modern hardware, vs. the warm pool's
            // habit of leaking child VHDXs that lock the parent).
            warmPoolProvider: () => null,
            onEdit: profile =>
            {
                // Open the editor on a fresh, single-profile VM so the
                // popup shows ONLY this profile — no picker, no Add,
                // no risk of editing a different one. Mirrors the
                // macOS port's modal editorWindow. Saves go through
                // the same ProfileStore so the main pane re-reads the
                // updated entry on close.
                var pvm = new ProfilesViewModel(_profileStore, _services.Paths,
                    isProfileRunning, onRestartRequired)
                {
                    EditorOnly = true,
                };
                var fresh = pvm.Profiles.FirstOrDefault(p => p.Id == profile.Id);
                if (fresh is not null) pvm.Selected = fresh;
                var editor = new Views.ProfileEditorWindow
                {
                    DataContext = pvm,
                    Owner = System.Windows.Application.Current.MainWindow,
                    Title = $"Edit profile — {profile.Name}",
                };
                editor.Show();
                editor.Closed += (_, _) =>
                {
                    // Re-read both panes so name / colour / status /
                    // SSH key changes propagate.
                    ProfilesPane.Reload();
                    SessionsPane!.Reload();
                };
            },
            installedBaseVersionProvider: installedBaseVersion);

        _selectedNavigation = Navigation[0];

        UpdateImageInfoLine();
        // Pre-flight: bail fast if the full Microsoft-Hyper-V feature
        // isn't enabled. Otherwise the user will hit a misleading
        // HCS_E_INVALID_JSON deep inside CreateComputeSystem when
        // Get Started → Bake → VM Start tries to fire. Caught by
        // HyperVPreflight.Detect — same check the e2e harness uses.
        var hv = HyperVPreflight.Detect();
        if (!hv.Ok)
        {
            HyperVMessage = hv.ErrorMessage ?? "Hyper-V pre-flight failed.";
            HyperVFixCommand = HyperVPreflight.FixCommand;
            Progress.Error = (hv.ErrorMessage ?? "Hyper-V pre-flight failed.")
                + "\n\n" + (hv.FixInstruction ?? "");
        }
        // Reap any leftover bromure-warm-* compute systems from prior
        // crashes BEFORE we kick off the session phase. HCS-create
        // collisions on a stale ID are otherwise possible. Fire-and-
        // forget — UI doesn't wait.
        _ = Task.Run(CleanupOrphanedVmsAsync);
        ResolvePhaseFromCache();

        StartAutomationServer();
    }

    /// <summary>
    /// Spin up the loopback automation HTTP server so external MCP
    /// clients (Claude Code, Codex, ac-e2e.mjs) can drive the AC app.
    /// Best-effort — if the port is taken (another AC instance) we log
    /// and continue without it. Mirrors macOS <c>ACAutomationServer</c>.
    /// </summary>
    private void StartAutomationServer()
    {
        try
        {
            _automation = new AutomationServer();
            _automation.OnListProfiles = () =>
                SessionsPane.Rows
                    .Select(r => new AutomationServer.ProfileInfo(
                        Id: r.Profile.Id.ToString("D"),
                        Name: r.Profile.Name,
                        Color: r.Profile.Color.ToString().ToLowerInvariant(),
                        Tool: r.Profile.Tool.ToString().ToLowerInvariant(),
                        AuthMode: r.Profile.AuthMode.ToString().ToLowerInvariant(),
                        McpServerCount: r.Profile.McpServers.Count))
                    .ToArray();

            _automation.OnListSessions = () =>
                SessionsPane.Rows
                    .Where(r => r.IsRunning)
                    .Select(r => new AutomationServer.SessionInfo(
                        ProfileId: r.Profile.Id.ToString("D"),
                        ProfileName: r.Profile.Name,
                        WindowId: 0,
                        Visible: true))
                    .ToArray();

            _automation.OnCreateSession = async nameOrId =>
            {
                SessionRowViewModel? row = null;
                await System.Windows.Application.Current.Dispatcher.InvokeAsync(() =>
                {
                    row = FindRow(nameOrId);
                });
                if (row is null) return null;
                // Dispatcher.InvokeAsync wrapping an async lambda is a
                // common footgun: the OUTER call returns the lambda's
                // Task immediately. To actually wait for the launch we
                // marshal a TCS-completed task back to this thread.
                var launchTask = await System.Windows.Application.Current.Dispatcher
                    .InvokeAsync(() => row!.LaunchAsync());
                await launchTask.ConfigureAwait(false);
                if (!row.IsRunning) return null;
                return new AutomationServer.SessionInfo(
                    ProfileId: row.Profile.Id.ToString("D"),
                    ProfileName: row.Profile.Name,
                    WindowId: 0,
                    Visible: true);
            };

            _automation.OnExecInSession = async (nameOrId, cmd) =>
            {
                SessionRowViewModel? row = null;
                await System.Windows.Application.Current.Dispatcher.InvokeAsync(() =>
                {
                    row = FindRow(nameOrId);
                });
                if (row?.Session is null) return "";
                var vmId = row.Session.VmRuntimeId;
                if (vmId == Guid.Empty) return "";
                return await Bromure.AC.Display.GuestCommand.RunAndCollectAsync(vmId, cmd).ConfigureAwait(false);
            };

            _automation.OnDestroySession = async nameOrId =>
            {
                SessionRowViewModel? row = null;
                await System.Windows.Application.Current.Dispatcher.InvokeAsync(() =>
                {
                    row = FindRow(nameOrId);
                });
                if (row is null) return false;
                var shutdownTask = await System.Windows.Application.Current.Dispatcher
                    .InvokeAsync(() => row!.ShutdownAsync());
                await shutdownTask.ConfigureAwait(false);
                return true;
            };

            _automation.OnGetAppState = () => new System.Text.Json.Nodes.JsonObject
            {
                ["phase"] = Phase.ToString(),
                ["profileCount"] = _profileStore.LoadAll().Count,
                ["sessionCount"] = SessionsPane.Rows.Count(r => r.IsRunning),
                ["hasBaseImage"] = _images.IsCached(Bromure.SandboxEngine.Image.ImageManager.AlpineVirt),
                ["windowVisible"] = System.Windows.Application.Current.MainWindow?.IsVisible == true,
            };

            _automation.OnGetProfileJson = id =>
            {
                var p = ResolveProfile(id);
                return p is null ? null : System.Text.Json.JsonSerializer.Serialize(p, ProfileJsonOptions);
            };

            _automation.OnSetProfileJson = (id, json) =>
            {
                var p = ResolveProfile(id);
                if (p is null) return false;
                try
                {
                    var incoming = System.Text.Json.JsonSerializer.Deserialize<Profile>(json, ProfileJsonOptions);
                    if (incoming is null) return false;
                    incoming.Id = p.Id;   // preserve id; rest is wholesale-replaced
                    _profileStore.Save(incoming);
                    System.Windows.Application.Current.Dispatcher.InvokeAsync(() =>
                    {
                        SessionsPane.Reload();
                        ProfilesPane.Reload();
                    });
                    return true;
                }
                catch (System.Text.Json.JsonException) { return false; }
            };

            _automation.OnGetProfileSetting = (id, key) =>
            {
                var p = ResolveProfile(id);
                return p is null ? null : ReadProfileSetting(p, key);
            };

            _automation.OnSetProfileSetting = (id, key, value) =>
            {
                var p = ResolveProfile(id);
                if (p is null) return false;
                if (!WriteProfileSetting(p, key, value)) return false;
                _profileStore.Save(p);
                System.Windows.Application.Current.Dispatcher.InvokeAsync(() =>
                {
                    SessionsPane.Reload();
                    ProfilesPane.Reload();
                });
                return true;
            };

            _automation.Start();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine("[automation] failed to start: " + ex);
            _automation = null;
        }
    }

    private static readonly System.Text.Json.JsonSerializerOptions ProfileJsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private SessionRowViewModel? FindRow(string nameOrId)
    {
        if (Guid.TryParse(nameOrId, out var g))
        {
            return SessionsPane.Rows.FirstOrDefault(r => r.Profile.Id == g);
        }
        return SessionsPane.Rows.FirstOrDefault(r =>
            string.Equals(r.Profile.Name, nameOrId, StringComparison.OrdinalIgnoreCase));
    }

    private Profile? ResolveProfile(string nameOrId)
    {
        if (Guid.TryParse(nameOrId, out var g)) return _profileStore.Load(g);
        return _profileStore.LoadAll()
            .FirstOrDefault(p => string.Equals(p.Name, nameOrId, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Delegate to <see cref="ProfileSettingsBridge"/> in
    /// Core so the table is unit-testable from Bromure.Tests.</summary>
    private static string? ReadProfileSetting(Profile p, string key)
        => ProfileSettingsBridge.Read(p, key);

    private static bool WriteProfileSettingDelegate(Profile p, string key, string value)
        => ProfileSettingsBridge.Write(p, key, value);

    /// <summary>Legacy inline reader kept temporarily for searching;
    /// production callers go through <see cref="ProfileSettingsBridge"/>.</summary>
    private static string? ReadProfileSetting_Inline(Profile p, string key) => key switch
    {
        // Identity + presentation.
        "name" => p.Name,
        "color" => p.Color.ToString(),
        "comments" => p.Comments,
        // Tool / auth.
        "tool" => p.Tool.ToString(),
        "authMode" => p.AuthMode.ToString(),
        "apiKey" => p.ApiKey ?? "",
        "apiKeyRequiresApproval" => p.ApiKeyRequiresApproval.ToString().ToLowerInvariant(),
        // Cosmetic.
        "useTerminalAppDefaults" => p.UseTerminalAppDefaults.ToString().ToLowerInvariant(),
        "customFontFamily" => p.CustomFontFamily ?? "",
        "customFontSize" => p.CustomFontSize?.ToString() ?? "",
        "customBackgroundHex" => p.CustomBackgroundHex ?? "",
        "customForegroundHex" => p.CustomForegroundHex ?? "",
        "cursorShape" => p.CursorShape.ToString(),
        "windowOpacity" => p.WindowOpacity.ToString(System.Globalization.CultureInfo.InvariantCulture),
        "keyboardLayoutOverride" => p.KeyboardLayoutOverride ?? "",
        // VM resources.
        "memoryGB" => p.MemoryGB.ToString(),
        "networkMode" => p.NetworkMode.ToString(),
        "bridgedInterfaceID" => p.BridgedInterfaceID ?? "",
        "closeAction" => p.CloseAction.ToString(),
        // Git identity.
        "gitUserName" => p.GitUserName,
        "gitUserEmail" => p.GitUserEmail,
        // SSH.
        "sshPublicKey" => p.SshPublicKey ?? "",
        "sshKeyRequiresApproval" => p.SshKeyRequiresApproval.ToString().ToLowerInvariant(),
        // Misc tokens.
        "digitalOceanToken" => p.DigitalOceanToken ?? "",
        "digitalOceanRequiresApproval" => p.DigitalOceanRequiresApproval.ToString().ToLowerInvariant(),
        // Bedrock.
        "bedrockEnabled" => p.BedrockEnabled.ToString().ToLowerInvariant(),
        "bedrockModelID" => p.BedrockModelID,
        // Lifecycle.
        "createdAt" => p.CreatedAt.ToString("O"),
        "lastUsedAt" => p.LastUsedAt?.ToString("O") ?? "",
        "baseImageVersionAtClone" => p.BaseImageVersionAtClone ?? "",
        // Subscription token consent state.
        "subscriptionTokenSwap" => p.SubscriptionTokenSwap.ToString(),
        "codexTokenSwap" => p.CodexTokenSwap.ToString(),
        // Counts (read-only, useful for assertions).
        "folderPathsCount" => p.FolderPaths.Count.ToString(),
        "mcpServerCount" => p.McpServers.Count.ToString(),
        "kubeconfigCount" => p.Kubeconfigs.Count.ToString(),
        "dockerRegistryCount" => p.DockerRegistries.Count.ToString(),
        "manualTokenCount" => p.ManualTokens.Count.ToString(),
        "importedSshKeyCount" => p.ImportedSshKeys.Count.ToString(),
        "environmentVariableCount" => p.EnvironmentVariables.Count.ToString(),
        // Privacy / tracing.
        "privateMode" => p.PrivateMode.ToString().ToLowerInvariant(),
        "traceLevel" => p.TraceLevel.ToString(),
        _ => null,
    };

    private static bool WriteProfileSetting(Profile p, string key, string value)
        => ProfileSettingsBridge.Write(p, key, value);

    private static bool WriteProfileSetting_Inline(Profile p, string key, string value)
    {
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        switch (key)
        {
            case "name": p.Name = value; return true;
            case "comments": p.Comments = value; return true;
            case "color":
                if (!Enum.TryParse<ProfileColor>(value, ignoreCase: true, out var c)) return false;
                p.Color = c; return true;
            case "tool":
                if (!Enum.TryParse<AgentTool>(value, ignoreCase: true, out var t)) return false;
                p.Tool = t; return true;
            case "authMode":
                if (!Enum.TryParse<AuthMode>(value, ignoreCase: true, out var a)) return false;
                p.AuthMode = a; return true;
            case "apiKey": p.ApiKey = value; return true;
            case "apiKeyRequiresApproval":
                if (!bool.TryParse(value, out var akra)) return false;
                p.ApiKeyRequiresApproval = akra; return true;
            // Cosmetic.
            case "useTerminalAppDefaults":
                if (!bool.TryParse(value, out var utd)) return false;
                p.UseTerminalAppDefaults = utd; return true;
            case "customFontFamily":
                p.CustomFontFamily = string.IsNullOrEmpty(value) ? null : value; return true;
            case "customFontSize":
                if (string.IsNullOrEmpty(value)) { p.CustomFontSize = null; return true; }
                if (!int.TryParse(value, System.Globalization.NumberStyles.Integer, inv, out var cfs)) return false;
                p.CustomFontSize = cfs; return true;
            case "customBackgroundHex":
                p.CustomBackgroundHex = string.IsNullOrEmpty(value) ? null : value; return true;
            case "customForegroundHex":
                p.CustomForegroundHex = string.IsNullOrEmpty(value) ? null : value; return true;
            case "cursorShape":
                if (!Enum.TryParse<CursorShape>(value, ignoreCase: true, out var cs)) return false;
                p.CursorShape = cs; return true;
            case "windowOpacity":
                if (!double.TryParse(value, System.Globalization.NumberStyles.Float, inv, out var wo)) return false;
                if (wo < 0.3 || wo > 1.0) return false;
                p.WindowOpacity = wo; return true;
            case "keyboardLayoutOverride":
                p.KeyboardLayoutOverride = string.IsNullOrEmpty(value) ? null : value; return true;
            // VM resources.
            case "memoryGB":
                if (!int.TryParse(value, System.Globalization.NumberStyles.Integer, inv, out var mg)) return false;
                if (mg < 0 || mg > 1024) return false;
                p.MemoryGB = mg; return true;
            case "networkMode":
                if (!Enum.TryParse<NetworkMode>(value, ignoreCase: true, out var nm)) return false;
                p.NetworkMode = nm; return true;
            case "bridgedInterfaceID":
                p.BridgedInterfaceID = string.IsNullOrEmpty(value) ? null : value; return true;
            case "closeAction":
                if (!Enum.TryParse<CloseAction>(value, ignoreCase: true, out var ca)) return false;
                p.CloseAction = ca; return true;
            // Git identity.
            case "gitUserName": p.GitUserName = value; return true;
            case "gitUserEmail": p.GitUserEmail = value; return true;
            // SSH.
            case "sshKeyRequiresApproval":
                if (!bool.TryParse(value, out var skra)) return false;
                p.SshKeyRequiresApproval = skra; return true;
            // Misc tokens.
            case "digitalOceanToken":
                p.DigitalOceanToken = string.IsNullOrEmpty(value) ? null : value; return true;
            case "digitalOceanRequiresApproval":
                if (!bool.TryParse(value, out var dora)) return false;
                p.DigitalOceanRequiresApproval = dora; return true;
            // Bedrock.
            case "bedrockEnabled":
                if (!bool.TryParse(value, out var be)) return false;
                p.BedrockEnabled = be; return true;
            case "bedrockModelID": p.BedrockModelID = value; return true;
            // Subscription consent state.
            case "subscriptionTokenSwap":
                if (!Enum.TryParse<SubscriptionTokenSwapState>(value, ignoreCase: true, out var ss)) return false;
                p.SubscriptionTokenSwap = ss; return true;
            case "codexTokenSwap":
                if (!Enum.TryParse<SubscriptionTokenSwapState>(value, ignoreCase: true, out var cxs)) return false;
                p.CodexTokenSwap = cxs; return true;
            // Privacy / tracing.
            case "privateMode":
                if (!bool.TryParse(value, out var pm)) return false;
                p.PrivateMode = pm; return true;
            case "traceLevel":
                if (!Enum.TryParse<TraceLevel>(value, ignoreCase: true, out var tl)) return false;
                p.TraceLevel = tl; return true;
            default: return false;
        }
    }

    /// <summary>
    /// Build a <see cref="CloudUploader"/> from the install identity if
    /// the host is enrolled, and attach it to the emitter. Called from
    /// the constructor and after a successful enrollment so events
    /// stop dropping with "no uploader".
    /// </summary>
    private void AttachCloudUploaderIfEnrolled()
    {
        if (!_enrollment.IsEnrolled) return;
        try
        {
            _cloudUploader?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        catch { /* best-effort */ }
        _cloudUploader = new CloudUploader(EnrollmentStore.DefaultIngestUrl(), _cloudIdentity);
        _cloudEmitter.SetUploader(_cloudUploader);
    }

    /// <summary>
    /// Opens the profile editor window with the template profile
    /// pre-loaded — what new profiles are seeded from. Mirrors the
    /// macOS port's Preferences sheet.
    /// </summary>
    private void OpenTemplateProfileEditor()
    {
        var template = _profileStore.LoadOrCreateTemplate();
        // Use a fresh ProfilesViewModel scoped to the template alone so
        // edits don't surprise the regular profile picker. The generic
        // editor view binds to ObservableCollection<Profile> so we
        // present a single-element list with the template selected.
        var pvm = new ProfilesViewModel(_profileStore, _services.Paths)
        {
            EditorOnly = true,
        };
        pvm.Profiles.Clear();
        pvm.Profiles.Add(template);
        pvm.Selected = template;
        var editor = new Views.ProfileEditorWindow
        {
            DataContext = pvm,
            Owner = System.Windows.Application.Current.MainWindow,
            Title = "Template profile (defaults for new profiles)",
        };
        editor.Closed += (_, _) =>
        {
            // Save whatever the user changed.
            _profileStore.SaveTemplate(template);
        };
        editor.Show();
    }

    /// <summary>
    /// On startup, reap any bromure-warm-* / bromure-ses-* compute
    /// systems left behind by a prior crash. The current AC build
    /// doesn't run a warm pool, but earlier builds did and could
    /// have leaked entries; on first launch after upgrade we still
    /// need to clean them up so they don't pin bromure-base.vhdx.
    /// </summary>
    private async Task CleanupOrphanedVmsAsync()
    {
        try
        {
            var warmRoot = Path.Combine(_services.Paths.AppDataRoot, "warm-pool");
            if (Directory.Exists(warmRoot))
            {
                await WarmVmPool.CleanupOrphansAsync(warmRoot).ConfigureAwait(false);
            }
        }
        catch { /* best-effort */ }
    }

    partial void OnSelectedNavigationChanged(NavigationItem value)
    {
        foreach (var n in Navigation) n.IsSelected = n == value;
    }

    /// <summary>Switch the right-pane content. Wired to the menu bar +
    /// keyboard shortcuts (Ctrl+1..5).</summary>
    [RelayCommand]
    public void GoToNavigation(string kindName)
    {
        if (!Enum.TryParse<NavigationKind>(kindName, out var kind)) return;
        var match = Navigation.FirstOrDefault(n => n.Kind == kind);
        if (match is not null) SelectedNavigation = match;
    }

    /// <summary>Launch a session for the currently-selected profile.
    /// Bound to File → New Session and Ctrl+N. Falls back to the first
    /// row when nothing is selected (matches macOS's default-behaviour
    /// of opening the first profile when the user hits Cmd+N from
    /// fresh).</summary>
    [RelayCommand]
    public async Task NewSessionAsync()
    {
        if (SessionsPane is null) return;
        SessionsPane.Selected ??= SessionsPane.Rows.FirstOrDefault();
        await SessionsPane.LaunchSelectedAsync().ConfigureAwait(true);
    }

    /// <summary>UX #2 — copy the dism command to the clipboard so
    /// the user can paste into an elevated cmd prompt. Cheaper UX
    /// than triggering UAC ourselves for users who'd rather verify
    /// the command before running it.</summary>
    [RelayCommand]
    public void CopyHyperVCommand()
    {
        try { System.Windows.Clipboard.SetText(HyperVFixCommand); }
        catch { /* clipboard contention; user can retry */ }
    }

    /// <summary>UX #2 — run dism.exe with UAC elevation to enable
    /// the Microsoft-Hyper-V feature in one click. dism.exe exists
    /// in every supported Windows install path and is the most
    /// reliable enable mechanism on Win11 24H2+ (the PowerShell
    /// Enable-WindowsOptionalFeature cmdlet fails with "Class not
    /// registered" on some recent builds, per HyperVPreflight.cs).</summary>
    [RelayCommand]
    public void EnableHyperV()
    {
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo
            {
                FileName = "dism.exe",
                Arguments = "/Online /Enable-Feature /FeatureName:Microsoft-Hyper-V /All /NoRestart",
                UseShellExecute = true,   // required for Verb=runas (UAC)
                Verb = "runas",
                WindowStyle = System.Diagnostics.ProcessWindowStyle.Normal,
            };
            System.Diagnostics.Process.Start(psi);
            // dism takes 30-90s; show a follow-up dialog explaining
            // that a reboot is required when it finishes. We don't
            // wait on the process so the UI stays responsive.
            System.Windows.MessageBox.Show(
                "DISM is enabling Microsoft-Hyper-V in the background. " +
                "A console window will show progress.\n\n" +
                "When it finishes successfully, REBOOT to activate Hyper-V " +
                "and then relaunch Bromure.",
                "Enabling Hyper-V",
                System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Information);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // User canceled the UAC prompt — silent, that's a normal
            // choice. They can always copy the command instead.
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(
                "Couldn't launch dism.exe: " + ex.Message + "\n\n" +
                "Copy the command and run it from an elevated cmd prompt instead.",
                "Enable Hyper-V failed",
                System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Warning);
        }
    }

    /// <summary>Window menu → About. Shows a small dialog with the
    /// app version + bake-image version. Direct port of macOS's
    /// NSApp.orderFrontStandardAboutPanel.</summary>
    [RelayCommand]
    public void ShowAbout()
    {
        var version = System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version?.ToString() ?? "dev";
        var imageVersion = Bromure.AC.Core.Model.ImageVersionAlert.VersionPrefix(ImageManager.ImageVersion);
        System.Windows.MessageBox.Show(
            $"Bromure Agentic Coding\nVersion {version}\nBase image v{imageVersion}",
            "About Bromure",
            System.Windows.MessageBoxButton.OK,
            System.Windows.MessageBoxImage.Information);
    }

    /// <summary>Help menu → Documentation. Opens the project README
    /// in the default browser. Same shape macOS NSApp uses for the
    /// Help menu's documentation link.</summary>
    [RelayCommand]
    public void OpenDocumentation()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "https://bromure.io",
                UseShellExecute = true,
            });
        }
        catch { /* best-effort */ }
    }

    public MitmEngine Engine => _engine;
    public ImageManager Images => _images;
    public bool HasError => Progress.Error is not null;

    private void ResolvePhaseFromCache()
    {
        var artefacts = BakeArtefacts.InDirectory(_services.Paths.ImagesDirectory);
        Phase = artefacts.AllExist() ? ShellPhase.Session : ShellPhase.Welcome;
        if (Phase == ShellPhase.Session)
        {
            PrepareSessionSync();
            // Defer the stale-image nag so the main window is visible
            // first — a MessageBox racing the WPF init feels broken.
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(
                new Action(CheckStaleBaseImageNag),
                System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        }
    }

    private CancellationTokenSource? _bakeCts;

    [RelayCommand]
    private async Task StartAsync()
    {
        // Diagnostic log: write to a known location BEFORE any logic so
        // we can prove the click handler fired even if a later step
        // throws. Bromure had a stretch where Get Started looked like a
        // no-op because [RelayCommand] silently swallowed exceptions
        // from this method; that's a known gotcha with the toolkit's
        // AsyncRelayCommand path. The full StartAsync body is wrapped
        // in a try/catch below so the same can't happen again, but
        // this file is the canonical "did the click fire?" proof.
        TraceStart("click");
        try
        {
            await StartAsyncImpl();
        }
        catch (Exception ex)
        {
            TraceStart("uncaught: " + ex);
            Progress.Error = "Get Started failed: " + ex.Message +
                "\n\n(diagnostic trace: %LOCALAPPDATA%\\Bromure\\AC\\start-trace.log)";
            Phase = ShellPhase.Welcome;
        }
    }

    private void TraceStart(string line)
    {
        try
        {
            var path = Path.Combine(_services.Paths.AppDataRoot, "start-trace.log");
            File.AppendAllText(path,
                DateTime.UtcNow.ToString("o") + " " + line + "\n");
        }
        catch { /* trace is best-effort */ }
    }

    private async Task StartAsyncImpl()
    {
        // Re-check Hyper-V on click in case the user enabled the
        // feature + rebooted without restarting BromureAC.
        var hv = HyperVPreflight.Detect();
        TraceStart("preflight ok=" + hv.Ok);
        if (!hv.Ok)
        {
            Progress.Error = (hv.ErrorMessage ?? "Hyper-V pre-flight failed.")
                + "\n\n" + (hv.FixInstruction ?? "");
            return;
        }
        var artefacts = BakeArtefacts.InDirectory(_services.Paths.ImagesDirectory);
        TraceStart("artefacts.AllExist=" + artefacts.AllExist());
        if (artefacts.AllExist())
        {
            UpdateImageInfoLine();
            PrepareSessionSync();
            Phase = ShellPhase.Session;
            return;
        }

        // No baked artefacts — drive the Alpine-based bake. No file
        // picker: VmBaker downloads the Alpine virt ISO itself and
        // boots it inside a transient Hyper-V VM, exactly like the
        // macOS port does. Same setup.sh runs in both.
        Progress.Reset();
        Progress.Status = "Preparing Alpine-driven bake…";
        Phase = ShellPhase.Initializing;
        _bakeCts?.Cancel();
        _bakeCts = new CancellationTokenSource();
        var ct = _bakeCts.Token;
        var imagesDir = _services.Paths.ImagesDirectory;
        var dispatcher = System.Windows.Application.Current.Dispatcher;
        var fwd = new Progress<VmBaker.BakeProgress>(p =>
        {
            void Apply()
            {
                // "console" updates carry guest serial bytes — append to
                // the log buffer but don't churn the status line on every
                // newline. Everything else updates both.
                if (p.Stage == "console")
                {
                    Progress.AppendLog(p.Message);
                }
                else
                {
                    Progress.Status = "[" + p.Stage + "] " + p.Message;
                    Progress.AppendLog("[" + p.Stage + "] " + p.Message + "\n");
                    if (!double.IsNaN(p.Fraction)) Progress.BumpProgress(p.Fraction);
                }
            }
            if (dispatcher.CheckAccess()) Apply();
            else dispatcher.Invoke(Apply);
        });

        try
        {
            // Perf #4: BEFORE the bake replaces base.vhdx, flatten
            // every per-profile differencing child so each profile
            // becomes a standalone disk. Without this, the next launch
            // of any pre-existing profile would trip the 0xC03A000E
            // parent-UniqueId mismatch and auto-recovery would wipe
            // the profile's data. With this, each profile keeps every
            // package + file the user installed pre-rebake.
            var profilesDir = _services.Paths.ProfilesDirectory;
            if (Directory.Exists(profilesDir))
            {
                foreach (var profileDir in Directory.EnumerateDirectories(profilesDir))
                {
                    var diskPath = Path.Combine(profileDir, "session", "disk.vhdx");
                    if (!File.Exists(diskPath)) continue;
                    var profileName = Path.GetFileName(profileDir);
                    Progress.Status = $"Flattening clone for profile {profileName}…";
                    try
                    {
                        await VmBaker.FlattenChildVhdxAsync(diskPath, ct).ConfigureAwait(true);
                    }
                    catch (Exception flattenEx)
                    {
                        // Surface but DON'T abort — a profile that can't
                        // flatten is one profile that loses its state.
                        // Others should still be saved.
                        Progress.AppendLog($"[flatten] FAILED for {profileName}: {flattenEx.Message}\n");
                    }
                }
            }

            var baker = new VmBaker();
            await Task.Run(() => baker.BakeAsync(imagesDir, fwd, ct), ct)
                .ConfigureAwait(true);
            UpdateImageInfoLine();
            PrepareSessionSync();
            Phase = ShellPhase.Session;
        }
        catch (OperationCanceledException)
        {
            Progress.AppendLog("[cancel] Bake cancelled by user.\n");
            Progress.Error = "Bake cancelled.";
            Phase = ShellPhase.Welcome;
        }
        catch (Exception ex)
        {
            Progress.AppendLog("[fail] " + ex.Message + "\n");
            Progress.Error = "Bake failed: " + ex.Message;
            Phase = ShellPhase.Welcome;
        }
        finally
        {
            Progress.IsRunning = false;
        }
    }

    [RelayCommand]
    private void Cancel()
    {
        // Cancel any in-flight bake. The actual VM stop happens in
        // VmBaker's finally block — we just signal the token here.
        try { _bakeCts?.Cancel(); } catch { /* best-effort */ }
        var artefacts = BakeArtefacts.InDirectory(_services.Paths.ImagesDirectory);
        Phase = artefacts.AllExist() ? ShellPhase.Session : ShellPhase.Welcome;
    }


    private void PrepareSessionSync()
    {
        if (Session is not null) return;

        var sessionRoot = Path.Combine(_services.Paths.SessionsDirectory, "default-session");
        Directory.CreateDirectory(sessionRoot);

        var profileId = Guid.Parse("00000000-0000-0000-0000-000000000001");
        var artefacts = BakeArtefacts.InDirectory(_services.Paths.ImagesDirectory);
        var activeProfile = _profileStore.LoadAll().FirstOrDefault();

        Session = new SessionViewModel(profileId, activeProfile?.Name ?? "Default Profile",
            _engine, activeProfile, artefacts, sessionRoot);

        if (!artefacts.AllExist())
        {
            Session.PreflightError =
                $"HCS base artefacts missing in {_services.Paths.ImagesDirectory}.\n\n" +
                $"Expected: {VmBaker.OutputBaseFileName}, " +
                $"{VmBaker.OutputKernelFileName}, {VmBaker.OutputInitrdFileName}.\n\n" +
                "Run the bake from Settings → Bake base image, or via\n" +
                "  bromure-spike bake-hcs <source-vhdx> " + _services.Paths.ImagesDirectory;
        }
    }

    private void UpdateImageInfoLine()
    {
        var artefacts = BakeArtefacts.InDirectory(_services.Paths.ImagesDirectory);
        if (artefacts.AllExist())
        {
            var fi = new FileInfo(artefacts.BaseVhdxPath);
            var sizeMb = fi.Length / (1024.0 * 1024.0);
            var installed = _images.ReadInstalledImageVersion();
            var current = Bromure.SandboxEngine.Image.ImageManager.ImageVersion;
            // Compare version-prefix only — the bake-uuid suffix on the
            // installed stamp distinguishes individual bakes of the
            // same version and isn't a drift signal (see
            // ImageVersionAlert.Evaluate for the same reasoning).
            var installedPrefix = installed is null ? null : Bromure.AC.Core.Model.ImageVersionAlert.VersionPrefix(installed);
            var currentPrefix = Bromure.AC.Core.Model.ImageVersionAlert.VersionPrefix(current);
            if (installedPrefix is not null && installedPrefix != currentPrefix)
            {
                ImageInfoLine = $"bromure-base.vhdx v{installedPrefix} ({sizeMb:F0} MB) — app expects v{currentPrefix}";
            }
            else
            {
                ImageInfoLine = $"bromure-base.vhdx cached ({sizeMb:F0} MB)";
            }
        }
        else
        {
            ImageInfoLine = "Bake required: " + VmBaker.OutputBaseFileName + " + kernel + initrd";
        }
    }

    /// <summary>
    /// Non-blocking "base image update available" nag. Direct port of
    /// macOS <c>BromureAC.swift:1412-1431</c>. Fires once per app
    /// launch — "Later" dismisses for this session only; the option
    /// re-appears next time so the user can update at their own pace.
    /// </summary>
    private bool _staleImageNagShown;
    public void CheckStaleBaseImageNag()
    {
        if (_staleImageNagShown) return;
        _staleImageNagShown = true;
        var artefacts = BakeArtefacts.InDirectory(_services.Paths.ImagesDirectory);
        if (!artefacts.AllExist()) return;  // no base yet, the Get-Started flow handles this
        var installed = _images.ReadInstalledImageVersion();
        var current = Bromure.SandboxEngine.Image.ImageManager.ImageVersion;
        if (installed is null) return;
        // Compare version-prefix only — see ImageVersionAlert.Evaluate
        // for why the bake-uuid suffix shouldn't trigger a drift nag.
        var installedPrefix = Bromure.AC.Core.Model.ImageVersionAlert.VersionPrefix(installed);
        var currentPrefix = Bromure.AC.Core.Model.ImageVersionAlert.VersionPrefix(current);
        if (installedPrefix == currentPrefix) return;
        var msg = $"Your base image is at version {installedPrefix} but the app ships version {currentPrefix}.\n\n"
                  + "The current image still works — rebuilding (~5-10 min) picks up the latest "
                  + "setup.sh changes (new tools, updated configs).";
        var result = System.Windows.MessageBox.Show(msg,
            "Base image update available",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Information,
            System.Windows.MessageBoxResult.No);
        if (result == System.Windows.MessageBoxResult.Yes)
        {
            // Navigate to Settings so the user can click "Build / rebuild".
            GoToNavigation(NavigationKind.Settings.ToString());
        }
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

