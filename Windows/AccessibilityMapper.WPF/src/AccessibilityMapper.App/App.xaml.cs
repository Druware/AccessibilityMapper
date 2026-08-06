using System.Diagnostics;
using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace AccessibilityMapper.App;

/// <summary>
/// Interaction logic for App.xaml
/// </summary>
public partial class App : Application
{
    /// <summary>Evergreen WebView2 Runtime bootstrapper (stable Microsoft fwlink).</summary>
    private const string WebView2DownloadUrl = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";

    /// <summary>
    /// The map surface is a WebView2 control, so the Evergreen Runtime is a hard
    /// requirement. It ships with Windows 11 and arrives on Windows 10 with Edge, but
    /// it can be absent or removed. Detect that here and explain it, rather than
    /// letting <c>EnsureCoreWebView2Async</c> throw into an empty window — a launch
    /// crash is also an automatic Store certification failure.
    /// </summary>
    protected override void OnStartup(StartupEventArgs e)
    {
        if (!IsWebView2RuntimeAvailable())
        {
            // Suppress the StartupUri window so no main window is ever created.
            StartupUri = null;
            PromptToInstallWebView2Runtime();
            Shutdown(1);
            return;
        }

        base.OnStartup(e);
    }

    private static bool IsWebView2RuntimeAvailable()
    {
        try
        {
            return !string.IsNullOrEmpty(CoreWebView2Environment.GetAvailableBrowserVersionString());
        }
        catch (WebView2RuntimeNotFoundException)
        {
            return false;
        }
        catch (DllNotFoundException)
        {
            // WebView2Loader.dll missing from the deployment.
            return false;
        }
    }

    private static void PromptToInstallWebView2Runtime()
    {
        var result = MessageBox.Show(
            "Accessibility Mapper needs the Microsoft Edge WebView2 Runtime to display the map, "
            + "and it is not installed on this PC.\n\n"
            + "Would you like to open the download page now?",
            "WebView2 Runtime required",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (result != MessageBoxResult.Yes)
            return;

        try
        {
            Process.Start(new ProcessStartInfo(WebView2DownloadUrl) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                $"Could not open the download page: {ex.Message}\n\n{WebView2DownloadUrl}",
                "WebView2 Runtime required",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }
}
