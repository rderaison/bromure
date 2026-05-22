using Bromure.AC.Mitm.Consent;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for ConsentBroker.Snapshot / Revoke / RevokeEverything —
/// the operations ApprovalsViewModel surfaces. The audit flagged
/// Windows Approvals as a stub; the VM + view actually wire them
/// already, these tests pin the broker contract so the UI keeps
/// working when grants/denies are mutated underneath.
/// </summary>
public class ConsentBrokerTests
{
    [Fact]
    public async Task Snapshot_AfterAllowGrant_HasAllowEntry()
    {
        var broker = new ConsentBroker(new AlwaysAllowSessionDialogPresenter());
        var profileId = Guid.NewGuid();
        broker.SetProfileName(profileId, "test");

        var allowed = await broker.RequestConsentAsync(
            profileId, "cred-1", "Test Credential",
            "test scope", CancellationToken.None);

        allowed.Should().BeTrue();
        var snap = broker.Snapshot();
        snap.Should().ContainSingle(e =>
            e.ProfileId == profileId && e.CredentialId == "cred-1"
            && e.Kind == ConsentBroker.DecisionKind.Allow);
    }

    [Fact]
    public async Task Revoke_RemovesEntryFromSnapshot()
    {
        var broker = new ConsentBroker(new AlwaysAllowSessionDialogPresenter());
        var profileId = Guid.NewGuid();
        broker.SetProfileName(profileId, "test");
        await broker.RequestConsentAsync(profileId, "cred-1", "X", "scope", CancellationToken.None);
        broker.Snapshot().Should().NotBeEmpty();

        broker.Revoke(profileId, "cred-1");
        broker.Snapshot().Should().BeEmpty();
    }

    [Fact]
    public async Task RevokeEverything_ClearsAllProfilesAndCreds()
    {
        var broker = new ConsentBroker(new AlwaysAllowSessionDialogPresenter());
        var p1 = Guid.NewGuid();
        var p2 = Guid.NewGuid();
        broker.SetProfileName(p1, "a");
        broker.SetProfileName(p2, "b");
        await broker.RequestConsentAsync(p1, "c1", "X", "scope", CancellationToken.None);
        await broker.RequestConsentAsync(p1, "c2", "Y", "scope", CancellationToken.None);
        await broker.RequestConsentAsync(p2, "c3", "Z", "scope", CancellationToken.None);
        broker.Snapshot().Should().HaveCount(3);

        broker.RevokeEverything();
        broker.Snapshot().Should().BeEmpty();
    }

    [Fact]
    public async Task RevokeAllForProfile_KeepsOtherProfileIntact()
    {
        var broker = new ConsentBroker(new AlwaysAllowSessionDialogPresenter());
        var p1 = Guid.NewGuid();
        var p2 = Guid.NewGuid();
        broker.SetProfileName(p1, "a");
        broker.SetProfileName(p2, "b");
        await broker.RequestConsentAsync(p1, "c", "X", "scope", CancellationToken.None);
        await broker.RequestConsentAsync(p2, "c", "Y", "scope", CancellationToken.None);

        broker.RevokeAllForProfile(p1);
        var remaining = broker.Snapshot();
        remaining.Should().ContainSingle(e => e.ProfileId == p2);
        remaining.Should().NotContain(e => e.ProfileId == p1);
    }
}
