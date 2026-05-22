// macos-source: Sources/SandboxEngine/LinuxSandboxVM.swift @ fe7e7d3a3e21
using System.Text.Json;
using Bromure.SandboxEngine.Hcs.Native;

namespace Bromure.SandboxEngine.Hcs;

/// <summary>
/// One Hyper-V Compute Service VM = one Bromure session/tab.
///
/// <para><b>Architecture.</b> Replaces <see cref="Wsl.WslDistro"/>.
/// Each session gets its own VM with its own Linux kernel, its own
/// rootfs (a VHDX differencing-disk clone of <c>bromure-base.vhdx</c>),
/// its own network namespace, its own process tree. This is the
/// macOS-VZ-equivalent shape that WSL2 didn't give us — distros
/// shared the WSL utility VM's kernel.</para>
///
/// <para><b>Why use HCS direct rather than hcsshim/wsl.exe.</b>
/// Same reasoning as the WSL pivot: avoid out-of-process calls,
/// avoid argv quoting weirdness, avoid extra runtime dependencies.
/// HCS is a JSON-document API; we drive it from .NET via P/Invoke.</para>
///
/// <para><b>Disposal</b> calls <see cref="DestroyAsync"/>:
/// terminate + close handle. Delete the child VHDX, revoke VM access
/// to the parent. Idempotent.</para>
/// </summary>
public sealed class HcsVm : IAsyncDisposable
{
    /// <summary>The compute-system ID HCS uses to identify this VM.
    /// Bromure derives it as <c>bromure-ses-{8-hex}</c> for cold
    /// sessions and <c>bromure-warm-{8-hex}</c> for pool entries
    /// — same convention as the WSL port.</summary>
    public string Id { get; }

    private IntPtr _handle = IntPtr.Zero;
    private bool _started;
    private bool _disposed;
    private readonly HcsVmConfig _cfg;

    public HcsVm(string id, HcsVmConfig cfg)
    {
        if (string.IsNullOrWhiteSpace(id))
            throw new ArgumentException("Compute-system id required", nameof(id));
        Id = id;
        _cfg = cfg ?? throw new ArgumentNullException(nameof(cfg));
    }

    /// <summary>Status as HCS reports it.</summary>
    public enum State { NotCreated, Created, Running, Stopped }

    /// <summary>
    /// Create the VM (HCS allocates state + builds device tree) but
    /// don't start it yet. Idempotent against an existing handle.
    /// Equivalent to <c>WslDistro.ImportAsync</c> — the cost-equivalent
    /// step where the underlying VM container exists but no Linux
    /// kernel is running yet.
    /// </summary>
    public Task CreateAsync(CancellationToken ct = default)
        => Task.Run(() => CreateSync(), ct);

    private void CreateSync()
    {
        ThrowIfDisposed();
        if (_handle != IntPtr.Zero) return;

        // Grant the VM worker process access to the kernel + initrd +
        // VHDX paths we'll mount. Without this the worker hits
        // ACCESS_DENIED at boot and the VM never starts.
        foreach (var p in _cfg.HostPathsToGrant())
        {
            HcsApi.TryGrantVmAccess(Id, p);
        }

        var doc = HcsSchema.Serialize(_cfg.BuildSchema());
        IntPtr handle = IntPtr.Zero;
        // v2 ASYNC pattern. HcsCreateComputeSystem queues the work
        // against an operation handle; we block on
        // HcsWaitForOperationResult. The handle returned via the
        // out-parameter is only safe to use after the wait completes.
        int hr = HcsApi.RunOperation(op =>
            HcsApi.HcsCreateComputeSystem(Id, doc, op, IntPtr.Zero, out handle),
            out string? resultDoc);
        _handle = handle;

        if (hr == HcsApi.HCS_E_SYSTEM_ALREADY_EXISTS)
        {
            // Idempotency: a stale VM with our chosen ID is treated
            // as ours — open the existing handle. HcsOpenComputeSystem
            // is the only non-async HCS call (it's a handle-lookup,
            // doesn't queue work).
            int openHr = HcsApi.HcsOpenComputeSystem(Id, requestedAccess: 0, out _handle);
            if (openHr < 0)
            {
                throw new HcsException($"HcsOpenComputeSystem({Id})", openHr, null);
            }
            return;
        }
        if (hr < 0)
        {
            // Dump the request JSON next to the install path so the
            // operator can see exactly what vmcompute rejected.
            try
            {
                var dumpDir = Path.Combine(Path.GetTempPath(), "bromure-hcs-failure");
                Directory.CreateDirectory(dumpDir);
                var stamp = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss");
                File.WriteAllText(Path.Combine(dumpDir, $"{Id}-{stamp}.json"), doc);
                if (resultDoc is not null)
                    File.WriteAllText(Path.Combine(dumpDir, $"{Id}-{stamp}.result.json"), resultDoc);
            }
            catch { /* best-effort */ }
            throw new HcsException($"HcsCreateComputeSystem({Id})", hr, resultDoc);
        }
    }

    /// <summary>Start the VM (boot the kernel, run init). Returns when
    /// HCS reports the start operation has completed at the host
    /// level — which is BEFORE userspace is up. Caller is responsible
    /// for waiting on a guest-side health probe (hvsocket boot signal,
    /// 9p share readiness) before issuing commands.</summary>
    public Task StartAsync(CancellationToken ct = default)
        => Task.Run(() => StartSync(), ct);

    private void StartSync()
    {
        ThrowIfDisposed();
        if (_handle == IntPtr.Zero)
            throw new InvalidOperationException("VM not created. Call CreateAsync first.");
        var handle = _handle;
        int hr = HcsApi.RunOperation(op =>
            HcsApi.HcsStartComputeSystem(handle, op, options: null),
            out string? resultDoc);
        if (hr < 0) throw new HcsException($"HcsStartComputeSystem({Id})", hr, resultDoc);
        _started = true;
    }

    /// <summary>Query the compute system's properties. Returns the
    /// raw JSON document HCS produces — caller parses the bits it
    /// cares about (e.g. <c>RuntimeId</c> for hvsocket dial /
    /// mstsc /v:vmconnect://&lt;host&gt;/&lt;runtime-id&gt; URLs).
    /// <paramref name="propertyQuery"/> is an HCS PropertyQuery
    /// JSON, e.g. <c>{"PropertyTypes":["Basic"]}</c>; empty/null
    /// returns the default property bundle which already includes
    /// RuntimeId.</summary>
    public async Task<string?> GetPropertiesAsync(string? propertyQuery = null,
        CancellationToken ct = default)
    {
        ThrowIfDisposed();
        if (_handle == IntPtr.Zero)
            throw new InvalidOperationException("VM not created. Call CreateAsync first.");
        var handle = _handle;
        var query = propertyQuery;
        return await Task.Run(() =>
        {
            int hr = HcsApi.RunOperation(op =>
                HcsApi.HcsGetComputeSystemProperties(handle, op, query),
                out string? doc);
            if (hr < 0)
                throw new HcsException($"HcsGetComputeSystemProperties({Id})", hr, doc);
            return doc;
        }, ct).ConfigureAwait(false);
    }

    /// <summary>Suspend the running VM and write CPU+RAM+device state
    /// to <paramref name="savePath"/>. After this completes the VM is
    /// in the "Saved" state; we still close the handle (state lives on
    /// disk, not on the handle). To resume, create a fresh
    /// <see cref="HcsVm"/> with
    /// <see cref="HcsVmConfig.SavedStateFilePath"/> pointing at the
    /// same file and call <see cref="ResumeAsync"/>.</summary>
    public Task SaveAsync(string savePath, CancellationToken ct = default)
        => Task.Run(() => SaveSync(savePath), ct);

    private void SaveSync(string savePath)
    {
        ThrowIfDisposed();
        if (_handle == IntPtr.Zero) return;
        var saveDir = Path.GetDirectoryName(savePath)!;
        Directory.CreateDirectory(saveDir);
        // The VM worker (vmwp.exe) runs as a virtual-machine SID that
        // can't write to %LOCALAPPDATA% by default — HcsSaveComputeSystem
        // returns "Access is denied" without a grant. Grant on the
        // PARENT DIR so the new save file inherits the ACE and we don't
        // have to grant after the file exists. Pre-create the file to
        // give Windows something concrete to inherit onto — empty files
        // are fine; vmcompute truncates.
        if (!File.Exists(savePath))
        {
            try { File.WriteAllBytes(savePath, Array.Empty<byte>()); } catch { }
        }
        HcsApi.TryGrantVmAccess(Id, saveDir);
        HcsApi.TryGrantVmAccess(Id, savePath);
        var handle = _handle;

        // HCS rejects Save directly from Running ("invalid state") on
        // this Windows build — VM must be Paused first. Hcsshim has
        // the same ordering for its hibernate path.
        int hrPause = HcsApi.RunOperation(op =>
            HcsApi.HcsPauseComputeSystem(handle, op, options: null),
            out string? pauseDoc,
            timeoutMs: 30 * 1000);
        if (hrPause < 0)
            throw new HcsException($"HcsPauseComputeSystem({Id})", hrPause, pauseDoc);

        // Escape backslashes for JSON.
        var jsonPath = savePath.Replace("\\", "\\\\");
        var options = $"{{\"SaveType\":\"ToFile\",\"SaveStateFilePath\":\"{jsonPath}\"}}";
        int hr = HcsApi.RunOperation(op =>
            HcsApi.HcsSaveComputeSystem(handle, op, options),
            out string? resultDoc,
            // Save can take a while (RAM dump), so be patient — but
            // bound it so a wedged VM doesn't hang the UI thread.
            timeoutMs: 60 * 1000);
        if (hr < 0)
            throw new HcsException($"HcsSaveComputeSystem({Id})", hr, resultDoc);
        _started = false;
    }

    /// <summary>Resume a VM that was created with
    /// <see cref="HcsVmConfig.SavedStateFilePath"/> set. Counterpart of
    /// <see cref="StartAsync"/> for the hibernate path.</summary>
    public Task ResumeAsync(CancellationToken ct = default)
        => Task.Run(() => ResumeSync(), ct);

    private void ResumeSync()
    {
        ThrowIfDisposed();
        if (_handle == IntPtr.Zero)
            throw new InvalidOperationException("VM not created. Call CreateAsync first.");
        var handle = _handle;
        int hr = HcsApi.RunOperation(op =>
            HcsApi.HcsResumeComputeSystem(handle, op, options: null),
            out string? resultDoc);
        if (hr < 0)
            throw new HcsException($"HcsResumeComputeSystem({Id})", hr, resultDoc);
        _started = true;
    }

    /// <summary>Hard-stop the VM without destroying its state. Cheap.
    /// Equivalent to <c>wsl --terminate</c>.</summary>
    public Task TerminateAsync(CancellationToken ct = default)
        => Task.Run(() => TerminateSync(), ct);

    private void TerminateSync()
    {
        if (_disposed || _handle == IntPtr.Zero) return;
        var handle = _handle;
        int hr = HcsApi.RunOperation(op =>
            HcsApi.HcsTerminateComputeSystem(handle, op, options: null),
            out string? resultDoc);
        if (hr < 0 && hr != HcsApi.HCS_E_SYSTEM_NOT_FOUND)
        {
            throw new HcsException($"HcsTerminateComputeSystem({Id})", hr, resultDoc);
        }
        _started = false;
    }

    /// <summary>Destroy the VM completely — terminate, close handle,
    /// revoke disk access. Idempotent. Equivalent to
    /// <c>wsl --unregister</c> + delete-vhdx.</summary>
    public async Task DestroyAsync(CancellationToken ct = default)
    {
        if (_disposed) return;
        if (_started)
        {
            try { await TerminateAsync(ct).ConfigureAwait(false); }
            catch { /* best-effort */ }
        }
        if (_handle != IntPtr.Zero)
        {
            try { HcsApi.HcsCloseComputeSystem(_handle); } catch { }
            _handle = IntPtr.Zero;
        }
        // Revoke any grants we made — prevents the VM ID from holding a
        // stale ACL on the parent VHDX directory after the session ends.
        foreach (var p in _cfg.HostPathsToGrant())
        {
            try { HcsApi.TryRevokeVmAccess(Id, p); } catch { }
        }
    }

    /// <summary>List Bromure-owned VMs HCS currently knows about. Used
    /// by <see cref="WarmVmPool.CleanupOrphansAsync"/> at startup to
    /// reap pool entries from a crashed previous run. Implementation
    /// note: HCS doesn't expose a "list all" API; we enumerate by
    /// trying to open compute systems by ID. Callers track names in
    /// the install directory tree (one folder per VM).</summary>
    public static async Task<IReadOnlyList<string>> ListByPrefixAsync(
        string prefix, string poolRoot, CancellationToken ct = default)
    {
        if (!Directory.Exists(poolRoot)) return Array.Empty<string>();
        return await Task.Run(() =>
        {
            var ids = new List<string>();
            foreach (var dir in Directory.EnumerateDirectories(poolRoot))
            {
                var name = Path.GetFileName(dir);
                if (!name.StartsWith(prefix, StringComparison.Ordinal)) continue;
                ids.Add(name);
            }
            return (IReadOnlyList<string>)ids;
        }, ct).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        await DestroyAsync().ConfigureAwait(false);
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(HcsVm));
    }
}

/// <summary>Inputs for a single <see cref="HcsVm"/>. Caller is responsible
/// for building paths (kernel, initrd, VHDX child, plan9 share dirs)
/// and choosing hvsocket ports.</summary>
public sealed record HcsVmConfig
{
    /// <summary>Path to the Linux kernel (vmlinuz). UNUSED on the
    /// current UEFI-boot path — grub on the VHDX's EFI partition
    /// loads its own kernel from /boot. Kept on the config record
    /// for backward-compat with code paths that still resolve it
    /// (WarmVmPool, HcsSession); they pass through artefacts the
    /// bake produced even though the firmware doesn't read them.</summary>
    public string? KernelPath { get; init; }

    /// <summary>Same as <see cref="KernelPath"/> — kept on the
    /// config record but unused with UEFI boot.</summary>
    public string? InitrdPath { get; init; }

    /// <summary>Kernel command line — unused with UEFI boot. grub
    /// gets its cmdline from the in-VHDX /etc/default/grub +
    /// /boot/grub/grub.cfg the bake's grub-install produced. Kept
    /// for parity with the LinuxKernelDirect path.</summary>
    public string KernelCmdLine { get; init; } =
        "console=ttyS0 root=/dev/sda rw rootfstype=ext4 init=/lib/systemd/systemd quiet";

    /// <summary>Per-session VHDX (differencing child of bromure-base.vhdx).
    /// Becomes /dev/sda inside the guest.</summary>
    public required string RootDiskPath { get; init; }

    /// <summary>Parent VHDX <see cref="RootDiskPath"/> differences
    /// from. VHDX differencing disks chain — the VM worker must
    /// be granted ACL access to BOTH the child and its parent or
    /// HCS returns "the chain of virtual hard disks is inaccessible"
    /// at VM-create time. Null if <see cref="RootDiskPath"/> isn't
    /// a differencing disk.</summary>
    public string? ParentDiskPath { get; init; }

    /// <summary>Megabytes of guest RAM. 2 GB default keeps cold-start
    /// memory pressure modest while leaving room for kitty + the agent
    /// CLI + a typical Node toolchain.</summary>
    public uint MemoryMB { get; init; } = 2048;

    /// <summary>Logical CPU count. 4 is a reasonable default on modern
    /// dev hardware; HCS will share with the host scheduler.</summary>
    public int CpuCount { get; init; } = 4;

    /// <summary>Plan9 shares to expose. Each entry becomes a 9p mount
    /// inside the guest. Keys: logical mount tag (e.g. "home-overlay",
    /// "shared-Downloads"). Values: <see cref="Plan9ShareSpec"/>.</summary>
    public IReadOnlyDictionary<string, Plan9ShareSpec> Plan9Shares { get; init; }
        = new Dictionary<string, Plan9ShareSpec>(StringComparer.Ordinal);

    /// <summary>Optional Windows named-pipe path for COM1. When set,
    /// guest kernel + systemd serial output streams to
    /// <c>\\.\pipe\&lt;name&gt;</c>. The pipe name is the leaf, e.g.
    /// "bromure-ses-1234-com1"; we route through the standard
    /// Hyper-V named-pipe ComPort plumbing. Caller is responsible
    /// for opening / reading the pipe.</summary>
    public string? ComPort1PipeName { get; init; }

    /// <summary>HvSocket ports the guest can bind/listen on. The Bromure
    /// agent uses one for the boot signal; weston-rdp uses another for
    /// the user-visible RDP session. Each entry becomes an
    /// <c>HvSocketServiceConfig</c> in the schema.</summary>
    public IReadOnlyList<uint> HvSocketPorts { get; init; } = Array.Empty<uint>();

    /// <summary>When true, boot via <c>LinuxKernelDirect</c> using
    /// <see cref="KernelPath"/> + <see cref="InitrdPath"/> + <see cref="KernelCmdLine"/>
    /// instead of UEFI/grub. Skips the EFI firmware entirely — useful
    /// for one-shot diagnostic boots where you need the cmdline you
    /// control (verbose serial console, custom init) without re-baking
    /// the VHDX's grub.cfg. Production boots stay on UEFI so the bake's
    /// GRUB cmdline (with the kernel modules it picked) drives.</summary>
    public bool UseLinuxKernelDirect { get; init; }

    /// <summary>When set, the compute system is created with
    /// <c>VirtualMachine.RestoreState.SavedStateFilePath</c> pointing
    /// here and the caller is expected to follow up with
    /// <see cref="HcsVm.ResumeAsync"/> instead of
    /// <see cref="HcsVm.StartAsync"/>. The file is whatever an earlier
    /// <see cref="HcsVm.SaveAsync"/> wrote.</summary>
    public string? SavedStateFilePath { get; init; }

    /// <summary>Optional HCN endpoint GUID + MAC. When set, the VM gets
    /// a NIC bound to the endpoint's HNS network at boot. Used to give
    /// session VMs an IP on the host's "bromure-bake-net" NAT subnet so
    /// the WPF VNC client can reach the guest over plain TCP (working
    /// around the host→guest hvsocket SEND issue).</summary>
    public Guid NetworkEndpointId { get; init; }
    public string? NetworkMacAddress { get; init; }

    /// <summary>Host paths that the VM worker process needs ACL access to
    /// (granted via <see cref="HcsApi.HcsGrantVmAccess"/>). UEFI boot
    /// reads the root VHDX (and, for differencing disks, every
    /// parent in the chain — without the parent grant HCS errors
    /// with "the chain of virtual hard disks is inaccessible" at
    /// VM-create time), plus any 9p share roots.</summary>
    public IEnumerable<string> HostPathsToGrant()
    {
        yield return RootDiskPath;
        if (!string.IsNullOrEmpty(ParentDiskPath))
        {
            yield return ParentDiskPath;
        }
        if (UseLinuxKernelDirect)
        {
            // vmcompute's worker process needs to read these from disk
            // at VM-create time. Without the grant, HCS returns
            // 0x80370102 (access denied) on Start.
            if (!string.IsNullOrEmpty(KernelPath)) yield return KernelPath;
            if (!string.IsNullOrEmpty(InitrdPath)) yield return InitrdPath;
        }
        foreach (var s in Plan9Shares.Values)
        {
            if (!string.IsNullOrEmpty(s.HostPath)) yield return s.HostPath;
        }
    }

    /// <summary>Build the v2 HCS schema document for this VM.</summary>
    internal HcsSchema.ComputeSystem BuildSchema()
    {
        var devices = new HcsSchema.Devices
        {
            // SCSI controller key: "primary". WSL2's utility VM and
            // Windows Sandbox both use this string — `wsl --list`
            // enumerates our bromure-* HCS systems alongside its
            // own distros, so vmcompute treats them as the same
            // class and the same controller-key convention applies.
            // The earlier "0" key was a guess that didn't match
            // either the schema reference or the working precedent.
            Scsi = new Dictionary<string, HcsSchema.Scsi>(StringComparer.Ordinal)
            {
                ["primary"] = new HcsSchema.Scsi
                {
                    Attachments = new Dictionary<string, HcsSchema.ScsiAttachment>
                    {
                        ["0"] = new HcsSchema.ScsiAttachment
                        {
                            Type = "VirtualDisk",
                            Path = RootDiskPath,
                        },
                    },
                },
            },
            Plan9 = Plan9Shares.Count == 0 ? null : new HcsSchema.Plan9
            {
                Shares = Plan9Shares.Select(kvp => new HcsSchema.Plan9Share
                {
                    Name = kvp.Key,
                    AccessName = kvp.Value.MountTag ?? kvp.Key,
                    Path = kvp.Value.HostPath,
                    Port = kvp.Value.Port,
                    // Flags = 6 (LinuxMetadata|CaseSensitive). WSL2's
                    // /mnt/c plan9 share emits exactly this combo;
                    // the ReadOnly bit in Flags is redundant with
                    // (and may conflict against) the separate
                    // ReadOnly bool.
                    Flags = HcsSchema.Plan9Flags.LinuxMetadata
                          | HcsSchema.Plan9Flags.CaseSensitive,
                    ReadOnly = kvp.Value.ReadOnly,
                }).ToList(),
            },
            ComPorts = string.IsNullOrEmpty(ComPort1PipeName) ? null :
                new Dictionary<string, HcsSchema.ComPort>(StringComparer.Ordinal)
                {
                    // COM1 — Ubuntu cloud-image kernels boot with
                    // console=ttyS0 by default, so kernel + systemd
                    // output streams here.
                    ["0"] = new HcsSchema.ComPort
                    {
                        NamedPipe = "\\\\.\\pipe\\" + ComPort1PipeName,
                    },
                },
            NetworkAdapters = NetworkEndpointId == Guid.Empty ? null
                : new Dictionary<string, HcsSchema.NetworkAdapter>(StringComparer.Ordinal)
                {
                    ["primary"] = new HcsSchema.NetworkAdapter
                    {
                        EndpointId = NetworkEndpointId.ToString("D"),
                        MacAddress = NetworkMacAddress,
                    },
                },
            HvSocket = HvSocketPorts.Count == 0 ? null : new HcsSchema.HvSocket
            {
                HvSocketConfig = new HcsSchema.HvSocketSystemConfig
                {
                    // SDDL "DACL Protected, Allow Full Access to
                    // Everyone" on both Bind + Connect. Without
                    // these, the hvsocket service slot accepts the
                    // schema (create succeeds) but rejects every
                    // inbound connect from the host with WSAEACCES.
                    // hcsshim's WSL2 utility VM sets the same default.
                    DefaultBindSecurityDescriptor    = "D:P(A;;FA;;;WD)",
                    DefaultConnectSecurityDescriptor = "D:P(A;;FA;;;WD)",
                    ServiceTable = HvSocketPorts.ToDictionary(
                        p => HvSocketApi.ServiceIdFromPort(p).ToString("D"),
                        _ => new HcsSchema.HvSocketServiceConfig { AllowWildcardBinds = true },
                        StringComparer.Ordinal),
                },
            },
        };

        return new HcsSchema.ComputeSystem
        {
            // Shape matches WSL2's utility VM (which co-resides with
            // our bromure-* compute systems in vmcompute's view —
            // `wsl --list` lists them all). ShouldTerminateOnLastHandleClosed
            // = true means the VM auto-destroys if we crash without
            // calling Terminate, which is the polite default.
            Owner = "Bromure",
            SchemaVersion = new HcsSchema.SchemaVersion { Major = 2, Minor = 5 },
            ShouldTerminateOnLastHandleClosed = true,
            VirtualMachine = new HcsSchema.VirtualMachine
            {
                StopOnReset = true,
                Chipset = UseLinuxKernelDirect
                    ? new HcsSchema.Chipset
                    {
                        // Direct kernel boot — vmcompute loads our
                        // vmlinuz + initrd into guest RAM, passes the
                        // cmdline, and jumps to the kernel entry point.
                        // No EFI, no GRUB. Same shape WSL2's utility
                        // VM uses; matches hcsshim's LCOW path.
                        LinuxKernelDirect = new HcsSchema.LinuxKernelDirect
                        {
                            KernelFilePath = KernelPath,
                            InitRdPath = InitrdPath,
                            KernelCmdLine = KernelCmdLine,
                        },
                    }
                    : new HcsSchema.Chipset
                    {
                        Uefi = new HcsSchema.Uefi
                        {
                            // "Skip" tells the firmware to bypass Secure
                            // Boot validation entirely — Ubuntu's grub
                            // signature chain isn't in Hyper-V's UEFI
                            // keystore. WSL2's utility VM sets the same.
                            ApplySecureBootTemplate = "Skip",
                            BootThis = new HcsSchema.UefiBootEntry
                            {
                                DeviceType = "ScsiDrive",
                                DiskNumber = 0,
                            },
                        },
                    },
                ComputeTopology = new HcsSchema.ComputeTopology
                {
                    Memory = new HcsSchema.Memory
                    {
                        SizeInMB = MemoryMB,
                        AllowOvercommit = true,
                    },
                    Processor = new HcsSchema.Processor { Count = CpuCount },
                },
                Devices = devices,
                RestoreState = string.IsNullOrEmpty(SavedStateFilePath) ? null
                    : new HcsSchema.RestoreState
                    {
                        SavedStateFilePath = SavedStateFilePath,
                        TemplateMemory = false,
                    },
            },
        };
    }
}

/// <summary>One 9p share configured on the VM. Caller picks the host
/// directory and the hvsocket port; HCS's built-in Plan9 server
/// handles the protocol — Linux's v9fs.ko mounts it.</summary>
public sealed record Plan9ShareSpec(
    string HostPath,
    uint Port,
    string? MountTag = null,
    bool ReadOnly = false);
