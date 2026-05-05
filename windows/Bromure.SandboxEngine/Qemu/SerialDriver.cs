using System.Net.Sockets;
using System.Text;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Qemu;

/// <summary>
/// Bidirectional version of <see cref="SerialConsoleClient"/>: connects
/// to QEMU's <c>-serial tcp:</c> server, exposes <see cref="SendAsync"/>
/// for typing into the guest and <see cref="WaitForAsync"/> for
/// expect-style line matching against the streamed serial output.
///
/// <para>Used by <see cref="Image.AlpineInstaller"/> to drive an Alpine
/// netboot installer over its login prompt — the macOS-port equivalent
/// of <c>VZFileHandleSerialPortAttachment</c> + an async read loop.</para>
/// </summary>
public sealed class SerialDriver : IAsyncDisposable
{
    private readonly string _host;
    private readonly int _port;
    private readonly ILogger _log;
    private readonly Action<string>? _onChunk;
    private readonly StringBuilder _buffer = new();
    private readonly object _bufferLock = new();
    private readonly CancellationTokenSource _cts = new();
    private TcpClient? _tcp;
    private NetworkStream? _stream;
    private Task? _readLoop;
    private const int BufferMaxBytes = 256 * 1024;

    /// <param name="endpoint">Host:port string matching <c>QemuConfig.SerialEndpoint</c>.</param>
    /// <param name="onChunk">Optional sink that receives every chunk read off
    /// the wire — typical use is to mirror the bake output to the host's
    /// progress UI. The driver also keeps an internal rolling buffer for
    /// <see cref="WaitForAsync"/> regardless.</param>
    public SerialDriver(string endpoint, Action<string>? onChunk = null, ILogger? log = null)
    {
        var lastColon = endpoint.LastIndexOf(':');
        if (lastColon < 0) throw new ArgumentException("Endpoint must be host:port", nameof(endpoint));
        _host = endpoint[..lastColon];
        _port = int.Parse(endpoint[(lastColon + 1)..], System.Globalization.CultureInfo.InvariantCulture);
        _onChunk = onChunk;
        _log = log ?? NullLogger.Instance;
    }

    public async Task ConnectAsync(TimeSpan connectTimeout, CancellationToken ct = default)
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
                _stream = _tcp.GetStream();
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

    /// <summary>Send literal bytes to the guest. The caller is responsible
    /// for the trailing <c>\n</c> when emulating an interactive line.</summary>
    public async Task SendAsync(string text, CancellationToken ct = default)
    {
        if (_stream is null) throw new InvalidOperationException("ConnectAsync first");
        var bytes = Encoding.UTF8.GetBytes(text);
        await _stream.WriteAsync(bytes, ct).ConfigureAwait(false);
        await _stream.FlushAsync(ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Poll the buffer until <paramref name="marker"/> appears or
    /// <paramref name="timeout"/> elapses or any of <paramref name="failures"/>
    /// shows up first. Returns the offset of the matched marker so callers
    /// can split the buffer or extract subsequent output.
    /// </summary>
    public async Task<int> WaitForAsync(string marker, TimeSpan timeout,
        IReadOnlyList<string>? failures = null, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            string snap;
            lock (_bufferLock) { snap = _buffer.ToString(); }

            if (failures is not null)
            {
                foreach (var f in failures)
                {
                    var idx = snap.IndexOf(f, StringComparison.Ordinal);
                    if (idx >= 0)
                    {
                        var line = snap[idx..].Split('\n').FirstOrDefault() ?? f;
                        throw new SerialFailureException(line.TrimEnd());
                    }
                }
            }

            var match = snap.IndexOf(marker, StringComparison.Ordinal);
            if (match >= 0) return match;

            await Task.Delay(100, ct).ConfigureAwait(false);
        }
        var tail = string.Empty;
        lock (_bufferLock)
        {
            var s = _buffer.ToString();
            tail = s.Length > 1024 ? s[^1024..] : s;
        }
        throw new TimeoutException(
            $"WaitFor('{marker}') timed out after {timeout.TotalSeconds:F0}s. Tail:\n{tail}");
    }

    private async Task ReadLoopAsync(CancellationToken ct)
    {
        if (_stream is null) return;
        var buf = new byte[16 * 1024];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var n = await _stream.ReadAsync(buf.AsMemory(), ct).ConfigureAwait(false);
                if (n == 0) break;
                var chunk = Encoding.UTF8.GetString(buf, 0, n);
                lock (_bufferLock)
                {
                    _buffer.Append(chunk);
                    if (_buffer.Length > BufferMaxBytes)
                    {
                        // Trim from the front; keep the recent tail —
                        // WaitFor matches against the latest bytes.
                        _buffer.Remove(0, _buffer.Length - BufferMaxBytes);
                    }
                }
                try { _onChunk?.Invoke(chunk); }
                catch (Exception ex)
                {
                    _log.LogDebug(ex, "serial onChunk subscriber threw");
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

public sealed class SerialFailureException : Exception
{
    public SerialFailureException(string line) : base(line) { }
}
