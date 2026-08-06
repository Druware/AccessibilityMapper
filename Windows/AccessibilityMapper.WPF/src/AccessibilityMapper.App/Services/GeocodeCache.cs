using System.IO;
using System.Text.Json;

namespace AccessibilityMapper.App.Services;

/// <summary>
/// On-disk cache of geocoding results, keyed by normalised query. The Nominatim usage
/// policy requires clients to cache; independently of that, a user re-searching the same
/// ZIP should not produce a request every time.
///
/// Misses are cached too — a typo that returns nothing should not be retried against the
/// server on every attempt.
/// </summary>
public sealed class GeocodeCache
{
    private sealed class Entry
    {
        public bool Found { get; set; }
        public double Latitude { get; set; }
        public double Longitude { get; set; }
        public DateTimeOffset Stored { get; set; }
    }

    private static readonly TimeSpan Ttl = TimeSpan.FromDays(90);

    private readonly string _path;
    private readonly Dictionary<string, Entry> _entries;
    private readonly object _gate = new();

    public GeocodeCache()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AccessibilityMapper", "geocode-cache.json"))
    {
    }

    public GeocodeCache(string path)
    {
        _path = path;
        _entries = Load(path);
    }

    /// <summary>
    /// Normalises a user query into a cache key: case- and whitespace-insensitive, so
    /// "  90210 " and "90210" are one entry.
    /// </summary>
    public static string Key(string query) =>
        string.Join(' ', query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
              .ToLowerInvariant();

    /// <summary>
    /// Returns true when the query has a live cache entry. <paramref name="result"/> is
    /// null for a cached miss, which is a hit as far as the caller is concerned.
    /// </summary>
    public bool TryGet(string query, out (double Latitude, double Longitude)? result)
    {
        result = null;
        lock (_gate)
        {
            if (!_entries.TryGetValue(Key(query), out var entry))
                return false;

            if (DateTimeOffset.UtcNow - entry.Stored > Ttl)
            {
                _entries.Remove(Key(query));
                return false;
            }

            if (entry.Found)
                result = (entry.Latitude, entry.Longitude);
            return true;
        }
    }

    public void Set(string query, (double Latitude, double Longitude)? result)
    {
        lock (_gate)
        {
            _entries[Key(query)] = new Entry
            {
                Found = result.HasValue,
                Latitude = result?.Latitude ?? 0,
                Longitude = result?.Longitude ?? 0,
                Stored = DateTimeOffset.UtcNow
            };
            Save();
        }
    }

    private static Dictionary<string, Entry> Load(string path)
    {
        // A cache is an optimisation: a missing, unreadable or corrupt file means we start
        // empty and re-fetch, never that geocoding fails. Anything wider than IO/JSON is
        // still allowed to propagate.
        try
        {
            if (File.Exists(path))
            {
                var json = File.ReadAllText(path);
                var loaded = JsonSerializer.Deserialize<Dictionary<string, Entry>>(json);
                if (loaded is not null)
                    return loaded;
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
        }

        return new Dictionary<string, Entry>();
    }

    /// <summary>Caller holds <see cref="_gate"/>.</summary>
    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);

            // Write-then-move so an interrupted save cannot leave a half-written cache
            // behind for the next run to trip over.
            var temp = _path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(_entries));
            File.Move(temp, _path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}
