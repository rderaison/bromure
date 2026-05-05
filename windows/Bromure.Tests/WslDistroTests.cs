using Bromure.SandboxEngine.Wsl;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class WslDistroTests
{
    [Fact]
    public void ParseList_basic_default_marker_is_stripped()
    {
        var output = """
              NAME             STATE           VERSION
            * Ubuntu-24.04     Stopped         2
              bromure-ses-abc  Running         2
            """;
        var distros = WslDistro.ParseList(output);
        distros.Should().HaveCount(2);
        distros[0].Should().Be(new DistroInfo("Ubuntu-24.04", WslDistro.State.Stopped, 2));
        distros[1].Should().Be(new DistroInfo("bromure-ses-abc", WslDistro.State.Running, 2));
    }

    [Fact]
    public void ParseList_handles_running_state()
    {
        var output = """
              NAME             STATE           VERSION
              foo              Running         2
            """;
        WslDistro.ParseList(output)[0].State.Should().Be(WslDistro.State.Running);
    }

    [Fact]
    public void ParseList_unknown_state_falls_back_to_Stopped()
    {
        var output = """
              NAME             STATE           VERSION
              installing-one   Installing      2
            """;
        WslDistro.ParseList(output)[0].State.Should().Be(WslDistro.State.Stopped);
    }

    [Fact]
    public void ParseList_empty_input_returns_empty()
    {
        WslDistro.ParseList("").Should().BeEmpty();
        WslDistro.ParseList("   \n\n").Should().BeEmpty();
    }

    [Fact]
    public void ParseList_skips_malformed_rows()
    {
        var output = """
              NAME             STATE           VERSION
              good             Stopped         2
              malformed-no-version
              alsogood         Running         2
            """;
        var distros = WslDistro.ParseList(output);
        distros.Should().HaveCount(2);
        distros.Select(d => d.Name).Should().Equal("good", "alsogood");
    }

    [Fact]
    public void ParseList_handles_carriage_returns()
    {
        var output = "  NAME\tSTATE\tVERSION\r\n* foo\tStopped\t2\r\n";
        var distros = WslDistro.ParseList(output);
        distros.Should().HaveCount(1);
        distros[0].Name.Should().Be("foo");
    }

    [Fact]
    public void Constructor_rejects_empty_name()
    {
        var act = () => new WslDistro("", "C:/tmp");
        act.Should().Throw<ArgumentException>().WithParameterName("name");
    }

    [Fact]
    public void Constructor_rejects_empty_install_path()
    {
        var act = () => new WslDistro("foo", "");
        act.Should().Throw<ArgumentException>().WithParameterName("installPath");
    }

    [Fact]
    public async Task LaunchAsync_throws_if_not_imported()
    {
        var d = new WslDistro("never-imported", @"C:\tmp\never");
        var act = async () => await d.LaunchAsync(new[] { "true" });
        await act.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*Distro not imported*");
    }

    [Fact]
    public async Task LaunchAsync_rejects_empty_argv()
    {
        var d = new WslDistro("foo", @"C:\tmp\foo");
        // Force _imported = true via reflection to bypass the
        // not-imported guard so we can test the argv guard.
        typeof(WslDistro).GetField("_imported",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!
            .SetValue(d, true);
        var act = async () => await d.LaunchAsync(Array.Empty<string>());
        await act.Should().ThrowAsync<ArgumentException>().WithParameterName("argv");
    }
}
