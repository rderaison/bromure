using System.Buffers;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Vsock;

/// <summary>
/// Host-side endpoint of the guest's <c>AF_VSOCK</c> connections.
///
/// On macOS, <c>VZVirtioSocketDevice</c> + <c>VZVirtioSocketListener</c>
/// hand the host a callback for every guest <c>connect(VMADDR_CID_HOST, port)</c>.
/// QEMU's <c>vhost-vsock-pci</c> device exposes the host endpoint as either
/// a UNIX domain socket (Linux/macOS) or — via QEMU's
/// <c>-chardev socket</c> + a small accept loop — a TCP listener bound
/// to localhost on a per-port basis.
///
/// We keep the wire format identical to the macOS bridges
/// (<c>SubscriptionTokenBridge</c>, <c>CodexTokenBridge</c>): newline-
/// delimited JSON. The bridge multiplexes per-port handlers; each port
/// becomes its own Windows named pipe, so callers consume them with the
/// same shape they'd use for a vsock listener.
/// </summary>
public sealed class VsockBridge : IAsyncDisposable
{
    private readonly ILogger _log;
    private readonly Dictionary<uint, PortListener> _listeners = new();
    private readonly object _gate = new();

    public VsockBridge(ILogger? log = null) => _log = log ?? NullLogger.Instance;

    /// <summary>
    /// Register a per-port handler. <paramref name="onConnection"/> is invoked
    /// for every accepted guest connection on <paramref name="port"/>.
    ///
    /// The returned <see cref="Stream"/> in <paramref name="onConnection"/>
    /// is full-duplex: the bridge handles connect/accept and routing.
    /// </summary>
    public void Listen(uint port, Func<Stream, CancellationToken, Task> onConnection)
    {
        lock (_gate)
        {
            if (_listeners.ContainsKey(port))
            {
                throw new InvalidOperationException($"Port {port} already has a listener");
            }
            var pipeName = $"bromure-ac-vsock-{port}";
            var listener = new PortListener(port, pipeName, onConnection, _log);
            _listeners[port] = listener;
            listener.Start();
        }
    }

    /// <summary>
    /// Symmetric: tear down the listener on this port. Existing connections
    /// are not forcibly closed (handlers own their lifetime).
    /// </summary>
    public async ValueTask StopListeningAsync(uint port)
    {
        PortListener? listener;
        lock (_gate)
        {
            _listeners.Remove(port, out listener);
        }
        if (listener is not null)
        {
            await listener.DisposeAsync().ConfigureAwait(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        PortListener[] listeners;
        lock (_gate)
        {
            listeners = _listeners.Values.ToArray();
            _listeners.Clear();
        }
        foreach (var l in listeners)
        {
            await l.DisposeAsync().ConfigureAwait(false);
        }
    }

    /// <summary>
    /// One named-pipe server per registered port. We accept connections
    /// in a loop and dispatch each to <see cref="_handler"/> on a Task.
    /// </summary>
    private sealed class PortListener : IAsyncDisposable
    {
        private readonly uint _port;
        private readonly string _pipeName;
        private readonly Func<Stream, CancellationToken, Task> _handler;
        private readonly CancellationTokenSource _cts = new();
        private readonly ILogger _log;
        private Task? _acceptLoop;

        public PortListener(uint port, string pipeName, Func<Stream, CancellationToken, Task> handler, ILogger log)
        {
            _port = port;
            _pipeName = pipeName;
            _handler = handler;
            _log = log;
        }

        public string PipeName => _pipeName;

        public void Start()
        {
            _acceptLoop = Task.Run(() => AcceptLoopAsync(_cts.Token));
        }

        private async Task AcceptLoopAsync(CancellationToken ct)
        {
            while (!ct.IsCancellationRequested)
            {
                NamedPipeServerStream? server = null;
                try
                {
                    server = new NamedPipeServerStream(
                        _pipeName,
                        PipeDirection.InOut,
                        maxNumberOfServerInstances: NamedPipeServerStream.MaxAllowedServerInstances,
                        PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous);
                    await server.WaitForConnectionAsync(ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    server?.Dispose();
                    return;
                }
                catch (IOException ex)
                {
                    _log.LogWarning(ex, "Accept failed on port {Port}, retrying", _port);
                    server?.Dispose();
                    await Task.Delay(50, ct).ConfigureAwait(false);
                    continue;
                }

                var pipe = server;
                _ = Task.Run(async () =>
                {
                    try
                    {
                        await _handler(pipe, ct).ConfigureAwait(false);
                    }
                    catch (Exception ex)
                    {
                        _log.LogWarning(ex, "Vsock handler on port {Port} threw", _port);
                    }
                    finally
                    {
                        try { pipe.Dispose(); } catch { }
                    }
                });
            }
        }

        public async ValueTask DisposeAsync()
        {
            _cts.Cancel();
            if (_acceptLoop is not null)
            {
                try { await _acceptLoop.ConfigureAwait(false); } catch { }
            }
            _cts.Dispose();
        }
    }
}

/// <summary>
/// Helpers for the newline-delimited-JSON framing that
/// <c>SubscriptionTokenBridge</c> and <c>CodexTokenBridge</c> use on macOS.
/// </summary>
public static class JsonLine
{
    public static async Task WriteAsync(Stream stream, string json, CancellationToken ct = default)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(json + "\n");
        await stream.WriteAsync(bytes.AsMemory(), ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    public static async Task<string?> ReadAsync(Stream stream, int maxBytes = 1024 * 1024, CancellationToken ct = default)
    {
        var pool = ArrayPool<byte>.Shared;
        var buf = pool.Rent(4096);
        try
        {
            var len = 0;
            while (true)
            {
                if (len == buf.Length)
                {
                    if (len >= maxBytes) throw new InvalidDataException("Frame exceeds max size");
                    var bigger = pool.Rent(buf.Length * 2);
                    Array.Copy(buf, bigger, len);
                    pool.Return(buf);
                    buf = bigger;
                }
                var n = await stream.ReadAsync(buf.AsMemory(len, 1), ct).ConfigureAwait(false);
                if (n == 0) return null;
                if (buf[len] == 0x0A)
                {
                    return System.Text.Encoding.UTF8.GetString(buf, 0, len);
                }
                len++;
            }
        }
        finally
        {
            pool.Return(buf);
        }
    }
}
