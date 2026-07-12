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
- **Klobuchar ionosphere** — `klobucharStatus = 'notImplemented'` (a synthetic mapped model is used instead).
- **Signal-dependent hardware delays / DCB / IFB** — zero (the inter-frequency-bias IF residual is not modelled).
- **Higher-order ionosphere in the dual-frequency IF *EKF* path** — the WP6 residual is injected on the primary (L1) code truth and its L3 survival is proven algebraically; full per-signal injection into the IF EKF rows is a future extension.
- **Full orbit-force adequacy, ISL joint EKF clock gauge, integer AR beyond the Stage-63 guarded path** — out of scope (separate plan).

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
