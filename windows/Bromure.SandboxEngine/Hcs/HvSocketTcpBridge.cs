using System.Net;
using System.Net.Sockets;

namespace Bromure.SandboxEngine.Hcs;

/// <summary>
/// Host-side TCP listener that bridges every accept to an
/// <see cref="HvSocket"/>-attached connection on a per-session VM. Used
/// so plain <c>mstsc.exe /v:127.0.0.1:&lt;port&gt;</c> can reach the
/// guest's weston-rdp via the in-guest <c>bromure-hvsock-proxy</c>
/// without needing the (registry-gated) <c>mstsc /v:hvsocket://…</c>
/// transport that Hyper-V Manager VMs use.
///
/// <para>One bridge per session — lifetime tied to the
/// <see cref="HcsSession"/>. Accepts as many concurrent mstsc
/// connections as the user opens. Bytes pumped both directions with a
/// shared buffer per connection; closing either side tears down both.</para>
/// </summary>
public sealed class HvSocketTcpBridge : IAsyncDisposable
{
    private readonly Guid _vmRuntimeId;
    private readonly uint _hvSocketPort;
    private readonly TcpListener _listener;
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;

    /// <summary>The loopback port mstsc should dial. Stable for the
    /// life of the bridge.</summary>
    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public HvSocketTcpBridge(Guid vmRuntimeId, uint hvSocketPort)
    {
        _vmRuntimeId = vmRuntimeId;
        _hvSocketPort = hvSocketPort;
        // Bind to loopback so external machines can't reach the VM
        // through us. Port 0 → OS picks a free ephemeral port.
        _listener = new TcpListener(IPAddress.Loopback, 0);
    }

    public void Start()
    {
        if (_acceptLoop is not null) throw new InvalidOperationException("Already started");
        _listener.Start();
        _cts = new CancellationTokenSource();
        _acceptLoop = Task.Run(() => AcceptLoopAsync(_cts.Token));
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient tcp;
            try { tcp = await _listener.AcceptTcpClientAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            // Don't pass ct as Task.Run's second arg — if the token is
            // already cancelled by the time Task.Run is reached, the
            // body NEVER runs and tcp is never disposed (the `using
            // (tcp)` lives inside HandleAsync). Socket-FD leak per
            // accept that races dispose; over many session starts +
            // stops this exhausts ephemeral ports. The body still
            // observes ct internally for early-exit.
            _ = Task.Run(() => HandleAsync(tcp, ct));
        }
    }

    private async Task HandleAsync(TcpClient tcp, CancellationToken ct)
    {
        using (tcp)
        {
            tcp.NoDelay = true;
            var peer = tcp.Client.RemoteEndPoint?.ToString() ?? "<unknown>";
            Console.Error.WriteLine($"[hvsock-tcp-bridge] accept tcp from {peer} → dialing hvsocket vm={_vmRuntimeId:D} port={_hvSocketPort}");
            IntPtr hvHandle;
            try
            {
                hvHandle = await HvSocket.ConnectRawAsync(_vmRuntimeId, _hvSocketPort, ct).ConfigureAwait(false);
                Console.Error.WriteLine($"[hvsock-tcp-bridge] hvsocket dial OK → pumping bytes for {peer}");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[hvsock-tcp-bridge] hvsocket dial FAILED for {peer}: {ex.GetType().Name}: {ex.Message}");
                return;
            }
            try
            {
                using var connCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                // tcp side stays a .NET Socket (AF_INET) — that wrapper
                // works fine. hvHandle stays a raw winsock SOCKET — the
                // .NET Socket wrapper poisons AF_HYPERV handles, so we
                // call winsock send/recv directly.
                var a = HandlePumpAsync(true, tcp.Client, hvHandle, connCts.Token, $"{peer} tcp→hv");
                var b = HandlePumpAsync(false, tcp.Client, hvHandle, connCts.Token, $"{peer} hv→tcp");
                await Task.WhenAny(a, b).ConfigureAwait(false);
                connCts.Cancel();
                await Task.WhenAll(a, b).ConfigureAwait(false);
                Console.Error.WriteLine($"[hvsock-tcp-bridge] session closed for {peer}");
            }
            finally
            {
                HvSocket.CloseRaw(hvHandle);
            }
        }
    }

    /// <summary>
    /// Pump one direction. <paramref name="tcpToHv"/> = true means read
    /// from TCP, write to hvsocket; false = the reverse. The TCP side
    /// uses <see cref="Socket"/>'s sync Send/Receive; the hvsocket side
    /// uses raw winsock <c>send()</c>/<c>recv()</c>.
    /// </summary>
    private static async Task HandlePumpAsync(bool tcpToHv, Socket tcpSock, IntPtr hvHandle,
        CancellationToken ct, string tag)
    {
        await Task.Run(() =>
        {
            var buf = new byte[16 * 1024];
            long total = 0;
            using var reg = ct.Register(() =>
            {
                try { tcpSock.Shutdown(SocketShutdown.Both); } catch { }
                // Closing the hv handle in another thread is racy — let
                // the natural read EOF on the other side trigger.
            });
            try
            {
                while (!ct.IsCancellationRequested)
                {
                    int n;
                    try
                    {
                        Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} about to recv");
                        n = tcpToHv
                            ? tcpSock.Receive(buf, SocketFlags.None)
                            : HvSocket.RecvRawHandle(hvHandle, buf, 0, buf.Length);
                        Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} recv returned {n}");
                    }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} recv threw after {total} B: {ex.GetType().Name}: {ex.Message}");
                        return;
                    }
                    if (n <= 0)
                    {
                        Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} EOF after {total} B");
                        return;
                    }
                    total += n;
                    var sent = 0;
                    while (sent < n)
                    {
                        try
                        {
                            int w;
                            if (tcpToHv)
                            {
                                Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} about to send {n - sent} B to hvsocket (via WSASend)");
                                w = HvSocket.WsaSendRawHandle(hvHandle, buf, sent, n - sent);
                                Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} WSASend returned {w}");
                            }
                            else
                            {
                                w = tcpSock.Send(buf, sent, n - sent, SocketFlags.None);
                            }
                            if (w <= 0)
                            {
                                Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} send returned 0 after {total - n + sent} B");
                                return;
                            }
                            sent += w;
                        }
                        catch (Exception ex)
                        {
                            Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} send threw after {total - n + sent} B: {ex.GetType().Name}: {ex.Message}");
                            return;
                        }
                    }
                }
            }
            catch (OperationCanceledException) { }
        }, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Bridge bytes between two <see cref="Socket"/>s. Uses
    /// SYNCHRONOUS Receive/Send wrapped in <see cref="Task.Run"/>
    /// because the .NET async-socket path tries to bind the socket
    /// handle to an IOCP completion port at first ReceiveAsync, and
    /// for an AF_HYPERV socket wrapped via <c>new Socket(SafeSocketHandle)</c>
    /// that bind throws <c>InvalidOperationException</c>. Synchronous
    /// I/O sidesteps the IOCP path entirely.
    /// </summary>
    private static async Task SocketPumpAsync(Socket from, Socket to, CancellationToken ct, string tag = "")
    {
        await Task.Run(() =>
        {
            var buf = new byte[16 * 1024];
            long total = 0;
            // Cancel kicks Receive out of its blocking state by
            // shutting down the receiving side of both sockets.
            using var reg = ct.Register(() =>
            {
                try { from.Shutdown(SocketShutdown.Both); } catch { }
                try { to.Shutdown(SocketShutdown.Both); } catch { }
            });
            try
            {
                while (!ct.IsCancellationRequested)
                {
                    int n;
                    // Use raw winsock recv() for both sides — for the
                    // AF_HYPERV socket the .NET Send/Receive path
                    // silently hangs (the IOCP-bind machinery isn't
                    // implemented for HV transport). Raw recv() is
                    // identical wire behaviour on the AF_INET side.
                    try { n = HvSocket.RecvRaw(from, buf, 0, buf.Length); }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} recv threw after {total} B: {ex.GetType().Name}: {ex.Message}");
                        return;
                    }
                    if (n <= 0)
                    {
                        Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} EOF after {total} B");
                        return;
                    }
                    total += n;
                    Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} recv {n} B (total {total})");
                    var sent = 0;
                    while (sent < n)
                    {
                        try
                        {
                            var w = HvSocket.SendRaw(to, buf, sent, n - sent);
                            Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} send returned {w} (of {n - sent} requested)");
                            if (w <= 0)
                            {
                                Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} send returned 0 after {total - n + sent} B");
                                return;
                            }
                            sent += w;
                        }
                        catch (Exception ex)
                        {
                            Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} send threw after {total - n + sent} B: {ex.GetType().Name}: {ex.Message}");
                            return;
                        }
                    }
                }
            }
            catch (OperationCanceledException) { }
        }, ct).ConfigureAwait(false);
    }

    private static async Task PumpAsync(Stream from, Stream to, CancellationToken ct, string tag = "")
    {
        var buf = new byte[16 * 1024];
        long total = 0;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                int n;
                try { n = await from.ReadAsync(buf, ct).ConfigureAwait(false); }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} read threw after {total} B: {ex.GetType().Name}: {ex.Message}");
                    return;
                }
                if (n <= 0)
                {
                    Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} EOF after {total} B");
                    return;
                }
                total += n;
                try { await to.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false); }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[hvsock-tcp-bridge] {tag} write threw after {total} B: {ex.GetType().Name}: {ex.Message}");
                    return;
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts?.Cancel(); } catch { }
        try { _listener.Stop(); } catch { }
        if (_acceptLoop is not null)
        {
            try { await _acceptLoop.ConfigureAwait(false); } catch { }
        }
        _cts?.Dispose();
    }
}
