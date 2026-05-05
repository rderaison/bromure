using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using Bromure.AC.Mitm.Pki;
using Bromure.Platform;
using Xunit;
using Xunit.Abstractions;

namespace Bromure.Tests;

/// <summary>
/// Reproduces the TLS handshake failure the live proxy hit on the
/// user's machine: openssl s_client through HTTPS_PROXY got
/// `unexpected eof while reading` after CONNECT — i.e. SslStream's
/// AuthenticateAsServer was failing silently inside HttpMitmProxy.
/// </summary>
public class TlsHandshakeProbe
{
    private readonly ITestOutputHelper _out;
    public TlsHandshakeProbe(ITestOutputHelper output) => _out = output;

    [Fact]
    public async Task Mint_leaf_and_authenticate_as_server_over_loopback()
    {
        using var paths = new TempPaths();
        var ca = BromureCa.LoadOrCreate(paths, paths.Secrets);
        var cache = new CertCache(ca);
        var leaf = cache.IdentityFor("test.example");
        _out.WriteLine($"leaf hasPrivateKey={leaf.HasPrivateKey} subject={leaf.Subject} alg={leaf.PublicKey.Oid.FriendlyName}");
        Assert.True(leaf.HasPrivateKey);

        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;

        var serverTask = Task.Run(async () =>
        {
            using var s = await listener.AcceptTcpClientAsync();
            await using var ns = s.GetStream();
            await using var tls = new SslStream(ns, leaveInnerStreamOpen: true);
            try
            {
                await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificate = leaf,
                    ClientCertificateRequired = false,
                });
                return "OK";
            }
            catch (Exception ex)
            {
                return $"{ex.GetType().Name}: {ex.Message} | inner: {ex.InnerException?.GetType().Name}: {ex.InnerException?.Message}";
            }
        });

        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port);
        await using var clientStream = client.GetStream();
        await using var clientTls = new SslStream(clientStream, leaveInnerStreamOpen: true,
            userCertificateValidationCallback: (_, _, _, _) => true);
        Exception? clientEx = null;
        try { await clientTls.AuthenticateAsClientAsync("test.example"); }
        catch (Exception ex) { clientEx = ex; }

        var serverResult = await serverTask;
        _out.WriteLine($"server: {serverResult}");
        if (clientEx is not null)
            _out.WriteLine($"client: {clientEx.GetType().Name}: {clientEx.Message} | inner: {clientEx.InnerException?.Message}");

        Assert.Equal("OK", serverResult);
        Assert.Null(clientEx);
    }

    private sealed class TempPaths : IAppPaths, IDisposable
    {
        private readonly string _root;
        public TempPaths()
        {
            _root = Path.Combine(Path.GetTempPath(), "bromure-tls-probe-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_root);
            Secrets = new InMemorySecretStore();
        }
        public InMemorySecretStore Secrets { get; }
        public string AppDataRoot => _root;
        public string MachineDataRoot => _root;
        public string ProfilesDirectory => Path.Combine(_root, "profiles");
        public string TracesDirectory => Path.Combine(_root, "traces");
        public string ImagesDirectory => Path.Combine(_root, "images");
        public string SessionsDirectory => Path.Combine(_root, "sessions");
        public string ResourcesDirectory => Path.Combine(_root, "resources");
        public string EnsureDirectory(string path) { Directory.CreateDirectory(path); return path; }
        public void Dispose()
        {
            try { Directory.Delete(_root, recursive: true); } catch (IOException) { }
        }
    }

    private sealed class InMemorySecretStore : ISecretStore
    {
        private readonly Dictionary<string, string> _secrets = new();
        private readonly Dictionary<string, byte[]> _blobs = new();
        public void StoreSecret(string service, string account, string value)
            => _secrets[$"{service}|{account}"] = value;
        public string? ReadSecret(string service, string account)
            => _secrets.TryGetValue($"{service}|{account}", out var v) ? v : null;
        public void DeleteSecret(string service, string account)
            => _secrets.Remove($"{service}|{account}");
        public void StoreBlob(string name, ReadOnlySpan<byte> data, BlobScope scope)
            => _blobs[$"{scope}|{name}"] = data.ToArray();
        public byte[]? ReadBlob(string name, BlobScope scope)
            => _blobs.TryGetValue($"{scope}|{name}", out var v) ? v : null;
        public void DeleteBlob(string name, BlobScope scope)
            => _blobs.Remove($"{scope}|{name}");
    }
}
