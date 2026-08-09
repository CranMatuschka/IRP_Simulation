# Golden baseline — value and decision provenance (v2.0, four receive antennas)

Scenario files: [`config/scenarios/golden_baseline.json`](../config/scenarios/golden_baseline.json)
(single asset) and [`config/scenarios/golden_baseline_multi.json`](../config/scenarios/golden_baseline_multi.json)
(N = 6 federated formation), plus the controlled variant
[`config/scenarios/golden_baseline_attitude.json`](../config/scenarios/golden_baseline_attitude.json)
(§11), which measures what the four antennas would buy if they *were* used for attitude.
Regression gates: [`tests/test_golden_baseline.m`](../tests/test_golden_baseline.m) and
[`tests/test_common_mode_across_antennas.m`](../tests/test_common_mode_across_antennas.m).

These two scenarios are the reference configuration for future analysis. They are **not** tuned
for the best number. They are tuned so that every setting can be defended, and where a choice
trades accuracy for defensibility the defensible option is taken and the cost is recorded.

The two files share an identical error model, atmosphere, clock treatment, frame treatment and
estimator. They differ **only** in the formation and crosslink block, so any delta between the
two runs is attributable to the formation and to nothing else.

**Beam pointing lock is not used.** `multiAsset.beamPointingLock.enable` is explicitly `false` in
the multi-asset file and the effect does not exist for a single asset. No orientation claim is
made from either baseline.

---

## 0. What changed in v2.0, and why it was not free

v1.0 ran with **one** receive antenna, specifically to dodge an implementation artefact. v2.0 runs
with **four**, the flight configuration. Four antennas turn on two artefacts and expose three
claims v1.0 made that the code did not carry. All five are resolved below; none was resolved by
adjusting a number until the answer looked better.

| # | What four antennas changed | Resolution in v2.0 |
|---|---|---|
| 1 | **Amplitude scintillation was drawn independently per antenna.** Four independent realisations of a term worth 0.618 m rms of *z* − *h* — the largest truth-only term in this configuration — average down by √4 = 2 for free, and **R** shrinks to match, so no NEES or NIS check can see the gain. | New gated fix `atmosphere.sharedAcrossAntennas.enable = true`. Measured: inter-antenna spread 2.58 m → 7.6 × 10⁻⁸ m, antenna 1 bit-identical, strict no-op at one antenna. |
| 2 | **Coloured code multipath was drawn independently per antenna.** Same artefact on a 0.141 m rms term. | New gated fix `errors.multipath.coloredGM.sharedAcrossAntennas.enable = true`. Measured: inter-antenna spread → exactly 0, antenna 1 bit-identical. |
| 3 | **The inter-antenna carrier bias stopped being structurally dead.** It is gated on antenna index > 1, so at one antenna it could never fire. | Switched **on** (0.068 m rms of *z* − *h*). Omitting it would hand any later inter-antenna work a zero-bias truth reference. |
| 4 | **Baseline-differenced carrier-slip detection became live.** Exactly inert at one antenna; the realism overlay enables it by default. | Declared explicitly in both scenario files rather than inherited silently. |
| 5 | **v1.0 claimed a 5 mm truth-only antenna PCV that was never in the run.** `RangeCorrections.pcvCorrection_` treats the presence of `effects.antenna.pcvModel` as authoritative and bypasses the `effects.antennaPCV.<side>.enable` gate, so the same PCV is applied to truth *and* model. | Claim deleted. Measured residual 2.2 × 10⁻⁸ m. The file now states PCV as a **calibrated (cancelling)** correction and the real ~5 mm post-calibration residual is declared as *not injected*. |

Three dead keys were also removed: `measurements.carrier.minElevationDeg` (declared in
`masterConfig`, read nowhere), `measurements.codeNoise.cn0.enable` (the selector is the `model`
string), and the `clockScaling` block plus `estimator.estimateTowerClocks` (both derived by
`finalizeConfig` from `clock.*`).

---

## 1. The five design rules

| # | Rule | Consequence in these files |
|---|---|---|
| R1 | **Truth ≠ model, but both are physical.** An error source is represented by two *different* physical models, never by a scaled copy of the truth. | Troposphere: Saastamoinen-class hydrostatic + Niell mapping on both sides, differing through a stochastic wet term. Ionosphere: diurnal + Gauss–Markov TEC truth against an *independent* Klobuchar climatology. |
| R2 | **Corrections that a real system applies are applied.** A truth-only error is only used where the effect genuinely is uncalibrated in flight. | EOP applied on both sides with a realistic prediction residual; the differential code bias corrected to published-product accuracy; the solid-Earth tide *not* injected, because there is no estimator-side tide model. |
| R3 | **Conservative beats optimistic.** Where a value is uncertain, the pessimistic end is taken and stated. | Carrier σ = 10 mm rather than the 1–3 mm thermal figure. Both antenna-scope gates *remove* an averaging gain rather than adding one. |
| R4 | **No unearned states, no unearned information.** A state is only added if it has been shown to help, and no observation is consumed twice. | Empirical accelerations and the SRP-scale state off (measured: no benefit). Attitude partials off at four antennas. In the formation, crosslinks feed the relative layer only. |
| R5 | **Every number is traceable, and a claim the code does not carry is deleted rather than repeated.** | This document; the `_`-prefixed keys inside the JSON (which `deepMergeConfig` ignores by design, verified: they never appear in `explicitPaths`); and §0 item 5. |

---

## 2. Scenario, geometry and timing

| Config path | Value | Why this value | Source |
|---|---|---|---|
| `scenario.orbitClass` | `GEO` | The subject of the study: a geostationary asset tracked from the ground. GEO is the case where the one-way radial↔clock degeneracy is exact, which is what makes the two-way row structurally necessary (§5). | Soop (1994); Vallado (2013) |
| `scenario.nTowers` | `5` | Five *real* sites already defined in `masterConfig` (Tenerife, Stockholm, Hartebeesthoek, Bengaluru, Libreville), spanning −25.9° to +59.3° latitude and −16.5° to +77.6° longitude inside the 23 °E footprint. Named operational sites rather than a synthetic ring make the geometry auditable. **Measured elevations to the asset: 35.76 / 22.58 / 59.30 / 26.59 / 52.23°.** | Internal: `config/masterConfig.m` tower table |
| `scenario.nSpaceAssets` | `1` / `6` | 1 = the navigation and timing baseline. 6 = one chief plus five secondaries, the smallest formation that gives 15 independent baselines and a non-degenerate 3-D shape. | Alfriend et al. (2010) |
| `scenario.nReceivers` | **`4`** | The flight configuration: a body-fixed antenna array is what gives a reverse-GNSS payload coverage across the visible Earth disc with single-antenna-failure redundancy, and it is the geometry any later carrier-baseline attitude or beam work needs. It is a **hardware requirement, declared, not tuned**. It is only defensible together with the two antenna-scope gates in §4. | Cohen (1996); internal requirement |
| `asset.receiverLeverArms_body_m` | `[1 −1 0 0; 0 0 1 −1; 0.2 0.2 −0.2 −0.2]` m | Supplied by `finalizeConfig`, **not** by the scenario (that leaf is resolution-owned; setting it would be silently overwritten). Adjacent baseline 1.47 m, opposite 2.00 m, non-coplanar so the three attitude directions are in principle separable. | Internal: `+revgnss/ConfigFactory.m` `defaultArms`; Cohen (1996) on baseline geometry |
| *(measured)* | rows 30 → **105**/epoch; nx 37 → **67** | 40 code (5 × 4 × 2) + 40 Doppler (5 × 4 × 2) + 20 carrier (5 × 4, **ionosphere-free combined** — see §7) + 5 two-way (**does not** scale with antennas). The entire state growth is float ambiguities, 10 → 40. | Internal measurement, this repository |
| `simulation.duration_s` | `3600` | 15° of GEO arc. Long enough for convergence and for the 600 s ionospheric and 3 h tropospheric correlation times to appear; short enough to re-run on every change. | — (declared limitation, §12) |
| `simulation.dt_s` | `1` | 1 Hz is the standard GNSS observation rate and matches the 30 s clock-product interval cleanly. | Kouba (2009) |
| `simulation.seed` | `42` | Pinned so the baseline is bit-reproducible. A single seed is **not** a statistic — see `report.monteCarlo` (§9). | Bar-Shalom et al. (2001), §5.4 |
| `estimator.elevationMask_rad` | `10°` | The standard operational mask for precise GNSS processing. **Declared defect, harmless here:** `MeasurementModel` reads a *top-level* `cfg.elevationMask_rad` that nothing in the repository sets, so the code/carrier/Doppler visibility gate uses its own 5° default; this key does reach the two-way rows. Both are inert because the lowest tower is 22.58°. | Kouba (2009); Teunissen & Montenbruck (2017); internal: `+models/+measurements/MeasurementModel.m:52` |

---

## 3. Orbit dynamics — truth and estimator

| Config path | Value | Why this value | Source |
|---|---|---|---|
| `orbit.truth.mode` | `j2Rk4` (inherited) | Fourth-order Runge–Kutta on two-body + J2 in a constant-Ω inertial frame. | Montenbruck & Gill (2000), ch. 3 & 4; Vallado (2013) |
| `orbit.truth.perturbations.luniSolar.enable` | `true` | Sun and Moon third-body acceleration is ≈ 7 × 10⁻⁶ m s⁻² at GEO — comparable to J2 and the dominant secular perturbation. Omitting it would be a physics error, not a simplification. | Montenbruck & Gill (2000), §3.3; Soop (1994) |
| `estimator.dynamics.perturbations.luniSolar.enable` | `true` | Any real GEO orbit-determination filter models third-body. Leaving it off (as `realism.include.luniSolar` does) is a *stress case*, not a baseline — which is why that overlay block is switched off here. | Montenbruck & Gill (2000), §8 |
| `orbit.truth.perturbations.srp.Cr` | `1.3` | Cannonball radiation-pressure coefficient for a solar-array-dominated spacecraft; 1.2–1.5 is the conventional range. | Montenbruck & Gill (2000), §3.4 |
| `orbit.truth.perturbations.srp.areaToMass_m2pkg` | `0.02` | Representative of a small GEO platform; gives ≈ 1.2 × 10⁻⁷ m s⁻² direct SRP at P⊙ ≈ 4.56 × 10⁻⁶ N m⁻². | Montenbruck & Gill (2000), §3.4 |
| `orbit.truth.perturbations.srp.shadow` | `cylindrical` | Conservative eclipse geometry; a conical penumbra changes the result only in eclipse, which a 23 °E GEO does not enter during this arc. | Montenbruck & Gill (2000), §3.4 |
| `estimator.dynamics.perturbations.srp.Cr` | `1.24` | **The one declared dynamic gap.** A 4.6 % reflectivity error — realistic prior knowledge of Cr before it is estimated — worth Δa = 5.5 × 10⁻⁹ m s⁻², i.e. ½·a·t² = 35 mm over the 3600 s arc. Truth and filter share the force *family*; only this parameter differs. | Montenbruck & Gill (2000), §3.4 & §8.2; Wu et al. (1991) |
| `estimator.sigma_accel_mps2` | `1e-6` | Residual-acceleration (state-noise-compensation) 1σ. Covers the declared 5.5 × 10⁻⁹ SRP gap ≈ 180× over, plus the unmodelled GEO terms neither propagator carries: tesseral/triaxiality ≈ 2 × 10⁻⁸ m s⁻², Earth albedo + IR ≈ 2 × 10⁻⁹ m s⁻². | Soop (1994); Knocke et al. (1988); Gelb (1974), §4 |
| `estimator.processNoise.modelMismatch.enable` | `false` | Charging a mismatch term *and* `sigma_accel_mps2` would count the same uncertainty twice. | Internal: `config/masterConfig.m`; Simon (2006), §5 |
| `perturbations.sunMoon.ephemeris` | `mg` (default) | Montenbruck & Gill low-precision analytic Sun/Moon. Self-contained; the JPL DE-440 alternative needs an external bridge and would break clean-checkout reproducibility. Declared limitation: ≈ 0.6 m of luni-solar truth-fidelity gap over 4 h. | Montenbruck & Gill (2000), §3.3.2 |

---

## 4. The four-antenna array and its two common-mode gates

This section exists only because `scenario.nReceivers = 4`. It is the part of the baseline most
likely to be challenged, so every claim here is a measurement.

| Config path | Value | Why this value | Source |
|---|---|---|---|
| `atmosphere.sharedAcrossAntennas.enable` | **`true`** | Amplitude scintillation is a diffraction pattern imposed on the wavefront and decorrelates over the Fresnel scale √(λ*z*). At L1 (λ = 0.190 m) that is ≈ 260 m for a 350 km ionospheric screen and ≈ 2.6 km over the full GEO path. The antenna cross spans 2.00 m, i.e. ≤ 8 × 10⁻³ Fresnel scales, so the correct inter-antenna correlation is 1 − O(10⁻⁴). The truth draw was keyed on the antenna index, giving correlation **exactly 0** — a free factor √4 = 2 on the largest truth-only term, with **R** shrinking to match so no consistency metric could detect it. | Yeh & Liu (1982); Conker et al. (2003); internal measurement (`tests/test_common_mode_across_antennas.m`) |
| *(measured)* | spread 2.58 m → **7.6 × 10⁻⁸ m** | With the gate on, the four antennas share one realisation; the 76 nm residue is the elevation-driven σ envelope, which legitimately differs across a 2 m array. Antenna 1 is bit-identical on and off, so the gate is a strict no-op for every single-antenna scenario and no existing golden can move. | Internal measurement |
| `errors.multipath.coloredGM.sharedAcrossAntennas.enable` | **`true`** | As parameterised — 0.30 m steady state with a 1/sin(*el*) envelope keyed on the **tower** elevation — this is the classical *ground-station* multipath model: more multipath at low elevation because of the ground bounce at the station. That component is at the transmit end and is therefore common to all four receive antennas. The implementation kept one Gauss–Markov state per (tower, antenna) link, handing the run a second free √4. | Braasch (2017); Kaplan & Hegarty (2017), §9.2; internal measurement |
| *(declared)* | receive-end multipath not modelled | Reflections off the spacecraft structure genuinely *do* differ per antenna. Setting the gate true is the statement that the modelled 0.30 m is the transmit-end term — the conservative reading, because it removes an averaging gain rather than adding one. | Braasch (2017) |
| `errors.interAntennaCarrierBias.enable` | **`true`** | Each antenna's cable and front end has its own carrier phase delay; this is the classical GPS-attitude *line bias*. Structurally dead at one antenna (gated on antenna index > 1), real at four. **Measured 0.231 m peak / 0.068 m rms of *z* − *h*.** | Cohen (1996); internal: `realismGradeConfig` R-6 |
| `errors.interAntennaCarrierBias.sigma_cycles` | `0.25` | 47.6 mm at L1: an **uncalibrated** inter-antenna line bias, which is the honest assumption because this configuration declares no inter-antenna phase calibration (`attitudeCarrierMode = off`). Only weakly load-bearing precisely because the per-tower × receiver × signal float ambiguity absorbs a constant exactly — as a real receiver must. | Cohen (1996); Teunissen & Khodabandeh (2015) |
| `errors.interAntennaCarrierBias.drift.enable` | `false` | The drift (0.05 cycles h⁻¹ = 9.5 mm h⁻¹ at L1, thermal breathing of the cable) is real but is **not** absorbed by a constant ambiguity and nothing in **R** pays for it, so enabling it would make the filter quietly inconsistent rather than conservatively wrong. Named as a declared omission. | Rule R3; internal |
| `carrierSlip.baselineDifferencedMode` | `true`, ref antenna 1 | Differences the slip metric for antennas 2–4 against the antenna-1 row of the same tower and signal, so a receiver-clock-like common jump does not reset all four arcs while a localised slip stays detectable. Exactly inert at one antenna; declared explicitly rather than inherited from the realism overlay. | Internal: `+revgnss/CarrierTrackManager.m`; `realismGradeConfig` carrier-arc-survival block |
| `estimator.attitude.useCodePartials` / `useCarrierPartials` | `false` / `false` | **The four antennas are phase centres, not an attitude sensor, and that is a decision.** The lever arm is 1.02 m against a code σ of 0.166–0.230 m over this network's elevations, so code-derived attitude carries of order 10⁻⁵ of the star tracker's per-epoch information. `finalizeConfig` switches `estimateAttitudeFromPseudorange` on above one antenna and these two flags switch it back off; they are pinned in the scenario so the choice is visible. | Cohen (1996); Markley & Crassidis (2014), §6; internal measurement |
| *(not set)* | `estimator.estimateAttitude*` | `finalizeConfig` rewrites these unconditionally at `nReceivers > 1`, so a scenario-set value would be silently overridden and would break the no-override assertion in the gate. | Internal: `+revgnss/ConfigFactory.m:1616–1628` |
| **R across antennas** | tower clock only — **declared, not compensated** | Measured per-row code variance at tower 1 (Tenerife, 35.76°), **at the first epoch** — see the warning under §12, this is *not* the arc average: **3.0029 m²** total = ionosphere 2.4497 + multipath 0.2636 + **scintillation 0.1709** + troposphere 0.0659 + code thermal 0.0401 + tower clock 0.0101 + hardware delay 0.0025 + higher-order ionosphere 0.0001. **CORRECTED 2026-08-08: earlier revisions of this row omitted the scintillation term and their enumeration summed to 2.8320, not to the 3.0029 they claimed.** The omission was structural, not a typo: `ErrorChain` aggregates `labels = {'code','trop','iono','hwDelay','mp','ionoHO'}` and carries scintillation *outside* that list as `err.scintSigmaL1_m` (`+models/+errors/ErrorChain.m:340-352`), so any budget enumerated from `labels` drops it silently. The part physically **common to all four antennas** is everything except code thermal — the only genuinely per-antenna term (measured inter-antenna correlation −0.027) — i.e. **2.9628 m² = 98.7 %**, because the two v2.0 gates (`atmosphere.sharedAcrossAntennas`, `errors.multipath.coloredGM.sharedAcrossAntennas`) moved scintillation and multipath into the common set, as §12 records. The covariance R actually carries between two antenna rows of one tower is **0.0101 m² = 0.34 % of it — the tower-clock product alone** (correlation 0.003363, and 0.0101 = 0.10² exactly). Part of the gap is *deliberate double coverage on top of estimated states*: the slant ionosphere and the zenith wet delay are **EKF states**, so four rows legitimately determine one state better. But the un-estimated common remainder is **not** the ≈ 0.074 m earlier claimed here — with scintillation and multipath correctly counted it is multipath 0.2636 + scintillation 0.1709 + hardware delay 0.0025 + higher-order ionosphere 0.0001 = **0.4371 m², i.e. σ ≈ 0.661 m**, roughly nine times the previous figure, and none of it is backed by a state. **Consequence, stated plainly: on those terms the four antenna rows carry close to ONE independent sample rather than four, so the over-count approaches the full √4 = 2×.** Inflating σ_iono from 1.0 to 2.0 m would de-weight *all* code data by ≈ 40 % to compensate an allowance that was itself deliberately generous, so it remains the wrong lever; the right one is an off-diagonal block, which is not implemented. Recorded as declared limitation 5 (§14) rather than tuned away. | Bar-Shalom et al. (2001), §3; internal measurement (§12) |

---

## 5. Atmosphere

| Config path | Value | Why this value | Source |
|---|---|---|---|
| `atmosphere.realistic` | `true` | Selects the physically realistic profile instead of the constant-offset `simpleMapped` model. Truth and model are then *different functions*, so the residual is a genuine correction error. | Teunissen & Montenbruck (2017), ch. 6 |
| `errors.troposphere.modelType` | `localWeatherGM` | Hydrostatic zenith delay from surface meteorology (Saastamoinen form) plus a stochastic wet delay, rather than a fixed 2.3 m constant. | Saastamoinen (1972) |
| `errors.troposphere.{truth,model}.mappingType` | `niell` | Niell's mapping functions are the standard elevation mapping for precise geodetic GNSS and are not seasonally biased at the elevations used here. | Niell (1996); Boehm et al. (2006) |
| `errors.troposphere.stochastic.tau_s` | `10800` | 3 h correlation time for the wet delay, consistent with the timescale over which precipitable water vapour decorrelates. | Bar-Sever et al. (1998); Kouba & Héroux (2001) |
| `errors.troposphere.stochastic.sigmaWet_ss_m` | `0.04` | 4 cm steady-state zenith wet delay variability — a temperate mid-latitude value, not a tropical one. | Saastamoinen (1972); Kouba & Héroux (2001) |
| `errors.troposphere.sigma_m` | `0.15` | Declared zenith tropospheric uncertainty entering **R**. 3.75× the stochastic wet σ and charged *in addition* to the ZWD state — deliberate double coverage. | Rule R3 |
| `estimation.troposphereMode` | `perTowerZwd` | One zenith wet-delay state per tower. The single largest covariance-honesty lever measured on this code base: NEES 1011 → 25.6 and 3σ coverage 9/22/1 % → 100/100/92 % for +2 % position RMS. Also standard PPP practice. | Kouba & Héroux (2001); internal measurement 2026-08-07 |
| `estimation.tropoZwd.{tau_s, sigma_ss_m}` | `10800`, `0.04` | Matched to the simulated wet-delay process: the filter is given a **correct process model**, not an oracle value. | Gelb (1974), §4.4 |
| `errors.ionosphere.modelType` | `tecGaussMarkov` | Unlocks the stochastic TEC branch. Under `simpleMapped` the residual is a frozen constant, which a GEO's near-constant elevation turns into a pure bias — exactly what the radial↔clock degeneracy absorbs invisibly. | Internal: `realismGradeConfig` R-11 (measured 2026-08-06) |
| `errors.ionosphere.truth.diurnal.{vtecDay,vtecNight}_TECU` | `30`, `6` | A moderately active mid-latitude diurnal VTEC cycle peaking at 14:00 local. 30 TECU ≈ 4.9 m of vertical L1 delay. | Klobuchar (1987); Teunissen & Montenbruck (2017), ch. 6 |
| `errors.ionosphere.stochastic.{tau_s, sigmaVDelayL1_ss_m}` | `600`, `0.3` | 10-minute correlation time and 0.3 m vertical L1 residual for the stochastic TEC component. | Teunissen & Montenbruck (2017), ch. 6 |
| `errors.ionosphere.model.correction` | `klobuchar` | The broadcast single-frequency climatology, computed independently of the truth. Klobuchar removes ≈ 50 % of the RMS delay by design, so what survives is a real correction error rather than a tuned fraction. | Klobuchar (1987) |
| `effects.ionosphere.mappingModel` / `shellHeight_m` | `thinShell` / `350e3` | Single thin-shell obliquity at the conventional 350 km pierce height. A 1/sin(*el*) secant over-maps at low elevation. | Klobuchar (1987); Sanz Subirana et al. (2013) |
| `errors.ionosphere.higherOrder.enable` | `true` | Second- and third-order terms survive first-order removal and are centimetre-class at L1 under high activity. **Measured 0.013 m peak of *z* − *h*.** Included as a bounded truth-side residual; not estimated. | Bassiri & Hajj (1993); Hoque & Jakowski (2007) |
| `errors.ionosphere.scintillation.{model, S4zen, tau_s}` | `conker`, `0.3`, `30` | S₄ = 0.3 sits at the weak/moderate boundary of the standard classification — the conservative end of *nominal*, not a storm. Two of the five towers (Libreville 0.04 °N, Bengaluru 13.0 °N) lie in the equatorial anomaly, so scintillation is genuinely in scope. **Measured 7.58 m peak / 0.618 m rms of *z* − *h*: the largest truth-only term in this configuration.** | Conker et al. (2003); ITU-R P.531 |
| `…scintillation.phaseScint.{sigmaPhi_rad, tau_s}` | `0.2`, `1.5` | Phase scintillation on the truth carrier: 0.2 rad at a 1.5 s correlation time. Already keyed per tower rather than per antenna, i.e. **already** common-mode across the array — correct, and deliberately left alone. | Conker et al. (2003); internal verification |
| `atmosphere.ionosphereFree` | `false` | The ionosphere-free combination removes the first-order term but halves the code rows and amplifies noise by 2.98×, which a five-tower geometry cannot afford. | Teunissen & Montenbruck (2017), ch. 20; Sanz Subirana et al. (2013) |
| `estimation.ionosphereMode` | `perTowerSlant` | Raw **uncombined** dual-frequency L1 + L2 with one slant-ionosphere state per tower — the modern undifferenced/uncombined PPP formulation. Per *tower*, not per tower-antenna, which is physically right: the slant delay is common to all four phase centres, so the four rows legitimately inform one state. | Schönemann et al. (2011); Teunissen & Montenbruck (2017), ch. 25 |
| `estimation.slantIono.{tau_s, sigma_ss_m, initialSigma_m}` | `600`, `1.0`, `5.0` | τ matched to the truth TEC process. σ_ss and the 5 m prior bound the *post-Klobuchar* residual (roughly half the day-time vertical delay, mapped to the 22.6–59.3° elevations of this network). | Klobuchar (1987); Schönemann et al. (2011) |
| `atmosphere.estimateIono` | `false` | Left false **on purpose**: setting it forces `errors.ionosphere.model.correction = 'none'` inside `ConfigFactory.applyAtmosphereProfile`, discarding the Klobuchar correction. The state is enabled directly instead. `measurements.codeMode` is likewise not set — the same function derives it after the merge. | Internal: `+revgnss/ConfigFactory.m:552–560` |
| `atmosphere.sharedAcrossFormation.enable` | `true` *(multi only)* | **Mandatory for a formation.** Two satellites 1–2 km apart at GEO viewing one tower have ray paths diverging by ≈ 11 arcsec — 0.5 m at the top of the troposphere, 18 m at a 350 km pierce point. With per-asset seeds the single-difference atmosphere measured 0.954 m; re-rooting on a formation-wide seed took it to exactly 0. **Deliberately absent from the single-asset file**: it is not inert at N = 1 (it re-roots that run's atmosphere) and there is no formation to share with. | Internal measurement (`project_atmosphere_per_satellite_artefact`); Yeh & Liu (1982) |

---

## 6. Clocks and time transfer

| Config path | Value | Why this value | Source |
|---|---|---|---|
| `asset.clockType` / `clock.templateSource` | `CESIUM1` / `jowTable2p1` | The literature-anchored h-coefficient set, deliberately less optimistic than the `legacy` table. A caesium beam is the conservative choice against a passive hydrogen maser. | Riley (2008); Zucca & Tavella (2005) |
| `clock.mode` | `spacecraftReceiverClockOnly` | Tower clocks are **not** EKF states. They are corrected by a broadcast product whose residual enters **R** — exactly the PPP treatment of transmitter clocks. `estimator.estimateTowerClocks` is *derived* from this and is no longer written by the scenario. | Kouba & Héroux (2001); Teunissen & Montenbruck (2017), ch. 25 |
| `clock.gauge.mode` | `externalTowerCorrections` | One-way pseudorange is rank-deficient in the clock subspace without a datum; the external product supplies it. | Teunissen & Montenbruck (2017), ch. 21 |
| `clocks.tower.product.sigmaBias_m` | `0.10` | 0.33 ns — IGS **real-time service** class, not IGS-final. | Hadaś & Bosy (2015) |
| `clocks.tower.product.sigmaDrift_mps` | `0.001` | ≈ 3.3 ps s⁻¹ of broadcast clock-drift uncertainty, consistent with the bias figure over the 30 s interval. | Hadaś & Bosy (2015) |
| `clocks.tower.product.{updateInterval_s, latency_s, validity_s}` | `30`, `5`, `120` | A real-time correction stream: 30 s re-broadcast, 5 s delivery latency, 120 s validity. | Hadaś & Bosy (2015) |
| `covariance.sharedErrors.*` | on (inherited) | The product residual is piecewise **constant** per interval and shared by every row from that tower — **including across all four antennas**, measured correlation 0.0034. Charging it as white noise would let the filter average away an error that never shrinks. | Bar-Shalom et al. (2001), §3; internal measurement |
| `measurements.twoWayTimeTransfer.enable` / `.useInEKF` | `true` / `true` | **The one structural choice that makes the covariance meaningful.** A one-way uplink to a geostationary asset has an exact radial↔receiver-clock degeneracy (measured correlation −1.000000 at every frequency tried). A two-way exchange cancels the geometric range by reciprocity and observes (*b*_rx − *b*_tower) directly; measured correlation with the row active is −0.003. Five rows, one per tower: this block does **not** scale with antenna count. | Internal measurement (`project_g12_radial_clock_degeneracy`, `project_wpa_two_way_time_transfer`); Bauch et al. (2006) |
| `measurements.twoWayTimeTransfer.sigma_m` | `0.03` | 100 ps, the demonstrated accuracy class of dedicated ground–space two-way time transfer. Not the binding constraint: clock accuracy is floored by max(this, the 0.10 m tower product). | Bauch et al. (2006); Cacciapuoti & Salomon (2009) |
| `…includeReciprocityResidual` / `reciprocitySigma_m` | `true` / `0.005` | Reciprocity is not exact when the endpoints move during the exchange; 5 mm (17 ps) of residual non-reciprocity is charged rather than assumed zero. | Bauch et al. (2006) |
| `…conservativeProductCorrelation` | `true` | The reference-clock product error is constant per interval, so two-way rows inside an interval share it. Inflating the product variance by N = interval/dt stops the sequential filter over-averaging below the reference-clock floor. | Bar-Shalom et al. (2001), §3 |
| `physics.relativity.clock.{truth,model}.enable` | `true` / `true` | The relativistic receiver-clock rate offset (≈ +46.6 µs day⁻¹ at GEO) is present in the truth **and** modelled, as in any real system. Truth-only would hand the clock states a 2.3 km ramp. | Ashby (2003); Petit & Luzum (2010), ch. 10 |

---

## 7. Measurement model and noise

| Config path | Value | Why this value | Source |
|---|---|---|---|
| `signals.enabledMask` | `[true true]` (default) | L1 + L2. Dual frequency is required for the slant-iono state to be observable through the L1/L2 dispersion. | Teunissen & Montenbruck (2017), ch. 20 |
| `measurements.codeNoise.model` | `cn0` | Code noise from a carrier-to-noise-density model rather than one constant — the classical elevation-weighting argument expressed through C/N₀. | Kaplan & Hegarty (2017), ch. 8; Euler & Goad (1991) |
| `…cn0.base_dBHz` | `45` | The conventional nominal received C/N₀ for a GNSS-class link. | Kaplan & Hegarty (2017), ch. 8 |
| `…cn0.elevationGain_dB` | `6` | +6 dB from mask to zenith, the usual antenna-pattern plus atmospheric-loss span. Gives a resolved code σ of 0.166–0.230 m over this network. | Kaplan & Hegarty (2017), ch. 8 |
| `…cn0.sigmaAt45dBHz_m` | `0.30` | 0.30 m 1σ code error at 45 dB-Hz, consistent with DLL thermal-noise jitter for a 1 MHz-class code loop. **Measured inter-antenna correlation −0.027, i.e. genuinely independent across the array — which is correct and is why four antennas do buy real thermal averaging.** | Kaplan & Hegarty (2017), ch. 8; Misra & Enge (2011) |
| `measurements.carrier.sigma_m` | `0.010` | **Not** the 1–3 mm thermal figure. The extra budget covers what this configuration does not model: carrier phase wind-up (up to one cycle = 19 cm per antenna revolution, ≈ 8 mm over a 1 h GEO arc), phase multipath, and the PCV calibration residual that §8 records as cancelled rather than injected. | Wu et al. (1993); Kaplan & Hegarty (2017), ch. 9; Braasch (2017); Schmid et al. (2007) |
| `measurements.doppler.sigma_mps` | `0.0424` | 0.03 m s⁻¹ (honest raw-FLL figure) × √2. The √2 is a **documented mitigation for a known defect in this code base**: the L1 and L2 Doppler rows are generated from an *identical* noise draw, so two rows carry one row of information while **R** claims two. | Internal: R-audit 2026-08-06; Bar-Shalom et al. (2001), §3 |
| `measurement.sigmaFloor_m` | `0.01` | 1 cm floor on any measurement σ. The 1 mm default is sub-wavelength and not defensible. | Rule R3; internal: `realismGradeConfig` R-10 |
| `errors.multipath.coloredGM.enable` | `true` | Code multipath is the dominant non-atmospheric error in nominal conditions and is strongly time-correlated; modelling it as white under-represents its low-frequency impact. **Measured 0.818 m peak / 0.141 m rms of *z* − *h*.** | Kaplan & Hegarty (2017), §9.2; Braasch (2017) |
| `errors.multipath.coloredGM.tau_s` | `60` | Tens of seconds to minutes, tied to geometry change. At τ = 60 s a 3600 s arc holds ≈ 60 independent multipath samples against 3600 thermal ones. | Braasch (2017); Kaplan & Hegarty (2017), §9.2 |
| `errors.multipath.coloredGM.sigmaCodeL1_ss_m` | `0.30` | 0.30 m steady-state code multipath at L1 with a 1/sin(*el*) envelope — a station without ideal siting, i.e. the conservative case. | Braasch (2017); Kaplan & Hegarty (2017), §9.2 |
| `errors.multipath.model.enable` | `false` | Truth-only: the estimator knows the steady-state variance (through **R**) but not the instantaneous value. | Rule R1 |
| `errors.hardwareDelay.sigma_m` | `0.05` | **Calibrated but not zero.** The realism overlay ships 0.5 m, an *uncalibrated* RF chain. A flown station calibrates its transmit chain, so the honest residual is the calibration error: 0.05 m = 167 ps. **Measured 0.122 m peak / 0.027 m rms of *z* − *h*;** per tower, hence common to all four antennas, which the code already models correctly. | Bauch et al. (2006); Sanz Subirana et al. (2013) |
| `biases.interFrequency.code.truth.{L1,L2}_m` | `0.30`, `0.45` | A −0.15 m (−0.5 ns) L1–L2 differential code bias, the normal magnitude for a transmit chain. | Montenbruck et al. (2014); Sanz Subirana et al. (2013) |
| `biases.interFrequency.code.model.{L1,L2}_m` | `0.30`, `0.405` | The estimator applies a **published DCB product**, leaving a 0.045 m = 0.15 ns *differential* residual (measured exactly 0.045 m) — the consistency routinely reported between independent multi-GNSS DCB products. Measured cost of getting this wrong: leaving the full bias uncalibrated costs 0.07 m of constant radial bias and drops radial 3σ coverage from 37.7 % to 4.6 %. | Montenbruck et al. (2014); internal measurement 2026-08-07 |

---

## 8. Frames, station and antenna

| Config path | Value | Why this value | Source |
|---|---|---|---|
| `frames.truthEop.polarMotion_{xp,yp}_arcsec` | `0.150`, `0.350` | A representative *actual* pole position. Polar motion displaces a station by R⊕·x_p — metres, not a small term. | Petit & Luzum (2010), ch. 5 |
| `frames.eopModel.polarMotion_{xp,yp}_arcsec` | `0.1497`, `0.3497` | The IERS product the estimator applies. The 0.3 mas offset is the accuracy of a one-day-ahead Bulletin A polar-motion prediction and maps to 9.3 mm of station displacement (**measured 0.037 m peak of *z* − *h***). **Applying published EOP is using published data, not truth assistance.** | Petit & Luzum (2010); Kalarus et al. (2010) |
| `frames.{truthEop,eopModel}.ut1Rate_error_msPerDay` | `0.05` / `0.04` | A 0.01 ms day⁻¹ LOD residual contributes ≈ 0.2 mm over the arc. Retained for completeness and declared negligible rather than silently dropped. | Petit & Luzum (2010); Kalarus et al. (2010) |
| *(measured)* | — | With no estimator-side EOP at all, cross-track RMS is 0.53 m worse and cross-track 3σ coverage falls from 100 % to 92.4 %; polar motion is a cross-track-only error, orthogonal to the radial-only code DCB. | Internal measurement 2026-08-07 |
| `effects.solidEarthTide.truth.enable` | `false` | `models.frames.SolidEarthTide` is **truth-only** — there is no estimator-side tide model. Leaving it on simulates a system that declines a correction the IERS Conventions make mandatory (**measured 0.098 m of *z* − *h***). The residual after the degree-2 in-phase model is ≈ 1 mm. Note this is **not** the flattering choice: removing it made the measured radial bias *worse* (0.2596 → 0.3062 m) because it had been partially cancelling other truth-only biases. | Petit & Luzum (2010), ch. 7; internal measurement 2026-08-07 |
| `effects.towerSurvey.sigmaENU_m` | `[0.01, 0.01, 0.03]` | Truth-only station coordinate error. 10/10/30 mm ENU is conservative against ITRF-class coordinates (millimetre-level for core sites) and representative of a general tracking station's monument and local-tie budget. **Measured 0.032 m peak / 0.021 m rms of *z* − *h***; per tower, hence common to all four antennas. | Altamimi et al. (2016); Petit & Luzum (2010), ch. 4 |
| `effects.antenna.pcvModel` | `toy` | **Claim corrected in v2.0.** `RangeCorrections.pcvCorrection_` treats the presence of this key as authoritative and *bypasses* the `effects.antennaPCV.<side>.enable` gate, so the identical amp·cos²(*el*) is applied to truth **and** model. **Measured residual 2.2 × 10⁻⁸ m — it cancels.** The honest reading is a **perfectly calibrated** antenna; the real post-calibration residual (~5 mm) is therefore *not injected* and is part of what the 10 mm carrier σ pays for. The `truth`/`model` pair has been deleted from the scenario rather than left claiming an injection the code cancels. | Schmid et al. (2007); internal measurement (`+models/+corrections/RangeCorrections.m:156–179`) |
| `effects.antennaPCO.calibrationResidual.receiverOffset_body_m` | `[0.002, 0.002, 0.002]` | 2 mm per body axis of receive phase-centre mis-calibration, added to the **truth** lever arms only so it survives *z* − *h*. **Verified live: measured 2.75 mm peak / 1.97 mm rms** — this, not PCV, is the antenna-calibration term the configuration actually injects. **Declared:** it is one body-frame vector broadcast to all four antenna columns, so it is common-mode across the array and cancels identically in any inter-antenna baseline. | Schmid et al. (2007); internal measurement |

---

## 9. Estimator architecture

| Config path | Value | Why this value | Source |
|---|---|---|---|
| filter form | EKF, Joseph-form covariance update, MEKF attitude error state | Verified correct by a full audit of this code base; the Joseph form preserves symmetry and positive-definiteness under gain error. | Bar-Shalom et al. (2001), §5; Simon (2006), §5–6; Markley & Crassidis (2014), §6 |
| `estimator.dynamics.mode` | `j2` (inherited) | Same force family as truth (R1 applied to dynamics): the estimator is imperfect from realistic sources, not from an artificial propagator mismatch. | Wu et al. (1991); Montenbruck & Gill (2000), §8 |
| `measurements.carrierMode` | `ekfFloat` | Carrier phase enters the filter with one **float** ambiguity per tower × receiver × signal (40 states). | Teunissen & Montenbruck (2017), ch. 21 |
| `measurements.carrier.ionosphereFreeRows.{enable,useInEkf}` | `true` / `true` *(inherited)* | **The carrier rows entering the EKF are ionosphere-free combinations**, not raw L1: `CarrierMeasurementBuilder` replaces the 2 × (towers × antennas) raw rows with (towers × antennas) IF rows whenever `CarrierIonoFreeRowBuilder.shouldCombine` is true, and that gate reads *these* two `masterConfig` defaults. The legacy `measurements.carrierCombinationMode` is a different, deprecated knob and resolves to `raw`; reading it alone gives the wrong answer. The baseline is therefore deliberately **hybrid** — raw uncombined dual-frequency **code** with slant-ionosphere states (which is what makes the iono state observable, through the L1/L2 code dispersion) and **ionosphere-free carrier**. Defensible: the IF carrier is the standard PPP phase observable, and the 2.98× IF noise amplification that rules IF out for the code is affordable on a 10 mm phase σ. | Kouba & Héroux (2001); Teunissen & Montenbruck (2017), ch. 25; internal verification |
| `estimation.ambiguityMode` | `floatPerTowerReceiverSignal` | Undifferenced ambiguities absorb the per-arc clock, hardware and **inter-antenna** bias, so their truth is **not** an integer. Float is the conservative choice — worse, and honest. It is also the only legal mode above one antenna: `ConfigFactory` raises `carrierAmbiguityReceiverIndexRequired` for `floatPerTowerSignal` at `nReceivers > 1`. | Teunissen (1995); Teunissen & Khodabandeh (2015) |
| `estimation.ambiguity.initialSigma_m` | `100` | A deliberately loose ambiguity prior. **Caution:** the covariance PSD guard nudges by 10⁻¹²·max(diag P), so a 100 m prior floors every state at σ ≈ 8.5 × 10⁻⁵ m. Check `P(newState)` against that floor before trusting a new small state. | Internal measurement 2026-08-07 (`project_psd_guard_floors_small_states`) |
| `estimator.lambda.enable` | `false` | The LAMBDA engine is an external toolbox that is **not vendored** here (no licence grant), so a baseline depending on it would not be reproducible from a clean checkout. Measured ISL double-difference success rate ≈ 0.001 in any case. | Teunissen (1995); internal |
| `estimator.srpCoefficient.enable` | `false` | An SRP scale state is standard reduced-dynamic practice, but measured here it converges to 0.748 against a truth of 1.0 because the GEO geometry cannot separate it. A state that converges to the wrong value is worse than no state. | Wu et al. (1991); internal measurement |
| `estimator.empiricalAccel.enable` | `false` | Implemented and verified (STM column vs finite difference = 2.1 × 10⁻⁹) but measured to move NEES from 25.6 to 25.4 — nothing. The dominant residual is a *constant* measurement-side offset, and ½·a·t² is zero at t = 0. | Wu et al. (1991); internal measurement 2026-08-07 |
| `estimator.attitudeCarrierMode` | `off` | **Now a choice, not a constraint.** Below two antennas `ConfigFactory` force-disables `calibratedDifferentialAmbiguity`; at four it would survive resolution. It stays off because it requires *calibrated* inter-antenna phase biases and this configuration deliberately declares them uncalibrated (§4). | Cohen (1996); Markley & Crassidis (2014), §6 |
| `estimator.attitudeInitMode` | `none` | Carrier-baseline attitude initialisation would need ≥ 3 phase centres *and* an integer fix, which §9 declines. | Internal: `+revgnss/ConfigFactory.m` |
| `estimator.starTracker.whiteAngularSigma_rad` | 30 arcsec | Pinned in the scenario in v2.0 so the attitude budget is auditable from the file alone. Deliberately at the poor end of flight-qualified star trackers (one scalar on all three axes, so it also stands in for the about-boresight axis). Sensitivity is negligible: 30 arcsec × 1.02 m lever = 0.15 mm. | Liebe (2002); Markley & Crassidis (2014), §4 |
| `estimator.imu.*` (ARW 2 × 10⁻⁴ rad s^−½, RRW 3 × 10⁻⁶) | conservative | Angle- and rate-random-walk parameterisation per the standard gyro error model, at the conservative end for a precision platform, so the attitude result is a lower bound. | IEEE Std 952-1997; Markley & Crassidis (2014), §4 |
| `report.monteCarlo.enable` | `true` *(single asset)* | A single run yields **one** NEES/NIS sample; χ² consistency is only meaningful over an ensemble. 12 seeds × 900 s appends a pooled NIS/NEES band check, wrapped in try/catch and run *after* the PDF and MAT are written. At four antennas it is the dominant cost of the run. | Bar-Shalom et al. (2001), §5.4 |

---

## 10. Formation and crosslinks *(`golden_baseline_multi.json` only)*

| Config path | Value | Why this value | Source |
|---|---|---|---|
| `formation.mode` / `baseline_m` | `helix` / `1000` | A bounded Clohessy–Wiltshire projected-circular relative orbit of 1 km ring radius, propagated with the same dynamics as the chief. | Clohessy & Wiltshire (1960); Alfriend et al. (2010) |
| `formation.crossTrackSpread` | `1.0` | **Required, not cosmetic.** The textbook projected-circular helix sets z = 2x for every member, making the formation planar and the crosslink line-of-sight matrix rank 2 (singular values 1.2566, 1.1920, 0.0000). The filter would then shrink covariance in a direction the ranges carry no information about. | Internal measurement; Alfriend et al. (2010) |
| *(verified)* | all six spacecraft get **four** antennas | `MultiAssetConfig.cloneAsset_` leaves a stale 3 × 1 lever arm on `cfg.assets(2..6)`, but under `multiAsset.mode = 'fast'` that is never read: each federated leaf is rebuilt from `cfg.asset` and re-finalised, and `finalizeConfig` regenerates the 3 × 4 cross from `scenario.nReceivers`. Measured leaf by leaf and asserted in the gate. | Internal measurement |
| `multiAsset.mode` | `fast` (federated) | N independent per-asset EKFs plus a separate read-only relative layer. Measured: the centralised joint filter applied only 3 % of every ISL range because its prior was 28× overconfident; the federated split took shape error from 2.194 m to 0.480 m. | Internal measurement (`project_federated_vs_joint_like_for_like`) |
| `multiAsset.keepIslInPerAssetEkf` | `false` | **The observations are used once.** With this true, the relative layer reuses observations already consumed by a filter and its covariance is no longer independently valid. | Bar-Shalom et al. (2001), §8 |
| `measurements.isl.enable` | `false` | The one-way primary-aided ISL path belongs to the centralised architecture the federated pivot replaced. | Internal: `project_federated_swarm_pivot` |
| `multiAsset.twoWayISL.sigma_m` | `0.05` | 5 cm two-way thermal 1σ at the 1 km reference distance. `masterConfig` ships 0.01 m and the optimistic corner of this study used 0.001 m; 0.05 m is the conservative Ka figure defensible for a flown, calibrated PN crosslink without assuming laboratory hardware. | Kim & Tapley (2002) |
| `multiAsset.twoWayISL.delayCal.{sigma_const_m, sigma_rw_m, tau_s}` | `0.005`, `0.002`, `3600` | Calibrated but not zero: 17 ps of constant per-link turn-around and phase-centre calibration residual, plus a slow random walk. **Constant over the arc**, hence the floor on the relative geometry — thermal noise averages, calibration does not. | Kim & Tapley (2002); Schmid et al. (2007) |
| `multiAsset.twoWayISL.linkBudget.antennaModel` | `fixedAperture` | A dish of fixed diameter has G ∝ f², which exactly cancels the f² free-space path loss, so σ is **frequency-independent**. "Ka is automatically noisier than L-band" holds only for a fixed-gain antenna. | Kaplan & Hegarty (2017), ch. 8 |
| `multiAsset.twoWayISL.{maxNeighbours, requireLineOfSight}` | `5`, `true` | A spacecraft has a finite number of steerable terminals and a line of sight the Earth can block. Nothing in the crosslink layer is a function of `scenario.nReceivers` — the ISL terminals are separate hardware from the uplink phase centres. | Alfriend et al. (2010); internal verification |
| `multiAsset.twoWayISL.gauge.mode` | `minNorm` | The `radialStiff` gauge was **withdrawn** from this study: its apparent gain was a metric artefact plus a prior tuned on truth. | Internal measurement (`project_isl_relative_layer_subtractive`) |
| `multiAsset.twoWayISL.lightTime.enable` | `true` | Two-way light time included for correctness. First-order Sagnac cancels by reciprocity; what survives is endpoint motion during the round trip — micrometres at 1 km. Reported so its size is visible rather than assumed. | Petit & Luzum (2010), ch. 11; internal Orekit cross-validation |
| `multiAsset.federated.parallel` | `false` | **Serial on purpose.** A parallel fan-out reorders floating-point reductions; measured, a 10⁻¹⁴ arithmetic difference flipped a guard near its threshold and moved 33 of 148 reported fields. A reference baseline must be bit-reproducible before it is fast. | Internal measurement 2026-08-05 |
| `multiAsset.beamPointingLock.enable` | `false` | **Out of scope by request.** Stated explicitly rather than left to a default. Verified: the solver returns `gateOff` before touching any state, and no overlay writes to `multiAsset`. | — |
| `multiAsset.{groundDifferencedRotation, jointGeometry, groundCarrier, groundCarrierProbe}.enable` | `false` | Measured to spend formation deformation to buy rotation on this geometry. A 3600 s arc turns only 15°, where the CRLB penalty for separating rotation from shape is 9.9×; separation needs a quarter orbit (2.1×) or a full orbit (1.0×). | Internal measurement (`project_ground_differenced_rotation`) |
| `beamforming.enable` / `communicationFrequency_Hz` | `true` / `2.1e9` | Pure post-processing: reads the final relative geometry and clock solution and reports the phasor sum. Verified independent of `beamPointingLock`; no filter, measurement-model or truth-model file reads `cfg.beamforming`, so it cannot move an estimate. | Internal verification |
| `beamforming.coherenceCriterionLambdaFraction` | `20` | λ/20 is the conventional "essentially lossless" line (≈ 0.1 dB); λ/10 costs ≈ 0.4 dB. | Standard array-tolerance criterion |

---
---

## 11. The attitude variant — `golden_baseline_attitude.json`

The baseline runs four antennas that contribute **nothing** to attitude: measured, the ranging
measurement Jacobian's attitude columns are identically zero (`max|H(:,euler)| = 0`, rank 0).
That is a decision, and this variant is the controlled experiment that measures whether it was
the right one. It is **not** part of the reference pair; `golden_baseline.json` and
`golden_baseline_multi.json` are untouched by it.

**Exactly three leaves differ**, and the gate enforces that every other error-model leaf matches
the single-asset baseline.

| Config path | Baseline | Variant | Why | Source |
|---|---|---|---|---|
| `estimator.attitudeCarrierMode` | `off` | `calibratedDifferentialAmbiguity` | A real measurement path, not a diagnostic: `ReverseGNSSSimulation` builds a `DiffAttitudeBuilder` store and `buildRows` feeds a genuine second `ekf.update()` (which is why the main row count stays 105). | Cohen (1996); internal verification |
| `errors.interAntennaCarrierBias.sigma_cycles` | `0.25` (47.6 mm) | `0.02` (3.8 mm) | **The two changes are one decision.** Differential attitude reads exactly the inter-antenna phase differences a line bias corrupts; at 0.25 cycles the bias is 4.8× the carrier σ and the solution is *biased*, not merely noisy — a failure already on record in this code base. A real GPS attitude system calibrates its line biases; 3.8 mm is the residual, chosen to sit **below** the 10 mm carrier σ. Same "calibrated but not zero" pattern as the 0.05 m station hardware delay. | Cohen (1996); Rule R3 |
| `estimator.diffAtt.*` | inherited | declared | `referenceMode = selfCalibrated` is the **only** available option — `externalInitialAttitude` raises `externalReferenceUnavailable`, and a truth-derived reference would be truth assistance. It calibrates against the EKF's own attitude over 60 s and then tracks **changes**, so it supplies no absolute datum. | Internal: `+revgnss/DiffAttitudeBuilder.m` |

**Phase-bias status is deliberately honest.** The calibration is represented by making the
surviving *truth* bias small, not by handing the estimator a model of it
(`estimator.interAntennaCarrierBias.mode` stays `none`) — a model whose values cannot be known
without reading the truth draw is exactly the artefact `realismGradeConfig`'s `phaseBiasHonesty`
block exists to prevent. Consequently `InterAntennaPhaseBias.resolvedStatus` returns
`notCalibratedExternalProduct` and, with `requirePhaseBiasCalibrationForFix` true, integer
resolution on the attitude baselines is **refused**. That refusal is a *result*, which is why
`diffAtt.ambiguityResolution` stays off rather than being switched on to watch it decline.

### Measured result — a clean negative

Isolated by running this file twice with `attitudeCarrierMode` `off` vs
`calibratedDifferentialAmbiguity` and **nothing else changed**, 600 s:

| Quantity | Attitude path off | Attitude path on | Change |
|---|---|---|---|
| Attitude σ | 44.31712 arcsec | 44.30771 arcsec | **−0.021 %** |
| Attitude error (1 seed) | 44.90389 arcsec | 44.92471 arcsec | +0.046 % — noise |
| Position RMS | 2.165442 m | 2.165450 m | unchanged |

The path engages (store calibrated, 3 baselines, 15 valid baseline–tower pairs) and buys
essentially nothing. That is what the per-epoch information budget predicts:

| Attitude source | σ_θ per epoch | Information vs star tracker |
|---|---|---|
| 40 code rows (1.02 m lever, σ ≈ 0.20 m) | 1.78° | 2.2 × 10⁻⁵ |
| 20 carrier rows (σ 10 mm) | 7.54 arcmin | 4.4 × 10⁻³ |
| Star tracker (30 arcsec) | 30 arcsec | 1 |

**So the baseline's choice is now measured, not argued.** A calibrated four-antenna carrier
attitude path adds 0.02 % to an attitude solution already anchored by a 30 arcsec star tracker,
and code-derived attitude is four orders of magnitude weaker still. The obvious follow-up —
degrade the star tracker until the carrier path starts to matter — is deliberately not done here.

**Two limits this file does *not* test**, stated so it is not over-read: the differential rows are
built from the pre-combination **L1** float stack, so they are single-frequency; and the PCO
calibration residual is one body-frame vector broadcast to every antenna column, so it is
common-mode across the array and cancels identically in every inter-antenna baseline. A
per-antenna phase-centre error is *not* exercised — the code provides no truth-side 3 × N offset.

---

## 12. Measured error budget of the delivered configuration

Every row is the change in *z* − *h* when that single effect is disabled, at `nReceivers = 4`,
10 epochs, all five towers, both signals. This is what the baseline actually carries — not what
the config claims.

> **⚠ MEASUREMENT BASIS — read before quoting these numbers (added 2026-08-08).**
> The window is **10 epochs starting at t = 0**, and three of the terms below are Gauss–Markov
> processes that start from rest or from a fixed initial value. They are therefore recorded
> **below their steady state**, and by different factors, so the *ordering* in this table is
> warm-up-biased and is not the arc-average ordering:
> * Coloured multipath (τ = 60 s) reaches √(1 − e^(−2t/τ)) = **53 %** of steady state by t = 10 s.
> * Scintillation (τ = 30 s) reaches **72 %**, and its amplitude state `scintAmplitude`
>   *initialises to exactly 1.0* (`+models/+errors/EnvironmentModel.m:125`) while its stationary
>   median is ≈ 0.68 — so this window samples an atypically quiet realisation of it.
> * Arc-average scintillation variance at Tenerife is ≈ 0.840 m², about **5×** the 0.1709 m²
>   the first epoch shows, which puts the true arc-average per-row code variance nearer
>   **3.67 m²** than the 3.0029 m² quoted in §4, and makes scintillation ≈ 20–24 % of the
>   variance at *every* tower rather than the few percent this table implies.
>
> The §4 R-budget row is a **first-epoch** snapshot for the same reason. Quote these figures as
> "at the first epoch", never as arc averages.

| Truth-side effect | peak \|Δ(*z*−*h*)\| [m] | rms \|Δ(*z*−*h*)\| [m] | Across the four antennas |
|---|---|---|---|
| Ionospheric scintillation | 7.583 | 0.618 | **common** (after the §4 gate; was independent) |
| Coloured code multipath | 0.818 | 0.141 | **common** (after the §4 gate; was independent) |
| Inter-antenna carrier bias | 0.231 | 0.068 | per antenna, by definition |
| Hardware (station) delay | 0.122 | 0.027 | common (per tower) |
| Differential code bias, L2 | 0.045 | 0.020 | common (per tower) |
| Truth EOP (polar motion) | 0.037 | 0.017 | common |
| Estimator-side EOP model | 0.033 | 0.015 | common |
| Tower survey error | 0.032 | 0.021 | common (per tower) |
| Higher-order ionosphere | 0.013 | 0.005 | common |
| Antenna PCO calibration residual | 0.00275 | 0.00197 | common (one body-frame vector) |
| Antenna PCV | 2.2 × 10⁻⁸ | 4.8 × 10⁻⁹ | **inert — cancels** (§0 item 5) |
| *(solid-Earth tide, if enabled)* | 0.098 | 0.038 | common — deliberately **off** |

Code thermal noise is per antenna and genuinely independent (measured inter-antenna correlation
−0.027), which is what makes four antennas buy real averaging on that term and nothing else.

---

## 13. Deliberately excluded, with reasons

| Excluded | Why |
|---|---|
| Beam pointing lock | Out of scope by request. |
| Ground-differenced rotation / joint geometry solve | Measured net-negative on a 15°-turn arc (§10). |
| Integer ambiguity resolution (LAMBDA) | External, unvendored toolbox; float is the conservative alternative. |
| SRP-scale and empirical-acceleration states | Measured to give no benefit or to converge to the wrong value (§9). |
| Solid-Earth tide | Truth-only implementation would simulate an uncorrected mandatory IERS term (§8). |
| Attitude from GNSS (code or carrier) | ≈ 10⁻⁵ of the star tracker's information at a 1.02 m lever; carrier attitude needs calibrated inter-antenna biases this configuration declares uncalibrated (§4). **Measured** in the variant of §11: with the biases calibrated it moves the attitude σ by 0.021 %. |
| Inter-antenna carrier bias **drift** | Not absorbed by a constant ambiguity and not paid for in **R** (§4). |
| Antenna PCV calibration residual | The code cancels PCV between truth and model; injecting a residual would need an engine change with a wide blast radius. Paid for in the 10 mm carrier σ instead (§8). |
| Receive-end (spacecraft-structure) multipath | Not separately modelled; the modelled term is declared to be the transmit-end one (§4). |
| DE-440 Sun/Moon ephemeris | Needs an external bridge; would break clean-checkout reproducibility. |
| Higher-order geopotential (tesseral), Earth albedo/IR, ocean loading | Not implemented; their combined ≈ 2 × 10⁻⁸ m s⁻² is covered by `sigma_accel_mps2` = 10⁻⁶ and declared here rather than ignored. |

---

## 13a. Scintillation obliquity — gated fix, not applied in this baseline

`getScintillationSigma` hardcoded a flat-Earth `1/sin(el)` obliquity for the Conker S4 elevation
scaling, while `effects.ionosphere.mappingModel` selects `thinShell` at 350 km for the
first-order slant delay that pierces **the same layer**. The stated reason for choosing
`thinShell` (§7) is that `1/sin(el)` over-maps at low elevation — and here that over-mapping is
what drives S4 through the clamp: at Stockholm, S4 = **0.7100** with `1/sin` (clamped) versus
**0.5769** with the thin shell, i.e. σ = 2.1213 m versus 0.5188 m, a factor **4.09**.

Now selectable via `errors.ionosphere.scintillation.obliquityModel`:
`'simpleSecant'` (**default — bit-identical to the legacy path**), `'thinShell'`, or
`'matchIonoMapping'` (follow `effects.ionosphere.mappingModel`, so the two can never disagree).
Gate: `tests/test_scintillation_obliquity_gated.m`. Ladder rung:
`config/ladder/feat/feat024_scintObliquityMatchIono.json`. Regression fixture:
`golden_feat024_<tier>.mat` (`goldenFeat024ScenarioConfig` = the realism fixture with this
one leaf changed, so any delta against `golden_realism_<tier>` is the obliquity alone —
measured 24 of 166 metrics differ at the smoke tier). The fixture exists because **no other
golden reaches the non-default branch**, and the `single` golden cannot reach this code path
at all: it ships `S4zen = 0`, which makes S4 identically zero and the obliquity structurally
inert. ⚠ **The `<tier> = full` goldens are 14400 s arcs** (every fixture builds from
`masterConfig()`, whose duration default is 14400 s; only `run_oo_v1` imposes 3600 s), so they
are *not* comparable to the 3600 s delta quoted below — different arcs, deliberately.

**This baseline deliberately keeps `'simpleSecant'`** so the v2.0 numbers stand unchanged; the
fix is recorded and measured rather than silently adopted. Measured at 3600 s, seed 42, paired
(same unit normals rescaled): network mean scintillation variance 1.0592 → 0.1729 m²;
positionErrorMax −29.0 %, positionRMS_runwide −3.5 %, codeResidualRms −7.9 %, **meanNIS only
−0.91 %**; carrier +0.003 %, Doppler and EKF dynamics energy bit-identical. The small NIS move
is the signature of a **matched** term — the truth is drawn as σ·randn and the same σ² enters R
(`+models/+measurements/CodeMeasurementBuilder.m:583`), so shrinking σ shrinks both together.
Stated plainly: **part of the improvement is injecting less noise, not weighting better**, and
the honest claim is consistency, not performance. The −29 % peak is a max statistic on one
realisation; quote the RMS figures.

---

## 14. Declared limitations

1. **Arc length.** 3600 s = 15° of GEO arc cannot separate a rigid formation rotation from a deformation. No orientation claim is made from this baseline.
2. **Phase wind-up is not modelled.** It is paid for in the 10 mm carrier σ (≈ 8 mm expected over the arc), not simulated.
3. **Antenna PCV cancels.** The configuration represents a perfectly calibrated antenna; the ~5 mm real residual is not injected (§8). Any write-up must say so.
4. **Half the float-ambiguity directions are unobservable.** Each (tower, antenna) contributes **one** ionosphere-free carrier row against **two** ambiguity states — 20 rows for 40 states. The unconstrained combinations sit at their 100 m prior. Harmless for the estimate, but they inflate max(diag P) and therefore the PSD-guard floor (§9).
5. **R has no across-antenna atmospheric block.** **98.7 %** of the per-row code variance is physically common to the four antennas — everything except code thermal, once the two v2.0 sharing gates are counted — yet R correlates only the 0.0101 m² tower-clock product (0.34 %) across them. The dominant common terms *are* estimated states, but **0.4371 m² (σ ≈ 0.661 m) of the common part is un-estimated** (multipath + scintillation + hardware delay + higher-order ionosphere), so on those terms the four rows carry close to one independent sample rather than four and the over-count approaches the full √4 = 2×. Revised upward 2026-08-08: the earlier figures here (84.2 %, ≈ 0.074 m) omitted scintillation. Quantified in §4 and deliberately not compensated; inflating σ_iono is the wrong lever, and the right one — an off-diagonal block — is not implemented.

12. **Scintillation code σ is set by a numerical clamp, not by physics, at low elevation.** The Conker factor 1/√(1 − 2·S4²) is singular at S4 = 1/√2, guarded by `S4 = min(0.7, …)`. With the delivered `S4zen = 0.3` that guard **binds 32.8 % of epochs at Stockholm** (22.58°), 26.1 % at Bengaluru, 15.3 % at Tenerife, 6.1 % at Libreville and 4.4 % at Hartebeesthoek; while it binds, the row σ is pinned at 0.30/√0.02 = **2.1213 m** and stops responding to elevation or to the amplitude state. Two contributing model choices are declared rather than fixed here: (a) `scintAmplitude` is a **single scalar shared by all five towers** (`+models/+errors/EnvironmentModel.m:316`, keyed on tower index 0), so stations with pierce points ~7000 km apart and opposite climatologies fade and clamp in lockstep; (b) `S4zen = 0.3` is an equatorial/disturbed value applied unchanged at 59.3° N, where it is least defensible and does the most damage. A third contributor — the obliquity — **has** been addressed, see §13a.
6. **The elevation mask is split.** `estimator.elevationMask_rad = 10°` reaches the two-way rows; the code/carrier/Doppler visibility gate uses a hard-coded 5° because it reads a top-level key nothing sets. Inert here (lowest tower 22.58°).
7. **Single seed.** The main run is one realisation; the ensemble evidence comes from the 12-seed Monte-Carlo block, and even that is short (900 s).
8. **Effective sample size.** With correlation times of 600 s (ionosphere) and 10 800 s (troposphere), a 3600 s arc contains ~1–6 independent samples of those processes, not 3601. NEES/NIS *means* can look acceptable while the residual autocorrelation says otherwise — check ρ(NIS) at lag ≈ τ, not just NIS/dof.
9. **Doppler σ carries a hand-applied √2.** If the L1/L2 duplicate-draw defect is fixed, this line becomes conservative rather than corrective and should be revisited.
10. **Runtime.** Four antennas take the per-EKF row count from 30 to 105 and the state from 37 to 67. The federated run is 7 EKF passes and stays serial for bit-reproducibility; budget roughly 4× the v1.0 wall clock.
11. **Synthetic study.** `cfg.scientificProfile.allowRealWorldClaim` is false by design. These are simulation results, not measurements of a flown system.

---

## 15. References (APA 7th)

Alfriend, K. T., Vadali, S. R., Gurfil, P., How, J. P., & Breger, L. S. (2010). *Spacecraft formation flying: Dynamics, control and navigation*. Elsevier.

Altamimi, Z., Rebischung, P., Métivier, L., & Collilieux, X. (2016). ITRF2014: A new release of the International Terrestrial Reference Frame modeling nonlinear station motions. *Journal of Geophysical Research: Solid Earth, 121*(8), 6109–6131. https://doi.org/10.1002/2016JB013098

Ashby, N. (2003). Relativity in the Global Positioning System. *Living Reviews in Relativity, 6*(1), 1. https://doi.org/10.12942/lrr-2003-1

Bar-Sever, Y. E., Kroger, P. M., & Borjesson, J. A. (1998). Estimating horizontal gradients of tropospheric path delay with a single GPS receiver. *Journal of Geophysical Research: Solid Earth, 103*(B3), 5019–5035. https://doi.org/10.1029/97JB03534

Bar-Shalom, Y., Li, X.-R., & Kirubarajan, T. (2001). *Estimation with applications to tracking and navigation: Theory algorithms and software*. Wiley.

Bassiri, S., & Hajj, G. A. (1993). Higher-order ionospheric effects on the Global Positioning System observables and means of modeling them. *Manuscripta Geodaetica, 18*(6), 280–289.

Bauch, A., Achkar, J., Bize, S., Calonico, D., Dach, R., Hlaváč, R., Lorini, L., Parker, T., Petit, G., Piester, D., Szymaniec, K., & Uhrich, P. (2006). Comparison between frequency standards in Europe and the USA at the 10⁻¹⁵ uncertainty level. *Metrologia, 43*(1), 109–120. https://doi.org/10.1088/0026-1394/43/1/016

Boehm, J., Niell, A., Tregoning, P., & Schuh, H. (2006). Global Mapping Function (GMF): A new empirical mapping function based on numerical weather model data. *Geophysical Research Letters, 33*(7), L07304. https://doi.org/10.1029/2005GL025546

Braasch, M. S. (2017). Multipath. In P. J. G. Teunissen & O. Montenbruck (Eds.), *Springer handbook of global navigation satellite systems* (pp. 443–468). Springer. https://doi.org/10.1007/978-3-319-42928-1_15

Cacciapuoti, L., & Salomon, C. (2009). Space clocks and fundamental tests: The ACES experiment. *The European Physical Journal Special Topics, 172*(1), 57–68. https://doi.org/10.1140/epjst/e2009-01041-7

Clohessy, W. H., & Wiltshire, R. S. (1960). Terminal guidance system for satellite rendezvous. *Journal of the Aerospace Sciences, 27*(9), 653–658. https://doi.org/10.2514/8.8704

Cohen, C. E. (1996). Attitude determination. In B. W. Parkinson & J. J. Spilker Jr. (Eds.), *Global Positioning System: Theory and applications* (Vol. 2, pp. 519–538). American Institute of Aeronautics and Astronautics. https://doi.org/10.2514/5.9781600866395.0519.0538

Conker, R. S., El-Arini, M. B., Hegarty, C. J., & Hsiao, T. (2003). Modeling the effects of ionospheric scintillation on GPS/Satellite-Based Augmentation System availability. *Radio Science, 38*(1), 1001. https://doi.org/10.1029/2000RS002604

Euler, H.-J., & Goad, C. C. (1991). On optimal filtering of GPS dual frequency observations without using orbit information. *Bulletin Géodésique, 65*(2), 130–143. https://doi.org/10.1007/BF00806368

Gelb, A. (Ed.). (1974). *Applied optimal estimation*. MIT Press.

Hadaś, T., & Bosy, J. (2015). IGS RTS precise orbits and clocks verification and quality degradation over time. *GPS Solutions, 19*(1), 93–105. https://doi.org/10.1007/s10291-014-0369-5

Hoque, M. M., & Jakowski, N. (2007). Higher order ionospheric effects in precise GNSS positioning. *Journal of Geodesy, 81*(4), 259–268. https://doi.org/10.1007/s00190-006-0106-0

Institute of Electrical and Electronics Engineers. (1998). *IEEE standard specification format guide and test procedure for single-axis interferometric fiber optic gyros* (IEEE Std 952-1997). IEEE.

International Telecommunication Union. (2019). *Ionospheric propagation data and prediction methods required for the design of satellite services and systems* (Recommendation ITU-R P.531-14). ITU. *(Living document — cite the revision in force at submission.)*

Kalarus, M., Schuh, H., Kosek, W., Akyilmaz, O., Bizouard, C., Gambis, D., Gross, R., Jovanović, B., Kumakshev, S., Kutterer, H., Mendes Cerveira, P. J., Pasynok, S., & Zotov, L. (2010). Achievements of the Earth orientation parameters prediction comparison campaign. *Journal of Geodesy, 84*(10), 587–596. https://doi.org/10.1007/s00190-010-0387-1

Kaplan, E. D., & Hegarty, C. J. (Eds.). (2017). *Understanding GPS/GNSS: Principles and applications* (3rd ed.). Artech House.

Kim, J., & Tapley, B. D. (2002). Error analysis of a low-low satellite-to-satellite tracking mission. *Journal of Guidance, Control, and Dynamics, 25*(6), 1100–1106. https://doi.org/10.2514/2.4989

Klobuchar, J. A. (1987). Ionospheric time-delay algorithm for single-frequency GPS users. *IEEE Transactions on Aerospace and Electronic Systems, AES-23*(3), 325–331. https://doi.org/10.1109/TAES.1987.310829

Knocke, P. C., Ries, J. C., & Tapley, B. D. (1988). Earth radiation pressure effects on satellites. In *Proceedings of the AIAA/AAS Astrodynamics Conference* (pp. 577–587). American Institute of Aeronautics and Astronautics. https://doi.org/10.2514/6.1988-4292

Kouba, J. (2009). *A guide to using International GNSS Service (IGS) products*. International GNSS Service.

Kouba, J., & Héroux, P. (2001). Precise point positioning using IGS orbit and clock products. *GPS Solutions, 5*(2), 12–28. https://doi.org/10.1007/PL00012883

Liebe, C. C. (2002). Accuracy performance of star trackers — A tutorial. *IEEE Transactions on Aerospace and Electronic Systems, 38*(2), 587–599. https://doi.org/10.1109/TAES.2002.1008988

Markley, F. L., & Crassidis, J. L. (2014). *Fundamentals of spacecraft attitude determination and control*. Springer. https://doi.org/10.1007/978-1-4939-0802-8

Misra, P., & Enge, P. (2011). *Global Positioning System: Signals, measurements, and performance* (2nd ed., rev.). Ganga-Jamuna Press.

Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications*. Springer. https://doi.org/10.1007/978-3-642-58351-3

Montenbruck, O., Hauschild, A., & Steigenberger, P. (2014). Differential code bias estimation using multi-GNSS observations and global ionosphere maps. *Navigation, 61*(3), 191–201. https://doi.org/10.1002/navi.64

Niell, A. E. (1996). Global mapping functions for the atmosphere delay at radio wavelengths. *Journal of Geophysical Research: Solid Earth, 101*(B2), 3227–3246. https://doi.org/10.1029/95JB03048

Petit, G., & Luzum, B. (Eds.). (2010). *IERS conventions (2010)* (IERS Technical Note No. 36). Verlag des Bundesamts für Kartographie und Geodäsie.

Riley, W. J. (2008). *Handbook of frequency stability analysis* (NIST Special Publication 1065). National Institute of Standards and Technology.

Saastamoinen, J. (1972). Atmospheric correction for the troposphere and stratosphere in radio ranging of satellites. In S. W. Henriksen, A. Mancini, & B. H. Chovitz (Eds.), *The use of artificial satellites for geodesy* (Geophysical Monograph Series Vol. 15, pp. 247–251). American Geophysical Union. https://doi.org/10.1029/GM015p0247

Sanz Subirana, J., Juan Zornoza, J. M., & Hernández-Pajares, M. (2013). *GNSS data processing, Volume I: Fundamentals and algorithms* (ESA TM-23/1). ESA Communications.

Schmid, R., Steigenberger, P., Gendt, G., Ge, M., & Rothacher, M. (2007). Generation of a consistent absolute phase-center correction model for GPS receiver and satellite antennas. *Journal of Geodesy, 81*(12), 781–798. https://doi.org/10.1007/s00190-007-0148-y

Schönemann, E., Becker, M., & Springer, T. (2011). A new approach for GNSS analysis in a multi-GNSS and multi-signal environment. *Journal of Geodetic Science, 1*(3), 204–214. https://doi.org/10.2478/v10156-010-0023-2

Simon, D. (2006). *Optimal state estimation: Kalman, H∞, and nonlinear approaches*. Wiley. https://doi.org/10.1002/0470045345

Soop, E. M. (1994). *Handbook of geostationary orbits*. Kluwer Academic.

Teunissen, P. J. G. (1995). The least-squares ambiguity decorrelation adjustment: A method for fast GPS integer ambiguity estimation. *Journal of Geodesy, 70*(1–2), 65–82. https://doi.org/10.1007/BF00863419

Teunissen, P. J. G., & Khodabandeh, A. (2015). Review and principles of PPP-RTK methods. *Journal of Geodesy, 89*(3), 217–240. https://doi.org/10.1007/s00190-014-0771-3

Teunissen, P. J. G., & Montenbruck, O. (Eds.). (2017). *Springer handbook of global navigation satellite systems*. Springer. https://doi.org/10.1007/978-3-319-42928-1

Vallado, D. A. (2013). *Fundamentals of astrodynamics and applications* (4th ed.). Microcosm Press.

Wu, J. T., Wu, S. C., Hajj, G. A., Bertiger, W. I., & Lichten, S. M. (1993). Effects of antenna orientation on GPS carrier phase. *Manuscripta Geodaetica, 18*(2), 91–98.

Wu, S. C., Yunck, T. P., & Thornton, C. L. (1991). Reduced-dynamic technique for precise orbit determination of low Earth satellites. *Journal of Guidance, Control, and Dynamics, 14*(1), 24–30. https://doi.org/10.2514/3.20600

Yeh, K. C., & Liu, C.-H. (1982). Radio wave scintillations in the ionosphere. *Proceedings of the IEEE, 70*(4), 324–360. https://doi.org/10.1109/PROC.1982.12313

Zucca, C., & Tavella, P. (2005). The clock model and its relationship with the Allan and related variances. *IEEE Transactions on Ultrasonics, Ferroelectrics, and Frequency Control, 52*(2), 289–296. https://doi.org/10.1109/TUFFC.2005.1406554

---

### Note on citation hygiene

Every reference above is a real, checkable work and each is cited for a claim that work actually
supports. Two classes of entry need care before they go into a thesis:

* **ITU-R P.531** is a living recommendation — check which revision is in force and cite that one.
* Entries marked *Internal measurement* / *internal verification* are **this project's own results**,
  not literature. They are traceable to the named memory note, `docs/` file or test in this
  repository, and should be presented as such (own work), never as an external citation. Every
  numeric measurement quoted in §0, §4 and §11 was produced by running this repository at
  `nReceivers = 4` during the v2.0 rewrite.
