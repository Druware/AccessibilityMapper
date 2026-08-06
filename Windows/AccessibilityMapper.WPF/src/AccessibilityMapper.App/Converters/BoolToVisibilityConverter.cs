using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace AccessibilityMapper.App.Converters;

/// <summary>bool -> Visibility (Visible/Collapsed). Pass ConverterParameter="Invert" to
/// flip the mapping (used e.g. to show the magnifier icon only while NOT fetching, next to
/// a spinner shown only while fetching).</summary>
public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var b = value is bool v && v;
        if (string.Equals(parameter as string, "Invert", StringComparison.OrdinalIgnoreCase))
            b = !b;
        return b ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
