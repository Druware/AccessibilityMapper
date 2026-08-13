using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Navigation;

namespace AccessibilityMapper.App.Views;

/// <summary>
/// About dialog. The identity and licensing blocks are CONVERSION-SPEC.md §9.3; the
/// attributions below them are specific to this build, because the Windows map stack shares
/// nothing with the Apple one. Content-sized, non-resizable, centered on its owner.
/// </summary>
public partial class AboutWindow : Window
{
    public AboutWindow()
    {
        InitializeComponent();

        VersionText.Text = BuildVersionText();

        // Show as much of the attribution list as the display allows before the ScrollViewer
        // has to take over — but stay inside the work area on a short screen, and stop well
        // short of full height on a tall one.
        MaxHeight = Math.Min(880, SystemParameters.WorkArea.Height - 80);
    }

    /// <summary>
    /// Reads the shipped assembly version rather than carrying a literal, which drifts. The
    /// revision field is dropped: it is always 0 here, and only the MSIX package needs it.
    /// </summary>
    private static string BuildVersionText()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version;

        return version is null
            ? "Version 1.0"
            : $"Version {version.Major}.{version.Minor}.{version.Build}";
    }

    private void Hyperlink_RequestNavigate(object sender, RequestNavigateEventArgs e)
    {
        Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        e.Handled = true;
    }
}
