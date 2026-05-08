// macos-source: Sources/AgentCoding/CloudMTLSIdentity.swift @ 905dd3dd2742
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Bromure.AC.Core.Enrollment;
using Bromure.Cloud;

namespace Bromure.AC.Cloud;

/// <summary>
/// Adapter that exposes the install's leaf cert + RSA private key
/// (already persisted by <see cref="EnrollmentStore"/>) as an
/// <see cref="ICloudMtlsIdentity"/> for the cloud uploader. Mirrors
/// the macOS <c>BACInstallMTLSIdentity</c> which builds an in-memory
/// <c>SecIdentity</c> from the same material.
/// </summary>
public sealed class EnrollmentCloudMtlsIdentity : ICloudMtlsIdentity, IDisposable
{
    private readonly EnrollmentStore _store;
    private readonly object _gate = new();
    private X509Certificate2? _cached;
    private string? _cachedSerial;

    public EnrollmentCloudMtlsIdentity(EnrollmentStore store) => _store = store;

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
            _cachedSerial = null;
        }
    }

    private X509Certificate2? LoadOrBuild()
    {
        lock (_gate)
        {
            var serial = _store.LoadLeafSerial();
            if (serial is null) return null;

            // Rebuild on rotation — the EnrollmentStore promotes the
            // serial pointer atomically, so a serial change means
            // there's a new (cert, key) pair on disk.
            if (_cached is not null && string.Equals(_cachedSerial, serial, StringComparison.OrdinalIgnoreCase))
                return _cached;

            var certPem = _store.LoadLeafCertPem();
            var keyDer = _store.LoadLeafPrivateKey(serial);
            if (certPem is null || keyDer is null) return null;

            try
            {
                var cert = X509Certificate2.CreateFromPem(certPem);
                using var rsa = RSA.Create();
                rsa.ImportPkcs8PrivateKey(keyDer, out _);
                using var withKey = cert.CopyWithPrivateKey(rsa);
                cert.Dispose();

                // Round-trip through PFX so SslStream sees a persisted
                // key. EphemeralKeySet fails Schannel server-auth on
                // some Windows revisions; UserKeySet is the safe pick.
                var pfx = withKey.Export(X509ContentType.Pfx);
                _cached?.Dispose();
                _cached = new X509Certificate2(pfx, (string?)null,
                    X509KeyStorageFlags.UserKeySet | X509KeyStorageFlags.Exportable);
                _cachedSerial = serial;
                return _cached;
            }
            catch (Exception)
            {
                _cached = null;
                _cachedSerial = null;
                return null;
            }
        }
    }

    public void Dispose() => Purge();
}
