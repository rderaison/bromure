// macos-source: Sources/AgentCoding/Mitm/PrivateSSHAgent.swift @ f44f15164019
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Security.Cryptography;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.AC.Mitm.Ssh;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/PrivateSSHAgent.swift</c>.
///
/// <para><b>Windows divergence.</b> macOS spawns <c>ssh-agent -D -a &lt;sock&gt;</c>
/// as a subprocess so a queryable agent always exists regardless of the
/// user's launchd configuration. Windows ships OpenSSH-for-Windows but
/// the bundled <c>ssh-agent.exe</c> is a Windows service shared with the
/// user's daily-driver agent — exactly what we want to avoid plugging
/// the disposable VM into. So this port runs the agent <b>in-process</b>
/// over a Windows Named Pipe, implementing the OpenSSH agent wire
/// protocol natively. No subprocess, no orphan-reaping.</para>
///
/// <para>The pipe path matches what the macOS source's
/// <c>HostAgentClient</c> expects on Windows
/// (<c>\\.\pipe\bromure-ac-ssh-agent</c>); the in-VM agent connects via
/// vsock-or-TCP fallback and the proxy forwards both ways.</para>
/// </summary>
public sealed class PrivateSshAgent : IAsyncDisposable
{
    public const string DefaultPipeName = "bromure-ac-ssh-agent";

    /// SSH agent protocol message types we handle.
    private const byte SSH_AGENT_FAILURE = 5;
    private const byte SSH_AGENT_SUCCESS = 6;
    private const byte SSH_AGENTC_REQUEST_IDENTITIES = 11;
    private const byte SSH_AGENT_IDENTITIES_ANSWER = 12;
    private const byte SSH_AGENTC_SIGN_REQUEST = 13;
    private const byte SSH_AGENT_SIGN_RESPONSE = 14;
    private const byte SSH_AGENTC_ADD_IDENTITY = 17;
    private const byte SSH_AGENTC_REMOVE_IDENTITY = 18;

    private readonly string _pipeName;
    private readonly ILogger _log;
    private readonly ConcurrentDictionary<string, KeyEntry> _keys = new();
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;

    public PrivateSshAgent(string pipeName = DefaultPipeName, ILogger? log = null)
    {
        _pipeName = pipeName;
        _log = log ?? NullLogger.Instance;
    }

    public string PipePath => @$"\\.\pipe\{_pipeName}";
    public int KeyCount => _keys.Count;

    public Task StartAsync(CancellationToken ct = default)
    {
        if (_cts is not null) throw new InvalidOperationException("Already started");
        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _acceptLoop = Task.Run(() => AcceptLoopAsync(_cts.Token));
        _log.LogInformation("[mitm] private ssh-agent up at {Pipe}", PipePath);
        return Task.CompletedTask;
    }

    public bool AddEd25519(ReadOnlySpan<byte> seed, ReadOnlySpan<byte> publicKey, string comment = "bromure-ac")
    {
        if (seed.Length != 32 || publicKey.Length != 32) return false;
        var blob = OpenSshKeyFormat.Ed25519PublicBlob(publicKey);
        var key = Convert.ToBase64String(blob);
        _keys[key] = new KeyEntry(blob, seed.ToArray(), publicKey.ToArray(), comment);
        return true;
    }

    public void RemoveByPublicBlob(ReadOnlySpan<byte> publicBlob)
    {
        var key = Convert.ToBase64String(publicBlob);
        _keys.TryRemove(key, out _);
    }

    public void Clear() => _keys.Clear();

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
            catch (OperationCanceledException) { server?.Dispose(); return; }
            catch (IOException ex)
            {
                _log.LogWarning(ex, "ssh-agent accept failed; retrying");
                server?.Dispose();
                await Task.Delay(50, ct).ConfigureAwait(false);
                continue;
            }

            var pipe = server;
            _ = Task.Run(async () =>
            {
                using (pipe)
                {
                    try { await ServeAsync(pipe, ct).ConfigureAwait(false); }
                    catch (Exception ex) { _log.LogDebug(ex, "ssh-agent connection threw"); }
                }
            }, ct);
        }
    }

    private async Task ServeAsync(Stream stream, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var reqLenBuf = await ReadExactAsync(stream, 4, ct).ConfigureAwait(false);
            if (reqLenBuf is null) return;
            var reqLen = (int)BinaryPrimitives.ReadUInt32BigEndian(reqLenBuf);
            if (reqLen <= 0 || reqLen > 256 * 1024)
            {
                await WriteFailure(stream, ct);
                return;
            }
            var payload = await ReadExactAsync(stream, reqLen, ct).ConfigureAwait(false);
            if (payload is null) return;

            var response = HandleRequest(payload);
            await WriteFrame(stream, response, ct).ConfigureAwait(false);
        }
    }

    private byte[] HandleRequest(byte[] payload)
    {
        if (payload.Length == 0) return new[] { SSH_AGENT_FAILURE };
        var op = payload[0];
        try
        {
            switch (op)
            {
                case SSH_AGENTC_REQUEST_IDENTITIES:
                    return BuildIdentitiesAnswer();
                case SSH_AGENTC_SIGN_REQUEST:
                    return BuildSignResponse(payload.AsSpan(1));
                case SSH_AGENTC_ADD_IDENTITY:
                    return TryAddIdentity(payload.AsSpan(1)) ? new[] { SSH_AGENT_SUCCESS } : new[] { SSH_AGENT_FAILURE };
                case SSH_AGENTC_REMOVE_IDENTITY:
                    return TryRemoveIdentity(payload.AsSpan(1)) ? new[] { SSH_AGENT_SUCCESS } : new[] { SSH_AGENT_FAILURE };
                default:
                    return new[] { SSH_AGENT_FAILURE };
            }
        }
        catch
        {
            return new[] { SSH_AGENT_FAILURE };
        }
    }

    private byte[] BuildIdentitiesAnswer()
    {
        var ms = new MemoryStream();
        ms.WriteByte(SSH_AGENT_IDENTITIES_ANSWER);
        WriteU32Be(ms, (uint)_keys.Count);
        foreach (var entry in _keys.Values)
        {
            WriteSshString(ms, entry.PublicBlob);
            WriteSshString(ms, System.Text.Encoding.UTF8.GetBytes(entry.Comment));
        }
        return ms.ToArray();
    }

    private byte[] BuildSignResponse(ReadOnlySpan<byte> body)
    {
        // body: ssh-string(public-blob) ssh-string(data) u32(flags)
        var publicBlob = ReadSshString(body, out var rest1);
        var toSign = ReadSshString(rest1, out _);
        // flags ignored — we always do raw ed25519.

        var key = Convert.ToBase64String(publicBlob);
        if (!_keys.TryGetValue(key, out var entry))
        {
            return new[] { SSH_AGENT_FAILURE };
        }

        // ed25519 sign(seed, message). System.Security.Cryptography
        // doesn't ship ed25519 in BCL; route through BouncyCastle.
        var sig = SignEd25519(entry.Seed, toSign.ToArray());

        // Response: SSH_AGENT_SIGN_RESPONSE (14)
        //           ssh-string(signature blob)
        //   signature blob = ssh-string("ssh-ed25519") ssh-string(sig)
        var sigBlob = new MemoryStream();
        WriteSshString(sigBlob, "ssh-ed25519");
        WriteSshString(sigBlob, sig);

        var response = new MemoryStream();
        response.WriteByte(SSH_AGENT_SIGN_RESPONSE);
        WriteSshString(response, sigBlob.ToArray());
        return response.ToArray();
    }

    private static byte[] SignEd25519(byte[] seed, byte[] message)
    {
        var keyParams = new Org.BouncyCastle.Crypto.Parameters.Ed25519PrivateKeyParameters(seed, 0);
        var signer = new Org.BouncyCastle.Crypto.Signers.Ed25519Signer();
        signer.Init(forSigning: true, keyParams);
        signer.BlockUpdate(message, 0, message.Length);
        return signer.GenerateSignature();
    }

    private bool TryAddIdentity(ReadOnlySpan<byte> body)
    {
        var alg = ReadSshString(body, out var rest1);
        var algStr = System.Text.Encoding.ASCII.GetString(alg);
        if (algStr != "ssh-ed25519") return false;
        var publicKey = ReadSshString(rest1, out var rest2);
        var privateBlob = ReadSshString(rest2, out var rest3);
        var commentSpan = ReadSshString(rest3, out _);
        if (publicKey.Length != 32 || privateBlob.Length != 64) return false;
        var seed = privateBlob[..32];
        var comment = System.Text.Encoding.UTF8.GetString(commentSpan);
        return AddEd25519(seed, publicKey, comment);
    }

    private bool TryRemoveIdentity(ReadOnlySpan<byte> body)
    {
        var publicBlob = ReadSshString(body, out _);
        RemoveByPublicBlob(publicBlob);
        return true;
    }

    // -- protocol primitives --------------------------------------------

    private static ReadOnlySpan<byte> ReadSshString(ReadOnlySpan<byte> input, out ReadOnlySpan<byte> rest)
    {
        rest = default;
        if (input.Length < 4) return default;
        var len = (int)BinaryPrimitives.ReadUInt32BigEndian(input);
        if (input.Length < 4 + len) return default;
        rest = input[(4 + len)..];
        return input.Slice(4, len);
    }

    private static void WriteSshString(MemoryStream ms, string s)
        => WriteSshString(ms, System.Text.Encoding.UTF8.GetBytes(s));

    private static void WriteSshString(MemoryStream ms, ReadOnlySpan<byte> data)
    {
        WriteU32Be(ms, (uint)data.Length);
        ms.Write(data);
    }

    private static void WriteU32Be(MemoryStream ms, uint v)
    {
        Span<byte> buf = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(buf, v);
        ms.Write(buf);
    }

    private static async Task WriteFrame(Stream stream, byte[] body, CancellationToken ct)
    {
        var lenBuf = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(lenBuf, (uint)body.Length);
        await stream.WriteAsync(lenBuf, ct).ConfigureAwait(false);
        await stream.WriteAsync(body, ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    private static Task WriteFailure(Stream stream, CancellationToken ct)
        => WriteFrame(stream, new[] { SSH_AGENT_FAILURE }, ct);

    private static async Task<byte[]?> ReadExactAsync(Stream stream, int count, CancellationToken ct)
    {
        var buf = new byte[count];
        var got = 0;
        while (got < count)
        {
            int n;
            try { n = await stream.ReadAsync(buf.AsMemory(got, count - got), ct).ConfigureAwait(false); }
            catch (IOException) { return null; }
            if (n == 0) return null;
            got += n;
        }
        return buf;
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts?.Cancel(); } catch { }
        if (_acceptLoop is not null)
        {
            try { await _acceptLoop.ConfigureAwait(false); } catch { }
        }
        _cts?.Dispose();
    }

    private sealed record KeyEntry(byte[] PublicBlob, byte[] Seed, byte[] PublicKey, string Comment);
}
