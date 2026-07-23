# oo_v1 — Reverse-GNSS EKF Simulation

A clean, object-oriented MATLAB simulation of a **reverse-GNSS** link: several ground towers
transmit GNSS-like ranging signals *up* to one or more space assets, and each asset estimates its
position, velocity, attitude, angular rate and receiver-clock state with an Extended Kalman Filter.
Everything lives under `oo_v1/` and runs on MATLAB R2025b.

The validated headline case is a single **GEO** asset with a **4-antenna cross** (attitude on).
An optional inter-satellite-link (ISL) swarm of secondaries, and an optional two-way time-transfer
(TWSTFT) observable, can aid the primary.

---

## 1. Quick start

```matlab
cd oo_v1
run_oo_v1        % the one entry point: masterConfig -> simulate -> post-process -> report
```

- **All run configuration lives in `config/masterConfig.m`.** `run_oo_v1.m` is a thin runner that
  adds no physics toggles of its own; change a run by editing `masterConfig`, never the runner.
- Output goes to a self-describing per-run folder (see §5).

### Run knobs (top of `config/masterConfig.m`)

| Knob | Meaning | Default |
|------|---------|---------|
| `cfg.scenario.nTowers` | ground transmitters (12 real sites defined; 5 = the frozen network) | 5 |
| `cfg.scenario.nSpaceAssets` | 1 = ground-only; >1 = helix ISL swarm aiding the primary | 1 |
| `cfg.scenario.nReceivers` | receiver antennas: 1 -> attitude OFF, >=2 -> 4-antenna cross, attitude ON | 4 |
| `cfg.simulation.duration_s` | run length in seconds | 14400 (4 h) |
| `cfg.asset.clockType` | oscillator class: `'CESIUM1'` \| `'OCXO'` \| `'RUBIDIUM'` \| `'TCXO'` | `'CESIUM1'` |
| `cfg.clock.templateSource` | clock realism: `'legacy'` (idealised) \| `'jowTable2p1'` (realistic, literature-anchored) | `'legacy'` |
| `cfg.measurements.twstft.enable` | two-way time-transfer observable on/off | false |
| `cfg.physics.relativity.clock.enable` | gated relativistic clock-rate offset (truth-side) | false |
| `cfg.atmosphere.realistic` | realistic troposphere/ionosphere overlay | true |

`ConfigFactory.finalizeConfig` resolves the literal config into the operative one (rebuilds lever
arms, clocks, atmosphere, frequency masks). The literal masterConfig is **not** the whole story, so
every run writes the fully-resolved config plus a literal-vs-resolved override list into its `.out`
(see §5) — the run is self-describing without MATLAB.

---

## 2. Topology and sign conventions

Reverse GNSS is, in clock/estimation topology, identical to forward GPS: many transmitters (towers,
each with its own clock) and one receiver per asset (one common receiver clock). The pseudorange is

```
z_i = rho_i + b_rx - b_tower_i + (atmosphere, corrections, noise)
```

with the receiver clock common to every row (`+1`) and each tower clock per-row (`-1`). The
"reverse" is purely geometric (transmitters on the rotating Earth, receiver in space), which changes
geometry/elevation, atmosphere path direction, Sagnac/light-time bookkeeping and observability.

---

## 3. Architecture

```
config/
  baseConfig.m        Structural defaults + physical base values.
  masterConfig.m      THE run config: base + user toggles + scenario assembly.
  validateMasterConfig.m  Contract check (value derivations happen in ConfigFactory).
+revgnss/
  ConfigFactory.m     finalizeConfig / presets / clock templates / atmosphere profile.
  ScenarioFactory.m   Instantiates asset(s), towers, EKF, measurement + error models from cfg.
  ReverseGNSSSimulation.m  Simulation orchestrator (truth -> measure -> predict -> update).
  ReportRunner.m      Single-run driver: simulate + optional PDF/MAT/.out/.tex report.
  ClockExactReportBuilder.m  The production LaTeX report builder.
  ConfigTextDump.m    Flatten a config + diff literal vs resolved (for the .out).
  MonteCarloConsistency.m  Ensemble NEES/NIS consistency harness (chi-square bounds).
  ChiSquareConsistency.m   Two-sided chi-square acceptance bounds (Bar-Shalom).
  Relativity.m        Gravitational + SR clock fractional-frequency offset.
  Plotter.m           Diagnostic figure suite.  Constants.m  Physical constants.
+filter/
  ReverseGNSSEKF.m    14+-state EKF, Joseph update, quaternion attitude error-state reset.
  EkfDynamicsPredictor.m  State propagation + F/Q.
+models/
  +clocks/ClockModel.m       IEEE-1139 power-law oscillator (WPM/FPM/WFM/FFM/RWFM).
  +measurements/*            Code / carrier / Doppler / ISL / TWSTFT measurement + Jacobian builders.
  +errors/*, +atmosphere/*   Error chain, troposphere/ionosphere models.
  +corrections/RangeCorrections.m  Sagnac, Shapiro, antenna PCO/PCV.
  +frames/*, +orbit/*        Frame/time utilities, J2 orbit propagator.
+data/
  SimulationDataStore.m  Flat per-epoch diagnostics store (position/clock/attitude/NIS/NEES).
archive/
  Retired, zero-reference scaffolding (kept out of the main tree; still resolvable).
```

---

## 4. State vector and measurement model

Base dimension **14**: `r(3) v(3) euler(3) omega(3) b_rx bdot_rx`. Augmented per run with carrier
float ambiguities (per tower x receiver x signal), per-tower ZWD, per-tower slant ionosphere, and —
when `estimateTowerClocks=true` — 2 states per tower.

```
antenna phase centre : r_ant = r_cm + C_ecef_body(euler) * leverArm_body
truth pseudorange    : z_i = ||r_ant_true - r_tower_i|| + b_rx - b_tower_i
                           + trop + iono(+code) + hardware + multipath + noise
model pseudorange    : h_i = ||r_ant_est  - r_tower_i|| + b_rx_est - b_tower_model_i
                           + trop_model + iono_model(+code)
```

Signs (verified): LOS Jacobian `+u` (tower->spacecraft unit vector); receiver clock `+1`; tower
clock `-1`; ionosphere `+` for code / `-` for carrier; troposphere `+` for both. Attitude is
observable only through the lever arm and (with >=2 antennas) carrier phase; it is weak from code.

---

## 5. Output structure

```
output/Report_YYYYMMDD/Report_v###_G#S#R#_TW#/Report_v###_ts#_G#S#R#_TW#.{pdf,mat,out,tex}
  v### = cfg.report.runVersion (numeric -> v%03d, else sanitised)
  ts#  = simulation duration in seconds
  G/S/R = ground towers / space assets / receivers
  TW#  = TWSTFT two-way time transfer enabled (1) or not (0)
```

The `.out` is a MATLAB-free run log: final metrics, output paths, the full **resolved** config, and
the **literal-vs-resolved override list** (what `finalizeConfig` changed — e.g. atmosphere on,
standalone Sagnac folded into iterative light-time, codeMode resolution).

**Ladder runs** (`run_ladder`) group every rung of one run under a single folder:

```
output/Report_YYYYMMDD/Ladder_{description}/Report_v###_G#S#R#_TW#/Report_v###_ts#_G#S#R#_TW#.{...}
output/Report_YYYYMMDD/Ladder_{description}/Ladder_{description}.txt   (combined summary)
```

`run_ladder(idx, durationOverride_s, description)` runs topology rungs; `run_ladder(k, 43200, 'x')`
overrides a rung's duration (e.g. 12 h).

---

## 6. Clock model

`ClockModel` implements the IEEE-1139 power-law PSD `S_y(f) = h2 f^2 + h1 f + h0 + h-1/f + h-2/f^2`.
WFM/RWFM propagate directly in the time domain; WPM/FPM/FFM are FFT-synthesised over the run. The EKF
process noise Q is the Brown-Hwang 2-state (bias, drift) result from the dominant WFM+RWFM terms.

Clock realism is one string: `cfg.clock.templateSource='legacy'` is an idealised/optimistic set;
`'jowTable2p1'` is the literature-anchored realistic set (real caesium / OCXO). The headline default
is `'legacy'`; switching to `'jowTable2p1'` degrades the timing result honestly. A known limit: for a
caesium receiver the drift wander is far below the Doppler resolution, so the drift +-3 sigma envelope
is observability-limited (measured in the report, not a filter bug).

The relativistic clock-rate offset (gravitational + SR, ~5.4e-10 fractional for GEO vs ground) is a
gated truth-side term (`cfg.physics.relativity.clock.enable`, default off); the constant offset is
absorbed by the estimated drift for a circular orbit, so it leaves zero estimation residual.

---

## 7. Regression gate and consistency

**Frozen golden gate** — certifies the scientific numbers never move under refactors:

```matlab
tests/regression/run_oo_v1_regression('smoke')              % 120 s single-antenna
tests/regression/run_oo_v1_regression('full')               % 14400 s single-antenna
tests/regression/run_oo_v1_regression('smoke','headline')   % 4-antenna headline
```

Two frozen references (single-antenna baseline + 4-antenna headline). The gate re-runs the frozen
scenario and fails if any core scientific metric moves beyond FP tolerance; non-core diagnostic
changes only warn. Never weaken it.

**Monte-Carlo consistency** — `revgnss.MonteCarloConsistency.run(baseCfg, opts)` runs an ensemble
(initial error drawn from P0; measurement + clock-truth seeds varied per draw), pools per-epoch
NIS/NEES, and band-checks the pooled sums against a two-sided chi-square interval. Synthetic
consistency evidence, not real-world proof; not run by the default single run.

**Full unit suite:** `cd oo_v1; tests/run_all_tests` runs every `tests/test_*.m`.

---

## 8. Limitations (not claimed)

- One-way uplink is clock- and geometry-limited; the two-way (TWSTFT) and ISL-swarm paths reach the
  sub-metre / sub-100 ps regime, a one-way link alone does not.
- No integer ambiguity fixing (LAMBDA/MLAMBDA) — carrier runs as float ambiguities.
- No calibrated hardware bias / DCB / phase-bias products; no ANTEX/IONEX/SP3/CLK/RINEX ingestion.
- No IERS/EOP-grade reference frames; simplified constant Earth-rotation rate.
- Meter-to-decimeter single-asset navigation; the swarm/two-way paths reach sub-metre / sub-100 ps.

---

## 9. Kalman convergence — what to expect

Pseudorange from N towers primarily observes position (3) and receiver clock bias (1); with few
measurements and many states the EKF is per-epoch underdetermined but converges recursively. Common-
mode delays (atmosphere, clock) are partly absorbed by the receiver-clock state — physically correct,
so atmosphere modelling improves innovation RMS more than position. Attitude converges slowly (weak
observability); position and clock converge first, typically within ~600-1800 s. Once converged, NIS
sits near the number of visible measurements; a conservative filter sits below the chi-square band.
