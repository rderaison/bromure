using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for the compromise-boot gate (master audit gap #15).
/// </summary>
public class CompromiseGateTests
{
    [Fact]
    public void IsCompromised_NoFlag_ReturnsFalse()
    {
        using var tmp = new TempDir();
        CompromiseGate.IsCompromised(tmp.Path).Should().BeFalse();
    }

    [Fact]
    public void Mark_DropsFlagFile_WithUtcTimestampBody()
    {
        using var tmp = new TempDir();
        CompromiseGate.Mark(tmp.Path);
        var flag = Path.Combine(tmp.Path, CompromiseGate.FlagFileName);
        File.Exists(flag).Should().BeTrue();
        var body = File.ReadAllText(flag);
        // ISO 8601 round-trip ("O") starts with year + dash, e.g. 2026-05-21T…
        body.Should().MatchRegex(@"^\d{4}-\d{2}-\d{2}T");
    }

    [Fact]
    public void Mark_Idempotent()
    {
        using var tmp = new TempDir();
        CompromiseGate.Mark(tmp.Path);
        CompromiseGate.Mark(tmp.Path);  // shouldn't throw
        CompromiseGate.IsCompromised(tmp.Path).Should().BeTrue();
    }

    [Fact]
    public void WipeForCompromise_DropsDiskHomeSavedStateAndFlag()
    {
        using var tmp = new TempDir();
        File.WriteAllText(Path.Combine(tmp.Path, "disk.vhdx"), "stale disk");
        File.WriteAllText(Path.Combine(tmp.Path, "saved-state.bin"), "stale save");
        Directory.CreateDirectory(Path.Combine(tmp.Path, "home", ".ssh"));
        File.WriteAllText(Path.Combine(tmp.Path, "home", ".ssh", "id_ed25519"), "secret");
        CompromiseGate.Mark(tmp.Path);

        CompromiseGate.WipeForCompromise(tmp.Path);

        File.Exists(Path.Combine(tmp.Path, "disk.vhdx")).Should().BeFalse();
        File.Exists(Path.Combine(tmp.Path, "saved-state.bin")).Should().BeFalse();
        File.Exists(Path.Combine(tmp.Path, CompromiseGate.FlagFileName)).Should().BeFalse();
        Directory.Exists(Path.Combine(tmp.Path, "home")).Should().BeFalse();
    }

    [Fact]
    public void WipeForCompromise_LeavesSharedFolderHostsAlone()
    {
        // The compromise wipe touches the per-profile session root
        // only — host shared-folder paths (e.g. ~/Projects) live
        // outside it and must not be deleted.
        using var tmp = new TempDir();
        using var hostFolder = new TempDir();
        var sentinel = Path.Combine(hostFolder.Path, "untouched.txt");
        File.WriteAllText(sentinel, "do not delete");

        CompromiseGate.WipeForCompromise(tmp.Path);
        File.Exists(sentinel).Should().BeTrue();
    }

    [Fact]
    public void WipeForCompromise_NoSessionRoot_NoOp()
    {
        // Non-existent dir → quiet no-op. Important because the
        // launcher may invoke this before any session has been
        // created (compromise flag set, then user deleted folder).
        var ghostPath = Path.Combine(Path.GetTempPath(),
            "bromure-ghost-" + Guid.NewGuid().ToString("N"));
        CompromiseGate.WipeForCompromise(ghostPath);  // no throw
    }

    [Fact]
    public void ConfirmWipe_BuildsMessageWithProfileName()
    {
        var profile = new Profile { Name = "evil-laptop" };
        string? capturedMsg = null;
        CompromiseGate.ConfirmWipe(profile, (msg, _) =>
        {
            capturedMsg = msg;
            return CompromiseGate.WipeDecision.Cancel;
        });
        capturedMsg.Should().Contain("evil-laptop");
        capturedMsg.Should().Contain("compromised");
    }

    [Fact]
    public void ConfirmWipe_NoSharedFolders_SkipsWarning()
    {
        var profile = new Profile { Name = "p" };
        string? capturedDetail = null;
        CompromiseGate.ConfirmWipe(profile, (_, detail) =>
        {
            capturedDetail = detail;
            return CompromiseGate.WipeDecision.Cancel;
        });
        capturedDetail.Should().NotContain("WARNING");
    }

    [Fact]
    public void ConfirmWipe_WithSharedFolders_ListsThemInWarning()
    {
        var profile = new Profile { Name = "p" };
        profile.FolderPaths.Add(@"C:\Users\me\Projects\thing");
        profile.FolderPaths.Add(@"C:\Users\me\Projects\other");
        string? capturedDetail = null;
        CompromiseGate.ConfirmWipe(profile, (_, detail) =>
        {
            capturedDetail = detail;
            return CompromiseGate.WipeDecision.Cancel;
        });
        capturedDetail.Should().Contain("WARNING");
        capturedDetail.Should().Contain(@"C:\Users\me\Projects\thing");
        capturedDetail.Should().Contain(@"C:\Users\me\Projects\other");
    }

    [Fact]
    public void ConfirmWipe_UserApproves_PropagatesWipeAndLaunch()
    {
        var profile = new Profile { Name = "p" };
        var decision = CompromiseGate.ConfirmWipe(profile,
            (_, _) => CompromiseGate.WipeDecision.WipeAndLaunch);
        decision.Should().Be(CompromiseGate.WipeDecision.WipeAndLaunch);
    }

    private sealed class TempDir : IDisposable
    {
        public string Path { get; }
        public TempDir()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                "bromure-compromise-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }
        public void Dispose()
        {
            try { Directory.Delete(Path, recursive: true); } catch (IOException) { }
        }
    }
}
