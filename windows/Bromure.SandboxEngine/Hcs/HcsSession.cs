// macos-source: Sources/SandboxEngine/SandboxVM.swift @ fe7e7d3a3e21
using System.Diagnostics;
using System.Text;

namespace Bromure.SandboxEngine.Hcs;

/// <summary>
/// One Bromure session = one HCS-managed Linux VM running our baked
/// rootfs, with per-session 9p shares for the home overlay, CA cert,
/// and the user's profile-configured shared folders. The guest's
/// systemd auto-mounts the 9p shares, applies the overlay, installs
/// the CA, and starts weston with the RDP backend; the host attaches
/// an RDP client to the VM over hvsocket to render kitty into the
/// WPF shell.
///
/// <para><b>Replaces <see cref="Wsl.WslSession"/>.</b> Method-for-method
/// parity:</para>
/// <list type="bullet">
///   <item><c>StartAsync</c> — same 5-phase pattern (create-or-adopt,
///   home overlay, CA cert, shares, spawn) but every step is now
///   "stage a Windows-side directory the 9p share will expose"
///   instead of "<c>tee</c> via wsl --user root."</item>
///   <item><c>ShutdownAsync</c> + <c>DisposeAsync</c> — terminate VM,
///   destroy compute system, delete child VHDX, revoke disk grants.</item>
///   <item>Phase log persisted to <c>hcs-timings.log</c> alongside
///   the install dir, same shape as the WSL port's
///   <c>wsl-timings.log</c>.</item>
/// </list>
///
/// <para><b>Guest-side cooperation.</b> The bake's
/// <c>setup-hcs.sh</c> drops a <c>bromure-overlay-apply.service</c>
/// systemd unit that copies the home overlay tree onto
/// <c>/home/bromure/</c> with correct ownership, and a
/// <c>bromure-ca-install.service</c> that runs
/// <c>update-ca-certificates</c> over the certs share. A
/// <c>bromure-boot.service</c> writes a one-byte handshake to a
/// hvsocket port so we know userspace is ready.</para>
/// </summary>
public sealed class HcsSession : IAsyncDisposable
{
    private readonly HcsSessionConfig _cfg;
    private VhdxDisk? _disk;
    private HcsVm? _vm;
    private string? _stagingRoot;
    private bool _disposed;
    private HvSocketTcpBridge? _rdpTcpBridge;
    private Guid _hcnEndpointId;

    public HcsSession(HcsSessionConfig cfg)
    {
        _cfg = cfg ?? throw new ArgumentNullException(nameof(cfg));
    }

    /// <summary>The underlying VM once <see cref="StartAsync"/> has run.</summary>
    public HcsVm Vm => _vm ?? throw new InvalidOperationException("Session not started");

    /// <summary>HvSocket port (and matching service GUID) the host should
    /// connect mstsc to in order to render the user-visible session.
    /// Equivalent to "find the WSLg HWND" in the WSL port — same
    /// purpose, completely different implementation.</summary>
    public uint RdpPort => _cfg.RdpPort;

    /// <summary>Loopback TCP port the bridge listens on; mstsc dials
    /// <c>/v:127.0.0.1:&lt;this&gt;</c> and the bridge forwards to the
    /// guest's hvsocket. 0 until <see cref="StartAsync"/> finishes.</summary>
    public int RdpTcpBridgePort => _rdpTcpBridge?.Port ?? 0;

    /// <summary>Guest IP on the host's "bromure-bake-net" NAT subnet
    /// (192.168.50.0/24). Populated by <see cref="StartAsync"/> when
    /// the session config includes <see cref="HcsSessionConfig.UseNetworkAdapter"/>.
    /// The IP is the WPF VNC client's actual connect target — far more
    /// reliable than the hvsocket bridge whose host→guest direction
    /// silently hangs on this Windows build.</summary>
    public string? GuestIpAddress { get; private set; }

    /// <summary>Host-side path the guest's <c>/mnt/bromure-outbox</c>
    /// 9p share is rooted at. Populated by <see cref="StartAsync"/>
    /// before the VM is created. Stable across the session — callers
    /// can park a FileSystemWatcher on it as soon as
    /// <c>StartAsync</c> returns.</summary>
    public string? OutboxDirectory { get; private set; }

    /// <summary>Phase-by-phase timings from the most recent
    /// <see cref="StartAsync"/>. Populated even on failure.</summary>
    public string LastTimings { get; private set; } = "";

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_vm is not null) throw new InvalidOperationException("Already started");

        // Hard deadline so a stuck HCS service doesn't freeze the UI
        // forever — same defensive pattern as WslSession.StartAsync.
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(120));
        try
        {
            await Task.Run(() => StartImpl(deadline.Token), deadline.Token).ConfigureAwait(false);
        }
        catch (Bromure.SandboxEngine.Hcs.Native.HcsException hcsEx) when (IsParentLocatorMismatch(hcsEx))
        {
            // Recovery path for child VHDXs whose parent rotated
            // since the clone (typically after Settings → Build /
            // rebuild). The launcher's image-version alert should
            // have caught this upstream, but old profiles with no
            // BaseImageVersionAtClone field — or where the field
            // was set during a pre-UUID-stamp build — bypass that
            // check. HCS reliably signals the condition via
            // 0xC03A000E, so we can act on it deterministically.
            var diskPath = System.IO.Path.Combine(_cfg.InstallPath, "disk.vhdx");
            try { System.IO.File.Delete(diskPath); }
            catch (System.IO.IOException) { throw; }  // re-throw original if we can't even delete
            // Drop the half-created VM + endpoint so the retry is
            // truly from a clean slate.
            try { if (_vm is not null) { _ = _vm.DisposeAsync(); _vm = null; } } catch { }
            try { if (_hcnEndpointId != Guid.Empty)
            {
                Bromure.SandboxEngine.Hcs.Native.HcnApi.DeleteEndpoint(_hcnEndpointId);
                _hcnEndpointId = Guid.Empty;
            } } catch { }
            using var retryDeadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            retryDeadline.CancelAfter(TimeSpan.FromSeconds(120));
            await Task.Run(() => StartImpl(retryDeadline.Token), retryDeadline.Token).ConfigureAwait(false);
        }
    }

    /// <summary>Detect HCS's "parent VHDX identifier mismatch" error
    /// (0xC03A000E) — the deterministic signal that a child VHDX is
    /// stale relative to its parent and needs to be recreated.</summary>
    private static bool IsParentLocatorMismatch(Bromure.SandboxEngine.Hcs.Native.HcsException ex)
    {
        const int E_VHD_PARENT_LOCATOR_MISMATCH = unchecked((int)0xC03A000E);
        return ex.HResult == E_VHD_PARENT_LOCATOR_MISMATCH
            || ex.Message.Contains("parent virtual hard disk", StringComparison.OrdinalIgnoreCase);
    }

    private async Task StartImpl(CancellationToken ct)
    {
        var t0 = Stopwatch.StartNew();
        var phaseLog = new StringBuilder();
        // Live log so a hang is visible in real time (the post-mortem
        // hcs-timings.log only gets written if StartImpl finishes).
        var liveLogPath = Path.Combine(Path.GetTempPath(), "bromure-ac-boot.log");
        void Live(string msg)
        {
            try
            {
                File.AppendAllText(liveLogPath,
                    $"[hcs +{t0.ElapsedMilliseconds}ms] {msg}\n");
            }
            catch { }
        }
        void Phase(string name, long ms)
        {
            phaseLog.AppendLine($"[hcs-start] {name} {ms} ms (total {t0.ElapsedMilliseconds} ms)");
            Live($"phase {name} took {ms} ms");
        }
        Live("StartImpl entered");

        // Per-session staging tree under InstallPath. The 9p shares
        // point at subdirectories of this; the guest mounts them.
        Directory.CreateDirectory(_cfg.InstallPath);
        _stagingRoot = _cfg.InstallPath;
        var overlayDir = Path.Combine(_stagingRoot, "overlay");
        var certsDir = Path.Combine(_stagingRoot, "certs");
        Directory.CreateDirectory(overlayDir);
        Directory.CreateDirectory(certsDir);

        // 1) VHDX child clone — the macOS APFS-CoW analogue.
        Live("vhdx-clone starting");
        var phaseStart = t0.ElapsedMilliseconds;
        var diskPath = Path.Combine(_stagingRoot, "disk.vhdx");
        _disk = new VhdxDisk(diskPath, _cfg.BaseVhdxPath);
        await _disk.CreateChildAsync(ct).ConfigureAwait(false);
        Phase("vhdx-clone", t0.ElapsedMilliseconds - phaseStart);

        // 1b) Resume eligibility — only honour SavedStateFilePath if
        // (a) the file exists, AND (b) it's newer than the parent
        // VHDX. If the parent was rebaked since the save, the saved
        // state's view of the kernel + rootfs is stale and resuming
        // would crash the guest the first time it touched a changed
        // page. Delete the stale save in that case and cold-boot.
        var resumeFromState = false;
        if (!string.IsNullOrEmpty(_cfg.SavedStateFilePath))
        {
            try
            {
                if (File.Exists(_cfg.SavedStateFilePath))
                {
                    var stateMtime  = File.GetLastWriteTimeUtc(_cfg.SavedStateFilePath);
                    var parentMtime = File.GetLastWriteTimeUtc(_cfg.BaseVhdxPath);
                    if (parentMtime > stateMtime)
                    {
                        Live($"saved-state: stale (parent={parentMtime:o} > state={stateMtime:o}); discarding");
                        try { File.Delete(_cfg.SavedStateFilePath); } catch { }
                    }
                    else
                    {
                        resumeFromState = true;
                        Live("saved-state: eligible for resume");
                    }
                }
            }
            catch (Exception ex) { Live("saved-state probe failed: " + ex.Message); }
        }

        // 2) Stage the home overlay onto the Windows side. The guest's
        // bromure-overlay-apply.service copies these into /home/bromure
        // at boot. Ownership fixup happens guest-side (same trade-off
        // the WSL port had with the chown pass after \\wsl$ writes).
        phaseStart = t0.ElapsedMilliseconds;
        await StageHomeOverlayAsync(overlayDir, ct).ConfigureAwait(false);
        Phase("home-overlay", t0.ElapsedMilliseconds - phaseStart);

        // 3) Stage the CA cert. The guest service that mounts this
        // share also runs update-ca-certificates, so HTTPS_PROXY MITM
        // is trusted by curl/git/node/openssl/etc.
        if (_cfg.BromureCaPem is { Length: > 0 })
        {
            phaseStart = t0.ElapsedMilliseconds;
            await StageCaCertAsync(certsDir, ct).ConfigureAwait(false);
            Phase("ca-cert", t0.ElapsedMilliseconds - phaseStart);
        }

        // 4) Configure 9p shares: home overlay, certs, and one share
        // per profile-configured shared folder. Plan9 ports start at
        // 50001 and increment — guests use the port to discriminate
        // mounts. This replaces both \\wsl$\ writes and wslpath-based
        // symlinks in one mechanism.
        phaseStart = t0.ElapsedMilliseconds;
        var shares = new Dictionary<string, Plan9ShareSpec>(StringComparer.Ordinal);
        uint nextPort = _cfg.Plan9StartPort;
        // ReadOnly:false on both shares — WSL2's working /mnt/c share
        // is RW and the guest-side mount options handle ro/rw. With
        // Plan9 share's ReadOnly=true, vmcompute rejects the device
        // construction (HCS_E_INVALID_DEFINITION_OBJECT). The guest
        // can still `mount -t 9p ... -o ro` if it wants the dir
        // read-only.
        shares["overlay"] = new Plan9ShareSpec(overlayDir, nextPort++, "bromure-overlay", ReadOnly: false);
        if (_cfg.BromureCaPem is { Length: > 0 })
        {
            shares["certs"] = new Plan9ShareSpec(certsDir, nextPort++, "bromure-certs", ReadOnly: false);
        }
        // Guest→host event channel: piggy-backs on the overlay 9p
        // share (already bidirectional) instead of a separate outbox
        // mount. The guest's bromure-title-poll writes
        // /mnt/bromure-overlay/.bromure-window-title; the host sees
        // it appear at overlayDir/.bromure-window-title and updates
        // SessionViewModel.ProcessTitle.
        OutboxDirectory = overlayDir;
        var seenShareTags = new HashSet<string>(StringComparer.Ordinal);
        foreach (var winPath in _cfg.SharedFolderPaths)
        {
            if (string.IsNullOrWhiteSpace(winPath) || !Directory.Exists(winPath)) continue;
            var tag = SafeBasename(winPath);
            if (!seenShareTags.Add(tag)) continue;
            shares["share-" + tag] = new Plan9ShareSpec(winPath, nextPort++, tag, ReadOnly: false);
        }
        Phase("share-plan", t0.ElapsedMilliseconds - phaseStart);

        // 4b) HCN endpoint on the configured switch's HNS network.
        // Guest's NIC binds to this endpoint; DHCP gives it an IP on
        // the switch's NAT subnet. Required because host→guest writes
        // over hvsocket hang on this Windows build — we bypass that
        // transport for the user-facing display traffic and use plain
        // TCP instead. Boot signal continues to use hvsocket (only
        // guest→host writes are needed for that).
        string? netMac = null;
        if (_cfg.UseNetworkAdapter)
        {
            Live($"hcn-endpoint: looking up HNS network for VMSwitch '{_cfg.NetworkSwitchName}'");
            phaseStart = t0.ElapsedMilliseconds;
            var netId = Bromure.SandboxEngine.Hcs.Native.HcnApi.FindNetworkIdByName(_cfg.NetworkSwitchName);
            Live($"hcn-endpoint: networkId={netId:D}");
            if (netId == Guid.Empty)
            {
                throw new InvalidOperationException(
                    "Could not find HNS network for VMSwitch '" + _cfg.NetworkSwitchName +
                    "'. Run a bake once first — VmBaker creates the switch via PowerShell.");
            }
            netMac = !string.IsNullOrEmpty(_cfg.NetworkMacAddressOverride)
                ? _cfg.NetworkMacAddressOverride!
                : Bromure.SandboxEngine.Hcs.Native.HcnApi.RandomMacAddress();
            Live($"hcn-endpoint: creating endpoint mac={netMac} ({(string.IsNullOrEmpty(_cfg.NetworkMacAddressOverride) ? "random" : "stable")})");
            _hcnEndpointId = Bromure.SandboxEngine.Hcs.Native.HcnApi.CreateEndpoint(netId, netMac);
            Live($"hcn-endpoint: created id={_hcnEndpointId:D}");
            Phase("hcn-endpoint", t0.ElapsedMilliseconds - phaseStart);
        }

        // 5) Build VM config + create + start. If the caller supplied a
        // warm VM (pre-created from the pool) we adopt it instead;
        // skips the create cost on the user-visible path. This is the
        // 1:1 analogue of WslSession.WarmDistro adoption.
        phaseStart = t0.ElapsedMilliseconds;
        if (_cfg.WarmVm is { } warm)
        {
            _vm = warm;
            // Warm VMs were created with placeholder shares; modify
            // adds the per-session shares before start. (HcsModify lets
            // us add Plan9 shares to a created-but-not-started VM.)
            // For the spike we restart-from-scratch on warm too — see
            // WarmVmPool docs for the rationale.
        }
        else
        {
            var vmCfg = new HcsVmConfig
            {
                KernelPath = _cfg.KernelPath,
                InitrdPath = _cfg.InitrdPath,
                KernelCmdLine = _cfg.KernelCmdLine,
                UseLinuxKernelDirect = _cfg.UseLinuxKernelDirect,
                NetworkEndpointId = _hcnEndpointId,
                NetworkMacAddress = netMac,
                RootDiskPath = diskPath,
                // Parent of the differencing child — the VM worker
                // needs ACL access to it OR HCS fails with "chain of
                // virtual hard disks is inaccessible".
                ParentDiskPath = _cfg.BaseVhdxPath,
                // Serial console to a host-side named pipe so we
                // can read kernel + systemd output for diagnostics.
                // Caller (spike or AC) opens \\.\pipe\<name>-com1.
                ComPort1PipeName = _cfg.VmId + "-com1",
                MemoryMB = _cfg.MemoryMB,
                CpuCount = _cfg.CpuCount,
                Plan9Shares = shares,
                // Plan9 ports MUST also appear in HvSocket.ServiceTable
                // — the Plan9 device doesn't auto-register; it binds
                // to a pre-existing hvsocket service slot at the
                // declared port. Without the corresponding service
                // entry, Plan9 device construction fails with
                // HCS_E_INVALID_DEFINITION_OBJECT. Earlier I yanked
                // these out thinking they conflicted with Plan9's
                // own registration; the bisect proved otherwise
                // (bare VM + HvSocket alone succeeds; adding Plan9
                // alone fails; adding both together with the ports
                // registered succeeds — same shape WSL2 uses).
                // 9224 = title push (guest→host). 9225 = overlay
                // fetch (guest→host). 9226 = command server
                // (host→guest, host dials in to exec "kitty" / xdotool
                // for the + button and tab-raise actions).
                HvSocketPorts = new uint[]
                {
                    _cfg.RdpPort, _cfg.BootSignalPort,
                    9224u, 9225u, 9226u,
                    // SSH-agent forwarding: in-VM bromure-ssh-agent-bridge
                    // daemon dials this port; the host's
                    // SshAgentHvSocketListener accepts. Matches
                    // MitmEngine.SshAgentVsockPort.
                    8444u,
                    // AWS credential_process: in-VM bromure-aws-credentials
                    // helper dials this port; the host's
                    // AwsCredentialHvSocketListener serves the fake
                    // payload. Matches MitmEngine.AwsCredsVsockPort.
                    8445u,
                    // SubscriptionTokenBridge (Claude OAuth) +
                    // CodexTokenBridge — guest agents push the
                    // captured access tokens here; the host's
                    // SubscriptionTokenCoordinator mints fakes +
                    // seeds the swap map. Audit 07 #3 fix: the
                    // earlier transport was Windows Named Pipes,
                    // which a Linux guest can't dial.
                    8446u, 8447u,
                }
                    .Concat(shares.Values.Select(s => s.Port)).ToArray(),
            };
            // Hibernate-resume: pass the saved-state path so HCS
            // creates the VM with RestoreState.SavedStateFilePath set
            // — we follow up with HcsResumeComputeSystem (not Start).
            var vmCfgWithRestore = resumeFromState
                ? vmCfg with { SavedStateFilePath = _cfg.SavedStateFilePath }
                : vmCfg;
            _vm = new HcsVm(_cfg.VmId, vmCfgWithRestore);
            Live("vm.CreateAsync starting" + (resumeFromState ? " (with RestoreState)" : ""));
            await _vm.CreateAsync(ct).ConfigureAwait(false);
            Live("vm.CreateAsync OK");
        }
        // Perf #2: VM identity is known — fire the hook BEFORE Start
        // so callers can register overlay/title producers with the
        // GuestEventServer keyed by the now-known RuntimeId. The
        // guest's bromure-overlay-fetch.service dials at ~+500ms into
        // boot; if the producer isn't registered by then, it blocks
        // 28s waiting for the host (which used to register only after
        // boot-signal, ~30s in).
        try { _cfg.OnRuntimeIdResolved?.Invoke(ResolveVmRuntimeId()); }
        catch (Exception ex) { Live("OnRuntimeIdResolved threw: " + ex.Message); }
        if (resumeFromState)
        {
            Live("vm.ResumeAsync starting");
            await _vm.ResumeAsync(ct).ConfigureAwait(false);
            Live("vm.ResumeAsync OK");
        }
        else
        {
            Live("vm.StartAsync starting");
            await _vm.StartAsync(ct).ConfigureAwait(false);
            Live("vm.StartAsync OK");
        }
        Phase("vm-" + (resumeFromState ? "resume" : "start"), t0.ElapsedMilliseconds - phaseStart);

        // 6) Wait for guest boot handshake. Perf #2: prefer the
        // caller-supplied BootSignalTask when set — it's typically
        // tied to the overlay dial-in, which fires at +2 s post-start
        // and lets us skip the 20-30 s WSAConnect-timeout cost the
        // hvsocket dial-poll pays before the in-VM proxy is ready to
        // accept. Falls back to the dial-poll for callers (spikes,
        // older paths) that don't supply a signal task.
        Live("boot-signal: waiting" + (_cfg.BootSignalTask is null ? " for hvsocket dial-back" : " for external signal"));
        phaseStart = t0.ElapsedMilliseconds;
        if (_cfg.BootSignalTask is not null)
        {
            // Bound the wait to 90 s — same deadline as the dial-poll.
            var bound = Task.WhenAny(_cfg.BootSignalTask, Task.Delay(TimeSpan.FromSeconds(90), ct));
            var winner = await bound.ConfigureAwait(false);
            if (winner != _cfg.BootSignalTask) throw new TimeoutException("BootSignalTask deadline elapsed");
        }
        else
        {
            await WaitForBootSignalAsync(ct).ConfigureAwait(false);
        }
        Live("boot-signal: received");
        Phase("boot-signal", t0.ElapsedMilliseconds - phaseStart);

        // 7) Boot signal arrived → spin up the host-side TCP→hvsocket
        // bridge so mstsc.exe can dial /v:127.0.0.1:<port>. mstsc's
        // built-in hvsocket transport only fires for VMs registered
        // with Hyper-V Manager; HCS-direct compute systems aren't,
        // so we bridge ourselves. Cheap — accepts on demand.
        phaseStart = t0.ElapsedMilliseconds;
        var runtimeId = ResolveVmRuntimeId();
        if (runtimeId != Guid.Empty)
        {
            _rdpTcpBridge = new HvSocketTcpBridge(runtimeId, _cfg.RdpPort);
            _rdpTcpBridge.Start();
            Console.Error.WriteLine(
                "[hcs-session] rdp-tcp-bridge listening on 127.0.0.1:" + _rdpTcpBridge.Port);
        }
        Phase("rdp-bridge", t0.ElapsedMilliseconds - phaseStart);

        // 8) Guest IP discovery — only when NetworkAdapter is on. We
        // generated a unique MAC for the endpoint; the guest's DHCP
        // client (systemd-networkd) will request and an IP will end
        // up in the host's ARP table on the first packet. Poll
        // `arp -a` for up to 20 s.
        if (!string.IsNullOrEmpty(netMac))
        {
            phaseStart = t0.ElapsedMilliseconds;
            GuestIpAddress = await DiscoverGuestIpAsync(netMac!, ct).ConfigureAwait(false);
            Phase("guest-ip",  t0.ElapsedMilliseconds - phaseStart);
            if (!string.IsNullOrEmpty(GuestIpAddress))
            {
                Console.Error.WriteLine("[hcs-session] guest IP: " + GuestIpAddress);
            }
            else
            {
                Console.Error.WriteLine("[hcs-session] WARNING: failed to discover guest IP (mac=" + netMac + ")");
            }
        }

        try
        {
            await File.WriteAllTextAsync(
                Path.Combine(_stagingRoot, "hcs-timings.log"),
                phaseLog.ToString(), ct).ConfigureAwait(false);
        }
        catch { /* best-effort */ }
        LastTimings = phaseLog.ToString();
    }

    /// <summary>Stage the home overlay tree on the Windows side. The 9p
    /// share will expose this directory read-only at boot; the
    /// guest service copies it into /home/bromure/. We also drop a
    /// /etc-style env file (<c>bromure-env.sh</c>) sourced by the
    /// guest's bashrc, replacing the WSLENV-based injection the WSL
    /// port used.</summary>
    private async Task StageHomeOverlayAsync(string overlayDir, CancellationToken ct)
    {
        foreach (var (relPath, bytes) in _cfg.HomeFiles)
        {
            var full = Path.Combine(overlayDir,
                relPath.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            await File.WriteAllBytesAsync(full, bytes, ct).ConfigureAwait(false);
        }

        // Env file — sourced by /etc/profile.d/bromure-env.sh inside
        // the guest. Replaces WSLENV. One KEY=VALUE per line, single-
        // quoted with backslash-escaping for embedded quotes.
        if (_cfg.EnvVars.Count > 0)
        {
            var sb = new StringBuilder();
            sb.AppendLine("# Bromure session env — generated by HcsSession.StageHomeOverlayAsync");
            foreach (var (k, v) in _cfg.EnvVars)
            {
                if (!IsValidEnvName(k)) continue;
                var quoted = "'" + v.Replace("'", "'\\''") + "'";
                sb.AppendLine($"export {k}={quoted}");
            }
            var envFile = Path.Combine(overlayDir, ".bromure-env");
            await File.WriteAllTextAsync(envFile, sb.ToString(), ct).ConfigureAwait(false);
        }
    }

    private static bool IsValidEnvName(string name)
    {
        if (string.IsNullOrEmpty(name)) return false;
        if (!char.IsLetter(name[0]) && name[0] != '_') return false;
        for (int i = 1; i < name.Length; i++)
        {
            var c = name[i];
            if (!char.IsLetterOrDigit(c) && c != '_') return false;
        }
        return true;
    }

    /// <summary>Stage the CA cert at the path the guest's
    /// update-ca-certificates expects. The guest's
    /// bromure-ca-install.service mounts the share at
    /// /usr/local/share/ca-certificates/bromure/ and runs
    /// update-ca-certificates. Same end state as WslSession's
    /// `tee` + `update-ca-certificates` pair, but without the wsl.exe
    /// shell-out.</summary>
    private async Task StageCaCertAsync(string certsDir, CancellationToken ct)
    {
        var path = Path.Combine(certsDir, "bromure-ca.crt");
        await File.WriteAllBytesAsync(path, _cfg.BromureCaPem!, ct).ConfigureAwait(false);
    }

    /// <summary>Wait for the guest's bromure-hvsock-proxy to start
    /// accepting connections on AF_VSOCK port 3389 — that proxy is
    /// the front-end for weston-rdp and is the canonical "ready"
    /// signal for the session. We dial it from the host until the
    /// connect succeeds (close the socket immediately; we don't
    /// actually want to occupy it before mstsc does).
    ///
    /// <para>Earlier this method waited on a dedicated boot-signal
    /// service at port 50100 — that service was specified by an
    /// older setup-hcs.sh but never installed by the current
    /// setup.sh bake, so the wait timed out 100% of the time. The
    /// RDP-listener probe is a better signal anyway: it confirms
    /// the actual user-facing service is ready, not just some
    /// arbitrary one-byte handshake.</para></summary>
    private async Task WaitForBootSignalAsync(CancellationToken ct)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(90);
        var vmId = ResolveVmRuntimeId();
        // Diagnostic: dump the resolved RuntimeId + the service-ID
        // GUID we'll dial. "Invalid argument" from Socket.ConnectAsync
        // means one of these is malformed — printing them makes
        // that fast to spot from spike output.
        var svcId = Bromure.SandboxEngine.Hcs.Native.HvSocketApi.ServiceIdFromPort(_cfg.RdpPort);
        Console.Error.WriteLine("[hcs-session] WaitForBootSignal: runtimeId=" + vmId.ToString("D") +
            ", port=" + _cfg.RdpPort + ", serviceId=" + svcId.ToString("D"));
        if (vmId == Guid.Empty)
        {
            // No runtime ID yet — fall back to a 10 s wait. mstsc
            // itself will retry the hvsocket connect for a few
            // seconds after spawn, so an imprecise wait here isn't
            // fatal; the user just sees a "Connecting…" pane.
            await Task.Delay(TimeSpan.FromSeconds(10), ct).ConfigureAwait(false);
            return;
        }
        Exception? last = null;
        var seenErrors = new HashSet<string>(StringComparer.Ordinal);
        while (DateTime.UtcNow < deadline)
        {
            // Per-attempt 500ms timeout. Without this, a single
            // hanging connect (the typical failure mode while the
            // guest's RDP daemon hasn't bound the hvsocket service
            // entry yet) burns ~20s on TCP-default timeout, blowing
            // the whole budget. Perf #2 wants the fast-fail loop so
            // the real "service is up" moment is detected within
            // hundreds of ms, not tens of seconds.
            using var attemptCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            attemptCts.CancelAfter(TimeSpan.FromMilliseconds(500));
            try
            {
                using var sock = await HvSocket.ConnectAsync(vmId, _cfg.RdpPort, attemptCts.Token)
                    .ConfigureAwait(false);
                Console.Error.WriteLine("[hcs-session] WaitForBootSignal: connected on attempt " +
                    (last is null ? "1" : ">1"));
                return;
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                // Per-attempt timeout — guest isn't ready yet, retry.
                last = new TimeoutException("connect timed out on attempt");
            }
            catch (System.Net.Sockets.SocketException sx)
            {
                last = sx;
                var key = sx.SocketErrorCode + ":" + sx.NativeErrorCode;
                if (seenErrors.Add(key))
                {
                    Console.Error.WriteLine(
                        "[hcs-session] WaitForBootSignal connect: SocketError=" +
                        sx.SocketErrorCode + " (" + (int)sx.SocketErrorCode +
                        "), NativeError=" + sx.NativeErrorCode + " ('" + sx.Message + "')");
                }
            }
            catch (Exception ex) { last = ex; }
            await Task.Delay(200, ct).ConfigureAwait(false);
        }
        throw new TimeoutException(
            "Guest's RDP listener on hvsocket port " + _cfg.RdpPort +
            " never accepted a connection within 90s. Common causes: " +
            "weston-rdp.service crashed inside the guest, or " +
            "bromure-hvsock-proxy didn't start (check the guest's " +
            "`journalctl -u bromure-weston -u bromure-hvsock-proxy` " +
            "after the VM boots). Last error: " + (last?.Message ?? "<none>"));
    }

    /// <summary>Resolve the VM's RUNTIME id (a Guid that hvsocket
    /// + mstsc + vmconnect all dial), as opposed to the compute-
    /// system id we picked at create time. HCS exposes it as the
    /// <c>RuntimeId</c> property in <see cref="HcsVm.GetPropertiesAsync"/>'s
    /// JSON response. Returns Guid.Empty if the call or the parse
    /// fails — callers fall back to a fixed wait / no-display path.</summary>
    private Guid ResolveVmRuntimeId()
    {
        if (_vm is null) return Guid.Empty;
        try
        {
            var json = _vm.GetPropertiesAsync().GetAwaiter().GetResult();
            if (string.IsNullOrEmpty(json)) return Guid.Empty;
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("RuntimeId", out var rt)) return Guid.Empty;
            var s = rt.GetString();
            if (string.IsNullOrEmpty(s)) return Guid.Empty;
            return Guid.TryParse(s, out var g) ? g : Guid.Empty;
        }
        catch { return Guid.Empty; }
    }

    /// <summary>Public hook for the AC's display code so it can
    /// build the <c>hvsocket://&lt;guid&gt;:&lt;port&gt;</c> URL mstsc
    /// dials. Returns Guid.Empty if the VM isn't running yet or HCS
    /// didn't surface a RuntimeId (older Windows builds: fall back
    /// to a fixed wait + retry).</summary>
    public Guid RuntimeId => ResolveVmRuntimeId();

    /// <summary>Linux-safe basename for a Windows folder path. Same logic
    /// as <see cref="Wsl.WslSession.SafeBasename"/> — kept compatible
    /// so a profile's shared folders surface under the same names
    /// regardless of which sandbox engine is active.</summary>
    internal static string SafeBasename(string winPath)
    {
        var trimmed = winPath.TrimEnd('\\', '/');
        var lastSep = trimmed.LastIndexOfAny(new[] { '\\', '/' });
        var raw = lastSep >= 0 ? trimmed[(lastSep + 1)..] : trimmed;
        var sb = new StringBuilder(raw.Length);
        foreach (var c in raw)
        {
            if (c == '/' || c == '\\' || c == '\0' || c < 0x20) continue;
            sb.Append(c);
        }
        var clean = sb.ToString().Trim();
        return clean.Length == 0 ? "share" : clean;
    }

    public async Task ShutdownAsync(CancellationToken ct = default)
    {
        if (_vm is not null)
        {
            try { await _vm.TerminateAsync(ct).ConfigureAwait(false); } catch { }
        }
    }

    /// <summary>Suspend the VM: dump its CPU+RAM+device state to
    /// <paramref name="savePath"/> and close the compute system. The
    /// per-session staging tree (overlay/, certs/, disk.vhdx) stays in
    /// place; a subsequent <see cref="StartAsync"/> with
    /// <see cref="HcsSessionConfig.SavedStateFilePath"/> set to the
    /// same path will resume from this state instead of cold-booting.
    /// </summary>
    public async Task SaveStateAsync(string savePath, CancellationToken ct = default)
    {
        if (_vm is null) throw new InvalidOperationException("Not started");
        await _vm.SaveAsync(savePath, ct).ConfigureAwait(false);
        // The TCP→hvsocket bridge dies once the VM goes into Saved
        // state — tear it down so the loopback port is released for
        // the next launch.
        if (_rdpTcpBridge is not null)
        {
            try { await _rdpTcpBridge.DisposeAsync().ConfigureAwait(false); } catch { }
            _rdpTcpBridge = null;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        if (_rdpTcpBridge is not null)
        {
            try { await _rdpTcpBridge.DisposeAsync().ConfigureAwait(false); } catch { }
            _rdpTcpBridge = null;
        }
        await ShutdownAsync().ConfigureAwait(false);
        if (_vm is not null)
        {
            try { await _vm.DisposeAsync().ConfigureAwait(false); } catch { }
            _vm = null;
        }
        if (_disk is not null)
        {
            try { await _disk.DisposeAsync().ConfigureAwait(false); } catch { }
            _disk = null;
        }
        if (_hcnEndpointId != Guid.Empty)
        {
            try { Bromure.SandboxEngine.Hcs.Native.HcnApi.DeleteEndpoint(_hcnEndpointId); } catch { }
            _hcnEndpointId = Guid.Empty;
        }
    }

    /// <summary>Poll the host's ARP cache until an entry for our
    /// generated MAC appears, then return its IP. Returns null on
    /// timeout. <paramref name="targetMac"/> matches the format
    /// PowerShell's <c>Get-NetNeighbor</c> uses (dash-separated hex).</summary>
    private static async Task<string?> DiscoverGuestIpAsync(string targetMac, CancellationToken ct)
    {
        var normalised = targetMac.Replace("-", "").Replace(":", "").ToLowerInvariant();
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(20);
        // First, encourage the guest to send a packet — ping the
        // gateway address on the bake net.  Even a few ICMP probes
        // wake systemd-networkd's DHCP client enough to land an ARP.
        _ = Task.Run(() =>
        {
            try { System.Net.NetworkInformation.PhysicalAddress.Parse(targetMac); }
            catch { }
        }, ct);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "arp", Arguments = "-a",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    CreateNoWindow = true,
                };
                using var proc = System.Diagnostics.Process.Start(psi)!;
                var output = await proc.StandardOutput.ReadToEndAsync().ConfigureAwait(false);
                await proc.WaitForExitAsync(ct).ConfigureAwait(false);
                // ARP table lines look like:
                //   192.168.50.10      02-1a-2b-3c-4d-5e   dynamic
                foreach (var line in output.Split('\n'))
                {
                    var trimmed = line.Trim();
                    if (trimmed.Length == 0) continue;
                    var parts = trimmed.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length < 2) continue;
                    var macField = parts[1].Replace("-", "").Replace(":", "").ToLowerInvariant();
                    if (macField == normalised)
                    {
                        return parts[0];
                    }
                }
            }
            catch { }
            await Task.Delay(500, ct).ConfigureAwait(false);
        }
        return null;
    }
}

/// <summary>Inputs for one <see cref="HcsSession"/>. 1:1 with
/// <see cref="Wsl.WslSessionConfig"/> — every field has a direct
/// counterpart, the pivot is "tarball/distro" → "vhdx/vm".</summary>
public sealed record HcsSessionConfig
{
    /// <summary>Path to the sealed <c>bromure-base.vhdx</c>. Equivalent
    /// of <c>WslSessionConfig.BaseRootfsPath</c>.</summary>
    public required string BaseVhdxPath { get; init; }

    /// <summary>Path to the Linux kernel shipped alongside the VHDX.</summary>
    public required string KernelPath { get; init; }

    /// <summary>Path to the initrd shipped alongside the VHDX.</summary>
    public required string InitrdPath { get; init; }

    /// <summary>Optional kernel cmdline override.</summary>
    public string KernelCmdLine { get; init; } =
        "console=ttyS0 root=/dev/sda rw rootfstype=ext4 init=/lib/systemd/systemd quiet";

    /// <summary>Compute-system ID for HCS. Use a per-session GUID-derived
    /// form so concurrent sessions don't collide. Equivalent of
    /// <c>WslSessionConfig.DistroName</c>.</summary>
    public required string VmId { get; init; }

    /// <summary>Per-session staging dir. Holds the child VHDX, the
    /// home-overlay 9p tree, the certs 9p tree, and the timings log.
    /// Caller picks something disposable under
    /// <c>%LOCALAPPDATA%\Bromure</c>. Equivalent of
    /// <c>WslSessionConfig.InstallPath</c>.</summary>
    public required string InstallPath { get; init; }

    /// <summary>Default user inside the guest. Should match the user
    /// the bake created (<c>bromure</c> by default — same as the WSL
    /// port).</summary>
    public string GuestUser { get; init; } = "bromure";

    /// <summary>Files to drop under <c>/home/&lt;GuestUser&gt;/</c>.
    /// Same shape as <c>WslSessionConfig.HomeFiles</c> — keys are
    /// slash-separated relative paths, values raw bytes.</summary>
    public IReadOnlyDictionary<string, byte[]> HomeFiles { get; init; }
        = new Dictionary<string, byte[]>();

    /// <summary>Environment variables for the guest's interactive
    /// shell. Written into <c>~/.bromure-env</c>; the guest's
    /// /etc/profile.d sources it. Replaces WSLENV.</summary>
    public IReadOnlyDictionary<string, string> EnvVars { get; init; }
        = new Dictionary<string, string>();

    /// <summary>PEM-encoded CA certificate to install into the guest.
    /// Same as <c>WslSessionConfig.BromureCaPem</c>.</summary>
    public byte[]? BromureCaPem { get; init; }

    /// <summary>Profile-configured shared folder paths. Each becomes a
    /// 9p share mounted at <c>/home/&lt;GuestUser&gt;/&lt;basename&gt;</c>.
    /// Same as <c>WslSessionConfig.SharedFolderPaths</c>.</summary>
    public IReadOnlyList<string> SharedFolderPaths { get; init; }
        = Array.Empty<string>();

    /// <summary>Pre-created warm VM from the pool. When set, the session
    /// adopts it instead of paying the create cost. Equivalent of
    /// <c>WslSessionConfig.WarmDistro</c>.</summary>
    public HcsVm? WarmVm { get; init; }

    /// <summary>Fires as soon as the VM's RuntimeId is known —
    /// i.e. right after <c>CreateAsync</c> returns, ~150ms into boot.
    /// Hosts use this to register the overlay/title hooks BEFORE the
    /// guest reaches its services that dial back, eliminating the
    /// chicken-and-egg where the guest's overlay-fetch blocks 28s
    /// waiting for the host to register the tar (Perf #2).</summary>
    public Action<Guid>? OnRuntimeIdResolved { get; init; }

    /// <summary>Perf #2: an externally-signalled boot-ready Task.
    /// When set, replaces the host→guest hvsocket dial poll (which
    /// pays a ~20-30 s built-in connect timeout the first time even
    /// when the service is up). Caller's typical pattern: complete
    /// this TCS from the overlay producer's invocation — the guest
    /// dials at ~+2 s post-VM-start, the producer fires synchronously
    /// on dial, signalling "guest is reachable".</summary>
    public Task? BootSignalTask { get; init; }

    /// <summary>Memory size for the VM (MB). 2048 default.</summary>
    public uint MemoryMB { get; init; } = 2048;

    /// <summary>VCPU count. 4 default.</summary>
    public int CpuCount { get; init; } = 4;

    /// <summary>First hvsocket port number for Plan9 shares. Subsequent
    /// shares increment from this. Default 50001.</summary>
    public uint Plan9StartPort { get; init; } = 50001;

    /// <summary>Hvsocket port the guest's Xvnc (TigerVNC) listens on.
    /// Default 5900 — the well-known RFB / VNC port; our WPF VNC
    /// client dials it via the host-side TCP→hvsocket bridge. Named
    /// <c>RdpPort</c> for backward-compat with code referring to the
    /// "RDP" embed even though we now speak RFB.</summary>
    public uint RdpPort { get; init; } = 5900;

    /// <summary>Hvsocket port the guest's boot-signal service writes
    /// the handshake byte to. Default 50100.</summary>
    public uint BootSignalPort { get; init; } = 50100;

    /// <summary>One-shot diagnostic: boot via <c>LinuxKernelDirect</c>
    /// (vmcompute loads kernel+initrd directly with our cmdline) instead
    /// of UEFI/grub. Lets us swap in a verbose serial console cmdline
    /// without re-baking. Production sessions stay on UEFI.</summary>
    public bool UseLinuxKernelDirect { get; init; }

    /// <summary>When true, the session attaches a NetworkAdapter (HCN
    /// endpoint on the named switch's HNS network). Guest gets a DHCP
    /// IP on the switch's subnet; the VNC client connects via that IP
    /// over plain TCP. Required because host→guest hvsocket SEND hangs
    /// on this Windows build.</summary>
    public bool UseNetworkAdapter { get; init; } = true;

    /// <summary>Name of the Hyper-V VMSwitch whose HNS network this
    /// session's NetworkAdapter binds to. Defaults to Windows'
    /// "Default Switch" — it has a built-in DHCP server (via the
    /// SharedAccess service) and a NAT subnet that Just Works. Our
    /// own "bromure-bake-net" switch is plain Internal+NAT without
    /// DHCP, so a guest there can't auto-config its IP.</summary>
    public string NetworkSwitchName { get; init; } = "Default Switch";

    /// <summary>
    /// Optional stable MAC for this session's NetworkAdapter (formatted
    /// <c>AA-BB-CC-DD-EE-FF</c>). When set, the session uses it
    /// verbatim instead of minting a random one — required for stable
    /// DHCP leases across launches. When null the legacy random-MAC
    /// behaviour applies. Sourced from
    /// <c>MacAddressBindings.GetOrCreate(profileId)</c>.
    /// </summary>
    public string? NetworkMacAddressOverride { get; init; }

    /// <summary>When set + file exists, <see cref="HcsSession.StartAsync"/>
    /// boots by resuming the saved CPU+RAM+device state instead of
    /// cold-booting. The 9p/overlay/CA staging phases are still
    /// performed (HCS attaches them on the create whether the VM
    /// boots fresh or resumes), but the kernel never re-runs init —
    /// systemd, kitty, the user's shell session all pick up where
    /// they left off. Pair with <see cref="HcsSession.SaveStateAsync"/>
    /// on the previous run.</summary>
    public string? SavedStateFilePath { get; init; }
}
