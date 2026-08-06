    # Issues

Work items for AccessibilityMapper.WPF. Newest first; close by deleting the entry or moving
it under **Closed**.

**No open items.** Everything filed so far is resolved; the entries are kept for the
decisions recorded in them.

| # | Title | Area | Priority | Status |
|---|---|---|---|---|
| 1 | App icon does not match the macOS original | Design / assets | Medium | Closed |
| 2 | Bundled Census boundaries; cached and rate-limited geocoding | Services / licensing | High | Closed |
| 3 | Map tiles used OSM and Esri endpoints with no licence agreement | Services / licensing | High | Closed |
| 4 | Boundary search resolves ambiguous names silently | UX | Low | Closed |

---

# Closed

## 1. App icon does not match the macOS original

**Area:** design / assets · **Priority:** medium · **Status:** closed

### What this was

The Windows icon was generated from scratch during distribution setup — a blue plate with a
white bullseye crosshair borrowed from `Views/TargetGlyph.xaml`, the *marker* glyph rather
than the app icon. Side by side with the macOS app the two looked unrelated. The macOS PNGs
could not simply be copied: they are `Format24bppRgb` with no alpha, flattened onto
near-white, and the MSIX `targetsize-*_altform-unplated` variants require transparent
corners. So it needed a redraw.

### Resolution

`New-IconDrawing` in `build/New-AppIcons.ps1` now draws the macOS design: a `#48B5EF` frame
around a cyan-to-green map with contour lines and a road, and a centred orange teardrop pin
carrying the International Symbol of Access in `#FBFAEF`.

Three things worth recording, because they are not obvious from the description that was
filed here:

- **The pin proportions were measured off the original rather than guessed** — the pin is
  ~42% of the frame width, centred, head slightly above centre.
- **The wheel of the wheelchair has to be an open arc, not a closed ring.** Drawn as a ring
  with the body stroke crossing it, the glyph reads as a prohibition sign — the exact
  opposite of the app's meaning. The macOS original leaves the arc open at the upper right
  so the thigh exits cleanly.
- **The simplification threshold is 32 px inclusive, not exclusive.** With the frame still
  in play at 32 px the wheelchair is about six pixels across and unreadable, which fails the
  acceptance criterion. At and below 32 px the artwork drops the frame, map and contours and
  enlarges the pin to fill the canvas.

The About dialog also gained the app icon, which was noted here as still outstanding from
the port. It needed `app.ico` added as a `<Resource>` so a `pack://` URI can reach it;
`<ApplicationIcon>` alone only embeds it in the executable.

### Verified

Rendered and compared side by side against `icon_256x256.png` from the macOS asset catalogue
at 256, 150, 48, 32, 24 and 16 px. The wheelchair is legible down to 24 px and the pin
silhouette still reads at 16. `build/Package/Images/` holds 45 files and every
`*_altform-unplated*` asset has a fully transparent corner pixel.

`Build-Packages.ps1 -Channel Direct -Architectures x64 -SkipSign` packs cleanly with no
`makepri` warnings, producing an 81.7 MB `.msix`, a matching `.msixbundle` and the
`.appinstaller` feed.

---

## 4. Boundary search resolves ambiguous names silently

**Area:** UX · **Priority:** low · **Status:** closed

### What this was

`BoundaryDataset` broke ties deterministically — incorporated place over census designated
place, then larger land area, then GEOID — so "Springfield" with no state always resolved to
Springfield, MO. Predictable and stable, which is what a saved `.accmap` needs, but the user
got a boundary they never asked for with no sign that 21 others matched.

### Resolution

`FindCandidates` returns every match in ranked order and `Load` materialises the one the
caller settles on, so the dataset no longer decides on the user's behalf. `MainViewModel`
adds a single match straight to the document and raises `Views/BoundaryPickerWindow` only
when several come back. Cancelling adds nothing and reports no error, because backing out is
not a failure.

Each candidate carries a qualifier built to be the thing that actually tells them apart —
state, Census place kind, and land area, e.g. `Missouri - city, 83 sq mi`.

### Verified

`Springfield` returns 22 candidates and prompts. `Springfield, IL`, `Cook County, Illinois`
and `Ohio` each return exactly one and never open the picker. Candidate order is stable
across calls, so the preselected row does not move. Picking the third candidate loads
Springfield, MA and round-trips through `.accmap` intact.

---

## 2. Bundled Census boundaries; cached and rate-limited geocoding

**Area:** services / licensing · **Priority:** high · **Status:** closed

### What this was

Both network services called the public Nominatim instance directly, once per user action,
with no caching and no rate limiting. The
[usage policy](https://operations.osmfoundation.org/policies/nominatim/) caps traffic at
1 req/s, requires clients to cache, and forbids use as a distributed lookup service — which
is exactly what a Store listing turns a desktop app into. The realistic failure mode was a
silent IP block.

Azure Maps was evaluated as the single-vendor answer and **rejected**: a subscription key
shipped in a Store app is extractable, its Get Polygon response carries the notice *"This
API and any results cannot be used or accessed without Microsoft's express written
permission"* which sits badly against `.accmap` persisting geometry forever, and Gen2
pricing after the 2026-09-15 Gen1 retirement charges two transactions per boundary lookup.
Recorded so it is not re-proposed.

### Resolution

**US-only, with boundaries bundled and geocoding cached.**

Boundary polygons now ship inside the app, built from the U.S. Census Bureau cartographic
boundary files (1:500,000, 2025 vintage) — public domain, so no attribution requirement, no
terms of service, and no constraint on `.accmap` persisting `PolygonRings`. Boundary search
makes **no network request at all** and works offline.

| | Before | After |
|---|---|---|
| Boundary source | Nominatim `polygon_geojson` | bundled Census artifact |
| Boundary network calls | one per search | none |
| Geocode caching | none | disk cache, 90-day TTL, misses cached |
| Nominatim rate limiting | none | 1 req/s |
| Package size | — | +23.1 MB |

Point geocoding still uses Nominatim, now behind that cache and limiter, and remains the
app's only network dependency.

### What shipped

- `build/tools/CensusBoundaryConverter` — reads the shapefiles directly, so no GDAL/ogr2ogr
  on any build machine. 35,920 records, 3.25M points, 23.1 MB, ~4 seconds.
- `build/Convert-CensusBoundaries.ps1` — downloads, converts, writes the committed artifact.
  Run once per Census vintage.
- `Services/BoundaryDataset.cs` — artifact reader and name index.
- `Services/BoundaryService.cs` — now a local lookup. Signature and every error message in
  `MainViewModel` unchanged.
- `Services/GeocodeCache.cs`, `Services/RateLimiter.cs`, and `GeocodingService` wired to use
  them.
- About dialog gained a Map Data block: Census (public domain) and OpenStreetMap (ODbL).
- `docs/BOUNDARY-DATA.md`.

### Verified

Spot checks over the real artifact: a city, a county by both "Cook County" and "Cook", a
state by name and by abbreviation, multi-part coastal cities (Seattle, Key West), "Saint
Louis" resolving to Census's "St. Louis", "Kansas City" *not* being mangled by the
type-word stripper, a Louisiana parish, an Alaska borough, a Puerto Rico municipality, and
Washington D.C. Non-US queries, gibberish and type mismatches correctly return nothing.
Washington State's geometry lands in the right envelope. Cache round-trips hits, misses and
reopens; the limiter serialises concurrent callers; a boundary survives an `.accmap`
save/load intact.

### Deliberately not done

Two things were carved out rather than crammed in — see §3 (tiles) and §4 (ambiguity).

---

## 3. Map tiles used OSM and Esri endpoints with no licence agreement

**Area:** services / licensing · **Priority:** high · **Status:** closed

### What this was

`Assets/Map/map.js` drew its base map from OpenStreetMap's own tile servers, whose
[tile usage policy](https://operations.osmfoundation.org/policies/tiles/) forbids
distributed app use exactly as the Nominatim policy does, and took its imagery and label
layers from two Esri ArcGIS endpoints with no licence agreement in place at all.

### Resolution

Both halves are now on sources whose terms permit desktop-app distribution, and neither
needs a key:

| | Was | Now |
|---|---|---|
| Standard | OSM tile servers | [OpenFreeMap](https://openfreemap.org) vector tiles, `liberty` style |
| Satellite | Esri `World_Imagery` (unlicensed) | USGS `USGSImageryOnly` |
| Hybrid | Esri imagery + Esri labels overlay | USGS `USGSImageryTopo`, one layer |

OpenFreeMap serves OpenStreetMap vector tiles with no API key, no registration and no
request limit, and can be self-hosted if that ever becomes necessary. The USGS layers are
public domain US Government work — no key, no terms, US coverage only, which matches the
rest of the app. Hybrid is now a single request per tile because `USGSImageryTopo` has the
labels composited in.

**This required migrating the map engine from Leaflet to MapLibre GL**, because OpenFreeMap
serves vector tiles rather than raster. See `docs/MAP-BRIDGE.md`.

### What the migration touched

Nothing outside `Assets/Map/`, plus one comment and one workaround in `MapControl.xaml.cs`.
The host bridge contract — every inbound message type, every outbound event, the `[lon,
lat]` ring order — is unchanged, which is what kept `MainViewModel` and the wire JSON
completely still.

Four things were not obvious going in and are worth keeping written down:

- **MapLibre GL 6 is ESM-only with no default export.** There is no UMD bundle to drop in
  behind a `<script>` tag; `map.js` is a module and imports the namespace.
- **Windows registers `.mjs` as `text/plain`** (verified on this machine), and Chromium
  *strictly* refuses to execute a module script served as anything but JavaScript. The map
  failed silently with an empty surface and no error. `MapControl` now serves `.mjs` itself
  with the right `Content-Type` rather than trusting the registry, because that registry
  entry is equally likely to be wrong on a user's machine.
- **`circle-radius` in MapLibre is pixels**, so the zone rings — fixed ground distances —
  are GeoJSON polygons approximating circles, not circle layers.
- **`setStyle()` discards every source and layer**, so switching map type has to rebuild the
  overlays. They are recreated on each `style.load` and the JS-side state is pushed back in.
  DOM markers are not part of the style and survive on their own.

A capture-phase error handler now writes JS failures into the map surface. It was added to
debug the MIME problem and kept: a blank map with no explanation is the one failure mode
this component cannot report for itself.

### Verified

Driven in the running app through UI Automation, with screenshots at each step:

- OpenFreeMap vector tiles render, with "OpenFreeMap © OpenMapTiles Data from OpenStreetMap"
  attribution.
- A city boundary search draws the correct polygon — Palo Alto including its southwestern
  foothills panhandle.
- Switching Standard → Satellite → Hybrid → Standard swaps the base map correctly, the
  attribution follows, and **the boundary, all four zone rings and the placed marker survive
  every swap**.
- Zone rings render as concentric circles at the right relative radii on both vector and
  raster base maps.

### Not covered

OpenFreeMap's public instance is a free service with no SLA. Self-hosting is available and
documented if that ever becomes a concern; nothing in the app would change but the style
URL.
