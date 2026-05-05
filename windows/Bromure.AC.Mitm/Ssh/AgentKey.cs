namespace Bromure.AC.Mitm.Ssh;

/// <summary>
/// Direct port of <c>AgentKey</c> from <c>SSHAgent.swift</c>. One ed25519
/// keypair available to a profile via the agent.
/// </summary>
public sealed record AgentKey(
    string Comment,
    /// Raw 32-byte ed25519 public key.
    byte[] PublicKey,
    /// Raw 32-byte ed25519 seed. In-process visibility is fine — the
    /// security model is "never crosses vsock", not "never visible to
    /// any C# code".
    byte[] Seed,
    bool RequireApproval = false,
    /// Stable consent ID — identifies the underlying credential across
    /// session restarts. Null = derive from the public-key fingerprint.
    string? ConsentCredentialId = null)
{
    /// <summary>
    /// SSH-protocol-formatted public key blob, the wire format the
    /// agent advertises and that ssh clients hand back in sign requests:
    /// <c>string("ssh-ed25519") + string(raw32-byte-public-key)</c>.
    /// </summary>
    public byte[] PublicKeyBlob => OpenSshKeyFormat.Ed25519PublicBlob(PublicKey);
}
