using System.Security.Cryptography;
using Bromure.AC.Mitm.Trace;
using Bromure.Platform;

namespace Bromure.AC.Mitm.Vault;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/SecretsVault.swift</c>.
/// Per-install AES-256 master key + AES-GCM encrypt/decrypt helpers for
/// at-rest secret storage.
///
/// <para>On macOS the master key lives in the Data Protection Keychain
/// (app-scoped, no prompts). On Windows it's a 32-byte random key
/// stored as a DPAPI-LocalMachine blob via <see cref="ISecretStore"/>,
/// which mirrors the same threat model: bound to this device, app-
/// scoped via the DPAPI entropy, no user interaction.</para>
///
/// <para>Wiping the blob (or the install dir + uninstall) rotates the
/// key. Every existing encrypted blob becomes unreadable, but the
/// non-sensitive metadata in profile.json is unaffected — the user
/// can re-enter their API keys.</para>
/// </summary>
public sealed class SecretsVault : IBodyEncryptor
{
    private const string KeyBlobName = "vault-master-key-v1";
    private readonly ISecretStore _store;
    private readonly object _gate = new();
    private byte[]? _cachedKey;

    public SecretsVault(ISecretStore store) => _store = store;

    /// <summary>Fetch (or lazily create) the per-install master key.</summary>
    public byte[] MasterKey()
    {
        lock (_gate)
        {
            if (_cachedKey is not null) return _cachedKey;

            var existing = _store.ReadBlob(KeyBlobName, BlobScope.LocalMachine);
            if (existing is { Length: 32 })
            {
                _cachedKey = existing;
                return existing;
            }
            var fresh = RandomNumberGenerator.GetBytes(32);
            _store.StoreBlob(KeyBlobName, fresh, BlobScope.LocalMachine);
            _cachedKey = fresh;
            return fresh;
        }
    }

    /// <summary>
    /// Encrypt with the master key. Output layout matches macOS:
    /// 12-byte nonce || ciphertext || 16-byte tag (the AES-GCM "combined"
    /// form). This makes encrypted blobs interchangeable with macOS
    /// builds when both unwrap the same master key — which they don't,
    /// but the layout is the right one to keep so a future cross-host
    /// sync doesn't have to re-encode.
    /// </summary>
    public byte[] Encrypt(ReadOnlySpan<byte> plaintext)
    {
        var key = MasterKey();
        var nonce = RandomNumberGenerator.GetBytes(12);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[16];
        using var aes = new AesGcm(key, tag.Length);
        aes.Encrypt(nonce, plaintext, ciphertext, tag);

        var output = new byte[nonce.Length + ciphertext.Length + tag.Length];
        Buffer.BlockCopy(nonce, 0, output, 0, nonce.Length);
        Buffer.BlockCopy(ciphertext, 0, output, nonce.Length, ciphertext.Length);
        Buffer.BlockCopy(tag, 0, output, nonce.Length + ciphertext.Length, tag.Length);
        return output;
    }

    public byte[] Decrypt(ReadOnlySpan<byte> blob)
    {
        if (blob.Length < 12 + 16) throw new VaultException("blob too short for nonce + tag");
        var key = MasterKey();
        var nonce = blob[..12].ToArray();
        var tag = blob[(blob.Length - 16)..].ToArray();
        var ciphertext = blob[12..(blob.Length - 16)].ToArray();
        var plaintext = new byte[ciphertext.Length];
        using var aes = new AesGcm(key, tag.Length);
        aes.Decrypt(nonce, ciphertext, tag, plaintext);
        return plaintext;
    }

    /// <summary>Forget the cached key (next call re-reads from <see cref="ISecretStore"/>).</summary>
    public void ClearCache()
    {
        lock (_gate) _cachedKey = null;
    }
}

public sealed class VaultException : Exception
{
    public VaultException(string message) : base(message) { }
}
