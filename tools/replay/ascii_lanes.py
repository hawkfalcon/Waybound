"""Terminal rasteriser for corridor ribbons — quick visual feedback without
image dependencies. Prints each strand's ribbon into a shared character grid
(route number's first character), main and scheduled side by side."""
import math

CHARS = {}


def _char(label):
    num = label.lstrip("j").upper()
    return num[0] if num else "?"


def ascii_panels(ribbons_main, ribbons_sched, width=150, height=34,
                 titles=("main (today)", "anchored lanes (branch)")):
    both = {**ribbons_main, **ribbons_sched}
    xs = [p[0] for pts in both.values() for p in pts]
    ys = [p[1] for pts in both.values() for p in pts]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    span = max(x1 - x0, 1e-6), max(y1 - y0, 1e-6)
    out = []
    for title, ribbons in ((titles[0], ribbons_main),
                           (titles[1], ribbons_sched)):
        grid = [[" "] * width for _ in range(height)]
        for label, pts in ribbons.items():
            ch = _char(label)
            for i in range(len(pts) - 1):
                (ax, ay), (bx, by) = pts[i], pts[i + 1]
                steps = int(max(abs(bx - ax) / (span[0] / width),
                                abs(by - ay) / (span[1] / height))) + 1
                for s in range(steps + 1):
                    t = s / max(steps, 1)
                    x = ax + (bx - ax) * t
                    y = ay + (by - ay) * t
                    col = int((x - x0) / span[0] * (width - 1))
                    row = int((y - y0) / span[1] * (height - 1))
                    if 0 <= row < height and 0 <= col < width:
                        grid[height - 1 - row][col] = ch
        out.append(f"--- {title} " + "-" * max(0, width - len(title) - 6))
        out.extend("".join(r).rstrip() for r in grid)
        out.append("")
    return "\n".join(out)
