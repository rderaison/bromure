using System.Text;
using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class TokenSwapperTests
{
    private static byte[] BuildRequest(string headers, byte[] body)
    {
        var headerBytes = Encoding.ASCII.GetBytes(headers + "\r\n\r\n");
        var output = new byte[headerBytes.Length + body.Length];
        Buffer.BlockCopy(headerBytes, 0, output, 0, headerBytes.Length);
        Buffer.BlockCopy(body, 0, output, headerBytes.Length, body.Length);
        return output;
    }

    [Fact]
    public async Task Swap_HeaderOnlyEntry_ReplacesFakeWithReal()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(new[]
        {
            new TokenMap.Entry("brm-fake-aaaa", "sk-real-zzzz",
                Host: "api.anthropic.com",
                Header: EntryHeader.Authorization),
        }), profile);

        var raw = BuildRequest(
            "POST /v1/messages HTTP/1.1\r\nHost: api.anthropic.com\r\nAuthorization: Bearer brm-fake-aaaa",
            Encoding.UTF8.GetBytes("{}"));

        var result = await swapper.SwapAsync(raw, "api.anthropic.com", profile);
        var output = Encoding.UTF8.GetString(result.Modified);

        output.Should().Contain("Bearer sk-real-zzzz");
        output.Should().NotContain("brm-fake-aaaa");
        result.Swaps.Should().HaveCount(1);
    }

    [Fact]
    public async Task Swap_HostScopeMismatch_DoesNotSubstitute()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(new[]
        {
            new TokenMap.Entry("brm-fake-aaaa", "sk-real-zzzz", Host: "api.anthropic.com"),
        }), profile);

        var raw = BuildRequest(
            "POST /x HTTP/1.1\r\nHost: evil.com\r\nAuthorization: Bearer brm-fake-aaaa",
            Array.Empty<byte>());

        var result = await swapper.SwapAsync(raw, "evil.com", profile);
        Encoding.UTF8.GetString(result.Modified).Should().Contain("brm-fake-aaaa");
        result.Swaps.Should().BeEmpty();
    }

    [Fact]
    public async Task Swap_BodySweepWithLengthChange_PatchesContentLength()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(new[]
        {
            new TokenMap.Entry("FAKE", "REAL-VALUE-LONGER",
                Host: "auth.openai.com",
                Body: true),
        }), profile);

        var body = Encoding.UTF8.GetBytes("{\"refresh_token\":\"FAKE\"}");
        var raw = BuildRequest(
            $"POST /oauth/token HTTP/1.1\r\nHost: auth.openai.com\r\nContent-Length: {body.Length}\r\nAuthorization: Bearer FAKE",
            body);

        var result = await swapper.SwapAsync(raw, "auth.openai.com", profile);
        var output = Encoding.UTF8.GetString(result.Modified);

        output.Should().NotContain("FAKE");
        output.Should().Contain("REAL-VALUE-LONGER");
        // body grew from 24 -> "REAL-VALUE-LONGER" replaced "FAKE" so +13 → 37
        output.Should().Contain("Content-Length: 37");
    }

    [Fact]
    public async Task Swap_DenyConsent_LeavesFakeInPlace()
    {
        var swapper = new TokenSwapper(new AlwaysDenyConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(new[]
        {
            new TokenMap.Entry("FAKE", "REAL", Host: "api.anthropic.com",
                ConsentCredentialId: "tool-apikey:claude",
                ConsentDisplayName: "Claude API key"),
        }), profile);

        var raw = BuildRequest(
            "POST /v1/messages HTTP/1.1\r\nHost: api.anthropic.com\r\nAuthorization: Bearer FAKE",
            Array.Empty<byte>());

        var result = await swapper.SwapAsync(raw, "api.anthropic.com", profile);
        Encoding.UTF8.GetString(result.Modified).Should().Contain("FAKE");
        result.Swaps.Should().BeEmpty();
    }

    [Fact]
    public void DetectLeaks_KnownPrefix_FlaggedAsKnownPrefix()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), profile);

        var raw = BuildRequest(
            "GET / HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: Bearer ghp_abcdefghijklmnop12345",
            Array.Empty<byte>());

        var leaks = swapper.DetectLeaks(raw, profile);
        leaks.Should().HaveCount(1);
        leaks[0].Suspicion.Should().Be(LeakSuspicionKind.KnownPrefix);
        leaks[0].Header.Should().Be("Authorization");
    }

    [Fact]
    public void DetectLeaks_KnownFakeIsNotALeak()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(new[]
        {
            new TokenMap.Entry("ghp_thisisourfake", "ghp_realvalue", Host: "github.com"),
        }), profile);

        var raw = BuildRequest(
            "GET / HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: Bearer ghp_thisisourfake",
            Array.Empty<byte>());

        swapper.DetectLeaks(raw, profile).Should().BeEmpty();
    }
}
