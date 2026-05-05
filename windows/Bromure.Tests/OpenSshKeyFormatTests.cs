using System.Buffers.Binary;
using System.Text;
using Bromure.AC.Mitm.Ssh;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class OpenSshKeyFormatTests
{
    [Fact]
    public void Ed25519Pem_BeginsAndEndsWithStandardOpenSshHeaders()
    {
        var seed = new byte[32];
        var pub = new byte[32];
        for (var i = 0; i < 32; i++) { seed[i] = (byte)i; pub[i] = (byte)(255 - i); }

        var pem = Encoding.ASCII.GetString(OpenSshKeyFormat.Ed25519Pem(seed, pub, "tester"));
        pem.Should().StartWith("-----BEGIN OPENSSH PRIVATE KEY-----");
        pem.Should().EndWith("-----END OPENSSH PRIVATE KEY-----\n");
    }

    [Fact]
    public void Ed25519Pem_RejectsMisSizedSeed()
    {
        var pub = new byte[32];
        FluentActions.Invoking(() => OpenSshKeyFormat.Ed25519Pem(new byte[31], pub, "x"))
            .Should().Throw<ArgumentException>();
    }

    [Fact]
    public void Ed25519PublicBlob_FollowsSshWireFormat()
    {
        var pub = new byte[32];
        for (var i = 0; i < 32; i++) pub[i] = (byte)i;

        var blob = OpenSshKeyFormat.Ed25519PublicBlob(pub);
        // u32(11) "ssh-ed25519" u32(32) <pub32>
        var expected = new MemoryStream();
        Span<byte> u32 = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(u32, 11); expected.Write(u32);
        expected.Write(Encoding.ASCII.GetBytes("ssh-ed25519"));
        BinaryPrimitives.WriteUInt32BigEndian(u32, 32); expected.Write(u32);
        expected.Write(pub);
        blob.Should().Equal(expected.ToArray());
    }
}
