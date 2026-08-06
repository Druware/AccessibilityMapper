using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace AccessibilityMapper.App.Views;

/// <summary>
/// Reusable "target/scope" vector glyph (ring + dot + crosshair) used for the "Accessible
/// Location" tool row and each marker row in the sidebar. See TargetGlyph.xaml.
/// </summary>
public partial class TargetGlyph : UserControl
{
    public static readonly DependencyProperty GlyphBrushProperty = DependencyProperty.Register(
        nameof(GlyphBrush), typeof(Brush), typeof(TargetGlyph),
        new PropertyMetadata(Brushes.Red));

    public Brush GlyphBrush
    {
        get => (Brush)GetValue(GlyphBrushProperty);
        set => SetValue(GlyphBrushProperty, value);
    }

    public TargetGlyph()
    {
        InitializeComponent();
    }
}
