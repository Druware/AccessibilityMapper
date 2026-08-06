using System.Text.Json;
using System.Text.Json.Serialization;

namespace AccessibilityMapper.App.Models;

/// <summary>
/// Type of administrative boundary attached to a <see cref="BoundaryRecord"/>.
/// Serialized as lowercase "city" / "county" / "state" per the .accmap format.
/// </summary>
[JsonConverter(typeof(BoundaryTypeJsonConverter))]
public enum BoundaryType
{
    City,
    County,
    State
}

public static class BoundaryTypeExtensions
{
    /// <summary>UI-only display name (not serialized).</summary>
    public static string DisplayName(this BoundaryType type) => type switch
    {
        BoundaryType.City => "City",
        BoundaryType.County => "County/Parish",
        BoundaryType.State => "State",
        _ => type.ToString()
    };
}

public sealed class BoundaryTypeJsonConverter : JsonConverter<BoundaryType>
{
    public override BoundaryType Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString();
        return raw switch
        {
            "city" => BoundaryType.City,
            "county" => BoundaryType.County,
            "state" => BoundaryType.State,
            _ => BoundaryType.City
        };
    }

    public override void Write(Utf8JsonWriter writer, BoundaryType value, JsonSerializerOptions options)
    {
        var raw = value switch
        {
            BoundaryType.City => "city",
            BoundaryType.County => "county",
            BoundaryType.State => "state",
            _ => "city"
        };
        writer.WriteStringValue(raw);
    }
}
