using System.Text;
using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class SessionHomeBuilderTests
{
    [Fact]
    public void Always_includes_kitty_conf()
    {
        var files = SessionHomeBuilder.Build(profile: null);
        files.Should().ContainKey(".config/kitty/kitty.conf");
        Encoding.UTF8.GetString(files[".config/kitty/kitty.conf"])
            .Should().Contain("font_size");
    }

    [Fact]
    public void Always_includes_bashrc_that_sources_api_key_env()
    {
        var files = SessionHomeBuilder.Build(profile: null);
        files.Should().ContainKey(".bashrc");
        var bashrc = Encoding.UTF8.GetString(files[".bashrc"]);
        bashrc.Should().Contain("/mnt/bromure-meta/api_key.env");
    }

    [Fact]
    public void Bash_profile_triggers_startx_on_tty1()
    {
        var files = SessionHomeBuilder.Build(profile: null);
        files.Should().ContainKey(".bash_profile");
        var profile = Encoding.UTF8.GetString(files[".bash_profile"]);
        profile.Should().Contain("/dev/tty1");
        profile.Should().Contain("startx");
    }

    [Fact]
    public void Output_uses_lf_line_endings()
    {
        var files = SessionHomeBuilder.Build(profile: null);
        foreach (var (_, bytes) in files)
        {
            var text = Encoding.UTF8.GetString(bytes);
            text.Should().NotContain("\r\n");
        }
    }
}
