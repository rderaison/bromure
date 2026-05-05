using Bromure.SandboxEngine.Sharing;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class Msys2PathTests
{
    [Theory]
    [InlineData(@"C:\Users\foo", "/c/Users/foo")]
    [InlineData(@"C:\Users\foo\bar baz", "/c/Users/foo/bar baz")]
    [InlineData(@"D:\projects\app", "/d/projects/app")]
    [InlineData(@"c:\lower", "/c/lower")]
    [InlineData(@"E:", "/e")]
    public void Drive_paths_become_msys2_form(string winPath, string expected)
    {
        Msys2Path.From(winPath).Should().Be(expected);
    }

    [Theory]
    [InlineData("/already/posix", "/already/posix")]
    [InlineData("relative/path", "relative/path")]
    [InlineData("", "")]
    public void Non_drive_paths_pass_through_with_slash_normalisation(string input, string expected)
    {
        Msys2Path.From(input).Should().Be(expected);
    }

    [Fact]
    public void Backslashes_in_non_drive_paths_normalise_to_slash()
    {
        Msys2Path.From(@"some\sub\path").Should().Be("some/sub/path");
    }
}
