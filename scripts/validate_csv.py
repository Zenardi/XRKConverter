#!/usr/bin/env python3
"""Validate that a CSV is a RaceChrono-importable AiM CSV. Exits 0/1.

Usage: validate_csv.py FILE.csv
"""
import csv
import sys


def fail(msg):
    print(f"  FAIL: {msg}")
    sys.exit(1)


def main(path):
    rows = list(csv.reader(open(path, newline="")))
    if not rows or rows[0] != ["Format", "AiM CSV File"]:
        fail('first row must be "Format","AiM CSV File"')

    # Channel-names row = "Time" row directly followed by the units row ("s").
    hi = None
    for i, r in enumerate(rows):
        if r and r[0] == "Time" and i + 1 < len(rows) and rows[i + 1] and rows[i + 1][0] == "s":
            hi = i
            break
    if hi is None:
        fail("could not find channel header (Time + units row)")
    names = rows[hi]

    required = ["Time", "GPS Speed", "GPS Heading", "GPS Latitude", "GPS Longitude"]
    for c in required:
        if c not in names:
            fail(f"missing required column: {c}")

    # No trailing empty field on the header (RaceChrono parser quirk).
    raw = open(path).read().splitlines()
    name_line = next(line for line in raw if line.startswith('"Time"') and "GPS Speed" in line)
    if name_line.rstrip().endswith(",") or name_line.rstrip().endswith(',""'):
        fail("header row has a trailing comma / empty field")

    data = [r for r in rows[hi + 2:] if r and r[0]]
    if len(data) < 10:
        fail(f"too few data rows: {len(data)}")

    li, oi, si = names.index("GPS Latitude"), names.index("GPS Longitude"), names.index("GPS Speed")

    # lat/long precision must be sub-meter (>= 6 decimals).
    for idx, label in ((li, "GPS Latitude"), (oi, "GPS Longitude")):
        sample = next((r[idx] for r in data if r[idx]), "")
        dec = len(sample.split(".")[1]) if "." in sample else 0
        if dec < 6:
            fail(f"{label} precision too low ({dec} dp): {sample!r}")

    lats = [float(r[li]) for r in data if r[li]]
    lons = [float(r[oi]) for r in data if r[oi]]
    spds = [float(r[si]) for r in data if r[si]]
    if not (-90 <= min(lats) and max(lats) <= 90):
        fail("latitude out of range")
    if not (-180 <= min(lons) and max(lons) <= 180):
        fail("longitude out of range")
    if max(lats) - min(lats) == 0 and max(lons) - min(lons) == 0:
        fail("GPS track is a single point (no movement)")
    if max(spds) > 500:
        fail(f"implausible max speed {max(spds)} km/h")

    print(f"  OK: {path}  ({len(data)} rows, {len(names)} cols, "
          f"lat {min(lats):.4f}..{max(lats):.4f}, vmax {max(spds):.1f} km/h)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: validate_csv.py FILE.csv", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
