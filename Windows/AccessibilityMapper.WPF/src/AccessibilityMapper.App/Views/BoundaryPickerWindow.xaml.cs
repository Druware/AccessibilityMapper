using System.Windows;
using System.Windows.Input;
using AccessibilityMapper.App.Services;

namespace AccessibilityMapper.App.Views;

/// <summary>
/// Asks which place the user meant when a boundary search matches more than one
/// (issues.md §4). A search with a single match never opens this.
/// </summary>
public partial class BoundaryPickerWindow : Window
{
    private BoundaryMatch? _selected;

    private BoundaryPickerWindow(IReadOnlyList<BoundaryMatch> candidates, string query)
    {
        InitializeComponent();

        PromptText.Text = $"\"{query}\" matches {candidates.Count} places. Which did you mean?";
        CandidateList.ItemsSource = candidates;
        CandidateList.SelectedIndex = 0; // the ranked-best candidate
    }

    /// <summary>
    /// Shows the picker and returns the chosen candidate, or null if the user cancelled.
    /// </summary>
    public static BoundaryMatch? Choose(IReadOnlyList<BoundaryMatch> candidates, string query)
    {
        var window = new BoundaryPickerWindow(candidates, query);

        // Matches how the file dialogs are raised from the view model: the owner is
        // whatever window is currently running the app.
        var owner = Application.Current?.MainWindow;
        if (owner is not null && !ReferenceEquals(owner, window))
            window.Owner = owner;

        return window.ShowDialog() == true ? window._selected : null;
    }

    private void Accept_Click(object sender, RoutedEventArgs e) => Accept();

    private void CandidateList_MouseDoubleClick(object sender, MouseButtonEventArgs e) => Accept();

    private void Accept()
    {
        if (CandidateList.SelectedItem is not BoundaryMatch match)
            return;

        _selected = match;
        DialogResult = true;
    }
}
