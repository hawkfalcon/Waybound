import math, sys
sys.path.insert(0, '/home/user/analysis')
sys.path.insert(0, '/home/user/Waybound/tools/lane-visualization')
from lane_geometry import ribbon, meters_per_unit
import drawn_paths as P
J5, J17 = 11893980750, 11893976981
mppJ = meters_per_unit(P.J_LAT)
def drawn(jid):
    d = P.RAW[jid]; ctr = P.CENTERS[jid][0]
    pts, _ = ribbon(ctr, d['off'], d['mpp'], screen_points_per_map_point=1.0)
    f = d['mpp'] / mppJ
    return [(x / f, y / f) for x, y in pts]
D5, D17 = drawn(J5), drawn(J17)
d5 = P.RAW[J5]; ctr5, dx5, dy5, corn5 = P.CENTERS[J5]
mpp5 = d5['mpp']
print('route 5 v12..v20 (rel raw v16, meters):')
for k in range(12, 21):
    rx = (d5['pts'][k][0] - d5['pts'][16][0]) * mpp5
    ry = (d5['pts'][k][1] - d5['pts'][16][1]) * mpp5
    dm = math.hypot(dx5[k], dy5[k]) * mpp5
    ref = d5['sched'].get(k, (0, 0, 0, -1))[3]
    rr = P.journeys[ref]['routeNumber'] if ref in P.journeys else '?'
    print(' v%d raw(%+7.1f,%+7.1f) |d|=%5.2f drawn(%+7.1f,%+7.1f) off=%+6.1f shr=%d ref=%s corner=%d' % (
        k, rx, ry, dm, D5[k][0] - D5[16][0], D5[k][1] - D5[16][1],
        d5['off'][k], int(d5['shared'][k]), rr, corn5[k]))
print('route 17 v17..v23 drawn (same origin = 5:v16 drawn):')
d17 = P.RAW[J17]
for k in range(17, 24):
    print(' v%d drawn(%+7.1f,%+7.1f) off=%+6.1f' % (
        k, D17[k][0] - D5[16][0], D17[k][1] - D5[16][1], d17['off'][k]))
