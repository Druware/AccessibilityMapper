using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using AccessibilityMapper.App.ViewModels;
using AccessibilityMapper.App.Views;

namespace AccessibilityMapper.App;

/// <summary>
/// Interaction logic for MainWindow.xaml
/// </summary>
public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;

    public MainWindow()
    {
        InitializeComponent();

        _viewModel = new MainViewModel();
        DataContext = _viewModel;
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
    }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(MainViewModel.ErrorMessage))
            return;

        var message = _viewModel.ErrorMessage;
        if (string.IsNullOrEmpty(message))
            return;

        MessageBox.Show(this, message, "Error", MessageBoxButton.OK, MessageBoxImage.Error);
        _viewModel.ErrorMessage = null;
    }

    private void MainWindow_Loaded(object sender, RoutedEventArgs e) => ZipTextBox.Focus();

    private void ZipTextBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter)
            return;

        if (_viewModel.GeocodeCommand.CanExecute(null))
            _viewModel.GeocodeCommand.Execute(null);
    }

    private void ExitMenuItem_Click(object sender, RoutedEventArgs e) => Application.Current.Shutdown();

    private void AboutMenuItem_Click(object sender, RoutedEventArgs e)
    {
        var about = new AboutWindow { Owner = this };
        about.ShowDialog();
    }
}
