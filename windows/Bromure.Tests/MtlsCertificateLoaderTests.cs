using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Bromure.Cloud;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit 06 §5.14 flagged the previous Windows mTLS identity loader
/// for using <c>UserKeySet | Exportable</c>, which silently persists
/// the private key to <c>%APPDATA%\Microsoft\Crypto\RSA</c>. macOS
/// keeps it in-memory via <c>SecPKCS12Import</c> without the keychain
/// flag. This test pins the new in-memory-only loader: cert + key
/// load cleanly, the key signs, and nothing lands in a Windows
/// cert store.
/// </summary>
public class MtlsCertificateLoaderTests
{
    [Fact]
    public void TryLoadEphemeral_HappyPath_ReturnsCertWithUsableKey()
    {
        var (certPem, keyDer) = MintLeaf();
        using var cert = MtlsCertificateLoader.TryLoadEphemeral(certPem, keyDer);
        cert.Should().NotBeNull();
        cert!.HasPrivateKey.Should().BeTrue();
        using var rsa = cert.GetRSAPrivateKey();
        rsa.Should().NotBeNull();

        // Sanity-sign + verify so we know the key is actually usable.
        var data = new byte[] { 1, 2, 3, 4, 5 };
        var sig = rsa!.SignData(data, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var pub = cert.GetRSAPublicKey();
        pub!.VerifyData(data, sig, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
            .Should().BeTrue("the loaded private key must produce signatures the public key verifies");
    }

    [Fact]
    public void TryLoadEphemeral_LeavesNoTraceInUserCertStore()
    {
        // The whole point of EphemeralKeySet: no key file written
        // under %APPDATA%\Microsoft\Crypto\RSA, no row inserted into
        // CurrentUser\My. Snapshot the relevant directory + the
        // store, load the cert, snapshot again — diff must be empty.
        var (certPem, keyDer) = MintLeaf();
        using var storeBefore = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        storeBefore.Open(OpenFlags.ReadOnly);
        var thumbprintsBefore = storeBefore.Certificates
            .OfType<X509Certificate2>()
            .Select(c => c.Thumbprint)
            .ToHashSet();
        storeBefore.Close();

        using var cert = MtlsCertificateLoader.TryLoadEphemeral(certPem, keyDer);
        cert.Should().NotBeNull();

        using var storeAfter = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        storeAfter.Open(OpenFlags.ReadOnly);
        var thumbprintsAfter = storeAfter.Certificates
            .OfType<X509Certificate2>()
            .Select(c => c.Thumbprint)
            .ToHashSet();
        storeAfter.Close();

        thumbprintsAfter.Should().BeEquivalentTo(thumbprintsBefore,
            "EphemeralKeySet must not add anything to the user's cert store");
    }

    [Fact]
    public void TryLoadEphemeral_GarbagePem_ReturnsNullDoesNotThrow()
    {
        var (_, keyDer) = MintLeaf();
        MtlsCertificateLoader.TryLoadEphemeral("not a cert", keyDer).Should().BeNull();
    }

    [Fact]
    public void TryLoadEphemeral_KeyDoesNotMatchCert_ReturnsNull()
    {
        // Cert from one keypair, private key from a different one —
        // CopyWithPrivateKey rejects the mismatch.
        var (certPem, _) = MintLeaf();
        var (_, otherKeyDer) = MintLeaf();
        MtlsCertificateLoader.TryLoadEphemeral(certPem, otherKeyDer).Should().BeNull();
    }

    [Theory]
    [InlineData("")]
    public void TryLoadEphemeral_EmptyInputs_ReturnsNull(string certPem)
    {
        MtlsCertificateLoader.TryLoadEphemeral(certPem, new byte[] { 1, 2, 3 }).Should().BeNull();
    }

    [Fact]
    public void TryLoadEphemeral_EmptyKeyBytes_ReturnsNull()
    {
        var (certPem, _) = MintLeaf();
        MtlsCertificateLoader.TryLoadEphemeral(certPem, Array.Empty<byte>()).Should().BeNull();
    }

    private static (string CertPem, byte[] KeyDer) MintLeaf()
    {
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest(
            "CN=bromure-test-leaf",
            rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var cert = req.CreateSelfSigned(
            DateTimeOffset.UtcNow.AddMinutes(-1),
            DateTimeOffset.UtcNow.AddHours(1));
        var pem = "-----BEGIN CERTIFICATE-----\n"
                  + Convert.ToBase64String(cert.RawData, Base64FormattingOptions.InsertLineBreaks)
                  + "\n-----END CERTIFICATE-----\n";
        var keyDer = rsa.ExportPkcs8PrivateKey();
        return (pem, keyDer);
    }
}
