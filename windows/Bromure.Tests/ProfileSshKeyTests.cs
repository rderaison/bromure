using Bromure.AC.Core.Model;
using Bromure.AC.Core.Ssh;
using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class ProfileSshKeyTests : IDisposable
{
    private readonly string _root;
    private readonly TestPaths _paths;

    public ProfileSshKeyTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "bromure-ssh-test-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(_root);
        _paths = new TestPaths(_root);
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    [Fact]
    public void EnsureExists_mints_keypair_when_profile_has_none()
    {
        var p = new Profile { Name = "Test" };
        ProfileSshKey.EnsureExists(_paths, p);
        p.SshPublicKey.Should().StartWith("ssh-ed25519 ");
        File.Exists(Path.Combine(ProfileSshKey.DirectoryFor(_paths, p.Id), "id_ed25519.raw"))
            .Should().BeTrue();
    }

    [Fact]
    public void EnsureExists_is_idempotent_without_force()
    {
        var p = new Profile { Name = "Test" };
        ProfileSshKey.EnsureExists(_paths, p);
        var first = p.SshPublicKey;
        ProfileSshKey.EnsureExists(_paths, p);
        p.SshPublicKey.Should().Be(first, "second call without force should be a no-op");
    }

    [Fact]
    public void EnsureExists_force_rotates_the_key()
    {
        var p = new Profile { Name = "Test" };
        ProfileSshKey.EnsureExists(_paths, p);
        var first = p.SshPublicKey;
        ProfileSshKey.EnsureExists(_paths, p, force: true);
        p.SshPublicKey.Should().NotBe(first);
    }

    [Fact]
    public void Raw_seed_is_64_bytes_and_starts_with_32_byte_seed()
    {
        var p = new Profile { Name = "Test" };
        ProfileSshKey.EnsureExists(_paths, p);
        var raw = File.ReadAllBytes(Path.Combine(
            ProfileSshKey.DirectoryFor(_paths, p.Id), "id_ed25519.raw"));
        raw.Length.Should().Be(64, "32-byte ed25519 seed + 32-byte public key");
    }

    [Fact]
    public void Delete_removes_per_profile_dir()
    {
        var p = new Profile { Name = "Test" };
        ProfileSshKey.EnsureExists(_paths, p);
        var dir = ProfileSshKey.DirectoryFor(_paths, p.Id);
        Directory.Exists(dir).Should().BeTrue();
        ProfileSshKey.Delete(_paths, p.Id);
        Directory.Exists(dir).Should().BeFalse();
    }

    [Fact]
    public void Delete_is_safe_when_dir_does_not_exist()
    {
        var unknown = Guid.NewGuid();
        ProfileSshKey.Delete(_paths, unknown);
    }

    [Fact]
    public void EnsureExists_withDefaultKey_seedsFromShared()
    {
        var def = new DefaultSshKey(_paths);
        def.EnsureExists();
        var sharedPub = File.ReadAllText(def.PubPath).Trim();

        var p = new Profile { Name = "p1" };
        ProfileSshKey.EnsureExists(_paths, p, defaultKey: def);
        p.SshPublicKey.Should().Be(sharedPub, "audit 05 §3.1: new profile starts with the shared default key");

        var perProfileRaw = File.ReadAllBytes(Path.Combine(
            ProfileSshKey.DirectoryFor(_paths, p.Id), "id_ed25519.raw"));
        var defaultRaw = File.ReadAllBytes(def.RawPath);
        perProfileRaw.Should().Equal(defaultRaw, "the raw seed is a byte-for-byte copy of the default");
    }

    [Fact]
    public void EnsureExists_withDefaultKey_acrossMultipleProfiles_allMatch()
    {
        var def = new DefaultSshKey(_paths);
        def.EnsureExists();

        var p1 = new Profile { Name = "p1" };
        var p2 = new Profile { Name = "p2" };
        var p3 = new Profile { Name = "p3" };
        ProfileSshKey.EnsureExists(_paths, p1, defaultKey: def);
        ProfileSshKey.EnsureExists(_paths, p2, defaultKey: def);
        ProfileSshKey.EnsureExists(_paths, p3, defaultKey: def);

        // All three profiles converge on the same public key —
        // matches macOS "paste-once-into-GitHub" contract.
        p1.SshPublicKey.Should().Be(p2.SshPublicKey);
        p2.SshPublicKey.Should().Be(p3.SshPublicKey);
    }

    [Fact]
    public void EnsureExists_force_True_overridesDefaultKey_AndMintsUnique()
    {
        var def = new DefaultSshKey(_paths);
        def.EnsureExists();
        var sharedPub = File.ReadAllText(def.PubPath).Trim();

        var p = new Profile { Name = "p1" };
        ProfileSshKey.EnsureExists(_paths, p, defaultKey: def);
        p.SshPublicKey.Should().Be(sharedPub);

        // Regenerate command path — should land on a unique key
        // even though defaultKey is still in scope.
        ProfileSshKey.EnsureExists(_paths, p, force: true, defaultKey: def);
        p.SshPublicKey.Should().NotBe(sharedPub,
            "force=true means the user explicitly wants a unique key");
    }

    [Fact]
    public void EnsureExists_withDefaultKey_NoOpWhenAlreadyMinted()
    {
        var def = new DefaultSshKey(_paths);
        def.EnsureExists();

        var p = new Profile { Name = "p1" };
        ProfileSshKey.EnsureExists(_paths, p); // mints fresh, no default
        var minted = p.SshPublicKey;
        ProfileSshKey.EnsureExists(_paths, p, defaultKey: def);
        p.SshPublicKey.Should().Be(minted,
            "second call with default must NOT clobber an already-minted key");
    }

    private sealed class TestPaths : IAppPaths
    {
        public TestPaths(string root)
        {
            AppDataRoot = root;
            MachineDataRoot = root;
            ProfilesDirectory = Path.Combine(root, "profiles");
            TracesDirectory = Path.Combine(root, "traces");
            ImagesDirectory = Path.Combine(root, "images");
            SessionsDirectory = Path.Combine(root, "sessions");
            ResourcesDirectory = root;
        }
        public string AppDataRoot { get; }
        public string MachineDataRoot { get; }
        public string ProfilesDirectory { get; }
        public string TracesDirectory { get; }
        public string ImagesDirectory { get; }
        public string SessionsDirectory { get; }
        public string ResourcesDirectory { get; }
        public string EnsureDirectory(string path)
        {
            Directory.CreateDirectory(path);
            return path;
        }
    }
}
