using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using AccessibilityMapper.App.ViewModels;

namespace AccessibilityMapper.App.Views;

/// <summary>
/// Hosts the MapLibre GL map (Assets/Map/map.html) in a WebView2 control and bridges it to
/// <see cref="MainViewModel"/>. This is the ONLY place that knows the JS bridge's wire
/// JSON shapes — see docs/MAP-BRIDGE.md for the contract.
/// </summary>
public partial class MapControl : UserControl
{
    private MainViewModel? _viewModel;
    private bool _webViewReady;
    private string _mapFolder = "";

    public MapControl()
    {
        InitializeComponent();
        Loaded += MapControl_Loaded;
        DataContextChanged += MapControl_DataContextChanged;
    }

    private async void MapControl_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            // WebView2 defaults its user-data folder to the executable's directory,
            // which is read-only under an MSIX install. Point it at LocalAppData —
            // per-package-redirected when running packaged, a plain per-user folder
            // otherwise — so the same build works installed or unpacked.
            var userDataFolder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "AccessibilityMapper",
                "WebView2");

            var environment = await CoreWebView2Environment.CreateAsync(null, userDataFolder);
            await Browser.EnsureCoreWebView2Async(environment);
        }
        catch (Exception ex)
        {
            // A Loaded handler is async void: an escaping exception would tear down the
            // process. Report it and leave an empty map surface instead.
            MessageBox.Show(
                Window.GetWindow(this),
                $"The map could not be initialised.\n\n{ex.Message}",
                "Map unavailable",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            return;
        }

        _mapFolder = Path.Combine(AppContext.BaseDirectory, "Assets", "Map");
        Browser.CoreWebView2.SetVirtualHostNameToFolderMapping(
            "appassets", _mapFolder, CoreWebView2HostResourceAccessKind.Allow);

        // MapLibre GL 6 ships ESM only, and the virtual host serves files with the MIME
        // type Windows has registered for the extension. HKCR\.mjs is commonly "text/plain"
        // (it is on at least one dev machine here), and Chromium *strictly* refuses to
        // execute a module script that is not served as JavaScript — the map silently never
        // starts. Serve .mjs ourselves with the correct type rather than depend on whatever
        // is in a given user's registry.
        Browser.CoreWebView2.AddWebResourceRequestedFilter(
            "https://appassets/*", CoreWebView2WebResourceContext.All);
        Browser.CoreWebView2.WebResourceRequested += CoreWebView2_WebResourceRequested;

        Browser.CoreWebView2.WebMessageReceived += CoreWebView2_WebMessageReceived;

        Browser.CoreWebView2.Navigate("https://appassets/map.html");
    }

    private void CoreWebView2_WebResourceRequested(
        object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        if (Browser.CoreWebView2 is null)
            return;

        if (!Uri.TryCreate(e.Request.Uri, UriKind.Absolute, out var uri) ||
            !uri.AbsolutePath.EndsWith(".mjs", StringComparison.OrdinalIgnoreCase))
        {
            return; // everything else keeps the virtual host's own handling
        }

        // Resolve inside the map folder only; a traversal would otherwise be able to read
        // any .mjs on disk through the bridge.
        var candidate = Path.GetFullPath(Path.Combine(_mapFolder, uri.AbsolutePath.TrimStart('/')));
        var root = Path.GetFullPath(_mapFolder) + Path.DirectorySeparatorChar;
        if (!candidate.StartsWith(root, StringComparison.OrdinalIgnoreCase) || !File.Exists(candidate))
            return;

        // Buffered rather than a FileStream: WebView2 reads the response asynchronously and
        // these are ~0.5 MB, so this avoids holding a file handle open across that.
        var content = new MemoryStream(File.ReadAllBytes(candidate));
        e.Response = Browser.CoreWebView2.Environment.CreateWebResourceResponse(
            content, 200, "OK", "Content-Type: text/javascript");
    }

    private void MapControl_DataContextChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (_viewModel is not null)
            _viewModel.MapMessageOut -= ViewModel_MapMessageOut;

        _viewModel = e.NewValue as MainViewModel;

        if (_viewModel is not null)
            _viewModel.MapMessageOut += ViewModel_MapMessageOut;
    }

    // ---- Outbound: VM -> JS -------------------------------------------------

    private void ViewModel_MapMessageOut(MapMessage message)
    {
        if (!_webViewReady || Browser.CoreWebView2 is null)
            return;

        Browser.CoreWebView2.PostWebMessageAsJson(BuildWireJson(message));
    }

    private static string BuildWireJson(MapMessage m)
    {
        object payload = m.Type switch
        {
            "init" => new
            {
                type = "init",
                markers = m.Markers?.Select(ToMarkerWire).ToArray() ?? [],
                selectedId = m.SelectedId?.ToString(),
                zones = ToZonesWire(m.Zones),
                boundaries = m.Boundaries?.Select(ToBoundaryWire).ToArray() ?? [],
                mapType = m.MapType ?? 0,
                view = new
                {
                    center = m.View?.Center ?? [37.3318, -122.0312],
                    span = m.View?.Span ?? [0.15, 0.15],
                    fitMarkers = m.View?.FitMarkers ?? false
                }
            },
            "setMarkers" => new
            {
                type = "setMarkers",
                markers = m.Markers?.Select(ToMarkerWire).ToArray() ?? [],
                selectedId = m.SelectedId?.ToString()
            },
            "setSelected" => new { type = "setSelected", id = m.SelectedId?.ToString() },
            "setZones" => new
            {
                type = "setZones",
                walk = m.Zones?.Walk ?? true,
                safeRoutes = m.Zones?.SafeRoutes ?? true,
                bike = m.Zones?.Bike ?? true,
                lsv = m.Zones?.Lsv ?? true
            },
            "setMode" => new { type = "setMode", placing = m.Placing ?? false },
            "setBoundaries" => new
            {
                type = "setBoundaries",
                boundaries = m.Boundaries?.Select(ToBoundaryWire).ToArray() ?? []
            },
            "setMapType" => new { type = "setMapType", mapType = m.MapType ?? 0 },
            "flyTo" => new { type = "flyTo", lat = m.Lat ?? 0, lon = m.Lon ?? 0, tight = m.Tight ?? false },
            _ => new { type = m.Type }
        };

        return JsonSerializer.Serialize(payload);
    }

    private static object ToMarkerWire(MarkerDto m) => new
    {
        id = m.Id.ToString(),
        lat = m.Lat,
        lon = m.Lon,
        label = m.Label
    };

    private static object ToBoundaryWire(BoundaryDto b) => new
    {
        id = b.Id.ToString(),
        name = b.Name,
        rings = b.Rings
    };

    private static object ToZonesWire(ZonesDto? z) => new
    {
        walk = z?.Walk ?? true,
        safeRoutes = z?.SafeRoutes ?? true,
        bike = z?.Bike ?? true,
        lsv = z?.Lsv ?? true
    };

    // ---- Inbound: JS -> VM -------------------------------------------------

    private void CoreWebView2_WebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (_viewModel is null)
            return;

        using var doc = JsonDocument.Parse(e.WebMessageAsJson);
        var root = doc.RootElement;
        if (!root.TryGetProperty("type", out var typeEl))
            return;

        switch (typeEl.GetString())
        {
            case "ready":
                _webViewReady = true;
                _viewModel.SendInit();
                break;

            case "addMarker":
                _viewModel.AddMarkerAt(root.GetProperty("lat").GetDouble(), root.GetProperty("lon").GetDouble());
                break;

            case "selectMarker":
                if (Guid.TryParse(root.GetProperty("id").GetString(), out var selId))
                    _viewModel.SelectedMarkerId = selId;
                break;

            case "deselect":
                _viewModel.SelectedMarkerId = null;
                break;

            case "removeMarker":
                if (Guid.TryParse(root.GetProperty("id").GetString(), out var remId))
                    _viewModel.DeleteMarkerCommand.Execute(remId);
                break;

            case "viewportChanged":
                _viewModel.UpdateViewport(
                    root.GetProperty("centerLat").GetDouble(),
                    root.GetProperty("centerLon").GetDouble(),
                    root.GetProperty("spanLatDelta").GetDouble(),
                    root.GetProperty("spanLonDelta").GetDouble());
                break;
        }
    }
}
