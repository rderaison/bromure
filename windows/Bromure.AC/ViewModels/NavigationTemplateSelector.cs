using System.Windows;
using System.Windows.Controls;

namespace Bromure.AC.ViewModels;

/// <summary>
/// Picks the right pane view based on the sidebar selection. The
/// "Sessions" kind reuses the phase-based dispatch (Welcome /
/// Initializing / Session); the others map to their own panes.
/// </summary>
public sealed class NavigationTemplateSelector : DataTemplateSelector
{
    public DataTemplate? SessionsTemplate { get; set; }
    public DataTemplate? ProfilesTemplate { get; set; }
    public DataTemplate? TraceInspectorTemplate { get; set; }
    public DataTemplate? ApprovalsTemplate { get; set; }
    public DataTemplate? SettingsTemplate { get; set; }

    public override DataTemplate? SelectTemplate(object? item, DependencyObject container)
    {
        if (item is not ShellViewModel vm) return null;
        return vm.SelectedNavigation.Kind switch
        {
            NavigationKind.Sessions => SessionsTemplate,
            NavigationKind.Profiles => ProfilesTemplate,
            NavigationKind.TraceInspector => TraceInspectorTemplate,
            NavigationKind.Approvals => ApprovalsTemplate,
            NavigationKind.Settings => SettingsTemplate,
            _ => null,
        };
    }
}
