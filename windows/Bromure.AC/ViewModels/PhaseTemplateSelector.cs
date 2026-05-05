using System.Windows;
using System.Windows.Controls;

namespace Bromure.AC.ViewModels;

/// <summary>
/// Picks the right phase view template from <see cref="ShellViewModel.Phase"/>.
/// Mirrors the SwiftUI `switch phase { case .welcome: WelcomeView() … }`
/// pattern the macOS source uses in <c>BromureAC.swift</c>.
/// </summary>
public sealed class PhaseTemplateSelector : DataTemplateSelector
{
    public DataTemplate? WelcomeTemplate { get; set; }
    public DataTemplate? InitializingTemplate { get; set; }
    public DataTemplate? SessionTemplate { get; set; }

    public override DataTemplate? SelectTemplate(object? item, DependencyObject container)
    {
        if (item is not ShellViewModel vm) return null;
        return vm.Phase switch
        {
            ShellPhase.Welcome => WelcomeTemplate,
            ShellPhase.Initializing => InitializingTemplate,
            ShellPhase.Session => SessionTemplate,
            _ => null,
        };
    }
}
