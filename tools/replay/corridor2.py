"""Compact port of Waybound's corridor lane pass (WayboundMapView.swift) for
diagnosing the Chapala x Sola alignment-handoff jog. Faithful to the shipped
gates: 20 m membership / 0.93 dot, 30 m run prune, 72 m offset blend, 150 m
gap bridge, [.25,.5,.25] delta smoothing, 58 m tapers, 6 m projection cap.
The optional delta rate clamp is the candidate fix under test."""
import json, math, sys
sys.path.insert(0, '.')
from geo import to_map_point, to_coord, mpm, dist, perp_distance
from collections import defaultdict

LS = 3.4 + 0.8  # laneSpacingPoints

def densify(coords, step_m=18.0):
    mm = mpm(coords[0][0])
    out = [coords[0]]
    for i in range(len(coords) - 1):
        a = to_map_point(*coords[i]); b = to_map_point(*coords[i+1])
        d = dist(a, b) * mm
        n = max(1, math.ceil(d / step_m))
        for k in range(1, n + 1):
            out.append(to_coord(a[0] + (b[0]-a[0])*k/n, a[1] + (b[1]-a[1])*k/n))
    return out

class Seg:
    __slots__ = ("s", "e", "ux", "uy")
    def __init__(self, s, e):
        dx, dy = e[0]-s[0], e[1]-s[1]
        l = math.hypot(dx, dy)
        if l < 1e-6: raise ValueError
        self.s, self.e = s, e
        self.ux, self.uy = dx/l, dy/l

class Index:
    def __init__(self, segs, lat):
        self.segs = segs
        ppm = 1.0 / mpm(lat)
        self.cell = max(1.0, 64 * ppm)
        pad = 24.0 * ppm
        self.grid = defaultdict(list)
        for i, sg in enumerate(segs):
            x0, x1 = sorted((sg.s[0], sg.e[0])); y0, y1 = sorted((sg.s[1], sg.e[1]))
            for cx in range(int((x0-pad)//self.cell), int((x1+pad)//self.cell)+1):
                for cy in range(int((y0-pad)//self.cell), int((y1+pad)//self.cell)+1):
                    self.grid[(cx, cy)].append(i)
    def near(self, p):
        return [self.segs[i] for i in self.grid.get((int(p[0]//self.cell), int(p[1]//self.cell)), [])]

def seg_dist(p, sg):
    dx, dy = sg.e[0]-sg.s[0], sg.e[1]-sg.s[1]
    l2 = dx*dx + dy*dy
    t = max(0, min(1, ((p[0]-sg.s[0])*dx + (p[1]-sg.s[1])*dy)/l2)) if l2 else 0
    return dist(p, (sg.s[0]+t*dx, sg.s[1]+t*dy))

def parallel(point, direction, cands, m, max_sep=20.0, min_dot=0.93):
    best, bd = None, None
    for c in cands:
        if abs(direction.ux*c.ux + direction.uy*c.uy) < min_dot: continue
        d = seg_dist(point, c) * m
        if d <= max_sep and (bd is None or d < bd): best, bd = c, d
    return best

def numkey(num):
    import re
    parts = re.split(r"(\d+)", num)
    return [int(p) if p.isdigit() else p.lower() for p in parts]

class G:
    def __init__(self, jid, num, direction, coords):
        self.id, self.num, self.direction = jid, num, direction
        self.stack = jid
        self.coords = coords
        d = densify(coords)
        self.dense = d
        pts = [to_map_point(*c) for c in d]
        segs = []
        for i in range(len(pts)-1):
            try: segs.append(Seg(pts[i], pts[i+1]))
            except ValueError: pass
        self.index = Index(segs, coords[0][0])
    def key(self): return f"SBMTD|{self.num}"

def lane_before(a, b):
    ka, kb = numkey(a.num), numkey(b.num)
    if ka != kb: return ka < kb
    da = a.direction if a.direction is not None else 2**31
    db = b.direction if b.direction is not None else 2**31
    return (da, a.id) < (db, b.id)

def projection(point, ref, m, cap=6.0):
    dx, dy = ref.e[0]-ref.s[0], ref.e[1]-ref.s[1]
    l2 = dx*dx + dy*dy
    if l2 == 0: return point
    t = max(0, min(1, ((point[0]-ref.s[0])*dx + (point[1]-ref.s[1])*dy)/l2))
    p = (ref.s[0]+t*dx, ref.s[1]+t*dy)
    return p if dist(point, p)*m <= cap else point

def segment_layout(geoms, seg, jid, m):
    mid = ((seg.s[0]+seg.e[0])/2, (seg.s[1]+seg.e[1])/2)
    local = {jid: seg}
    for cid, g in geoms.items():
        if cid == jid: continue
        ms = parallel(mid, seg, g.index.near(mid), m)
        if ms is None: continue
        if parallel(seg.s, seg, g.index.near(seg.s), m) is None: continue
        if parallel(seg.e, seg, g.index.near(seg.e), m) is None: continue
        local[cid] = ms
    if len(local) <= 1: return None
    member = sorted(local.keys(), key=lambda x: (numkey(geoms[x].num), geoms[x].direction or 2**31, x))
    claimed, lanes = set(), []
    for mm_ in member:
        k = geoms[mm_].key()
        if k not in claimed: claimed.add(k); lanes.append(mm_)
    lane_j = next((x for x in lanes if geoms[x].key() == geoms[jid].key()), jid)
    ref_id = member[0]; ref = local[ref_id]
    aligned = [x for x in lanes if local[x].ux*ref.ux + local[x].uy*ref.uy >= 0]
    reverse = [x for x in lanes if x not in aligned]
    if reverse:
        if lane_j in aligned:
            off = LS/2 + aligned.index(lane_j)*LS
        else:
            off = -(LS/2 + reverse.index(lane_j)*LS)
    else:
        if lane_j not in aligned: return None
        off = (aligned.index(lane_j) - (len(aligned)-1)/2) * LS
    if ref_id == jid:
        a_s, a_e = seg.s, seg.e
    else:
        a_s = projection(seg.s, ref, m); a_e = projection(seg.e, ref, m)
    dsign = 1 if (seg.ux*ref.ux + seg.uy*ref.uy) >= 0 else -1
    return (off*dsign, a_s, a_e, ref_id)

def layout(geoms, jid, rate_clamp=None):
    coords = geoms[jid].dense
    pts = [to_map_point(*c) for c in coords]
    m = mpm(coords[0][0])
    lay = []
    for i in range(len(pts)-1):
        try: sg = Seg(pts[i], pts[i+1])
        except ValueError: lay.append(None); continue
        lay.append(segment_layout(geoms, sg, jid, m))
    # removeShortCorridorRuns (30 m)
    i = 0
    while i < len(lay):
        while i < len(lay) and lay[i] is None: i += 1
        if i >= len(lay): break
        j = i + 1
        while j < len(lay) and lay[j] is not None: j += 1
        d = sum(dist(pts[k], pts[k+1]) for k in range(i, j)) * m
        if d < 30:
            for k in range(i, j): lay[k] = None
        i = j
    n = len(pts)
    off_s = [0.0]*n; off_c = [0]*n
    adx = [0.0]*n; ady = [0.0]*n
    for i, L in enumerate(lay):
        if L is None: continue
        off, a_s, a_e, ref = L
        off_s[i] += off; off_s[i+1] += off
        off_c[i] += 1; off_c[i+1] += 1
        adx[i] += a_s[0]-pts[i][0]; ady[i] += a_s[1]-pts[i][1]
        adx[i+1] += a_e[0]-pts[i+1][0]; ady[i+1] += a_e[1]-pts[i+1][1]
    for i in range(n):
        if off_c[i]: adx[i] /= off_c[i]; ady[i] /= off_c[i]
    offsets = [off_s[i]/off_c[i] if off_c[i] else 0.0 for i in range(n)]
    stacked = [c > 0 for c in off_c]
    # stabilizeCorridorRunOffsets (72 m among shared)
    def shared(i): return (i < len(lay) and lay[i] is not None) or (i > 0 and lay[i-1] is not None)
    TD = 72.0
    orig = offsets[:]
    for i in range(n):
        if not shared(i): continue
        ws, wt = orig[i], 1.0
        d = 0; b = i
        while b > 0:
            d += dist(pts[b-1], pts[b]) * m
            if d > TD or not shared(b-1): break
            w = 1 - d/TD; ws += orig[b-1]*w; wt += w; b -= 1
        d = 0; f = i
        while f < n-1:
            d += dist(pts[f], pts[f+1]) * m
            if d > TD or not shared(f+1): break
            w = 1 - d/TD; ws += orig[f+1]*w; wt += w; f += 1
        offsets[i] = ws/wt
    # stabilizeSharedAlignmentTransitions [.25,.5,.25]
    ox, oy = adx[:], ady[:]
    for i in range(1, n-1):
        if stacked[i-1] and stacked[i] and stacked[i+1]:
            adx[i] = .25*ox[i-1] + .5*ox[i] + .25*ox[i+1]
            ady[i] = .25*oy[i-1] + .5*oy[i] + .25*oy[i+1]
    # tapers (58 m)
    T2 = 58.0
    i = 0
    while i < n:
        while i < n and not stacked[i]: i += 1
        if i >= n: break
        rs = i
        while i < n and stacked[i]: i += 1
        re = i - 1
        acc = 0
        for bi in range(rs-1, -1, -1):
            if stacked[bi]: break
            acc += dist(pts[bi], pts[bi+1]) * m
            if acc >= T2: break
            f = 1 - acc/T2
            for arr, src in ((offsets, offsets[rs]), (adx, adx[rs]), (ady, ady[rs])):
                pass
            co = offsets[rs]*f
            if abs(co) > abs(offsets[bi]): offsets[bi] = co
            cx, cy = adx[rs]*f, ady[rs]*f
            if math.hypot(cx, cy) > math.hypot(adx[bi], ady[bi]): adx[bi], ady[bi] = cx, cy
        acc = 0
        for fi in range(re+1, n):
            if stacked[fi]: break
            acc += dist(pts[fi-1], pts[fi]) * m
            if acc >= T2: break
            f = 1 - acc/T2
            co = offsets[re]*f
            if abs(co) > abs(offsets[fi]): offsets[fi] = co
            cx, cy = adx[re]*f, ady[re]*f
            if math.hypot(cx, cy) > math.hypot(adx[fi], ady[fi]): adx[fi], ady[fi] = cx, cy
    # CANDIDATE FIX: rate-limit the centerline correction so a reference
    # handoff ramps instead of stepping. Two passes = symmetric limiter.
    if rate_clamp:
        for i in range(1, n):
            seg_m = dist(pts[i-1], pts[i]) * m
            budget = rate_clamp * seg_m
            dx_ = adx[i] - adx[i-1]; dy_ = ady[i] - ady[i-1]
            step = math.hypot(dx_, dy_)
            if step > budget > 0:
                t = budget / step
                adx[i] = adx[i-1] + dx_*t
                ady[i] = ady[i-1] + dy_*t
        for i in range(n-2, -1, -1):
            seg_m = dist(pts[i], pts[i+1]) * m
            budget = rate_clamp * seg_m
            dx_ = adx[i] - adx[i+1]; dy_ = ady[i] - ady[i+1]
            step = math.hypot(dx_, dy_)
            if step > budget > 0:
                t = budget / step
                adx[i] = adx[i+1] + dx_*t
                ady[i] = ady[i+1] + dy_*t
    aligned = [(pts[i][0]+adx[i], pts[i][1]+ady[i]) for i in range(n)]
    return {"pts": pts, "aligned": aligned, "offsets": offsets,
            "stacked": stacked, "adx": adx, "ady": ady, "m": m}

def lateral_profile(result, window_center=None, window_m=250.0):
    """Signed lateral deviation of aligned coords from own centerline."""
    pts, aligned, m = result["pts"], result["aligned"], result["m"]
    out = []
    for i in range(len(pts)):
        dev = perp_distance(aligned[i], pts[i] if False else None, None) if False else None
        # signed: project aligned[i] onto local segment normal
        j = min(i, len(pts)-2)
        dx, dy = pts[j+1][0]-pts[j][0], pts[j+1][1]-pts[j][1]
        l = math.hypot(dx, dy) or 1
        nx, ny = -dy/l, dx/l
        s = (aligned[i][0]-pts[i][0])*nx + (aligned[i][1]-pts[i][1])*ny
        out.append(s * m)
    return out
