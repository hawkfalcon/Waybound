import math, sys
sys.path.insert(0, '/home/user/Waybound/tools/lane-visualization')
sys.path.insert(0, '/home/user/Waybound/tools/forensics')
import drawn_paths as P
from zoom_render import render
J5 = 11893980750
mpp5 = P.RAW[J5]['mpp']
def xing(a1, a2, b1, b2):
    d1 = (a2[0]-a1[0], a2[1]-a1[1]); d2 = (b2[0]-b1[0], b2[1]-b1[1])
    den = d1[0]*d2[1]-d1[1]*d2[0]
    if abs(den) < 1e-9:
        return None
    t = ((b1[0]-a1[0])*d2[1]-(b1[1]-a1[1])*d2[0])/den
    u = ((b1[0]-a1[0])*d1[1]-(b1[1]-a1[1])*d1[0])/den
    if not (0.02 < t < 0.98 and 0.02 < u < 0.98):
        return None
    la = math.hypot(*d1); lb = math.hypot(*d2)
    # distance from crossing to nearest endpoint of each seg, in px
    pxa = min(t, 1-t) * la
    pxb = min(u, 1-u) * lb
    return t, u, pxa, pxb
for level in (11, 12, 13, 14, 15, 16, 17):
    r = render(J5, level, True)
    z = r['z']
    print('=== L%d (1px=%.2fm, line=%.1fpx) ===' % (level, mpp5/z, 5.7))
    for tag, vi in (('v1', 1), ('v16', 16), ('v26', 26)):
        cx, cy = P.CENTERS[J5][0][vi]
        rad = 120.0 / mpp5
        segs = []
        for name, runs in (('iso', r['iso']), ('det', r['det']), ('trk', r['trk'])):
            for ri, run in enumerate(runs):
                for i in range(len(run) - 1):
                    mx = (run[i][0]+run[i+1][0])/2; my = (run[i][1]+run[i+1][1])/2
                    if math.hypot(mx-cx, my-cy) <= rad:
                        segs.append((name, run[i], run[i+1]))
        found = []
        for a in range(len(segs)):
            for b in range(a+1, len(segs)):
                x = xing(segs[a][1], segs[a][2], segs[b][1], segs[b][2])
                if x:
                    t, u, pxa, pxb = x
                    # convert map-pt margin to px: px = mappt * z
                    found.append('%s+%s t=%.2f u=%.2f marg=%.1f/%.1fpx' % (
                        segs[a][0], segs[b][0], t, u, pxa*z, pxb*z))
        print('  %s: %s' % (tag, found if found else 'clean'))
