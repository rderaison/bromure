namespace Bromure.Platform;

/// <summary>
/// Replaces macOS Keychain (`PassphraseKeychain.swift` + `kSecClassGenericPassword`).
/// Two storage shapes:
///   - Short tokens / passphrases: round-trip via Credential Manager.
///   - Larger blobs (e.g. the MITM CA private key): DPAPI-wrapped under
///     <see cref="IAppPaths.MachineDataRoot"/>. LocalMachine scope so kiosk /
///     shared-machine deployments work; the BitLocker-on-by-default
///     posture on Win11 makes this materially safe per WIN32_AC_PLAN §6.
/// </summary>
public interface ISecretStore
{
    /// <summary>Store a short string (≤2.5 KB) under <paramref name="account"/>.</summary>
    void StoreSecret(string service, string account, string value);

    /// <summary>Read it back. Returns null if not found.</summary>
    string? ReadSecret(string service, string account);

    /// <summary>Delete a stored secret. No-op if absent.</summary>
    void DeleteSecret(string service, string account);

    /// <summary>Store an opaque blob (CA private key, refresh token batches).</summary>
    void StoreBlob(string name, ReadOnlySpan<byte> data, BlobScope scope);

    /// <summary>Read blob; returns null if not found.</summary>
    byte[]? ReadBlob(string name, BlobScope scope);

    /// <summary>Delete blob.</summary>
    void DeleteBlob(string name, BlobScope scope);
}

public enum BlobScope
{
    /// Tied to the calling user's profile. Roams with the user.
    CurrentUser,

    /// Tied to the machine. Survives user switch; required for the
    /// MITM CA key in shared-machine deployments.
    LocalMachine,
}
