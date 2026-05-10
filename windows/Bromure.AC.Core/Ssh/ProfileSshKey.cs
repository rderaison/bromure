// macos-source: Sources/AgentCoding/BromureAC.swift @ fe7e7d3a3e21
using System.Buffers.Binary;
using System.Text;
using Bromure.AC.Core.Model;
using Bromure.Platform;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;

namespace Bromure.AC.Core.Ssh;

/// <summary>
/// Per-profile Ed25519 SSH key. Mirrors the macOS source's
/// <c>makeSSHKey(in:)</c> helper. The 32-byte private seed lives in
/// the profile's host-only agent directory; the OpenSSH-format public
/// key is mirrored both into the profile's <c>id_ed25519.pub</c> file
/// and copied onto <see cref="Profile.SshPublicKey"/> for paste-into-
/// GitHub. <b>No private key file</b> in OpenSSH format is ever
/// produced — there's no plaintext form to leak.
/// </summary>
public static class ProfileSshKey
{
    /// <summary>Per-profile agent directory:
    /// <c>%LOCALAPPDATA%\Bromure\AC\agent\&lt;profileId&gt;\</c>.</summary>
    public static string DirectoryFor(IAppPaths paths, Guid profileId)
        => Path.Combine(paths.AppDataRoot, "agent", profileId.ToString("D"));

    /// <summary>Generate a fresh keypair if the profile doesn't have
    /// one yet, or always when <paramref name="force"/> is true. Updates
    /// <see cref="Profile.SshPublicKey"/> in place. Caller is
    /// responsible for persisting the profile.</summary>
    public static void EnsureExists(IAppPaths paths, Profile profile, bool force = false)
    {
        var dir = DirectoryFor(paths, profile.Id);
        var rawPath = Path.Combine(dir, "id_ed25519.raw");
        var pubPath = Path.Combine(dir, "id_ed25519.pub");

        if (!force
            && !string.IsNullOrEmpty(profile.SshPublicKey)
            && File.Exists(rawPath))
        {
            return;
        }

        Directory.CreateDirectory(dir);
        var generator = new Ed25519KeyPairGenerator();
        generator.Init(new Ed25519KeyGenerationParameters(new SecureRandom()));
        var pair = generator.GenerateKeyPair();
        var seed = ((Ed25519PrivateKeyParameters)pair.Private).GetEncoded();
        var pub = ((Ed25519PublicKeyParameters)pair.Public).GetEncoded();

        // raw layout: 32-byte seed || 32-byte public — same format
        // as the macOS port + DefaultSshKey, so the in-process
        // ssh-agent loader is unchanged.
        var raw = new byte[64];
        Buffer.BlockCopy(seed, 0, raw, 0, 32);
        Buffer.BlockCopy(pub, 0, raw, 32, 32);
        File.WriteAllBytes(rawPath, raw);

        var blob = BuildOpenSshBlob("ssh-ed25519", pub);
        var comment = "bromure-ac-" + profile.Id.ToString("N")[..8];
        var pubText = $"ssh-ed25519 {Convert.ToBase64String(blob)} {comment}";
        File.WriteAllText(pubPath, pubText);
        profile.SshPublicKey = pubText;
    }

    /// <summary>Wipe the on-disk material when a profile is deleted.</summary>
    public static void Delete(IAppPaths paths, Guid profileId)
    {
        try { Directory.Delete(DirectoryFor(paths, profileId), recursive: true); }
        catch (DirectoryNotFoundException) { }
        catch (IOException) { /* best-effort */ }
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
