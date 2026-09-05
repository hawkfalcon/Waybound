"""Tiny pure-Python PNG renderer (stdlib zlib only) so the replay harness can
produce viewable images of corridor ribbons. RGB8, no interlace."""
import math
import struct
import zlib


class Canvas:
    def __init__(self, width, height, background=(247, 244, 238)):
        self.w = width
        self.h = height
        self.px = bytearray()
        for _ in range(width * height):
            self.px += bytes(background)

    def blend_pixel(self, x, y, color, alpha=1.0):
        if not (0 <= x < self.w and 0 <= y < self.h):
            return
        i = (y * self.w + x) * 3
        r, g, b = color
        if alpha >= 1.0:
            self.px[i] = b
            self.px[i + 1] = g
            self.px[i + 2] = r
        else:
            self.px[i] = int(self.px[i] * (1 - alpha) + b * alpha)
            self.px[i + 1] = int(self.px[i + 1] * (1 - alpha) + g * alpha)
            self.px[i + 2] = int(self.px[i + 2] * (1 - alpha) + r * alpha)

    def stroke_polyline(self, pts, color, radius, alpha=1.0):
        """Round-capped polyline with a one-pixel anti-aliased edge."""
        rr = radius
        for i in range(len(pts) - 1):
            (ax, ay), (bx, by) = pts[i], pts[i + 1]
            x_lo = int(min(ax, bx) - rr - 1)
            x_hi = int(max(ax, bx) + rr + 1)
            y_lo = int(min(ay, by) - rr - 1)
            y_hi = int(max(ay, by) + rr + 1)
            dx, dy = bx - ax, by - ay
            l2 = dx * dx + dy * dy
            for py in range(max(0, y_lo), min(self.h, y_hi + 1)):
                for px_ in range(max(0, x_lo), min(self.w, x_hi + 1)):
                    if l2 <= 0:
                        d = math.hypot(px_ - ax, py - ay)
                    else:
                        t = ((px_ - ax) * dx + (py - ay) * dy) / l2
                        t = max(0.0, min(1.0, t))
                        d = math.hypot(px_ - ax - dx * t, py - ay - dy * t)
                    if d <= rr - 0.5:
                        self.blend_pixel(px_, py, color, alpha)
                    elif d <= rr + 0.5:
                        self.blend_pixel(px_, py, color, alpha * (rr + 0.5 - d))

    def write(self, path):
        raw = bytearray()
        stride = self.w * 3
        for row in range(self.h):
            raw.append(0)  # filter type 0
            raw += self.px[row * stride:(row + 1) * stride]
        def chunk(tag, data):
            c = tag + data
            return struct.pack(">I", len(data)) + c + \
                struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
        ihdr = struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0)
        with open(path, "wb") as fh:
            fh.write(b"\x89PNG\r\n\x1a\n")
            fh.write(chunk(b"IHDR", ihdr))
            fh.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
            fh.write(chunk(b"IEND", b""))
