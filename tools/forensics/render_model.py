"""Mirror the app's route-lane renderer at a chosen map zoom level.

Everything here follows Waybound/Views/WayboundMapView.swift:

    RouteMapStyle.zoomLevel / detailProgress / laneSpacing / laneOffsetScale
    deduplicatedRouteLaneSamples
    stableRouteOffsetPoints
    routeSegmentPath / simplifiedRoutePoints

Units: screen points.  One map point = metersPerUnit metres, and
zoomScale (MKZoomScale) is screen points per map point, so
    screen points per metre = zoomScale / metersPerUnit
and, since RouteMapStyle.zoomLevel = log2(zoomScale) + 20,
    metres per screen point = metersPerUnit * 2**(20 - zoomLevel).
"""

import json
import math

WORLD = 268_435_456
EARTH_SEMI_MAJOR = 6_378_137

# RouteMapStyle
STANDARD_LINE_WIDTH = 5.0
SEPARATOR_WIDTH = 1.1
TRUNK_LINE_WIDTH = 6.0
LANE_SPACING_POINTS = 4.2


def meters_per_unit(latitude):
    return math.cos(math.radians(latitude)) * 2 * math.pi * EARTH_SEMI_MAJOR / WORLD


def project(latitude, longitude):
    x = (longitude + 180.0) / 360.0 * WORLD
    s = math.sin(math.radians(latitude))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * WORLD
    return x, y


def zoom_level(zoom_scale):
    return math.log2(max(zoom_scale, 1e-7)) + 20


def detail_progress(zoom_scale):
    linear = max(0.0, min(1.0, (zoom_level(zoom_scale) - 13) / 1.75))
    return linear * linear * (3 - 2 * linear)


def zoom_line_expansion(zoom_scale):
    progress = max(0.0, min(1.0, (zoom_level(zoom_scale) - 13.75) / 3.5))
    return progress * 2.8


def lane_spacing(zoom_scale):
    return STANDARD_LINE_WIDTH + zoom_line_expansion(zoom_scale) * 0.85 + SEPARATOR_WIDTH


def lane_offset_scale(zoom_scale):
    return lane_spacing(zoom_scale) / LANE_SPACING_POINTS


class Samples:
    def __init__(self, points, offsets, shared, isolated, trunk):
        self.points = points
        self.offsets = offsets
        self.shared = shared
        self.isolated = isolated
        self.trunk = trunk


def deduplicated_samples(points, offsets, shared, trunk, minimum_distance):
    """deduplicatedRouteLaneSamples."""
    n = len(points)
    if len(offsets) != n:
        return Samples(points, [0.0] * n, [False] * n, [True] * n, [False] * n)
    has_shared = len(shared) == n
    has_trunk = len(trunk) == n
    out_points, out_offsets, out_shared, out_isolated, out_trunk = [], [], [], [], []
    for index in range(n):
        point = points[index]
        is_shared = shared[index] if has_shared else False
        is_trunk = trunk[index] if has_trunk else False
        if out_points:
            px, py = out_points[-1]
            if math.hypot(point[0] - px, point[1] - py) <= minimum_distance:
                last = len(out_points) - 1
                if abs(offsets[index]) >= abs(out_offsets[last]):
                    out_offsets[last] = offsets[index]
                out_shared[last] = out_shared[last] or is_shared
                out_isolated[last] = out_isolated[last] or (not is_shared)
                out_trunk[last] = out_trunk[last] or is_trunk
                continue
        out_points.append(point)
        out_offsets.append(offsets[index])
        out_shared.append(is_shared)
        out_isolated.append(not is_shared)
        out_trunk.append(is_trunk)
    return Samples(out_points, out_offsets, out_shared, out_isolated, out_trunk)


def stable_route_offset_points(points, offsets):
    """stableRouteOffsetPoints."""
    n = len(points)
    if n < 2 or len(offsets) != n:
        return list(points)
    if not any(abs(o) > 0.0001 for o in offsets):
        return list(points)

    directions, lengths = [], []
    previous = None
    for i in range(n - 1):
        dx = points[i + 1][0] - points[i][0]
        dy = points[i + 1][1] - points[i][1]
        raw_length = math.hypot(dx, dy)
        length = max(1e-4, raw_length)
        ux, uy = dx / length, dy / length
        if previous and ux * previous[0] + uy * previous[1] < -0.8:
            ux, uy = -ux, -uy
        directions.append((ux, uy))
        lengths.append(raw_length)
        previous = (ux, uy)

    natural, sines, reach = [], [], []
    for i in range(n):
        pd = directions[i - 1 if i > 0 else 0]
        nd = directions[i if i < n - 1 else n - 2]
        pn = (-pd[1], pd[0])
        nn = (-nd[1], nd[0])
        sx, sy = pn[0] + nn[0], pn[1] + nn[1]
        sl = math.hypot(sx, sy)
        local = offsets[i]
        normal, scale, sine = nn, float(local), 0.0
        if sl > 0.001:
            normal = (sx / sl, sy / sl)
            denom = normal[0] * nn[0] + normal[1] * nn[1]
            if denom > 0.25:
                scale = local / denom
            if 0 < i < n - 1:
                sine = math.sqrt(max(0.0, 1.0 - denom * denom))
        maximum = abs(local) * 1.75
        if local >= 0:
            scale = max(0.0, min(maximum, scale))
        else:
            scale = min(0.0, max(-maximum, scale))
        natural.append((points[i][0] + normal[0] * scale,
                        points[i][1] + normal[1] * scale))
        sines.append(sine)
        reach.append(abs(scale))

    output = list(natural)
    if n > 2:
        claims = [[] for _ in range(n)]
        for apex in range(1, n - 1):
            if sines[apex] <= 0.02:
                continue
            apex_reach = reach[apex] * sines[apex]
            for direction in (-1, 1):
                path_distance = 0.0
                cursor = apex
                while True:
                    nxt = cursor + direction
                    if not (0 < nxt < n - 1):
                        break
                    if sines[nxt] > 0.1:
                        break
                    path_distance += lengths[min(cursor, nxt)]
                    if not path_distance < apex_reach:
                        break
                    claims[nxt].append(natural[apex])
                    cursor = nxt
        for middle in range(1, n - 1):
            if len(claims[middle]) == 1:
                output[middle] = claims[middle][0]
            elif len(claims[middle]) > 1:
                count = len(claims[middle])
                output[middle] = (
                    sum(c[0] for c in claims[middle]) / count,
                    sum(c[1] for c in claims[middle]) / count,
                )
    return output


def perpendicular_distance(point, start, end):
    dx, dy = end[0] - start[0], end[1] - start[1]
    l2 = dx * dx + dy * dy
    if l2 <= 0:
        return math.hypot(point[0] - start[0], point[1] - start[1])
    t = max(0.0, min(1.0, ((point[0] - start[0]) * dx
                           + (point[1] - start[1]) * dy) / l2))
    proj = (start[0] + dx * t, start[1] + dy * t)
    return math.hypot(point[0] - proj[0], point[1] - proj[1])


def simplified_route_points(points, tolerance):
    """simplifiedRoutePoints (RDP, peak first, strict improvement)."""
    if len(points) <= 2:
        return list(points)
    dedup = []
    for point in points:
        if dedup and math.hypot(point[0] - dedup[-1][0],
                                point[1] - dedup[-1][1]) <= tolerance * 0.35:
            continue
        dedup.append(point)
    if len(dedup) <= 2:
        return dedup

    keep = [False] * len(dedup)
    keep[0] = keep[-1] = True
    stack = [(0, len(dedup) - 1)]
    while stack:
        low, high = stack.pop()
        if high <= low + 1:
            continue
        start, end = dedup[low], dedup[high]
        worst_index, worst_distance = -1, 0.0
        for index in range(low + 1, high):
            distance = perpendicular_distance(dedup[index], start, end)
            if distance > worst_distance:
                worst_distance, worst_index = distance, index
        if worst_index >= 0 and worst_distance > tolerance:
            keep[worst_index] = True
            stack.append((low, worst_index))
            stack.append((worst_index, high))
    return [dedup[i] for i in range(len(dedup)) if keep[i]]


def route_segment_path(points, included, tolerance):
    runs, current = [], []
    for index, flag in enumerate(included):
        if flag:
            if not current:
                current.append(points[index])
            current.append(points[index + 1])
        elif current:
            runs.append(current)
            current = []
    if current:
        runs.append(current)
    out = []
    for run in runs:
        if len(run) < 2:
            continue
        simplified = simplified_route_points(run, tolerance)
        if len(simplified) >= 2:
            out.append(simplified)
    return out


class Rendered:
    """Everything the renderer derives for one overlay at one zoom."""

    def __init__(self, **kw):
        self.__dict__.update(kw)


def render(journey, layout, zoom_scale, is_selected=False):
    coords = journey["polylines"][max(layout.get("polylineIndex", 0), 0)]
    latitude = coords[0][0]
    mpu = meters_per_unit(latitude)
    # MKMapPoint in, then every screen quantity is divided by zoomScale, so
    # work directly in screen points: 1 screen point = 2**(zoomLevel-20) map
    # points.
    mpp = 2.0 ** (zoom_level(zoom_scale) - 20)
    raw_points = [(project(lat, lon)[0] * mpp, project(lat, lon)[1] * mpp)
                  for lat, lon in coords]
    zoom_detail = detail_progress(zoom_scale)
    detail = 1.0 if is_selected else zoom_detail
    offset_scale = lane_offset_scale(zoom_scale) * detail
    # The renderer works in map points and divides every screen-point
    # quantity by zoomScale; this model works in screen points, so those
    # divisions cancel: offsets are plain screen points and the dedup
    # radius and RDP tolerance are the literal 0.245 / 0.9 points.
    raw_offsets = [o * offset_scale for o in layout["offsets"]]
    shared = layout["shared"]
    trunk = layout["trunk"]
    minimum = 0.245
    s = deduplicated_samples(raw_points, raw_offsets, shared, trunk, minimum)
    offset_points = stable_route_offset_points(s.points, s.offsets)
    segment_count = len(offset_points) - 1
    has_shared = len(s.shared) == len(offset_points)
    has_trunk = len(s.trunk) == len(offset_points)
    shared_segments = [has_shared and s.shared[i] and s.shared[i + 1]
                       for i in range(segment_count)]
    boundary_joints = [
        shared_segments[i]
        and ((i > 0 and not shared_segments[i - 1])
             or (i + 1 < segment_count and not shared_segments[i + 1]))
        for i in range(segment_count)
    ]
    corner_zone = [
        boundary_joints[i]
        or (i > 0 and boundary_joints[i - 1])
        or (i + 1 < segment_count and boundary_joints[i + 1])
        for i in range(segment_count)
    ]
    isolated_segments = [
        (not shared_segments[i])
        or (s.isolated[i] and s.isolated[i + 1])
        or boundary_joints[i]
        for i in range(segment_count)
    ]
    owned_trunk = [
        shared_segments[i] and has_trunk and s.trunk[i] and s.trunk[i + 1]
        and not corner_zone[i]
        for i in range(segment_count)
    ]
    tolerance = 0.9
    return Rendered(
        raw_points=raw_points,
        raw_offsets=raw_offsets,
        coords=coords,
        latitude=latitude,
        meters_per_unit=mpu,
        mpp=mpp,
        zoom_detail_progress=zoom_detail,
        detail_progress=detail,
        trunk_progress=1 - zoom_detail,
        samples=s,
        offset_points=offset_points,
        segment_count=segment_count,
        shared_segments=shared_segments,
        boundary_joints=boundary_joints,
        corner_zone=corner_zone,
        isolated_segments=isolated_segments,
        owned_trunk=owned_trunk,
        tolerance=tolerance,
        isolated_path=route_segment_path(offset_points, isolated_segments, tolerance),
        detail_path=route_segment_path(offset_points, shared_segments, tolerance),
        trunk_path=route_segment_path(s.points, owned_trunk, tolerance),
    )
