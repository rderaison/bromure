// macos-source: Sources/SandboxEngine/VMPool.swift @ fe7e7d3a3e21
using System.Threading.Channels;

namespace Bromure.SandboxEngine.Hcs;

/// <summary>
/// Pre-creates one Bromure HCS VM in the background so the user-visible
/// launch path doesn't pay the VHDX-clone + HCS-create cost. The pool
/// keeps one VM "ready" at a time; consuming it kicks off a top-up
/// task that pre-creates the next.
///
/// <para>1:1 with <see cref="Wsl.WarmDistroPool"/> — same channel
/// semantics, same orphan-cleanup pattern, same trade-off (one
/// pre-created VHDX-child on disk in exchange for sub-second cold
/// start).</para>
///
/// <para>Pre-created VMs are created but NOT started — starting a VM
/// costs measurable RAM, and we don't want to pay it speculatively.
/// On adopt the warm VM is started by the session.</para>
/// </summary>
public sealed class WarmVmPool : IAsyncDisposable
{
    public const string WarmIdPrefix = "bromure-warm-";

    private readonly Func<BakeArtefacts> _templateProvider;
    private readonly string _poolRoot;
    private readonly Channel<WarmVm> _ready;
    private readonly CancellationTokenSource _cts = new();
    private Task? _topper;
    private bool _disposed;

    /// <summary>
    /// <paramref name="templateProvider"/> is queried each top-up cycle
    /// so the pool tolerates rebake-without-restart (caller swaps
    /// in a new <see cref="BakeArtefacts"/> path set on the next call).
    /// </summary>
    public WarmVmPool(Func<BakeArtefacts> templateProvider, string poolRoot)
    {
        _templateProvider = templateProvider
            ?? throw new ArgumentNullException(nameof(templateProvider));
        _poolRoot = poolRoot;
        _ready = Channel.CreateBounded<WarmVm>(new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = false,
            SingleWriter = true,
        });
    }

    /// <summary>Begin background pre-creation. Idempotent.</summary>
    public void Start()
    {
        if (_topper is not null) return;
        _topper = Task.Run(() => TopLoopAsync(_cts.Token));
    }

    /// <summary>Acquire a warm VM. Returns null if none is ready inside
    /// <paramref name="timeout"/> — caller falls back to a cold create.</summary>
    public async Task<WarmVm?> AcquireAsync(TimeSpan timeout, CancellationToken ct)
    {
        if (_disposed) return null;
        using var to = CancellationTokenSource.CreateLinkedTokenSource(ct);
        to.CancelAfter(timeout);
        try
        {
            return await _ready.Reader.ReadAsync(to.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { return null; }
        catch (ChannelClosedException) { return null; }
    }

    private async Task TopLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            BakeArtefacts template;
            try { template = _templateProvider(); }
            catch
            {
                try { await Task.Delay(TimeSpan.FromSeconds(5), ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                continue;
            }
            if (!File.Exists(template.BaseVhdxPath) ||
                !File.Exists(template.KernelPath) ||
                !File.Exists(template.InitrdPath))
            {
                try { await Task.Delay(TimeSpan.FromSeconds(5), ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                continue;
            }

            string id = WarmIdPrefix + Guid.NewGuid().ToString("N")[..8];
            string installPath = Path.Combine(_poolRoot, id);

            VhdxDisk? disk = null;
            HcsVm? vm = null;
            try
            {
                Directory.CreateDirectory(installPath);
                var diskPath = Path.Combine(installPath, "disk.vhdx");
                disk = new VhdxDisk(diskPath, template.BaseVhdxPath);
                await disk.CreateChildAsync(ct).ConfigureAwait(false);

                // Create-but-don't-start: keeps RAM cost ~0 for the warm
                // entry, while paying the VHDX-clone + schema validation
                // cost up front. Starting happens at adopt time.
                var cfg = new HcsVmConfig
                {
                    KernelPath = template.KernelPath,
                    InitrdPath = template.InitrdPath,
                    RootDiskPath = diskPath,
                    // Pass the parent so the worker process gets ACL
                    // access to it (HCS chain validation otherwise
                    // fails "chain inaccessible").
                    ParentDiskPath = template.BaseVhdxPath,
                    // No Plan9 shares yet — the session's per-tab shares
                    // are added via HcsModifyComputeSystem at adopt time.
                };
                vm = new HcsVm(id, cfg);
                await vm.CreateAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return; }
            catch
            {
                if (vm is not null) { try { await vm.DestroyAsync().ConfigureAwait(false); } catch { } }
                if (disk is not null) { try { await disk.DisposeAsync().ConfigureAwait(false); } catch { } }
                try { Directory.Delete(installPath, recursive: true); } catch { }
                try { await Task.Delay(TimeSpan.FromSeconds(10), ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                continue;
            }

            try
            {
                await _ready.Writer.WriteAsync(new WarmVm(vm, disk, installPath), ct)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                try { await vm.DestroyAsync().ConfigureAwait(false); } catch { }
                try { await disk.DisposeAsync().ConfigureAwait(false); } catch { }
                return;
            }
        }
    }

    /// <summary>Reap any <c>bromure-warm-*</c> VMs from a prior run. Safe
    /// to call before <see cref="Start"/>. Mirrors
    /// <see cref="Wsl.WarmDistroPool.CleanupOrphansAsync"/>.</summary>
    public static async Task CleanupOrphansAsync(string poolRoot, CancellationToken ct = default)
    {
        if (!Directory.Exists(poolRoot)) return;
        var ids = await HcsVm.ListByPrefixAsync(WarmIdPrefix, poolRoot, ct).ConfigureAwait(false);
        var tasks = new List<Task>();
        foreach (var id in ids)
        {
            tasks.Add(Task.Run(async () =>
            {
                try
                {
                    var diskPath = Path.Combine(poolRoot, id, "disk.vhdx");
                    var stubCfg = new HcsVmConfig
                    {
                        KernelPath = "<stub>", InitrdPath = "<stub>", RootDiskPath = diskPath,
                    };
                    var vm = new HcsVm(id, stubCfg);
                    await vm.DestroyAsync(ct).ConfigureAwait(false);
                }
                catch { /* best-effort */ }
                try { Directory.Delete(Path.Combine(poolRoot, id), recursive: true); } catch { }
            }, ct));
        }
        try { await Task.WhenAll(tasks).ConfigureAwait(false); } catch { }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        _cts.Cancel();
        try { _ready.Writer.TryComplete(); } catch { }
        if (_topper is not null)
        {
            try { await _topper.ConfigureAwait(false); } catch { }
        }
        while (_ready.Reader.TryRead(out var w))
        {
            try { await w.Vm.DestroyAsync().ConfigureAwait(false); } catch { }
            try { await w.Disk.DisposeAsync().ConfigureAwait(false); } catch { }
        }
        try { _cts.Dispose(); } catch { }
    }
}

/// <summary>Locator for the three artefacts a bake produces: the sealed
/// rootfs VHDX (the parent for differencing clones), the matched
/// Linux kernel, and the matched initramfs. The warm pool re-queries
/// this each top-up cycle so a rebake is picked up without restart.</summary>
public sealed record BakeArtefacts(
    string BaseVhdxPath, string KernelPath, string InitrdPath)
{
    /// <summary>Default discovery: assume all three files live in
    /// <paramref name="dir"/> with the canonical names produced by
    /// <see cref="VmBaker"/>.</summary>
    public static BakeArtefacts InDirectory(string dir) => new(
        Path.Combine(dir, VmBaker.OutputBaseFileName),
        Path.Combine(dir, VmBaker.OutputKernelFileName),
        Path.Combine(dir, VmBaker.OutputInitrdFileName));

    /// <summary>True if all three files exist on disk.</summary>
    public bool AllExist() =>
        File.Exists(BaseVhdxPath) &&
        File.Exists(KernelPath) &&
        File.Exists(InitrdPath);
}

/// <summary>One warm pre-created VM waiting for a session to claim it.</summary>
public sealed record WarmVm(HcsVm Vm, VhdxDisk Disk, string InstallPath);
