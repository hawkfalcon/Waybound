"""Regression battery for the stop-connector notch stage.

Mirror of TripPathGeometry.removingStopConnectorNotches (notch2.py is the
algorithm port). Every fixture below was validated against the Swift gates
when they shipped; if a case flips, the Swift code and this battery must be
reconciled before anything is committed.

  MUST-DELETE: the stop coordinate is gone and every surviving vertex is
  still on the input street polyline (<= 1 m) — deletions are street-aligned
  by construction.
  MUST-KEEP:   output is the input, unchanged.

Run:  python3 tools/replay/battery.py   (exit 1 on any failure)
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from geo import distance_to_polyline, mpm, to_map_point
from notch2 import removing_stop_connector_notches

HERE = os.path.dirname(os.path.abspath(__file__))

BASE_LAT, BASE_LON = 34.4208, -119.7000


def C(north, east):
    """Local meter-framed coordinate fixture (same as TestFixtures.swift)."""
    return (
        BASE_LAT + north / 111320.0,
        BASE_LON + east / (111320.0 * math.cos(math.radians(BASE_LAT))),
    )


failures = []


def check(name, ok, detail=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("  " + detail if detail else ""))
    if not ok:
        failures.append(name)


def max_street_offset(path, out):
    """Worst distance of any surviving vertex from the input polyline, m."""
    street = [to_map_point(*c) for c in path]
    return max(
        distance_to_polyline(to_map_point(*c), street) for c in out
    ) * mpm(path[0][0])


def stops_gone(out, stops):
    return all(
        not any(
            abs(p[0] - s[0]) < 1e-12 and abs(p[1] - s[1]) < 1e-12
            for p in out
        )
        for s in stops
    )


# ---------------------------------------------------------------- MUST DELETE

def must_delete(name, path, stops, expect_count=None):
    out = removing_stop_connector_notches(path, stops)
    ok = stops_gone(out, stops) and max_street_offset(path, out) <= 1.0
    if expect_count is not None:
        ok = ok and len(out) == expect_count
    check(
        "delete: " + name,
        ok,
        f"{len(path)} -> {len(out)} pts, "
        f"worst street offset {max_street_offset(path, out):.2f} m",
    )


must_delete(
    "dense V (route-3 downtown form)",
    [C(0, 0), C(0, 40), C(0, 80), C(0, 100), C(10, 100), C(0, 128), C(0, 160), C(0, 220)],
    [C(10, 100)],
    expect_count=7,
)
must_delete(
    "shallow near-exact return (published oab form)",
    [C(0, 0), C(0, 60), C(0, 120), C(8, 120), C(0, 124), C(0, 200)],
    [C(8, 120)],
    expect_count=4,
)
must_delete(
    "comb of five (pass iterates)",
    [C(0, 0)] + sum(
        [[C(0, e), C(12, e), C(0, e + 40)] for e in range(80, 401, 80)],
        [],
    ) + [C(0, 460)],
    [C(12, e) for e in range(80, 401, 80)],
    expect_count=8,
)
must_delete(
    "sparse V (re-entry vertex 100 m on; route-2 form)",
    [C(0, 0), C(0, 100), C(0, 200), C(9, 200), C(0, 300), C(0, 420)],
    [C(9, 200)],
    expect_count=5,
)
must_delete(
    "noisy V (re-entry drifts 4 m sideways)",
    [C(0, 0), C(0, 100), C(10, 106), C(4, 132), C(4, 230), C(4, 330)],
    [C(12, 112)],
)
must_delete(
    "terminal connector at the end",
    [C(0, 0), C(0, 100), C(0, 200), C(0, 300), C(10, 300)],
    [C(10, 300)],
    expect_count=4,
)
must_delete(
    "terminal connector at the start",
    [C(10, 0), C(0, 0), C(0, 100), C(0, 200), C(0, 300)],
    [C(10, 0)],
    expect_count=4,
)

# ------------------------------------------------------------------ MUST KEEP


def must_keep(name, path, stops):
    out = removing_stop_connector_notches(path, stops)
    check(
        "keep:   " + name,
        len(out) == len(path)
        and all(abs(a[0] - b[0]) < 1e-12 and abs(a[1] - b[1]) < 1e-12
                for a, b in zip(out, path)),
        f"{len(path)} -> {len(out)} pts",
    )


must_keep(
    "block jog with a stop at the corner",
    [C(0, 0), C(100, 0), C(100, 40), C(220, 40), C(320, 40)],
    [C(100, 40)],
)
must_keep(
    "asymmetric corner with a stop at the bend",
    [C(0, 0), C(0, 60), C(0, 120), C(180, 120), C(180, 300)],
    [C(4, 116)],
)
must_keep(
    "90-degree corner with a stop beside the apex",
    [C(0, 0), C(0, 80), C(0, 160), C(80, 160), C(160, 160), C(160, 240)],
    [C(8, 156)],
)
must_keep(
    "hairpin turnaround serving a stop",
    [C(0, 0), C(0, 60), C(0, 100), C(18, 104), C(0, 108), C(0, 30)],
    [C(18, 104)],
)
must_keep(
    "R150 curve with a stop outside the mid-curve",
    [
        C(
            150 - 150 * (1 - math.cos(math.radians(t))),
            150 * math.sin(math.radians(t)),
        )
        for t in range(-23, 24, 5)
    ],
    [C(150 - 150 * (1 - math.cos(math.radians(0))) + 8, 0)],
)
must_keep(
    "R250 crest with a stop beyond the apex",
    [
        C(
            60 - 250 * (1 - math.cos(math.radians(t))),
            250 * math.sin(math.radians(t)),
        )
        for t in range(-14, 15, 2)
    ],
    [C(68, 0)],
)
must_keep(
    "sparse shallow S-bow with a stop at the apex (steep-leg gate)",
    [C(0, -60), C(0, 0), C(12, 55), C(0, 110), C(0, 210)],
    [C(22, 60)],
)
must_keep(
    "45-degree terminal approach to a stop",
    [C(0, 0), C(0, 120), C(0, 180), C(60, 240)],
    [C(60, 240)],
)
must_keep(
    "straight-in terminal stop",
    [C(0, 0), C(0, 120), C(0, 240), C(0, 300)],
    [C(0, 300)],
)

# ------------------------------------------------------- PROPERTY ON REAL DATA

with open(os.path.join(HERE, "data", "route_6dt.json")) as fh:
    trace = [tuple(c) for c in json.load(fh)]

identity = removing_stop_connector_notches(trace, [])
check(
    "real 122-pt OSRM trace: inert without stops",
    len(identity) == len(trace),
    f"{len(trace)} -> {len(identity)} pts",
)

# Stops set 1 m beside every tenth vertex: the cleaner may delete, but only
# onto the street it already had — the structural safety property.
spread = [
    (c[0] + 1.0 / 111320.0, c[1]) for c in trace[5::10]
]
touched = removing_stop_connector_notches(trace, spread)
check(
    "real trace with stops: every survivor on the original street",
    max_street_offset(trace, touched) <= 1.2,
    f"{len(trace)} -> {len(touched)} pts, "
    f"worst street offset {max_street_offset(trace, touched):.2f} m",
)

print()
if failures:
    print(f"{len(failures)} FAILED: " + ", ".join(failures))
    sys.exit(1)
print("battery green")
