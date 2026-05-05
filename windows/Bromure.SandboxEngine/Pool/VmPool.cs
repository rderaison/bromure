using System.Collections.Concurrent;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Pool;

/// <summary>
/// Pre-warms <see cref="DesiredWarmCount"/> VMs so a "new browser/AC
/// window" claim resolves in &lt;1 s. Mirrors <c>VMPool</c> on macOS:
/// when a VM is claimed, immediately start warming a replacement.
///
/// <para>The pool is a pure state machine; the host just plugs in a
/// "factory" delegate that knows how to actually boot a VM.</para>
/// </summary>
public sealed class VmPool<T> : IAsyncDisposable where T : class, IAsyncDisposable
{
    private readonly Func<CancellationToken, Task<T>> _factory;
    private readonly ILogger _log;
    private readonly ConcurrentQueue<T> _warm = new();
    private readonly SemaphoreSlim _slots;
    private readonly CancellationTokenSource _cts = new();
    private int _warming;

    public VmPool(int desiredWarmCount, Func<CancellationToken, Task<T>> factory, ILogger? log = null)
    {
        if (desiredWarmCount <= 0) throw new ArgumentOutOfRangeException(nameof(desiredWarmCount));
        DesiredWarmCount = desiredWarmCount;
        _factory = factory;
        _log = log ?? NullLogger.Instance;
        _slots = new SemaphoreSlim(0, int.MaxValue);
    }

    public int DesiredWarmCount { get; }
    public int WarmCount => _warm.Count;

    /// <summary>Kick off an initial round of warming. Call once after construction.</summary>
    public void Start()
    {
        for (var i = 0; i < DesiredWarmCount; i++) ScheduleWarming();
    }

    /// <summary>
    /// Take the next warm VM, blocking until one is ready (or
    /// <paramref name="ct"/> fires). Schedules a replacement immediately.
    /// </summary>
    public async Task<T> ClaimAsync(CancellationToken ct = default)
    {
        await _slots.WaitAsync(ct).ConfigureAwait(false);
        if (!_warm.TryDequeue(out var vm))
        {
            throw new InvalidOperationException("Pool reported a warm VM but couldn't dequeue it");
        }
        ScheduleWarming();
        return vm;
    }

    private void ScheduleWarming()
    {
        Interlocked.Increment(ref _warming);
        _ = Task.Run(async () =>
        {
            try
            {
                var vm = await _factory(_cts.Token).ConfigureAwait(false);
                if (_cts.IsCancellationRequested)
                {
                    await vm.DisposeAsync().ConfigureAwait(false);
                    return;
                }
                _warm.Enqueue(vm);
                _slots.Release();
            }
            catch (OperationCanceledException) { /* shutting down */ }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Warm-VM factory threw; pool will retry in 2s");
                await Task.Delay(2000).ConfigureAwait(false);
                if (!_cts.IsCancellationRequested) ScheduleWarming();
            }
            finally
            {
                Interlocked.Decrement(ref _warming);
            }
        });
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        while (_warm.TryDequeue(out var vm))
        {
            try { await vm.DisposeAsync().ConfigureAwait(false); } catch { }
        }
        _cts.Dispose();
        _slots.Dispose();
    }
}
