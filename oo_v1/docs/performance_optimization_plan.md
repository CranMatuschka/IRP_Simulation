# Performance Optimization Plan — oo_v1 Reverse-GNSS Simulation

*Author: senior MATLAB dev review · Date: 2026-07-21 · Scope: make runs faster **without changing results**, plus the parallelism options that need no result change.*

---

## 0. Implementation status (what was actually tried, measured, and kept)

> This section supersedes the catalogue below where they disagree — it records what the profiler and the byte-identical gates proved, not what static analysis predicted.

**Corrected baseline (measured, non-profiled):** a single default run is **~17.6 epoch/s → ~13–14 min for 14,401 epochs**, *not* 45–55 min. The "45–55 min" figure is the **6-asset swarm** (6 × a full single-asset run, serial). The MATLAB profiler inflates per-epoch time ~15× here, which misled the first estimate.

**Where the time actually goes (profiler self-time ranking, default config):** it is **distributed across hundreds of small OOP calls per epoch**, not one hot kernel — `AttitudeKinematics.bodyToEcefRotation` (2.8 s / 89 k calls), `LightTimeSolver.solve` (2.2 s), `elevationAngle` trig (1.7 s), `enu2ecef` (1.4 s), `applyLeverArm` (1.2 s), `getAntennaPositionECEF` (1.1 s — already an O(1) property read; pure call overhead), `towerPositionEcef` (1.0 s), Niell/`interp1` (1.3 s). **Consequence: the byte-identical single-run ceiling is low (~10–15%)** — it is death-by-a-thousand-calls, so no single cache moves the needle.

**Bucket A micro-opts — tried, gated, then reverted by decision:**
| Item | Byte-identical? | Net single-run effect | Disposition |
|---|---|---|---|
| A1 memoize `ecef2geodetic` | ✅ gated 0-dev (single+headline+realism) | within noise | reverted (complexity ≫ gain) |
| A3 hoist config reads | ✅ gated 0-dev | within noise | reverted |
| A5 memoize sun/moon ephemeris | ✅ gated 0-dev | within noise | reverted |
| A6 `chol` PSD test (replace `eig`) | ❌ **FAILS gate** (up to 1e-2 rel) | — | rejected: `eig`'s spurious tiny-negative eigenvalue triggers a diagonal nudge that is **load-bearing in the golden**; `chol` skips it. Keep `eig()`. |

Lesson: value-safe *memoization* (cache identical output keyed by exact input) is provably byte-identical, but *alternative-algorithm* swaps (`eig`→`chol`) are not — and here even the safe memoizations don't pay off because the cost is distributed. **Profile first; the static "repeated call" heuristic over-weighted cheap functions.**

**Bucket B — swarm process-parallelism (kept):** implemented as opt-in `cfg.multiAsset.federated.parallel` (default **false** → the byte-identical serial path). When true, the N independent single-asset EKFs run in parallel `matlab -batch` workers (bounded to `cores−1`, override via `cfg.multiAsset.federated.maxWorkers`), each writing a per-asset result `.mat` that the parent gathers; any failed worker falls back to an in-process serial re-run, so a crash or license cap changes only speed. **Verified:** `tests/regression/run_swarm_relative_regression.m` serial baseline still PASSES, and parallel is **bit-identical to serial (max|Δ| = 0)** on the canonical N=4 case — no hidden global-RNG coupling. See `+revgnss/ReportRunner.m` `runFederatedEstimationParallel_`.

- **Enable it:** add `"multiAsset": { "federated": { "parallel": true } }` to the swarm JSON (e.g. `config/swarm_G5S6R4.json`).
- **Measured speedup (8-core Mac, bit-identical in every case):**
  | Case | Serial | Parallel | Speedup |
  |---|---|---|---|
  | N=4, 300 s/asset | 43 s | 61 s | **0.7× (slower)** |
  | N=6, 900 s/asset | 202 s | 117 s | **1.73×** |
  The gain is capped by a large **per-worker cold-start** — MATLAB launch + JIT + reading ~100 class files from the OneDrive-synced repo (network-backed cold reads, 6 workers contending). This is a *fixed* cost per worker, so it dominates short runs and amortizes on long ones.
- **`-singleCompThread` was tried and reverted** — it made things *worse* (1.10×): the per-asset sim benefits from BLAS multithreading more than 6 workers oversubscribing 8 cores costs. So workers keep default multithreading.
- **Production expectation (not yet measured):** a 7200 s × 6-asset run has ~4–5 min of *sim* per asset, so the fixed cold-start becomes a small fraction and the speedup should climb well above 1.73× (rough extrapolation ~3–4×). The two biggest additional levers, if more is needed: (a) put the repo on **local disk** rather than OneDrive (cuts the cold file-I/O that dominates worker startup), and (b) install **Parallel Computing Toolbox** and replace the `matlab -batch` fan-out with an in-process `parfor` (no per-worker MATLAB startup at all).
- It never helps a single (non-swarm) run — that loop is recursive.

---

## 1. Executive summary

The simulation is slow for three compounding reasons, none of which is "a slow matrix":

1. **It is a long, strictly-sequential recursive filter.** One run steps an EKF once per second of simulated time — **14,401 epochs** for the default 4 h run, **7,201 epochs** for a 7,200 s swarm run — and each epoch depends on the previous one, so the epoch loop of a *single* run **cannot be threaded**.
2. **Each epoch runs a "kitchen-sink" physics + estimation stack.** The default config is not a light config: J2 orbit dynamics with a **finite-difference state-transition matrix (12 orbit re-integrations per epoch)**, dual-frequency L1+L2, carrier `ekfFloat` ambiguities, **differential-attitude calibration with ambiguity resolution**, a finite-difference measurement Jacobian, a clock-observability window solve, and postfit residuals that **re-evaluate the whole measurement model a second time**. Measured default rate ≈ **1.36 epoch/s under the profiler** (nx = 59).
3. **Independent runs are executed one after another.** The **N = 6 swarm** runs six full single-asset EKFs in a plain `for ai = 1:N` loop (`ReportRunner.m:1848`); batteries/sweeps loop over 12+ independent configs sequentially (`run_oo_v1_battery.m:63`). These are *embarrassingly parallel* and are currently 100 % serial.

There are two **independent** levers, and they stack:

| Lever | Applies to | Result change | Expected gain |
|---|---|---|---|
| **A. Cut per-epoch work** (caching / hoisting / preallocation / cheaper PSD test) | every run, incl. the single 4 h run | **none (byte-identical)** | **~1.5–3× per run** |
| **B. Parallelize independent runs** (swarm assets, batteries, MC seeds) | swarm, batteries, sweeps, MC | none (each run identical) | **near-linear in cores** (e.g. 6× swarm on ≥6 cores) |

> **Hard constraint discovered:** **Parallel Computing Toolbox is NOT installed** (MATLAB R2025b; installed toolboxes are Antenna, Comms, DSP, Mapping, Navigation, Phased Array, RF, Robotics, SatComms, Signal, Stats/ML, Symbolic, Stateflow, Simulink — no PCT). Therefore `parfor` / `parpool("Processes")` / `parpool("Threads")` / `gpuArray` give **no speedup here** (`parfor` silently runs serially without PCT). Lever B must be done at the **OS-process level** (multiple `matlab -batch` workers) — which is toolbox-free, fully byte-identical, and already half-built in `run_tests_all.m`'s slice mechanism.

---

## 2. Measured baseline & where the time goes

**Config resolution (verified by evaluating the config in MATLAB):**

| Quantity | Default | Realism (`realism.grade=true`) |
|---|---|---|
| State dim `nx` | 59 (5 towers, 4 receivers, 1 asset) | 59 |
| `dt_s` | 1 s | 1 s |
| Epochs (default 4 h / swarm 7,200 s) | 14,401 / 7,201 | 14,401 / 7,201 |
| EKF dynamics mode | **`j2`** (not constant-velocity) | `j2` |
| Orbit perturbations in EKF (sun/moon + SRP) | off | **on** |
| Carrier | `ekfFloat`, dual-freq L1+L2 | same |
| Differential attitude | calibration + AR **on** | same |

Two facts that matter for the plan:

- **The default run already pays the expensive orbit-integration path.** Because EKF `dynamics.mode = 'j2'`, `predict()` calls `EkfDynamicsPredictor.finiteDiffStm6`, which propagates the full orbit **12 times per epoch** (central differences on 6 states) plus 1 nominal propagation. Each propagation does an ECEF→inertial→ECEF frame transform + RK4.
- **Realism is 3–4× slower per epoch** because `realismGradeConfig` turns on luni-solar + SRP perturbations, so **each** of those ~13 orbit propagations now also evaluates the sun/moon ephemeris and SRP force (`EkfDynamicsPredictor.m:120–131`, `OrbitPerturbations.accel`). Same code path, heavier force evaluation.

**Cost taxonomy:**

| Bucket | Runs how often | Notes |
|---|---|---|
| Per-epoch estimation+truth (`step`) | ×14,401 (or ×7,201×6) | **dominates**; everything in §3 lives here |
| One-time report / PDF (`ReportRunner.runSingle` tail, `ClockExactReportBuilder`/`LatexReportBuilder`, `exportgraphics`) | ×1 at end | heavy in absolute terms but **fixed**; skip with `report.writePdf=false` for sweeps (batteries already do) |

(The measured per-function hot table from the profiler is in the **Appendix**.)

---

## 3. Root causes, ranked

1. **Sequential recursive loop** (`ReverseGNSSSimulation.run`, `for k = 1:nEpochs`). Inherent — a single run's loop cannot be parallelized. → attack per-epoch cost (Bucket A) and parallelize *across* runs (Bucket B).
2. **Finite-difference STM: 12 orbit re-integrations/epoch** (`EkfDynamicsPredictor.finiteDiffStm6`). In realism each re-integration also re-computes the **same** sun/moon ephemeris and the **same** frame-rotation matrices — these are **loop-invariant across the 13 calls** (they depend only on `t0`/`t1`, not on the perturbed `r`,`v`). Biggest realism lever.
3. **Repeated `ecef2geodetic` (5-iteration Bowring) on stationary towers** (`GeometryUtils.elevationAngle`, `LinkGeometry.analyticLosJacobian`, `MeasurementModelUtils.modelRangeOnly`). The tower does not move, yet the geodetic solve is redone every epoch — and **6×M times/epoch** when the finite-difference measurement Jacobian is active (Sagnac on → `needsFiniteDiffH_` true). Biggest measurement-path lever.
4. **Kitchen-sink estimation**: differential-attitude calibration runs a **second EKF `update()`** per epoch (`ReverseGNSSSimulation.m:553`); dual-freq L1+L2 doubles code/carrier rows and ambiguity states; carrier `ekfFloat` builder runs every epoch.
5. **Postfit residuals re-evaluate the measurement model a second time per epoch** (`computePostfitResiduals_` → `computePseudorangeModelOnly` / `computeCarrierModelOnly`).
6. **`eig(obj.P)` every epoch** purely to test positive-definiteness (`ReverseGNSSEKF.m:518`). Full eigendecomposition where a Cholesky attempt suffices.
7. **Per-epoch diagnostics**: clock-observability window solve every epoch (`SimulationDataStore` clock-obs path); a large transient `entry` struct is built and unpacked every epoch (storage itself is already preallocated — good).
8. **Zero parallelism across independent runs** (swarm N assets, batteries, MC seeds all serial).
9. **Heavy OOP dispatch overhead** (structural): dozens of `package.Class.staticMethod()` calls per epoch across 110 `+revgnss` classes; MATLAB package/method resolution is not free at 14k×.
10. **No Parallel Computing Toolbox and no MATLAB Coder** → no `parfor`, no `gpuArray`, no MEX codegen available today.

---

## 4. Optimization catalogue

### Bucket A — Byte-identical single-run speedups (no result change)

Ordered low-risk → higher-risk. Each is verifiable against the frozen golden (must stay byte-identical).

| # | Change | Where | Mechanism | Est. gain | Effort | Risk |
|---|---|---|---|---|---|---|
| **A1** | **Memoize `ecef2geodetic(tower)`** — cache the Bowring *output* per tower index (input is bit-identical each epoch → output bit-identical) | `GeometryUtils.elevationAngle` callers; a small per-tower cache on the tower or model | remove repeated 5-iteration solve on stationary towers | **High** (×6 under FD Jacobian) | M | Low — cache the computed value, *not* the stored `lat/lon` (round-trip differs at 1e-12) |
| **A2** | **Precompute one `enu2ecef` rotation per tower**; remove the duplicate build at `CodeMeasurementBuilder.m:91` vs `:96` | measurement builder + utils | reuse constant rotation | Med (PCO/survey paths) | S | Low |
| **A3** | **Hoist per-`mi` config lookups** out of inner loops: `zwdMappingKind`, `rxCodeBiasModel`, `isfield(cfg.effects.antennaPCO…)` gates | `CodeMeasurementBuilder`, `CodeJacobianBuilder` | compute once/epoch not once/measurement | Med | S | Low |
| **A4** | **Gate the survey/PCO `norm()` diagnostic blocks on their enable flags** (they currently run every `mi` and evaluate to exactly 0 when disabled) | `CodeMeasurementBuilder.m:77–120` | skip ~10 `norm()`/measurement when the effect is off | Med | S | Low (result is 0 today) |
| **A6** | **Replace per-epoch `eig(P)` PSD test with a `chol` attempt** (`[R,p]=chol(P); if p==0 → PSD`; fall back to the existing `eig`/`nearestSPD_` only when `p≠0`) | `ReverseGNSSEKF.m:518–531` | Cholesky is ~5–10× cheaper than full eig; identical accept/repair decision | Med (grows with nx) | S | Low — same PSD decision, P unchanged when PSD |
| **A7** | **Preallocate the Doppler/carrier measurement stack** instead of `z=[z;…]` / `R=diag([diag(R);…])` / `blkdiag` growth | `MeasurementModel.m:255–296` | one allocation instead of repeated reallocation | Low–Med | S | Low (allocation only) |
| **A8** | **Precompute Niell (a,b,c) mapping coefficients per tower** (day-of-year constant within a run) | `EnvironmentModel`/`NiellCoefficients` | drop per-tower-per-epoch `interp1` + seasonal `cos` | Low–Med (only `localWeatherGM`+`niell`) | S | Low |
| **A5** | **Cache loop-invariant frame rotations + sun/moon ephemeris across the 13 `propagateEcef` calls of the FD STM** (they depend only on `t0`/`t1`) | `EkfDynamicsPredictor.finiteDiffStm6` / `propagateEcef` signature | compute rotations + ephemeris once/epoch, pass in | **High (realism)** | M | Medium — must prove bit-identity of the refactor |
| **A9** | **Reuse prefit link geometry in the postfit pass** instead of a second full measurement-model evaluation | `computePostfitResiduals_` | avoid 2nd `ecef2geodetic`/range build/epoch | Med | M | Medium — postfit uses updated `x`; only geometry-independent terms are reusable |
| **A10** | **Write flat store arrays directly**, skipping the large transient `entry` struct built/unpacked every epoch | `SimulationDataStore.recordEpoch`/`storeEntry_` | cut per-epoch allocation churn | Low | M | Low (storage already preallocated) |

> **Combined Bucket A** realistically yields **~1.5–3×** on a single default run (more in realism, where A5 alone removes most of the 3–4× force-eval penalty). A1 + A6 + A3/A4 are the fast, safe first wins.

### Bucket B — Parallelism / threading (no PCT → OS-process level)

| # | Change | Where | Mechanism | Est. gain |
|---|---|---|---|---|
| **B1** | **Parallelize the swarm N-asset loop.** The N assets are fully independent (no shared covariance). Spawn one `matlab -batch "run one asset → save per-asset .mat"` per asset, then a gather step loads them and runs `SwarmRelativeSolver`. | `ReportRunner.runFederatedEstimation` (`:1848`) | process-level fan-out + gather | **~N×** (≈6× on ≥6 cores), byte-identical |
| **B2** | **Process-parallel battery/sweep dispatcher.** Batteries iterate independent configs serially; convert to a launcher that fires K `matlab -batch` workers (one config each), bounded to core count, then collects. Generalize the existing `run_tests_all` *slice* pattern into an auto-spawning orchestrator. | `run_oo_v1_battery.m:63`, `run_error_ladder.m`, `run_oo_v1_freqbattery.m`, `run_tests_all.m` | bounded process pool | near-linear in cores |
| **B3** | **Process-parallel Monte-Carlo seeds** (each seed is an independent run). | `MonteCarloConsistency` / MC harness | same fan-out | near-linear in cores |
| **B4** | *(Optional, if a license is available)* **Install Parallel Computing Toolbox** → the B1–B3 loops become one-line `parfor`s (cleaner, in-process, no `.mat` shuffling). Cranfield site licenses usually include PCT. As a zero-cost interim, `parpool("Threads")`/`backgroundPool` *can* run these on a thread pool **without** PCT for `backgroundPool`, but thread workers have function restrictions this handle-class stack may not tolerate — treat as an experiment, not a plan item. | runners | `parfor`/`parfeval` | near-linear, less plumbing |

> **Important:** Bucket B does **not** speed up a *single* 4 h run — that loop is recursive. If the single default run itself is the pain point, only Bucket A helps it.

### Bucket C — Matrix / linear-algebra specifics

- **C1 = A6** (`chol` PSD test) is the one real linear-algebra win at current `nx`.
- **Already correct, keep:** `update()` uses right-division `K = PH'/S` and the Joseph form rather than explicit `inv()`; `NIS = nu'*(S\nu)` uses backslash. No `inv()` in the hot path. Good — do **not** "optimize" these into inverses.
- **C2 (low priority):** at `nx = 59` the dense `F*P*F'+Q` and Joseph products are microseconds; the linear algebra is **not** the bottleneck. Only for large states (**G12 = 122**, or tower-clock/ambiguity-heavy configs) is it worth exploiting that **F is near-identity with a few dense blocks** and **Q is block-sparse** — compute `F*P*F'` block-wise or store `F`/`Q` as `sparse`. Defer until a large-`nx` config is the target; risk of breaking bit-identity is non-trivial.

### Bucket D — Levers that DO change results (explicitly out of "same results"; listed for honesty)

Do **not** apply these to the certified/golden runs. They are only for *exploratory* sweeps where the user accepts a different number:

- **D1** Throttle the clock-observability window / heavy diagnostics cadence (changes which epochs are sampled).
- **D2** Increase `dt` for scoping runs (changes the filter trajectory).
- **D3** Shorten `duration_s` for scoping runs.

---

## 5. Recommended phased plan

**Phase 0 — Instrument & freeze (½ day).** Land a reusable benchmark harness (the profiling script used for this analysis) and confirm the current frozen goldens (`tests/regression/run_swarm_fingerprint.m`, byte-identical `traceP` baselines) pass. Every subsequent change is gated on these staying byte-identical.

**Phase 1 — Safe Bucket A (1–2 days).** A1, A3, A4, A6, A7, A8 (all Low risk). Run the golden regression after **each** change; keep only byte-identical diffs. Re-benchmark. Expected: most of the single-run win with near-zero risk.

**Phase 2 — Medium Bucket A (1–2 days).** A2, A5 (realism), A9, A10. These need explicit bit-identity proofs (A5's rotation/ephemeris caching and A9's geometry reuse). Gate hard.

**Phase 3 — Bucket B process parallelism (2–3 days).** B1 (swarm fan-out + gather) first — highest leverage, self-contained. Then B2 (battery/sweep dispatcher) reusing the same worker-spawn utility. Validate that a parallel swarm/battery produces **bit-identical** `.mat`s to the serial path.

**Phase 4 — Optional (scoping).** B4 (evaluate PCT license → replace fan-out with `parfor`); Bucket C2 only if a large-`nx` config becomes the hot target.

---

## 6. Verification protocol (non-negotiable for "no result change")

- **Byte-identical gate:** after every Bucket A/B change, a golden run must reproduce the frozen digest (e.g. swarm fingerprint `traceP = 50503.7896526557`, plus the single-asset golden). If a diff appears, the change is rejected or reworked — no "close enough".
- **Benchmark before/after** with the fixed profiling harness (same config, same epoch count) to record the actual speedup.
- **Parallel = same as serial:** B1–B3 must be validated by diffing parallel-produced `.mat`s against a serial reference run bit-for-bit.

---

## 7. What NOT to do

- ❌ Don't lower `dt`, shorten `duration`, or disable physics on the certified runs — that changes the science, not the runtime of the same computation.
- ❌ Don't switch to `single` precision — changes numerics.
- ❌ Don't add `parfor` expecting a speedup — without PCT it runs serially and hides the fact.
- ❌ Don't try to thread a single run's epoch loop — it's a recursive filter.
- ❌ Don't replace the backslash/Joseph forms with explicit `inv()` — slower and less stable.

---

## Appendix — Measured baseline & benchmark harness

**Measured baseline (default config, steady-state epoch loop, under the MATLAB profiler):**
`nx = 59`, 5 towers, 4 receivers → **≈ 1.0–1.4 epoch/s under the profiler** (≈ 0.7–1.0 s/epoch profiled; the profiler adds ~5–8× uniform overhead, so real throughput is several×higher). At 14,401 epochs, a single default 4 h run is the dominant cost; the N = 6 swarm run multiplies a full single-asset run by 6, serially.

**Reusable harness:** `tests/benchmark_epoch_loop.m` produces the ranked per-function self-time table on demand:

```matlab
benchmark_epoch_loop                              % default config, 130 s sample
benchmark_epoch_loop('Realism', true)             % realism-grade
benchmark_epoch_loop('Duration', 200, 'Out', 'prof.txt')
```

Use it to (a) capture the current hot-function ranking, and (b) re-measure after each Bucket A change to confirm the speedup. It uses `profile('info')` and derives self-time from the `Children` field (R2025b's `FunctionTable` has no `SelfTime` field).

> The ranked table was intentionally **not** captured in this pass because a background swarm production run (`run_oo_v1('config/swarm_G5S6R4.json')`) was occupying the machine; running a competing profiler would both slow that run and produce CPU-contended numbers. Run the harness above once the machine is free to fill in the ranking.
