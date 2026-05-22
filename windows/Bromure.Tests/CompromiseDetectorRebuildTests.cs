using System.Text;
using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit 03 #1 (CRITICAL) backfill: the body-scan compromise
/// detector's Aho-Corasick scanner had to be rebuilt whenever the
/// swap map mutated (OAuth rotation, SubscriptionTokenCoordinator
/// append) or post-rotation tokens would slip past. These tests
/// pin both the rebuild contract and the MapMutated event the
/// engine subscribes to.
/// </summary>
public class CompromiseDetectorRebuildTests
{
    [Fact]
    public void Scan_BeforeRebuild_ReturnsEmpty()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var detector = new CompromiseDetector(swapper);
        var hits = detector.Scan(Guid.NewGuid(), Encoding.ASCII.GetBytes("anything"), "evil.com");
        hits.Should().BeEmpty();
    }

    [Fact]
    public void Scan_AfterRebuild_FindsFakeOutsideScope()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(new[]
        {
            new TokenMap.Entry(
                Fake: "brm-fake-claude-token-abcd1234",
                Real: "sk-ant-real-secret",
                Host: "api.anthropic.com",
                Header: EntryHeader.Authorization,
                ConsentDisplayName: "Claude OAuth"),
        }), profile);

        var detector = new CompromiseDetector(swapper);
        detector.Rebuild(profile);

        var body = Encoding.UTF8.GetBytes(
            "POST /upload HTTP/1.1\r\nHost: evil.com\r\n\r\n"
            + "uploading data with token brm-fake-claude-token-abcd1234 embedded");
        var hits = detector.Scan(profile, body, "evil.com");
        hits.Should().HaveCount(1);
        // FakeTokenPreview is redacted (start…end) so we only assert
        // it begins with the brm- prefix the fake had.
        hits[0].FakeTokenPreview.Should().StartWith("brm-");
        hits[0].DeclaredHost.Should().Be("api.anthropic.com");
        hits[0].ObservedHost.Should().Be("evil.com");
    }

    [Fact]
    public void Scan_SiblingSubdomainOfDeclaredHost_NotALeak()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(new[]
        {
            new TokenMap.Entry(
                Fake: "brm-fake-token-xyz",
                Real: "real-xyz",
                Host: "api.anthropic.com",
                Header: EntryHeader.Authorization),
        }), profile);
        var detector = new CompromiseDetector(swapper);
        detector.Rebuild(profile);

        // console.anthropic.com is a sibling — same registered
        // domain — so a fake travelling there isn't a compromise.
        var body = Encoding.UTF8.GetBytes("Authorization: Bearer brm-fake-token-xyz");
        var hits = detector.Scan(profile, body, "console.anthropic.com");
        hits.Should().BeEmpty();
    }

    [Fact]
    public void MapMutated_FiresOnSetMap()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var fired = new List<Guid>();
        swapper.MapMutated += pid => fired.Add(pid);
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), profile);
        fired.Should().Equal(new[] { profile });
    }

    [Fact]
    public void MapMutated_FiresOnAppendEntries()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), profile);
        var fired = new List<Guid>();
        swapper.MapMutated += pid => fired.Add(pid);
        swapper.AppendEntries(new[]
        {
            new TokenMap.Entry("f", "r", Host: "x", Header: EntryHeader.Authorization),
        }, profile);
        fired.Should().Equal(new[] { profile });
    }

    [Fact]
    public void Detector_AfterMapMutation_PicksUpNewFakes()
    {
        // The integration that audit 03 #1 demanded: post-OAuth
        // rotation, the new fake must be in the scanner. We
        // simulate by appending an entry and asserting the
        // detector (rebuilt by the MapMutated subscriber) finds
        // it next time it scans.
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var detector = new CompromiseDetector(swapper);
        var profile = Guid.NewGuid();
        // Subscribe just like MitmEngine does.
        swapper.MapMutated += pid => detector.Rebuild(pid);

        // Initial map — no fakes yet, scanner is empty.
        swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), profile);
        var body = Encoding.UTF8.GetBytes(
            "Authorization: Bearer brm-rotated-fake-jklmnop");
        detector.Scan(profile, body, "evil.com").Should().BeEmpty();

        // Rotation: coordinator appends the new fake. Without the
        // subscription this Scan would still come back empty.
        swapper.AppendEntries(new[]
        {
            new TokenMap.Entry(
                Fake: "brm-rotated-fake-jklmnop",
                Real: "rotated-real",
                Host: "api.anthropic.com",
                Header: EntryHeader.Authorization,
                ConsentDisplayName: "rotated claude token"),
        }, profile);

        var hits = detector.Scan(profile, body, "evil.com");
        hits.Should().HaveCount(1, "post-rotation scan must find the freshly-appended fake");
    }
}
