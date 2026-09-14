# Mapping Pedestrian and Bicyclist Fatalities on Your `.accmap` with FARS Data

If you're making the case for a crosswalk, a road diet, or a protected bike lane, the most
persuasive thing you can put in front of a city council isn't a survey — it's a map
showing exactly where people have already died trying to walk or bike through the
intersection you're asking them to fix. `scripts/fars/fars_to_accmap.py` in this
repository builds that map for you: it downloads NHTSA's national fatal-crash data, filters
it to your county, and adds one marker per crash to an `.accmap` file. This article walks
a non-developer through the whole process, using real output from real runs against real
government data — nothing here is simulated.

None of this requires you to write code, only to run one command a few times from a
terminal, with the exact values shown below.

## 1. What FARS is

FARS — the Fatality Analysis Reporting System — is the U.S. Department of Transportation's
national census of fatal traffic crashes, covering all 50 states and the District of
Columbia. Two things matter about it before you start:

- **It counts fatal crashes only.** A crash only appears in FARS if someone died in it.
  There is no equivalent nationwide file of *non-fatal* pedestrian or bicyclist injuries —
  see the caveats in Step 7 for what that means for how you present a map built from it.
- **It's published with a lag.** NHTSA finalizes each year's data roughly a year or more
  after the fact, so the most recent one or two calendar years usually aren't published
  yet. The script handles this automatically: when you ask for a year NHTSA hasn't
  released, it gets an HTTP 404 from NHTSA's server, prints a warning, and moves on to the
  years that do exist rather than failing the whole run.

This article doesn't link to NHTSA's FARS page directly; search "NHTSA Fatality Analysis
Reporting System" if you want the agency's own description of the program. The script
itself downloads NHTSA's published national data files directly, at a stable URL.

## 2. What the script does — and deliberately doesn't do

Run with `--help` for the full reference; here's what matters before your first run:

- **One marker per crash**, not per victim. If a single crash killed two pedestrians, that's
  one marker labeled `2 pedestrian fatalities`, not two markers.
- **Who counts.** A person counts as a pedestrian fatality when FARS' `PER_TYP` (person
  type) code is `5`, and as a bicyclist fatality when it's `6` or `7` ("Bicyclist" and
  "Other Cyclist"/"Other Pedalcyclist"). `--mode pedestrian` counts only `5`, `--mode
  bicycle` counts `6` and `7`, and the default, `--mode both`, counts all three.
- **`PER_TYP` 7 is counted as a bicyclist in every year.** NHTSA renamed this code from
  "Other Cyclist" in the 2021 file to "Other Pedalcyclist" in 2022's, but it's the same
  fixed code, `7`, in the `bicycle`/`both` set both years — worth knowing only if you're
  cross-checking a label against NHTSA's own documentation for a given year.
- **Personal conveyances are excluded, in every mode.** People on wheelchairs, motorized
  scooters, or skateboards are coded `11`–`13` in the 2021 file and `8` in 2022's; none of
  those codes appear in the script's pedestrian (`5`) or bicyclist (`6`, `7`) sets, so
  they're simply never matched — not filtered out by any special-case logic.
- **Crashes without usable coordinates are skipped**, with a warning naming the crash, not
  silently dropped — NHTSA uses sentinel values like `99.9999`/`999.9999` for "not
  reported," which aren't real locations, and the script filters those out before they'd
  otherwise show up as a marker.
- **It filters by county, not city.** FARS' `CITY` field is a General Services
  Administration location code, not a Census city code, and there's no reliable public
  table to translate it — so the script only accepts a state and a *county* FIPS code.
  If you want just one city inside a bigger county, use `--clip-boundary` or `--clip-bbox`
  (Step 5) on top of the county filter, rather than looking for a `--city` flag that
  doesn't exist.
- **Re-running never duplicates or overwrites a marker.** Every fatality marker gets a
  fixed ID derived from the state, year, and case number, so importing the same
  county/year range twice adds zero markers the second time — proven in Step 5. Markers
  already in the map are also never edited: if you first import with `--mode pedestrian`
  and later re-run the same range with `--mode both`, the pedestrian markers you already
  have keep their original labels; only the newly-qualifying crashes get added.

## 3. Requirements

Everything the script imports — `json`, `csv`, `zipfile`, `urllib.request`, `argparse`,
and so on — is part of Python's standard library; there's nothing to `pip install`. The
script's shebang (`#!/usr/bin/env python3`) just asks for "some Python 3," and this
article's examples were all run under Python 3.9. On macOS, `python3` is provided by
Apple's Command Line Tools (`xcode-select --install`) or by a separate python.org or
Homebrew install; either works.

You'll need an internet connection the first time you request a given year: each year's
national archive is about 35 MB, downloaded once and cached afterward (`--refresh` forces
a fresh download). The cache defaults to a per-OS location — `~/Library/Caches/accmap-fars`
on macOS, and (on Linux or Windows) either `$XDG_CACHE_HOME/accmap-fars` or
`~/.cache/accmap-fars` in your user profile — or you can point `--cache-dir` at a folder of
your choosing, which is what this article's examples do.

## 4. Finding your state and county codes

`--state` takes either a USPS abbreviation (`GA`) or a 2-digit state FIPS code (`13`) —
either works. `--county` needs the 3-digit *county* FIPS code on its own, not the combined
5-digit code you'll see in some references (Fulton County, Georgia's full FIPS is `13121`;
you'd pass `--county 121`).

If you don't already know your county's code, the Census Bureau publishes the reference
files: see its
[ANSI codes for counties and county-equivalent entities](https://www.census.gov/library/reference/code-lists/ansi.html)
page, which lists the current county FIPS code for every U.S. county by state.

## 5. Step-by-step examples

All of the output below is real — pasted from actual runs against the real 2021 and 2022
NHTSA archives, filtered to Fulton County, Georgia (state `GA`, county `121`).

### Preview with `--dry-run`

Before writing anything, see what the script would add:

```
$ python3 scripts/fars/fars_to_accmap.py --state GA --county 121 --from-year 2021 \
    --output "Fulton County Fatalities.accmap" --dry-run
2021: 47 crashes with pedestrian/bicyclist fatalities (46 pedestrian, 1 bicyclist), 0 outside the clip area, 0 skipped without a usable coordinate
47 markers to add, 0 already in the map
  + Pedestrian fatality — Jan 2, 2021 — I-75/85, Atlanta
  + Pedestrian fatality — Jan 8, 2021 — SR-14, Fairburn
  + Pedestrian fatality — Jan 13, 2021 — SR-70, Atlanta
  + Pedestrian fatality — Jan 22, 2021 — SR-70
  + Pedestrian fatality — Mar 1, 2021 — SR-400, Sandy Springs
  ... (40 more lines, one per crash) ...
  + Pedestrian fatality — Nov 3, 2021 — SR-9/PEACHTREE RD, Atlanta
  + Pedestrian fatality — Dec 16, 2021 — SR-400, Sandy Springs
dry run: nothing written
```

`--dry-run` performs the real download and filter, it just doesn't write the output file —
safe to run as many times as you like while you're deciding on a year range or a clip.

### Adding fatalities to an existing map

Make a working copy of your school or advocacy map first — never edit `Samples/*.accmap`
directly — then point `--input` and `--output` at it (they can be the same file):

```
$ cp "Samples/Fulton County GA Schools.accmap" "Fulton County GA Schools.accmap"
$ python3 scripts/fars/fars_to_accmap.py --state GA --county 121 \
    --from-year 2021 --to-year 2022 \
    --input "Fulton County GA Schools.accmap" \
    --output "Fulton County GA Schools.accmap"
2021: 47 crashes with pedestrian/bicyclist fatalities (46 pedestrian, 1 bicyclist), 0 outside the clip area, 0 skipped without a usable coordinate
2022: 52 crashes with pedestrian/bicyclist fatalities (52 pedestrian, 0 bicyclist), 0 outside the clip area, 0 skipped without a usable coordinate
99 markers to add, 0 already in the map
wrote Fulton County GA Schools.accmap
```

The file's 201 school markers are untouched; it now also has 99 new fatality markers (47
from 2021, 52 from 2022), and its `formatVersion` was bumped to `2` — the version that
added marker kinds — since it didn't have one already.

### Re-running adds nothing

Run the exact same command again, and every marker's ID already matches one in the file,
so nothing new is written:

```
$ python3 scripts/fars/fars_to_accmap.py --state GA --county 121 \
    --from-year 2021 --to-year 2022 \
    --input "Fulton County GA Schools.accmap" \
    --output "Fulton County GA Schools.accmap"
2021: 47 crashes with pedestrian/bicyclist fatalities (46 pedestrian, 1 bicyclist), 0 outside the clip area, 0 skipped without a usable coordinate
2022: 52 crashes with pedestrian/bicyclist fatalities (52 pedestrian, 0 bicyclist), 0 outside the clip area, 0 skipped without a usable coordinate
0 markers to add, 99 already in the map
nothing to add; output not written
```

That makes it safe to re-run this periodically (say, once a year, when NHTSA finalizes the
next year's data) without worrying about ending up with duplicate pins.

### Clipping to a boundary already on your map

If your `.accmap` already has a county or city boundary added (Step 5 of the schools
article covers adding one), `--clip-boundary` keeps only crashes inside it, matched by the
boundary's exact name. This example starts from a fresh copy of the sample map, not the
one already filled with fatalities above, so the clip's effect is visible on the first
import:

```
$ cp "Samples/Fulton County GA Schools.accmap" "Fulton County GA Schools.accmap"
$ python3 scripts/fars/fars_to_accmap.py --state GA --county 121 --from-year 2021 \
    --input "Fulton County GA Schools.accmap" \
    --output "Fulton County GA Schools.accmap" \
    --clip-boundary "Fulton County, Georgia, United States"
2021: 47 crashes with pedestrian/bicyclist fatalities (46 pedestrian, 1 bicyclist), 0 outside the clip area, 0 skipped without a usable coordinate
47 markers to add, 0 already in the map
wrote Fulton County GA Schools.accmap
```

Here "0 outside the clip area" because the whole county filter and the boundary are the
same shape; `--clip-boundary` earns its keep when your `--county` is bigger than the area
you actually want to show, e.g. filtering a county-wide pull down to just one city's
boundary polygon. Note that clipping only matters on the crashes being newly added — if
you run this against a map that already has all of that year's fatalities in it (like the
one from the previous two examples), every crash is already present and the clip has
nothing left to filter: `0 markers to add, 47 already in the map` / `nothing to add;
output not written`.

### Clipping to a bounding box

`--clip-bbox` takes `minLon,minLat,maxLon,maxLat` and needs an `=` sign when any value is
negative (a leading `-` would otherwise be read as another flag):

```
$ python3 scripts/fars/fars_to_accmap.py --state GA --county 121 --from-year 2021 \
    --output "Downtown Atlanta Fatalities.accmap" \
    --clip-bbox=-84.40,33.76,-84.38,33.78
2021: 47 crashes with pedestrian/bicyclist fatalities (46 pedestrian, 1 bicyclist), 46 outside the clip area, 0 skipped without a usable coordinate
1 markers to add, 0 already in the map
wrote Downtown Atlanta Fatalities.accmap
```

A small box around downtown Atlanta keeps exactly the one 2021 crash that falls inside it.

### Starting a brand-new map

Leave off `--input` entirely (or point it at a file that doesn't exist yet) and the script
creates a new `.accmap` from scratch, centered and zoomed to fit the markers it just added
— not left at the app's built-in Cupertino/Sunnyvale default:

```
$ python3 scripts/fars/fars_to_accmap.py --state GA --county 121 --from-year 2021 \
    --output "My Map.accmap"
2021: 47 crashes with pedestrian/bicyclist fatalities (46 pedestrian, 1 bicyclist), 0 outside the clip area, 0 skipped without a usable coordinate
47 markers to add, 0 already in the map
wrote My Map.accmap
```

Opening `My Map.accmap` afterward, `centerLatitude`/`centerLongitude` are `33.8047`/
`-84.3651` and the span is sized to comfortably fit all 47 points — right over Fulton
County, not California.

### `--mode pedestrian` vs. `--mode bicycle`

Splitting the same year by mode shows the split in Fulton County for 2021 plainly:

```
$ python3 scripts/fars/fars_to_accmap.py --state GA --county 121 --from-year 2021 \
    --mode pedestrian --output "Pedestrian Only.accmap" --dry-run
2021: 46 crashes with pedestrian fatalities (46 pedestrian, 0 bicyclist), 0 outside the clip area, 0 skipped without a usable coordinate
46 markers to add, 0 already in the map

$ python3 scripts/fars/fars_to_accmap.py --state GA --county 121 --from-year 2021 \
    --mode bicycle --output "Bicycle Only.accmap" --dry-run
2021: 1 crashes with bicyclist fatalities (0 pedestrian, 1 bicyclist), 0 outside the clip area, 0 skipped without a usable coordinate
1 markers to add, 0 already in the map
  + Bicyclist fatality — Sep 16, 2021 — SR-3 METROPOLITIAN PKWY, Atlanta
dry run: nothing written
```

46 pedestrian fatalities and 1 bicyclist fatality add up to the 47 that `--mode both`
(the default) reports.

### Exit codes

The script exits `0` on success — including the legitimate case of zero fatalities found
for a quiet county-year, which is not an error — `1` if a year's data failed to download
or the output file couldn't be written, and `2` for a problem with your arguments or
`--input` file, checked and reported before any download starts. If you're scripting
around this tool (say, a scheduled yearly refresh), check the exit code rather than
scraping stdout.

## 6. What you'll see in the app

Fatality markers are written with `"kind": "incident"`. What that looks like depends on
your Accessibility Mapper version:

- **1.0.4 and later**: an incident draws as a red-outlined, solid black triangle, with
  **no distance rings** — the four walk/bike/Safe-Routes rings are drawn only for ordinary
  ("bullseye") markers like schools. The Toolbox's Radius Legend has a fifth row, **Show
  Incidents**, on by default, that hides or shows every incident marker on the map without
  removing it from the Markers list or the file. If a marker's label is ever left blank,
  its default title is "Incident" (versus "Accessible Location" for a bullseye) — though
  every marker this script creates always has a descriptive label, so you won't see that
  default in practice. Opening any map that has markers — including one this script just
  wrote — always fits the view to show all of them, with a 15% margin.
- **1.0.3 and earlier**: these versions predate the `kind` field entirely. They draw every
  marker — fatality or otherwise — as an ordinary bullseye with the same four distance
  rings, since they have no concept of an incident glyph.

If you generated the fatality markers into their own separate file (as in the `--clip-bbox`
and new-map examples above) rather than merging directly into your working map, use
**File ▸ Import Map** (macOS ⇧⌘I, Windows Ctrl+I) to bring them into the map you actually
present — it merges markers and boundaries, skipping anything already present by ID, the
same rule this script itself uses.

## 7. Caveats and responsible use

- **Coordinates come from police crash reports**, not a survey-grade GPS fix. Expect a
  marker to land close to, but not always exactly on, the precise spot of the crash.
- **FARS counts fatalities only.** A street with no markers on your map might genuinely be
  safe, or it might simply not have had a fatal crash yet despite many close calls or
  serious injuries — this data cannot tell you which. Don't present an empty map as proof
  of safety.
- **There's a reporting lag.** The most recent year or two of crashes usually aren't in
  FARS yet; a corridor that's had a fatality this year may not show it until next year's
  file is published.
- **Labels are deliberately anonymous.** A marker's label states only the count, type,
  date, and roadway/city of a crash — never a name, age, or any other detail about the
  people involved.
- **These are real people who died**, not abstract data points. Presenting this map to a
  council or a community meeting is legitimate, powerful advocacy — do it with the same
  care and context you'd want if the crash were near your own home.
- **Re-running with a different `--mode` doesn't relabel markers you already imported.**
  If you first pull in pedestrian-only data and later want bicyclist fatalities too,
  re-run with `--mode both` (or `bicycle`) — your existing pedestrian markers keep their
  original labels, and only the newly-qualifying crashes are added.

## A note on support

Accessibility Mapper is donation-supported. If this data helped your advocacy group,
neighborhood association, or city staff make the case for a safer street, consider
supporting continued development through
[Two Wheel Junction](https://www.twowheeljunction.com).
