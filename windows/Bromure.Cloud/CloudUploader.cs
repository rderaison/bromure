using System.Net.Http;
using System.Net.Http.Json;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.Cloud;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/CloudUploader.swift</c>.
///
/// <para>Batches <see cref="CloudEvent"/>s and POSTs them to the
/// analytics service's <c>/ac-ingest</c> endpoint over mTLS. The install
/// authenticates with the leaf cert issued from the workspace's org CA
/// — no bearer token rides with the data.</para>
///
/// <para>In-memory only: dropping buffered events on a hard quit is fine
/// for telemetry, and a disk-backed retry queue is a Phase 3c-or-later
/// problem. Up to 200 events / 5 s in flight at once. Failures are
/// logged but don't drop the buffer — the next flush retries the whole
/// batch.</para>
/// </summary>
public sealed class CloudUploader : IAsyncDisposable
{
    /// Cap matching the server-side <c>MAX_EVENTS_PER_BATCH</c>.
    /// Bumping this requires bumping the server too.
    private const int MaxBatch = 500;
    /// Auto-flush threshold — when pending hits this, kick a flush
    /// without waiting for the timer.
    private const int FlushHighWatermark = 200;
    /// Periodic flush interval. Long enough that a Claude turn that
    /// fires 5 events bundles them into one POST; short enough that
    /// the admin UI feels live.
    private static readonly TimeSpan FlushInterval = TimeSpan.FromSeconds(5);

    private readonly Uri _endpoint;
    private readonly HttpClient _client;
    private readonly ILogger _log;
    private readonly object _gate = new();
    private readonly List<CloudEvent> _pending = new();
    private CancellationTokenSource? _cts;
    private Task? _flushLoop;
    private bool _stopped;

    public CloudUploader(Uri endpoint, ICloudMtlsIdentity mtls, ILogger? log = null)
    {
        _endpoint = endpoint;
        _log = log ?? NullLogger.Instance;

        // Hook the SocketsHttpHandler's TLS callback to present the
        // mTLS identity when the server requests a client cert.
        var handler = new SocketsHttpHandler
        {
            SslOptions = new SslClientAuthenticationOptions
            {
                ClientCertificates = mtls.ClientCertificates,
                LocalCertificateSelectionCallback = (_, _, _, _, _) => mtls.SelectCertificate()!,
            },
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };

        _cts = new CancellationTokenSource();
        _flushLoop = Task.Run(() => FlushLoopAsync(_cts.Token));
    }

    public void Enqueue(CloudEvent ev)
    {
        bool kick;
        int dropped = 0;
        lock (_gate)
        {
            _pending.Add(ev);
            kick = _pending.Count >= FlushHighWatermark;
            // Hard cap at 4× MaxBatch — drop the oldest half on a long outage.
            var drainCap = MaxBatch * 4;
            if (_pending.Count > drainCap)
            {
                dropped = _pending.Count - drainCap / 2;
                _pending.RemoveRange(0, dropped);
            }
        }
        if (dropped > 0) _log.LogWarning("[cloud] dropped {N} events (over cap)", dropped);
        if (kick) _ = Task.Run(FlushNowAsync);
    }

    public async Task FlushNowAsync()
    {
        List<CloudEvent> batch;
        bool stopped;
        lock (_gate)
        {
            stopped = _stopped;
            batch = _pending.Count == 0
                ? new List<CloudEvent>()
                : _pending.GetRange(0, Math.Min(_pending.Count, MaxBatch));
        }
        if (stopped || batch.Count == 0) return;

        try
        {
            await PostBatchAsync(batch).ConfigureAwait(false);
            lock (_gate)
            {
                _pending.RemoveRange(0, Math.Min(_pending.Count, batch.Count));
            }
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "[cloud] flush of {N} events failed", batch.Count);
            // Leave _pending intact for the next flush.
        }
    }

    private async Task PostBatchAsync(List<CloudEvent> events)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, _endpoint);
        var bodyJson = JsonSerializer.Serialize(new { events });
        req.Content = new StringContent(bodyJson, System.Text.Encoding.UTF8, "application/json");
        using var resp = await _client.SendAsync(req).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            throw new HttpRequestException($"HTTP {(int)resp.StatusCode}");
        }
    }

    private async Task FlushLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(FlushInterval, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            await FlushNowAsync().ConfigureAwait(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        lock (_gate) _stopped = true;
        try { _cts?.Cancel(); } catch { }
        if (_flushLoop is not null)
        {
            try { await _flushLoop.ConfigureAwait(false); } catch { }
        }
        _cts?.Dispose();
        _client.Dispose();
    }
}

/// <summary>
/// Provides the install's mTLS leaf cert + the selection callback for
/// SocketsHttpHandler. Direct port of the macOS <c>BACMTLSIdentity</c>
/// abstraction.
/// </summary>
public interface ICloudMtlsIdentity
{
    X509CertificateCollection ClientCertificates { get; }
    X509Certificate? SelectCertificate();
}
