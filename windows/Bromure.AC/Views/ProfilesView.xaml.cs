using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using Bromure.AC.ViewModels;

namespace Bromure.AC.Views;

public partial class ProfilesView : UserControl
{
    public ProfilesView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    /// <summary>
    /// Collapse the left picker column when the bound view-model is
    /// in <see cref="ProfilesViewModel.EditorOnly"/> mode. Drive
    /// the ColumnDefinition.Width from code because GridLength isn't
    /// directly bindable through a converter cleanly.
    /// </summary>
    private void OnDataContextChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is INotifyPropertyChanged oldVm)
            oldVm.PropertyChanged -= OnVmPropertyChanged;
        if (e.NewValue is INotifyPropertyChanged newVm)
            newVm.PropertyChanged += OnVmPropertyChanged;
        ApplyEditorOnlyFromVm(e.NewValue as ProfilesViewModel);
    }

    private void OnVmPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ProfilesViewModel.EditorOnly))
            ApplyEditorOnlyFromVm(sender as ProfilesViewModel);
    }

    private void ApplyEditorOnlyFromVm(ProfilesViewModel? vm)
    {
        if (vm is null) return;
        PickerColumn.Width = vm.EditorOnly
            ? new GridLength(0)
            : new GridLength(240);
    }

    /// <summary>Open an external URL in the user's default browser.
    /// Bound by Hyperlink.RequestNavigate in the editor's
    /// "Open … token page" affordances.</summary>
    private void OnHyperlinkNavigate(object sender, System.Windows.Navigation.RequestNavigateEventArgs e)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = e.Uri.AbsoluteUri,
                UseShellExecute = true,
            });
            e.Handled = true;
        }
        catch { /* best-effort */ }
    }

    /// <summary>Open a small popup with a curated palette of
    /// programmer-terminal-friendly colors. Tag on the invoking
    /// button selects which profile field to write back — "bg" or
    /// "fg". WPF doesn't ship a ColorDialog and pulling WinForms
    /// in globally clashes with WPF type names — a 14-color preset
    /// palette covers 95% of users and a hex input handles the rest.
    /// Audit code-comb follow-up: the previous text-only inputs let
    /// users set fg=bg and end up with a terminal where everything
    /// was invisible.</summary>
    private void OnPickColorClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button b) return;
        if (DataContext is not ProfilesViewModel vm || vm.Selected is null) return;
        var fieldTag = b.Tag as string;
        var picker = new ColorPickerPopup
        {
            Owner = System.Windows.Window.GetWindow(this),
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Title = fieldTag == "bg" ? "Pick background color" : "Pick foreground color",
        };
        if (picker.ShowDialog() != true || picker.PickedHex is null) return;
        // Write through the TextBox rather than the model directly:
        // Profile doesn't implement INotifyPropertyChanged on its
        // leaf string fields, so a direct model assignment doesn't
        // re-paint the editor's bound controls. The TextBox's two-way
        // binding (UpdateSourceTrigger=PropertyChanged) forwards the
        // value into the model + the swatch button's binding
        // converter re-runs on the same property change. Both halves
        // of the UI stay in sync without manual BindingExpression
        // refreshes.
        var target = fieldTag == "bg" ? BgHexBox : FgHexBox;
        if (target is not null)
        {
            target.Text = picker.PickedHex;
        }
    }
}
