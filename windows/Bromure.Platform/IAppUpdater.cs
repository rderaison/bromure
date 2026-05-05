namespace Bromure.Platform;

/// <summary>
/// Auto-update seam. macOS uses Sparkle; Windows uses WinSparkle.
/// Both consume the same appcast XML — single-source the feed so the
/// release process publishes one URL.
/// </summary>
public interface IAppUpdater
{
    /// <summary>Best-effort init. Safe to call multiple times.</summary>
    void Initialize(string appcastUrl, string companyName, string appName, string appVersion);

    /// <summary>Triggers a silent background check.</summary>
    void CheckSilently();

    /// <summary>Triggers an interactive check (shows UI even if no update).</summary>
    void CheckInteractively();

    /// <summary>Releases native handles. Idempotent.</summary>
    void Shutdown();
}
