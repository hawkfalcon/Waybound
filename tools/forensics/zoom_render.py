"""Zoom-exact render port: dedup + collapse-ribbon + RDP + trunk/detail/isolated.

Reproduces RouteLaneRenderer.draw in map-point space at a given zoom level
for the selected journey (route 5 owns the downtown trunk live) and reports
pink-on-pink crossings (self + between its own three paths) near the
downtown corners v1/v16/v26.

Usage: python3 zoom_render.py <export.json> <level> [level...]
"""
import math
import sys

sys.path.insert(0, '/home/user/Waybound/tools/lane-visualization')
sys.path.insert(0, '/home/user/Waybound/tools/forensics')
from lane_geometry import meters_per_unit, ribbon, segments_cross  # noqa: E402
import drawn_paths as P  # noqa: E402 (runs pipeline; needs argv[1])

J5 = 11893980750


def zoom_params(level):
    z = 2.0 ** (level - 20)
    lin = max(0.0, min(1.0, (level - 13) / 1.75))
    p = lin * lin * (3 - 2 * lin)
    prog = max(0.0, min(1.0, (level - 13.75) / 3.5))
    spacing = 5.0 + prog * 2.8 * 0.85 + 1.1
    return z, p, spacing / 4.2


def perp(pt, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    L2 = dx * dx + dy * dy
    if L2 <= 0:
        return math.hypot(pt[0] - a[0], pt[1] - a[1])
    t = ((pt[0] - a[0]) * dx + (pt[1] - a[1]) * dy) / L2
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return math.hypot(pt[0] - (a[0] + t * dx), pt[1] - (a[1] + t * dy))


def rdp(points, tol):
    ded = []
    for pt in points:
        if ded and math.hypot(pt[0] - ded[-1][0], pt[1] - ded[-1][1]) <= tol * 0.35:
            continue
        ded.append(pt)
    if len(ded) <= 2:
        return ded

    def rec(s, e):
        if e <= s + 1:
            return [ded[s], ded[e]]
        best, bi = 0.0, None
        for i in range(s + 1, e):
            dd = perp(ded[i], ded[s], ded[e])
            if dd > best:
                best, bi = dd, i
        if not (best > tol and bi is not None):
            return [ded[s], ded[e]]
        return rec(s, bi)[:-1] + rec(bi, e)

    return rec(0, len(ded) - 1)


def seg_runs(points, included, tol):
    runs, run = [], []
    for i, inc in enumerate(included):
        if inc:
            if not run:
                run.append(points[i])
            run.append(points[i + 1])
        elif run:
            if len(run) >= 2:
                s = rdp(run, tol)
                if len(s) >= 2:
                    runs.append(s)
            run = []
    if len(run) >= 2:
        s = rdp(run, tol)
        if len(s) >= 2:
            runs.append(s)
    return runs


def dedup(points, offsets, shared, trunk, min_dist):
    pts, off, shr, iso, trk = [], [], [], [], []
    for i, pt in enumerate(points):
        s = shared[i]
        t = trunk[i]
        if pts and math.hypot(pt[0] - pts[-1][0], pt[1] - pts[-1][1]) <= min_dist:
            if abs(offsets[i]) >= abs(off[-1]):
                off[-1] = offsets[i]
            shr[-1] = shr[-1] or s
            iso[-1] = iso[-1] or (not s)
            trk[-1] = trk[-1] or t
            continue
        pts.append(pt)
        off.append(offsets[i])
        shr.append(s)
        iso.append(not s)
        trk.append(t)
    return pts, off, shr, iso, trk


def render(jid, level, selected):
    d = P.RAW[jid]
    ctr = P.CENTERS[jid][0]
    mpp = d['mpp']
    z, p, los = zoom_params(level)
    detail_p = 1.0 if selected else p
    off_map = [o * los * detail_p / z for o in d['off']]
    trunk_live = [(s and selected) or (t and not selected)
                  for s, t in zip(d['shared'], d['trunk'])] \
        if jid == J5 else d['trunk']
    # selected route 5 owns every shared segment live (dominance)
    if jid == J5 and selected:
        trunk_live = list(d['shared'])
    pts, off, shr, iso, trk = dedup(ctr, off_map, d['shared'], trunk_live,
                                    0.245 / z)
    opt, _ = ribbon(pts, off, mpp, screen_points_per_map_point=mpp)
    n = len(opt) - 1
    shared_seg = [shr[i] and shr[i + 1] for i in range(n)]
    bnd = [(shared_seg[i] and ((i > 0 and not shared_seg[i - 1]) or
                               (i + 1 < n and not shared_seg[i + 1])))
           for i in range(n)]
    corner_zone = [(bnd[i] or (i > 0 and bnd[i - 1]) or
                    (i + 1 < n and bnd[i + 1])) for i in range(n)]
    isolated_seg = [(not shared_seg[i]) or (iso[i] and iso[i + 1]) or bnd[i]
                    for i in range(n)]
    owned = [(shared_seg[i] and trk[i] and trk[i + 1]
              and not corner_zone[i]) for i in range(n)]
    tol = 0.9 / z
    return dict(iso=seg_runs(opt, isolated_seg, tol),
                det=seg_runs(opt, shared_seg, tol),
                trk=seg_runs(pts, owned, tol),
                z=z, p=p, trunk_prog=1 - p, detail_p=detail_p,
                n_pts=len(pts), n_raw=d['n'])


def window_cross(paths, cx, cy, rad):
    segs = []
    for name, runs in paths.items():
        for r in runs:
            for i in range(len(r) - 1):
                mx = (r[i][0] + r[i + 1][0]) / 2
                my = (r[i][1] + r[i + 1][1]) / 2
                if math.hypot(mx - cx, my - cy) <= rad:
                    segs.append((name, r[i], r[i + 1]))
    out = []
    for a in range(len(segs)):
        for b in range(a + 1, len(segs)):
            if segments_cross(segs[a][1], segs[a][2], segs[b][1], segs[b][2]):
                out.append((segs[a][0], segs[b][0]))
    return out, len(segs)


def main():
    levels = [float(a) for a in sys.argv[2:]] or [11, 12, 13, 14, 15, 16, 17]
    mpp5 = P.RAW[J5]['mpp']
    Jx, Jy = P.project(P.J_LAT, P.J_LON)
    anchors = {}
    for tag, vi in (('v1', 1), ('v16', 16), ('v26', 26)):
        c = P.CENTERS[J5][0][vi]
        anchors[tag] = c
    for level in levels:
        r = render(J5, level, True)
        print('=== level %.1f (z=%.4f detailP=%.2f trunkP=%.2f pts %d/%d) ==='
              % (level, r['z'], r['detail_p'], r['trunk_prog'],
                 r['n_pts'], P.RAW[J5]['n']))
        for tag, (cx, cy) in anchors.items():
            # radius 120 m in map points
            res, nseg = window_cross(
                {'iso': r['iso'], 'det': r['det'], 'trk': r['trk']},
                cx, cy, 120.0 / mpp5)
            if res:
                kinds = {}
                for a, b in res:
                    k = '+'.join(sorted((a, b)))
                    kinds[k] = kinds.get(k, 0) + 1
                print('  %s: %d pink crossings %s (%d segs in window)'
                      % (tag, len(res), kinds, nseg))
            else:
                print('  %s: clean (%d segs in window)' % (tag, nseg))


main()
print('DONE')
