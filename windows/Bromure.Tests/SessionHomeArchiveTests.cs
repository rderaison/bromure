using System.Formats.Tar;
using Bromure.SandboxEngine.Image;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class SessionHomeArchiveTests
{
    [Fact]
    public void Empty_input_returns_empty_array()
    {
        SessionHomeArchive.Build(new Dictionary<string, byte[]>())
            .Should().BeEmpty();
    }

    [Fact]
    public void Single_file_at_root_round_trips()
    {
        var bytes = SessionHomeArchive.Build(new Dictionary<string, byte[]>
        {
            [".bashrc"] = "hello"u8.ToArray(),
        });
        var entries = ReadEntries(bytes);
        entries.Should().Contain(e => e.Name == ".bashrc" && e.Type == TarEntryType.RegularFile);
    }

    [Fact]
    public void Nested_paths_emit_intermediate_directory_entries()
    {
        var bytes = SessionHomeArchive.Build(new Dictionary<string, byte[]>
        {
            [".config/kitty/kitty.conf"] = "font_size 14\n"u8.ToArray(),
            [".config/gh/hosts.yml"] = "github.com:\n  user: foo\n"u8.ToArray(),
        });
        var entries = ReadEntries(bytes);
        entries.Should().Contain(e => e.Type == TarEntryType.Directory && e.Name == ".config/");
        entries.Should().Contain(e => e.Type == TarEntryType.Directory && e.Name == ".config/kitty/");
        entries.Should().Contain(e => e.Type == TarEntryType.Directory && e.Name == ".config/gh/");
        entries.Should().Contain(e => e.Type == TarEntryType.RegularFile
                                    && e.Name == ".config/kitty/kitty.conf");
    }

    [Fact]
    public void Same_directory_emitted_once_for_multiple_children()
    {
        var bytes = SessionHomeArchive.Build(new Dictionary<string, byte[]>
        {
            [".config/kitty/kitty.conf"] = "a"u8.ToArray(),
            [".config/kitty/colors.conf"] = "b"u8.ToArray(),
        });
        var entries = ReadEntries(bytes);
        entries.Count(e => e.Type == TarEntryType.Directory && e.Name == ".config/kitty/")
            .Should().Be(1);
    }

    [Fact]
    public void Backslashes_in_paths_are_normalised()
    {
        var bytes = SessionHomeArchive.Build(new Dictionary<string, byte[]>
        {
            [@".config\foo\bar.conf"] = "x"u8.ToArray(),
        });
        var entries = ReadEntries(bytes);
        entries.Should().Contain(e => e.Name == ".config/foo/bar.conf");
    }

    private static List<(string Name, TarEntryType Type)> ReadEntries(byte[] tarBytes)
    {
        var list = new List<(string, TarEntryType)>();
        using var ms = new MemoryStream(tarBytes);
        using var reader = new TarReader(ms);
        TarEntry? entry;
        while ((entry = reader.GetNextEntry()) is not null)
        {
            list.Add((entry.Name, entry.EntryType));
        }
        return list;
    }
}
