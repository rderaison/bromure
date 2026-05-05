using System.Windows.Input;

namespace Bromure.AC.Common;

/// <summary>
/// Tiny command wrapper for cases where CommunityToolkit's SimpleRelayCommand
/// generator isn't a fit (delegate captured at view-model construction
/// time, no fields needed). Used by the Profile editor list sections to
/// wire each row's Remove button without spamming generated commands.
/// </summary>
public sealed class SimpleRelayCommand<T> : ICommand
{
    private readonly Action<T> _execute;
    private readonly Predicate<T>? _canExecute;

    public SimpleRelayCommand(Action<T> execute, Predicate<T>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public bool CanExecute(object? parameter)
        => _canExecute?.Invoke((T)parameter!) ?? true;

    public void Execute(object? parameter) => _execute((T)parameter!);

    public event EventHandler? CanExecuteChanged
    {
        add { CommandManager.RequerySuggested += value; }
        remove { CommandManager.RequerySuggested -= value; }
    }
}
