"""Dissect one or more fuzz seeds: which strand wobbles, where, and the
worst-separation sample (journeys, offsets, frames)."""
import sys
sys.path.insert(0, '.')
import lane_fuzz
from corridor3 import build, LS


def dissect(seed):
    geoms = lane_fuzz.make(seed)
    sl, scan = build(geoms, "sched")
    ml, _ = build(geoms, "main")
    print(f"=== seed {seed}: {len(geoms)} journeys ===")
    for jid, l in sorted(sl.items(), key=lambda kv: geoms[kv[0]].num):
        off, st = l["offsets"], l["stacked"]
        n = len(off)
        jumps = []
        for i in range(1, n):
            if not (st[i] and st[i - 1]):
                continue
            if any(st[j] != st[i] for j in range(max(0, i - 3), min(n, i + 4))):
                continue
            if abs(off[i] - off[i - 1]) > 0.05 * LS:
                jumps.append((i, round(off[i - 1], 1), round(off[i], 1)))
        if jumps:
            print(f"  {geoms[jid].num:>4} wobble jumps: {jumps[:14]}"
                  f"{' ...' if len(jumps) > 14 else ''}")
    from corridor3 import min_lane_separation
    sep = min_lane_separation(sl, scan, geoms)
    if sep is not None and sep < 0.75:
        print(f"  sep={sep:.2f}")
    from corridor3 import count_bundle_crossings
    cm, _ = count_bundle_crossings(ml, geoms)
    cs, cp = count_bundle_crossings(sl, geoms)
    print(f"  crossings main={cm} sched={cs} pairs={cp[:6]}")


for arg in sys.argv[1:]:
    dissect(int(arg))
