using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for the image-versioning alert flow (master audit gap #1 —
/// the user's headline example: "When the major version of the image
/// differs from the cloned copy, an alert shows up asking the user if
/// he wants to use the new image or the old one").
/// </summary>
public class ImageVersionAlertTests
{
    private static ImageVersionAlert.Decision NeverPrompt(string _, string __)
        => throw new InvalidOperationException("prompt was not expected to fire");

    [Fact]
    public void NoDiskYet_AlwaysProceeds()
    {
        var profile = new Profile { BaseImageVersionAtClone = "99" };
        ImageVersionAlert.Evaluate(profile, installedVersion: "100", diskExists: false, prompt: NeverPrompt)
            .Should().Be(ImageVersionAlert.Decision.ProceedAsIs);
    }

    [Fact]
    public void NoRecordedVersion_AlwaysProceeds()
    {
        var profile = new Profile { BaseImageVersionAtClone = null };
        ImageVersionAlert.Evaluate(profile, installedVersion: "100", diskExists: true, prompt: NeverPrompt)
            .Should().Be(ImageVersionAlert.Decision.ProceedAsIs);
    }

    [Fact]
    public void NoStampOnDisk_AlwaysProceeds()
    {
        // Bake hasn't stamped yet → can't compare → fail open.
        var profile = new Profile { BaseImageVersionAtClone = "99" };
        ImageVersionAlert.Evaluate(profile, installedVersion: null, diskExists: true, prompt: NeverPrompt)
            .Should().Be(ImageVersionAlert.Decision.ProceedAsIs);
    }

    [Fact]
    public void VersionsMatch_NoPromptNoChange()
    {
        var profile = new Profile { BaseImageVersionAtClone = "100" };
        ImageVersionAlert.Evaluate(profile, installedVersion: "100", diskExists: true, prompt: NeverPrompt)
            .Should().Be(ImageVersionAlert.Decision.ProceedAsIs);
    }

    [Fact]
    public void VersionDrift_FiresPromptAndReturnsUserChoice()
    {
        string? lastMessage = null;
        string? lastDetail = null;
        var profile = new Profile { BaseImageVersionAtClone = "99" };
        var decision = ImageVersionAlert.Evaluate(
            profile, installedVersion: "100", diskExists: true,
            prompt: (msg, detail) =>
            {
                lastMessage = msg;
                lastDetail = detail;
                return ImageVersionAlert.Decision.ResetAndLaunch;
            });
        decision.Should().Be(ImageVersionAlert.Decision.ResetAndLaunch);
        lastMessage.Should().Contain("Base image updated");
        lastDetail.Should().Contain("v99").And.Contain("v100");
    }

    [Fact]
    public void VersionDrift_UserCancel_AbortsLaunch()
    {
        var profile = new Profile { BaseImageVersionAtClone = "99" };
        ImageVersionAlert.Evaluate(profile, installedVersion: "100", diskExists: true,
            prompt: (_, _) => ImageVersionAlert.Decision.Cancel)
            .Should().Be(ImageVersionAlert.Decision.Cancel);
    }

    [Fact]
    public void VersionDrift_LaunchAsIs_LeavesProfileUntouched()
    {
        var profile = new Profile { BaseImageVersionAtClone = "99" };
        ImageVersionAlert.Evaluate(profile, installedVersion: "100", diskExists: true,
            prompt: (_, _) => ImageVersionAlert.Decision.ProceedAsIs)
            .Should().Be(ImageVersionAlert.Decision.ProceedAsIs);
        profile.BaseImageVersionAtClone.Should().Be("99");
    }

    [Fact]
    public void LegacyStampVsCurrentBakeWithUuidSuffix_NoPrompt()
    {
        // Profile saved with the pre-uuid stamp format ("100"); the
        // current bake uses the new "<v>:<uuid>" form. Same OS/packages,
        // so no alert should fire — surfacing one would scare users
        // about a non-material change. The 0xC03A000E auto-recovery in
        // HcsSession handles the parent-VHDX UniqueId rotation that
        // accompanies a fresh bake.
        var profile = new Profile { BaseImageVersionAtClone = "100" };
        ImageVersionAlert.Evaluate(
            profile,
            installedVersion: "100:b77c0d512f594e9b861e2e460a236fc4",
            diskExists: true,
            prompt: NeverPrompt)
            .Should().Be(ImageVersionAlert.Decision.ProceedAsIs);
    }

    [Fact]
    public void SameVersionDifferentBakeUuids_NoPrompt()
    {
        // User rebuilt the base — same version, fresh bake-uuid. The
        // child VHDX may need wiping (parent UniqueId rotated) but
        // that's the auto-recovery's job. No alert.
        var profile = new Profile { BaseImageVersionAtClone = "100:aaaaaaaa11111111aaaaaaaa11111111" };
        ImageVersionAlert.Evaluate(
            profile,
            installedVersion: "100:bbbbbbbb22222222bbbbbbbb22222222",
            diskExists: true,
            prompt: NeverPrompt)
            .Should().Be(ImageVersionAlert.Decision.ProceedAsIs);
    }

    [Fact]
    public void DifferentVersionsWithUuids_StillFiresPrompt()
    {
        // The version DID change (e.g., new OS / new packages). Alert
        // must still fire even though both stamps carry uuid suffixes.
        string? lastDetail = null;
        var profile = new Profile { BaseImageVersionAtClone = "99:aaaaaaaa11111111aaaaaaaa11111111" };
        var decision = ImageVersionAlert.Evaluate(
            profile,
            installedVersion: "100:bbbbbbbb22222222bbbbbbbb22222222",
            diskExists: true,
            prompt: (_, detail) => { lastDetail = detail; return ImageVersionAlert.Decision.ResetAndLaunch; });
        decision.Should().Be(ImageVersionAlert.Decision.ResetAndLaunch);
        // Detail uses the version prefix only — readable, no uuid noise.
        lastDetail.Should().Contain("v99").And.Contain("v100");
        lastDetail.Should().NotContain("aaaaaaaa", "uuid noise must be stripped from the user-facing message");
    }

    [Fact]
    public void ApplyReset_DeletesChildVhdxAndUpdatesStamp()
    {
        using var tmp = new TempDir();
        var sessionRoot = tmp.Path;
        var diskPath = Path.Combine(sessionRoot, "disk.vhdx");
        File.WriteAllText(diskPath, "stale child");

        var profile = new Profile { Id = Guid.NewGuid(), BaseImageVersionAtClone = "99" };
        var store = new ProfileStore(Path.Combine(tmp.Path, "profiles"));
        store.Save(profile);

        ImageVersionAlert.ApplyReset(sessionRoot, profile, "100", store);

        File.Exists(diskPath).Should().BeFalse("disk should be wiped on Reset");
        profile.BaseImageVersionAtClone.Should().Be("100");
        store.Load(profile.Id)!.BaseImageVersionAtClone.Should().Be("100");
    }

    private sealed class TempDir : IDisposable
    {
        public string Path { get; }
        public TempDir()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                "bromure-imgver-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }
        public void Dispose()
        {
            try { Directory.Delete(Path, recursive: true); } catch (IOException) { }
        }
    }
}
