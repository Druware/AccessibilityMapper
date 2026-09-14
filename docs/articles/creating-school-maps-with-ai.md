# Using AI Tools to Build School Accessibility Maps (.accmap) from Public Addresses

If you're doing advocacy for safer routes to school — sidewalks, bike lanes, crossing
guards — one of the most persuasive things you can hand a school board or city council is
a single map showing every school in your city or county, with walking, biking, and
"safe routes" distance rings drawn around each one. Accessibility Mapper is built for
exactly this. This article walks a non-developer through the whole pipeline: finding real
public school addresses, cleaning the list with an AI assistant (without letting it
invent anything), and turning that list into a finished `.accmap` map — including the
easy path of having an AI coding agent build the file for you.

None of this requires you to write code. It does require you to be a little skeptical of
AI output at one specific step (address/coordinate generation), which this guide flags
clearly.

## 1. What you'll build, and what an `.accmap` file actually is

Accessibility Mapper's whole job is to place "bullseye" markers — one per school, one per
library, one per anything — and draw four distance rings around each:

- 0.5 mile — walking
- 1.0 mile — "Safe Routes to School"
- 2.0 miles — bicycling
- 3.0 miles — low-speed vehicles (e-bikes, scooters, golf carts)

You can also overlay a city, county, or state boundary so the map reads as "every school
in Fulton County," not just a loose scatter of pins.

A finished map is a `.accmap` file — plain JSON, openable in any text editor, and (this
matters for what follows) the **same file format on macOS and Windows**. A real example
ships with the project: `Samples/Fulton County GA Schools.accmap`, with 201 school markers
and one county boundary. Here's a trimmed excerpt of its actual shape:

```json
{
  "centerLatitude" : 34.12750307776707,
  "centerLongitude" : -84.43521305870654,
  "markers" : [
    {
      "id" : "C45325AF-85F0-59ED-B1FE-B97C787D75B7",
      "label" : "Abbotts Hill Elementary School",
      "latitude" : 34.0562,
      "longitude" : -84.1964
    }
  ],
  "boundaries" : [
    {
      "id" : "...",
      "name" : "Fulton County, Georgia, United States",
      "type" : "county",
      "polygonRings" : [ [ [ -84.55, 34.10 ], [ -84.54, 34.11 ] ] ]
    }
  ]
}
```

Every marker needs an `id` (a UUID), `latitude`, and `longitude`; `label` is optional in
the current apps (a marker with no `label` just shows no name), but always include it
anyway — AccessibilityMapper 1.0.3 and earlier fail to open the whole file if any marker
is missing `label`. Every boundary needs an `id`,
`name`, `type` (exactly `"city"`, `"county"`, or `"state"`, lowercase), and
`polygonRings` — note the coordinate order inside a ring is `[longitude, latitude]`
(GeoJSON order), which is backwards from the marker fields and the easiest thing to get
wrong if you ever hand-edit the file.

Two more fields exist as of the apps' 1.0.4 release, and neither is required: an optional
per-marker `kind` (`"bullseye"`, the default — the accessible-location pin described
above — or `"incident"`, a marker with no distance rings, used for imported crash data;
see Step 5's closing note), and an optional top-level `formatVersion` integer (currently
2, when present). The sample file below predates both and has neither field, which makes
it a "version 1" document — both apps still open it exactly the same way.

You will not need to memorize this schema. It's here so you understand what the AI agent
is producing when we get to Step 5, and so you can sanity-check the result yourself.

## 2. Finding authoritative public school addresses

The single biggest mistake to avoid in this whole project is asking an AI model to *tell
you* where schools are. Language models can produce very confident, very wrong street
addresses and coordinates. Always start from a real, downloaded dataset published by an
official source. A few to know about:

- **NCES Common Core of Data (CCD) / EDGE geocodes** — the U.S. Department of Education's
  National Center for Education Statistics publishes an annual directory of every public
  school in the country, including street address and, in the companion "EDGE" geocode
  files, latitude/longitude already computed for you. This is the best starting point
  precisely because it already has coordinates — you can often skip geocoding entirely.
  Start at `https://nces.ed.gov/ccd/` and look for the current school year's Public
  School Universe / EDGE geocode download.
- **NCES Private School Survey (PSS)** — the equivalent directory for private schools, if
  your map needs to include them. Also from NCES.
- **State department of education school directories** — most states publish their own
  school locator or directory (sometimes as a downloadable CSV, sometimes as a public
  GIS/open-data layer), which can be more current than the federal data mid-year.
- **District websites and open-data portals** — for a single district, the "Schools" or
  "Find a School" page is often the fastest, most current source, and some cities/counties
  run open-data portals with a schools layer already geocoded.

**Cross-check data vintage.** Federal datasets are usually a school year or more behind
(a school that opened or closed this year may not be reflected yet). If your map needs to
be current, compare the federal list against your state or district's current directory
and adjust for recent openings/closings/renamings before treating the list as final.

Download the raw file (CSV/XLSX/GeoJSON) rather than copying addresses by hand — you want
a file you can hand to a tool in the next step, and a paper trail back to an authoritative
source if anyone questions a marker later.

## 3. Using AI tools to gather and clean the list — safely

Once you have a downloaded dataset, an AI assistant (Claude, ChatGPT, etc., in a normal
chat — no coding needed) is genuinely useful for the tedious part: extracting just the
columns you need, normalizing formatting, deduping, and filtering down to your city or
county.

**The rule that matters: only feed the model data you already downloaded. Never ask it to
supply an address or a coordinate from memory.** If a model produces a school name you
don't recognize, or a coordinate with no matching row in your source file, treat it as
hallucinated and remove it. This is the one place in the whole pipeline where AI can
silently corrupt your map with a school that isn't real or is in the wrong place — so the
model's job here is transformation of data you provide, never generation of new data.

A prompt that keeps the model on the rails:

```
I'm attaching a CSV export from the NCES EDGE public school geocode file for [state].
Using only the rows in this file (do not add, invent, or guess any school not present
in the data):

1. Filter to schools where county = "Fulton County" (or city = "Alpharetta", etc.)
2. Output a table with columns: name, street, city, state, zip, level (elementary/
   middle/high), latitude, longitude
3. Drop duplicate rows for the same school (same NCES ID)
4. Flag any row that is missing latitude/longitude so I can geocode it separately
5. Do not fill in any missing field with an assumed or estimated value — leave it blank
   and flag it instead

Show me the flagged/missing rows separately from the clean table.
```

After the model responds, spot-check a handful of rows against the source file yourself
— pick a few schools you recognize and confirm the address and coordinates actually
appear in the original data, not just in the model's output.

## 4. Geocoding: prefer the dataset's own coordinates

If you used the NCES EDGE geocode file, you likely already have latitude/longitude for
every school — use those directly rather than re-geocoding, since they were computed
against an authoritative address-matching pipeline you don't need to duplicate.

For the schools your dataset left un-geocoded (or if your source was address-only, like
some state directories), the two platforms don't geocode addresses the same way, which is
worth knowing if you're choosing a service to match by hand:

- **Windows**: the in-app address/ZIP search (`GeocodingService`) calls **Nominatim**
  (OpenStreetMap's search service) `/search` endpoint, through a 1-request-per-second
  limiter and an on-disk cache (kept 90 days) — Nominatim's usage policy requires clients
  to cache results and to stay at or under one request per second; the app's specific
  90-day retention is its own choice, not something the policy mandates. City/county/state
  *boundaries* on Windows, notably, do **not** hit Nominatim at all — they're resolved
  from a Census Bureau dataset bundled inside the app (more on this in the boundaries
  section below).
- **macOS**: the in-app "go to ZIP or address" field uses Apple's own `CLGeocoder`, not
  Nominatim. macOS does call Nominatim, but only for its separate boundary-search feature
  (fetching a city/county/state polygon), not for the schools list itself.

If you geocode addresses by hand outside the app, Nominatim (used by Windows for point
search, and by both platforms for boundaries) is a reasonable, free choice — but respect
the same policy the app does: identify your tool in a `User-Agent` header and stay at or
under one request per second, with a short pause between calls. Don't fire off 200
requests at once.

## 5. Creating the `.accmap` with an AI coding agent

This is where an AI *coding* agent — Claude Code, or any similar tool that can read and
write files — earns its keep. You don't need any special add-on to do this: give the
agent the schema from Step 1 and point it at the real sample file,
`Samples/Fulton County GA Schools.accmap`, as a reference for the exact format (field
names, required keys, and the `[longitude, latitude]` ring order), and it can produce a
valid `.accmap` from your cleaned list. (If you're working in this project's own
repository, its maintainers also keep a Claude Code skill, `accmap-edit`, that automates
this same process — a convenience for people who already have it, not something you need
to seek out.)

### Option A: direct JSON edit (macOS or Windows)

This is the one to use if you're on Windows, or on macOS but don't want to drive the live
app. Because `.accmap` is the same JSON schema on both platforms, this path works
identically either way.

Example prompt to an AI coding agent:

```
I have a cleaned CSV of Fulton County, GA public schools with name, latitude, longitude
columns (attached). The .accmap format is JSON with top-level keys zipCode,
centerLatitude, centerLongitude, spanLatDelta, spanLonDelta, mapTypeRaw, markers, and
boundaries. Each marker needs id (a UUID), latitude, and longitude; always add a label too
(the school name) — older versions of the app fail to open the file without one. Use
Samples/Fulton County GA Schools.accmap in this repo as a reference for the exact format.

Create a new .accmap file called "Fulton County Schools.accmap" with one marker per row
(label = school name, latitude/longitude from the CSV — do not recompute or guess any
coordinate, use exactly what's in the file). Center the map on Fulton County rather than
leaving the default center. Then add a county boundary for "Fulton County, Georgia".
```

A well-configured agent will, under the hood, do something like this to create the
document and add each marker:

```python
import json, uuid

path = "Fulton County Schools.accmap"

# Every top-level key has an app-side default (missing keys fall back to them — the
# default center is Apple's own Cupertino/Sunnyvale region, not your county), so start
# a new file by setting all of them explicitly rather than relying on the defaults.
doc = {
    "zipCode": "",
    "centerLatitude": 34.0562,   # set to your county's center, not left at the default
    "centerLongitude": -84.2553,
    "spanLatDelta": 0.6,         # wide enough to show the whole county
    "spanLonDelta": 0.6,
    "mapTypeRaw": 0,
    "markers": [],
    "boundaries": [],
}

doc["markers"].append({
    "id": str(uuid.uuid4()).upper(),
    "latitude": 34.0562,
    "longitude": -84.1964,
    "label": "Abbotts Hill Elementary School",
})
# ...repeat for every row in your cleaned CSV...

# "formatVersion" and each marker's "kind" are both optional and left out above; that
# produces a version-1 file of ordinary ("bullseye") markers, which every app version opens.

with open(path, "w") as f:
    json.dump(doc, f, indent=2, sort_keys=True, separators=(',', ' : '))
```

(This is the format the real `Samples/Fulton County GA Schools.accmap` file uses — both
the macOS and Windows apps fall back to those same defaults, Cupertino/Sunnyvale center
included, for any top-level key an older or partial file is missing.)

Then fetch the county boundary and flatten it into `polygonRings`, being careful about the
`[longitude, latitude]` ring order — a `Polygon` response is one list of rings, a
`MultiPolygon` response is a list of polygons that gets flattened into one flat list of
rings:

```python
import json, time, urllib.parse, urllib.request, uuid

path = "Fulton County Schools.accmap"
with open(path) as f:
    doc = json.load(f)

def rings_from_polygon(coords):
    return [[[pt[0], pt[1]] for pt in ring] for ring in coords]

params = urllib.parse.urlencode({
    "q": "Fulton County, Georgia", "format": "geojson",
    "polygon_geojson": "1", "limit": "1",
})
req = urllib.request.Request(
    f"https://nominatim.openstreetmap.org/search?{params}",
    headers={"User-Agent": "accmap-edit-skill/1.0 (you@example.com)"},
)
with urllib.request.urlopen(req) as resp:
    geo = json.load(resp)
time.sleep(1)  # Nominatim: max 1 request/second

feature = geo["features"][0]
name = feature["properties"]["display_name"]
geom = feature["geometry"]

rings = []
if geom["type"] == "Polygon":
    rings = rings_from_polygon(geom["coordinates"])
elif geom["type"] == "MultiPolygon":
    for poly in geom["coordinates"]:
        rings += rings_from_polygon(poly)

doc["boundaries"].append({
    "id": str(uuid.uuid4()).upper(),
    "name": name,
    "type": "county",
    "polygonRings": rings,
})

with open(path, "w") as f:
    json.dump(doc, f, indent=2, sort_keys=True, separators=(',', ' : '))
```

After the agent finishes, always ask it to validate the file — a broken JSON file will
fail to open in the app, with no partial recovery (on Windows the app shows an error
message quoting the underlying exception; on macOS the document simply fails to load) —
so check it yourself too:

```bash
python3 -m json.tool "Fulton County Schools.accmap" > /dev/null && echo "valid JSON"
```

### Option B: drive the live macOS app with AppleScript

If you're on macOS and prefer to watch the map build in front of you (or want the app's
own document/undo handling rather than hand-rolled JSON), Accessibility Mapper exposes a
small AppleScript vocabulary. With a map document already open in the app:

```applescript
-- Navigate the map to a starting ZIP code or address
tell application "Accessibility Mapper" to geocode "30303"

-- Add one marker; returns its UUID
tell application "Accessibility Mapper"
    set newID to add marker at latitude 34.0562 longitude -84.1964 with label "Abbotts Hill Elementary School"
end tell

-- Remove a marker if you added one in error
tell application "Accessibility Mapper" to remove marker "360BB104-B9AC-4F07-B89C-E1A742DA783D"
```

An AI coding agent can loop this `add marker` command over every row of your cleaned CSV,
driving the real running app. Two limits worth knowing up front: there is no scripting
command for boundaries — you still add those either through the direct-JSON recipe above
or through the app's own Toolbox sidebar — and AppleScript only exists on macOS, since
it's an AppKit feature; Windows users use Option A exclusively.

One safety note that applies to both options: **never hand-edit a `.accmap` file that is
currently open in the app with unsaved changes.** The app writes out its entire in-memory
document on every save, so it will silently overwrite whatever you changed on disk.
Close the document first, or have it saved and closed before an agent edits the file.

### Windows and the shared format

To be direct about it: Windows does not have an AppleScript equivalent, and its "boundary
search" feature doesn't call the same web service macOS does — it looks up city/county/
state polygons from a Census Bureau dataset bundled inside the Windows app itself (offline,
no rate limit, U.S. and territories only). But the *document* the two apps read and write —
field names, required keys, the lowercase `"city"/"county"/"state"` boundary type, the
`[longitude, latitude]` ring order — is identical on both platforms. A `.accmap` file built
by an agent following Option A opens the same way in either app.

### Combining maps, and adding real fatality data

If you built your school map and a separately-built boundary or marker set as two
different files, you don't need to merge them by hand: File ▸ Import Map (macOS ⇧⌘I,
Windows Ctrl+I) merges another `.accmap` file's markers and boundaries into the one
that's open, skipping anything already present by id (or, for boundaries, a matching
name and type). And if your advocacy case would benefit from showing where pedestrians
and cyclists have actually been killed nearby,
[`scripts/fars/fars_to_accmap.py`](mapping-traffic-fatalities-with-fars.md) in this
repository adds NHTSA FARS fatality markers to a `.accmap` file straight from the
command line; in Accessibility Mapper 1.0.4 and later those show as triangles with no
distance rings, and can be hidden on demand with the toolbox's Show Incidents toggle.

## 6. Verifying the result

Don't ship a map you haven't looked at. Open the finished `.accmap` file in Accessibility
Mapper and:

- Confirm the boundary polygon roughly matches the county/city outline you expect, and
  that markers fall inside (or sensibly near) it. A marker sitting well outside the
  boundary, or in the ocean/another state, usually means a swapped latitude/longitude or a
  bad geocode.
- Spot-check a sample of schools — pick 5–10 you know, click through, and confirm the pin
  lands on the actual campus, not a district office or a PO box.
- Fix outliers by re-checking the source row: is the address a PO box (see pitfalls
  below), a multi-campus school split across two lots, or genuinely a bad geocode? Correct
  the coordinate and re-save, or ask your coding agent to fix that one marker.

## 7. Tips and pitfalls

- **PO boxes vs. physical addresses.** Some school directories list a mailing address
  (a district PO box) instead of the school's physical location. Geocoding a PO box puts
  your marker at the post office, not the school. When a marker looks obviously wrong,
  check whether the source address is a PO box and look for the physical street address
  instead.
- **Multi-campus schools.** Some schools operate across more than one building or site
  (a shared middle/high school campus, a temporary annex during construction). Decide up
  front whether you want one marker per legal school or one per physical building, and
  apply that consistently across your map.
- **Closed or renamed schools.** Federal datasets lag; a school that closed or merged this
  year may still appear. Cross-check against your district or state's current list before
  finalizing (see Step 2).
- **Privacy.** Only map public school locations and other public infrastructure. Never use
  this workflow — or this app — to plot the addresses of individual students, families, or
  any other private residence. School addresses are public information; a home is not.
- **Keep it current.** School directories change yearly (new schools, closures, boundary
  changes). If this map will be used for ongoing advocacy, plan to regenerate it against a
  fresh dataset annually rather than treating one export as permanent.

## A note on support

Accessibility Mapper is donation-supported. If this workflow helped your advocacy group,
school district, or city put together a map that made the case for safer routes to school,
consider supporting continued development through
[Two Wheel Junction](https://www.twowheeljunction.com).
