using Bromure.SandboxEngine.Hcs;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class HcsSessionShareTests
{
    [Theory]
    [InlineData(@"C:\Users\renaud\Projects\foo", "foo")]
    [InlineData(@"C:\Users\renaud\Projects\foo\", "foo")]
    [InlineData(@"D:\src", "src")]
    [InlineData(@"\\server\share\folder", "folder")]
    [InlineData(@"foo", "foo")]
    public void SafeBasename_picks_last_component(string input, string expected)
    {
        HcsSession.SafeBasename(input).Should().Be(expected);
    }

    [Fact]
    public void SafeBasename_falls_back_when_input_is_empty_or_only_separators()
    {
        HcsSession.SafeBasename(@"\").Should().Be("share");
        HcsSession.SafeBasename("").Should().Be("share");
    }

    [Fact]
    public void SafeBasename_strips_control_characters()
    {
        HcsSession.SafeBasename("foobar").Should().Be("foobar");
    }
}
