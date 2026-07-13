# oo_v1 Reverse-GNSS Simulation — Scientific-Correctness Review & Forward Plan (v2)

**Reviewer role:** Senior MATLAB developer / GNSS & Kalman-filter specialist
**Scope:** Independent re-read of the scientific core (EKF, clock model, error chain, measurement models, atmosphere, orbit/frames, config *resolution* — not just the literal config), cross-checked against GNSS/estimation literature and the project's time-transfer reference set (papers 01–04). Every headline finding was re-verified against the **current on-disk code** (including uncommitted working-tree changes), not inherited from the prior review.
**Date:** 2026-07-13
**Branch:** `feature/scientific-correctness`
**Supersedes:** `docs/scientific_correctness_review.md` (v1). This document treats v1 as a *hypothesis set*, not ground truth: §11 is a finding-by-finding audit of v1, and several v1 statements are corrected below.

---

## 0. Executive summary

**The scientific core remains, to a high standard, correct.** Re-verified directly in the current code: the reverse-link (ground→space) measurement topology and sign conventions (LOS Jacobian `+û`, receiver clock `+1`, tower clock `−1`, ionosphere `+code`/`−carrier`, Sagnac, Shapiro), the transmit-time tower-clock handling, the Joseph-form covariance update with quaternion error-state reset applied to the *posterior*, the Brown–Hwang 2-state clock Q, the correlation-aware ionosphere-free R, the double-count guards, and the J2 truth/EKF family match. **No first-order physics or Kalman-logic error was found in the default estimation path.**

The open issues fall into four classes, in priority order:

1. **The default run still does not exercise the stated objective.** `run_oo_v1` out-of-the-box resolves to **one receiver antenna, zero lever arm, attitude estimation OFF** — despite the scenario being named `singleAssetCarrierAttitude`, despite masterConfig *literally setting* `estimateAttitude = true`, and despite masterConfig's own comment advertising a "4-antenna cross pattern." `finalizeConfig` silently overrides all of it. This is the single most important gap and it is **unchanged since v1** (§4).
2. **Configuration opacity is structural, not cosmetic.** The literal `masterConfig.m` is not a faithful description of the run: `finalizeConfig`/`applyAtmosphereProfile` flip attitude off, disable the relativistic clock term, disable the standalone Sagnac term, turn atmosphere on, and choose `codeMode`. A reader cannot know what ran without executing MATLAB (§4, §7).
3. **Realism levers undercut a "scientifically defensible noise" claim.** The active clock coefficients are the code's own self-labelled **"optimistic" `legacy`** set (receiver ≈ 7×10⁻¹⁴ at 1 s, ~2 orders quieter than a real cesium); the relativistic clock-rate offset — a first-order effect for any picosecond GEO claim — is disabled; and filter consistency is judged from a **single deterministic trajectory** with Monte-Carlo explicitly disabled (§5, §6, §9).
4. **A known, still-unresolved filter-consistency defect is documented in the code itself.** A new working-tree note in `ClockModel.getProcessNoiseQ` records that the receiver **clock-drift ±3σ envelope under-covers** the true frequency wander, and that inflating Q does not fix it ("an R / observability issue"). This is a live consistency finding, not a closed one (§5.4).

Two small numerical items persist: the theoretical RWFM Allan coefficient is 2× too large (diagnostic-only, §6.3), and the Doppler Jacobian omits `∂ρ̇/∂r` (§3.6).

**Scope has grown, not shrunk:** 376 `.m` files, ~72.7 kLOC (47.5 k prod / 25.1 k test), 220 stage-tagged files, with multiple zero-reference dead builders. The validated single-GEO deliverable is still buried (§8).

### Priority work-package table

| WP | Severity | Finding (current status) | v1 tag | Fix effort | Acceptance test |
|----|----------|--------------------------|--------|-----------|-----------------|
| **WP-1** | **High** | Default resolves to 1 antenna / zero lever arm / attitude OFF; `finalizeConfig:1414-1421` overrides masterConfig's `estimateAttitude=true`. Contradicts the ≥4-antenna objective. | F1 (confirmed, unchanged) | 1 line + re-validation | Resolved cfg dump shows `nReceivers=4`, `estimateAttitude=true`; attitude observability panel non-degenerate |
| **WP-2** | **High** | Config opacity: literal ≠ resolved for attitude, relativistic clock, Sagnac term, atmosphere, codeMode. | F5 (confirmed, broadened) | Emit resolved-config dump | PDF/`.out` contains post-`finalizeConfig` dump; CI diff of literal-vs-resolved toggles |
| **WP-3** | High (scope) | ~72.7 kLOC / 376 files / dead report+stage clusters bury the one validated chain. | F2 (confirmed, worsened) | Curate/archive | One canonical scenario frozen; experimental code behind an explicit boundary |
| **WP-4** | Medium | Active clock = self-labelled "optimistic" `legacy`; ~2 orders quieter than a real cesium at τ=1 s. | F3 (confirmed) | Config choice + citation, or explicit caveat | Datasheet-anchored h-params, or report states "idealised clock" |
| **WP-5** | Medium | Consistency judged from one deterministic run; Monte-Carlo disabled. | F4 (confirmed; framing corrected) | Add MC harness | Averaged NEES/NIS over N seeds inside χ² bounds |
| **WP-6** | Medium | **Clock-drift ±3σ under-coverage** documented in code; unresolved (R/observability). | **NEW (N2)** | Investigate R / drift observability | Drift NEES/√-consistency restored, or documented as fundamental |
| **WP-7** | Medium | Relativistic clock-rate offset disabled (truth+model) — first-order for a ps-class GEO claim. | **NEW (N3)** | Model or scope-declare | Effect modelled, or explicit claim boundary in report |
| **WP-8** | Low | `theoreticalAllanDeviation` RWFM coeff `8π²/6` should be `2π²/3` (diagnostic-only). | F6 (confirmed, still open) | 1 line + magnitude test | Overlay matches empirical ADEV within tolerance |
| **WP-9** | Low | Doppler H omits `∂ρ̇/∂r` (`DopplerMeasurementBuilder:174-175`). | F8 (confirmed) | Add partial or document | H includes LOS-rotation + tower-rotation position partial, or a comment |
| **WP-10** | Low | Tower-clock state init = exact truth while P0=1000 m (only if `estimateTowerClocks=true`). | F7 (confirmed, conditional) | Perturb init | Init drawn from P0; initial tower-clock NEES ≈ 1 |
| **WP-11** | Low | masterConfig comment claims a 4-antenna default that is never selected. | **NEW (N1)** | Fix comment / behaviour | Comment matches resolved behaviour |
| **WP-12** | Low | `EARTH_OMEGA` rounding; `FrameTimeUtils` hard-codes constants. | F9 (carried) | Cosmetic | Constants routed through `revgnss.Constants` |

---

## 1. What the system is, and whether the code matches it

**Stated goal.** ≥5 ground towers transmit GNSS-like signals up to one or more space assets; each asset has multiple receiver antennas sharing **one common receiver clock**. First validated case: a single **GEO** asset with **≥4 antennas**. Immediate objective: a *physically consistent* truth + EKF + post-processing + report. Long-term: sub-100 ps / sub-wavelength synchronisation and attitude.

**Topology is correct (re-verified).** A "reverse GNSS" uplink is, in clock/estimation topology, identical to forward GPS: many transmitters each with their own clock, one receiver with one clock. The pseudorange therefore reads

```
z_i = ρ_i + b_rx − b_tower_i + (atmosphere, corrections, noise)
```

with the **receiver clock common to every row (+1)** and each **tower clock per-row (−1)**. The "reverse" is purely geometric (transmitters on the rotating Earth, receiver in space), which changes geometry/elevation, atmosphere path direction, Sagnac/light-time bookkeeping, and observability. The code implements exactly this; the sign/geometry consequences are handled correctly (§3, §7).

---

## 2. Verification method and epistemic calibration

This review distinguishes **what I re-verified line-by-line** from **what I confirmed structurally** (call-site signatures, sign tests, presence of the right formula), because the subagent fleet allocated to the deep atmosphere/scope pass was terminated early by a session limit and its structured output was not recovered. I therefore re-derived the headline items myself.

- **Directly re-read in full (this pass):** `masterConfig.m`, `baseConfig` (init/P0 block), `ClockModel.m` (+ working-tree diff), `run_oo_v1.m`, `ReverseGNSSEKF.m`, `CodeJacobianBuilder.m`, `DopplerMeasurementBuilder.m`, `ReceiverGeometry.m`, `ConfigFactory.finalizeConfig`/`applyAtmosphereProfile`/`getClockTemplate_`, `ScenarioFactory.buildInitialState_`/`buildInitialCovariance_`.
- **Confirmed by targeted grep + call-site/signature inspection:** LOS sign in `LinkGeometry.analyticLosJacobian`; code `+iono`/carrier `−iono` signs and the correlation-aware IF-R block in `Code/CarrierMeasurementBuilder`; Sagnac/Shapiro formula and uplink call sites in `RangeCorrections`/`LightTimeSolver`; Monte-Carlo/consistency wiring; dead-code reference counts.
- **Trusted at the level of "correct formula present, guarded by a dedicated test":** the detailed atmosphere coefficients (Niell continued-fraction constants, Klobuchar constants, higher-order iono scaling, Conker scintillation). Signs and structure verified; individual literature coefficients not re-derived here. These are candidates for a dedicated numeric-regression pass (see WP list, §10).

Where v1 asserted a numerically-confirmed result I could not independently re-run (e.g. the 30-seed RWFM Monte-Carlo), I re-derived the **analytic** result and marked the empirical part as "reported by v1, analytically consistent."

---

## 3. Kalman filter — state, dynamics, observables, Jacobians

**Files:** `+filter/ReverseGNSSEKF.m`, `+filter/EkfDynamicsPredictor.m`, `+models/+measurements/*`.

### 3.1 State vector — correct and cleanly extensible ✔
Base 14 states `r(3) v(3) euler(3) omega(3) b_rx bdot_rx` (`ReverseGNSSEKF.m:4-14`, `buildStateMap_:532-627`). Augmentations each get a clean `stateMap` slot, F/Q block, and H column: tower clocks (2/tower), carrier float ambiguities (per tower×receiver×signal), per-tower ZWD, per-tower slant-ionosphere, per-tower tx code bias.

### 3.2 Process model F / Q — correct ✔
- ZWD and slant-ionosphere use first-order Gauss–Markov `φ=exp(−dt/τ)` in **both** F (`buildF_:706-735`) and steady-state Q `σ²(1−φ²)` (`buildQ_:856-892`) — the correct discrete OU pair.
- Clock bias–drift coupling `F(b,ḃ)=dt` (`:695`); receiver clock Q from `ClockModel.getProcessNoiseQ` (`:800-809`).
- Attitude uses either the **analytic** Euler-rate Jacobian `F=I+dt·J` (`:672`, removes FD round-off, WP7 of the prior effort) or the quaternion error-state `F=I−[ω]×dt` (`:660`). Frozen (Q×1e-20, F=I) when `estimateAttitude=false` (`:784-787`) — which is the default (§4).
- Position/velocity white-acceleration Q with the optional model-mismatch inflation correctly **off** in the matched default (`:759-766`).

### 3.3 Measurement update — correct and well-hardened ✔
`update()` (`:346-451`) uses the **Joseph form** `P⁺=(I−KH)P⁻(I−KH)ᵀ+KRKᵀ` computed from the saved `Pminus` (`:377-381`), symmetry projection, an eigenvalue PSD guard with nearest-SPD projection (`:431-447`), `K = P⁻Hᵀ/S` via right-division (`:372`, no explicit inverse), and NIS via backslash (`:450`). The quaternion error-state injection is applied **after** the Joseph posterior, with the first-order covariance reset `G=I−½[δθ]×` on the attitude block (`:387-401`) — order-correct.

### 3.4 Measurement Jacobian signs — the crux, re-verified ✔
- **Position:** `H(r)=g.losRow` where `LinkGeometry.analyticLosJacobian` sets `losRow=(r_ant−r_twr)ᵀ/ρ = +û` (unit LOS tower→spacecraft; `LinkGeometry.m:72`). Correct sign (range increases as the spacecraft recedes), guarded by `test_measurement_jacobian_position_sign.m`. (`CodeJacobianBuilder.m:52`)
- **Receiver clock:** `+1` (`:63`). **Tower clock state:** `−1` (`:69`). **Tx code bias:** `+1` (`:76`). **ZWD:** troposphere mapping factor, same sign as code (`:84`).
- Attitude columns via central-difference of the corrected range, gated on non-zero lever arm and per-observable config (`:56-60`).

### 3.5 Reverse-link timing — correct ✔
The tower is the transmitter, so its clock enters at **transmit time**; the receiver clock at receive time. Verified structurally in `CodeMeasurementBuilder` (transmit-time tower-clock evaluation) and the iterative one-way light-time solver.

### 3.6 Doppler — frame-consistent model, but H omits `∂ρ̇/∂r` (WP-9, = F8) ⚠
`DopplerMeasurementBuilder` + `OneWayRangeRateModel`: the range-rate **model** `h = ûᵀv_rx + ûᵀ(ω×Δ) + ...` is frame-consistent, including the tower Earth-rotation velocity (`:146,165`). But the **Jacobian** is built as only
```matlab
Hd(mi, stateMap.v_idx)       = u_e';   % ∂ρ̇/∂v
Hd(mi, stateMap.bdot_rx_idx) = 1;      % ∂ρ̇/∂ḃ_rx
```
(`DopplerMeasurementBuilder.m:174-175`) — there is **no `∂ρ̇/∂r`** (the LOS-rotation + tower-rotation position partial). For a GEO with small velocity uncertainty this is negligible, but the tower-rotation term is position-dependent, so H is a documented approximation. **Fix:** add the partial or annotate; low priority.

---

## 4. Configuration resolution and the objective gap (WP-1, WP-2, WP-11)

**Files:** `config/masterConfig.m`, `+revgnss/ConfigFactory.m`, `+revgnss/ReceiverGeometry.m`, `config/baseConfig.m`.

This is the most consequential section and the one where the literal config most misleads.

### 4.1 WP-1 (High) — the default is single-antenna, attitude-OFF (F1, confirmed, **unchanged**)
Tracing the resolution end-to-end:

1. `masterConfig` does **not** set `cfg.scenario.nReceivers`; its scenario assembly computes `nRecvReq_=1` unless a value >1 was preset (`masterConfig.m:314-317`), then `arms = ReceiverGeometry.defaultLeverArms(1)`.
2. `defaultLeverArms(1)` returns a **single** column `[1;0;0.2]` (`ReceiverGeometry.m:22-27`), so `cfg.scenario.nReceivers = size(arms,2) = 1`.
3. `masterConfig:343` then *explicitly sets* `cfg.estimator.estimateAttitude = true`.
4. **But `finalizeConfig` (run inside `ReportRunner.runSingle`) overrides it:** for `nReceivers==1` it forces
```matlab
cfg.asset.receiverLeverArm_body_m  = [0;0;0];
cfg.estimator.estimateAttitude     = false;
cfg.estimator.estimateAngularRate  = false;   % ConfigFactory.m:1414-1421
```

**Net resolved default:** `nReceivers=1`, **zero lever arm**, `estimateAttitude=false`. The 6 attitude/ω states remain in the vector but are frozen (Q≈0, H columns zero), and the entire differential-carrier-attitude / quaternion error-state / integer-ambiguity apparatus configured across `masterConfig` (lines 162-212, 340-378) is **dormant**. The flagship 4-antenna attitude claim is not exercised by the shipped run.

**Fix (WP-1):** set `cfg.scenario.nReceivers = 4` before the scenario assembly (the cross pattern and attitude path already exist — `ConfigFactory.multiAntennaAttitudeConfig` is the reference), then **re-validate** attitude observability at GEO range from carrier + lever-arm geometry (§9). This is a one-line change plus a validation gate.

### 4.2 WP-11 (Low) — the comment actively misleads (NEW)
`masterConfig.m:41-42` states *"nReceivers is owned by the scenario assembly below (4-antenna cross pattern)"* — but the assembly selects **one** column, not four. A reader taking the comment at face value would believe attitude is exercised. Either the behaviour (WP-1) or the comment must change; ideally both, together.

### 4.3 WP-2 (High) — literal ≠ resolved (F5, confirmed and broadened)
The single-source-of-truth principle ("ALL run config in masterConfig") is undermined because the operative truth lives in `finalizeConfig`. Confirmed divergences:

| Toggle | Literal in masterConfig | Resolved at run | Overriding site |
|--------|-------------------------|-----------------|-----------------|
| `estimator.estimateAttitude` | `true` (`:343`) | **`false`** | `ConfigFactory.m:1418` |
| `estimator.estimateAngularRate` | `false` | `false` | `:1419` |
| receiver lever arm | `[1;0;0.2]` | **`[0;0;0]`** | `:1416-1417` |
| `errors.troposphere.enable` | `false` (`:85`) | **on** (realistic overlay) | `applyAtmosphereProfile:513` |
| `errors.ionosphere.enable` | `false` (`:88`) | **on** (realistic overlay) | `applyAtmosphereProfile:513` |
| `measurements.codeMode` | (unset) | **`singleFrequency`** (RAW dual-freq) | `applyAtmosphereProfile:543` |
| `physics.relativity.clock.enable` | `true` (`:77`) | **`false`** (disabled + warning) | `ConfigFactory.m:958-971` |
| standalone first-order Sagnac term | on (`:71`) | **off** (folded into iterative light-time) | `ConfigFactory.m:933-938` |

The last two are physically *correct* resolutions (avoiding double-counting the Sagnac; scoping out an unvalidated relativistic model), but they are invisible in the literal file. `activePhysicsConfig` reports some of this; a **complete resolved-config dump** (the post-`finalizeConfig` struct) should be written to the `.out`/PDF so the run is self-describing without MATLAB. **`validateMasterConfig` is a thin contract check and explicitly defers the derivations** — so it does not catch literal-vs-resolved drift either.

### 4.4 Confirmed run-time scalars
`duration_s=14400` (4 h — v1's 600 s is stale), `dt_s=1`, `nTowers=5` (12 available for the wide network), `orbitClass=GEO`, `codeMode=singleFrequency`, `templateSource=legacy`, `estimateTowerClocks=false`, truth `j2Rk4` / EKF `j2`.

---

## 5. Truth/model separation, initialisation, consistency

**Files:** `+revgnss/ReverseGNSSSimulation.m`, `+revgnss/ScenarioFactory.m`, `+revgnss/ConsistencyStatistics.m`.

### 5.1 Separation is clean ✔
Truth state feeds **only** `z`; `h`/`H` use the estimated state via `getMeasurementState()`. Per-epoch order: advance truth → `[k>1]` predict → build measurements (`z`=truth, `h`=estimate) → slip/ISL/gauge → update → post-fit. Oracle reads are actively rejected (`modelResidual.mode='sameAsTruth'` throws). Truth `j2Rk4` (10 s RK4 sub-steps) vs EKF `j2` (single RK4 + finite-diff STM) is the **same family** — an honest, not artificial, mismatch — with the `modelMismatch` Q inflation correctly off in the matched default.

### 5.2 WP-5 (Medium) — consistency from one deterministic run (F4, confirmed; v1 framing corrected)
Initial errors are **fixed deterministic offsets** from `cfg.estimator.initialError` (`ScenarioFactory.m:75-82`), read from `baseConfig.m:246-252`:
`pos=[1000;−500;250] m`, `vel=[0.1;−0.1;0.05] m/s`, `euler=[1;−1;0.5]°` (masterConfig override), `clockBias=100 m`. P0 (`baseConfig.m:237-243`): per-axis `σ_pos=1000 m`, `σ_v=1 m/s`, `σ_bRx=100 m`, `σ_ḃRx=0.01 m/s`.

**Correction to v1:** v1 flagged "‖pos error‖≈1146 m > P0 1σ 1000 m" as a prior/error mismatch. That comparison is imprecise — it pits a 3-vector norm against a 1-axis σ. The actual initial position NEES is `(1000/1000)²+(500/1000)²+(250/1000)² = 1.31`, i.e. `NEES/dof ≈ 0.44`, comfortably inside the 3-DOF χ² band. So the **magnitude is not the problem**. The real, valid point is: **a single deterministic trajectory yields a single NEES/NIS sample**, and χ² consistency of a filter is only meaningful over an ensemble. `ConsistencyStatistics` (NIS/NEES) is computed live on that one run; **Monte-Carlo is explicitly disabled** (`ConfigFactory.m:1647,1902` set `validation.statistics.monteCarlo.enable=false`; `ModelCoverageAudit` reports *"Monte Carlo/NEES stochastic validation: disabled"*; the ladder analysis literally prints *"No Monte Carlo. One run. Not statistical proof."*).

**Fix (WP-5):** add a small Monte-Carlo harness (N seeds, initial error drawn from P0, tower/receiver/atmosphere seeds varied) and report averaged NEES/NIS with χ² bounds. This is the standard statistical-consistency evidence required for a "scientifically correct" claim.

### 5.3 WP-10 (Low, conditional) — tower-clock init = exact truth (F7, confirmed)
`ScenarioFactory.buildInitialState_:102-108` seeds tower-clock states to the **exact truth** bias/drift (no perturbation), while `buildInitialCovariance_:125-133` advertises `σ_b=1000 m`, `σ_ḃ=10 m/s`. Zero actual error against huge stated uncertainty makes the initial tower-clock NEES meaningless and can drive a covariance transient. **Only reachable when `estimateTowerClocks=true`** (default false), so it does not bite the default. **Fix:** seed from truth + a P0-consistent draw (or shrink P0) whenever tower clocks are states.

### 5.4 WP-6 (Medium) — documented clock-drift ±3σ under-coverage (NEW, N2)
The uncommitted working-tree change to `ClockModel.getProcessNoiseQ` adds an opt-in `driftFlickerInQ` lever and, more importantly, **documents a real, still-open consistency defect** (`ClockModel.m:352-358`):

> *"the RWFM-only Q22 is too small and the drift ±3σ envelope under-covers the true frequency wander … an A/B test showed adding FFM inflates Q22 ~26× but leaves the actual-error/filter-σ ratio unchanged, so it does NOT restore drift ±3σ consistency (that is an R / observability issue, not a process-noise magnitude issue)."*

This is a genuine finding the code base has surfaced and not resolved: the receiver clock-drift state is **not covariance-consistent**, and the cause is believed to be measurement information / observability, not Q. For a sub-100 ps result this matters, because clock-drift confidence bounds feed directly into the reported timing uncertainty. **Fix (WP-6):** treat as a first-class investigation — check whether Doppler (the drift-observing measurement) is actually informative at GEO given its σ and geometry, whether the drift is weakly observable and its P is optimistic, and whether the R for Doppler product-drift is correctly sized. Resolve, or document as a fundamental observability limit with the honest caveat in the report.

---

## 6. Clock model & noise stochastics

**File:** `+models/+clocks/ClockModel.m` (has uncommitted working-tree changes — reviewed on-disk).

### 6.1 Process-noise Q is textbook-correct ✔
Brown–Hwang 2-state (bias, drift) discrete Q for WFM + RWFM (`getProcessNoiseQ:366-392`):
```
Q11 = (h0/2 + 2ln2·h₋₁)·dt + 2π²h₋₂·dt³/3     Q12 = π²h₋₂·dt²     Q22 = 2π²h₋₂·dt
```
with `q1=h0/2`, `q2=2π²h₋₂` — the standard result. The FFM term `2ln2·h₋₁` in Q11 is the recognised conservative approximation. The new `driftFlickerInQ` opt-in (default **false** → no default-path change) additionally injects `2ln2·h₋₁·dt` into Q22. Per-step truth synthesis is consistent: WFM phase kick `σ=√(h0·dt/2)` (`:246`), RWFM frequency increment `σ=√(2π²h₋₂·dt)` (`:249`). ✔

### 6.2 Colored noise (WPM/FPM/FFM) via FFT ✔
Spectral synthesis with Hermitian symmetry → real IFFT → integrated to phase (`precomputeNoise:157-215`); stored as **absolute** sequences and *read* (not accumulated) per step (`step:262-270`) — the correct handling that avoids the classic double-integration blow-up. Per-instance `RandStream` (reproducible, global-state-independent). ✔

### 6.3 WP-8 (Low) — RWFM theoretical ADEV coefficient 2× too large (F6, confirmed, **still open**)
In `theoreticalAllanDeviation` (`:446`):
```matlab
var_y = var_y + (8*pi^2/6) * h.hMinus2 .* tau;   % RWFM
```
The standard IEEE-1139 RWFM Allan **variance** is `σ_y²(τ)=(2π²/3)·h₋₂·τ`. The code uses `8π²/6 = 4π²/3`, i.e. **2× too large in variance** (√2 in deviation). This is internally inconsistent with the code's own **correct** convention: the process noise (`q2=2π²h₋₂`, `:369`) and the RWFM truth synthesis (`:249`) both use `2π²h₋₂`, whose analytic Allan variance is exactly `(2π²/3)h₋₂τ`. So the error is **isolated to the diagnostic overlay** — it does not touch Q, the truth, or the filter. (Derivation: `∫₀^∞ sin⁴u/u⁴ du = π/3 ⇒ σ_y²(τ)=2π²h₋₂τ/3`.) The WPM/FPM terms also drop the `f_h` high-cutoff factors — acceptable, but worth a comment. The existing `test_clock_allan_model.m` checks only the empirical slope *sign*, so it does not catch the magnitude. **Fix (WP-8):** `(8*pi^2/6) → (2*pi^2/3)` and add a test asserting the overlay *magnitude* matches the empirical ADEV.

### 6.4 WP-4 (Medium) — active clock coefficients are the "optimistic" `legacy` set (F3, confirmed)
`cfg.clock.templateSource` defaults to **`legacy`** (`baseConfig.m:681,90`; `getClockTemplate_` default `:1939`). The receiver clock (CESIUM1) uses `h0=1e-26, h₋₁=1e-28, h₋₂=1e-30` (`ConfigFactory.m:1979-1985`), giving white-FM `σ_y(1 s)=√(h0/2)≈7×10⁻¹⁴` — roughly **two orders of magnitude quieter than a real cesium beam** (HP-5071A ≈ 5–8×10⁻¹² at 1 s). The code's own comment labels the legacy OCXO/CESIUM templates "optimistic" (`:2010-2012`) and provides a literature-anchored alternative `jowTable2p1` that is **not** the default (kept legacy per the project's WP4 decision).

The brief requires scientifically defensible noise. For any headline sub-100 ps result the clock coefficients should be tied to a **named oscillator datasheet / published IEEE-1139 h-parameters**, or the report must state explicitly that the achieved sync is conditioned on an idealised clock. This is the single biggest noise-realism lever. **Fix (WP-4):** switch the default to `jowTable2p1` (or a cited datasheet set) for the headline run, or add a prominent "idealised-clock" caveat and a sensitivity row showing the result under a realistic cesium.

### 6.5 Tower clocks — thoughtful and honest ✔
Towers are **deterministic** OCXO (`masterConfig.m:409-411`); their error enters only through the broadcast-product model (`truthHistoryProductNoisy`, σ_bias=1 cm, σ_drift=2×10⁻⁴ m/s, 30 s update, 5 s latency, 120 s validity — `masterConfig.m:118-126`), whose age-grown prediction uncertainty is folded into R with a **deterministic per-(tower,epoch)** noise cache (a real broadcast product does not re-randomise each epoch). Physically honest.

---

## 7. Error states — atmosphere, corrections, R

**Files:** `+models/+errors/*`, `+models/+atmosphere/*`, `+models/+corrections/RangeCorrections.m`, `+models/+measurements/{Code,Carrier}MeasurementBuilder.m`, `+models/+frames/LightTimeSolver.m`.

### 7.1 Physics and signs — correct (signs re-verified directly) ✔
- **Signs (crux):** ionosphere `+` for code (group delay), `−` for carrier (phase advance); troposphere `+` for both. Verified directly: code `z += iono_t`, `h += iono_m` (`CodeMeasurementBuilder.m:339-340`); carrier `−iono` with the slant-iono carrier column `−(f_L1/f)²` (`CarrierMeasurementBuilder.m:211-212,227-228,307-312`). Guarded by `test_carrier_iono_opposite_sign.m`.
- **Sagnac / light-time (uplink):** `sagnacCorrectionMeters(rx_ecef, tx_ecef, cfg)` is called with `rx=spacecraft, tx=tower`; under iterative one-way light-time the standalone Sagnac term is **skipped** to avoid double counting (`RangeCorrections.m:76,108`; `ConfigFactory.m:933-938`), and the iterative solver rotates the tower by `−ωτ`. Guarded by `test_sagnac_sign.m`.
- **Shapiro:** `dR=(2μ/c²)ln((r_r+r_t+R)/(r_r+r_t−R))` (`RangeCorrections.m:43,58`) ≈ 1.9 cm at GEO — correct formula and magnitude.
- **Troposphere / Ionosphere models** (Saastamoinen–Davis ZHD, Niell mapping, thin-shell obliquity, Klobuchar, higher-order f⁻³/f⁻⁴ residuals, Conker scintillation): the correct formulae are present and sign-consistent. Detailed coefficient re-derivation is deferred to a numeric-regression pass (§2, §10).

### 7.2 Two standout-good design points ✔
- **Correlation-aware ionosphere-free R** (`CodeMeasurementBuilder.m:486-560`): instead of the naïve `α²R_L1+β²R_L2` (which over-inflates every term by ~8.9×), R_IF is rebuilt per source — non-dispersive terms (troposphere, tower clock) pass at **unit gain** `(α+β)²=1`; first-order ionosphere **cancels to 0**; higher-order iono survives at gain `α+β(f1/f2)³`; only genuinely independent per-signal terms get `α²/β²`. Correct and rarely done properly.
- **Double-count guards** (recent commits `9d53123`, `90a327e`, `2c552c5`): when ZWD or slant-iono is an EKF *state*, its steady-state variance is stripped from R (R keeps only the fast, un-trackable increment); twin guard for estimated tower clocks; the slant-iono H is guarded on dispersion so H rows and h match on single-frequency. Structurally correct; these prevent the classic "estimate it *and* pay for it in R" error. (Full numeric re-verification of the guard magnitudes is a WP-list candidate.)

---

## 8. Scope, duplication, dead code (WP-3, = F2 — confirmed and worsened)

The immediate objective is a *single validated* GEO chain (`run_oo_v1.m → ReportRunner.runSingle → ClockExactReportBuilder`, confirmed live at `ReportRunner.m:1502`). The repository now carries **376 `.m` files, ~72.7 kLOC (47.5 k production / 25.1 k test), 220 stage-tagged files** — larger than at the v1 review. The sanctioned physics pipeline is clean and there is **no physics duplication** (the lowercase `models/atmosphere/*` are thin façades over `+models/+atmosphere`; `baseConfig`/`masterConfig` are a legitimate foundation/user pair). The debt is **orphaned scaffolding**:

- **Zero production references (safe-to-archive candidates, re-counted this pass):** `run_oo_reverse_gnss_ladder_sweep_progressive_report.m`, `run_oo_reverse_gnss_ladder_sweep_real_report_fixed.m`, `+revgnss/ReportSummary.m`, `+revgnss/ReportText.m`, `+revgnss/BaselineDiffAttitudeDiag.m`, `OriginalStyleReportLayout.m`, `ChiSquareConsistency.m` (hold the last for a scientist sign-off — it computes NEES/NIS, superseded by the live `ConsistencyStatistics`).
- **Dead-by-gating:** the `LatexReportBuilder` cluster (4 prod refs, all in the `layout≠clockExact` branch of `ReportRunner`) is unreachable under the default `layout='clockExact'` (`ReportRunner.m:1502` vs `:1546`).
- **Load-bearing legacy:** `run_oo_reverse_gnss_report.m` is dead-by-intent but still called by ~10 validation tests — retire only via a coordinated test migration.

**Markers:** grep found **no** `TODO`/`FIXME`/`HACK` in `+models`/`+filter`/`+revgnss`/`config`; every "not implemented" note is a documented, honest scientific limitation (LAMBDA fixing, ISL stub, VMF3/GPT3, DCB, IF-carrier combination, light-time rate). This honesty is a genuine strength. **Fix (WP-3):** freeze one canonical single-GEO 4-antenna scenario as *the* deliverable and move ISL/swarm/TWSTFT/AR-readiness/report-builder variants behind an explicit `experimental/` boundary or archive.

---

## 9. Physical-realism caveats for the picosecond objective

Anchored to the project reference set — wireless picosecond sync for distributed antenna arrays (paper 04), sub-picosecond SDR multi-band time/frequency transfer (01), T2L2 optical two-way time transfer (02), and enhanced multi-way time transfer among UAS (03). These describe **two-way / multi-way** links reaching the ps-and-below regime; the present simulation is a **one-way uplink** whose absolute timing is fundamentally clock- and geometry-limited. That difference frames the following caveats:

1. **WP-7 (NEW, N3) — relativistic clock rate is disabled.** The gravitational + special-relativistic frequency offset between a GEO clock and a ground clock is a **first-order, systematic** effect at the picosecond level and is a routine correction in every operational time-transfer system (including the reference papers). It is currently disabled in both truth and model (`ConfigFactory.m:958-971`). Because truth==model, it creates no EKF inconsistency, but it is a **modelling omission** that any sub-100 ps claim must address — either model it, or state the claim boundary explicitly.
2. **GEO radial–clock degeneracy.** For a GEO the ECEF geometry is near-static and all towers view the asset from one hemisphere, so a radial position shift is nearly indistinguishable from a receiver-clock shift. The code mitigates with **12 wide-spread real sites**, but the **frozen 5-tower default** is far more degenerate. Any accuracy statement must specify the tower network and show the radial-vs-horizontal error split — and, per WP-6, the clock-drift observability that this degeneracy directly affects.
3. **Attitude is not observable from code.** With ~0.3 m code noise and ~1 m lever arms, attitude needs **carrier** phase (mm) and the 4-antenna baseline — which is exactly why WP-1 matters: the default run *cannot* demonstrate the attitude objective, regardless of the machinery present.
4. **Sub-100 ps / sub-wavelength is a carrier-phase, ambiguity-fixed regime.** The default runs carrier as **float** ambiguities (no fixing in the main filter). Reaching the target needs validated integer fixing (machinery exists but is gated/diagnostic) *and* realistic clock/atmosphere noise (WP-4). The optimistic legacy clock flatters the short-term result; a one-way uplink cannot, in principle, match the two-way links in the reference papers without an independent frequency reference or a return path.

---

## 10. Consolidated forward plan

**Tier 1 — make the validated path match the objective (highest value):**
- **WP-1** Set `cfg.scenario.nReceivers = 4` as the default; confirm the resolved cfg shows `estimateAttitude=true` and a non-zero lever arm; add an attitude-observability panel to the report. Guard with a test asserting the *resolved* (post-`finalizeConfig`) attitude state.
- **WP-2** Emit the full **resolved** config (post-`finalizeConfig`) into the `.out`/PDF; add a CI check that diffs literal-vs-resolved toggles and lists every override, so opacity becomes visible rather than silent. Promote `validateMasterConfig` from a contract check to also assert the key resolved invariants.
- **WP-11** Fix the misleading `masterConfig` 4-antenna comment in the same change as WP-1.

**Tier 2 — scientific defensibility of the noise & consistency claims:**
- **WP-4** Switch the headline clock to `jowTable2p1` / a cited datasheet set, or add a prominent idealised-clock caveat plus a realistic-cesium sensitivity row.
- **WP-5** Add a Monte-Carlo harness (N seeds; initial error drawn from P0; averaged NEES/NIS with χ² bounds) and surface it in the report. This is the statistical-consistency evidence the "correct" claim needs.
- **WP-6** Investigate and resolve (or formally document) the clock-drift ±3σ under-coverage — check Doppler informativeness/observability and the drift R sizing at GEO.
- **WP-7** Model the relativistic clock-rate offset, or declare the claim boundary explicitly in the report.

**Tier 3 — correctness clean-ups (small, isolated):**
- **WP-8** `theoreticalAllanDeviation`: `8π²/6 → 2π²/3`; add a magnitude test (not just slope sign).
- **WP-9** Add `∂ρ̇/∂r` to the Doppler Jacobian or document the omission.
- **WP-10** Perturb tower-clock init to be P0-consistent whenever `estimateTowerClocks=true`.
- **WP-12** Route `FrameTimeUtils` constants through `revgnss.Constants`; update `EARTH_OMEGA` to `7.2921151467e-5`.

**Tier 4 — scope discipline (highest structural value):**
- **WP-3** Freeze one canonical single-GEO 4-antenna scenario as *the* deliverable; archive/boundary the ISL/swarm/TWSTFT/AR-readiness/report-builder variants and the zero-reference dead files listed in §8.

**Cross-cutting guardrail.** Every change above must pass the **Stage-85 regression against the frozen golden** (the golden opts out of the realistic atmosphere via the single `atmosphere.realistic=false` flag, so physics stays byte-identical there). WP-1/WP-4 change the *default headline scenario*, not the golden — re-freeze a *separate* headline reference, do not overwrite the golden.

---

## 11. Appendix A — Finding-by-finding audit of the v1 review

| v1 | v1 claim | v2 verdict | Note |
|----|----------|-----------|------|
| F1 | Default = 1 antenna, attitude OFF | **CONFIRMED, unchanged** | `finalizeConfig:1414-1421` overrides `estimateAttitude=true` → WP-1 |
| F2 | Scope bloat ~72.6 kLOC | **CONFIRMED, worsened** | Now 376 files / ~72.7 kLOC / 220 stage files → WP-3 |
| F3 | Clock = optimistic `legacy` | **CONFIRMED** | CESIUM1 `h0=1e-26` → 7e-14 @1 s; default `legacy` (`baseConfig:681`) → WP-4 |
| F4 | Consistency from one run; init > P0 | **CONFIRMED; framing corrected** | MC disabled; but "1146 m > 1σ" is imprecise (initial NEES/dof≈0.44) → WP-5 |
| F5 | Config opacity | **CONFIRMED, broadened** | Full literal-vs-resolved table in §4.3 → WP-2 |
| F6 | RWFM ADEV coeff 2× too large | **CONFIRMED, still open** | `ClockModel.m:446` still `8π²/6`; diagnostic-only → WP-8 |
| F7 | Tower-clock init = exact truth | **CONFIRMED, conditional** | `ScenarioFactory:102-108`; only if `estimateTowerClocks=true` → WP-10 |
| F8 | Doppler H omits `∂ρ̇/∂r` | **CONFIRMED** | `DopplerMeasurementBuilder:174-175` → WP-9 |
| F9 | Constant precision/duplication | **CARRIED** | Cosmetic → WP-12 |
| — | Clock-drift ±3σ under-coverage | **NEW (N2)** | Documented in code `ClockModel:352-358` → WP-6 |
| — | Relativistic clock disabled | **NEW (N3)** | First-order for ps GEO claim → WP-7 |
| — | Misleading 4-antenna comment | **NEW (N1)** | `masterConfig:41-42` → WP-11 |

**Corrections v2 makes to v1:** (a) v1's initial-error/P0 "mismatch" is overstated — the per-axis initial NEES is consistent; the real issue is single-run vs ensemble. (b) v1's scalars (600 s duration) are stale; the current default is 14 400 s. (c) v1 under-counted the scope (repo grew). (d) v1 did not surface the clock-drift consistency defect now documented in the code, nor the relativistic-clock omission as a picosecond-relevant caveat.

## 12. Appendix B — Checks performed this pass

1. **Config resolution** traced by hand through `masterConfig` → `ReceiverGeometry.defaultLeverArms(1)` → `finalizeConfig` → resolved `nReceivers=1`, lever arm `[0;0;0]`, `estimateAttitude=false` (§4.1).
2. **RWFM coefficient**: analytic derivation confirms `2π²/3`; code line `:446` uses `4π²/3` (2×); internally inconsistent with the code's own correct `q2=2π²h₋₂` and truth synthesis (§6.3).
3. **Clock realism**: legacy CESIUM1 `h0=1e-26` → `σ_y(1 s)=√(h0/2)≈7×10⁻¹⁴`, ~2 orders below a real cesium (§6.4).
4. **Doppler Jacobian**: only `∂ρ̇/∂v` and `∂ρ̇/∂ḃ_rx` present; no `∂ρ̇/∂r` (§3.6).
5. **Signs**: LOS `+û`, receiver `+1`, tower `−1`, code `+iono`, carrier `−iono`, Shapiro formula, Sagnac uplink call sites — all verified in current code (§3.4, §7.1).
6. **Consistency wiring**: `monteCarlo.enable=false`; live single-run `ConsistencyStatistics` present (§5.2).
7. **Scope**: 376 `.m`, ~72.7 kLOC, dead-reference counts for the §8 candidates.

## 13. Appendix C — Files reviewed
`config/masterConfig.m`, `config/baseConfig.m` (init/P0), `+revgnss/ConfigFactory.m` (finalizeConfig, applyAtmosphereProfile, getClockTemplate_), `+revgnss/ReceiverGeometry.m`, `+revgnss/ScenarioFactory.m`, `+filter/ReverseGNSSEKF.m`, `+models/+clocks/ClockModel.m` (+ working-tree diff), `+models/+measurements/{CodeJacobianBuilder,DopplerMeasurementBuilder}.m`, `run_oo_v1.m`, `+revgnss/ReportRunner.m` (builder selection); grep-verified: `+revgnss/LinkGeometry.m`, `+models/+measurements/{Code,Carrier}MeasurementBuilder.m`, `+models/+corrections/RangeCorrections.m`, `+models/+frames/LightTimeSolver.m`, `+revgnss/ConsistencyStatistics.m`, `+revgnss/ModelCoverageAudit.m`.
