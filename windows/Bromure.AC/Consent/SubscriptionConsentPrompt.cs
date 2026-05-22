using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Engine;

namespace Bromure.AC.Consent;

/// <summary>
/// WPF host's implementation of <see cref="ISubscriptionConsentPrompt"/>.
/// Decision logic lives in
/// <see cref="SubscriptionConsentDecision"/> (testable, no WPF deps);
/// this class supplies the actual MessageBox + maps the engine's
/// <c>ProviderKind</c> onto the Core enum.
/// </summary>
public sealed class SubscriptionConsentPrompt : ISubscriptionConsentPrompt
{
    private readonly ProfileStore _store;
    private readonly Func<string, string, bool> _ui;

    public SubscriptionConsentPrompt(ProfileStore store, Func<string, string, bool>? ui = null)
    {
        _store = store;
        _ui = ui ?? DefaultUi;
    }

    public Task<bool> AskFirstSwapAsync(Guid profileId, ProviderKind kind, CancellationToken ct)
    {
        var coreKind = kind == ProviderKind.Claude
            ? SubscriptionConsentDecision.ProviderKind.Claude
            : SubscriptionConsentDecision.ProviderKind.Codex;
        var allowed = SubscriptionConsentDecision.Resolve(profileId, coreKind, _store,
            (text, detail) => _ui(text, detail));
        return Task.FromResult(allowed);
    }

    private static bool DefaultUi(string text, string detail)
    {
        var result = System.Windows.MessageBox.Show(
            $"{text}\n\n{detail}",
            "Bromure AC — Subscription Token",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Question,
            System.Windows.MessageBoxResult.No);
        return result == System.Windows.MessageBoxResult.Yes;
    }
}
