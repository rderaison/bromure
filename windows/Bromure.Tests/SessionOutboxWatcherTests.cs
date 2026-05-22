using Bromure.AC.Core.Outbox;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit 10 outbox piece: macOS opens guest-emitted URLs in the
/// host's default browser; Windows had the share but no consumer.
/// These tests pin the watcher's drain + dispatch + safety behaviour.
/// </summary>
public class SessionOutboxWatcherTests
{
    [Fact]
    public void HandleUrlFile_HappyHttpsUrl_FiresOpenerAndDeletesFile()
    {
        using var tmp = new TempDir();
        var path = Path.Combine(tmp.Path, "url-1.txt");
        File.WriteAllText(path, "https://example.com/path?q=1\n");

        var captured = new List<string>();
        using var w = new SessionOutboxWatcher(tmp.Path) { UrlOpener = captured.Add };

        w.HandleUrlFile(path);

        captured.Should().Equal(new[] { "https://example.com/path?q=1" });
        File.Exists(path).Should().BeFalse("the watcher deletes the file after dispatch");
    }

    [Fact]
    public void HandleUrlFile_HttpAlsoAllowed()
    {
        using var tmp = new TempDir();
        var path = Path.Combine(tmp.Path, "url-2.txt");
        File.WriteAllText(path, "http://localhost:3000/");
        var captured = new List<string>();
        using var w = new SessionOutboxWatcher(tmp.Path) { UrlOpener = captured.Add };
        w.HandleUrlFile(path);
        captured.Should().Equal(new[] { "http://localhost:3000/" });
    }

    [Theory]
    [InlineData("file:///c:/Windows/System32/cmd.exe")]
    [InlineData("ftp://example.com/")]
    [InlineData("javascript:alert(1)")]
    [InlineData("data:text/html,<script>x</script>")]
    [InlineData("not a url at all")]
    [InlineData("")]
    public void HandleUrlFile_RejectsNonHttpUrl_DoesNotFireOpener(string url)
    {
        using var tmp = new TempDir();
        var path = Path.Combine(tmp.Path, "url-x.txt");
        File.WriteAllText(path, url);

        var captured = new List<string>();
        using var w = new SessionOutboxWatcher(tmp.Path) { UrlOpener = captured.Add };
        w.HandleUrlFile(path);

        captured.Should().BeEmpty(
            $"refusing to shell out to non-http(s) URL: {url}");
        // The file is still deleted — we ate the bad URL so a retry
        // loop doesn't fire repeatedly.
        File.Exists(path).Should().BeFalse();
    }

    [Fact]
    public void HandleUrlFile_OpenerThrows_DoesNotPropagate()
    {
        using var tmp = new TempDir();
        var path = Path.Combine(tmp.Path, "url-3.txt");
        File.WriteAllText(path, "https://example.com/");

        using var w = new SessionOutboxWatcher(tmp.Path)
        {
            UrlOpener = _ => throw new InvalidOperationException("browser dead")
        };
        // No exception should escape.
        w.HandleUrlFile(path);
    }

    [Fact]
    public void HandleUrlFile_FileGoneByTheTimeWeRead_QuietNoOp()
    {
        // Simulates the Created+Changed double-fire race: the first
        // handler deletes the file, the second sees nothing.
        using var tmp = new TempDir();
        var path = Path.Combine(tmp.Path, "url-vanished.txt");
        // Don't create the file.
        var captured = new List<string>();
        using var w = new SessionOutboxWatcher(tmp.Path) { UrlOpener = captured.Add };
        w.HandleUrlFile(path);
        captured.Should().BeEmpty();
    }

    [Fact]
    public void Start_DrainsPreExistingFilesBeforeWatching()
    {
        // setup.sh's bromure-open could fire DURING the host's
        // watcher-startup window. The drain on Start() catches any
        // url-*.txt the guest dropped before the FileSystemWatcher
        // came up.
        using var tmp = new TempDir();
        File.WriteAllText(Path.Combine(tmp.Path, "url-pre1.txt"), "https://a.example/");
        File.WriteAllText(Path.Combine(tmp.Path, "url-pre2.txt"), "https://b.example/");

        var captured = new List<string>();
        using var w = new SessionOutboxWatcher(tmp.Path) { UrlOpener = captured.Add };
        w.Start();
        captured.Should().BeEquivalentTo(new[]
        {
            "https://a.example/", "https://b.example/",
        });
        Directory.EnumerateFiles(tmp.Path, "url-*.txt").Should().BeEmpty();
    }

    [Theory]
    [InlineData("https://x.example", true)]
    [InlineData("HTTPS://x.example", true)]
    [InlineData("http://localhost:8080", true)]
    [InlineData("ftp://x.example", false)]
    [InlineData("file:///etc/passwd", false)]
    [InlineData("javascript:void(0)", false)]
    [InlineData("not a url", false)]
    [InlineData("", false)]
    [InlineData("ssh://example.com", false)]
    public void LooksLikeSafeUrl_Table(string url, bool expected)
    {
        SessionOutboxWatcher.LooksLikeSafeUrl(url).Should().Be(expected);
    }

    private sealed class TempDir : IDisposable
    {
        public string Path { get; }
        public TempDir()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                "bromure-outbox-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }
        public void Dispose() { try { Directory.Delete(Path, recursive: true); } catch (IOException) { } }
    }
}
