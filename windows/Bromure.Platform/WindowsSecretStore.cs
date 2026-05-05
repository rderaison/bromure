using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;

namespace Bromure.Platform;

/// <summary>
/// Windows implementation of <see cref="ISecretStore"/>. Short secrets
/// go to Credential Manager via advapi32 (`CredWrite`/`CredRead`/`CredDelete`);
/// blobs go through DPAPI <see cref="ProtectedData"/> and are persisted
/// to disk under <see cref="IAppPaths.MachineDataRoot"/>.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsSecretStore : ISecretStore
{
    private const string EntropyConst = "bromure-ac-v1";
    private readonly IAppPaths _paths;

    public WindowsSecretStore(IAppPaths paths) => _paths = paths;

    public void StoreSecret(string service, string account, string value)
    {
        var bytes = Encoding.Unicode.GetBytes(value);
        if (bytes.Length > 2500)
        {
            throw new ArgumentException(
                "Credential Manager values are capped at 2500 bytes; use StoreBlob for larger payloads.",
                nameof(value));
        }
        var target = TargetName(service, account);
        var cred = new CREDENTIAL
        {
            Type = CRED_TYPE_GENERIC,
            TargetName = target,
            CredentialBlobSize = bytes.Length,
            Persist = CRED_PERSIST_LOCAL_MACHINE,
            UserName = account,
        };
        var bufHandle = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, bufHandle, bytes.Length);
            cred.CredentialBlob = bufHandle;
            if (!CredWrite(ref cred, 0))
            {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            Marshal.FreeHGlobal(bufHandle);
        }
    }

    public string? ReadSecret(string service, string account)
    {
        var target = TargetName(service, account);
        if (!CredRead(target, CRED_TYPE_GENERIC, 0, out var ptr))
        {
            return null;
        }
        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
            if (cred.CredentialBlobSize == 0 || cred.CredentialBlob == IntPtr.Zero)
            {
                return string.Empty;
            }
            var buf = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, buf, 0, cred.CredentialBlobSize);
            return Encoding.Unicode.GetString(buf);
        }
        finally
        {
            CredFree(ptr);
        }
    }

    public void DeleteSecret(string service, string account)
    {
        CredDelete(TargetName(service, account), CRED_TYPE_GENERIC, 0);
    }

    public void StoreBlob(string name, ReadOnlySpan<byte> data, BlobScope scope)
    {
        var path = BlobPath(name, scope);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var protectedBytes = ProtectedData.Protect(
            data.ToArray(),
            Encoding.UTF8.GetBytes(EntropyConst),
            scope == BlobScope.LocalMachine ? DataProtectionScope.LocalMachine : DataProtectionScope.CurrentUser);
        File.WriteAllBytes(path, protectedBytes);
    }

    public byte[]? ReadBlob(string name, BlobScope scope)
    {
        var path = BlobPath(name, scope);
        if (!File.Exists(path)) return null;
        var protectedBytes = File.ReadAllBytes(path);
        try
        {
            return ProtectedData.Unprotect(
                protectedBytes,
                Encoding.UTF8.GetBytes(EntropyConst),
                scope == BlobScope.LocalMachine ? DataProtectionScope.LocalMachine : DataProtectionScope.CurrentUser);
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    public void DeleteBlob(string name, BlobScope scope)
    {
        var path = BlobPath(name, scope);
        if (File.Exists(path)) File.Delete(path);
    }

    private string BlobPath(string name, BlobScope scope)
    {
        var safe = name.Replace('/', '_').Replace('\\', '_');
        var root = scope == BlobScope.LocalMachine ? _paths.MachineDataRoot : _paths.AppDataRoot;
        return Path.Combine(root, "secrets", safe + ".bin");
    }

    private static string TargetName(string service, string account)
        => $"Bromure.AC:{service}:{account}";

    // --- advapi32 P/Invoke ----------------------------------------------------

    private const int CRED_TYPE_GENERIC = 1;
    private const int CRED_PERSIST_LOCAL_MACHINE = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "CredWriteW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "CredReadW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "CredDeleteW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}
