# Accessibility Mapper — WPF (.NET 10) Conversion Spec

Source of truth for a from-scratch reimplementation. This document was written by reading
every file in the SwiftUI/AppKit/MapKit source tree of `AccessibilityMapper`
(`C:/Users/dru_s/Sources/repos/druware/AccessibilityMapper`). Implementers should not need
to open the Swift source — every number, string, and behavior needed to reproduce the app
is captured below.

Target architecture (fixed, decided outside this spec):
- WPF, .NET 10, built-in Fluent theme
- Map surface: WebView2 hosting a local HTML page with Leaflet.js + OpenStreetMap tiles
- Geocoding + boundary search: Nominatim (OSM)
- MVVM via CommunityToolkit.Mvvm
- `.accmap` persistence via `System.Text.Json`

---

## 1. Data model (`Models.swift`) — the `.accmap` file format

The document is a single JSON object, written with `JSONEncoder` configured as
`[.prettyPrinted, .sortedKeys]` (i.e. keys are alphabetically sorted in the output file).
Decoding uses `decodeIfPresent` with fallback defaults for every field, so **older files
missing newer fields must load successfully** — replicate this with either all-optional
JSON properties + defaults, or a custom converter that fills in the same defaults.

### 1.1 `MapDocument` (root object)

| Swift property | JSON key | Type | Default | Notes |
|---|---|---|---|---|
| `zipCode` | `zipCode` | string | `""` | Last-searched ZIP/address; shown in window title |
| `centerLatitude` | `centerLatitude` | double | `37.3318` | Persisted map center (updated on every pan/zoom end) |
| `centerLongitude` | `centerLongitude` | double | `-122.0312` | |
| `spanLatDelta` | `spanLatDelta` | double | `0.15` | MKCoordinateSpan latitude delta (degrees) |
| `spanLonDelta` | `spanLonDelta` | double | `0.15` | MKCoordinateSpan longitude delta (degrees) |
| `mapTypeRaw` | `mapTypeRaw` | int | `0` | `0`=Standard, `1`=Satellite, `2`=Hybrid |
| `markers` | `markers` | array of `BullseyeMarker` | `[]` | |
| `boundaries` | `boundaries` | array of `BoundaryRecord` | `[]` | |

Default coordinates (37.3318, -122.0312) are Sunnyvale/Cupertino CA (Apple's default
region) — reproduce these exact literals as the app/document defaults.

`region` (computed, not serialized): `MKCoordinateRegion(center: (centerLatitude,
centerLongitude), span: (spanLatDelta, spanLonDelta))` — this is the region used on open
when there are no markers.

`fitRegion` (computed, not serialized) — used on open **when there are markers**, so all
markers plus their outer ring are visible with a 15% margin:
```
minLat/maxLat/minLon/maxLon = bounds of all marker lat/lon
centerLat = (minLat+maxLat)/2 ; centerLon = (minLon+maxLon)/2
metersPerDegreeLat = 111320.0
metersPerDegreeLon = 111320.0 * cos(centerLat * π / 180)
latPad = outerRadiusMeters(4828.032) / metersPerDegreeLat
lonPad = outerRadiusMeters(4828.032) / metersPerDegreeLon
spanLat = ((maxLat - minLat) + 2*latPad) * 1.15
spanLon = ((maxLon - minLon) + 2*lonPad) * 1.15
```
Returns `nil` (use plain `region` instead) when `markers` is empty.

### 1.2 `BullseyeMarker`

| Swift property | JSON key | Type | Default |
|---|---|---|---|
| `id` | `id` | UUID string | new `UUID()` per instance |
| `latitude` | `latitude` | double | required |
| `longitude` | `longitude` | double | required |
| `label` | `label` | string | `""` |

`coordinate` is a computed convenience `(latitude, longitude)` — not serialized.
Equality (`==`) is by `id` only.

Radii constants (`BullseyeMarker.Radii`, meters) — see §2 for full detail:
```
inner      = 804.672     // 0.5 mi
safeRoutes = 1_609.344   // 1.0 mi
middle     = 3_218.688   // 2.0 mi
outer      = 4_828.032   // 3.0 mi
```

### 1.3 `BoundaryRecord`

| Swift property | JSON key | Type | Default |
|---|---|---|---|
| `id` | `id` | UUID string | new `UUID()` |
| `name` | `name` | string | required (Nominatim `display_name`) |
| `type` | `type` | string enum | required — `"city"` \| `"county"` \| `"state"` |
| `polygonRings` | `polygonRings` | array of ring | required |

`polygonRings`: array of rings; each ring is an array of `[longitude, latitude]` pairs
(GeoJSON coordinate order — **lon, lat**, not lat, lon). One `BoundaryRecord` can hold
multiple rings (built by flattening a GeoJSON `MultiPolygon`'s outer rings — see §7).

### 1.4 `BoundaryType` enum

```swift
enum BoundaryType: String, Codable, CaseIterable { case city, county, state }
```
Raw values used in JSON: `"city"`, `"county"`, `"state"` (lowercase, exact). Display names
(UI only, not serialized):

| raw value | `displayName` |
|---|---|
| `city` | `"City"` |
| `county` | `"County/Parish"` |
| `state` | `"State"` |

### 1.5 File type / UTI

- Extension: `.accmap`
- UTI: `com.openbcm.accmap`, conforms to `public.json`
- `CFBundleTypeName`: `"Accessibility Map"`, editor role
- File contents are plain UTF-8 JSON (it's literally `public.json` typed) — for the WPF
  port this just means: save as `.accmap`, content = pretty-printed JSON, filter in
  Open/Save dialogs as `Accessibility Map (*.accmap)|*.accmap`.

### 1.6 Example serialized `.accmap` document

Keys sorted alphabetically (as `JSONEncoder` with `.sortedKeys` produces), 2 markers, no
boundaries, satellite map type:

```json
{
  "boundaries" : [],
  "centerLatitude" : 37.42412,
  "centerLongitude" : -122.08351,
  "mapTypeRaw" : 1,
  "markers" : [
    {
      "id" : "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
      "label" : "Central Library",
      "latitude" : 37.42412,
      "longitude" : -122.08351
    },
    {
      "id" : "72B905B0-71B4-4D2C-9C10-6A6E7B9F3E22",
      "label" : "",
      "latitude" : 37.4293,
      "longitude" : -122.0784
    }
  ],
  "spanLatDelta" : 0.15,
  "spanLonDelta" : 0.15,
  "zipCode" : "94043"
}
```

With one boundary present:
```json
{
  "boundaries" : [
    {
      "id" : "9C7A2B10-1234-4EAB-9F00-1122334455AA",
      "name" : "Mountain View, Santa Clara County, California, United States",
      "polygonRings" : [
        [ [ -122.1112, 37.3861 ], [ -122.1105, 37.3870 ], [ -122.1090, 37.3855 ], [ -122.1112, 37.3861 ] ]
      ],
      "type" : "city"
    }
  ],
  "centerLatitude" : 37.3318,
  ...
}
```

---

## 2. The four "bullseye" zones

Driven by the `BullseyeMarker.Radii` enum in `Models.swift`; each zone has a visibility
toggle in `MapViewModel` (`showWalk`, `showSafeRoutes`, `showBike`, `showLSV`, all default
`true`) and a legend row in the toolbox.

| Zone (internal name) | Legend label (exact string) | Radius (miles) | Radius (meters, exact literal) | Toggle property | Stroke color (unselected / selected) | Fill color (unselected / selected) | Stroke width |
|---|---|---|---|---|---|---|---|
| `inner` — Walk | `"Walk         —  0.5 mi"` | 0.5 | **804.672** | `showWalk` | `systemRed` α0.5 / α0.85 | `systemRed` α0.20 / α0.38 | 1.0 / 1.5 |
| `safeRoutes` — Safe Routes | `"Safe Routes  —  1.0 mi"` | 1.0 | **1609.344** | `showSafeRoutes` | teal `RGB(0, 0.62, 0.72)` α0.60 / α0.90 | same teal α0.17 / α0.32 | 1.0 / 1.5 |
| `middle` — Bike | `"Bike         —  2.0 mi"` | 2.0 | **3218.688** | `showBike` | `systemOrange` α0.5 / α0.85 | `systemOrange` α0.17 / α0.32 | 1.0 / 1.5 |
| `outer` — LSV (Low Speed Vehicle) | `"LSV          —  3.0 mi"` | 3.0 | **4828.032** | `showLSV` | `systemBlue` α0.5 / α0.85 | `systemBlue` α0.14 / α0.26 | 1.0 / 1.5 |

Notes:
- The em-dash spacing in the legend strings above is literal (copy exactly, including the
  multiple spaces used for column alignment in a monospace-ish rendering).
- "Selected" doubles stroke opacity boost, roughly doubles fill opacity, and increases
  stroke width from 1.0→1.5 px (see §3/§8 for the general "prominence" rule).
- Colors are AppKit `NSColor` system colors; approximate hex for Leaflet (macOS system
  colors, standard/light appearance — close enough for the port, exact hex not mandated by
  source since these are dynamic system colors):
  - `systemRed` ≈ `#FF3B30`
  - teal (explicit RGB given in source, exact) = `rgb(0, 158, 184)` i.e. `#009EB8`
    (0.0, 0.62, 0.72 × 255)
  - `systemOrange` ≈ `#FF9500`
  - `systemBlue` ≈ `#007AFF`
- **Draw order (z-order)**: outer (LSV) first, then middle (Bike), then safeRoutes, then
  inner (Walk) drawn last/on top — see `rebuildOverlays` order: LSV → Bike → SafeRoutes →
  Walk. In Leaflet, add layers in that same order so Walk renders on top.
- Rings are per-marker; toggling a checkbox hides/shows that ring for **all** markers
  simultaneously.
- Radius values in **miles** for the legend/labels only: 0.5, 1.0, 2.0, 3.0. Always pass
  the **meters** value to `L.circle({ radius })` (Leaflet radius is meters).

---

## 3. Marker model & rendering

A marker (`BullseyeMarker`) has: `id` (guid), `latitude`, `longitude`, `label` (free text,
default empty).

### 3.1 Visual composition (`Coordinator.bullseyeIcon`)
Each marker's on-map icon is a composite bitmap: a bullseye glyph (ring + center dot +
4 crosshair tick lines) with an optional label pill drawn below it. Exact geometry:

| Property | Unselected | Selected |
|---|---|---|
| Overall glyph box (`dim`) | 14 px | 36 px |
| Ring stroke width (`lineW`) | 1.0 | 3.0 |
| Center dot radius (`dotR`) | 1.5 | 5.0 |
| Crosshair gap from center (`gap`) | 3.0 | 7.5 |
| Crosshair margin from edge (`margin`) | 1.5 | 4.0 |
| Crosshair line width | 0.75 | 2.5 |
| Glyph color | `systemRed` α **0.22** | `systemRed` α **1.0** |
| Label font | 9pt regular | 10pt medium |
| Label pill background | black α0.50 | black α0.65 |
| Label pill text color | white | white |

Bullseye glyph = 1 stroked circle (ring) + 1 filled circle (center dot) + 4 short line
segments (crosshair ticks: top, bottom, left, right, each stopping `gap` px short of
center so they don't overlap the dot). This is effectively a distinct "target/scope" icon
— not literally the same as the 4 radius rings, it's a small on-map badge.

Label pill (if `label` is non-empty): a rounded rect (corner radius 3) positioned directly
below the glyph, containing the label text in white on a translucent black background.
Icon anchor point is the **bottom** of the glyph (so the glyph sits on the coordinate;
label pill hangs below it without shifting the anchor).

**WPF/Leaflet simplification**: reproduce as an `L.divIcon` (or SVG marker) with two
visual states — small dim red target icon (unselected) vs large bold fully-opaque red
target icon (selected) — plus a label chip below when `label` is non-empty. Exact pixel
sizing above should be matched as closely as practical; exact glyph vector art is not
required to be pixel-identical as long as the size/opacity/prominence contrast is
preserved.

### 3.2 Selected vs. unselected — "prominence" rule (see also CHANGE.md 05-31 entries)
Two systems both react to selection, and both must be kept in sync application-wide:
1. **Marker icon** — dim small (unselected) vs. bold large fully-opaque (selected), per
   §3.1 table.
2. **Bullseye rings for that marker** — every ring (`inner`/`safeRoutes`/`middle`/`outer`)
   belonging to the selected marker gets higher stroke/fill opacity and thicker stroke
   (the `-sel` suffix variants in §2's table), while rings of all other markers stay at
   normal (unselected) opacity. This is per-marker, not global — only the selected
   marker's 4 rings are emphasized; everyone else's rings stay "less prominent."

### 3.3 Marker callout (map click)
Clicking an existing marker's icon shows a callout with:
- Title: `label` if non-empty, else `"Accessible Location"`
- Subtitle: coordinates formatted `"%.5f,  %.5f"` (lat, then lon; two spaces after the
  comma), e.g. `"37.42412,  -122.08351"`
- A "Delete" button (right callout accessory) that removes the marker from the document.

WPF/Leaflet: reproduce via Leaflet popup bound to the marker with the same title/subtitle
text and a Delete button whose click posts a `removeMarker` message back to C#.

---

## 4. Interactions / modes

Two mutually exclusive modes, stored as `MapViewModel.isPlacingBullseye: Bool`:

| Mode | `isPlacingBullseye` | Toolbox row | Icon | Subtitle text |
|---|---|---|---|---|
| Select | `false` (default) | "Select" | SF Symbol `cursorarrow` | "Move map, inspect markers" |
| Accessible Location (create) | `true` | "Accessible Location" | SF Symbol `scope` | "Click map to place rings" |

Mode is chosen exclusively via the two `ToolRow` buttons in the toolbox sidebar (§5); there
is no keyboard shortcut or map-based mode toggle in the source.

### Click behavior
- **Select mode + click empty map area**: nothing happens (no-op; panning/zoom via normal
  map gestures still works).
- **Select mode + click a marker**: `didSelect` fires → `viewModel.selectedMarkerID` set to
  that marker's id (emphasizes it per §3.2, and shows its callout). Clicking empty map
  space afterward (or `didDeselect`) clears `selectedMarkerID` back to `nil`.
- **Create mode + click empty map area**: the tap gesture is only active in this mode
  (`tapGesture.isEnabled = viewModel.isPlacingBullseye`); a new `BullseyeMarker` is
  appended to `document.markers` at the clicked coordinate with `label = ""`. If the click
  landed on an existing marker's annotation view (hit-test), the click is swallowed instead
  (no new marker is created; `for ann in map.annotations { if av.frame.contains(pt) { return } }`).
- **Double-click a marker in the sidebar Marker List** (not the map): centers the map on it
  — see §4.1.
- Deleting via the map callout's Delete button, or via the sidebar list's minus-circle
  button, both remove the marker from `document.markers` (and clear selection if it was
  selected).

### 4.1 Marker list ↔ map selection sync
- Sidebar `MarkerRow`: single tap (`onTapGesture(count: 1)`) → `onSelect` →
  `viewModel.selectedMarkerID = marker.id`. Double tap (`onTapGesture(count: 2)`) →
  `onCenter` → `viewModel.centerOn(marker:)`.
- `centerOn(marker:)`: sets `selectedMarkerID = marker.id` **and** pans/animates the map to
  a region centered on the marker with span `0.05°` lat/lon (tight zoom), by bumping
  `navigationTrigger` (a UUID that the map view watches to know when to animate).
- Selecting a marker on the map (clicking its icon) likewise sets
  `viewModel.selectedMarkerID`, which the sidebar list watches (`isSelected:
  viewModel.selectedMarkerID == marker.id`) to highlight the corresponding row — sync is
  bidirectional through the shared `selectedMarkerID` published property.
- Selected row background: `Color.accentColor.opacity(0.15)`; unselected row background:
  `Color.secondary.opacity(0.07)`.
- Renaming: the sidebar row's `TextField` is bound live — every keystroke calls `onRename`
  which updates `document.markers[i].label` immediately (not on blur/submit).

---

## 5. Sidebar / Toolbox (`ToolboxView.swift`)

Left sidebar, width 200–260px (ideal 220), an `HSplitView` pane alongside the map. Sections
top to bottom, each separated by a `Divider()`:

### 5.1 Header
`"Toolbox"` — headline weight font, padding 12h/10v.

### 5.2 Section "TOOLS" (header label exact text: `"TOOLS"`, uppercase, 10pt semibold gray)
Two selectable rows (`ToolRow`), only one active at a time (see §4):
1. **Select** — icon `cursorarrow`, subtitle "Move map, inspect markers"
2. **Accessible Location** — icon `scope`, subtitle "Click map to place rings"

Active row styling: accent-colored icon+bold title, accent-tinted background
(`Color.accentColor.opacity(0.12)`), trailing checkmark. Inactive: primary-colored icon,
regular weight, transparent background.

### 5.3 Section "RADIUS LEGEND" (header text: `"RADIUS LEGEND"`)
Four `LegendRow`s, each: a checkbox toggle bound to the show-flag, a small ring+fill swatch
circle (14×14) in the zone color, and the label text from §2's table. Unchecked state dims
the swatch (fill α0.06, stroke α0.3 instead of full) and dims the label text to secondary
color.

### 5.4 Section "BOUNDARIES" (header text: `"BOUNDARIES"`)
- A segmented/dropdown type picker (`BoundaryType`: City / County/Parish / State), width
  108, no visible label (`.labelsHidden()`).
- A text field, placeholder `"Search…"`, submits on Enter (`onSubmit`) → calls
  `searchBoundary()`.
- A search button: magnifying-glass icon normally, a small spinner (`ProgressView`) while
  `viewModel.isFetchingBoundary` is true. Disabled when the query is empty or a fetch is
  already in flight.
- On success, the fetched `BoundaryRecord` is appended to `document.boundaries` and the
  search field is cleared.
- Below the search row: a list of currently-added boundary chips (`BoundaryRow`), each
  showing a purple `map` icon, the boundary's `name` (Nominatim `display_name`, up to 2
  lines), and a red minus-circle delete button. Row background: purple tint
  (`Color.purple.opacity(0.08)`), corner radius 5.

### 5.5 Section "MARKERS" (header text: `"MARKERS"`)
Header row includes a right-aligned pill badge showing the marker count
(`document.markers.count`), 10pt semibold, secondary-color text on a
`Color.secondary.opacity(0.18)` capsule background.

- Empty state text (exact, multi-line): `"No markers yet.\nSelect Accessible Location, then\nclick anywhere on the map."` — caption font, secondary color.
- Non-empty: a scrollable list of `MarkerRow`s (see §3/§4 for interaction), each row shows:
  - `scope` icon (accent color if selected, else red)
  - An editable name `TextField` (placeholder `"Name..."`), live-bound to label
  - Coordinates as two monospaced 10pt fields: `"%.5f°"` lat, `"%.5f°"` lon (degree symbol
    suffix)
  - A minus-circle delete button (red, α0.7)
  - Row corner radius 5; background per §4.1 selection colors.

### 5.6 Status bar (bottom, above nothing — pinned via `Spacer()` above it)
A single-line label reflecting current mode:
- Placing mode: `"Click map to place accessible location"` with `scope` icon, accent
  color text, accent-tinted background (`Color.accentColor.opacity(0.08)`).
- Select mode: `"Select mode"` with `cursorarrow` icon, secondary color text, no
  background tint.

### 5.7 Top toolbar (`ContentView.swift`, above the map, not in the sidebar)
Horizontal bar, 14h/9v padding, window-background color, bottom divider:
- `map.fill` icon, accent color
- ZIP code text field (bordered, width 110), placeholder `"ZIP code"`, bound to
  `document.zipCode`, submits on Enter → `viewModel.geocodeZipCode(document.zipCode)`.
  **This field has initial keyboard focus when the window opens** (`zipFocused = true` in
  `onAppear` — also listed in TODO.md as the most recent focus fix).
- `"Go"` button, prominent/bordered style, small control size → same geocode action.
- A vertical divider.
- A segmented picker (no label), width 210, three segments: `"Standard"` (tag 0),
  `"Satellite"` (tag 1), `"Hybrid"` (tag 2), bound to `document.mapTypeRaw`. Tooltip/help
  text: `"Map display style"`.

---

## 6. Geocoding / search (starting point)

`MapViewModel.geocodeZipCode(_:)` uses Apple's `CLGeocoder().geocodeAddressString(query)` —
a general-purpose forward geocoder that accepts **either** a ZIP code (e.g. `"94025"`) or a
free-form `"city, state"` string (e.g. `"Mountain View, CA"`); Apple's geocoder disambiguates
automatically. There is exactly one text input for this (the toolbar ZIP field) — no
separate city/state fields.

- Trims whitespace; no-ops if empty.
- On success: takes the **first** placemark's coordinate, sets
  `navigationRegion = MKCoordinateRegion(center: coord, latitudinalMeters: 9000,
  longitudinalMeters: 9000)` (i.e. a ~9km × 9km viewport — noticeably wider than the 0.05°
  span used for `centerOn(marker:)`), then bumps `navigationTrigger` to animate the map.
- On failure (geocoder error, or no placemarks): sets `errorMessage`, which the app
  presents as a modal alert titled `"Error"` with an `"OK"` button. Error message templates
  (exact):
  - `"Could not find \"\(query)\": \(error.localizedDescription)"`
  - `"No location found for \"\(query)\""`

**WPF replacement**: Nominatim `/search` endpoint (already used for boundaries — see §7),
single query string, `limit=1`, take the first result's `lat`/`lon`. Replicate the ~9km
square viewport by converting to a Leaflet `flyTo`/`setView` with an appropriate zoom, or by
computing a bounding box ±4500m around the point and calling `fitBounds`. Preserve both
error message wordings (adapted to whatever exception text .NET/HttpClient produces) and
the same "Error" modal-alert / OK-button UX.

---

## 7. City/County/Parish limits overlay (boundaries)

`MapViewModel.fetchBoundary(query:type:)`:

- Endpoint: `https://nominatim.openstreetmap.org/search`
- Query params: `q=<query>`, `format=geojson`, `polygon_geojson=1`, `limit=1`
- Required header: `User-Agent: AccessibilityMapper/1.0 (dru@openbcm.com)` — Nominatim's
  usage policy requires a descriptive User-Agent; **the WPF port must send an equivalent
  identifying User-Agent header** (e.g. `AccessibilityMapper-WPF/1.0 (<contact>)`).
- Parses the GeoJSON `FeatureCollection` response: takes `features[0]`, reads
  `properties.display_name` (→ `BoundaryRecord.name`) and `geometry`.
- Geometry handling:
  - `"Polygon"`: `geometry.coordinates` is `[[[lon,lat],...], ...]` (array of linear rings)
    → parsed directly into `polygonRings`.
  - `"MultiPolygon"`: `geometry.coordinates` is `[[[[lon,lat],...],...], ...]` (array of
    polygons, each an array of rings) → **all polygons' rings are flattened into one
    `polygonRings` array** (concatenated, not kept as separate polygons/records).
  - Any other geometry type, or missing/empty rings → treated as failure.
- Failure error messages (exact):
  - `"No boundary found for \"\(q)\""` (missing/unparseable feature)
  - `"No polygon boundary returned for \"\(q)\""` (parsed but zero rings, e.g. geometry was
    a Point)
  - `"Boundary search failed: \(error.localizedDescription)"` (network/transport error)
- On success, `ToolboxView.searchBoundary()` appends the new `BoundaryRecord` to
  `document.boundaries` and clears the search field. Each boundary is independently
  removable (minus button, §5.4) — no de-duplication is performed by the app.
- `type` (city/county/state) is purely a user-selected label attached to the record for
  display purposes; it does not affect the query sent to Nominatim (the free-text query is
  whatever the user typed, e.g. `"Mountain View, CA"` or `"Santa Clara County"`) and does
  not change how the polygon is fetched or rendered.

### Rendering
- Boundaries render as `MKPolygon` overlays added at `.aboveRoads` level (i.e. above the
  base map tiles/roads but below markers/bullseyes — bullseyes and marker icons are added
  as separate overlay/annotation layers on top). Order in `MapView.makeNSView`/
  `updateNSView`: boundaries are (re)built first, then marker bullseye circles, then marker
  annotations — so in Leaflet, add boundary polygons to a pane below the circle/marker
  panes, or simply add them first so later layers draw on top.
- Renderer style (`MKPolygonRenderer`):
  - Stroke: `systemPurple` α0.75, width 1.5, **dashed** (`lineDashPattern = [6, 4]`,
    i.e. 6pt dash / 4pt gap)
  - Fill: a 45°-diagonal **hatch pattern** in `systemPurple` α0.30, tile size 8×8pt (one
    diagonal line per 8×8 tile, i.e. hatch stripes spaced `8/√2 ≈ 5.66pt` apart
    perpendicular to the stripe direction). This is a custom-drawn pattern image, not a
    solid fill.
  - `systemPurple` ≈ `#AF52DE`.
  - **WPF/Leaflet simplification**: Leaflet doesn't have a first-class hatch-fill option;
    acceptable equivalents are (a) an SVG pattern fill (`<pattern>` with diagonal lines,
    referenced as the polygon's `fillPattern`/`fillColor` via a data-URI or inline SVG
    defs) to match the look closely, or (b) if simplicity is preferred, a flat purple fill
    at a low, comparable opacity — call this out to the implementer as a deliberate
    simplification if chosen, since the spec's default expectation is to reproduce the
    hatch look.
  - Rebuilt in full (`removeOverlays` + re-add) whenever the boundaries array's id list
    changes — no incremental diffing.

---

## 8. Map behaviors (general)

- **Initial region**: if the document has markers, use `fitRegion` (§1.1, fits all markers
  + outer ring + 15% margin). Otherwise use the document's persisted `region`
  (center/span, defaulting to the Sunnyvale coordinate with a 0.15° span — a wide
  regional view, not a street-level zoom).
- **Map type**: Standard / Satellite / Hybrid via the toolbar segmented control, backed by
  `document.mapTypeRaw` (persisted per-document, not global). Leaflet equivalent: swap the
  active tile layer — OSM standard tiles for Standard; for Satellite/Hybrid use an
  imagery tile source (e.g. Esri World Imagery) with, for Hybrid, an OSM label/road overlay
  pane on top of imagery. Exact tile provider is an implementation choice since MapKit's
  imagery source isn't OSM-equivant 1:1 — document whichever provider is chosen.
- **Region persistence**: every time the user pans/zooms and the gesture ends
  (`regionDidChangeAnimated`), the new center/span is written back into
  `document.centerLatitude/Longitude/spanLatDelta/spanLonDelta` — so the last viewport is
  saved with the document and restored on next open (when there are no markers; fitRegion
  takes precedence when markers exist, per above).
- **Marker labels on map**: label text appears as a pill directly below each marker's
  bullseye icon when `label` is non-empty (§3.1); markers with no label show only the
  bullseye icon, no pill.
- **General ring prominence rule**: *all* on-map bullseye rings default to a dimmed,
  "less prominent" appearance (lower opacity, thinner stroke — see the "unselected" column
  throughout §2 and §3), and only the rings + icon belonging to the currently-selected
  marker are boosted to full prominence (§3.2). This was an explicit, deliberate design
  change (see CHANGE.md 05-31: "make all on map bullseyes to be less prominent" /
  "emphasize the bullseyes of the selected marker") — the WPF port must replicate both the
  dimmed default and the selection-boost, not just draw all rings at one fixed style.
- **Window title**: `"Accessibility Mapper"` when `zipCode` is empty, else
  `"Accessibility Mapper — \(zipCode)"` (em dash, not hyphen).
- **Window minimum size**: 900×600 (`ContentView().frame(minWidth: 900, minHeight: 600)`).
- **Sidebar width**: min 200, ideal 220, max 260 (a resizable split, not fixed).

---

## 9. Menus / commands

### 9.1 App-level (`AccessibilityMapperApp.swift`)
- Document-based app (`DocumentGroup(newDocument: MapDocument())`) — File ▸ New creates an
  empty `MapDocument()` (all defaults per §1.1); File ▸ Open/Save/Save As use the standard
  macOS document machinery with `.accmap` as the sole readable/writable content type.
  **WPF equivalent**: implement File ▸ New / Open / Save / Save As menu commands manually
  (WPF has no built-in document-architecture equivalent to `DocumentGroup`) — New creates a
  fresh in-memory `MapDocument` with the same defaults, Open/Save read/write `.accmap` via
  `System.Text.Json` with the same JSON shape as §1.
- App menu: the default "About AccessibilityMapper" command group is **replaced**
  (`CommandGroup(replacing: .appInfo)`) with a single item, **"About Accessibility
  Mapper"**, which opens a separate non-resizable About window (id `"about"`, content-sized,
  opens centered). No other custom menu commands exist in the source (no custom File/Edit/
  View menu items beyond the About replacement and the standard document commands supplied
  automatically by `DocumentGroup`).
- **WPF mapping**: a Help ▸ "About Accessibility Mapper" menu item (or File menu, per WPF/
  Fluent convention) opening a modal or non-modal About window sized to content, centered
  on screen.

### 9.2 AppleScript scripting bridge (`ScriptCommands.swift`)
Mac-only AppleScript automation support — **out of scope for the WPF port** (no Windows
equivalent is required by the fixed architecture), but documented here for completeness in
case an equivalent automation surface (e.g. named-pipe/COM API) is wanted later:
- `geocode "<address>"` → calls the same geocode-and-recenter logic as the toolbar (§6).
- `add marker at latitude <Double> longitude <Double> with label "<label>"` → appends a
  `BullseyeMarker` to the active document's `markers`; returns its UUID string as the
  script result. Fails (`errAEEventNotPermitted`) if no document window is active.
- `remove marker "<uuid-string>"` → removes the marker with that id; fails
  (`errAENoSuchObject`) if not found.
- These are wired through a singleton `ScriptingBridge.shared` with 3 closures set/cleared
  in `ContentView.onAppear`/`onDisappear`. No `.sdef` file was included in the requested
  read list, so its exact AppleScript grammar is not reproduced here — irrelevant to WPF.

### 9.3 About dialog content (`AboutView.swift`) — reproduce verbatim
Fixed-size window, 380pt wide, centered content, non-resizable
(`.windowResizability(.contentSize)`), centered on screen by default.

Exact text content, top to bottom:
1. App icon image, 96×96.
2. **"Accessibility Mapper"** — title2, bold.
3. **"Version \(ver) (\(build))"** — e.g. "Version 1.0 (1)"; `ver` = `CFBundleShortVersionString`
   (fallback `"1.0"`), `build` = `CFBundleVersion` (fallback `"1"`). Subheadline, secondary
   color.
4. Divider.
5. **"Copyright © 2026 Druware Software Designs"** — footnote, medium weight.
6. **"Dual Licensed — Open Source & Commercial"** — footnote, secondary color.
7. "Open Source License" heading (medium weight), then body text (exact, secondary color,
   centered): *"This source code is available under the "* + **"GNU General Public License
   v3"** (medium weight) + *". You may use, modify, and distribute it under those terms."*
   — followed by a hyperlink **"View GPL v3 license"** →
   `https://www.gnu.org/licenses/gpl-3.0.html`.
8. Divider.
9. "Commercial License" heading (medium weight), then body text (exact): *"A commercial
   license is available from Druware Software Designs for use in proprietary or
   closed-source products."* — followed by a hyperlink **"Learn about commercial
   licensing"** → `https://druware.com/accessibilitymapper/licensing`.

All of section 7–9's caption-sized body text is centered, secondary color, horizontal
padding 28.

**Copyright/company name discrepancy in source** (reproduce as-is, do not "fix"): most
file headers and `AboutView.swift` say *"Copyright © 2026 Druware Software Designs"*, while
`README.md`'s copyright line and `ScriptCommands.swift`'s header say *"Druware Software
Development"*. Use **"Druware Software Designs"** for the About dialog (that's what
`AboutView.swift` itself renders) — this is the user-facing string that must match exactly.

---

## 10. WPF mapping notes — construct-by-construct

| Swift / MapKit / SwiftUI construct | WPF / .NET 10 equivalent |
|---|---|
| `DocumentGroup` document architecture | Hand-rolled: `MainWindow` + File ▸ New/Open/Save/Save As commands (`ICommand`/`RelayCommand` via CommunityToolkit.Mvvm), tracking current file path + dirty flag manually |
| `MapDocument: Codable, FileDocument` | POCO `MapDocument` class/record + `System.Text.Json` `JsonSerializer` with `WriteIndented = true`; property names must match JSON keys in §1 exactly (use `[JsonPropertyName]` if C# property casing differs) |
| `UUID` | `System.Guid`, serialized as its default string form (`Guid.ToString()`), matching the same field where MapKit/Swift used `UUID().uuidString` |
| `MKMapView` / `NSViewRepresentable` | `Microsoft.Web.WebView2.Wpf.WebView2` control hosting a local `map.html` with Leaflet.js; `WebView2.CoreWebView2.PostWebMessageAsJson` (C#→JS) and `CoreWebView2.WebMessageReceived` (JS→C#) for the bridge |
| `MKCoordinateRegion` (center + span in degrees) | Leaflet `map.setView([lat,lon], zoom)` or `map.fitBounds(bounds)`; convert degree-span to a zoom level, or just pass a bounding box computed the same way `fitRegion`/`region` do and call `fitBounds` |
| `MKCircle` (bullseye rings) | `L.circle([lat,lon], { radius: <meters>, color, fillColor, fillOpacity, weight, opacity })` — radius already in meters per §1.2/§2, no conversion needed |
| `MKPolygon` (boundary overlay) | `L.polygon(ringLatLngs, { color, weight, dashArray: "6 4", fillColor/fillPattern })`; ring coordinates must be converted from GeoJSON `[lon,lat]` to Leaflet `[lat,lon]` order |
| `MKAnnotation` / custom `NSImage` icon (`bullseyeIcon`) | `L.divIcon` (HTML/CSS-drawn target glyph + optional label chip) or `L.marker` with a custom SVG icon; two CSS classes/states for selected vs unselected per §3.1 sizing table |
| `MKMapViewDelegate.didSelect/didDeselect` | Leaflet marker `click` handler → `postMessage` to C# → sets `SelectedMarkerId` on the ViewModel; deselect via a map-level click handler on empty space |
| `NSClickGestureRecognizer` tap-to-place | Leaflet `map.on('click', ...)` in JS, gated on a JS-side "placing mode" flag mirrored from `IsPlacingBullseye`; on click, `postMessage` the lat/lon back to C# which appends the marker to the document (matches source's "ViewModel owns mode, map just obeys it" pattern) |
| `regionDidChangeAnimated` (persist viewport) | Leaflet `moveend`/`zoomend` events → postMessage current center/bounds → write back to `MapDocument.centerLatitude/Longitude/spanLatDelta/spanLonDelta` (WPF side can derive an equivalent span from Leaflet's zoom/bounds) |
| `CLGeocoder.geocodeAddressString` | `HttpClient` GET to `https://nominatim.openstreetmap.org/search?q=<query>&format=json&limit=1`, parse `lat`/`lon` from the first result; **must** set a descriptive `User-Agent` header per Nominatim usage policy |
| Boundary fetch (already OSM-native in source) | Same Nominatim `/search?format=geojson&polygon_geojson=1&limit=1` call via `HttpClient`/`System.Text.Json`, same Polygon/MultiPolygon flattening logic as §7 |
| `HSplitView` (resizable sidebar) | `Grid` with a `GridSplitter` between a fixed-min-width sidebar column and the map column (min 200 / ideal 220 / max 260 — enforce via `MinWidth`/`MaxWidth` on the sidebar column or `ColumnDefinition`) |
| `@Published` / `ObservableObject` (MapViewModel) | `ObservableObject`/`[ObservableProperty]` via CommunityToolkit.Mvvm `ObservableObject` base + `[ObservableProperty]` source-generated fields for `IsPlacingBullseye`, `SelectedMarkerId`, `ErrorMessage`, `IsFetchingBoundary`, `ShowWalk/ShowSafeRoutes/ShowBike/ShowLSV`, `NavigationRegion`/trigger |
| SwiftUI `.alert(...)` for `errorMessage` | A bound `ErrorMessage` string on the ViewModel driving a WPF `MessageBox.Show` (or a themed dialog) titled "Error" with an OK button — trigger via a value-changed handler or a messenger/behavior, not direct MVVM-breaking calls from the ViewModel |
| SF Symbols (`cursorarrow`, `scope`, `map.fill`, `map`, `magnifyingglass`, `minus.circle.fill`, `checkmark`) | Fluent System Icons / Segoe Fluent Icons glyphs, or simple vector paths matching the same meaning (arrow cursor, scope/target, map, map, magnifier, remove-circle, checkmark) |
| `NSColor.system*` semantic colors | Fixed hex constants (§2) since WPF doesn't have live-adapting system accent colors the same way; pick fixed light/dark-appropriate values and keep them stable |
| AppleScript `ScriptCommands.swift` / `.sdef` | Out of scope — no Windows equivalent required by the fixed architecture (§9.2) |
| `UTType(exportedAs: "com.openbcm.accmap")` / `CFBundleDocumentTypes` | Windows file association via installer/registry (or simply an Open/Save dialog filter `"Accessibility Map (*.accmap)|*.accmap"`) — full shell integration (icon, double-click-to-open) is an installer concern, not app-code |
| `Window("About...", id: "about")`, `.windowResizability(.contentSize)` | A separate `AboutWindow : Window` with `SizeToContent="WidthAndHeight"`, `ResizeMode="NoResize"`, `WindowStartupLocation="CenterScreen"` |

---

## Appendix — files read for this spec

`AccessibilityMapperApp.swift`, `ContentView.swift`, `MapView.swift`, `MapViewModel.swift`,
`Models.swift`, `ToolboxView.swift`, `AboutView.swift`, `ScriptCommands.swift`, plus
`README.md`, `CHANGE.md`, `TODO.md`, `project.yml`, `AccessibilityMapper-Info.plist` from
`C:/Users/dru_s/Sources/repos/druware/AccessibilityMapper`.
