using System.Threading.Channels;

namespace Bromure.SandboxEngine.Wsl;

/// <summary>
/// Pre-imports one WSL distro from <c>bromure-base.tar.gz</c> in the
/// background so the user-visible launch path doesn't pay the
/// 8–15 s <c>wsl --import</c> cost. The pool keeps one distro
/// "ready" at a time; consuming it kicks off a top-up task that
/// imports the next one.
///
/// <para>Trade-off: one pre-imported distro consumes a sparse
/// <c>ext4.vhdx</c> on disk (typically 1–2 GB). For a coding tool
/// where users routinely have many GBs free, the latency win
/// outweighs the storage cost.</para>
///
/// <para>Distros from a prior run with a <c>bromure-warm-*</c> name
/// are reaped at startup by <see cref="WslDistro.ListAsync"/> +
/// <c>--unregister</c> so a crashed previous run doesn't leak
/// vhdx files indefinitely.</para>
/// </summary>
public sealed class WarmDistroPool : IAsyncDisposable
{
    public const string WarmNamePrefix = "bromure-warm-";

    private readonly Func<string> _baseRootfsPathProviderFn;
    private readonly string _poolRoot;
    private readonly Channel<WarmDistro> _ready;
    private readonly CancellationTokenSource _cts = new();
    private Task? _topper;
    private bool _disposed;

    /// <summary>
    /// <paramref name="baseRootfsPathProvider"/> is queried each
    /// top-up cycle so the pool tolerates rootfs rebuilds without
    /// restarting the app.
    /// </summary>
    public WarmDistroPool(Func<string> baseRootfsPathProvider, string poolRoot)
    {
        _baseRootfsPathProviderFn = baseRootfsPathProvider
            ?? throw new ArgumentNullException(nameof(baseRootfsPathProvider));
        _poolRoot = poolRoot;
        _ready = Channel.CreateBounded<WarmDistro>(new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = false,
            SingleWriter = true,
        });
    }

    /// <summary>Begin background pre-importing. Idempotent.</summary>
    public void Start()
    {
        if (_topper is not null) return;
        _topper = Task.Run(() => TopLoopAsync(_cts.Token));
    }

    /// <summary>
    /// Acquire a warm distro. Returns null if none is ready inside
    /// <paramref name="timeout"/> — caller falls back to a cold import.
    /// </summary>
    public async Task<WarmDistro?> AcquireAsync(TimeSpan timeout, CancellationToken ct)
    {
        if (_disposed) return null;
        using var to = CancellationTokenSource.CreateLinkedTokenSource(ct);
        to.CancelAfter(timeout);
        try
        {
            return await _ready.Reader.ReadAsync(to.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (ChannelClosedException)
        {
            return null;
        }
    }

    private async Task TopLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            string rootfs;
            try { rootfs = _baseRootfsPathProviderFn(); }
            catch { rootfs = ""; }
            if (string.IsNullOrEmpty(rootfs) || !File.Exists(rootfs))
            {
                // Wait for the rootfs to appear (user may be baking).
                try { await Task.Delay(TimeSpan.FromSeconds(5), ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                continue;
            }

            string name = WarmNamePrefix + Guid.NewGuid().ToString("N")[..8];
            string install = Path.Combine(_poolRoot, name);
            WslDistro distro;
            try
            {
                Directory.CreateDirectory(install);
                distro = new WslDistro(name, install);
                await distro.ImportAsync(rootfs, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return; }
            catch
            {
                // Import failed — could be a busy disk, WSL service
                // restart, or a corrupted rootfs. Back off and try
                // again so we don't spin.
                try { Directory.Delete(install, recursive: true); } catch { }
                try { await Task.Delay(TimeSpan.FromSeconds(10), ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                continue;
            }

            try
            {
                await _ready.Writer.WriteAsync(new WarmDistro(distro, install), ct)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Pool shutting down — best-effort unregister so the
                // pre-imported distro doesn't leak.
                try { await distro.UnregisterAsync().ConfigureAwait(false); } catch { }
                return;
            }
        }
    }

    /// <summary>
    /// Reap any <c>bromure-warm-*</c> distros from a prior run. Safe to
    /// call before <see cref="Start"/> — clears the slate so the new
    /// pool doesn't share install directories with a crashed predecessor.
    /// </summary>
    public static async Task CleanupOrphansAsync(CancellationToken ct = default)
    {
        IReadOnlyList<DistroInfo> existing;
        try { existing = await WslDistro.ListAsync(ct).ConfigureAwait(false); }
        catch { return; }
        var unregisterTasks = new List<Task>();
        foreach (var d in existing)
        {
            if (!d.Name.StartsWith(WarmNamePrefix, StringComparison.Ordinal)) continue;
            unregisterTasks.Add(Task.Run(async () =>
            {
                try
                {
                    var temp = new WslDistro(d.Name, Path.Combine(Path.GetTempPath(), d.Name));
                    await temp.UnregisterAsync(ct).ConfigureAwait(false);
                }
                catch { /* best-effort */ }
            }, ct));
        }
        try { await Task.WhenAll(unregisterTasks).ConfigureAwait(false); } catch { }
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
        // Drain + unregister anything the topper produced that hasn't
        // been claimed yet.
        while (_ready.Reader.TryRead(out var w))
        {
            try { await w.Distro.UnregisterAsync().ConfigureAwait(false); } catch { }
        }
        try { _cts.Dispose(); } catch { }
    }
}

/// <summary>One warm pre-imported distro waiting for a session to claim it.</summary>
public sealed record WarmDistro(WslDistro Distro, string InstallPath);
