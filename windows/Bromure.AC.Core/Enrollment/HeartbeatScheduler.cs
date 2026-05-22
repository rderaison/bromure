// macos-source: Sources/AgentCoding/Enrollment.swift @ 841d4b4e44e2
namespace Bromure.AC.Core.Enrollment;

/// <summary>
/// Direct port of the heartbeat loop from <c>Enrollment.swift</c>.
/// Pings <c>/v1/installs/{installId}/heartbeat</c> at a fixed
/// interval (10 min default) so the admin dashboard shows the
/// install as "last seen N minutes ago" and the server can rotate
/// the leaf cert when its NotAfter approaches.
///
/// <para>Lifetime: started when the app finishes launching with a
/// valid install identity, stopped on app shutdown OR
/// <see cref="EnrollmentCoordinator.UnenrollAsync"/>. Errors are
/// swallowed (logged once per backoff cycle); the loop never
/// crashes the app.</para>
/// </summary>
public sealed class HeartbeatScheduler : IAsyncDisposable
{
    private readonly EnrollmentClient _client;
    private readonly EnrollmentStore _store;
    private CancellationTokenSource? _cts;
    private Task? _loop;

    public TimeSpan Interval { get; set; } = TimeSpan.FromMinutes(10);

    public HeartbeatScheduler(EnrollmentClient client, EnrollmentStore store)
    {
        _client = client;
        _store = store;
    }

    public void Start()
    {
        if (_cts is not null) return;
        _cts = new CancellationTokenSource();
        _loop = Task.Run(() => LoopAsync(_cts.Token));
    }

    public async ValueTask DisposeAsync()
    {
        if (_cts is null) return;
        try { _cts.Cancel(); } catch { }
        if (_loop is not null)
        {
            try { await _loop.ConfigureAwait(false); } catch { }
        }
        _cts.Dispose();
        _cts = null;
        _loop = null;
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await TickAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine("HeartbeatScheduler tick failed: " + ex);
            }
            try { await Task.Delay(Interval, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    /// <summary>Run a single heartbeat. Exposed for tests; the
    /// production path calls this from the loop on its own cadence.</summary>
    public async Task TickAsync(CancellationToken ct)
    {
        var install = _store.Load();
        var bearer = _store.LoadInstallToken();
        if (install is null || bearer is null) return;  // not enrolled, soft no-op
        await _client.HeartbeatAsync(install.InstallId, bearer, install.ServerUrl, ct)
            .ConfigureAwait(false);
    }
}

/// <summary>
/// Coordinator that owns the lifecycle of the enrollment-side
/// background work: heartbeat loop + unenroll path. Wired by the
/// host at app launch.
/// </summary>
public sealed class EnrollmentCoordinator : IAsyncDisposable
{
    private readonly EnrollmentClient _client;
    private readonly EnrollmentStore _store;
    private HeartbeatScheduler? _heartbeat;

    public EnrollmentCoordinator(EnrollmentClient client, EnrollmentStore store)
    {
        _client = client;
        _store = store;
    }

    /// <summary>Start the heartbeat loop iff the install is enrolled.
    /// Returns false when there's no install on disk yet (the
    /// EnrollmentSheet flow will call this again after enroll).</summary>
    public bool StartHeartbeat()
    {
        if (!_store.IsEnrolled) return false;
        _heartbeat ??= new HeartbeatScheduler(_client, _store);
        _heartbeat.Start();
        return true;
    }

    /// <summary>Tell the server we're gone, then wipe local state.
    /// Errors from the server call are logged but don't prevent
    /// local cleanup — leaving stale state on disk would let a
    /// reinstall hit "already enrolled" forever.</summary>
    public async Task UnenrollAsync(CancellationToken ct = default)
    {
        var install = _store.Load();
        var bearer = _store.LoadInstallToken();
        if (install is not null && bearer is not null)
        {
            try { await _client.UnenrollAsync(install.InstallId, bearer, install.ServerUrl, ct).ConfigureAwait(false); }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine("Server-side unenroll failed (continuing with local wipe): " + ex.Message);
            }
        }
        if (_heartbeat is not null)
        {
            try { await _heartbeat.DisposeAsync().ConfigureAwait(false); } catch { }
            _heartbeat = null;
        }
        _store.Destroy();
    }

    public async ValueTask DisposeAsync()
    {
        if (_heartbeat is not null)
        {
            try { await _heartbeat.DisposeAsync().ConfigureAwait(false); } catch { }
            _heartbeat = null;
        }
    }
}
