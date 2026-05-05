using Bromure.AC.Mitm.Pki;
using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class BromureCaTests
{
    [Fact]
    public void LoadOrCreate_ProducesValidUsableServerCertificate()
    {
        using var paths = new TempPaths();
        var ca = BromureCa.LoadOrCreate(paths, paths.Secrets);

        ca.CertificatePem.Should().Contain("BEGIN CERTIFICATE");
        ca.ServerCertificate.HasPrivateKey.Should().BeTrue();
        ca.Certificate.IssuerDN.ToString().Should().Contain("Bromure Agentic Coding Root CA");
        ca.Certificate.IssuerDN.ToString().Should().Be(ca.Certificate.SubjectDN.ToString(),
            "self-signed root: issuer == subject");
    }

    [Fact]
    public void LoadOrCreate_PersistsAcrossCalls()
    {
        using var paths = new TempPaths();
        var first = BromureCa.LoadOrCreate(paths, paths.Secrets);
        var second = BromureCa.LoadOrCreate(paths, paths.Secrets);

        // Same serial number across reloads - we read the persisted file.
        first.Certificate.SerialNumber.Should().Be(second.Certificate.SerialNumber);
        first.CertificatePem.Should().Be(second.CertificatePem);
    }

    [Fact]
    public void CertCache_MintsPerHostLeavesAndCachesByHost()
    {
        using var paths = new TempPaths();
        var ca = BromureCa.LoadOrCreate(paths, paths.Secrets);
        var cache = new CertCache(ca);

        var anthropic = cache.IdentityFor("api.anthropic.com");
        var anthropicAgain = cache.IdentityFor("api.anthropic.com");
        var openai = cache.IdentityFor("api.openai.com");

        anthropicAgain.Thumbprint.Should().Be(anthropic.Thumbprint, "same host hits the cache");
        openai.Thumbprint.Should().NotBe(anthropic.Thumbprint, "different host gets a fresh leaf");
        anthropic.HasPrivateKey.Should().BeTrue();
        anthropic.Subject.Should().Contain("api.anthropic.com");
    }

    [Fact]
    public void CertCache_LeafIssuerEqualsCaSubject()
    {
        using var paths = new TempPaths();
        var ca = BromureCa.LoadOrCreate(paths, paths.Secrets);
        var cache = new CertCache(ca);
        var leaf = cache.IdentityFor("example.com");

        // Leaf's issuer == CA's subject — required for trust-store validation.
        leaf.Issuer.Should().Be(ca.ServerCertificate.Subject);
    }

    private sealed class TempPaths : IAppPaths, IDisposable
    {
        private readonly string _root;
        public TempPaths()
        {
            _root = Path.Combine(Path.GetTempPath(), "bromure-ca-tests-" + Guid.NewGuid().ToString("N"));
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
