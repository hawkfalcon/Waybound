"""Reference-handoff regression for the corridor alignment rate clamp.

Scenario (the 12x/24x jog at Chapala x Sola): a dominant companion route
(here: route 6, which turns off at Sola) shares the approach street, then
leaves. The member's lane adopts the dominant route's centerline while they
share, and returns to its own after the split. With feed drift between the
two shapes, that bounded (<= 6 m) correction used to arrive within a vertex
or two — a one-sided diagonal jog exactly at the corner.

Route 6's real downtown trace (route_6dt.json) and an express-shaped trace
(route_xdt.json, continues up Chapala past Sola) share the approach; drift
is injected perpendicular to route 6's own direction to model the feeds
disagreeing by a few meters.

Run:  python3 tools/replay/corridor_check.py   (exit 1 on failure)
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from corridor2 import G, layout
from geo import mpm, to_coord, to_map_point

HERE = os.path.dirname(os.path.abspath(__file__))

DRIFT_METERS = 4.0
RATE_CLAMP = 0.08  # meters of correction per meter of street (ships in Swift)


def load(name):
    with open(os.path.join(HERE, "data", name)) as fh:
        return [tuple(c) for c in json.load(fh)]


def inject_drift(path, meters):
    """Offset every vertex perpendicular to its local travel direction."""
    pts = [to_map_point(*c) for c in path]
    m = mpm(path[0][0])
    out = []
    for i in range(len(path)):
        a = pts[max(0, i - 1)]
        b = pts[min(len(pts) - 1, i + 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy)
        if length < 1e-9:
            out.append(path[i])
            continue
        # left-hand normal, in map points
        nx, ny = -dy / length, dx / length
        out.append((path[i], pts[i], nx * meters / m, ny * meters / m))
    return [
        to_coord(p[1][0] + p[2], p[1][1] + p[3]) for p in out
    ]


def max_kink(result):
    """Worst per-vertex step of the alignment-correction VECTOR, in meters,
    over consecutive vertices that are both inside a corridor run. This is
    exactly the quantity the rate clamp bounds; unlike a signed projection
    on the local normal it is immune to the trace's own corners, and it
    excludes the deliberate lane-merge tapers outside the run."""
    adx, ady, stacked, m = result["adx"], result["ady"], result["stacked"], result["m"]
    return max(
        math.hypot(adx[i + 1] - adx[i], ady[i + 1] - ady[i]) * m
        for i in range(len(adx) - 1)
        if stacked[i] and stacked[i + 1]
    )


six = inject_drift(load("route_6dt.json"), DRIFT_METERS)
xdt = load("route_xdt.json")

geoms = {
    "j6": G("j6", "6", 0, six),
    "jx": G("jx", "12X", 0, xdt),
}

uncapped = layout(geoms, "jx", rate_clamp=None)
capped = layout(geoms, "jx", rate_clamp=RATE_CLAMP)

kink_before = max_kink(uncapped)
kink_after = max_kink(capped)
print(f"member lane: {len(xdt)} pts (express proxy), drift {DRIFT_METERS} m")
print(f"max lateral step WITHOUT clamp: {kink_before:.2f} m/vertex")
print(f"max lateral step WITH clamp {RATE_CLAMP}: {kink_after:.2f} m/vertex")

problems = []
if kink_before < 0.5:
    problems.append(
        f"handoff no longer reproduces without the clamp ({kink_before:.2f} m)"
    )
if not kink_after < kink_before:
    problems.append("clamp does not reduce the handoff step")
if kink_after > 0.5:
    problems.append(f"clamped step still visible ({kink_after:.2f} m)")

if problems:
    for p in problems:
        print("FAIL  " + p)
    sys.exit(1)
print("corridor check green")
