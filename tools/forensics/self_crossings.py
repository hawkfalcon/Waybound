"""Where does a route's own drawn ribbon self-cross at a given zoom?"""

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import render_model as rm

DEFAULT_EXPORT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "tools", "replay", "data", "waybound-lanes-1790225339.json",
)


def load(path=DEFAULT_EXPORT):
    with open(path) as handle:
        document = json.load(handle)
    journeys = {j["id"]: j for j in document["journeys"]}
    pairs = []
    for layout in document["layouts"]:
        pairs.append((journeys[layout["journeyID"]], layout))
    return document, pairs


def segments_cross(a1, a2, b1, b2, eps=0.02):
    d1x, d1y = a2[0] - a1[0], a2[1] - a1[1]
    d2x, d2y = b2[0] - b1[0], b2[1] - b1[1]
    den = d1x * d2y - d1y * d2x
    if abs(den) < 1e-12:
        return None
    t = ((b1[0] - a1[0]) * d2y - (b1[1] - a1[1]) * d2x) / den
    u = ((b1[0] - a1[0]) * d1y - (b1[1] - a1[1]) * d1x) / den
    if eps < t < 1 - eps and eps < u < 1 - eps:
        return (t, u)
    return None


def self_crossings(rendered, which="detail"):
    """Proper self-crossings of one drawn sub-path."""
    path = getattr(rendered, which + "_path")
    hits = []
    for run_index, run in enumerate(path):
        for i in range(len(run) - 1):
            for j in range(i + 2, len(run) - 1):
                hit = segments_cross(run[i], run[i + 1], run[j], run[j + 1])
                if hit:
                    hits.append({
                        "run": run_index,
                        "i": i, "j": j,
                        "t": hit[0], "u": hit[1],
                        "point": (run[i][0] + hit[0] * (run[i + 1][0] - run[i][0]),
                                  run[i][1] + hit[0] * (run[i + 1][1] - run[i][1])),
                    })
    return hits


def main():
    document, pairs = load()
    levels = [float(a) for a in sys.argv[1:]] or [11, 12, 13, 14, 14.5, 15, 16, 17]
    for level in levels:
        zoom_scale = 2.0 ** (level - 20)
        print(f"=== zoom level {level} (zoomScale {zoom_scale:g}, "
              f"{rm.lane_spacing(zoom_scale):.2f} pt lane spacing, "
              f"detail {rm.detail_progress(zoom_scale):.3f})")
        total = 0
        for journey, layout in pairs:
            rendered = rm.render(journey, layout, zoom_scale, is_selected=True)
            for which in ("detail", "isolated"):
                hits = self_crossings(rendered, which)
                if hits:
                    total += len(hits)
                    print(f"  route {journey['routeNumber']:>5} {which:>8}: "
                          f"{len(hits)} self-crossing(s)")
                    for hit in hits:
                        print(f"      run {hit['run']} seg {hit['i']}x{hit['j']} "
                              f"t={hit['t']:.3f} u={hit['u']:.3f} "
                              f"at ({hit['point'][0]:.1f},{hit['point'][1]:.1f})")
        print(f"  TOTAL {total}")


if __name__ == "__main__":
    main()
