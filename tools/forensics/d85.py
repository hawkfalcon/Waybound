import math, sys
sys.path.insert(0, '/home/user/analysis')
sys.path.insert(0, '/home/user/Waybound/tools/lane-visualization')
from lane_geometry import ribbon, segments_cross, meters_per_unit
import drawn_paths as P
J8 = 12356142933
mppJ = meters_per_unit(P.J_LAT)
d = P.RAW[J8]; ctr = P.CENTERS[J8][0]
pts, _ = ribbon(ctr, d['off'], d['mpp'], screen_points_per_map_point=1.0)
f = d['mpp'] / mppJ
D = [(x / f, y / f) for x, y in pts]
print('85X drawn v14..v23 rel v19-drawn (m):')
for k in range(14, 24):
    print('  v%d (%+7.2f,%+7.2f)' % (k, D[k][0]-D[19][0], D[k][1]-D[19][1]))
a1, a2, b1, b2 = D[17], D[18], D[20], D[21]
d1 = (a2[0]-a1[0], a2[1]-a1[1]); d2 = (b2[0]-b1[0], b2[1]-b1[1])
den = d1[0]*d2[1]-d1[1]*d2[0]
t = ((b1[0]-a1[0])*d2[1]-(b1[1]-a1[1])*d2[0])/den
u = ((b1[0]-a1[0])*d1[1]-(b1[1]-a1[1])*d1[0])/den
print('seg17 x seg20: den=%.3f t=%.4f u=%.4f cross=%s' % (den, t, u, segments_cross(a1,a2,b1,b2)))
print('seg17 endpoints rel v19d:', (a1[0]-D[19][0], a1[1]-D[19][1]), (a2[0]-D[19][0], a2[1]-D[19][1]))
print('seg20 endpoints rel v19d:', (b1[0]-D[19][0], b1[1]-D[19][1]), (b2[0]-D[19][0], b2[1]-D[19][1]))
