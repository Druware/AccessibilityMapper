using AccessibilityMapper.App.Models;

namespace AccessibilityMapper.App.Services;

/// <summary>
/// Thrown when a boundary was found but its geometry parsed to zero polygon rings, so the
/// caller can distinguish this from "no feature at all".
/// </summary>
public class NoPolygonBoundaryException : Exception
{
}

/// <summary>
/// Resolves a city/county/state boundary polygon from the bundled U.S. Census cartographic
/// boundary dataset (1:500,000). See CONVERSION-SPEC.md §7 and docs/BOUNDARY-DATA.md.
///
/// This makes no network request: the data ships with the app, so boundary search works
/// offline and costs nothing per lookup. Coverage is the United States and its territories.
/// </summary>
public class BoundaryService
{
    private readonly BoundaryDataset _dataset;

    public BoundaryService() : this(new BoundaryDataset())
    {
    }

    public BoundaryService(BoundaryDataset dataset)
    {
        _dataset = dataset;
    }

    /// <summary>
    /// Every boundary matching the query, best first, or empty when nothing matched. The
    /// caller decides what to do when more than one comes back. A missing or unreadable
    /// dataset propagates as-is for translation into the spec's "Boundary search failed:
    /// ..." wording.
    /// </summary>
    public Task<IReadOnlyList<BoundaryMatch>> FindCandidatesAsync(string query, BoundaryType type)
        // Off the UI thread: the first call reads and indexes ~36,000 records.
        => Task.Run(() => _dataset.FindCandidates(query, type));

    /// <summary>
    /// Loads the rings for a chosen candidate. Throws
    /// <see cref="NoPolygonBoundaryException"/> when the record carries no usable rings.
    /// </summary>
    public Task<BoundaryRecord> LoadAsync(BoundaryMatch match)
        => Task.Run(() => _dataset.Load(match));
}
