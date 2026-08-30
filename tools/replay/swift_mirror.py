"""LITERAL transliteration of TripPathGeometry.swift as committed, for
diffing against the user's Xcode results. Line-by-line from source, NOT
from notch2.py. If this reproduces the Xcode failures, the bug is in the
transliterated logic; if it passes, the bug is elsewhere (target/harness).
"""
import math

WORLD = 268435456.0


def map_point(lat, lon):
    x = (lon + 180.0) / 360.0 * WORLD
    s = math.sin(math.radians(lat))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * WORLD
    return (x, y)


def mpm(lat):  # 1.0 / MKMapPointsPerMeterAtLatitude
    return math.cos(math.radians(lat)) / (WORLD / (2 * math.pi * 6378137.0))


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def unit_heading(start, end):
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    length = math.hypot(dx, dy)
    if not (length > 0.000001):
        return None
    return (dx / length, dy / length)


def perp_distance(point, start, end):
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    l2 = dx * dx + dy * dy
    if not (l2 > 0):
        return dist(point, start)
    progress = max(0.0, min(1.0, ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / l2))
    return dist(point, (start[0] + progress * dx, start[1] + progress * dy))


def travel_heading(points, index, backward, m):
    step = -1 if backward else 1
    far = index
    traveled = 0.0
    steps = 0
    while steps < 3:
        nxt = far + step
        if not (0 <= nxt < len(points)):
            break
        segment = dist(points[far], points[nxt]) * m
        if traveled > 0 and traveled + segment > 60:
            break
        traveled += segment
        far = nxt
        steps += 1
    if far == index:
        return None
    return (unit_heading(points[far], points[index]) if backward
            else unit_heading(points[index], points[far]))


# ---- removingSinglePointSpikes (literal) ----
def remove_single_point_spikes(coords):
    if len(coords) < 3:
        return list(coords)
    m = mpm(coords[0][0])
    result = list(coords)
    i = 1
    while i < len(result) - 1:
        prev = map_point(*result[i - 1])
        cand = map_point(*result[i])
        nxt = map_point(*result[i + 1])
        incoming = dist(prev, cand) * m
        outgoing = dist(cand, nxt) * m
        bypass = dist(prev, nxt) * m
        large = incoming > 300 and outgoing > 300 and bypass < 75 and bypass * 8 < incoming + outgoing
        tiny = (incoming >= 2 and outgoing >= 2 and incoming <= 40 and outgoing <= 40
                and bypass <= 2)
        if large or tiny:
            del result[i]
            if i > 1:
                i -= 1
        else:
            i += 1
    return result


# ---- firstOutAndBackSpurRange (literal) ----
def first_spur_range(coords, m):
    points = [map_point(*c) for c in coords]
    for a in range(1, len(points) - 1):
        spur_len = 0.0
        for r in range(a + 1, len(points) - 1):
            spur_len += dist(points[r - 1], points[r]) * m
            if spur_len > 150:
                break
            if not (spur_len >= 20):
                continue
            return_dist = dist(points[a], points[r]) * m
            if not (return_dist <= min(12, max(6, spur_len * 0.08))):
                continue
            hin = unit_heading(points[a - 1], points[a])
            hout = unit_heading(points[r], points[r + 1])
            if hin is None or hout is None:
                continue
            if not (hin[0] * hout[0] + hin[1] * hout[1] >= 0.5):
                continue
            depth = 0.0
            for k in range(a + 1, r):
                depth = max(depth, perp_distance(points[k], points[a], points[r]) * m)
            if not (depth >= 12):
                continue
            return (a + 1, r)
    return None


def remove_spurs(coords):
    if len(coords) < 4:
        return list(coords)
    m = mpm(coords[0][0])
    result = list(coords)
    for _ in range(32):
        rng = first_spur_range(result, m)
        if rng is None:
            break
        del result[rng[0]:rng[1]]
    return result


# ---- splitPolyline (literal) ----
def split_polyline(coords, max_jump):
    if not coords:
        return []
    m = mpm(coords[0][0])
    result = []
    current = [coords[0]]
    for coord in coords[1:]:
        prev = current[-1]
        d = dist(map_point(*prev), map_point(*coord)) * m
        if d < 0.05:
            continue
        elif d > max_jump:
            if len(current) >= 2:
                result.append(current)
            current = [coord]
        else:
            current.append(coord)
    if len(current) >= 2:
        result.append(current)
    return result


# ---- firstStopConnectorNotchRange (literal, 47fe06c) ----
def first_notch(points, stop_points, m):
    for a in range(1, len(points) - 1):
        hin = travel_heading(points, a, True, m)
        if hin is None:
            continue
        path_len = 0.0
        for r in range(a + 1, len(points) - 1):
            path_len += dist(points[r - 1], points[r]) * m
            if path_len > 260:
                break
            chord = dist(points[a], points[r]) * m
            if not (1 <= chord <= 240):
                continue
            depth = 0.0
            apex = a + 1
            for k in range(a + 1, r):
                d = perp_distance(points[k], points[a], points[r]) * m
                if d > depth:
                    depth = d
                    apex = k
            if not (3 <= depth <= 25):
                continue
            if not any(dist(s, points[apex]) * m <= 12 for s in stop_points):
                continue
            hout = travel_heading(points, r, False, m)
            if hout is None:
                continue
            dx = points[r][0] - points[a][0]
            dy = points[r][1] - points[a][1]
            if not (abs(dx * hin[1] - dy * hin[0]) * m <= 8):
                continue
            if not (abs(dx * hout[1] - dy * hout[0]) * m <= 8):
                continue
            if not (hin[0] * hout[0] + hin[1] * hout[1] >= 0.9):
                continue
            leg_in = unit_heading(points[a], points[apex])
            leg_out = unit_heading(points[apex], points[r])
            if leg_in is None or leg_out is None:
                continue
            steep_in = abs(leg_in[0] * hin[0] + leg_in[1] * hin[1]) <= 0.766
            steep_out = abs(leg_out[0] * hin[0] + leg_out[1] * hin[1]) <= 0.766
            if not (steep_in or steep_out):
                continue
            return (a + 1, r)
    return None


def is_terminal_stop_connector(points, stop_points, m, end):
    if len(points) < 3:
        return False
    if end == 'last':
        vertex = points[len(points) - 1]
        approach = points[len(points) - 2]
        approach_index = len(points) - 2
        step = -1
    else:
        vertex = points[0]
        approach = points[1]
        approach_index = 1
        step = 1
    if not any(dist(s, vertex) * m <= 12 for s in stop_points):
        return False
    baseline = approach_index
    skipped = 0
    while (0 <= baseline < len(points)
           and dist(points[baseline], vertex) * m <= 25
           and skipped < 8):
        nxt = baseline + step
        if end == 'last' and nxt < 1:
            break
        if end == 'first' and nxt > len(points) - 2:
            break
        baseline = nxt
        skipped += 1
    if not (0 <= baseline < len(points)):
        return False
    street = travel_heading(points, baseline, end == 'last', m)
    depart = unit_heading(approach, vertex)
    if street is None or depart is None:
        return False
    return abs(depart[0] * street[0] + depart[1] * street[1]) <= 0.34


def remove_notches(coords, stops):
    if len(coords) < 4 or not stops:
        return list(coords)
    m = mpm(coords[0][0])
    stop_points = [map_point(*s) for s in stops]
    result = list(coords)
    passes = 0
    while passes < 128:
        passes += 1
        points = [map_point(*c) for c in result]
        rng = first_notch(points, stop_points, m)
        if rng is None:
            break
        del result[rng[0]:rng[1]]
    for end in ('last', 'first'):
        drops = 0
        while drops < 3 and len(result) >= 4:
            points = [map_point(*c) for c in result]
            if not is_terminal_stop_connector(points, stop_points, m, end):
                break
            if end == 'last':
                result.pop()
            else:
                result.pop(0)
            drops += 1
    return result


def cleaned_shape(coords, stops=None):
    r = remove_single_point_spikes(coords)
    r = remove_spurs(r)
    if stops:
        r = remove_notches(r, stops)
    return r
