using System.Windows;
using Bromure.AC.Mitm.Consent;

namespace Bromure.AC.Views;

public partial class ConsentDialog : Window
{
    public ConsentBroker.Decision Decision { get; private set; } = ConsentBroker.Decision.Deny;

    public ConsentDialog(string profileName, string credentialDisplayName, string scopeHint)
    {
        InitializeComponent();
        DataContext = new
        {
            HeaderText = $"Allow “{profileName}” to use this credential?",
            ScopeHint = scopeHint,
            CredentialDisplayName = credentialDisplayName,
        };
    }

    private void OnAllow1Hr(object sender, RoutedEventArgs e)
    {
        Decision = ConsentBroker.Decision.Allow1Hr;
        DialogResult = true;
    }

    private void OnAllow5Min(object sender, RoutedEventArgs e)
    {
        Decision = ConsentBroker.Decision.Allow5Min;
        DialogResult = true;
    }

    private void OnAllowSession(object sender, RoutedEventArgs e)
    {
        Decision = ConsentBroker.Decision.AllowSession;
        DialogResult = true;
    }

    private void OnDeny(object sender, RoutedEventArgs e)
    {
        Decision = ConsentBroker.Decision.Deny;
        DialogResult = true;
    }
}
