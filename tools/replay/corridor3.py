"""Multi-route mirror of Waybound's shared-corridor lane pass.

corridor2.py mirrors one observer journey; this module mirrors the pieces
needed to reason about the whole bundle at once:

  * membership_scan — the parallel-match half of sharedCorridorSegmentLayout
                      (midpoint + both endpoints near a parallel candidate)
  * main_lane       — main's per-segment lane offset: sort the local member
                      set, centre the stack (or split it by travel direction)
  * pipeline        — the shipped downstream per-journey stages, verbatim:
                      30 m run prune, per-vertex average, 72 m lane blend,
                      150 m gap bridge, [.25 .5 .25] delta smoothing, 58 m
                      tapers, 0.08 m/m alignment rate clamp
  * ribbon          — screen-space offset application mirroring
                      stableRouteOffsetPoints (averaged normal, miter limit,
                      reversal side-hold)

A lane source (main_lane or a scheduler) produces one CorridorSeg per shared
segment; everything after that is identical, so metric and render differences
are attributable to lane *ordering* only.
"""
import bisect
import math
import sys

sys.path.insert(0, ".")
from corridor2 import Seg, Index, parallel, densify, numkey, projection, LS
from geo import to_map_point, mpm, dist

MAX_SEPARATION = 20.0          # corridor membership, metres
MIN_PARALLEL_DOT = 0.93
MIN_SHARED_DISTANCE = 30.0     # removeShortCorridorRuns
BLEND_DISTANCE = 72.0          # stabilizeCorridorRunOffsets
MAX_GAP_DISTANCE = 150.0       # bridgeShortCorridorGaps
MAX_LANE_CHANGE = LS * 1.1
GAP_CHORD_RATIO = 0.75
TAPER_DISTANCE = 58.0
ALIGNMENT_RATE_CLAMP = 0.08    # metres per metre
ADOPTION_CAP = 6.0


class G:
    """One journey's flagship polyline and its corridor segment index."""

    def __init__(self, jid, num, direction, coords, agency="SBMTD",
                 departures=4, stack=None):
        self.id = jid
        self.num = num
        self.direction = direction
        self.agency = agency
        self.departures = departures
        self.stack = jid if stack is None else stack
        self.coords = [tuple(c) for c in coords]
        self.dense = densify(self.coords)
        self.points = [to_map_point(*c) for c in self.dense]
        self.segs = []
        for i in range(len(self.points) - 1):
            try:
                self.segs.append(Seg(self.points[i], self.points[i + 1]))
            except ValueError:
                self.segs.append(None)
        valid = [(i, s) for i, s in enumerate(self.segs) if s is not None]
        self.index = Index([s for _, s in valid], self.coords[0][0])
        self.seg_index = {id(s): i for i, s in valid}

    def key(self):
        return f"{self.agency}|{self.num}"

    def sort_key(self):
        return (numkey(self.num),
                self.direction if self.direction is not None else 2 ** 31,
                self.id)

    def arc(self):
        m = mpm(self.coords[0][0])
        arcs = [0.0]
        for i in range(1, len(self.points)):
            arcs.append(arcs[-1] + dist(self.points[i - 1], self.points[i]) * m)
        return arcs


def seg_before(a, b):
    """corridorLaneComesBefore: route number, agency, direction, stack, id."""
    ka, kb = numkey(a.num), numkey(b.num)
    if ka != kb:
        return ka < kb
    if a.agency != b.agency:
        return a.agency.lower() < b.agency.lower()
    da = a.direction if a.direction is not None else 2 ** 31
    db = b.direction if b.direction is not None else 2 ** 31
    if da != db:
        return da < db
    if a.stack != b.stack:
        return a.stack < b.stack
    return a.id < b.id


def sorted_members(geoms, ids):
    return sorted(ids, key=lambda x: geoms[x].sort_key())


def membership_scan(geoms, stats=None):
    """Per journey, per segment: {other journey id: matched segment}."""
    scan = {}
    for jid, g in geoms.items():
        m = mpm(g.coords[0][0])
        rows = []
        for seg in g.segs:
            if seg is None:
                rows.append({})
                continue
            mid = ((seg.s[0] + seg.e[0]) / 2, (seg.s[1] + seg.e[1]) / 2)
            members = {}
            for cid, cg in geoms.items():
                if cid == jid:
                    continue
                if stats is not None:
                    stats["parallel_calls"] = stats.get("parallel_calls", 0) + 3
                ms = parallel(mid, seg, cg.index.near(mid), m,
                              MAX_SEPARATION, MIN_PARALLEL_DOT)
                if ms is None:
                    continue
                if parallel(seg.s, seg, cg.index.near(seg.s), m,
                            MAX_SEPARATION, MIN_PARALLEL_DOT) is None:
                    continue
                if parallel(seg.e, seg, cg.index.near(seg.e), m,
                            MAX_SEPARATION, MIN_PARALLEL_DOT) is None:
                    continue
                members[cid] = ms
            rows.append(members)
        scan[jid] = rows
    return scan


# ---------------------------------------------------------------------------
# Lane source 1 — main: order the local member set, centre / split the stack.
# ---------------------------------------------------------------------------

class CorridorSeg:
    __slots__ = ("offset", "a_s", "a_e", "ref_id", "trunk")

    def __init__(self, offset, a_s, a_e, ref_id, trunk=False):
        self.offset = offset
        self.a_s = a_s
        self.a_e = a_e
        self.ref_id = ref_id
        self.trunk = trunk


def main_lane(geoms, scan, jid, si, selected=None, highlighted=None):
    """sharedCorridorSegmentLayout's lane math, exactly as shipped on main."""
    g = geoms[jid]
    seg = g.segs[si]
    members = scan[jid][si]
    if not members or seg is None:
        return None
    local = dict(members)
    local[jid] = seg
    member_ids = sorted_members(geoms, local.keys())
    claimed, lanes = set(), []
    for mid_ in member_ids:
        k = geoms[mid_].key()
        if k not in claimed:
            claimed.add(k)
            lanes.append(mid_)
    lane_j = next((x for x in lanes if geoms[x].key() == geoms[jid].key()), jid)
    ref_id = member_ids[0]
    ref = local[ref_id]
    aligned = [x for x in lanes if local[x].ux * ref.ux + local[x].uy * ref.uy >= 0]
    reverse = [x for x in lanes if x not in aligned]
    if reverse:
        if lane_j in aligned:
            off = LS / 2 + aligned.index(lane_j) * LS
        else:
            off = -(LS / 2 + reverse.index(lane_j) * LS)
    else:
        if lane_j not in aligned:
            return None
        off = (aligned.index(lane_j) - (len(aligned) - 1) / 2) * LS
    dsign = 1 if (seg.ux * ref.ux + seg.uy * ref.uy) >= 0 else -1
    return off * dsign, ref_id, ref


def adoption(g, seg, ref_id, ref_seg, m):
    """Project both endpoints onto the reference segment (<= 6 m only)."""
    if ref_id == g.id or ref_seg is None:
        return seg.s, seg.e
    a_s = projection(seg.s, ref_seg, m, ADOPTION_CAP)
    a_e = projection(seg.e, ref_seg, m, ADOPTION_CAP)
    return a_s, a_e


# ---------------------------------------------------------------------------
# Downstream pipeline — shared by both lane sources.
# ---------------------------------------------------------------------------

def pipeline(g, seg_layouts, rate_clamp=ALIGNMENT_RATE_CLAMP):
    """sharedCorridorLaneLayout after the per-segment layouts. Returns the
    per-vertex arrays the renderer consumes."""
    pts = g.points
    m = mpm(g.coords[0][0])
    n = len(pts)

    # removeShortCorridorRuns
    layouts = list(seg_layouts)
    i = 0
    while i < len(layouts):
        while i < len(layouts) and layouts[i] is None:
            i += 1
        if i >= len(layouts):
            break
        j = i + 1
        while j < len(layouts) and layouts[j] is not None:
            j += 1
        d = sum(dist(pts[k], pts[k + 1]) for k in range(i, j)) * m
        if d < MIN_SHARED_DISTANCE:
            for k in range(i, j):
                layouts[k] = None
        i = j

    off_s = [0.0] * n
    off_c = [0] * n
    adx = [0.0] * n
    ady = [0.0] * n
    trunk_votes = [0] * n
    ref_votes = [dict() for _ in range(n)]
    for i, L in enumerate(layouts):
        if L is None:
            continue
        off_s[i] += L.offset
        off_s[i + 1] += L.offset
        off_c[i] += 1
        off_c[i + 1] += 1
        adx[i] += L.a_s[0] - pts[i][0]
        ady[i] += L.a_s[1] - pts[i][1]
        adx[i + 1] += L.a_e[0] - pts[i + 1][0]
        ady[i + 1] += L.a_e[1] - pts[i + 1][1]
        ref_votes[i][L.ref_id] = ref_votes[i].get(L.ref_id, 0) + 1
        ref_votes[i + 1][L.ref_id] = ref_votes[i + 1].get(L.ref_id, 0) + 1
        if L.trunk:
            trunk_votes[i] += 1
            trunk_votes[i + 1] += 1
    offsets = []
    for i in range(n):
        if off_c[i]:
            adx[i] /= off_c[i]
            ady[i] /= off_c[i]
            offsets.append(off_s[i] / off_c[i])
        else:
            offsets.append(0.0)
    stacked = [c > 0 for c in off_c]
    lane_signal = offsets[:]
    trunk = [v > 0 for v in trunk_votes]
    ref_ids = []
    for votes in ref_votes:
        if not votes:
            ref_ids.append(None)
            continue
        ref_ids.append(sorted(votes.items(),
                              key=lambda kv: (-kv[1], kv[0]))[0][0])

    # stabilizeCorridorRunOffsets — 72 m blend among shared vertices
    def shared(i):
        return (i < len(layouts) and layouts[i] is not None) or \
               (i > 0 and layouts[i - 1] is not None)

    TD = BLEND_DISTANCE
    orig = offsets[:]
    for i in range(n):
        if not shared(i):
            continue
        ws, wt = orig[i], 1.0
        d = 0.0
        b = i
        while b > 0:
            d += dist(pts[b - 1], pts[b]) * m
            if d > TD or not shared(b - 1):
                break
            w = 1 - d / TD
            ws += orig[b - 1] * w
            wt += w
            b -= 1
        d = 0.0
        f = i
        while f < n - 1:
            d += dist(pts[f], pts[f + 1]) * m
            if d > TD or not shared(f + 1):
                break
            w = 1 - d / TD
            ws += orig[f + 1] * w
            wt += w
            f += 1
        offsets[i] = ws / wt

    # bridgeShortCorridorGaps
    left = 0
    while left < n - 1:
        if not stacked[left]:
            left += 1
            continue
        right = left + 1
        gap = 0.0
        while right < n:
            gap += dist(pts[right - 1], pts[right]) * m
            if stacked[right]:
                break
            right += 1
        if right >= n:
            break
        if right <= left + 1:
            left = right
            continue
        chord = dist(pts[left], pts[right]) * m
        lo, ro = offsets[left], offsets[right]
        same_ref = ref_ids[left] is not None and ref_ids[right] == ref_ids[left]
        if (gap <= MAX_GAP_DISTANCE and chord >= GAP_CHORD_RATIO * gap
                and same_ref and lo * ro >= 0 and abs(lo - ro) <= MAX_LANE_CHANGE):
            both_trunk = trunk[left] and trunk[right]
            dist_left = 0.0
            for k in range(left + 1, right):
                dist_left += dist(pts[k - 1], pts[k]) * m
                p = dist_left / gap if gap > 0 else 0.0
                offsets[k] = lo + (ro - lo) * p
                adx[k] = adx[left] + (adx[right] - adx[left]) * p
                ady[k] = ady[left] + (ady[right] - ady[left]) * p
                stacked[k] = True
                trunk[k] = both_trunk
                ref_ids[k] = ref_ids[left]
        left = right

    # stabilizeSharedAlignmentTransitions — [.25 .5 .25]
    ox, oy = adx[:], ady[:]
    for i in range(1, n - 1):
        if stacked[i - 1] and stacked[i] and stacked[i + 1]:
            adx[i] = .25 * ox[i - 1] + .5 * ox[i] + .25 * ox[i + 1]
            ady[i] = .25 * oy[i - 1] + .5 * oy[i] + .25 * oy[i + 1]

    # tapers — 58 m before/after each stacked run (max-abs candidate)
    T2 = TAPER_DISTANCE
    i = 0
    while i < n:
        while i < n and not stacked[i]:
            i += 1
        if i >= n:
            break
        rs = i
        while i < n and stacked[i]:
            i += 1
        re = i - 1
        acc = 0.0
        for bi in range(rs - 1, -1, -1):
            if stacked[bi]:
                break
            acc += dist(pts[bi], pts[bi + 1]) * m
            if acc >= T2:
                break
            f = 1 - acc / T2
            co = offsets[rs] * f
            if abs(co) > abs(offsets[bi]):
                offsets[bi] = co
            cx, cy = adx[rs] * f, ady[rs] * f
            if math.hypot(cx, cy) > math.hypot(adx[bi], ady[bi]):
                adx[bi], ady[bi] = cx, cy
        acc = 0.0
        for fi in range(re + 1, n):
            if stacked[fi]:
                break
            acc += dist(pts[fi - 1], pts[fi]) * m
            if acc >= T2:
                break
            f = 1 - acc / T2
            co = offsets[re] * f
            if abs(co) > abs(offsets[fi]):
                offsets[fi] = co
            cx, cy = adx[re] * f, ady[re] * f
            if math.hypot(cx, cy) > math.hypot(adx[fi], ady[fi]):
                adx[fi], ady[fi] = cx, cy

    # alignment rate clamp — two symmetric passes
    if rate_clamp:
        for i in range(1, n):
            seg_m = dist(pts[i - 1], pts[i]) * m
            budget = rate_clamp * seg_m
            dx_ = adx[i] - adx[i - 1]
            dy_ = ady[i] - ady[i - 1]
            step = math.hypot(dx_, dy_)
            if step > budget > 0:
                t = budget / step
                adx[i] = adx[i - 1] + dx_ * t
                ady[i] = ady[i - 1] + dy_ * t
        for i in range(n - 2, -1, -1):
            seg_m = dist(pts[i], pts[i + 1]) * m
            budget = rate_clamp * seg_m
            dx_ = adx[i] - adx[i + 1]
            dy_ = ady[i] - ady[i + 1]
            step = math.hypot(dx_, dy_)
            if step > budget > 0:
                t = budget / step
                adx[i] = adx[i + 1] + dx_ * t
                ady[i] = ady[i + 1] + dy_ * t

    aligned = [(pts[i][0] + adx[i], pts[i][1] + ady[i]) for i in range(n)]
    return {"pts": pts, "aligned": aligned, "offsets": offsets,
            "lane_signal": lane_signal,
            "stacked": stacked, "adx": adx, "ady": ady, "m": m,
            "ref_ids": ref_ids}


# ---------------------------------------------------------------------------
# Screen-space ribbon — stableRouteOffsetPoints, verbatim (see ribbon() at the
# end of this file, in screen-point space).
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def _seg_intersect(a1, a2, b1, b2, eps=0.02):
    """Proper crossing: intersection strictly interior on both segments."""
    d1 = (a2[0] - a1[0], a2[1] - a1[1])
    d2 = (b2[0] - b1[0], b2[1] - b1[1])
    den = d1[0] * d2[1] - d1[1] * d2[0]
    if abs(den) < 1e-12:
        return False
    t = ((b1[0] - a1[0]) * d2[1] - (b1[1] - a1[1]) * d2[0]) / den
    u = ((b1[0] - a1[0]) * d1[1] - (b1[1] - a1[1]) * d1[0]) / den
    return eps < t < 1 - eps and eps < u < 1 - eps


def count_crossings(ribbons):
    """Pairwise proper crossings between different strands' ribbons."""
    total = 0
    ids = list(ribbons.keys())
    for ii in range(len(ids)):
        for jj in range(ii + 1, len(ids)):
            a = ribbons[ids[ii]]
            b = ribbons[ids[jj]]
            for i in range(len(a) - 1):
                for k in range(len(b) - 1):
                    if _seg_intersect(a[i], a[i + 1], b[k], b[k + 1]):
                        total += 1
    return total


def count_bundle_crossings(layouts, ribbons, guard=4):
    """Crossings between two strands that are BOTH stacked and both well
    inside their stacked runs — i.e. not at a merge taper or a peel-off.
    These are the ordering artifacts a subway-style corridor must not have;
    stub merges at junctions are inherent to the street geometry."""
    total = 0
    pairs = []
    ids = list(layouts.keys())
    for ii in range(len(ids)):
        for jj in range(ii + 1, len(ids)):
            la, lb = layouts[ids[ii]], layouts[ids[jj]]
            ra, rb = ribbons[ids[ii]], ribbons[ids[jj]]
            sa, sb = la["stacked"], lb["stacked"]

            def inside(stacked, i):
                if not stacked[i]:
                    return False
                lo = i
                while lo > 0 and stacked[lo - 1]:
                    lo -= 1
                hi = i
                while hi < len(stacked) - 1 and stacked[hi + 1]:
                    hi += 1
                return i - lo >= guard and hi - i >= guard

            hit = 0
            for i in range(len(ra) - 1):
                if not (sa[i] and sa[i + 1] and inside(sa, i)):
                    continue
                for k in range(len(rb) - 1):
                    if not (sb[k] and sb[k + 1] and inside(sb, k)):
                        continue
                    if _seg_intersect(ra[i], ra[i + 1], rb[k], rb[k + 1]):
                        hit += 1
            if hit:
                pairs.append((ids[ii], ids[jj], hit))
            total += hit
    return total, pairs



def _nearest_on_poly(pts, p, start=0, window=None, reanchor_sq=None):
    """Nearest point of a polyline to p, searching a moving window around
    the last hit (full search when window is None). Returns (seg_idx, t,
    hit_point). With reanchor_sq, a windowed hit farther than that squared
    distance triggers one full re-search: the cursor can otherwise snap to
    a far-away segment when the observer jumps (e.g. an approach stub)."""
    n = len(pts)
    best = None
    lo, hi = (0, n - 1) if window is None else \
        (max(0, start - window), min(n - 1, start + window))
    for i in range(lo, hi):
        ax, ay = pts[i]
        bx, by = pts[i + 1]
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        t = 0.0 if L2 < 1e-12 else ((p[0] - ax) * dx + (p[1] - ay) * dy) / L2
        t = max(0.0, min(1.0, t))
        hx, hy = ax + dx * t, ay + dy * t
        d = (p[0] - hx) ** 2 + (p[1] - hy) ** 2
        if best is None or d < best[0]:
            best = (d, i, t, (hx, hy))
    if window is not None and reanchor_sq is not None and \
            best[0] > reanchor_sq:
        return _nearest_on_poly(pts, p, 0, None)
    return best[1], best[2], best[3]


def _spine_frame(spine, geoms, mpp):
    """Screen-space frame of a spine journey: polyline scaled to screen
    points, held-normal chain (stable across the spine's own 180-degree
    reversals), cumulative arc, and per-vertex turn flags."""
    g = geoms[spine]
    m = mpm(g.coords[0][0])
    k = m / mpp
    pts = [(x * k, y * k) for x, y in g.points]
    held = held_directions(g)
    dirs = []
    last = (1.0, 0.0)
    for i in range(len(g.segs)):
        s = g.segs[i]
        d = held.get(i) or ((s.ux, s.uy) if s is not None else last)
        last = d
        dirs.append((-d[1], d[0]))
    arc = [0.0]
    for i in range(len(pts) - 1):
        arc.append(arc[-1] + math.hypot(pts[i + 1][0] - pts[i][0],
                                        pts[i + 1][1] - pts[i][1]))
    turn = [0] * len(pts)
    for i in range(1, len(pts) - 1):
        d0, d1 = dirs[i - 1], dirs[i]
        if d0[0] * d1[0] + d0[1] * d1[1] < math.cos(math.radians(8)):
            turn[i] = 1
    return {"pts": pts, "normals": dirs, "arc": arc, "turn": turn}


def spine_frame(spine, geoms, mpp=2.0):
    # cached on the spine journey itself: id()-keyed global caches get
    # poisoned as scenario dicts are garbage collected and their ids reused
    g = geoms[spine]
    cache = getattr(g, "_frame_cache", None)
    if cache is None or cache[0] != mpp:
        cache = (mpp, _spine_frame(spine, geoms, mpp))
        g._frame_cache = cache
    return cache[1]


def project_onto_spine(layout, geoms, spine, mpp=2.0):
    """Project the DRAWN ribbon of a layout onto one fixed spine, walking
    a cursor (full search for the first sample, re-anchoring when the
    windowed hit is implausibly far). Returns per-vertex (spine_arc,
    lateral, corner | None) — lateral in screen points against the
    spine's held-normal chain, so corners and the spine's own reversals
    cannot flip its sign."""
    fr = spine_frame(spine, geoms, mpp)
    pts, _ = ribbon(layout, mpp, with_lateral=True)
    stacked = layout["stacked"]
    out = [None] * len(pts)
    cursor = None
    nrm, spts, arc, turn = fr["normals"], fr["pts"], fr["arc"], fr["turn"]
    for i, p in enumerate(pts):
        if not stacked[i]:
            continue
        if cursor is None:
            si, t, hit = _nearest_on_poly(spts, p, 0, None)
        else:
            si, t, hit = _nearest_on_poly(spts, p, cursor, window=16,
                                          reanchor_sq=40.0 * 40.0)
        cursor = si
        nx, ny = nrm[si]
        lat = (p[0] - hit[0]) * nx + (p[1] - hit[1]) * ny
        corner = turn[si] or (si + 1 < len(turn) and turn[si + 1])
        out[i] = (arc[si] + t * (arc[si + 1] - arc[si]), lat, corner)
    return out


def _pair_metrics_one(a, b, ja, jb, geoms, mpp, edge):
    """Relative drift and minimum gap between two stacked strands on ONE
    common spine (a's dominant reference). Samples are paired by spine
    arc (bisect; the cursor walks either way, so opposite travel
    directions pair correctly). Excluded: samples on spine corners
    (miter pinch), samples far off the spine (another street), and
    samples within `edge` of a stacked or reference boundary on either
    side (tapered joins and leaves)."""
    refs = a["ref_ids"]
    votes = {}
    for i, r in enumerate(refs):
        if a["stacked"][i] and r is not None and r in geoms:
            votes[r] = votes.get(r, 0) + 1
    if not votes:
        return None
    spine = max(sorted(votes), key=lambda r: votes[r])
    pa = project_onto_spine(a, geoms, spine, mpp)
    pb = project_onto_spine(b, geoms, spine, mpp)
    sa, sb = a["stacked"], b["stacked"]
    n, m = len(pa), len(pb)
    border = sorted((v[0], k) for k, v in enumerate(pb) if v is not None)
    if not border:
        return None
    barcs = [t[0] for t in border]
    good = []
    for i in range(n):
        if pa[i] is None:
            continue
        ai = pa[i][0]
        pos = bisect.bisect_left(barcs, ai)
        cands = [c for c in (pos - 1, pos) if 0 <= c < len(border)]
        if not cands:
            continue
        best = min(cands, key=lambda c: abs(border[c][0] - ai))
        ak, k = border[best]
        if abs(ak - ai) > 6.0:
            continue
        if pa[i][2] or pb[k][2]:
            continue  # on a spine corner: miter pinch, not drift
        if abs(pa[i][1]) > 50.0 or abs(pb[k][1]) > 50.0:
            continue  # that ribbon is on another street, not this spine
        ok = True
        for j in range(max(0, i - edge), min(n, i + edge + 1)):
            if not sa[j] or refs[j] != spine:
                ok = False
                break
        if ok:
            for j in range(max(0, k - edge), min(m, k + edge + 1)):
                if not sb[j]:
                    ok = False
                    break
        if ok:
            good.append((pa[i][1] - pb[k][1], i, k, ai, pb[k][0]))
    if len(good) < 4:
        return {"drift": None, "gap": None, "spine": spine, "pairs": len(good)}
    # Split into monotone passes: a U-turn route passes the same street
    # twice on opposite legs, and its two legs must never be compared.
    passes = []
    cur = [good[0]]
    for gprev, gnext in zip(good, good[1:]):
        da = gnext[3] - gprev[3]
        db = gnext[4] - gprev[4]
        flip = False
        if len(cur) > 1:
            pa_dir = cur[-1][3] - cur[-2][3]
            pb_dir = cur[-1][4] - cur[-2][4]
            if (da > 0) != (pa_dir > 0) or (db > 0) != (pb_dir > 0):
                flip = True
        if abs(da) > 50 or abs(db) > 50 or flip:
            passes.append(cur)
            cur = [gnext]
        else:
            cur.append(gnext)
    passes.append(cur)
    drift = None
    for p in passes:
        if len(p) < 4:
            continue
        # a merge from an adjacent lane sweeps d while it converges: a
        # (tapered) join, not mid-run drift — trim both ends of the pass
        t = max(1, len(p) // 5)
        core = p[t:len(p) - t] or p
        ds = sorted(d for d, *_ in core)
        # robust 5th-95th percentile range: a couple of corner-cutting
        # apex samples must not read as drift
        lo = ds[int(0.05 * (len(ds) - 1))]
        hi = ds[int(0.95 * (len(ds) - 1))]
        nd = (hi - lo) / LS
        if drift is None or nd > drift:
            drift = nd
    ad = sorted(abs(g[0]) for g in good)
    gap = ad[min(len(ad) - 1, max(0, int(round(0.05 * (len(ad) - 1)))))] / LS
    return {"drift": drift, "gap": gap, "spine": spine, "pairs": len(good)}


def pair_metrics(a, b, ja, jb, geoms, mpp=2.0, edge=3):
    """Orientation-stable: measure both directions (each observer's
    dominant spine can differ) and keep the one with more matched
    interior pairs, so pm(a,b) == pm(b,a)."""
    r1 = _pair_metrics_one(a, b, ja, jb, geoms, mpp, edge)
    r2 = _pair_metrics_one(b, a, jb, ja, geoms, mpp, edge)
    if r1 is None:
        return r2
    if r2 is None:
        return r1
    return r1 if (r1["pairs"], r1["spine"]) >= (r2["pairs"], r2["spine"]) else r2


def bundle_wobble(layouts, scan, geoms, mpp=2.0):
    """Worst-pair relative drift across the bundle, in lanes: how much
    any two strands that share a corridor slide sideways relative to each
    other. A continuing route must hold its lane; tapered joins, leaves,
    corner pinch, and off-spine excursions are excluded per pair."""
    worst = None
    ids = list(layouts.keys())
    for ii in range(len(ids)):
        for jj in range(ii + 1, len(ids)):
            ga, gb = geoms[ids[ii]], geoms[ids[jj]]
            if ga.key() == gb.key():
                continue
            if not any(scan[ga.id][k].get(gb.id) for k in range(len(ga.segs))):
                continue
            pm = pair_metrics(layouts[ids[ii]], layouts[ids[jj]],
                              ids[ii], ids[jj], geoms, mpp)
            if pm and pm["drift"] is not None:
                if worst is None or pm["drift"] > worst:
                    worst = pm["drift"]
    return worst or 0.0


def wobble(layout, layouts, scan, geoms, mpp=2.0):
    """Worst-partner relative drift of one DRAWN ribbon, in lanes."""
    worst = None
    jid = None
    for k, l in layouts.items():
        if l is layout:
            jid = k
            break
    if jid is None:
        return 0.0
    for oid, other in layouts.items():
        if oid == jid:
            continue
        ga, gb = geoms[jid], geoms[oid]
        if ga.key() == gb.key():
            continue
        if not any(scan[ga.id][k].get(oid) for k in range(len(ga.segs))):
            continue
        pm = pair_metrics(layout, other, jid, oid, geoms, mpp)
        if pm and pm["drift"] is not None:
            if worst is None or pm["drift"] > worst:
                worst = pm["drift"]
    return worst or 0.0


def min_lane_separation(layouts, scan, geoms, mpp=2.0):
    """Smallest gap between two stacked strands sharing a corridor, in
    lanes, measured on a common spine (frame-free). Same-public-key pairs
    share a lane by design and are skipped."""
    worst = None
    ids = list(layouts.keys())
    for ii in range(len(ids)):
        for jj in range(ii + 1, len(ids)):
            ga, gb = geoms[ids[ii]], geoms[ids[jj]]
            if ga.key() == gb.key():
                continue
            if not any(scan[ga.id][k].get(gb.id) for k in range(len(ga.segs))):
                continue
            pm = pair_metrics(layouts[ids[ii]], layouts[ids[jj]],
                              ids[ii], ids[jj], geoms, mpp)
            if pm and pm["gap"] is not None:
                if worst is None or pm["gap"] < worst:
                    worst = pm["gap"]
    return worst



def trunk_owner(geoms, scan, jid, si, selected=None, highlighted=None):
    """Main's dominance vote, verbatim: selection > highlight > frequency."""
    rows = scan[jid][si]
    if not rows:
        return None
    member_ids = sorted_members(geoms, list(rows.keys()) + [jid])
    if selected is not None and selected in member_ids:
        candidates = [selected]
    elif highlighted is not None:
        inside = [x for x in member_ids if x in highlighted]
        candidates = inside or member_ids
    else:
        candidates = member_ids
    dominant = min(candidates,
                   key=lambda x: (-geoms[x].departures, geoms[x].stack, x))
    return geoms[jid].key() == geoms[dominant].key()


def main_layouts(geoms, scan, selected=None, highlighted=None):
    layouts = {}
    for jid, g in geoms.items():
        m = mpm(g.coords[0][0])
        segs = []
        for si in range(len(g.segs)):
            lane = main_lane(geoms, scan, jid, si)
            if lane is None:
                segs.append(None)
                continue
            offset, ref_id, ref_seg = lane
            a_s, a_e = adoption(g, g.segs[si], ref_id, ref_seg, m)
            segs.append(CorridorSeg(offset, a_s, a_e, ref_id,
                                    trunk_owner(geoms, scan, jid, si,
                                                selected, highlighted) or False))
        layouts[jid] = pipeline(g, segs)
    return layouts


def held_directions(g):
    """The renderer holds the lane normal through a 180-degree doubling
    back (stableRouteOffsetPoints' reversal rule). Lane offsets must be
    converted against the same held basis or a hairpin jumps the strand to
    the wrong side of the street."""
    held = {}
    prev = None
    for i, seg in enumerate(g.segs):
        if seg is None:
            continue
        ux, uy = seg.ux, seg.uy
        if prev is not None and ux * prev[0] + uy * prev[1] < -0.8:
            ux, uy = -ux, -uy
        held[i] = (ux, uy)
        prev = (ux, uy)
    return held


def scheduled_lane(geoms, scan, schedule, jid, si, held=None):
    """The observer takes a lane only where its own scan says it shares —
    exactly main's gate. Schedule entries recorded from another journey's
    perspective must not offset this strand on approach/exit geometry."""
    if not scan[jid][si]:
        return None
    entry = schedule.get((jid, si))
    if entry is None:
        return None
    seg = geoms[jid].segs[si]
    if seg is None:
        return None
    if held is None:
        held = held_directions(geoms[jid])
    basis = held.get(si) or (seg.ux, seg.uy)
    sign = 1 if basis[0] * entry.dx + basis[1] * entry.dy >= 0 else -1
    ref_seg = scan[jid][si].get(entry.ref_id) if scan[jid][si] else None
    return entry.offset * sign, entry.ref_id, ref_seg


def _spine_delta(g, ref_id, geoms, held, mpp=2.0):
    """Per-vertex signed lateral displacement of this journey's OWN path
    from the reference street polyline, in screen points, measured against
    the reference's held-normal chain. Slots are defined against the
    street; the ribbon is drawn from the own path, so the own path's
    displacement must be subtracted or a journey whose centerline runs
    half a lane inside the street draws half a lane inside its slot."""
    fr = spine_frame(ref_id, geoms)
    k = mpm(g.coords[0][0]) / mpp
    out = {}
    cursor = None
    for i, p0 in enumerate(g.points):
        p = (p0[0] * k, p0[1] * k)
        if cursor is None:
            si, t, hit = _nearest_on_poly(fr["pts"], p, 0, None)
        else:
            si, t, hit = _nearest_on_poly(fr["pts"], p, cursor, window=16,
                                          reanchor_sq=40.0 * 40.0)
        cursor = si
        nx, ny = fr["normals"][si]
        out[i] = (p[0] - hit[0]) * nx + (p[1] - hit[1]) * ny
    return out


def scheduled_layouts(geoms, scan, schedule, selected=None, highlighted=None):
    layouts = {}
    for jid, g in geoms.items():
        m = mpm(g.coords[0][0])
        held = held_directions(g)
        deltas = {}
        segs = []
        for si in range(len(g.segs)):
            lane = scheduled_lane(geoms, scan, schedule, jid, si, held)
            if lane is None:
                segs.append(None)
                continue
            offset, ref_id, ref_seg = lane
            a_s, a_e = adoption(g, g.segs[si], ref_id, ref_seg, m)
            segs.append(CorridorSeg(offset, a_s, a_e, ref_id,
                                    trunk_owner(geoms, scan, jid, si,
                                                selected, highlighted) or False))
        layouts[jid] = pipeline(g, segs)
    return layouts


def build(geoms, mode="main", selected=None, highlighted=None, stats=None):
    scan = membership_scan(geoms, stats)
    if mode == "main":
        return main_layouts(geoms, scan, selected, highlighted), scan
    from lanesched import schedule_lanes
    schedule = schedule_lanes(geoms, scan)
    return scheduled_layouts(geoms, scan, schedule, selected, highlighted), scan


# ---------------------------------------------------------------------------
# Ribbon in screen-point space (geometry scaled by the zoom's m/pt ratio).
# ---------------------------------------------------------------------------

def ribbon(layout, mpp=2.0, with_lateral=False):
    """stableRouteOffsetPoints: apply lane offsets along the averaged normal,
    with the miter limit and reversal side-hold, in screen points. With
    with_lateral, also return the drawn lateral offset per vertex (the
    frame-free quantity a rider sees sliding sideways)."""
    k = layout["m"] / mpp   # screen points per map point
    pts = [(p[0] * k, p[1] * k) for p in layout["aligned"]]
    offsets = layout["offsets"]
    n = len(pts)
    if n < 2:
        return (pts, offsets) if with_lateral else pts
    directions = []
    prev = None
    for i in range(n - 1):
        dx = pts[i + 1][0] - pts[i][0]
        dy = pts[i + 1][1] - pts[i][1]
        length = max(1e-4, math.hypot(dx, dy))
        ux, uy = dx / length, dy / length
        if prev is not None and ux * prev[0] + uy * prev[1] < -0.8:
            ux, uy = -ux, -uy
        directions.append((ux, uy))
        prev = (ux, uy)
    out = []
    lateral = []
    for i in range(n):
        pd = directions[i - 1 if i > 0 else 0]
        nd = directions[i if i < n - 1 else n - 2]
        pn = (-pd[1], pd[0])
        nn = (-nd[1], nd[0])
        sx, sy = pn[0] + nn[0], pn[1] + nn[1]
        sl = math.hypot(sx, sy)
        local = offsets[i]
        normal = nn
        scale = local
        if sl > 0.001:
            normal = (sx / sl, sy / sl)
            denom = normal[0] * nn[0] + normal[1] * nn[1]
            if denom > 0.25:
                scale = local / denom
        max_miter = abs(local) * 1.75
        scale = max(0.0, min(max_miter, scale)) if local >= 0 \
            else min(0.0, max(-max_miter, scale))
        out.append((pts[i][0] + normal[0] * scale,
                    pts[i][1] + normal[1] * scale))
        lateral.append(scale * (normal[0] * nn[0] + normal[1] * nn[1]))
    return (out, lateral) if with_lateral else out
