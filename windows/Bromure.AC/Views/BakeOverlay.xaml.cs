using System.ComponentModel;
using System.Windows.Controls;

namespace Bromure.AC.Views;

public partial class BakeOverlay : UserControl
{
    public BakeOverlay()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is INotifyPropertyChanged n)
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
