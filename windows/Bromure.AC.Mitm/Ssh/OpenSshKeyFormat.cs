// macos-source: Sources/AgentCoding/Mitm/OpenSSHKeyFormat.swift @ 7e01322b8b99
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

    /// <summary>
    /// Inverse of <see cref="Ed25519Pem"/>: decode an unencrypted
    /// OpenSSH-format ed25519 private key into its raw seed + public
    /// halves. Returns null when the PEM isn't ours to parse — bad
    /// magic, multiple keys, encrypted, or non-ed25519. Throwing
    /// here would force every caller to catch; returning null lets
    /// the engine quietly skip malformed entries.
    /// </summary>
    public static (byte[] Seed, byte[] PublicKey)? ParseEd25519PrivatePem(string pem)
    {
        if (string.IsNullOrWhiteSpace(pem)) return null;
        var sb = new StringBuilder();
        foreach (var rawLine in pem.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("-----", StringComparison.Ordinal)) continue;
            sb.Append(line);
        }
        byte[] blob;
        try { blob = Convert.FromBase64String(sb.ToString()); }
        catch { return null; }
        var idx = 0;
        if (blob.Length < 15) return null;
        var magic = Encoding.ASCII.GetString(blob, 0, 14);
        if (magic != "openssh-key-v1") return null;
        if (blob[14] != 0) return null;
        idx = 15;

        if (!TryReadSshString(blob, ref idx, out var cipher)) return null;
        if (Encoding.ASCII.GetString(cipher) != "none") return null; // no encrypted-key support
        if (!TryReadSshString(blob, ref idx, out _)) return null;     // kdfName
        if (!TryReadSshString(blob, ref idx, out _)) return null;     // kdfOptions
        if (!TryReadU32Be(blob, ref idx, out var keyCount)) return null;
        if (keyCount != 1) return null;
        if (!TryReadSshString(blob, ref idx, out var pubBlob)) return null;

        // Validate the public-key blob is ed25519.
        var pIdx = 0;
        if (!TryReadSshString(pubBlob, ref pIdx, out var pubType)) return null;
        if (Encoding.ASCII.GetString(pubType) != "ssh-ed25519") return null;
        if (!TryReadSshString(pubBlob, ref pIdx, out var publicKey)) return null;
        if (publicKey.Length != 32) return null;

        if (!TryReadSshString(blob, ref idx, out var privSection)) return null;
        // privSection: check (4) || check (4) || keyType (string) ||
        //              public (string) || expanded (string with 64 bytes) || comment (string) || padding
        if (privSection.Length < 8) return null;
        var sIdx = 8; // skip check1+check2
        if (!TryReadSshString(privSection, ref sIdx, out var sKeyType)) return null;
        if (Encoding.ASCII.GetString(sKeyType) != "ssh-ed25519") return null;
        if (!TryReadSshString(privSection, ref sIdx, out _)) return null; // dup public
        if (!TryReadSshString(privSection, ref sIdx, out var expanded)) return null;
        if (expanded.Length != 64) return null;

        var seed = new byte[32];
        Buffer.BlockCopy(expanded, 0, seed, 0, 32);
        return (seed, publicKey);
    }

    private static bool TryReadU32Be(byte[] blob, ref int idx, out uint v)
    {
        v = 0;
        if (idx + 4 > blob.Length) return false;
        v = BinaryPrimitives.ReadUInt32BigEndian(blob.AsSpan(idx, 4));
        idx += 4;
        return true;
    }

    private static bool TryReadSshString(byte[] blob, ref int idx, out byte[] data)
    {
        data = Array.Empty<byte>();
        if (!TryReadU32Be(blob, ref idx, out var len)) return false;
        if (idx + len > blob.Length) return false;
        data = new byte[len];
        Buffer.BlockCopy(blob, idx, data, 0, (int)len);
        idx += (int)len;
        return true;
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
