"""Far-zoom fan pinch -- the algorithm the Swift port implements.

A route's lane ribbon folds over itself when the lane offset outgrows the width
of the street feature it is drawn on.  The pinch pulls the lane back inside its
own street: for each maximal shared run it scales that run's lane offsets down,
uniformly, until the run's own drawn ribbon has no proper self-crossing.

Two guards keep it from touching anything it should not:

  * the run's centerline must itself be simple.  A route that doubles back
    along the same street has a self-crossing centerline; no offset scale can
    separate those two legs, and pinching would only flatten the route onto
    itself.
  * the fold must be a lane-off-street fold: the two legs' ground separation
    has to be at least the lane displacement at the crossing.  When it is not,
    the route is simply running along the same corridor twice and the crossing
    is the route's real shape, not a rendering artifact.

Uniform over the whole run matters: the lane stays parallel to its corridor
neighbours instead of pinching locally, the lane ORDER is untouched so no lane
braids across another, and the route keeps every vertex so there is no
coverage gap.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import render_model as rm
from self_crossings import load, segments_cross


# ---------------------------------------------------------------- geometry

def orient(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def crosses(a, b, c, d, tol):
    o1, o2 = orient(a, b, c), orient(a, b, d)
    o3, o4 = orient(c, d, a), orient(c, d, b)
    if o1 * o2 > -tol or o3 * o4 > -tol:
        return False
    return not (abs(o1) < tol and abs(o2) < tol and abs(o3) < tol and abs(o4) < tol)


def run_spans(flags):
    spans, start = [], None
    for i, f in enumerate(flags):
        if f and start is None:
            start = i
        elif not f and start is not None:
            spans.append((start, i - 1))
            start = None
    if start is not None:
        spans.append((start, len(flags) - 1))
    return spans


# ---------------------------------------------------------------- the pinch

def pinch_span(centre, disp, max_seg, min_street=0.0):
    """Smallest uniform scale k<=1 on `disp` with a self-crossing-free ribbon.

    Returns (k, n_artifact_crossings).  k == 1.0 means "leave it alone".
    """
    n = len(centre)
    reach = max((math.hypot(dx, dy) for dx, dy in disp), default=0.0)
    if n < 4 or reach <= 0.0:
        return 1.0, 0

    def ribbon(k):
        return [(centre[i][0] + disp[i][0] * k, centre[i][1] + disp[i][1] * k)
                for i in range(n)]

    # Candidate pairs: same-run segments whose bounding boxes overlap.
    cell = max(2.0 * reach + max_seg, 1e-9)
    grid, boxes = {}, []
    for i in range(n - 1):
        x0 = min(centre[i][0] + disp[i][0], centre[i + 1][0] + disp[i + 1][0])
        x1 = max(centre[i][0] + disp[i][0], centre[i + 1][0] + disp[i + 1][0])
        y0 = min(centre[i][1] + disp[i][1], centre[i + 1][1] + disp[i + 1][1])
        y1 = max(centre[i][1] + disp[i][1], centre[i + 1][1] + disp[i + 1][1])
        boxes.append((x0, y0, x1, y1))
        grid.setdefault((int(x0 // cell), int(y0 // cell)), []).append(i)
    pairs = set()
    for i, (x0, y0, x1, y1) in enumerate(boxes):
        cx, cy = int(x0 // cell), int(y0 // cell)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((cx + dx, cy + dy), ()):
                    if j > i and not (x1 < boxes[j][0] or boxes[j][2] < x0
                                      or y1 < boxes[j][1] or boxes[j][3] < y0):
                        pairs.add((i, j))
    pairs = sorted(p for p in pairs if p[1] >= p[0] + 2)
    if not pairs:
        return 1.0, 0

    tol = 1e-12

    def raw_folding(k):
        rib = ribbon(k)
        return [ij for ij in pairs
                if crosses(rib[ij[0]], rib[ij[0] + 1], rib[ij[1]], rib[ij[1] + 1], tol)]

    # Which folds are lane-off-street artifacts?  Judged once, at the lane's
    # real width: the two legs have to be further apart on the ground than the
    # lane is drawn to the side of its own centerline.  Judging it at a shrunk
    # scale would reclassify a route that doubles back along one street as an
    # artifact the moment its lane got narrow.
    # Only legs that are genuinely different streets count.  Two samples of
    # one street -- a route that doubles back along the corridor it just came
    # down -- sit closer together than one stroke width, and no offset scale
    # can separate them; pinching those only flattens the route onto itself.
    artifacts = []
    for i, j in pairs:
        gap = min(math.hypot(centre[p][0] - centre[q][0],
                             centre[p][1] - centre[q][1])
                  for p in (i, i + 1) for q in (j, j + 1))
        widest = max(math.hypot(*disp[i]), math.hypot(*disp[j]))
        if gap >= widest and gap >= min_street:
            artifacts.append((i, j))
    if not artifacts:
        return 1.0, 0
    if not raw_folding(1.0):
        return 1.0, 0

    def still_folding(k):
        rib = ribbon(k)
        return any(crosses(rib[i], rib[i + 1], rib[j], rib[j + 1], tol)
                   for i, j in artifacts)

    lo, hi = 0.0, 1.0                      # lo known clean, hi known folding
    for _ in range(20):
        mid = 0.5 * (lo + hi)
        if still_folding(mid):
            hi = mid
        else:
            lo = mid
    return lo, len(artifacts)


def pinched_render(journey, layout, zoom_scale, is_selected=False):
    r = rm.render(journey, layout, zoom_scale, is_selected)
    if r.detail_progress <= 0.001 or r.segment_count < 1:
        return r
    pts = r.samples.points
    disp = [(r.offset_points[i][0] - pts[i][0], r.offset_points[i][1] - pts[i][1])
            for i in range(len(pts))]
    max_seg = max(math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1])
                  for i in range(r.segment_count))
    # Two legs closer together than one stroke are the same street drawn twice.
    min_street = (rm.STANDARD_LINE_WIDTH
                  + max(0.0, min(1.0, (rm.zoom_level(zoom_scale) - 13.75) / 3.5)) * 2.8
                  + rm.SEPARATOR_WIDTH)
    new_points = list(r.offset_points)
    applied = []
    for a, b in run_spans(r.shared_segments):
        if b - a < 2:   # a run of fewer than 4 samples cannot fold
            continue
        centre = [pts[i] for i in range(a, b + 1)]
        d = [disp[i] for i in range(a, b + 1)]
        k, before = pinch_span(centre, d, max_seg, min_street)
        if k < 1.0:
            applied.append((a, b, k, before))
            for i in range(a, b + 1):
                new_points[i] = (pts[i][0] + disp[i][0] * k,
                                 pts[i][1] + disp[i][1] * k)
    r.pinched_points = new_points
    r.pinch_applied = applied
    r.isolated_path = rm.route_segment_path(new_points, r.isolated_segments, r.tolerance)
    r.detail_path = rm.route_segment_path(new_points, r.shared_segments, r.tolerance)
    return r


# ---------------------------------------------------------------- reporting

def all_crossings(r):
    out = []
    strokes = [("detail", r.detail_path), ("isolated", r.isolated_path)]
    for name, path in strokes:
        for ri, run in enumerate(path):
            for i in range(len(run) - 1):
                for j in range(i + 2, len(run) - 1):
                    h = segments_cross(run[i], run[i + 1], run[j], run[j + 1])
                    if h:
                        out.append((name + "SELF", ri, i, j, h))
    for a in range(len(strokes)):
        for b in range(a + 1, len(strokes)):
            (na, pa), (nb, pb) = strokes[a], strokes[b]
            for ra, run in enumerate(pa):
                for ia in range(len(run) - 1):
                    for rb, runb in enumerate(pb):
                        for ib in range(len(runb) - 1):
                            h = segments_cross(run[ia], run[ia + 1],
                                               runb[ib], runb[ib + 1])
                            if h:
                                out.append((na + "X" + nb, ra, ia, (rb, ib), h))
    return out


def main():
    document, pairs = load()
    levels = [float(a) for a in sys.argv[1:]] or [11.0, 12.0, 13.0, 13.5, 14.0,
                                                 14.5, 15.0, 15.5, 16.0, 17.0]
    for level in levels:
        zs = 2.0 ** (level - 20)
        print("=== L%s  laneSpacing %.2fpt  detail %.3f"
              % (level, rm.lane_spacing(zs), rm.detail_progress(zs)))
        sel = os.environ.get("SEL") == "1"
        for journey, layout in pairs:
            r = pinched_render(journey, layout, zs, is_selected=sel)
            if not getattr(r, "pinch_applied", None):
                continue
            for a, b, k, before in r.pinch_applied:
                print("  route %5s run[%d,%d] %dv k=%.4f" % (journey["routeNumber"], a, b, b - a + 1, k))
        tot_before = tot_after = 0
        for journey, layout in pairs:
            rb = rm.render(journey, layout, zs, is_selected=sel)
            ra = pinched_render(journey, layout, zs, is_selected=sel)
            tot_before += len(all_crossings(rb))
            tot_after += len(all_crossings(ra))
        print("  own-ink crossings before=%d after=%d" % (tot_before, tot_after))


if __name__ == "__main__":
    main()
