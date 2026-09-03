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
(cos 40° ≈ 0.766), ≤ 128 interior passes. Terminal trim: up to 3 vertices
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
- That formula models the LEGACY 256-point MapKit world. The Xcode 26 SDKs
  ship a meter-based `MKMapPoint` world where point distances are already
  true meters while `MKMapPointsPerMeterAtLatitude` still answers the legacy
  constant — the Swift helper now self-calibrates against `CLLocation`
  instead of trusting it (this exact mismatch made every app threshold ~8×
  too strict and is why the first full Xcode run failed while the Python
  mirrors passed).
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

## Lane metrics (corridor3.pair_metrics, bundle_wobble, min_lane_separation)

All lane-quality numbers are measured on the DRAWN ribbons (ribbon() applies
stableRouteOffsetPoints verbatim) against a COMMON street spine, so no
travel-frame convention can fake or hide a result:

- `project_onto_spine(layout, geoms, spine)` — screen-space projection of a
  ribbon onto one spine polyline. The spine's direction chain is *held*
  through its own 180° reversals (held_directions), so lateral sign is
  stable along the street. The cursor full-searches the first sample and
  re-anchors when a windowed hit is > 40 pts away (approach stubs).
- `pair_metrics(a, b, ...)` — orientation-stable wrapper (tries both
  observers' dominant spines, keeps the one with more matched pairs).
  Samples are paired by spine arc (bisect, either direction of travel).
  Excluded per sample: spine corners (miter pinch is renderer physics,
  not a lane change — the whole segment touching a turn is flagged),
  |lateral| > 50 pts (that ribbon is on another street), and samples
  within 3 of a stacked/ref boundary on either side (tapered join/leave).
  The sequence is split into monotone passes (a U-turn's two legs are never
  compared to each other); each pass is trimmed 20% at both ends (a merge
  from an adjacent lane sweeps while it converges — a join, not drift).
  Drift = robust p5–p95 range of (lat_a − lat_b); gap = p5 of |lat_a −
  lat_b|. Both in lanes (LS = laneSpacingPoints = 4.2 screen pts).
- `bundle_wobble` = worst pair drift over the bundle; `min_lane_separation`
  = worst pair gap. Same-public-key pairs share a lane by design: skipped.

Gate semantics (lane_check, lane_fuzz): comparative against main run on the
same scenario — wobble_sched ≤ max(0.05, wobble_main)·1.10 + 0.05,
sep_sched ≥ min(0.75, sep_main) − 0.02 (− per-scenario sep_slack).
Structurally forced crossings are gated by per-scenario max_bundle.

Known scheduler gap (next fix): slots are stored and applied along each
journey's OWN path normals, so a journey whose own polyline runs ~half a
lane inside the street draws ~half a lane inside its slot (fuzz seeds 35/
42/46/68: sched sep 0.4–0.6 vs main ~1.0). Tried and reverted this round:
`_spine_delta()` grounding — subtract the own path's lateral displacement
from the applied offset (delta measured against the ref spine's held
normals, in screen points). With full grounding those four seeds go to
0.8–1.0, but forks gain crossings (a peeling strand's delta grows fast and
pushing it sideways crosses the bundle: fuzz seeds 4 and 10 went 2->8 and
2->10 in-bundle crossings), and a gradient fade trades one class for
another (45 -> 55 problem seeds). The next attempt should ground on a
group-consensus street (median displacement of the bundle) rather than a
single ref, and skip observers whose corridor membership is ending.

## Fuzz status after the metric rebuild (2026-09-01)

lane_check: green on all 7 scenarios (drawn-ribbon metrics, comparative
gates). lane_fuzz: 45/120 seeds flagged, now all real signal, classes:
- crossings added vs main (15 seeds; worst 43: 5->13, 10: 2->10, 1: 12->14)
- bundle wobble above main (sched instability; worst 54: 5.41 vs 0.00,
  18: 2.64 vs 0.00, 61: 4.09 vs 0.37)
- separation below main (own-path displacement class above; plus marginal
  both-bad cases where main also pinches)

## Swift port (2026-09-02)

The anchored-lane scheduler is now ported into
`Waybound/Views/WayboundMapView.swift` (this file remains the executable
spec; constants above are mirrored 1:1 by `CorridorLaneScheduling`):

- `Coordinator.recomputeCorridorLaneSchedule()` — runs inside
  `ensureCorridorLaneLayouts()`'s corridor-content signature gate, so the
  schedule is cached per static feed/journey set and live departures never
  re-trigger it. It builds one `CorridorSchedStrand` per (journey,
  flagship polyline) from the same densified coordinates the layout pass
  uses, plus each strand's held-direction chain (the renderer's reversal
  hold), then `buildCorridorLaneSchedule` (runs → union-find corridors →
  longest-first sweeps → `postFillSchedule`).
- `CorridorSegmentIndex` gained per-segment `CorridorSegmentLocation`
  (polylineIndex, segmentIndex) and `parallelMember(near:direction:)` so
  the membership scan can locate a matched segment on the member's own
  strand — the `own_index` of the spec.
- `sharedCorridorSegmentLayout` no longer re-sorts members per sample or
  re-centres offsets on current member count. It keeps membership,
  dominance/trunk voting, and adoption, but the lane offset comes from
  `corridorLaneSchedule[(journey, polyline)][segmentIndex]`, converted
  into the journey's own frame by the held-direction dot (replacing
  main's per-sample directionSign). Alignment follows the schedule's
  sticky reference when locally matched.
- The rest of the pipeline (removeShortCorridorRuns, offset averaging,
  stabilize/bridge/transitions, taper, clamp, `stableRouteOffsetPoints`,
  dedup, trunk/detail cross-fade) is untouched.

Port divergences (intentional): member ordering uses the shipped
`corridorLaneComesBefore` (route number → agency → direction → stack →
id) everywhere, where the spec's `sort_key` omitted agency; strands are
per flagship polyline rather than per journey (multi-leg trips schedule
each leg independently, keyed by (journeyID, polylineIndex)).

No Swift compiler exists in this sandbox: the port was validated by
line-by-line review against the spec above. lane_check (7 scenarios,
drawn-ribbon metrics) and lane_fuzz expectations carry over unchanged;
the real gate is the downtown-SB screenshot comparison on a Mac build.
