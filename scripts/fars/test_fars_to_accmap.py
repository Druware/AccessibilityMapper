#!/usr/bin/env python3
"""
test_fars_to_accmap.py — offline tests for fars_to_accmap.py.

    python3 -m unittest -v scripts/fars/test_fars_to_accmap.py

The fixtures are real rows copied from the NHTSA FARS 2021 and 2022 national
accident.csv and person.csv (trimmed to the columns the script reads, UTF-8
with BOM like the originals). Archives are built in memory and served by a
fake downloader; nothing touches the network.
"""

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import urllib.error
import uuid
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fars_to_accmap as fars  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
SAMPLE = os.path.join(HERE, "..", "..", "Samples", "Fulton County GA Schools.accmap")
SAMPLE_BOUNDARY = "Fulton County, Georgia, United States"

FULTON_2021 = {130007, 130027, 130107, 131350, 131458}


def fixture_zip(year):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for member in ("accident", "person"):
            with open(os.path.join(FIXTURES, f"{member}_{year}.csv"), "rb") as f:
                archive.writestr(f"FARS{year}NationalCSV/{member}.csv", f.read())
    return buffer.getvalue()


class FakeFetch:
    """Serves fixture archives by year. A year maps to bytes, an exception, or
    a list of those consumed one per call."""

    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def __call__(self, url, out):
        self.calls.append(url)
        year = int(url.split("/FARS/")[1].split("/")[0])
        response = self.responses.get(year, 404)
        if isinstance(response, list):
            response = response.pop(0)
        if response == 404:
            raise urllib.error.HTTPError(url, 404, "Not Found", None, None)
        if isinstance(response, Exception):
            raise response
        out.write(response)


def no_network(url, out):
    raise AssertionError(f"tests must not download {url}")


class FarsTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.cache = os.path.join(self.tmp, "cache")
        self._patch("RETRY_DELAY_SECONDS", 0)
        self._patch("http_fetch", no_network)
        self.warnings = []

    def _patch(self, name, value):
        original = getattr(fars, name)
        setattr(fars, name, value)
        self.addCleanup(setattr, fars, name, original)

    def path(self, name):
        return os.path.join(self.tmp, name)

    def run_cli(self, args, fetch=None):
        fetch = fetch or FakeFetch({2021: fixture_zip(2021), 2022: fixture_zip(2022)})
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = fars.main(args + ["--cache-dir", self.cache], fetch=fetch)
            except SystemExit as e:
                code = e.code
        return code, out.getvalue(), err.getvalue(), fetch

    def crashes(self, year, state, county, mode="both"):
        crashes, skipped = fars.find_crashes(io.BytesIO(fixture_zip(year)), year, state, county,
                                             fars.MODES[mode], self.warnings.append)
        return {c.st_case: c for c in crashes}, skipped

    def load(self, name):
        with open(self.path(name), encoding="utf-8") as f:
            return json.load(f)

    def copy_sample(self, name="map.accmap"):
        shutil.copyfile(SAMPLE, self.path(name))
        return self.path(name)


class FilterTests(FarsTestCase):
    def test_county_filter(self):
        fulton, _ = self.crashes(2021, 13, 121)
        self.assertEqual(set(fulton), FULTON_2021)
        lowndes, _ = self.crashes(2021, 13, 185)
        self.assertEqual(set(lowndes), {130238})
        none, _ = self.crashes(2021, 13, 89)
        self.assertEqual(none, {})

    def test_join_and_injury_filter_exclude_driver_and_injured(self):
        fulton, _ = self.crashes(2021, 13, 121)
        # 130007: fatal pedestrian, injured driver, uninjured passenger.
        self.assertEqual((fulton[130007].pedestrians, fulton[130007].bicyclists), (1, 0))
        # 131458: one fatal pedestrian and one with a suspected minor injury.
        self.assertEqual((fulton[131458].pedestrians, fulton[131458].bicyclists), (1, 0))

    def test_mode_counts(self):
        self.assertEqual(set(self.crashes(2021, 13, 121, "pedestrian")[0]), FULTON_2021 - {131350})
        self.assertEqual(set(self.crashes(2021, 13, 121, "bicycle")[0]), {131350})
        self.assertEqual(set(self.crashes(2021, 13, 121, "both")[0]), FULTON_2021)
        # PER_TYP 7 "Other Cyclist" (San Jose) counts as a bicyclist only.
        other_cyclist, _ = self.crashes(2021, 6, 85, "bicycle")
        self.assertEqual(other_cyclist[61620].bicyclists, 1)
        self.assertEqual(self.crashes(2021, 6, 85, "pedestrian")[0], {})
        # PER_TYP 8 "Person on a Personal Conveyance" (Birmingham) is never counted.
        self.assertEqual(self.crashes(2022, 1, 73, "both")[0], {})

    def test_two_qualifying_persons_give_one_marker_with_count(self):
        lowndes, _ = self.crashes(2021, 13, 185)
        self.assertEqual(len(lowndes), 1)
        self.assertEqual(fars.build_label(lowndes[130238]), "2 pedestrian fatalities — Mar 2, 2021 — CR-237")

    def test_pedestrian_and_bicyclist_in_one_crash(self):
        label = "{} — Jul 2, 2022 — MINNESOTA AVE NE, Washington"
        for mode, phrase in (("both", "Pedestrian and bicyclist fatalities"),
                             ("pedestrian", "Pedestrian fatality"),
                             ("bicycle", "Bicyclist fatality")):
            crashes, _ = self.crashes(2022, 11, 1, mode)
            self.assertEqual(list(crashes), [110013])
            self.assertEqual(fars.build_label(crashes[110013]), label.format(phrase))

    def test_labels(self):
        fulton, _ = self.crashes(2021, 13, 121)
        self.assertEqual(fars.build_label(fulton[130007]), "Pedestrian fatality — Jan 2, 2021 — I-75/85, Atlanta")
        self.assertEqual(fars.build_label(fulton[130027]), "Pedestrian fatality — Jan 8, 2021 — SR-14, Fairburn")
        # CITY 0 "NOT APPLICABLE" drops the city.
        self.assertEqual(fars.build_label(fulton[130107]), "Pedestrian fatality — Jan 22, 2021 — SR-70")
        self.assertEqual(fars.build_label(fulton[131350]),
                         "Bicyclist fatality — Sep 16, 2021 — SR-3 METROPOLITIAN PKWY, Atlanta")
        no_location = fars.Crash(13, 2021, 1, 1, 2, 33.7, -84.4, "", "", 1, 0)
        self.assertEqual(fars.build_label(no_location), "Pedestrian fatality — Jan 2, 2021")

    def test_placeholder_coordinates_skipped(self):
        crashes, skipped = self.crashes(2021, 4, 9)
        self.assertEqual((crashes, skipped), ({}, 1))
        self.assertIn("ST_CASE 40246", self.warnings[0])
        for lat, lon in (("77.77770000", "777.777700000"), ("88.88880000", "888.888800000"),
                         ("99.99990000", "999.999900000")):
            self.assertIsNone(fars.usable_coordinate(lat, lon))
        self.assertEqual(fars.usable_coordinate("33.76784722", "-84.389097220"), (33.76784722, -84.38909722))


class IdTests(FarsTestCase):
    def test_stable_ids(self):
        first = fars.marker_id(13, 2021, 130007)
        self.assertEqual(first, fars.marker_id(13, 2021, 130007))
        self.assertEqual(first, str(uuid.uuid5(uuid.UUID("05AA96AB-3B88-4708-BDC0-DD9DE2148290"),
                                               "fars:13:2021:130007")).upper())
        self.assertEqual(uuid.UUID(first).version, 5)
        self.assertNotEqual(first, fars.marker_id(13, 2022, 130007))
        self.assertNotEqual(first, fars.marker_id(12, 2021, 130007))

        ids = []
        for name in ("a.accmap", "b.accmap"):
            code, _, _, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                          "--output", self.path(name)])
            self.assertEqual(code, 0)
            ids.append([m["id"] for m in self.load(name)["markers"]])
        self.assertEqual(ids[0], ids[1])
        self.assertEqual(len(set(ids[0])), 5)

    def test_every_marker_has_exactly_the_app_fields(self):
        self.run_cli(["--state", "13", "--county", "121", "--from-year", "2021", "--output", self.path("m.accmap")])
        markers = self.load("m.accmap")["markers"]
        self.assertEqual(len(markers), 5)
        for marker in markers:
            self.assertEqual(set(marker), {"id", "latitude", "longitude", "label", "kind"})
            self.assertEqual(marker["kind"], "incident")
        fulton, _ = self.crashes(2021, 13, 121)
        self.assertEqual(fars.build_marker(fulton[130007])["kind"], "incident")


class MergeTests(FarsTestCase):
    def test_rerun_adds_zero(self):
        target = self.copy_sample()
        args = ["--state", "GA", "--county", "121", "--from-year", "2021", "--input", target, "--output", target]
        code, out, _, _ = self.run_cli(args)
        self.assertEqual(code, 0)
        self.assertIn("5 markers to add, 0 already in the map", out)
        self.assertEqual(self.load("map.accmap")["formatVersion"], 2)
        with open(target, "rb") as f:
            before = f.read()
        code, out, _, _ = self.run_cli(args)
        self.assertEqual(code, 0)
        self.assertIn("0 markers to add, 5 already in the map", out)
        with open(target, "rb") as f:
            self.assertEqual(f.read(), before)

    def test_existing_ids_match_case_insensitively(self):
        target = self.path("lower.accmap")
        doc = fars.new_document()
        doc["markers"] = [{"id": fars.marker_id(13, 2021, 130007).lower(), "latitude": 1.0,
                           "longitude": 2.0, "label": "kept"}]
        fars.write_document(doc, target)
        code, out, _, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                        "--input", target, "--output", target])
        self.assertEqual(code, 0)
        self.assertIn("4 markers to add, 1 already in the map", out)
        self.assertEqual(self.load("lower.accmap")["markers"][0]["label"], "kept")

    def test_existing_document_view_fields_unchanged(self):
        source = self.copy_sample("source.accmap")
        output = self.path("out.accmap")
        code, _, _, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                      "--input", source, "--output", output])
        self.assertEqual(code, 0)
        with open(SAMPLE, encoding="utf-8") as f:
            original = json.load(f)
        merged = self.load("out.accmap")
        self.assertNotIn("formatVersion", original)
        self.assertEqual(merged["formatVersion"], 2)
        self.assertEqual(set(merged), set(original) | {"formatVersion"})
        for key in ("zipCode", "centerLatitude", "centerLongitude", "spanLatDelta", "spanLonDelta",
                    "mapTypeRaw", "boundaries"):
            self.assertEqual(merged[key], original[key], key)
        # The sample's markers are kept exactly: no "kind" is added to them.
        self.assertEqual(len(original["markers"]), 201)
        self.assertEqual(merged["markers"][:201], original["markers"])
        self.assertFalse(any("kind" in m for m in merged["markers"][:201]))
        self.assertEqual(len(merged["markers"]), 201 + 5)
        self.assertEqual([m["kind"] for m in merged["markers"][201:]], ["incident"] * 5)

    def test_merge_never_lowers_format_version(self):
        # 3 is kept; 1, missing, and invalid values (not an int, a bool, < 1) become 2.
        missing = object()
        for existing, expected in ((3, 3), (1, 2), (2, 2), (missing, 2), ("x", 2), (True, 2),
                                   (0, 2), (-4, 2), (3.0, 2), (None, 2)):
            with self.subTest(existing=existing):
                target = self.copy_sample("versioned.accmap")
                with open(target, encoding="utf-8") as f:
                    doc = json.load(f)
                if existing is not missing:
                    doc["formatVersion"] = existing
                fars.write_document(doc, target)
                code, out, _, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                                "--input", target, "--output", target])
                self.assertEqual(code, 0)
                self.assertIn("5 markers to add", out)
                merged = self.load("versioned.accmap")
                self.assertEqual(merged["formatVersion"], expected)
                self.assertIs(type(merged["formatVersion"]), int)

    def test_new_document_fitted_to_markers(self):
        code, _, _, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                      "--output", self.path("new.accmap")])
        self.assertEqual(code, 0)
        doc = self.load("new.accmap")
        self.assertEqual(set(doc), {"formatVersion", "zipCode", "centerLatitude", "centerLongitude",
                                    "spanLatDelta", "spanLonDelta", "mapTypeRaw", "markers", "boundaries"})
        self.assertEqual((doc["formatVersion"], doc["zipCode"], doc["mapTypeRaw"], doc["boundaries"]),
                         (2, "", 0, []))
        lats = [m["latitude"] for m in doc["markers"]]
        lons = [m["longitude"] for m in doc["markers"]]
        # Real extremes: latitude 131458 (33.7862) / 130027 (33.55853889),
        # longitude 130007 (-84.38909722) / 130027 (-84.59016389).
        self.assertEqual((min(lats), max(lats)), (33.55853889, 33.7862))
        self.assertAlmostEqual(doc["centerLatitude"], (33.55853889 + 33.7862) / 2)
        self.assertAlmostEqual(doc["centerLongitude"], (-84.59016389 + -84.38909722) / 2)
        self.assertAlmostEqual(doc["spanLatDelta"], (33.7862 - 33.55853889) * 1.15)
        self.assertAlmostEqual(doc["spanLonDelta"], (max(lons) - min(lons)) * 1.15)

    def test_new_document_when_input_is_missing_output(self):
        target = self.path("same.accmap")
        code, _, _, _ = self.run_cli(["--state", "DC", "--county", "1", "--from-year", "2022",
                                      "--input", target, "--output", target])
        self.assertEqual(code, 0)
        doc = self.load("same.accmap")
        self.assertEqual(doc["formatVersion"], 2)
        self.assertEqual(len(doc["markers"]), 1)
        # A single marker gets the minimum span, centered on it.
        self.assertEqual((doc["centerLatitude"], doc["centerLongitude"]), (38.90194722, -76.94260556))
        self.assertEqual((doc["spanLatDelta"], doc["spanLonDelta"]), (0.02, 0.02))

    def test_output_formatting(self):
        doc = {"zipCode": "é", "markers": [{"label": "Pedestrian fatality — I-75/85", "longitude": -84.5,
                                            "id": "A", "latitude": 33.25}], "mapTypeRaw": 0}
        fars.write_document(doc, self.path("fmt.accmap"))
        with open(self.path("fmt.accmap"), encoding="utf-8") as f:
            text = f.read()
        self.assertEqual(text, '{\n'
                               '  "mapTypeRaw" : 0,\n'
                               '  "markers" : [\n'
                               '    {\n'
                               '      "id" : "A",\n'
                               '      "label" : "Pedestrian fatality — I-75/85",\n'
                               '      "latitude" : 33.25,\n'
                               '      "longitude" : -84.5\n'
                               '    }\n'
                               '  ],\n'
                               '  "zipCode" : "é"\n'
                               '}')
        self.assertEqual([n for n in os.listdir(self.tmp) if n.endswith(".tmp")], [])

    def test_dry_run_does_not_write(self):
        output = self.path("dry.accmap")
        code, out, _, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                        "--output", output, "--dry-run"])
        self.assertEqual(code, 0)
        self.assertFalse(os.path.exists(output))
        self.assertIn("  + Pedestrian fatality — Jan 2, 2021 — I-75/85, Atlanta", out)
        target = self.copy_sample()
        with open(target, "rb") as f:
            before = f.read()
        self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                      "--input", target, "--output", target, "--dry-run"])
        with open(target, "rb") as f:
            self.assertEqual(f.read(), before)

    def test_zero_fatalities_exit_zero(self):
        output = self.path("none.accmap")
        code, out, _, _ = self.run_cli(["--state", "GA", "--county", "89", "--from-year", "2021",
                                        "--output", output])
        self.assertEqual(code, 0)
        self.assertIn("No pedestrian/bicyclist fatalities found for county 089, state 13, 2021", out)
        self.assertFalse(os.path.exists(output))


class ClipTests(FarsTestCase):
    SQUARE_WITH_HOLE = [
        [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
        [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]],
    ]
    TWO_PARTS = [
        [[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]],
        [[5, 5], [6, 5], [6, 6], [5, 6]],  # unclosed ring
    ]

    def test_even_odd_hole_is_outside(self):
        self.assertTrue(fars.point_in_rings(2, 2, self.SQUARE_WITH_HOLE))
        self.assertTrue(fars.point_in_rings(8, 5, self.SQUARE_WITH_HOLE))
        self.assertFalse(fars.point_in_rings(5, 5, self.SQUARE_WITH_HOLE))
        self.assertFalse(fars.point_in_rings(11, 5, self.SQUARE_WITH_HOLE))

    def test_even_odd_two_part_boundary(self):
        self.assertTrue(fars.point_in_rings(0.5, 0.5, self.TWO_PARTS))
        self.assertTrue(fars.point_in_rings(5.5, 5.5, self.TWO_PARTS))
        self.assertFalse(fars.point_in_rings(3, 3, self.TWO_PARTS))

    def write_boundary_map(self, boundaries):
        doc = fars.new_document()
        doc["boundaries"] = boundaries
        fars.write_document(doc, self.path("b.accmap"))
        return self.path("b.accmap")

    def test_clip_boundary_with_hole(self):
        # A real-coordinate square around downtown/midtown Atlanta with a hole around 130007.
        target = self.write_boundary_map([{
            "id": "64A63D56-364B-5B48-A22C-0204014D19E9", "name": "Atlanta", "type": "city",
            "polygonRings": [
                [[-84.45, 33.65], [-84.35, 33.65], [-84.35, 33.80], [-84.45, 33.80]],
                [[-84.395, 33.76], [-84.385, 33.76], [-84.385, 33.775], [-84.395, 33.775]],
            ]}])
        code, out, _, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                        "--input", target, "--output", target, "--clip-boundary", "Atlanta"])
        self.assertEqual(code, 0, out)
        cases = {m["label"] for m in self.load("b.accmap")["markers"]}
        self.assertEqual(cases, {"Bicyclist fatality — Sep 16, 2021 — SR-3 METROPOLITIAN PKWY, Atlanta",
                                 "Pedestrian fatality — Oct 29, 2021 — SR-9, Atlanta"})

    def test_clip_to_real_county_boundary(self):
        target = self.copy_sample()
        code, out, _, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                        "--input", target, "--output", target, "--clip-boundary", SAMPLE_BOUNDARY])
        self.assertEqual(code, 0)
        self.assertIn("0 outside the clip area", out)

    def test_unknown_clip_boundary_errors_before_download(self):
        target = self.copy_sample()
        fetch = FakeFetch({})
        code, _, err, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                        "--input", target, "--output", target, "--clip-boundary", "Atlanta"], fetch)
        self.assertEqual(code, 2)
        self.assertIn('no boundary named "Atlanta"', err)
        self.assertIn(SAMPLE_BOUNDARY, err)
        self.assertEqual(fetch.calls, [])

    def test_ambiguous_clip_boundary_needs_type(self):
        ring = [[[-84.6, 33.5], [-84.3, 33.5], [-84.3, 33.9], [-84.6, 33.9]]]
        target = self.write_boundary_map([
            {"id": "11111111-1111-1111-1111-111111111111", "name": "Fulton", "type": "city", "polygonRings": ring},
            {"id": "22222222-2222-2222-2222-222222222222", "name": "Fulton", "type": "county", "polygonRings": ring},
        ])
        base = ["--state", "GA", "--county", "121", "--from-year", "2021", "--input", target, "--output", target,
                "--clip-boundary", "Fulton"]
        code, _, err, fetch = self.run_cli(base, FakeFetch({}))
        self.assertEqual(code, 2)
        self.assertIn("--clip-boundary-type", err)
        self.assertEqual(fetch.calls, [])
        code, _, _, _ = self.run_cli(base + ["--clip-boundary-type", "county"])
        self.assertEqual(code, 0)
        self.assertEqual(len(self.load("b.accmap")["markers"]), 5)

    def test_clip_bbox(self):
        output = self.path("bbox.accmap")
        code, out, _, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                        "--output", output, "--clip-bbox=-84.40,33.76,-84.38,33.78"])
        self.assertEqual(code, 0)
        self.assertIn("4 outside the clip area", out)
        self.assertEqual([m["label"] for m in self.load("bbox.accmap")["markers"]],
                         ["Pedestrian fatality — Jan 2, 2021 — I-75/85, Atlanta"])

    def test_clip_boundary_and_bbox_are_exclusive(self):
        target = self.copy_sample()
        code, _, err, fetch = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                            "--input", target, "--output", target, "--clip-boundary",
                                            SAMPLE_BOUNDARY, "--clip-bbox=-85,33,-84,34"], FakeFetch({}))
        self.assertEqual(code, 2)
        self.assertIn("cannot be used together", err)
        self.assertEqual(fetch.calls, [])


class DownloadTests(FarsTestCase):
    def test_404_year_is_skipped(self):
        output = self.path("404.accmap")
        fetch = FakeFetch({2021: fixture_zip(2021), 2022: 404})
        code, out, err, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                          "--to-year", "2022", "--output", output], fetch)
        self.assertEqual(code, 0)
        self.assertIn("2022: not yet published by NHTSA, skipping", err)
        self.assertEqual(len(self.load("404.accmap")["markers"]), 5)
        self.assertEqual(len(fetch.calls), 2)  # no retry for a 404

    def test_failed_download_retried_once(self):
        fetch = FakeFetch({2021: [urllib.error.URLError("reset"), fixture_zip(2021)]})
        code, _, err, _ = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                        "--output", self.path("retry.accmap")], fetch)
        self.assertEqual(code, 0)
        self.assertEqual(len(fetch.calls), 2)
        self.assertIn("retrying", err)

    def test_download_failing_twice_skips_year_and_leaves_no_partial_file(self):
        fetch = FakeFetch({2021: [urllib.error.URLError("reset"), b"<html>not a zip</html>"],
                           2022: fixture_zip(2022)})
        code, _, err, _ = self.run_cli(["--state", "DC", "--county", "1", "--from-year", "2021",
                                        "--to-year", "2022", "--output", self.path("fail.accmap")], fetch)
        self.assertEqual(code, 1)
        self.assertIn("2021: download failed after retry", err)
        self.assertEqual(len(self.load("fail.accmap")["markers"]), 1)
        self.assertEqual(sorted(os.listdir(self.cache)), ["FARS2022NationalCSV.zip"])

    def test_cache_reused_unless_refresh(self):
        args = ["--state", "GA", "--county", "121", "--from-year", "2021", "--output", self.path("c.accmap"),
                "--dry-run"]
        fetch = FakeFetch({2021: fixture_zip(2021)})
        self.run_cli(args, fetch)
        self.run_cli(args, fetch)
        self.assertEqual(len(fetch.calls), 1)
        self.run_cli(args + ["--refresh"], fetch)
        self.assertEqual(len(fetch.calls), 2)


class ValidationTests(FarsTestCase):
    def test_invalid_years_rejected_before_download(self):
        for years in (["--from-year", "1974"], ["--from-year", "2021", "--to-year", "2999"],
                      ["--from-year", "2022", "--to-year", "2021"]):
            code, _, err, fetch = self.run_cli(["--state", "GA", "--county", "121", "--output",
                                                self.path("y.accmap")] + years, FakeFetch({}))
            self.assertEqual(code, 2, years)
            self.assertEqual(fetch.calls, [])

    def test_invalid_input_rejected_before_download(self):
        bad = self.path("bad.accmap")
        with open(bad, "w") as f:
            f.write("not json")
        for path in (bad, self.path("missing.accmap")):
            code, _, err, fetch = self.run_cli(["--state", "GA", "--county", "121", "--from-year", "2021",
                                                "--input", path, "--output", self.path("o.accmap")], FakeFetch({}))
            self.assertEqual(code, 2)
            self.assertEqual(fetch.calls, [])

    def test_state_and_county_parsing(self):
        self.assertEqual(fars.parse_state("ga"), 13)
        self.assertEqual(fars.parse_state("13"), 13)
        self.assertEqual(fars.parse_county("121"), 121)
        for bad in ("XX", "3", "99"):
            with self.assertRaises(fars.UsageError):
                fars.parse_state(bad)
        for bad in ("1210", "abc", "0"):
            with self.assertRaises(fars.UsageError):
                fars.parse_county(bad)


if __name__ == "__main__":
    unittest.main()
