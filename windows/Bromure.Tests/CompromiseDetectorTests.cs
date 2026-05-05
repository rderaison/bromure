using System.Text;
using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class CompromiseDetectorTests
{
    [Fact]
    public void Scan_ReturnsLeak_WhenFakeAppearsOnUnscopedHost()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(new[]
        {
            new TokenMap.Entry("brm-anthropic-fake", "real-anthropic",
                Host: "anthropic.com",
                ConsentCredentialId: "tool-apikey:claude",
                ConsentDisplayName: "Claude API key"),
        }), profile);
        var detector = new CompromiseDetector(swapper);
        detector.Rebuild(profile);

        var bytes = Encoding.UTF8.GetBytes("Authorization: Bearer brm-anthropic-fake stolen");
        var leaks = detector.Scan(profile, bytes, observedHost: "evil.com");
        leaks.Should().HaveCount(1);
        leaks[0].DeclaredHost.Should().Be("anthropic.com");
        leaks[0].ObservedHost.Should().Be("evil.com");
        leaks[0].CredentialDisplayName.Should().Be("Claude API key");
    }

    [Fact]
    public void Scan_NoLeakWhenHostInScopeFamily()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(new[]
        {
            new TokenMap.Entry("brm-fake", "real",
                Host: "api.anthropic.com",
                ConsentDisplayName: "Claude API"),
        }), profile);
        var detector = new CompromiseDetector(swapper);
        detector.Rebuild(profile);

        // Sibling subdomain under the same registered domain — fine.
        var bytes = Encoding.UTF8.GetBytes("payload contains brm-fake here");
        detector.Scan(profile, bytes, observedHost: "console.anthropic.com").Should().BeEmpty();
    }

    [Fact]
    public void Scan_EmptyForUnknownProfile()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var detector = new CompromiseDetector(swapper);
        detector.Rebuild(Guid.NewGuid());

        var bytes = Encoding.UTF8.GetBytes("nothing");
        detector.Scan(Guid.NewGuid(), bytes, observedHost: "evil.com").Should().BeEmpty();
    }
}
