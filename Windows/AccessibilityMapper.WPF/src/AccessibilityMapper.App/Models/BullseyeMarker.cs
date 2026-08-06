using System.Text.Json.Serialization;

namespace AccessibilityMapper.App.Models;

/// <summary>
/// A single accessible-location marker with its four "bullseye" radius rings.
/// </summary>
public class BullseyeMarker
{
    /// <summary>Radii of the four bullseye rings, in meters (see CONVERSION-SPEC.md §2).</summary>
    public static class Radii
    {
        public const double Inner = 804.672;       // Walk — 0.5 mi
        public const double SafeRoutes = 1609.344;  // Safe Routes — 1.0 mi
        public const double Middle = 3218.688;      // Bike — 2.0 mi
        public const double Outer = 4828.032;       // LSV — 3.0 mi
    }

    [JsonPropertyName("id")]
    public Guid Id { get; set; } = Guid.NewGuid();

    [JsonPropertyName("latitude")]
    public double Latitude { get; set; }

    [JsonPropertyName("longitude")]
    public double Longitude { get; set; }

    [JsonPropertyName("label")]
    public string Label { get; set; } = "";
}
