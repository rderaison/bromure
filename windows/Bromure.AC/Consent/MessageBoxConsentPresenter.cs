using System.Windows;
using Bromure.AC.Mitm.Consent;

namespace Bromure.AC.Consent;

/// <summary>
/// Direct port of the <c>NSAlert</c>-based consent dialog from
/// <c>ConsentBroker.swift</c>. Uses WPF's built-in <see cref="MessageBox"/>
/// for the v1 host shell — a dedicated dialog with the four
/// 5-min/1-hour/session/deny buttons is a follow-up.
/// </summary>
public sealed class MessageBoxConsentPresenter : IConsentDialogPresenter
{
    public Task<ConsentBroker.Decision> AskAsync(
        string profileName, string credentialDisplayName, string scopeHint,
        CancellationToken ct)
    {
        var tcs = new TaskCompletionSource<ConsentBroker.Decision>();
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            var msg = $"Allow “{profileName}” to use {credentialDisplayName}?\n\n{scopeHint}\n\n"
                    + "Yes → allow for this session\n"
                    + "No  → deny";
            var result = MessageBox.Show(msg, "Bromure AC consent",
                MessageBoxButton.YesNo, MessageBoxImage.Question);
            tcs.SetResult(result == MessageBoxResult.Yes
                ? ConsentBroker.Decision.AllowSession
                : ConsentBroker.Decision.Deny);
        });
        return tcs.Task;
    }
}
