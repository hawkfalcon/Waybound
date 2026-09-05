"""Ingest a lane-diagnostics JSON exported from the app (debug export
button) and rebuild the exact shapes in this harness.

Usage:  python3 ingest.py <waybound-lanes-*.json>

What it reports:
  1. the strand stacking along each spine (lateral order by arc station),
     so a reported on-screen order can be read off numerically;
  2. a port check: the Swift-exported final offsets vs this harness's
     pipeline re-run over the Swift schedule (mismatch = port divergence);
  3. a scheduler check: the Swift schedule vs what the Python scheduler
     would choose on the same geometry (mismatch = the algorithm itself,
     i.e. real-data case the scenarios/fuzz did not cover);
  4. an SVG rendering (out/ingest-<name>.svg) with route-number labels.
"""
import json
import math
import os
import sys

sys.path.insert(0, ".")
from corridor3 import (G, LS, build, membership_scan, scheduled_layouts,
                       ribbon)
from corridor2 import densify, to_map_point
from geo import mpm
from lanesched import LaneSample, schedule_lanes
from render_lanes import PALETTE, DEFAULT, STROKE, CASING

OUT = os.path.join(os.path.dirname(__file__), "out")


def _key(jid, pidx):
    return f"j{jid}#{pidx}"


def load(path):
    with open(path) as f:
        return json.load(f)


def build_geoms(doc):
    geoms = {}
    meta = {}
    for j in doc["journeys"]:
        direction = j.get("directionID", -1)
        direction = None if direction is None or direction < 0 else direction
        for pidx, poly in enumerate(j["polylines"]):
            if len(poly) < 2:
                continue
            key = _key(j["id"], pidx)
            coords = [(p[0], p[1]) for p in poly]
            geoms[key] = G(
                key, j["routeNumber"], direction, coords,
                agency=j.get("agency", "SBMTD"),
                departures=j.get("departures", 4),
                stack=j.get("stackOrder", 0),
            )
            meta[key] = j
    return geoms, meta


def load_schedule(doc):
    sched = {}
    for strand in doc.get("schedule", []):
        base = _key(strand["journeyID"], strand["polylineIndex"])
        for entry in strand["entries"]:
            seg, offset, dx, dy, ref = entry
            sched[(base, seg)] = LaneSample(
                offset, dx, dy, _key(ref, 0))
    return sched


def swift_layouts(doc):
    out = {}
    for lay in doc.get("layouts", []):
        out[(_key(lay["journeyID"], lay["polylineIndex"]),)] = lay
    return out


def station_report(geoms, layouts, meta, spine_key, label):
    """Print lateral order at stations along one spine."""
    spine = geoms[spine_key]
    arcs = spine.arc()
    stations = [arcs[-1] * f for f in
                (0.08, 0.2, 0.35, 0.5, 0.65, 0.8, 0.92)]
    print(f"\n[{label}] stacking along {spine.num} "
          f"({_key_to_num(meta, spine_key)}):")
    for station in stations:
        si = min(range(len(arcs)), key=lambda i: abs(arcs[i] - station))
        rows = []
        for key, g in geoms.items():
            if key == spine_key:
                continue
            lay = layouts.get(key)
            if lay is None or si >= len(lay["offsets"]):
                continue
            if not lay["stacked"][si]:
                continue
            rows.append((lay["offsets"][si], g.num, key))
        rows.sort()
        order = " | ".join(f"{n}({o / LS:+.1f})" for o, n, _ in rows)
        spine_off = ""
        lay = layouts.get(spine_key)
        if lay and si < len(lay["offsets"]) and lay["stacked"][si]:
            spine_off = f" spine {spine.num}({lay['offsets'][si] / LS:+.1f})"
        print(f"  @ {station:7.0f} m: {order}{spine_off}")


def _key_to_num(meta, key):
    j = meta.get(key, {})
    return f"{j.get('agency', '?')} {j.get('routeNumber', '?')}"


def svg_dump(geoms, ribbons, path, title):
    os.makedirs(OUT, exist_ok=True)
    xs, ys = [], []
    for pts in ribbons.values():
        for x, y in pts:
            xs.append(x)
            ys.append(y)
    if not xs:
        print("no ribbon points; svg skipped")
        return
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    pad = 40
    w = x1 - x0 + 2 * pad
    h = y1 - y0 + 2 * pad
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" '
        f'height="{h:.0f}" viewBox="{x0 - pad} {y0 - pad} {w} {h}">',
        f'<rect x="{x0 - pad}" y="{y0 - pad}" width="{w}" height="{h}" '
        f'fill="#f7f4ee"/>',
        f'<text x="{x0 - pad + 8}" y="{y0 - pad + 20}" '
        f'font-family="Helvetica" font-size="15" fill="#403a34">{title}</text>',
    ]
    # casings first, then strokes, then labels
    for key, pts in ribbons.items():
        num = geoms[key].num if key in geoms else "?"
        color = PALETTE.get(num, DEFAULT)
        d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts)
        parts.append(
            f'<path d="{d}" fill="none" stroke="{color}" '
            f'stroke-width="{STROKE + 2 * CASING}" stroke-opacity="0.35" '
            f'stroke-linejoin="round" stroke-linecap="round"/>')
    for key, pts in ribbons.items():
        num = geoms[key].num if key in geoms else "?"
        color = PALETTE.get(num, DEFAULT)
        d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts)
        parts.append(
            f'<path d="{d}" fill="none" stroke="{color}" '
            f'stroke-width="{STROKE}" stroke-linejoin="round" '
            f'stroke-linecap="round"/>')
    for key, pts in ribbons.items():
        num = geoms[key].num if key in geoms else "?"
        color = PALETTE.get(num, DEFAULT)
        mid = pts[len(pts) // 2]
        parts.append(
            f'<text x="{mid[0] + 6:.1f}" y="{mid[1] - 6:.1f}" '
            f'font-family="Helvetica" font-size="13" font-weight="bold" '
            f'fill="{color}">{num}</text>')
    parts.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(parts))
    print(f"\nsvg -> {path}")


def main(path):
    doc = load(path)
    geoms, meta = build_geoms(doc)
    print(f"journeys: {len(doc['journeys'])}, strands: {len(geoms)}")
    for key, g in sorted(geoms.items()):
        print(f"  {key}: {g.num:>4} ({g.agency}) dir="
              f"{g.direction} dep={g.departures} segs={len(g.segs)}")

    scan = membership_scan(geoms)
    swift_sched = load_schedule(doc)
    print(f"schedule entries (swift): {len(swift_sched)}")

    # --- render what the app drew, using the swift schedule through our
    # pipeline (identical downstream math)
    layouts = scheduled_layouts(geoms, scan, swift_sched)
    ribbons = {key: ribbon(lay) for key, lay in layouts.items()}

    # --- port check: our offsets vs the exported final offsets
    mismatches = []
    for lay in doc.get("layouts", []):
        key = (_key(lay["journeyID"], lay["polylineIndex"]),)
        ours = layouts.get(key[0])
        swift_offsets = lay["offsets"]
        if ours is None:
            continue
        n = min(len(swift_offsets), len(ours["offsets"]))
        drift = max(
            (abs(swift_offsets[i] - ours["offsets"][i])
             for i in range(n)
             if lay["shared"][i]),
            default=0.0,
        )
        if drift > 0.05 * LS:
            mismatches.append((key[0], drift / LS))
    if mismatches:
        print("\nPORT DIVERGENCE (swift final offsets vs pipeline re-run):")
        for key, drift in sorted(mismatches, key=lambda t: -t[1]):
            print(f"  {key}: max {drift:.2f} lanes")
    else:
        print("\nport check: swift offsets match pipeline re-run (<0.05 lanes)")

    # --- scheduler check: python scheduler on the same geometry
    py_sched = schedule_lanes(geoms, scan)
    same = 0
    diff = []
    for (key, seg), sample in swift_sched.items():
        mine = py_sched.get((key, seg))
        if mine is None:
            continue
        if abs(mine.offset - sample.offset) < 0.05 * LS:
            same += 1
        else:
            diff.append((key, seg, sample.offset / LS, mine.offset / LS))
    total = len(swift_sched)
    if total:
        print(f"scheduler check: {same}/{total} swift entries agree with a "
              f"fresh python run")
        by_strand = {}
        for key, seg, swift_off, py_off in diff:
            by_strand.setdefault(key, []).append((seg, swift_off, py_off))
        for key, rows in sorted(by_strand.items(),
                                key=lambda t: -len(t[1]))[:8]:
            sample = rows[:3]
            extra = f" (+{len(rows) - 3} more)" if len(rows) > 3 else ""
            print(f"  {key} ({geoms[key].num if key in geoms else '?'}): "
                  + ", ".join(
                      f"seg{s}: swift {a:+.1f} py {b:+.1f}"
                      for s, a, b in sample) + extra)

    # --- stacking report along the longest strands
    ranked = sorted(geoms.items(),
                    key=lambda kv: -kv[1].arc()[-1])
    seen = set()
    for key, g in ranked:
        if g.num in seen:
            continue
        seen.add(g.num)
        station_report(geoms, layouts, meta, key, "stacking")
        if len(seen) >= 3:
            break

    name = os.path.splitext(os.path.basename(path))[0]
    svg_dump(geoms, ribbons, os.path.join(OUT, f"ingest-{name}.svg"),
             f"{name} — scheduled lanes as drawn")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1])
