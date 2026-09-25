"""Count strand crossings between different routes' drawn ink, before and after
the ribbon pinch.  A pinch that only moves a lane inward must not create new
crossings with its corridor neighbours."""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import render_model as rm
from self_crossings import load
from pinch_final import pinched_render


def segments_of(r):
    out = []
    for name, path in (("detail", r.detail_path), ("isolated", r.isolated_path)):
        for run in path:
            for i in range(len(run) - 1):
                out.append((name, run[i], run[i + 1]))
    return out


def crossings_between(segs_a, segs_b, cell):
    """Proper crossings between two segment lists, via a uniform grid."""
    grid = {}
    for idx, (kind, a, b) in enumerate(segs_b):
        x0, x1 = min(a[0], b[0]), max(a[0], b[0])
        y0, y1 = min(a[1], b[1]), max(a[1], b[1])
        for cx in range(int(x0 // cell), int(x1 // cell) + 1):
            for cy in range(int(y0 // cell), int(y1 // cell) + 1):
                grid.setdefault((cx, cy), []).append(idx)
    hits = []
    for kind_a, a, b in segs_a:
        x0, x1 = min(a[0], b[0]), max(a[0], b[0])
        y0, y1 = min(a[1], b[1]), max(a[1], b[1])
        seen = set()
        for cx in range(int(x0 // cell), int(x1 // cell) + 1):
            for cy in range(int(y0 // cell), int(y1 // cell) + 1):
                for idx in grid.get((cx, cy), ()):
                    if idx in seen:
                        continue
                    seen.add(idx)
                    kind_b, c, d = segs_b[idx]
                    d1x, d1y = b[0] - a[0], b[1] - a[1]
                    d2x, d2y = d[0] - c[0], d[1] - c[1]
                    den = d1x * d2y - d1y * d2x
                    if abs(den) < 1e-12:
                        continue
                    t = ((c[0] - a[0]) * d2y - (c[1] - a[1]) * d2x) / den
                    u = ((c[0] - a[0]) * d1y - (c[1] - a[1]) * d1x) / den
                    if 0.02 < t < 0.98 and 0.02 < u < 0.98:
                        hits.append((kind_a, kind_b, a, c))
    return hits


def main():
    document, pairs = load()
    levels = [float(a) for a in sys.argv[1:]] or [11.0, 12.0, 13.0, 13.5, 14.0,
                                                 14.5, 15.0, 15.5, 16.0, 17.0]
    for level in levels:
        zs = 2.0 ** (level - 20)
        cell = max(rm.lane_spacing(zs) * 4, 1.0)
        base = []
        pinched = []
        for journey, layout in pairs:
            base.append((journey, segments_of(rm.render(journey, layout, zs, True))))
            pinched.append((journey, segments_of(pinched_render(journey, layout, zs, True))))
        for tag, data in (("before", base), ("after", pinched)):
            cross_tot = 0
            detail = []
            for i in range(len(data)):
                for j in range(i + 1, len(data)):
                    n = len(crossings_between(data[i][1], data[j][1], cell))
                    if n:
                        cross_tot += n
                        detail.append("%s/%s=%d" % (data[i][0]["routeNumber"],
                                                    data[j][0]["routeNumber"], n))
            print("L%-5s %-6s cross-route strand crossings = %d  %s"
                  % (level, tag, cross_tot, " ".join(detail)))


if __name__ == "__main__":
    main()
