#!/usr/bin/env python3
"""
fars_to_accmap.py — add NHTSA FARS pedestrian and bicyclist fatalities to an .accmap map.

WHAT IT DOES
    Downloads the national FARS CSV archive for each requested year, keeps the
    crashes in one US county, and adds one marker per crash in which at least
    one pedestrian or bicyclist was killed. The markers can be clipped to a
    boundary already stored in the map, or to a bounding box.

DATA
    Public NHTSA Fatality Analysis Reporting System (FARS) data:
        https://static.nhtsa.gov/nhtsa/downloads/FARS/<year>/National/
    NHTSA finalizes each year's file with a lag of roughly a year or more, so
    the most recent years are usually not published yet. A year that is not
    published (HTTP 404) is skipped with a warning. Each archive is about
    35 MB and is cached in --cache-dir, so later runs do not download it again
    (use --refresh to force a new download).

    A person counts when INJ_SEV is 4 (fatal) and PER_TYP is 5 (Pedestrian)
    for --mode pedestrian, 6 or 7 (Bicyclist, Other Cyclist) for --mode
    bicycle, or any of those for --mode both. People on personal conveyances
    (skateboards, scooters, wheelchairs) are not included.

MARKERS
    One marker per crash, labelled with the counted fatalities, the date, the
    roadway and the city, for example:
        Pedestrian fatality — Jan 2, 2021 — I-75/85, Atlanta
        2 pedestrian fatalities — Mar 2, 2021 — CR-237
    Fatality markers are written with "kind": "incident". Accessibility Mapper
    1.0.4 and later draws an incident as a red-outlined black triangle with no
    distance rings, and can hide incidents with its Show Incidents toggle.
    Older versions ignore the kind and draw them as ordinary bullseye markers.

    Marker IDs are derived from the state, year and case number, so re-running
    the same import adds only crashes that are not already in the map. Markers
    already in the map are never changed, so re-running with a different --mode
    does not relabel them.

MERGING
    --input and --output may be the same file. Existing markers, boundaries,
    ZIP code, map center, span and map type are kept as they are. When --input
    is omitted, or names the --output file that does not exist yet, a new map
    is created and centered on the added markers. Crash rows without a usable
    coordinate are skipped with a warning. The output is written only when at
    least one marker is added.

    Every file written carries "formatVersion": 2, the document version that
    introduced marker kinds, or the --input file's higher version, which is
    never lowered. When merging, that is the only top-level value changed;
    markers already in the map are not given a kind (a marker without one is
    a bullseye).

CLIPPING
    --clip-boundary NAME keeps crashes inside the boundary with that exact name
    in --input. Every ring of the boundary is tested with the even-odd rule, so
    holes are excluded and every part of a multi-part boundary is included.
    Add --clip-boundary-type when several boundaries share the name.

    --clip-bbox minLon,minLat,maxLon,maxLat keeps crashes inside a box. Write it
    with "=" (--clip-bbox=-84.5,33.6,-84.2,33.9), because a value that starts
    with "-" is otherwise read as an option.

EXIT STATUS
    0  success, including when no fatalities are found
    1  a year failed to download or read, or the output could not be written
    2  invalid arguments or an unreadable --input

EXAMPLE
    scripts/fars/fars_to_accmap.py --state GA --county 121 \\
        --from-year 2019 --to-year 2023 --mode both \\
        --input  "Samples/Fulton County GA Schools.accmap" \\
        --output "Fulton County GA Schools with FARS.accmap" \\
        --clip-boundary "Fulton County, Georgia, United States"
"""

from __future__ import annotations

import argparse
import csv
import datetime
import http.client
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import zipfile
from collections import Counter
from dataclasses import dataclass
from typing import Callable, List, Optional, Tuple

FARS_URL = "https://static.nhtsa.gov/nhtsa/downloads/FARS/{year}/National/FARS{year}NationalCSV.zip"
FIRST_YEAR = 1975
RETRY_DELAY_SECONDS = 2.0

# Fixed namespace for marker IDs. Never change it: every marker imported earlier
# would get a new ID and be added to the map a second time.
FARS_NAMESPACE = uuid.UUID("05AA96AB-3B88-4708-BDC0-DD9DE2148290")

# person.csv PER_TYP codes, checked against the PER_TYPNAME column of the real
# 2021 and 2022 national files: 5 "Pedestrian", 6 "Bicyclist", 7 "Other Cyclist"
# (2021) / "Other Pedalcyclist" (2022). Personal conveyance (8 from 2022,
# 11-13 in 2021) is deliberately left out.
PEDESTRIAN = 5
MODES = {
    "pedestrian": frozenset({5}),
    "bicycle": frozenset({6, 7}),
    "both": frozenset({5, 6, 7}),
}
MODE_WORDS = {"pedestrian": "pedestrian", "bicycle": "bicyclist", "both": "pedestrian/bicyclist"}
FATAL_INJURY = 4  # INJ_SEV "Fatal Injury (K)"

# LATITUDE/LONGITUD placeholders ("not applicable", "not reported", "unknown");
# all three pairs occur in the 2021 and 2022 accident.csv.
PLACEHOLDER_LATITUDES = frozenset({77.7777, 88.8888, 99.9999})
PLACEHOLDER_LONGITUDES = frozenset({777.7777, 888.8888, 999.9999})

# CITY codes without a real city name: 0 NOT APPLICABLE, 9898 Not Reported,
# 9997 Other, 9999 Unknown.
NO_CITY_CODES = frozenset({0, 9898, 9997, 9999})

# The 50 states and DC, the jurisdictions present in the FARS national files.
STATE_FIPS = {
    "AL": 1, "AK": 2, "AZ": 4, "AR": 5, "CA": 6, "CO": 8, "CT": 9, "DE": 10,
    "DC": 11, "FL": 12, "GA": 13, "HI": 15, "ID": 16, "IL": 17, "IN": 18,
    "IA": 19, "KS": 20, "KY": 21, "LA": 22, "ME": 23, "MD": 24, "MA": 25,
    "MI": 26, "MN": 27, "MS": 28, "MO": 29, "MT": 30, "NE": 31, "NV": 32,
    "NH": 33, "NJ": 34, "NM": 35, "NY": 36, "NC": 37, "ND": 38, "OH": 39,
    "OK": 40, "OR": 41, "PA": 42, "RI": 44, "SC": 45, "SD": 46, "TN": 47,
    "TX": 48, "UT": 49, "VT": 50, "VA": 51, "WA": 53, "WV": 54, "WI": 55,
    "WY": 56,
}

MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

# .accmap formatVersion written by this script; version 2 added marker "kind".
FORMAT_VERSION = 2

MIN_NEW_SPAN = 0.02
SPAN_MARGIN = 1.15

Fetch = Callable[[str, io.BufferedIOBase], None]
Warn = Callable[[str], None]


class UsageError(Exception):
    """Invalid arguments or input; reported before any download."""


class YearNotPublished(Exception):
    pass


class DownloadFailed(Exception):
    pass


@dataclass(frozen=True)
class Crash:
    state: int
    year: int
    st_case: int
    month: int
    day: int
    latitude: float
    longitude: float
    roadway: str
    city: str
    pedestrians: int
    bicyclists: int


# ---------------------------------------------------------------------------
# Markers
# ---------------------------------------------------------------------------

def marker_id(state: int, year: int, st_case: int) -> str:
    # One ID per crash. It does not depend on --mode, so a crash imported once
    # keeps its first label even if the import is re-run with another --mode.
    return str(uuid.uuid5(FARS_NAMESPACE, f"fars:{state}:{year}:{st_case}")).upper()


def fatality_phrase(pedestrians: int, bicyclists: int) -> str:
    if pedestrians and bicyclists:
        return "Pedestrian and bicyclist fatalities"
    kind, count = ("pedestrian", pedestrians) if pedestrians else ("bicyclist", bicyclists)
    return f"{kind.capitalize()} fatality" if count == 1 else f"{count} {kind} fatalities"


def format_date(year: int, month: int, day: int) -> str:
    if not 1 <= month <= 12:
        return str(year)
    if not 1 <= day <= 31:
        return f"{MONTHS[month - 1]} {year}"
    return f"{MONTHS[month - 1]} {day}, {year}"


def build_label(crash: Crash) -> str:
    parts = [fatality_phrase(crash.pedestrians, crash.bicyclists),
             format_date(crash.year, crash.month, crash.day)]
    location = ", ".join(p for p in (crash.roadway, crash.city) if p)
    if location:
        parts.append(location)
    return " — ".join(parts)


def build_marker(crash: Crash) -> dict:
    return {
        "id": marker_id(crash.state, crash.year, crash.st_case),
        "latitude": crash.latitude,
        "longitude": crash.longitude,
        "label": build_label(crash),
        "kind": "incident",
    }


# ---------------------------------------------------------------------------
# FARS data
# ---------------------------------------------------------------------------

def usable_coordinate(lat_text: str, lon_text: str) -> Optional[Tuple[float, float]]:
    try:
        lat, lon = float(lat_text), float(lon_text)
    except ValueError:
        return None
    if round(lat, 4) in PLACEHOLDER_LATITUDES or round(lon, 4) in PLACEHOLDER_LONGITUDES:
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    return lat, lon


def roadway_name(tway_id: str) -> str:
    name = " ".join(tway_id.split())
    return "" if name.upper() == "UNKNOWN" else name


def city_name(city_code: str, name: str) -> str:
    if int(city_code) in NO_CITY_CODES:
        return ""
    return name.strip().title()


def open_member(archive: zipfile.ZipFile, basename: str) -> io.TextIOWrapper:
    for name in archive.namelist():
        if name.rsplit("/", 1)[-1].lower() == basename:
            return io.TextIOWrapper(archive.open(name), encoding="utf-8-sig", newline="")
    raise KeyError(f"{basename} is missing from the archive")


def find_crashes(zip_file, year: int, state: int, county: int,
                 person_types: frozenset, warn: Warn) -> Tuple[List[Crash], int]:
    """Return the county's crashes with at least one counted fatality, and the
    number of such crashes skipped for lack of a usable coordinate."""
    with zipfile.ZipFile(zip_file) as archive:
        with open_member(archive, "accident.csv") as f:
            accidents = {int(r["ST_CASE"]): r for r in csv.DictReader(f)
                         if int(r["STATE"]) == state and int(r["COUNTY"]) == county}

        pedestrians: Counter = Counter()
        bicyclists: Counter = Counter()
        with open_member(archive, "person.csv") as f:
            for r in csv.DictReader(f):
                if int(r["STATE"]) != state:
                    continue
                case = int(r["ST_CASE"])
                if case not in accidents or int(r["INJ_SEV"]) != FATAL_INJURY:
                    continue
                per_typ = int(r["PER_TYP"])
                if per_typ not in person_types:
                    continue
                if per_typ == PEDESTRIAN:
                    pedestrians[case] += 1
                else:
                    bicyclists[case] += 1

    crashes, skipped = [], 0
    for case in sorted(set(pedestrians) | set(bicyclists)):
        row = accidents[case]
        coordinate = usable_coordinate(row["LATITUDE"], row["LONGITUD"])
        if coordinate is None:
            warn(f"{year}: ST_CASE {case}: no usable coordinate "
                 f"({row['LATITUDE']}, {row['LONGITUD']}), skipping")
            skipped += 1
            continue
        crashes.append(Crash(
            state=state, year=year, st_case=case,
            month=int(row["MONTH"]), day=int(row["DAY"]),
            latitude=coordinate[0], longitude=coordinate[1],
            roadway=roadway_name(row["TWAY_ID"]),
            city=city_name(row["CITY"], row["CITYNAME"]),
            pedestrians=pedestrians[case], bicyclists=bicyclists[case],
        ))
    return crashes, skipped


# ---------------------------------------------------------------------------
# Download cache
# ---------------------------------------------------------------------------

def default_cache_dir() -> str:
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Caches/accmap-fars")
    xdg = os.environ.get("XDG_CACHE_HOME")
    if xdg:
        return os.path.join(xdg, "accmap-fars")
    return os.path.expanduser("~/.cache/accmap-fars")


def http_fetch(url: str, out: io.BufferedIOBase) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "accmap-fars"})
    with urllib.request.urlopen(request, timeout=120) as response:
        shutil.copyfileobj(response, out, 1 << 20)


def cached_zip(year: int, cache_dir: str, refresh: bool, fetch: Fetch, warn: Warn) -> str:
    path = os.path.join(cache_dir, f"FARS{year}NationalCSV.zip")
    if os.path.exists(path) and not refresh:
        return path
    os.makedirs(cache_dir, exist_ok=True)
    url = FARS_URL.format(year=year)
    warn(f"{year}: downloading {url}")
    error: Exception = DownloadFailed("no attempt made")
    for attempt in (1, 2):
        # Download beside the cache entry and rename into place, so an
        # interrupted download never leaves a partial zip in the cache.
        fd, tmp = tempfile.mkstemp(dir=cache_dir, prefix=f".FARS{year}-", suffix=".part")
        try:
            with os.fdopen(fd, "wb") as out:
                fetch(url, out)
            if not zipfile.is_zipfile(tmp):
                raise DownloadFailed("the downloaded file is not a zip archive")
            os.replace(tmp, path)
            return path
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise YearNotPublished() from None
            error = e
        except (OSError, http.client.HTTPException, DownloadFailed) as e:
            error = e
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
        if attempt == 1:
            warn(f"{year}: download failed ({error}), retrying")
            time.sleep(RETRY_DELAY_SECONDS)
    raise DownloadFailed(f"download failed after retry: {error}")


# ---------------------------------------------------------------------------
# Clipping
# ---------------------------------------------------------------------------

def point_in_rings(lon: float, lat: float, rings) -> bool:
    """Even-odd rule over every ring: inside when the total number of ring
    edges crossed by a ray from the point is odd. Rings are [lon, lat] pairs."""
    inside = False
    for ring in rings:
        j = len(ring) - 1
        for i in range(len(ring)):
            xi, yi = ring[i][0], ring[i][1]
            xj, yj = ring[j][0], ring[j][1]
            if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
                inside = not inside
            j = i
    return inside


def select_boundary_rings(doc: dict, name: str, boundary_type: Optional[str]):
    boundaries = doc.get("boundaries") or []
    matches = [b for b in boundaries if b.get("name") == name]
    if not matches:
        available = "; ".join(f'"{b.get("name")}" ({b.get("type")})' for b in boundaries) or "none"
        raise UsageError(f'no boundary named "{name}" in --input; available: {available}')
    if boundary_type:
        typed = [b for b in matches if b.get("type") == boundary_type]
        if not typed:
            types = ", ".join(sorted(str(b.get("type")) for b in matches))
            raise UsageError(f'no {boundary_type} boundary named "{name}"; its types are: {types}')
        matches = typed
    if len(matches) > 1:
        if not boundary_type:
            types = ", ".join(sorted(str(b.get("type")) for b in matches))
            raise UsageError(f'{len(matches)} boundaries are named "{name}" ({types}); '
                             "add --clip-boundary-type city|county|state")
        raise UsageError(f'{len(matches)} {boundary_type} boundaries are named "{name}"')
    rings = matches[0].get("polygonRings")
    if not (isinstance(rings, list) and all(
            isinstance(ring, list) and all(
                isinstance(p, list) and len(p) >= 2
                and all(isinstance(v, (int, float)) for v in p[:2]) for p in ring)
            for ring in rings)):
        raise UsageError(f'boundary "{name}" has no valid polygonRings')
    return rings


def parse_bbox(text: str) -> Tuple[float, float, float, float]:
    try:
        min_lon, min_lat, max_lon, max_lat = (float(v) for v in text.split(","))
    except ValueError:
        raise UsageError("--clip-bbox must be minLon,minLat,maxLon,maxLat") from None
    if not (min_lon < max_lon and min_lat < max_lat):
        raise UsageError("--clip-bbox needs minLon < maxLon and minLat < maxLat")
    return min_lon, min_lat, max_lon, max_lat


# ---------------------------------------------------------------------------
# Documents
# ---------------------------------------------------------------------------

def new_document() -> dict:
    # The same defaults as MapDocument in Models.swift; the view is fitted to
    # the added markers before writing.
    return {
        "formatVersion": FORMAT_VERSION,
        "zipCode": "",
        "centerLatitude": 37.3318,
        "centerLongitude": -122.0312,
        "spanLatDelta": 0.15,
        "spanLonDelta": 0.15,
        "mapTypeRaw": 0,
        "markers": [],
        "boundaries": [],
    }


def load_document(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except OSError as e:
        raise UsageError(f"cannot read --input {path}: {e.strerror}") from None
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        raise UsageError(f"--input {path} is not valid JSON: {e}") from None
    if not isinstance(doc, dict):
        raise UsageError(f"--input {path} is not an .accmap document (expected a JSON object)")
    markers = doc.setdefault("markers", [])
    if not (isinstance(markers, list) and all(
            isinstance(m, dict) and isinstance(m.get("id"), str) for m in markers)):
        raise UsageError(f"--input {path}: markers must be a list of objects with a string id")
    if not isinstance(doc.get("boundaries", []), list):
        raise UsageError(f"--input {path}: boundaries must be a list")
    return doc


def fit_view(doc: dict, markers: List[dict]) -> None:
    lats = [m["latitude"] for m in markers]
    lons = [m["longitude"] for m in markers]
    doc["centerLatitude"] = (min(lats) + max(lats)) / 2
    doc["centerLongitude"] = (min(lons) + max(lons)) / 2
    doc["spanLatDelta"] = max((max(lats) - min(lats)) * SPAN_MARGIN, MIN_NEW_SPAN)
    doc["spanLonDelta"] = max((max(lons) - min(lons)) * SPAN_MARGIN, MIN_NEW_SPAN)


def write_document(doc: dict, path: str) -> None:
    path = os.path.abspath(path)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path),
                               prefix=f".{os.path.basename(path)}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=2, sort_keys=True, separators=(",", " : "), ensure_ascii=False)
        try:
            mode = stat.S_IMODE(os.stat(path).st_mode)
        except FileNotFoundError:
            umask = os.umask(0)
            os.umask(umask)
            mode = 0o666 & ~umask
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

def parse_state(text: str) -> int:
    t = text.strip().upper()
    if t in STATE_FIPS:
        return STATE_FIPS[t]
    if t.isdigit() and int(t) in STATE_FIPS.values():
        return int(t)
    raise UsageError(f"--state {text!r} is not a US state FIPS code or USPS abbreviation")


def parse_county(text: str) -> int:
    t = text.strip()
    if t.isdigit() and len(t) <= 3 and int(t) > 0:
        return int(t)
    raise UsageError(f"--county {text!r} is not a 3-digit county FIPS code (e.g. 121)")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--state", required=True, help="state FIPS code (13) or USPS abbreviation (GA)")
    p.add_argument("--county", required=True, help="3-digit county FIPS code, without the state part (121)")
    p.add_argument("--from-year", type=int, required=True, help="first crash year")
    p.add_argument("--to-year", type=int, help="last crash year, inclusive (default: --from-year)")
    p.add_argument("--mode", choices=sorted(MODES), default="both", help="fatalities to count (default: both)")
    p.add_argument("--input", help="existing .accmap to add markers to (default: start a new map)")
    p.add_argument("--output", required=True, help=".accmap to write; may be the same file as --input")
    p.add_argument("--clip-boundary", metavar="NAME", help="keep crashes inside this boundary of --input")
    p.add_argument("--clip-boundary-type", choices=("city", "county", "state"),
                   help="boundary type, required when several boundaries share NAME")
    p.add_argument("--clip-bbox", metavar="minLon,minLat,maxLon,maxLat", help="keep crashes inside this box")
    p.add_argument("--cache-dir", default=default_cache_dir(),
                   help="where downloaded archives are kept (default: %(default)s)")
    p.add_argument("--refresh", action="store_true", help="download the archives again even if cached")
    p.add_argument("--dry-run", action="store_true", help="print what would be added without writing")
    return p


def main(argv: Optional[List[str]] = None, fetch: Optional[Fetch] = None) -> int:
    args = build_parser().parse_args(argv)
    fetch = fetch or http_fetch

    def warn(message: str) -> None:
        print(f"warning: {message}", file=sys.stderr)

    # Everything that can be wrong with the arguments or --input is checked
    # here, before any download.
    try:
        state = parse_state(args.state)
        county = parse_county(args.county)
        to_year = args.to_year if args.to_year is not None else args.from_year
        last_year = datetime.date.today().year - 1
        for flag, year in (("--from-year", args.from_year), ("--to-year", to_year)):
            if not FIRST_YEAR <= year <= last_year:
                raise UsageError(f"{flag} {year} is outside {FIRST_YEAR}-{last_year}")
        if args.from_year > to_year:
            raise UsageError("--from-year is after --to-year")
        if args.clip_boundary and args.clip_bbox:
            raise UsageError("--clip-boundary and --clip-bbox cannot be used together")
        if args.clip_boundary_type and not args.clip_boundary:
            raise UsageError("--clip-boundary-type needs --clip-boundary")

        output_dir = os.path.dirname(os.path.abspath(args.output))
        if not os.path.isdir(output_dir):
            raise UsageError(f"the --output directory {output_dir} does not exist")

        input_path = args.input
        if input_path and not os.path.exists(input_path) \
                and os.path.realpath(input_path) == os.path.realpath(args.output):
            input_path = None
        is_new = input_path is None
        doc = new_document() if is_new else load_document(input_path)

        clip = None
        if args.clip_boundary:
            rings = select_boundary_rings(doc, args.clip_boundary, args.clip_boundary_type)
            clip = lambda lon, lat: point_in_rings(lon, lat, rings)  # noqa: E731
        elif args.clip_bbox:
            min_lon, min_lat, max_lon, max_lat = parse_bbox(args.clip_bbox)
            clip = lambda lon, lat: min_lon <= lon <= max_lon and min_lat <= lat <= max_lat  # noqa: E731
    except UsageError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    person_types = MODES[args.mode]
    words = MODE_WORDS[args.mode]
    found: List[Crash] = []
    not_published: List[int] = []
    failed: List[int] = []

    for year in range(args.from_year, to_year + 1):
        try:
            path = cached_zip(year, args.cache_dir, args.refresh, fetch, warn)
        except YearNotPublished:
            warn(f"{year}: not yet published by NHTSA, skipping")
            not_published.append(year)
            continue
        except DownloadFailed as e:
            print(f"error: {year}: {e}", file=sys.stderr)
            failed.append(year)
            continue
        try:
            crashes, skipped = find_crashes(path, year, state, county, person_types, warn)
        except (zipfile.BadZipFile, KeyError, csv.Error, UnicodeDecodeError, ValueError, OSError) as e:
            print(f"error: {year}: cannot read {path}: {e!r} (--refresh downloads it again)", file=sys.stderr)
            failed.append(year)
            continue
        kept = [c for c in crashes if clip is None or clip(c.longitude, c.latitude)]
        print(f"{year}: {len(crashes)} crashes with {words} fatalities "
              f"({sum(c.pedestrians for c in crashes)} pedestrian, {sum(c.bicyclists for c in crashes)} bicyclist)"
              f", {len(crashes) - len(kept)} outside the clip area"
              f", {skipped} skipped without a usable coordinate")
        found.extend(kept)

    years_text = str(args.from_year) if args.from_year == to_year else f"{args.from_year}-{to_year}"
    if not found:
        print(f"No {words} fatalities found for county {county:03d}, state {state:02d}, {years_text}")

    existing_ids = {m["id"].upper() for m in doc["markers"]}
    added, duplicates = [], []
    for marker in (build_marker(c) for c in found):
        (duplicates if marker["id"] in existing_ids else added).append(marker)
        existing_ids.add(marker["id"])
    print(f"{len(added)} markers to add, {len(duplicates)} already in the map")

    status = 0
    if args.dry_run:
        for marker in added:
            print(f"  + {marker['label']}")
        for marker in duplicates:
            print(f"  = {marker['label']} (already in the map)")
        print("dry run: nothing written")
    elif added:
        doc["markers"].extend(added)
        # The added markers carry "kind", so the document is now at least
        # version 2. A higher version from a newer app is never lowered.
        existing = doc.get("formatVersion")
        if isinstance(existing, int) and not isinstance(existing, bool) and existing >= 1:
            doc["formatVersion"] = max(existing, FORMAT_VERSION)
        else:
            doc["formatVersion"] = FORMAT_VERSION
        if is_new:
            fit_view(doc, added)
        try:
            write_document(doc, args.output)
        except OSError as e:
            print(f"error: cannot write {args.output}: {e}", file=sys.stderr)
            return 1
        print(f"wrote {args.output}")
    else:
        print("nothing to add; output not written")

    if not_published:
        print(f"not yet published: {', '.join(map(str, not_published))}", file=sys.stderr)
    if failed:
        print(f"failed years: {', '.join(map(str, failed))}", file=sys.stderr)
        status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
