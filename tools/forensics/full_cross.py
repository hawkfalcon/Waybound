"""Full-route drawn-lane crossings involving route 5 (TRUE scale).

Reuses drawn_paths.py's faithful centerline pipeline (runs on import, ~1s),
then tests route 5's full drawn ribbon vs every other near journey + itself.
"""
import math
import sys

sys.path.insert(0, '/home/user/analysis')
sys.path.insert(0, '/home/user/Waybound/tools/lane-visualization')
from lane_geometry import ribbon, segments_cross, meters_per_unit  # noqa: E402
import drawn_paths as P  # noqa: E402 (runs pipeline + J report)

J5 = 11893980750
mppJ = meters_per_unit(P.J_LAT)

R = {}
for jid in P.keep:
    d = P.RAW[jid]
    ctr = P.CENTERS[jid][0]
    pts, _ = ribbon(ctr, d['off'], d['mpp'], screen_points_per_map_point=1.0)
    f = d['mpp'] / mppJ
    R[jid] = [(x / f, y / f) for x, y in pts]

A = R[J5]
print('=== route 5 full-route TRUE-scale crossings ===')
n5 = 0
for q in P.keep:
    if q == J5:
        continue
    B = R[q]
    hits = []
    for i in range(len(A) - 1):
        a1, a2 = A[i], A[i + 1]
        for j in range(len(B) - 1):
            if segments_cross(a1, a2, B[j], B[j + 1]):
                hits.append((i, j))
    if hits:
        print('5 x %s: %d crossings, segs %s' % (
            P.journeys[q]['routeNumber'], len(hits), hits[:12]))
        n5 += len(hits)
print('route5 pair total:', n5)
self5 = []
for i in range(len(A) - 1):
    for j in range(i + 2, len(A) - 1):
        if segments_cross(A[i], A[i + 1], A[j], A[j + 1]):
            self5.append((i, j))
print('route5 SELF crossings:', len(self5), self5[:12])
# where are route 5's shared corners? (turn > 45deg on shared verts)
d = P.RAW[J5]
pts = d['pts']
print('=== route 5 shared-corner apices (raw turn>45deg, shr=1) ===')
for k in range(1, d['n'] - 1):
    if not d['shared'][k]:
        continue
    ax = pts[k][0] - pts[k - 1][0]
    ay = pts[k][1] - pts[k - 1][1]
    bx = pts[k + 1][0] - pts[k][0]
    by = pts[k + 1][1] - pts[k][1]
    la, lb = math.hypot(ax, ay), math.hypot(bx, by)
    if la == 0 or lb == 0:
        continue
    turn = math.degrees(math.acos(max(-1.0, min(1.0,
                        (ax * bx + ay * by) / (la * lb)))))
    if turn > 45:
        print('   v%d turn=%.0f off=%+.1f ref=%s' % (
            k, turn, d['off'][k],
            P.journeys[d['sched'].get(k, (0, 0, 0, -1))[3]]['routeNumber']
            if d['sched'].get(k, (0, 0, 0, -1))[3] in P.journeys else '?'))
print('DONE')
