using Bromure.AC.Core.Enrollment;
using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class EnrollmentStoreTests
{
    [Fact]
    public void SaveLoad_RoundTripsInstallMetadata()
    {
        using var paths = new TempPaths();
        var store = new EnrollmentStore(paths, paths.Secrets);
        var install = new BromureInstall(
            InstallId: "install_x",
            OrgSlug: "demo",
            UserId: "user_42",
            UserEmail: "alice@example.com",
            ServerUrl: new Uri("https://app.bromure.io"),
            EnrolledAt: DateTimeOffset.UtcNow,
            DeviceName: "win-test");
        store.Save(install);

        var loaded = store.Load();
        loaded.Should().NotBeNull();
        loaded!.InstallId.Should().Be("install_x");
        loaded.UserEmail.Should().Be("alice@example.com");
        store.IsEnrolled.Should().BeFalse("install metadata only — no bearer yet");
    }

    [Fact]
    public void IsEnrolled_RequiresBothMetadataAndBearer()
    {
        using var paths = new TempPaths();
        var store = new EnrollmentStore(paths, paths.Secrets);
        store.IsEnrolled.Should().BeFalse();

        store.Save(new BromureInstall("i", "o", "u", "u@x", new Uri("https://x"),
            DateTimeOffset.UtcNow, "h"));
        store.IsEnrolled.Should().BeFalse();

        store.StoreInstallToken("bearer-xyz");
        store.IsEnrolled.Should().BeTrue();
    }

    [Fact]
    public void Destroy_WipesEverything()
    {
        using var paths = new TempPaths();
        var store = new EnrollmentStore(paths, paths.Secrets);
        store.Save(new BromureInstall("i", "o", "u", "u@x", new Uri("https://x"),
            DateTimeOffset.UtcNow, "h"));
        store.StoreInstallToken("bearer-xyz");
        store.IsEnrolled.Should().BeTrue();
        store.Destroy();
        store.IsEnrolled.Should().BeFalse();
        store.LoadInstallToken().Should().BeNull();
    }

    [Fact]
    public void StoreLeafCert_PreservesSerialPointerAtomically()
    {
        using var paths = new TempPaths();
        var store = new EnrollmentStore(paths, paths.Secrets);
        store.StoreLeafCert(
            certPem: "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----",
            caPem: "-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----",
            privateKeyDer: new byte[] { 1, 2, 3, 4 },
            serialHex: "ABCD1234");
        store.LoadLeafSerial().Should().Be("abcd1234");
        store.LoadLeafPrivateKey("abcd1234").Should().Equal(1, 2, 3, 4);
        store.LoadLeafCertPem().Should().Contain("BEGIN CERTIFICATE");
        store.LoadCaPem().Should().Contain("BEGIN CERTIFICATE");
    }

    private sealed class TempPaths : IAppPaths, IDisposable
    {
        private readonly string _root;
        public TempPaths()
        {
            _root = Path.Combine(Path.GetTempPath(), "bromure-enroll-tests-" + Guid.NewGuid().ToString("N"));
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
