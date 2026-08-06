# Boundary data

City, county and state boundary polygons ship **inside the app**. There is no boundary
server, no API key, no rate limit and no per-lookup cost, and boundary search works with the
machine offline.

This document covers where the data comes from, how the artifact is built, and how a query
is resolved against it. See `issues.md` §2 for why this approach was chosen over a hosted
geocoder.

## Source

[U.S. Census Bureau cartographic boundary files](https://www.census.gov/geographies/mapping-files/time-series/geo/cartographic-boundary.html),
1:500,000, vintage 2025:

| File | `BoundaryType` | Download |
|---|---|---|
| `cb_2025_us_place_500k` | `City` | 22 MB |
| `cb_2025_us_county_500k` | `County` | 11 MB |
| `cb_2025_us_state_500k` | `State` | 3.1 MB |

The cartographic files are the *generalised* versions, intended for display. Full TIGER/Line
is surveying-grade and far heavier than a map overlay needs.

**Licence: public domain.** As a work of the U.S. Government the data carries no attribution
requirement, no terms of service, and no restriction on persisting geometry into a saved
`.accmap` document. The About dialog credits the Census Bureau regardless, because it is the
decent thing to do rather than because anything compels it.

**Coverage: the United States and its territories.** Nothing outside that resolves. This was
a deliberate scope decision, not an oversight.

## Building the artifact

```powershell
pwsh -File build/Convert-CensusBoundaries.ps1
```

Downloads the three files, converts them, and writes
`src/AccessibilityMapper.App/Assets/Boundaries/boundaries.bin` — 35,920 records
(32,629 places, 3,235 counties, 56 states), 3.25 million points, **23.1 MB**. Conversion
takes about 4 seconds once the tool is built.

The artifact is committed. **This only needs running when moving to a new Census vintage**
— contributors and CI never run it, and never need GDAL/ogr2ogr installed, because
`build/tools/CensusBoundaryConverter` parses the shapefiles directly. That tool is a plain
console project kept out of the solution: it is build tooling, not part of the app.

Census publishes an annual vintage. Boundaries move slowly — annexations and the occasional
incorporation — so an annual refresh folded into a normal release is enough. Pass
`-Vintage 2026` when the new one lands.

## Artifact format

One file, little-endian, strings length-prefixed UTF-8 (`BinaryWriter` convention):

```
"ACBD", int32 version, int32 vintage, int32 recordCount, int64 geometryBase

recordCount x index entry:
  byte   type            0 = City, 1 = County, 2 = State
  string name, stateUsps, stateName, lsad, geoid
  int64  aland
  int64  geometryOffset  relative to geometryBase
  int32  geometryLength

geometry section, per record a Deflate blob of:
  int32 ringCount
  per ring: int32 pointCount, then pointCount x (int32 lonE6, int32 latE6)
```

Two decisions worth knowing:

- **Coordinates are integers scaled by 1e6.** That is ~0.11 m of precision, far finer than
  1:500,000 source data, and half the size of the doubles the shapefile stores.
- **Geometry is compressed per record, not per file**, so a lookup can seek straight to the
  one record it matched instead of inflating the whole dataset.

23.1 MB against 67.7 MB of raw shapefile. Delta-encoding the coordinates as varints would
take roughly another third off, at the cost of a hand-rolled encoder; it was not worth it
for 8 MB.

The index is read into memory on first use; ring geometry stays on disk until a record
actually matches.

## Resolving a query

`BoundaryDataset.Find` turns "Springfield, IL" into rings:

1. **Split** on the last comma into name and state. The state part is optional.
2. **Normalise** both sides: lowercase, drop periods and apostrophes, collapse everything
   else to single spaces, and expand the abbreviations that appear in Census names — `st`
   → `saint`, `ste` → `sainte`, `mt` → `mount`, `ft` → `fort`. So "St. Louis" and
   "saint louis" reach the same key.
3. **Match** on the Census `NAME` column, then filter by state if one was given. States also
   index under their `STUSPS`, so "OH" and "Ohio" both work.
4. **Retry with the trailing type word stripped** if nothing matched — "Cook County" →
   "cook", "Lee Parish" → "lee". This is a *second pass* on purpose: stripping
   unconditionally would turn "Kansas City" into "Kansas".
5. **Break ties deliberately.** An incorporated place outranks a census designated place of
   the same name (`LSAD` 57), then larger land area wins, then `GEOID` as a final
   deterministic tiebreak. Stability matters because the result is written into `.accmap`.

### Known limits

- A query with no state and a name that exists in several states resolves to the largest by
  land area. "Springfield" alone will not ask which one you meant. A disambiguation picker
  is the honest fix and is UI work that has not been done.
- `BoundaryRecord.Name` is now `"Springfield, IL"` rather than the long comma-joined string
  Nominatim used to return. States keep their bare name.

## What still uses the network

Only point geocoding — the ZIP / "find a location" search in `GeocodingService`, which
still calls Nominatim. That path now goes through an on-disk cache
(`%LOCALAPPDATA%\AccessibilityMapper\geocode-cache.json`, 90-day TTL, misses cached too) and
a 1 request/second limiter, both of which the
[Nominatim usage policy](https://operations.osmfoundation.org/policies/nominatim/) requires
of clients.

Map tiles were tracked separately in `issues.md` §3 and are now resolved too: the street
base map comes from OpenFreeMap (OpenStreetMap vector tiles, no key, no request limit) and
the imagery layers from USGS The National Map, on the same public-domain footing as the
boundaries here. See `docs/MAP-BRIDGE.md`.
