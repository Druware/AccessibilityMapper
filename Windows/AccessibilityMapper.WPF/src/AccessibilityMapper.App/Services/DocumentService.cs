using System.IO;
using System.Text.Json;
using AccessibilityMapper.App.Models;

namespace AccessibilityMapper.App.Services;

/// <summary>
/// Loads/saves `.accmap` documents as pretty-printed JSON.
/// </summary>
public class DocumentService
{
    public const string DialogFilter = "Accessibility Map (*.accmap)|*.accmap";

    private static readonly JsonSerializerOptions SaveOptions = new()
    {
        WriteIndented = true
    };

    public MapDocument Load(string path)
    {
        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<MapDocument>(json) ?? new MapDocument();
    }

    public void Save(MapDocument document, string path)
    {
        var json = JsonSerializer.Serialize(document, SaveOptions);
        File.WriteAllText(path, json);
    }
}
