using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace AccessibilityMapper.App.Interop;

/// <summary>
/// Puts the Windows 11 Mica material behind a window, which is what gives a WinUI 3 app its
/// wallpaper-tinted title bar and side panes.
/// </summary>
/// <remarks>
/// DWM composes the material <em>behind</em> the window, so two things have to be true for it
/// to show: the frame has to be extended over the whole client area, and the window itself has
/// to leave those pixels unpainted. Both are done here; anything the XAML paints opaque —
/// the map surface, for instance — simply covers the material, which is the intended look.
/// </remarks>
internal static class WindowBackdrop
{
    /// <summary>DWMWA_SYSTEMBACKDROP_TYPE.</summary>
    private const int SystemBackdropTypeAttribute = 38;

    /// <summary>DWMSBT_MAINWINDOW — Mica.</summary>
    private const int MicaBackdrop = 2;

    /// <summary>DWMWA_SYSTEMBACKDROP_TYPE arrived in Windows 11 22H2.</summary>
    private const int MinimumBuild = 22621;

    /// <summary>
    /// False on Windows 10 and pre-22H2 Windows 11, where the window has to keep its opaque
    /// Fluent background: the backdrop call is a no-op there, so a transparent client area
    /// would render black rather than fall back gracefully.
    /// </summary>
    public static bool IsSupported { get; } = Environment.OSVersion.Version.Build >= MinimumBuild;

    /// <summary>
    /// Applies Mica to <paramref name="window"/>, now if it already has an HWND, otherwise as
    /// soon as it gets one. Does nothing where Mica is unavailable.
    /// </summary>
    public static void Apply(Window window)
    {
        if (!IsSupported)
            return;

        window.Background = Brushes.Transparent;

        var handle = new WindowInteropHelper(window).Handle;
        if (handle != IntPtr.Zero)
            ApplyTo(handle);
        else
            window.SourceInitialized += (sender, _) => ApplyTo(new WindowInteropHelper((Window)sender!).Handle);
    }

    private static void ApplyTo(IntPtr handle)
    {
        if (handle == IntPtr.Zero)
            return;

        // -1 on every edge is the documented "sheet of glass" margin: the frame covers the
        // entire client area, so the material is not confined to the caption strip.
        var margins = new Margins { LeftWidth = -1, RightWidth = -1, TopHeight = -1, BottomHeight = -1 };
        DwmExtendFrameIntoClientArea(handle, ref margins);

        var backdrop = MicaBackdrop;
        DwmSetWindowAttribute(handle, SystemBackdropTypeAttribute, ref backdrop, sizeof(int));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Margins
    {
        public int LeftWidth;
        public int RightWidth;
        public int TopHeight;
        public int BottomHeight;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
