# Map Bridge Contract (WebView2 &lt;-&gt; MainViewModel)

Implements the bridge specified in the Phase A task brief and CONVERSION-SPEC.md §§2-8.
The C# side of the bridge lives entirely in `Views/MapControl.xaml.cs` — `MainViewModel`
never references WebView2 or JSON wire shapes directly; it raises `MapMessage` objects via
the `MapMessageOut` event, and `MapControl` translates those into the JSON below.

## Map engine

The JS side is **MapLibre GL** (`Assets/Map/maplibre-gl.mjs`, bundled — nothing is fetched
from a CDN). It replaced Leaflet when the base map moved to vector tiles; the wire contract
below did not change, and `MapControl.xaml.cs` needed no edit beyond a comment.

Two consequences worth knowing before editing `map.js`:

- **MapLibre GL 6 is ESM with named exports and no default export**, so `map.js` is a module
  (`<script type="module">`) and imports it as `import * as maplibregl from ...`.
- **Windows registers `.mjs` as `text/plain`** on at least some machines, and Chromium
  refuses to execute a module script that is not served as JavaScript — the map silently
  never starts. `MapControl` therefore serves `.mjs` itself with `Content-Type:
  text/javascript` instead of trusting the virtual host's registry lookup.

## Tile providers

- **Standard** (mapType 0): [OpenFreeMap](https://openfreemap.org) vector tiles, style
  `https://tiles.openfreemap.org/styles/liberty`. OpenStreetMap data, no API key, no
  registration, no request limit. Replaced OSM's own raster tile servers, whose usage
  policy forbids distributed app use.
- **Satellite** (mapType 1): USGS The National Map orthoimagery,
  `https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}`.
- **Hybrid** (mapType 2): `.../USGSImageryTopo/...`, which composites place labels and
  contours into the imagery — one layer, where the previous Esri stack needed two.

Both USGS layers are public domain US Government work: no key, no terms, US coverage only.
Their caches stop at **z16**, so the raster source sets `maxzoom: 16` and MapLibre overzooms
past it; deep zoom softens rather than going blank.

Changing map type calls `map.setStyle()`, which discards every source and layer. All overlay
sources and layers are therefore (re)created on each `style.load`, and the marker/zone/
boundary state held in JS is pushed back into them. DOM markers are not part of the style
and survive untouched.

## Boundary fill simplification

Per CONVERSION-SPEC.md §7, MapKit's 45°-diagonal hatch fill is **not** reproduced. Boundary
polygons render with a flat purple fill (`#AF52DE`, fillOpacity 0.30) and the specified
dashed purple stroke (weight 1.5, opacity 0.75, dashArray `"6 4"`). This is the
spec-documented acceptable simplification, not a bug.

Boundary layers are added before the zone layers on every `style.load`, and MapLibre draws
in layer order, so boundaries always stay below the rings regardless of when data arrives —
the same guarantee Leaflet's dedicated low-z-index pane used to provide. Markers are DOM
overlays and so sit above both.

A `BoundaryRecord` with multiple rings (flattened MultiPolygon) becomes one GeoJSON
`Polygon` feature per ring — the flattened data model has no outer/hole distinction to
preserve, so each ring is drawn as its own independent shape.

Zone rings are GeoJSON polygons approximating a circle (96 segments), not MapLibre `circle`
layers: `circle-radius` is in **pixels**, and the zones are fixed distances on the ground.
Selection is a feature property driving `['case', ['get', 'selected'], ...]` paint
expressions, so selecting a marker is a `setData` call rather than a layer rebuild.

## Marker glyph simplification

The bullseye marker icon is a CSS-drawn circle (border) + crosshair (linear-gradient cross)
+ center dot (`::after`), not the exact vector art from `Coordinator.bullseyeIcon`. Sizing
(14px unselected / 36px selected), opacity (0.22 / 1.0), and border width (1px / 3px) match
the spec's prominence table; the crosshair ticks are drawn as a continuous cross through the
circle rather than four gapped segments — a documented simplification since exact glyph
vector art was explicitly not required (CONVERSION-SPEC.md §3.1).

## Outbound: C# -> JS (`CoreWebView2.PostWebMessageAsJson`)

All messages are `{"type": "...", ...}`. Implemented exactly as specified in the task brief:

| type | shape |
|---|---|
| `init` | `{type, markers:[{id,lat,lon,label}], selectedId, zones:{walk,safeRoutes,bike,lsv}, boundaries:[{id,name,rings:[[[lon,lat]...]]}], mapType, view:{center:[lat,lon], span:[latDelta,lonDelta], fitMarkers}}` |
| `setMarkers` | `{type, markers:[...], selectedId}` |
| `setSelected` | `{type, id}` |
| `setZones` | `{type, walk, safeRoutes, bike, lsv}` (flat — **not** nested under `zones`, unlike `init`) |
| `setMode` | `{type, placing}` |
| `setBoundaries` | `{type, boundaries:[...]}` |
| `setMapType` | `{type, mapType}` |
| `flyTo` | `{type, lat, lon, tight}` — `tight:true` uses a 0.05°×0.05° span; `tight:false` uses a ~9km×9km span (matches the spec's geocode viewport) |

`init` is sent twice in practice: once when the map posts `ready`, and again whenever
`MainViewModel.Document` is replaced (New/Open) so an already-initialized map fully resets
— `map.js`'s `init` handler is idempotent (full rebuild), so this is safe.

`view.span`/`flyTo` bounds are both implemented as `map.fitBounds(...)` over a
center±span/2 box computed with `metersPerDegreeLat = 111320` and
`metersPerDegreeLon = 111320 * cos(lat)`, mirroring `MapDocument.FitRegion()`'s formula
(CONVERSION-SPEC.md §1.1) exactly.

## Inbound: JS -> C# (`window.chrome.webview.postMessage`)

| type | shape | VM effect |
|---|---|---|
| `ready` | `{type}` | `MainViewModel.SendInit()` |
| `addMarker` | `{type, lat, lon}` | `MainViewModel.AddMarkerAt(lat, lon)` |
| `selectMarker` | `{type, id}` | `SelectedMarkerId = id` |
| `deselect` | `{type}` | `SelectedMarkerId = null` |
| `removeMarker` | `{type, id}` | `DeleteMarkerCommand.Execute(id)` |
| `viewportChanged` | `{type, centerLat, centerLon, spanLatDelta, spanLonDelta}` | `MainViewModel.UpdateViewport(...)` |

No deviations from the task brief's inbound contract.

## Known Phase A gaps (for Phase B)

- `MainViewModel` has no `RemoveBoundary(Guid)` command yet — not in the Phase A command
  list, but the boundary-chip delete button (spec §5.4) will need one. Cheap to add
  (mirror `DeleteMarker`).
- The placeholder sidebar (`MainWindow.xaml`) has no boundary search UI, marker list, or
  About dialog — all explicitly deferred to Phase B per the task brief.
