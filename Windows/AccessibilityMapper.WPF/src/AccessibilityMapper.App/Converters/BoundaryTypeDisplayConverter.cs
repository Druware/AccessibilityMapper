using System.Globalization;
using System.Windows.Data;
using AccessibilityMapper.App.Models;

namespace AccessibilityMapper.App.Converters;

/// <summary>BoundaryType -> its UI display name ("City" / "County/Parish" / "State"),
/// per CONVERSION-SPEC.md §1.4.</summary>
public sealed class BoundaryTypeDisplayConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is BoundaryType t ? t.DisplayName() : string.Empty;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
