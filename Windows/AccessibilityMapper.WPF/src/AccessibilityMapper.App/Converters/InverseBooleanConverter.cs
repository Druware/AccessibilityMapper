using System.Globalization;
using System.Windows.Data;

namespace AccessibilityMapper.App.Converters;

/// <summary>Inverts a bool. Used to drive the "Select" tool row's IsChecked from the
/// inverse of MainViewModel.IsPlacingBullseye (the "Accessible Location" row binds
/// directly).</summary>
public sealed class InverseBooleanConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is bool b && !b;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is bool b && !b;
}
