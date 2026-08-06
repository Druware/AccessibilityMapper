using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using AccessibilityMapper.App.Models;
using AccessibilityMapper.App.ViewModels;

namespace AccessibilityMapper.App.Views;

/// <summary>
/// The left sidebar (CONVERSION-SPEC.md §5): tool mode, radius legend, boundary search,
/// marker list, and mode status. Most bindings are declarative (see ToolboxView.xaml);
/// this code-behind only handles the handful of interactions that need a tuple command
/// parameter or imperative row lookup that XAML alone can't express.
/// </summary>
public partial class ToolboxView : UserControl
{
    public ToolboxView()
    {
        InitializeComponent();

        BoundaryTypeCombo.ItemsSource = Enum.GetValues<BoundaryType>();
        BoundaryTypeCombo.SelectedIndex = 0;
    }

    private MainViewModel? ViewModel => DataContext as MainViewModel;

    // ---- Boundary search ----------------------------------------------------

    private async void BoundarySearchButton_Click(object sender, RoutedEventArgs e) => await SubmitBoundarySearchAsync();

    private async void BoundarySearchBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter)
            return;

        await SubmitBoundarySearchAsync();
    }

    private async Task SubmitBoundarySearchAsync()
    {
        var vm = ViewModel;
        if (vm is null)
            return;

        var query = BoundarySearchBox.Text.Trim();
        if (string.IsNullOrEmpty(query) || vm.IsFetchingBoundary)
            return;

        var type = BoundaryTypeCombo.SelectedItem is BoundaryType t ? t : BoundaryType.City;
        var args = (Query: query, Type: type);

        if (!vm.SearchBoundaryCommand.CanExecute(args))
            return;

        await vm.SearchBoundaryCommand.ExecuteAsync(args);

        if (string.IsNullOrEmpty(vm.ErrorMessage))
            BoundarySearchBox.Clear();
    }

    // ---- Marker rename (commit on LostFocus / Enter, not live per-keystroke) ------

    private void MarkerLabelBox_LostFocus(object sender, RoutedEventArgs e) => CommitMarkerLabel(sender);

    private void MarkerLabelBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter)
            return;

        CommitMarkerLabel(sender);
        Keyboard.ClearFocus();
    }

    private void CommitMarkerLabel(object sender)
    {
        if (ViewModel is not { } vm)
            return;

        if (sender is not TextBox { DataContext: BullseyeMarker marker } textBox)
            return;

        vm.RenameMarkerCommand.Execute((marker.Id, textBox.Text));
    }

    // ---- Marker row double-click -> center map on marker -------------------

    private void MarkersList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (ViewModel is not { } vm)
            return;

        var container = FindAncestor<ListBoxItem>(e.OriginalSource as DependencyObject);
        if (container?.DataContext is not BullseyeMarker marker)
            return;

        vm.CenterOnMarkerCommand.Execute(marker.Id);
    }

    private static T? FindAncestor<T>(DependencyObject? node) where T : DependencyObject
    {
        while (node is not null and not T)
            node = VisualTreeHelper.GetParent(node);

        return node as T;
    }
}
