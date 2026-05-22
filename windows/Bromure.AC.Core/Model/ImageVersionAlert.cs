namespace Bromure.AC.Core.Model;

/// <summary>
/// Direct port of macOS <c>BromureAC.swift:2019-2041</c>: when a
/// profile's <see cref="Profile.BaseImageVersionAtClone"/> differs
/// from the version stamped at the most recent bake, the launcher
/// must surface a 3-button alert ("Reset and launch" / "Launch as-is"
/// / "Cancel"). The pure decision logic lives here so the test suite
/// (which can't reference the WPF host) covers every branch; the
/// view-model layers the actual <c>MessageBox</c> on top.
/// </summary>
public static class ImageVersionAlert
{
    /// <summary>What the launcher should do after consulting the user.</summary>
    public enum Decision
    {
        /// No drift, or no stamp — proceed as normal.
        ProceedAsIs,
        /// User clicked "Reset and launch". Caller should delete the
        /// child VHDX and re-stamp BaseImageVersionAtClone before boot.
        ResetAndLaunch,
        /// User clicked Cancel. Caller should abort launch.
        Cancel,
    }

    public delegate Decision Prompt(string message, string detail);

    /// <summary>
    /// Compare the profile's recorded clone-time version against what
    /// the engine has stamped on disk and (when they differ) invoke
    /// <paramref name="prompt"/>. The default behaviour when no drift /
    /// first launch / no stamp is <see cref="Decision.ProceedAsIs"/>.
    ///
    /// <para>Stamp format. The bake writes <c>&lt;version&gt;:&lt;bake-uuid&gt;</c>;
    /// older bakes wrote just <c>&lt;version&gt;</c>. Equality is decided on
    /// the version prefix ONLY — the bake-uuid distinguishes individual
    /// bakes of the same OS/package set but doesn't change what's installed.
    /// When only the uuid differs, the parent VHDX UniqueId may have rotated
    /// and the child differential will fail with 0xC03A000E on boot; that's
    /// handled transparently by <c>HcsSession</c>'s auto-recovery, which wipes
    /// the child and retries. Surfacing a 3-button alert for that case would
    /// scare users into thinking their VM data was lost when really nothing
    /// material changed.</para>
    /// </summary>
    public static Decision Evaluate(Profile profile, string? installedVersion,
        bool diskExists, Prompt prompt)
    {
        if (!diskExists) return Decision.ProceedAsIs;
        var recorded = profile.BaseImageVersionAtClone;
        if (string.IsNullOrEmpty(recorded) || string.IsNullOrEmpty(installedVersion))
            return Decision.ProceedAsIs;
        if (string.Equals(VersionPrefix(recorded), VersionPrefix(installedVersion), StringComparison.Ordinal))
            return Decision.ProceedAsIs;

        var message = "Base image updated since this profile was created.";
        var detail = $"This profile is on base v{VersionPrefix(recorded)}; the current base is "
                     + $"v{VersionPrefix(installedVersion)}. Reset the profile disk to pick up the new base? "
                     + "(Resetting wipes anything you've installed inside the VM. Your project "
                     + "folder is untouched.)";
        return prompt(message, detail);
    }

    /// <summary>Extract the version-prefix portion of a stamp.
    /// <c>"100" → "100"</c>; <c>"100:abc123" → "100"</c>. The bake-uuid
    /// suffix is intentionally ignored — see <see cref="Evaluate"/>.
    /// Public because the shell's "base image update available" nag
    /// (<c>CheckStaleBaseImageNag</c>) uses the same comparator.</summary>
    public static string VersionPrefix(string stamp)
    {
        var idx = stamp.IndexOf(':');
        return idx < 0 ? stamp : stamp[..idx];
    }

    /// <summary>
    /// Apply <see cref="Decision.ResetAndLaunch"/>: drop the child VHDX
    /// so the next boot recreates it from the current base, and stamp
    /// <see cref="Profile.BaseImageVersionAtClone"/> to the new
    /// version. Idempotent — missing VHDX is fine.
    /// </summary>
    public static void ApplyReset(string sessionRoot, Profile profile,
        string installedVersion, ProfileStore store)
    {
        var diskPath = Path.Combine(sessionRoot, "disk.vhdx");
        try { File.Delete(diskPath); } catch (IOException) { }
        profile.BaseImageVersionAtClone = installedVersion;
        store.Save(profile);
    }
}
