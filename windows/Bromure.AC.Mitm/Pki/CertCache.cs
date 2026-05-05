using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography.X509Certificates;
using Org.BouncyCastle.Asn1;
using Org.BouncyCastle.Asn1.Sec;
using Org.BouncyCastle.Asn1.X509;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Operators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Math;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.X509;

namespace Bromure.AC.Mitm.Pki;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/CertCache.swift</c>.
/// Mints + caches per-host TLS leaf certificates signed by the
/// <see cref="BromureCa"/>. Same host repeated → cached
/// <see cref="X509Certificate2"/> (no re-mint). Different host → fresh
/// cert with that host as the CN + SAN.
/// </summary>
public sealed class CertCache
{
    private readonly BromureCa _ca;
    private readonly ConcurrentDictionary<string, X509Certificate2> _cache =
        new(StringComparer.OrdinalIgnoreCase);

    public CertCache(BromureCa ca) => _ca = ca;

    /// <summary>
    /// Returns a cert+key pair ready for <c>SslStream.AuthenticateAsServer</c>.
    /// Generated lazily, cached for the process lifetime.
    /// </summary>
    public X509Certificate2 IdentityFor(string host)
        => _cache.GetOrAdd(host, MintLeaf);

    private X509Certificate2 MintLeaf(string host)
    {
        // Per-host EC key. Sharing a single key across leaves would let
        // a leaked leaf re-impersonate every host; per-host keys keep
        // blast radius scoped to the leaked host.
        var generator = new ECKeyPairGenerator();
        generator.Init(new ECKeyGenerationParameters(
            SecObjectIdentifiers.SecP256r1, new SecureRandom()));
        var leafKey = generator.GenerateKeyPair();

        var subject = new X509Name("CN=" + EscapeDn(host));
        var now = DateTime.UtcNow;

        var gen = new X509V3CertificateGenerator();
        gen.SetSerialNumber(new BigInteger(160, new SecureRandom()).Abs());
        gen.SetIssuerDN(_ca.Certificate.SubjectDN);
        gen.SetSubjectDN(subject);
        // notBefore back-dated 24h: the guest's clock can be hours
        // behind the host (suspended VMs freeze CLOCK_REALTIME, fresh
        // boots can lag NTP sync, the user may travel time zones
        // between sessions). A few hours' tolerance keeps TLS valid
        // while still bounding the window during which a leaked cert
        // could be presented as "issued in the past".
        gen.SetNotBefore(now.AddHours(-24));
        gen.SetNotAfter(now.AddYears(1));
        gen.SetPublicKey(leafKey.Public);

        gen.AddExtension(X509Extensions.BasicConstraints, critical: true,
            new BasicConstraints(cA: false));
        gen.AddExtension(X509Extensions.KeyUsage, critical: true,
            new KeyUsage(KeyUsage.DigitalSignature | KeyUsage.KeyEncipherment));
        gen.AddExtension(X509Extensions.ExtendedKeyUsage, critical: false,
            new ExtendedKeyUsage(KeyPurposeID.id_kp_serverAuth));
        gen.AddExtension(X509Extensions.SubjectAlternativeName, critical: false,
            BuildSan(host));

        var sigFactory = new Asn1SignatureFactory("SHA256WITHECDSA", _ca.KeyPair.Private);
        var cert = gen.Generate(sigFactory);

        return BromureCa.BuildServerCertificate(cert, leafKey);
    }

    private static GeneralNames BuildSan(string host)
    {
        if (IPAddress.TryParse(host, out var ip))
        {
            return new GeneralNames(new GeneralName(GeneralName.IPAddress, ip.ToString()));
        }
        return new GeneralNames(new GeneralName(GeneralName.DnsName, host));
    }

    /// <summary>
    /// Escape a value to drop into a DN safely. BC's X509Name ctor parses
    /// commas/equals as separators; hosts shouldn't carry those, but
    /// belt-and-braces.
    /// </summary>
    private static string EscapeDn(string s) =>
        s.Replace("\\", "\\\\").Replace(",", "\\,").Replace("=", "\\=").Replace("+", "\\+");
}
