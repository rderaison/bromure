using System.Text;
using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit 03 #2 (CRITICAL): the previous Windows port wrote the
/// real DO PAT into the guest's ~/.config/doctl/config.yaml AND
/// only registered a naked-token swap entry — the
/// <c>doctl registry login</c> path uses HTTP Basic auth with
/// the wire form <c>Authorization: Basic base64("&lt;tok&gt;:&lt;tok&gt;")</c>
/// which the naked-token swap can't see through. Both gaps are
/// closed here; these tests pin the wire shape + scope.
/// </summary>
public class DigitalOceanFakeMintTests
{
    private const string ExampleReal = "dop_v1_abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

    [Fact]
    public void MintFake_HasDoPatPrefixAnd71Chars()
    {
        var salt = new byte[32];
        var fake = DigitalOceanFakeMint.MintFake(ExampleReal, salt);
        fake.Should().NotBeNull();
        fake!.Should().StartWith("dop_v1_");
        fake!.Length.Should().Be(71, "real DO PATs are dop_v1_ + 64 hex chars");
        // Hex suffix only — `doctl` does syntactic validation.
        fake![7..].Should().MatchRegex("^[0-9a-f]{64}$");
    }

    [Fact]
    public void MintFake_Deterministic_ForSameRealAndSalt()
    {
        var salt = new byte[32];
        DigitalOceanFakeMint.MintFake(ExampleReal, salt)
            .Should().Be(DigitalOceanFakeMint.MintFake(ExampleReal, salt));
    }

    [Fact]
    public void MintFake_DifferentSaltsProduceDifferentFakes()
    {
        var s1 = new byte[32];
        var s2 = new byte[32]; s2[0] = 1;
        DigitalOceanFakeMint.MintFake(ExampleReal, s1)
            .Should().NotBe(DigitalOceanFakeMint.MintFake(ExampleReal, s2));
    }

    [Fact]
    public void MintFake_EmptyReal_ReturnsNull()
    {
        DigitalOceanFakeMint.MintFake("", new byte[32]).Should().BeNull();
        DigitalOceanFakeMint.MintFake("   ", new byte[32]).Should().BeNull();
    }

    [Fact]
    public void BuildSwapEntries_HasNakedAndBase64PairForms()
    {
        var fake = "dop_v1_aaaabbbbccccddddeeeeffff00001111222233334444555566667777";
        var entries = DigitalOceanFakeMint.BuildSwapEntries(ExampleReal, fake);

        entries.Should().HaveCount(2);
        entries.Should().ContainSingle(e => e.Real == ExampleReal && e.Fake == fake);

        // Second entry covers base64("token:token") which is what
        // `doctl registry login` emits.
        var expectedRealPair = Convert.ToBase64String(
            Encoding.ASCII.GetBytes(ExampleReal + ":" + ExampleReal));
        var expectedFakePair = Convert.ToBase64String(
            Encoding.ASCII.GetBytes(fake + ":" + fake));
        entries.Should().ContainSingle(e =>
            e.Real == expectedRealPair && e.Fake == expectedFakePair);
    }

    [Fact]
    public void BuildSwapEntries_BothScopedToDigitaloceanCom_WithSiblings()
    {
        var entries = DigitalOceanFakeMint.BuildSwapEntries(
            ExampleReal,
            "dop_v1_" + new string('a', 64));
        entries.Should().AllSatisfy(e =>
        {
            e.Host.Should().Be("digitalocean.com");
            e.AcceptSiblings.Should().BeTrue(
                "api.digitalocean.com + registry.digitalocean.com must match the same scope");
        });
    }

    [Fact]
    public void SessionHomeBuilder_WritesFake_WhenProvided()
    {
        var profile = new Profile { DigitalOceanToken = ExampleReal };
        var fake = "dop_v1_" + new string('a', 64);
        var files = SessionHomeBuilder.Build(profile, digitalOceanFake: fake);
        files.Should().ContainKey(".config/doctl/config.yaml");
        var contents = Encoding.UTF8.GetString(files[".config/doctl/config.yaml"]);
        contents.Should().Contain($"access-token: {fake}");
        contents.Should().NotContain(ExampleReal,
            "the real PAT must never reach the VM filesystem");
    }

    [Fact]
    public void SessionHomeBuilder_FallsBackToRealWhenNoFake()
    {
        // Belt-and-suspenders fallback: a caller that constructs
        // SessionHomeBuilder without a host (test harness, MCP
        // get_profile path) should still produce a functional
        // config rather than emit an empty access-token.
        var profile = new Profile { DigitalOceanToken = ExampleReal };
        var files = SessionHomeBuilder.Build(profile);
        var contents = Encoding.UTF8.GetString(files[".config/doctl/config.yaml"]);
        contents.Should().Contain(ExampleReal);
    }
}
