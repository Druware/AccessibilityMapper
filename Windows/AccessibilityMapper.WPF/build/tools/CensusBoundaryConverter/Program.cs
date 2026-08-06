// Converts the U.S. Census Bureau cartographic boundary shapefiles (1:500,000) into the
// single compact artifact the app ships as Assets/Boundaries/boundaries.bin.
//
// Run through build/Convert-CensusBoundaries.ps1, which downloads and unzips the inputs
// first. Standalone:
//
//     dotnet run build/CensusBoundaryConverter.cs -- <inputDir> <outputFile> <vintage>
//
// A .NET 10 file-based app on purpose: the conversion needs a real binary parser, but it
// runs once per Census vintage and does not deserve a project file. Reading the shapefiles
// directly is what keeps GDAL/ogr2ogr off the build machine.
//
// Artifact layout (all little-endian; strings are BinaryWriter length-prefixed UTF-8):
//
//   "ACBD", int32 version, int32 vintage, int32 recordCount, int64 geometryBase
//   recordCount x index entry:
//     byte type (0=City, 1=County, 2=State)
//     string name, stateUsps, stateName, lsad, geoid
//     int64 aland, int64 geometryOffset (relative to geometryBase), int32 geometryLength
//   geometry section: per record a Deflate blob of
//     int32 ringCount, then per ring int32 pointCount and pointCount x (int32 lonE6, latE6)
//
// Coordinates are stored as integers scaled by 1e6: about 0.11 m of precision, which is far
// finer than 1:500,000 source data and half the size of the doubles the shapefile holds.

using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;

const int FormatVersion = 1;
const double Scale = 1e6;

if (args.Length != 3)
{
    Console.Error.WriteLine("usage: CensusBoundaryConverter <inputDir> <outputFile> <vintage>");
    return 1;
}

var inputDir = args[0];
var outputPath = args[1];
var vintage = int.Parse(args[2]);

// Type bytes match Models/BoundaryType.cs ordering, but the runtime maps them explicitly
// rather than casting, so the artifact does not silently break if that enum is reordered.
var layers = new (string Stem, byte Type, string Label)[]
{
    ($"cb_{vintage}_us_place_500k", 0, "City"),
    ($"cb_{vintage}_us_county_500k", 1, "County"),
    ($"cb_{vintage}_us_state_500k", 2, "State"),
};

var index = new List<Entry>();
var geometry = new MemoryStream();
long totalPoints = 0;

foreach (var (stem, type, label) in layers)
{
    var shpPath = FindInput(inputDir, stem + ".shp");
    var dbfPath = FindInput(inputDir, stem + ".dbf");

    var rows = ReadDbf(dbfPath);
    var added = 0;
    var skipped = 0;
    var row = 0;

    foreach (var rings in ReadShp(shpPath))
    {
        var attrs = rows[row++];

        if (rings.Count == 0)
        {
            skipped++;
            continue;
        }

        var offset = geometry.Position;
        foreach (var ring in rings) totalPoints += ring.Count;
        WriteGeometry(geometry, rings);

        index.Add(new Entry(
            type,
            attrs.GetValueOrDefault("NAME", ""),
            attrs.GetValueOrDefault("STUSPS", ""),
            // The state layer has no STATE_NAME column: it *is* the state.
            attrs.GetValueOrDefault("STATE_NAME") ?? attrs.GetValueOrDefault("NAME", ""),
            attrs.GetValueOrDefault("LSAD", ""),
            attrs.GetValueOrDefault("GEOID", ""),
            ParseLong(attrs.GetValueOrDefault("ALAND", "0")),
            offset,
            (int)(geometry.Position - offset)));
        added++;
    }

    if (row != rows.Count)
        throw new InvalidDataException($"{stem}: {row} shapes but {rows.Count} attribute rows");

    Console.WriteLine($"  {label,-7} {added,6:N0} records" + (skipped > 0 ? $" ({skipped} null shapes skipped)" : ""));
}

Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
using (var outFs = File.Create(outputPath))
using (var bw = new BinaryWriter(outFs, Encoding.UTF8))
{
    bw.Write("ACBD"u8.ToArray());
    bw.Write(FormatVersion);
    bw.Write(vintage);
    bw.Write(index.Count);

    var basePlaceholder = outFs.Position;
    bw.Write(0L);

    foreach (var e in index)
    {
        bw.Write(e.Type);
        bw.Write(e.Name);
        bw.Write(e.StateUsps);
        bw.Write(e.StateName);
        bw.Write(e.Lsad);
        bw.Write(e.Geoid);
        bw.Write(e.ALand);
        bw.Write(e.Offset);
        bw.Write(e.Length);
    }

    var geometryBase = outFs.Position;
    geometry.Position = 0;
    geometry.CopyTo(outFs);

    outFs.Position = basePlaceholder;
    bw.Write(geometryBase);
}

var size = new FileInfo(outputPath).Length;
Console.WriteLine($"  {"total",-7} {index.Count,6:N0} records, {totalPoints:N0} points");
Console.WriteLine($"  wrote {outputPath} ({size / 1024.0 / 1024.0:F1} MB)");
return 0;

static string FindInput(string dir, string name)
{
    var hit = Directory.EnumerateFiles(dir, name, SearchOption.AllDirectories).FirstOrDefault()
        ?? throw new FileNotFoundException($"{name} not found under {dir}");
    return hit;
}

static long ParseLong(string s) => long.TryParse(s, out var v) ? v : 0;

static void WriteGeometry(MemoryStream dest, List<List<(double X, double Y)>> rings)
{
    using var raw = new MemoryStream();
    var bw = new BinaryWriter(raw);
    bw.Write(rings.Count);
    foreach (var ring in rings)
    {
        bw.Write(ring.Count);
        foreach (var (x, y) in ring)
        {
            bw.Write((int)Math.Round(x * Scale));
            bw.Write((int)Math.Round(y * Scale));
        }
    }
    bw.Flush();

    raw.Position = 0;
    // Optimal, not SmallestSize: on ~36,000 blobs this size the extra squeeze is worth
    // well under a percent and costs minutes of build time.
    using var deflate = new DeflateStream(dest, CompressionLevel.Optimal, leaveOpen: true);
    raw.CopyTo(deflate);
}

// dBASE III table. Census ships these as UTF-8 (declared in the companion .cpg).
static List<Dictionary<string, string>> ReadDbf(string path)
{
    using var fs = File.OpenRead(path);
    using var br = new BinaryReader(fs, Encoding.ASCII);

    br.ReadBytes(4);
    var recordCount = br.ReadInt32();
    var headerLength = br.ReadInt16();
    var recordLength = br.ReadInt16();
    br.ReadBytes(20);

    var fields = new List<(string Name, int Length)>();
    while (true)
    {
        var peek = fs.ReadByte();
        if (peek == 0x0D || peek < 0) break;
        fs.Position -= 1;
        var raw = br.ReadBytes(32);
        fields.Add((Encoding.ASCII.GetString(raw, 0, 11).TrimEnd('\0', ' '), raw[16]));
    }

    var rows = new List<Dictionary<string, string>>(recordCount);
    for (var r = 0; r < recordCount; r++)
    {
        fs.Position = headerLength + (long)r * recordLength;
        var raw = br.ReadBytes(recordLength);
        var row = new Dictionary<string, string>(fields.Count, StringComparer.Ordinal);
        var offset = 1; // leading byte is the deletion flag
        foreach (var (name, length) in fields)
        {
            row[name] = Encoding.UTF8.GetString(raw, offset, length).Trim();
            offset += length;
        }
        rows.Add(row);
    }
    return rows;
}

// ESRI shapefile, polygon (type 5) only, which is what the cartographic boundary files use.
// Each part of a record is one ring; rings are yielded flat, matching how BoundaryRecord
// stores them and how map.js draws them (one L.polygon per ring).
static IEnumerable<List<List<(double X, double Y)>>> ReadShp(string path)
{
    using var fs = File.OpenRead(path);
    using var br = new BinaryReader(fs);

    var header = br.ReadBytes(100);
    if (BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(0)) != 9994)
        throw new InvalidDataException($"{path}: not a shapefile");

    // Header stores the file length in 16-bit words.
    var fileLength = 2L * BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(24));

    while (fs.Position < fileLength)
    {
        br.ReadBytes(8); // record number + content length, both big-endian, both unused
        var shapeType = br.ReadInt32();

        var rings = new List<List<(double X, double Y)>>();
        if (shapeType == 0)
        {
            yield return rings; // null shape: keeps record alignment with the .dbf
            continue;
        }
        if (shapeType != 5)
            throw new NotSupportedException($"{path}: shape type {shapeType} is not a polygon");

        br.ReadBytes(32); // bounding box
        var partCount = br.ReadInt32();
        var pointCount = br.ReadInt32();

        var parts = new int[partCount];
        for (var p = 0; p < partCount; p++) parts[p] = br.ReadInt32();

        var points = new (double X, double Y)[pointCount];
        for (var q = 0; q < pointCount; q++) points[q] = (br.ReadDouble(), br.ReadDouble());

        for (var p = 0; p < partCount; p++)
        {
            var start = parts[p];
            var end = p + 1 < partCount ? parts[p + 1] : pointCount;
            var ring = new List<(double X, double Y)>(end - start);
            for (var q = start; q < end; q++) ring.Add(points[q]);
            rings.Add(ring);
        }

        yield return rings;
    }
}

record struct Entry(
    byte Type,
    string Name,
    string StateUsps,
    string StateName,
    string Lsad,
    string Geoid,
    long ALand,
    long Offset,
    int Length);
