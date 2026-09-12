"""SVG renderer for corridor ribbons: main vs scheduled, side by side.

Pure standard-library; writes one .svg per scenario into tools/replay/out/.
Lane offsets are drawn in screen points at the same metres-per-point ratio
the app uses near street zoom, so ribbon spacing matches the shipped look.
"""
import math
import os

PALETTE = {
    "1": "#e4572e", "2": "#17a398", "3": "#2e6f95", "4": "#8e3b46",
    "5": "#f2a541", "6": "#5b8e7d", "7": "#4f5d75", "11": "#9c89b8",
    "12X": "#0f4c5c", "17": "#b0413e", "24X": "#5d8233", "12x": "#0f4c5c",
    "24x": "#5d8233",
}
DEFAULT = "#666666"
BACKGROUND = "#f7f4ee"
ROAD = "#e3ded3"
MPP = 2.0          # metres per screen point at street zoom
SCALE = 1.0        # svg units per screen point
STROKE = 3.4
CASING = 0.8


def _bbox(ribbons):
    xs, ys = [], []
    for pts in ribbons.values():
        for x, y in pts:
            xs.append(x)
            ys.append(y)
    if not xs:
        return 0, 0, 1, 1
    return min(xs), min(ys), max(xs), max(ys)


def _panel(ribbons, title, x0, y0, x1, y1, width, height):
    """SVG fragment for one panel; ribbons given in screen-point space
    (y down) — flip y for a north-up rendering."""
    out = [f'<text x="{width / 2:.0f}" y="28" font-family="Helvetica" '
           f'font-size="15" fill="#403a34" text-anchor="middle">{title}</text>']
    cx = (x0 + x1) / 2
    cy = (y0 + y1) / 2
    tx = width / 2 - cx * SCALE
    ty = height / 2 + cy * SCALE
    out.append(f'<g transform="translate({tx:.1f},{ty:.1f}) scale(1,-1)">')
    # casing pass then colour pass keeps the hairline separators readable
    for label, pts in ribbons.items():
        d = " ".join(f"{x * SCALE:.1f},{y * SCALE:.1f}" for x, y in pts)
        if len(pts) >= 2:
            out.append(f'<polyline points="{d}" fill="none" stroke="#1c1917" '
                       f'stroke-width="{STROKE + CASING}" stroke-linecap="round" '
                       f'stroke-linejoin="round" opacity="0.75"/>')
    for label, pts in ribbons.items():
        d = " ".join(f"{x * SCALE:.1f},{y * SCALE:.1f}" for x, y in pts)
        if len(pts) >= 2:
            num = label.lstrip("j").upper()
            color = PALETTE.get(num, DEFAULT)
            out.append(f'<polyline points="{d}" fill="none" stroke="{color}" '
                       f'stroke-width="{STROKE}" stroke-linecap="round" '
                       f'stroke-linejoin="round"/>')
    out.append("</g>")
    return "\n".join(out)


def render_comparison(geoms, ribbons_main, ribbons_sched, path, title=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bx0, by0, bx1, by1 = _bbox({**ribbons_main, **ribbons_sched})
    w = (bx1 - bx0) + 80
    h = (by1 - by0) + 80
    panel_w, panel_h = max(360, w), max(220, h)
    width, height = panel_w * 2 + 60, panel_h + 60
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}">',
        f'<rect width="{width}" height="{height}" fill="{BACKGROUND}"/>',
    ]
    parts.append(_panel(ribbons_main, f"{title} — main (today)",
                        bx0, by0, bx1, by1, panel_w, panel_h))
    parts.append(_panel(ribbons_sched, f"{title} — anchored lanes (branch)",
                        bx0, by0, bx1, by1, panel_w, panel_h))
    parts.append("</svg>")
    with open(path, "w") as fh:
        fh.write("\n".join(parts))
