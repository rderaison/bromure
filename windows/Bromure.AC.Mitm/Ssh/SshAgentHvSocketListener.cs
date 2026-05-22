using System.Net.Sockets;
using Bromure.SandboxEngine.Hcs;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.AC.Mitm.Ssh;

/// <summary>
/// Host-side hvsocket listener that bridges in-VM ssh-add traffic
/// into <see cref="PrivateSshAgent"/>'s OpenSSH protocol handler.
///
/// <para><b>Why this exists.</b> The Bromure agent on the host owns
/// a Windows Named Pipe (<c>\\.\pipe\bromure-ac-ssh-agent</c>). A
/// Windows-side <c>ssh-add</c> can dial it directly via
/// <c>SSH_AUTH_SOCK</c>. But Linux <c>ssh-add</c> running inside a
/// VM cannot reach a Windows Named Pipe — it speaks Unix sockets.
/// The guest must dial AF_VSOCK to the host, and something on the
/// host has to accept those connections and reply with the OpenSSH
/// agent protocol.</para>
///
/// <para><b>This listener.</b> Binds AF_HYPERV port
/// <see cref="Engine.MitmEngine.SshAgentVsockPort"/> (8444) with the
/// HV_GUID_WILDCARD VM filter, so any registered guest can dial in.
/// On accept, hands the socket's network stream to
/// <see cref="PrivateSshAgent.ServePublicAsync"/> — the same wire
/// protocol that serves the host-side named pipe.</para>
///
/// <para><b>Setup.</b> The guest needs (a) a small bridge daemon
/// that exposes a Unix socket at <c>/run/bromure-ssh-agent.sock</c>
/// and pumps bytes to AF_VSOCK CID_HOST:8444, and (b) the bake
/// script must export <c>SSH_AUTH_SOCK</c> pointing at that path.
/// See <c>setup-hcs.sh</c> and the <c>bromure-ssh-agent-bridge</c>
/// systemd unit.</para>
/// </summary>
public sealed class SshAgentHvSocketListener : IAsyncDisposable
{
    private readonly PrivateSshAgent _agent;
    private readonly uint _port;
    private readonly ILogger _log;
    private Socket? _listener;
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;

    public SshAgentHvSocketListener(PrivateSshAgent agent, uint port, ILogger? log = null)
    {
        _agent = agent;
        _port = port;
        _log = log ?? NullLogger.Instance;
    }

    public Task StartAsync(CancellationToken ct = default)
    {
        if (_cts is not null) throw new InvalidOperationException("Already started");
        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        try
        {
            _listener = HvSocket.Listen(_port, backlog: 4);
            _log.LogInformation("[mitm] ssh-agent hvsocket listener up on port {Port}", _port);
        }
        catch (Exception ex)
        {
            // Binding hvsocket can fail (no Hyper-V, missing service
            // table entry, permission). Don't crash the engine; the
            // host-side named-pipe agent still works.
            _log.LogWarning(ex, "[mitm] ssh-agent hvsocket listener failed to bind on port {Port}", _port);
            return Task.CompletedTask;
        }
        _acceptLoop = Task.Run(() => AcceptLoopAsync(_cts.Token));
        return Task.CompletedTask;
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
                _log.LogDebug(ex, "ssh-agent hvsocket accept threw — continuing");
                continue;
            }

            _ = Task.Run(async () =>
            {
                using (peer)
                using (var stream = new NetworkStream(peer, ownsSocket: false))
                {
                    try { await _agent.ServePublicAsync(stream, ct).ConfigureAwait(false); }
                    catch (Exception ex) { _log.LogDebug(ex, "ssh-agent hvsocket session threw"); }
                }
            }, ct);
        }
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts?.Cancel(); } catch { }
        try { _listener?.Close(); } catch { }
        if (_acceptLoop is not null)
        {
            try { await _acceptLoop.ConfigureAwait(false); } catch { }
        }
        _cts?.Dispose();
    }
}
