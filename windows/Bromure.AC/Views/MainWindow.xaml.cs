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

    private void OnMinimizeMainWindow(object sender, RoutedEventArgs e)
        => WindowState = WindowState.Minimized;

    private void OnBringMainToFront(object sender, RoutedEventArgs e)
    {
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Focus();
    }

    /// <summary>Audit 08 — Window menu populated on open. Rebuild the
    /// session-row entries each time so closed sessions disappear and
    /// fresh ones show up without us subscribing to collection
    /// changes. Removes any MenuItem we appended last time before
    /// re-adding.</summary>
    private void OnWindowMenuOpened(object sender, RoutedEventArgs e)
    {
        var menu = (System.Windows.Controls.MenuItem)sender;
        var keep = new HashSet<object?> { menu.Items[0], menu.Items[1], WindowMenuSeparator, WindowMenuEmpty };
        for (var i = menu.Items.Count - 1; i >= 0; i--)
        {
            if (!keep.Contains(menu.Items[i])) menu.Items.RemoveAt(i);
        }

        var running = (DataContext is ShellViewModel vm)
            ? vm.SessionsPane.Rows.Where(r => r.IsRunning).ToArray()
            : Array.Empty<SessionRowViewModel>();
        WindowMenuEmpty.Visibility = running.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var row in running)
        {
            var item = new System.Windows.Controls.MenuItem
            {
                Header = row.Profile.Name,
                Tag = row,
            };
            item.Click += OnRaiseSessionWindow;
            menu.Items.Add(item);
        }
    }

    private void OnRaiseSessionWindow(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.MenuItem mi && mi.Tag is SessionRowViewModel)
        {
            // SessionWindow holds a single static _instance — bring it
            // to the front. (When we expand to multi-window-per-session
            // each row will need a dedicated window reference.)
            var sw = Views.SessionWindow.CurrentInstance;
            if (sw is null) return;
            if (sw.WindowState == WindowState.Minimized) sw.WindowState = WindowState.Normal;
            sw.Show();
            sw.Activate();
        }
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
