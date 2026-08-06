using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace AccessibilityMapper.App.Converters;

/// <summary>int count -> Visibility. Zero maps to Collapsed by default (used to hide a
/// list once it has items); pass ConverterParameter="Invert" to flip (used to show the
/// matching empty-state text only when the count is zero).</summary>
public sealed class CountToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var isZero = value is int count && count == 0;
        var visibleWhenZero = string.Equals(parameter as string, "Invert", StringComparison.OrdinalIgnoreCase);
        var visible = visibleWhenZero ? isZero : !isZero;
        return visible ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
