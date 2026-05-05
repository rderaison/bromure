using System.Windows;
using System.Windows.Controls;

namespace Bromure.AC.Common;

/// <summary>
/// Attached-property bridge that lets us two-way bind a string to
/// <see cref="PasswordBox.Password"/>. WPF's <c>PasswordBox</c>
/// intentionally doesn't expose Password as a DependencyProperty (the
/// idea being you shouldn't keep credentials in plaintext memory longer
/// than needed). For our editor this *is* the right model — the user is
/// editing a stored credential, the cleartext lives in the profile JSON
/// already — so we wire it explicitly via this attached property:
/// <code>
///   &lt;PasswordBox cmn:PasswordBoxBinding.Password="{Binding ApiKey, Mode=TwoWay}" /&gt;
/// </code>
/// </summary>
public static class PasswordBoxBinding
{
    public static readonly DependencyProperty PasswordProperty =
        DependencyProperty.RegisterAttached(
            "Password",
            typeof(string),
            typeof(PasswordBoxBinding),
            new FrameworkPropertyMetadata(string.Empty,
                FrameworkPropertyMetadataOptions.BindsTwoWayByDefault,
                OnPasswordChanged));

    private static readonly DependencyProperty IsAttachedProperty =
        DependencyProperty.RegisterAttached(
            "IsAttached", typeof(bool), typeof(PasswordBoxBinding),
            new PropertyMetadata(false));

    private static readonly DependencyProperty UpdatingFromVmProperty =
        DependencyProperty.RegisterAttached(
            "UpdatingFromVm", typeof(bool), typeof(PasswordBoxBinding),
            new PropertyMetadata(false));

    public static string GetPassword(DependencyObject d)
        => (string)d.GetValue(PasswordProperty);

    public static void SetPassword(DependencyObject d, string value)
        => d.SetValue(PasswordProperty, value);

    private static bool GetIsAttached(DependencyObject d) => (bool)d.GetValue(IsAttachedProperty);
    private static void SetIsAttached(DependencyObject d, bool value) => d.SetValue(IsAttachedProperty, value);
    private static bool GetUpdatingFromVm(DependencyObject d) => (bool)d.GetValue(UpdatingFromVmProperty);
    private static void SetUpdatingFromVm(DependencyObject d, bool value) => d.SetValue(UpdatingFromVmProperty, value);

    private static void OnPasswordChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not PasswordBox pb) return;

        // Hook the PasswordChanged event the first time we see this PB.
        if (!GetIsAttached(pb))
        {
            SetIsAttached(pb, true);
            pb.PasswordChanged += OnPasswordBoxChanged;
        }

        // Avoid recursion: only push the new value back if the change
        // came from the view-model (not from the user typing).
        var incoming = (string?)e.NewValue ?? "";
        if (pb.Password == incoming) return;

        SetUpdatingFromVm(pb, true);
        pb.Password = incoming;
        SetUpdatingFromVm(pb, false);
    }

    private static void OnPasswordBoxChanged(object sender, RoutedEventArgs e)
    {
        if (sender is not PasswordBox pb) return;
        if (GetUpdatingFromVm(pb)) return;
        SetPassword(pb, pb.Password);
    }
}
