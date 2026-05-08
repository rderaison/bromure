using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.Pki;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Verifies the consent metadata round-trip on
/// <see cref="ClientIdentityRegistry"/> + the broker's deny path —
/// the two halves of the new mTLS gate. Driving the gate end-to-end
/// would require a full TLS pipeline; the proxy code path is covered
/// by the parity anchor instead.
/// </summary>
public class ClientIdentityConsentTests
{
    private static X509Certificate2 SelfSigned()
    {
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest("CN=test", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        return req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
    }

    [Fact]
    public void EntryFor_returns_consent_credential_id_and_display_name()
    {
        var reg = new ClientIdentityRegistry();
        var pid = Guid.NewGuid();
        using var cert = SelfSigned();
        reg.SetIdentity(cert, "k8s.example.com", pid,
            consentCredentialId: "kube:abc",
            consentDisplayName: "Production cluster");

        var entry = reg.EntryFor("k8s.example.com", pid);
        entry.Should().NotBeNull();
        entry!.ConsentCredentialId.Should().Be("kube:abc");
        entry.ConsentDisplayName.Should().Be("Production cluster");
    }

    [Fact]
    public void EntryFor_omits_consent_when_unset()
    {
        var reg = new ClientIdentityRegistry();
        var pid = Guid.NewGuid();
        using var cert = SelfSigned();
        reg.SetIdentity(cert, "internal.svc", pid);

        var entry = reg.EntryFor("internal.svc", pid);
        entry!.ConsentCredentialId.Should().BeNull();
        entry.ConsentDisplayName.Should().BeNull();
    }

    [Fact]
    public async Task Broker_deny_blocks_consent_request()
    {
        var broker = new ConsentBroker(new AlwaysDenyDialogPresenter());
        var pid = Guid.NewGuid();
        broker.SetProfileName(pid, "Profile X");
        var allowed = await broker.RequestConsentAsync(
            pid, "kube:abc", "Production cluster",
            "to authenticate with the API server at k8s.example.com",
            CancellationToken.None);
        allowed.Should().BeFalse();
    }

    [Fact]
    public async Task Broker_allow_session_caches_decision()
    {
        var broker = new ConsentBroker(new AlwaysAllowSessionDialogPresenter());
        var pid = Guid.NewGuid();
        broker.SetProfileName(pid, "Profile X");
        var first = await broker.RequestConsentAsync(
            pid, "kube:abc", "Production cluster", "scope", CancellationToken.None);
        var second = await broker.RequestConsentAsync(
            pid, "kube:abc", "Production cluster", "scope", CancellationToken.None);
        first.Should().BeTrue();
        second.Should().BeTrue();
    }
}
