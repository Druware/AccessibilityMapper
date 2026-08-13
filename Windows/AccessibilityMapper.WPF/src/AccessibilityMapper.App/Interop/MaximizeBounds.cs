using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace AccessibilityMapper.App.Interop;

/// <summary>
/// Keeps a maximized frameless window inside the monitor's work area.
/// </summary>
/// <remarks>
/// A window with <see cref="WindowStyle.None"/> maximizes to the whole monitor rather than to
/// the work area, so it covers the taskbar. Windows asks for the maximized geometry through
/// WM_GETMINMAXINFO, which is the one chance to correct it.
/// </remarks>
internal static class MaximizeBounds
{
    private const int WmGetMinMaxInfo = 0x0024;
    private const int MonitorDefaultToNearest = 0x00000002;

    /// <summary>
    /// Constrains <paramref name="window"/> to the work area of whichever monitor it is
    /// maximized onto, now or once it has an HWND.
    /// </summary>
    public static void ConstrainToWorkArea(Window window)
    {
        if (PresentationSource.FromVisual(window) is HwndSource existing)
            existing.AddHook(OnWindowMessage);
        else
            window.SourceInitialized += (sender, _) =>
                ((HwndSource)PresentationSource.FromVisual((Window)sender!)).AddHook(OnWindowMessage);
    }

    private static IntPtr OnWindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != WmGetMinMaxInfo)
            return IntPtr.Zero;

        var monitor = MonitorFromWindow(hwnd, MonitorDefaultToNearest);
        if (monitor == IntPtr.Zero)
            return IntPtr.Zero;

        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(monitor, ref info))
            return IntPtr.Zero;

        var minMax = Marshal.PtrToStructure<MinMaxInfo>(lParam);

        // ptMaxPosition is relative to the monitor, not to the virtual desktop.
        minMax.MaxPosition = new Point
        {
            X = info.WorkArea.Left - info.Monitor.Left,
            Y = info.WorkArea.Top - info.Monitor.Top,
        };
        minMax.MaxSize = new Point
        {
            X = info.WorkArea.Right - info.WorkArea.Left,
            Y = info.WorkArea.Bottom - info.WorkArea.Top,
        };

        Marshal.StructureToPtr(minMax, lParam, true);

        // DefWindowProc would put its own defaults back, so this message stops here. WPF's own
        // handler runs ahead of this hook, so the min/max track sizes it derives from
        // MinWidth and MinHeight are already in the struct and are left untouched.
        handled = true;
        return IntPtr.Zero;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MinMaxInfo
    {
        public Point Reserved;
        public Point MaxSize;
        public Point MaxPosition;
        public Point MinTrackSize;
        public Point MaxTrackSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public Rect Monitor;
        public Rect WorkArea;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, int flags);

    [DllImport("user32.dll")]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
}
