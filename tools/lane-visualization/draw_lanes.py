"""Draw the app's real lane ribbons, and every place two of them cross.

    python3 tools/lane-visualization/draw_lanes.py [export.json]

`lane_geometry` builds ribbons with the package's own convention
(`screenPointsPerMapPoint = 2`), where one lane of 4.2 points spans 8.4 m of
ground, so the whole network fits one panel and the counts here are the ones the
package's gates measure. Red crosses are in-bundle crossings -- two ribbons
crossing inside a shared run, which is an ordering artifact the corridor must
not have -- and orange dots are every other crossing, where junction merges
legitimately land.

The verifier's three live areas are projected into the same space, so the three
zoom windows can be read against the same places CI reports on.
"""

import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

import lane_geometry as geometry

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_EXPORT = os.path.join(
    REPO, "tools", "replay", "data", "waybound-lanes-1789254859.json"
)

# The verifier's own areas (see the branch-live workflow's `Select areas`).
AREAS = {
    "Downtown Santa Barbara": (34.4209, -119.7033),
    "UCSB": (34.4139, -119.8489),
    "Carpinteria": (34.3989, -119.5185),
}

PALETTE = ["#e6194b", "#3cb44b", "#4363d8", "#f58231", "#911eb4", "#46f0f0",
           "#f032e6", "#bcf60c", "#fabebe", "#008080", "#e6beff", "#9a6324",
           "#800000", "#aaffc3", "#808000", "#000075", "#a9a9a9"]


def cluster(points, cell=220.0, minimum=3):
    """Group crossing points into windows worth zooming into, by cell."""
    grid = collections.Counter((int(x // cell), int(y // cell))
                               for x, y in points)
    keep = {c for c, n in grid.items() if n >= minimum}
    parent = {c: c for c in keep}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for c in keep:
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                neighbour = (c[0] + dx, c[1] + dy)
                if neighbour in keep:
                    a, b = find(c), find(neighbour)
                    if a != b:
                        parent[a] = b

    groups = collections.defaultdict(list)
    for c in keep:
        groups[find(c)].append(c)

    found = []
    for cells in groups.values():
        members = [p for p in points
                   if (int(p[0] // cell), int(p[1] // cell)) in cells]
        xs = [p[0] for p in members]
        ys = [p[1] for p in members]
        found.append(dict(
            n=len(members),
            cx=sum(xs) / len(xs),
            cy=sum(ys) / len(ys),
            x0=min(xs), x1=max(xs), y0=min(ys), y1=max(ys),
        ))
    return sorted(found, key=lambda c: -c["n"])


def main(export_path):
    document, lanes = geometry.load(export_path)
    all_crossings, bundle_crossings = geometry.crossings(lanes)
    for index, lane in enumerate(lanes):
        lane["index"] = index

    scale = geometry.meters_per_unit(34.42) / geometry.SCREEN_POINTS_PER_MAP_POINT
    area_xy = {}
    for name, (latitude, longitude) in AREAS.items():
        x, y = geometry.project(latitude, longitude)
        area_xy[name] = (x * scale, y * scale)

    colour = {l["index"]: PALETTE[i % len(PALETTE)]
              for i, l in enumerate(lanes)}
    route_of = {l["index"]: l["route"] for l in lanes}
    windows = cluster([(x, y) for x, y, _, _ in bundle_crossings])

    figure = plt.figure(figsize=(21, 15.5), dpi=100)
    grid = figure.add_gridspec(2, 1, height_ratios=[1.32, 1], hspace=.10,
                               left=.03, right=.985, top=.925, bottom=.085)

    # ------------------------------------------------------------ overview
    axes = figure.add_subplot(grid[0])
    xs = [p[0] for l in lanes for p in l["points"]]
    ys = [p[1] for l in lanes for p in l["points"]]
    padding = 260
    axes.set_xlim(min(xs) - padding, max(xs) + padding)
    axes.set_ylim(min(-y for y in ys) - padding, max(-y for y in ys) + padding)
    for lane in lanes:
        axes.plot([p[0] for p in lane["points"]],
                  [-p[1] for p in lane["points"]],
                  color="#c3c9cf", lw=1.2, zorder=2, solid_capstyle="round")
    axes.scatter([p[0] for p in all_crossings], [-p[1] for p in all_crossings],
                 s=10, c="#f1a33c", zorder=3,
                 label=f"line crossings  ({len(all_crossings)})")
    axes.scatter([p[0] for p in bundle_crossings],
                 [-p[1] for p in bundle_crossings],
                 s=34, c="#c0392b", marker="X", zorder=4, linewidths=.5,
                 edgecolors="white",
                 label=f"in-bundle crossings  ({len(bundle_crossings)})"
                       " \u2014 the ordering artifacts")
    window_width, window_height = 500.0, 300.0
    for index, window in enumerate(windows[:3]):
        axes.add_patch(Rectangle(
            (window["cx"] - window_width / 2,
             -(window["cy"] + window_height / 2)),
            window_width, window_height, fill=False, ec="#111", lw=1.5,
            ls=(0, (6, 3)), zorder=5))
        axes.annotate(f"zoom {index + 1}",
                      (window["cx"] + window_width / 2 - 10,
                       -(window["cy"] + window_height / 2) + 16),
                      fontsize=11, fontweight="bold", color="#111", ha="right",
                      bbox=dict(boxstyle="round,pad=.2", fc="white", ec="#111",
                                alpha=.9), zorder=6)
    for name, (x, y) in area_xy.items():
        axes.annotate(name, (x, -y), fontsize=10.5, fontweight="bold",
                      color="#333", ha="center", va="center", zorder=6,
                      bbox=dict(boxstyle="round,pad=.24", fc="#ffffffcc",
                                ec="#bbb", lw=.7))
    axes.plot([min(xs) + 60, min(xs) + 60 + 2000],
              [max(-y for y in ys) - 60] * 2, color="#111", lw=3)
    axes.annotate("1000 m", (min(xs) + 60, max(-y for y in ys) - 40),
                  fontsize=9, color="#111")
    axes.legend(loc="upper right", fontsize=10.5, framealpha=.95)
    axes.set_axis_off()
    axes.set_aspect("equal")
    journey_count = len(document["journeys"])
    axes.set_title(
        "Every line the app draws today, and every place two of them cross\n"
        f"Ribbons reconstructed from the device's own recorded geometry and "
        f"lane offsets ({os.path.basename(export_path)} \u00b7 "
        f"{journey_count} journeys \u00b7 South Coast)",
        fontsize=14, fontweight="bold", loc="left", pad=14)

    # -------------------------------------------------------------- zooms
    inner = grid[1].subgridspec(1, 3, wspace=.06)
    for index, window in enumerate(windows[:3]):
        axes = figure.add_subplot(inner[0, index])
        span_x = max(60.0, window["x1"] - window["x0"])
        span_y = max(60.0, window["y1"] - window["y0"])
        margin = max(90.0, 0.35 * max(span_x, span_y))
        half_width = max(150.0, span_x / 2 + margin)
        half_height = half_width * 0.62
        x0, x1 = window["cx"] - half_width, window["cx"] + half_width
        y0, y1 = window["cy"] - half_height, window["cy"] + half_height

        local_all = [(x, y, i, j) for x, y, i, j in all_crossings
                     if x0 - 20 <= x <= x1 + 20 and y0 - 20 <= y <= y1 + 20]
        local_bundle = [(x, y, i, j) for x, y, i, j in bundle_crossings
                        if x0 - 20 <= x <= x1 + 20 and y0 - 20 <= y <= y1 + 20]
        hot_routes = ({route_of[i] for _, _, i, _ in local_all}
                      | {route_of[j] for _, _, _, j in local_all})

        for lane in lanes:
            keep = [p for p in lane["points"]
                    if x0 - 60 <= p[0] <= x1 + 60]
            if len(keep) < 2:
                continue
            hot = lane["route"] in hot_routes
            axes.plot([p[0] for p in keep], [-p[1] for p in keep],
                      color=colour[lane["index"]] if hot else "#cdd2d7",
                      lw=3.0 if hot else 1.2, alpha=1 if hot else .6,
                      zorder=3 if hot else 2, solid_capstyle="round")

        axes.scatter([x for x, y, _, _ in local_bundle],
                     [-y for x, y, _, _ in local_bundle],
                     s=95, c="#c0392b", marker="X", zorder=6,
                     edgecolors="white", linewidths=1.0)

        for lane in lanes:
            if lane["route"] not in hot_routes:
                continue
            inside_points = [(p[0], -p[1]) for p in lane["points"]
                             if x0 + 40 <= p[0] <= x1 - 40
                             and y0 + 40 <= p[1] <= y1 - 40]
            if not inside_points:
                continue
            px, py = inside_points[len(inside_points) // 2]
            clashing = any(abs(px - bx) < 22 and abs(py + by) < 14
                           for bx, by, _, _ in local_bundle)
            axes.annotate(lane["route"], (px, py + (-16 if clashing else 13)),
                          fontsize=9.5, fontweight="bold",
                          color=colour[lane["index"]], ha="center", va="center",
                          zorder=7,
                          bbox=dict(boxstyle="round,pad=.16", fc="white",
                                    ec=colour[lane["index"]], lw=.8, alpha=.94))

        axes.set_xlim(x0, x1)
        axes.set_ylim(-y1, -y0)
        axes.set_aspect("equal")
        axes.add_patch(Rectangle((x0, -y1), x1 - x0, y1 - y0, fill=False,
                                 ec="#ccc", lw=1))
        axes.plot([x0 + 16, x0 + 216], [-y1 + 24] * 2, color="#111", lw=2.6)
        axes.annotate("100 m", (x0 + 116, -y1 + 32), fontsize=8,
                      ha="center", color="#111")

        pairs = collections.Counter(
            tuple(sorted((route_of[i], route_of[j])))
            for _, _, i, j in local_bundle)
        worst = "   ".join(f"{p[0]}&{p[1]}\u00d7{n}"
                           for p, n in pairs.most_common(4))
        axes.annotate(f"{len(local_all)} line crossings \u2014 "
                      f"{len(local_bundle)} in-bundle",
                      (x0 + 12, -y0 + 20), fontsize=11, fontweight="bold",
                      color="#111", va="center", zorder=8,
                      bbox=dict(boxstyle="round,pad=.24", fc="white",
                                ec="#999", lw=.7, alpha=.95))
        axes.annotate("worst pairs:  " + (worst if worst else "\u2014"),
                      (x0 + 12, -y0 + 42), fontsize=9.5, color="#c0392b",
                      va="center", zorder=8,
                      bbox=dict(boxstyle="round,pad=.2", fc="white",
                                ec="none", alpha=.9))

        nearest = min(area_xy.items(),
                      key=lambda kv: (kv[1][0] - window["cx"]) ** 2
                      + (kv[1][1] - window["cy"]) ** 2)
        distance = (((nearest[1][0] - window["cx"]) ** 2
                     + (nearest[1][1] - window["cy"]) ** 2) ** .5)
        where = (f"{distance / 1000:.1f} km from {nearest[0]}"
                 if distance > 700 else nearest[0])
        axes.set_title(f"zoom {index + 1} \u2014 {where}", fontsize=11,
                       fontweight="bold", loc="left", color="#222")
        axes.set_axis_off()

    in_bundle_pairs = collections.Counter(
        tuple(sorted((route_of[i], route_of[j])))
        for _, _, i, j in bundle_crossings)
    top_pairs = ", ".join(f"{a}&{b} ({n})"
                          for (a, b), n in in_bundle_pairs.most_common(3))
    figure.text(
        .03, .012,
        "Scale: ribbons are built with the package's own measurement convention "
        "(LaneHarness.ribbon, screenPointsPerMapPoint = 2). At that convention the "
        "geometry is scaled by metersPerUnit / mpp while lane offsets are applied "
        "in points, so one lane of 4.2 points spans 8.4 m of ground. These are the "
        "crossings the package's own gates count; they are not a prediction of a "
        "particular map zoom, where the app spaces lanes differently.\n"
        "A crossing is a proper intersection of two drawn ribbons; an in-bundle "
        "crossing is one where both ribbons are stacked and well inside their "
        "shared run \u2014 an ordering artifact the corridor must not have, "
        "unlike a stub merge at a junction.\n"
        f"Measured on this drawing: {len(all_crossings)} line crossings, "
        f"{len(bundle_crossings)} of them in-bundle. Worst pairs: {top_pairs}.",
        fontsize=8.6, color="#555")

    out_png = os.path.join(HERE, "real-lines.png")
    figure.savefig(out_png, dpi=100)
    figure.savefig(os.path.join(HERE, "real-lines.svg"))
    print(f"wrote {out_png}")
    print(f"journeys={len(lanes)} crossings={len(all_crossings)} "
          f"in-bundle={len(bundle_crossings)}")
    for pair, n in in_bundle_pairs.most_common(5):
        print(f"  {pair[0]:>4s} & {pair[1]:<4s} {n:3d}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_EXPORT)
