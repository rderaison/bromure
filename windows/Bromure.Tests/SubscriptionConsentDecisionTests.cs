using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for <see cref="SubscriptionConsentDecision.Resolve"/>.
/// Wired in this session — the audit flagged subscription-token
/// consent state (Accepted / Declined / Unset) as missing so a
/// "Never for this profile" choice couldn't stick.
/// </summary>
public class SubscriptionConsentDecisionTests
{
    private static SubscriptionConsentDecision.UserPrompt NeverAsk = (_, _) =>
        throw new InvalidOperationException("prompt was not expected to fire");

    [Fact]
    public void Accepted_State_SkipsPromptAndProceeds()
    {
        using var t = new TempStoreFixture();
        var profile = new Profile
        {
            Id = Guid.NewGuid(),
            SubscriptionTokenSwap = SubscriptionTokenSwapState.Accepted,
        };
        t.Store.Save(profile);

        var allowed = SubscriptionConsentDecision.Resolve(
            profile.Id, SubscriptionConsentDecision.ProviderKind.Claude, t.Store, NeverAsk);
        allowed.Should().BeTrue();
    }

    [Fact]
    public void Declined_State_SkipsPromptAndRefuses()
    {
        using var t = new TempStoreFixture();
        var profile = new Profile
        {
            Id = Guid.NewGuid(),
            SubscriptionTokenSwap = SubscriptionTokenSwapState.Declined,
        };
        t.Store.Save(profile);

        var allowed = SubscriptionConsentDecision.Resolve(
            profile.Id, SubscriptionConsentDecision.ProviderKind.Claude, t.Store, NeverAsk);
        allowed.Should().BeFalse();
    }

    [Fact]
    public void Unset_State_AsksUser_AndAcceptPersistsToProfile()
    {
        using var t = new TempStoreFixture();
        var profile = new Profile { Id = Guid.NewGuid() };
        t.Store.Save(profile);

        var allowed = SubscriptionConsentDecision.Resolve(
            profile.Id, SubscriptionConsentDecision.ProviderKind.Claude, t.Store,
            (_, _) => true);
        allowed.Should().BeTrue();

        var reloaded = t.Store.Load(profile.Id)!;
        reloaded.SubscriptionTokenSwap.Should().Be(SubscriptionTokenSwapState.Accepted);
        // Second call now matches the Accepted branch — prompt must not fire again.
        var allowed2 = SubscriptionConsentDecision.Resolve(
            profile.Id, SubscriptionConsentDecision.ProviderKind.Claude, t.Store, NeverAsk);
        allowed2.Should().BeTrue();
    }

    [Fact]
    public void Unset_State_DeclinePersistsAndStops()
    {
        using var t = new TempStoreFixture();
        var profile = new Profile { Id = Guid.NewGuid() };
        t.Store.Save(profile);

        var allowed = SubscriptionConsentDecision.Resolve(
            profile.Id, SubscriptionConsentDecision.ProviderKind.Codex, t.Store,
            (_, _) => false);
        allowed.Should().BeFalse();

        t.Store.Load(profile.Id)!.CodexTokenSwap.Should().Be(SubscriptionTokenSwapState.Declined);
    }

    [Fact]
    public void Claude_And_Codex_States_AreIndependent()
    {
        using var t = new TempStoreFixture();
        var profile = new Profile { Id = Guid.NewGuid() };
        t.Store.Save(profile);

        // Accept Claude.
        SubscriptionConsentDecision.Resolve(profile.Id,
            SubscriptionConsentDecision.ProviderKind.Claude, t.Store, (_, _) => true)
            .Should().BeTrue();
        // Codex is still Unset → must prompt.
        var codexAsked = false;
        SubscriptionConsentDecision.Resolve(profile.Id,
            SubscriptionConsentDecision.ProviderKind.Codex, t.Store,
            (_, _) => { codexAsked = true; return false; })
            .Should().BeFalse();
        codexAsked.Should().BeTrue();
    }

    [Fact]
    public void UnknownProfile_NeverPrompts_ReturnsFalse()
    {
        using var t = new TempStoreFixture();
        var allowed = SubscriptionConsentDecision.Resolve(
            Guid.NewGuid(), SubscriptionConsentDecision.ProviderKind.Claude, t.Store, NeverAsk);
        allowed.Should().BeFalse("missing profiles can't be swapped against");
    }

    private sealed class TempStoreFixture : IDisposable
    {
        private readonly string _dir;
        public ProfileStore Store { get; }
        public TempStoreFixture()
        {
            _dir = Path.Combine(Path.GetTempPath(), "bromure-sub-consent-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_dir);
            Store = new ProfileStore(_dir);
        }
        public void Dispose() { try { Directory.Delete(_dir, recursive: true); } catch (IOException) { } }
    }
}
