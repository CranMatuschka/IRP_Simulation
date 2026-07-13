# oo_v1 Reverse-GNSS Simulation — Scientific-Correctness Review

**Reviewer role:** Senior MATLAB developer / GNSS & Kalman-filter specialist
**Scope:** Full read of the scientific core (EKF, clock model, error chain, measurement models, atmosphere, orbit/frames, config), cross-checked against GNSS/estimation literature and the reference PDFs supplied. Selected findings verified numerically in MATLAB.
**Date:** 2026-07-13
**Branch:** `feature/scientific-correctness`

---

## 0. Executive summary

**The scientific core is, to a high standard, correct.** The EKF construction, the clock stochastic model, the reverse-link (ground→space) measurement equations, the sign conventions (LOS Jacobian, Sagnac, ionosphere code/carrier), the light-time/transmit-time handling, the J2/two-body/RK4 dynamics, the atmosphere physics (Saastamoinen–Davis, Niell, thin-shell, Klobuchar, higher-order ionosphere, scintillation), and the truth/model separation are all implemented correctly and, in several places, with unusual care (correlation-aware ionosphere-free R, variance double-count guards, oracle-read rejection). I found **no first-order physics or Kalman-logic error** in the default estimation path.

The issues are of three kinds:

1. **One genuine (but diagnostic-only) numerical bug** — the theoretical Allan-deviation RWFM coefficient is 2× too large (§4.3). Confirmed numerically.
2. **Configuration / realism gaps that undercut the stated objective** — the default run silently executes a **single-antenna, attitude-OFF** scenario despite being named `singleAssetCarrierAttitude` and despite the goal of "at least four receiver antennas" (§2.1); the active clock noise coefficients are the self-described "optimistic" set (§4.4); consistency (NEES) is judged from a single deterministic run, not a Monte-Carlo ensemble (§3.3).
3. **Scope / hygiene** — the codebase (72.6 kLOC, 200+ tests, 86 "stages", ISL/swarm/TWSTFT/integer-ambiguity/quaternion-attitude, several 1.5–2.5 kLOC report builders, legacy top-level scripts) vastly exceeds the "first validated implementation" and buries the immediate objective (§6).

**Priority actions**

| # | Severity | Finding | Fix effort |
|---|----------|---------|-----------|
| F1 | **High** | Default resolves to 1 receiver antenna, attitude estimation OFF — contradicts the ≥4-antenna objective (§2.1) | 1 line + re-validation |
| F2 | High (scope) | Massive optional machinery obscures the validated single-GEO path (§6) | Curate / archive |
| F3 | Medium | Active clock coefficients (`legacy`) are optimistic; ~2 orders quieter than a real cesium at τ=1 s (§4.4) | Config choice + justification |
| F4 | Medium | Consistency judged from one deterministic run, not an ensemble; initial pos error (1146 m) > P0 1σ (1000 m) (§3.3) | Add MC harness |
| F5 | Medium | Config opacity: `finalizeConfig` overrides many literal `masterConfig` toggles (atmosphere on, attitude off, Sagnac term off, …) (§5.2) | Emit resolved-config dump |
| F6 | Low | `ClockModel.theoreticalAllanDeviation` RWFM coeff 2× too large (diagnostic only) — **numerically confirmed** (§4.3) | 1 line |
| F7 | Low | Tower-clock state initialised to exact truth while P0=1000 m (only in estimate-tower-clocks mode) (§3.2) | Perturb init |
| F8 | Low | Doppler H omits ∂ρ̇/∂r (range-rate position partial) (§3.6) | Optional |
| F9 | Low | Constant precision / duplication: `EARTH_OMEGA` rounding, hard-coded constants in `FrameTimeUtils` (§4.6) | Cosmetic |

---

## 1. What the system is, and whether the code matches it

**Stated goal:** ≥5 ground towers transmit GNSS-like signals up to one or more space assets; each asset has multiple receiver antennas sharing **one common receiver clock**. First validated case: a single **GEO** asset with **≥4 antennas**. Immediate objective: a *physically consistent* truth simulation + EKF + post-processing + report. Long-term: sub-100 ps / sub-wavelength.

**Key structural insight (and the code gets it right):** a "reverse GNSS" uplink is, in clock/estimation topology, **identical to forward GPS**: many transmitters each with their own clock, one receiver with one clock. In forward GPS: many satellites (tx), one ground receiver (rx). Here: many towers (tx), one spacecraft receiver (rx). Therefore the pseudorange still reads

```
z_i = ρ_i + b_rx − b_tower_i + (atmosphere, corrections, noise)
```

with the **receiver clock common to all rows (+1)** and each **tower clock per-row (−1)**. The "reverse" is purely geometric — transmitters on the rotating Earth, receiver in space — which changes (a) geometry/elevation, (b) atmosphere path direction, (c) the Sagnac/light-time sign bookkeeping, and (d) observability. The code implements exactly this, and the sign/geometry consequences are handled correctly (§2).

---

## 2. Kalman filter — state, dynamics, observables, Jacobians

**File:** `+filter/ReverseGNSSEKF.m`, `+filter/EkfDynamicsPredictor.m`

### State vector (correct and cleanly extensible)
Base 14 states: `r(3) v(3) euler(3) omega(3) b_rx bdot_rx`. Optional augmentations, each with a clean `stateMap` slot, correct F/Q block, and correct H column:
- tower clocks (2/tower), carrier float ambiguities (per tower×rx×signal), per-tower ZWD, per-tower slant-ionosphere, per-tower tx code bias.

The augmentation bookkeeping (`buildStateMap_`, `buildF_`, `buildQ_`) is consistent: random-walk states get F=I; ZWD/slant-iono get first-order Gauss–Markov `φ=exp(−dt/τ)` in **both** F and the steady-state Q `σ²(1−φ²)` — this is the correct discrete OU pair and it matches `StochasticProcess.gaussMarkovStep`. ✔

### Update (correct, well-hardened)
`update()` uses the **Joseph form** `P⁺ = (I−KH)P⁻(I−KH)ᵀ + KRKᵀ`, symmetry projection, an eigenvalue PSD guard with nearest-SPD projection, `K = P⁻Hᵀ/S` via right-division (no explicit inverse), and NIS via backslash. The quaternion error-state path applies injection **after** the Joseph posterior and then a first-order covariance reset `G = I − ½[δθ]×` on the attitude block — order-correct (Stage 62). ✔

### Predict (correct)
F is linearised at the **pre-propagation** point (standard EKF); the translational block accepts a finite-difference 6×6 STM from `EkfDynamicsPredictor` (J2/two-body) or falls back to `[I dtI; 0 I]`. Clock bias–drift coupling `F(b,ḃ)=dt`. Attitude uses either Euler kinematics with the **analytic** Euler-rate Jacobian (WP7 — good, removes FD round-off) or the quaternion error-state linearisation `I − [ω]×dt`. ✔

### Measurement Jacobian (correct signs — the crux for reverse GNSS)
`+models/+measurements/CodeJacobianBuilder.m`, `+revgnss/LinkGeometry.m`:
- **Position:** `H(r) = (r_ant − r_tower)ᵀ/ρ = +û` (unit LOS **tower→spacecraft**). This is the correct sign — range increases as the spacecraft recedes from the tower — and is guarded by `test_measurement_jacobian_position_sign.m`. ✔
- **Receiver clock:** `+1` (analytic). **Tower clock state:** `−1`. ✔
- Attitude columns via central-difference of the corrected range (correctly gated on non-zero lever arm and per-observable config).

### Doppler (frame-consistent; one minor omission)
`DopplerMeasurementBuilder` + `OneWayRangeRateModel`: `ρ̇ = ûᵀv_rx + ûᵀ(ω×Δ)`, i.e. the ECI-consistent range rate including the tower's Earth-rotation velocity (up to ~465 m/s at the equator, ~0.1–0.8 m/s on the LOS). I verified the cross-product term algebraically: `ûᵀ(ω×Δ) = ω(û_y·Δ_x − û_x·Δ_y)`, exactly as coded. ✔
- **F8 (minor):** the Doppler H includes only `∂ρ̇/∂v = ûᵀ` and `∂ρ̇/∂ḃ_rx = 1`; it omits `∂ρ̇/∂r` (the LOS-rotation + tower-rotation position partial). For a GEO with small velocity uncertainty this is negligible, but it is an approximation worth a comment, especially because the tower-rotation term is position-dependent.

### Reverse-link timing (correct)
The tower is the transmitter, so its clock enters at **transmit time**: `CodeMeasurementBuilder` uses `b_tower(t_tx) = b_tower(t_rx) − ḃ_tower·τ` (Stage 7A), while the spacecraft receiver clock enters at receive time. This is the physically correct GNSS timing for an uplink. ✔

### 2.1 F1 (High) — the default does not match the objective
The scenario is named `singleAssetCarrierAttitude` and `masterConfig.m` comments describe a "4-antenna cross pattern." **Verified in MATLAB, the resolved default is:**

```
scenario.nReceivers      = 1        (lever arm [1;0;0.2], single antenna)
estimateAttitude         = 0        (forced OFF by finalizeConfig because nReceivers<=1)
estimateAngularRate      = 0
```

So `run_oo_v1` out-of-the-box runs a **single-antenna, attitude-OFF** GEO case. This directly contradicts the stated immediate objective ("a single GEO-class space asset with at least four receiver antennas") and the scenario's own name. The 6 attitude/ω states remain in the vector but are **frozen** (Q≈0, H columns zero), and the entire differential-carrier-attitude / integer-ambiguity apparatus configured in `masterConfig` (lines 162–211) is dormant.

**Recommendation:** make `cfg.scenario.nReceivers = 4` the default (the cross pattern and attitude path already exist — this is a one-line change), then **re-validate** that spacecraft attitude is actually observable from the carrier + lever-arm geometry at GEO range (see §7). As shipped, the flagship 4-antenna attitude claim is not exercised by the default run.

---

## 3. Truth/model separation, initialisation, consistency

**Files:** `+revgnss/ReverseGNSSSimulation.m`, `+revgnss/ScenarioFactory.m`

### 3.1 Separation is clean (verified)
Truth state (`asset.r_ecef_m`, truth clock/attitude) feeds **only** `z`; `h`/`H` use the estimated state `ekf.x` and `getMeasurementState()`. Per-epoch order is: advance truth (orbit is an absolute cache lookup at `t_k`; attitude/clock integrated) → `[k>1]` EKF predict → build measurements (`z`=truth, `h`=estimate) → slip/ISL/gauge → EKF update → post-fit. Oracle reads are actively rejected (`troposphere modelResidual.mode='sameAsTruth'` throws). This is exactly right. ✔

### 3.2 F7 (Low, conditional) — tower-clock state init = exact truth
In `ScenarioFactory.buildInitialState_`, tower-clock states are initialised to the **exact truth** bias/drift (no perturbation) while `P0` advertises `σ_b = 1000 m`, `σ_ḃ = 10 m/s`. That is a covariance/state inconsistency (zero actual error, huge stated uncertainty) that makes the initial tower-clock NEES meaningless and can drive a covariance transient. **Scope:** the default has `estimateTowerClocks = false`, so tower clocks are *not* states — this bites only when that mode is enabled. Fix: seed the tower-clock states from truth + a draw consistent with P0 (or shrink P0).

### 3.3 F4 (Medium) — consistency from a single deterministic run
Initial errors are **fixed deterministic offsets** (`pos = [1000;−500;250] m`, `vel = [0.1;−0.1;0.05]`, `euler = [1;−1;0.5]°`, `clk = 100 m`), not Monte-Carlo draws. Two consequences:
- The initial position error norm is `‖[1000,−500,250]‖ ≈ 1146 m`, **just outside** the P0 1σ of 1000 m — a mild but real prior/error mismatch.
- Any NEES/NIS "consistency" statement from one run is a **single sample**; χ² consistency of a filter is only meaningful over an ensemble. `test_filter_consistency_nees_nis.m` exists, but the headline report is a single trajectory.

**Recommendation:** add a small Monte-Carlo harness (N seeds, randomised initial error drawn from P0) and report averaged NEES/NIS with χ² bounds. This is the standard evidence that the filter is *statistically* consistent — essential for a "scientifically correct" claim.

### 3.4 Dynamics family
Truth = `j2Rk4` (10 s RK4 sub-steps), EKF = `j2` (single RK4 step of `dt` + finite-diff STM). Same family (good — no artificial mismatch), differing only in integration granularity and a constant-Earth-rotation frame on both sides. A `modelMismatch` process-noise inflation exists (`Q += σ²`) and is correctly **off** in the matched default.

---

## 4. Clock model & noise stochastics

**File:** `+models/+clocks/ClockModel.m`

### 4.1 Process-noise Q is textbook-correct
The Brown–Hwang 2-state (bias, drift) discrete Q for WFM + RWFM:
```
Q11 = (h0/2)·dt + 2π²h₋₂·dt³/3      Q12 = π²h₋₂·dt²      Q22 = 2π²h₋₂·dt
```
matches the standard result exactly (with `q1 = h0/2`, `q2 = 2π²h₋₂`). The optional FFM term `2ln2·h₋₁` added to Q11 is a recognised conservative approximation. The per-step truth synthesis is consistent: WFM phase kick σ = √(h0·dt/2), RWFM frequency increment σ = √(2π²h₋₂·dt). ✔

### 4.2 Colored noise (WPM/FPM/FFM) via FFT
Spectral synthesis with Hermitian symmetry → real IFFT, integrated to phase; stored as absolute sequences and read (not accumulated) per step — correct handling that avoids the classic double-integration blow-up. Per-instance `RandStream` (reproducible, global-state-independent). ✔

### 4.3 F6 (Low, **confirmed numerically**) — RWFM theoretical ADEV coefficient is 2× too large
In `theoreticalAllanDeviation` (IEEE-1139 power-law overlay):
```matlab
var_y = var_y + (8*pi^2/6) * h.hMinus2 .* tau;   % RWFM
```
The standard RWFM Allan variance is `σ_y²(τ) = (2π²/3)·h₋₂·τ`. The code uses `8π²/6 = 4π²/3`, i.e. **2× too large in variance** (√2 in deviation). I derived this analytically (∫₀^∞ sin⁴u/u⁴ du = π/3 ⇒ 2π²/3) and confirmed empirically: a pure-RWFM clock's empirical ADEV variance at τ=100 s (mean of 30 seeds) matched the analytic `2π²/3` prediction to within ~19%, but was only **0.40×** the code's `4π²/3` prediction — the predicted factor of two.

**Impact:** *diagnostic only.* The process noise Q and the empirical ADEV (which drive the filter and the truth) use the correct `2π²/3`; only the theoretical-overlay curve in `theoreticalAllanDeviation` (used in `plotClockDiagnostics` and reporting) is wrong. The existing `test_clock_allan_model.m` checks only the empirical slope *sign*, so it does not catch this.
Also note the WPM/FPM terms drop the `f_h` high-cutoff factor `3f_h h2/(4π²τ²)` / the `3ln(2πf_h τ)` term — acceptable approximations but worth a comment.
**Fix:** `(8*pi^2/6)` → `(2*pi^2/3)`.

### 4.4 F3 (Medium) — active clock coefficients are the optimistic `legacy` set
`cfg.clock.templateSource = 'legacy'` is active by default. The receiver (CESIUM1, stochastic — verified: it produces ~28 mm ≈ 93 ps of bias over 600 s) uses `h0 = 1e-26, h₋₁ = 1e-28, h₋₂ = 1e-30`. That gives white-FM `σ_y(1 s) = √(h0/2) ≈ 7×10⁻¹⁴` — roughly **two orders of magnitude quieter than a real cesium beam** (HP-5071A ≈ 5–8×10⁻¹² at 1 s). The code's own comments label `legacy` "optimistic" and provide a literature-referenced alternative (`jowTable2p1`) that is **not** the default.

The user's brief explicitly requires the noise values to be scientifically defensible. For any headline sub-100 ps result, the clock coefficients should be tied to a **named oscillator datasheet / published IEEE-1139 h-parameters**, and the optimistic default should be replaced (or the report should state the achieved sync is conditioned on an idealised clock). This is the single biggest "noise-value realism" lever in the model.

### 4.5 Tower clocks
Towers are `deterministic` OCXO (verified) — no stochastic realisation; their error enters only through the broadcast-product model (`truthHistoryProductNoisy`, σ_bias = 1 cm, σ_drift = 2×10⁻⁴ m/s, 30 s update, 5 s latency, 120 s validity), whose age-grown prediction uncertainty is correctly folded into R with a *deterministic per-(tower, epoch)* noise cache (a real broadcast product does not re-randomise every epoch). This is a thoughtful, physically honest model. ✔

### 4.6 F9 (Low) — constants
`EARTH_OMEGA_RADPS = 7.2921150e-5` vs the WGS84/IS-GPS `7.2921151467e-5` (rel. err ~2×10⁻⁹, dynamically negligible but not strictly conformant); `FrameTimeUtils` re-hard-codes `7.2921150e-5` and `c = 299792458` instead of referencing `revgnss.Constants` (drift risk); `OrbitDynamics` docstring says "mean" radius where the value is the equatorial semi-major axis (correct value, wrong word). All cosmetic.

---

## 5. Error states — atmosphere, corrections, R

**Files:** `+models/+errors/ErrorChain.m`, `EnvironmentModel.m`, `+models/+atmosphere/*`, `+models/+corrections/RangeCorrections.m`, `CodeMeasurementBuilder.m`

### 5.1 Physics is correct and, in places, excellent
- **Troposphere:** Saastamoinen–Davis ZHD `0.0022768·P/(1−0.00266cos2φ−0.00028h_km)` with an ICAO standard-atmosphere pressure profile and validity guard [−500, 11000] m; **Niell (1996)** hydrostatic/wet mapping via the normalised Marini continued fraction; wet residual as a per-tower Gauss–Markov. Dry/wet split correct. ✔
- **Ionosphere:** thin-shell obliquity mapping `1/√(1−(R_e cos e/(R_e+h_I))²)`; diurnal VTEC bump (14:00 peak) → `K_L1 = 40.308×10¹⁶/f² ≈ 0.162 m/TECU`; **Klobuchar** half-cosine broadcast correction (4th-order cosine, 5 ns night floor, 20 h period floor — matches IS-GPS-200); topside/uplink column fraction (1.0 for GEO — correct, the asset sees the full column); **higher-order** 2nd/3rd-order residuals scaling as f⁻³/f⁻⁴ (so they correctly *survive* the IF combination); **Conker (2003)** amplitude-scintillation `1/√(1−2S4²)`. ✔
- **Signs:** ionosphere is `+` for code (group delay) and `−` for carrier (phase advance); troposphere `+` for both. Verified in `CarrierMeasurementBuilder` and guarded by `test_carrier_iono_opposite_sign.m`. ✔
- **Sagnac / light-time:** verified **correct for the uplink** end-to-end. The correction `(ω/c)(tx_x·rx_y − tx_y·rx_x)` is passed `tx = tower, rx = spacecraft` at every call site; the iterative light-time solver rotates the **tower** by `−ωτ` while holding the spacecraft at `t_rx`; Sagnac is skipped in iterative mode to avoid double counting; equivalence is locked by `test_sagnac_sign.m`. ✔
- **Shapiro:** `(2μ/c²)ln((r_r+r_t+R)/(r_r+r_t−R))` ≈ 1.9 cm at GEO — correct formula and magnitude. ✔

### 5.2 Two standout-good design points
- **Correlation-aware ionosphere-free R** (`CodeMeasurementBuilder`): instead of the naïve `α²R_L1+β²R_L2` (which over-inflates every term by ~8.9×), the code rebuilds R_IF per source: non-dispersive terms (troposphere, tower clock) pass at **unit gain** `(α+β)²=1`; the first-order ionosphere **cancels to exactly 0**; higher-order iono survives at `(α+β(f1/f2)³)²`; only the genuinely independent per-signal terms get `α²/β²`. This is correct and rarely done properly.
- **Variance double-count guards:** when the ZWD or slant-ionosphere is an EKF *state*, its steady-state variance is removed from R (R keeps only the fast, un-trackable increment). Twin guard for estimated tower clocks. These prevent the classic "estimate it *and* pay for it in R" error.

### 5.3 F5 (Medium) — configuration opacity
The literal `masterConfig.m` is **not** a faithful description of the resolved run. `finalizeConfig` (and the `atmosphere.realistic` overlay) override many toggles: `troposphere.enable`/`ionosphere.enable` read `false` in the file but resolve **on**; `troposphereMode` flips `none`→`perTowerZwd`; the separate first-order Sagnac term is **disabled**; the relativistic clock term is **disabled with warning**; **attitude is forced off**. The memory principle "ALL run config in masterConfig, single source of truth" is undermined because the truth lives in `finalizeConfig`. `activePhysicsConfig` reports some of this, but a **complete resolved-config dump** (the `finalizeConfig` output) should be written to the report/log so a reader can see what actually ran without executing MATLAB. `validateMasterConfig` is currently only a thin contract check and explicitly defers the derivations.

---

## 6. Scope, duplication, dead code (F2)

The immediate objective is a *single validated* GEO chain. The repository instead carries ~72.6 kLOC across ~230 `.m` files: 86 numbered "stages", ISL one-/two-way, helix swarm, TWSTFT diagnostics, quaternion error-state attitude, integer-ambiguity readiness, wide-lane/narrow-lane, dozens of diagnostic plugins, several 1.5–2.5 kLOC report builders, and multiple legacy top-level run scripts. This is far beyond a first validated implementation and is the main obstacle to the code being auditable "with nothing doubled, no unnecessary code" as requested.

**Good news first — the sanctioned pipeline is clean.** `run_oo_v1.m` → `revgnss.ReportRunner.runSingle` → `revgnss.ClockExactReportBuilder` is a genuine single-entry path (`cfg.report.layout='clockExact'`, `masterConfig.m:54`). There is **no true physics duplication**: the lowercase `models/atmosphere/{ionosphere,troposphere}.m` are thin façades that delegate verbatim to the `+models/+atmosphere` classes ("no physics here"), and `baseConfig`/`masterConfig` are a legitimate foundation/user-layer pair, not clones. So the "nothing doubled" requirement is essentially met for the *physics*.

The debt is **orphaned scaffolding**, not duplication. The figures below are grep-derived (reference count = non-self, non-test production files naming the symbol) and should be **confirmed before any deletion** — treat this as a candidate list, not a verified-safe delete script.

### 6.1 Duplication / dead-code inventory

**Dead / unreachable (candidates for removal, ~11–12 kLOC):**

| Item | Lines (approx) | Evidence | Note |
|------|------|----------|------|
| `run_oo_reverse_gnss_ladder_sweep_progressive_report.m` | 1663 | 0 references anywhere | orphaned root sweep driver |
| `run_oo_reverse_gnss_ladder_sweep_real_report_fixed.m` | 1146 | 0 external references | orphaned root sweep driver |
| `LatexReportBuilder.m` + `ReportLayout.m` + `OriginalStyleReportLayout.m` + `ReportEquations.m` + `ReportTables.m` | ~3,600 | reachable only when `style='latex'` **and** `layout≠'clockExact'` — no shipped config produces that combo (default sets both, and `layout` wins) | the entire "original Latex" report cluster is dead-by-gating |
| `+revgnss/ReportSummary.m`, `+revgnss/ReportText.m`, `+revgnss/BaselineDiffAttitudeDiag.m` | — | **0 references** (headers falsely claim "used by LatexReportBuilder") | zero-coupling, safest to delete |
| ~12 stage diagnostic classes (`AmbiguityArcState`, `AmbiguityReadinessDiagnostics`, `CarrierAttitudePreparation`, `CarrierIonoFreeAmbiguityTraceability`, `CodeIonoFreeConsistencyDiagnostics`, `CodeIonoFreeEkfDiagnostics`, `L2CarrierArchitectureDiagnostics`, `OrbitDiagnostics`, `BiasArchitecture`, `OriginalStyleReportLayout`, `ChiSquareConsistency`, …) | ~5,380 total | each referenced **only by its own single `test_stageNN_*`** — built, tested once, never wired into the pipeline | delete class + its lone test together; **hold `ChiSquareConsistency`** for a scientist sign-off (it computes NEES/NIS — superseded by the live `ConsistencyStatistics`/`EkfInnovationAccounting`, but sensitive) |

**Keep, but tidy:**
- `run_oo_reverse_gnss_report.m` (~7 KB) is **dead-by-intent but load-bearing** — ~10 validation tests (`run_stage25/26/27/28_validation`, `test_main_script_creates_pdf_v4`, several `test_stage7b*`) still call it. `run_oo_v1.m:5` already flags this. Retire only via a coordinated test migration; do **not** delete standalone.
- `Triage{Analyzer,ResultExtractor,ScenarioFactory}` and `ValidationCaseFactory` live in the `+revgnss` *production* namespace but are used only by test harnesses — **relocate under `tests/`** (namespace hygiene, not deletion).
- `run_geo_realworld_truth_comparison.m` and `run_swarm_check.m` are functional utilities that carry their own config paths (`ConfigFactory.geoRealWorldTruthComparisonConfig`, duration overrides) — this violates the "all config in `masterConfig`" principle; fold into tests or a documented experiments harness.
- `plot_mat_report.m`, `run_ladder.m`, `analyse_oo_reverse_gnss_ladder_sweep.m` are working post-processing utilities — keep.

**Markers:** grep found **no** `TODO`/`FIXME`/`HACK`/`XXX` in `+models`, `+filter`, `+revgnss`, `config`. Every "not implemented" note is a *documented, honest scientific limitation* (LAMBDA integer fixing, ISL measurement stub, VMF3/GPT3 truth mapping, DCB calibration, IF-carrier combination, light-time rate) — appropriately disclosed rather than silently faked. This is a genuine strength: the code is honest about what it does not model.

**Net:** ~11–12 kLOC of removable scaffolding, no physics duplication. The problem is not doubled physics — it is that a validated *single-GEO* deliverable is spread across 86 stages of half-wired diagnostic classes and dead report builders, so a reviewer cannot easily see "the one correct chain." Curating this down is the highest-leverage structural action (F2).

---

## 7. Physical-realism caveats (not bugs, but essential for the claims)

1. **GEO observability / radial–clock degeneracy.** For a GEO the ECEF geometry is nearly static and all towers view the asset from roughly one hemisphere, so a radial position shift is nearly indistinguishable from a receiver-clock shift. The code is aware of this and deliberately uses **12 wide-spread real sites** (lat −26…+68°, lon −25…+78°) to break it — but the **frozen-golden 5-tower** network is far more degenerate. Any accuracy statement should specify the tower network and show the radial vs horizontal error split.
2. **Attitude is not observable from code.** With ~0.3 m code noise and ~1 m lever arms, attitude needs **carrier** phase (mm) and the 4-antenna baseline. This is exactly why F1 matters: the default run cannot demonstrate the attitude objective.
3. **Sub-100 ps / sub-wavelength is a carrier-phase, ambiguity-fixed regime.** The default runs carrier as *float* ambiguities (no fixing in the main filter). Reaching the target needs validated integer fixing (the machinery exists but is gated/diagnostic) *and* realistic clock/atmosphere noise (F3). The current optimistic clock flatters the short-term result.

---

## 8. Consolidated recommendations

**Make the validated path match the goal (highest value):**
- Set `cfg.scenario.nReceivers = 4` as the default; confirm `estimateAttitude` resolves true; add an attitude-observability check to the report (F1).
- Switch the default clock template to the literature-referenced set, or state explicitly that results are conditioned on an idealised clock; cite datasheet h-parameters (F3).
- Add a Monte-Carlo consistency harness (averaged NEES/NIS with χ² bounds) and align the initial-error magnitude to P0 (F4).
- Emit the full **resolved** config (post-`finalizeConfig`) into the report so the run is self-describing (F5).

**Correctness clean-ups (small):**
- Fix the RWFM theoretical-ADEV coefficient `8π²/6 → 2π²/3` and add a test that checks the theoretical *magnitude*, not just the empirical slope (F6).
- Add `∂ρ̇/∂r` to the Doppler Jacobian or document the omission (F8).
- Perturb tower-clock state initialisation to be P0-consistent (F7).
- Route `FrameTimeUtils` constants through `revgnss.Constants`; update `EARTH_OMEGA` to `7.2921151467e-5` (F9).

**Scope discipline (highest structural value):**
- Freeze one **canonical single-GEO 4-antenna** scenario as *the* validated deliverable; move ISL/swarm/TWSTFT/attitude-search/AR-readiness/report-builder variants behind an explicit "experimental" boundary or archive them (F2, see §6.1).

---

## Appendix A — Files reviewed in full
`+filter/ReverseGNSSEKF.m`, `+filter/EkfDynamicsPredictor.m`, `+models/+clocks/ClockModel.m`, `+models/+clocks/TowerClockCorrectionProvider.m`, `+models/+errors/ErrorChain.m`, `+models/+errors/EnvironmentModel.m`, `+models/+errors/HigherOrderIonosphere.m`, `+models/+measurements/{MeasurementModel,CodeMeasurementBuilder,CodeJacobianBuilder,CarrierMeasurementBuilder,DopplerMeasurementBuilder}.m`, `+models/+atmosphere/{MappingFunctions,TroposphereModel,Klobuchar}.m`, `+models/+corrections/RangeCorrections.m`, `+models/+noise/StochasticProcess.m`, `+models/+frames/{GeometryUtils,LightTimeSolver,FrameTimeUtils}.m`, `+models/+orbit/{OrbitDynamics,OrbitPropagator}.m`, `+revgnss/{LinkGeometry,OneWayRangeRateModel,Constants}.m`, `config/{masterConfig,baseConfig,realisticAtmosphereConfig,validateMasterConfig}.m`, `run_oo_v1.m`, `+revgnss/ReverseGNSSSimulation.m`, `+revgnss/ScenarioFactory.m`.

## Appendix B — Numerical checks performed
1. RWFM Allan coefficient: analytic + 30-seed Monte-Carlo confirm `theoreticalAllanDeviation` overpredicts RWFM variance by 2× (§4.3).
2. Resolved default config: `nReceivers=1`, `estimateAttitude=0`, `codeMode=singleFrequency`, `troposphereMode=perTowerZwd`, `templateSource=legacy` (§2.1).
3. Receiver clock: resolves to stochastic; ~28 mm (~93 ps) bias over 600 s; CESIUM1 legacy coefficients (§4.4).
