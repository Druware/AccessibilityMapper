using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace AccessibilityMapper.App.Converters;

/// <summary>Null/empty string -> Visible, otherwise Collapsed. Drives placeholder-text
/// overlays (e.g. "ZIP code", "Name...") that sit behind a TextBox and should only show
/// while it is empty.</summary>
public sealed class StringEmptyToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => string.IsNullOrEmpty(value as string) ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
