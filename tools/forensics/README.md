# Corner-X forensics (route 5 downtown apex)

Verification scaffold for the miter-overshoot collapse fix
(`stableRouteOffsetPoints` / `LaneHarness.ribbon` / `lane_geometry.ribbon`).
Built against the device export in `e40d2be`
(`tools/replay/data/waybound-lanes-1790225339.json`).

`drawn_paths.py` is a faithful port of the app's drawn-centerline pipeline
(local scan 20 m / |dot| >= 0.93 midpoint+endpoints, schedule sticky ref,
8 m clamped projection, 30 m street-anchor, per-vertex average, gap bridge,
0.25/0.5/0.25 stabilize, 58 m taper, 0.08 clamp + corner hold, Gaussian
lateral smooth) followed by true-scale ribbons (via
`tools/lane-visualization/lane_geometry.py`) and crossing tests. It imports
`lane_geometry`, so ribbon results always track the current Swift logic.

Run (from anywhere; export path is argv[1]):

    python3 tools/forensics/drawn_paths.py tools/replay/data/waybound-lanes-1790225339.json
    python3 tools/forensics/full_cross.py tools/replay/data/waybound-lanes-1790225339.json
    python3 tools/forensics/zoom_render.py tools/replay/data/waybound-lanes-1790225339.json 11 12 13 14 15 16 17
    python3 tools/forensics/zoom_px.py tools/replay/data/waybound-lanes-1790225339.json

`zoom_render.py` replays the zoom-exact draw path (dedup + collapse ribbon
+ per-run RDP + isolated/detail/trunk split with live selected-trunk
ownership) at levels 11-17 and reports pink crossings in 120 m windows at
the downtown corners v1/v16/v26. `zoom_px.py` re-checks each crossing with
its screen-pixel margin from the nearest segment endpoint, so sub-stroke
endpoint grazes (buried in the round join) can be told apart from visible
mid-segment Xes.

What the scaffold proved (true scale, 1 unit = 1 m):

- Route 5's drawn deltas at Chapala/Anapamu (v26, 87 deg) are exactly 0,
  offsets constant -14.7, no trunk: its V there is clean. The X is at the
  96 deg corner v16 (34.422330, -119.705620): 22 m of miter reach on
  12.1/14.5 m legs overshoots both straight neighbors, whose plain shifts
  land past the offset lines' crossing. The drawn lane self-crosses
  (segs 14x17) with a 4.5 m spur, and nicks route 17's exit leg (15x20).
- Route 17 (same raw points, offset -10.5, miter 15.7 m) keeps its exit
  neighbor past its miter (14.5 m leg > 10.5 m offset), so it never
  self-crosses: the 5-vs-17 discriminator is outermost-lane miter reach
  vs leg length, not centers, refs, or the corner hold.
- After the collapse fix: route 5 self-X gone, 5x17 nick gone, 85X
  self-loop at its 88 deg corner gone, J-window true-scale crossings drop
  from 6 to 1 (a genuine mixed brown/pink braid 24 m out). Remaining
  route-5 self-crossings are all zero-offset isolated raw-shape overlaps
  (Mesa backtrack etc.), a separate phenomenon.
- Mid zoom needs the cascade: constant-screen lane offsets outgrow
  ground-fixed legs, so one miter overshoots several vertices (L16 v16:
  58 m of reach on 12 m legs). The per-apex outward walk collapses every
  plain contiguous joint within reach; the zoom sweep then reads clean
  at L11-13 and L16-17, and street scale loses exactly one self-crossing
  (segs 14x17, the v16 fold) with zero new crossings anywhere.

One-line roles:

- `drawn_paths.py` — full centerline port + J-window crossings (true + 2x).
- `full_cross.py` — full-route route-5 pair/self crossings + corner census.
- `anatomy.py`, `anatomy17.py` — v16 corner coordinates, 5 vs 17 legs.
- `verify.py` — exact nick location, 17 self-check, self-X context, leg census.
- `diag85x.py` — 85X centerline sines/reach/legs + v935/v966 context.
- `d85.py` — 85X drawn points + exact residual crossing parameters.
