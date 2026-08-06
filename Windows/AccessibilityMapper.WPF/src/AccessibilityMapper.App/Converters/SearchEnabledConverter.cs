using System.Globalization;
using System.Windows.Data;

namespace AccessibilityMapper.App.Converters;

/// <summary>MultiBinding[searchText, isFetching] -> bool. Used to enable the boundary
/// search button only when the query is non-blank and no fetch is already in flight
/// (CONVERSION-SPEC.md §5.4).</summary>
public sealed class SearchEnabledConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object? parameter, CultureInfo culture)
    {
        if (values.Length < 2)
            return false;

        var text = values[0] as string;
        var isFetching = values[1] is bool b && b;
        return !string.IsNullOrWhiteSpace(text) && !isFetching;
    }

    public object[] ConvertBack(object? value, Type[] targetTypes, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
