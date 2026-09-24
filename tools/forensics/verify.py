import math, sys
sys.path.insert(0, '/home/user/analysis')
sys.path.insert(0, '/home/user/Waybound/tools/lane-visualization')
from lane_geometry import ribbon, segments_cross, meters_per_unit
import drawn_paths as P
mppJ = meters_per_unit(P.J_LAT)
def drawn(jid):
    d = P.RAW[jid]; ctr = P.CENTERS[jid][0]
    pts, _ = ribbon(ctr, d['off'], d['mpp'], screen_points_per_map_point=1.0)
    f = d['mpp'] / mppJ
    return [(x / f, y / f) for x, y in pts]
D5 = drawn(11893980750); D17 = drawn(11893976981)
# exact location of 5seg15 x 17seg20
a1, a2, b1, b2 = D5[15], D5[16], D17[20], D17[21]
d1 = (a2[0]-a1[0], a2[1]-a1[1]); d2 = (b2[0]-b1[0], b2[1]-b1[1])
den = d1[0]*d2[1]-d1[1]*d2[0]
t = ((b1[0]-a1[0])*d2[1]-(b1[1]-a1[1])*d2[0])/den
sec = (a1[0]+t*d1[0], a1[1]+t*d1[1])
print('5seg15 x 17seg20 at t=%.2f, dist from 5-apex-drawn=%.2fm' % (t, math.hypot(sec[0]-D5[16][0], sec[1]-D5[16][1])))
# 17 self crossings full route
S17 = []
for i in range(len(D17)-1):
    for j in range(i+2, len(D17)-1):
        if segments_cross(D17[i], D17[i+1], D17[j], D17[j+1]):
            S17.append((i, j))
print('17 SELF crossings:', S17)
# 5 self-X context: offsets/shared + coords
d5 = P.RAW[11893980750]
j5 = P.journeys[11893980750]['polylines'][0]
for (i, j) in [(417,505),(423,513),(620,645),(904,929)]:
    print('5 self (%d,%d): off_i=%+.1f/%+.1f shr=%d/%d @(%f,%f)' % (
        i, j, d5['off'][i], d5['off'][j], int(d5['shared'][i]), int(d5['shared'][j]), j5[i][0], j5[i][1]))
# 85X legs at v19 corner
d8 = P.RAW[12356142933]
mpp8 = d8['mpp']
la = math.hypot(d8['pts'][19][0]-d8['pts'][18][0], d8['pts'][19][1]-d8['pts'][18][1])*mpp8
lb = math.hypot(d8['pts'][20][0]-d8['pts'][19][0], d8['pts'][20][1]-d8['pts'][19][1])*mpp8
print('85X v19 corner: legs %.1f/%.1fm off=%+.1f miter=%.1fm' % (la, lb, d8['off'][19], abs(d8['off'][19])/math.cos(math.radians(44))))
# v1 corner legs (route 5)
la1 = math.hypot(d5['pts'][1][0]-d5['pts'][0][0], d5['pts'][1][1]-d5['pts'][0][1])*P.RAW[11893980750]['mpp']
lb1 = math.hypot(d5['pts'][2][0]-d5['pts'][1][0], d5['pts'][2][1]-d5['pts'][1][1])*P.RAW[11893980750]['mpp']
print('5 v1 corner: legs %.1f/%.1fm off=-14.7 miter=%.1fm' % (la1, lb1, 14.7/math.cos(math.radians(29.5))))
