using System.Collections.Concurrent;
using System.Net.Sockets;
using Bromure.AC.Core.Events;
using Bromure.SandboxEngine.Hcs;

namespace Bromure.AC.Display;

/// <summary>
/// Singleton AF_HYPERV listener that receives guest→host events
/// (today: terminal-title pushes for the tab labels, plus closed
/// signals, alive roster, and IP refresh — see audit 10 §2.8).
/// Used instead of a plain TCP listener on the Default Switch NIC
/// because that path was being silently dropped by Windows Firewall —
/// AF_HYPERV runs on the hypervisor's VMBus, below the IP stack,
/// and isn't subject to firewall rules.
///
/// <para>The actual line-parsing/dispatch lives in
/// <see cref="GuestEventDispatcher"/> (Bromure.AC.Core) so xunit can
/// test it without a real Hyper-V backend. This class is just the
/// AF_HYPERV plumbing.</para>
/// </summary>
public sealed class GuestEventServer
{
    public const uint TitlePort = 9224;
    public const uint OverlayPort = 9225;
    public static readonly GuestEventServer Instance = new();

    private Socket? _titleListener;
    private Socket? _overlayListener;
    private CancellationTokenSource? _cts;
    private readonly GuestEventDispatcher _dispatcher = new();
    private readonly ConcurrentDictionary<Guid, System.Func<byte[]>> _overlayByVmId = new();

    public void Subscribe(Guid vmRuntimeId, System.Action<string>? onTitle)
        => _dispatcher.SubscribeLegacyTitle(vmRuntimeId, onTitle);

    public void SubscribeTab(Guid vmRuntimeId, Guid tabUuid, System.Action<string>? onTitle)
        => _dispatcher.SubscribeTab(vmRuntimeId, tabUuid, onTitle);

    public void SubscribeTabClosed(Guid vmRuntimeId, Guid tabUuid, System.Action? onClosed)
        => _dispatcher.SubscribeTabClosed(vmRuntimeId, tabUuid, onClosed);

    public void SubscribeAlive(Guid vmRuntimeId, System.Action<IReadOnlySet<Guid>>? onAlive)
        => _dispatcher.SubscribeAlive(vmRuntimeId, onAlive);

    public void SubscribeIp(Guid vmRuntimeId, System.Action<string>? onIp)
        => _dispatcher.SubscribeIp(vmRuntimeId, onIp);

    /// <summary>Register the home-overlay tar bytes the host will
    /// stream when the VM dials port 9225. Producer is invoked on
    /// each connection so it can pick up profile edits without a
    /// re-register. Pass null to unregister.</summary>
    public void RegisterOverlay(Guid vmRuntimeId, System.Func<byte[]>? producer)
    {
        if (vmRuntimeId == Guid.Empty) return;
        if (producer is null) _overlayByVmId.TryRemove(vmRuntimeId, out _);
        else _overlayByVmId[vmRuntimeId] = producer;
    }

    public void EnsureStarted()
    {
        if (_titleListener is not null && _overlayListener is not null) return;
        _cts ??= new CancellationTokenSource();
        if (_titleListener is null)
        {
            try
            {
                _titleListener = HvSocket.Listen(TitlePort, backlog: 8);
                _ = Task.Run(() => TitleAcceptLoopAsync(_cts.Token));
                Log($"AF_HYPERV title listener up on port {TitlePort}");
            }
            catch (System.Exception ex) { Log("title-listener EnsureStarted failed: " + ex); }
        }
        if (_overlayListener is null)
        {
            try
            {
                _overlayListener = HvSocket.Listen(OverlayPort, backlog: 8);
                _ = Task.Run(() => OverlayAcceptLoopAsync(_cts.Token));
                Log($"AF_HYPERV overlay listener up on port {OverlayPort}");
            }
            catch (System.Exception ex) { Log("overlay-listener EnsureStarted failed: " + ex); }
        }
    }

    private async Task TitleAcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _titleListener is not null)
        {
            Socket peer;
            try { peer = await _titleListener.AcceptAsync(ct).ConfigureAwait(false); }
            catch (System.OperationCanceledException) { return; }
            catch (SocketException ex) { Log("title accept threw: " + ex.Message); continue; }
            _ = Task.Run(() => HandleTitleAsync(peer));
        }
    }

    private async Task OverlayAcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _overlayListener is not null)
        {
            Socket peer;
            try { peer = await _overlayListener.AcceptAsync(ct).ConfigureAwait(false); }
            catch (System.OperationCanceledException) { return; }
            catch (SocketException ex) { Log("overlay accept threw: " + ex.Message); continue; }
            _ = Task.Run(() => HandleOverlayAsync(peer));
        }
    }

    private static Guid SourceVmId(Socket peer)
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

    private async Task HandleTitleAsync(Socket peer)
    {
        try
        {
            var vmId = SourceVmId(peer);
            var buf = new byte[4096];
            var sb = new System.Text.StringBuilder();
            while (true)
            {
                int n;
                try { n = HvSocket.RecvRaw(peer, buf, 0, buf.Length); }
                catch (SocketException) { break; }
                if (n <= 0) break;
                sb.Append(System.Text.Encoding.UTF8.GetString(buf, 0, n));
            }
            var counts = _dispatcher.Dispatch(vmId, sb.ToString());
            Log($"title batch from vmId={vmId:D}: tab={counts.Tab} closed={counts.Closed} alive={counts.Alive} ip={counts.Ip} legacy={counts.Legacy}");
            await Task.CompletedTask;
        }
        finally { try { peer.Dispose(); } catch { } }
    }

    private async Task HandleOverlayAsync(Socket peer)
    {
        try
        {
            var vmId = SourceVmId(peer);
            Log($"overlay request from vmId={vmId:D}");
            // Race: the guest can dial as soon as multi-user.target
            // brings its overlay-fetch service up (~10 s into boot),
            // but the host only calls RegisterOverlay after the
            // boot-signal handshake completes (~30 s). Hold the
            // connection open while we wait for the producer to
            // appear, so the guest gets the bytes on its FIRST dial.
            System.Func<byte[]>? producer = null;
            var deadline = System.DateTime.UtcNow.AddSeconds(45);
            while (System.DateTime.UtcNow < deadline)
            {
                if (_overlayByVmId.TryGetValue(vmId, out producer)) break;
                await Task.Delay(250).ConfigureAwait(false);
            }
            if (producer is null)
            {
                Log($"overlay request from vmId={vmId:D}: timed out waiting for producer");
                return;
            }
            byte[] tar;
            try { tar = producer(); }
            catch (System.Exception ex) { Log("overlay producer threw: " + ex); return; }
            int off = 0;
            while (off < tar.Length)
            {
                int sent;
                try { sent = HvSocket.SendRaw(peer, tar, off, tar.Length - off); }
                catch (SocketException ex) { Log("overlay send: " + ex.Message); return; }
                if (sent <= 0) break;
                off += sent;
            }
            try { peer.Shutdown(System.Net.Sockets.SocketShutdown.Send); } catch { }
            Log($"overlay sent {off} bytes to vmId={vmId:D} (tar.Length={tar.Length})");
        }
        finally { try { peer.Dispose(); } catch { } }
    }

    private static readonly string LogPath = System.IO.Path.Combine(
        System.IO.Path.GetTempPath(), "bromure-events.log");

    private static void Log(string msg)
    {
        try { System.IO.File.AppendAllText(LogPath, $"[{System.DateTime.Now:HH:mm:ss.fff}] {msg}\n"); } catch { }
    }
}
