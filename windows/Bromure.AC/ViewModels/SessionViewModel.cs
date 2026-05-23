using System.IO;
using System.Net;
using System.Windows.Media;
using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Engine;
using Bromure.AC.Mitm.Proxy;
using Bromure.SandboxEngine.Hcs;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

/// <summary>
/// One running session = one HCS-managed Linux VM rendered into the
/// WPF shell over RDP. BromureAC connects mstsc to the per-session
/// weston-rdp on hvsocket; the user sees kitty inside the BromureAC
/// window, just like the macOS port shows the VZ framebuffer.
///
/// <para>This shape mirrors the macOS port: <c>ACAppDelegate</c>
/// shows a profile picker; clicking a profile opens a
/// <c>TabbedSessionWindow</c> backed by a per-tab disposable VM.</para>
/// </summary>
public sealed partial class SessionViewModel : ObservableObject, IAsyncDisposable
{
    private readonly MitmEngine _engine;
    private readonly Profile? _activeProfile;
    private readonly BakeArtefacts _artefacts;
    private readonly string _sessionRoot;
    private readonly WarmVm? _warmVm;
    private HttpMitmProxy? _mitm;
    private HcsSession? _session;
    private Bromure.AC.Core.Outbox.SessionOutboxWatcher? _outbox;

    [ObservableProperty] private string _profileName = "Default Profile";
    [ObservableProperty] private string _vmStatus = "Idle";
    [ObservableProperty] private string _vmStatusDetail = "";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusBrush))]
    private bool _isRunning;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private bool _hasFailure;
    [ObservableProperty] private string _failureDetail = "";
    [ObservableProperty] private string? _stderrLogPath;
    /// <summary>VM's runtime GUID — what mstsc / vmconnect dial.
    /// Different from <see cref="ProfileId"/> (that's our identity
    /// for the compute system). Populated after StartAsync.</summary>
    [ObservableProperty] private Guid _vmRuntimeId;
    /// <summary>Hvsocket port the in-guest weston-rdp (via
    /// bromure-hvsock-proxy) listens on.</summary>
    [ObservableProperty] private uint _vmRdpPort;
    /// <summary>Loopback TCP port on which the host-side hvsocket
    /// bridge listens; mstsc dials <c>127.0.0.1:&lt;this&gt;</c>.</summary>
    [ObservableProperty] private int _vmRdpTcpBridgePort;
    /// <summary>Guest IP on the host's Default-Switch NAT subnet. Set
    /// when HCS attached a NetworkAdapter to the VM (default in the
    /// production session path). The VNC client prefers this over the
    /// hvsocket bridge because host→guest hvsocket SEND hangs on this
    /// Windows build.</summary>
    [ObservableProperty] private string? _vmGuestIpAddress;

    /// <summary>Legacy whole-window title from the guest. Per-tab
    /// labels are now driven directly by
    /// <see cref="Bromure.AC.Display.GuestEventServer.SubscribeTab"/>
    /// (see SessionWindow.SessionTab). This property still holds the
    /// startup "starting" sentinel + any future single-line pushes,
    /// but nothing in the UI binds to it today.</summary>
    [ObservableProperty] private string _processTitle = "";


    public string? PreflightError
    {
        get => _preflightError;
        set
        {
            SetProperty(ref _preflightError, value);
            if (!string.IsNullOrEmpty(value))
            {
                FailureDetail = value;
                VmStatusDetail = "Pre-flight check failed.";
                HasFailure = true;
            }
        }
    }
    private string? _preflightError;

    public Guid ProfileId { get; }

    /// <summary>Per-profile staging dir (profiles/&lt;id&gt;/session). Holds
    /// the persistent VHDX, the overlay/cert 9p trees, and — when the
    /// user hibernates the window with tabs open — the saved-state
    /// file + tabs roster. SessionWindow uses this to write/read
    /// saved-state.bin and tabs.json.</summary>
    public string SessionRoot => _sessionRoot;

    /// <summary>True when <see cref="StartAsync"/> found a valid
    /// saved-state file in <see cref="SessionRoot"/> and the VM
    /// resumed from it instead of cold-booting. SessionWindow checks
    /// this to know whether to rebuild the tab strip from
    /// tabs.json (resume) or spawn a fresh first tab (cold).</summary>
    public bool WasResumedFromSavedState { get; private set; }

    /// <summary>Profile color from the active profile, or Blue if
    /// the session was constructed without one (preflight error
    /// stubs, etc.). Used by the tabbed SessionWindow to tint each
    /// tab — same per-profile colour identification macOS shows in
    /// its window-tab accents.</summary>
    /// <summary>Profile-configured behavior when the session window's
    /// close button is clicked. SessionWindow.OnClosing reads this to
    /// branch between Suspend (write saved-state, restore on next
    /// launch), Shutdown (cleanly terminate the VM, drop saved state),
    /// and Ask (3-button prompt). Audit 09 §A1 + audit 10 §4.1.</summary>
    public Bromure.AC.Core.Model.CloseAction CloseAction
        => _activeProfile?.CloseAction ?? Bromure.AC.Core.Model.CloseAction.Ask;

    public Bromure.AC.Core.Model.ProfileColor ProfileColor =>
        _activeProfile?.Color ?? Bromure.AC.Core.Model.ProfileColor.Blue;

    public Brush StatusBrush => IsRunning
        ? (Brush)new SolidColorBrush(Color.FromRgb(0x4C, 0xC9, 0x90))
        : (Brush)new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x99));

    public SessionViewModel(Guid profileId, string profileName,
        MitmEngine engine, Profile? activeProfile,
        BakeArtefacts artefacts, string sessionRoot,
        WarmVm? warmVm = null)
    {
        ProfileId = profileId;
        ProfileName = profileName;
        _engine = engine;
        _activeProfile = activeProfile;
        _artefacts = artefacts;
        _sessionRoot = sessionRoot;
        _warmVm = warmVm;
    }

    /// <summary>
    /// Boot session = bring up the per-profile MITM proxy + create a
    /// fresh per-session VHDX clone + boot an HCS VM with weston-rdp
    /// listening on hvsocket. The host attaches an RDP control to
    /// render kitty inside the BromureAC window.
    /// </summary>
    [RelayCommand]
    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_session is not null) return;
        IsBusy = true;
        VmStatus = "Booting…";
        VmStatusDetail = "Bringing up MITM proxy…";

        // Per-session boot log — written to %TEMP%\bromure-ac-boot.log
        // so we can diagnose hangs without attaching a debugger. Each
        // line includes elapsed-ms-since-StartAsync-entry so phases
        // are easy to spot. We truncate at start so the log shows ONLY
        // the most-recent launch — easier to find what's hanging.
        var bootLogPath = Path.Combine(Path.GetTempPath(), "bromure-ac-boot.log");
        try { System.IO.File.WriteAllText(bootLogPath, ""); } catch { }
        var bootSw = System.Diagnostics.Stopwatch.StartNew();
        void BootLog(string msg)
        {
            try
            {
                System.IO.File.AppendAllText(bootLogPath,
                    $"[{DateTime.Now:HH:mm:ss.fff}] [+{bootSw.ElapsedMilliseconds}ms] {msg}\n");
            }
            catch { }
        }
        BootLog($"=== launch profile={ProfileName} ({ProfileId:D}) ===");

        try
        {
            BootLog("MitmEngine.RegisterAsync…");
            _mitm = await _engine.RegisterAsync(ProfileId,
                new IPEndPoint(IPAddress.Loopback, 0), ct).ConfigureAwait(true);
            var proxyPort = _mitm.LocalEndpoint!.Port;
            BootLog($"MitmEngine ready (proxy port {proxyPort})");

            // Apply the per-profile bindings (AWS creds + SSO refresh,
            // SSH agent keys). Kubeconfig identities + cluster CAs are
            // registered below right after we materialise them.
            try
            {
                await _engine.ApplyProfileBindingsAsync(_activeProfile, ct).ConfigureAwait(true);
                BootLog("MitmEngine bindings applied");
            }
            catch (Exception bindEx)
            {
                BootLog("MitmEngine bindings FAILED (fail-open): " + bindEx.Message);
            }
            // The per-profile VHDX persists across launches; first
            // launch clones the base, subsequent launches just open
            // the existing child. Pick the right copy in the status
            // line so the user knows whether they're paying the clone
            // cost or just the boot.
            var profileDiskPath = Path.Combine(_sessionRoot, "disk.vhdx");
            var isFreshClone = !File.Exists(profileDiskPath) ||
                File.GetLastWriteTimeUtc(_artefacts.BaseVhdxPath)
                    > File.GetLastWriteTimeUtc(profileDiskPath);
            VmStatusDetail = isFreshClone
                ? $"Cloning VHDX + booting VM… (proxy 127.0.0.1:{proxyPort})"
                : $"Booting VM (reusing profile disk)… (proxy 127.0.0.1:{proxyPort})";

            var vmId = "bromure-ses-" + Guid.NewGuid().ToString("N")[..8];
            // _sessionRoot is per-PROFILE now (profiles/<id>/session).
            // The disk.vhdx inside survives across launches; first
            // launch creates it as a CoW child of the base, subsequent
            // launches reuse — VhdxDisk.CreateChildSync is idempotent.
            var installPath = _sessionRoot;
            Directory.CreateDirectory(installPath);

            var envVars = _activeProfile is not null
                ? new Dictionary<string, string>(ProfileEnvExports.ForProfile(_activeProfile), StringComparer.Ordinal)
                : new Dictionary<string, string>(StringComparer.Ordinal);
            envVars["HTTP_PROXY"] = $"http://127.0.0.1:{proxyPort}";
            envVars["HTTPS_PROXY"] = $"http://127.0.0.1:{proxyPort}";
            envVars["http_proxy"] = $"http://127.0.0.1:{proxyPort}";
            envVars["https_proxy"] = $"http://127.0.0.1:{proxyPort}";
            envVars["SSL_CERT_FILE"] = "/etc/ssl/certs/ca-certificates.crt";
            envVars["NODE_EXTRA_CA_CERTS"] = "/usr/local/share/ca-certificates/bromure/bromure-ca.crt";

            // MCP servers — mint a per-session bearer fake for each
            // enabled HTTP server, register the fake→real entries with
            // the proxy's swap map, and project the fakes for the
            // config-file builder. The fake never sees the real bearer;
            // the MITM swaps it on the wire. Direct port of macOS
            // SessionDisk's MCP path. STDIO MCP servers have no wire
            // surface so no fakes are needed for them.
            Dictionary<string, (string EnvVar, string Fake)>? mcpFakes = null;
            if (_activeProfile is not null && _activeProfile.McpServers.Count > 0)
            {
                var mcpPlan = Bromure.AC.Mitm.Swap.McpFakeMint.Build(
                    _activeProfile.McpServers, _engine.FakeTokenSalt);
                if (mcpPlan.Entries.Count > 0)
                {
                    _engine.Swapper.AppendEntries(mcpPlan.Entries, ProfileId);
                }
                if (mcpPlan.Fakes.Count > 0)
                {
                    mcpFakes = Bromure.AC.Mitm.Swap.McpFakeMint.ToConfigFakes(mcpPlan);
                }
            }

            // DigitalOcean fake-mint. Audit 03 #2: the home overlay
            // used to receive the real PAT. We mint a same-shape
            // fake here, register fake↔real (plus the base64-pair
            // for `doctl registry login`) into the swap map, and
            // pass the fake to SessionHomeBuilder so .config/doctl/
            // never holds the real token.
            string? doFake = null;
            if (_activeProfile is not null
                && !string.IsNullOrWhiteSpace(_activeProfile.DigitalOceanToken))
            {
                doFake = Bromure.AC.Mitm.Swap.DigitalOceanFakeMint.MintFake(
                    _activeProfile.DigitalOceanToken!, _engine.FakeTokenSalt);
                if (doFake is not null)
                {
                    var doEntries = Bromure.AC.Mitm.Swap.DigitalOceanFakeMint.BuildSwapEntries(
                        realPat: _activeProfile.DigitalOceanToken!,
                        fakePat: doFake,
                        consentCredentialId: _activeProfile.DigitalOceanRequiresApproval
                            ? $"do/{ProfileId:D}"
                            : null);
                    _engine.Swapper.AppendEntries(doEntries, ProfileId);
                }
            }

            // Build the home overlay. SessionHomeBuilder produces every
            // dotfile that doesn't need PKI plumbing; we add the
            // kubeconfig (which needs the Bromure CA so kubectl trusts
            // the proxy's MITM leaves) on top.
            var caPem = _engine.Ca.CertificatePem;
            var homeFiles = new Dictionary<string, byte[]>(
                SessionHomeBuilder.Build(_activeProfile, caPem, mcpFakes, doFake),
                StringComparer.Ordinal);
            if (_activeProfile is not null && _activeProfile.Kubeconfigs.Count > 0)
            {
                try
                {
                    var matz = new Bromure.AC.Mitm.Pki.KubeconfigMaterializer()
                        .Materialize(_activeProfile, caPem);
                    if (!string.IsNullOrEmpty(matz.Yaml))
                    {
                        homeFiles[".kube/config"] = System.Text.Encoding.UTF8.GetBytes(
                            matz.Yaml.Replace("\r\n", "\n"));
                    }
                    // Hand the materialised client identities + cluster
                    // CAs to the engine so the proxy can present mTLS on
                    // kubectl traffic (e.g. EKS API server requiring a
                    // client cert, on-prem clusters with a private CA).
                    foreach (var ident in matz.ClientIdentities)
                    {
                        _engine.ClientIdentities.SetIdentity(
                            ident.Identity, ident.Host, ProfileId,
                            consentCredentialId: ident.ConsentCredentialId,
                            consentDisplayName: ident.ConsentDisplayName);
                    }
                    foreach (var (host, caPemHost) in matz.ClusterCas)
                    {
                        _engine.ClusterCaTrust.SetCa(caPemHost, host, ProfileId);
                    }
                    // Bearer-token swaps for the kubeconfig auth-token
                    // entries — materialiser produces fake↔real pairs;
                    // the proxy's swap path picks these up automatically.
                    if (matz.BearerSwaps.Count > 0)
                    {
                        var swapEntries = new List<Bromure.AC.Mitm.Swap.TokenMap.Entry>();
                        foreach (var bs in matz.BearerSwaps)
                        {
                            swapEntries.Add(new Bromure.AC.Mitm.Swap.TokenMap.Entry(
                                Fake: bs.FakeToken, Real: bs.RealToken,
                                Host: bs.Host, Header: Bromure.AC.Mitm.Swap.EntryHeader.Authorization));
                        }
                        _engine.Swapper.AppendEntries(swapEntries, ProfileId);
                    }
                    // Exec-plugin contexts (EKS / GKE / AKS default
                    // auth). Arm the poller so it shells out to e.g.
                    // `aws eks get-token` every RefreshSeconds and
                    // refreshes the fake↔real entry in the swap map.
                    if (matz.ExecContexts.Count > 0)
                    {
                        _engine.ExecPoller.Start(matz.ExecContexts, ProfileId, _engine.Swapper);
                    }
                    BootLog($"kubeconfig: registered {matz.ClientIdentities.Count} identities, {matz.ClusterCas.Count} cluster CAs, {matz.BearerSwaps.Count} bearer swaps, {matz.ExecContexts.Count} exec contexts");
                }
                catch (Exception kex)
                {
                    System.Diagnostics.Debug.WriteLine("kubeconfig materialise failed: " + kex);
                    BootLog("kubeconfig materialise FAILED: " + kex.Message);
                }
            }

            // Resume from saved state when a previous run hibernated.
            // HcsSession invalidates a stale save (parent VHDX newer
            // than the save file) on its own — we just pass the path
            // here unconditionally and let it decide.
            var savedStatePath = Path.Combine(_sessionRoot, "saved-state.bin");
            var hasSavedState = File.Exists(savedStatePath);
            if (hasSavedState)
            {
                VmStatusDetail = $"Resuming suspended VM… (proxy 127.0.0.1:{proxyPort})";
            }

            // Stable per-profile MAC. macOS's MACBindings (Profile.swift
            // :1565-1638) persists a generated MAC per profile.id so
            // DHCP leases survive across launches — container networks,
            // port-forward rules, host-side firewall allow-lists all
            // depend on the lease staying put. Without this every
            // session VM got a fresh random MAC and a fresh lease.
            var stableMac = _engine.MacBindings.GetOrCreate(ProfileId);
            BootLog($"Stable MAC for profile: {stableMac}");

            // Bridged-mode profiles bind to a user-named external
            // Hyper-V switch (typed into the profile editor's "Bridged
            // interface ID" field). NAT uses Default Switch — that's
            // HcsSessionConfig's built-in default, so we only override
            // when the profile asks for it. Empty/missing interface ID
            // falls back to NAT silently rather than refusing to boot.
            string? networkSwitch = null;
            if (_activeProfile is { NetworkMode: Bromure.AC.Core.Model.NetworkMode.Bridged } bp
                && !string.IsNullOrWhiteSpace(bp.BridgedInterfaceID))
            {
                networkSwitch = bp.BridgedInterfaceID;
            }

            // Profile-driven RAM. macOS-parity: 0 = "engine picks a
            // sensible default that scales to host"; positive = user
            // override. Clamp to [2, 64] GiB so a typo in the editor
            // can't request a 1 TiB guest (HCS would surface a vague
            // E_OUTOFMEMORY from vmcompute at start time, painful to
            // diagnose).
            int memoryGb = _activeProfile?.MemoryGB ?? 0;
            if (memoryGb <= 0) memoryGb = Bromure.SandboxEngine.Hcs.HostMemoryProbe.DefaultGuestMemoryGB();
            else if (memoryGb < 2) memoryGb = 2;
            else if (memoryGb > 64) memoryGb = 64;

            var cfg = new HcsSessionConfig
            {
                BaseVhdxPath = _artefacts.BaseVhdxPath,
                KernelPath = _artefacts.KernelPath,
                InitrdPath = _artefacts.InitrdPath,
                VmId = vmId,
                InstallPath = installPath,
                SavedStateFilePath = hasSavedState ? savedStatePath : null,
                NetworkMacAddressOverride = stableMac,
                NetworkSwitchName = networkSwitch ?? "Default Switch",
                MemoryMB = (uint)memoryGb * 1024,
                // Bypass UEFI/GRUB and boot the kernel directly from
                // the artefacts dir. Same kernel + initrd content as
                // the UEFI path, just skips the firmware. UEFI boot
                // hangs on this build with no boot signal arriving;
                // LinuxKernelDirect is what the spike validated and
                // is the production path until we figure out UEFI.
                UseLinuxKernelDirect = true,
                KernelCmdLine =
                    "root=/dev/sda2 rw rootfstype=ext4 console=ttyS0,115200 earlyprintk=ttyS0,115200 "
                    + "loglevel=7 systemd.log_level=info systemd.log_target=console "
                    + "systemd.show_status=true systemd.journald.forward_to_console=1",
                HomeFiles = homeFiles,
                EnvVars = envVars,
                BromureCaPem = System.Text.Encoding.ASCII.GetBytes(_engine.Ca.CertificatePem),
                // Profile-configured shared folders → 9p mounts at
                // /home/bromure/<basename>. Same end-user shape as the
                // WSL port's drvfs symlinks; here the host directly
                // serves the share via vmcompute.dll's Plan9.
                SharedFolderPaths = _activeProfile?.FolderPaths.ToArray()
                    ?? Array.Empty<string>(),
                // Warm VM from the pool — the session adopts its
                // pre-created compute system instead of paying the
                // VHDX-clone + HCS-create cost. Null → cold create.
                WarmVm = _warmVm?.Vm,
            };
            // Perf #2: pre-build the home-overlay tar so we can
            // register it the instant RuntimeId is resolved (~150ms
            // in). The guest's overlay-fetch service dials at +2s,
            // so without this the host's late registration would
            // block the guest's boot 28s waiting for the tar.
            //
            // The producer lambda also doubles as the BOOT SIGNAL:
            // when the guest dials port 9225, the overlay listener
            // calls our producer; we set the TCS, which unblocks
            // HcsSession.StartAsync. This replaces the hvsocket
            // dial-poll (which paid a 20-30 s WSAConnect-timeout
            // cost on the first iteration before the in-VM proxy
            // was reachable).
            var bootReady = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            cfg = cfg with
            {
                BootSignalTask = bootReady.Task,
                OnRuntimeIdResolved = runtimeId =>
                {
                    try
                    {
                        var tar = Bromure.SandboxEngine.Image.SessionHomeArchive.Build(homeFiles);
                        Bromure.AC.Display.GuestEventServer.Instance.EnsureStarted();
                        Bromure.AC.Display.GuestEventServer.Instance.RegisterOverlay(runtimeId, () =>
                        {
                            // Producer called → guest dialed → guest is reachable.
                            bootReady.TrySetResult();
                            return tar;
                        });
                        BootLog($"overlay producer pre-registered for runtimeId={runtimeId:D}");
                    }
                    catch (Exception ovEx)
                    {
                        BootLog("overlay pre-register failed: " + ovEx.Message);
                    }
                },
            };

            BootLog($"HcsSession.StartAsync (vmId={vmId}, install={installPath}, resume={hasSavedState})");
            _session = new HcsSession(cfg);
            await _session.StartAsync(ct).ConfigureAwait(true);
            // The session deletes its own save-state file when it
            // determines the file is stale (parent VHDX newer). Trust
            // the post-start existence as the source of truth for
            // whether we actually resumed.
            WasResumedFromSavedState = hasSavedState && File.Exists(savedStatePath);
            BootLog($"HcsSession.StartAsync OK ({(WasResumedFromSavedState ? "resumed from saved state" : "cold boot")}); timings:\n{_session.LastTimings.TrimEnd()}");
            BootLog($"RuntimeId={_session.RuntimeId:D} RdpPort={_session.RdpPort} BridgePort={_session.RdpTcpBridgePort} GuestIp={_session.GuestIpAddress ?? "<none>"}");
            // RuntimeId / RdpPort surfaced to the view via the
            // accessors below — HcsSessionWindowHost dials
            // mstsc /v:hvsocket://<RuntimeId>:<RdpPort>.
            VmRuntimeId = _session.RuntimeId;
            VmRdpPort = _session.RdpPort;
            VmRdpTcpBridgePort = _session.RdpTcpBridgePort;
            VmGuestIpAddress = _session.GuestIpAddress;
            SubscribeToGuestTitle();
            // Audit 10 §2.9 — resume timekeeping fix. On hibernate
            // resume the guest's RTC has drifted by however long the
            // host was off / suspended; journal timestamps, TLS-cert
            // chain validation, and `kubectl` token-expiry math all
            // misbehave. macOS touches `.resume-signal` in the meta
            // share + a systemd path unit fires rdate. Our meta share
            // is a read-only ISO so the path-watcher can't trigger;
            // drive the same `rdate` over the bromure-cmd-server
            // hvsocket instead. Fire-and-forget — the sh process
            // backgrounds rdate itself so the cmd-server's wait()
            // doesn't block on the network round-trip.
            if (WasResumedFromSavedState)
            {
                _ = Bromure.AC.Display.GuestCommand.SendAsync(
                    VmRuntimeId,
                    "(rdate -n -s pool.ntp.org &) >/dev/null 2>&1",
                    ct);
            }
            // Audit 10 §3.7 — key-repeat per profile. The guest's X
            // session uses xset default rates (250 ms delay / 30 Hz);
            // a user who's tuned their host's keyboard to 200/40 wants
            // the same in the VM. Fire xset over the cmd-server once
            // RuntimeId resolves — X is up by then on the production
            // boot path. Sub-second cmd; failure (X not yet up) is
            // best-effort and tolerable.
            if (_activeProfile is { KeyRepeatDelayMs: int delay, KeyRepeatRateHz: int rate }
                && delay > 0 && rate > 0)
            {
                _ = Bromure.AC.Display.GuestCommand.SendAsync(
                    VmRuntimeId,
                    $"DISPLAY=:1 xset r rate {delay} {rate} >/dev/null 2>&1",
                    ct);
            }
            // Audit 07 §4 — bind this profile to the VM that's hosting
            // its session so the SubscriptionTokenCoordinator can route
            // bridge state by source VM ID, then fire-and-forget the
            // autoSeed of stored Claude/Codex tokens. Best-effort: if
            // the agent never dials in (image missing the helper) the
            // await inside AutoSeed* hits the session's cancellation
            // budget and the user just re-logs.
            if (_engine.SubscriptionCoord is { } coord && _activeProfile is { } seedProfile)
            {
                coord.RegisterClaude(ProfileId, VmRuntimeId);
                coord.RegisterCodex(ProfileId, VmRuntimeId);
                _ = coord.AutoSeedClaudeAsync(ProfileId, VmRuntimeId, seedProfile, ct);
                _ = coord.AutoSeedCodexAsync(ProfileId, VmRuntimeId, seedProfile, ct);
            }
            // Perf #2: overlay producer was already pre-registered
            // in the OnRuntimeIdResolved hook above. No need to
            // re-register here.
            // Outbox watcher: opens guest-emitted URLs in the host's
            // default browser (bromure-open inside the VM drops a
            // url-*.txt into the share, we read it + dispatch).
            // Direct port of macOS's outbox loop.
            if (!string.IsNullOrEmpty(_session.OutboxDirectory))
            {
                _outbox = new Bromure.AC.Core.Outbox.SessionOutboxWatcher(_session.OutboxDirectory!);
                try { _outbox.Start(); }
                catch (Exception oxEx)
                {
                    BootLog("outbox watcher failed to start: " + oxEx.Message);
                    _outbox.Dispose();
                    _outbox = null;
                }
            }
            IsRunning = true;
            VmStatus = "Running";
            VmStatusDetail = $"VM up (RDP {_session.RdpPort}) · MITM 127.0.0.1:{proxyPort}";
        }
        catch (Exception ex)
        {
            BootLog("EXCEPTION " + ex.GetType().Name + ": " + ex.Message + "\n" + ex.StackTrace);
            VmStatus = "Boot failed";
            VmStatusDetail = ex.Message;
            FailureDetail = ex.ToString();
            HasFailure = true;
            IsRunning = false;
            try { await DisposeInternalsAsync().ConfigureAwait(false); } catch { }
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Cache the home-overlay tar on the GuestEventServer
    /// keyed by VM RuntimeId so the guest's bromure-overlay-fetch
    /// service can pull it at boot. Replaces the broken Plan9
    /// overlay path (Ubuntu kernel lacks HV_SOCK 9p).</summary>
    private void RegisterOverlayProducer(IReadOnlyDictionary<string, byte[]> homeFiles)
    {
        var vmId = VmRuntimeId;
        if (vmId == Guid.Empty) return;
        // Build the tar once, here on the UI thread; cheap (~ms).
        var tar = Bromure.SandboxEngine.Image.SessionHomeArchive.Build(homeFiles);
        Bromure.AC.Display.GuestEventServer.Instance.EnsureStarted();
        Bromure.AC.Display.GuestEventServer.Instance.RegisterOverlay(vmId, () => tar);
    }

    /// <summary>Subscribe to the singleton GuestEventServer for this
    /// session's guest-pushed window-title updates. Match is by VM
    /// RuntimeId — the AF_HYPERV peer address on the accepted
    /// connection carries the source VM's GUID, so the server can
    /// route each push straight to the right SessionViewModel.
    /// Also subscribes to the IP refresh push (audit 10 §2.8) so
    /// VmGuestIpAddress stays accurate across DHCP renewals.</summary>
    private void SubscribeToGuestTitle()
    {
        var vmId = VmRuntimeId;
        if (vmId == Guid.Empty) return;
        Bromure.AC.Display.GuestEventServer.Instance.EnsureStarted();
        Bromure.AC.Display.GuestEventServer.Instance.Subscribe(vmId, title =>
        {
            if (title == ProcessTitle || string.Equals(title, "starting", StringComparison.Ordinal)) return;
            System.Windows.Application.Current?.Dispatcher.InvokeAsync(() =>
            {
                ProcessTitle = title;
            });
        });
        // ip|<addr> heartbeat — guest pushes every ~5s (and on change).
        // Mirrors macOS ip.txt outbox file. Updates VmGuestIpAddress
        // so anything reading it (RDP host string, diagnostics, MCP
        // /sessions/{id}) stays current even after a DHCP renewal.
        Bromure.AC.Display.GuestEventServer.Instance.SubscribeIp(vmId, addr =>
        {
            if (string.IsNullOrWhiteSpace(addr) || addr == VmGuestIpAddress) return;
            System.Windows.Application.Current?.Dispatcher.InvokeAsync(() =>
            {
                VmGuestIpAddress = addr;
            });
        });
    }

    [RelayCommand]
    public async Task ShutdownAsync()
    {
        IsBusy = true;
        VmStatus = "Shutting down…";
        await DisposeInternalsAsync().ConfigureAwait(true);
        IsRunning = false;
        IsBusy = false;
        VmStatus = "Stopped";
    }

    /// <summary>Suspend the VM: dump CPU+RAM+device state to
    /// &lt;SessionRoot&gt;/saved-state.bin and tear down the MITM
    /// proxy + RDP bridge. The per-session VHDX stays in place; the
    /// next <see cref="StartAsync"/> for this profile will pick up the
    /// saved state and resume via HCS RestoreState/Resume.</summary>
    public async Task SaveStateAsync(CancellationToken ct = default)
    {
        if (_session is null) return;
        IsBusy = true;
        VmStatus = "Suspending…";
        var savedStatePath = Path.Combine(_sessionRoot, "saved-state.bin");
        try
        {
            await _session.SaveStateAsync(savedStatePath, ct).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            // Save failed (HCS sometimes can't snapshot a busy VM).
            // Fall back to a hard terminate so the user isn't left
            // with a zombie VM holding the VHDX open. Surface the
            // failure on the status line AND dump it to a known log
            // file so the close-path diagnostics can correlate.
            VmStatusDetail = "Suspend failed: " + ex.Message + " — terminated instead.";
            try
            {
                File.AppendAllText(
                    Path.Combine(Path.GetTempPath(), "bromure-close.log"),
                    $"[{DateTime.Now:HH:mm:ss.fff}] SaveStateAsync EXCEPTION: {ex}\n");
            }
            catch { }
            try { File.Delete(savedStatePath); } catch { }
            await DisposeInternalsAsync().ConfigureAwait(true);
            IsRunning = false;
            IsBusy = false;
            VmStatus = "Stopped";
            return;
        }
        // Drop the host-side bookkeeping that was tied to the live VM
        // (proxy, event subscriptions, HCN endpoint). The save file
        // is durable on disk, so the next launch can re-create them.
        if (VmRuntimeId != Guid.Empty)
        {
            try { Bromure.AC.Display.GuestEventServer.Instance.Subscribe(VmRuntimeId, null); } catch { }
            try { Bromure.AC.Display.GuestEventServer.Instance.SubscribeIp(VmRuntimeId, null); } catch { }
            try { Bromure.AC.Display.GuestEventServer.Instance.SubscribeAlive(VmRuntimeId, null); } catch { }
            try { Bromure.AC.Display.GuestEventServer.Instance.RegisterOverlay(VmRuntimeId, null); } catch { }
        }
        try { _engine.SubscriptionCoord?.UnregisterClaude(ProfileId); } catch { }
        try { _engine.SubscriptionCoord?.UnregisterCodex(ProfileId); } catch { }
        if (_session is not null)
        {
            try { await _session.DisposeAsync().ConfigureAwait(false); } catch { }
            _session = null;
        }
        if (_mitm is not null)
        {
            try { await _engine.UnregisterAsync(ProfileId).ConfigureAwait(false); } catch { }
            _mitm = null;
        }
        IsRunning = false;
        IsBusy = false;
        VmStatus = "Suspended";
    }

    [RelayCommand]
    private void DismissFailure()
    {
        HasFailure = false;
        FailureDetail = "";
    }

    [RelayCommand]
    private void OpenLog()
    {
        if (string.IsNullOrEmpty(StderrLogPath) || !File.Exists(StderrLogPath)) return;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "notepad.exe",
                Arguments = $"\"{StderrLogPath}\"",
                UseShellExecute = true,
            });
        }
        catch { /* best-effort */ }
    }

    [RelayCommand]
    private void CopyLog()
    {
        if (string.IsNullOrEmpty(FailureDetail)) return;
        try { System.Windows.Clipboard.SetText(FailureDetail); }
        catch { }
    }

    private async Task DisposeInternalsAsync()
    {
        if (VmRuntimeId != Guid.Empty)
        {
            try { Bromure.AC.Display.GuestEventServer.Instance.Subscribe(VmRuntimeId, null); } catch { }
            try { Bromure.AC.Display.GuestEventServer.Instance.SubscribeIp(VmRuntimeId, null); } catch { }
            try { Bromure.AC.Display.GuestEventServer.Instance.SubscribeAlive(VmRuntimeId, null); } catch { }
            try { Bromure.AC.Display.GuestEventServer.Instance.RegisterOverlay(VmRuntimeId, null); } catch { }
        }
        try { _engine.SubscriptionCoord?.UnregisterClaude(ProfileId); } catch { }
        try { _engine.SubscriptionCoord?.UnregisterCodex(ProfileId); } catch { }
        if (_outbox is not null)
        {
            try { _outbox.Dispose(); } catch { }
            _outbox = null;
        }
        if (_session is not null)
        {
            try { await _session.DisposeAsync().ConfigureAwait(false); } catch { }
            _session = null;
        }
        if (_mitm is not null)
        {
            try { await _engine.UnregisterAsync(ProfileId).ConfigureAwait(false); } catch { }
            _mitm = null;
        }
    }

    public ValueTask DisposeAsync() => new(ShutdownAsync());
}
