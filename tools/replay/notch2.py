"""Notch-stage harness matching the UPDATED Swift gates:
  path <= 160 m, chord <= 120 m, depth 3-25 m, apex <= 12 m from a stop,
  street continues straight through (anchor and return each within 8 m of the
  other leg's line, heading-through dot >= 0.9), plus terminal-connector
  trimming (drop a final/first vertex that is a stop reached >= 70 degrees
  off the street line)."""
import math
from geo import to_map_point, to_coord, dist, perp_distance, mpm

def unit(a, b):
    dx, dy = b[0]-a[0], b[1]-a[1]
    l = math.hypot(dx, dy)
    return None if l < 1e-9 else (dx/l, dy/l)

def heading_over(pts, i, step, m, max_len=60.0, max_steps=3):
    """Travel heading at i, over up to ~60 m / 3 vertices. Normalized to the
    direction of travel regardless of step sign."""
    acc = 0.0
    j = i
    for _ in range(max_steps):
        nxt = j + step
        if nxt < 0 or nxt >= len(pts): break
        seg = dist(pts[j], pts[nxt]) * m
        if acc > 0 and acc + seg > max_len: break
        acc += seg
        j = nxt
    if j == i: return None
    a, b = (pts[i], pts[j]) if step > 0 else (pts[j], pts[i])
    return unit(a, b)

def first_notch(pts, m, stop_pts, max_path=160.0, max_chord=120.0,
                min_depth=3.0, max_depth=25.0, max_stop_dist=12.0,
                max_line_offset=8.0, min_dot=0.9, max_leg_angle_deg=40.0):
    n = len(pts)
    for a in range(1, n - 1):
        hprev = heading_over(pts, a, -1, m)
        if hprev is None: continue
        path_len = 0.0
        for r in range(a + 1, n - 1):
            path_len += dist(pts[r-1], pts[r]) * m
            if path_len > max_path: break
            chord = dist(pts[a], pts[r]) * m
            if chord > max_chord or chord < 1.0: continue
            interior = pts[a+1:r]
            if not interior: continue
            depths = [perp_distance(p, pts[a], pts[r]) * m for p in interior]
            dmax = max(depths)
            if dmax < min_depth or dmax > max_depth: continue
            apex = interior[depths.index(dmax)]
            if min(dist(apex, s) * m for s in stop_pts) > max_stop_dist: continue
            hnext = heading_over(pts, r, +1, m)
            if hnext is None: continue
            # Street continues straight through, tested against BOTH legs:
            # the return sits on the incoming line and the anchor sits on the
            # outgoing line. The stop itself must not qualify as the return.
            dx = pts[r][0]-pts[a][0]; dy = pts[r][1]-pts[a][1]
            if abs(dx*hprev[1] - dy*hprev[0]) * m > max_line_offset: continue
            if abs(dx*hnext[1] - dy*hnext[0]) * m > max_line_offset: continue
            if hprev[0]*hnext[0] + hprev[1]*hnext[1] < min_dot: continue
            # A connector reaches its stop steeply off the street; a curve's
            # legs diverge from the chord gradually. At least one leg must
            # leave the street line by >= max_leg_angle_deg.
            leg_in = unit(pts[a], apex)
            leg_out = unit(apex, pts[r])
            if leg_in is None or leg_out is None: continue
            cos_max = math.cos(math.radians(max_leg_angle_deg))
            steep = (abs(leg_in[0]*hprev[0] + leg_in[1]*hprev[1]) <= cos_max
                     or abs(leg_out[0]*hprev[0] + leg_out[1]*hprev[1]) <= cos_max)
            if not steep: continue
            return (a + 1, r)
    return None

def trim_terminal(pts, m, stop_pts, end, max_stop_dist=12.0, max_depart_dot=0.34):
    """end='last' or 'first'. Drops a terminal vertex that is a stop reached
    steeply off the street line the shape was traveling."""
    n = len(pts)
    if end == 'last':
        v, u, h = pts[n-1], pts[n-2], heading_over(pts, n-2, -1, m)
    else:
        v, u, h = pts[0], pts[1], heading_over(pts, 1, +1, m)
    if h is None: return False
    if min(dist(v, s) * m for s in stop_pts) > max_stop_dist: return False
    hv = unit(u, v)
    if hv is None: return False
    return (hv[0]*h[0] + hv[1]*h[1]) <= max_depart_dot

def removing_stop_connector_notches(coords, stops, max_passes=64):
    if len(coords) < 4 or not stops: return list(coords)
    m = mpm(coords[0][0])
    stop_pts = [to_map_point(*s) for s in stops]
    result = list(coords)
    for _ in range(max_passes):
        pts = [to_map_point(*c) for c in result]
        rng = first_notch(pts, m, stop_pts)
        if rng is None: break
        del result[rng[0]:rng[1]]
    pts = [to_map_point(*c) for c in result]
    if trim_terminal(pts, m, stop_pts, 'last'):
        result.pop()
        pts = [to_map_point(*c) for c in result]
    if trim_terminal(pts, m, stop_pts, 'first'):
        result.pop(0)
    return result
