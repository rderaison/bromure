namespace Bromure.AC.Core.Vault;

/// <summary>
/// Loose-coupling seam that lets the encrypted-string converter in
/// <see cref="EncryptedStringConverter"/> reach the AES-GCM encrypt/decrypt
/// implementation without taking a project reference on Bromure.AC.Mitm
/// (where <c>SecretsVault</c> lives). App startup wires the gateway by
/// assigning the two delegates; tests + tooling that don't care about
/// encryption simply leave them unset, and the converter falls through
/// to plaintext (read + write).
///
/// <para>Audit 01 §1, §10 §10 — applies the existing vault infrastructure
/// to <c>profile.json</c> secret fields so a copy of the file off-machine
/// can't be unwrapped without DPAPI-LocalMachine access to the host
/// where it was written.</para>
/// </summary>
public static class SecretsCryptoGateway
{
    /// <summary>Encrypt a UTF-8 plaintext into an opaque blob. Null when
    /// the host hasn't initialised the vault (tests, command-line tools);
    /// the converter then writes plaintext.</summary>
    public static Func<byte[], byte[]>? Encrypt { get; set; }

    /// <summary>Inverse of <see cref="Encrypt"/>. Same null semantics.</summary>
    public static Func<byte[], byte[]>? Decrypt { get; set; }

    /// <summary>Marker that distinguishes vault-encrypted blobs from
    /// legacy plaintext values in old profile.json files. Lets the
    /// converter migrate transparently on first read.</summary>
    public const string Prefix = "vault:v1:";
}
