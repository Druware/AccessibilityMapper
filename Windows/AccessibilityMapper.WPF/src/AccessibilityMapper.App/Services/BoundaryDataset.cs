using System.IO;
using System.IO.Compression;
using System.Text;
using AccessibilityMapper.App.Models;

namespace AccessibilityMapper.App.Services;

/// <summary>
/// One candidate for a boundary search. Carries enough to tell candidates apart in the
/// picker, and an opaque handle back to the record it came from.
/// </summary>
public sealed class BoundaryMatch
{
    internal BoundaryMatch(int index, string displayName, string qualifier, BoundaryType type)
    {
        Index = index;
        DisplayName = displayName;
        Qualifier = qualifier;
        Type = type;
    }

    internal int Index { get; }

    /// <summary>The name this candidate would be saved under, e.g. "Springfield, IL".</summary>
    public string DisplayName { get; }

    /// <summary>What distinguishes it from the others, e.g. "Illinois - city, 61.8 sq mi".</summary>
    public string Qualifier { get; }

    public BoundaryType Type { get; }
}

/// <summary>
/// Reads the bundled U.S. Census cartographic boundary artifact
/// (Assets/Boundaries/boundaries.bin, built by build/Convert-CensusBoundaries.ps1) and
/// resolves a user's "name, state" query to polygon rings.
///
/// The index is held in memory after first use; ring geometry stays on disk and is read
/// only for the record the user actually settles on.
/// </summary>
public sealed class BoundaryDataset
{
    private sealed record Entry(
        int Index,
        BoundaryType Type,
        string Name,
        string StateUsps,
        string StateName,
        string Lsad,
        string Geoid,
        long ALand,
        long Offset,
        int Length);

    /// <summary>Census LSAD for a census designated place: unincorporated, so it loses a
    /// tie against a real city/town/village of the same name.</summary>
    private const string CdpLsad = "57";

    private const double SquareMetresPerSquareMile = 2_589_988.11;

    /// <summary>
    /// Stripped only as a second pass, after an exact match on the Census NAME column has
    /// already failed. A blanket strip would turn "Kansas City" into "Kansas".
    /// </summary>
    private static readonly string[] TrailingTypeWords =
    {
        "city and borough", "census area", "municipality", "county", "parish",
        "borough", "village", "town", "city", "cdp"
    };

    private static readonly Dictionary<string, string> TokenAliases = new(StringComparer.Ordinal)
    {
        ["st"] = "saint",
        ["ste"] = "sainte",
        ["mt"] = "mount",
        ["ft"] = "fort"
    };

    /// <summary>Readable form of the Census LSAD codes that appear on places. Anything not
    /// listed contributes nothing to the qualifier rather than showing a raw code.</summary>
    private static readonly Dictionary<string, string> PlaceKinds = new(StringComparer.Ordinal)
    {
        ["21"] = "borough",
        ["25"] = "city",
        ["37"] = "municipality",
        ["43"] = "town",
        ["47"] = "village",
        ["57"] = "CDP"
    };

    private readonly string _path;
    private readonly object _gate = new();

    private List<Entry>? _entries;
    private Dictionary<string, List<Entry>>? _byName;
    private long _geometryBase;

    public BoundaryDataset()
        : this(Path.Combine(AppContext.BaseDirectory, "Assets", "Boundaries", "boundaries.bin"))
    {
    }

    public BoundaryDataset(string path)
    {
        _path = path;
    }

    /// <summary>
    /// Returns every boundary matching "Springfield, IL" / "Cook County, Illinois" / "Ohio",
    /// best first. Empty when nothing matches. Ranking is an incorporated place ahead of a
    /// census designated place of the same name, then larger land area, then GEOID — stable
    /// across runs, which matters because the choice is saved into .accmap.
    /// </summary>
    public IReadOnlyList<BoundaryMatch> FindCandidates(string query, BoundaryType type)
    {
        var index = EnsureLoaded();

        var (namePart, statePart) = SplitQuery(query);
        if (namePart.Length == 0)
            return Array.Empty<BoundaryMatch>();

        var candidates = Match(index, type, Normalise(namePart), statePart);

        if (candidates.Count == 0 && StripTrailingTypeWord(Normalise(namePart)) is { } stripped)
            candidates = Match(index, type, stripped, statePart);

        return candidates
            .OrderBy(e => e.Lsad == CdpLsad ? 1 : 0)
            .ThenByDescending(e => e.ALand)
            .ThenBy(e => e.Geoid, StringComparer.Ordinal)
            .Select(e => new BoundaryMatch(e.Index, DisplayName(e), Qualifier(e), e.Type))
            .ToList();
    }

    /// <summary>
    /// Materialises the rings for a candidate returned by <see cref="FindCandidates"/>.
    /// Throws <see cref="NoPolygonBoundaryException"/> if the record carries no rings,
    /// which would mean a corrupt artifact.
    /// </summary>
    public BoundaryRecord Load(BoundaryMatch match)
    {
        var entries = EnsureLoadedEntries();
        if (match.Index < 0 || match.Index >= entries.Count)
            throw new ArgumentOutOfRangeException(nameof(match), "Candidate does not belong to this dataset.");

        var entry = entries[match.Index];
        var rings = ReadRings(entry);
        if (rings.Count == 0)
            throw new NoPolygonBoundaryException();

        return new BoundaryRecord
        {
            Name = DisplayName(entry),
            Type = entry.Type,
            PolygonRings = rings
        };
    }

    private static List<Entry> Match(
        Dictionary<string, List<Entry>> index, BoundaryType type, string name, string? statePart)
    {
        if (!index.TryGetValue(KeyOf(type, name), out var hits))
            return new List<Entry>();

        if (statePart is null)
            return hits;

        // Normalised on both sides so "D.C." reaches "dc" and matches the STUSPS.
        var normalisedState = Normalise(statePart);
        return hits
            .Where(e => Normalise(e.StateUsps) == normalisedState
                        || Normalise(e.StateName) == normalisedState)
            .ToList();
    }

    /// <summary>
    /// A state is shown by its own name; anything below it is qualified, so two same-named
    /// results in a saved document stay tellable apart.
    /// </summary>
    private static string DisplayName(Entry e) =>
        e.Type == BoundaryType.State ? e.Name : $"{e.Name}, {e.StateUsps}";

    /// <summary>
    /// The detail line the picker shows. States need none — there is only ever one. For
    /// everything else the state plus the kind and size is what actually tells two
    /// same-named candidates apart.
    /// </summary>
    private static string Qualifier(Entry e)
    {
        if (e.Type == BoundaryType.State)
            return "";

        var squareMiles = e.ALand / SquareMetresPerSquareMile;
        var size = squareMiles >= 10 ? $"{squareMiles:N0} sq mi" : $"{squareMiles:N1} sq mi";

        return PlaceKinds.TryGetValue(e.Lsad, out var kind) && kind.Length > 0
            ? $"{e.StateName} - {kind}, {size}"
            : $"{e.StateName} - {size}";
    }

    /// <summary>Splits on the last comma: "Springfield, IL" but also "Lee, Saint Louis, MO".</summary>
    private static (string Name, string? State) SplitQuery(string query)
    {
        var trimmed = query.Trim();
        var comma = trimmed.LastIndexOf(',');
        if (comma < 0)
            return (trimmed, null);

        var name = trimmed[..comma].Trim();
        var state = trimmed[(comma + 1)..].Trim();
        return state.Length == 0 ? (name, null) : (name, state);
    }

    /// <summary>
    /// Case, punctuation and spacing all collapse, and the abbreviations that appear in
    /// Census names expand, so "St. Louis" and "saint louis" reach the same key.
    /// </summary>
    private static string Normalise(string value)
    {
        var cleaned = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            if (char.IsLetterOrDigit(ch))
                cleaned.Append(char.ToLowerInvariant(ch));
            else if (ch is '.' or '\'' or '’')
                continue; // "St." -> "st", "Coeur d'Alene" -> "coeur dalene"
            else
                cleaned.Append(' ');
        }

        var tokens = cleaned.ToString()
            .Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(t => TokenAliases.GetValueOrDefault(t, t));

        return string.Join(' ', tokens);
    }

    private static string? StripTrailingTypeWord(string normalisedName)
    {
        foreach (var word in TrailingTypeWords)
        {
            if (normalisedName.Length > word.Length + 1 && normalisedName.EndsWith(' ' + word, StringComparison.Ordinal))
                return normalisedName[..^(word.Length + 1)].TrimEnd();
        }
        return null;
    }

    private static string KeyOf(BoundaryType type, string normalisedName) =>
        (int)type + "|" + normalisedName;

    private List<Entry> EnsureLoadedEntries()
    {
        EnsureLoaded();
        return _entries!;
    }

    private Dictionary<string, List<Entry>> EnsureLoaded()
    {
        lock (_gate)
        {
            if (_byName is not null)
                return _byName;

            if (!File.Exists(_path))
                throw new FileNotFoundException(
                    $"Boundary dataset not found at {_path}. Run build/Convert-CensusBoundaries.ps1.",
                    _path);

            using var fs = File.OpenRead(_path);
            using var br = new BinaryReader(fs, Encoding.UTF8);

            if (Encoding.ASCII.GetString(br.ReadBytes(4)) != "ACBD")
                throw new InvalidDataException($"{_path} is not a boundary dataset.");

            var version = br.ReadInt32();
            if (version != 1)
                throw new InvalidDataException($"{_path} is format version {version}; this build reads version 1.");

            br.ReadInt32(); // vintage, informational
            var count = br.ReadInt32();
            _geometryBase = br.ReadInt64();

            var entries = new List<Entry>(count);
            var index = new Dictionary<string, List<Entry>>(count, StringComparer.Ordinal);

            for (var i = 0; i < count; i++)
            {
                var entry = new Entry(
                    i,
                    TypeOf(br.ReadByte()),
                    br.ReadString(),
                    br.ReadString(),
                    br.ReadString(),
                    br.ReadString(),
                    br.ReadString(),
                    br.ReadInt64(),
                    br.ReadInt64(),
                    br.ReadInt32());

                entries.Add(entry);
                Add(index, KeyOf(entry.Type, Normalise(entry.Name)), entry);

                // A state is just as likely to be typed as "OH" as "Ohio".
                if (entry.Type == BoundaryType.State && entry.StateUsps.Length > 0)
                    Add(index, KeyOf(entry.Type, Normalise(entry.StateUsps)), entry);
            }

            _entries = entries;
            _byName = index;
            return index;
        }
    }

    private static void Add(Dictionary<string, List<Entry>> index, string key, Entry entry)
    {
        if (!index.TryGetValue(key, out var list))
            index[key] = list = new List<Entry>(1);
        list.Add(entry);
    }

    private static BoundaryType TypeOf(byte raw) => raw switch
    {
        0 => BoundaryType.City,
        1 => BoundaryType.County,
        2 => BoundaryType.State,
        _ => throw new InvalidDataException($"Unknown boundary type {raw} in dataset.")
    };

    private List<List<double[]>> ReadRings(Entry entry)
    {
        using var fs = File.OpenRead(_path);
        fs.Position = _geometryBase + entry.Offset;

        var compressed = new byte[entry.Length];
        fs.ReadExactly(compressed);

        using var buffer = new MemoryStream(compressed);
        using var deflate = new DeflateStream(buffer, CompressionMode.Decompress);
        using var br = new BinaryReader(deflate);

        var ringCount = br.ReadInt32();
        var rings = new List<List<double[]>>(ringCount);
        for (var r = 0; r < ringCount; r++)
        {
            var pointCount = br.ReadInt32();
            var ring = new List<double[]>(pointCount);
            for (var p = 0; p < pointCount; p++)
            {
                // Stored as integers scaled by 1e6; emitted as GeoJSON [lon, lat].
                var lon = br.ReadInt32() / 1e6;
                var lat = br.ReadInt32() / 1e6;
                ring.Add(new[] { lon, lat });
            }
            rings.Add(ring);
        }
        return rings;
    }
}
