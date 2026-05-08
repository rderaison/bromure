using System.Collections.ObjectModel;
using System.IO;
using System.Windows.Media;
using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Engine;
using Bromure.SandboxEngine.Wsl;
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
    private readonly Func<string> _baseRootfsPathProvider;
    private readonly Func<string> _sessionRootProvider;
    private readonly WarmDistroPool? _warmPool;
    private readonly Action<Profile> _onEdit;

    public ObservableCollection<SessionRowViewModel> Rows { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelection))]
    private SessionRowViewModel? _selected;

    public bool HasSelection => Selected is not null;

    public bool HasRows => Rows.Count > 0;

    public SessionsViewModel(ProfileStore store, MitmEngine engine,
        Func<string> baseRootfsPathProvider,
        Func<string> sessionRootProvider,
        WarmDistroPool? warmPool,
        Action<Profile> onEdit)
    {
        _store = store;
        _engine = engine;
        _baseRootfsPathProvider = baseRootfsPathProvider;
        _sessionRootProvider = sessionRootProvider;
        _warmPool = warmPool;
        _onEdit = onEdit;
        Rows.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasRows));
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
                    _baseRootfsPathProvider, _sessionRootProvider,
                    _warmPool, _onEdit));
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
}

/// <summary>
/// One row in the picker. Owns the running <see cref="SessionViewModel"/>
/// (or null). Knows how to launch/shutdown/edit the underlying
/// profile.
/// </summary>
public sealed partial class SessionRowViewModel : ObservableObject
{
    private readonly MitmEngine _engine;
    private readonly Func<string> _baseRootfsPathProvider;
    private readonly Func<string> _sessionRootProvider;
    private readonly WarmDistroPool? _warmPool;
    private readonly Action<Profile> _onEdit;

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
        Func<string> baseRootfsPathProvider,
        Func<string> sessionRootProvider,
        WarmDistroPool? warmPool,
        Action<Profile> onEdit)
    {
        _profile = profile;
        _engine = engine;
        _baseRootfsPathProvider = baseRootfsPathProvider;
        _sessionRootProvider = sessionRootProvider;
        _warmPool = warmPool;
        _onEdit = onEdit;
    }

    internal void UpdateProfile(Profile p) => Profile = p;

    [RelayCommand]
    public async Task LaunchAsync()
    {
        if (Session is { IsRunning: true }) return;
        if (IsLaunching) return;
        var rootfs = _baseRootfsPathProvider();
        var sessionRoot = _sessionRootProvider();
        if (!File.Exists(rootfs))
        {
            var stub = new SessionViewModel(Profile.Id, Profile.Name, _engine, Profile,
                rootfs, sessionRoot);
            stub.PreflightError = $"Base rootfs not found at {rootfs}.\n" +
                                  "Run Settings → Build / rebuild first.";
            Session = stub;
            StatusDetail = stub.PreflightError;
            return;
        }
        Directory.CreateDirectory(sessionRoot);
        IsLaunching = true;
        // Try to grab a pre-imported warm distro. 250 ms is enough
        // when the pool's already topped up; failure → null and we
        // fall back to a cold import inside StartAsync.
        WarmDistro? warm = null;
        if (_warmPool is not null)
        {
            try
            {
                warm = await _warmPool.AcquireAsync(TimeSpan.FromMilliseconds(250),
                    CancellationToken.None).ConfigureAwait(true);
            }
            catch { }
        }
        StatusDetail = warm is null
            ? "Importing distro + bringing up MITM proxy…"
            : "Adopting warm distro + bringing up MITM proxy…";
        try
        {
            var sv = new SessionViewModel(Profile.Id, Profile.Name, _engine, Profile,
                rootfs, sessionRoot, warm);
            Session = sv;
            // Mirror the inner VM's status-detail back to the row so
            // the user sees "Bringing up MITM proxy…" / "kitty up · …"
            // updates as they happen.
            sv.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName is nameof(SessionViewModel.VmStatusDetail))
                    StatusDetail = sv.VmStatusDetail;
            };
            await sv.StartAsync().ConfigureAwait(true);
            if (sv.HasFailure) StatusDetail = sv.VmStatusDetail;
            else StatusDetail = "";
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
    }

    [RelayCommand]
    private void Edit() => _onEdit(Profile);

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
