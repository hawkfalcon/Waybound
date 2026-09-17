"""What shape is each crossing? Two straight questions per crossing.

  * do the two paths actually cross (headings far apart, centrelines a street
    apart), which the brief allows, or
  * are they the same path (headings alike, centrelines within a lane or two),
    where a crossing can only come from the drawing, not the street?

For the same-path ones, the offsets say which drawing fault it is:

  * offsets a lane or more apart  -> the order was not held (fixable by holding
    one order per corridor)
  * offsets on the same lane      -> both routes drawn on top of each other,
    so a metre of polyline disagreement is enough to cross (a co-location
    fault, not an ordering one)

Centreline distance is segment-to-segment, in metres, not vertex-to-vertex:
routes are densified unevenly, so a vertex near the crossing can be tens of
metres off the line that actually crosses.
"""

import collections
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lane_geometry as geometry
import ladder_experiment as experiment

PARALLEL_DEGREES = 45.0     # headings within this count as "the same path"
SAME_STREET_METRES = 25.0   # centrelines within this count as "the same street"
SAME_LANE_POINTS = 1.0      # offsets within this count as "on the same lane"


def segment_distance(p1, p2, q1, q2):
    """Shortest distance between two segments, in map-point units."""
    def point_segment(p, a, b):
        ax, ay = a
        bx, by = b
        px, py = p
        dx, dy = bx - ax, by - ay
        length2 = dx * dx + dy * dy
        if length2 <= 0:
            return math.hypot(px - ax, py - ay)
        t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length2))
        return math.hypot(px - (ax + t * dx), py - (ay + t * dy))

    if _segments_intersect(p1, p2, q1, q2):
        return 0.0
    return min(point_segment(p1, q1, q2), point_segment(p2, q1, q2),
               point_segment(q1, p1, p2), point_segment(q2, p1, p2))


def _cross(ax, ay, bx, by, cx, cy):
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)


def _segments_intersect(p1, p2, q1, q2):
    d1 = _cross(*q1, *q2, *p1)
    d2 = _cross(*q1, *q2, *p2)
    d3 = _cross(*p1, *p2, *q1)
    d4 = _cross(*p1, *p2, *q2)
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0))


def crossing_segments(points_a, points_b):
    """The pairs of ribbon segment indices that properly cross, by the very
    same `segmentsCross` the gate counts use."""
    return [(i, k)
            for i in range(len(points_a) - 1)
            for k in range(len(points_b) - 1)
            if geometry.segments_cross(points_a[i], points_a[i + 1],
                                       points_b[k], points_b[k + 1])]


def heading_degrees(coords, index):
    """Heading of the centreline segment leaving `index`, in degrees."""
    n = min(index, len(coords) - 2)
    if n < 0:
        return 0.0
    (lat1, lon1), (lat2, lon2) = coords[n], coords[n + 1]
    return math.degrees(math.atan2(lat2 - lat1,
                                   (lon2 - lon1) * math.cos(math.radians(lat1))))


def heading_delta(a, b):
    return abs((a - b + 180.0) % 360.0 - 180.0)


def to_latlon(x, y, k):
    return experiment.to_latlon(x, y, k)


def classify(lanes, verbose=True):
    """Every crossing, sorted into the shapes that matter."""
    route_of = {i: l["route"] for i, l in enumerate(lanes)}
    rows = []
    for i in range(len(lanes)):
        for j in range(i + 1, len(lanes)):
            for seg_a, seg_b in crossing_segments(lanes[i]["points"],
                                                  lanes[j]["points"]):
                A, B = lanes[i], lanes[j]
                ia, ib = min(seg_a, len(A["coords"]) - 2), min(seg_b, len(B["coords"]) - 2)
                ma = geometry.meters_per_unit(A["coords"][ia][0])
                a1 = geometry.project(*A["coords"][ia])
                a2 = geometry.project(*A["coords"][ia + 1])
                b1 = geometry.project(*B["coords"][ib])
                b2 = geometry.project(*B["coords"][ib + 1])
                separation = segment_distance(a1, a2, b1, b2) * ma
                delta = heading_delta(heading_degrees(A["coords"], ia),
                                      heading_degrees(B["coords"], ib))
                offset_gap = abs(A["offsets"][ia] - B["offsets"][ib])
                same_path = delta <= PARALLEL_DEGREES and separation <= SAME_STREET_METRES
                both_stacked = (geometry.inside(A["shared"], seg_a)
                                and geometry.inside(B["shared"], seg_b))
                if not same_path:
                    kind = "paths cross (street corner)"
                elif both_stacked and offset_gap >= SAME_LANE_POINTS:
                    kind = "same path, order not held"
                elif both_stacked:
                    kind = "same path, drawn on the same lane"
                else:
                    kind = "same path, not both stacked"
                lat, lon = to_latlon((A["points"][seg_a][0] + B["points"][seg_b][0]) / 2,
                                     (A["points"][seg_a][1] + B["points"][seg_b][1]) / 2,
                                     (A["k"] + B["k"]) / 2)
                rows.append(dict(pair=tuple(sorted((route_of[i], route_of[j]))),
                                 kind=kind, delta=delta, separation=separation,
                                 offset_gap=offset_gap, lat=lat, lon=lon,
                                 stacked=both_stacked))
    if verbose:
        summary = collections.Counter(r["kind"] for r in rows)
        print(f"{len(rows)} crossings")
        for kind, n in summary.most_common():
            print(f"   {kind:34s} {n}")
    return rows


def main(export_path):
    with open(export_path) as handle:
        document = json.load(handle)
    print(f"frame: {experiment.FRAME}\n")
    print("today, as recorded:")
    base = classify(experiment.build(document, {}))
    downtown = [r for r in base if experiment.in_window(r["lat"], r["lon"])]
    print(f"   of which in the downtown window: {len(downtown)}")
    for kind, n in collections.Counter(r["kind"] for r in downtown).most_common():
        print(f"      {kind:31s} {n}")

    overrides, _ = experiment.pinned(document, experiment.window_runs)
    print("\nwith the ladder held through the window:")
    held = classify(experiment.build(document, overrides))
    downtown = [r for r in held if experiment.in_window(r["lat"], r["lon"])]
    print(f"   of which in the downtown window: {len(downtown)}")
    for kind, n in collections.Counter(r["kind"] for r in downtown).most_common():
        print(f"      {kind:31s} {n}")
    return 0


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else experiment.DEFAULT_EXPORT
    sys.exit(main(path))
