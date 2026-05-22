using System.Net.Sockets;
using Bromure.SandboxEngine.Hcs;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.AC.Mitm.Aws;

/// <summary>
/// Host-side AF_HYPERV listener that vends a credential_process
/// payload to each in-VM caller.
///
/// <para><b>Why this exists.</b> Audit 04 flagged
/// <see cref="AwsCredentialServer.WriteCredentialProcessPayloadAsync"/>
/// as having zero call sites — the resigner had real credentials in
/// memory but no transport for the guest's AWS SDK to fetch them.
/// Combined with <c>SessionHomeBuilder</c> writing the *real* secret
/// into <c>.aws/credentials</c>, the fail-closed threat model was
/// entirely broken.</para>
///
/// <para><b>Wire.</b> The guest's <c>bromure-aws-credentials</c>
/// helper (Python, AF_VSOCK) dials this listener with the profile
/// UUID as the first newline-terminated line. The listener resolves
/// the profile against <see cref="AwsCredentialServer"/> and writes
/// the JSON document the AWS SDK consumes.</para>
/// </summary>
public sealed class AwsCredentialHvSocketListener : IAsyncDisposable
{
    private readonly AwsCredentialServer _server;
    private readonly uint _port;
    private readonly ILogger _log;
    private Socket? _listener;
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;

    public AwsCredentialHvSocketListener(AwsCredentialServer server, uint port, ILogger? log = null)
    {
        _server = server;
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
            _log.LogInformation("[mitm] aws-credentials hvsocket listener up on port {Port}", _port);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "[mitm] aws-credentials hvsocket listener failed on port {Port}", _port);
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
                _log.LogDebug(ex, "aws-credentials accept threw — continuing");
                continue;
            }

            _ = Task.Run(async () =>
            {
                using (peer)
                using (var stream = new NetworkStream(peer, ownsSocket: false))
                {
                    try { await ServeAsync(stream, ct).ConfigureAwait(false); }
                    catch (Exception ex) { _log.LogDebug(ex, "aws-credentials session threw"); }
                }
            }, ct);
        }
    }

    private async Task ServeAsync(NetworkStream stream, CancellationToken ct)
    {
        // Protocol: client writes one newline-terminated profile UUID,
        // then half-closes (or just waits). We read up to 64 bytes
        // looking for the newline.
        var buf = new byte[64];
        var got = 0;
        while (got < buf.Length)
        {
            int n;
            try { n = await stream.ReadAsync(buf.AsMemory(got, buf.Length - got), ct).ConfigureAwait(false); }
            catch { return; }
            if (n == 0) break;
            got += n;
            if (Array.IndexOf(buf, (byte)'\n', 0, got) >= 0) break;
        }
        if (got == 0) return;
        var line = System.Text.Encoding.ASCII.GetString(buf, 0, got).Trim();
        if (!Guid.TryParse(line, out var profileId))
        {
            var err = System.Text.Encoding.UTF8.GetBytes(
                "{\"Version\":1,\"Error\":\"aws-credentials: malformed profile UUID\"}");
            await stream.WriteAsync(err, ct).ConfigureAwait(false);
            await stream.FlushAsync(ct).ConfigureAwait(false);
            return;
        }
        await _server.WriteCredentialProcessPayloadAsync(stream, profileId, ct).ConfigureAwait(false);
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
