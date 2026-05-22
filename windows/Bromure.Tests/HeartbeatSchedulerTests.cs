using System.Net;
using System.Net.Sockets;
using System.Text;
using Bromure.AC.Core.Enrollment;
using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for the heartbeat / unenroll coordinator. Audit 06 #6/7
/// flagged these as missing — without heartbeat the dashboard shows
/// every install as "last seen never"; without coordinated unenroll
/// the sign-out path leaves stale state on disk.
/// </summary>
public class HeartbeatSchedulerTests
{
    [Fact]
    public async Task Tick_NotEnrolled_NoOps()
    {
        using var server = LoopbackServer.Start(_ => HttpStatusCode.OK);
        using var paths = new TempPaths();
        var store = new EnrollmentStore(paths, paths.Secrets);
        var client = new EnrollmentClient();
        var sched = new HeartbeatScheduler(client, store);
        // No install on disk → tick is a no-op, no exception.
        await sched.TickAsync(CancellationToken.None);
        await sched.DisposeAsync();
    }

    [Fact]
    public async Task Tick_Enrolled_PostsToHeartbeatEndpoint()
    {
        string? capturedPath = null;
        string? capturedAuth = null;
        using var server = LoopbackServer.Start(req =>
        {
            capturedPath = req.Path;
            capturedAuth = req.Headers.GetValueOrDefault("Authorization");
            return HttpStatusCode.OK;
        });

        using var paths = new TempPaths();
        var store = new EnrollmentStore(paths, paths.Secrets);
        store.Save(new BromureInstall(
            InstallId: "inst-xyz",
            OrgSlug: "acme",
            UserId: "u",
            UserEmail: "e@x",
            ServerUrl: server.Uri,
            EnrolledAt: DateTimeOffset.UtcNow,
            DeviceName: "test"));
        store.StoreInstallToken("tok-xyz");

        var sched = new HeartbeatScheduler(new EnrollmentClient(), store);
        await sched.TickAsync(CancellationToken.None);
        await sched.DisposeAsync();

        capturedPath.Should().Be("/v1/installs/inst-xyz/heartbeat");
        capturedAuth.Should().Be("Bearer tok-xyz");
    }

    [Fact]
    public async Task UnenrollAsync_PostsServerThenWipesLocal()
    {
        var serverHit = false;
        using var server = LoopbackServer.Start(req =>
        {
            if (req.Path.EndsWith("/unenroll")) serverHit = true;
            return HttpStatusCode.OK;
        });
        using var paths = new TempPaths();
        var store = new EnrollmentStore(paths, paths.Secrets);
        store.Save(new BromureInstall(
            InstallId: "inst-z",
            OrgSlug: "o",
            UserId: "u",
            UserEmail: "e@x",
            ServerUrl: server.Uri,
            EnrolledAt: DateTimeOffset.UtcNow,
            DeviceName: "d"));
        store.StoreInstallToken("tok-bye");
        store.IsEnrolled.Should().BeTrue();

        var coord = new EnrollmentCoordinator(new EnrollmentClient(), store);
        await coord.UnenrollAsync();

        serverHit.Should().BeTrue("server must be told before we wipe locally");
        store.IsEnrolled.Should().BeFalse();
        store.Load().Should().BeNull();
        store.LoadInstallToken().Should().BeNull();
    }

    [Fact]
    public async Task UnenrollAsync_ServerError_StillWipesLocal()
    {
        // If the server is down or returns 500, we still need to
        // clear local state — otherwise the user gets stuck in
        // "already enrolled" hell after a re-install attempt.
        using var server = LoopbackServer.Start(_ => HttpStatusCode.InternalServerError);
        using var paths = new TempPaths();
        var store = new EnrollmentStore(paths, paths.Secrets);
        store.Save(new BromureInstall(
            InstallId: "inst",
            OrgSlug: "o",
            UserId: "u",
            UserEmail: "e@x",
            ServerUrl: server.Uri,
            EnrolledAt: DateTimeOffset.UtcNow,
            DeviceName: "d"));
        store.StoreInstallToken("tok");
        var coord = new EnrollmentCoordinator(new EnrollmentClient(), store);
        await coord.UnenrollAsync();
        store.IsEnrolled.Should().BeFalse();
    }

    [Fact]
    public async Task EnrollmentCoordinator_StartHeartbeat_NotEnrolled_ReturnsFalse()
    {
        using var paths = new TempPaths();
        var store = new EnrollmentStore(paths, paths.Secrets);
        var coord = new EnrollmentCoordinator(new EnrollmentClient(), store);
        coord.StartHeartbeat().Should().BeFalse();
        await coord.DisposeAsync();
    }

    private sealed class TempPaths : IAppPaths, IDisposable
    {
        private readonly string _root;
        public InMemSecrets Secrets { get; } = new();
        public TempPaths()
        {
            _root = Path.Combine(Path.GetTempPath(), "bromure-hb-" + Guid.NewGuid().ToString("N"));
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

    private sealed class InMemSecrets : ISecretStore
    {
        private readonly Dictionary<string, string> _s = new();
        private readonly Dictionary<string, byte[]> _b = new();
        public void StoreSecret(string svc, string acct, string v) => _s[svc + "|" + acct] = v;
        public string? ReadSecret(string svc, string acct) => _s.GetValueOrDefault(svc + "|" + acct);
        public void DeleteSecret(string svc, string acct) => _s.Remove(svc + "|" + acct);
        public void StoreBlob(string n, ReadOnlySpan<byte> d, BlobScope s) => _b[s + "|" + n] = d.ToArray();
        public byte[]? ReadBlob(string n, BlobScope s) => _b.GetValueOrDefault(s + "|" + n);
        public void DeleteBlob(string n, BlobScope s) => _b.Remove(s + "|" + n);
    }

    private sealed class LoopbackServer : IDisposable
    {
        private readonly HttpListener _listener;
        public Uri Uri { get; }

        private LoopbackServer(Func<Captured, HttpStatusCode> handler, int port)
        {
            _listener = new HttpListener();
            var prefix = $"http://127.0.0.1:{port}/";
            _listener.Prefixes.Add(prefix);
            _listener.Start();
            Uri = new Uri(prefix);
            _ = Task.Run(() => Loop(handler));
        }

        public static LoopbackServer Start(Func<Captured, HttpStatusCode> handler)
            => new(handler, FreePort());

        private static int FreePort()
        {
            using var sock = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            sock.Bind(new IPEndPoint(IPAddress.Loopback, 0));
            return ((IPEndPoint)sock.LocalEndPoint!).Port;
        }

        private async Task Loop(Func<Captured, HttpStatusCode> handler)
        {
            while (true)
            {
                HttpListenerContext ctx;
                try { ctx = await _listener.GetContextAsync().ConfigureAwait(false); }
                catch { return; }
                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var h in ctx.Request.Headers.AllKeys)
                {
                    if (h is null) continue;
                    headers[h] = ctx.Request.Headers[h] ?? "";
                }
                var captured = new Captured(ctx.Request.Url!.AbsolutePath, ctx.Request.HttpMethod, headers);
                var code = handler(captured);
                ctx.Response.StatusCode = (int)code;
                ctx.Response.Close();
            }
        }

        public void Dispose()
        {
            try { _listener.Stop(); } catch { }
            try { _listener.Close(); } catch { }
        }

        public sealed record Captured(string Path, string Method, IReadOnlyDictionary<string, string> Headers);
    }
}
