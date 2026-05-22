using System.Buffers.Binary;
using System.Collections.Concurrent;
using Bromure.AC.Mitm.Ssh;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// The in-VM ssh-add path is: guest Unix socket → AF_VSOCK →
/// host-side hvsocket listener → <c>PrivateSshAgent.ServePublicAsync</c>.
/// I can't boot a real Hyper-V VM in xunit to exercise the wire, but
/// I CAN drive ServePublicAsync directly with the OpenSSH agent
/// protocol over an in-memory full-duplex stream pair and prove
/// that the same handler that serves the named pipe also serves an
/// arbitrary stream. That's the half of the bridge that lives in
/// managed code; the C-side bridge daemon is exercised by the bake.
/// </summary>
public class PrivateSshAgentServePublicTests
{
    private const byte SSH_AGENTC_REQUEST_IDENTITIES = 11;
    private const byte SSH_AGENT_IDENTITIES_ANSWER = 12;

    [Fact]
    public async Task ServePublicAsync_OverDuplexStream_ReturnsIdentities()
    {
        await using var agent = new PrivateSshAgent("bromure-ac-ssh-agent-test-" + Guid.NewGuid().ToString("N"));
        // Pre-load one identity. The host-side listener path
        // populates this from ApplyProfileBindings; here we go
        // straight at PrivateSshAgent's key store.
        var seed = new byte[32];
        var pub = new byte[32];
        for (var i = 0; i < 32; i++) { seed[i] = (byte)(i + 1); pub[i] = (byte)(i + 100); }
        agent.AddEd25519(seed, pub, "agent-bridge-test");

        // In-memory duplex: caller stream <-> agent stream.
        var (callerStream, agentStream) = CreateDuplex();
        var serveTask = Task.Run(() => agent.ServePublicAsync(agentStream, CancellationToken.None));

        // Send REQUEST_IDENTITIES.
        var msg = new byte[] { SSH_AGENTC_REQUEST_IDENTITIES };
        var lenBuf = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(lenBuf, (uint)msg.Length);
        await callerStream.WriteAsync(lenBuf);
        await callerStream.WriteAsync(msg);
        await callerStream.FlushAsync();

        var respLenBuf = await ReadExactAsync(callerStream, 4);
        var respLen = (int)BinaryPrimitives.ReadUInt32BigEndian(respLenBuf);
        respLen.Should().BeGreaterThan(0);
        var resp = await ReadExactAsync(callerStream, respLen);
        resp[0].Should().Be(SSH_AGENT_IDENTITIES_ANSWER);

        // Parse count + first entry.
        var idx = 1;
        var count = (int)BinaryPrimitives.ReadUInt32BigEndian(resp.AsSpan(idx, 4));
        idx += 4;
        count.Should().Be(1);
        var blob = ReadSshString(resp, ref idx);
        var comment = System.Text.Encoding.UTF8.GetString(ReadSshString(resp, ref idx));
        comment.Should().Be("agent-bridge-test");
        blob.Length.Should().Be(4 + 11 + 4 + 32,
            "blob is ssh-string('ssh-ed25519') ssh-string(<32-byte pub>)");

        // Close the caller side so ServePublicAsync exits cleanly.
        callerStream.Dispose();
        try { await serveTask; } catch { /* expected — stream closed */ }
    }

    private static (Stream Caller, Stream Agent) CreateDuplex()
    {
        // TCP socket pair on loopback. Known-good duplex stream
        // implementation in BCL; works on every Windows build the
        // app supports.
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        var client = new System.Net.Sockets.TcpClient();
        client.Connect(System.Net.IPAddress.Loopback, port);
        var server = listener.AcceptTcpClient();
        listener.Stop();
        return (client.GetStream(), server.GetStream());
    }

    private static async Task<byte[]> ReadExactAsync(Stream s, int n)
    {
        var buf = new byte[n];
        var got = 0;
        while (got < n)
        {
            var r = await s.ReadAsync(buf.AsMemory(got, n - got));
            if (r == 0) throw new EndOfStreamException();
            got += r;
        }
        return buf;
    }

    private static byte[] ReadSshString(byte[] buf, ref int idx)
    {
        var len = (int)BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(idx, 4));
        idx += 4;
        var data = buf.AsSpan(idx, len).ToArray();
        idx += len;
        return data;
    }

}
