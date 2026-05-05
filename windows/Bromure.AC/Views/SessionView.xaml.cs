using System.ComponentModel;
using System.Windows.Controls;

namespace Bromure.AC.Views;

public partial class SessionView : UserControl
{
    public SessionView()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is INotifyPropertyChanged n)
            {
                n.PropertyChanged += (_, args) =>
                {
                    if (args.PropertyName == "SerialBuffer")
                    {
                        Dispatcher.BeginInvoke(() => SerialScroll.ScrollToEnd());
                    }
                };
            }
        };
    }
}
