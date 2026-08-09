# oo_v1 Error Budget

Purpose: an honest, single-page accounting of every pseudorange/carrier error term the
`oo_v1` reverse-GNSS simulation models — its magnitude, whether it is **truth-side** (a
realised error injected into the truth measurement, with its variance entering **R**) or
**estimated** (an EKF state), and whether it **cancels in the dual-frequency
ionosphere-free (L3) combination**. Terms that are **absent** are listed explicitly so
the feasibility conclusion (aspirationally ~3 cm / ~100 ps) is defensible and not
flattered by silent omissions.

This is a *feasibility study*: the target is realistic-to-conservative accuracy. Every
term below is chosen at the conservative (error-increasing) end where uncertain.

## Modelled error terms

| Term | Model | Typical magnitude | Truth-side (R) / Estimated | Cancels in L3? | Notes |
|------|-------|-------------------|-----------------------------|----------------|-------|
| Code thermal noise | White, elevation-dependent | σ ≈ 0.30 m at L1 (`signals.L1.codeSigma0_m`) | truth + R | No (per-frequency) | `cfg.measurements.codeNoise.model` |
| Carrier phase noise | White, mm-level | ~few mm | truth + R | No | receiver carrier bias absorbed into float ambiguities (`carrierMode='ekfFloat'`) |
| Troposphere | Saastamoinen/Davis ZHD + Gauss-Markov ZWD truth, Niell (NMF) mapping; per-tower ZWD EKF model | ~3 cm zenith → ~20–40 cm at low elevation (residual) | truth + estimated (per-tower ZWD) | **No** (non-dispersive) | realistic path = `localWeatherGM` (see [atmosphere_realism.md](atmosphere_realism.md)); matched `simpleMapped` is the default |
| Ionosphere, 1st order | `40.3·TEC/f²`, diurnal + GM VTEC truth, thin-shell obliquity, uplink `f_seen`; Klobuchar / IF model | ~1–3 m single-freq residual; removed to <1 mm by L3 | truth + estimated / removed by L3 | **Yes** (`f⁻²`) | realistic path = `tecGaussMarkov`; single-freq residual ~50% (Klobuchar) is a bias |
| Ionosphere, 2nd/3rd order (WP6) | Bounded residual `f⁻³` / `f⁻⁴` | ~1–2 cm / few mm at L1 (high activity) | truth + R | **No** (survives L3) | opt-in `errors.ionosphere.higherOrder.enable` (default off) |
| Multipath (WP5) | Coloured Gauss-Markov, per link | σ ≈ 0.30 m, τ ≈ 60 s | truth + R | Partially (frequency-independent in this model) | opt-in `errors.multipath.coloredGM.enable`; legacy white-sinusoid default |
| Scintillation | Gauss-Markov amplitude, frequency-scaled | σ ~0.3 m at L1 (code) | truth + R (σ) | No | `errors.ionosphere.scintillation` |
| Receiver clock | Two-state (bias, drift), OCXO template | h-parameter driven | **estimated** (2 states) | No (non-dispersive) | WP4: `clock.templateSource` legacy (default) / jowTable2p1 |
| Tower clocks | Deterministic / product, optionally estimated | template / product σ | external correction or estimated (+ gauge) | No | WP1: clock gauge required when estimated |
| Sagnac / Earth rotation | Geometric Earth rotation inside the iterative light-time solution | ~m-level | truth | No | separate additive Sagnac disabled to avoid double counting (Stage 80) |
| Shapiro delay | `physics.relativity.shapiro` | mm-level | truth | No | enabled |
| Antenna PCO | `effects.antennaPCO` | cm-level | truth | No | enabled |
| Hardware / group delay | Per-tower code delay (optional Stage-11 states) | 0 by default (signal-independent) | truth (or estimated with gauge) | — | signal-**dependent** DCB/IFB = 0 (see absent) |

## Ionosphere-free (L3) combination

The IF combination `ρ_IF = (f₁²·ρ₁ − f₂²·ρ₂)/(f₁²−f₂²)` (`revgnss.IonoFreeCombination`)
removes the first-order ionosphere but **amplifies noise**. For equal per-frequency
sigma σ:

```
σ_IF² = (f₁⁴σ₁² + f₂⁴σ₂²)/(f₁²−f₂²)²   ⇒   σ_IF ≈ 2.98·σ   (variance ≈ 8.87·σ²)
```

for GPS L1/L2 — a real and important cost (`√(α²+β²) ≈ 2.98`, see
`tests/test_iono_free_noise_amplification.m`). The **higher-order** ionosphere residual
(WP6) scales as `f⁻³`/`f⁻⁴`, so it does **not** cancel and **survives** L3 at the cm
level (`tests/test_iono_higher_order.m`). Availability: L3 code combination is opt-in via
`cfg.measurements.code.ionosphereFreeRows` / `codeMode='ionosphereFree'`; the EKF
otherwise runs per-frequency. Estimated first-order ionosphere or the L3 combination is
therefore required to reach the cm target — the higher-order residual then dominates.

## Absent terms (NOT modelled — feasibility caveats)

These are **not** modelled; their omission bounds how far the ~3 cm / ~100 ps conclusion
can be pushed and must be stated in any feasibility claim:

- **Phase wind-up** — absent (no `effects.phaseWindup`). cm-level on carrier for rotating platforms.
- **Antenna phase-centre variation (PCV)** — `effects.antennaPCV.enable = false` (PCO is modelled; PCV is not). mm–cm.
- **Relativistic clock-rate correction** — flag present but **disabled** by the v1 sanitiser (`Relativistic clock-rate correction is not implemented as a validated v1 model`).
- ~~**Klobuchar ionosphere** — `klobucharStatus = 'notImplemented'`~~ **CORRECTED 2026-08-09: this entry was wrong.** The reduced Klobuchar kernel (`models.atmosphere.Klobuchar`) IS implemented and IS applied on the model side whenever `errors.ionosphere.model.correction = 'klobuchar'` — which the shipped `golden_baseline.json` selects. `klobucharStatus` now resolves to `appliedModelSideBroadcastClimatology` or `notSelected` from the config. What is genuinely absent is the ICD's 8-coefficient α/β polynomial and its obliquity `F = 1 + 16(0.53 − E)³`; the thin-shell obliquity is substituted.
- **Signal-dependent hardware delays / DCB / IFB** — zero (the inter-frequency-bias IF residual is not modelled).
- **Higher-order ionosphere in the dual-frequency IF *EKF* path** — the WP6 residual is injected on the primary (L1) code truth and its L3 survival is proven algebraically; full per-signal injection into the IF EKF rows is a future extension.
- **Full orbit-force adequacy, ISL joint EKF clock gauge, integer AR beyond the Stage-63 guarded path** — out of scope (separate plan).
- **Elevation weighting on the carrier R** — absent. `CarrierMeasurementBuilder` builds
  `R_phi = sigma_phi^2 * eye(...)`: one scalar for every carrier row, from 5° to zenith.
  The code path has three selectable per-row models (`MeasurementModelUtils.codeSignalSigma`:
  `constant` / `elevation` 1/sinᵖ(el) / `cn0`); **there is no carrier equivalent** — no
  `carrierSignalSigma` function exists. Measured consequence: the non-dispersive part of the
  carrier budget (troposphere, multipath, antenna phase centre) maps as ~1/sin(el), so a 10 mm
  zenith floor should be ~20 mm at 30°, ~58 mm at 10° and ~115 mm at 5°. Low-elevation carrier
  rows are therefore over-weighted by up to ~10× at every band, in every scenario including
  the goldens. See [Carrier R and the band](#carrier-r-and-the-band) below for why the
  *thermal* half of this is negligible and the *floor* half is not.

## Carrier R and the band

`cfg.measurements.carrier.sigma_m` is the R applied to every carrier EKF row. Because carrier
precision is a fraction of a **wavelength**, a value fixed in metres silently rescales with the
band — 5 mm is 0.026 cycles at GPS L1 (190.29 mm) but 1.02 cycles at the 61.25 GHz ladder rung
(4.895 mm), where R would assert a whole wavelength of noise and the ambiguity and the noise
become indistinguishable. Two opt-in band-referenced handles resolve in
`ConfigFactory.finalizeConfig` once λ is known (both default to `NaN` = not specified, so the
frozen goldens are byte-identical):

| knob | meaning |
|------|---------|
| `measurements.carrier.sigma_cycles` | dispersive term; `sigma_m = sigma_cycles · λ` |
| `measurements.carrier.sigmaFloor_m` | non-dispersive floor, added **in quadrature**; `NaN` inherits `measurement.sigmaFloor_m` |
| `carrierSlip.threshold_cycles` | slip threshold in cycles (a slip *is* an integer cycle count) |
| `carrierSlip.threshold_m = NaN` | AUTO `5·√2·σ`, the idiom already used by `measurements.isl.carrier.slipDetection.threshold_m` |

**Why the floor is mandatory.** `sigma_cycles` alone models only the *dispersive* error — PLL
thermal noise, phase multipath (bounded by λ/4), phase wind-up (one cycle per revolution) —
all genuinely proportional to λ. The *non-dispersive* error (troposphere, oscillator phase
noise, antenna phase-centre stability, PCV residual) is constant in **metres**, so expressed in
cycles it *grows* with frequency: a fixed cycles figure models it backwards. Without the floor,
0.01 cycles at 61.25 GHz is 0.049 mm — **204× below** the 1 cm "real-world guard"
`realismGradeConfig` declares (`honestFloors.carrier_sigma_m`) and `GeoRealWorldScenarioGuard`
enforces.

**Consequence, worth knowing before reading a band sweep.** With `sigma_cycles = 0.01` and the
1 cm realism floor, the result is ~1 cm at *every* band — 10.179 mm at L1, 10.000 mm at
61.25 GHz — because this budget is floor-dominated throughout. That is the honest answer, not a
bug, and it means a band sweep should **not** be expected to show carrier R improving with
frequency.

**Why C/N₀-weighting the carrier is not worth implementing.** Under the floor, applying the
code path's C/N₀ model (45 dB-Hz + 6 dB·sin el) to the carrier moves σ by 1.13 % at L1, 0.08 %
at 5.8 GHz and 0.00 % at 61.25 GHz. The elevation gap above is a ~10× effect and the thermal
gap is a ~1 % one; only the former is worth a change, and since any per-row `R_phi` re-baselines
every frozen golden it should be spent once, together with the R-correlation work (R's
magnitude is sound; its *colour* — correlated errors charged as white — is the known binding
constraint, and elevation weighting does not address it).

**Not band-dependent, but assumed constant anyway:** `measurements.codeNoise.cn0.base_dBHz` is
45 dB-Hz for every band, i.e. the ladder assumes an identical link budget from 915 MHz to
61.25 GHz. Whether that is optimistic depends on an unstated antenna assumption (fixed-aperture
dishes give gain ∝ f² at both ends and more than cancel the f² path loss; fixed-gain antennas
leave C/N₀ falling as 1/f²) — a ~36 dB spread across the ladder. Separately, 61.25 GHz sits in
the **oxygen absorption band** (~10–15 dB/km at sea level), so `freq013` is not a viable
ground-link band at all; that frequency is chosen in practice *because* the atmosphere blocks
it, which makes it a crosslink candidate rather than an uplink one.

## Scientific-correctness changes (WP1–WP8)

| WP | Change | Default behaviour |
|----|--------|-------------------|
| WP1 | Clock gauge required when tower clocks are estimated (`masterClock`/`zeroMeanEnsemble` aliases) | unchanged (enforced only when estimating tower clocks) |
| WP2 | `computeNEES` + two-sided χ² consistency (`ChiSquareConsistency`) | unchanged (new API + test) |
| WP3 | `sigma_angAccel` from a torque budget for attitude presets (~1e-7 rad/s²) | **changed** for attitude-estimating presets |
| WP4 | `clock.templateSource` legacy / jowTable2p1 (sourced OCXO/CESIUM) | unchanged (default `legacy`; jow opt-in) |
| WP5 | Coloured Gauss-Markov multipath, per link | unchanged (default off) |
| WP6 | Second/third-order ionosphere bounded residual (survives L3) | unchanged (default off) |
| WP7 | Analytic (guarded) Euler-rate Jacobian replacing the finite difference | numerically identical (golden unaffected) |
| WP8 | This document + L3 noise-amplification test | documentation |
