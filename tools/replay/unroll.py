"""Unrolled-corridor diagnostic: plot each strand's lane offset against its
arc position along the scenario spine. In this view a subway-style corridor
is a set of horizontal lines; lane slides are slopes and crossings are
intersections — readable as text without image support."""
import math

from geo import mpm, dist


def _project_arc(spine_pts, spine_arcs, point):
    """Arc position of the closest projection of point onto the spine."""
    best, best_d = None, None
    for i in range(len(spine_pts) - 1):
        (ax, ay), (bx, by) = spine_pts[i], spine_pts[i + 1]
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        t = 0.0 if l2 == 0 else max(0.0, min(1.0, ((point[0] - ax) * dx + (point[1] - ay) * dy) / l2))
        px, py = ax + dx * t, ay + dy * t
        d = dist(point, (px, py))
        if best_d is None or d < best_d:
            best_d = d
            best = spine_arcs[i] + (spine_arcs[i + 1] - spine_arcs[i]) * t
    return best or 0.0


def unrolled(geoms, layouts, spine_pts, spine_arcs, width=110,
             title="", only_stacked=True, origin=None, m=None):
    """Returns text rows: lane offset (rows) vs spine arc (columns)."""
    series = {}
    for jid, layout in layouts.items():
        mm = m or mpm(geoms[jid].coords[0][0])
        pts = layout["aligned"]
        if origin is None:
            pts_m = pts
        else:
            pts_m = [((p[0] - origin[0]) * mm, -(p[1] - origin[1]) * mm)
                     for p in pts]
        data = []
        for i, p in enumerate(pts_m):
            if only_stacked and not layout["stacked"][i]:
                continue
            arc = _project_arc(spine_pts, spine_arcs, p)
            data.append((arc, layout["offsets"][i]))
        series[jid] = data
    nums = sorted({geoms[j].num for j in geoms})
    pool = "123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    char_of = {num: pool[i % len(pool)] for i, num in enumerate(nums)}
    all_offsets = [o for data in series.values() for _, o in data]
    if not all_offsets:
        return f"{title}: (nothing stacked)"
    lo = math.floor(min(all_offsets) / 2.1 - 0.6)
    hi = math.ceil(max(all_offsets) / 2.1 + 0.6)
    rows = []
    header = f"{title}  [rows: lane offset (lanes), cols: arc along spine]"
    grid = {}
    for jid, data in series.items():
        ch = geoms[jid].num[0].upper()
        for arc, off in data:
            col = int(arc / max(spine_arcs[-1], 1) * (width - 1))
            row = round(-off / 2.1)  # +offset (left of travel) up
            grid[(row, col)] = (grid.get((row, col)), ch)
    legend = "  ".join(f"{char_of[n]}={n}" for n in nums)
    out = [header, f"       {legend}"]
    for row in range(hi, lo - 1, -1):
        line = []
        for col in range(width):
            cell = grid.get((row, col))
            line.append("·" if cell is None else cell[1])
        label = f"{-row * 2.1:+.1f}"
        out.append(f"{label:>6} {''.join(line)}")
    return "\n".join(out)
