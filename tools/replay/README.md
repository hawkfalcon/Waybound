# Replay harness

Python mirrors of the two geometry passes that are hardest to reason about
in the abstract, plus the regression batteries that gate changes to them.
There is no Swift toolchain in the environment where this work is developed,
so every candidate change is prototyped here — mirroring the Swift algorithm
exactly — validated against the batteries and real traces, and only then
ported. If a Swift change and these mirrors ever disagree, reconcile before
shipping.

Run both (a few seconds, no dependencies beyond the standard library):

```sh
python3 tools/replay/battery.py        # stop-connector notch stage
python3 tools/replay/corridor_check.py # corridor alignment rate clamp
```

Each exits non-zero on failure. Both must be green before touching the
Swift counterparts.

## Files

| File | What it is |
| --- | --- |
| `notch2.py` | Port of `TripPathGeometry.removingStopConnectorNotches` / `firstStopConnectorNotchRange` / terminal trim |
| `battery.py` | MUST-DELETE / MUST-KEEP fixtures for the notch stage + property checks on a real trace |
| `corridor2.py` | Port of the corridor lane pass in `WayboundMapView.swift` (membership, adoption cap, run prune, blend, taper, delta smoothing, rate clamp) |
| `corridor_check.py` | Reference-handoff regression: the Chapala × Sola jog scenario on real geometry |
| `geo.py` | Web-mercator map-point math; `mpm(lat)` = meters per `MKMapPoint` |
| `decode.py` | Google-encoded polyline (precision 1e-6) decoder |
| `data/route_6dt.json`, `data/route_xdt.json` | Real OSRM traces (122 / 70 pts) of downtown Santa Barbara: route 6, which turns off at Sola, and an express-shaped trace that continues up Chapala — the shared-approach handoff |
| `data/geom_6dt.txt`, `data/geom_xdt.txt` | The same traces as raw OSRM response geometry (backslash-escaped polylines) for provenance |

## Constant parity

Notch stage (`notch2.py` ↔ `Waybound/Transit/TripPathGeometry.swift`):
path ≤ 260 m, chord ≤ 240 m, depth 3–25 m, apex ≤ 12 m from a trip stop,
anchor and return each ≤ 8 m off the other leg's line of travel,
heading-through dot ≥ 0.9, at least one leg ≥ 40° off the street
(cos 40° ≈ 0.766), ≤ 64 interior passes. Terminal trim: up to 3 vertices
per end, each within 12 m of a stop and ≥ 70° off the street (dot ≤ 0.34),
with the street line measured from outside the connector — the first
vertex beyond 25 m of the terminal.

Corridor pass (`corridor2.py` ↔ `Waybound/Views/WayboundMapView.swift`):
parallel membership 20 m / dot 0.93, projection adoption cap 6 m, run prune
30 m, offset blend 72 m, gap bridge 150 m, delta smoothing [.25 .5 .25],
taper 58 m, alignment rate clamp 0.08 m per meter of street in two
symmetric passes.

## Disciplines baked into this harness

- `mpm(lat) = cos(lat) · 2π · 6378137 / 268435456` — map points *shrink*
  toward the poles; ≈ 8.1188 pts/m at 34.42° N. An earlier harness divided
  instead of multiplying and every threshold was 1.47× off.
- `travelHeading`-equivalents must be normalized to the direction of travel
  (a backward walk returns `unit(far → index)`), use a ≤ 3-vertex / ≤ 60 m
  baseline, and single-vertex headings are unreliable on duplicates.
- Deleting street vertices is only ever safe by *construction* — the span
  ends must be gated onto the street's own lines. A perpendicularity
  heuristic was tried once and ate real jogs and corners.
- With long chord caps, two companion gates are mandatory: the anchor must
  also sit on the *outgoing* line (or the stop itself can pass as the
  return vertex), and at least one excursion leg must be steep (or crests
  and S-curves with an apex stop get deleted).
- OSRM polylines fetched via HTTP tooling arrive backslash-escaped;
  `.replace('\\\\', '\\')` before decoding or the varint stream desyncs.
- Real-shape regressions: a clean trace with no stops must come back
  untouched, and with stops nearby, every surviving vertex must stay on the
  original street polyline.

## Trace provenance

Both traces were routed through the public OSRM instance
(router.project-osrm.org) on 2026-08-30, from the downtown transit center
area (−119.7035, 34.4210). `route_6dt` follows route 6's downtown path via
Sola to State Street (3.0 km); `route_xdt` runs up Chapala and across
Arrellaga (1.4 km), standing in for the 12x/24x expresses where they share
Chapala with route 6 south of Sola. Feed drift (the two agencies'/routes'
centerlines disagreeing by a few meters) is injected synthetically in
`corridor_check.py` because both traces come from the same router.
