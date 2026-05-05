using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Cryptography;
using Bromure.AC.Mitm.Ssh;
using FluentAssertions;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// End-to-end test of the in-process SSH agent: connect to its named
/// pipe, list identities, request a signature, verify the signature.
/// </summary>
public class PrivateSshAgentTests
{
    [Fact]
    public async Task EndToEnd_AddListSignVerify()
    {
        var pipeName = "bromure-ac-tests-" + Guid.NewGuid().ToString("N");
        await using var agent = new PrivateSshAgent(pipeName);
        await agent.StartAsync();

        // Generate a fresh ed25519 key.
        var gen = new Ed25519KeyPairGenerator();
        gen.Init(new Ed25519KeyGenerationParameters(new SecureRandom()));
        var pair = gen.GenerateKeyPair();
        var seed = ((Ed25519PrivateKeyParameters)pair.Private).GetEncoded();
        var pub = ((Ed25519PublicKeyParameters)pair.Public).GetEncoded();
        agent.AddEd25519(seed, pub, "test-key").Should().BeTrue();

        // Open the pipe and request identities.
        await using var client = new NamedPipeClientStream(".", pipeName,
            PipeDirection.InOut, PipeOptions.Asynchronous);
        await client.ConnectAsync(5000);

        // SSH_AGENTC_REQUEST_IDENTITIES (op = 11).
        await SendFrame(client, new byte[] { 11 });
        var idsResp = await ReadFrame(client);
        idsResp[0].Should().Be((byte)12, "SSH_AGENT_IDENTITIES_ANSWER");

        // Pull the public-key blob and comment via byte[] helpers (no
        // spans across awaits).
        ParseIdentitiesAnswer(idsResp, out var publicBlobBytes, out var comment);
        comment.Should().Be("test-key");

        // SIGN_REQUEST.
        var data = "hello sign me"u8.ToArray();
        await SendFrame(client, BuildSignRequest(publicBlobBytes, data));
        var signResp = await ReadFrame(client);
        signResp[0].Should().Be((byte)14, "SSH_AGENT_SIGN_RESPONSE");
        ParseSignResponse(signResp, out var algName, out var signature);
        algName.Should().Be("ssh-ed25519");

        // Verify the signature against the public key — the agent
        // genuinely signed our message, not just stubbed a response.
        var verifier = new Ed25519Signer();
        verifier.Init(forSigning: false, new Ed25519PublicKeyParameters(pub, 0));
        verifier.BlockUpdate(data, 0, data.Length);
        verifier.VerifySignature(signature).Should().BeTrue();
    }

    // -- async I/O helpers ---------------------------------------------

    private static async Task SendFrame(Stream stream, byte[] body)
    {
        var lenBuf = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(lenBuf, (uint)body.Length);
        await stream.WriteAsync(lenBuf);
        await stream.WriteAsync(body);
        await stream.FlushAsync();
    }

    private static async Task<byte[]> ReadFrame(Stream stream)
    {
        var lenBuf = new byte[4];
        await ReadExact(stream, lenBuf);
        var len = (int)BinaryPrimitives.ReadUInt32BigEndian(lenBuf);
        var body = new byte[len];
        await ReadExact(stream, body);
        return body;
    }

    private static async Task ReadExact(Stream stream, byte[] buf)
    {
        var got = 0;
        while (got < buf.Length)
        {
            var n = await stream.ReadAsync(buf.AsMemory(got));
            if (n == 0) throw new IOException("stream closed");
            got += n;
        }
    }

    // -- synchronous byte-level parsing helpers ------------------------

    private static byte[] BuildSignRequest(byte[] publicBlob, byte[] data)
    {
        var ms = new MemoryStream();
        ms.WriteByte(13);
        WriteSshString(ms, publicBlob);
        WriteSshString(ms, data);
        var flags = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(flags, 0);
        ms.Write(flags);
        return ms.ToArray();
    }

    private static void ParseIdentitiesAnswer(byte[] resp, out byte[] publicBlob, out string comment)
    {
        // [0]=op (already validated), [1..5)=u32 count, then per-key:
        // ssh-string(public-blob) ssh-string(comment)
        var span = (ReadOnlySpan<byte>)resp;
        // skip op + count
        var rest = span[5..];
        var pub = ReadSshString(rest, out var rest2);
        var commentSpan = ReadSshString(rest2, out _);
        publicBlob = pub.ToArray();
        comment = System.Text.Encoding.UTF8.GetString(commentSpan);
    }

    private static void ParseSignResponse(byte[] resp, out string algName, out byte[] signature)
    {
        var span = (ReadOnlySpan<byte>)resp;
        var sigBlob = ReadSshString(span[1..], out _);
        var alg = ReadSshString(sigBlob, out var afterAlg);
        var sig = ReadSshString(afterAlg, out _);
        algName = System.Text.Encoding.ASCII.GetString(alg);
        signature = sig.ToArray();
    }

    private static ReadOnlySpan<byte> ReadSshString(ReadOnlySpan<byte> input, out ReadOnlySpan<byte> rest)
    {
        var len = (int)BinaryPrimitives.ReadUInt32BigEndian(input);
        rest = input[(4 + len)..];
        return input.Slice(4, len);
    }

    private static void WriteSshString(MemoryStream ms, byte[] data)
    {
        var u32 = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(u32, (uint)data.Length);
        ms.Write(u32);
        ms.Write(data);
    }
}
