using Bromure.AC.Core.Events;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit 10 §2.8: the guest→host event channel carries five
/// line-prefixed payloads (tab, closed, alive, ip, legacy). These
/// tests pin the dispatch routing and the auto-clearing semantics
/// of one-shot subscriptions (closed).
/// </summary>
public class GuestEventDispatcherTests
{
    private static readonly Guid VmA = Guid.Parse("11111111-2222-3333-4444-555555555555");
    private static readonly Guid VmB = Guid.Parse("99999999-8888-7777-6666-555555555555");
    private static readonly Guid TabA = Guid.Parse("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    private static readonly Guid TabB = Guid.Parse("12345678-1234-1234-1234-123456789abc");

    [Fact]
    public void Tab_TitleLine_DispatchesToMatchingSubscriber()
    {
        var d = new GuestEventDispatcher();
        string? captured = null;
        d.SubscribeTab(VmA, TabA, t => captured = t);

        var counts = d.Dispatch(VmA, $"tab|{TabA:N}|claude\n");
        captured.Should().Be("claude");
        counts.Tab.Should().Be(1);
    }

    [Fact]
    public void Tab_WithMismatchedVmId_DoesNotFire()
    {
        var d = new GuestEventDispatcher();
        var captured = 0;
        d.SubscribeTab(VmA, TabA, _ => captured++);

        d.Dispatch(VmB, $"tab|{TabA:N}|claude\n");
        captured.Should().Be(0);
    }

    [Fact]
    public void Closed_FiresOnce_ThenAutoClears()
    {
        var d = new GuestEventDispatcher();
        var closedHits = 0;
        d.SubscribeTabClosed(VmA, TabA, () => closedHits++);

        d.Dispatch(VmA, $"closed|{TabA:N}\n");
        d.Dispatch(VmA, $"closed|{TabA:N}\n");

        closedHits.Should().Be(1, "the closed subscription auto-clears after first fire");
    }

    [Fact]
    public void Closed_AlsoClearsTabTitleSubscription()
    {
        var d = new GuestEventDispatcher();
        var titles = 0;
        d.SubscribeTab(VmA, TabA, _ => titles++);
        d.SubscribeTabClosed(VmA, TabA, () => { });

        d.Dispatch(VmA, $"tab|{TabA:N}|claude\n");
        titles.Should().Be(1);

        d.Dispatch(VmA, $"closed|{TabA:N}\n");
        d.Dispatch(VmA, $"tab|{TabA:N}|stale\n");
        titles.Should().Be(1, "the dead tab's title subscription is reaped along with the closed one");
    }

    [Fact]
    public void Alive_NonEmptyRoster_DispatchesAsHashSet()
    {
        var d = new GuestEventDispatcher();
        IReadOnlySet<Guid>? captured = null;
        d.SubscribeAlive(VmA, set => captured = set);

        d.Dispatch(VmA, $"alive|{TabA:N},{TabB:N}\n");
        captured.Should().NotBeNull();
        captured!.Should().Contain(TabA).And.Contain(TabB).And.HaveCount(2);
    }

    [Fact]
    public void Alive_EmptyRoster_DispatchesEmptySet()
    {
        var d = new GuestEventDispatcher();
        IReadOnlySet<Guid>? captured = null;
        d.SubscribeAlive(VmA, set => captured = set);

        d.Dispatch(VmA, "alive|\n");
        captured.Should().NotBeNull();
        captured!.Should().BeEmpty();
    }

    [Fact]
    public void Alive_GarbageUuid_IsSkippedNotThrown()
    {
        var d = new GuestEventDispatcher();
        IReadOnlySet<Guid>? captured = null;
        d.SubscribeAlive(VmA, set => captured = set);

        d.Dispatch(VmA, $"alive|{TabA:N},not-a-guid,{TabB:N}\n");
        captured.Should().NotBeNull();
        captured!.Should().Contain(TabA).And.Contain(TabB).And.HaveCount(2);
    }

    [Fact]
    public void Ip_FiresPerLine_OneSubscriberPerVm()
    {
        var d = new GuestEventDispatcher();
        var capturedA = new List<string>();
        var capturedB = new List<string>();
        d.SubscribeIp(VmA, addr => capturedA.Add(addr));
        d.SubscribeIp(VmB, addr => capturedB.Add(addr));

        d.Dispatch(VmA, "ip|172.20.144.5\n");
        d.Dispatch(VmA, "ip|172.20.144.5\n"); // duplicate intentional — dispatcher doesn't de-dup
        d.Dispatch(VmB, "ip|10.0.0.7\n");

        capturedA.Should().Equal("172.20.144.5", "172.20.144.5");
        capturedB.Should().Equal("10.0.0.7");
    }

    [Fact]
    public void Ip_EmptyAddress_IsSkipped()
    {
        var d = new GuestEventDispatcher();
        var hits = 0;
        d.SubscribeIp(VmA, _ => hits++);

        d.Dispatch(VmA, "ip|\n");
        hits.Should().Be(0);
    }

    [Fact]
    public void Legacy_NonPrefixedLine_RoutesToLegacyTitleCallback()
    {
        var d = new GuestEventDispatcher();
        string? captured = null;
        d.SubscribeLegacyTitle(VmA, t => captured = t);

        d.Dispatch(VmA, "starting\n");
        captured.Should().Be("starting");
    }

    [Fact]
    public void Batch_MixedLines_DispatchAllSeparately()
    {
        var d = new GuestEventDispatcher();
        var titles = new List<string>();
        var closes = 0;
        IReadOnlySet<Guid>? lastAlive = null;
        string? lastIp = null;
        d.SubscribeTab(VmA, TabA, titles.Add);
        d.SubscribeTabClosed(VmA, TabB, () => closes++);
        d.SubscribeAlive(VmA, set => lastAlive = set);
        d.SubscribeIp(VmA, addr => lastIp = addr);

        var payload =
            $"tab|{TabA:N}|claude\n" +
            $"closed|{TabB:N}\n" +
            $"alive|{TabA:N}\n" +
            "ip|172.20.144.10\n";
        var counts = d.Dispatch(VmA, payload);

        titles.Should().Equal("claude");
        closes.Should().Be(1);
        lastAlive.Should().NotBeNull();
        lastAlive!.Should().Equal(new[] { TabA });
        lastIp.Should().Be("172.20.144.10");

        counts.Tab.Should().Be(1);
        counts.Closed.Should().Be(1);
        counts.Alive.Should().Be(1);
        counts.Ip.Should().Be(1);
        counts.Legacy.Should().Be(0);
    }

    [Fact]
    public void CrLfFraming_NormalizedToLf()
    {
        var d = new GuestEventDispatcher();
        string? captured = null;
        d.SubscribeTab(VmA, TabA, t => captured = t);

        d.Dispatch(VmA, $"tab|{TabA:N}|x\r\n");
        captured.Should().Be("x");
    }

    [Fact]
    public void Unsubscribe_NullCallback_RemovesSubscription()
    {
        var d = new GuestEventDispatcher();
        var hits = 0;
        d.SubscribeIp(VmA, _ => hits++);
        d.Dispatch(VmA, "ip|1.2.3.4\n");
        hits.Should().Be(1);

        d.SubscribeIp(VmA, null);
        d.Dispatch(VmA, "ip|1.2.3.4\n");
        hits.Should().Be(1);
    }

    [Fact]
    public void Subscribe_EmptyGuid_NoOp()
    {
        var d = new GuestEventDispatcher();
        // No throw, no subscription registered — guards against
        // dispatch from a peer whose AF_HYPERV address didn't decode.
        d.SubscribeTab(Guid.Empty, TabA, _ => { });
        d.SubscribeAlive(Guid.Empty, _ => { });
        d.SubscribeIp(Guid.Empty, _ => { });
        d.Dispatch(Guid.Empty, $"tab|{TabA:N}|claude\n");
        // No assertion needed — test passes if Dispatch doesn't throw.
    }
}
