using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using AccessibilityMapper.App.Models;
using AccessibilityMapper.App.Services;
using AccessibilityMapper.App.Views;

namespace AccessibilityMapper.App.ViewModels;

/// <summary>
/// Owns all application state: the current document, the map's live view state, and the
/// bridge to the map surface via <see cref="MapMessageOut"/>. Deliberately has no
/// WebView2/JSON-bridge-wire-format knowledge — that translation happens in
/// Views/MapControl.xaml.cs.
/// </summary>
public partial class MainViewModel : ObservableObject
{
    private readonly DocumentService _documentService = new();
    private readonly GeocodingService _geocodingService = new();
    private readonly BoundaryService _boundaryService = new();

    private bool _suppressSync;

    /// <summary>Raised whenever the map surface needs to be updated. The view (MapControl)
    /// subscribes and translates each message into the JS bridge wire format.</summary>
    public event Action<MapMessage>? MapMessageOut;

    [ObservableProperty]
    private MapDocument document = new();

    [ObservableProperty]
    private string? currentFilePath;

    [ObservableProperty]
    private bool isDirty;

    public ObservableCollection<BullseyeMarker> Markers { get; } = new();

    public ObservableCollection<BoundaryRecord> Boundaries { get; } = new();

    [ObservableProperty]
    private Guid? selectedMarkerId;

    [ObservableProperty]
    private bool isPlacingBullseye;

    [ObservableProperty]
    private bool showWalk = true;

    [ObservableProperty]
    private bool showSafeRoutes = true;

    [ObservableProperty]
    private bool showBike = true;

    [ObservableProperty]
    private bool showLsv = true;

    [ObservableProperty]
    private string? errorMessage;

    [ObservableProperty]
    private bool isFetchingBoundary;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Title))]
    [NotifyCanExecuteChangedFor(nameof(GeocodeCommand))]
    private string zipCode = "";

    [ObservableProperty]
    private int mapTypeRaw;

    /// <summary>Window title per CONVERSION-SPEC.md §8 (em dash, not hyphen).</summary>
    public string Title => string.IsNullOrEmpty(ZipCode)
        ? "Accessibility Mapper"
        : $"Accessibility Mapper — {ZipCode}";

    public MainViewModel()
    {
        LoadFromDocument();
    }

    // ---- Document lifecycle -------------------------------------------------

    partial void OnDocumentChanged(MapDocument value) => LoadFromDocument();

    private void LoadFromDocument()
    {
        _suppressSync = true;
        try
        {
            Markers.Clear();
            foreach (var marker in Document.Markers)
                Markers.Add(marker);

            Boundaries.Clear();
            foreach (var boundary in Document.Boundaries)
                Boundaries.Add(boundary);

            ZipCode = Document.ZipCode;
            MapTypeRaw = Document.MapTypeRaw;
            SelectedMarkerId = null;
            IsPlacingBullseye = false;
        }
        finally
        {
            _suppressSync = false;
        }

        IsDirty = false;
        ErrorMessage = null;
        SendInit();
    }

    /// <summary>Builds and raises the full-state "init" message. Called by MapControl when
    /// the JS side reports "ready", and again here whenever the document is replaced
    /// (New/Open) so an already-initialized map fully resets.</summary>
    public void SendInit()
    {
        MapMessageOut?.Invoke(new MapMessage
        {
            Type = "init",
            Markers = Markers.Select(ToMarkerDto).ToList(),
            SelectedId = SelectedMarkerId,
            Zones = new ZonesDto(ShowWalk, ShowSafeRoutes, ShowBike, ShowLsv),
            Boundaries = Boundaries.Select(ToBoundaryDto).ToList(),
            MapType = MapTypeRaw,
            View = BuildViewDto()
        });
    }

    private ViewDto BuildViewDto()
    {
        var fit = Document.FitRegion();
        if (fit is { } f)
            return new ViewDto([f.CenterLat, f.CenterLon], [f.SpanLat, f.SpanLon], true);

        return new ViewDto(
            [Document.CenterLatitude, Document.CenterLongitude],
            [Document.SpanLatDelta, Document.SpanLonDelta],
            false);
    }

    // ---- File commands --------------------------------------------------------

    [RelayCommand]
    private void NewDocument()
    {
        Document = new MapDocument();
        CurrentFilePath = null;
    }

    [RelayCommand]
    private void Open()
    {
        var dialog = new OpenFileDialog { Filter = DocumentService.DialogFilter };
        if (dialog.ShowDialog() != true)
            return;

        try
        {
            Document = _documentService.Load(dialog.FileName);
            CurrentFilePath = dialog.FileName;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Could not open \"{dialog.FileName}\": {ex.Message}";
        }
    }

    [RelayCommand]
    private void Save()
    {
        if (string.IsNullOrEmpty(CurrentFilePath))
        {
            SaveAs();
            return;
        }

        try
        {
            _documentService.Save(Document, CurrentFilePath);
            IsDirty = false;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Could not save: {ex.Message}";
        }
    }

    [RelayCommand]
    private void SaveAs()
    {
        var suggestedName = string.IsNullOrEmpty(Document.ZipCode) ? "Untitled" : Document.ZipCode;
        var dialog = new SaveFileDialog
        {
            Filter = DocumentService.DialogFilter,
            FileName = $"{suggestedName}.accmap"
        };
        if (dialog.ShowDialog() != true)
            return;

        try
        {
            _documentService.Save(Document, dialog.FileName);
            CurrentFilePath = dialog.FileName;
            IsDirty = false;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Could not save: {ex.Message}";
        }
    }

    // ---- Geocoding --------------------------------------------------------

    private bool CanGeocode() => !string.IsNullOrWhiteSpace(ZipCode);

    [RelayCommand(CanExecute = nameof(CanGeocode))]
    private async Task Geocode()
    {
        var query = ZipCode.Trim();
        if (string.IsNullOrEmpty(query))
            return;

        ErrorMessage = null;
        try
        {
            var result = await _geocodingService.GeocodeAsync(query);
            if (result is null)
            {
                ErrorMessage = $"No location found for \"{query}\"";
                return;
            }

            Document.CenterLatitude = result.Value.Latitude;
            Document.CenterLongitude = result.Value.Longitude;
            IsDirty = true;
            MapMessageOut?.Invoke(new MapMessage
            {
                Type = "flyTo",
                Lat = result.Value.Latitude,
                Lon = result.Value.Longitude,
                Tight = false
            });
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Could not find \"{query}\": {ex.Message}";
        }
    }

    // ---- Boundaries --------------------------------------------------------

    [RelayCommand]
    private async Task SearchBoundary((string Query, BoundaryType Type) args)
    {
        var query = args.Query.Trim();
        if (string.IsNullOrEmpty(query) || IsFetchingBoundary)
            return;

        IsFetchingBoundary = true;
        ErrorMessage = null;
        try
        {
            var candidates = await _boundaryService.FindCandidatesAsync(query, args.Type);
            if (candidates.Count == 0)
            {
                ErrorMessage = $"No boundary found for \"{query}\"";
                return;
            }

            // One match goes straight in; several ask rather than guessing (issues.md §4).
            var chosen = candidates.Count == 1
                ? candidates[0]
                : BoundaryPickerWindow.Choose(candidates, query);

            if (chosen is null)
                return; // cancelled: the user backed out, which is not an error

            var record = await _boundaryService.LoadAsync(chosen);

            Boundaries.Add(record);
            Document.Boundaries.Add(record);
            IsDirty = true;
            MapMessageOut?.Invoke(new MapMessage
            {
                Type = "setBoundaries",
                Boundaries = Boundaries.Select(ToBoundaryDto).ToList()
            });
        }
        catch (NoPolygonBoundaryException)
        {
            ErrorMessage = $"No polygon boundary returned for \"{query}\"";
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Boundary search failed: {ex.Message}";
        }
        finally
        {
            IsFetchingBoundary = false;
        }
    }

    [RelayCommand]
    private void RemoveBoundary(Guid id)
    {
        var boundary = Boundaries.FirstOrDefault(b => b.Id == id);
        if (boundary is null)
            return;

        Boundaries.Remove(boundary);
        Document.Boundaries.RemoveAll(b => b.Id == id);
        IsDirty = true;
        MapMessageOut?.Invoke(new MapMessage
        {
            Type = "setBoundaries",
            Boundaries = Boundaries.Select(ToBoundaryDto).ToList()
        });
    }

    // ---- Markers --------------------------------------------------------

    public void AddMarkerAt(double lat, double lon)
    {
        var marker = new BullseyeMarker { Latitude = lat, Longitude = lon, Label = "" };
        Markers.Add(marker);
        Document.Markers.Add(marker);
        IsDirty = true;
        PushMarkers();
    }

    [RelayCommand]
    private void DeleteMarker(Guid id)
    {
        var marker = Markers.FirstOrDefault(m => m.Id == id);
        if (marker is null)
            return;

        Markers.Remove(marker);
        Document.Markers.RemoveAll(m => m.Id == id);
        if (SelectedMarkerId == id)
            SelectedMarkerId = null;

        IsDirty = true;
        PushMarkers();
    }

    [RelayCommand]
    private void RenameMarker((Guid Id, string Label) args)
    {
        var marker = Markers.FirstOrDefault(m => m.Id == args.Id);
        if (marker is null)
            return;

        marker.Label = args.Label;
        IsDirty = true;
        PushMarkers();
    }

    [RelayCommand]
    private void CenterOnMarker(Guid id)
    {
        var marker = Markers.FirstOrDefault(m => m.Id == id);
        if (marker is null)
            return;

        SelectedMarkerId = id;
        MapMessageOut?.Invoke(new MapMessage
        {
            Type = "flyTo",
            Lat = marker.Latitude,
            Lon = marker.Longitude,
            Tight = true
        });
    }

    [RelayCommand]
    private void ToggleMode(bool placing) => IsPlacingBullseye = placing;

    /// <summary>Called by MapControl when Leaflet reports a pan/zoom-end viewport, so the
    /// document's persisted center/span stay current (CONVERSION-SPEC.md §8).</summary>
    public void UpdateViewport(double centerLat, double centerLon, double spanLat, double spanLon)
    {
        Document.CenterLatitude = centerLat;
        Document.CenterLongitude = centerLon;
        Document.SpanLatDelta = spanLat;
        Document.SpanLonDelta = spanLon;
        IsDirty = true;
    }

    private void PushMarkers()
    {
        MapMessageOut?.Invoke(new MapMessage
        {
            Type = "setMarkers",
            Markers = Markers.Select(ToMarkerDto).ToList(),
            SelectedId = SelectedMarkerId
        });
    }

    // ---- Property-change side effects -> map bridge -----------------------

    partial void OnSelectedMarkerIdChanged(Guid? value)
    {
        if (_suppressSync) return;
        MapMessageOut?.Invoke(new MapMessage { Type = "setSelected", SelectedId = value });
    }

    partial void OnIsPlacingBullseyeChanged(bool value)
    {
        if (_suppressSync) return;
        MapMessageOut?.Invoke(new MapMessage { Type = "setMode", Placing = value });
    }

    partial void OnShowWalkChanged(bool value) => PushZones();
    partial void OnShowSafeRoutesChanged(bool value) => PushZones();
    partial void OnShowBikeChanged(bool value) => PushZones();
    partial void OnShowLsvChanged(bool value) => PushZones();

    private void PushZones()
    {
        if (_suppressSync) return;
        MapMessageOut?.Invoke(new MapMessage
        {
            Type = "setZones",
            Zones = new ZonesDto(ShowWalk, ShowSafeRoutes, ShowBike, ShowLsv)
        });
    }

    partial void OnZipCodeChanged(string value)
    {
        if (_suppressSync) return;
        Document.ZipCode = value;
        IsDirty = true;
    }

    partial void OnMapTypeRawChanged(int value)
    {
        Document.MapTypeRaw = value;
        if (_suppressSync) return;
        IsDirty = true;
        MapMessageOut?.Invoke(new MapMessage { Type = "setMapType", MapType = value });
    }

    // ---- DTO mapping --------------------------------------------------------

    private static MarkerDto ToMarkerDto(BullseyeMarker m) => new(m.Id, m.Latitude, m.Longitude, m.Label);

    private static BoundaryDto ToBoundaryDto(BoundaryRecord b) => new(b.Id, b.Name, b.PolygonRings);
}
