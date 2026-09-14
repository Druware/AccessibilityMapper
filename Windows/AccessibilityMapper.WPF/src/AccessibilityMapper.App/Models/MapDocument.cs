using System.Text.Json.Serialization;

namespace AccessibilityMapper.App.Models;

/// <summary>
/// Root object of a `.accmap` document. Defaults mirror the Swift/MapKit source exactly
/// (Sunnyvale/Cupertino CA region) so older/partial files still load — see
/// docs/CONVERSION-SPEC.md §1.1.
/// </summary>
public class MapDocument
{
    /// <summary>Format version always written on save. A file without it is version 1;
    /// every version opens, so the value read is ignored.</summary>
    public const int CurrentFormatVersion = 2;

    [JsonPropertyName("formatVersion")]
    public int FormatVersion => CurrentFormatVersion;

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
    /// Fit-to-markers region (center + span) with a 15% margin, or null when there are no
    /// markers — caller should fall back to the persisted center/span in that case. Each
    /// marker contributes its coordinate ± its own pad: the outer ring for bullseyes, none
    /// for incidents. See CONVERSION-SPEC.md §1.1.
    /// </summary>
    public (double CenterLat, double CenterLon, double SpanLat, double SpanLon)? FitRegion()
    {
        if (Markers.Count == 0)
            return null;

        // Degree conversion uses the latitude midpoint of the coordinates themselves.
        double midLat = (Markers.Min(m => m.Latitude) + Markers.Max(m => m.Latitude)) / 2.0;

        const double metersPerDegreeLat = 111320.0;
        double metersPerDegreeLon = 111320.0 * Math.Cos(midLat * Math.PI / 180.0);

        double latPad = BullseyeMarker.Radii.Outer / metersPerDegreeLat;
        double lonPad = BullseyeMarker.Radii.Outer / metersPerDegreeLon;

        double LatPad(BullseyeMarker m) => m.Kind == MarkerKind.Bullseye ? latPad : 0;
        double LonPad(BullseyeMarker m) => m.Kind == MarkerKind.Bullseye ? lonPad : 0;

        double minLat = Markers.Min(m => m.Latitude - LatPad(m));
        double maxLat = Markers.Max(m => m.Latitude + LatPad(m));
        double minLon = Markers.Min(m => m.Longitude - LonPad(m));
        double maxLon = Markers.Max(m => m.Longitude + LonPad(m));

        double centerLat = (minLat + maxLat) / 2.0;
        double centerLon = (minLon + maxLon) / 2.0;

        // Incidents are unpadded, so incidents at one point would otherwise fit to span 0.
        const double minSpan = 0.02;
        double spanLat = Math.Max((maxLat - minLat) * 1.15, minSpan);
        double spanLon = Math.Max((maxLon - minLon) * 1.15, minSpan);

        return (centerLat, centerLon, spanLat, spanLon);
    }

    /// <summary>
    /// Appends <paramref name="other"/>'s markers and boundaries after this document's own,
    /// in file order. A marker is skipped when its id is already present; a boundary when its
    /// id is, or when a boundary with the same Name (ordinal) and Type is. Items appended
    /// earlier in the same merge count as present. Zip code, view and map type are untouched.
    /// </summary>
    public (int MarkersAdded, int BoundariesAdded, int Skipped) Merge(MapDocument other)
    {
        int markersAdded = 0, boundariesAdded = 0, skipped = 0;

        var markerIds = Markers.Select(m => m.Id).ToHashSet();
        foreach (var marker in other.Markers.ToList())
        {
            if (markerIds.Add(marker.Id))
            {
                Markers.Add(marker);
                markersAdded++;
            }
            else
            {
                skipped++;
            }
        }

        var boundaryIds = Boundaries.Select(b => b.Id).ToHashSet();
        var boundaryKeys = Boundaries.Select(b => (b.Name, b.Type)).ToHashSet();
        foreach (var boundary in other.Boundaries.ToList())
        {
            if (!boundaryIds.Contains(boundary.Id) && boundaryKeys.Add((boundary.Name, boundary.Type)))
            {
                boundaryIds.Add(boundary.Id);
                Boundaries.Add(boundary);
                boundariesAdded++;
            }
            else
            {
                skipped++;
            }
        }

        return (markersAdded, boundariesAdded, skipped);
    }
}
