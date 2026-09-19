"""Hold a fixed downtown ladder and measure what it does to the crossings.

The ladder the rider described is, in the app's own offset frame:

    85X -4.5 | 5 -3.5 | 17 -2.5 | 4 -0.5 | 7 +0.5 | 3 +1.5 | 24X +2.5 | 12X +3.5

Those are exactly the lanes each route *holds* at its mode inside the downtown
shared corridor -- the arrangement the map was validated on. What the corridor
does not do is hold them: a route re-lanes 30-60 times along its length, and
every re-lane is a chance to swap sides with whatever else is on the street.

This script pins each route to its own rung across the corridor (ramping in and
out so the drawing stays smooth) and re-counts the crossings against the
untouched export. No Swift toolchain is involved: it rebuilds the ribbons with
the same code the package's gates use, so the counts are directly comparable to
`LaneHarness.countCrossings`.
"""

import collections
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lane_geometry as geometry

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_EXPORT = os.path.join(
    REPO, "tools", "replay", "data", "waybound-lanes-1789254859.json"
)

LANE = 4.2                     # lane spacing, in the offsets' own points
LANE_M = 8.4                   # ... which is this many metres on the ground

# Which frame the ribbons are drawn in.
#   "per-route" -- what LaneHarness.ribbon does today: k = metersPerUnit(lat of
#                  the route's first vertex) / mpp, applied to ABSOLUTE map
#                  points. Two routes standing on the same coordinate therefore
#                  land metres apart, by (y_map * delta k) -- up to 150 m here.
#   "one-frame" -- a single metersPerUnit for the whole map, which is what a
#                  map renderer does; shared coordinates land together.
FRAME = os.environ.get("WB_FRAME", "per-route")
REFERENCE_LATITUDE = 34.4209
RAMP = 12                      # vertices used to reach the rung and leave it
# The downtown window: State Street and its approaches, where the ladder runs.
# Wide enough to hold every shared run the eight ladder routes have downtown,
# narrow enough that it does not reach the 101/UCSB corridor.
WINDOW = dict(lat0=34.4175, lat1=34.4285, lon0=-119.7190, lon1=-119.7020)

# The rider's ladder, in each route's own recorded offset frame.
LADDER = {"85X": -4.5, "5": -3.5, "17": -2.5, "4": -0.5,
          "7": 0.5, "3": 1.5, "24X": 2.5, "12X": 3.5}


def in_window(lat, lon):
    return (WINDOW["lat0"] <= lat <= WINDOW["lat1"]
            and WINDOW["lon0"] <= lon <= WINDOW["lon1"])


def window_runs(coords, shared):
    """Contiguous stretches of a route that lie inside the downtown window."""
    runs, start = [], None
    for i, (lat, lon) in enumerate(coords):
        if in_window(lat, lon):
            if start is None:
                start = i
        elif start is not None:
            runs.append((start, i - 1))
            start = None
    if start is not None:
        runs.append((start, len(coords) - 1))
    # ignore one-vertex clips at the window edge: nothing to hold there
    return [r for r in runs if r[1] - r[0] >= 3]


def co_run_runs(coords, shared):
    """The route's shared (stacked) runs, as the layout marks them -- whole
    runs that reach downtown, end to end. This is the real unit: the order a
    route takes should be decided where it joins the run and held until it
    leaves, not just while it happens to be inside a box."""
    if len(shared) != len(coords):          # defensive: fall back to geometry
        return window_runs(coords, shared)
    runs, start = [], None
    for i, flag in enumerate(shared):
        if flag and start is None:
            start = i
        elif not flag and start is not None:
            runs.append((start, i - 1))
            start = None
    if start is not None:
        runs.append((start, len(shared) - 1))
    runs = [r for r in runs if r[1] - r[0] >= 3]
    return [r for r in runs
            if any(in_window(*coords[i]) for i in range(r[0], r[1] + 1))]


def pin(offsets, runs, rung_pts):
    """Hold the rung across each run, ramping in and out so the drawing stays
    smooth where the route reaches its normal lane."""
    out = list(offsets)
    for start, end in runs:
        out[start:end + 1] = [rung_pts] * (end - start + 1)
        for step in range(1, RAMP + 1):
            weight = step / (RAMP + 1)
            head = start - step
            if head >= 0:
                out[head] = offsets[head] * weight + rung_pts * (1 - weight)
            tail = end + step
            if tail < len(out):
                out[tail] = offsets[tail] * weight + rung_pts * (1 - weight)
    return out


K_REF = geometry.meters_per_unit(34.42) / geometry.SCREEN_POINTS_PER_MAP_POINT


def to_latlon(x, y, k=None):
    """Inverse of the ribbon's scaled space, back to degrees. Each route has
    its own scale factor (from its first vertex), and that factor multiplies
    the huge absolute y, so the inverse has to use the route's own `k`."""
    mx, my = x / (k or K_REF), y / (k or K_REF)
    lon = mx / geometry.WORLD * 360.0 - 180.0
    # project(): y = (0.5 - ln((1+s)/(1-s))/(4*pi)) * WORLD
    log_ratio = (0.5 - my / geometry.WORLD) * 4 * math.pi
    lat = math.degrees(math.asin(math.tanh(log_ratio / 2.0)))
    return lat, lon


# round-trip check, so a silent sign slip cannot make every window test pass
for _lat in (34.4175, 34.4209, 34.4223, 34.4285):
    for _lon in (-119.7190, -119.7076, -119.7037, -119.7020):
        _x, _y = geometry.project(_lat, _lon)
        _k = geometry.meters_per_unit(_lat) / geometry.SCREEN_POINTS_PER_MAP_POINT
        _back = to_latlon(_x * _k, _y * _k, _k)
        assert abs(_back[0] - _lat) < 1e-9 and abs(_back[1] - _lon) < 1e-9, (_lat, _lon, _back)


def build(document, overrides):
    journeys = {j["id"]: j for j in document["journeys"]}
    lanes = []
    for layout in document["layouts"]:
        journey = journeys[layout["journeyID"]]
        coords = journey["polylines"][max(layout["polylineIndex"], 0)]
        offsets = overrides.get(journey["id"], layout["offsets"])
        mpp = (geometry.meters_per_unit(REFERENCE_LATITUDE) if FRAME == "one-frame"
               else geometry.meters_per_unit(coords[0][0]))
        aligned = [geometry.project(lat, lon) for lat, lon in coords]
        points, lateral = geometry.ribbon(aligned, offsets, mpp)
        lanes.append(dict(id=journey["id"], route=journey["routeNumber"],
                          points=points, lateral=lateral, offsets=offsets,
                          shared=layout["shared"], trunk=layout["trunk"],
                          coords=coords,
                          k=mpp / geometry.SCREEN_POINTS_PER_MAP_POINT))
    return lanes


def report(label, lanes):
    all_crossings, bundle = geometry.crossings(lanes)
    route_of = {i: l["route"] for i, l in enumerate(lanes)}
    pairs = collections.Counter(tuple(sorted((route_of[i], route_of[j])))
                                for _, _, i, j in bundle)
    def where(c):
        k = (lanes[c[2]]["k"] + lanes[c[3]]["k"]) / 2.0
        return to_latlon(c[0], c[1], k)

    inside = [c for c in all_crossings if in_window(*where(c))]
    inside_bundle = [c for c in bundle if in_window(*where(c))]
    print(f"{label:28s} crossings={len(all_crossings):4d} (downtown {len(inside):3d})  "
          f"in-bundle={len(bundle):4d} (downtown {len(inside_bundle):3d})  "
          f"worst={', '.join(f'{a}&{b}×{n}' for (a, b), n in pairs.most_common(3))}")
    return all_crossings, bundle


def pinned(document, runs_fn):
    """Rung per route (the rider's ladder where given, else the route's own
    modal lane over the same runs), and the overridden offsets."""
    journeys = {j["id"]: j for j in document["journeys"]}
    overrides, rungs = {}, {}
    for layout in document["layouts"]:
        journey = journeys[layout["journeyID"]]
        coords = journey["polylines"][max(layout["polylineIndex"], 0)]
        runs = runs_fn(coords, layout["shared"])
        if not runs:
            continue
        lanes_here = [round(layout["offsets"][i] / LANE, 1)
                      for start, end in runs for i in range(start, end + 1)]
        rung = LADDER.get(journey["routeNumber"])
        if rung is None:
            rung = collections.Counter(lanes_here).most_common(1)[0][0]
        rungs[journey["routeNumber"]] = (rung, len(lanes_here))
        overrides[journey["id"]] = pin(layout["offsets"], runs, rung * LANE)
    return overrides, rungs


def show_rungs(rungs, title):
    print(f"\n{title}")
    for route, (rung, n) in sorted(rungs.items(), key=lambda kv: kv[1][0]):
        tag = ""
        if route in LADDER:
            tag = ("  <- ladder" if abs(rung - LADDER[route]) < 0.05
                   else f"  <- ladder says {LADDER[route]:+.1f}")
        print(f"  {route:>5s} {rung:+5.1f}  ({n} pinned vertices){tag}")


def main(export_path):
    with open(export_path) as handle:
        document = json.load(handle)
    print(f"frame: {FRAME}"
          + (f" (reference latitude {REFERENCE_LATITUDE})" if FRAME == "one-frame" else ""))
    base_lanes = build(document, {})
    report("today (as recorded)", base_lanes)

    overrides, rungs = pinned(document, window_runs)
    show_rungs(rungs, "rung held per route, downtown window only "
                      "(rider's ladder where given):")
    report("ladder held in window", build(document, overrides))

    overrides, rungs = pinned(document, co_run_runs)
    show_rungs(rungs, "rung held per route, whole shared runs reaching downtown "
                      "(rider's ladder where given):")
    report("ladder held whole run", build(document, overrides))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_EXPORT))
