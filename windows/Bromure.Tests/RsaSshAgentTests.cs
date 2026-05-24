using System.Security.Cryptography;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.Ssh;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// End-to-end coverage for RFC 8332 RSA-SHA2 signing through
/// <see cref="SshAgentServer"/>. Audit 05 §2.1: the agent supported
/// ed25519 only; this confirms the polymorphic <see cref="AgentKey"/>
/// refactor + RSA path produces signatures the host BCL can verify.
/// </summary>
public class RsaSshAgentTests
{
    private static (string Pem, RsaAgentKey Key) MintRsaKey(string comment)
    {
        using var rsa = RSA.Create(2048);
        var pem = rsa.ExportRSAPrivateKeyPem();
        var parsed = OpenSshKeyFormat.ParseRsaPrivatePem(pem);
        parsed.Should().NotBeNull();
        var key = new RsaAgentKey(
            Comment: comment,
            PublicKey: parsed!.Value.PublicBlob,
            Parameters: parsed.Value.Parameters);
        return (pem, key);
    }

    [Fact]
    public void ParseRsaPrivatePem_PKCS1_HappyPath()
    {
        using var rsa = RSA.Create(2048);
        var pem = rsa.ExportRSAPrivateKeyPem();
        var parsed = OpenSshKeyFormat.ParseRsaPrivatePem(pem);
        parsed.Should().NotBeNull();
        parsed!.Value.PublicBlob.Length.Should().BeGreaterThan(0);
        parsed.Value.Parameters.Modulus.Should().NotBeNull();
        parsed.Value.Parameters.D.Should().NotBeNull();
    }

    [Fact]
    public void ParseRsaPrivatePem_PKCS8_HappyPath()
    {
        using var rsa = RSA.Create(2048);
        var pem = rsa.ExportPkcs8PrivateKeyPem();
        var parsed = OpenSshKeyFormat.ParseRsaPrivatePem(pem);
        parsed.Should().NotBeNull();
    }

    [Fact]
    public void ParseRsaPrivatePem_Garbage_ReturnsNull()
    {
        OpenSshKeyFormat.ParseRsaPrivatePem("not a pem").Should().BeNull();
        OpenSshKeyFormat.ParseRsaPrivatePem("").Should().BeNull();
        OpenSshKeyFormat.ParseRsaPrivatePem("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----").Should().BeNull();
    }

    [Fact]
    public void RsaPublicBlob_HasExpectedSshWireShape()
    {
        var (_, key) = MintRsaKey("rsa-shape");
        var blob = key.PublicKeyBlob;
        // First ssh-string must be "ssh-rsa" (8 bytes: 4-byte len + 7 bytes).
        blob.Length.Should().BeGreaterThan(11);
        var len = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(blob);
        len.Should().Be(7u);
        System.Text.Encoding.ASCII.GetString(blob, 4, 7).Should().Be("ssh-rsa");
    }

    [Theory]
    [InlineData(0x02u, "rsa-sha2-256", "SHA-256")]
    [InlineData(0x04u, "rsa-sha2-512", "SHA-512")]
    [InlineData(0x00u, "ssh-rsa", "SHA-1")]
    public void Sign_returns_expected_algorithm_for_flags(uint flags, string expectedFormat, string expectedHashName)
    {
        var (_, key) = MintRsaKey("rsa-sign");
        var message = System.Text.Encoding.UTF8.GetBytes("the quick brown fox");
        var (sig, format) = key.Sign(message, flags);
        format.Should().Be(expectedFormat);

        // Verify the signature with a fresh RSA instance reading the
        // SAME parameters — round-trips that the chosen hash + PKCS#1
        // signature are consistent.
        using var rsa = RSA.Create();
        rsa.ImportParameters(key.Parameters);
        var hash = expectedHashName switch
        {
            "SHA-512" => HashAlgorithmName.SHA512,
            "SHA-256" => HashAlgorithmName.SHA256,
            _ => HashAlgorithmName.SHA1,
        };
        rsa.VerifyData(message, sig, hash, RSASignaturePadding.Pkcs1).Should().BeTrue();
    }

    [Fact]
    public async Task SshAgentServer_RoutesRsaSignRequest_AndReturnsSha256Signature()
    {
        var consent = new ConsentBroker(new AlwaysAllowSessionDialogPresenter());
        var server = new SshAgentServer(consent);
        var profileId = Guid.NewGuid();
        var (_, key) = MintRsaKey("integration");
        server.SetKeys(new AgentKey[] { key }, profileId);

        // Build a SIGN_REQUEST body: ssh-string(publicBlob) ssh-string(data) u32(flags=0x02)
        var ms = new MemoryStream();
        WriteSshString(ms, key.PublicKeyBlob);
        WriteSshString(ms, System.Text.Encoding.UTF8.GetBytes("payload"));
        var u32 = new byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(u32, 0x02u);
        ms.Write(u32);
        var body = ms.ToArray();

        var response = await server.HandleSignRequestAsync(body, profileId, CancellationToken.None);

        // Response: SSH_AGENT_SIGN_RESPONSE (14) + ssh-string(sigBlob)
        //   sigBlob = ssh-string("rsa-sha2-256") + ssh-string(sig)
        response[0].Should().Be(14);
        var sigBlobLen = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(response.AsSpan(1, 4));
        var sigBlob = response.AsSpan(5, sigBlobLen).ToArray();
        var fmtLen = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(sigBlob.AsSpan(0, 4));
        System.Text.Encoding.ASCII.GetString(sigBlob, 4, fmtLen).Should().Be("rsa-sha2-256");
    }

    [Fact]
    public async Task SshAgentServer_RoutesRsaSignRequest_DefaultsToSshRsa_WhenFlagsZero()
    {
        var consent = new ConsentBroker(new AlwaysAllowSessionDialogPresenter());
        var server = new SshAgentServer(consent);
        var profileId = Guid.NewGuid();
        var (_, key) = MintRsaKey("integration");
        server.SetKeys(new AgentKey[] { key }, profileId);

        var ms = new MemoryStream();
        WriteSshString(ms, key.PublicKeyBlob);
        WriteSshString(ms, System.Text.Encoding.UTF8.GetBytes("payload"));
        // Intentionally omit the flags u32 — exercises the "afterData < 4" fallback.

        var response = await server.HandleSignRequestAsync(ms.ToArray(), profileId, CancellationToken.None);
        response[0].Should().Be(14);
        var sigBlobLen = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(response.AsSpan(1, 4));
        var sigBlob = response.AsSpan(5, sigBlobLen).ToArray();
        var fmtLen = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(sigBlob.AsSpan(0, 4));
        System.Text.Encoding.ASCII.GetString(sigBlob, 4, fmtLen).Should().Be("ssh-rsa");
    }

    private static void WriteSshString(MemoryStream ms, byte[] data)
    {
        var u32 = new byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(u32, (uint)data.Length);
        ms.Write(u32);
        ms.Write(data);
    }
}
