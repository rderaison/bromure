using System.Net;
using System.Net.Http;
using Bromure.Platform;
using Bromure.SandboxEngine.Image;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class ImageManagerTests
{
    [Fact]
    public async Task EnsureAvailable_DownloadsFromTestServerAndReportsProgress()
    {
        // Spin up a tiny HTTP server that serves a deterministic byte
        // pattern. Tests the streaming + atomic-rename path without
        // pulling on the real Alpine CDN.
        const int payloadSize = 4 * 1024 * 1024;  // 4 MiB
        var payload = new byte[payloadSize];
        for (var i = 0; i < payload.Length; i++) payload[i] = (byte)(i & 0xFF);

        var listener = new HttpListener();
        var port = NextFreePort();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();
        var serverTask = Task.Run(async () =>
        {
            var ctx = await listener.GetContextAsync();
            ctx.Response.ContentLength64 = payload.Length;
            ctx.Response.ContentType = "application/octet-stream";
            await ctx.Response.OutputStream.WriteAsync(payload);
            ctx.Response.OutputStream.Close();
        });

        using var paths = new TempPaths();
        var images = new ImageManager(paths);
        var image = new ImageManager.ImageDescriptor(
            FileName: "fake.bin",
            Url: new Uri($"http://127.0.0.1:{port}/fake.bin"),
            ExpectedBytes: payload.Length,
            ExpectedSha256: null);

        var reports = new List<DownloadProgress>();
        var progress = new Progress<DownloadProgress>(reports.Add);

        var path = await images.EnsureAvailableAsync(image, progress);
        await serverTask;
        listener.Stop();

        File.Exists(path).Should().BeTrue();
        new FileInfo(path).Length.Should().Be(payload.Length);
        File.ReadAllBytes(path).Should().Equal(payload);

        reports.Should().NotBeEmpty();
        reports.Last().IsDone.Should().BeTrue();
        reports.Last().Fraction.Should().Be(1.0);
    }

    [Fact]
    public async Task EnsureAvailable_NoOpWhenAlreadyCached()
    {
        using var paths = new TempPaths();
        var images = new ImageManager(paths);
        var image = new ImageManager.ImageDescriptor(
            FileName: "cached.bin",
            Url: new Uri("http://127.0.0.1:1/should-not-be-fetched"),
            ExpectedBytes: 64,
            ExpectedSha256: null);

        var dst = images.LocalPath(image);
        Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
        File.WriteAllBytes(dst, new byte[64]);

        var path = await images.EnsureAvailableAsync(image);
        path.Should().Be(dst);
    }

    [Fact]
    public void IsCached_FalseWhenSizeMismatchesByMoreThanTolerance()
    {
        using var paths = new TempPaths();
        var images = new ImageManager(paths);
        var image = new ImageManager.ImageDescriptor(
            FileName: "x.bin",
            Url: new Uri("http://example.com/"),
            ExpectedBytes: 100_000_000,
            ExpectedSha256: null);
        var dst = images.LocalPath(image);
        Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
        File.WriteAllBytes(dst, new byte[1_000_000]);  // way off
        images.IsCached(image).Should().BeFalse();
    }

    private static int NextFreePort()
    {
        // HttpListener wants a fixed port; pick a random one in the
        // ephemeral range. Cheap retry if it's busy.
        var rnd = new Random();
        for (var i = 0; i < 8; i++)
        {
            var port = rnd.Next(40000, 60000);
            try
            {
                using var probe = new System.Net.Sockets.TcpListener(IPAddress.Loopback, port);
                probe.Start();
                probe.Stop();
                return port;
            }
            catch (System.Net.Sockets.SocketException) { }
        }
        return 51234;
    }

    private sealed class TempPaths : IAppPaths, IDisposable
    {
        private readonly string _root;
        public TempPaths()
        {
            _root = Path.Combine(Path.GetTempPath(), "bromure-image-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_root);
        }
        public string AppDataRoot => _root;
        public string MachineDataRoot => _root;
        public string ProfilesDirectory => Path.Combine(_root, "profiles");
        public string TracesDirectory => Path.Combine(_root, "traces");
        public string ImagesDirectory => Path.Combine(_root, "images");
        public string SessionsDirectory => Path.Combine(_root, "sessions");
        public string ResourcesDirectory => Path.Combine(_root, "resources");
        public string EnsureDirectory(string p) { Directory.CreateDirectory(p); return p; }
        public void Dispose() { try { Directory.Delete(_root, recursive: true); } catch (IOException) { } }
    }
}
