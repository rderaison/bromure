using CommunityToolkit.Mvvm.ComponentModel;

namespace Bromure.AC.ViewModels;

/// <summary>
/// One row in the sidebar. The shell view-model swaps the right pane
/// based on which item is selected.
/// </summary>
public sealed partial class NavigationItem : ObservableObject
{
    [ObservableProperty] private string _label;
    [ObservableProperty] private string _glyph;
    [ObservableProperty] private NavigationKind _kind;
    [ObservableProperty] private bool _isSelected;

    public NavigationItem(string label, string glyph, NavigationKind kind, bool selected = false)
    {
        _label = label;
        _glyph = glyph;
        _kind = kind;
        _isSelected = selected;
    }
}

public enum NavigationKind
{
    Sessions,
    Profiles,
    // UX #6: Conversations removed — folded into TraceInspector.
    TraceInspector,
    Approvals,
    Settings,
}
