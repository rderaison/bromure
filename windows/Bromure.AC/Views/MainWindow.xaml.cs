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

    protected override async void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        if (DataContext is ShellViewModel vm && vm.Session is not null)
        {
            await vm.Session.DisposeAsync();
        }
    }
}
