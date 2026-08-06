namespace AccessibilityMapper.App.ViewModels;

/// <summary>
/// An outbound C#-to-JS bridge message. <see cref="Type"/> selects which of the other
/// (nullable) fields are meaningful — see docs/MAP-BRIDGE.md for the exact wire shapes
/// the map control (Views/MapControl.xaml.cs) produces from each variant.
/// </summary>
public class MapMessage
{
    public required string Type { get; init; }

    public IReadOnlyList<MarkerDto>? Markers { get; init; }
    public Guid? SelectedId { get; init; }

    public ZonesDto? Zones { get; init; }
    public bool? Placing { get; init; }
    public IReadOnlyList<BoundaryDto>? Boundaries { get; init; }
    public int? MapType { get; init; }
    public ViewDto? View { get; init; }

    public double? Lat { get; init; }
    public double? Lon { get; init; }
    public bool? Tight { get; init; }
}

public record MarkerDto(Guid Id, double Lat, double Lon, string Label);

public record BoundaryDto(Guid Id, string Name, IReadOnlyList<IReadOnlyList<double[]>> Rings);

public record ZonesDto(bool Walk, bool SafeRoutes, bool Bike, bool Lsv);

public record ViewDto(double[] Center, double[] Span, bool FitMarkers);
