# Replay data

Real device exports and OSRM traces used by `WayboundCore` golden tests.

## Contents

- `data/waybound-lanes-*.json` — lane diagnostics exports (`waybound-lanes-v1` format):
  densified flagship coordinates, anchored-lane schedule, and final per-vertex
  layouts. Consumed by `LaneLayoutGoldenTests`, `LaneScheduleGoldenTests`, and
  `ScanGoldenTests` to pin the Swift port to the device's own recorded geometry.

- `data/route_6dt.json`, `data/route_xdt.json` — real OSRM traces of downtown
  Santa Barbara: route 6 (turns off at Sola) and an express-shaped trace that
  continues up Chapala. The shared-approach handoff scenario.

- `data/geom_6dt.txt`, `data/geom_xdt.txt` — same traces as raw OSRM response
  geometry for provenance.

- `data/baked_fragments_1420.json` — additional geometry fixture.

## Golden tests

```
swift test --package-path WayboundCore --filter LaneCheckTests
swift test --package-path WayboundCore --filter LaneFuzzTests
swift test --package-path WayboundCore --filter LaneLayoutGoldenTests
swift test --package-path WayboundCore --filter LaneScheduleGoldenTests
swift test --package-path WayboundCore --filter ScanGoldenTests
```

The lane quality gates (crossings, wobble, separation, kink) now live in
`WayboundCore` as plain Swift tests. Python mirrors previously in this directory
have been retired — the Swift implementation is the source of truth.

## Lane visualization

See `tools/lane-visualization/` for the visual debugger that renders real lane
ribbons and crossings from these exports:
`python3 tools/lane-visualization/draw_lanes.py`

## Provenance

Traces routed via router.project-osrm.org on 2026-08-30 from downtown transit
center area (-119.7035, 34.4210).
