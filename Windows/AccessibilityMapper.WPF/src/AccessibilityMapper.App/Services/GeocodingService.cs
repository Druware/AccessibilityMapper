using System.Net.Http;
using System.Text.Json;

namespace AccessibilityMapper.App.Services;

/// <summary>
/// Forward geocoding via the Nominatim (OpenStreetMap) /search endpoint.
///
/// This is the app's only remaining network dependency — boundary polygons come from the
/// bundled Census dataset (see <see cref="BoundaryService"/>). Every request goes through
/// an on-disk cache and a 1 req/s limiter, both of which the Nominatim usage policy
/// requires of clients.
/// </summary>
public class GeocodingService
{
    private static readonly HttpClient Client = CreateClient();

    // Static: the policy caps the *application*, not each service instance.
    private static readonly RateLimiter Limiter = new(TimeSpan.FromSeconds(1));

    private readonly GeocodeCache _cache;

    public GeocodingService() : this(new GeocodeCache())
    {
    }

    public GeocodingService(GeocodeCache cache)
    {
        _cache = cache;
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient();
        client.DefaultRequestHeaders.UserAgent.ParseAdd("AccessibilityMapper-WPF/1.0 (dru@openbcm.com)");
        return client;
    }

    /// <summary>
    /// Geocodes a ZIP code or free-form "city, state" query. Returns null when no result
    /// was found. Network/transport failures propagate as exceptions for the caller to
    /// translate into the spec's error-message wording.
    /// </summary>
    public async Task<(double Latitude, double Longitude)?> GeocodeAsync(string query)
    {
        if (_cache.TryGet(query, out var cached))
            return cached;

        await Limiter.WaitAsync();

        var url = $"https://nominatim.openstreetmap.org/search?q={Uri.EscapeDataString(query)}&format=json&limit=1";

        using var response = await Client.GetAsync(url);
        response.EnsureSuccessStatusCode();

        await using var stream = await response.Content.ReadAsStreamAsync();
        using var doc = await JsonDocument.ParseAsync(stream);

        var result = Parse(doc);

        // Only reached on a successful response, so transport failures are never cached.
        _cache.Set(query, result);
        return result;
    }

    private static (double Latitude, double Longitude)? Parse(JsonDocument doc)
    {
        if (doc.RootElement.ValueKind != JsonValueKind.Array || doc.RootElement.GetArrayLength() == 0)
            return null;

        var first = doc.RootElement[0];
        var lat = double.Parse(first.GetProperty("lat").GetString()!, System.Globalization.CultureInfo.InvariantCulture);
        var lon = double.Parse(first.GetProperty("lon").GetString()!, System.Globalization.CultureInfo.InvariantCulture);
        return (lat, lon);
    }
}
