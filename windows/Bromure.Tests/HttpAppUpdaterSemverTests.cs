using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Unit coverage for <see cref="SemverCompare.Compare"/>. The
/// auto-update path's only piece of logic that's worth covering in
/// isolation — the actual HTTP fetch is integration territory.
/// </summary>
public class HttpAppUpdaterSemverTests
{
    [Theory]
    [InlineData("1.0.0", "1.0.0", 0)]
    [InlineData("1.0.1", "1.0.0", 1)]
    [InlineData("1.0.0", "1.0.1", -1)]
    [InlineData("2.0.0", "1.9.9", 1)]
    [InlineData("1.10.0", "1.9.0", 1)]
    [InlineData("1.0.0", "1.0", 0)]
    [InlineData("1.2.3-rc1", "1.2.3", -1)]
    [InlineData("1.2.3", "1.2.3-rc1", 1)]
    [InlineData("0.0.0", "1.0.0", -1)]
    public void Compare_returns_expected_sign(string a, string b, int expectedSign)
    {
        var result = SemverCompare.Compare(a, b);
        Math.Sign(result).Should().Be(expectedSign);
    }
}
