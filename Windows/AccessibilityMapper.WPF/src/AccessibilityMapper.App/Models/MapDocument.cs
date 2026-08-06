using System.Text.Json.Serialization;

namespace AccessibilityMapper.App.Models;

/// <summary>
/// Root object of a `.accmap` document. Defaults mirror the Swift/MapKit source exactly
/// (Sunnyvale/Cupertino CA region) so older/partial files still load — see
/// docs/CONVERSION-SPEC.md §1.1.
/// </summary>
public class MapDocument
{
    [JsonPropertyName("zipCode")]
    public string ZipCode { get; set; } = "";

    [JsonPropertyName("centerLatitude")]
    public double CenterLatitude { get; set; } = 37.3318;

    [JsonPropertyName("centerLongitude")]
    public double CenterLongitude { get; set; } = -122.0312;

    [JsonPropertyName("spanLatDelta")]
    public double SpanLatDelta { get; set; } = 0.15;

    [JsonPropertyName("spanLonDelta")]
    public double SpanLonDelta { get; set; } = 0.15;

    [JsonPropertyName("mapTypeRaw")]
    public int MapTypeRaw { get; set; } = 0;

    [JsonPropertyName("markers")]
    public List<BullseyeMarker> Markers { get; set; } = new();

    [JsonPropertyName("boundaries")]
    public List<BoundaryRecord> Boundaries { get; set; } = new();

    /// <summary>
    /// Fit-to-markers region (center + span) with the outer ring and a 15% margin, or
    /// null when there are no markers — caller should fall back to the persisted
    /// center/span in that case. See CONVERSION-SPEC.md §1.1.
    /// </summary>
    public (double CenterLat, double CenterLon, double SpanLat, double SpanLon)? FitRegion()
    {
        if (Markers.Count == 0)
            return null;

        double minLat = Markers.Min(m => m.Latitude);
        double maxLat = Markers.Max(m => m.Latitude);
        double minLon = Markers.Min(m => m.Longitude);
        double maxLon = Markers.Max(m => m.Longitude);

        double centerLat = (minLat + maxLat) / 2.0;
        double centerLon = (minLon + maxLon) / 2.0;

        const double metersPerDegreeLat = 111320.0;
        double metersPerDegreeLon = 111320.0 * Math.Cos(centerLat * Math.PI / 180.0);

        double latPad = BullseyeMarker.Radii.Outer / metersPerDegreeLat;
        double lonPad = BullseyeMarker.Radii.Outer / metersPerDegreeLon;

        double spanLat = ((maxLat - minLat) + 2 * latPad) * 1.15;
        double spanLon = ((maxLon - minLon) + 2 * lonPad) * 1.15;

        return (centerLat, centerLon, spanLat, spanLon);
    }
}
