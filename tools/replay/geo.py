import math
WORLD = 268435456.0
def to_map_point(lat, lon):
    x = (lon + 180.0) / 360.0 * WORLD
    s = math.sin(math.radians(lat))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * WORLD
    return (x, y)
def to_coord(x, y):
    lon = x / WORLD * 360.0 - 180.0
    lat = math.degrees(2 * math.atan(math.exp((0.5 - y / WORLD) * 2 * math.pi)) - math.pi / 2)
    return (lat, lon)
def mpm(lat):  # meters per map point (matches MapKit ~8.1188 pts/m at 34.42N)
    return math.cos(math.radians(lat)) / (WORLD / (2 * math.pi * 6378137.0))
def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])
def perp_distance(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    l2 = dx * dx + dy * dy
    if l2 == 0: return dist(p, a)
    t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2
    t = max(0, min(1, t))
    return dist(p, (a[0] + t * dx, a[1] + t * dy))
def distance_to_polyline(p, pts):
    return min(perp_distance(p, pts[i], pts[i+1]) for i in range(len(pts)-1))
