using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Critical security tests: substring matching is forbidden in the swap
/// path (a malicious VM could connect to <c>openai.com.evil.com</c> and
/// the proxy would happily inject the OpenAI key). The macOS source
/// pins this with the same shape; mirror tests here so future drift is
/// caught at CI time.
/// </summary>
public class HostMatcherTests
{
    [Theory]
    [InlineData("anthropic.com", "anthropic.com", true)]
    [InlineData("api.anthropic.com", "anthropic.com", true)]
    [InlineData("a.b.anthropic.com", "anthropic.com", true)]
    [InlineData("anthropic.com.evil.com", "anthropic.com", false)] // CRITICAL
    [InlineData("anthropiccom", "anthropic.com", false)]
    [InlineData("anthropic.com.au", "anthropic.com", false)]
    [InlineData("Anthropic.COM", "anthropic.com", true)] // case-insensitive
    public void HostMatchesScope_StrictSubdomainOnly(string host, string scope, bool expected)
    {
        HostMatcher.HostMatchesScope(host, scope).Should().Be(expected,
            $"because {host} vs scope {scope} should be {expected}");
    }

    [Theory]
    [InlineData("api.anthropic.com", "console.anthropic.com", true)]  // sibling
    [InlineData("mcp-tools.anthropic.com", "api.anthropic.com", true)] // sibling
    [InlineData("anthropic.com", "api.anthropic.com", true)]            // parent of scope
    [InlineData("evil.com", "api.anthropic.com", false)]
    [InlineData("foo.com", "bar.com", false)]
    [InlineData("anything.com", "foo.bar", false)] // <3 labels: no parent-strip
    public void HostMatchesScopeFamily_AllowsSiblings(string host, string scope, bool expected)
    {
        HostMatcher.HostMatchesScopeFamily(host, scope).Should().Be(expected);
    }
}
