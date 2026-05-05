using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Bromure.Platform;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;

namespace Bromure.AC.Core.Ssh;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/DefaultSSHKey.swift</c>.
///
/// <para>One ed25519 keypair shared as the <i>default</i> across new
/// profiles. Lives at
/// <c>%LOCALAPPDATA%\Bromure\AC\default-ssh\</c> alongside an
/// <c>id_ed25519.raw</c> file (32-byte seed || 32-byte public key) and
/// <c>id_ed25519.pub</c> (OpenSSH text). New profiles forked from the
/// preferences template get this keypair copied into their own agent
/// dir at save time, matching the per-profile SSH-agent loader's
/// expectations.</para>
/// </summary>
public sealed class DefaultSshKey
{
    public sealed class GenerationException : Exception
    {
        public GenerationException(string m, Exception? inner = null) : base(m, inner) { }
    }

    private readonly IAppPaths _paths;
    public DefaultSshKey(IAppPaths paths) => _paths = paths;

    public string DirectoryPath => Path.Combine(_paths.AppDataRoot, "default-ssh");
    public string RawPath => Path.Combine(DirectoryPath, "id_ed25519.raw");
    public string PubPath => Path.Combine(DirectoryPath, "id_ed25519.pub");

    public bool Exists => File.Exists(RawPath) && File.Exists(PubPath);

    /// <summary>
    /// Generate the keypair if missing. Idempotent — safe to call
    /// unconditionally on app launch.
    /// </summary>
    public string EnsureExists()
    {
        if (Exists) return DirectoryPath;
        Directory.CreateDirectory(DirectoryPath);

        var generator = new Ed25519KeyPairGenerator();
        generator.Init(new Ed25519KeyGenerationParameters(new SecureRandom()));
        var pair = generator.GenerateKeyPair();

        var priv = (Ed25519PrivateKeyParameters)pair.Private;
        var pub = (Ed25519PublicKeyParameters)pair.Public;
        var seed = priv.GetEncoded();
        var pubBytes = pub.GetEncoded();

        var raw = new byte[64];
        Buffer.BlockCopy(seed, 0, raw, 0, 32);
        Buffer.BlockCopy(pubBytes, 0, raw, 32, 32);
        File.WriteAllBytes(RawPath, raw);

        // OpenSSH public-key text: ssh-ed25519 <base64> bromure-ac-default
        var blob = BuildOpenSshBlob("ssh-ed25519", pubBytes);
        var pubText = $"ssh-ed25519 {Convert.ToBase64String(blob)} bromure-ac-default";
        File.WriteAllText(PubPath, pubText);
        return DirectoryPath;
    }

    public string PublicKeyText()
    {
        EnsureExists();
        return File.ReadAllText(PubPath).Trim();
    }

    /// <summary>
    /// Copy the default keypair into <paramref name="agentDir"/>.
    /// Mirrors the macOS source's per-profile <c>agent/</c> dir layout.
    /// </summary>
    public void CopyTo(string agentDir)
    {
        EnsureExists();
        Directory.CreateDirectory(agentDir);
        var dstRaw = Path.Combine(agentDir, "id_ed25519.raw");
        var dstPub = Path.Combine(agentDir, "id_ed25519.pub");
        try { File.Delete(dstRaw); } catch (IOException) { }
        try { File.Delete(dstPub); } catch (IOException) { }
        File.Copy(RawPath, dstRaw);
        File.Copy(PubPath, dstPub);
    }

    private static byte[] BuildOpenSshBlob(string label, byte[] publicKey)
    {
        var ms = new MemoryStream();
        var labelBytes = Encoding.ASCII.GetBytes(label);
        Span<byte> u32 = stackalloc byte[4];

        BinaryPrimitives.WriteUInt32BigEndian(u32, (uint)labelBytes.Length);
        ms.Write(u32);
        ms.Write(labelBytes);
        BinaryPrimitives.WriteUInt32BigEndian(u32, (uint)publicKey.Length);
        ms.Write(u32);
        ms.Write(publicKey);
        return ms.ToArray();
    }
}
