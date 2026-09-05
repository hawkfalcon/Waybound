"""Lane-ordering gates: main vs the anchored-lane scheduler.

Scenarios model the downtown Santa Barbara patterns that matter:
  A  the State Street trunk bundle (1/3/4/5/7/12X/17/24X-style joins/leaves)
  B  a one-way couplet converging on a two-way street (direction split)
  C  the real Chapala x Sola reference handoff (route 6 + express traces)
  D  strands born together at a boarding stop, then diverging service
  E  a dropout-and-return strand (lane memory)

For each: render main vs scheduled ribbons, count proper strand crossings,
count continuing-strand lane wobble, and check the bundle never overlaps.
Exit status is non-zero if any gate fails.

Run:  python3 tools/replay/lane_check.py [render]
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from corridor2 import LS
from corridor3 import (G, build, ribbon, count_crossings, count_bundle_crossings,
                       min_lane_separation, wobble, bundle_wobble)
from geo import to_map_point, to_coord, mpm

HERE = os.path.dirname(os.path.abspath(__file__))
M = mpm(34.4209)
ORIGIN = to_map_point(34.4209, -119.7033)


def to_ll(x_m, y_m):
    """Local east/north metres -> lat/lon via the mercator map-point frame."""
    return to_coord(ORIGIN[0] + x_m / M, ORIGIN[1] - y_m / M)


def polyline_m(points):
    return [to_ll(x, y) for x, y in points]


def spine_points(control):
    """Densified smooth spine through control points (metres, x east y north)."""
    pts = []
    for i in range(len(control) - 1):
        (x0, y0), (x1, y1) = control[i], control[i + 1]
        d = math.hypot(x1 - x0, y1 - y0)
        steps = max(1, int(d / 40))
        for s in range(steps):
            t = s / steps
            pts.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t))
    pts.append(control[-1])
    return pts


def arc_of(points):
    arcs = [0.0]
    for i in range(1, len(points)):
        arcs.append(arcs[-1] + math.hypot(points[i][0] - points[i - 1][0],
                                          points[i][1] - points[i - 1][1]))
    return arcs


def point_at(spine, arcs, target):
    for i in range(1, len(spine)):
        if arcs[i] >= target:
            t = (target - arcs[i - 1]) / max(arcs[i] - arcs[i - 1], 1e-9)
            return (spine[i - 1][0] + (spine[i][0] - spine[i - 1][0]) * t,
                    spine[i - 1][1] + (spine[i][1] - spine[i - 1][1]) * t,
                    spine[i][0] - spine[i - 1][0],
                    spine[i][1] - spine[i - 1][1])
    return (*spine[-1], 0.001, 0.0)


def indices_between(spine, arcs, a, b):
    start = None
    end = None
    for i, arc in enumerate(arcs):
        if start is None and arc >= a:
            start = i
        if arc >= b:
            end = i
            break
    if start is None:
        start = len(spine) - 1
    if end is None:
        end = len(spine) - 1
    return start, end


def strand(spine, arcs, join, leave, side_in=None, side_out=None,
           reverse=False, stub=70.0):
    """A route sharing the spine between two arc positions.

    side_in/side_out: +1 joins/leaves on the spine's left, -1 right, None
    starts/ends on the corridor itself (boarding-stop-born strand).
    reverse: travel direction against the spine (one-way couplet member).
    """
    i0, i1 = indices_between(spine, arcs, join, leave)
    core = spine[i0:i1 + 1]
    px, py, dx, dy = point_at(spine, arcs, join)
    ux, uy = dx / max(math.hypot(dx, dy), 1e-9), dy / max(math.hypot(dx, dy), 1e-9)
    pre = []
    if side_in is not None:
        nx, ny = -uy * side_in, ux * side_in
        pre = [(px + nx * stub * 0.4, py + ny * stub * 0.4),
               (px + nx * stub, py + ny * stub)]
    px, py, dx, dy = point_at(spine, arcs, leave)
    ux, uy = dx / max(math.hypot(dx, dy), 1e-9), dy / max(math.hypot(dx, dy), 1e-9)
    post = []
    if side_out is not None:
        nx, ny = -uy * side_out, ux * side_out
        post = [(px + nx * stub, py + ny * stub),
                (px + nx * stub * 0.4, py + ny * stub * 0.4)]
    pts = pre + core + post
    if reverse:
        pts = pts[::-1]
    return pts


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

def scenario_state_trunk():
    """Downtown trunk bundle: staggered joins/leaves on a gentle curving
    street, the 1/3/4/5/7/12X/17/24X shape."""
    control = [(0, 0), (200, 8), (400, 4), (600, 18), (800, 14),
               (1000, 30), (1200, 26)]
    spine = spine_points(control)
    arcs = arc_of(spine)
    return {
        "j1": G("j1", "1", 0, polyline_m(strand(spine, arcs, 100, 1200))),
        "j3": G("j3", "3", 0, polyline_m(strand(spine, arcs, 100, 1200))),
        "j5": G("j5", "5", 0, polyline_m(strand(spine, arcs, 100, 900, side_out=1))),
        "j12x": G("j12x", "12X", 0, polyline_m(strand(spine, arcs, 100, 1000, side_out=-1))),
        "j17": G("j17", "17", 0, polyline_m(strand(spine, arcs, 350, 700, side_in=1, side_out=1))),
        "j4": G("j4", "4", 0, polyline_m(strand(spine, arcs, 300, 1200, side_in=-1))),
        "j24x": G("j24x", "24X", 0, polyline_m(strand(spine, arcs, 450, 1200, side_in=-1))),
        "j7": G("j7", "7", 0, polyline_m(strand(spine, arcs, 500, 950, side_in=1, side_out=1))),
    }


def scenario_couplet():
    """Two one-way carriageways converging on a two-way street: opposite
    directions must sit on opposite sides of the centreline and stay there."""
    control = [(0, 0), (250, -4), (500, 2), (800, -6), (1100, 0)]
    spine = spine_points(control)
    arcs = arc_of(spine)
    return {
        "j1": G("j1", "1", 0, polyline_m(strand(spine, arcs, 50, 1100))),
        "j3": G("j3", "3", 0, polyline_m(strand(spine, arcs, 150, 1100, side_in=1))),
        "j2": G("j2", "2", 1, polyline_m(strand(spine, arcs, 200, 1050, reverse=True))),
        "j4": G("j4", "4", 1, polyline_m(strand(spine, arcs, 400, 1050, reverse=True, side_in=-1))),
    }


def scenario_boarding_bundle():
    """Every strand is born at the same downtown boarding stop (flagship
    polylines start mid-corridor); service then diverges street by street."""
    control = [(0, 0), (180, 6), (360, 2), (540, 12), (720, 8), (900, 18)]
    spine = spine_points(control)
    arcs = arc_of(spine)
    return {
        "j1": G("j1", "1", 0, polyline_m(strand(spine, arcs, 120, 900))),
        "j3": G("j3", "3", 0, polyline_m(strand(spine, arcs, 120, 900))),
        "j4": G("j4", "4", 0, polyline_m(strand(spine, arcs, 120, 900))),
        "j5": G("j5", "5", 0, polyline_m(strand(spine, arcs, 120, 900, side_out=-1))),
        "j11": G("j11", "11", 0, polyline_m(strand(spine, arcs, 300, 900, side_in=1))),
        "j6": G("j6", "6", 0, polyline_m(strand(spine, arcs, 420, 900, side_in=-1))),
    }


def scenario_dropout():
    """A strand whose parallel presence drops out briefly (side street bay)
    must reclaim its own lane when it returns."""
    control = [(0, 0), (200, 4), (400, -2), (600, 6), (800, 0)]
    spine = spine_points(control)
    arcs = arc_of(spine)
    a, b = indices_between(spine, arcs, 300, 500)
    bulge = []
    for i, (x, y) in enumerate(spine):
        if a <= i <= b:
            t = math.sin((i - a) / max(b - a, 1) * math.pi)
            bulge.append((x + 26 * t, y + 26 * t))   # > 20 m: not a member
        else:
            bulge.append((x, y))
    return {
        "j1": G("j1", "1", 0, polyline_m(strand(spine, arcs, 50, 800))),
        "j3": G("j3", "3", 0, polyline_m(strand(spine, arcs, 50, 800))),
        "j2": G("j2", "2", 0, polyline_m(bulge[:1] + bulge)),
        "j5": G("j5", "5", 0, polyline_m(strand(spine, arcs, 50, 800))),
    }


def scenario_chapala(drift=4.0):
    """The real Chapala x Sola handoff: route 6 turns off at Sola while the
    express continues; the feeds disagree by a few metres."""
    def load(name):
        with open(os.path.join(HERE, "data", name)) as fh:
            return [tuple(c) for c in json.load(fh)]

    def inject_drift(path, meters):
        pts = [to_map_point(*c) for c in path]
        mm = mpm(path[0][0])
        out = []
        for i in range(len(path)):
            a = pts[max(0, i - 1)]
            b = pts[min(len(pts) - 1, i + 1)]
            dx, dy = b[0] - a[0], b[1] - a[1]
            length = math.hypot(dx, dy)
            if length < 1e-9:
                out.append(path[i])
                continue
            nx, ny = -dy / length, dx / length
            out.append(to_coord(pts[i][0] + nx * meters / mm,
                                pts[i][1] + ny * meters / mm))
        return out

    return {
        "j6": G("j6", "6", 0, inject_drift(load("route_6dt.json"), drift)),
        "jx": G("jx", "12X", 0, load("route_xdt.json")),
    }



def scenario_fanout():
    """Transit-center fan-out (user-reported downtown SB shape): six lines
    leave the center together; 80 joins slightly later; then they peel off
    in sequence. Least-crosses order puts the first to peel on each side
    outermost on that side."""
    spine = spine_points([(0, 0), (0, 1200)])
    arcs = arc_of(spine)

    def leg(x_exit, side):
        pts = strand(spine, arcs, 0, x_exit)
        pts.append((30 * side, x_exit))
        pts.append((140 * side, x_exit + 60))
        return pts

    return {
        "j1": G("j1", "1", 0, polyline_m(strand(spine, arcs, 0, 1200))),
        "j7": G("j7", "7", 0, polyline_m(leg(450, +1))),
        "j80": G("j80", "80", 0, polyline_m(
            [(-60, -150), (-25, -60)] + strand(spine, arcs, 0, 300)
            + [(30, 300), (140, 360)]), agency="VCTC"),
        "j5": G("j5", "5", 0, polyline_m(leg(600, -1))),
        "j17": G("j17", "17", 0, polyline_m(leg(750, -1))),
        "j4": G("j4", "4", 0, polyline_m(leg(900, -1))),
    }


def scenario_fork():
    """A trunk that forks: 1/3 turn onto a side street and keep sharing it
    while 12X/24X continue on the trunk — the corridor graph branches."""
    xstreet = spine_points([(0, 0), (200, 5), (400, 10), (600, 6),
                            (800, 12), (1000, 8)])
    xarcs = arc_of(xstreet)
    # street Y peels off at arc 600 toward the north-east
    fork_pt, = [point_at(xstreet, xarcs, 600)[:2]]
    ystreet = spine_points([(fork_pt[0], fork_pt[1]),
                            (fork_pt[0] + 120, fork_pt[1] + 90),
                            (fork_pt[0] + 240, fork_pt[1] + 100),
                            (fork_pt[0] + 360, fork_pt[1] + 120)])
    yarcs = arc_of(ystreet)

    fork_pt = point_at(xstreet, xarcs, 600)[:2]
    fork_i = indices_between(xstreet, xarcs, 600, 601)[0]

    def combined(join, leave, tail):
        i0, _ = indices_between(xstreet, xarcs, join, leave)
        pts = xstreet[i0:fork_i] + [fork_pt] + (ystreet[:tail] if tail else [])
        return pts

    return {
        "j1": G("j1", "1", 0, polyline_m(combined(100, 600, 4))),
        "j3": G("j3", "3", 0, polyline_m(combined(150, 600, 4))),
        "j12x": G("j12x", "12X", 0, polyline_m(strand(xstreet, xarcs, 100, 1000))),
        "j24x": G("j24x", "24X", 0, polyline_m(strand(xstreet, xarcs, 200, 1000, side_in=1))),
        "j5": G("j5", "5", 0, polyline_m(strand(xstreet, xarcs, 300, 800, side_in=-1, side_out=-1))),
    }


def scenario_reversed_spine():
    """The longest shared run belongs to a journey travelling against the
    others (a one-way couplet member with the longer trace): the schedule's
    frame conversion must keep every strand on a stable side."""
    control = [(0, 0), (200, 6), (400, 2), (600, 10), (800, 4), (1000, 8)]
    spine = spine_points(control)
    arcs = arc_of(spine)
    return {
        "j2": G("j2", "2", 1, polyline_m(strand(spine, arcs, 50, 1000, reverse=True))),
        "j4": G("j4", "4", 1, polyline_m(strand(spine, arcs, 50, 1000, reverse=True))),
        "j1": G("j1", "1", 0, polyline_m(strand(spine, arcs, 100, 900))),
        "j3": G("j3", "3", 0, polyline_m(strand(spine, arcs, 250, 950, side_in=1))),
    }


# Per-scenario gates. max_bundle_crossings is the structurally forced
# minimum of in-bundle crossings (verified by hand): a strand that enters a
# corridor from the same side another strand later peels off toward, with no
# free interior slot, must cross it once.
SCENARIOS = [
    ("state_trunk", scenario_state_trunk, {"max_bundle": 0}),
    ("couplet", scenario_couplet, {"max_bundle": 0}),
    ("boarding_bundle", scenario_boarding_bundle, {"max_bundle": 0}),
    ("dropout", scenario_dropout, {"max_bundle": 2, "sep_slack": 0.2,
                                   "note": "side-street bay excursion crosses the outer lanes out and back"}),
    ("fork", scenario_fork, {"max_bundle": 1, "note": "24X enters north of 3; 3 later peels north across it"}),
    # My synthetic legs put 5/17/4 on the -side and 7/80 on the +side; in
    # this geometry least-crosses reads (5, 17, 4, 1, 7, 80) left-to-right,
    # the mirror image of the user's real-world (80, 7, 1, 4, 17, 5).
    ("fanout", scenario_fanout, {"max_bundle": 0,
                                 "expect_order": (250, ["5", "17", "4", "1", "7", "80"])}),
    ("reversed_spine", scenario_reversed_spine, {"max_bundle": 0}),
    ("chapala", scenario_chapala, {"max_bundle": 0}),
]


def evaluate(name, maker, opts, render=False):
    geoms = maker()
    stats = {}
    import time
    t0 = time.perf_counter()
    main_layouts, scan = build(geoms, "main", stats=stats)
    t_main = time.perf_counter() - t0
    t0 = time.perf_counter()
    sched_layouts, _ = build(geoms, "sched", stats=stats)
    t_sched = time.perf_counter() - t0
    schedule = sched_layouts.get("__schedule__")

    ribbons_main = {jid: ribbon(l) for jid, l in main_layouts.items()}
    ribbons_sched = {jid: ribbon(l) for jid, l in sched_layouts.items()}
    crossings_main = count_crossings(ribbons_main)
    crossings_sched = count_crossings(ribbons_sched)
    bundle_main, pairs_main = count_bundle_crossings(main_layouts, ribbons_main)
    bundle_sched, pairs_sched = count_bundle_crossings(sched_layouts, ribbons_sched)
    wobble_main = bundle_wobble(main_layouts, scan, geoms)
    wobble_sched = bundle_wobble(sched_layouts, scan, geoms)
    separation = min_lane_separation(sched_layouts, scan, geoms)
    sep_main = min_lane_separation(main_layouts, scan, geoms)
    kink_main = max((alignment_kink(l) for l in main_layouts.values()), default=0)
    kink_sched = max((alignment_kink(l) for l in sched_layouts.values()), default=0)

    print(f"\n[{name}]")
    print(f"  crossings (all)        main {crossings_main:3d}   scheduled {crossings_sched:3d}")
    print(f"  crossings (in-bundle)  main {bundle_main:3d}   scheduled {bundle_sched:3d}"
          + (f"   pairs {[(geoms[a].num, geoms[b].num) for a, b, _ in pairs_sched]}" if pairs_sched else ""))
    print(f"  lane wobble            main {wobble_main:6.2f}   scheduled {wobble_sched:6.2f}  (lanes of drift)")
    print(f"  min lane separation    main "
          f"{sep_main if sep_main is None else round(sep_main, 2)}   scheduled "
          f"{separation if separation is None else round(separation, 2)}")
    print(f"  alignment kink         main {kink_main:4.2f}   scheduled {kink_sched:4.2f}  (m/vertex)")
    print(f"  build time             main {t_main * 1000:6.1f} ms   scheduled {t_sched * 1000:6.1f} ms")

    problems = []
    if bundle_sched > bundle_main:
        problems.append(f"scheduler adds in-bundle crossings ({bundle_main} -> {bundle_sched})")
    allowed = opts.get("max_bundle", 0)
    if bundle_sched > allowed:
        problems.append(f"strands cross inside the bundle ({bundle_sched} > "
                        f"{allowed}: {[(geoms[a].num, geoms[b].num) for a, b, _ in pairs_sched]})")
    expected = opts.get("expect_order")
    if expected:
        probe, nums = expected
        from lanesched import schedule_lanes
        from corridor3 import membership_scan as _mscan
        sched2 = schedule_lanes(geoms, _mscan(geoms))
        by_num = {g.num: jid for jid, g in geoms.items()}
        entries = []
        for num in nums:
            jid = by_num[num]
            g = geoms[jid]
            best_si, best_d = None, None
            for i in range(len(g.segs)):
                if g.segs[i] is None:
                    continue
                d = abs(g.arc()[i] - probe)
                if best_d is None or d < best_d:
                    best_d, best_si = d, i
            e = sched2.get((jid, best_si)) if best_si is not None else None
            entries.append((None if e is None else e.offset, num))
        got = [n for _, n in sorted(entries, key=lambda t: (t[0] is None, t[0]))]
        ok = got == nums
        print(f"  lateral order           {'ok ' if ok else 'BAD'}  {got}")
        if not ok:
            problems.append(f"lateral order {got} != {nums}")

    if wobble_sched > max(0.05, wobble_main) * 1.10 + 0.05:
        problems.append(f"continuing strands still wobble ({wobble_sched:.3f} lanes,"
                        f" main {wobble_main:.3f})")
    sep_floor = (min(0.75, sep_main if sep_main is not None else 0.75)
                 - 0.02 - opts.get("sep_slack", 0.0))
    if separation is not None and separation < sep_floor:
        problems.append(f"lanes overlap ({separation:.2f}, main {sep_main})")
    if kink_sched > max(0.5, kink_main):
        problems.append(f"alignment kink regresses ({kink_main:.2f} -> {kink_sched:.2f} m)")
    if t_sched > t_main * 3 + 0.05:
        problems.append(f"scheduled build too slow ({t_sched / max(t_main, 1e-6):.1f}x main)")

    # direction awareness: opposite-direction lanes must not interleave with
    # same-direction lanes (each group contiguous in the corridor stack)
    if name == "couplet":
        problems += direction_contiguity_problems(geoms, sched_layouts, scan)

    if render:
        from render_lanes import render_comparison
        path = os.path.join(HERE, "out", f"{name}.svg")
        render_comparison(geoms, ribbons_main, ribbons_sched, path, title=name)
        print(f"  rendered {path}")

    return problems


def alignment_kink(layout):
    """Worst per-vertex step of the alignment-correction vector, in metres,
    over consecutive vertices inside a stacked run (the corridor_check
    quantity the shipped rate clamp bounds)."""
    adx, ady, stacked, m = (layout["adx"], layout["ady"],
                            layout["stacked"], layout["m"])
    worst = 0.0
    for i in range(len(adx) - 1):
        if stacked[i] and stacked[i + 1]:
            worst = max(worst,
                        math.hypot(adx[i + 1] - adx[i], ady[i + 1] - ady[i]) * m)
    return worst


def direction_contiguity_problems(geoms, layouts, scan):
    """For each pair of strands sharing samples and travelling in opposite
    directions, their lanes may not sit between two same-direction lanes."""
    problems = []
    ids = list(layouts.keys())
    for ii in range(len(ids)):
        for jj in range(ii + 1, len(ids)):
            a, b = ids[ii], ids[jj]
            ga, gb = geoms[a], geoms[b]
            shared = any(scan[a][k].get(b) for k in range(len(ga.segs)))
            if not shared:
                continue
            # direction relation via the first shared sample's matched segment
            rel = None
            for k in range(len(ga.segs)):
                hit = scan[a][k].get(b)
                if hit is not None and ga.segs[k] is not None:
                    rel = 1 if (ga.segs[k].ux * hit.ux + ga.segs[k].uy * hit.uy) >= 0 else -1
                    break
            if rel != -1:
                continue  # same direction: any order is fine
            la, lb = layouts[a], layouts[b]
            offs_a = {round(o / 2.1) for o, s in zip(la["offsets"], la["stacked"]) if s}
            offs_b = {round(o / 2.1) for o, s in zip(lb["offsets"], lb["stacked"]) if s}
            for ob in offs_b:
                for o1 in offs_a:
                    for o2 in offs_a:
                        if o1 < ob < o2:
                            problems.append(
                                f"opposite-direction {gb.num} lane interleave "
                                f"between {ga.num} lanes {o1}..{o2}")
                            return problems
    return problems


def main():
    render = "render" in sys.argv
    failures = []
    for name, maker, opts in SCENARIOS:
        problems = evaluate(name, maker, opts, render=render)
        for p in problems:
            print(f"  FAIL  {p}")
        if problems:
            failures.append(name)

    print()
    if failures:
        print(f"lane check RED  ({', '.join(failures)})")
        sys.exit(1)
    print("lane check green")


if __name__ == "__main__":
    main()
