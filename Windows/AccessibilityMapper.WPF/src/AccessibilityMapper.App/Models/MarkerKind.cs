using System.Text.Json;
using System.Text.Json.Serialization;

namespace AccessibilityMapper.App.Models;

/// <summary>
/// What a <see cref="BullseyeMarker"/> represents. Serialized as lowercase "bullseye" /
/// "incident" per the .accmap format. A missing or unrecognized value reads as Bullseye.
/// </summary>
[JsonConverter(typeof(MarkerKindJsonConverter))]
public enum MarkerKind
{
    Bullseye,
    Incident
}

public sealed class MarkerKindJsonConverter : JsonConverter<MarkerKind>
{
    public override MarkerKind Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            reader.Skip(); // null, number, object, array: tolerated, read as bullseye
            return MarkerKind.Bullseye;
        }

        return reader.GetString() switch
        {
            "incident" => MarkerKind.Incident,
            _ => MarkerKind.Bullseye
        };
    }

    public override void Write(Utf8JsonWriter writer, MarkerKind value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value == MarkerKind.Incident ? "incident" : "bullseye");
    }
}
