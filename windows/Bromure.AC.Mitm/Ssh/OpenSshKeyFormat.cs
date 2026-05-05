using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace Bromure.AC.Mitm.Ssh;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/OpenSSHKeyFormat.swift</c>.
/// Encoder for the OpenSSH unencrypted ed25519 private-key format.
///
/// <para>We hand the PEM bytes to <c>ssh-add -</c> at session launch so
/// the per-profile bromure key lives in our private ssh-agent for the
/// duration of the session — without ever touching disk in OpenSSH form.</para>
///
/// <para>File layout (unencrypted, single-key):</para>
/// <code>
///   "openssh-key-v1\0"
///   ssh-string("none")          // cipher
///   ssh-string("none")          // kdf
///   ssh-string("")              // kdf options
///   uint32(1)                   // number of keys
///   ssh-string(public-key-blob)
///   ssh-string(private-section-padded-to-block-size)
/// </code>
/// </summary>
public static class OpenSshKeyFormat
{
    public static byte[] Ed25519Pem(ReadOnlySpan<byte> seed, ReadOnlySpan<byte> publicKey, string comment)
    {
        if (seed.Length != 32) throw new ArgumentException("ed25519 seed must be 32 bytes", nameof(seed));
        if (publicKey.Length != 32) throw new ArgumentException("ed25519 public must be 32 bytes", nameof(publicKey));

        var pubBlob = new MemoryStream();
        WriteSshString(pubBlob, "ssh-ed25519");
        WriteSshString(pubBlob, publicKey);

        var priv = new MemoryStream();
        Span<byte> check = stackalloc byte[4];
        RandomNumberGenerator.Fill(check);
        priv.Write(check);
        priv.Write(check);
        WriteSshString(priv, "ssh-ed25519");
        WriteSshString(priv, publicKey);
        var expanded = new byte[64];
        seed.CopyTo(expanded.AsSpan(0, 32));
        publicKey.CopyTo(expanded.AsSpan(32, 32));
        WriteSshString(priv, expanded);
        WriteSshString(priv, comment);

        // Pad to multiple of 8 with 0x01, 0x02, …
        const int padBlock = 8;
        var padNeeded = (padBlock - (int)(priv.Length % padBlock)) % padBlock;
        for (var i = 1; i <= padNeeded; i++) priv.WriteByte((byte)i);

        var blob = new MemoryStream();
        blob.Write(Encoding.ASCII.GetBytes("openssh-key-v1"));
        blob.WriteByte(0);
        WriteSshString(blob, "none");
        WriteSshString(blob, "none");
        WriteSshString(blob, "");
        WriteU32Be(blob, 1);
        WriteSshString(blob, pubBlob.ToArray());
        WriteSshString(blob, priv.ToArray());

        var b64 = Convert.ToBase64String(blob.ToArray());
        var pem = new StringBuilder();
        pem.Append("-----BEGIN OPENSSH PRIVATE KEY-----\n");
        for (var i = 0; i < b64.Length; i += 70)
        {
            var chunk = b64.AsSpan(i, Math.Min(70, b64.Length - i));
            pem.Append(chunk).Append('\n');
        }
        pem.Append("-----END OPENSSH PRIVATE KEY-----\n");
        return Encoding.ASCII.GetBytes(pem.ToString());
    }

    /// <summary>Public-key blob in the format ssh-add reports / ssh-agent uses.</summary>
    public static byte[] Ed25519PublicBlob(ReadOnlySpan<byte> publicKey)
    {
        var ms = new MemoryStream();
        WriteSshString(ms, "ssh-ed25519");
        WriteSshString(ms, publicKey);
        return ms.ToArray();
    }

    private static void WriteSshString(MemoryStream ms, string s)
        => WriteSshString(ms, Encoding.UTF8.GetBytes(s));

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
}
