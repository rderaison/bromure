namespace Bromure.AC.Core.Model;

/// <summary>
/// Direct port of <c>SessionDisk.isCompromised / markCompromised</c>
/// + <c>confirmWipeAndProceed</c> from macOS BromureAC. The MITM
/// compromise detector marks a per-profile flag on disk when an
/// outbound credential leak is observed; the launcher refuses to
/// boot until the user explicitly approves a wipe.
///
/// <para>Flag file: <c>&lt;sessionRoot&gt;/compromised.flag</c>.
/// Body is the UTC timestamp of the flag for forensic value.</para>
/// </summary>
public static class CompromiseGate
{
    public const string FlagFileName = "compromised.flag";

    /// <summary>True iff <paramref name="sessionRoot"/> contains the
    /// flag file. Used by the picker to show a red badge and by the
    /// launcher to gate the boot path.</summary>
    public static bool IsCompromised(string sessionRoot)
        => File.Exists(Path.Combine(sessionRoot, FlagFileName));

    /// <summary>Drop the flag file. Called by the compromise detector
    /// when an outbound leak is observed. Idempotent.</summary>
    public static void Mark(string sessionRoot)
    {
        Directory.CreateDirectory(sessionRoot);
        var stamp = DateTimeOffset.UtcNow.ToString("O");
        File.WriteAllText(Path.Combine(sessionRoot, FlagFileName), stamp);
    }

    /// <summary>Wipe the per-profile disk + home overlay + flag.
    /// Used by the confirmation handler after the user approves
    /// "Wipe and Launch". Shared folders are NOT touched — the
    /// caller surfaces that warning in the alert text.</summary>
    public static void WipeForCompromise(string sessionRoot)
    {
        if (!Directory.Exists(sessionRoot)) return;
        // Surgical wipe: drop the VHDX, the home overlay tar, the
        // saved-state file, and the flag. Anything else under the
        // session root (logs, debug dumps, etc.) is fine to keep.
        TryDelete(Path.Combine(sessionRoot, "disk.vhdx"));
        TryDelete(Path.Combine(sessionRoot, "saved-state.bin"));
        TryDelete(Path.Combine(sessionRoot, FlagFileName));
        var homeDir = Path.Combine(sessionRoot, "home");
        if (Directory.Exists(homeDir))
        {
            try { Directory.Delete(homeDir, recursive: true); }
            catch (IOException) { }
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { /* best-effort */ }
        catch (UnauthorizedAccessException) { }
    }

    /// <summary>Outcome of the wipe-confirmation dialog.</summary>
    public enum WipeDecision { Cancel, WipeAndLaunch }

    public delegate WipeDecision Prompt(string messageText, string detail);

    /// <summary>
    /// Show the critical-style wipe-confirmation alert. Returns the
    /// user's choice; on <see cref="WipeDecision.WipeAndLaunch"/> the
    /// caller invokes <see cref="WipeForCompromise"/>.
    ///
    /// <para>UI seam: <paramref name="prompt"/> defaults to a WPF
    /// MessageBox in the host view-model; tests inject a
    /// deterministic callback here.</para>
    /// </summary>
    public static WipeDecision ConfirmWipe(Profile profile, Prompt prompt)
    {
        var message = $"⛔ \"{profile.Name}\" is marked as compromised";
        var detail = "Bromure refused to boot this VM because the proxy detected "
                     + "an outbound credential leak in a previous session.\n\n"
                     + "To continue, the VM disk image and the persistent home folder "
                     + "must be wiped. Your tokens, ssh keys, and profile settings are "
                     + "preserved.";
        if (profile.FolderPaths.Count > 0)
        {
            detail += "\n\nWARNING: shared folders are NOT wiped. Compromised packages or "
                      + "files may still be present in:\n";
            foreach (var path in profile.FolderPaths)
                detail += $"  • {path}\n";
            detail += "Inspect those folders before launching anything that re-uses them.";
        }
        return prompt(message, detail);
    }
}
