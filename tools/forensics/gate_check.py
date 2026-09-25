"""Which ribbon folds are "the lane wandered off its own street" (a rendering
artifact worth pinching) and which are "the route doubles back along the same
street" (no offset scale can separate those legs)?

Test per crossing pair (i, j):  leg separation g  vs  the two displacements
|o_i|, |o_j|.  If g >= max(|o_i|,|o_j|) the two legs are distinct streets and
the lane has been drawn past the far one -- that is the artifact.  If g is
small the route simply runs along the same corridor twice.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import render_model as rm
from self_crossings import load
from pinch_final import run_spans, crosses


def main():
    document, pairs = load()
    levels = [float(a) for a in sys.argv[1:]] or [14.0, 14.5, 15.0, 15.5, 16.0]
    for level in levels:
        zs = 2.0 ** (level - 20)
        print("=== L%s" % level)
        for journey, layout in pairs:
            r = rm.render(journey, layout, zs, is_selected=True)
            if r.detail_progress <= 0.001 or r.segment_count < 1:
                continue
            pts = r.samples.points
            disp = [(r.offset_points[i][0] - pts[i][0], r.offset_points[i][1] - pts[i][1])
                    for i in range(len(pts))]
            for a, b in run_spans(r.shared_segments):
                if b - a < 3:
                    continue
                centre = [pts[i] for i in range(a, b + 1)]
                d = [disp[i] for i in range(a, b + 1)]
                n = len(centre)
                rib = [(centre[i][0] + d[i][0], centre[i][1] + d[i][1])
                       for i in range(n)]
                for i in range(n - 1):
                    for j in range(i + 2, n - 1):
                        if not crosses(rib[i], rib[i + 1], rib[j], rib[j + 1], 1e-12):
                            continue
                        g = min(math.hypot(centre[p][0] - centre[q][0],
                                           centre[p][1] - centre[q][1])
                                for p in (i, i + 1) for q in (j, j + 1))
                        oi = math.hypot(*d[i])
                        oj = math.hypot(*d[j])
                        verdict = "ARTIFACT" if g >= max(oi, oj) else "doubling-back"
                        print("  route %5s run[%d,%d] seg %dx%d  g=%.2f "
                              "|o_i|=%.2f |o_j|=%.2f  -> %s"
                              % (journey["routeNumber"], a, b, i, j, g, oi, oj,
                                 verdict))


if __name__ == "__main__":
    main()
