using System.Windows.Controls;

namespace Bromure.AC.Views;

public partial class InitializingView : UserControl
{
    public InitializingView()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is System.ComponentModel.INotifyPropertyChanged n)
            {
                n.PropertyChanged += (_, args) =>
                {
                    if (args.PropertyName == "ConsoleLog")
                    {
                        Dispatcher.BeginInvoke(() => ConsoleScroll.ScrollToEnd());
                    }
                };
            }
        };
    }
}
