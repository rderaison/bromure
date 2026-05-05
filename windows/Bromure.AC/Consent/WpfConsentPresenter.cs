using System.Windows;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Views;

namespace Bromure.AC.Consent;

/// <summary>
/// Replaces <see cref="MessageBoxConsentPresenter"/> with the proper
/// four-button modal sheet matching the macOS <c>NSAlert</c> shape.
/// </summary>
public sealed class WpfConsentPresenter : IConsentDialogPresenter
{
    public Task<ConsentBroker.Decision> AskAsync(
        string profileName, string credentialDisplayName, string scopeHint,
        CancellationToken ct)
    {
        var tcs = new TaskCompletionSource<ConsentBroker.Decision>();
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            var dlg = new ConsentDialog(profileName, credentialDisplayName, scopeHint)
            {
                Owner = Application.Current.MainWindow,
            };
            // Activate: the user might have the VM display in focus when
            // a credential prompt fires.
            dlg.Activate();
            var ok = dlg.ShowDialog();
            tcs.SetResult(ok == true ? dlg.Decision : ConsentBroker.Decision.Deny);
        });
        return tcs.Task;
    }
}
