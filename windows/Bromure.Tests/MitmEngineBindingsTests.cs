using Bromure.AC.Core.Model;
using Bromure.AC.Core.Ssh;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.Engine;
using Bromure.AC.Mitm.Aws;
using Bromure.AC.Mitm.Ssh;
using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Integration coverage for <see cref="MitmEngine.ApplyProfileBindingsAsync"/>.
/// The audit flagged AwsCredentialServer.SetCredentials + SshAgent.SetKeys
/// + AwsSsoResolver.StartRefreshLoopAsync as never-called dead code; these
/// tests prove the engine wires them at session start now.
/// </summary>
public class MitmEngineBindingsTests
{
    [Fact]
    public async Task ApplyProfileBindings_StaticAwsKeys_PopulateCredentialServer()
    {
        using var paths = new TestPaths();
        await using var engine = new MitmEngine(paths, paths.Secrets, new AlwaysAllowSessionDialogPresenter());
        var profile = new Profile
        {
            Id = Guid.NewGuid(),
            Name = "test",
            Aws = new AwsCredentialsConfig
            {
                AuthMode = AwsAuthMode.StaticKeys,
                AccessKeyId = "AKIAIOSFODNN7EXAMPLE",
                SecretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                SessionToken = "session-token-abc",
            },
        };

        await engine.ApplyProfileBindingsAsync(profile);

        var material = await engine.AwsCreds.SigningMaterialAsync(profile.Id, "iam", CancellationToken.None);
        material.Should().BeOfType<SigningMaterial.Material>();
        var creds = ((SigningMaterial.Material)material).Credentials;
        creds.AccessKeyId.Should().Be("AKIAIOSFODNN7EXAMPLE");
        creds.SecretAccessKey.Should().Be("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
        creds.SessionToken.Should().Be("session-token-abc");
    }

    [Fact]
    public async Task ApplyProfileBindings_DefaultSshKey_LoadsIntoAgent()
    {
        using var paths = new TestPaths();
        await using var engine = new MitmEngine(paths, paths.Secrets, new AlwaysAllowSessionDialogPresenter());
        var profile = new Profile { Id = Guid.NewGuid(), Name = "test" };

        // Generate the profile's ed25519 key on disk where the engine
        // expects it. Matches what BromureAC.swift's makeSSHKey + the
        // Windows ProfileSshKey.EnsureExists do at first launch.
        ProfileSshKey.EnsureExists(paths, profile);

        await engine.ApplyProfileBindingsAsync(profile);

        var loaded = engine.SshAgent.KeysFor(profile.Id);
        loaded.Should().HaveCount(1);
        loaded[0].Should().BeOfType<Ed25519AgentKey>();
        ((Ed25519AgentKey)loaded[0]).Seed.Length.Should().Be(32);
        loaded[0].PublicKey.Length.Should().Be(32);
        loaded[0].Comment.Should().StartWith("bromure-ac-");
    }

    [Fact]
    public async Task ApplyProfileBindings_ImportedSshKey_LoadsIntoAgent()
    {
        using var paths = new TestPaths();
        await using var engine = new MitmEngine(paths, paths.Secrets, new AlwaysAllowSessionDialogPresenter());
        // Mint a real-looking PEM by going through the encoder.
        var seed = new byte[32];
        var pub = new byte[32];
        for (var i = 0; i < 32; i++) { seed[i] = (byte)(i + 7); pub[i] = (byte)(i * 3 + 1); }
        var pem = System.Text.Encoding.ASCII.GetString(
            Bromure.AC.Mitm.Ssh.OpenSshKeyFormat.Ed25519Pem(seed, pub, "imported-test"));

        var profile = new Profile
        {
            Id = Guid.NewGuid(),
            Name = "test",
            ImportedSshKeys =
            {
                new ImportedSshKey { Label = "imported-test", PrivateKeyPem = pem, RequireApproval = true },
            },
        };

        await engine.ApplyProfileBindingsAsync(profile);

        var loaded = engine.SshAgent.KeysFor(profile.Id);
        loaded.Should().HaveCount(1);
        loaded[0].Comment.Should().Be("imported-test");
        loaded[0].RequireApproval.Should().BeTrue();
        loaded[0].Should().BeOfType<Ed25519AgentKey>();
        ((Ed25519AgentKey)loaded[0]).Seed.Should().Equal(seed);
        loaded[0].PublicKey.Should().Equal(pub);
    }

    [Fact]
    public async Task ApplyProfileBindings_SshKeyRequiresApproval_PropagatesFlag()
    {
        using var paths = new TestPaths();
        await using var engine = new MitmEngine(paths, paths.Secrets, new AlwaysAllowSessionDialogPresenter());
        var profile = new Profile
        {
            Id = Guid.NewGuid(),
            Name = "test",
            SshKeyRequiresApproval = true,
        };
        ProfileSshKey.EnsureExists(paths, profile);

        await engine.ApplyProfileBindingsAsync(profile);

        engine.SshAgent.KeysFor(profile.Id)[0].RequireApproval.Should().BeTrue();
    }

    [Fact]
    public async Task ApplyProfileBindings_NullProfile_DoesNotThrow()
    {
        using var paths = new TestPaths();
        await using var engine = new MitmEngine(paths, paths.Secrets, new AlwaysAllowSessionDialogPresenter());
        await engine.ApplyProfileBindingsAsync(null);
    }

    private sealed class TestPaths : IAppPaths, IDisposable
    {
        private readonly string _root;
        public TestPaths()
        {
            _root = Path.Combine(Path.GetTempPath(), "bromure-engine-bind-" + Guid.NewGuid().ToString("N"));
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
        public string EnsureDirectory(string p) { Directory.CreateDirectory(p); return p; }
        public void Dispose() { try { Directory.Delete(_root, recursive: true); } catch (IOException) { } }
    }

    public sealed class InMemorySecretStore : ISecretStore
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
