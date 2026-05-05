using System.Security.Cryptography.X509Certificates;
using Bromure.Platform;

namespace Bromure.Cloud;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/CloudMTLSIdentity.swift</c>.
///
/// <para><b>macOS approach.</b> Build a <c>SecIdentity</c> in-memory from
/// the stored leaf cert + RSA private key via PKCS#12. Never touches the
/// system keychain.</para>
///
/// <para><b>Windows approach.</b> .NET 8's <c>X509Certificate2.CreateFromPem</c>
/// reads PEM cert + PEM PKCS#1/PKCS#8 private key directly into a
/// memory-only X509Certificate2 with the private key attached. No Windows
/// cert store interaction; safe to load multiple identities side-by-side
/// in a single process.</para>
/// </summary>
public sealed class FileBackedCloudMtlsIdentity : ICloudMtlsIdentity, IDisposable
{
    private const string LeafCertBlobName = "ac-mtls-leaf-cert-pem";
    private const string LeafKeyBlobName = "ac-mtls-leaf-key-pem";

    private readonly object _gate = new();
    private readonly ISecretStore _store;
    private X509Certificate2? _cached;

    public FileBackedCloudMtlsIdentity(ISecretStore store) => _store = store;

    public X509CertificateCollection ClientCertificates
    {
        get
        {
            var c = LoadOrBuild();
            return c is null
                ? new X509CertificateCollection()
                : new X509CertificateCollection(new X509Certificate[] { c });
        }
    }

    public X509Certificate? SelectCertificate() => LoadOrBuild();

    /// <summary>Drop the cached identity (call after leaf rotation).</summary>
    public void Purge()
    {
        lock (_gate)
        {
            _cached?.Dispose();
            _cached = null;
        }
    }

    public void StorePem(string certPem, string keyPem)
    {
        _store.StoreBlob(LeafCertBlobName, System.Text.Encoding.UTF8.GetBytes(certPem), BlobScope.LocalMachine);
        _store.StoreBlob(LeafKeyBlobName, System.Text.Encoding.UTF8.GetBytes(keyPem), BlobScope.LocalMachine);
        Purge();
    }

    private X509Certificate2? LoadOrBuild()
    {
        lock (_gate)
        {
            if (_cached is not null) return _cached;
            var certBlob = _store.ReadBlob(LeafCertBlobName, BlobScope.LocalMachine);
            var keyBlob = _store.ReadBlob(LeafKeyBlobName, BlobScope.LocalMachine);
            if (certBlob is null || keyBlob is null) return null;

            try
            {
                var certPem = System.Text.Encoding.UTF8.GetString(certBlob);
                var keyPem = System.Text.Encoding.UTF8.GetString(keyBlob);
                var built = X509Certificate2.CreateFromPem(certPem, keyPem);
                // CreateFromPem returns an X509Certificate2 with an
                // ephemeral key attached. On Windows the SslStream layer
                // needs the cert to have a persisted key; round-trip
                // through pfx export to land an exportable, persisted form.
                var pfx = built.Export(X509ContentType.Pfx);
                _cached = new X509Certificate2(pfx, (string?)null,
                    X509KeyStorageFlags.EphemeralKeySet);
                built.Dispose();
                return _cached;
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    public void Dispose() => Purge();
}
