using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace AccessibilityMapper.App.Converters;

/// <summary>bool (row is selected, e.g. ListBoxItem.IsSelected) -> the marker glyph
/// brush: the theme accent color when selected, otherwise the fixed "Walk" red used for
/// marker glyphs throughout the map (CONVERSION-SPEC.md §5.5 / §3.1).</summary>
public sealed class MarkerGlyphBrushConverter : IValueConverter
{
    private static readonly Brush RedBrush = new SolidColorBrush(Color.FromRgb(0xFF, 0x3B, 0x30));

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is bool selected && selected)
            return Application.Current.TryFindResource("AccentFillColorDefaultBrush") as Brush ?? RedBrush;

        return RedBrush;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
