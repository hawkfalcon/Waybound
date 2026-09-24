import math, sys
sys.path.insert(0, '/home/user/analysis')
sys.path.insert(0, '/home/user/Waybound/tools/lane-visualization')
from lane_geometry import ribbon, meters_per_unit
import drawn_paths as P
J5, J17 = 11893980750, 11893976981
mppJ = meters_per_unit(P.J_LAT)
for jid, apex, lo, hi in ((J5, 16, 13, 19), (J17, 19, 16, 22)):
    d = P.RAW[jid]; ctr, dx, dy, corn = P.CENTERS[jid]; mpp = d['mpp']
    pts, _ = ribbon(ctr, d['off'], mpp, screen_points_per_map_point=1.0)
    f = mpp / mppJ
    D = [(x / f, y / f) for x, y in pts]
    rn = P.journeys[jid]['routeNumber']
    print('route %s apex v%d (raw-rel meters, origin=raw apex):' % (rn, apex))
    for k in range(lo, hi + 1):
        rx = (d['pts'][k][0] - d['pts'][apex][0]) * mpp
        ry = (d['pts'][k][1] - d['pts'][apex][1]) * mpp
        mx = (ctr[k][0] - d['pts'][apex][0]) * mpp
        my = (ctr[k][1] - d['pts'][apex][1]) * mpp
        dm = math.hypot(dx[k], dy[k]) * mpp
        print('  v%d raw(%+7.1f,%+7.1f) ctr(%+7.1f,%+7.1f) |d|=%5.2f off=%+6.1f' % (
            k, rx, ry, mx, my, dm, d['off'][k]))
    la = math.hypot(d['pts'][apex][0] - d['pts'][apex-1][0],
                    d['pts'][apex][1] - d['pts'][apex-1][1]) * mpp
    lb = math.hypot(d['pts'][apex+1][0] - d['pts'][apex][0],
                    d['pts'][apex+1][1] - d['pts'][apex][1]) * mpp
    print('  entry leg %.1fm exit leg %.1fm miter=%.1fm' % (
        la, lb, abs(d['off'][apex]) / math.cos(math.radians(48))))
