using System.Net;
using System.Net.Sockets;
using System.Text;
using Bromure.AC.Mitm.Aws;
using Bromure.AC.Mitm.Pki;
using Bromure.AC.Mitm.Proxy;
using Bromure.AC.Mitm.SigV4;
using Bromure.AC.Mitm.Swap;
using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Focused tests on the proxy's CONNECT handling. Full TLS-MITM-plus-
/// upstream-forwarding requires a tunable DNS to point an arbitrary
/// hostname at our fake upstream — moved to the integration suite. The
/// pieces driven by these tests:
///
/// <list type="bullet">
///   <item>Listening on a chosen port and accepting the VM's TCP.</item>
///   <item>Parsing the CONNECT line + port suffix.</item>
///   <item>Replying with <c>200 Connection established</c>.</item>
///   <item>Rejecting non-CONNECT verbs cleanly.</item>
/// </list>
///
/// The swap engine + cert cache + OAuth rewriter are already covered by
/// their own focused tests; gluing them with a real TLS leaf is what the
/// integration suite will pick up.
/// </summary>
public class HttpMitmProxyTests
{
    [Fact]
    public async Task Connect_ProxyReplies200ConnectionEstablished()
    {
        await using var harness = await Harness.CreateAsync();
        using var vm = new TcpClient();
        await vm.ConnectAsync(IPAddress.Loopback, harness.ProxyPort);
        using var raw = vm.GetStream();

        // Use 65535 — guaranteed-unused; the proxy doesn't actually
        // touch upstream until after the TLS handshake.
        var connectLine = "CONNECT api.anthropic.com:65535 HTTP/1.1\r\nHost: api.anthropic.com:65535\r\n\r\n";
        await raw.WriteAsync(Encoding.ASCII.GetBytes(connectLine));

        var buf = new byte[256];
        var n = await raw.ReadAsync(buf);
        var resp = Encoding.ASCII.GetString(buf, 0, n);
        resp.Should().StartWith("HTTP/1.1 200 Connection established");
    }

    [Fact]
    public async Task NonConnectVerb_Returns405()
    {
        await using var harness = await Harness.CreateAsync();
        using var vm = new TcpClient();
        await vm.ConnectAsync(IPAddress.Loopback, harness.ProxyPort);
        using var raw = vm.GetStream();

        var get = "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n";
        await raw.WriteAsync(Encoding.ASCII.GetBytes(get));

        var buf = new byte[256];
        var n = await raw.ReadAsync(buf);
        var resp = Encoding.ASCII.GetString(buf, 0, n);
        resp.Should().StartWith("HTTP/1.1 405");
    }

    private sealed class Harness : IAsyncDisposable
    {
        public required HttpMitmProxy Proxy { get; init; }
        public required int ProxyPort { get; init; }
        public required TempPaths Paths { get; init; }

        public static async Task<Harness> CreateAsync()
        {
            var paths = new TempPaths();
            var ca = BromureCa.LoadOrCreate(paths, paths.Secrets);
            var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
            swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), Guid.NewGuid());
            var resigner = new AwsResigner(new NullCredServer());
            var proxy = new HttpMitmProxy(Guid.NewGuid(), swapper, resigner, new CertCache(ca));
            await proxy.StartAsync(new IPEndPoint(IPAddress.Loopback, 0));
            return new Harness
            {
                Proxy = proxy,
                ProxyPort = proxy.LocalEndpoint!.Port,
                Paths = paths,
            };
        }

        public async ValueTask DisposeAsync()
        {
            await Proxy.DisposeAsync();
            Paths.Dispose();
        }
    }

    private sealed class NullCredServer : IAwsCredentialServer
    {
        public Task<SigningMaterial> SigningMaterialAsync(Guid profileId, string scopeHint, CancellationToken ct)
            => Task.FromResult<SigningMaterial>(new SigningMaterial.Missing());
    }

    private sealed class TempPaths : IAppPaths, IDisposable
    {
        private readonly string _root;
        public TempPaths()
        {
            _root = Path.Combine(Path.GetTempPath(), "bromure-proxy-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_root);
            Secrets = new InMemoryStore();
        }
        public InMemoryStore Secrets { get; }
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

    private sealed class InMemoryStore : ISecretStore
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
}
