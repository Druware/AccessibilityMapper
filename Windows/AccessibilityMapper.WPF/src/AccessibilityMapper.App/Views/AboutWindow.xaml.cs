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
    /// Reads the shipped assembly metadata rather than carrying a literal, which drifts.
    /// Shows "Version 1.0.4 (46)" like the macOS About screen: the version is &lt;Version&gt;
    /// (the informational version without the SDK's "+commit" suffix) and the build is the
    /// FileVersion revision, which the csproj sets from &lt;BuildNumber&gt;.
    /// </summary>
    private static string BuildVersionText()
    {
        var assembly = Assembly.GetExecutingAssembly();
        return FormatVersionText(
            assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion,
            assembly.GetCustomAttribute<AssemblyFileVersionAttribute>()?.Version);
    }

    internal static string FormatVersionText(string? informationalVersion, string? fileVersion)
    {
        var version = informationalVersion?.Split('+')[0];
        if (string.IsNullOrEmpty(version))
            return "Version 1.0";

        return Version.TryParse(fileVersion, out var file) && file.Revision >= 0
            ? $"Version {version} ({file.Revision})"
            : $"Version {version}";
    }

    private void Hyperlink_RequestNavigate(object sender, RequestNavigateEventArgs e)
    {
        Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        e.Handled = true;
    }
}
