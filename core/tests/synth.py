"""Builders for synthetic libxrk LogFile objects, for tests that must exercise
code paths (no-GPS, no-laps, etc.) without a real .xrk on disk."""
import pyarrow as pa
from libxrk import ChannelMetadata, LogFile


def channel(name, timecodes_ms, values, units="", dec_pts=2, interpolate=True):
    """One channel table: 'timecodes' (int64 ms) + value column with metadata."""
    cm = ChannelMetadata(units=units, dec_pts=dec_pts, interpolate=interpolate)
    field = pa.field(name, pa.float64(), metadata=cm.to_field_metadata())
    schema = pa.schema([pa.field("timecodes", pa.int64()), field])
    return pa.table([pa.array(timecodes_ms, pa.int64()),
                     pa.array(values, pa.float64())], schema=schema)


def make_log(channels, laps_rows=(), metadata=None, file_name="synthetic.xrk"):
    """Build a LogFile. laps_rows: iterable of (num, start_ms, end_ms)."""
    laps = pa.table({
        "num": pa.array([r[0] for r in laps_rows], pa.int64()),
        "start_time": pa.array([r[1] for r in laps_rows], pa.int64()),
        "end_time": pa.array([r[2] for r in laps_rows], pa.int64()),
    })
    return LogFile(channels=dict(channels), laps=laps,
                   metadata=dict(metadata or {}), file_name=file_name)


def gps_log(n=5, step_ms=50, **meta):
    """A small moving-vehicle GPS log plus an RPM channel."""
    tc = [i * step_ms for i in range(n)]
    ch = {
        "GPS Latitude": channel("GPS Latitude", tc, [35.370 + 0.001 * i for i in range(n)], "deg", 4),
        "GPS Longitude": channel("GPS Longitude", tc, [138.920 + 0.001 * i for i in range(n)], "deg", 4),
        "GPS Speed": channel("GPS Speed", tc, [10.0 + 10 * i for i in range(n)], "m/s", 1),
        "GPS Altitude": channel("GPS Altitude", tc, [600.0 + i for i in range(n)], "m", 1),
        "RPM": channel("RPM", tc, [3000 + 500 * i for i in range(n)], "rpm", 0),
    }
    laps = [(1, 0, tc[n // 2]), (2, tc[n // 2], tc[-1])]
    md = {"Venue": "TestTrack", "Vehicle": "Kart", "Driver": "Me",
          "Series": "Test Cup", "Long Comment": "",
          "Log Date": "01/01/2026", "Log Time": "12:00:00",
          "Logger Model": "MXm"}
    md.update(meta)
    return make_log(ch, laps, md)
