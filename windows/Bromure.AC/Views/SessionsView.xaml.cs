using System.Windows;
using System.Windows.Controls;
using Bromure.AC.ViewModels;

namespace Bromure.AC.Views;

public partial class SessionsView : UserControl
{
    public SessionsView() => InitializeComponent();

    /// <summary>Resolve the SessionRowViewModel that the right-click
    /// menu was anchored to. The MenuItem.DataContext is the row's
    /// VM because the ContextMenu is set on ListBoxItem (which
    /// inherits its DataContext from the ItemsSource binding).</summary>
    private static SessionRowViewModel? RowFromMenuItem(object sender)
        => (sender as FrameworkElement)?.DataContext as SessionRowViewModel;

    private void OnViewSshPublicKey(object sender, RoutedEventArgs e)
    {
        var row = RowFromMenuItem(sender);
        if (row is null) return;
        var key = row.Profile.SshPublicKey;
        if (string.IsNullOrWhiteSpace(key))
        {
            MessageBox.Show(Window.GetWindow(this),
                "This profile doesn't have an SSH key yet. Launch the session once to generate one.",
                "SSH public key",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }
        // Show the key in a copyable text box. MessageBox content is
        // selectable in WPF (unlike WinForms), so this is enough for
        // a paste-into-GitHub workflow.
        var window = new Window
        {
            Title = $"SSH public key — {row.Profile.Name}",
            Width = 720, Height = 220,
            Owner = Window.GetWindow(this),
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.CanResize,
            ShowInTaskbar = false,
        };
        var grid = new Grid { Margin = new Thickness(12) };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var hint = new TextBlock
        {
            Text = "Public key — paste this into GitHub / your remote ~/.ssh/authorized_keys:",
            Margin = new Thickness(0, 0, 0, 8),
        };
        Grid.SetRow(hint, 0);
        var tb = new TextBox
        {
            Text = key,
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            AcceptsReturn = true,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        Grid.SetRow(tb, 1);
        var btnPanel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        var copy = new Button { Content = "Copy", Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(0, 0, 8, 0) };
        copy.Click += (_, __) =>
        {
            try { Clipboard.SetText(key); } catch { /* clipboard contention */ }
        };
        var close = new Button { Content = "Close", Padding = new Thickness(14, 4, 14, 4), IsCancel = true };
        close.Click += (_, __) => window.Close();
        btnPanel.Children.Add(copy);
        btnPanel.Children.Add(close);
        Grid.SetRow(btnPanel, 2);
        grid.Children.Add(hint);
        grid.Children.Add(tb);
        grid.Children.Add(btnPanel);
        window.Content = grid;
        window.ShowDialog();
    }

    private async void OnResetDiskClick(object sender, RoutedEventArgs e)
    {
        var row = RowFromMenuItem(sender);
        if (row is null) return;
        var choice = MessageBox.Show(
            Window.GetWindow(this),
            $"Reset disk for \"{row.Profile.Name}\"?\n\n" +
            "This wipes the per-profile VHDX, home overlay, and saved state. " +
            "Profile settings and the SSH key are preserved. The next launch " +
            "will boot a fresh copy of the base image.\n\nProceed?",
            "Reset disk",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);
        if (choice != MessageBoxResult.Yes) return;
        try
        {
            await row.ResetDiskAsync();
        }
        catch (System.Exception ex)
        {
            MessageBox.Show(Window.GetWindow(this),
                "Reset failed: " + ex.Message,
                "Reset disk", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OnDuplicateProfileClick(object sender, RoutedEventArgs e)
    {
        var row = RowFromMenuItem(sender);
        if (row is null) return;
        var clone = row.DuplicateProfile();
        // Reload the picker so the new row appears + select it.
        var vm = (sender as FrameworkElement)?.DataContext is SessionRowViewModel
            ? FindSessionsViewModel(sender)
            : null;
        if (vm is not null)
        {
            vm.Reload();
            var fresh = vm.Rows.FirstOrDefault(r => r.Profile.Id == clone.Id);
            if (fresh is not null) vm.Selected = fresh;
        }
    }

    /// <summary>Resolve the owning <see cref="SessionsViewModel"/>
    /// for a context-menu item event. The ContextMenu is a popup so
    /// the visual tree is detached — use the PlacementTarget chain
    /// to find the ListBox, then read its DataContext.</summary>
    private static SessionsViewModel? FindSessionsViewModel(object sender)
    {
        if (sender is MenuItem mi)
        {
            var menu = mi.Parent as ContextMenu ?? mi.GetType().GetProperty("Parent")?.GetValue(mi) as ContextMenu;
            // Walk up: ContextMenu → PlacementTarget (the Border in
            // ItemTemplate) → visual ancestors → ListBox.
            var target = menu?.PlacementTarget as DependencyObject;
            while (target is not null)
            {
                if (target is ListBox lb) return lb.DataContext as SessionsViewModel;
                target = System.Windows.Media.VisualTreeHelper.GetParent(target)
                         ?? System.Windows.LogicalTreeHelper.GetParent(target);
            }
        }
        return null;
    }

    private async void OnDeleteProfileClick(object sender, RoutedEventArgs e)
    {
        var row = RowFromMenuItem(sender);
        if (row is null) return;
        var choice = MessageBox.Show(
            Window.GetWindow(this),
            $"Delete profile \"{row.Profile.Name}\"?\n\n" +
            "This stops the session (if running), removes the profile " +
            "from the list, and deletes its data on disk. This cannot be undone.",
            "Delete profile",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);
        if (choice != MessageBoxResult.Yes) return;
        var listBox = AncestorListBox(sender);
        var vm = listBox?.DataContext as SessionsViewModel;
        if (vm is null) return;
        // Make sure DeleteSelected operates on this row, not whatever
        // happened to be selected.
        vm.Selected = row;
        try { await vm.DeleteSelectedCommand.ExecuteAsync(null); }
        catch (System.Exception ex)
        {
            MessageBox.Show(Window.GetWindow(this),
                "Delete failed: " + ex.Message,
                "Delete profile", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private static ListBox? AncestorListBox(object sender)
    {
        var fe = sender as FrameworkElement;
        // Walk up through the visual + logical parents to find the
        // owning ListBox (the menu lives in a popup so the tree is
        // not a simple chain — try Parent first, then templated parent).
        var dep = fe as System.Windows.DependencyObject;
        while (dep is not null)
        {
            if (dep is ListBox lb) return lb;
            dep = System.Windows.LogicalTreeHelper.GetParent(dep)
                  ?? System.Windows.Media.VisualTreeHelper.GetParent(dep);
        }
        // Fall back: locate via the open ContextMenu's PlacementTarget.
        if (sender is MenuItem mi && mi.Parent is ContextMenu cm && cm.PlacementTarget is FrameworkElement target)
        {
            dep = target;
            while (dep is not null)
            {
                if (dep is ListBox lb) return lb;
                dep = System.Windows.LogicalTreeHelper.GetParent(dep)
                      ?? System.Windows.Media.VisualTreeHelper.GetParent(dep);
            }
        }
        return null;
    }
}
