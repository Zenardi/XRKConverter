#!/usr/bin/env python3
"""
xrk2csv - Convert AiM XRK/XRZ telemetry files to an "AiM CSV File" that
RaceChrono can import.

RaceChrono has a native importer for the AiM RS2Analysis-style CSV. This tool
reproduces that format from the raw .xrk/.xrz using the pure-Python libxrk
parser (no AiM proprietary DLL required, works natively on macOS).

Notes on the conversion:
  * Channels are resampled to a uniform sample rate (default 20 Hz), matching
    how RaceStudio exports the AiM CSV.
  * GPS Speed is stored in m/s inside the XRK but km/h in the AiM CSV, so it is
    converted (x3.6). Same for the GPS velocity-accuracy channel.
  * The XRK has no GPS heading channel, so heading is computed as the bearing
    between consecutive GPS fixes (RaceChrono needs heading for accelerations).
  * Values are CSV-quoted and the header has no trailing comma (a known
    RaceChrono parser requirement).

Usage:
    python xrk2csv.py INPUT.xrk [-o OUTPUT.csv] [--rate HZ] [--json]
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import json
import math
import os
import sys
from typing import Any

import numpy as np
import pyarrow as pa
from libxrk import GPS_CHANNEL_NAMES, ChannelMetadata, aim_xrk

# ---------------------------------------------------------------------------
# Channel mapping: libxrk name -> (AiM-CSV name, output unit, scale factor)
# GPS-derived channels are renamed to the names RaceChrono's AiM importer
# expects, and speed-like channels are converted from m/s to km/h.
# ---------------------------------------------------------------------------
MS_TO_KMH = 3.6

# Ordered set of GPS columns to emit (when present in the file).
# Latitude/Longitude MUST use high precision: 4 dp ~= 11 m of error, which
# would wreck the racing line. RaceStudio's export uses 8 dp for lat/long.
GPS_COLUMN_MAP: list[tuple[str, str, str, float, int]] = [
    # libxrk name,            out name,           out unit, scale,    decimals
    ("GPS Speed",             "GPS Speed",        "km/h",   MS_TO_KMH, 4),
    # "GPS Heading" is synthesized separately (bearing from lat/long).
    ("GPS Latitude",          "GPS Latitude",     "deg",    1.0,       8),
    ("GPS Longitude",         "GPS Longitude",    "deg",    1.0,       8),
    ("GPS Altitude",          "GPS Altitude",     "m",      1.0,       2),
    ("GPS_Satellites",        "GPS Nsat",         " ",      1.0,       0),
    ("GPS_Position_Accuracy", "GPS PosAccuracy",  "m",      1.0,       2),
    ("GPS_Velocity_Accuracy", "GPS SpdAccuracy",  "km/h",   MS_TO_KMH, 2),
    ("GPS_LateralAcc",        "GPS LatAcc",       "g",      1.0,       2),
    ("GPS_InlineAcc",         "GPS InlineAcc",    "g",      1.0,       2),
    ("GPS_Yaw_Rate",          "GPS Yaw Rate",     "deg/s",  1.0,       1),
]

# GPS channels we deliberately do not emit as generic telemetry.
_GPS_NAMES = set(GPS_CHANNEL_NAMES)


def _progress_reporter(json_mode: bool):
    """Return a libxrk-compatible progress callback (current, total)."""
    last = [-1]

    def cb(current: int, total: int) -> None:
        if total <= 0:
            return
        pct = int(current * 100 / total)
        if pct == last[0]:
            return
        last[0] = pct
        # Parsing is ~the first 70% of the job.
        emit_progress(pct * 0.7, f"Parsing XRK ({pct}%)", json_mode)

    return cb


# When set (during XRK parsing), JSON progress is written here instead of
# sys.stdout so libxrk's own stdout chatter can be diverted to stderr without
# corrupting the --json protocol stream. None means "use sys.stdout".
_PROTOCOL: Any = None


def emit_progress(pct: float, message: str, json_mode: bool) -> None:
    """Emit a progress line the GUI (--json, stdout) or a human (stderr) reads."""
    pct = max(0.0, min(100.0, pct))
    if json_mode:
        stream = _PROTOCOL if _PROTOCOL is not None else sys.stdout
        stream.write(json.dumps({"progress": round(pct, 1), "message": message}) + "\n")
        stream.flush()
    else:
        sys.stderr.write(f"[{pct:5.1f}%] {message}\n")
        sys.stderr.flush()


def compute_heading(lat: np.ndarray, lon: np.ndarray) -> np.ndarray:
    """Great-circle bearing (deg, 0..360) from each fix to the next.

    Stationary points (negligible displacement) produce an undefined bearing;
    those are held at the last valid heading so RaceChrono sees a stable value.
    """
    n = len(lat)
    heading = np.zeros(n, dtype=np.float64)
    if n < 2:
        return heading

    latr = np.radians(lat)
    lonr = np.radians(lon)
    dlon = lonr[1:] - lonr[:-1]
    y = np.sin(dlon) * np.cos(latr[1:])
    x = (np.cos(latr[:-1]) * np.sin(latr[1:])
         - np.sin(latr[:-1]) * np.cos(latr[1:]) * np.cos(dlon))
    brg = np.degrees(np.arctan2(y, x))
    brg = np.mod(brg + 360.0, 360.0)

    # Mask near-stationary segments (displacement below ~ a few cm).
    # Approx local meters using equirectangular deltas.
    mean_lat = np.radians(np.nanmean(lat))
    dx = np.radians(lon[1:] - lon[:-1]) * math.cos(mean_lat) * 6371000.0
    dy = np.radians(lat[1:] - lat[:-1]) * 6371000.0
    dist = np.hypot(dx, dy)
    brg[dist < 0.05] = np.nan

    heading[:-1] = brg
    heading[-1] = heading[-2] if n >= 2 else 0.0

    # Forward-fill NaNs, then back-fill any leading NaNs.
    _forward_fill(heading)
    return np.nan_to_num(heading, nan=0.0)


def _forward_fill(a: np.ndarray) -> None:
    """In-place forward fill of NaNs, then back-fill leading NaNs."""
    n = len(a)
    last = math.nan
    for i in range(n):
        if math.isnan(a[i]):
            a[i] = last
        else:
            last = a[i]
    # back-fill leading NaNs
    first = math.nan
    for i in range(n - 1, -1, -1):
        if math.isnan(a[i]):
            a[i] = first
        else:
            first = a[i]


def _fmt_seg_time(ms: float) -> str:
    """Format a lap time in ms as M:SS.mmm (matches AiM CSV 'Segment Times')."""
    total = ms / 1000.0
    m = int(total // 60)
    s = total - m * 60
    return f"{m}:{s:06.3f}"


def convert(input_path: str, output_path: str, rate_hz: float = 20.0,
            json_mode: bool = False) -> dict[str, Any]:
    """Load an XRK/XRZ file and write an AiM-CSV that RaceChrono can import."""
    if rate_hz <= 0:
        raise ValueError("rate must be positive")

    emit_progress(1, f"Opening {os.path.basename(input_path)}", json_mode)
    # libxrk prints channel warnings to stdout; divert its chatter to stderr
    # while our JSON progress continues to the real stdout via _PROTOCOL.
    global _PROTOCOL
    _PROTOCOL = sys.stdout
    try:
        with contextlib.redirect_stdout(sys.stderr):
            log = aim_xrk(input_path, progress=_progress_reporter(json_mode))
    finally:
        _PROTOCOL = None
    result = log_to_csv(log, output_path, rate_hz=rate_hz, json_mode=json_mode)
    result["input"] = input_path
    return result


def log_to_csv(log: Any, output_path: str, rate_hz: float = 20.0,
               json_mode: bool = False) -> dict[str, Any]:
    """Write an already-parsed libxrk ``LogFile`` to a RaceChrono AiM CSV.

    Split out from :func:`convert` so it can be exercised with synthetic
    ``LogFile`` objects (no-GPS files, no-laps sessions, etc.) without needing a
    real .xrk on disk.
    """
    if rate_hz <= 0:
        raise ValueError("rate must be positive")

    if not log.channels:
        raise ValueError("No channels found in file")

    meta = log.metadata
    laps = log.laps.to_pydict()

    # ---- Build a uniform time grid (ms) spanning the session -------------
    # Session starts at t=0; end = full recording length (so we never drop the
    # tail after the final lap line). Lap ends are still emitted as beacons.
    duration_ms = int(max(
        tbl.column("timecodes").to_numpy()[-1] for tbl in log.channels.values()
    ))
    step_ms = 1000.0 / rate_hz
    n_samples = int(round(duration_ms / step_ms)) + 1
    grid_ms = np.round(np.arange(n_samples) * step_ms).astype(np.int64)

    emit_progress(72, f"Resampling {len(log.channels)} channels to {rate_hz:g} Hz", json_mode)
    resampled = log.resample_to_timecodes(pa.array(grid_ms, type=pa.int64()))

    # ---- Assemble output columns -----------------------------------------
    # Each column: (name, unit, numpy float array aligned to grid, decimals)
    columns: list[tuple[str, str, np.ndarray, int]] = []

    def channel_values(libxrk_name: str) -> np.ndarray | None:
        tbl = resampled.channels.get(libxrk_name)
        if tbl is None:
            return None
        return tbl.column(libxrk_name).to_numpy().astype(np.float64)

    # GPS speed / heading / position first (RaceChrono keys on these).
    lat = channel_values("GPS Latitude")
    lon = channel_values("GPS Longitude")

    for libxrk_name, out_name, out_unit, scale, decimals in GPS_COLUMN_MAP:
        vals = channel_values(libxrk_name)
        if vals is None:
            continue
        columns.append((out_name, out_unit, vals * scale, decimals))
        # Insert synthesized heading right after GPS Speed.
        if out_name == "GPS Speed" and lat is not None and lon is not None:
            columns.append(("GPS Heading", "deg", compute_heading(lat, lon), 4))

    if lat is None or lon is None:
        emit_progress(72, "WARNING: file has no GPS latitude/longitude channels", json_mode)

    # Remaining (non-GPS) telemetry channels, native names + units, using each
    # channel's own display precision.
    for name, tbl in resampled.channels.items():
        if name in _GPS_NAMES:
            continue
        cm = ChannelMetadata.from_channel_table(log.channels[name])
        vals = tbl.column(name).to_numpy().astype(np.float64)
        columns.append((name, cm.units or " ", vals, max(0, cm.dec_pts)))

    # ---- Write the CSV ----------------------------------------------------
    emit_progress(88, "Writing CSV", json_mode)
    date_str = meta.get("Log Date", "") or ""
    time_str = meta.get("Log Time", "") or ""

    with open(output_path, "w", newline="") as f:
        w = csv.writer(f, quoting=csv.QUOTE_ALL)
        w.writerow(["Format", "AiM CSV File"])
        w.writerow(["Session", meta.get("Venue", "") or ""])
        w.writerow(["Vehicle", meta.get("Vehicle", "") or ""])
        w.writerow(["Racer", meta.get("Driver", "") or ""])
        w.writerow(["Championship", meta.get("Series", "") or ""])
        w.writerow(["Comment", meta.get("Long Comment", "") or ""])
        w.writerow(["Date", date_str])
        w.writerow(["Time", time_str])
        w.writerow(["Sample Rate", f"{rate_hz:g}"])
        w.writerow(["Duration", f"{duration_ms / 1000:g}"])
        w.writerow(["Segment", "Session"])
        beacons = [f"{t / 1000:g}" for t in laps.get("end_time", [])]
        w.writerow(["Beacon Markers", *beacons])
        seg_times = []
        for s, e in zip(laps.get("start_time", []), laps.get("end_time", []), strict=False):
            seg_times.append(_fmt_seg_time(e - s))
        w.writerow(["Segment Times", *seg_times])
        w.writerow([])  # blank line

        names = ["Time"] + [c[0] for c in columns]
        units = ["s"] + [c[1] for c in columns]
        w.writerow(names)
        w.writerow(units)
        w.writerow([])  # blank line

        time_s = grid_ms / 1000.0
        data = [time_s] + [c[2] for c in columns]
        decimals = [3] + [c[3] for c in columns]
        ncols = len(data)
        for i in range(n_samples):
            row = [None] * ncols
            for j in range(ncols):
                v = data[j][i]
                if v is None or (isinstance(v, float) and math.isnan(v)):
                    row[j] = ""
                else:
                    row[j] = f"{v:.{decimals[j]}f}"
            w.writerow(row)
            if json_mode and (i & 0x3FFF) == 0:
                emit_progress(88 + 12 * i / n_samples, "Writing CSV", json_mode)

    result = {
        "ok": True,
        "input": getattr(log, "file_name", ""),
        "output": output_path,
        "samples": n_samples,
        "rate_hz": rate_hz,
        "duration_s": round(duration_ms / 1000, 3),
        "laps": log.laps.num_rows,
        "channels": len(columns),
        "has_gps": lat is not None and lon is not None,
        # Coerce None -> "" so the JSON contract is always strings (some fields,
        # e.g. Logger Model, exist with a None value for unrecognized loggers).
        "venue": meta.get("Venue") or "",
        "vehicle": meta.get("Vehicle") or "",
        "driver": meta.get("Driver") or "",
        "logger": meta.get("Logger Model") or "",
    }
    emit_progress(100, "Done", json_mode)
    return result


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Convert AiM XRK/XRZ to RaceChrono-compatible AiM CSV.")
    p.add_argument("input", help="Path to .xrk or .xrz file")
    p.add_argument("-o", "--output", help="Output CSV path (default: alongside input)")
    p.add_argument("--rate", type=float, default=20.0, help="Uniform sample rate in Hz (default 20)")
    p.add_argument("--json", action="store_true", help="Emit machine-readable JSON progress/result on stdout")
    args = p.parse_args(argv)

    if not os.path.isfile(args.input):
        sys.stderr.write(f"error: no such file: {args.input}\n")
        return 2

    output = args.output or (os.path.splitext(args.input)[0] + ".csv")
    try:
        result = convert(args.input, output, rate_hz=args.rate, json_mode=args.json)
    except Exception as e:  # surface a clean error to the GUI
        if args.json:
            sys.stdout.write(json.dumps({"ok": False, "error": str(e)}) + "\n")
        else:
            sys.stderr.write(f"error: {e}\n")
        return 1

    if args.json:
        sys.stdout.write(json.dumps({"result": result}) + "\n")
    else:
        sys.stderr.write(
            f"Wrote {result['output']}\n"
            f"  {result['samples']} samples @ {result['rate_hz']:g} Hz, "
            f"{result['duration_s']}s, {result['laps']} laps, "
            f"{result['channels']} channels, GPS={result['has_gps']}\n"
        )
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
