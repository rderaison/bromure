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
}
