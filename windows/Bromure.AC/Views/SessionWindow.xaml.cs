using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Bromure.AC.Core.Model;
using Bromure.AC.Display;
using Bromure.AC.ViewModels;

namespace Bromure.AC.Views;

/// <summary>
/// Singleton multi-tab session window. Mirrors the macOS
/// <c>TabbedSessionWindow</c>: ONE VM per profile-launch, ONE shared
/// <see cref="VncControl"/>, tabs are kitty PROCESSES inside that VM
/// (identified by <c>--class bromure-&lt;UUID&gt;</c>). The host drives
/// spawn / raise / close over the vsock command channel; the guest's
/// openbox <c>&lt;fullscreen/&gt;</c> rule keeps whichever kitty has
/// focus visible.
/// </summary>
public partial class SessionWindow : Window
{
    private static SessionWindow? _instance;
    /// <summary>The currently-open session window, if any. Read by
    /// MainWindow's Window menu so it can raise the SessionWindow
    /// from the picker. Null when no session is open.</summary>
    public static SessionWindow? CurrentInstance => _instance;

    public static System.Action<System.Guid>? NewSessionRequested { get; set; }

    private SessionViewModel? _vm;
    private VncControl? _vnc;
    private readonly List<SessionTab> _tabs = new();
    private SessionTab? _active;
    // Distinguishes the two close paths:
    //   - last-tab-cascade   (_lastTabCascade=true)  → terminate VM
    //   - user clicked the X (_lastTabCascade=false) → suspend VM
    // Set just before we call Close() in RemoveTab so OnClosing knows.
    private bool _lastTabCascade;
    private bool _shuttingDown;
    // Audit 10 §2.8 alive-roster reconciliation: each entry counts
    // CONSECUTIVE missing-from-roster sweeps. A miss-count of MISS_THRESHOLD
    // reaps the pill. Resets to 0 on every sweep that sees the UUID.
    // Two misses (~3 s at the 1.5 s poll cadence) avoids reaping during
    // a transient kitty restart while still cleaning up orphan tabs
    // within a few seconds.
    private readonly Dictionary<Guid, int> _missCounts = new();
    private const int MissThreshold = 2;

    public SessionWindow()
    {
        InitializeComponent();
        Closing += OnClosing;
        Closed += (_, _) => { if (ReferenceEquals(_instance, this)) _instance = null; };
        InputBindings.Add(new KeyBinding(
            new RelayCommand(_ => CloseActiveTab()),
            new KeyGesture(Key.W, ModifierKeys.Control)));
        InputBindings.Add(new KeyBinding(
            new RelayCommand(_ => AppendTab()),
            new KeyGesture(Key.T, ModifierKeys.Control)));
        // Audit 10 §4.4 — Ctrl+1..9 switches tabs by index. Matches
        // macOS's `performKeyEquivalent` + every other terminal app on
        // Windows (Windows Terminal, kitty, alacritty). Out-of-range
        // gesture is a no-op rather than an error.
        for (int i = 1; i <= 9; i++)
        {
            int idx = i - 1;
            InputBindings.Add(new KeyBinding(
                new RelayCommand(_ =>
                {
                    if (idx < _tabs.Count) SetActiveTab(_tabs[idx]);
                }),
                new KeyGesture(Key.D0 + i, ModifierKeys.Control)));
        }
        StateChanged += (_, _) => UpdateMaxGlyph();
        // Window-level fallback so modifier keys (Shift, Alt) ALWAYS
        // reach the VNC channel even if WPF parked keyboard focus on
        // one of our custom title-bar buttons.
        PreviewKeyDown += OnWindowKey;
        PreviewKeyUp += OnWindowKey;
    }

    /// <summary>Window-close intercept. Two paths:
    ///   - <c>_lastTabCascade</c> = true  → terminate the VM (the user
    ///     manually closed every tab; nothing to preserve).
    ///   - otherwise (user clicked the title-bar X with tabs still
    ///     open) → save VM state to disk + persist the tab roster, so
    ///     the next launch of the same profile resumes the VM and
    ///     rebuilds the pills.
    /// The first Closing fire defers actual close (e.Cancel = true)
    /// while the save/terminate runs async; we re-Close on completion.
    /// </summary>
    private static readonly string CloseLogPath = Path.Combine(
        Path.GetTempPath(), "bromure-close.log");

    private static void CloseLog(string msg)
    {
        try { File.AppendAllText(CloseLogPath,
            $"[{DateTime.Now:HH:mm:ss.fff}] {msg}\n"); } catch { }
    }

    private void RefreshIpChip(string? ip)
    {
        if (string.IsNullOrWhiteSpace(ip))
        {
            IpChip.Visibility = Visibility.Collapsed;
            return;
        }
        IpChip.Content = ip;
        IpChip.Visibility = Visibility.Visible;
    }

    private void OnRebootClick(object sender, RoutedEventArgs e)
    {
        _vm?.RebootCommand?.Execute(null);
    }

    private void OnTraceButtonClick(object sender, RoutedEventArgs e)
    {
        // Audit 10 §4.1 — bring the main window's Trace Inspector
        // pane forward. The session window can't host the trace view
        // itself (which is bound to the cross-profile store), so we
        // surface the existing pane on the picker window.
        var main = System.Windows.Application.Current?.MainWindow;
        if (main is null) return;
        if (main.WindowState == WindowState.Minimized) main.WindowState = WindowState.Normal;
        main.Show();
        main.Activate();
        if (main.DataContext is Bromure.AC.ViewModels.ShellViewModel shell)
        {
            shell.GoToNavigation("TraceInspector");
        }
    }

    private void OnIpChipClick(object sender, RoutedEventArgs e)
    {
        var ip = _vm?.VmGuestIpAddress;
        if (string.IsNullOrWhiteSpace(ip)) return;
        try { System.Windows.Clipboard.SetText(ip); }
        catch { /* clipboard can transiently fail (locked by another process) */ }
    }

    private void RefreshStreamingDot(SessionViewModel vm)
    {
        // Audit 10 §4.1. Read enrollment lazily — App.Services has the
        // paths + secret store needed to instantiate EnrollmentStore.
        // The session window doesn't own a long-lived store; this
        // method runs once at adopt time and the dot doesn't refresh
        // mid-session (enrollment + private-mode toggles are restart-
        // bound for the session anyway).
        try
        {
            var s = App.Services;
            var enrollment = new Bromure.AC.Core.Enrollment.EnrollmentStore(s.Paths, s.Secrets);
            var enrolled = enrollment.IsEnrolled;
            StreamingDot.Visibility = (enrolled && vm.IsTraceUploadEligible)
                ? Visibility.Visible
                : Visibility.Collapsed;
        }
        catch
        {
            StreamingDot.Visibility = Visibility.Collapsed;
        }
    }

    private void RefreshSharesButton(SessionViewModel vm)
    {
        var paths = vm.SharedFolderHostPaths;
        if (paths.Count == 0)
        {
            SharesButton.Visibility = Visibility.Collapsed;
            return;
        }
        SharesList.ItemsSource = paths;
        SharesButton.Visibility = Visibility.Visible;
    }

    private void OnSharesClick(object sender, RoutedEventArgs e)
    {
        SharesPopup.IsOpen = !SharesPopup.IsOpen;
    }

    private void OnSharesItemClick(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Button b && b.Tag is string path
            && !string.IsNullOrWhiteSpace(path))
        {
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = $"\"{path}\"",
                    UseShellExecute = true,
                });
            }
            catch { /* best-effort */ }
        }
        SharesPopup.IsOpen = false;
    }

    /// <summary>3-button prompt asking what to do when the user
    /// closes the window with profile.CloseAction = Ask. Returns
    /// true → suspend, false → shutdown. Cancel resets _shuttingDown
    /// to false so the caller knows to abort the close entirely.</summary>
    private bool AskCloseAction()
    {
        var result = System.Windows.MessageBox.Show(
            this,
            "Suspend this session so it resumes on next launch, " +
            "or shut down and discard its state?",
            "Close session",
            System.Windows.MessageBoxButton.YesNoCancel,
            System.Windows.MessageBoxImage.Question,
            System.Windows.MessageBoxResult.Yes);
        switch (result)
        {
            case System.Windows.MessageBoxResult.Yes:
                return true;   // suspend
            case System.Windows.MessageBoxResult.No:
                return false;  // shutdown
            default:
                _shuttingDown = false;
                return false;
        }
    }

    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        CloseLog($"OnClosing fired (shuttingDown={_shuttingDown}, _vm null? {_vm is null}, " +
                 $"IsRunning? {_vm?.IsRunning}, tabs={_tabs.Count}, cascade={_lastTabCascade})");
        if (_shuttingDown) return;
        if (_vm is null || !_vm.IsRunning)
        {
            CloseLog("OnClosing: nothing live → let Close proceed");
            return;
        }
        _shuttingDown = true;
        e.Cancel = true;
        var vm = _vm;
        var sessionRoot = vm.SessionRoot;
        var tabsJsonPath = Path.Combine(sessionRoot, "tabs.json");
        try
        {
            // Audit 09 §A1 — close behavior driven by profile.CloseAction.
            // Last-tab-cascade always shuts down (no point suspending a
            // 0-tab VM). Otherwise: Suspend / Shutdown / Ask the user.
            bool suspend;
            if (_lastTabCascade || _tabs.Count == 0)
            {
                suspend = false;
            }
            else
            {
                suspend = vm.CloseAction switch
                {
                    Bromure.AC.Core.Model.CloseAction.Suspend => true,
                    Bromure.AC.Core.Model.CloseAction.Shutdown => false,
                    _ => AskCloseAction(),
                };
                // AskCloseAction returns false-and-cancels via _shuttingDown reset.
                if (_shuttingDown == false) { e.Cancel = true; return; }
            }
            if (!suspend)
            {
                CloseLog("OnClosing: terminate path — last-tab cascade, no tabs, or profile.CloseAction=Shutdown");
                try { File.Delete(Path.Combine(sessionRoot, "saved-state.bin")); } catch { }
                try { File.Delete(tabsJsonPath); } catch { }
                await vm.ShutdownAsync().ConfigureAwait(true);
                CloseLog("OnClosing: ShutdownAsync returned");
            }
            else
            {
                CloseLog($"OnClosing: SUSPEND path — sessionRoot={sessionRoot}");
                try
                {
                    var roster = new TabRoster
                    {
                        Tabs = _tabs.ConvertAll(t => new TabRosterEntry
                        {
                            Uuid = t.TabUuid.ToString("N"),
                            Label = t.CurrentLabel,
                        }),
                    };
                    Directory.CreateDirectory(sessionRoot);
                    File.WriteAllText(tabsJsonPath,
                        JsonSerializer.Serialize(roster, new JsonSerializerOptions { WriteIndented = true }));
                    CloseLog($"OnClosing: wrote tabs.json ({roster.Tabs.Count} entries)");
                }
                catch (Exception ex) { CloseLog("OnClosing: roster write failed: " + ex.Message); }
                try
                {
                    await vm.SaveStateAsync().ConfigureAwait(true);
                    CloseLog($"OnClosing: SaveStateAsync returned, VmStatus={vm.VmStatus}");
                }
                catch (Exception ex) { CloseLog("OnClosing: SaveStateAsync THREW: " + ex); }
                // KEEP tabs.json even if save fell back to terminate —
                // the next launch will cold-boot and re-spawn kittys
                // with the persisted UUIDs (poor-man's resume: tab
                // strip survives, in-memory shell state doesn't).
            }
        }
        catch (Exception ex)
        {
            CloseLog("OnClosing: outer THREW: " + ex);
        }
        finally
        {
            CloseLog("OnClosing: finally — re-Close");
            Closing -= OnClosing;
            Close();
        }
    }

    private void OnWindowKey(object sender, KeyEventArgs e)
    {
        // Only forward when keyboard focus is NOT on the VncControl
        // — otherwise its own PreviewKeyDown / KeyDown handlers also
        // fire and the VNC server sees every keysym twice, which
        // cancels modifier state mid-keystroke (Shift_L down +
        // Shift_L down with no Up between, then A press: X's modifier
        // tracker glitches and we get lowercase 'a' instead of 'A').
        if (_vnc is null) return;
        if (ReferenceEquals(System.Windows.Input.Keyboard.FocusedElement, _vnc)) return;
        _vnc.ForwardKey(e);
    }

    /// <summary>Called by SessionsViewModel after StartAsync. Adopts the
    /// VM (one per window) and appends the first tab — which sends
    /// spawn-kitty to the guest just like macOS does.</summary>
    public static void AddTab(SessionViewModel vm)
    {
        if (_instance is null || !_instance.IsLoaded)
        {
            _instance = new SessionWindow();
            _instance.Show();
        }
        _instance.AdoptVmAndOpenFirstTab(vm);
        _instance.Activate();
    }

    /// <summary>Perf #3 — pop a placeholder "Booting…" window
    /// IMMEDIATELY so the user gets feedback while the VM boots
    /// (~30s on a cold start). Subscribes to <paramref name="sv"/>'s
    /// status updates and swaps to the real VNC view once the boot
    /// completes (VmRuntimeId set + IsRunning). Mirrors macOS's
    /// behaviour: window appears on click, doesn't wait for boot.</summary>
    public static void ShowBootingView(SessionViewModel sv)
    {
        if (_instance is null || !_instance.IsLoaded)
        {
            _instance = new SessionWindow();
            _instance.Show();
        }
        _instance.AttachBootingView(sv);
        _instance.Activate();
    }

    private void AttachBootingView(SessionViewModel sv)
    {
        try { System.IO.File.AppendAllText(
            System.IO.Path.Combine(System.IO.Path.GetTempPath(), "bromure-kitty-watch.log"),
            $"[{DateTime.Now:HH:mm:ss.fff}] booting view shown for profile={sv.ProfileName}\n"); } catch { }
        // Only attach the placeholder on the FIRST adoption — if the
        // window is already showing a live VNC for a previous VM,
        // don't blow it away. Tabs added later are handled by the
        // regular AddTab/AppendTab path.
        if (_vm is not null) return;

        var profileName = new TextBlock
        {
            Text = sv.ProfileName,
            Foreground = Brushes.White,
            FontSize = 22,
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        var subtitle = new TextBlock
        {
            Text = "Booting the session VM…",
            Foreground = new SolidColorBrush(Color.FromRgb(0x9F, 0xB6, 0xD8)),
            FontSize = 13,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 8, 0, 24),
        };
        var spinner = new System.Windows.Controls.ProgressBar
        {
            IsIndeterminate = true,
            Width = 320,
            Height = 4,
            Foreground = ProfileAccent(sv.ProfileColor),
            Background = new SolidColorBrush(Color.FromRgb(0x1B, 0x1F, 0x2A)),
            BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        var statusText = new TextBlock
        {
            Text = sv.VmStatusDetail ?? "Preparing…",
            Foreground = new SolidColorBrush(Color.FromRgb(0x6B, 0x82, 0xA8)),
            FontSize = 11,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(20, 24, 20, 0),
            TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 600,
        };

        var stack = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        stack.Children.Add(profileName);
        stack.Children.Add(subtitle);
        stack.Children.Add(spinner);
        stack.Children.Add(statusText);
        ActiveContent.Content = stack;

        // Drive live updates of the status line until the VM is up.
        PropertyChangedEventHandler? handler = null;
        handler = (_, e) =>
        {
            if (e.PropertyName is nameof(SessionViewModel.VmStatusDetail))
            {
                Dispatcher.InvokeAsync(() => statusText.Text = sv.VmStatusDetail ?? "");
            }
            else if (e.PropertyName is nameof(SessionViewModel.IsRunning))
            {
                if (sv.IsRunning && sv.VmRuntimeId != Guid.Empty)
                {
                    Dispatcher.InvokeAsync(() =>
                    {
                        // Boot complete — detach the listener so we don't
                        // keep updating a stack panel that's been replaced.
                        if (handler is not null) sv.PropertyChanged -= handler;
                        AdoptVmAndOpenFirstTab(sv);
                    });
                }
                else if (!sv.IsRunning && sv.HasFailure)
                {
                    Dispatcher.InvokeAsync(() =>
                    {
                        // Boot failed — surface the error in place of
                        // the spinner so the user sees what went wrong.
                        subtitle.Text = "Boot failed";
                        spinner.Visibility = Visibility.Collapsed;
                        statusText.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x4D, 0x4F));
                        statusText.Text = sv.VmStatusDetail ?? "Unknown error";
                    });
                }
            }
        };
        sv.PropertyChanged += handler;
    }


    private void AdoptVmAndOpenFirstTab(SessionViewModel vm)
    {
        var firstAdoption = _vm is null;
        if (firstAdoption)
        {
            _vm = vm;
            _vnc = BuildVncControl(vm);
            ActiveContent.Content = _vnc;
            SubscribeAliveRoster(vm);
            // Audit 10 §4.1 — IP chip + shared-folders popover. Pull
            // initial values and subscribe to live changes (guest
            // pushes ip|<addr> every ~5s via title-pusher; folder set
            // is fixed for the lifetime of the session).
            RefreshIpChip(vm.VmGuestIpAddress);
            RefreshSharesButton(vm);
            RefreshStreamingDot(vm);
            vm.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(SessionViewModel.VmGuestIpAddress))
                {
                    Dispatcher.InvokeAsync(() => RefreshIpChip(vm.VmGuestIpAddress));
                }
            };
        }
        if (firstAdoption)
        {
            // Two roster paths:
            //   - WasResumedFromSavedState  → kittys are STILL RUNNING
            //     inside the resumed VM; rebuild pills WITHOUT spawn.
            //   - cold boot + tabs.json     → kittys are gone with the
            //     terminated VM; rebuild pills AND spawn fresh kittys
            //     using the persisted UUIDs (so the user gets her tab
            //     strip back exactly the way she left it).
            var rosterPath = Path.Combine(vm.SessionRoot, "tabs.json");
            var rebuilt = TryRebuildFromRoster(rosterPath, spawnKittys: !vm.WasResumedFromSavedState);
            if (rebuilt) return;
        }
        AppendTab();
    }

    private void SubscribeAliveRoster(SessionViewModel vm)
    {
        var vmId = vm.VmRuntimeId;
        if (vmId == Guid.Empty) return;
        GuestEventServer.Instance.EnsureStarted();
        GuestEventServer.Instance.SubscribeAlive(vmId, alive =>
        {
            // Dispatcher hop: _tabs / _missCounts are touched here
            // and from RemoveTab on the UI thread.
            System.Windows.Application.Current?.Dispatcher.InvokeAsync(() =>
            {
                ReconcileAliveRoster(alive);
            });
        });
    }

    private void ReconcileAliveRoster(IReadOnlySet<Guid> alive)
    {
        // Snapshot _tabs to a list — RemoveTabSilently mutates _tabs.
        var snapshot = _tabs.ToArray();
        var now = DateTime.UtcNow;
        foreach (var tab in snapshot)
        {
            if (alive.Contains(tab.TabUuid))
            {
                _missCounts.Remove(tab.TabUuid);
                continue;
            }
            // Grace window for newly-spawned tabs that the guest
            // hasn't picked up yet (kitty takes a beat to register
            // its window class). Without this, every fresh
            // AppendTab() would race a sweep and risk being reaped.
            if ((now - tab.CreatedAtUtc).TotalSeconds < 5.0) continue;

            _missCounts.TryGetValue(tab.TabUuid, out var miss);
            miss++;
            if (miss >= MissThreshold)
            {
                _missCounts.Remove(tab.TabUuid);
                RemoveTabSilently(tab);
            }
            else
            {
                _missCounts[tab.TabUuid] = miss;
            }
        }
    }

    private bool TryRebuildFromRoster(string rosterPath, bool spawnKittys)
    {
        if (_vm is null) return false;
        if (!File.Exists(rosterPath)) return false;
        try
        {
            var roster = JsonSerializer.Deserialize<TabRoster>(File.ReadAllText(rosterPath));
            if (roster?.Tabs is null || roster.Tabs.Count == 0) return false;
            foreach (var entry in roster.Tabs)
            {
                if (!Guid.TryParseExact(entry.Uuid, "N", out var uuid)) continue;
                AppendTab(resumeUuid: uuid, initialLabel: entry.Label, spawnKitty: spawnKittys);
            }
            if (_tabs.Count > 0) SetActiveTab(_tabs[0]);
            return _tabs.Count > 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Append a UUID-tagged tab to the strip. By default the
    /// kitty process is spawned in the VM via cmd-server; pass
    /// <paramref name="spawnKitty"/>=false when the kitty already
    /// exists (true hibernate-resume case) and just the pill is being
    /// rebuilt.
    /// </summary>
    public void AppendTab(Guid? resumeUuid = null, string? initialLabel = null, bool spawnKitty = true)
    {
        if (_vm is null) return;
        var tab = new SessionTab(this, _vm,
            accent: ProfileAccent(_vm.ProfileColor),
            existingUuid: resumeUuid,
            initialLabel: initialLabel);
        _tabs.Add(tab);
        TabStrip.Children.Add(tab.HeaderElement);
        SetActiveTab(tab);
        if (spawnKitty)
        {
            _ = tab.SpawnKittyAsync();
        }
    }

    internal void SetActiveTab(SessionTab tab)
    {
        if (ReferenceEquals(_active, tab)) return;
        _active = tab;
        foreach (var t in _tabs) t.SetActive(ReferenceEquals(t, tab));
        // Raise the corresponding kitty in the guest so the VNC stream
        // shows it.
        _ = tab.RaiseKittyAsync();
    }

    internal void RemoveTab(SessionTab tab) => RemoveTabCore(tab, sendCloseToGuest: true);

    /// <summary>Tab disappeared in the guest (closed-uuid signal or
    /// alive-roster reconciliation) — drop the pill but don't try to
    /// close the kitty; it's already gone. Closing a dead window via
    /// xdotool just adds noise to the guest log.</summary>
    internal void RemoveTabSilently(SessionTab tab) => RemoveTabCore(tab, sendCloseToGuest: false);

    private void RemoveTabCore(SessionTab tab, bool sendCloseToGuest)
    {
        var idx = _tabs.IndexOf(tab);
        if (idx < 0) return;
        _tabs.RemoveAt(idx);
        TabStrip.Children.Remove(tab.HeaderElement);
        tab.DisposeSubscription();
        if (sendCloseToGuest)
        {
            _ = tab.CloseKittyAsync();
        }
        if (ReferenceEquals(_active, tab))
        {
            _active = null;
            if (_tabs.Count > 0)
            {
                SetActiveTab(_tabs[System.Math.Min(idx, _tabs.Count - 1)]);
            }
        }
        if (_tabs.Count == 0)
        {
            // Last tab closed — flag the cascade so OnClosing routes
            // to a hard terminate (not a hibernate-save).
            _lastTabCascade = true;
            Close();
        }
    }

    private void CloseActiveTab()
    {
        if (_active is not null) RemoveTab(_active);
    }

    private void NewTabFromActive() => AppendTab();

    private void OnNewTabClick(object sender, RoutedEventArgs e) => AppendTab();
    private void OnMinClick(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void OnMaxClick(object sender, RoutedEventArgs e)
        => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    private void UpdateMaxGlyph()
    {
        // Segoe MDL2:  = ChromeMaximize,  = ChromeRestore
        MaxButton.Content = WindowState == WindowState.Maximized ? "" : "";
        MaxButton.ToolTip = WindowState == WindowState.Maximized ? "Restore" : "Maximize";
    }

    private VncControl BuildVncControl(SessionViewModel vm)
    {
        string? host = null;
        int port = 0;
        if (!string.IsNullOrEmpty(vm.VmGuestIpAddress))
        {
            host = vm.VmGuestIpAddress;
            port = 5900;
        }
        else if (vm.VmRdpTcpBridgePort > 0)
        {
            host = "127.0.0.1";
            port = vm.VmRdpTcpBridgePort;
        }
        if (host is null)
        {
            // Surface the failure inline — content will render as a
            // text label, not a VncControl. The owning Border keeps
            // the rest of the chrome alive.
            var msg = new TextBlock
            {
                Text = "VM is running but no display transport is available.",
                Foreground = Brushes.LightGray,
                Margin = new Thickness(20),
                TextWrapping = TextWrapping.Wrap,
            };
            ActiveContent.Content = msg;
            return new VncControl("0.0.0.0", 0);   // placeholder so _vnc isn't null
        }
        var v = new VncControl(host, port);
        v.Focus();
        _ = v.ConnectAsync();
        return v;
    }

    private static SolidColorBrush ProfileAccent(ProfileColor c) => c switch
    {
        ProfileColor.Red    => new(Color.FromRgb(0xFF, 0x4D, 0x4F)),
        ProfileColor.Orange => new(Color.FromRgb(0xFF, 0x9C, 0x33)),
        ProfileColor.Green  => new(Color.FromRgb(0x4C, 0xC9, 0x90)),
        ProfileColor.Teal   => new(Color.FromRgb(0x33, 0xB0, 0xB8)),
        ProfileColor.Blue   => new(Color.FromRgb(0x4C, 0x8B, 0xF5)),
        ProfileColor.Purple => new(Color.FromRgb(0xA8, 0x6E, 0xE0)),
        ProfileColor.Pink   => new(Color.FromRgb(0xE0, 0x6E, 0xA8)),
        ProfileColor.Gray   => new(Color.FromRgb(0x88, 0x88, 0x99)),
        _                   => new(Color.FromRgb(0x4C, 0x8B, 0xF5)),
    };

    private sealed class RelayCommand : ICommand
    {
        private readonly System.Action<object?> _exec;
        public RelayCommand(System.Action<object?> exec) { _exec = exec; }
        public bool CanExecute(object? p) => true;
        public void Execute(object? p) => _exec(p);
        public event System.EventHandler? CanExecuteChanged { add { } remove { } }
    }
}

/// <summary>One tab = one kitty process inside the shared VM. Carries
/// only display-state (header element, accent); the actual terminal
/// content is the shared <see cref="VncControl"/> on the owning
/// window. Spawn / raise / close go to the in-VM cmd-server.</summary>
internal sealed class SessionTab
{
    public Guid TabUuid { get; }

    /// <summary>Monotonic UTC timestamp the pill was created on the
    /// host. Used by the alive-roster reconciler to grant a grace
    /// window before reaping a tab that hasn't been seen yet —
    /// otherwise a freshly-spawned kitty would get reaped between
    /// its registration here and its first appearance in the
    /// guest's title-pusher sweep.</summary>
    public DateTime CreatedAtUtc { get; } = DateTime.UtcNow;

    /// <summary>Current pill label — snapshot value the window grabs
    /// when serialising the tab roster for hibernate. Updated every
    /// time the title-pusher pushes a new title for this UUID.</summary>
    public string CurrentLabel { get; private set; }

    private readonly SessionWindow _window;
    private readonly SessionViewModel _vm;
    private readonly Border _headerBorder;
    private readonly Border _activeUnderline;
    private readonly TextBlock _label;
    // Host-side kitty watcher — image-independent backstop for the
    // alive-roster/closed-uuid signal in title-pusher.c. macOS-style
    // "exit kills the shell, host shuts the VM down" depends on the
    // host noticing the kitty process is gone. We poll the in-VM
    // process table via the cmd-server (always present in every base
    // image) so this works even on un-rebaked machines.
    private CancellationTokenSource? _kittyWatchCts;

    public UIElement HeaderElement => _headerBorder;

    private static readonly SolidColorBrush ActiveBg =
        new(Color.FromRgb(0x1B, 0x1F, 0x2A));
    private static readonly SolidColorBrush InactiveBg =
        new(Color.FromRgb(0x0D, 0x11, 0x17));
    private static readonly SolidColorBrush HoverBg =
        new(Color.FromRgb(0x15, 0x1A, 0x22));

    public SessionTab(SessionWindow window, SessionViewModel vm, SolidColorBrush accent,
        Guid? existingUuid = null, string? initialLabel = null)
    {
        _window = window;
        _vm = vm;
        TabUuid = existingUuid ?? Guid.NewGuid();
        CurrentLabel = string.IsNullOrEmpty(initialLabel) ? vm.ProfileName : initialLabel;

        // Per-tab title subscription — the guest's bromure-title-pusher
        // emits one `tab|<UUID>|<TITLE>` line per running kitty every
        // 1.5 s, and SubscribeTab routes each line to the matching
        // pill so every tab's label reflects its OWN foreground
        // process (vim, claude, bash…), matching macOS.
        var vmId = vm.VmRuntimeId;
        if (vmId != Guid.Empty)
        {
            GuestEventServer.Instance.SubscribeTab(vmId, TabUuid, raw =>
            {
                var t = raw?.Trim();
                var label = string.IsNullOrEmpty(t) ? _vm.ProfileName : t;
                CurrentLabel = label;
                System.Windows.Application.Current?.Dispatcher.InvokeAsync(() =>
                {
                    SetLabel(label);
                });
            });
            // Audit 10 §2.8: closed-uuid signal — when the guest
            // reports the kitty has exited (Ctrl-D in the shell, etc.)
            // tear down the pill from the strip so the user doesn't
            // have to click the × on a dead tab.
            GuestEventServer.Instance.SubscribeTabClosed(vmId, TabUuid, () =>
            {
                System.Windows.Application.Current?.Dispatcher.InvokeAsync(() =>
                {
                    _window.RemoveTabSilently(this);
                });
            });
            // UX #5: image-independent kitty death detector. Runs in
            // parallel with the guest-pushed closed-uuid signal; the
            // first one to fire wins (RemoveTabCore dedupes via
            // _tabs.IndexOf check). Kicked here so the resume path
            // (which skips SpawnKittyAsync) also gets it.
            StartKittyWatch(vmId);
        }

        var dot = new System.Windows.Shapes.Ellipse
        {
            Width = 8, Height = 8,
            Fill = accent,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
        };
        _label = new TextBlock
        {
            Text = CurrentLabel,
            Foreground = Brushes.White,
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 13,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 200,
        };
        var close = new Button
        {
            Content = "✕",
            Width = 18, Height = 18,
            Padding = new Thickness(0),
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Foreground = new SolidColorBrush(Color.FromRgb(0x9F, 0xB6, 0xD8)),
            FontSize = 11,
            Cursor = Cursors.Hand,
            Margin = new Thickness(10, 0, 0, 0),
            ToolTip = "Close tab (Ctrl+W)",
            VerticalAlignment = VerticalAlignment.Center,
        };
        close.Click += (_, e) => { e.Handled = true; _window.RemoveTab(this); };

        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(dot);
        panel.Children.Add(_label);
        panel.Children.Add(close);

        _activeUnderline = new Border
        {
            Background = accent,
            Height = 2,
            VerticalAlignment = VerticalAlignment.Bottom,
        };

        var inner = new Grid();
        inner.Children.Add(panel);
        inner.Children.Add(_activeUnderline);

        _headerBorder = new Border
        {
            Background = InactiveBg,
            Padding = new Thickness(14, 8, 6, 8),
            Margin = new Thickness(0, 0, 2, 0),
            CornerRadius = new CornerRadius(6, 6, 0, 0),
            Cursor = Cursors.Hand,
            Child = inner,
        };
        _headerBorder.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            _window.SetActiveTab(this);
        };
        _headerBorder.MouseEnter += (_, _) =>
        {
            if (!IsActive) _headerBorder.Background = HoverBg;
        };
        _headerBorder.MouseLeave += (_, _) =>
        {
            if (!IsActive) _headerBorder.Background = InactiveBg;
        };

        SetActive(false);
    }

    private bool IsActive { get; set; }

    public void SetActive(bool active)
    {
        IsActive = active;
        _headerBorder.Background = active ? ActiveBg : InactiveBg;
        _activeUnderline.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
    }

    public void SetLabel(string label) => _label.Text = label;

    // -- guest control -----------------------------------------------------

    public Task SpawnKittyAsync()
    {
        var vmId = _vm.VmRuntimeId;
        if (vmId == Guid.Empty) return Task.CompletedTask;
        // Match macOS tab-agent.sh: kitty --start-as=fullscreen
        // --class bromure-<UUID>. The --class lets xdotool target it
        // for raise / close. --directory $HOME so the shell starts
        // in ~/ (otherwise systemd-launched kitty inherits cwd=/
        // and the prompt reads `/$` instead of `~$`).
        var cmd =
            $"DISPLAY=:1 HOME=/home/ubuntu nohup kitty --start-as=fullscreen " +
            $"--class bromure-{TabUuid:N} --directory /home/ubuntu " +
            $">/tmp/kitty-{TabUuid:N}.log 2>&1 &";
        return GuestCommand.SendAsync(vmId, cmd);
    }

    /// <summary>UX #5 — `exit` in the shell kills kitty; the host
    /// must notice and reap the tab so the cascade-close path can
    /// terminate the VM (the user is done with this session).
    ///
    /// <para>Polls the in-VM process table via bromure-cmd-server.
    /// Two consecutive zero-counts after the 5-second creation grace
    /// ⇒ reap. The grace window covers (a) kitty taking ~1 s to spawn
    /// before pgrep sees it, and (b) a short crash-loop oscillation
    /// that shouldn't take the tab down on the first miss.</para>
    ///
    /// <para>This is image-independent (cmd-server ships in every
    /// base image). The alive-roster signal from title-pusher.c
    /// (added in #56) provides the same coverage on freshly-baked
    /// images but isn't required.</para></summary>
    private static readonly string KittyWatchLog = System.IO.Path.Combine(
        System.IO.Path.GetTempPath(), "bromure-kitty-watch.log");

    private static void WatchLog(string msg)
    {
        try { System.IO.File.AppendAllText(KittyWatchLog, $"[{DateTime.Now:HH:mm:ss.fff}] {msg}\n"); } catch { }
    }

    private void StartKittyWatch(Guid vmId)
    {
        // Cancel any prior watcher — defensive; the tab is fresh, but
        // SpawnKittyAsync could be called twice on a restart path.
        try { _kittyWatchCts?.Cancel(); } catch { }
        _kittyWatchCts = new CancellationTokenSource();
        var ct = _kittyWatchCts.Token;
        WatchLog($"tab={TabUuid:N} vm={vmId:D} watch start");
        _ = Task.Run(async () =>
        {
            var createdAt = DateTime.UtcNow;
            int consecutiveZeros = 0;
            while (!ct.IsCancellationRequested)
            {
                try { await Task.Delay(TimeSpan.FromSeconds(2), ct).ConfigureAwait(false); }
                catch (TaskCanceledException) { return; }

                // 5-second creation grace — kitty needs a beat to
                // register its window class before pgrep finds it.
                if ((DateTime.UtcNow - createdAt).TotalSeconds < 5.0) continue;

                string output;
                try
                {
                    // Anchor the regex with `^kitty ` so it matches the
                    // real kitty process but NOT the `/bin/sh -c <pattern>`
                    // wrapper running this pgrep (the wrapper contains the
                    // pattern as a literal substring but its cmdline starts
                    // with `/bin/sh`, not `kitty`). The `.*` is required
                    // because kitty's actual argv is
                    // `kitty --start-as=fullscreen --class bromure-<UUID> …`
                    // — `--start-as=fullscreen` sits between `kitty` and
                    // `--class`, so a literal-anchored `^kitty --class`
                    // never matches. Trailing `; true` keeps cmd-server
                    // happy with a zero exit code (pgrep returns 1 on
                    // no-match even though stdout still has "0").
                    output = await GuestCommand.RunAndCollectAsync(vmId,
                        $"pgrep -fc '^kitty .*--class bromure-{TabUuid:N}' ; true", ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException) { return; }
                catch { continue; } // transient cmd-server hiccup; try again next tick

                if (!int.TryParse(output.Trim(), out var count)) continue;

                if (count > 0)
                {
                    consecutiveZeros = 0;
                    continue;
                }

                consecutiveZeros++;
                if (consecutiveZeros >= 2)
                {
                    WatchLog($"tab={TabUuid:N} kitty gone, reaping");
                    System.Windows.Application.Current?.Dispatcher.InvokeAsync(() =>
                    {
                        _window.RemoveTabSilently(this);
                    });
                    return;
                }
            }
        }, ct);
    }

    public Task RaiseKittyAsync()
    {
        var vmId = _vm.VmRuntimeId;
        if (vmId == Guid.Empty) return Task.CompletedTask;
        var cmd =
            $"DISPLAY=:1 xdotool search --class bromure-{TabUuid:N} 2>/dev/null | " +
            $"head -1 | xargs -r xdotool windowactivate";
        return GuestCommand.SendAsync(vmId, cmd);
    }

    public Task CloseKittyAsync()
    {
        var vmId = _vm.VmRuntimeId;
        if (vmId == Guid.Empty) return Task.CompletedTask;
        var cmd =
            $"DISPLAY=:1 xdotool search --class bromure-{TabUuid:N} 2>/dev/null | " +
            $"head -1 | xargs -r xdotool windowclose; " +
            $"pkill -f 'bromure-{TabUuid:N}' 2>/dev/null || true";
        return GuestCommand.SendAsync(vmId, cmd);
    }

    public void DisposeSubscription()
    {
        try { _kittyWatchCts?.Cancel(); } catch { }
        var vmId = _vm.VmRuntimeId;
        if (vmId == Guid.Empty) return;
        try { GuestEventServer.Instance.SubscribeTab(vmId, TabUuid, null); } catch { }
        try { GuestEventServer.Instance.SubscribeTabClosed(vmId, TabUuid, null); } catch { }
    }
}

/// <summary>Persisted tab strip — written to
/// <c>&lt;sessionRoot&gt;/tabs.json</c> when the window is closed
/// with tabs open, read back on the next launch to rebuild the pills
/// against the resumed VM's already-running kittys.</summary>
internal sealed class TabRoster
{
    public List<TabRosterEntry> Tabs { get; set; } = new();
}

internal sealed class TabRosterEntry
{
    public string Uuid  { get; set; } = "";
    public string Label { get; set; } = "";
}
