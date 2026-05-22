using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Windows.Media;
using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Engine;
using Bromure.SandboxEngine.Hcs;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

/// <summary>
/// macOS-style profile picker. Lists the user's profiles and routes
/// click → launch (kitty as a free WSLg window). Mirrors the
/// <c>ProfilePickerView</c> in <c>Sources/AgentCoding/ProfileViews.swift</c>.
///
/// <para>Each row carries the profile's name + colour dot + a green
/// dot when its session is running. Click "Open" → spawns kitty as
/// a separate Windows window (no embed). The session lives on its
/// own; closing kitty does not close BromureAC.</para>
/// </summary>
public sealed partial class SessionsViewModel : ObservableObject
{
    private readonly ProfileStore _store;
    private readonly MitmEngine _engine;
    private readonly Func<BakeArtefacts> _artefactsProvider;
    private readonly Func<Guid, string> _sessionRootProvider;
    // Indirection so the bake driver can swap the live pool out (it
    // gets disposed before bake to release the parent VHDX, then
    // recreated after). Each launch resolves the current pool fresh.
    private readonly Func<WarmVmPool?> _warmPoolProvider;
    private readonly Action<Profile> _onEdit;
    // Optional: reads the bake-time version stamp from disk. Used by
    // LaunchAsync to surface the macOS-port image-versioning alert
    // when a profile's BaseImageVersionAtClone has drifted. Provider
    // returns null when no bake has stamped yet — alert never fires.
    private readonly Func<string?> _installedBaseVersionProvider;

    public ObservableCollection<SessionRowViewModel> Rows { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelection))]
    private SessionRowViewModel? _selected;

    public bool HasSelection => Selected is not null;

    public bool HasRows => Rows.Count > 0;

    public SessionsViewModel(ProfileStore store, MitmEngine engine,
        Func<BakeArtefacts> artefactsProvider,
        Func<Guid, string> sessionRootProvider,
        Func<WarmVmPool?> warmPoolProvider,
        Action<Profile> onEdit,
        Func<string?>? installedBaseVersionProvider = null)
    {
        _store = store;
        _engine = engine;
        _artefactsProvider = artefactsProvider;
        _sessionRootProvider = sessionRootProvider;
        _warmPoolProvider = warmPoolProvider;
        _onEdit = onEdit;
        _installedBaseVersionProvider = installedBaseVersionProvider ?? (() => null);
        Rows.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasRows));
        };
        // Wire the tabbed session window's "+" / Ctrl+T new-tab hook
        // back to the same RunAsync path the profile-row "Run" button
        // takes. Keeps the View layer ignorant of how sessions get
        // created.
        Views.SessionWindow.NewSessionRequested = profileId =>
        {
            var row = Rows.FirstOrDefault(r => r.Profile.Id == profileId);
            if (row is not null) _ = row.LaunchAsync();
        };
        Reload();
    }

    public void Reload()
    {
        var existingByProfile = Rows.ToDictionary(r => r.Profile.Id);
        Rows.Clear();
        foreach (var p in _store.LoadAll())
        {
            if (existingByProfile.TryGetValue(p.Id, out var row))
            {
                row.UpdateProfile(p);
                Rows.Add(row);
            }
            else
            {
                Rows.Add(new SessionRowViewModel(p, _engine,
                    _artefactsProvider, _sessionRootProvider,
                    _warmPoolProvider, _onEdit,
                    _store, _installedBaseVersionProvider));
            }
        }
        if (Selected is null && Rows.Count > 0) Selected = Rows[0];
    }

    [RelayCommand]
    private void NewProfile()
    {
        // Seed from the template profile (Settings → Edit template)
        // so common fields the user already configured (default tool,
        // colour, auth mode, etc.) carry over to every new profile.
        var p = _store.NewFromTemplate();
        _store.Save(p);
        Reload();
        Selected = Rows.LastOrDefault();
        // Open the editor right away — without this an empty picker
        // strands the user with no obvious way into the editor.
        if (Selected is not null) _onEdit(Selected.Profile);
    }

    [RelayCommand]
    private async Task DeleteSelectedAsync()
    {
        if (Selected is null) return;
        await Selected.ShutdownAsync().ConfigureAwait(true);
        _store.Delete(Selected.Profile.Id);
        Reload();
    }

    /// <summary>Launch the currently selected profile.</summary>
    [RelayCommand]
    public Task LaunchSelectedAsync()
        => Selected?.LaunchAsync() ?? Task.CompletedTask;

    /// <summary>Stop the currently selected profile's session if running.</summary>
    [RelayCommand]
    public Task StopSelectedAsync()
        => Selected?.ShutdownAsync() ?? Task.CompletedTask;

    /// <summary>Audit 08 §2.4 — Duplicate currently selected profile.</summary>
    [RelayCommand]
    public void DuplicateSelected()
    {
        if (Selected is null) return;
        var clone = Selected.DuplicateProfile();
        Reload();
        Selected = Rows.FirstOrDefault(r => r.Profile.Id == clone.Id) ?? Selected;
    }

    /// <summary>Audit 08 §2.4 — Reset disk for currently selected profile.</summary>
    [RelayCommand]
    public Task ResetSelectedDiskAsync()
        => Selected?.ResetDiskAsync() ?? Task.CompletedTask;
}

/// <summary>
/// One row in the picker. Owns the running <see cref="SessionViewModel"/>
/// (or null). Knows how to launch/shutdown/edit the underlying
/// profile.
/// </summary>
public sealed partial class SessionRowViewModel : ObservableObject
{
    private readonly MitmEngine _engine;
    private readonly Func<BakeArtefacts> _artefactsProvider;
    private readonly Func<Guid, string> _sessionRootProvider;
    // Indirection so the bake driver can swap the live pool out (it
    // gets disposed before bake to release the parent VHDX, then
    // recreated after). Each launch resolves the current pool fresh.
    private readonly Func<WarmVmPool?> _warmPoolProvider;
    private readonly Action<Profile> _onEdit;
    private readonly ProfileStore _store;
    private readonly Func<string?> _installedBaseVersionProvider;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Name))]
    [NotifyPropertyChangedFor(nameof(ColorBrush))]
    [NotifyPropertyChangedFor(nameof(SubtitleText))]
    private Profile _profile;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsRunning))]
    [NotifyPropertyChangedFor(nameof(RunStatusText))]
    private SessionViewModel? _session;

    /// <summary>
    /// True between the user clicking Launch and either the kitty
    /// embed appearing OR the boot failing. Drives a per-row spinner
    /// + disables the Launch button while in flight.
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(RunStatusText))]
    private bool _isLaunching;

    /// <summary>
    /// One-line status under the profile name when the session is
    /// either booting (live import / proxy / cert / kitty progress)
    /// or has failed (last error). Empty in the idle/running steady
    /// state — the run-state dot already covers those.
    /// </summary>
    [ObservableProperty] private string _statusDetail = "";

    public string Name => Profile.Name;
    public bool IsRunning => Session?.IsRunning == true;
    public string RunStatusText => IsLaunching ? "Launching…" : (IsRunning ? "Running" : "Idle");

    /// <summary>Audit 08 §2.2: red badge on the picker pill so the
    /// user sees the compromised state without trying to launch.
    /// Reads the per-session compromised.flag at the session root;
    /// macOS uses the equivalent SessionDisk.isCompromised static.</summary>
    public bool IsCompromised
    {
        get
        {
            try
            {
                var sessionRoot = _sessionRootProvider(Profile.Id);
                return CompromiseGate.IsCompromised(sessionRoot);
            }
            catch { return false; }
        }
    }

    public string SubtitleText
    {
        get
        {
            var bits = new List<string> { Profile.Tool.ToString() };
            if (Profile.FolderPaths.Count > 0)
                bits.Add($"{Profile.FolderPaths.Count} folder{(Profile.FolderPaths.Count == 1 ? "" : "s")}");
            return string.Join(" · ", bits);
        }
    }

    public Brush ColorBrush => new SolidColorBrush(ProfileColorToWpf(Profile.Color));

    public SessionRowViewModel(Profile profile, MitmEngine engine,
        Func<BakeArtefacts> artefactsProvider,
        Func<Guid, string> sessionRootProvider,
        Func<WarmVmPool?> warmPoolProvider,
        Action<Profile> onEdit,
        ProfileStore? store = null,
        Func<string?>? installedBaseVersionProvider = null)
    {
        _profile = profile;
        _engine = engine;
        _artefactsProvider = artefactsProvider;
        _sessionRootProvider = sessionRootProvider;
        _warmPoolProvider = warmPoolProvider;
        _onEdit = onEdit;
        _store = store!;
        _installedBaseVersionProvider = installedBaseVersionProvider ?? (() => null);
    }

    internal void UpdateProfile(Profile p) => Profile = p;

    /// <summary>
    /// WPF MessageBox-backed prompt for the image-version alert.
    /// Pure decision logic lives in <see cref="ImageVersionAlert"/> so
    /// the test suite can cover every branch without referencing WPF;
    /// this row supplies the actual UI when running in the app.
    /// </summary>
    private static CompromiseGate.WipeDecision DefaultWipeAndLaunchPrompt(string text, string detail)
    {
        // Critical-style modal — destructive action requires explicit
        // Yes click. Default selection is Cancel so an enter-press
        // can't auto-wipe.
        var combined = text + "\n\n" + detail
                       + "\n\nProceed? (Yes = wipe and launch, No = cancel)";
        var result = System.Windows.MessageBox.Show(
            combined,
            "Bromure AC — compromised VM",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Stop,
            System.Windows.MessageBoxResult.No);
        return result == System.Windows.MessageBoxResult.Yes
            ? CompromiseGate.WipeDecision.WipeAndLaunch
            : CompromiseGate.WipeDecision.Cancel;
    }

    private static ImageVersionAlert.Decision DefaultImageVersionPrompt(string text, string detail)
    {
        // Yes = "Reset and launch", No = "Launch as-is", Cancel = abort.
        var combined = text + "\n\n" + detail;
        var result = System.Windows.MessageBox.Show(
            combined,
            "Bromure AC — base image updated",
            System.Windows.MessageBoxButton.YesNoCancel,
            System.Windows.MessageBoxImage.Question,
            System.Windows.MessageBoxResult.No);
        return result switch
        {
            System.Windows.MessageBoxResult.Yes => ImageVersionAlert.Decision.ResetAndLaunch,
            System.Windows.MessageBoxResult.Cancel => ImageVersionAlert.Decision.Cancel,
            _ => ImageVersionAlert.Decision.ProceedAsIs,
        };
    }

    /// <summary>Launch a brand-new session in a new tab, ignoring
    /// whatever this row's primary <see cref="Session"/> slot is
    /// already doing. Used by the SessionWindow's "+" button so the
    /// user can open additional tabs for the same profile.</summary>
    public async Task LaunchAdditionalSessionAsync()
    {
        var artefacts = _artefactsProvider();
        if (!artefacts.AllExist()) return;
        var sessionRoot = _sessionRootProvider(Profile.Id);
        Directory.CreateDirectory(sessionRoot);
        WarmVm? warm = null;
        var pool = _warmPoolProvider();
        if (pool is not null)
        {
            try
            {
                warm = await pool.AcquireAsync(TimeSpan.FromMilliseconds(250),
                    CancellationToken.None).ConfigureAwait(true);
            }
            catch { }
        }
        var sv = new SessionViewModel(Profile.Id, Profile.Name, _engine, Profile,
            artefacts, sessionRoot, warm);
        // Perf #3: open the booting placeholder immediately, before
        // the ~30s boot, so the second-window UX matches the first.
        Views.SessionWindow.ShowBootingView(sv);
        await sv.StartAsync().ConfigureAwait(true);
    }

    [RelayCommand]
    public async Task LaunchAsync()
    {
        if (Session is { IsRunning: true })
        {
            // Row already running. Treat re-click as "open another
            // tab" so the user gets the additive UX they expect.
            await LaunchAdditionalSessionAsync().ConfigureAwait(true);
            return;
        }
        if (IsLaunching) return;
        var artefacts = _artefactsProvider();
        var sessionRoot = _sessionRootProvider(Profile.Id);
        if (!artefacts.AllExist())
        {
            var stub = new SessionViewModel(Profile.Id, Profile.Name, _engine, Profile,
                artefacts, sessionRoot);
            stub.PreflightError = $"Base bake artefacts missing at {Path.GetDirectoryName(artefacts.BaseVhdxPath)}.\n" +
                                  "Run Settings → Build / rebuild first.";
            Session = stub;
            StatusDetail = stub.PreflightError;
            return;
        }
        Directory.CreateDirectory(sessionRoot);

        // Compromise gate. If the proxy flagged this profile in a
        // previous session, refuse to boot until the user explicitly
        // approves a wipe. Direct port of BromureAC.swift:2011-2017
        // + confirmWipeAndProceed at :2499.
        if (CompromiseGate.IsCompromised(sessionRoot))
        {
            var wipeDecision = CompromiseGate.ConfirmWipe(Profile, DefaultWipeAndLaunchPrompt);
            if (wipeDecision != CompromiseGate.WipeDecision.WipeAndLaunch) return;
            CompromiseGate.WipeForCompromise(sessionRoot);
        }

        // Image-version drift gate. When the bake has rotated since
        // this profile's disk was cloned, surface the 3-button alert
        // ("Reset and launch" / "Launch as-is" / "Cancel"). Direct
        // port of BromureAC.swift:2019-2041.
        var diskPath = Path.Combine(sessionRoot, "disk.vhdx");
        var diskExists = File.Exists(diskPath);
        var installedVersion = _installedBaseVersionProvider();
        var decision = ImageVersionAlert.Evaluate(
            Profile, installedVersion, diskExists, DefaultImageVersionPrompt);
        if (decision == ImageVersionAlert.Decision.Cancel) return;
        if (decision == ImageVersionAlert.Decision.ResetAndLaunch && installedVersion is not null)
        {
            ImageVersionAlert.ApplyReset(sessionRoot, Profile, installedVersion, _store);
        }

        IsLaunching = true;
        // Try to grab a pre-created warm VM. 250 ms is enough when the
        // pool's already topped up; failure → null and we fall back to
        // a cold create inside StartAsync.
        WarmVm? warm = null;
        var pool = _warmPoolProvider();
        if (pool is not null)
        {
            try
            {
                warm = await pool.AcquireAsync(TimeSpan.FromMilliseconds(250),
                    CancellationToken.None).ConfigureAwait(true);
            }
            catch { }
        }
        StatusDetail = warm is null
            ? "Cloning VHDX + booting VM + bringing up MITM proxy…"
            : "Adopting warm VM + bringing up MITM proxy…";
        try
        {
            var sv = new SessionViewModel(Profile.Id, Profile.Name, _engine, Profile,
                artefacts, sessionRoot, warm);
            Session = sv;
            // Perf #3: pop the session window IMMEDIATELY with a
            // booting placeholder, so the user gets feedback while
            // the VM cold-boots (~30 s). The placeholder watches sv's
            // PropertyChanged and swaps itself out for the real VNC
            // view as soon as IsRunning + VmRuntimeId arrive.
            Views.SessionWindow.ShowBootingView(sv);
            // Mirror the inner VM's status-detail back to the row so
            // the user sees "Bringing up MITM proxy…" / "kitty up · …"
            // updates as they happen. Also drop the Session reference
            // when the VM transitions out of Running — that's how the
            // close-last-tab cascade unsticks the row's green dot
            // (Row.IsRunning is computed from Session?.IsRunning, but
            // WPF doesn't re-evaluate computed-from-nested unless the
            // top-level _session reference itself changes).
            sv.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName is nameof(SessionViewModel.VmStatusDetail))
                    StatusDetail = sv.VmStatusDetail;
                if (e.PropertyName is nameof(SessionViewModel.IsRunning) && !sv.IsRunning)
                {
                    System.Windows.Application.Current?.Dispatcher.InvokeAsync(() =>
                    {
                        Session = null;
                        StatusDetail = "";
                    });
                }
            };
            await sv.StartAsync().ConfigureAwait(true);
            if (sv.HasFailure) StatusDetail = sv.VmStatusDetail;
            else
            {
                StatusDetail = "";
                // First-launch stamp: record the bake version the
                // child VHDX was cloned from + bump LastUsedAt. Drives
                // future drift detection + the "last used X ago" UI.
                if (installedVersion is not null
                    && string.IsNullOrEmpty(Profile.BaseImageVersionAtClone))
                {
                    Profile.BaseImageVersionAtClone = installedVersion;
                    try { _store.Save(Profile); } catch { }
                }
                try { _store.Touch(Profile.Id); } catch { }
                // Perf #3: the SessionWindow was already opened with a
                // booting placeholder above, and its property listener
                // swapped in the VNC view as soon as IsRunning became
                // true. Nothing to do here.
            }
        }
        finally
        {
            IsLaunching = false;
            OnPropertyChanged(nameof(IsRunning));
            OnPropertyChanged(nameof(RunStatusText));
        }
    }

    [RelayCommand]
    public async Task ShutdownAsync()
    {
        if (Session is null) return;
        await Session.ShutdownAsync().ConfigureAwait(true);
        Session = null;
        OnPropertyChanged(nameof(IsRunning));
        OnPropertyChanged(nameof(RunStatusText));
        // A session that ended after a compromise event will now
        // have CompromiseGate.IsCompromised==true on disk; refresh
        // the badge so the picker reflects it.
        OnPropertyChanged(nameof(IsCompromised));
    }

    /// <summary>External signal — used by the shell when the proxy
    /// fires OnCompromiseDetected. Forces the badge to re-evaluate
    /// without waiting for a session shutdown.</summary>
    public void RefreshCompromiseFlag() => OnPropertyChanged(nameof(IsCompromised));

    [RelayCommand]
    private void Edit() => _onEdit(Profile);

    /// <summary>Audit 08 §2.4 — Duplicate. Deep-clones the profile,
    /// regenerates the Id, appends " (copy)" to the name, clears the
    /// per-clone lifecycle fields. The new profile gets a fresh disk
    /// on its first launch.</summary>
    public Profile DuplicateProfile()
    {
        var clone = ProfileCloner.Clone(Profile);
        _store.Save(clone);
        return clone;
    }

    /// <summary>Audit 08 §2.4 — Reset disk. Wipes the per-profile
    /// VHDX + home overlay + saved-state, mirroring
    /// <see cref="CompromiseGate.WipeForCompromise"/> but without
    /// setting the compromised flag. Profile.json and SSH keys stay.</summary>
    public async Task ResetDiskAsync()
    {
        if (IsRunning)
        {
            await ShutdownAsync().ConfigureAwait(true);
        }
        var sessionRoot = _sessionRootProvider(Profile.Id);
        CompromiseGate.WipeForCompromise(sessionRoot);
    }

    private static Color ProfileColorToWpf(ProfileColor c) => c switch
    {
        ProfileColor.Red => Color.FromRgb(0xFF, 0x4D, 0x4F),
        ProfileColor.Orange => Color.FromRgb(0xFF, 0x9C, 0x33),
        ProfileColor.Green => Color.FromRgb(0x4C, 0xC9, 0x90),
        ProfileColor.Teal => Color.FromRgb(0x33, 0xB0, 0xB8),
        ProfileColor.Blue => Color.FromRgb(0x4C, 0x8B, 0xF5),
        ProfileColor.Purple => Color.FromRgb(0xA8, 0x6E, 0xE0),
        ProfileColor.Pink => Color.FromRgb(0xE0, 0x6E, 0xA8),
        ProfileColor.Gray => Color.FromRgb(0x88, 0x88, 0x99),
        _ => Color.FromRgb(0x4C, 0x8B, 0xF5),
    };
}
