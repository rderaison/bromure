using Bromure.AC.Mitm.Consent;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Regression coverage for the bug-comb finding: if the consent
/// presenter throws (dispatcher failure during shutdown, OOM,
/// MainWindow null), the driver's exception used to abandon
/// _pending[key] populated, hanging every subsequent caller for the
/// same (profileId, credentialId) tuple forever (cascading deadlock
/// of every swap / sign on that credential).
/// </summary>
public class ConsentBrokerCascadeTests
{
    private sealed class ThrowingPresenter : IConsentDialogPresenter
    {
        public int Calls;
        public Task<ConsentBroker.Decision> AskAsync(string profileName, string credentialDisplayName, string scopeHint, CancellationToken ct)
        {
            Calls++;
            throw new InvalidOperationException("simulated dispatcher failure");
        }
    }

    [Fact]
    public async Task PresenterException_ReleasesPendingAndAllowsRetry()
    {
        var presenter = new ThrowingPresenter();
        var broker = new ConsentBroker(presenter);
        var profileId = Guid.NewGuid();
        var credId = "ssh-key/test";

        // First call: driver hits the presenter, presenter throws.
        Func<Task> first = () => broker.RequestConsentAsync(profileId, credId, "Test", "to test", CancellationToken.None);
        await first.Should().ThrowAsync<InvalidOperationException>();

        // Second call: must NOT hang. Either reaches the presenter
        // (which throws again) or returns deny — both acceptable; the
        // bug was that the call hung forever waiting on a TCS that
        // would never be resolved.
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        Func<Task> second = () => broker.RequestConsentAsync(profileId, credId, "Test", "to test", cts.Token);
        await second.Should().ThrowAsync<Exception>();
        cts.IsCancellationRequested.Should().BeFalse("the call returned before the 2s timeout (not hung)");
        presenter.Calls.Should().Be(2, "the second call must reach the presenter, proving _pending was released");
    }

    [Fact]
    public async Task ConcurrentCoalescedWaiters_AllResolveOnPresenterException()
    {
        var presenter = new ThrowingPresenter();
        var broker = new ConsentBroker(presenter);
        var profileId = Guid.NewGuid();
        var credId = "ssh-key/test";

        // Race two calls so the second one coalesces under the first
        // (becomes a non-driver waiter). When the driver fails, both
        // must resolve — coalesced waiters used to leak too.
        var first = broker.RequestConsentAsync(profileId, credId, "Test", "to test", CancellationToken.None);
        var second = broker.RequestConsentAsync(profileId, credId, "Test", "to test", CancellationToken.None);

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var both = Task.WhenAll(
            first.ContinueWith(_ => 0, cts.Token),
            second.ContinueWith(_ => 0, cts.Token));
        await both;
        cts.IsCancellationRequested.Should().BeFalse("both calls resolved before timeout");
    }
}
