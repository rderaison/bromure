using System.Net.Sockets;
using System.Text;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Qemu;

/// <summary>
/// Connects to QEMU's <c>-serial tcp:host:port,server=on</c> socket and
/// streams the guest's serial console output back to a delegate. QEMU
/// is the listener (<c>server=on</c>) so we connect; we don't write
/// anything (input forwarding is a follow-up; this is a one-way debug
/// aid for now).
/// </summary>
public sealed class SerialConsoleClient : IAsyncDisposable
{
    private readonly string _host;
    private readonly int _port;
    private readonly ILogger _log;
    private readonly Action<string> _onChunk;
    private readonly CancellationTokenSource _cts = new();
    private TcpClient? _tcp;
    private Task? _readLoop;

    public SerialConsoleClient(string endpoint, Action<string> onChunk, ILogger? log = null)
    {
        var lastColon = endpoint.LastIndexOf(':');
        if (lastColon < 0) throw new ArgumentException("Endpoint must be host:port", nameof(endpoint));
        _host = endpoint[..lastColon];
        _port = int.Parse(endpoint[(lastColon + 1)..], System.Globalization.CultureInfo.InvariantCulture);
        _onChunk = onChunk;
        _log = log ?? NullLogger.Instance;
    }

    /// <summary>
    /// Start a background reader. Retries the connect for up to
    /// <paramref name="connectTimeout"/> — QEMU opens the listener
    /// slightly after process start, same as QMP.
    /// </summary>
    public async Task StartAsync(TimeSpan connectTimeout, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow + connectTimeout;
        Exception? last = null;
        var delay = TimeSpan.FromMilliseconds(50);
        while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
        {
            try
            {
                _tcp = new TcpClient();
                await _tcp.ConnectAsync(_host, _port, ct).ConfigureAwait(false);
                _readLoop = Task.Run(() => ReadLoopAsync(_cts.Token));
                return;
            }
            catch (Exception ex) when (ex is SocketException or IOException)
            {
                last = ex;
                _tcp?.Dispose();
                _tcp = null;
                await Task.Delay(delay, ct).ConfigureAwait(false);
                delay = TimeSpan.FromMilliseconds(Math.Min(delay.TotalMilliseconds * 1.5, 500));
            }
        }
        throw new TimeoutException(
            $"Could not attach to serial console at {_host}:{_port}", last);
    }

    private async Task ReadLoopAsync(CancellationToken ct)
    {
        if (_tcp is null) return;
        var buffer = new byte[16 * 1024];
        try
        {
            await using var stream = _tcp.GetStream();
            while (!ct.IsCancellationRequested)
            {
                var n = await stream.ReadAsync(buffer.AsMemory(), ct).ConfigureAwait(false);
                if (n == 0) break;
                // Decode as UTF-8 with replacement on bad bytes — kernel
                // logs are 7-bit-clean, but the boot loader may emit
                // box-drawing or non-ASCII bytes that we don't want to
                // crash on.
                var chunk = Encoding.UTF8.GetString(buffer, 0, n);
                try { _onChunk(chunk); }
                catch (Exception ex)
                {
                    _log.LogDebug(ex, "serial console subscriber threw");
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (SocketException) { }
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts.Cancel(); } catch { }
        try { _tcp?.Close(); } catch { }
        if (_readLoop is not null)
        {
            try { await _readLoop.ConfigureAwait(false); } catch { }
        }
        _cts.Dispose();
        _tcp?.Dispose();
    }
}
