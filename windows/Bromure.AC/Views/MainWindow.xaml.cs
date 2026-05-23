using System.ComponentModel;
using System.Linq;
using System.Windows;
using Bromure.AC.ViewModels;

namespace Bromure.AC.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        DataContext = new ShellViewModel(App.Services);
    }

    private void OnCheckForUpdatesClick(object sender, RoutedEventArgs e)
    {
        App.Updater?.CheckInteractively();
    }

    /// <summary>Intercept the close request so we can warn the user
    /// before terminating running VMs or aborting an in-flight image
    /// bake. Audit 08 §1.3 (HIGH) + §1.10 (MEDIUM): previous
    /// implementation silently killed every running session on
    /// window-close and dropped a bake task without cleanup. Now we
    /// surface both, ask Yes/No, and honour cancel.</summary>
    protected override void OnClosing(CancelEventArgs e)
    {
        base.OnClosing(e);
        if (e.Cancel) return;
        if (DataContext is not ShellViewModel vm) return;

        var running = vm.SessionsPane.Rows.Where(r => r.IsRunning).ToArray();
        var baking = vm.Phase == ShellPhase.Initializing;
        if (running.Length == 0 && !baking) return;

        string msg;
        if (running.Length > 0 && baking)
        {
            var names = string.Join("\n", running.Select(r => "  • " + r.Profile.Name));
            msg =
                $"An image build is in progress AND you have {running.Length} session{(running.Length == 1 ? "" : "s")} running:\n\n" +
                $"{names}\n\n" +
                "Closing Bromure will cancel the build and terminate all sessions. Continue?";
        }
        else if (running.Length > 0)
        {
            var names = string.Join("\n", running.Select(r => "  • " + r.Profile.Name));
            msg =
                $"You have {running.Length} session{(running.Length == 1 ? "" : "s")} running:\n\n" +
                $"{names}\n\n" +
                "Closing Bromure will terminate them and discard any unsaved work in those VMs. Continue?";
        }
        else
        {
            msg =
                "An image build is in progress. Closing Bromure will cancel the build " +
                "and you'll need to start it again next time. Continue?";
        }
        var choice = MessageBox.Show(
            this,
            msg,
            "Quit Bromure?",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);
        if (choice != MessageBoxResult.Yes)
        {
            e.Cancel = true;
        }
    }

    protected override async void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        if (DataContext is not ShellViewModel vm) return;

        // 1. Cancel an in-flight image bake first so the spawned
        // builder VM begins tearing down while we shut down sessions.
        if (vm.Phase == ShellPhase.Initializing)
        {
            try { vm.CancelCommand.Execute(null); } catch { }
        }
        // 2. Tear down EVERY running session, not just vm.Session —
        // the old code path only cleaned up the single-session field
        // even though SessionsPane.Rows may have many live VMs.
        var runningRows = vm.SessionsPane.Rows.Where(r => r.IsRunning).ToArray();
        foreach (var row in runningRows)
        {
            try { await row.ShutdownAsync(); } catch { /* best-effort during exit */ }
        }
        if (vm.Session is not null)
        {
            try { await vm.Session.DisposeAsync(); } catch { }
        }
    }
}
