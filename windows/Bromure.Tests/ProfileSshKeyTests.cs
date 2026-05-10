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
