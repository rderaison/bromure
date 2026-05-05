using Bromure.SandboxEngine.Wsl;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class RootfsBakerTests
{
    [Theory]
    [InlineData(@"C:\foo\bar.sh", "/mnt/c/foo/bar.sh")]
    [InlineData(@"D:\projects\app", "/mnt/d/projects/app")]
    [InlineData(@"C:\Users\foo\Bromure-base.tar.gz", "/mnt/c/Users/foo/Bromure-base.tar.gz")]
    [InlineData(@"e:\lower", "/mnt/e/lower")]
    public void ToWslPath_translates_drive_to_mnt(string winPath, string expected)
    {
        RootfsBaker.ToWslPath(winPath).Should().Be(expected);
    }

    [Theory]
    [InlineData(@"\\share\foo")]
    [InlineData("relative/path")]
    [InlineData("/already/posix")]
    public void ToWslPath_rejects_non_drive_paths(string winPath)
    {
        var act = () => RootfsBaker.ToWslPath(winPath);
        act.Should().Throw<ArgumentException>().WithParameterName("winPath");
    }

    [Fact]
    public void OutputBaseFileName_is_stable()
    {
        RootfsBaker.OutputBaseFileName.Should().Be("bromure-base.tar.gz");
    }
}
