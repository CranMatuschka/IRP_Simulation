# Multi-asset helix ISL swarm

Reverse-GNSS with a helix swarm of space assets. The **primary** asset (index 1) is
the only one estimated by the EKF; the other assets are **represented-only** precise
references that transmit one-way inter-satellite links (ISL) into the primary EKF.
All reported results are the primary asset's position/clock error — "one asset, based
in a swarm".

## Why a swarm (the physics)

Ground beacons all sit **below** a GEO asset, so every line of sight lies in an
upward cone: the radial (height) position and the receiver clock are nearly
degenerate (VDOP >> HDOP, GDOP ~1200). Ground-only the primary converges to only
**~8 m position / ~26 ns clock**, and the error is **vertical-dominated** (height
RMS ~14 m, vertical/horizontal ratio ~20).

A one-way ISL code row from a swarm-mate is an extra pseudorange with a
**non-vertical** line of sight (the mates are beside/around the primary, not below
it). It carries the receiver-clock column, so it is consistent with the ground
pseudoranges and directly breaks the radial/clock degeneracy. The vertical error
collapses from ~14 m to ~2 cm.

The per-reference product bias (see below) averages down over the `N-1` secondaries,
so the primary clock scales roughly as `1/sqrt(N-1)`: a 100 ps reference ensemble
yields a sub-100 ps primary clock — the same ensemble-timescale principle as TAI.

## The one control

`cfg.scenario.nSpaceAssets` in `config/masterConfig.m`:

- `= 1` — single asset, ground-only (the frozen single-asset regression baseline).
- `> 1` — helix ISL swarm. Everything else auto-configures.

Formation (`cfg.formation`):
- `mode = 'helix'` — bounded Clohessy-Wiltshire projected-circular relative orbit
  about the primary chief, propagated with the same j2 dynamics (physically real,
  not dead-reckoned). Separation stays in `[baseline, 1.118*baseline]`, bounded to
  <0.5 m drift over 12 h at GEO.
- `baseline_m` — the inter-satellite separation (default 1000 m, a changeable
  variable, kept > 500 m).

## The ISL aiding (honest, not perfect-truth)

`cfg.measurements.isl` (auto-set for the swarm):
- `transmitters = 'all'` — every secondary aids the primary (multi-transmitter).
- one-way **code** + **Doppler** enter the EKF; **carrier** is diagnostic-only
  (needs ISL ambiguity states, not implemented).
- `code.sigma_m` (0.3 m, good microwave ISL), `doppler.sigma_mps` — thermal
  measurement noise added to z. The ISL code ranging noise sets the clock floor
  (not the reference products): 1.0 -> 0.3 m halves the primary clock (~92 -> ~47 ps).
- `product.*` — the secondary is a broadcast **product** (ephemeris + clock) with a
  piecewise-constant error re-issued every `updateInterval_s` (300 s)
  (`productAidedExternal`). This biases the model and inflates R, so the achievable
  primary accuracy is floored by the reference-product quality — the aiding is honest,
  not perfect-truth. `sigmaPos_m` ~5 cm (precise OD), `sigmaClock_m` ~3 cm (~100 ps
  reference clock). The per-interval error averages down across intervals and swarm
  members, so the primary clock beats a single reference (ensemble timescale).
- `warmup_s = 300` — ISL rows are diagnostic until the ground-only fix converges
  (the initial covariance shrinks), then they enter the EKF. Prevents the
  tight-ISL-on-huge-initial-covariance transient overshoot.

Two-way ISL range and TWSTFT stay diagnostic (two-way range has no clock column and
is ill-conditioned into this near-degenerate filter).

## Result (default 6-asset helix, 1 km baseline)

Primary asset, one-way ISL code+Doppler from 5 references (last-20% RMS):

| metric | ground-only | + helix ISL swarm (3600 s) | + swarm (12 h) |
|---|---|---|---|
| position | ~8 m | ~0.084 m | **~0.095 m** |
| height (Up) RMS | ~14 m | ~0.03 m | **~0.022 m** |
| vertical/horizontal ratio | ~21 | ~0.3 | **~0.24** |
| clock | ~26 ns | ~47 ps | **~72 ps** (meets 100 ps = 3 cm) |
| clock NEES (consistency) | — | ~1 (consistent) | ~2 (≈consistent) |

The clock floor is set by the **ISL code ranging noise**, not the reference products
(tightening product position 5→3 cm or clock 100→50 ps barely moved it). ISL code
1.0→0.3 m halves the clock. Swarm size gives further margin (clock ~`1/sqrt(N-1)`).

Honest limitations:
- The reference-product error is correlated **within** each broadcast interval
  (~300 epochs) but R models it as white, so the **position** NEES grows above the
  ideal over long runs (~10–15 vs 3): the position covariance is optimistic —
  reported, not hidden. The clock NEES stays ≈1–2 (consistent). A per-reference bias
  state (consider/Schmidt-Kalman filter) is the principled fix.
- The 100 ps **clock** (timing) budget is met with margin over the full 12 h. The
  **position** (~9 cm) is sub-wavelength (L1 ≈ 19 cm) but ground/atmosphere-limited,
  not ISL-limited; driving it to 3 cm needs ISL carrier phase (mm ranging).
- ISL carrier phase is generated but diagnostic-only (needs ISL ambiguity states);
  one-way code+Doppler already meet the timing budget.

## Regression

The frozen Stage-85 golden (`tests/regression/`) forces the single-asset baseline in
`goldenScenarioConfig.m`, so it keeps certifying the single-asset physics unchanged
regardless of the swarm default.
