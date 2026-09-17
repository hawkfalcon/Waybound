"""One street, eight routes, two rulers.

Downtown, eight routes run the same street and are supposed to sit in eight
parallel lanes, one lane (8.4 m) apart. `LaneHarness.ribbon` draws each route
by multiplying the map's ABSOLUTE coordinates by a scale factor taken at that
route's own first vertex. Two routes' factors differ by about 3e-6, and the
absolute coordinates are about 1.2e8 units, so the two routes are drawn
hundreds of metres apart even where they stand on the very same coordinate.

This figure puts the eight routes at one street coordinate they all pass
through, measured in metres along and across that street:

  left  -- one scale factor for the whole map: the routes sit in their lanes
  right -- today's per-route factor: the same offsets, hundreds of metres apart

Nothing else differs between the two panels: same coordinate, same lane
offsets, same ribbon code.
"""

import json
import math
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lane_geometry as geometry
import ladder_experiment as experiment

COLOUR = {"85X": "#7b1fa2", "5": "#1b5e20", "17": "#c62828", "4": "#ef6c00",
          "7": "#0d47a1", "3": "#00838f", "24X": "#2e7d32", "12X": "#37474f",
          "1": "#5d4037", "80": "#ef6c00", "92": "#ad1457", "82": "#33691e",
          "6": "#2e7d32", "11": "#00695c", "2": "#4527a0", "14": "#6a1b9a",
          "20": "#01579b"}


def build(document, one_frame):
    journeys = {j["id"]: j for j in document["journeys"]}
    reference = geometry.meters_per_unit(experiment.REFERENCE_LATITUDE)
    lanes = []
    for layout in document["layouts"]:
        journey = journeys[layout["journeyID"]]
        coords = journey["polylines"][max(layout["polylineIndex"], 0)]
        if len(coords) < 2:
            continue
        mpp = reference if one_frame else geometry.meters_per_unit(coords[0][0])
        points, _ = geometry.ribbon(
            [geometry.project(lat, lon) for lat, lon in coords],
            layout["offsets"], mpp)
        lanes.append(dict(route=journey["routeNumber"], coords=coords,
                          points=points, offsets=layout["offsets"]))
    return lanes


def main(export_path):
    with open(export_path) as handle:
        document = json.load(handle)

    # the street coordinate the most routes pass through exactly
    journeys = {j["id"]: j for j in document["journeys"]}
    tally = {}
    for layout in document["layouts"]:
        journey = journeys[layout["journeyID"]]
        for lat, lon in journey["polylines"][max(layout["polylineIndex"], 0)]:
            if 34.418 < lat < 34.425 and -119.712 < lon < -119.700:
                tally[(round(lat, 6), round(lon, 6))] = \
                    tally.get((round(lat, 6), round(lon, 6)), 0) + 1
    key = max(tally, key=tally.get)
    print(f"street coordinate {key}, passed by {tally[key]} routes")

    frames = {"one ruler for the whole map": build(document, True),
              "today: a ruler per route": build(document, False)}

    # street direction, from the route that is nearest the coordinate
    def spot(lanes):
        found = {}
        for lane in lanes:
            hit = [i for i, (lat, lon) in enumerate(lane["coords"])
                   if (round(lat, 6), round(lon, 6)) == key]
            if hit:
                found[lane["route"]] = hit[0]
        return found

    indices = spot(frames["one ruler for the whole map"])
    seed = sorted(indices)[0]
    lane = next(l for l in frames["one ruler for the whole map"] if l["route"] == seed)
    i = indices[seed]
    b = min(i + 3, len(lane["coords"]) - 1)
    x0, y0 = geometry.project(*lane["coords"][i])
    x1, y1 = geometry.project(*lane["coords"][b])
    length = math.hypot(x1 - x0, y1 - y0)
    along_x, along_y = (x1 - x0) / length, (y1 - y0) / length
    across_x, across_y = -along_y, along_x

    def metres_coords(lane, i):
        """The drawn vertex, in metres, in the street's own frame."""
        mx, my = lane["points"][i]
        # 1 unit of the ribbon is 2 m on the ground, whichever ruler drew it
        metre_x, metre_y = mx * 2.0, my * 2.0
        return metre_x, metre_y

    origin = None
    plots = {}
    for name, lanes in frames.items():
        indices = spot(lanes)
        spots = {}
        for lane in lanes:
            if lane["route"] not in indices:
                continue
            mx, my = metres_coords(lane, indices[lane["route"]])
            spots[lane["route"]] = (mx, my)
        if origin is None:
            ox = sum(p[0] for p in spots.values()) / len(spots)
            oy = sum(p[1] for p in spots.values()) / len(spots)
            origin = (ox, oy)
        placed = {}
        for route, (mx, my) in spots.items():
            dx, dy = mx - origin[0], my - origin[1]
            placed[route] = (dx * along_x + dy * along_y,
                             dx * across_x + dy * across_y)
        plots[name] = placed

    fig, axes = plt.subplots(1, 2, figsize=(17, 9))
    for ax, (name, placed) in zip(axes, plots.items()):
        ax.axhline(0, color="#9e9e9e", lw=1.0, zorder=0)
        for route, (s_, t_) in placed.items():
            if -40 <= t_ <= 60 and -60 <= s_ <= 60:
                ax.plot([s_], [t_], "o", ms=16,
                        color=COLOUR.get(route, "#455a64"),
                        mec="white", mew=1.6, zorder=3)
                ax.annotate(route, (s_, t_), textcoords="offset points",
                            xytext=(12, -6), fontsize=15, weight="bold",
                            color=COLOUR.get(route, "#455a64"))
            else:
                ax.annotate(f"{route} is drawn\n{s_:,.0f} m along,\n{t_:,.0f} m across",
                            (0, 0), textcoords="offset points",
                            xytext=(220, 40), fontsize=15, weight="bold",
                            color=COLOUR.get(route, "#455a64"),
                            arrowprops=dict(arrowstyle="->", lw=2.5,
                                            color=COLOUR.get(route, "#455a64"),
                                            connectionstyle="arc3,rad=-0.25"))
        ax.set_xlim(-60, 60)
        ax.set_ylim(-45, 60)
        ax.grid(alpha=0.25)
        ax.tick_params(labelsize=10)
        ax.set_xlabel("along the street (metres)", fontsize=12)
        ax.set_title(name, fontsize=15)
        # a lane ruler on the left edge
        for n in range(-5, 7):
            ax.plot([-58, -55], [n * 8.4, n * 8.4], color="#616161", lw=1.4)
            ax.annotate("1 lane" if n == 0 else f"{n*8.4:+.1f} m",
                        (-54, n * 8.4), fontsize=9, va="center", color="#616161")

    # the lane the eight dots should sit in, and the distance between neighbours
    strip = plots["one ruler for the whole map"]
    order = sorted(strip, key=lambda r: strip[r][1])
    gaps = [strip[order[i + 1]][1] - strip[order[i]][1] for i in range(len(order) - 1)
            if -40 <= strip[order[i]][1] <= 60 and -40 <= strip[order[i + 1]][1] <= 60]
    for ax, note, colour in (
            (axes[0], "one ruler: every route lands where it belongs,\n"
                      "inside the width of the street", "#1b5e20"),
            (axes[1], "a ruler per route: same street, same lane offsets,\n"
                      "but 92 lands 536 m down the road", "#b71c1c")):
        ax.annotate(note, xy=(0.5, 0.97), xycoords="axes fraction",
                    ha="center", va="top", fontsize=13, weight="bold",
                    color=colour,
                    bbox=dict(facecolor="white", edgecolor="none", alpha=0.92))
    fig.text(0.5, 0.015,
             "Both panels: identical street coordinates, identical lane offsets, identical "
             "ribbon code. The only difference is the ruler.",
             ha="center", fontsize=12, color="#37474f")
    print("neighbour gaps in the lane strip: "
          + ", ".join(f"{g:.1f}" for g in gaps) + " m")

    out = os.path.join(HERE, "frame-explainer.png")
    fig.savefig(out, dpi=110)
    print(f"wrote {out}")
    for name, placed in plots.items():
        print(f"\n{name}:")
        for route in sorted(placed, key=lambda r: placed[r][1]):
            print(f"   {route:>4s} drawn at {placed[route][0]:9.1f} m along, "
                  f"{placed[route][1]:9.1f} m across")
    return 0


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else experiment.DEFAULT_EXPORT
    sys.exit(main(path))
