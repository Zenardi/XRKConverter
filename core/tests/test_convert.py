"""Regression tests for xrk2csv. Run: python -m unittest -v (from core/).

Validates conversion invariants against the bundled Fuji Speedway sample and,
when present, cross-checks against RaceStudio's reference CSV.
"""
import csv
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import xrk2csv  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLES = os.path.normpath(os.path.join(HERE, "..", "..", "samples"))
FUJI = os.path.join(SAMPLES, "fuji_0033.xrk")
FUJI_REF = os.path.join(SAMPLES, "fuji_0033_reference.csv")


def _read_csv(path):
    rows = list(csv.reader(open(path, newline="")))
    hi = next(i for i, r in enumerate(rows) if r and r[0] == "Time" and len(r) > 5)
    names = rows[hi]
    data = []
    for r in rows[hi + 2:]:
        if not r or not r[0]:
            continue
        try:
            float(r[0])
        except ValueError:
            continue
        data.append(dict(zip(names, r, strict=False)))
    return names, data


class TestHeading(unittest.TestCase):
    def test_bearing_cardinals(self):
        import numpy as np
        # north-ish then east-ish movement
        lat = np.array([0.0, 0.001, 0.001])
        lon = np.array([0.0, 0.0, 0.001])
        h = xrk2csv.compute_heading(lat, lon)
        self.assertAlmostEqual(h[0], 0.0, delta=1.0)     # heading north
        self.assertAlmostEqual(h[1], 90.0, delta=1.0)    # heading east


@unittest.skipUnless(os.path.isfile(FUJI), "sample fuji_0033.xrk not present")
class TestFujiConversion(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.out = os.path.join(cls.tmp, "out.csv")
        cls.result = xrk2csv.convert(FUJI, cls.out, rate_hz=20.0, json_mode=False)
        cls.names, cls.data = _read_csv(cls.out)

    def test_result_metadata(self):
        self.assertTrue(self.result["ok"])
        self.assertEqual(self.result["laps"], 13)
        self.assertTrue(self.result["has_gps"])
        self.assertEqual(self.result["venue"], "Fuji GP Sh")

    def test_format_header(self):
        first = list(csv.reader(open(self.out, newline="")))[0]
        self.assertEqual(first, ["Format", "AiM CSV File"])

    def test_required_gps_columns_present(self):
        for c in ("Time", "GPS Speed", "GPS Heading", "GPS Latitude", "GPS Longitude"):
            self.assertIn(c, self.names)

    def test_gps_within_fuji_bounds(self):
        lats = [float(r["GPS Latitude"]) for r in self.data if r["GPS Latitude"]]
        lons = [float(r["GPS Longitude"]) for r in self.data if r["GPS Longitude"]]
        self.assertTrue(35.35 < max(lats) < 35.38, f"lat out of range: {max(lats)}")
        self.assertTrue(138.91 < max(lons) < 138.94, f"lon out of range: {max(lons)}")

    def test_speed_kmh_plausible(self):
        spd = [float(r["GPS Speed"]) for r in self.data if r["GPS Speed"]]
        self.assertGreater(max(spd), 150.0)   # a race car exceeds 150 km/h
        self.assertLess(max(spd), 400.0)

    def test_lat_lon_precision(self):
        # lat/lon must carry >=6 decimal places (sub-meter), not 4
        sample = next(r["GPS Latitude"] for r in self.data if r["GPS Latitude"])
        decimals = len(sample.split(".")[1]) if "." in sample else 0
        self.assertGreaterEqual(decimals, 6, f"lat precision too low: {sample!r}")

    def test_no_trailing_comma_in_header(self):
        # each structural row must not end with an empty trailing field
        raw = open(self.out).read().splitlines()
        name_line = next(l for l in raw if l.startswith('"Time"') and "GPS Speed" in l)
        self.assertFalse(name_line.rstrip().endswith(","))
        self.assertFalse(name_line.rstrip().endswith(',""'))

    @unittest.skipUnless(os.path.isfile(FUJI_REF), "reference CSV not present")
    def test_matches_reference_speed_and_position(self):
        import numpy as np
        _, ref = _read_csv(FUJI_REF)
        ours = {round(float(r["Time"]), 3): r for r in self.data}
        refm = {round(float(r["Time"]), 3): r for r in ref}
        common = [t for t in ours if t in refm and 200 <= t <= 1600]
        self.assertGreater(len(common), 10000)
        so = np.array([float(ours[t]["GPS Speed"]) for t in common])
        sr = np.array([float(refm[t]["GPS Speed"]) for t in common])
        self.assertLess(np.abs(so - sr).max(), 0.5)  # km/h
        lat_o = np.array([float(ours[t]["GPS Latitude"]) for t in common])
        lat_r = np.array([float(refm[t]["GPS Latitude"]) for t in common])
        lon_o = np.array([float(ours[t]["GPS Longitude"]) for t in common])
        lon_r = np.array([float(refm[t]["GPS Longitude"]) for t in common])
        mlat = np.radians(lat_r.mean())
        dist = np.hypot(np.radians(lon_o - lon_r) * np.cos(mlat) * 6371000,
                        np.radians(lat_o - lat_r) * 6371000)
        self.assertLess(dist.max(), 1.0)  # within 1 m of RaceStudio's line


if __name__ == "__main__":
    unittest.main()
