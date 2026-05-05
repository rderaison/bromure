using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class ProfileStoreTests
{
    [Fact]
    public void Save_LoadAll_RoundTripsThroughJson()
    {
        using var dir = new TempDir();
        var store = new ProfileStore(dir.Path);
        var profile = new Profile
        {
            Name = "Test",
            Tool = AgentTool.Claude,
            AuthMode = AuthMode.Token,
            ApiKey = "sk-test",
            FolderPaths = new List<string> { @"C:\src" },
            ManualTokens = new()
            {
                new ManualToken
                {
                    Id = Guid.NewGuid(),
                    Name = "DO PAT",
                    Value = "secret-value",
                    EnvVarName = "DIGITALOCEAN_TOKEN",
                },
            },
            Kubeconfigs = new()
            {
                new KubeconfigEntry
                {
                    Name = "prod",
                    ServerUrl = "https://k8s.example.com",
                    Auth = new KubeBearerToken { Token = "real-token" },
                },
            },
            TraceLevel = TraceLevel.AiDetails,
        };
        store.Save(profile);

        var loaded = store.LoadAll();
        loaded.Should().HaveCount(1);
        loaded[0].Name.Should().Be("Test");
        loaded[0].FolderPaths.Should().Equal(@"C:\src");
        loaded[0].ManualTokens.Should().HaveCount(1);
        loaded[0].Kubeconfigs.Should().HaveCount(1);
        loaded[0].Kubeconfigs[0].Auth.Should().BeOfType<KubeBearerToken>();
        loaded[0].TraceLevel.Should().Be(TraceLevel.AiDetails);
    }

    [Fact]
    public void Delete_RemovesPersistedFile()
    {
        using var dir = new TempDir();
        var store = new ProfileStore(dir.Path);
        var profile = new Profile { Name = "Throwaway" };
        store.Save(profile);
        store.Delete(profile.Id).Should().BeTrue();
        store.LoadAll().Should().BeEmpty();
        store.Delete(profile.Id).Should().BeFalse();
    }

    [Fact]
    public void Load_ReturnsNullForMissingProfile()
    {
        using var dir = new TempDir();
        var store = new ProfileStore(dir.Path);
        store.Load(Guid.NewGuid()).Should().BeNull();
    }

    private sealed class TempDir : IDisposable
    {
        public string Path { get; }
        public TempDir()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                "bromure-profile-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }
        public void Dispose() { try { Directory.Delete(Path, recursive: true); } catch (IOException) { } }
    }
}
