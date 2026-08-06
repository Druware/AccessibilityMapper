using System.Text.Json.Serialization;

namespace AccessibilityMapper.App.Models;

/// <summary>
/// A fetched administrative boundary (city/county/state) overlay.
/// <see cref="PolygonRings"/> holds GeoJSON-ordered [longitude, latitude] pairs per ring;
/// a MultiPolygon result has all of its polygons' rings flattened into this one list.
/// </summary>
public class BoundaryRecord
{
    [JsonPropertyName("id")]
    public Guid Id { get; set; } = Guid.NewGuid();

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("type")]
    public BoundaryType Type { get; set; } = BoundaryType.City;

    /// <summary>Rings of [lon, lat] coordinate pairs.</summary>
    [JsonPropertyName("polygonRings")]
    public List<List<double[]>> PolygonRings { get; set; } = new();
}
