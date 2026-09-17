"""Rebuild the app's drawn lane ribbons and find where they cross.

Input is a device export (`tools/replay/data/waybound-lanes-*.json`), which
carries each journey's polyline geometry and the lane offsets the app recorded
for it, vertex by vertex.

The ribbon construction, the crossing test and the drawing scale are copied
from `LaneHarness` so that what this module measures is what the package's own
lane gates measure:

    LaneHarness.ribbon(layout, screenPointsPerMapPoint: 2.0)
    LaneHarness.segmentsCross(...)
    LaneHarness.countCrossings / countBundleCrossings

Scale, stated exactly: the geometry is scaled by `metersPerUnit / mpp` and
lane offsets are applied unscaled in points, so at this convention one lane of
4.2 points spans 8.4 m of ground and the crossing counts are the ones the
package's gates measure. They are not a prediction of what a user sees at a
particular map zoom -- the app's own lane spacing varies with zoom.
"""

import json
import math

# GeoProjection: MKMapPoint's world, and WGS84's semi-major axis.
WORLD = 268_435_456
EARTH_SEMI_MAJOR = 6_378_137

# LaneHarness.ribbon's default: screen points per map point.
SCREEN_POINTS_PER_MAP_POINT = 2.0

# How far inside a stacked run a crossing must sit to count as a bundle
# crossing (LaneHarness.countBundleCrossings' `guardSegments`).
GUARD_SEGMENTS = 4

# LaneHarness.segmentsCross' interior epsilon.
CROSSING_EPSILON = 0.02


def project(latitude, longitude):
    """GeoCoordinate.projected, in map points."""
    x = (longitude + 180.0) / 360.0 * WORLD
    s = math.sin(math.radians(latitude))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * WORLD
    return x, y


def meters_per_unit(latitude):
    """GeoProjection.metersPerUnit(atLatitude:)."""
    return (math.cos(math.radians(latitude)) * 2 * math.pi
            * EARTH_SEMI_MAJOR / WORLD)


def ribbon(aligned, offsets, meters_per_unit_value,
           screen_points_per_map_point=SCREEN_POINTS_PER_MAP_POINT):
    """LaneHarness.ribbon, in Python: averaged-normal offsetting with the
    reversal side-hold and the 1.75x miter limit."""
    k = meters_per_unit_value / screen_points_per_map_point
    points = [(x * k, y * k) for x, y in aligned]
    n = len(points)
    if n < 2:
        return points, list(offsets)

    directions = []
    previous = None
    for i in range(n - 1):
        dx = points[i + 1][0] - points[i][0]
        dy = points[i + 1][1] - points[i][1]
        length = max(1e-4, math.hypot(dx, dy))
        ux, uy = dx / length, dy / length
        if previous and ux * previous[0] + uy * previous[1] < -0.8:
            ux, uy = -ux, -uy
        directions.append((ux, uy))
        previous = (ux, uy)

    out, lateral = [], []
    for i in range(n):
        pd = directions[max(i - 1, 0)]
        nd = directions[min(i, n - 2)]
        pn = (-pd[1], pd[0])
        nn = (-nd[1], nd[0])
        sx, sy = pn[0] + nn[0], pn[1] + nn[1]
        sl = math.hypot(sx, sy)
        local = offsets[i]
        normal, scale = nn, local
        if sl > 0.001:
            normal = (sx / sl, sy / sl)
            denom = normal[0] * nn[0] + normal[1] * nn[1]
            if denom > 0.25:
                scale = local / denom
        maximum_miter = abs(local) * 1.75
        scale = (max(0.0, min(maximum_miter, scale)) if local >= 0
                 else min(0.0, max(-maximum_miter, scale)))
        out.append((points[i][0] + normal[0] * scale,
                    points[i][1] + normal[1] * scale))
        lateral.append(scale * (normal[0] * nn[0] + normal[1] * nn[1]))
    return out, lateral


def segments_cross(a1, a2, b1, b2, epsilon=CROSSING_EPSILON):
    """LaneHarness.segmentsCross: a proper intersection, interior to both."""
    d1x, d1y = a2[0] - a1[0], a2[1] - a1[1]
    d2x, d2y = b2[0] - b1[0], b2[1] - b1[1]
    denominator = d1x * d2y - d1y * d2x
    if abs(denominator) < 1e-12:
        return False
    t = ((b1[0] - a1[0]) * d2y - (b1[1] - a1[1]) * d2x) / denominator
    u = ((b1[0] - a1[0]) * d1y - (b1[1] - a1[1]) * d1x) / denominator
    return (epsilon < t < 1 - epsilon) and (epsilon < u < 1 - epsilon)


def inside(stacked, index, guard=GUARD_SEGMENTS):
    """Both ends of a stacked run clear of `guard` segments: a merge at a
    junction is inherent, an ordering artifact inside the run is not."""
    if not stacked[index]:
        return False
    low = index
    while low > 0 and stacked[low - 1]:
        low -= 1
    high = index
    while high < len(stacked) - 1 and stacked[high + 1]:
        high += 1
    return (index - low) >= guard and (high - index) >= guard


def load(export_path):
    """Every journey's drawn ribbon, keyed to the export's own fields."""
    with open(export_path) as handle:
        document = json.load(handle)
    journeys = {j["id"]: j for j in document["journeys"]}
    lanes = []
    for layout in document["layouts"]:
        journey = journeys[layout["journeyID"]]
        coords = journey["polylines"][max(layout["polylineIndex"], 0)]
        aligned = [project(lat, lon) for lat, lon in coords]
        points, lateral = ribbon(
            aligned, layout["offsets"],
            meters_per_unit(coords[0][0])
        )
        lanes.append({
            "id": journey["id"],
            "route": journey["routeNumber"],
            "agency": journey["agency"],
            "coords": coords,
            "points": points,
            "lateral": lateral,
            "offsets": layout["offsets"],
            "shared": layout["shared"],
            "trunk": layout["trunk"],
        })
    return document, lanes


def crossings(lanes, guard=GUARD_SEGMENTS):
    """Every proper crossing, split into all crossings and the in-bundle ones.

    Returns two lists of `(x, y, laneIndexA, laneIndexB)`.
    """
    all_crossings = []
    bundle_crossings = []
    for i in range(len(lanes)):
        a = lanes[i]
        for j in range(i + 1, len(lanes)):
            b = lanes[j]
            for ai in range(len(a["points"]) - 1):
                for bi in range(len(b["points"]) - 1):
                    if not segments_cross(a["points"][ai], a["points"][ai + 1],
                                          b["points"][bi], b["points"][bi + 1]):
                        continue
                    x, y = a["points"][ai]
                    all_crossings.append((x, y, i, j))
                    if (inside(a["shared"], ai, guard)
                            and inside(b["shared"], bi, guard)):
                        bundle_crossings.append((x, y, i, j))
    return all_crossings, bundle_crossings
