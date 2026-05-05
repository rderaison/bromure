using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Bromure.Platform;
using Org.BouncyCastle.Asn1;
using Org.BouncyCastle.Asn1.Sec;
using Org.BouncyCastle.Asn1.X509;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Operators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Math;
using Org.BouncyCastle.OpenSsl;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.X509;

namespace Bromure.AC.Mitm.Pki;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/BromureCA.swift</c>.
/// One per host, one per app install — every per-profile leaf cert
/// minted on the fly is signed by this. The matching public certificate
/// is mounted into every VM's trust store at session boot, so guest TLS
/// clients accept our forged per-host leaves without complaint.
///
/// <para><b>Storage on Windows.</b> Per <c>WIN32_AC_PLAN.md §6 "MITM CA
/// private key storage"</c>: DPAPI with <c>LocalMachine</c> scope,
/// persisted under <see cref="IAppPaths.MachineDataRoot"/>. The public
/// cert (PEM) sits next to it as a plain file because the guest needs
/// to read it from the meta share.</para>
///
/// <para><b>Rotation.</b> <see cref="LoadOrCreate"/> regenerates if the
/// blob is missing or unwrappable; the next session pushes the new PEM
/// through the meta share, the guest's <c>update-ca-certificates</c>
/// reseats trust. Cheap.</para>
/// </summary>
public sealed class BromureCa
{
    /// <summary>Private key (BouncyCastle representation — used for signing leaves).</summary>
    public AsymmetricCipherKeyPair KeyPair { get; }

    /// <summary>Issued root certificate (BouncyCastle).</summary>
    public Org.BouncyCastle.X509.X509Certificate Certificate { get; }

    /// <summary>PEM-encoded root cert. Drop into the guest's meta share.</summary>
    public string CertificatePem { get; }

    /// <summary>
    /// Combined <see cref="X509Certificate2"/> with private key — what
    /// .NET's <c>SslStream.AuthenticateAsServer(serverCertificate)</c>
    /// expects. Built once at construction.
    /// </summary>
    public X509Certificate2 ServerCertificate { get; }

    private const string CertFileName = "mitm-ca-cert.pem";
    private const string KeyBlobName = "mitm-ca-key";

    private BromureCa(AsymmetricCipherKeyPair keyPair,
                      Org.BouncyCastle.X509.X509Certificate certificate,
                      string certificatePem,
                      X509Certificate2 serverCertificate)
    {
        KeyPair = keyPair;
        Certificate = certificate;
        CertificatePem = certificatePem;
        ServerCertificate = serverCertificate;
    }

    /// <summary>
    /// Load from <see cref="ISecretStore"/> + <see cref="IAppPaths"/>
    /// if present; otherwise mint a fresh one and persist.
    /// </summary>
    public static BromureCa LoadOrCreate(IAppPaths paths, ISecretStore secrets)
    {
        Directory.CreateDirectory(paths.MachineDataRoot);
        var certPath = Path.Combine(paths.MachineDataRoot, CertFileName);
        var keyBlob = secrets.ReadBlob(KeyBlobName, BlobScope.LocalMachine);
        if (File.Exists(certPath) && keyBlob is not null)
        {
            try
            {
                return Load(certPath, keyBlob);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[mitm] CA on disk unreadable ({ex.Message}), regenerating");
                try { File.Delete(certPath); } catch { }
                secrets.DeleteBlob(KeyBlobName, BlobScope.LocalMachine);
            }
        }
        return Mint(paths, secrets, certPath);
    }

    private static BromureCa Load(string certPath, byte[] keyBlob)
    {
        var certPem = File.ReadAllText(certPath);
        var cert = ParseCertificate(certPem);

        AsymmetricCipherKeyPair keyPair;
        using (var reader = new StringReader(Encoding.UTF8.GetString(keyBlob)))
        {
            var pemReader = new PemReader(reader);
            var obj = pemReader.ReadObject();
            keyPair = obj as AsymmetricCipherKeyPair
                ?? throw MitmException.KeyImportFailed("PEM did not contain a key pair");
        }

        var server = BuildServerCertificate(cert, keyPair);
        return new BromureCa(keyPair, cert, certPem, server);
    }

    private static BromureCa Mint(IAppPaths paths, ISecretStore secrets, string certPath)
    {
        // P-256 EC keypair — same curve macOS uses (P256.Signing.PrivateKey).
        var generator = new ECKeyPairGenerator();
        generator.Init(new ECKeyGenerationParameters(
            SecObjectIdentifiers.SecP256r1, new SecureRandom()));
        var keyPair = generator.GenerateKeyPair();

        var subject = new X509Name("CN=Bromure Agentic Coding Root CA, O=Bromure");
        var now = DateTime.UtcNow;
        var notBefore = now.AddSeconds(-60);
        var notAfter = now.AddYears(10);

        var serial = new BigInteger(160, new SecureRandom()).Abs();
        var gen = new X509V3CertificateGenerator();
        gen.SetSerialNumber(serial);
        gen.SetIssuerDN(subject);
        gen.SetSubjectDN(subject);
        gen.SetNotBefore(notBefore);
        gen.SetNotAfter(notAfter);
        gen.SetPublicKey(keyPair.Public);

        gen.AddExtension(X509Extensions.BasicConstraints, critical: true,
            new BasicConstraints(cA: true));
        gen.AddExtension(X509Extensions.KeyUsage, critical: true,
            new KeyUsage(KeyUsage.KeyCertSign | KeyUsage.CrlSign));
        gen.AddExtension(X509Extensions.SubjectKeyIdentifier, critical: false,
            new SubjectKeyIdentifier(SubjectPublicKeyInfoFactory.CreateSubjectPublicKeyInfo(keyPair.Public)));

        var sigFactory = new Asn1SignatureFactory("SHA256WITHECDSA", keyPair.Private);
        var cert = gen.Generate(sigFactory);

        var certPem = ToPem(cert);
        var keyPem = ToPem(keyPair);

        File.WriteAllText(certPath, certPem);
        secrets.StoreBlob(KeyBlobName, Encoding.UTF8.GetBytes(keyPem), BlobScope.LocalMachine);

        var server = BuildServerCertificate(cert, keyPair);
        return new BromureCa(keyPair, cert, certPem, server);
    }

    /// <summary>
    /// Build an <see cref="X509Certificate2"/> with the EC private key
    /// attached, suitable for <c>SslStream.AuthenticateAsServer</c>.
    /// </summary>
    internal static X509Certificate2 BuildServerCertificate(
        Org.BouncyCastle.X509.X509Certificate bcCert,
        AsymmetricCipherKeyPair keyPair)
    {
        // Round-trip through PKCS#12: BC encodes cert+key into a pfx
        // blob, .NET's X509Certificate2 ctor parses it back. We wipe
        // the pfx password since the resulting cert lives only in the
        // proxy process's memory.
        var store = new Org.BouncyCastle.Pkcs.Pkcs12StoreBuilder().Build();
        var entry = new Org.BouncyCastle.Pkcs.X509CertificateEntry(bcCert);
        store.SetCertificateEntry("bromure-ca", entry);
        store.SetKeyEntry("bromure-ca",
            new Org.BouncyCastle.Pkcs.AsymmetricKeyEntry(keyPair.Private),
            new[] { entry });

        using var ms = new MemoryStream();
        store.Save(ms, "x".ToCharArray(), new SecureRandom());
        var pfx = ms.ToArray();
        // EphemeralKeySet is NOT compatible with Schannel-based
        // SslStream.AuthenticateAsServer on Windows — produces
        // "Authentication failed because the platform does not
        // support ephemeral keys." Use UserKeySet so the key lands
        // in the user's CryptoAPI store, which Schannel can locate
        // when negotiating a TLS server handshake. The cert is
        // process-scoped (not persisted across restarts) and
        // exportable so we can hand the public PEM to the guest.
        return new X509Certificate2(pfx, "x",
            X509KeyStorageFlags.UserKeySet | X509KeyStorageFlags.Exportable);
    }

    internal static string ToPem(object obj)
    {
        var sw = new StringWriter();
        var writer = new PemWriter(sw);
        writer.WriteObject(obj);
        writer.Writer.Flush();
        return sw.ToString();
    }

    internal static Org.BouncyCastle.X509.X509Certificate ParseCertificate(string pem)
    {
        using var reader = new StringReader(pem);
        var pemReader = new PemReader(reader);
        return pemReader.ReadObject() as Org.BouncyCastle.X509.X509Certificate
            ?? throw new InvalidOperationException("PEM did not contain a certificate");
    }
}
