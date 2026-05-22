using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for <see cref="RestartRequiringChanges.Compute"/>. Audit 08
/// gap #5 — macOS prompts to reboot the session when relevant profile
/// fields change; without this diff we'd silently let the running VM
/// drift from what the user just saved.
/// </summary>
public class RestartRequiringChangesTests
{
    private static Profile NewBaseline() => new()
    {
        Id = Guid.NewGuid(),
        Name = "p",
        MemoryGB = 8,
        NetworkMode = NetworkMode.Nat,
        Tool = AgentTool.Claude,
        AuthMode = AuthMode.Token,
        ApiKey = "tok-1",
        TraceLevel = TraceLevel.Off,
        Aws = new AwsCredentialsConfig { AuthMode = AwsAuthMode.Sso, SsoProfile = "x" },
    };

    [Fact]
    public void Compute_NoChanges_ReturnsEmpty()
    {
        var p = NewBaseline();
        var snapshot = Clone(p);
        RestartRequiringChanges.Compute(p, snapshot).Should().BeEmpty();
    }

    [Fact]
    public void Compute_MemoryChange_FlagsMemory()
    {
        var oldP = NewBaseline();
        var newP = Clone(oldP);
        newP.MemoryGB = 16;
        RestartRequiringChanges.Compute(oldP, newP).Should().Contain(RestartRequiringChanges.Kind.Memory);
    }

    [Fact]
    public void Compute_NetworkModeChange_FlagsNetworking()
    {
        var oldP = NewBaseline();
        var newP = Clone(oldP);
        newP.NetworkMode = NetworkMode.Bridged;
        newP.BridgedInterfaceID = "eth0";
        RestartRequiringChanges.Compute(oldP, newP).Should().Contain(RestartRequiringChanges.Kind.Networking);
    }

    [Fact]
    public void Compute_FolderPathsChange_FlagsSharedFolders()
    {
        var oldP = NewBaseline();
        var newP = Clone(oldP);
        newP.FolderPaths.Add(@"C:\Projects");
        RestartRequiringChanges.Compute(oldP, newP).Should().Contain(RestartRequiringChanges.Kind.SharedFolders);
    }

    [Fact]
    public void Compute_ApiKeyChange_FlagsPrimaryTool()
    {
        var oldP = NewBaseline();
        var newP = Clone(oldP);
        newP.ApiKey = "tok-2";
        RestartRequiringChanges.Compute(oldP, newP).Should().Contain(RestartRequiringChanges.Kind.PrimaryTool);
    }

    [Fact]
    public void Compute_EnvVarChange_FlagsEnvironmentVariables()
    {
        var oldP = NewBaseline();
        var newP = Clone(oldP);
        newP.EnvironmentVariables.Add(new EnvironmentVariable { Name = "FOO", Value = "bar" });
        RestartRequiringChanges.Compute(oldP, newP).Should().Contain(RestartRequiringChanges.Kind.EnvironmentVariables);
    }

    [Fact]
    public void Compute_AwsChange_FlagsAwsCredentials()
    {
        var oldP = NewBaseline();
        var newP = Clone(oldP);
        newP.Aws.SsoProfile = "different-profile";
        RestartRequiringChanges.Compute(oldP, newP).Should().Contain(RestartRequiringChanges.Kind.AwsCredentials);
    }

    [Fact]
    public void Compute_TerminalAppearanceChange_FlagsTerminalAppearance()
    {
        var oldP = NewBaseline();
        var newP = Clone(oldP);
        newP.CustomFontSize = 14;
        RestartRequiringChanges.Compute(oldP, newP).Should().Contain(RestartRequiringChanges.Kind.TerminalAppearance);
    }

    [Fact]
    public void Compute_GitIdentityChange_FlagsGitIdentity()
    {
        var oldP = NewBaseline();
        var newP = Clone(oldP);
        newP.GitUserName = "Alice";
        RestartRequiringChanges.Compute(oldP, newP).Should().Contain(RestartRequiringChanges.Kind.GitIdentity);
    }

    [Fact]
    public void Compute_LifecycleFieldsAreIgnored()
    {
        // macOS deliberately omits CreatedAt / LastUsedAt /
        // BaseImageVersionAtClone / DefaultClaudeTokens / etc. from
        // the diff — restarting the VM doesn't apply them.
        var oldP = NewBaseline();
        var newP = Clone(oldP);
        newP.CreatedAt = oldP.CreatedAt.AddDays(-1);
        newP.LastUsedAt = DateTimeOffset.UtcNow;
        newP.BaseImageVersionAtClone = "999";
        newP.SubscriptionTokenSwap = SubscriptionTokenSwapState.Accepted;
        RestartRequiringChanges.Compute(oldP, newP).Should().BeEmpty();
    }

    [Fact]
    public void Compute_MultipleChanges_ReturnsAll()
    {
        var oldP = NewBaseline();
        var newP = Clone(oldP);
        newP.MemoryGB = 16;
        newP.TraceLevel = TraceLevel.All;
        newP.GitUserName = "Bob";
        var changes = RestartRequiringChanges.Compute(oldP, newP);
        changes.Should().Contain(RestartRequiringChanges.Kind.Memory);
        changes.Should().Contain(RestartRequiringChanges.Kind.TraceLevel);
        changes.Should().Contain(RestartRequiringChanges.Kind.GitIdentity);
        changes.Should().HaveCount(3);
    }

    [Fact]
    public void SaveAndDiffRunning_NoRunningSession_SkipsPromptStillSaves()
    {
        using var tmp = TempStore();
        var profile = NewBaseline();
        profile.MemoryGB = 8;
        tmp.Store.Save(profile);

        profile.MemoryGB = 16;
        var fired = false;
        var diff = RestartRequiringChanges.SaveAndDiffRunning(
            profile, tmp.Store,
            isProfileRunning: _ => false,
            onRestartRequired: (_, _) => fired = true);

        fired.Should().BeFalse("no live session → no prompt");
        diff.Should().BeEmpty("when isProfileRunning returns false we don't compute a diff");
        tmp.Store.Load(profile.Id)!.MemoryGB.Should().Be(16, "the save still happens");
    }

    [Fact]
    public void SaveAndDiffRunning_RunningWithChanges_FiresPromptOnce()
    {
        using var tmp = TempStore();
        var profile = NewBaseline();
        profile.MemoryGB = 8;
        tmp.Store.Save(profile);

        profile.MemoryGB = 16;
        profile.TraceLevel = TraceLevel.All;

        Profile? capturedProfile = null;
        IReadOnlyList<RestartRequiringChanges.Kind>? capturedDiff = null;
        var fireCount = 0;
        var diff = RestartRequiringChanges.SaveAndDiffRunning(
            profile, tmp.Store,
            isProfileRunning: _ => true,
            onRestartRequired: (p, d) =>
            {
                fireCount++;
                capturedProfile = p;
                capturedDiff = d;
            });

        fireCount.Should().Be(1);
        capturedProfile.Should().Be(profile);
        capturedDiff.Should().Contain(RestartRequiringChanges.Kind.Memory);
        capturedDiff.Should().Contain(RestartRequiringChanges.Kind.TraceLevel);
        diff.Should().BeEquivalentTo(capturedDiff);
    }

    [Fact]
    public void SaveAndDiffRunning_RunningButNoChanges_SkipsPrompt()
    {
        using var tmp = TempStore();
        var profile = NewBaseline();
        tmp.Store.Save(profile);
        // Re-save unchanged. No diff → no prompt.
        var fired = false;
        RestartRequiringChanges.SaveAndDiffRunning(
            profile, tmp.Store,
            isProfileRunning: _ => true,
            onRestartRequired: (_, _) => fired = true);
        fired.Should().BeFalse();
    }

    [Fact]
    public void SaveAndDiffRunning_PromptThrowing_DoesNotCorruptSave()
    {
        using var tmp = TempStore();
        var profile = NewBaseline();
        profile.MemoryGB = 8;
        tmp.Store.Save(profile);

        profile.MemoryGB = 24;
        RestartRequiringChanges.SaveAndDiffRunning(
            profile, tmp.Store,
            isProfileRunning: _ => true,
            onRestartRequired: (_, _) => throw new InvalidOperationException("UI is gone"));
        tmp.Store.Load(profile.Id)!.MemoryGB.Should().Be(24,
            "the save must succeed even if the prompt callback explodes");
    }

    private static TempStoreFixture TempStore() => new();

    private sealed class TempStoreFixture : IDisposable
    {
        public ProfileStore Store { get; }
        private readonly string _dir;
        public TempStoreFixture()
        {
            _dir = Path.Combine(Path.GetTempPath(), "bromure-restart-diff-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_dir);
            Store = new ProfileStore(_dir);
        }
        public void Dispose() { try { Directory.Delete(_dir, recursive: true); } catch (IOException) { } }
    }

    [Fact]
    public void DisplayLabel_AllKindsHaveLabels()
    {
        foreach (RestartRequiringChanges.Kind k in Enum.GetValues<RestartRequiringChanges.Kind>())
        {
            var label = RestartRequiringChanges.DisplayLabel(k);
            label.Should().NotBeNullOrWhiteSpace($"every kind needs a human-readable label; {k} did not");
        }
    }

    private static Profile Clone(Profile p)
    {
        var json = System.Text.Json.JsonSerializer.Serialize(p);
        return System.Text.Json.JsonSerializer.Deserialize<Profile>(json)!;
    }
}
