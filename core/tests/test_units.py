"""Unit tests for xrk2csv pure functions, log_to_csv branches, and the CLI.

These use synthetic LogFile objects and need no real .xrk on disk, so they run
anywhere (CI included). Real-file integration lives in test_convert.py.
"""
import csv
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import numpy as np  # noqa: E402
import synth  # noqa: E402
import xrk2csv  # noqa: E402


def read_aim_csv(path):
    rows = list(csv.reader(open(path, newline="")))
    # The channel-names row is the "Time" row immediately followed by the units
    # row (which starts with "s"). This disambiguates it from the metadata
    # "Time" row in the header block.
    hi = next(i for i, r in enumerate(rows)
              if r and r[0] == "Time" and i + 1 < len(rows)
              and rows[i + 1] and rows[i + 1][0] == "s")
    names = rows[hi]
    data = [r for r in rows[hi + 2:] if r and r[0]]
    return rows, names, data


class TestEmitProgress(unittest.TestCase):
    def test_json_mode_writes_json_to_stdout(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            xrk2csv.emit_progress(42.0, "hello", json_mode=True)
        obj = json.loads(buf.getvalue().strip())
        self.assertEqual(obj["progress"], 42.0)
        self.assertEqual(obj["message"], "hello")

    def test_human_mode_writes_to_stderr(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            xrk2csv.emit_progress(10.0, "working", json_mode=False)
        self.assertIn("working", err.getvalue())
        self.assertEqual(out.getvalue(), "")

    def test_progress_is_clamped(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            xrk2csv.emit_progress(250.0, "over", json_mode=True)
            xrk2csv.emit_progress(-5.0, "under", json_mode=True)
        lines = [json.loads(x) for x in buf.getvalue().splitlines()]
        self.assertEqual(lines[0]["progress"], 100.0)
        self.assertEqual(lines[1]["progress"], 0.0)


class TestProgressReporter(unittest.TestCase):
    def test_callback_emits_and_dedupes(self):
        buf = io.StringIO()
        cb = xrk2csv._progress_reporter(json_mode=True)
        with redirect_stdout(buf):
            cb(0, 0)         # total<=0 -> no output
            cb(50, 100)      # 50%
            cb(50, 100)      # same pct -> deduped, no new line
            cb(100, 100)     # 100%
        lines = buf.getvalue().splitlines()
        self.assertEqual(len(lines), 2)


class TestComputeHeading(unittest.TestCase):
    def test_cardinals(self):
        lat = np.array([0.0, 0.001, 0.001])
        lon = np.array([0.0, 0.0, 0.001])
        h = xrk2csv.compute_heading(lat, lon)
        self.assertAlmostEqual(h[0], 0.0, delta=1.0)     # north
        self.assertAlmostEqual(h[1], 90.0, delta=1.0)    # east

    def test_single_point_returns_zero(self):
        h = xrk2csv.compute_heading(np.array([1.0]), np.array([2.0]))
        self.assertEqual(list(h), [0.0])

    def test_stationary_points_hold_last_heading(self):
        # move north, then sit still: stationary sample inherits prior heading
        lat = np.array([0.0, 0.001, 0.001])
        lon = np.array([0.0, 0.0, 0.0])
        h = xrk2csv.compute_heading(lat, lon)
        self.assertAlmostEqual(h[1], h[0], delta=1.0)

    def test_all_stationary_is_zero_filled(self):
        lat = np.array([1.0, 1.0, 1.0])
        lon = np.array([2.0, 2.0, 2.0])
        h = xrk2csv.compute_heading(lat, lon)
        self.assertTrue(np.all(h == 0.0))


class TestForwardFill(unittest.TestCase):
    def test_forward_and_back_fill(self):
        a = np.array([np.nan, np.nan, 5.0, np.nan, 7.0, np.nan])
        xrk2csv._forward_fill(a)
        self.assertEqual(list(a), [5.0, 5.0, 5.0, 5.0, 7.0, 7.0])


class TestFmtSegTime(unittest.TestCase):
    def test_format(self):
        self.assertEqual(xrk2csv._fmt_seg_time(193611), "3:13.611")
        self.assertEqual(xrk2csv._fmt_seg_time(5000), "0:05.000")


class TestLogToCsvBranches(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def out(self, name="o.csv"):
        return os.path.join(self.tmp, name)

    def test_gps_log_full(self):
        log = synth.gps_log(n=6)
        with redirect_stderr(io.StringIO()):
            res = xrk2csv.log_to_csv(log, self.out(), rate_hz=20.0)
        self.assertTrue(res["ok"])
        self.assertTrue(res["has_gps"])
        self.assertEqual(res["venue"], "TestTrack")
        self.assertEqual(res["laps"], 2)
        _, names, data = read_aim_csv(self.out())
        self.assertIn("GPS Heading", names)
        # GPS Speed converted m/s -> km/h: first sample 10 m/s = 36 km/h
        si = names.index("GPS Speed")
        self.assertAlmostEqual(float(data[0][si]), 36.0, delta=0.1)
        # lat/long precision >= 6 dp
        li = names.index("GPS Latitude")
        self.assertGreaterEqual(len(data[0][li].split(".")[1]), 6)

    def test_no_gps_log(self):
        log = synth.make_log(
            {"RPM": synth.channel("RPM", [0, 50, 100], [1, 2, 3], "rpm", 0)},
            [(1, 0, 100)], {"Venue": "X"})
        err = io.StringIO()
        with redirect_stderr(err):
            res = xrk2csv.log_to_csv(log, self.out(), rate_hz=20.0)
        self.assertFalse(res["has_gps"])
        self.assertIn("no GPS", err.getvalue())
        _, names, _ = read_aim_csv(self.out())
        self.assertNotIn("GPS Latitude", names)

    def test_no_laps_uses_recording_length(self):
        log = synth.make_log(
            {"RPM": synth.channel("RPM", [0, 100, 200], [1, 2, 3], "rpm", 0)},
            [], {"Venue": "NoLaps"})
        with redirect_stderr(io.StringIO()):
            res = xrk2csv.log_to_csv(log, self.out(), rate_hz=10.0)
        self.assertEqual(res["laps"], 0)
        self.assertGreater(res["samples"], 0)
        rows, _, _ = read_aim_csv(self.out())
        beacon = next(r for r in rows if r and r[0] == "Beacon Markers")
        self.assertEqual(beacon, ["Beacon Markers"])   # no lap beacons

    def test_nan_values_write_empty_cells(self):
        tc = [0, 50, 100]
        ch = {
            "GPS Latitude": synth.channel("GPS Latitude", tc, [35.0, 35.1, 35.2], "deg", 4),
            "GPS Longitude": synth.channel("GPS Longitude", tc, [138.0, 138.1, 138.2], "deg", 4),
            "GPS Speed": synth.channel("GPS Speed", tc, [1.0, 2.0, 3.0], "m/s", 1),
            "Broken": synth.channel("Broken", tc, [float("nan")] * 3, "x", 0, interpolate=False),
        }
        log = synth.make_log(ch, [(1, 0, 100)], {"Venue": "NaN"})
        with redirect_stderr(io.StringIO()):
            xrk2csv.log_to_csv(log, self.out(), rate_hz=20.0)
        _, names, data = read_aim_csv(self.out())
        bi = names.index("Broken")
        self.assertEqual(data[0][bi], "")

    def test_empty_channels_raises(self):
        log = synth.make_log({}, [(1, 0, 100)], {})
        with self.assertRaises(ValueError):
            xrk2csv.log_to_csv(log, self.out(), rate_hz=20.0)

    def test_nonpositive_rate_raises(self):
        log = synth.gps_log()
        with self.assertRaises(ValueError):
            xrk2csv.log_to_csv(log, self.out(), rate_hz=0)

    def test_json_progress_during_write(self):
        # >16384 samples triggers the periodic JSON progress line while writing
        log = synth.make_log(
            {"RPM": synth.channel("RPM", [0, 1_000_000], [0, 100], "rpm", 0)},
            [], {"Venue": "Long"})
        buf = io.StringIO()
        with redirect_stdout(buf):
            res = xrk2csv.log_to_csv(log, self.out(), rate_hz=50.0, json_mode=True)
        self.assertGreater(res["samples"], 16384)
        progresses = [json.loads(x) for x in buf.getvalue().splitlines() if x.strip()]
        self.assertTrue(any(p.get("message") == "Writing CSV" for p in progresses))


class TestMainCLI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        # Write a synthetic file? main() calls aim_xrk on a real path, so we need
        # a real .xrk. Use the bundled sample if present; otherwise skip file-based
        # cases (still covers arg parsing / missing-file / error paths).
        here = os.path.dirname(os.path.abspath(__file__))
        self.sample = os.path.normpath(os.path.join(here, "..", "..", "samples", "aim_official_test.xrk"))

    def test_missing_file_returns_2(self):
        err = io.StringIO()
        with redirect_stderr(err):
            rc = xrk2csv.main(["/no/such/file.xrk"])
        self.assertEqual(rc, 2)
        self.assertIn("no such file", err.getvalue())

    @unittest.skipUnless(os.path.isfile(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "samples", "aim_official_test.xrk")),
        "sample not present")
    def test_success_human_mode(self):
        out = os.path.join(self.tmp, "s.csv")
        err = io.StringIO()
        with redirect_stderr(err):
            rc = xrk2csv.main([self.sample, "-o", out, "--rate", "20"])
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.isfile(out))
        self.assertIn("Wrote", err.getvalue())

    @unittest.skipUnless(os.path.isfile(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "samples", "aim_official_test.xrk")),
        "sample not present")
    def test_success_json_mode_and_default_output(self):
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(io.StringIO()):
            rc = xrk2csv.main([self.sample, "--json"])   # default output path
        self.assertEqual(rc, 0)
        lines = [json.loads(x) for x in out.getvalue().splitlines() if x.strip()]
        self.assertTrue(any("result" in x for x in lines))
        default_out = os.path.splitext(self.sample)[0] + ".csv"
        self.assertTrue(os.path.isfile(default_out))
        os.remove(default_out)

    @unittest.skipUnless(os.path.isfile(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "samples", "aim_official_test.xrk")),
        "sample not present")
    def test_error_returns_1_human(self):
        err = io.StringIO()
        with redirect_stderr(err):
            rc = xrk2csv.main([self.sample, "-o", os.path.join(self.tmp, "e.csv"), "--rate", "0"])
        self.assertEqual(rc, 1)
        self.assertIn("error", err.getvalue())

    @unittest.skipUnless(os.path.isfile(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "samples", "aim_official_test.xrk")),
        "sample not present")
    def test_error_returns_1_json(self):
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(io.StringIO()):
            rc = xrk2csv.main([self.sample, "--json", "--rate", "-1"])
        self.assertEqual(rc, 1)
        obj = json.loads(out.getvalue().splitlines()[-1])
        self.assertFalse(obj["ok"])


if __name__ == "__main__":
    unittest.main()
