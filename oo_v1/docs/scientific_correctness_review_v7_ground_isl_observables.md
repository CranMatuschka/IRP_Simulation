# Scientific-Correctness Review v7 — Ground↔Space and ISL Observables

**Scope:** TWSTFT (ground↔space and ISL), code range, carrier phase, Doppler, light-time,
swarm-frame shape/relative-error analysis, and the σ inventory behind all of them.
**Method:** static reading of the measurement kernels, their Jacobians, their EKF entry
points and their config defaults. No code was changed and no runs were made; every
numeric claim below is either derived analytically here or quoted from a comment/config
value in the repository (quoted values are marked as such).

**Reviewer stance.** I checked three things independently for each observable:
(a) is the *physics* right, (b) is the *linearisation* consistent with the physics
(H ≡ ∂h/∂x for the h that is actually formed), and (c) is the *statistics* right
(does R describe the error that is actually in z − h, once, and only once).

**Headline.** The implementation is unusually disciplined. Truth/model separation is
structural rather than conventional, sign conventions are consistent across code /
carrier / Doppler / two-way, the four-event two-way ranging kernel is genuinely correct
relativistic physics, and the honesty gates (floorless-σ warnings, calibration-bias
excursion warnings, `coherenceClaimStatus`, the "declared-not-fabricated" NaN discipline)
are better than most operational GNSS software. The defects I found are concentrated in
two places: **(1) the `firstOrderReciprocal` time-transfer path is an algebraic
substitute, not a measurement** — it omits the dominant two-way non-reciprocity by ~3
orders of magnitude; and **(2) the swarm shape numbers are produced by a synthetic
post-processor fed from truth, not by the simulated measurement chain.** Both are
documented in-code, but neither is documented loudly enough for a result to be quoted
safely without the caveat.

---

## Table of contents

1. [Light-time and frame handling](#1-light-time-and-frame-handling)
2. [Code (pseudo)range — ground→space](#2-code-pseudorange--groundspace)
3. [Carrier phase](#3-carrier-phase)
4. [Doppler / range-rate](#4-doppler--range-rate)
5. [TWSTFT — ground↔space](#5-twstft--groundspace)
6. [ISL — two-way code range (four-event)](#6-isl--two-way-code-range-four-event)
7. [ISL — time transfer](#7-isl--time-transfer)
8. [Swarm frame, shape and relative-error analysis](#8-swarm-frame-shape-and-relative-error-analysis)
9. [σ inventory — optimistic or conservative?](#9-σ-inventory--optimistic-or-conservative)
10. [Kalman-filter integration and cross-observable consistency](#10-kalman-filter-integration-and-cross-observable-consistency)
11. [Findings register and recommendations](#11-findings-register-and-recommendations)

---

## 1. Light-time and frame handling

Files: `+models/+frames/LightTimeSolver.m`, `+models/+corrections/RangeCorrections.m`,
`+revgnss/CoherentTwoWayCodeRangingModel.m` (`solveRetardedTransmitTime_`),
`+revgnss/OneWayInterSatelliteRangingModel.m`.

### 1.1 The uplink rotation is correct, and provably equivalent to the Sagnac term

`LightTimeSolver.solve` (`iterative` mode) rotates the tower by

```
Rz = [ cos(ωτ)  sin(ωτ)  0 ; -sin(ωτ)  cos(ωτ)  0 ; 0 0 1 ] ,   r_twr_at_tx = Rz · r_twr_ecef
```

**Verdict: correct sign for an uplink.** Setting the inertial frame to coincide with ECEF
at *t_rx*, the tower's inertial position at t_tx = t_rx − τ is the *active* rotation of
its ECEF position by −ωτ, which is exactly the matrix above. Because the frames coincide
at t_rx, `norm(r_rx_ecef − Rz·r_twr_ecef)` *is* the inertial range — the trick is exact
(to the accuracy of "ECEF→ECI is a pure z-rotation", i.e. ignoring precession/nutation/
polar motion, which is well below any σ here).

I verified the claimed equivalence with the analytic Sagnac term. To first order
`Rz·r_tx ≈ r_tx − ωτ (ẑ × r_tx)`, so

```
Δρ = −u·δr_tx = ωτ · u·(ẑ × r_tx) = (ω/c) · ẑ·(r_tx × r_rx) = (ω/c)(x_tx·y_rx − y_tx·x_rx)
```

which is **identical** to `RangeCorrections.sagnacCorrectionMeters`, and identical to the
IS-GPS-200 form with tx ↔ transmitter. `correctedPseudorange` correctly suppresses the
analytic Sagnac when `ltModel=='iterative'`, so **there is no double count**. This is the
cleanest part of the whole geometry stack.

Magnitude sanity: at GEO, τ ≈ 0.127 s, ωτ ≈ 9.3 µrad, and the correction reaches
2ωA/c² ≈ 218 ns ≈ **65 m** at the extreme geometry — i.e. this is a first-order term, not
a refinement, and it is right.

`MeasurementModelUtils.needsFiniteDiffH_` correctly forces finite-difference H when
`lightTime.model=='iterative'`, because dρ/dr = u′ is then no longer exact. Good.

### 1.2 The four-event ISL/two-way solver is the strongest kernel in the repo

`CoherentTwoWayCodeRangingModel.solveEvents_` solves the genuine retarded-time chain
backwards from t4: t4 → (t3 by downleg retarded solve) → t2 = t3 − turnaround-in-
coordinate-time → (t1 by upleg retarded solve). It then *checks* closure
(`lightTimeResidual`) and *checks* time ordering. Notable correctness points:

- The turnaround is converted **proper → coordinate** through the transponder's own
  `properTimeRate` (`coordinateDurationForProperDuration`). That is the right relativistic
  bookkeeping, and it is rare to see it done.
- `properTimeRate_` implements dτ/dt = 1 − (GM/r + ½v²)/c², the standard 1PN rate. Both
  endpoints use the same convention so only the ratio matters — correct.
- `solveRetardedTransmitTime_` requires ≥3 iterations *and* convergence. The contraction
  factor is ~v/c ≈ 10⁻⁵, so 3 iterations drives the residual below machine precision.
  The `10 × tolerance` closure assertion is a real guard, not decoration.

### 1.3 Declared simplifications (correct to declare, but bound the scope)

- `OneWayInterSatelliteRangingModel` declares `LightTimeCorrectionSupported = false` and
  `GeometryKernelIdentifier = 'instantaneousCoordinateEpochGeometry'`. For a ~1 km
  formation (τ = 3.3 µs, relative motion ~1 m/s) the omitted term is ~3 µm — genuinely
  negligible. **But this scales as τ·|Δv|**: at a 70 000 km GEO-to-GEO separation
  (τ = 0.23 s, Δv up to ~6 km/s) it is **~1.4 km**. The class name says
  "instantaneous", which is honest, but nothing in the config refuses a wide baseline.
- The frame-invariance argument in that class's header is correct and worth keeping:
  `u′Δv` is exactly ECEF/ECI-invariant because Δr_eci ∥ u so the transport term
  u′(ω × Δr) ≡ 0. I verified this.
- `TwoWayCodeEndpointModel.constantVelocity` straight-lines each endpoint across the round
  trip. For ground↔space at GEO the tower's ECI circular motion over 0.127 s gives a
  chord-vs-arc error of ~0.24 mm per leg, largely cancelling in the difference — well
  under the 30 mm σ. Fine as-is; worth a comment so it is not re-derived later.

---

## 2. Code (pseudo)range — ground→space

Files: `+models/+measurements/CodeMeasurementBuilder.m`, `CodeJacobianBuilder.m`,
`MeasurementModel.m`.

### 2.1 The core equation is right

```
z = ρ_true(r_ant_true, r_twr_true) + b_rx_true − b_twr_true + Σ truth errors
h = ρ_est (r_ant_est , r_twr_model) + b_rx_est  − b_twr_model + Σ model errors
```

with `H(r) = u′`, `H(b_rx) = +1`, `H(b_twr) = −1`, `H(zwd) = mf(el)`,
`H(iono) = +(f_L1/f_row)²`, `H(txCodeBias) = +1`. Every sign is the GNSS-standard one:
code is a **group delay** (+I), the receiver clock enters with +1 and the transmitter
clock with −1 for a tx→rx link, and the tropospheric mapping factor is positive.

A genuinely good detail at `CodeMeasurementBuilder.m:133-139`: the tower clock is
evaluated at **transmit time** (`b_twr − ḃ_twr·τ`) on the truth side, and the model side
re-evaluates the broadcast product at t_tx too. That is the correct epoch for an uplink
and is usually got wrong.

### 2.2 Double-count guards are correct and, unusually, complete

The `maskStateTowerSigma_` pattern is right: when a tower clock is an EKF state its
uncertainty lives in **P**, so the broadcast-product σ must not *also* enter **R**. The
guard is applied per-tower and per-column (bias vs drift) so gauge/non-estimated towers
correctly *retain* their σ — no under-count either. It is threaded consistently into
(i) the single-frequency diagonal, (ii) the L2/multi-signal diagonal, (iii) the IF
rebuild, (iv) the shared-tower off-diagonal block, (v) the carrier drift block, and
(vi) the Doppler drift block. I found no leak.

### 2.3 The ionosphere-free R rebuild is the most sophisticated thing here — and it is right

The naive `R_IF = α²R₁ + β²R₂` inflates *every* source by α²+β² ≈ 8.9. The code instead
splits by correlation structure:

| source | correlation across L1/L2 | IF gain applied | correct? |
|---|---|---|---|
| code / multipath / scintillation | independent | α²σ₁² + β²σ₂² | ✔ |
| troposphere, tower clock, hw delay | identical (non-dispersive) | (α+β)²σ² = σ² | ✔ |
| 1st-order ionosphere | same TEC, 1/f² | **0** (cancels deterministically) | ✔ |
| higher-order ionosphere | same ray path, f⁻³/f⁻⁴ | \|ασ₁ + βσ₂\| (signed) | ✔ |

I checked α·1 + β·(f₁/f₂)² = 0 exactly with α = f₁²/(f₁²−f₂²), β = −f₂²/(f₁²−f₂²).
The hardware-delay case is a latent-bug fix that has not yet fired (σ_hw defaults to 0)
but would have caused a silent ×8.9 over-count — good defensive work.

The IF `modelTotal_m`/`truthTotal_m` are also IF-combined before storage so the post-fit
recomputation does not reintroduce the single-frequency ionosphere. Correct, and a subtle
trap avoided.

### 2.4 **Defect C-1 (latent): H/h mismatch when IF code meets a slant-iono state**

`MeasurementModel.m:227-243` sets `H(row, ionoIdx) = (f_L1/f_row)²` for every code row
whenever the config has ≥2 frequencies and a per-tower slant-iono state exists. After the
IF combination, `frequencyHz_perMeas` has been compressed to the **L1** entry, so `f_row =
f_L1` and the column is set to **1.0**. But the IF-combined `h` has, by construction,
**exactly zero** dependence on the iono state (α·1 + β·(f₁/f₂)² = 0). The Jacobian
therefore claims unit sensitivity to a state the prediction does not use.

Consequence: the filter would push the slant-iono state to absorb IF-row innovations and,
through P, corrupt position and clock.

**Reachability.** `ConfigFactory.applyAtmosphereProfile` *does* enforce
`ionosphereFree` XOR `estimateIono` — but only on the `cfg.atmosphere.realistic` path.
A scenario that sets `cfg.measurements.codeMode='ionosphereFree'` and
`cfg.estimation.ionosphereMode='perTowerSlant'` **directly** bypasses that guard. So this
is currently latent, not live. It should be fenced at the point of use (skip the iono
column when `errStruct.ifCombination` is true) rather than relying on a guard three layers
away that only runs in one mode.

### 2.5 Minor: the `ionosphereFreeRows` toggle is dead code

`CodeMeasurementBuilder.m:551-557` only consults
`cfg.measurements.code.ionosphereFreeRows.*` when `codeMode_v` is empty, but
`masterConfig` always sets `codeMode = 'singleFrequency'`. The toggle (which defaults to
`enable=true, useInEkf=true`) is therefore inert. `masterConfig:196-201` already says it
is "diagnostic metadata, not a toggle" — but a reader seeing `useInEkf = true` will
reasonably assume otherwise. Consider renaming it `…Declared` or removing it.

---

## 3. Carrier phase

Files: `+models/+measurements/CarrierMeasurementBuilder.m`,
`+revgnss/ISLMeasurementBuilder.m` (ISL carrier), `+revgnss/IslCarrierTrackManager.m`.

### 3.1 Physics and signs

```
z_φ = ρ_true + b_rx_true − b_twr_true + trop_true − I_true·(f_L1/f)² + B_true + ε + …
h_φ = ρ_est  + b_rx_est  − b_twr_model + trop_model − I_model·(f_L1/f)² + B_est + …
H(amb) = +1  (ambiguity carried in METRES)   H(iono) = −(f_L1/f)²   H(zwd) = +mf
```

**Verdict: correct.** The ionosphere sign is negative (phase advance), opposite to the
code group delay, and it is signed consistently in `h` *and* in `H`. The troposphere keeps
the same (positive) sign as code. The ambiguity in metres with a +1 column (rather than
cycles with a λ column) is a legitimate, internally consistent choice and is documented as
such in both the ground and ISL paths.

### 3.2 The null-space statement in the ISL carrier config is exactly right

`masterConfig` around the ISL carrier σ documents that
`(b_rx + d, B_i − d)` is an **exact null direction** of the carrier rows
(`‖H_carrier·v‖ = 0`), so the only thing anchoring it is the 0.3 m code rows — and it
backs this with a measured σ sweep showing 2 mm weighting degrades position 23×. This is a
correct observability argument and the right conclusion (σ is the *total* budget, not the
thermal figure). I would not change it.

The same statement applies to the *ground* undifferenced carrier and matches the recorded
finding that the undifferenced ISL carrier is inert because the float ambiguity absorbs
what it would contribute.

### 3.3 Carrier R: the tower-clock omission is defensible; the elevation omission is not

`CarrierMeasurementBuilder.m:279-282` deliberately excludes `towerClkSigma` from the
carrier R, arguing the float ambiguity absorbs a constant per-arc clock bias. That is
right for the **constant** part, and the code correctly adds back only the *time-varying*
residual via `addCarrierDriftBlock` (age-weighted from the product epoch). Good.

However `R_φ = σ_φ² · I` is **flat in elevation** — the code path has three elevation
models (`constant` / `elevation` / `cn0`), the carrier has none. Physically the carrier
tracking error follows C/N₀ just as the code does. At the default 5° mask this
under-weights low-elevation carrier rows by roughly the same factor the code model applies
(1/sin 5° ≈ 11 for the `elevation` model). This is a real, if modest, optimism.

### 3.4 **Defect C-2: the raw-L1 carrier loses its ionosphere when the code is IF-combined**

The carrier rows read `errStruct.bySource.truth_m.iono` / `.model_m.iono`. When
`codeMode='ionosphereFree'`, `combineIfValueStruct_` overwrites those fields with the
IF-combined values — which are **identically zero** for the first-order ionosphere. A raw
L1 carrier row that should carry −I_L1 then carries nothing.

Because it vanishes from **both** z and h, this is self-consistent (it will not corrupt the
filter) — but the simulated world silently loses the carrier ionosphere, which is the
dominant carrier error at L-band. Anyone reading a carrier-residual plot from an IF-code
run would draw the wrong conclusion. Fix by snapshotting the pre-IF per-signal iono before
`combineIfSources_`, or by refusing the combination `codeMode='ionosphereFree'` +
`carrierMode='ekfFloat'` without `carrier.ionoFreeRows.enable`.

### 3.5 What is honestly declared as missing

Phase wind-up and antenna PCV/PCO on the ISL carrier are declared not-implemented
(`ISLMeasurementBuilder.m` carrier block) and folded into the total σ budget rather than
silently ignored. For a formation whose members hold fixed relative attitude, wind-up is
near-constant and absorbed by B; for a rotating or slewing member it is not, and it is a
genuine cycle-level error. The declaration is correct; the limitation should be repeated
wherever a carrier-derived beamforming claim is made.

The `buildDiagnostic` path deliberately excludes the atmosphere entirely and says so with
the correct signs for whoever adds it later. Good practice.

---

## 4. Doppler / range-rate

Files: `+models/+measurements/DopplerMeasurementBuilder.m`,
`+revgnss/OneWayRangeRateModel.m`.

### 4.1 The observable is the exact time derivative of the pseudorange — correct

```
z_D = ρ̇ + ḃ_rx − ḃ_twr + ε ,   ρ̇ = u′v_rx_ecef + u′(ω × Δ)
```

Differentiating `z = ρ + b_rx − b_twr` gives precisely this. The Sagnac-*rate* term is
handled by adding the tower's ECI rotational velocity **once**, on both sides, with an
explicit `sagnacRateHandling = 'capturedByTowerVelocityTerm'` flag — i.e. the double-count
trap is closed by construction, not by convention. The ECI equivalence claimed in the
header (ρ̇ = u′(v_rx_eci − v_tx_eci)) is algebraically correct.

### 4.2 **Defect D-1: H omits ∂ρ̇/∂r by default, and the omission is not negligible at metre-level errors**

`Hd` carries only `∂/∂v = u′` and `∂/∂ḃ_rx = 1`. The position partial exists, is exact, and
is *implemented* (`OneWayRangeRateModel.positionPartial`) — but is gated off by default
(`measurements.doppler.includePositionPartial = false`).

Magnitude at GEO: the dominant piece is `omegaPart = ω·|u| ≈ 7.3e-5` plus
`(v_eff − ρ̇u)/ρ` with |v_eff| ≈ |ω × Δ| ≈ 2.8 km/s over ρ ≈ 3.8e7 m ≈ 7.3e-5. Total
**≈ 1.5e-4 (m/s) per metre**. Against the default σ_D = 0.01 m/s:

| position error | omitted innovation term | fraction of σ_D |
|---|---|---|
| 1 m | 1.5e-4 m/s | 1.5 % |
| 5 m | 7.5e-4 m/s | 7.5 % |
| 20 m | 3.0e-3 m/s | 30 % |

The recorded along/cross-track floor for this architecture is "a few metres", and the
transient is much larger. So the approximation is fine in steady state and **marginal
during acquisition**. Since the exact partial already exists and costs nothing, the default
should be `true`; the "documented approximation" framing is a weaker justification than the
code deserves.

### 4.3 Doppler is *off* in the shipped default, and reports zeros rather than nothing

`masterConfig` ships `measurements.doppler.enable = true`, `useInEKF = true`, but
`physics.doppler.truth.enable = false` and `.model.enable = false`. `finalizeConfig`
(`ConfigFactory.m:1456+`) auto-disables `useInEKF`, so no error is raised — but the
diagnostic path still emits `z = 0`, `h = 0`, `prefit = 0`. A report reading
`dopplerInfo.prefit` will show a perfect zero residual, which is indistinguishable from an
excellent Doppler solution. The 300 s warning helps in a console but not in a `.mat`
report. Recommend setting `dopplerInfo.z/h/prefit = []` (or a `modelled=false` flag that
consumers must honour) when `doTruth` is false.

### 4.4 Missing rate terms — declared

`lightTimeRateHandling = 'metadataOnlyV1'`; there is no troposphere-rate or ionosphere-rate
term. For a GEO at fixed elevation the atmospheric rates are ~0, so this is well matched to
the scenario. The `includeRateTerm` guard that *excludes* all Doppler rows rather than
applying an unmodelled dispersive bias is the right call.

---

## 5. TWSTFT — ground↔space

Files: `+revgnss/TwoWayTimeTransferBuilder.m`, `+revgnss/ReciprocalTimeTransferModel.m`,
`+revgnss/FourTimestampGroundSpaceTimeTransferBuilder.m`,
`+revgnss/FourTimestampObservableBuilder.m`.

There are **two** ground↔space time-transfer paths and they are of very different quality.

### 5.1 `mode = 'firstOrderReciprocal'` (the default) — **this is not a two-way measurement**

`ReciprocalTimeTransferModel.evaluate` returns, algebraically:

```
value = (b_remote − b_reference)  [+ reciprocity]
reciprocity = −(Δr′Δv)/c = −ρ·ρ̇_rel/c
H(b_rx) = +1,  H(b_twr) = −1  [+ small r/v columns if reciprocity on]
```

The clock-difference part and its partials are internally consistent, and the
"observes the clock with no position column" observability argument in the file header is
correct — this genuinely is the row that breaks the GEO radial↔clock degeneracy.

**But `reciprocity_m` is not the physical two-way non-reciprocity.** I derived the exact
first-order term for the transponder exchange the rest of the repo implements
(A transmits at T1, B turns around after T_turn, A receives at T4):

```
½(τ_f − τ_r)·c  =  τ·(u·v_A)  +  ½·T_turn·(u·Δv)
```

The leading term depends on the **absolute inertial velocity of the reference endpoint**,
not on the relative range rate. For a ground station at GEO slant range:

| term | value |
|---|---|
| implemented `−ρ·ρ̇_rel/c` (with v_tower forced to **0**) | ~0.1 m (ρ̇ ≈ 1 m/s) |
| **physical** `τ·(u·v_tower_eci)` | **~20–40 m** (τ = 0.127 s, u·v ≈ 150–300 m/s) |
| declared `reciprocitySigma_m` | 0.005 m |

That is a **2–3 order-of-magnitude** miss in a term whose real-world analogue (the TWSTFT
Sagnac correction, 2ωA/c² ≈ 218 ns ≈ 65 m at the extreme geometry) is precisely what
operational TWSTFT must calibrate to reach 100 ps.

**Why this does not corrupt the filter, and why it still matters.** The term is absent from
both z and h, so the simulated world simply has no two-way non-reciprocity and the EKF sees
no inconsistency. The reported clock accuracy is therefore not *wrong* — it is **untested**.
The simulation demonstrates "if the geometry-dependent non-reciprocity were perfectly
known, TWSTFT delivers σ_m"; it does not demonstrate that the non-reciprocity can be
modelled to the 3 mm needed to defend 10 ps. Any 100 ps claim resting on this path must
carry that caveat explicitly.

Two further omissions on this path:

- **No differential (tx − rx) hardware delay.** I derived the exact hardware residual of a
  two-way exchange: `½[(d_A^tx − d_A^rx) − (d_B^tx − d_B^rx)]`. Only the *asymmetry within
  a terminal* survives; the totals cancel. The model carries **one** delay per endpoint, so
  it structurally cannot represent this — and it is *the* dominant TWSTFT systematic
  (0.5–1 ns ≈ 15–30 cm, and drifting with temperature). `masterConfig` sets both
  `truth.*CalibrationError_s` and `calibration.*Sigma_s` to 0, so the shipped scenario has
  a perfectly calibrated link.
- **No atmospheric non-reciprocity.** The troposphere is reciprocal to first order; the
  ionosphere is not (different frequencies up/down in real TWSTFT). Neither appears.

`conservativeProductCorrelation` (default **on**) is a genuinely good piece of statistics:
it inflates the tower-product variance by N = updateInterval/dt so a sequential EKF cannot
average a *piecewise-constant* product error down by √N below the reference-clock floor.
This is the right conservative treatment; the rigorous alternative (a per-tower product-bias
state) is correctly named in the comment.

### 5.2 `mode = 'fourTimestampClockDifference'` — this one *is* a measurement

`FourTimestampObservableBuilder.reduceClockDifference_`:

```
value_s = ½[(t2 − t1) − (t4 − t3)]
```

**Verdict: correct.** With t1 = T1 + b_A, t2 = T2 + b_B, t3 = T3 + b_B, t4 = T4 + b_A:

```
½[(τ_f + b_B − b_A) − (τ_r + b_A − b_B)] = (b_B − b_A) + ½(τ_f − τ_r)
```

so the sign is `remote − reference`, matching `ReciprocalTimeTransferModel`'s
`referenceClockPartial = −1 / remoteClockPartial = +1`, and the non-reciprocity is the real
one — computed by the four-event retarded-time solver from actual geometry, on **both** the
truth and the estimated side, so it cancels down to the state error rather than being
assumed away. This is the path that should be used for any defensible time-transfer claim.

I also verified the terminal-delay allocation (`applyTerminalDelayAllocation_`), which is
an **injection** model despite the "correction" wording:

| allocation | net effect on the clock difference | correct? |
|---|---|---|
| `receiveEvent` (default) | +½(d_anchor − d_origin) | ✔ (all delay on rx) |
| `transmitEvent` | +½(d_origin − d_anchor) | ✔ (all delay on tx) |
| `splitEvenly` | **0** | ✔ (symmetric ⇒ no differential ⇒ cancels) |

All three are physically right *given* the one-delay-per-endpoint model. The config comment
that a turnaround error is inert for this observable is also correct — shifting T3 shifts T4
equally, so (t4 − t3) is unchanged.

**Recommendation.** `firstOrderReciprocal` should be relabelled in-code and in reports as
what it is (a *processed clock-difference substitute with idealised reciprocity*), and
`fourTimestampClockDifference` promoted to the default for any TWSTFT result that is quoted.

---

## 6. ISL — two-way code range (four-event)

Files: `+revgnss/TwoWayISLMeasurementBuilder.m`,
`+revgnss/CoherentTwoWayCodeRangingModel.m`.

### 6.1 Physics: correct, including the parts usually skipped

```
measured = rate_A·(τ_f + T_turn_coord + τ_r) + d_term_true + d_plasma + ε
z        = ½c·(measured − d_term_cal − rate_A·T_turn_cal/rate_B)
h        = ½c·(rate_Â·(τ̂_f + T̂ + τ̂_r) + d_term_cal + d_plasma_model
                 − d_term_cal − rate_Â·T_turn_cal/rate_B̂)
```

Checks I made:

- **The initiator clock bias cancels exactly.** It is an interval measurement on one clock;
  only the *rate* survives. The `clockCancellation` string states this and it is true. This
  is the correct and important distinction between a two-way *range* and a two-way *time
  transfer*, and the repo gets it right.
- **Truth adds the physical delay and subtracts the calibrated one; the model adds and
  subtracts the calibrated one.** The residual is therefore exactly the calibration error —
  no oracle leak. Verified term by term for both the terminal delay and the turnaround.
- The turnaround cancels exactly because `events.turnaroundCoordinate_s = T_true/rate_B`
  and the subtracted equivalent is `rate_A·T_cal/rate_B`, leaving
  `rate_A·(T_true − T_cal)/rate_B`. Correct.
- `finalReceptionCoordinateTime_s = initiatorEstimate.coordinateTimeAtLocalTag(tag)` — the
  estimator maps the *recorded local tag* back to coordinate time through its **own clock
  state**. This is exactly how a real receiver works and is what makes the row weakly
  sensitive to the clock at all. Excellent design.

### 6.2 Common-motion cancellation — I verified the claim

For the **range** (the *sum* ½(τ_f + τ_r)), the common velocity cancels:

```
½c(τ_f + τ_r) = ρ + (τ + ½T_turn)·(u·Δv)
```

so a two-way range is first-order insensitive to common motion, and only the **relative**
velocity survives. This confirms the assertion in `SwarmRelativeSolver.twoWayLightTime_`
("first-order Sagnac/transport terms cancel by reciprocity"). Note the `½T_turn·(u·Δv)`
piece: with T_turn = 1 ms (the config default) and u·Δv ≈ 1 m/s this is **0.5 mm** — the
same order as the sub-cm shape claims, and it is present in the four-event path but absent
from the synthetic path (§8).

### 6.3 Linearisation

Five-point FD (`(−h₊₂ + 8h₊₁ − 8h₋₁ + h₋₂)/12s`) over both endpoint blocks, with the
attitude columns correctly differentiated in the **tangent basis** when
`quaternionErrorState` is active — a trap the code names explicitly and avoids. Steps are
0.5 m / 0.05 m/s / 5e-4 rad / 10 m / 0.01 m/s.

Numerical health: positions are inertial (~4.2e7 m) and the range is ~10³ m, so the
cancellation floor is ~1e-8 m. Against a 0.5 m position step the FD noise is ~2e-8 — fine.
The clock-bias column is the worst case (∂ρ/∂b ~ v_rel/c ~ 3e-9 per metre, so ~30 %
relative FD noise) but the **absolute** error is ~1e-9 per metre and cannot move the
update. No action needed; worth a comment so it is not "fixed" later.

### 6.4 The honesty gates here are exemplary — and they are pointing at a real hazard

- `warnOnFloorlessSigma_`: a thermal-only link budget at 1 km / 26 GHz / 10.23 MHz yields
  **1.9e-5 m** with a 99.9 dB margin. As R, a 0.37 m uncalibrated delay then reads as a
  **20 000 σ** inconsistency. **There is no innovation gate anywhere in the EKF**
  (`ReverseGNSSEKF.update` has no χ² rejection), so the filter resolves that by warping
  geometry. The warning is the only defence. `nonThermalSigma_m` exists to fix it but
  defaults to 0.
- `warnOnBiasExcursion_`: correctly identifies that a per-link calibration bias is
  rank-deficient against the baseline for a single link, quotes the measured failure
  (b → 1000/1136/…/1980 m at a *reported* σ of 0.000 m with the formation collapsed under
  5 m), and warns rather than silently producing it.
- `validateConfig` refuses to fold a **recurring** calibration error into a white per-epoch
  R unless either the persistent bias state is enabled or the declared σ covers the error.
  This is the single most important statistical guard in the file and the reasoning
  (constant errors do not average as 1/√n) is correct.

### 6.5 Structural constraint, correctly enforced

`range.useInEKF` requires `multiAsset.mode = 'joint'`, because a physical two-way range
must update **both** endpoints. Correct — a range row applied to only one endpoint block
would be a different (and wrong) measurement.

---

## 7. ISL — time transfer

Files: `+revgnss/InterSatelliteTimeTransferBuilder.m`,
`+revgnss/InterSatelliteFourTimestampTimeTransferBuilder.m`,
`+revgnss/IndependentFleetCoordinator.m`.

The same two-tier split as §5, and the same conclusion:

- **`InterSatelliteTimeTransferBuilder`** (the EKF-usable, `multiAsset.mode='joint'` path)
  calls `ReciprocalTimeTransferModel.evaluate` — i.e. the **algebraic** clock difference.
  It records this honestly: `rawTimestampTagsAvailable = false`,
  `physicalFourEventModelApplied = false`, `timestampTags_s = nan(1,4)`. Those flags are
  the correct provenance and any report consuming this row should print them.
- **`InterSatelliteFourTimestampTimeTransferBuilder`** (reached via the distributed/
  federated coordinator) uses the real t1..t4 chain.

For an ISL, the omitted non-reciprocity `τ·(u·v_A)` is τ = 3.3 µs × v_A ≈ 3075 m/s
(inertial GEO velocity) ⇒ up to **~1 cm** depending on baseline orientation. That is *not*
negligible against a 0.03 m σ or a mm-class shape claim, and it is exactly the term the
four-timestamp path captures and the first-order path does not.

This matches, and explains, the recorded measurement that the sat-sat time transfer
*degrades* the relative clock 0.0156 → 0.0192 m (+23 %) versus simply differencing the
per-asset EKFs: once the ground TWSTFT has pinned the clocks and the errors are
common-mode, adding a row whose modelled non-reciprocity is wrong by ~1 cm can only hurt.

**Recommendation.** Where the ISL time-transfer row enters the EKF, either use the
four-timestamp observable or inflate σ to cover `τ·|v_orbital|` (≈1 cm at GEO) rather than
the 0.005 m `reciprocitySigma_m`.

---

## 8. Swarm frame, shape and relative-error analysis

Files: `+revgnss/SwarmRelativeSolver.m`, `+revgnss/PairwiseRelativePositionError.m`,
`+revgnss/BeamformingPhasorDiagnostics.m`, `+revgnss/SwarmFormation.m`.

### 8.1 The metric definitions are correct and the distinction is the right one

`PairwiseRelativePositionError` is the cleanest file in the review. It separates:

```
relativePositionError_m = ‖(r̂_i − r̂_j) − (r_i − r_j)‖        VECTOR baseline error
baselineLengthError_m   = ‖r̂_i − r̂_j‖ − ‖r_i − r_j‖          SCALAR length error, signed
```

and states in the payload itself that the second is "blind to error perpendicular to the
baseline, so it is always the smaller and more flattering". Both are translation-invariant.
This is exactly the trap that makes range-only formation results look better than they are,
and it is named and defended with a negative-control test.

`attachFinalCovariance` computes `P_rel = P_ii + P_jj − P_ij − P_ijᵀ` — correct, and the
only honest route to a pair σ when the filter retains per-epoch relative covariance only
against the reference.

### 8.2 The free-network solve is correct

`solveEpoch_` builds `H(p, i) = u′, H(p, k) = −u′`, `res = z − ρ`, and solves with a
**truncated** pseudo-inverse. Checks:

- The 6-DOF rigid null space is **exactly** in the null space of H: a rotation δr_i = ω × r_i
  gives `u′(ω × ρu) = ρ·u′(ω × u) = 0`. Verified. So min-norm/inner-gauge truncation is the
  right device and the reported metrics (baseline lengths, Kabsch best-fit-rigid residual)
  are genuinely gauge-invariant.
- Truncating (rather than plain `pinv`) is the correct choice: it leaves a weakly-observable
  shape DOF at the prior instead of amplifying noise by 1/s_min. The measured failure it
  prevents (32 m on a collinear N=3 helix) is quoted in the comment.
- `rigidityMargin = nLinks − (3N − 6)` is stated rather than left to fail silently. Good.
- Kabsch alignment uses `diag([1,1,sign(det)])` to forbid reflections. Correct.

### 8.3 **Defect S-1 (the most important caveat in this review): the shape observable is synthetic and truth-fed**

The default shape path is `shapeObservationSource = 'syntheticTwoWayISL'`:

```
z_pair = ‖r_truth_i − r_truth_k‖ + pairBias + thermal   [+ optional light-time term]
```

The observation is generated **from the truth trajectories**, not from the simulated
measurement chain, and the solver then corrects the EKF estimate toward it. The file says
so plainly ("The synthetic range observations above are generated from truth trajectories,
so this remains a diagnostic post-processor") — but the consequence deserves to be stated
at the top of any results table:

> **The reported `shapeErrSolved_m` is bounded by the assumed ISL noise model, not by
> anything the simulation measured.** It answers "if a two-way ISL of this quality existed,
> what shape could a free-network solve recover", not "what shape did this simulation
> achieve".

The `fourTimestampObservables_` branch replaces this with the real four-event range when
the recorded truth supports it (and records `shapeFallbackReason` when it cannot) — that is
the right architecture, and it is what makes the difference between a demonstration and a
result. `shapeObservationSource` should be printed next to every shape number.

Two smaller points on the synthetic path:

- It omits the `½·T_turn·(u·Δv)` term (§6.2) — ~0.5 mm at T_turn = 1 ms, i.e. at the same
  order as the sub-cm claims.
- `pairR = σ_thermal² + nCorr·(σ_const² + σ_rw²)` with nCorr = min(τ/dt, 60) = 60 by
  default. With σ_thermal = 0.01 and σ_const = 0.01, σ_rw = 0.003, the bias term dominates R
  by ~65×. Because it is common to all pairs it does **not** change the WLS solution (the
  weights cancel); it only changes the reported `formalShapeSigma_m`. Once the per-pair link
  budget makes σ_thermal pair-dependent, the *relative* weighting is mildly distorted
  (a long link's thermal noise is up-weighted against a bias that is not length-dependent).
  Minor, worth a note.
- The per-link delay-cal bias is **not** estimated by default
  (`delayCal.estimate.enable = false`) and is a constant ~10 mm 1σ per pair, so with
  shape-error ≈ range-error it sets a ~1 cm shape floor. The self-calibration pass, when
  enabled, correctly removes only the *differential* part and deliberately leaves the common
  part (which is an unobservable scale). That reasoning is right.

### 8.4 The beamforming bridge is scientifically sound

`BeamformingPhasorDiagnostics` gets four things right that are routinely got wrong:

1. **Exact phasor sum**, with Ruze `exp(−σ_ψ²)` carried alongside only for comparison and
   correctly described as a small-error envelope valid to ~σ_ψ < 1 rad.
2. **Focused, not plane-wave.** Exact element-to-target ranges throughout, with the Fresnel
   distance 2D²/λ computed and a `nearField` flag reported. For a km-class GEO formation at
   S-band the user *is* in the radiating near field, so a plane-wave array factor would
   simply be the wrong model.
3. **Common-mode is not free at finite range.** The payload separates the shape-only term
   from the total so the `|d|·D/R` leak is visible rather than attributed to shape.
4. **`coherenceClaimStatus`** refuses the claim unless physical range rows were consumed
   *and* there are at least as many scalar constraints as relative DOF. This is the exact
   guard needed to stop a phasor diagram drawn on an unconstrained follower set (which looks
   *better* than a constrained one) from being reported. Consumers must print the status —
   that instruction should be enforced, not requested.

Piston removal (`e_i ← e_i − mean(e)`) is correct: an overall beam phase is free.

---

## 9. σ inventory — optimistic or conservative?

Values quoted from `config/masterConfig.m`. My assessment is against what the *stated
physics* would support, and against operational practice.

### 9.1 Ground→space

| quantity | key | value | assessment |
|---|---|---|---|
| Code thermal | `errors.codeNoise.sigma_m` | 0.30 m | **Realistic→conservative.** Reasonable for a GEO uplink; the `cn0`/`elevation` weighting models are available and physically formulated. |
| Code σ at 45 dB-Hz | `measurements.codeNoise.cn0.sigmaAt45dBHz_m` | 0.30 m | Consistent with the above. The C/N₀ law σ = σ₀·10^(−(C/N₀−45)/20) is the correct thermal scaling. |
| Carrier | `measurements.carrier.sigma_m` | 0.005 m | **Conservative as a thermal figure** (real L-band tracking is 1–3 mm), but it is being used as a *total* budget with no elevation dependence and with wind-up/PCV unmodelled. Net: **borderline optimistic** at low elevation. |
| Carrier (diagnostic) | `measurements.carrierPhase.sigma_cycles` | 0.01 cyc | ≈ 1.9 mm at L1. Diagnostic-only; fine. |
| Doppler | `measurements.doppler.sigma_mps` | 0.01 m/s | **Optimistic for a raw FLL.** 1 cm/s ≈ 0.05 Hz at L1 — achievable only with carrier-aiding. `realismGradeConfig` overrides it with an explicit "raw FLL, not carrier-derived" honest floor, which is the right instinct; the *default* should follow. |
| Troposphere residual | `errors.troposphere.sigma_m` / `stochastic.sigmaWet_ss_m` | 0.10 / 0.05 m | Realistic post-model residual. ✔ |
| Ionosphere residual | `errors.ionosphere.sigma_m` / `stochastic.sigmaVDelayL1_ss_m` | 0.50 / 1.0 m | Realistic post-Klobuchar. ✔ |
| Tower clock product | `clocks.tower.product.sigmaBias_m` | 0.01 m (33 ps) | **IGS-class, defensible**, and *stated as such*. It is the honest floor the TWSTFT comment correctly identifies. |
| Tower survey | `effects.towerSurvey.sigmaENU_m` | [1,1,3] cm | Realistic for a surveyed site. ✔ |
| σ floor | `measurement.sigmaFloor_m` | 1e-3 m | Sensible guard. ✔ |

### 9.2 TWSTFT

| quantity | value | assessment |
|---|---|---|
| `twoWayTimeTransfer.sigma_m` | 0.03 m (100 ps) | **Optimistic as a *total* budget, given the physics that is missing.** 100 ps white noise is achievable for the *random* part of a good TWSTFT link. But there is **no** systematic term at all: no differential tx/rx hardware delay (0.5–1 ns ≈ 15–30 cm in reality, and the dominant error), no geometry-dependent non-reciprocity (§5.1, ~20–40 m unmodelled), no atmospheric non-reciprocity. σ describes only the term the simulator injects. |
| `reciprocitySigma_m` | 0.005 m | **Optimistic by ~3 orders** relative to the physical non-reciprocity it nominally covers. |
| `truth.*CalibrationError_s`, `calibration.*Sigma_s` | 0 | Perfectly calibrated link by default. The knobs exist — they are simply all zero. |
| `conservativeProductCorrelation` | true | **Correctly conservative.** ✔ |

### 9.3 ISL

| quantity | value | assessment |
|---|---|---|
| `isl.oneWay.code.sigma_m` / `isl.code.sigma_m` | 0.30 / 0.50 m | Reasonable for a one-way crosslink. ✔ |
| `isl.carrier.sigma_m` | 0.20 m | **Deliberately and correctly conservative**, with a measured σ-sweep table justifying it and a hard warning below 0.05 m. This is the best-argued σ in the repo. |
| `isl.twoWay.range.sigma_m` | 0.25 m | Conservative as a *total* budget on the `fixed`/`linkBudget` branches. ✔ |
| `isl.twoWay.range.nonThermalSigma_m` | 0 | **The hazard.** On the `physicalRF` branch the thermal-only σ is 1.9e-5 m; with this at 0 and no innovation gate, a single uncalibrated delay becomes a 20 000 σ constraint the filter satisfies by distorting geometry. The warning fires, but the default should be non-zero. |
| `multiAsset.twoWayISL.sigma_m` | 0.01 m | Plausible for a cm-class wideband crosslink. |
| `multiAsset.twoWayISL.delayCal.sigma_const_m` / `sigma_rw_m` | 0.01 / 0.003 m | **The right instinct** — a constant per-link bias that cannot average down is what actually sets the shape floor, and it is modelled. ✔ |
| `isl.twoWay.timeTransfer.sigma_m` | 0.03 m | Should be ≥ ~1 cm larger to cover the unmodelled `τ·u·v_orbital` non-reciprocity on the first-order path (§7). |
| `isl.product.sigmaPos_m` / `sigmaClock_m` | 0.05 m / 0.03 m | Honest "assumed-known beacon" floor, and the anti-circularity guard (`estimateMode='position'` ⇒ product forbidden) is the correct architectural fence. ✔ |

### 9.4 Summary judgement

- **Conservative and well-argued:** ISL carrier σ, ISL two-way range σ on the declared
  branches, the delay-cal bias model, `conservativeProductCorrelation`, the tower-clock
  product floor, the IF correlation-aware R.
- **Optimistic:** ground Doppler σ (default only), TWSTFT σ *as a total budget*, ISL
  time-transfer σ on the first-order path, flat carrier R in elevation,
  `nonThermalSigma_m = 0` on `physicalRF`, and — most consequentially — the fact that every
  systematic knob (`truth.*CalibrationError_s`, `calibration.*Sigma_s`,
  `errors.hardwareDelay.sigma_m`, `errors.multipath.sigma_m`) **ships at zero**.

The distinction the repo draws — "σ_m is the TOTAL error budget, not the thermal noise
alone" (`ISLMeasurementBuilder.m:130`) — is exactly the right rule. It is applied rigorously
on the ISL carrier and two-way range paths, and **not** applied on the TWSTFT paths.

---

## 10. Kalman-filter integration and cross-observable consistency

### 10.1 The update is textbook-correct

`ReverseGNSSEKF.update`: `S = HP⁻Hᵀ + R` (symmetrised), `K = P⁻Hᵀ/S` (right division, no
explicit inverse), Joseph form `P⁺ = (I−KH)P⁻(I−KH)ᵀ + KRKᵀ`, quaternion error-state
injection applied to the **posterior** with the reset Jacobian `I − ½[δθ×]`, then a PSD
guard that distinguishes a genuine non-PSD projection from a benign floating-point nudge.
NIS via backslash. All correct, and the ordering (Joseph before reset) is the subtle part
that is got right.

### 10.2 **Defect K-1: there is no innovation gate**

No χ² / Mahalanobis rejection exists anywhere in the update path. Combined with:

- a two-way ISL row that can legitimately reach σ = 1.9e-5 m (§6.4), and
- systematics that are *not* in R by default,

a single uncalibrated effect becomes a many-thousand-σ constraint that the filter satisfies
by distorting whatever it *can* move. The recorded observation that the joint filter
applied only ~3 % of every ISL range (K = 0.028) is the *opposite* pathology — an
over-confident prior — but both are symptoms of the same missing safety valve. A per-row
gate at, say, 9σ with a logged rejection count would be cheap and would convert silent
geometry warping into a visible diagnostic.

### 10.3 R block structure: correct *within* the MeasurementModel stack, block-diagonal *outside* it

`ProductClockCovarianceBuilder.addSharedProductClockStack` restores the cross-observable
covariance of the shared tower-clock product across code / Doppler / carrier rows — the
right thing, and non-trivial. But the measurement assembly in
`ReverseGNSSSimulation` appends ISL, two-way ISL, ISL time-transfer and ground TWSTFT
blocks with plain `blkdiag`.

The ISL blocks legitimately share nothing with the ground rows. **The ground TWSTFT rows do
not** — they carry the *same* tower-clock product error as the code rows, and treating them
as independent lets the filter average that shared error down. Since the whole purpose of
the TWSTFT row is to pin the clock at the product floor, this is precisely where the
approximation bites. It is documented as a v1 simplification; it should be closed, or the
TWSTFT σ inflated to compensate.

Same-tower off-diagonal blocks *within* the code rows are correctly built as
`R = diag(σ_track²) + Σ_t σ_t²·1·1ᵀ`, which is SPD whenever σ_track > 0, with a `chol`
check and a jitter fallback. Correct.

### 10.4 Truth/model separation

Structural, not conventional. Endpoint objects carry a `stateSource` that is *asserted*
(`assertStateSource('physicalTruth')` / `'estimatorState'`), hardware carries a
`parameterSource`, and calibration identity is checked against the observation record
before linearisation. `getMeasurementState()` (rather than raw `ekf.x`) is used wherever an
observable is attitude-sensitive, because `x(euler_idx)` is reset to zero inside every
update under `quaternionErrorState` — a trap that is named and avoided at the call site.
I found no truth leakage into any `h` or `H`.

### 10.5 Cross-observable consistency of signs — verified

| observable | clock sign | iono sign | notes |
|---|---|---|---|
| code (tower→sat) | +b_rx, −b_twr | +I·(f₁/f)² | ✔ |
| carrier (tower→sat) | +b_rx, −b_twr | **−**I·(f₁/f)² | ✔ opposite to code |
| Doppler | +ḃ_rx, −ḃ_twr | n/a | ✔ exact derivative of the code row |
| ISL one-way (tx→rx) | +b_rx, −b_tx | n/a | ✔ same convention |
| TWSTFT / ISL TT | +1 remote, −1 reference | n/a | ✔ matches the four-timestamp reduction |
| two-way ISL range | initiator bias **cancels** | n/a | ✔ interval on one clock |

No sign inconsistency found anywhere. This is a strong result for a codebase this size.

---

## 11. Findings register and recommendations

Ranked by consequence for a quotable result.

| # | Finding | Severity | Status |
|---|---|---|---|
| **S-1** | Swarm shape observable is **synthetic and truth-fed** by default; `shapeErrSolved_m` is bounded by the assumed noise model, not by the simulation. | **High (interpretation)** | Documented in-code; needs to be surfaced in every report next to the number. |
| **T-1** | `firstOrderReciprocal` TWSTFT omits the physical two-way non-reciprocity by ~3 orders (~20–40 m ground↔space, ~1 cm ISL) and has no differential tx/rx hardware delay at all. | **High (realism)** | Not a filter bug (absent from z and h). Blocks any defensible sub-ns claim. |
| **K-1** | No innovation/χ² gate anywhere in the EKF, while a two-way ISL row can carry σ = 1.9e-5 m. | **High (robustness)** | Only defence is a once-per-link warning. |
| **C-1** | `H(iono) = 1` on IF-combined code rows whose `h` has exactly zero iono dependence. | **Medium (latent bug)** | Guarded only via `applyAtmosphereProfile`, which runs only when `atmosphere.realistic = true`. |
| **C-2** | Raw-L1 carrier silently loses its ionosphere when the code is IF-combined (`bySource.iono` overwritten with the cancelled IF value). | **Medium (realism)** | Self-consistent, so harmless to the filter; misleading in residual plots. |
| **D-1** | Doppler H omits `∂ρ̇/∂r` (≈1.5e-4 per metre at GEO ⇒ 7.5 % of σ_D at a 5 m error) although the exact partial is implemented and gated off. | **Medium** | Flip `includePositionPartial` to true. |
| **R-1** | Ground TWSTFT rows are `blkdiag`'d against the code rows despite sharing the same tower-clock product error. | **Medium (statistics)** | Documented v1 simplification; bites exactly where TWSTFT is supposed to help. |
| **Σ-1** | Every systematic knob ships at zero (`truth.*CalibrationError_s`, `calibration.*Sigma_s`, `hardwareDelay.sigma_m`, `multipath.sigma_m`, `nonThermalSigma_m`). | **Medium (realism)** | `realismGradeConfig` exists to fix this — but the *default* is a perfectly calibrated world. |
| **D-2** | Doppler default σ = 0.01 m/s is carrier-aided-grade, applied to a raw FLL. | **Low–Medium** | `realismGradeConfig` already overrides it; the default should follow. |
| **C-3** | Carrier R is flat in elevation while code R has three elevation/C-N₀ models. | **Low–Medium** | |
| **D-3** | With `physics.doppler.truth.enable = false` (the default), `dopplerInfo.prefit` is reported as exactly zero — indistinguishable from a perfect solution in a `.mat` report. | **Low (reporting)** | |
| **L-1** | `OneWayInterSatelliteRangingModel` uses instantaneous geometry; error scales as τ·\|Δv\| and reaches ~1.4 km at GEO-to-GEO separations. | **Low (scope)** | Correctly declared; nothing refuses a wide baseline. |
| **M-1** | `measurements.code.ionosphereFreeRows.*` defaults to `enable/useInEkf = true` but is dead code because `codeMode` is always set. | **Low (clarity)** | |

### Recommended order of work

1. **Reporting first, code second.** Print `shapeObservationSource`, `shapeFallbackReason`,
   `coherenceClaimStatus`, `rawTimestampTagsAvailable` and `physicalFourEventModelApplied`
   adjacent to every shape / coherence / time-transfer number. Most of the risk in this
   review is a correct number being read as answering a different question.
2. **Promote the four-timestamp paths** (`fourTimestampClockDifference` ground↔space,
   `InterSatelliteFourTimestampTimeTransferBuilder` ISL) to the default for any quoted
   time-transfer or relative-clock result, and relabel `firstOrderReciprocal` as an
   idealised substitute.
3. **Add a per-row innovation gate** with a logged rejection count (K-1). Cheap, and it
   converts the two-way-ISL failure mode from silent to visible.
4. **Fence C-1 at the point of use** — skip the iono column when `errStruct.ifCombination`
   is true, rather than relying on `applyAtmosphereProfile`.
5. **Flip two defaults:** `doppler.includePositionPartial = true`, and a non-zero
   `nonThermalSigma_m` on the `physicalRF` branch.
6. **Give the TWSTFT σ a systematic term** — either model the differential tx/rx delay
   (which needs splitting the single per-endpoint delay into tx and rx) or inflate σ to
   cover it, and state which was done.
7. **Close R-1** by extending `addSharedProductClockStack` over the TWSTFT rows, or inflate
   the TWSTFT σ instead and say so.

### What should *not* be changed

The Sagnac/light-time equivalence, the four-event solver and its proper-time bookkeeping,
the IF correlation-aware R rebuild, the tower-clock P-vs-R double-count guards, the
truncated-pinv free-network gauge, the pairwise relative-error definitions, the ISL carrier
σ and its measured justification, and the beamforming honesty gate are all correct and
better-argued than the norm. Several of them encode hard-won failure modes in comments —
those comments are load-bearing and should survive any refactor.
