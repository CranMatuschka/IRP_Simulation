# Atmosphere realism — physically-grounded troposphere & ionosphere

Purpose: document the change from the *matched synthetic* atmosphere (whose truth-model
residual cancelled to machine precision) to a *physically-grounded* atmosphere whose
troposphere and ionosphere residuals are non-zero, correctly sized, and correctly
dependent on elevation, frequency and time of day. British English throughout; every
constant is web-sourced and adversarially verified (see the reference table at the end).

## The problem

The per-source report panel (`ClockExactReportBuilder.plotPerSourceError_`) showed the
`trop` and `iono` traces at **exactly zero**, flat under the ~0.3 m code-noise floor. This
was not a plotting artefact. Three facts combined:

1. **Matched by construction.** `masterConfig` uses the `simpleMapped` troposphere/ionosphere
   with *identical* truth and model parameters, and `config/expandEnableToggles.m`
   deliberately slaves `truth.enable` and `model.enable` to a single master enable — so the
   config surface cannot manufacture a `truth ≠ model` mismatch. The mean delay therefore
   cancels: `Δ = m(e)·(Z − 1·Z) = 0`.
2. **No physical residual mechanism.** The only stochastic hook (`modelResidual`) was off, and
   even on it merely added seeded white noise to the truth side (noise inflation), with a
   `sameAsTruth` branch that copied the truth realisation into the model (an oracle read that
   forces the residual to exactly zero).
3. **Buried on a linear axis.** Even a correct cm-level residual would be invisible under the
   code floor on the single linear-axis panel.

An atmosphere that contributes identically zero residual makes the covariance and the
~100 ps / ~3 cm feasibility assessment unrealistically optimistic.

## Governing principle

The on-board **model** must be a genuinely imperfect estimate of a stochastic **truth** —
correct in the mean, wrong in its parameters and high-frequency content — so that
`truth − model` is non-zero and physically representative. The divergence is **structural**,
from three always-on mechanisms that survive the single-master-enable rule:

- **independent RNG streams** for truth vs model (`ENV_TROP_TRUTH` vs `ENV_TROP_MODEL`);
- **estimator lag / different bandwidth** (the model is a lagged EKF estimate or a coarser
  climatology, not a fresh copy of the truth draw);
- **different functional form** (Niell truth mapping; Klobuchar model correction).

Two hard rules: **no oracle access** (the model/`h` path never reads a `*Truth` field or an
`ENV_*_TRUTH` stream — the `sameAsTruth` mode is now a hard error) and **no arbitrary noise
inflation** (every σ is tied to a cited model accuracy). Slowly-varying mismodelling is a
**bias** that drives the innovation and belongs on `h`; only zero-mean unpredictable effects
(scintillation fading, thermal noise) belong in **R**.

## What was implemented

### Troposphere (non-dispersive; `localWeatherGM`)

Slant delay `STD = ZHD·m_h(e) + ZWD·m_w(e)`, identical on L1 and L2 (does **not** cancel in
the ionosphere-free combination).

- **ZHD (truth & model, ~2.3 m, predictable):** Saastamoinen model in the Davis (1985) form
  `ZHD = 0.0022768·P/(1 − 0.00266·cos2φ − 0.00028·h_km)` (`P` from the ICAO standard atmosphere,
  driven by tower latitude/height). Cancels to ~mm between truth and model.
- **ZWD (the hard part):** a per-tower first-order Gauss–Markov **truth** wet delay
  (`τ = 3 h`, `σ_ss = 4 cm`) on the `ENV_TROP_TRUTH` stream. The **model** corrects ZHD exactly
  and estimates the wet delay with the per-tower **ZWD EKF state**
  (`estimation.troposphereMode = 'perTowerZwd'`). The residual is `m_w(e)·(ZWD_truth − ZWD_est)`.
- **Mapping:** the genuine Niell (NMF) hydrostatic/wet mapping functions
  (`MappingFunctions.niellHydrostatic`/`niellWet`, coefficients in `NiellCoefficients`),
  replacing the flat-Earth secant. `'simple'` (1/sin) is retained and is the default, so the
  legacy path is byte-identical.

**Resulting residual:** ~3 cm at zenith, growing as ~1/sin(e) to ~20–40 cm at 5–10°.

### Scintillation (gated)

- **Amplitude fading → R:** the Conker et al. (2003) model (`scintillation.model='conker'`)
  raises the code/carrier tracking noise by `1/√(1 − 2·S4²)`, with `S4` elevation-scaled and
  clamped at the 0.707 loss-of-lock limit. Default `legacy` keeps the previous formula.
- **Phase scintillation → truth carrier:** a per-tower, time-correlated first-order
  Gauss–Markov jitter (`τ ≈ 1.5 s`, **not white**) scaled to `σ_φ` and elevation, injected
  into the truth carrier as `φ·λ/(2π)` (mm-level). Gated by `scintillation.phaseScint.enable`;
  off ⇒ exactly zero, no RNG consumed, carrier golden untouched.

### Ionosphere (dispersive 1/f²; `tecGaussMarkov`)

`I = 40.308·STEC/f²` (`+` code, `−` carrier); `K_L1 = 40.308e16/f_L1² ≈ 0.162 m/TECU`.

- **Truth:** a diurnal VTEC profile (night floor + 14:00 daytime bump) plus a stochastic
  Gauss–Markov TEC fluctuation, scaled by the **uplink topside fraction** `f_seen ∈ [0,1]`
  (GEO ≈ full column; a LEO within/above the F2 peak sees a reduced fraction) and mapped to
  slant by the **thin-shell obliquity** `M(e) = 1/√(1 − (Rₑcos e/(Rₑ+h_ion))²)`.
- **Model:** the single-frequency **Klobuchar** broadcast correction (`+models/+atmosphere/Klobuchar.m`,
  IS-GPS-200 half-cosine with the 5 ns night floor), a deliberately crude climatology that
  removes ~50 % of the RMS iono error. Dual-frequency users instead remove the first-order term
  via the ionosphere-free rows already in the measurement pipeline; what survives there is the
  higher-order term.
- **Higher order:** the WP6 second/third-order residual (`HigherOrderIonosphere`) that survives
  the IF combination (~cm at L1).

**Resulting residual:** single-frequency Klobuchar ~1–3 m (a slowly-varying bias); second/third
order ~1–2 cm; both grow toward low elevation and peak with the diurnal TEC.

## Config knobs (all opt-in; defaults reproduce the legacy behaviour)

The realistic scenario is assembled by `config/realisticAtmosphereConfig.m`
(applied on top of `masterConfig`). It is wired into `run_oo_v1.m` behind the
`useRealisticAtmosphere` toggle (default true), so the normal run exercises it and
writes the log-scale residual figures into the run folder — no separate driver script.

| Field | Meaning | Legacy default |
|-------|---------|----------------|
| `errors.troposphere.modelType` | `simpleMapped` \| `localWeatherGM` | `simpleMapped` |
| `errors.troposphere.<side>.mappingType` | `simple` (1/sin) \| `niell` | `simple` |
| `errors.troposphere.dayOfYear` | Niell seasonal day-of-year | 1 |
| `errors.troposphere.stochastic.tau_s` / `.sigmaWet_ss_m` | wet-delay GM correlation time / σ | 3600 s / 0.05 m |
| `estimation.troposphereMode` | `none` \| `perTowerZwd` (EKF wet estimate) | `none` |
| `errors.ionosphere.modelType` | `simpleMapped` \| `tecGaussMarkov` | `simpleMapped` |
| `errors.ionosphere.truth.diurnal.enable` / `.vtecDay_TECU` / `.vtecNight_TECU` / `.peakLocalTime_h` | diurnal VTEC truth | off |
| `errors.ionosphere.topsideFraction` or `.topside.*` | uplink column fraction `f_seen` | 1.0 |
| `errors.ionosphere.model.correction` | `biasFraction` \| `klobuchar` | `biasFraction` |
| `errors.ionosphere.model.klobuchar.{amplitude_ns,period_h,dc_ns}` | Klobuchar parameters | — |
| `errors.ionosphere.higherOrder.enable` | 2nd/3rd-order residual | off |
| `effects.ionosphere.mappingModel` / `.shellHeight_m` | `simpleSecant` \| `thinShell` | `simpleSecant` |
| `errors.ionosphere.scintillation.model` | `legacy` \| `conker` (S4 amplitude fading → R) | `legacy` |
| `errors.ionosphere.scintillation.S4zen` | zenith S4 index | — |
| `errors.ionosphere.scintillation.phaseScint.{enable,sigmaPhi_rad,tau_s}` | time-correlated phase jitter → truth carrier | off |

## Before / after (evidence)

Running `run_oo_v1.m` (with `useRealisticAtmosphere = true`) writes two log-scale PNGs
(`atmosphere_residuals_time.png`, `..._elevation.png`) into the run folder; the acceptance
test `test_realistic_atmosphere_residuals` asserts the same contrast:

| Quantity | Matched default | Realistic atmosphere |
|----------|-----------------|----------------------|
| Troposphere residual RMS | **0.000 m** | 0.11 m (0.43 m @5° → 0.04 m @85°, ~1/sin e) |
| Ionosphere residual RMS (1st order, single-freq) | **0.000 m** | ~1.7 m (diurnal, peaks 14:00 LT) |
| Ionosphere 2nd/3rd order RMS | 0 | ~1.6 cm (survives IF) |
| Ionosphere truth (zenith) | constant | 0.5 → 5.2 m diurnal swing |

## Verification

New tests (all pass; run via `tests/run_all_tests.m`):
`test_niell_mapping_function`, `test_saastamoinen_zhd`, `test_troposphere_structural_residual`,
`test_ionosphere_truth_realism`, `test_klobuchar_correction`, `test_scintillation_gated`,
`test_realistic_atmosphere_residuals`. They verify mapping functions vs published values, the
ZHD constant, first-order dispersion `(f1/f2)²`, thin-shell obliquity, the Conker amplitude
factor and time-correlated phase jitter, exact-zero when truth ≡ model and non-zero otherwise,
the no-oracle property, the `sameAsTruth` rejection, and the physical residual bands.

**Regression:** every commit keeps the Stage-85 golden byte-identical
(`run_oo_v1_regression('smoke')` — 183/183, `rtol = 1e-9`). The new physics is strictly opt-in;
`masterConfig`'s default (matched `simpleMapped`) is untouched.

## Ionosphere handling & accuracy (run_oo_v1 `ionosphereHandling`)

Three ways to handle the (now honest) ionosphere, selectable in `run_oo_v1.m`:

| Mode | Mechanism | Cost | When it helps |
|------|-----------|------|---------------|
| `'single'` | raw dual-frequency L1+L2 | iono partly absorbed into the receiver clock | default |
| `'ionosphereFree'` | L1/L2 IF combination (`codeMode='ionosphereFree'`) | **halves code rows, ×2.98 noise** | many redundant ranging sources |
| `'ekfState'` | per-tower slant-iono EKF states (`estimation.ionosphereMode='perTowerSlant'`) | +1 state/tower | measurement-rich geometry |

**Finding (single-asset, 5-tower scenario):** the IF combination is correctly implemented
(cancels first-order iono to machine precision) but *degrades* absolute position (~28 m →
~130 m) because it discards half the code information in a geometry that is already
measurement-starved, and the ionosphere is largely clock-absorbed (position ≈ clock). The
`ekfState` prototype correctly estimates the slant iono (states converge from a 5 m prior to
~0.15 m 1-σ, estimating ~0.4–2.4 m/tower) but likewise does not recover *absolute* position,
because position here is **geometry/clock-limited, not iono-limited**. Both iono-removal
methods are sound; the binding constraint is the number of independent tower ranges. IF/
`ekfState` pay off in measurement-rich geometries (more towers), or for relative/attitude
solutions where the ionosphere is not clock-absorbable.

Two IF **diagnostics** were also fixed (they misreported the IF path, not the filter): the
postfit recompute now re-applies the IF combination (postfit ≤ prefit), and the reported code
residual is finite under IF (`'ifCode'` rows are counted).

## Not yet implemented (follow-up)

- **Doppler phase-scintillation rate.** The phase jitter is injected on the truth carrier;
  the corresponding truth-side Doppler perturbation (`δf_d = φ̇/(2π)`) is not yet added to the
  Doppler builder. Straightforward to add behind the same `phaseScint` flag.
- **Full IS-GPS-200 Klobuchar geometry** (broadcast α/β coefficients + geomagnetic pierce
  point). The current model uses the half-cosine algorithm with supplied amplitude/period,
  adequate for a feasibility study.

## Verified physics reference table

| Quantity | Value | Source |
|----------|-------|--------|
| Ionospheric delay per TECU (L1 / L2) | 0.162 m / 0.267 m | 40.308e16/f²; Kaplan & Hegarty; Misra & Enge |
| IF coefficients (L1/L2) | c1 = +2.5457, c2 = −1.5457 | c1+c2=1, c1/f1²+c2/f2²=0 |
| Saastamoinen constant / sea-level ZHD | 0.0022768 m/hPa / 2.307 m | Davis et al. 1985 |
| Thin-shell obliquity M(5°) (h=350 km) | 3.04 | Klobuchar 1987 geometry |
| Niell m_h(5°) / m_w(5°) (lat 45) | 10.13 / 10.75 (vs 1/sin=11.47) | Niell 1996 |
| Klobuchar RMS removal | ≥ 50 % | Klobuchar 1987; IS-GPS-200 |
| 2nd-order iono after IF | 0–2 cm, ∝ f⁻³ | Bassiri & Hajj 1993; IERS Conventions |
| ZWD correlation time (corrected) | hours to tens of hours (~3–24 h), **not** 0.5–2 h | PPP literature; FOGMP ≈ 20 h |
