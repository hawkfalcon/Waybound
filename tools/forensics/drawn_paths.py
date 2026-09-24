"""Faithful port of the app's drawn-centerline pipeline + true-scale crossings.

Pipeline (WayboundMapView, committed through ddf7d3b):
  local scan (20m / |dot|>=0.93, midpoint+endpoints, nearest wins)
  -> schedule sticky ref (read from the export) -> clamped projection (8m gate)
  -> street-anchor (sticky only, 30m) -> per-vertex average -> bridge gaps
  -> stabilize (0.25/0.5/0.25) -> taper (58m) -> clamp (0.08) + corner hold
  -> smoothSharedLateralCenters (sigma 30, +-3 verts, curvature gate)
  -> ribbon (lane_geometry, TRUE scale k=mpp AND 2x convention)
  -> crossings within 60m of J=(34.421250,-119.706710).

Usage: python3 drawn_paths.py <export.json>
"""
import json
import math
import re
import sys
from functools import cmp_to_key

sys.path.insert(0, '/home/user/Waybound/tools/lane-visualization')
from lane_geometry import (  # noqa: E402
    project, meters_per_unit, ribbon, segments_cross,
)

J_LAT, J_LON = 34.421250, -119.706710
R_NEAR = 60.0      # crossing report radius (m)
R_KEEP = 250.0     # journey prefilter radius (m)

export_path = sys.argv[1]
doc = json.load(open(export_path))
journeys = {j['id']: j for j in doc['journeys']}
layouts = {(l['journeyID'], l['polylineIndex']): l for l in doc['layouts']}
schedules = {(s['journeyID'], s['polylineIndex']): s for s in doc['schedule']}


def ground_dist(lat1, lon1, lat2, lon2):
    return math.hypot((lat1 - lat2) * 111320.0,
                      (lon1 - lon2) * 111320.0 * math.cos(math.radians(lat1)))


# ---- journey prefilter: keep journeys passing within R_KEEP of J ----
keep = []
for jid, j in journeys.items():
    if (jid, 0) not in layouts:
        continue
    best = min(ground_dist(v[0], v[1], J_LAT, J_LON) for v in j['polylines'][0])
    if best <= R_KEEP:
        keep.append(jid)
print('journeys within %.0fm of J:' % R_KEEP,
      [(journeys[i]['routeNumber'], i) for i in keep], flush=True)

# ---- per-journey raw data in map points ----
RAW = {}
for jid in keep:
    j = journeys[jid]
    coords = j['polylines'][0]
    pts = [project(lat, lon) for lat, lon in coords]
    mpp = meters_per_unit(coords[0][0])
    lay = layouts[(jid, 0)]
    sched = {}
    for e in schedules[(jid, 0)]['entries']:
        sched[int(e[0])] = (float(e[1]), float(e[2]), float(e[3]), int(e[4]))
    RAW[jid] = dict(pts=pts, mpp=mpp, off=lay['offsets'], shared=lay['shared'],
                    trunk=lay['trunk'], sched=sched, n=len(pts))

# ---- segment arrays + grid hash (cell 25m) ----
SEG = {}
for jid in keep:
    d = RAW[jid]
    pts, mpp = d['pts'], d['mpp']
    cell = 25.0 / mpp
    segs = []   # (x1,y1,x2,y2,ux,uy,ok)
    grid = {}
    for i in range(len(pts) - 1):
        x1, y1 = pts[i]
        x2, y2 = pts[i + 1]
        dx, dy = x2 - x1, y2 - y1
        L = math.hypot(dx, dy)
        if L > 1e-6:
            ux, uy, ok = dx / L, dy / L, True
        else:
            ux, uy, ok = 0.0, 0.0, False
        segs.append((x1, y1, x2, y2, ux, uy, ok))
        if ok:
            cx0 = int(math.floor(min(x1, x2) / cell))
            cx1 = int(math.floor(max(x1, x2) / cell))
            cy0 = int(math.floor(min(y1, y2) / cell))
            cy1 = int(math.floor(max(y1, y2) / cell))
            for cx in range(cx0, cx1 + 1):
                for cy in range(cy0, cy1 + 1):
                    grid.setdefault((cx, cy), []).append(i)
    SEG[jid] = dict(segs=segs, grid=grid, cell=cell)


def match_near(qjid, px, py, dux, duy):
    """parallelCorridorSegment: nearest seg with |dot|>=0.93 and dist<=20m."""
    S = SEG[qjid]
    mpp = RAW[qjid]['mpp']
    segs, grid, cell = S['segs'], S['grid'], S['cell']
    maxd = 20.0 / mpp
    cx, cy = int(math.floor(px / cell)), int(math.floor(py / cell))
    best, bestd = None, None
    seen = set()
    for ix in range(cx - 1, cx + 2):
        for iy in range(cy - 1, cy + 2):
            for si in grid.get((ix, iy), ()):
                if si in seen:
                    continue
                seen.add(si)
                x1, y1, x2, y2, ux, uy, ok = segs[si]
                if abs(dux * ux + duy * uy) < 0.93:
                    continue
                dx, dy = x2 - x1, y2 - y1
                L2 = dx * dx + dy * dy
                t = ((px - x1) * dx + (py - y1) * dy) / L2
                t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
                hx, hy = x1 + t * dx, y1 + t * dy
                dd = math.hypot(px - hx, py - hy)
                if dd <= maxd and (bestd is None or dd < bestd):
                    best, bestd = si, dd
    return best


def comes_before(a, b):
    if a == b:
        return 0
    A, B = journeys[a], journeys[b]
    an, bn = str(A['routeNumber']), str(B['routeNumber'])
    a1, a4 = an == '1', an == '4'
    b1, b4 = bn == '1', bn == '4'
    if (a1 and b4) or (a4 and b1):
        return -1 if a4 else 1

    def nat(s):
        return [int(t) if t.isdigit() else t.lower()
                for t in re.split(r'(\d+)', s.lower())]
    ka, kb = nat(an), nat(bn)
    if ka != kb:
        return -1 if ka < kb else 1
    aa, ab = A['agency'].lower(), B['agency'].lower()
    if aa != ab:
        return -1 if aa < ab else 1
    da = A['directionID'] if A['directionID'] is not None else 10**9
    db = B['directionID'] if B['directionID'] is not None else 10**9
    if da != db:
        return -1 if da < db else 1
    if A['stackOrder'] != B['stackOrder']:
        return -1 if A['stackOrder'] < B['stackOrder'] else 1
    return -1 if a < b else 1


CENTERS = {}
for jid in keep:
    d = RAW[jid]
    pts, mpp, n = d['pts'], d['mpp'], d['n']
    shared = d['shared']
    segs = SEG[jid]['segs']
    # local scan + sticky ref + projection + street-anchor, per segment
    layouts_seg = [None] * (n - 1)
    for i in range(n - 1):
        x1, y1, x2, y2, ux, uy, ok = segs[i]
        if not ok:
            continue
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        members = {jid: i}          # journey -> matched seg idx in ITS segs
        for q in keep:
            if q == jid:
                continue
            m = match_near(q, mx, my, ux, uy)
            if m is None:
                continue
            if match_near(q, x1, y1, ux, uy) is None:
                continue
            if match_near(q, x2, y2, ux, uy) is None:
                continue
            members[q] = m
        if len(members) <= 1:
            continue
        smp = d['sched'].get(i)
        if smp is None:
            continue
        _, _, _, ref = smp
        member_ids = sorted(members.keys(), key=cmp_to_key(comes_before))
        if ref in members:
            refseg_j, refseg_i, sticky = ref, members[ref], True
        else:
            refseg_j = member_ids[0]
            refseg_i, sticky = members[refseg_j], False
        if refseg_j == jid:
            layouts_seg[i] = (x1, y1, x2, y2, refseg_j)
            continue
        qx1, qy1, qx2, qy2, qux, quy, _ = SEG[refseg_j]['segs'][refseg_i]
        # corridorProjection, clamped, 8m gate
        rdx, rdy = qx2 - qx1, qy2 - qy1
        L2 = rdx * rdx + rdy * rdy
        gate = 8.0 / mpp
        ax1, ay1, ax2, ay2 = x1, y1, x2, y2
        if L2 > 0:
            for k, (px, py) in enumerate(((x1, y1), (x2, y2))):
                t = ((px - qx1) * rdx + (py - qy1) * rdy) / L2
                t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
                hx, hy = qx1 + t * rdx, qy1 + t * rdy
                if math.hypot(px - hx, py - hy) <= gate:
                    if k == 0:
                        ax1, ay1 = hx, hy
                    else:
                        ax2, ay2 = hx, hy
        # street-anchor (sticky only)
        if sticky:
            frame = 1.0 if (ux * qux + uy * quy) >= 0 else -1.0
            nx, ny = -quy, qux
            spanx, spany = rdx, rdy
            norm2 = spanx * spanx + spany * spany
            if norm2 > 0:
                maxshift = 30.0 / mpp
                for k, (px, py) in enumerate(((ax1, ay1), (ax2, ay2))):
                    t = ((px - qx1) * spanx + (py - qy1) * spany) / norm2
                    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
                    hx, hy = qx1 + t * spanx, qy1 + t * spany
                    dd = ((px - hx) * nx + (py - hy) * ny) * frame
                    dd = -maxshift if dd < -maxshift else (
                        maxshift if dd > maxshift else dd)
                    if k == 0:
                        ax1, ay1 = px + dd * uy, py - dd * ux
                    else:
                        ax2, ay2 = px + dd * uy, py - dd * ux
        layouts_seg[i] = (ax1, ay1, ax2, ay2, refseg_j)
    # per-vertex average (package-shared endpoints only)
    dx = [0.0] * n
    dy = [0.0] * n
    base = [False] * n
    cnt = [0] * n
    for i, L in enumerate(layouts_seg):
        if L is None or not (shared[i] and shared[i + 1]):
            continue
        ax1, ay1, ax2, ay2, _ = L
        dx[i] += ax1 - pts[i][0]
        dy[i] += ay1 - pts[i][1]
        dx[i + 1] += ax2 - pts[i + 1][0]
        dy[i + 1] += ay2 - pts[i + 1][1]
        base[i] = base[i + 1] = True
        cnt[i] += 1
        cnt[i + 1] += 1
    for i in range(n):
        if base[i] and cnt[i]:
            dx[i] /= cnt[i]
            dy[i] /= cnt[i]
    # bridge gaps
    s = 0
    while s < n:
        if not (shared[s] and not base[s]):
            s += 1
            continue
        gs = s
        while s < n and shared[s] and not base[s]:
            s += 1
        ge, left, right = s, gs - 1, s
        if left >= 0 and right < n and base[left] and base[right]:
            gap = sum(math.hypot(pts[k + 1][0] - pts[k][0],
                                 pts[k + 1][1] - pts[k][1])
                      for k in range(left, right)) * mpp
            if gap > 0:
                run = 0.0
                for k in range(gs, ge):
                    run += math.hypot(pts[k][0] - pts[k - 1][0],
                                      pts[k][1] - pts[k - 1][1]) * mpp
                    p = run / gap
                    dx[k] = dx[left] + (dx[right] - dx[left]) * p
                    dy[k] = dy[left] + (dy[right] - dy[left]) * p
    # stabilize (Jacobi 0.25/0.5/0.25 over stacked triples)
    if n > 2:
        ox, oy = dx[:], dy[:]
        for i in range(1, n - 1):
            if shared[i - 1] and shared[i] and shared[i + 1]:
                dx[i] = 0.25 * ox[i - 1] + 0.5 * ox[i] + 0.25 * ox[i + 1]
                dy[i] = 0.25 * oy[i - 1] + 0.5 * oy[i] + 0.25 * oy[i + 1]
    # taper 58m
    T = 58.0
    i = 0
    while i < n:
        while i < n and not shared[i]:
            i += 1
        if i >= n:
            break
        rs = i
        while i < n and shared[i]:
            i += 1
        rend = i - 1
        bd = 0.0
        for dst in range(rs - 1, -1, -1):
            if shared[dst]:
                break
            bd += math.hypot(pts[dst][0] - pts[dst + 1][0],
                             pts[dst][1] - pts[dst + 1][1]) * mpp
            if bd >= T:
                break
            f = 1 - bd / T
            cx_, cy_ = dx[rs] * f, dy[rs] * f
            if math.hypot(cx_, cy_) > math.hypot(dx[dst], dy[dst]):
                dx[dst], dy[dst] = cx_, cy_
        fd = 0.0
        for dst in range(rend + 1, n):
            if shared[dst]:
                break
            fd += math.hypot(pts[dst - 1][0] - pts[dst][0],
                             pts[dst - 1][1] - pts[dst][1]) * mpp
            if fd >= T:
                break
            f = 1 - fd / T
            cx_, cy_ = dx[rend] * f, dy[rend] * f
            if math.hypot(cx_, cy_) > math.hypot(dx[dst], dy[dst]):
                dx[dst], dy[dst] = cx_, cy_
    # corners + clamp + hold
    rawd = []
    for k in range(n - 1):
        sx = pts[k + 1][0] - pts[k][0]
        sy = pts[k + 1][1] - pts[k][1]
        L = math.hypot(sx, sy)
        if L > 1e-6:
            rawd.append((sx / L, sy / L))
        elif rawd:
            rawd.append(rawd[-1])
        else:
            rawd.append((1.0, 0.0))
    corner = [False] * n
    if n > 2:
        for k in range(1, n - 1):
            b, a = rawd[k - 1], rawd[k]
            corner[k] = (b[0] * a[0] + b[1] * a[1]) < 0.7
    if n > 2:
        for k in range(1, n):
            if corner[k]:
                dx[k], dy[k] = dx[k - 1], dy[k - 1]
                continue
            segm = math.hypot(pts[k][0] - pts[k - 1][0],
                              pts[k][1] - pts[k - 1][1]) * mpp
            budget = 0.08 * segm
            sx_, sy_ = dx[k] - dx[k - 1], dy[k] - dy[k - 1]
            st = math.hypot(sx_, sy_)
            if st > budget and budget > 0:
                sc = budget / st
                dx[k] = dx[k - 1] + sx_ * sc
                dy[k] = dy[k - 1] + sy_ * sc
        for k in range(n - 2, -1, -1):
            if corner[k]:
                dx[k], dy[k] = dx[k + 1], dy[k + 1]
                continue
            segm = math.hypot(pts[k][0] - pts[k + 1][0],
                              pts[k][1] - pts[k + 1][1]) * mpp
            budget = 0.08 * segm
            sx_, sy_ = dx[k] - dx[k + 1], dy[k] - dy[k + 1]
            st = math.hypot(sx_, sy_)
            if st > budget and budget > 0:
                sc = budget / st
                dx[k] = dx[k + 1] + sx_ * sc
                dy[k] = dy[k + 1] + sy_ * sc
    # smoothSharedLateralCenters
    ax = [pts[k][0] + dx[k] for k in range(n)]
    ay = [pts[k][1] + dy[k] for k in range(n)]
    held = []
    prev = None
    for k in range(n - 1):
        sx_ = ax[k + 1] - ax[k]
        sy_ = ay[k + 1] - ay[k]
        L = math.hypot(sx_, sy_)
        if L <= 1e-6:
            held.append(prev if prev else (1.0, 0.0))
            prev = held[-1]
            continue
        u = (sx_ / L, sy_ / L)
        if prev and u[0] * prev[0] + u[1] * prev[1] < -0.8:
            u = (-u[0], -u[1])
        held.append(u)
        prev = u
    nX = [0.0] * n
    nY = [1.0] * n
    for k in range(n):
        p = held[max(k - 1, 0)]
        q = held[min(k, n - 2)]
        sxx = -(p[1] + q[1]) / 2
        syy = (p[0] + q[0]) / 2
        L = max(1e-6, math.hypot(sxx, syy))
        nX[k], nY[k] = sxx / L, syy / L
    arc = [0.0] * n
    for k in range(1, n):
        arc[k] = arc[k - 1] + math.hypot(ax[k] - ax[k - 1],
                                         ay[k] - ay[k - 1]) * mpp
    w = [1.0 if s_ else 0.0 for s_ in shared]
    last = -1e18
    for k in range(n):
        if shared[k]:
            last = arc[k]
        elif arc[k] - last < 58.0:
            w[k] = max(w[k], 1 - (arc[k] - last) / 58.0)
    nxt = 1e18
    for k in range(n - 1, -1, -1):
        if shared[k]:
            nxt = arc[k]
        elif nxt - arc[k] < 58.0:
            w[k] = max(w[k], 1 - (nxt - arc[k]) / 58.0)
    smx, smy = ax[:], ay[:]
    for k in range(n):
        if w[k] <= 0.001:
            continue
        lo, hi = max(0, k - 3), min(n - 1, k + 3)
        coh = 1.0
        if len(rawd) >= 2:
            fs = max(0, lo)
            ls = min(hi, len(rawd) - 1)
            if fs < ls:
                for sg in range(fs, ls):
                    coh = min(coh, rawd[sg][0] * rawd[sg + 1][0]
                             + rawd[sg][1] * rawd[sg + 1][1])
        cf = max(0.0, min(1.0, (coh - 0.70) / 0.25))
        strength = w[k] * 0.9 * cf
        if strength <= 0.001:
            continue
        X, Y = nX[k], nY[k]
        ws = wt = 0.0
        for nb in range(lo, hi + 1):
            dist = abs(arc[nb] - arc[k])
            g = math.exp(-(dist / 30.0) ** 2)
            ws += (ax[nb] * X + ay[nb] * Y) * g
            wt += g
        if wt <= 0:
            continue
        base_ = ax[k] * X + ay[k] * Y
        sh = (ws / wt - base_) * strength
        smx[k] += X * sh
        smy[k] += Y * sh
    CENTERS[jid] = (list(zip(smx, smy)), dx, dy, corner)
    nz = sum(1 for k in range(n)
             if math.hypot(dx[k], dy[k]) * mpp > 0.05)
    print('route %s: |d|>5cm at %d/%d verts' % (
        journeys[jid]['routeNumber'], nz, n), flush=True)

# ---- report deltas near J ----
Jx, Jy = project(J_LAT, J_LON)
print('--- deltas (m) near J ---')
for jid in keep:
    d = RAW[jid]
    pts, mpp = d['pts'], d['mpp']
    ctr, dx, dy, corner = CENTERS[jid]
    dists = [(math.hypot(p[0] - Jx, p[1] - Jy) * mpp, k)
             for k, p in enumerate(pts)]
    dists.sort()
    if dists[0][0] > R_NEAR:
        continue
    k0 = dists[0][1]
    rn = journeys[jid]['routeNumber']
    print('route %s (id %d), nearest v%d (%.1fm):' % (rn, jid, k0, dists[0][0]))
    for k in range(max(0, k0 - 3), min(d['n'], k0 + 4)):
        dm = math.hypot(dx[k], dy[k]) * mpp
        ref = d['sched'].get(k, (None, None, None, None))[3]
        rr = journeys[ref]['routeNumber'] if ref in journeys else ref
        print('   v%d: |d|=%.2fm corner=%d off=%+.1f shr=%d trk=%d ref=%s'
              % (k, dm, corner[k], d['off'][k],
                 int(d['shared'][k]), int(d['trunk'][k]), rr))

# ---- ribbons + crossings near J, at TRUE scale and 2x ----
for tag, spp in (('TRUE', 1.0), ('2x', 2.0)):
    R = {}
    for jid in keep:
        d = RAW[jid]
        ctr = CENTERS[jid][0]
        pts_r, _ = ribbon(ctr, d['off'], d['mpp'],
                          screen_points_per_map_point=spp)
        R[jid] = pts_r
    kref = RAW[keep[0]]['mpp'] / spp
    jx, jy = Jx * kref, Jy * kref
    # NOTE: k differs per journey (mpp at first vertex); crossings use each
    # journey's own scaled space -- pairwise compare needs common space.
    # mpp varies <0.1% across SB; re-scale all to J's mpp for comparison.
    mppJ = meters_per_unit(J_LAT)
    Rc = {}
    for jid in keep:
        f = (RAW[jid]['mpp'] / spp) / (mppJ / spp)
        Rc[jid] = [(x / f, y / f) for x, y in R[jid]]
    jx, jy = Jx * mppJ / spp, Jy * mppJ / spp
    print('--- %s-scale crossings within %.0fm of J ---' % (tag, R_NEAR))
    ids = [i for i in keep if min(
        math.hypot(p[0] - jx, p[1] - jy) for p in Rc[i]) <= R_NEAR * 1.2]
    print('lanes near J:', [journeys[i]['routeNumber'] for i in ids])
    shown = 0
    for a in range(len(ids)):
        for b in range(a, len(ids)):
            A, B = Rc[ids[a]], Rc[ids[b]]
            na = [i for i in range(len(A) - 1)
                  if min(math.hypot(A[i][0] - jx, A[i][1] - jy),
                         math.hypot(A[i + 1][0] - jx, A[i + 1][1] - jy))
                  <= R_NEAR]
            nb = [i for i in range(len(B) - 1)
                  if min(math.hypot(B[i][0] - jx, B[i][1] - jy),
                         math.hypot(B[i + 1][0] - jx, B[i + 1][1] - jy))
                  <= R_NEAR]
            for i in (na if b > a else range(len(na))):
                for j in nb:
                    ii = na[i] if b == a else i
                    if b == a and j <= ii:
                        continue
                    if b == a and j == ii + 1:
                        continue
                    if segments_cross(A[ii], A[ii + 1], B[j], B[j + 1]):
                        mx = (A[ii][0] + A[ii + 1][0]) / 2
                        my = (A[ii][1] + A[ii + 1][1]) / 2
                        dd = math.hypot(mx - jx, my - jy)
                        ra = journeys[ids[a]]['routeNumber']
                        rb = journeys[ids[b]]['routeNumber']
                        print('   %sx%s seg %d x seg %d @ %.1fm' % (
                            ra, rb, ii, j, dd))
                        shown += 1
                        if shown > 40:
                            print('   ... (truncated)')
                            break
                if shown > 40:
                    break
            if shown > 40:
                break
    if shown == 0:
        print('   (none)')
print('DONE')
