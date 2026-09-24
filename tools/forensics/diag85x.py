import math, sys
sys.path.insert(0, '/home/user/analysis')
sys.path.insert(0, '/home/user/Waybound/tools/lane-visualization')
import drawn_paths as P
J8 = 12356142933
d = P.RAW[J8]; ctr, dx, dy, corn = P.CENTERS[J8]; mpp = d['mpp']
n = d['n']
dirs = []
for k in range(n - 1):
    sx = ctr[k+1][0] - ctr[k][0]; sy = ctr[k+1][1] - ctr[k][1]
    L = math.hypot(sx, sy)
    dirs.append((sx / max(L, 1e-9), sy / max(L, 1e-9), L * mpp))
print('85X centers v14..v24 (sine=sin(beta), turn deg, legIn/legOut m):')
for k in range(14, 25):
    p, q = dirs[k-1], dirs[k]
    dot = p[0]*q[0] + p[1]*q[1]
    turn = math.degrees(math.acos(max(-1.0, min(1.0, dot))))
    pn = (-p[1], p[0]); nn = (-q[1], q[0])
    sl = math.hypot(pn[0]+nn[0], pn[1]+nn[1])
    if sl > 0.001:
        nx, ny = (pn[0]+nn[0])/sl, (pn[1]+nn[1])/sl
        denom = nx*nn[0] + ny*nn[1]
        sine = math.sqrt(max(0.0, 1 - denom*denom))
    else:
        denom, sine = 0.0, 1.0
    w = d['off'][k]
    s = abs(w / denom) if denom > 0.25 else abs(w)
    s = min(s, abs(w) * 1.75)
    print('  v%d turn=%5.1f sine=%.3f legs=%.1f/%.1f reach*sine=%.1f off=%+.1f' % (
        k, turn, sine, dirs[k-1][2], dirs[k][2], s*sine, w))
J5 = 11893980750
d5 = P.RAW[J5]; j5 = P.journeys[J5]['polylines'][0]; mpp5 = d5['mpp']
for k in (935, 966):
    la = math.hypot(d5['pts'][k][0]-d5['pts'][k-1][0], d5['pts'][k][1]-d5['pts'][k-1][1])*mpp5
    lb = math.hypot(d5['pts'][k+1][0]-d5['pts'][k][0], d5['pts'][k+1][1]-d5['pts'][k][1])*mpp5
    print('5 v%d @(%f,%f) legs=%.1f/%.1f off=%+.1f shr=%d' % (
        k, j5[k][0], j5[k][1], la, lb, d5['off'][k], int(d5['shared'][k])))
