using Bromure.Cloud;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class SessionTrackerTests
{
    [Fact]
    public void FirstActivity_OpensFreshSession()
    {
        var t = new SessionTracker();
        var profile = Guid.NewGuid();
        var bump = t.BumpActivity(profile, DateTimeOffset.UnixEpoch);
        bump.Rolled.Should().BeTrue();
        bump.PriorSessionId.Should().BeNull();
        bump.SessionId.Should().NotBeEmpty();
    }

    [Fact]
    public void RepeatActivityWithinIdleWindow_KeepsSession()
    {
        var t = new SessionTracker();
        var profile = Guid.NewGuid();
        var first = t.BumpActivity(profile, DateTimeOffset.UnixEpoch);
        var second = t.BumpActivity(profile, DateTimeOffset.UnixEpoch + TimeSpan.FromMinutes(15));

        second.Rolled.Should().BeFalse();
        second.SessionId.Should().Be(first.SessionId);
        second.PriorSessionId.Should().BeNull();
    }

    [Fact]
    public void IdleBeyondTimeout_RollsToFreshSessionAndCarriesPrior()
    {
        var t = new SessionTracker();
        var profile = Guid.NewGuid();
        var first = t.BumpActivity(profile, DateTimeOffset.UnixEpoch);
        var second = t.BumpActivity(profile, DateTimeOffset.UnixEpoch + TimeSpan.FromMinutes(25));

        second.Rolled.Should().BeTrue();
        second.PriorSessionId.Should().Be(first.SessionId);
        second.SessionId.Should().NotBe(first.SessionId);
    }

    [Fact]
    public void Close_ClearsActiveSession()
    {
        var t = new SessionTracker();
        var profile = Guid.NewGuid();
        var first = t.BumpActivity(profile);
        t.Close(profile).Should().Be(first.SessionId);
        t.Close(profile).Should().BeNull("second close finds nothing to close");
    }
}
