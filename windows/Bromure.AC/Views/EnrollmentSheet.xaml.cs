using System.Windows;
using Bromure.AC.ViewModels;

namespace Bromure.AC.Views;

public partial class EnrollmentSheet : Window
{
    public EnrollmentSheet(EnrollmentSheetViewModel vm)
    {
        InitializeComponent();
        DataContext = vm;
        vm.Done += (_, _) => Dispatcher.Invoke(() =>
        {
            DialogResult = vm.Result is not null;
            Close();
        });
    }
}
