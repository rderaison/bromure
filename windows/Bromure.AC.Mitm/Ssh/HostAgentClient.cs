using System.Buffers.Binary;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;

namespace Bromure.AC.Mitm.Ssh;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/HostAgentClient.swift</c>.
/// Tiny synchronous client for an ssh-agent endpoint. Used by
/// <see cref="SshAgentServer"/> to forward <c>SIGN_REQUEST</c> and
/// <c>REQUEST_IDENTITIES</c> from the VM into Bromure's private
/// ssh-agent — the only host-side agent the VM ever sees.
///
/// <para><b>Endpoint shape on Windows.</b> macOS uses an
/// <c>AF_UNIX</c> socket at <c>~/.bromure/agent.sock</c>. Windows
/// switches to a Named Pipe at <c>\\.\pipe\bromure-ac-ssh-agent</c>;
/// OpenSSH-for-Windows already supports named-pipe agent sockets via
/// <c>SSH_AUTH_SOCK</c> pointing at a pipe path, so guest tooling
/// doesn't notice the change.</para>
///
/// <para><b>What we don't proxy.</b> The user's regular
/// <c>SSH_AUTH_SOCK</c> is intentionally NOT plumbed through. Earlier
/// macOS revisions multiplexed it in alongside the private agent —
/// that exposed every key in the user's daily-driver agent to the
/// disposable VM with no consent gate. Keys the user wants reachable
/// from the VM go through the explicit-import flow in the profile UI.
/// </para>
/// </summary>
public sealed class HostAgentClient
{
    public string Endpoint { get; }
    public AgentEndpointKind Kind { get; }

    /// <summary>
    /// Singleton set by the engine after it spawns the private ssh-agent.
    /// Used as the destination for ssh-add of per-profile keys and as
    /// the only forwarding target for in-VM SIGN_REQUESTs.
    /// </summary>
    public static HostAgentClient? BromurePrivate { get; set; }

    public HostAgentClient(string endpoint, AgentEndpointKind kind)
    {
        Endpoint = endpoint;
        Kind = kind;
    }

    /// <summary>
    /// Send a single ssh-agent-protocol request frame; return the response
    /// frame (without the 4-byte length prefix). Null on any I/O failure
    /// — caller falls back to its own behaviour.
    /// </summary>
    public async Task<byte[]?> RequestAsync(byte[] payload, CancellationToken ct = default)
    {
        try
        {
            await using var stream = await OpenAsync(ct).ConfigureAwait(false);
            // Frame: 4-byte big-endian length + payload.
            var lenBuf = new byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(lenBuf, (uint)payload.Length);
            await stream.WriteAsync(lenBuf, ct).ConfigureAwait(false);
            await stream.WriteAsync(payload, ct).ConfigureAwait(false);
            await stream.FlushAsync(ct).ConfigureAwait(false);

            var respLenBuf = await ReadExactAsync(stream, 4, ct).ConfigureAwait(false);
            if (respLenBuf is null) return null;
            var respLen = (int)BinaryPrimitives.ReadUInt32BigEndian(respLenBuf);
            if (respLen <= 0 || respLen > 256 * 1024) return null;
            return await ReadExactAsync(stream, respLen, ct).ConfigureAwait(false);
        }
        catch (IOException)
        {
            return null;
        }
        catch (SocketException)
        {
            return null;
        }
    }

    private async Task<Stream> OpenAsync(CancellationToken ct)
    {
        switch (Kind)
        {
            case AgentEndpointKind.NamedPipe:
                var pipe = new NamedPipeClientStream(".",
                    Endpoint, PipeDirection.InOut, PipeOptions.Asynchronous);
                await pipe.ConnectAsync(5000, ct).ConfigureAwait(false);
                return pipe;

            case AgentEndpointKind.UnixSocket:
                var sock = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                await sock.ConnectAsync(new UnixDomainSocketEndPoint(Endpoint), ct).ConfigureAwait(false);
                return new NetworkStream(sock, ownsSocket: true);

            case AgentEndpointKind.LoopbackTcp:
                var (host, port) = ParseLoopback(Endpoint);
                var tcp = new TcpClient();
                await tcp.ConnectAsync(host, port, ct).ConfigureAwait(false);
                return tcp.GetStream();

            default:
                throw new InvalidOperationException("Unknown endpoint kind: " + Kind);
        }
    }

    private static (string Host, int Port) ParseLoopback(string endpoint)
    {
        // "127.0.0.1:1234"
        var colon = endpoint.LastIndexOf(':');
        if (colon < 0) throw new ArgumentException("Loopback endpoint requires host:port");
        return (endpoint[..colon], int.Parse(endpoint[(colon + 1)..], System.Globalization.CultureInfo.InvariantCulture));
    }

    private static async Task<byte[]?> ReadExactAsync(Stream stream, int count, CancellationToken ct)
    {
        var buf = new byte[count];
        var got = 0;
        while (got < count)
        {
            var n = await stream.ReadAsync(buf.AsMemory(got, count - got), ct).ConfigureAwait(false);
            if (n == 0) return null;
            got += n;
        }
        return buf;
    }
}

public enum AgentEndpointKind
{
    NamedPipe,
    UnixSocket,
    LoopbackTcp,
}
