using System.Buffers;
using System.Net;
using System.Net.Sockets;
using Bromure.SandboxEngine.Hcs;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Vsock;

/// <summary>
/// Host-side endpoint of the guest's <c>AF_VSOCK</c> connections.
///
/// On macOS, <c>VZVirtioSocketDevice</c> + <c>VZVirtioSocketListener</c>
/// hand the host a callback for every guest <c>connect(VMADDR_CID_HOST, port)</c>.
/// On Windows / HCS we bind an <c>AF_HYPERV</c> listener per port (via
/// <see cref="HvSocket.Listen"/>); a Linux guest dialling
/// <c>AF_VSOCK CID_HOST:&lt;port&gt;</c> lands here and we hand the
/// accepted stream to the per-port handler.
///
/// <para>Audit 07 #3 (CRITICAL) called this out: the earlier
/// implementation used Windows Named Pipes
/// (<c>\\.\pipe\bromure-ac-vsock-&lt;port&gt;</c>), which Linux
/// guests can't dial — the SubscriptionTokenCoordinator's wiring
/// was therefore dead even after my Phase 1 work. The hvsocket
/// transport fixes the actual reachability.</para>
///
/// <para>Wire format identical to the macOS bridges
/// (<c>SubscriptionTokenBridge</c>, <c>CodexTokenBridge</c>):
/// newline-delimited JSON. Each registered port gets its own
/// service-table entry in the VM's HCS schema (see
/// <see cref="HcsSession"/>'s <c>HvSocketPorts</c>).</para>
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
    /// The handler receives the connection stream + the source VM's
    /// AF_HYPERV peer GUID (extracted from the accepted peer address)
    /// so a single host listener can multiplex connections from
    /// multiple concurrent guest VMs — required for the subscription
    /// token bridge once more than one session can run at a time.
    /// </summary>
    public void Listen(uint port, Func<Stream, Guid, CancellationToken, Task> onConnection)
    {
        lock (_gate)
        {
            if (_listeners.ContainsKey(port))
            {
                throw new InvalidOperationException($"Port {port} already has a listener");
            }
            var listener = new PortListener(port, onConnection, _log);
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
    /// Test seam: invoke the registered handler on
    /// <paramref name="port"/> with an arbitrary bidirectional
    /// stream and a synthetic source VM ID, bypassing the AF_HYPERV
    /// transport. Used by the token bridge tests since xunit can't
    /// open an AF_HYPERV listener and nothing dials AF_VSOCK CID_HOST
    /// on the other side without a real VM. Production callers never
    /// use this.
    /// </summary>
    internal async Task TestInvokeAsync(uint port, Stream stream, Guid sourceVmId, CancellationToken ct)
    {
        PortListener? listener;
        lock (_gate)
        {
            _listeners.TryGetValue(port, out listener);
        }
        if (listener is null) throw new InvalidOperationException($"No listener for port {port}");
        await listener.InvokeHandlerAsync(stream, sourceVmId, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// One AF_HYPERV listener per registered port. We accept
    /// connections in a loop and dispatch each to the handler on a
    /// Task. Failure to bind (no Hyper-V, missing service-table
    /// entry, permission) is logged but doesn't crash the engine —
    /// the caller decides whether the feature is degraded.
    /// </summary>
    private sealed class PortListener : IAsyncDisposable
    {
        private readonly uint _port;
        private readonly Func<Stream, Guid, CancellationToken, Task> _handler;
        private readonly CancellationTokenSource _cts = new();
        private readonly ILogger _log;
        private Socket? _listener;
        private Task? _acceptLoop;

        public PortListener(uint port, Func<Stream, Guid, CancellationToken, Task> handler, ILogger log)
        {
            _port = port;
            _handler = handler;
            _log = log;
        }

        public void Start()
        {
            try
            {
                _listener = HvSocket.Listen(_port, backlog: 4);
                _log.LogInformation("[vsock] hvsocket listener up on port {Port}", _port);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "[vsock] hvsocket bind on port {Port} failed — feature degraded", _port);
                return;
            }
            _acceptLoop = Task.Run(() => AcceptLoopAsync(_cts.Token));
        }

        private async Task AcceptLoopAsync(CancellationToken ct)
        {
            var listener = _listener!;
            while (!ct.IsCancellationRequested)
            {
                Socket peer;
                try { peer = await listener.AcceptAsync(ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                catch (ObjectDisposedException) { return; }
                catch (SocketException ex)
                {
                    _log.LogDebug(ex, "[vsock] accept on port {Port} threw — continuing", _port);
                    continue;
                }

                var sourceVmId = ExtractSourceVmId(peer);
                _ = Task.Run(async () =>
                {
                    Stream? stream = null;
                    try
                    {
                        stream = new NetworkStream(peer, ownsSocket: false);
                        await _handler(stream, sourceVmId, ct).ConfigureAwait(false);
                    }
                    catch (Exception ex)
                    {
                        _log.LogWarning(ex, "[vsock] handler on port {Port} threw", _port);
                    }
                    finally
                    {
                        try { stream?.Dispose(); } catch { }
                        try { peer.Dispose(); } catch { }
                    }
                });
            }
        }

        /// <summary>Test-only direct handler invocation.</summary>
        internal Task InvokeHandlerAsync(Stream stream, Guid sourceVmId, CancellationToken ct)
            => _handler(stream, sourceVmId, ct);

        /// <summary>Decode the AF_HYPERV peer's source VM ID from the
        /// accepted socket's RemoteEndPoint. The address layout for
        /// AF_HYPERV starts with a u16 family + u16 reserved + a 16-byte
        /// VM GUID at offset 4 (see HvSocketApi.BuildSocketAddress).
        /// Returns Guid.Empty if extraction fails — callers treat that
        /// as "single-VM mode" and accept any peer.</summary>
        private static Guid ExtractSourceVmId(Socket peer)
        {
            try
            {
                var sa = peer.RemoteEndPoint?.Serialize();
                if (sa is null || sa.Size < 20) return Guid.Empty;
                var raw = new byte[16];
                for (int i = 0; i < 16; i++) raw[i] = sa[4 + i];
                return new Guid(raw);
            }
            catch { return Guid.Empty; }
        }

        public async ValueTask DisposeAsync()
        {
            _cts.Cancel();
            try { _listener?.Close(); } catch { }
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
