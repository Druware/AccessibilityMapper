using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shell;
using AccessibilityMapper.App.Interop;
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

        WindowBackdrop.Apply(this);
        MaximizeBounds.ConstrainToWorkArea(this);
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

    private void AppIcon_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        var icon = (FrameworkElement)sender;

        // ShowSystemMenu wants device-independent screen coordinates, and PointToScreen
        // hands back physical pixels, so this has to divide the scale back out. Window.Left
        // and Top are not usable here: they report the restore position while maximized.
        var dpi = VisualTreeHelper.GetDpi(this);
        var corner = icon.PointToScreen(new Point(0, icon.ActualHeight));

        SystemCommands.ShowSystemMenu(this, new Point(corner.X / dpi.DpiScaleX, corner.Y / dpi.DpiScaleY));
        e.Handled = true;
    }

    // The title bar is drawn by the app, so its buttons have to do what the system frame
    // would otherwise have done.
    private void MinimizeButton_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    private void MaximizeRestoreButton_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private void ExitMenuItem_Click(object sender, RoutedEventArgs e) => Application.Current.Shutdown();

    private void AboutMenuItem_Click(object sender, RoutedEventArgs e)
    {
        var about = new AboutWindow { Owner = this };
        about.ShowDialog();
    }
}
