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
        var tcs = new TaskCompletionSource<ConsentBroker.Decision>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            // ANY exception inside the dispatcher lambda has to be
            // propagated to the awaiter — otherwise ConsentBroker's
            // driver hangs forever and every future coalesced waiter
            // for the same (profileId, credentialId) hangs with it
            // (cascading failure of every swap / sign on that
            // credential). Common triggers: MainWindow null during
            // shutdown, ConsentDialog ctor failure, OOM.
            try
            {
                var dlg = new ConsentDialog(profileName, credentialDisplayName, scopeHint)
                {
                    Owner = Application.Current.MainWindow,
                };
                // Activate: the user might have the VM display in focus when
                // a credential prompt fires.
                dlg.Activate();
                var ok = dlg.ShowDialog();
                tcs.TrySetResult(ok == true ? dlg.Decision : ConsentBroker.Decision.Deny);
            }
            catch (Exception ex)
            {
                tcs.TrySetException(ex);
            }
        });
        return tcs.Task;
    }
}
