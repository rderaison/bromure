namespace Bromure.AC.Core.Model;

/// <summary>
/// Pure decision logic for the Claude / Codex subscription-token
/// swap prompt. Reads + writes the per-profile tri-state on
/// <see cref="Profile.SubscriptionTokenSwap"/> /
/// <see cref="Profile.CodexTokenSwap"/> so the user's "Never for
/// this profile" choice sticks. The WPF host wraps this with a
/// MessageBox; tests inject a deterministic callback to exercise
/// every branch.
/// </summary>
public static class SubscriptionConsentDecision
{
    public enum ProviderKind { Claude, Codex }

    public delegate bool UserPrompt(string text, string detail);

    /// <summary>
    /// Should we proceed with swap registration for
    /// <paramref name="profileId"/>? Side-effect: persists the user's
    /// choice on the profile so a Yes/No answer sticks.
    /// </summary>
    public static bool Resolve(Guid profileId, ProviderKind kind,
        ProfileStore store, UserPrompt ask)
    {
        var profile = store.Load(profileId);
        if (profile is null) return false;

        var existing = kind == ProviderKind.Claude
            ? profile.SubscriptionTokenSwap
            : profile.CodexTokenSwap;
        if (existing == SubscriptionTokenSwapState.Accepted) return true;
        if (existing == SubscriptionTokenSwapState.Declined) return false;

        var providerLabel = kind == ProviderKind.Claude ? "Claude" : "Codex / ChatGPT";
        var allowed = ask(
            $"Capture {providerLabel} session token for re-use across sessions?",
            $"Bromure detected a clean {providerLabel} OAuth token leaving the VM. "
            + "If you allow capture, Bromure stores the real token on the host, "
            + "substitutes a fake into the VM, and re-injects it on future "
            + "session boots so you don't have to log in again.\n\n"
            + "The real token never leaves the host. Decline to skip — Bromure "
            + "won't ask again for this profile.");

        if (kind == ProviderKind.Claude)
            profile.SubscriptionTokenSwap = allowed ? SubscriptionTokenSwapState.Accepted : SubscriptionTokenSwapState.Declined;
        else
            profile.CodexTokenSwap = allowed ? SubscriptionTokenSwapState.Accepted : SubscriptionTokenSwapState.Declined;
        try { store.Save(profile); } catch { /* best-effort */ }
        return allowed;
    }
}
