"""Randomised corridor fuzz for the lane scheduler: no exceptions, no lane
wobble for continuing strands, no lane overlap, and never more in-bundle
crossings than main's lane math on the same geometry.

Run:  python3 tools/replay/lane_fuzz.py [seeds] [--gate]
"""
import random
import sys

sys.path.insert(0, ".")
from lane_check import strand, spine_points, arc_of, polyline_m
from corridor3 import (G, build, ribbon, count_bundle_crossings, wobble,
                       min_lane_separation, bundle_wobble)


def make(seed):
    rng = random.Random(seed)
    ctrl = [(0.0, 0.0)]
    x, y = 0.0, 0.0
    for _ in range(rng.randint(4, 10)):
        x += rng.uniform(120, 260)
        y += rng.uniform(-60, 60)
        ctrl.append((x, y))
    spine = spine_points(ctrl)
    arcs = arc_of(spine)
    total = arcs[-1]
    geoms = {}
    for i in range(rng.randint(3, 12)):
        join = rng.uniform(0, total * 0.5)
        leave = min(total, join + rng.uniform(150, total - join))
        if rng.random() < 0.5:
            join = rng.uniform(0, 60)
        sin = rng.choice([None, 1, -1]) if join > 80 else None
        sout = rng.choice([None, 1, -1]) if leave < total - 80 else None
        rev = rng.random() < 0.25
        num = str(rng.randint(1, 30)) + rng.choice(["", "", "X"])
        geoms[f"j{i}"] = G(f"j{i}", num, i % 2,
                           polyline_m(strand(spine, arcs, join, leave,
                                             sin, sout, reverse=rev)))
    return geoms


def check(seed, gate=False):
    geoms = make(seed)
    main_layouts, scan = build(geoms, "main")
    sched_layouts, _ = build(geoms, "sched")
    rm = {k: ribbon(v) for k, v in main_layouts.items()}
    rs = {k: ribbon(v) for k, v in sched_layouts.items()}
    bm, _ = count_bundle_crossings(main_layouts, rm)
    bs, ps = count_bundle_crossings(sched_layouts, rs)
    wob = bundle_wobble(sched_layouts, scan, geoms)
    sep = min_lane_separation(sched_layouts, scan, geoms)
    problems = []
    if bs > bm:
        problems.append(f"in-bundle crossings {bm} -> {bs}")
    wob_main = bundle_wobble(main_layouts, scan, geoms)
    if wob > max(0.1, wob_main + 0.25):
        problems.append(f"lane wobble {wob:.2f} (main {wob_main:.2f})")
    sep_main = min_lane_separation(main_layouts, scan, geoms)
    floor = min(0.75, sep_main if sep_main is not None else 0.75) - 0.05
    if sep is not None and sep < floor:
        problems.append(f"lane separation {sep:.2f} (main {sep_main})")
    return problems, (bm, bs, wob, sep,
                      [(geoms[a].num, geoms[b].num) for a, b, _ in ps])


def main():
    seeds = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 120
    bad = 0
    for seed in range(seeds):
        try:
            problems, stats = check(seed)
        except Exception as exc:  # noqa: BLE001 - fuzz reports any crash
            bad += 1
            print(f"seed {seed:3d} EXCEPTION {type(exc).__name__}: {exc}")
            continue
        if problems:
            bad += 1
            bm, bs, wob, sep, pairs = stats
            print(f"seed {seed:3d} main={bm:2d} sched={bs:2d} "
                  f"wob={wob:5.2f} sep={sep if sep is None else round(sep, 2)} "
                  f"{'| '.join(problems)} pairs={pairs}")
    print(f"fuzz: {bad} problem seeds of {seeds}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
