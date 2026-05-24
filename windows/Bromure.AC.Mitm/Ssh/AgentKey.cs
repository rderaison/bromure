// macos-source: Sources/AgentCoding/Mitm/SSHAgent.swift @ 7c8491d4a21f
using System.Security.Cryptography;

namespace Bromure.AC.Mitm.Ssh;

/// <summary>
/// One keypair available to a profile via the agent. Polymorphic so the
/// SSH agent server (and the host-side named-pipe agent) can hold ed25519
/// + RSA keys side-by-side. Sign is dispatched per-type so the response
/// signature format matches the key shape — RFC 4253 ssh-ed25519,
/// RFC 8332 rsa-sha2-256 / rsa-sha2-512.
///
/// <para>Common fields (<see cref="Comment"/>, <see cref="PublicKey"/>,
/// <see cref="RequireApproval"/>, <see cref="ConsentCredentialId"/>) live
/// on the base; algorithm-specific private material lives on the derived
/// type. Callers iterate <c>IEnumerable&lt;AgentKey&gt;</c> and dispatch
/// via <see cref="Sign"/> / <see cref="PublicKeyBlob"/> without caring
/// which type they got.</para>
/// </summary>
public abstract record AgentKey(
    string Comment,
    /// Raw public-key material (for fingerprinting / consent IDs).
    /// Ed25519: 32-byte point. RSA: the SSH-wire public blob bytes
    /// (cheap to re-hash + matches macOS fingerprint computation).
    byte[] PublicKey,
    bool RequireApproval = false,
    /// Stable consent ID — identifies the underlying credential across
    /// session restarts. Null = derive from the public-key fingerprint.
    string? ConsentCredentialId = null)
{
    /// <summary>SSH key-type string: "ssh-ed25519", "ssh-rsa", etc.
    /// Used to advertise in IDENTITIES_ANSWER and to default-format
    /// the signature when no algorithm flags were sent.</summary>
    public abstract string KeyType { get; }

    /// <summary>SSH-wire public blob: <c>string(KeyType) string(material…)</c>.
    /// Identical to what <c>ssh-add -L</c> emits for the same key.</summary>
    public abstract byte[] PublicKeyBlob { get; }

    /// <summary>Sign <paramref name="data"/>. <paramref name="flags"/>
    /// is the u32 from the tail of <c>SSH_AGENTC_SIGN_REQUEST</c>:
    /// bit 1 (0x02) selects rsa-sha2-256, bit 2 (0x04) selects
    /// rsa-sha2-512, no bits = the key's default algorithm. Returns
    /// the signature plus the algorithm name we used (which the
    /// caller wraps in <c>ssh-string(format) ssh-string(sig)</c>).</summary>
    public abstract (byte[] Signature, string Format) Sign(byte[] data, uint flags);
}

public sealed record Ed25519AgentKey(
    string Comment,
    byte[] PublicKey,
    /// 32-byte ed25519 seed. In-process visibility is fine — the
    /// security model is "never crosses vsock", not "never visible to
    /// any C# code".
    byte[] Seed,
    bool RequireApproval = false,
    string? ConsentCredentialId = null)
    : AgentKey(Comment, PublicKey, RequireApproval, ConsentCredentialId)
{
    public override string KeyType => "ssh-ed25519";
    public override byte[] PublicKeyBlob => OpenSshKeyFormat.Ed25519PublicBlob(PublicKey);
    public override (byte[] Signature, string Format) Sign(byte[] data, uint flags)
    {
        // RFC 8709 ed25519 has no flag-driven variants. The flags
        // argument is intentionally ignored.
        var keyParams = new Org.BouncyCastle.Crypto.Parameters.Ed25519PrivateKeyParameters(Seed, 0);
        var signer = new Org.BouncyCastle.Crypto.Signers.Ed25519Signer();
        signer.Init(forSigning: true, keyParams);
        signer.BlockUpdate(data, 0, data.Length);
        return (signer.GenerateSignature(), "ssh-ed25519");
    }
}

/// <summary>
/// RSA agent key. Carries the full RSA private parameters so we can
/// emit RFC 8332 rsa-sha2-256 / rsa-sha2-512 signatures (modern OpenSSH
/// servers reject ssh-rsa+SHA-1 by default since 8.8). The default
/// algorithm when no flag bits are sent stays "ssh-rsa" (SHA-1) for
/// compatibility with older daemons.
/// </summary>
public sealed record RsaAgentKey(
    string Comment,
    /// Pre-computed SSH-wire public blob (for fingerprinting / dedupe).
    byte[] PublicKey,
    RSAParameters Parameters,
    bool RequireApproval = false,
    string? ConsentCredentialId = null)
    : AgentKey(Comment, PublicKey, RequireApproval, ConsentCredentialId)
{
    public override string KeyType => "ssh-rsa";
    public override byte[] PublicKeyBlob
        => OpenSshKeyFormat.RsaPublicBlob(Parameters.Exponent!, Parameters.Modulus!);

    public override (byte[] Signature, string Format) Sign(byte[] data, uint flags)
    {
        // RFC 8332 / OpenSSH SSH_AGENT_RSA_SHA2 bits:
        //   0x02 SSH_AGENT_RSA_SHA2_256
        //   0x04 SSH_AGENT_RSA_SHA2_512
        // Default (no bits) = legacy "ssh-rsa" with SHA-1.
        HashAlgorithmName hash;
        string format;
        if ((flags & 0x04) != 0) { hash = HashAlgorithmName.SHA512; format = "rsa-sha2-512"; }
        else if ((flags & 0x02) != 0) { hash = HashAlgorithmName.SHA256; format = "rsa-sha2-256"; }
        else { hash = HashAlgorithmName.SHA1; format = "ssh-rsa"; }
        using var rsa = RSA.Create();
        rsa.ImportParameters(Parameters);
        return (rsa.SignData(data, hash, RSASignaturePadding.Pkcs1), format);
    }
}
