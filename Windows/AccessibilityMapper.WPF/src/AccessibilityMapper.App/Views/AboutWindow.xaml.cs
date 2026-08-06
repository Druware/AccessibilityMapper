using System.Diagnostics;
using System.Windows;
using System.Windows.Navigation;

namespace AccessibilityMapper.App.Views;

/// <summary>
/// About dialog, CONVERSION-SPEC.md §9.3. Content-sized, non-resizable, centered on its
/// owner.
/// </summary>
public partial class AboutWindow : Window
{
    public AboutWindow()
    {
        InitializeComponent();
    }

    private void Hyperlink_RequestNavigate(object sender, RequestNavigateEventArgs e)
    {
        Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        e.Handled = true;
    }
}
