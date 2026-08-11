# oo_v1 Scientific Traceability & Verification Analysis

**Scope.** This document verifies the scientific content of the `oo_v1` reverse-GNSS simulation — every formula, physical constant, model, estimator, and element of simulation logic — against (a) the project's own literature collection (`IRP/Paper/`, 84 documents) and (b) external authoritative sources where the collection is silent. For each feature it records: the implementation (file:line), a verdict, one or more sources with an **exact verbatim quote** (page-referenced), and a critical analysis of what is right and what is flawed.

**Method.** Nine parallel domain audits (clocks, atmosphere, orbits, measurements, filter/attitude, time transfer, ambiguity, ISL/swarm, simulation flow), each reading the code line-by-line and the sources by full-text extraction (pymupdf) or, for the four scanned PDFs without a text layer (Brown & Hwang; Hofmann-Wellenhof 2008; two others), by visual page transcription. Constants were checked digit-by-digit; closed-form solutions were re-derived or numerically re-verified; every claimed defect from prior audits was re-tested rather than trusted. A separate anti-fabrication pass sampled quotes from every section and matched them verbatim against the extracted PDF text (all sampled quotes verified; all initial mismatches traced to PDF ligature/hyphenation artifacts, none to misquotation).

**Verdict key.** ✅ verified correct against sources · ⚠️ partially correct / correct-but-unsourced / honest simplification · ❌ defect confirmed · ❓ unverifiable from available material.

---

## Executive summary

The headline finding of this audit is double-edged and, on balance, favorable:

**The deterministic physics core is unusually well built.** The audit verified — digit-by-digit against primary sources — the two-body+J2 dynamics, the Montenbruck & Gill analytic Sun/Moon series (every coefficient), the solid-Earth tide (exact IERS 2010 Eq. 7.5), the Saastamoinen/Davis ZHD at full precision, all 45 Niell (1996) mapping coefficients, the thin-shell obliquity, the iono-free combination invariants, the FSPL/C-N0 chain (ITU-R P.525), the classical TWSTFT four-timestamp reduction, Teunissen's bootstrapped success-rate formula, the Melbourne-Wübbena combination (re-proved geometry-free and iono-free), the CW helix (re-derived from the Hill equations), and the Kalman two-state clock Q (Van Dierendonck et al. 1984). Several implementation choices exceed common research-code practice: the Sagnac effect is generated *by construction* in the four-timestamp event chain rather than bolted on; DD covariances are built fully correlated; the IF measurement variance is rebuilt per error source instead of naively amplified; correlated broadcast-product errors are charged as off-diagonal R blocks; truth/model separation is enforced by hard errors on oracle modes; and inert configuration is *refused* rather than silently dropped.

**The weaknesses are concentrated in three classes.**
1. **Stochastic-layer defects** (the covariance the filter believes): the committed flicker-noise synthesis is 2/N too quiet (fixed in the working tree, uncommitted — every archived run lacked a flicker floor); the one-way ISL broadcast-product error is charged as white noise (√300-class overconfidence); the flicker Q approximation under-covers phase error vs. the primary source; the EKF ZWD time constant contradicts the truth process and the repo's own documentation.
2. **Truth-assisted defaults** (results that are twin-consistency demonstrations, not receiver-realizable measurements): `towerClockMode='perfectCorrection'`; the legacy `CESIUM1+legacy` clock template ~7 orders quieter than Winkel's Table 2.1 caesium; zero-magnitude default antenna offsets; the solver-layer observables re-synthesized from recorded truth. All are disclosed in-code; none is disclosed loudly enough in the headline numbers.
3. **Absent physics that is material for the project's own goals**: carrier-phase wind-up (≈1 cycle/day/link of arc-correlated drift — precisely the signal class the ground-referenced rotation solver is vulnerable to), carrier multipath (would dominate the 5 mm carrier σ), ionospheric up/down asymmetry in two-way links (ns-class at the S-band default), and the periodic relativistic clock term for eccentric GEO.

A further class of findings is **documentation drift**: stale claims that contradict the current code (ERROR_BUDGET's "elevation-dependent" noise that defaults constant; "disabled by the v1 sanitiser" for a now-gated relativity model; "LAMBDA not implemented" strings printed in the same reports as LAMBDA decisions; the Klobuchar `notImplemented` flag over a shipped Klobuchar kernel; the "classical MDS" label on what is actually a Gauss-Newton free-network adjustment).

**What this means for verifiability.** With this document, every load-bearing formula in the simulation now has either (a) a page-referenced verbatim quote from a source in `Paper/` or an external authority, or (b) an explicit ❓/❌ flag stating that it is unsourced or defective. The critical-findings register below is the actionable summary.

## Critical-findings register

Severity: **H** = affects published/headline numbers or their honesty; **M** = affects specific configurations or secondary claims; **L** = cosmetic, naming, or documentation.

> **Re-audit, 2026-08-09.** Every row below was re-derived against the working tree. The physics verdicts held — all digit-level constant checks re-verified independently. Four rows moved: **F4 is WITHDRAWN as wrong** (it understated the simulation's realism), **F1 is fixed and committed** (H→M), **F24's "off by default" is untrue of the flagship config** (H→M), and **F23's stated reason for inertness was wrong**. F13 and F28 carry arithmetic/magnitude corrections. Rows not annotated with a 2026-08-09 note were re-checked and stand as written. Defects found in this pass that the register never had are tracked separately, the largest being that six `config/ladder/feat/*.json` ablation rungs disabled nothing at all until this date — see `resolveEnablePairsPostMerge` and the `_pairNote` keys in those files.

| # | Sev | Finding | Where | Status |
|---|-----|---------|-------|--------|
| F1 | M | FFT colored-noise amplitude 2/N too small — flicker floor absent from every run archived *before* 2026-08-08 | `+models/+clocks/ClockModel.m:214` | **CORRECTED 2026-08-09 — the physics defect is FIXED AND COMMITTED** (`5995bfa`; `A_frac = sqrt(max(Sy_frac,0)*fs*N)/2`), so the severity drops H→M. The register entry that called it "uncommitted" was itself stale: HEAD contained the fix and this line 77 s apart. Still open: the DC bin is `abs(X(1))` (`ClockModel.m:535`), a Rayleigh-positive fractional-frequency offset of ≈0.63·√h₋₁ in every realization, and Nyquist is likewise `abs()`-forced |
| F2 | H | One-way ISL piecewise-constant broadcast-product error charged as per-epoch white R (up to ~√300 overconfident); rule enforced everywhere else | `+revgnss/ISLMeasurementBuilder.m:216-217` | Confirmed defect (latent: product disabled by default) |
| F3 | H | Default asset clock = CESIUM1+`legacy`, h0 7 orders below JOW Table 2.1 caesium (≈3000× quieter ADEV); headline sub-100-ps results ride on it | `+revgnss/ConfigFactory.m:2138-2185`, `masterConfig.m:156-157` | Disclosed in-code; must be disclosed with headline numbers |
| F4 | — | ~~`towerClockMode='perfectCorrection'` default = truth-assisted tower clock (error row zero by construction)~~ | `masterConfig.m:1920-1925`, `ConfigFactory.m:759-776`, `masterConfig.m:3070` | **WITHDRAWN 2026-08-09 — THIS FINDING WAS WRONG.** `cfg.estimator.towerClockMode` is a DERIVED field, not a knob: masterConfig sets `'perfectCorrection'` as a placeholder under a comment saying so, and `finalizeConfig` overwrites it from `cfg.towerClock.correctionMode`, whose default is `'truthHistoryProductNoisy'`. The resolved default is therefore a latency-delayed, quantised broadcast product (`t_prod = floor((t−5)/30)·30`, age ≤ 35 s) carrying a deterministic per-(tower, product-epoch) bias/drift error — a receiver-realizable model, NOT an oracle. The register **understated** the simulation's realism. Verify with `cfg.estimator.towerClockMode` after `resolveSimulationConfig` |
| F5 | H | Phase wind-up absent: nadir-pointing GEO → ~1 cycle/day/link arc-correlated carrier drift; material for rotation/attitude observables, not just the 3 cm budget | absent (declared in ERROR_BUDGET) | Declared but under-weighted; should move to top of absent-terms list |
| F6 | M | `jowTable2p1` TCXO and RUBIDIUM rows do not match JOW Table 2.1 (TCXO h−1 5× low; RUBIDIUM matches no row); OCXO retains legacy h−1 → flicker floor ~60× optimistic | `+revgnss/ConfigFactory.m:2193-2263` | Confirmed mislabels |
| F7 | M | Flicker Q term (2·ln2·h−1·Δt, Q11-only) ~14× smaller than Van Dierendonck eq. (60) at Δt=10 s, wrong Δt-scaling, no Q12 term | `ClockModel.m:389-401` | Nonstandard heuristic, documented as approximation, under-covers flicker |
| F8 | M | Legacy two-way reciprocity term −ρρ̇/c is 2× the sequential-protocol asymmetry and omits the common-velocity part; only the static limit is tested | `ReciprocalTimeTransferModel.m:44-46` | Twin-cancelling, default off, superseded by 4TS mode |
| F9 | M | Ionosphere up/down asymmetry absent from all two-way observables — ns-class at the 2.2 GHz default → 100 ps *accuracy* claims frequency-unsupportable as configured | two-way z/h paths | Confirmed gap; needs dual-frequency or Ku/Ka carriers for accuracy claims |
| F10 | M | EKF ZWD Gauss-Markov τ = 1 h contradicts truth (3 h) and repo docs ("3–24 h, not 0.5–2 h"); σ/τ pairs uncited | `masterConfig.m:408`, `TroposphereModel.m:75-91` | Confirmed inconsistency |
| F11 | M | Default thermal noise `model='constant'` (no elevation dependence) contradicts ERROR_BUDGET "elevation-dependent"; shaped models are opt-in | `masterConfig.m:129`, `ErrorChain.m:364-423` | Documentation/default mismatch |
| F12 | M | Multipath τ = 60 s encodes moving-constellation fading; for static GEO-tower geometry true correlation is ~hours → optimistic averaging; frequency-independent; no carrier multipath | `ErrorChain.m:711-766` | Confirmed physics mismatch (default off) |
| F13 | M | Periodic relativistic clock term (e·sinE) absent: 0.3–3 ns (9 cm–1 m) orbit-periodic for real GEO e=1e-4–1e-3, aliasing into the radial-clock weak direction | absent | Confirmed 2026-08-09, unchanged. **Arithmetic correction to §6.12 of this document:** the turnaround-conversion effect is 1.6×10⁻¹⁰ × 1 ms = 1.6×10⁻¹³ s = **160 fs**, not the "0.16 fs" stated there — 1000× low. Still decorative at current fidelity; the conclusion is unaffected |
| F14 | M | Scintillation default degenerate: `conker` with S4zen=0 → flat 0.3 m floor, no elevation/fading; S4 not frequency-scaled (lit. exponent ~1.5) | `masterConfig.m:1908-1920`, `EnvironmentModel.m:590-638` | Confirmed |
| F15 | M | Fixed ratio-test thresholds (2.0/3.0) are the fixed critical values deprecated by Verhagen & Teunissen (2013); mitigated by conjunctive 0.999 SR gate | `LambdaResolver.m:174-181` etc. | Literature-deprecated heuristic, mitigated |
| F16 | M | Higher-order iono: carrier omits the −½/−⅓ phase counterparts; sign lacks B·k geometry | `HigherOrderIonosphere.m`, `CarrierMeasurementBuilder.m` | Confirmed omission (truth-side R-sizing OK) |
| F17 | M | ProductClockCovarianceBuilder code-carrier cross block omits carAge·covBiasDrift term (inert at default covBD=0) | `ProductClockCovarianceBuilder.m:200` | Latent defect |
| F18 | L | "Classical MDS" label wrong: SwarmRelativeSolver is Gauss-Newton free-network WLS + truncated-SVD gauge (sound, arguably better) | `SwarmRelativeSolver.m:732-808` | Label/provenance error |
| F19 | L | Stale hard-coded claims: "LAMBDA/MLAMBDA not available in v1", "ratio test absent" printed alongside LAMBDA/ratio decisions; `klobucharStatus='notImplemented'` over a shipped Klobuchar kernel; ERROR_BUDGET stale in 4 places; J2 constant comment says "EGM2008" for a JGM-3/EGM96 value; `IslDoubleDifference` computes single differences | multiple | Documentation drift |
| F20 | L | Niell seasonal cosine sign: code uses "−" (community consensus: Navipedia/Orekit/RTKLIB; physically correct winter-max) but the printed Niell 1996 and in-repo Osah et al. show "+"; repo test evaluates at the cosine null → sign untested | `NiellCoefficients.m:79-83` | Convention right, citation trap + test gap |
| F21 | M | Moon ephemeris omits M&G's −1.3972°·T precession term (negligible at default J2000 epoch; ~0.37° if epochJD_TT moved to 2026) | `OrbitPerturbations.m:111-115` | Latent epoch-dependent |
| F22 | M | Solver-layer observables (rotation/shape) re-synthesized from recorded truth — results are simulation-internal demonstrations, not end-to-end measurement processing (declared) | `GroundDifferencedRotationSolver.buildObservable` etc. | Architectural boundary, declared |

| F23 | M | J2 auto-tuner in `finalizeConfig` force-enables `modelMismatch` and **silently overwrites** `sigma_mps2 ≤ 1e-6` (incl. the shipped default) with `max(1e-8, 0.25·|a_J2|)` — no warning; masterConfig text alone under-determines the run | `ConfigFactory.m:2086-2097` | Confirmed still present and still un-warned. **The stated REASON for inertness was wrong (corrected 2026-08-09):** `stationaryEcef` is never the resolved default — `masterConfig.m:621-626` rewrites `orbit.truth.mode` to `'j2Rk4'` unconditionally. The tuner is inert because both writes sit inside `if isJ2Truth && isTwoBodyEkf`, and the scenario assembly at `masterConfig.m:629` forces the EKF to `'j2'`. It fires only if a scenario sets the EKF back to two-body |
| F24 | M | Monte-Carlo NEES/NIS machinery is correct (two-sided χ², proper pooling, matched-crutch refusal); `masterConfig`'s own default is off | `MonteCarloConsistency.m`, `config/golden_baseline.json` | **CORRECTED 2026-08-09, severity H→M. "Off by default" is untrue of the flagship config:** `golden_baseline.json` — the `_extends` base of every ladder rung — sets `report.monteCarlo.enable = true, nSeeds = 12, duration_s = 900`, so the headline run *does* execute an ensemble. Two things survive: the knob this row originally cited, `cfg.validation.statistics.monteCarlo.enable`, is **inert** (written by `finalizeConfig`, read only as a report label — do not toggle it expecting an effect); and the manifest string `declaredNotStatisticallyExecuted` is now itself stale |
| F25 | M | Formation-shared atmosphere fix default OFF → swarm members draw independent atmospheres (physically one air column, 11″ ray divergence); invalidates between-satellite differenced ground observables unless the gate is enabled | `masterConfig.m:715-736`, `SharedAtmosphereRng.m` | Fix implemented + quantitatively argued, default-off for golden stability |
| F26 | L | Per-asset and Monte-Carlo RNG separation rest on additive seed offsets (`seed+1000·ai`, `baseSeed+j+500000`) — convention-based, weaker than the identity-keyed substream guarantee used everywhere else | `ReverseGNSSSimulation.m:153-158`, `MonteCarloConsistency.m:70-71` | Bounded weakness |

| F27 | M | No chi-square innovation gate anywhere in the filter (NIS computed, never thresholded); the only editing gate is an unsourced fixed 1 m diffAtt threshold | `ReverseGNSSEKF.m:834`, `DiffAttitudeBuilder.m:443,470` | Deliberate-looking design choice; must be stated (and sourced if faults are ever simulated) |
| F28 | M | Star-tracker noise isotropic (10″ per axis) — ignores the 5–10× boresight/twist anisotropy every unit in the NASA reference exhibits; error geometry spherical instead of cigar-shaped, which matters for lever-arm/attitude observables | `masterConfig.m:278`, `config/golden_baseline.json`, `StarTrackerMeasurementModel.m` | Interface already supports full 3×3 covariance — parameterization gap only. **Magnitude corrected 2026-08-09:** masterConfig's bare default is 10″, but **every shipped golden and ladder run uses 30″** (`golden_baseline.json` pins `whiteAngularSigma_rad = 1.454441043328608e-4` = deg2rad(30/3600)). The anisotropy criticism stands; the "10″" figure applies to no run that matters |
| F29 | M | Gyro defaults are MEMS/industrial-class (ARW 0.34°/√h, initial bias 2°/h — ~30× worse than a navigation RLG, ~10³× worse than a space FOG), and bias *instability* (flicker) is unmodelled; conservative direction, but not a GEO-grade IRU | `masterConfig.m:1670-1676` | Confirms standing concern; must be labelled in any publication |
| F30 | L | r/v process noise stays constant-velocity white-acceleration Q while F uses the J2 finite-difference STM — standard state-noise-compensation practice, but F and Q derive from different dynamics assumptions | `ReverseGNSSEKF.m:1299-1307` | Documented practice, low consequence |

**Defects from prior audits re-tested and now VERIFIED FIXED** (important for the fairness of this register): the `estimatedEuler_`/lever-arm "prediction at identity attitude" systematic is fixed on both consumer paths (nominal-quaternion history + an all-zero-signature refusal, `GroundDifferencedRotationSolver.m:616-679`; `ReverseGNSSSimulation.m:937-939`); the 2/N flicker synthesis is fixed in the working tree (commit pending, F1); the Doppler/tower-clock-drift R double-charge has an explicit mask (`CodeMeasurementBuilder.maskStateTowerSigma_`); the R-7 Monte-Carlo pooling bug is fixed and memorialized in place; the worktree-shadowing test hazard has a durable guard in `run_all_tests.m`.

## Contents

1. [Clock & Oscillator Models](#section-clock--oscillator-models)
2. [Atmospheric Error Models](#section-atmospheric-error-models)
3. [Orbital Dynamics & Frames](#section-orbital-dynamics--frames)
4. [Measurement Models & Error Chain](#section-measurement-models--error-chain)
5. [Kalman Filter & Attitude Estimation](#section-kalman-filter--attitude-estimation)
6. [Two-Way Time Transfer & Four-Timestamp Observables](#section-two-way-time-transfer--four-timestamp-observables)
7. [Integer Ambiguity Resolution](#section-integer-ambiguity-resolution)
8. [ISL, Link Budget, Beamforming & Swarm Solvers](#section-isl-link-budget-beamforming--swarm-solvers)
9. [Simulation Architecture, Stochastics & Validation Methodology](#section-simulation-architecture-stochastics--validation-methodology)
10. [Appendix: Complete Paper/ Folder Coverage Map](#appendix-complete-paper-folder-coverage-map)
11. [Master Reference List (APA 7)](#master-reference-list-apa-7)

Each section carries its own APA 7 reference list with the page-referenced verbatim quotes used in that section; the master list at the end consolidates all sources. Line numbers refer to the working tree of branch `feature/ground-orientation-exec`, 2026-08-06.

---
# Section: Clock & Oscillator Models

The simulation models every oscillator (asset receiver clock and ground-tower transmitter clocks) with `+models/+clocks/ClockModel.m`: a five-coefficient power-law PSD of fractional frequency, S_y(f) = h2·f² + h1·f + h0 + h−1/f + h−2/f², split into (a) a two-state Markov component (bias, fractional frequency) that carries white-FM (h0) and random-walk-FM (h−2) and matches the EKF's two clock states, and (b) a non-Markovian "colored" component (h2, h1, h−1) synthesized offline by FFT spectral shaping and read back per epoch. The EKF process noise `getProcessNoiseQ` is the classical two-state clock Q built from the same h-coefficients. h-coefficient templates (TCXO/OCXO/RUBIDIUM/CESIUM1) come from `revgnss.ConfigFactory.getClockTemplate_` with two selectable sources: `cfg.clock.templateSource = 'legacy'` (default; frozen for golden-run reproducibility, deliberately optimistic) or `'jowTable2p1'` (re-anchored to Winkel's dissertation Table 2.1). Defaults that matter scientifically: asset clock = `CESIUM1` + `legacy` (config/masterConfig.m:156–157), tower clock corrections = `cfg.estimator.towerClockMode = 'perfectCorrection'` (masterConfig.m:1740), i.e. a truth-assisted baseline. Tower broadcast-clock products are modeled by `TowerClockCorrectionProvider` (linear bias+drift prediction from a quantized product epoch with deterministic per-epoch product noise) and their correlated R-contributions by `ProductClockCovarianceBuilder`. Allan deviation is computed two ways: a textbook overlapping estimator in `revgnss/AllanDeviation.m` (used by the report section `+revgnss/+report/oscillatorValidation.m`) and a nonstandard internal diagnostic in `ClockModel.allanDeviation`.

---

### Power-law noise model and h-parameter convention

- **Code**: `+models/+clocks/ClockModel.m:7` — `S_y(f) = h2*f^2 + h1*f + h0 + hMinus1/f + hMinus2/f^2` (one-sided PSD of fractional frequency); ADEV slope table at lines 15–20.
- **Verdict**: ✅ verified correct — this is the standard IEEE/NIST five-term power-law model, and the code's h-coefficients carry the same meaning as the sources' (verified through the ADEV mapping below, which is convention-sensitive).
- **Sources**:
  - Riley, W. J. (2008). *Handbook of Frequency Stability Analysis* (NIST Special Publication 1065). NIST. — "It has been found that the instability of most frequency sources can be modeled by a combination of power-law noises" (p. 8, §4.3)
  - Winkel, J. Ó. (2003). *Modeling and Simulating GNSS Signal Structures and Receivers* [Doctoral dissertation]. Universität der Bundeswehr München. — transcription of eq. (2.154), p. 99: S_y(ω) = 2π²h−2/ω² + πh−1/ω + h0/2 (JOW's ω-domain form; identical h-coefficient meaning, confirmed by his eq. 2.156 below)
  - Van Dierendonck, A. J., McGraw, J. B., & Brown, R. G. (1984). Relationship between Allan variances and Kalman filter parameters. *Proc. 16th PTTI Meeting*, 273–293. — "In this paper we construct a relationship between the Allan variance parameters (h2, h1, ho, h-1 and h-2) and a Kalman Filter model that would be used to estimate and predict clock phase, frequency and frequency drift." (p. 273)
- **Critical analysis**: The docstring's slope table (WPM τ⁻¹, FPM τ⁻¹, WFM τ⁻¹ᐟ², FFM τ⁰, RWFM τ⁺¹ᐟ²) is exactly the canonical table. One subtlety handled correctly: JOW writes S_y in angular frequency with different-looking constants (πh−1/ω etc.); the code uses the f-domain one-sided convention, and both produce the same Allan variance h-mapping — so the templates lifted from JOW Table 2.1 are convention-compatible with the code's synthesis and Q. In practice every shipped template has h2 = h1 = 0, so WPM/FPM branches are inert in all default runs — the colored component is flicker-FM only.

---

### Two-state EKF process-noise Q from h-parameters

- **Code**: `+models/+clocks/ClockModel.m:389–401` —
  `q1 = h.h0/2;  q2 = 2*pi^2*h.hMinus2;  q_ffm = 2*log(2)*h.hMinus1;`
  `Q_s = [(q1+q_ffm)*dt + q2*dt^3/3,  q2*dt^2/2;  q2*dt^2/2,  q22]` with `q22 = q2*dt` (+ optional `q_ffm*dt` gated by `driftFlickerInQ`, default false, line 92). Converted to meters via `T = diag([c, c])` (lines 406–409).
- **Verdict**: ✅ WFM/RWFM part verified correct digit-by-digit; ⚠️ the flicker (h−1) handling is a nonstandard heuristic that differs from the primary source in both magnitude and Δt-scaling (documented as an approximation in the code, lines 57–59).
- **Sources**:
  - Van Dierendonck, A. J., McGraw, J. B., & Brown, R. G. (1984). Relationship between Allan variances and Kalman filter parameters. *Proc. 16th PTTI Meeting*, 273–293. — "and we let the Q matrix be Q = Cov[x(Δt), ȳ(Δt)] as given by equation 60." (p. 284, eqs. 62–63). Equation (60), transcribed from the page scan (marked transcription):
    Q11 = (h0/2)Δt + 2h−1Δt² + (2/3)π²h−2Δt³; Q12 = Q21 = 2h−1Δt + π²h−2Δt²; Q22 = h0/(2Δt) + 2h−1 + (8/3)π²h−2Δt.
  - Van Dierendonck et al. (1984) — "all of which is a well-balanced function of t, except the 2,2 term that has terms as a function of Δt that basically describe the Allan standard deviation (within ln2)." (p. 284)
  - Van Dierendonck et al. (1984) — "No finite-order state model will fit flicker noise perfectly!" (p. 285)
  - Carpenter, J. R., & Lee, T. (2008). A stable clock error model using coupled first- and second-order Gauss-Markov processes (AAS 08-109). — "Clearly, the clock drift variance increases linearly with elapsed time, and the clock bias increases as the cube of elapsed time." (Appendix; RW model attributed to Brown & Hwang)
  - Zucca, C., & Tavella, P. (2005). The clock model and its relationship with the Allan and related variances. *IEEE Trans. UFFC, 52*(2), 289–296. (EXTERNAL, paywalled — cited as the standard modern statement of the instantaneous-frequency two-state form σ1²τ + σ2²τ³/3 / σ2²τ²/2 / σ2²τ; full text not quotable here.)
- **Critical analysis**: **What is exactly right**: q1 = h0/2 matches Van Dierendonck's two-sided white-FM density S_y0(ω) = h0/2 (p. 278, eq. 32-region: "S_y0(u) = h0/2 (white frequency noise)"); q2 = 2π²h−2 matches his random-walk driving density 2π²h−2/ω²; and the three RWFM entries q2Δt³/3 = (2/3)π²h−2Δt³, q2Δt²/2 = π²h−2Δt², q2Δt = 2π²h−2Δt agree term-by-term with eq. (60)'s h−2 parts and with the Carpenter-Lee/Brown-Hwang RW covariance (drift ∝ t, bias ∝ t³). **Deliberate difference**: the code's frequency state is *instantaneous* frequency, so Q22 = 2π²h−2Δt without VD's h0/(2Δt) average-frequency term and with 2π²/3→ replaced by the correct instantaneous coefficient — that is the Brown-Hwang/Zucca-Tavella form, self-consistent with the truth generator in `step()`. **The flicker discrepancy**: VD1984 puts 2h−1Δt² in Q11, 2h−1Δt in Q12, and 2h−1 (constant) in Q22; the code instead adds 2·ln2·h−1·Δt to Q11 only (and, opt-in, 2·ln2·h−1·Δt to Q22). At Δt = 10 s the code's Q11 flicker term is ~14× smaller than VD's (13.9·h−1 vs 200·h−1) and scales as Δt rather than Δt²; Q12's flicker term is absent entirely. Since flicker is non-Markovian ("No finite-order state model will fit flicker noise perfectly!"), *some* approximation is unavoidable, but the chosen one systematically under-covers flicker phase error growth relative to the primary source — a covariance-honesty (not accuracy) issue that becomes material now that the truth-side flicker synthesis actually produces flicker (see FFT fix below). Also note the filter's Q is built from the *same* h-coefficients as the truth clock — a perfectly-tuned-filter idealization a real receiver does not enjoy.

---

### Truth-side clock propagation (`step`)

- **Code**: `+models/+clocks/ClockModel.m:258–296` — WFM phase kick std `sqrt(h.h0*dt_s/2)` (line 259), RWFM frequency increment std `sqrt(2*pi^2*h.hMinus2*dt_s)` (line 262), Euler update `new_bias = bias + dt*(fracFreq + relativisticFracFreq) + n_wfm`, `new_frac = fracFreq + drift*dt + dn_rwfm`.
- **Verdict**: ✅ verified correct — per-step variances match σ²_x0(t) = (h0/2)t and the RW-FM driving density 2π²h−2; asymptotically reproduces the t³/3 bias growth (verified numerically in this audit: simulated RWFM ADEV matched √((2π²/3)h−2τ) to <2%).
- **Sources**:
  - Van Dierendonck et al. (1984) — variance list, p. 280 (transcription from garbled scan): σ²_x0(t) = (h0/2)t; σ²_x−1(t) = 2h−1t²; σ²_x−2(t) = (2/3)π²h−2t³.
  - Carpenter, J. R., & Lee, T. (2008). AAS 08-109. — "Clearly, the clock drift variance increases linearly with elapsed time, and the clock bias increases as the cube of elapsed time." (Appendix)
- **Critical analysis**: Modeling WFM as an independent phase jump per step (not accumulated into frequency) is the correct discrete realization — it yields the τ⁻¹ᐟ² ADEV branch and avoids double-integration. The Euler scheme's single-step covariance is diag(q1Δt, q2Δt) — it lacks the within-step q2Δt³/3 and q2Δt²/2 terms that the EKF's Q includes; over n steps the accumulated process converges to the exact law (error is one part in n), which is standard and harmless at simulation Δt. The deterministic drift and gated relativistic ramp (lines 80–87) are additive and don't interact with the stochastic terms. One reproducibility nicety verified: `precomputeNoise` resets the RNG stream (line 197), so colored synthesis is reproducible regardless of prior `step()` calls.

---

### FFT colored-noise synthesis (WPM/FPM/FFM) — the 2/N amplitude bug and its fix

- **Code**: `+models/+clocks/ClockModel.m:199–227` — one-sided target `Sy_frac = h2*f² + h1*f + hMinus1./f`; amplitude `A_frac = sqrt(max(Sy_frac,0) * fs * N) / 2` (line 214); Hermitian symmetrization `makeHermitian_` (lines 532–542); `y = real(ifft(X_sym))`; phase via `cumtrapz` (line 224).
- **Verdict**: ⚠️ now correct in the working tree, but the committed HEAD is flawed — `git diff` shows HEAD still has `A_frac = sqrt(max(Sy_frac,0) * fs / N)`, which is exactly a factor 2/N too small in amplitude (i.e., (2/N)² in power). The audit finding is CONFIRMED, and the fix (with a correct derivation comment) is present but **uncommitted**.
- **Sources**:
  - Kasdin, N. J. (1995). Discrete simulation of colored noise and stochastic processes and 1/f^α power law noise generation. *Proceedings of the IEEE, 83*(5), 802–827. — (EXTERNAL, abstract) "The paper presents a new digital model for power law noises that allows for very accurate and efficient computer generation of 1/fα noises for any α."
  - Winkel, J. Ó. (2003). *Modeling and Simulating GNSS Signal Structures and Receivers*. — "The most sensible way to generate the flicker noise … is perhaps to perform the simulation in frequency domain and transform the result back to time domain in the end. This is done in [Kas95]" (p. 100)
  - Riley, W. J. (2008). *NIST SP 1065*. — the target the synthesis must satisfy is the one-sided PSD/AVAR mapping of §7.1 (see next feature); the corrected synthesis was checked against it.
- **Critical analysis**: Independent re-derivation (this audit): with MATLAB's `ifft` carrying 1/N and each Hermitian-paired bin drawn as X_k = A_k(g₁+ig₂) with unit-variance g's, Var(y_n) = (4/N²)ΣA_k², so matching Σ S_y(f_k)Δf with Δf = fs/N requires A_k = √(N·fs·S_k)/2 — the fixed line. Numerical check (N = 4096, flat S_y = h0): fixed scaling reproduces the target variance to 0.2%; HEAD's scaling is low by exactly 2/N in amplitude (measured 0.000488 = 2/4096), i.e. ~5×10⁻⁷ in power — **the flicker floor has been effectively absent from every archived run**, including all `legacy`-template results and the golden references. A further check confirmed the corrected synthesis lands on the theoretical flicker floor: measured ADEV floor 5.30×10⁻¹¹ vs √(2ln2·h−1) = 5.27×10⁻¹¹ for h−1 = 2×10⁻²¹. Remaining (minor) defects even after the fix: (1) the DC bin is set to `abs(X(1))` rather than zeroed — a Rayleigh-distributed, strictly positive random DC fractional-frequency offset (mean ≈ 0.63·√h−1) enters every realization; standard practice (Kasdin 1995) zeroes DC and lets the low-frequency divergence be represented only down to f₁ = fs/N. (2) Nyquist is likewise `abs()`-forced rather than a real ±Gaussian. (3) Because the synthesis is circular, flicker power below fs/N is truncated, so the floor is underrepresented for τ approaching the run length — inherent to single-segment FFT synthesis, worth a docstring note. (4) The `f_pos(1) = f_pos(2)` DC dodge (line 202) couples defect (1) to the first nonzero bin's PSD value.

---

### Theoretical Allan deviation overlay

- **Code**: `+models/+clocks/ClockModel.m:466–474` — `3*h2/(4π²τ²)` (WPM), `1.038*h1/(4π²τ²)` (FPM), `h0/(2τ)` (WFM), `2*ln2*hMinus1` (FFM floor), `(2π²/3)*hMinus2*τ` (RWFM).
- **Verdict**: ✅ verified correct against NIST SP 1065 §7.1 and JOW eq. (2.156), including the RWFM coefficient that an earlier code revision had 2× too large (the fix note at lines 469–473 is accurate); ⚠️ the WPM/FPM branches deliberately omit the measurement-bandwidth factors (f_h and the 3ln(2πf_hτ) term) — documented at lines 464–465, and inert because all templates set h2 = h1 = 0.
- **Sources**:
  - Riley, W. J. (2008). *NIST SP 1065*. — "A = 4π²/6 B = 2·ln2 C = 1/2 D = 1.038 + 3·ln(2πfhτ0)/4π² E = 3fh /4π²" (§7.1, p. 74; conversion σ²y(τ) = A·f²S_y·τ etc.)
  - Winkel, J. Ó. (2003). — "A frequency normal with the spectral characteristics as given above by eq. (2.154) can also be described in terms of the so-called Allan variance:" followed by (transcription, eq. 2.156, p. 99): Aσ²_y(τ) = h0/(2τ) + 2ln2·h−1 + (2π²/3)τh−2.
  - Rubiola, E. (2011). *The Leeson effect: Phase noise and frequency stability in oscillators* (IFCS tutorial). — power-law table (transcription, slide table): flicker FM → σ²(τ) = 2ln(2)h−1; random-walk FM → (2π)²/6·h−2τ; white FM → ½h0τ⁻¹.
- **Critical analysis**: Digit checks: 4π²/6 = 2π²/3 ✓ (code's RWFM); 2ln2 ✓; 1/2 ✓; the FPM constant 1.038/(4π²) matches D with the 3ln term dropped ✓; WPM 3/(4π²) matches E with f_h set to 1 Hz ✓. Three sources agree independently. This overlay is what would have exposed the 2/N synthesis bug on any diagnostic plot with an FFM-dominated template — the empirical curve would sit far below the theoretical floor; with the flicker-weak legacy templates the gap was easy to miss. Two trivial comment errors in the legacy template annotations (not code): ConfigFactory.m:2144 claims TCXO WFM "ADEV ~1e-10 at tau=1s" (actual √(9e-22/2) = 2.1×10⁻¹¹) and :2145 claims floor "~2e-11" (actual √(2ln2·2e-21) = 5.3×10⁻¹¹).

---

### Empirical Allan deviation estimators — one exact, one nonstandard

- **Code**: (a) `+revgnss/AllanDeviation.m:48–51` — vectorized `d2 = x(2m+1:N) − 2x(m+1:N−m) + x(1:N−2m)`, `σ = sqrt(Σd2²/(2·(N−2m)·(m·dt)²))`. (b) `+models/+clocks/ClockModel.m:436–449` — block MEANS of phase over m samples, non-overlapped stride, second difference of the block means, same 1/(2nτ²) normalization.
- **Verdict**: (a) ✅ verified correct — matches NIST SP 1065 eq. (11) symbol-for-symbol, including the N−2m term count. (b) ⚠️ flawed as an AVAR estimator — averaging phase over blocks makes it a *non-overlapped modified-Allan-like* statistic normalized as ordinary AVAR; measured bias (this audit): ×0.708 for WFM (= 1/√2, the known Mod-σ/σ ratio), ×0.91 for RWFM. Diagnostic-plot-only impact.
- **Sources**:
  - Riley, W. J. (2008). *NIST SP 1065*. — "In terms of phase data, the overlapping Allan variance can be estimated from a set of N = M + 1 time measurements as" (§5.2.3, p. 16), followed by (transcription, eq. 11): σ²_y(τ) = 1/(2(N−2m)τ²) Σᵢ₌₁^{N−2m} [x_{i+2m} − 2x_{i+m} + x_i]².
  - Riley, W. J. (2008). *NIST SP 1065*. — "The original non-overlapped Allan, or two-sample variance, AVAR, is the standard time domain measure of frequency stability" (§5.2.1, p. 15)
  - Riley, W. J. (2008). *NIST SP 1065*. — "The modified Allan variance … [uses] phase averaging" (§5.2.5; the block-mean-of-phase construction is exactly the Mod-σ ingredient)
  - Robins, W. P. (1984). *Phase Noise in Signal Sources*. Peter Peregrinus/IET. — "The Allan Variance … is calculated by taking half the mean of the squared difference between two successive measurements of normalised frequency" (§9.4.2, p. 184)
- **Critical analysis**: The report pipeline (`oscillatorValidation.m` → `revgnss.AllanDeviation.compute`) is on the exact estimator, so published ADEV figures are trustworthy; the caption's slope reading guide (−0.5 WFM, +0.5 RWFM, flat FFM) is correct. `AllanDeviation.compute` also handles τ-grid selection (τ_max = N·dt/4) and NaN-guarding sensibly, and uses `median(diff(t))` so a single dropped epoch does not corrupt dt. The `ClockModel` internal estimator's √2 underestimate for WFM will make the empirical curve sit visibly *below* the theoretical overlay on its own diagnostic figure even when everything is correct — worth either fixing (use point-sampled phase, drop the block means) or renaming to state it estimates Mod-σ_y. Both estimators assume a uniform grid; that holds for the truth series they consume.

---

### h-parameter templates vs. JOW Table 2.1 — digit-by-digit

- **Code**: `+revgnss/ConfigFactory.m:2138–2185` (legacy), `:2193–2263` (jowTable2p1), threaded via `makeClockConfig` (:407–465, multiplier semantics `h0_out = template.h0 * h0Factor * noiseScale`, a direct PSD multiplier so ADEV scales as its square root — correctly stated at :422). Locked by `tests/test_clock_template_sourcing.m`.
- **Verdict**: CESIUM1(jow) ✅ exact; OCXO(jow) ⚠️ partially correct (h−2 exact, h0/h−1 knowingly retained from legacy — retention makes the flicker floor ~60× optimistic vs JOW OCXO2); TCXO(jow) ❌ mislabeled — claims "(JOW Table 2.1)" but does not match it; RUBIDIUM(jow) ❌ mislabeled — matches neither JOW rubidium row; legacy table ❓ unsourced (attributed to "IEEE Std 1139-2008; Sesia et al.; GPS ICD" at :2118 with no per-number citation; several values are orders optimistic vs. any published analogue).
- **Sources**:
  - Winkel, J. Ó. (2003). — Table 2.1, p. 100 (verbatim rows): "TCXO 1·10−21 s 1·10−20 2·10−20 Hz"; "OCXO2 2.51·10−26 s 2.51·10−23 2.51·10−22 Hz"; "Rubidium1 2·10−20 s 7·10−24 4·10−29 Hz"; "Cesium1 1·10−19 s 1·10−25 2·10−32 Hz" — caption "Table 2.1.: Parameters for the Allan variance of several oscillators"
- **Critical analysis**: **Exact matches**: jow CESIUM1 h0 = 1e-19, h−1 = 1e-25, h−2 = 2e-32 ✓✓✓; jow OCXO h−2 = 2.51e-22 = JOW OCXO2 ✓ (the comment correctly notes OCXO1's 4e-23 as the milder alternative ✓). **Mismatches under the 'jowTable2p1' label**: TCXO keeps 9e-22/2e-21/1e-20 while JOW's TCXO row is 1e-21/1e-20/2e-20 — h−1 is 5× low (flicker floor 2.2× optimistic), h−2 2× low; the comment "already close to the legacy values" is wrong for h−1. RUBIDIUM keeps 1e-22/4.5e-24/3e-28; JOW Rubidium1 is 2e-20/7e-24/4e-29 (h0 200× low, h−2 7.5× high) and Rubidium2 is 1e-23/1e-22/1.3e-26 — neither row matches, so "Aligned to JOW Table 2.1 rubidium" is unsupported. jow OCXO's retained h−1 = 7e-27 vs JOW OCXO2's 2.51e-23 puts the flicker floor at 9.9e-14 instead of 5.9e-12 (~60× optimistic) — the in-code justification ("sets only the short-term/flicker floor") is candid but the floor *is* the quantity of interest for a τ-independent error budget. **Legacy table**: OCXO 2e-25/7e-27/2e-29 is 4–6 orders below JOW OCXO1 (8e-20/2e-21/4e-23); CESIUM1 h0 = 1e-26 vs JOW Cesium1 1e-19 — the code's own "~7 orders" admission is digit-exact ✓. Since the DEFAULT run uses CESIUM1+legacy for the asset, the headline sub-100-ps timing results ride on a receiver clock ~3000× quieter (in ADEV) than JOW's caesium beam — this is disclosed in masterConfig (:152–154) and switchable in one string, which is good practice, but any publication should quote the jowTable2p1 numbers or justify the legacy ones from a real hardware datasheet. The regression test locks both tables byte-exactly, so the mislabeled TCXO/RUBIDIUM rows are at least frozen and auditable.

---

### Tower clock correction products (`TowerClockCorrectionProvider`)

- **Code**: `+models/+clocks/TowerClockCorrectionProvider.m` — product epoch `t_prod = floor((t−latency)/interval)*interval` (:72–80); linear prediction `towerClkModel = (b_p + b_noise) + (bd_p + d_noise)*age` (:108); R-contribution `var = σb² + age²σd² + 2·age·covBD` (:110–113, same formula in `evalProductStruct` :258); deterministic per-(tower, t_prod) product noise via seeded RNG cache (:447–483).
- **Verdict**: ✅ formulas verified correct (the prediction variance is the exact error propagation of b̃ + d̃·age with Cov(b̃,d̃) = covBD); ⚠️ scientific-honesty caveat: the DEFAULT mode is `'perfectCorrection'` (:89–90 applies the *true* tower bias as the correction; drift path :320–328 likewise anchors on truth) — a truth-assisted baseline, not a receiver-realizable observable.
- **Sources**:
  - (Internal design, no external formula to source; the linear bias+drift product with age-grown sigma is structurally the standard GNSS broadcast/IGS clock-product prediction model. The sigma values σb = 0.01 m ≈ 33 ps and σd = 2×10⁻⁴ m/s claimed as "IGS-class" in masterConfig.m:162–163 are plausible for a high-quality network but are ❓ unsourced in the repo.)
- **Critical analysis**: The `truthHistoryProductNoisy` mode is the scientifically defensible one: the product error is drawn ONCE per (tower, product epoch) — "the error is fixed at broadcast time and does not redraw for every measurement epoch" (:453–455) — which is the correct correlation structure for a broadcast product and is what makes the shared-error R-blocks below meaningful. Two caveats: (1) the product noise seed is a pure function of (towerIdx, t_prod) outside the RngRegistry (documented at :458–466), so Monte-Carlo over master seeds does NOT re-randomize product errors — deliberate (cross-fleet sharing) but easy to misread in ensemble statistics; (2) `'perfectCorrection'` being the default means every headline run's tower-clock error budget row is zero by construction; the report should (and per the config comments, does) label this as a baseline. The `noisyCorrection` mode redraws white noise per epoch and is correctly annotated as "NOT a model of what a real receiver produces" (:43–47).

---

### Product-clock covariance blocks (`ProductClockCovarianceBuilder`)

- **Code**: `+models/+clocks/ProductClockCovarianceBuilder.m` — Doppler: `R(g,g) += sd²·ones` per (tower, productEpoch) group (:56); carrier: `R(g,g) += (age_g*age_g')·sd²` (:108); cross code-Doppler: `covBiasDrift + codeAge_i·σd_j²` (:179); cross code-carrier: `codeAge_i·carAge_j·σd_j²` (:200); SPD guard via jitter/chol (:216–226).
- **Verdict**: ✅ structurally correct rank-1 correlated-error models (a single shared drift error d̃ gives exactly Cov = σd²·age_i·age_j and Cov(code_i, dop_j) = covBD + age_i·σd²); ⚠️ one incompleteness: the code-carrier cross term omits the `carAge_j·covBiasDrift` contribution (E[(b̃+d̃age_i)(d̃age_j)] = age_j·covBD + age_i age_j σd²) — inert at the default `covBiasDrift = 0` but wrong if a correlated product were ever configured.
- **Sources**:
  - (Standard multivariate error propagation; no external source required. The carrier policy "Constant product bias is absorbed by float ambiguity; only the time-varying drift residual … enters carrier R" (:15–17) is the standard treatment of a per-arc constant bias under float ambiguities.)
- **Critical analysis**: This class is the rare place where the simulation charges *correlated* measurement errors as off-diagonal R instead of inflating diagonals — scientifically the right thing, and the SPD guard with minimum-eigenvalue jitter (:219–222) is implemented carefully (jitter magnitude recorded in `info`). The group keying by `sprintf('%d_%.3f', towerIdx, t_prod)` is exact-match on the product epoch; fragile only if two callers quantize t_prod differently (they share the same computation path, so currently safe). The O(M_code·M_dop) double loops are fine at these row counts. Flag for follow-up: add the missing covBD term or assert covBiasDrift == 0 at the entry point.

---

### Gauss-Markov clock modeling

- **Code**: none — the simulation implements only the random-walk (integrated Wiener) two-state model; there is no first/second-order Gauss-Markov clock state anywhere in `+models/+clocks/`.
- **Verdict**: ✅ acceptable omission for this use case, worth one sentence of justification in the paper.
- **Sources**:
  - Carpenter, J. R., & Lee, T. (2008). AAS 08-109. — "Long data outages may occur … Current clock error models based on the random walk idealization may not be suitable in these circumstances, since the covariance of the clock errors may become large enough to overflow flight computer arithmetic." (p. 1)
- **Critical analysis**: The Carpenter-Lee coupled FOGM/SOGM model exists to keep covariance bounded through multi-hour outages; this simulation's measurement cadence is seconds-to-minutes with continuous tower visibility at GEO, so the RW model's unbounded growth is never stressed and matches the Allan-variance asymptotes over the arc lengths used ("Over short intervals, the Gauss-Markov and random walk models agree well," Fig. 3 caption). The omission is therefore sound engineering, not an oversight — but it should be stated with the outage caveat if the thesis discusses long GNSS-denied arcs.

---

### Ancillary sources reviewed and found not load-bearing

- *AN-756* (Brannon, Analog Devices): sampled-system clock jitter — background only; no simulation formula derives from it.
- *Receiver clock error determination* (scanned book excerpt, §8.4.1, SBAS GUS): MOPS weighted-least-squares clock bias — relates to the estimator domain, not the clock model; no formula used.
- *micromachines-15-00455* (Naumann & Sands, 2024, "Micro-Satellite Systems Design, Integration, and Flight"): not clock-related; not relevant to this section.
- *2220.pdf.pdf* is a duplicate copy of NIST SP 1065 (cleaner text layer); treated as one source.

---

#### References (APA 7)

- Brannon, B. (2004). *Sampled systems and the effects of clock phase noise and jitter* (Application Note AN-756). Analog Devices.
- Brown, R. G., & Hwang, P. Y. C. (1997). *Introduction to random signals and applied Kalman filtering* (3rd ed.). John Wiley & Sons. (Cited via Carpenter & Lee, 2008, Ref. 2; the in-repo scan `Paper/Error Calculation/KalmanFilter/Brown.pdf` has no text layer.)
- Carpenter, J. R., & Lee, T. (2008). *A stable clock error model using coupled first- and second-order Gauss-Markov processes* (AAS 08-109). AAS/AIAA Space Flight Mechanics Meeting.
- Kasdin, N. J. (1995). Discrete simulation of colored noise and stochastic processes and 1/f^α power law noise generation. *Proceedings of the IEEE, 83*(5), 802–827. (EXTERNAL; abstract verified, full text via JOW's [Kas95].)
- Naumann, P., & Sands, T. (2024). Micro-satellite systems design, integration, and flight. *Micromachines, 15*(4), 455. (Reviewed; not relevant.)
- Riley, W. J. (2008). *Handbook of frequency stability analysis* (NIST Special Publication 1065). National Institute of Standards and Technology.
- Robins, W. P. (1984). *Phase noise in signal sources* (IET Telecommunications Series 9). Peter Peregrinus.
- Rubiola, E. (2011, May). *The Leeson effect: Phase noise and frequency stability in oscillators* [Tutorial]. IEEE International Frequency Control Symposium, San Francisco.
- Van Dierendonck, A. J., McGraw, J. B., & Brown, R. G. (1984). Relationship between Allan variances and Kalman filter parameters. *Proceedings of the 16th Annual Precise Time and Time Interval (PTTI) Applications and Planning Meeting* (pp. 273–293). NASA Goddard Space Flight Center.
- Winkel, J. Ó. (2003). *Modeling and simulating GNSS signal structures and receivers* [Doctoral dissertation, Universität der Bundeswehr München].
- Zucca, C., & Tavella, P. (2005). The clock model and its relationship with the Allan and related variances. *IEEE Transactions on Ultrasonics, Ferroelectrics, and Frequency Control, 52*(2), 289–296. (EXTERNAL; paywalled, cited for the instantaneous-frequency two-state form.)

---

# Section: Atmospheric Error Models

This section audits the troposphere, ionosphere, scintillation and ionosphere-free (IF) machinery of the oo_v1 reverse-GNSS simulation digit-by-digit against the project's own paper library (`Paper/`) and, where the library is silent, against external authoritative sources (marked EXTERNAL). Files audited: `+models/+atmosphere/{TroposphereModel,MappingFunctions,NiellCoefficients,IonosphereModel,Klobuchar}.m`, `+models/+errors/{EnvironmentModel,ErrorChain,HigherOrderIonosphere}.m`, `+revgnss/{IonoFreeCombination,IonosphereFreeBiasBudget,IonosphereFreeCombinationDiagnostics}.m`, the façades `models/atmosphere/{troposphere,ionosphere}.m`, and `docs/atmosphere_realism.md`. Headline result: the deterministic physics is remarkably clean — the Saastamoinen/Davis ZHD, the complete Niell (1996) coefficient tables, the thin-shell obliquity, the first-order dispersion signs and the IF invariants all verify exactly — while the honest weaknesses are in the *stochastic* layer (a 1 h ZWD filter time constant the repo's own docs disavow, a degenerate default Conker scintillation with S4zen=0, and a Klobuchar status flag that contradicts the shipped code).

### Saastamoinen / Davis zenith hydrostatic delay (ZHD)

- **Code**: `+models/+errors/EnvironmentModel.m:802-811` — `ZHD = 0.0022768*P / (1 - 0.00266*cos(2*lat) - 0.00028*h_km)`, with surface pressure from the ICAO standard atmosphere `P(h) = P0*(1 - 2.2557e-5*h)^5.2559` (line 787) and a validity guard `[-500, 11000] m` (lines 775-781).
- **Verdict**: ✅ The constant and both gravity-correction coefficients are the full-precision Davis et al. (1985) form; the in-repo papers quote only rounded variants, so the code is *more* precise than its local sources.
- **Sources**:
  - Barba et al. (2023) — "ZHD = 0.002277 · P / (1 − 0.0026 · cos(2φ) − 0.00028 · h0)" (p. 3). Rounded coefficients.
  - Zhang et al. (2026) — ZHD integral closed with "0 0022768 P top / 1 − 0 0026 cos 2 lat − 0 00028 zR" (p. 312) [OCR of Eq.; confirms 0.0022768 and 0.00028].
  - Osah et al. (2021) — gravity correction "9.784(1 − 0.00266cos2φ − 2.8×10⁻⁷ H)" (p. 122) — confirms the unrounded 0.00266 (2.8e-7 per m ≡ 0.00028 per km).
  - Li et al. (2023) — "A typical accuracy at 2–6 mm level in the zenith direction has been demonstrated" (p. 1718) — supports the code's claim that ZHD is predictable to ~mm from surface pressure.
  - Davis, Herring, Shapiro, Rogers & Elgered (1985), Radio Science 20(6), 1593–1607 — canonical source of 0.0022768 ± 5e-7 m/hPa (EXTERNAL; cited in the code comment at lines 802-807 and not present as a PDF in `Paper/`).
- **Critical analysis**: Numerically verified: 0.0022768·1013.25/(1−0.00266·cos 90°) = 2.3070 m at 45°/sea level, matching the docs' "2.307 m". The ISA exponent pair (2.2557e-5, 5.2559) is the standard barometric formula (1 − h/44330.8)^5.2559. Cross-validated in-repo against Orekit `ModifiedSaastamoinenModel` (`tests/test_orekit_troposphere_crossvalidation.m`, sub-cm assertion) — a strong independent check. Two blemishes: (i) the *docstring* at line 741 still says `ZHD = 2.3 * P(h) / 1013.25`, describing an older scaled model the code no longer uses — stale comment; (ii) the zenith *wet* mean `ZWD = 0.15*RH*exp(-h/2000)` (line 812) is an ad-hoc parameterisation, not the Saastamoinen wet term `0.002277·(1255/T + 0.05)·e` that Osah et al. (2021, p. 117) print — acceptable because the wet residual is carried stochastically, but it should be labelled as invented, not "Saastamoinen".

### Niell (1996) mapping function — coefficient tables

- **Code**: `+models/+atmosphere/NiellCoefficients.m:27-51` (tables), `MappingFunctions.m:71-99, 151-160` (Marini form + height correction).
- **Verdict**: ✅ All 45 table entries and the 3 height-correction coefficients are **digit-for-digit identical** to Niell (1996) Tables 3 and 4 — verified against the retrieved original paper, not a secondary source.
- **Sources**:
  - Niell (1996), Table 3 "Coefficients of the Hydrostatic Mapping Function (nmfh2.0)" (p. 3235): a_avg = 1.2769934e-3 / 1.2683230e-3 / 1.2465397e-3 / 1.2196049e-3 / 1.2045996e-3 at 15/30/45/60/75°; b_avg, c_avg, all amplitudes (0.0, 1.2709626e-5, 2.6523662e-5, 3.4000452e-5, 4.1202191e-5 for a; up to 170.37206e-5 for c), a_ht = 2.53e-5, b_ht = 5.49e-3, c_ht = 1.14e-3 — every value matches the MATLAB constants exactly. [EXTERNAL retrieval of the paper the code cites]
  - Niell (1996), Table 4 (p. 3235): wet a/b/c rows (5.8021897e-4 … 5.4736038e-2) — exact match.
  - Niell (1996) — "Eight digits are given in order to be exactly equivalent to the FORTRAN implementation already in use" (p. 3235).
  - Osah et al. (2021) — the continued fraction "m(ε) = (1 + a/(1 + b/(1+c))) / (sinε + a/(sinε + b/(sinε + c)))" (p. 123, eq. [36]) and height correction mfh = m(ε) + ΔM·Hs·10⁻³ (eq. [37]-[38]) — in-repo confirmation of the functional form.
- **Critical analysis**: The Marini-normalised form (`marini_`, numerator = value at sin e = 1, so m(90°) = 1 exactly) matches Niell's eq. (4) and Li et al. (2023, p. 1721: mapping "has a value of 1 when the elevation angle is zenithal"). The height correction `dm = 1/sin(e) − marini(sinE; a_ht,b_ht,c_ht)`, applied per km to the hydrostatic term only, is Niell's eqs. (6)-(7) verbatim. Spot-computation reproduces the repo's claimed reference values: m_h(5°, 45°, annual) = 10.129, m_w(5°) = 10.751 vs 1/sin 5° = 11.474. Latitude clamping to [15°, 75°] with linear interpolation matches the paper's prescription. Wet coefficients latitude-only (no season/height) — correct per Table 4. This is genuinely well done: most simulations copy NMF from secondary sources; this one is byte-consistent with the primary tables *and* cross-validated byte-identically against Orekit's `NiellMappingFunctionModel`.

### Niell seasonal term — the sign question

- **Code**: `NiellCoefficients.m:79-83` — `a = a_avg - a_amp * cos(2π(doy - 28)/365.25)`, southern hemisphere adds 182.625 d (line 51).
- **Verdict**: ⚠️ The printed Niell (1996) equation shows a **plus**; the code (like every major implementation) uses **minus**. The code follows the de facto standard and the physically sensible convention, but the repo's own test cannot detect the sign, and the repo's own paper source prints the opposite sign.
- **Sources**:
  - Niell (1996) — "a(λi,t) = aavg(λi) + aamp(λi) cos(2π(t−T0)/365.25)" with "T0 … the adopted phase, DOY 28" (p. 3234) — plus sign as printed.
  - Niell (1996) — "the inversion of the seasons has been accounted for simply by adding half a year to the phase for southern latitudes" (p. 3234) — matches SOUTH_SHIFT = 182.625.
  - Osah et al. (2021) — eq. [39]: "a(φ,t) = a_avg(φ) + a_amp(φ) cos(2π(doy − 28)/365.25)" (p. 123) — also plus.
  - ESA Navipedia, "Mapping of Niell" — "ξ(φ,t) = ξ_avg(φ) − ξ_amp(φ) cos(2π(t−T₀)/365.25)" with T₀ = 28 — minus. [EXTERNAL]
  - Orekit `NiellMappingFunctionModel` source — `ah = ahAverage - ahAmplitude * cosCoef`, `t0 += 183` for southern latitudes. [EXTERNAL]
- **Critical analysis**: My numerical check resolves which convention is physical: with the minus sign, m_h(5°, 45°N) is 10.152 at DOY 28 (winter) and 10.106 in July; a cold compressed atmosphere (smaller effective height) must have the *larger* low-elevation mapping factor, so winter-max — i.e. the minus convention — is right, and the printed plus in the journal (faithfully copied by Osah et al.) appears to be an error propagated in print. The code agrees with Navipedia, Orekit and RTKLIB, and the repo's Orekit cross-validation is byte-identical, which pins the implementation to the community consensus. Two residual criticisms: (i) `tests/test_niell_mapping_function.m` evaluates only at `doyAvg = 28 + 365.25/4`, which *nulls the cosine* — the seasonal sign is untested by the published-value test (the Orekit test covers it only if its day-of-year differs from the null point); (ii) the effect is small (±0.023 in m_h(5°), ~0.2%) but for a paper the sign convention should be stated explicitly with the Navipedia/Orekit-style formula, since citing "Niell 1996, eq. (5)" verbatim would document the opposite sign.

### ZWD Gauss-Markov truth process and per-tower ZWD EKF state

- **Code**: Truth: `EnvironmentModel.m:256-274` first-order GM per tower via `StochasticProcess.gaussMarkovStep`, parameters `cfg.errors.troposphere.stochastic` — realistic profile τ = 10800 s, σ_ss = 0.04 m (`config/masterConfig.m:748-749`). Estimator: `TroposphereModel.zwdProcessParams` (`TroposphereModel.m:75-91`) defaults σ_ss = 0.05 m, τ = 3600 s, init 0.10 m; masterConfig sets init 0.3 m, σ_ss 0.05 m, τ 3600 s (`masterConfig.m:405-408`); the discrete-time Q is applied consistently in `ErrorChain.m:503-510` (σ√(1−e^(−2dt/τ))).
- **Verdict**: ⚠️ Magnitude is well within the literature; the *time constant* of the EKF process (1 h) contradicts both the truth process (3 h) and the repo's own documentation, which explicitly disavows 0.5–2 h.
- **Sources**:
  - Li et al. (2023) — "the small 'wet' part, highly variable in time and space, generally varies between 0 and 40 cm in the zenith direction" (p. 1718) — a 4–5 cm residual GM about a climatological mean is comfortably inside this envelope.
  - Li et al. (2023) — residuals of estimated ZWD "can reach up to several millimeters (~ 2–7 mm)" (p. 1719) — the achievable EKF accuracy the perTowerZwd state aims at.
  - Tralli & Lichten (1990), *Stochastic estimation of tropospheric path delays in GPS geodetic measurements*, Bull. Géod. 64 — canonical justification for random-walk / first-order Gauss-Markov ZWD models with cm-level process noise. [EXTERNAL — random-walk/FOGM ZWD modelling is standard PPP practice]
  - `docs/atmosphere_realism.md` reference table — "ZWD correlation time (corrected) hours to tens of hours (~3–24 h), **not** 0.5–2 h — PPP literature; FOGMP ≈ 20 h".
- **Critical analysis**: The architecture is right: the truth wet residual lives on its own `ENV_TROP_TRUTH` stream, the model side may only use an *independent* GM or the EKF state, and the `sameAsTruth` oracle mode is a hard error (`EnvironmentModel.m:250-254`) — an unusually principled truth/model separation. The inconsistency: the repo corrected its documentation to "3–24 h, not 0.5–2 h", set the *truth* τ to 3 h, but left the *estimator* τ at 1 h (`masterConfig.m:408`, and the hardcoded default in `zwdProcessParams`). A filter that assumes 3× faster decorrelation than truth over-injects Q — conservative for covariance honesty, but it is precisely the kind of un-cited σ/τ the docs' own "no arbitrary noise inflation" rule forbids. Neither 4 cm/3 h (truth) nor 5 cm/1 h (filter) carries a citation to a specific measured ZWD structure function; a Ning & Elgered-type or Tralli & Lichten-type citation with numbers should be attached. Genuinely good: `weakObservabilityNote` (`TroposphereModel.m:93-109`) flags elevation spreads < 15°, exactly the geometry in which ZWD aliases into clock/range bias — an honest observability admission most simulators omit.

### First-order ionosphere: 40.3 vs 40.308, signs, thin-shell obliquity

- **Code**: `EnvironmentModel.m:525` — `K_L1 = 40.308e16 / f_L1^2` (0.16241 m/TECU at L1); signs in `IonosphereModel.m:30-48` (code **+**, carrier **−**, both scaled `(f_L1/f)²` via `SignalDefinition.ionoScale`); thin-shell mapping `MappingFunctions.m:131-139` — `M(e) = 1/sqrt(1 − (Re·cos e/(Re+hI))²)`, hI default 350 km, Re = 6378137 m.
- **Verdict**: ✅ All three elements verify; the papers use the rounded 40.3, the code uses the more precise 40.308, and the two differ by 0.02%.
- **Sources**:
  - Enge (1994) — "the group delay introduced by the ionosphere is approximately 40.3 TEC/cf2" (sec. 2.4) — and "changes in the total electron content will introduce equal but opposite changes in the phase and [group delay]" — the ± sign pair implemented in `IonosphereModel`.
  - Kaplan & Hegarty (2006) — eq. (7.21): "F = [1 − (Re cos φpp/(Re + hI))²]^(−1/2)"; "The height of the maximum electron density, hI, in this model is 350 km" (p. 312) — the thin-shell formula and default shell height, verbatim.
  - Fritsche et al. (2005) — eqs. (1)-(2): P = ρ + q/f² + …, L = ρ + nλ − q/f² − … , q = 40.3∫N dL (p. 2) — confirms +code/−carrier and the 40.3 coefficient.
  - An et al. (2020) — "I = 40.3/f₁² F(z) × VTEC" (p. 5) — in-repo IF/PPP source using 40.3 with a thin-shell mapping function.
  - GLONASS IAC ionosphere methods page — quotes 40.31 m³/s²; the exact physical value is κ = e²/(8π²ε₀mₑ) ≈ 40.308 m³s⁻² [EXTERNAL — the full-precision constant is not in `Paper/`].
- **Critical analysis**: Numerically confirmed: K_L1 = 0.16241 m/TECU, K_L2 = 0.26747 m/TECU (docs table "0.162 / 0.267" ✓); M(5°) = 3.041, M(15°) = 2.488, M(30°) = 1.751 — matching both the docs table and `test_niell_mapping_function`'s reference rows. The thin-shell mapping is used (correctly) for the ionosphere only, distinct from the troposphere mapping, and the code's comment that it "does NOT use magic constants" is fair — the formula is pure geometry given Re and hI. Two internal nits: (i) `+revgnss/InterSatelliteRFLinkModel.m:178` uses `40.3` while `EnvironmentModel` uses `40.308e16` — a harmless 0.02% inconsistency, but a single named constant would be cleaner; (ii) `ErrorChain.m` comments cite "Leick et al. 2015 eq. 9.11" for the mapped vertical delay — Leick is not in `Paper/`, so that citation is unverifiable locally (the Kaplan 7.21 source above covers the same content).

### Klobuchar model — what is actually implemented vs what is claimed

- **Code**: `+models/+atmosphere/Klobuchar.m` — reduced *vertical* kernel: `Iv = DC + AMP·(1 − x²/2 + x⁴/24)` for `|x| < 1.57`, else `DC`; `x = 2π(t_LT − 50400)/PER`; `DC = 5 ns`, `PER ≥ 72000 s`, `AMP ≥ 0`. Wired as an iono *model correction* in `EnvironmentModel.m:558-571` (`ic.model.correction='klobuchar'`, local time from tower longitude, then topside fraction × thin-shell mapping × (f_L1/f)²); enabled by the realistic profile (`masterConfig.m:768`).
- **Verdict**: ⚠️ Every implemented digit matches the ICD algorithm, and the class docstring is honest about the reduction — but the machine-readable status flag and two code comments still claim Klobuchar is *not implemented*, which is now false.
- **Sources**:
  - ESA Navipedia, "Klobuchar Ionospheric Model" — night value 5·10⁻⁹ s; "X_I = 2π(t−50,400)/P_I"; delay "[5·10⁻⁹ + A_I·(1 − X_I²/2 + X_I⁴/24)]·F" for |X_I| ≤ 1.57 else 5·10⁻⁹·F; "if P_I < 72,000 then P_I = 72,000"; "if A_I < 0, then A_I = 0" [EXTERNAL, transcribing IS-GPS-200 / Klobuchar 1987] — the code's PEAK_LOCALTIME_S = 50400, NIGHT_DC_S = 5e-9, MIN_PERIOD_S = 72000, CUTOFF_X = 1.57, series and clamps all match.
  - Kaplan & Hegarty (2006) — "the Klobuchar model, which removes (on average) about 50% of the ionospheric delay at midlatitudes"; vertical delay "approximated by half a cosine function of the local time during daytime and by a constant level during nighttime" (p. 313) — the algorithm's shape and the ~50% RMS-removal figure quoted in `docs/atmosphere_realism.md`.
- **Critical analysis**: Not implemented (and correctly declared in the class header and in `docs/atmosphere_realism.md` "Not yet implemented"): the 8-coefficient α/β polynomial evaluation of AMP and PER from geomagnetic pierce-point latitude, and the ICD's own obliquity `F = 1 + 16(0.53 − E)³` — the code substitutes the thin-shell obliquity, which is defensible (Kaplan p. 312 presents thin-shell as an obliquity model) and arguably better-behaved at GEO uplink geometry. The genuine defect is self-consistency: `+revgnss/ConfigFactory.m:1818-1820` defaults `cfg.effects.ionosphere.klobucharStatus = 'notImplemented'` unconditionally, and stale comments at `MappingFunctions.m:116` ("This is NOT a Klobuchar model. Klobuchar is not implemented.") and `ErrorChain.m:530` repeat it — written before `Klobuchar.m` landed. A reader of the config audit will conclude the realistic profile has no iono model correction when it in fact runs the reduced Klobuchar. The status string should become something like `'reducedKernelSuppliedClimatology'`, set when `model.correction='klobuchar'`. Also note the truncated cosine is the ICD's, not a bug: at the |x| = 1.57 cutoff the 4th-order series returns 0.0207 while cos(1.57) = 0.0008 — the small daytime-edge discontinuity is a documented property of the broadcast algorithm itself.

### Higher-order ionosphere (2nd/3rd order)

- **Code**: `+models/+errors/HigherOrderIonosphere.m:26-42` — `d2 = sign(I_L1)·min(0.003·|I_L1|, 0.05 m)·(f_L1/f)³`, `d3 = sign(I_L1)·min(5e-5·I_L1², 0.005 m)·(f_L1/f)⁴` (defaults `masterConfig.m:1903-1907`); truth-side only, `model_m = 0`, `sigma_m = |truth|` into R (`ErrorChain.m:769-788`); re-evaluated per signal frequency in `CodeMeasurementBuilder.m:817-846`.
- **Verdict**: ⚠️ Scaling laws and magnitudes are right and deliberately conservative; the physics reduction (no geomagnetic geometry) is honestly labelled; but the carrier phase never receives its −½ / −⅓ counterparts.
- **Sources**:
  - Fritsche et al. (2005) — "s = 7527 · c ∫N|B0| cosθB dL" (eq. 4) and "r = 2437 ∫N²dL + 4.74·10²² ∫NB0²(1 + cos²θB) dL" (eq. 5) (p. 2) — 2nd order ∝ f⁻³, 3rd ∝ f⁻⁴, as implemented.
  - Fritsche et al. (2005) — "ΔI(2)_p = −½ ΔI(2)_g" (eq. 11) and third-order phase = −⅓ group (p. 2-3) — the phase counterparts the code *omits*.
  - Li et al. (2023) — "the higher-order ionosphere terms can be greater than 1 cm, especially for high TEC cases. The second-order term S2 … is typically only 0.1% of the first order value"; third order "less than 10% of the second-order value for GPS L1" (p. 1716); Table 5: "Ionosphere (Higher order): 0–2 cm" (p. 1720).
- **Critical analysis**: Magnitude audit: from Fritsche eq. (10), at 100 TECU with B0·cosθ = 4·10⁻⁵ T, ΔI(2)_g(L1) ≈ 2.3 cm = 0.14% of the 16.24 m first-order delay. The code's `secondOrderFractionL1 = 0.003` (0.3%) is therefore ~2× conservative, consistent with its "high solar activity" framing, and the 5 cm cap prevents pathological growth; the third-order default (5e-5·I² capped at 5 mm) matches the "< 10% of second order" bound. The IF-survival property (f⁻³/f⁻⁴ terms do NOT cancel in the f⁻² combination; residual ≈ −0.72·d2_L1 for L1/L2) is real physics and is regression-tested (`tests/test_iono_higher_order.m`). Three limitations to state in the paper: (i) **carrier omission** — `CarrierMeasurementBuilder` has no higher-order term at all, so the truth carrier is missing the −½·d2 phase advance (mm-to-cm at high TEC; Fritsche eq. 11); (ii) the sign is tied to sign(I_L1), i.e. always positive for code — physically the 2nd-order sign depends on the ray-geomagnetic geometry (B0·k), which for a *southward-looking* northern-hemisphere uplink can flip; the bounded-residual framing makes this acceptable for R-sizing but not for bias studies; (iii) the effective coefficients (0.003, 5e-5) are calibrated to literature magnitudes, not derived from B and Nmax — the code says so ("Branch A collapses the geomagnetic / profile detail into effective coefficients"), which is the honest way to do it.

### Ionosphere-free combination and its noise amplification

- **Code**: `+revgnss/IonoFreeCombination.m:16-40` — α = f1²/(f1²−f2²), β = −f2²/(f1²−f2²), variance α²σ1² + β²σ2² + 2αβcov; identically in `IonosphereModel.ionoFreeCoefficients` (lines 50-68) and `IonosphereFreeCombinationDiagnostics` ("Noise amplification factor approx 2.98", line 163); bias propagation in `IonosphereFreeBiasBudget.m:46-52`.
- **Verdict**: ✅ Coefficients, invariants and the 2.98 amplification are exact; the IF float-ambiguity caveat is correctly stated.
- **Sources**:
  - Kaplan & Hegarty (2006) — eq. (7.22): "ρ_ionospheric_free = (ρ_L2 − γρ_L1)/(1 − γ), where γ = (f_L1/f_L2)²"; "measurement errors are significantly magnified through the combination" (p. 312) — algebraically identical to α/β.
  - An et al. (2020) — in-repo demonstration of dual-frequency IF PPP versus raw observations with ionospheric constraints (pp. 1-3) — supports the code's diagnostic distinction between IF rows and per-frequency rows with iono states.
  - Enge (1994) — dual-frequency TEC estimation from "40.3TEC(f²L1 − f²L2)/c f²L1 f²L2" (sec. 2.4) — the same dispersion algebra.
- **Critical analysis**: Verified numerically for L1 = 1575.42 MHz / L2 = 1227.60 MHz (`SignalDefinition.m:110-113`): α = +2.545728, β = −1.545728, α+β = 1 (geometry/clock/tropo preserved — important because the *non-dispersive* troposphere must survive IF unchanged, which the code states explicitly in `docs/atmosphere_realism.md`), α/f1² + β/f2² = 0 to machine precision, and √(α²+β²) = 2.9783 — the "×2.98" used throughout the repo's IF trade-off analysis (5-tower divergence vs 12-tower recovery) is exact, not folklore. `IonosphereFreeBiasBudget` correctly notes that IF *amplifies* inter-frequency hardware biases through the same α/β and that IF ambiguities are float-valued (no integer fixing) — both true and frequently glossed over. Criticism: the identical coefficient formula now lives in **three** classes (`IonoFreeCombination`, `IonosphereModel`, `IonosphereFreeCombinationDiagnostics`); they agree today, but this is a maintenance liability for a "single source of truth" codebase.

### Scintillation: amplitude fading, Conker model, phase scintillation

- **Code**: `EnvironmentModel.m:310-342` (unit-σ amplitude GM, τ = 30 s, `abs()` clamp; per-tower phase GM τ = 1.5 s), `getScintillationSigma` (lines 590-638): legacy σ = |amp|·σ_L1·(f_L1/f)^exp/√sin e; 'conker' σ = σ_L1·(f_L1/f)^exp/√(1−2S4²) with S4 = min(0.7, |amp|·S4zen·(1/sin e)^0.9); `getPhaseScintRad` (lines 346-369): φ = GM·σφ·(1/sin e)^0.9, σφ default 0.2 rad. Defaults: `masterConfig.m:1908-1920` — model 'conker', **S4zen = 0**, σ_codeL1 = 0.3 m, frequencyExponent = 1.0.
- **Verdict**: ⚠️ The Conker functional form and the 0.707 loss-of-lock clamp are correct, and the time-correlated (non-white) phase jitter is the right physics — but the default configuration (S4zen = 0 under model 'conker') degenerates to a flat, elevation-independent 0.3 m code-noise floor that is scintillation in name only, and the frequency exponent 1.0 is soft against the ~1.5 weak-scatter scaling.
- **Sources**:
  - Conker, El-Arini, Hegarty & Hsiao (2003), *Modeling the effects of ionospheric scintillation on GPS/Satellite-Based Augmentation System availability*, Radio Science 38(1) — tracking-loop error variance with effective (C/N0)·(1 − 2S4²), valid S4 < 0.707 [EXTERNAL — the model named by the code; the ×1/√(1−2S4²) σ amplification is the dominant-term reading of Conker's DLL variance].
  - Kaplan & Hegarty (2006) — "the S4 index … is equal to the standard deviation of the power variation"; phase scintillation PSD "T f^−p with p in the range of 2.0–3.0" (p. 296) — supports modelling phase jitter as a *correlated* (non-white) process, exactly what the per-tower GM does.
  - Carrano & Rino (2016) / ITU-R P.531 — weak-scatter S4 ∝ f^−n with n = (p+3)/4; multi-satellite observations 30 MHz–6 GHz give n between 1 and 2, nominal ~1.5 [EXTERNAL].
- **Critical analysis**: Three findings. (1) **Degenerate default**: with S4zen = 0 the 'conker' branch returns σ = σ_L1·(f_L1/f)^1.0 — constant 0.3 m, no elevation dependence, no fading dynamics, and the amplitude-GM state becomes inert (it only enters through S4). This 0.3 m is injected into the truth code observable *and* into R (`CodeMeasurementBuilder.m:333-339, 415`), i.e. the default run carries a flat noise floor labelled "scintillation". Switching model from 'legacy' to 'conker' at S4zen = 0 silently *dropped* the legacy 1/√sin e elevation factor and amplitude modulation. This should either be documented as a deliberate C/N0-floor proxy or S4zen given a nonzero default. (2) **Frequency scaling**: the exponent 1.0 applies to σ, and S4 itself is never frequency-scaled in the conker branch — physically S4(L2)/S4(L1) ≈ (f1/f2)^1.5 ≈ 1.45, so dual-frequency scintillation is understated; the knob exists (`frequencyExponent`) but its default and its attachment point (σ, not S4) are both weakly justified. **[UPDATED 2026-08-11]** The attachment point is now addressed: `scintillation.s4FrequencyExponent` applies the dispersive law to **S4 itself** inside the Conker fading factor, via the same `climatologyAnchorScale` helper the delay constants use. It ships **default 0**, which makes the scale exactly 1.0 and leaves every existing result bit-identical, and it is deliberately NOT set to 1.5 under realism grade yet — because the direction is the uncomfortable one. L2 is *below* L1, so 1.5 puts **45% more** S4 on the L2 row, and with `S4zen = 0.3` live in the golden and the `min(0.7)` clamp already firing on ~a third of epochs, that drives more L2 rows into the clamp where σ pins at 0.30/√0.02 = 2.121 m. The clamp rate must be measured before it is enabled; doing so re-cuts every realism golden. (3) The obliquity exponent 0.9 on (1/sin e) for S4 and phase jitter is plausible (Rino-type (sec θ)^((p+1)/4) geometry) but uncited in the code. Done well: the phase scintillation is a per-tower Gauss-Markov *truth* perturbation (τ ≈ 1.5 s), not white noise in R — matching the Kaplan p. 296 spectral description — and it is gated off by default with zero RNG consumption, keeping the carrier golden intact.

### Gaseous absorption (ITU-R P.676) and link closure

- **Code**: Frozen zenith table in `+models/+atmosphere/GaseousAbsorption.m` (dry and wet columns kept separate; `ZWD_REF_M = 0.095669`), composed onto a slant path as `A_dry·m_h(e) + A_wet·m_w(e)·(ZWD_tower/ZWD_ref)` using the same `MappingFunctions` the troposphere uses. Subtracted from C/N0 in the one shared helper `MeasurementModelUtils.cn0CodeSigma` (`cn0_dBHz = base + elevGain·sin e − A_gas`), which both `codeSignalSigma` and `ErrorChain.computeCodeSigmaVec_` now call. Generator: `analysis/p676_annex1.m` + `analysis/generate_gas_absorption_table.m` (plain MATLAB, no toolbox, 0.2 s). Gate `cfg.atmosphere.gaseousAbsorption.enable`, **default false**. Resolve-time link-closure refusal `ConfigFactory:linkDoesNotClose` (zenith / best-case test) with threshold `cn0.minTrackable_dBHz = 25`.
- **Verdict**: ✅ Implementation verified to machine precision against an independent transcription, and **both line tables verified row-by-row against the Recommendation itself** (44/44 oxygen, 35/35 water vapour, 0 mismatches).
- **Sources**:
  - Recommendation ITU-R P.676-13 (08/2022), Annex 1 — line-by-line method; Table 1 (44 oxygen lines), Table 2 (35 water-vapour lines), equations (1)–(9). **Both tables read directly from the Recommendation and compared row-by-row — reproduce with `analysis/verify_p676_tables.py`.** The PDF release is a scanned image with no text layer and cannot be used; the **Word release** (`R-REC-P.676-13-202208-I!!MSW-E.docx`) stores the tables as real Word tables, and a .docx is zipped XML. Parsing needs three document conventions undone: EN DASH for the minus, the leading zero omitted (`.1079`), and a SPACE as the thousands separator (`1 780.000000`).
  - Recommendation ITU-R P.676-13, Annex 2 — closed-form approximation, implemented separately as `analysis/p676_annex2.m` and retained only as an independent cross-check.
  - Recommendation ITU-R P.835 — mean annual global reference atmosphere (US Standard Atmosphere 1976 layers; ρ(h) = 7.5·exp(−h/2) g/m³), the profile the zenith integration uses.
  - MathWorks `gaspl` (Phased Array System Toolbox, R2025b), an independent transcription of P.676-10 Annex 1 — used ONLY to validate the generator; no runtime dependency.
- **Critical analysis**: **What is proven.** The dry path of `p676_annex1.m` reproduces the independent `gaspl` transcription with relative error **exactly 0.00e+00** at all nine ladder frequencies, so equations (1)–(9) are correct rather than merely plausible. Separately, **both line tables were read out of the Recommendation and compared row-by-row: 44/44 oxygen and 35/35 water vapour, zero value mismatches.** That closes the gap this entry previously flagged — Table 2 was revised between P.676-10 and -13 (22.235 GHz `b1` 0.1130 → 0.1079, `b3` 28.11 → 26.38, 1780 GHz line by 21%), so no v10 implementation could corroborate it and it had a single source until the Word release was parsed. **Measured effect (A/B, 3600 s, one flag differing).** At L-band the largest movement in any of 175 summary metrics is 0.061% and position RMS moves 0.029% (0.47 mm on 1.6 m) — which is why absorption is deliberately NOT part of realism grade and the goldens are not re-cut. At 24.125 GHz code NIS moves 2.76% while position moves −0.049%, i.e. it changes the weighting and not the answer. **The one place it is decisive** is 61.25 GHz: 161.47 dB at zenith takes a nominal 51 dB-Hz link to −110.5 dB-Hz, 135.5 dB short of the tracking threshold, so `freq013` is refused at resolve time rather than simulated. Two further limits are stated rather than fixed: 915 MHz sits below P.676's own 1 GHz validity floor (the reference implementation refuses the frequency outright), and the per-tower humidity scaling is available in the class but not wired at the call sites, which do not know their tower index — so the reference ZWD is used, exact below 6 GHz and the dominant remaining approximation at 24 GHz.

### Uplink column fraction "f_seen" (reverse-GNSS specific)

- **Code**: `EnvironmentModel.m:672-691` — `f_seen = clamp(B + T·(1 − exp(−(h_sat − h_peak)/H_top)), 0, 1)`, defaults B = 0.30, T = 0.55, h_peak = 350 km, H_top = 100 km; scalar `topsideFraction` default 1.0 (`masterConfig.m:763`, GEO).
- **Verdict**: ✅ Physically sound *in intent and in the GEO default* (and explicitly labelled "[ILLUSTRATIVE]" in code); note this is a **TEC column fraction**, not a Doppler-shifted frequency — no Doppler-modified frequency is used anywhere in the iono scaling (`SignalDefinition.ionoScale` uses static carrier frequencies).
- **Sources**:
  - Kaplan & Hegarty (2006) — the standard single-shell geometry (Fig. 7.4, p. 313) presumes the receiver above the whole layer; for a ground-to-GEO uplink the ray traverses the entire ionosphere plus plasmasphere, so f_seen = 1 is the correct limit.
  - Code's own admission — `ionoTopsideFraction_` marks the exponential parameterisation "[ILLUSTRATIVE]" (`EnvironmentModel.m:677`) — honest labelling of an uncited profile model.
- **Critical analysis**: The concept is right and matters only off the default path: a GEO asset (36000 km, above the plasmasphere bulk) sees essentially the full vertical column, so the default 1.0 is exact for this simulation's headline scenario; a 550 km LEO sees only the column below it, and the default parameterisation gives f_seen(550) = 0.30 + 0.55(1 − e⁻²) ≈ 0.776 — consistent with a Chapman-layer estimate (~⅓ of TEC below the 350 km peak plus most of one topside scale height). Criticisms: (i) the name and comment are inverted — the docstring says a LEO sees "only a topside fraction" when the quantity is the fraction of the column *below* the satellite (bottomside + partial topside); (ii) B/T/H_top are invented shape constants with no citation (an IRI-derived fraction would be citable); (iii) plasmaspheric TEC (up to ~10% of daytime column, more at night) means even GEO f_seen = 1 slightly *understates* nothing — it is the right bound because the truth VTEC is itself the total column. Since it is gated, labelled, and defaults to the exact GEO value, this is acceptable for a feasibility simulation.

### Formation-shared atmosphere gate (correctness feature)

- **Code**: `+models/+noise/SharedAtmosphereRng.m` (formation-wide RNG root; default seed 7201), `EnvironmentModel.m:99-110, 131-147, 174-209` — when `cfg.atmosphere.sharedAcrossFormation.enable = true`, all four stochastic states (tropo wet GM, iono TEC GM, scintillation amplitude, phase scintillation) draw from epoch-keyed substreams of a formation-wide seed, with grid-dt catch-up replay so an asset that skipped epochs (no visible towers) still lands on the identical realisation.
- **Verdict**: ✅ A genuine correctness feature, quantitatively argued and carefully engineered; default-off for golden stability.
- **Sources**:
  - `SharedAtmosphereRng.m` header — "ray paths to one tower diverge by 2000/36e6 rad = 11 arcsec: ~0.5 m of separation at the top of the troposphere and ~18 m at a 350 km ionospheric pierce point" — all three numbers independently recomputed and confirmed (5.6e-5 rad ≈ 11.5″; 0.56 m at 10 km; 19.4 m at 350 km), all far inside tropo (~km) / iono (~tens of km) decorrelation lengths and the L-band Fresnel scale √(λz) ≈ 260 m.
  - Li et al. (2023) — spatially correlated atmosphere is the basis of all differential/regional correction techniques (pp. 1716-1721) — two rays 19 m apart at the pierce point are, for every practical purpose, one ray.
- **Critical analysis**: Without the gate, each swarm asset roots its atmosphere at its own seed (the `RngRegistry` key has no asset field), so satellites 2 km apart at GEO draw *independent* atmospheres and any between-satellite differenced ground observable inherits √2× the full atmospheric error instead of ~0 — 2-3 orders of magnitude too pessimistic, which invalidates differenced-observable studies. Re-rooting (rather than adding an asset key pinned to a constant) is correctly identified as the only lever that works, and the epoch-keyed pure-function draw (`epochStream(src, node, 0, 0, ep)`) makes the realisation independent of per-asset call history — the subtle desync trap (an asset skipping epochs with no visible towers) is handled by grid-dt replay with an explicit guard against unbounded catch-up. The header also correctly distinguishes this from the blunt `cfg.rng.independentStreams.enable=false`, which would collapse *all* noise streams. The one physical simplification: sharing makes the atmosphere *perfectly* common-mode (correlation 1.0), whereas reality leaves a mm-level decorrelated residual (the header itself estimates 0.006–1.6 mm) — negligible against the observables studied, but worth one sentence in the paper.

### Legacy façades and documentation claims

- **Code**: `models/atmosphere/troposphere.m` and `models/atmosphere/ionosphere.m` — mode-dispatched façades delegating verbatim to `TroposphereModel` / `IonosphereModel`; both hard-error on `mode='truth'` with pointers to the stateful `ErrorChain`. `docs/atmosphere_realism.md` — the repo's own sourcing table.
- **Verdict**: ✅ No duplicated physics (the "legacy versions" are thin delegating shims, not divergent implementations); the docs' verified-physics table survives adversarial recomputation with one soft spot.
- **Sources**: `docs/atmosphere_realism.md` reference table rows — each recomputed in this audit: 0.162/0.267 m/TECU ✓; c1/c2 = +2.5457/−1.5457 ✓; 0.0022768 m/hPa and 2.307 m ✓; M(5°) = 3.04 ✓; Niell 10.13/10.75 vs 11.47 ✓; Klobuchar ≥50% (Kaplan & Hegarty 2006, p. 313) ✓; 2nd-order 0–2 cm (Li et al. 2023, Table 5, p. 1720) ✓.
- **Critical analysis**: The façades cannot move the golden (standalone, delegating) and refusing to fake a stateless 'truth' draw is the right call — the truth realisation is a path-dependent GM state. Docs nits: (i) the shorthand "I = 40.308·STEC/f²" (docs line 81) omits the 10¹⁶ TECU conversion that the code and the same line's K_L1 correctly include — a units-sloppy sentence over a correct implementation; (ii) the docs' Klobuchar row cites "IS-GPS-200" while `ConfigFactory` still stamps `klobucharStatus='notImplemented'` (see the Klobuchar feature above); (iii) the before/after table's numbers (0.11 m tropo RMS, ~1.7 m single-frequency iono residual, ~1.6 cm higher-order) are consistent with the configured σ/τ and the Klobuchar ~50% removal claim, and the acceptance test `test_realistic_atmosphere_residuals` pins them — good evidence hygiene.

#### References (APA 7)

- An, X., Meng, X., & Jiang, W. (2020). Multi-constellation GNSS precise point positioning with multi-frequency raw observations and dual-frequency observations of ionospheric-free linear combination. *Satellite Navigation, 1*, 7. https://doi.org/10.1186/s43020-020-0009-x
- Barba, P., Ramírez-Zelaya, J., Jiménez, V., Rosado, B., Jaramillo, E., Moreno, M., & Berrocoso, M. (2023). Tropospheric and ionospheric modeling using GNSS time series in volcanic eruptions (La Palma, 2021). *Engineering Proceedings, 39*(1), 47. https://doi.org/10.3390/engproc2023039047
- Carrano, C. S., & Rino, C. L. (2016). A theory of scintillation for two-component power law irregularity spectra: Overview and numerical results. *Radio Science, 51*(6), 789–813. https://doi.org/10.1002/2015RS005903 [EXTERNAL]
- Conker, R. S., El-Arini, M. B., Hegarty, C. J., & Hsiao, T. (2003). Modeling the effects of ionospheric scintillation on GPS/Satellite-Based Augmentation System availability. *Radio Science, 38*(1), 1001. https://doi.org/10.1029/2000RS002604 [EXTERNAL]
- Davis, J. L., Herring, T. A., Shapiro, I. I., Rogers, A. E. E., & Elgered, G. (1985). Geodesy by radio interferometry: Effects of atmospheric modeling errors on estimates of baseline length. *Radio Science, 20*(6), 1593–1607. https://doi.org/10.1029/RS020i006p01593 [EXTERNAL]
- Enge, P. K. (1994). The Global Positioning System: Signals, measurements, and performance. *International Journal of Wireless Information Networks, 1*(2), 83–105. https://doi.org/10.1007/BF02106512
- European Space Agency. (n.d.). *Klobuchar ionospheric model*; *Mapping of Niell*. Navipedia. https://gssc.esa.int/navipedia/ [EXTERNAL]
- Fritsche, M., Dietrich, R., Knöfel, C., Rülke, A., Vey, S., Rothacher, M., & Steigenberger, P. (2005). Impact of higher-order ionospheric terms on GPS estimates. *Geophysical Research Letters, 32*, L23311. https://doi.org/10.1029/2005GL024342
- International Telecommunication Union. (2019). *Ionospheric propagation data and prediction methods required for the design of satellite services and systems* (Recommendation ITU-R P.531). [EXTERNAL]
- Kaplan, E. D., & Hegarty, C. J. (Eds.). (2006). *Understanding GPS: Principles and applications* (2nd ed.). Artech House.
- Li, X., Barriot, J.-P., Lou, Y., Zhang, W., Li, P., & Shi, C. (2023). Towards millimeter-level accuracy in GNSS-based space geodesy: A review of error budget for GNSS precise point positioning. *Surveys in Geophysics, 44*(6), 1691–1780. https://doi.org/10.1007/s10712-023-09785-w
- Niell, A. E. (1996). Global mapping functions for the atmosphere delay at radio wavelengths. *Journal of Geophysical Research: Solid Earth, 101*(B2), 3227–3246. https://doi.org/10.1029/95JB03048 [EXTERNAL retrieval; cited by the code]
- Osah, S., Acheampong, A. A., Dadzie, I., & Fosu, C. (2021). Comparative evaluation and analysis of different tropospheric delay models in Ghana. *South African Journal of Geomatics, 10*(2), 115–134. https://doi.org/10.4314/sajg.v10i2.10
- Tralli, D. M., & Lichten, S. M. (1990). Stochastic estimation of tropospheric path delays in Global Positioning System geodetic measurements. *Bulletin Géodésique, 64*(2), 127–159. https://doi.org/10.1007/BF02520642 [EXTERNAL]
- Zhang, J., Liang, Q., & Huang, Y. (2026). Establishing high-precision regional real-time ZTD vertical models using ERA5 model-level data and GNSS observations. *Advances in Space Research, 77*(1), 310–328.

---

# Section: Orbital Dynamics & Frames

This section traces the orbital-dynamics, perturbation, frame, and formation-geometry models of oo_v1 against Montenbruck & Gill (2000) — the project's primary orbit-mechanics source — plus Kaplan & Hegarty (2006) for the relativistic clock terms, the IERS Conventions 2010 (EXTERNAL) for the solid-Earth tide, and Clohessy & Wiltshire (1960) (EXTERNAL) for the relative-motion equations. Every constant was checked digit by digit against the extracted source text; every closed-form solution (J2 Cartesian components, the third-body differential form, the Montenbruck & Gill analytic Sun/Moon series, the projected-circular Clohessy-Wiltshire helix) was re-derived or numerically re-verified. Headline result: the implemented physics is correct and traceable, in several places digit-exact against the book; the honest weaknesses are deliberate, documented simplifications (constant-rate Earth rotation, cylindrical shadow, truncated lunar series) rather than errors — with two small caveats worth recording (a mislabeled J2 provenance comment, and a lunar-longitude precession term that only matters if a user moves `epochJD_TT` away from J2000).

### Two-body + J2 acceleration

- **Code**: `+models/+orbit/OrbitDynamics.m:31-51`. Two-body: `a = -(mu/r^3)*r` (line 35). J2 (lines 48-50): `fac = -1.5*J2*mu*Re^2/r^5; a = fac*[(1-5*(z/r)^2)*x; (1-5*(z/r)^2)*y; (3-5*(z/r)^2)*z]`.
- **Verdict**: ✅ Component-by-component exact match with the standard Cartesian J2 gradient; two-body form is Eq. (3.1)/Newton exactly.
- **Sources**: Montenbruck, O., & Gill, E. (2000). *Satellite Orbits* (Ch. 3). M&G derive gravity-field accelerations via the general Legendre recursion (Sect. 3.2); the explicit C2,0 Cartesian form the code uses is the textbook-standard expansion (e.g., Vallado, 2013, Eq. 8-30, EXTERNAL): a_x = −(3/2)J2(μ/r²)(Re/r)²(x/r)(1−5z²/r²), a_z-component factor (3−5z²/r²).
- **Critical analysis**: I expanded the code's factorisation: `fac·(1−5(z/r)²)·x = −(3/2)J2 (μ/r²)(Re/r)²(x/r)(1−5(z/r)²)` — identical, including the crucial `(3−5(z/r)²)` z-component (the asymmetry that makes J2 a zonal, not radial, force). The formula is valid only when +z is the Earth spin axis; `OrbitDynamics.m:42` states exactly that assumption ("Valid when z-axis is aligned with Earth rotation axis (no polar motion)"), which is consistent with the simulation's no-polar-motion frame (see Frames below). At GEO the J2 acceleration evaluates to 8.33e-6 m/s² (verified numerically), matching the code's own docs ("~8.5e-6", `OrbitPerturbations.m:5-6`). Higher zonals/tesserals (J22 is the driver of GEO longitudinal drift) are absent — a documented limitation (`OrbitPropagator.m:13-16`), shared by truth and EKF so it cancels internally, but it means the truth orbit is not a realistic drifting GEO.

### Physical constants (GM, Re, J2, Omega_E)

- **Code**: `+revgnss/Constants.m:14-23`: `EARTH_GM_M3PS2 = 3.986004418e14`, `EARTH_RADIUS_M = 6378137.0`, `EARTH_OMEGA_RADPS = 7.2921150e-5`, `EARTH_J2 = 1.08262668e-3` (comment: "EGM2008").
- **Verdict**: ✅ values correct and single-sourced; ⚠ the J2 provenance comment is wrong (value is JGM-3/EGM96, not EGM2008).
- **Sources**: Montenbruck & Gill (2000) — "GM⊕ = 398 600.4415 km³s⁻², R⊕ = 6378.13630 km) (Tapley et al. 1996)" with JGM-3 C̄2,0 = −484.165368e-6 (Table 3.3, p. 64); "ω⊕ = d(GAST)/dt ≈ 1.002737909350795·(2π/86400 s) = 7.2921158553·10⁻⁵ s⁻¹" (p. 191); back-matter constant list "0.7292115·10⁻⁴ rad/s" (Appendix, p. 377). WGS-84 defines GM = 3.986004418e14 m³/s², a = 6378137.0 m, ω = 7.292115e-5 rad/s (NIMA TR8350.2, EXTERNAL).
- **Critical analysis**: (1) **J2 digit check**: J2 = −√5·C̄2,0 = √5 × 484.165368e-6 = **1.08262668e-3** — the code value is digit-exact against M&G's JGM-3 table (and EGM96, which shares these digits). EGM2008's tide-free value computes to 1.08262617e-3 (differs in the 8th significant digit), so the "(EGM2008)" comment is a mislabel with zero numerical consequence at this precision. (2) **GM/Re** are the WGS-84 values, not M&G's JGM-3 (398600.4415 vs .4418 km³/s²; 6378137.0 vs 6378136.30 m); the fractional differences (7.5e-10 and 1.1e-7) are far below every error budget in the simulation, and using WGS-84 keeps gravity consistent with the WGS-84 geodetic conversion in `GeometryUtils`. (3) **ω choice**: 7.2921150e-5 is the WGS-84 nominal. The precise inertial (ERA) rate is 7.29211514671e-5 and the GMST rate (which a J2000-equinox-fixed ECI would strictly require) is 7.2921158553e-5. I quantified the consequence: 5.3 m/day (vs ERA rate) to 31 m/day (vs GMST rate) of accumulated ECEF-longitude offset at GEO radius. Because truth, measurement model, and EKF all read the same `Constants` value, this is a pure *absolute-frame realism* offset with **zero truth-model mismatch** — internally consistent, honestly declared in `FrameTimeUtils.m:6-15`.

### Luni-solar third-body acceleration

- **Code**: `+models/+orbit/OrbitPerturbations.m:140-144` (`thirdBody_`): `a = GM*( d/norm(d)^3 - r_body/norm(r_body)^3 )` with `d = r_body - r_sat`; GM_SUN = 1.32712440018e20, GM_MOON = 4.9028e12 (lines 20-21). Truth-only, gated, default OFF (lines 2-9).
- **Verdict**: ✅ Exactly the M&G direct-plus-indirect differential form; constants standard.
- **Sources**: Montenbruck & Gill (2000): "¨r = GM·((s−r)/|s−r|³ − s/|s|³) of the satellite's Earth-centered position vector" (Eq. 3.37, p. 69); "Both values have to be subtracted" (p. 69).
- **Critical analysis**: The code implements Eq. (3.37) literally — the direct attraction on the satellite minus the indirect acceleration of the Earth itself — which is the correct Earth-centred form (omitting the indirect term is a classic error; it is not made here). Verified magnitudes at GEO: tidal (differential) acceleration ≈ 7.3e-6 m/s² (Moon) + 3.3e-6 m/s² (Sun), consistent with the header's "~7e-6 m/s² at GEO, comparable to J2's ~8.5e-6" (`OrbitPerturbations.m:5-6`). GM_Moon = 4.9028e12 matches M&G's GM⊕·0.0123000345; GM_Sun = 1.32712440018e20 is the JPL DE-405 value (M&G's own table lists 1.32712438e20; difference 1.6e-8 relative — irrelevant).

### Sun/Moon ephemeris — analytic (M&G Sec. 3.3.2) and DE-440

- **Code**: `OrbitPerturbations.m:87-134` — analytic series: Sun `M = 357.5256 + 35999.049*T`, `lam = 282.9400 + M + (6892/3600)*sind(M) + (72/3600)*sind(2M)`, `rm = (149.619 − 2.499cosM − 0.021cos2M)*1e9` (lines 95-97); Moon fundamental arguments lines 111-115, 14-term longitude series lines 117-120, 8-term latitude lines 123-125, 9-term distance lines 128-130; obliquity `23.43929111 − 0.0130042*T` (lines 98, 131). `+models/+orbit/De440Ephemeris.m:27-45` — real JPL DE-440 via the Orekit bridge (`CelestialBodyFactory.getSun()/getMoon()` in EME2000), gated behind `ephemeris='de440'`.
- **Verdict**: ✅ Sun series digit-exact vs Eq. (3.43); ✅ Moon perturbation terms digit-exact vs Eqs. (3.47)-(3.50); ⚠ two documented-class truncations in the Moon series (see analysis); ✅ De440Ephemeris is a genuine DE-440 reader, not an approximation.
- **Sources**: Montenbruck & Gill (2000): "λ⊙ = Ω + ω + M + 6892″ sin M + 72″ sin 2M, r⊙ = (149.619 − 2.499 cos M − 0.021 cos 2M)·10⁶ km" (Eq. 3.43, p. 71); "Ω + ω = 282°.9400, M = 357°.5256 + 35999°.049·T" (p. 70); "L0 = 218°.31617 + 481267°.88088·T − 1°.3972·T" (Eq. 3.47, p. 72); "βM = 18520″ sin(F + λM − L0 + 412″·sin 2F + 541″·sin l′) − 526″·sin(F−2D) + ..." (Eq. 3.49, p. 72); "rM = (385 000 − 20 905 cos(l) − 3 699 cos(2D−l) − ...) km" (Eq. 3.50, p. 72); accuracy statement: "several arcminutes and about 500 km in the lunar distance" (p. 72).
- **Critical analysis**: I compared every coefficient. Sun: all five numbers exact; the code *adds* the IAU secular obliquity rate (−0.0130042°/cy = −46.815″/cy) that M&G's low-precision model holds constant — a harmless refinement. Moon longitude: all 14 sine terms (22640, 769, −4586, +2370, −668, −412, −212, −206, +192, −165, +148, −125, −110, −55) exact; latitude 8 terms and distance 9 terms exact. Two truncations: (a) the code's `L0 = 218.31617 + 481267.88088*T` **omits M&G's −1.3972°·T term** (the precession correction that refers the longitude to the EME2000 equinox). At the default `epochJD_TT = 2451545.0` (J2000, so T≈0 over any run: masterConfig line 993) the omission is 0.14″ after 24 h — utterly negligible; but if a user sets a 2026 epoch it grows to ~0.37° of lunar longitude, i.e., the series silently returns equinox-of-date rather than EME2000 longitude. (b) the latitude leading term drops the inner "+412″ sin 2F + 541″ sin l′" argument correction — worst case ~0.26° in the argument, ~85″ in β, inside M&G's own "several arcminutes" accuracy class for this model. Both are within the model's advertised fidelity and immaterial for a ≤4 h perturbing-acceleration integral (the header's own honesty note, lines 12-14, says exactly this), but (a) deserves a code comment. The DE-440 path is real (Orekit `CelestialBodyFactory` over `orekit-data`), correctly frames jd_tt as TT and geocentric EME2000 (`De440Ephemeris.m:19-21`), and the repo has already quantified the analytic-vs-DE440 truth gap at ~0.6 m per 4 h (masterConfig lines 1001-1005) — a model whose error is *measured against its replacement* is the right kind of traceability.

### Solar radiation pressure (cannonball + shadow)

- **Code**: `OrbitPerturbations.m:22` `P_SRP_1AU = 4.56e-6` N/m²; `srpAccel_` (lines 146-157): `P = P0*(AU/dist)²`, `a = nu*Cr*(A/m)*P*(d/dist)` with `d = r_sat − r_sun` (points away from Sun); `cylShadow_` (lines 159-169): binary ν∈{0,1}, satellite occulted when behind Earth inside a cylinder of radius Re. Defaults Cr=1.3, A/m=0.02 m²/kg (line 48).
- **Verdict**: ✅ Cannonball model equivalent to M&G Eq. (3.75) with correct 1 AU normalisation and sign; ⚠ cylindrical shadow is a deliberate simplification of M&G's conical/penumbra model.
- **Sources**: Montenbruck & Gill (2000): "P⊙ ≈ 4.56·10⁻⁶ Nm⁻²" (Eq. 3.69, p. 77); "¨r = −P⊙ CR (A/m) (r⊙/r⊙³) AU²" and "CR = 1+ε" (Eqs. 3.75-3.76, p. 79); "commonly used in orbit determination programs with the option of estimating CR as a free parameter" (p. 79); conical shadow model with "half cone angle of the umbra is 0.264° and 0.269° for the penumbra" (p. 81); Cr=1.30 for a high-gain antenna, Table 3.5 (p. 78).
- **Critical analysis**: Expanding the code: a = Cr·(A/m)·P0·AU²·(r_sat−r_sun)/|r_sat−r_sun|³ — identical to Eq. (3.75) except the code uses the *satellite*-to-Sun distance where M&G's simplified form uses the geocentric Sun distance; at GEO the difference is ≤ 2.8e-4 relative and the code's version is actually the more physical one. Sign verified: acceleration along Sun→satellite, i.e., away from the Sun. Magnitude with defaults: 4.56e-6×1.3×0.02 = 1.19e-7 m/s², matching the header's "~1e-7" (line 6). Cr=1.3 matches M&G Table 3.5 (CR≈1+ε, ε=0.30). The cylindrical shadow ignores the penumbra (M&G model it conically with ν∈[0,1]); at GEO, eclipses occur only in ~45-day equinox seasons with ≤72 min umbra, and the penumbra transit adds ~2 min of mis-modelled partial illumination — acceptable for a truth-side realism stressor, and the config exposes `shadow` as a parameter so a conical upgrade has a seam. One structural remark: SRP is truth-only by default (EKF stays J2), but `EkfDynamicsPredictor.m:104-131` can optionally give the EKF its own scaled-SRP dynamics via the estimated SRP coefficient state — exactly M&G's "estimate CR as a free parameter" pattern, correctly implemented as a replacement (not stacked) Cr (line 114).

### Numerical integrator (RK4 + step size)

- **Code**: `OrbitDynamics.m:63-96` — classical RK4, coefficients (dt/6)(k1+2k2+2k3+k4), half-step stage evaluation; time-aware variant `rk4StepWithAccel` evaluates the extra (Sun/Moon/SRP) acceleration at each stage's absolute time (lines 89-92). `OrbitPropagator.m:204` — truth substepping `nSub = max(1, ceil(dt/10))`, i.e., a 10 s maximum step. EKF prediction: one RK4 step per filter step (dt = 1 s, `masterConfig.m:35`).
- **Verdict**: ✅ Textbook-exact RK4; step sizes are conservatively far inside the accuracy regime for GEO.
- **Sources**: Montenbruck & Gill (2000): "Φ_RK4 = (1/6)(k1 + 2k2 + 2k3 + k4)" with "k2 = f(t0 + h/2, y0 + hk1/2), k3 = f(t0 + h/2, y0 + hk2/2), k4 = f(t0 + h, y0 + hk3)" (Eqs. 4.7-4.8, pp. 118-119); "Its local truncation error e_RK4 ... is bound by a term of order h⁵" (Eq. 4.9, p. 119); Sect. 4.1.6 compares RK4 unfavourably to higher-order RK for *high-accuracy, large-step* work (pp. 129 ff.).
- **Critical analysis**: The Butcher tableau matches Eq. (4.8) stage by stage, including the correct half-step time arguments in the time-aware variant (a common bug — evaluating a time-varying force at t0 for all stages — is avoided at `OrbitDynamics.m:90-92`). Step-size adequacy: h = 10 s against a GEO period of 86 164 s gives h/T ≈ 1.2e-4; with RK4's O(h⁵) local error this is orders of magnitude below every measurement noise floor (M&G's own examples use tens-to-hundreds of seconds at this orbit class with higher-order integrators; RK4 at 10 s is *more* conservative). M&G would recommend an embedded/higher-order method (RKF, DP) with step control for efficiency (Sect. 4.1.3-4.1.6), not accuracy, and the truth cache (`masterConfig.m:983-984`, precompute-vectorized) already neutralises the cost argument. The EKF's single 1 s RK4 step per prediction is exact to machine level at GEO curvature. No energy-conservation defect: `specificEnergy_Jkg` is tracked per prediction (`EkfDynamicsPredictor.m:97,134-135`) as a self-diagnostic — good practice.

### State transition matrix (finite difference vs variational equations)

- **Code**: `+filter/EkfDynamicsPredictor.m:150-196` — 6×6 translational STM by *central finite differences*: perturb each of r (±1 m) and v (±1e-3 m/s), 12 full propagations per prediction step; steps configurable (`fdPositionStep_m`, `fdVelocityStep_mps`, lines 169-173). Analytic [I dtI; 0 I] for constant-velocity mode (line 162). Callers: `ReverseGNSSEKF.m:507-514, 588-591`.
- **Verdict**: ⚠ Correct but non-standard: M&G recommend integrating the variational equations; finite differencing is accurate here yet is a known performance liability.
- **Sources**: Montenbruck & Gill (2000): "one ... has to solve a special set of differential equations – the variational equations – by numerical methods" (Sect. 7.2, p. 240); "the concept of the variational equations ... may also be extended to the treatment of partial derivatives with respect to force model parameters" (p. 240); the two-body/Keplerian STM alternative is Sect. 7.1 (p. 235).
- **Critical analysis**: For smooth J2-only dynamics over dt = 1 s, central differences with 1 m / 1 mm/s steps have truncation error O(h²·∂³f) that is negligible, and the GEO round-off floor (position 4.2e7 m × eps ≈ 1e-8 m) is four orders below the 1 m step — the FD STM is numerically sound, and taking the STM about the same (J2 + scaled-SRP) dynamics as the prediction (line 154-155, srpScale passthrough) keeps filter consistency. The costs: 12 extra propagations per step (the prior performance audit attributes ~34% of runtime to finite-difference Jacobians overall), and no access to M&G's elegant sensitivity extension (Sect. 7.2's force-parameter partials — the SRP scale column is instead done by a *second* FD pass, `srpStmColumn`, lines 198-218, exploiting exact linearity in s with a deliberately large ds=10; that trick is clever and numerically justified since SRP is exactly linear in Cr). Verdict stands: scientifically defensible, computationally the known bottleneck, and M&G's variational-equation route is the documented upgrade path.

### Clohessy-Wiltshire helix formation

- **Code**: `+revgnss/SwarmFormation.m:84-99` — Hill-frame offsets `x = (ρ/2)sin(nt+φ), y = ρcos(nt+φ), z = ca·ρ·sin(nt+φ)` with velocities `(ρ/2)n cos, −ρn sin, ca·ρn cos`; Hill basis R = r/|r|, W = r×v/|r×v|, S = W×R (lines 137-141); rotating→inertial `dv_eci = A*(dv_h + cross([0;0;n], dr_h))` (line 148); ICs then propagated with the full (J2) truth dynamics via `OrbitPropagator.propagateFromEciState` (lines 159-167, `SwarmFormation.m:202`). Docs claim boundedness in [baseline, 1.118·baseline] and the no-drift condition ẏ(0) = −2n x(0) (lines 9-19). `+revgnss/OrbitFrame.m:48-71` — RAC basis with the GEO fix v_eff = v_ecef + ω×r; `+revgnss/MultiAssetGeometry.m` — truth-only separation/RAC bookkeeping.
- **Verdict**: ✅ Verified analytically: the coded offsets are an exact bounded solution of the CW equations; the 2:1 ellipse, no-drift condition, and 1.118 bound all check out.
- **Sources**: Clohessy, W. H., & Wiltshire, R. S. (1960). Terminal guidance system for satellite rendezvous. *Journal of the Aerospace Sciences, 27*(9), 653-658 (EXTERNAL — the Hill/CW equations ẍ−2nẏ−3n²x=0, ÿ+2nẋ=0, z̈+n²z=0 and their drift-free solutions). The projected-circular-orbit form is standard formation-flying literature (e.g., Sabol, C., Burns, R., & McLaughlin, C. A. (2001). Satellite formation flying design and evolution. *Journal of Spacecraft and Rockets, 38*(2), 270-278, EXTERNAL).
- **Critical analysis**: Substituting the coded solution into all three CW equations: x-eq gives (−1/2+2−3/2)ρn²sin = 0 ✓; y-eq gives (−1+1)ρn²cos = 0 ✓; z-eq trivially ✓ for any crossAmp (z is an independent harmonic — so the `crossTrackSpread` 3-D fan, lines 101-112, keeps every member on a valid bounded relative orbit, as claimed). No-drift: ẏ(0) = −ρn sinφ = −2n·(ρ/2)sinφ = −2n x(0) ✓ — the secular term −(6nx₀+3ẏ₀)t vanishes identically. The along-track amplitude ρ is twice the radial amplitude ρ/2 — the classic 2:1 CW ellipse. Numerically scanned separation: |Δr|/ρ ∈ [1.0000, 1.11803] = [1, √1.25] — the "1.118*baseline" doc claim is exact. The rotating→inertial velocity map v_i = v_rot + ω×Δr with ω = nŴ is correct for a circular chief, which holds (chief IC is circular, `OrbitPropagator.initialEciState`). Two honest caveats, neither an error: (1) the CW ICs use the *two-body* mean motion n = √(GM/a³) while the truth propagates both chief and deputies with J2 — the common J2 period offset cancels in the relative motion, and the *differential* J2 across a 1 km formation at 42 164 km is ~1e-12 m/s²-scale, so the helix stays bounded in practice (the code re-propagates truthfully rather than trusting the CW solution, which is exactly right); (2) `ringLayout_` (lines 37-82) documents from measurement that `baseline_m` is the ring *radius*, not neighbour separation — an engineering honesty note that fixed a real 27× shape-solve dilution, with the multiRingHelix keeping ~constant chord spacing; the physics per member is unchanged. `OrbitFrame.ecefToRacGeo`'s v_eff = v_ecef + ω×r fix for the degenerate GEO ECEF velocity is the correct inertial-velocity restoration and is what makes RAC decomposition meaningful at GEO.

### Earth orientation / ECI-ECEF transformation

- **Code**: `+models/+frames/FrameTimeUtils.m:24-98` — single-axis rotation R3(θ), θ = ω·t, constant ω; full state transforms v_i = R(v_e + ω×r_e) and inverse (lines 72-90); limitations L1-L5 declared in the header (lines 6-15). `OrbitPropagator.m:219-222` — same model with θ = epochGMST + ω·t and v_ecef = R(−θ)(v_i − ω×r_i). `+models/+frames/TruthEarthOrientation.m` — gated truth-only EOP error: per-tower displacement δr = φ×r with φ = [−yp; −xp; ω_extra·t] (lines 32-41), default OFF.
- **Verdict**: ⚠ Deliberately simplified (no precession, nutation, polar motion, UT1); internally consistent and honestly documented; the transport terms are algebraically correct.
- **Sources**: Montenbruck & Gill (2000): full ICRS↔ITRS chain U = Π·Θ·N·P (Ch. 5); "dΘ(t)/dt = ω⊕[antisymmetric]Θ(t)" with ω⊕ = 7.2921158553e-5 s⁻¹ (Eq. 5.92, p. 191); GMST definition Sect. 5.1.4 (p. 165). IERS Conventions 2010, Ch. 5 (polar motion/ERA) — cited by the code itself (`TruthEarthOrientation.m:13`) (EXTERNAL: Petit, G., & Luzum, B. (2010), IERS TN No. 36).
- **Critical analysis**: I verified the velocity transport algebra both ways: d/dt[R(−θ)r_i] = R(−θ)(v_i − ω×r_i) since rotation about z commutes with ω× — the `OrbitPropagator` and `FrameTimeUtils` forms are exact inverses of each other (and `roundTripStateError` exists as a self-check, lines 92-98). What is missing versus M&G Ch. 5 is the full P·N·Θ·Π chain; the code states this five ways (L1-L5) and scopes itself to "metre-to-sub-metre navigation ... at sub-second flight times" (lines 13-15) — an accurate scope statement, since polar motion (~9 m at the surface for 0.3″) and UT1 error enter *identically* into truth and model here and thus cancel internally. `TruthEarthOrientation` then reintroduces exactly that class of error as a gated truth-only residual: the first-order rotation δr = φ×r with φ = [−yp; −xp; δω·t] matches the small-angle limit of the IERS polar-motion rotation W = R1(yp)R2(xp) applied to an ECEF vector (sign convention: displacement of the *crust-fixed* station as seen in the model frame), and the UT1-rate mapping ms/day → rad/s (line 27) is dimensionally verified: δω = ω·(ms/day·1e-3/86400). This is a sound "what if a real deployment skipped EOP corrections" stressor. Residual realism gap already quantified under Constants: the constant-ω frame accrues 5-31 m/day of absolute longitude offset versus a real precessing Earth — irrelevant to internal consistency, relevant only to absolute-frame claims, which the code does not make.

### Solid Earth tide

- **Code**: `+models/+frames/SolidEarthTide.m:15-48` — degree-2 in-phase displacement, per ground station: `dr = Σ_bodies (GM_b/GM_E)(Re⁴/R_b³)·[h2·r̂·(1.5·cφ²−0.5) + 3·l2·cφ·(R̂_b − cφ·r̂)]` with cφ = r̂·R̂_b (lines 43-47); nominal h2 = 0.6078, l2 = 0.0847 (line 16); Sun+Moon from the M&G analytic series rotated to ECEF (lines 37-40, 53-58). Truth-only, gated, default OFF.
- **Verdict**: ✅ Digit-exact match with the IERS 2010 degree-2 in-phase formula and nominal Love/Shida numbers.
- **Sources**: EXTERNAL — Petit, G., & Luzum, B. (Eds.). (2010). *IERS Conventions (2010)* (IERS TN No. 36), Ch. 7, Eq. (7.5): Δr = Σ_j [GM_j Re⁴/(GM⊕ R_j³)]·{h2 r̂ (3(R̂_j·r̂)²−1)/2 + 3l2 (R̂_j·r̂)[R̂_j −(R̂_j·r̂)r̂]}, with nominal degree-2 values h2 = 0.6078, l2 = 0.0847 (Sect. 7.1.1). Also flagged in-code (`SolidEarthTide.m:11`). Montenbruck & Gill (2000) note the effect qualitatively among station-displacement corrections (p. 43 region).
- **Critical analysis**: Term-by-term: (3cφ²−1)/2 = 1.5cφ²−0.5 ✓; the transverse factor 3l2·cφ·(R̂−cφ·r̂) ✓ (the projection removing the radial component of R̂ is exactly the IERS transverse direction); the amplitude factor (GM_j/GM⊕)(Re⁴/R_j³) ✓. h2/l2 are the IERS *nominal* elastic degree-2 values, exactly as documented. Omitted relative to the full dehanttideinel model (and honestly so, per the header "in-phase term"): degree-3 (h3/l3, ~mm), latitude dependence of the effective Love numbers, out-of-phase/anelasticity terms, and the frequency-dependent corrections — all sub-cm refinements against a modelled effect of "~10-30 cm vertical" (line 4), i.e., the model captures ≥95% of the signal it is meant to inject. Two small internal notes: (1) `eci2ecef_` (lines 53-58) rotates by ω·t only, ignoring `epochGMST_rad`; consistent with the default epochGMST=0 but would desynchronise the tide phase if a nonzero epoch GMST were ever configured; (2) the permanent-tide convention (tide-free vs mean-tide station coordinates) is not addressed — for a *differential truth-vs-model residual* stressor this constant part is absorbed by clock/position states, as the header correctly argues (lines 6-8).

### Relativistic orbital clock terms

- **Code**: `+revgnss/Relativity.m:27-69` — y = (GM/c²)(1/Re − 1/r) − v²/(2c²) [+ (ωRe)²/(2c²)]; circular-orbit inertial speed v = √(GM/r) (line 52); doc states the eccentricity periodic term "−2(r·v)/c² ... EXACTLY ZERO for a circular orbit" (lines 13-14) and "GEO ... y_rel ~ +5.39e-10 (+46.6 us/day)" (line 20). Shapiro delay: other agent's domain — no overlap conflict found (Relativity.m contains clock-rate terms only).
- **Verdict**: ✅ Standard formula, correct signs and frame (explicitly demands *inertial* velocity, the classic GEO trap), and the quoted numbers reproduce.
- **Sources**: Kaplan, E. D., & Hegarty, C. J. (Eds.). (2006). *Understanding GPS: Principles and Applications* (2nd ed.): "the satellite clock frequency is adjusted ... prior to launch" (p. 306); "Exactly half of the periodic effect is caused by the periodic change in the speed ... and half ... in its gravitational potential" (p. 306); Δt = F·e·√a·sin Ek with "F = −4.442807633×10⁻¹⁰ s/m^½" (Eq. 7.4, pp. 306-307); Δf/f = 4.467×10⁻¹⁰ for GPS (p. 123). Montenbruck & Gill (2000): relativistic time scales, Sect. 5.1.3 (pp. 163-165); orbit-dynamics relativistic correction Sect. 3.7.3 (p. 110).
- **Critical analysis**: Recomputed from the code's own constants: grav = 5.95e-10, SR = −5.26e-11, ground rotation +1.20e-12 → y = 5.388e-10 = +46.55 µs/day, confirming the header's "+5.39e-10 (+46.6 µs/day)" to its stated precision. The structure (gravitational potential difference minus v²/2c², ground-rotation velocity term optional) is the standard clock comparison; the code's insistence on ECI speed with the explicit warning that GEO ECEF speed ≈ 0 (lines 16-18) defuses the single most common GEO relativity bug. The periodic-term claim is consistent with Kaplan Eq. (7.4): −2(r·v)/c² is the instantaneous form of F·e·√a·sinE, and r·v ≡ 0 on a circular orbit. Honest omission: the ground clock's potential uses point-mass GM/Re rather than the geoid potential W0 (the J2 contribution ≈ 3.8e-13 fractional) — constant, absorbed by the estimated clock states, as the header argues for the main offset too (lines 21-23; the claim that a constant rate offset is observable and absorbed is correct given the clock-drift state). The relativistic *orbit dynamics* correction (M&G Sect. 3.7.3, ~1e-9 m/s² scale) is absent from the force model — negligible against the µm-to-m budgets here.

### Truth vs EKF force-model separation (scientific honesty)

- **Code**: `config/masterConfig.m:568-580` — truth `j2Rk4`, EKF `dynamics.mode='j2'`, comment "Truth and EKF share the J2 family (not a mismatch)", plus `cfg.validation.enforceModelFamilyConsistency = true`. `config/internal/applyLuniSolar.m:11-24` — gated stressor: truth gains Sun/Moon+SRP, EKF explicitly kept without them (lines 19-20), and `modelMismatch.sigma_mps2 = 1e-5` process noise sized to cover the gap (line 16). `OrbitDynamics.rk4StepWithAccel` header: "TRUTH-ONLY: the EKF uses the base rk4Step ... and never calls this" (lines 83-84). `config/internal/orbitClassConfig.m` — GEO strict no-op; MEO/LEO same-family with retuned SNC; LEO drag gap explicitly documented (lines 22-26).
- **Verdict**: ✅ The default same-family twin is deliberate, declared, and guarded; the perturbation gap is a gated, sigma-covered stressor — with one known config-order defect to flag.
- **Sources**: Montenbruck & Gill (2000): the variational/force-model treatment presumes the estimator's "consider" handling of unmodelled forces (Ch. 7-8 framing); the ~1e-5 m/s² mismatch sigma matches the summed unmodelled accelerations verified above (1.07e-5 m/s² Sun+Moon tidal + 1.2e-7 SRP).
- **Critical analysis**: The architecture separates three regimes cleanly: (1) default — truth and EKF both J2 ("same-family twin"): convergence and filter-consistency results are then *not* force-model-limited, which is scientifically honest only as long as reports say so; the masterConfig comment does say it, and the prior realism audit already classified the default as pervasively optimistic. (2) gated realism — `applyLuniSolar` opens a genuine ~1e-5 m/s² truth-only force gap and simultaneously turns on `modelMismatch` process noise of exactly that size: the sigma is well-sized (matches my computed 1.08e-5 m/s² total unmodelled acceleration). (3) closure — the EKF can optionally be given the same perturbations (`EkfDynamicsPredictor.m:99-131`) or an SRP scale state, closing the gap from the estimation side. Cross-reference (from the prior full audit, still open): the finalizeConfig J2 auto-tuner can silently overwrite the `modelMismatch` sigma set here — a config-resolution defect, not a physics one, but it can quietly invalidate regime (2)'s noise sizing. Also note `masterConfig.m:977-979` sets base defaults to `stationaryEcef` and the scenario assembly upgrades to `j2Rk4` — a two-layer default that the config-resolution trap documentation already covers.

### Geodetic conversion and local frames (supporting)

- **Code**: `+models/+frames/GeometryUtils.m:6-62` — ECEF↔geodetic with WGS-84 a/e² via 5 fixed-point iterations `lat = atan2(z + e²N sinφ, p)`, alt = p/cosφ − N; ENU↔ECEF rotation (lines 49-56); elevation from local-up projection (lines 34-47). `Constants.m:26-29` — f = 1/298.257223563, e² = 2f − f².
- **Verdict**: ✅ Standard WGS-84 machinery; converges to sub-mm in 5 iterations for ground/GEO geometry.
- **Sources**: WGS-84 defining parameters (NIMA TR8350.2, EXTERNAL); the iteration is the standard Hirvonen/Moritz fixed-point scheme found in GNSS textbooks (e.g., Misra, P., & Enge, P. (2006). *Global Positioning System: Signals, Measurements, and Performance*, App. — the Paper copy is a scan with poor text extraction; formula verified independently).
- **Critical analysis**: e² = 2f − f² with f = 1/298.257223563 is definitionally exact; the ENU→ECEF matrix columns are the standard (ê, n̂, û) triad (verified against the local-up vector used in `elevationAngle` — consistent). One naming nit: the comment says "Bowring iteration" but the scheme is the plain geodetic fixed-point iteration (Bowring's method uses the parametric latitude); behaviourally irrelevant. The elevation angle uses geodetic up from the converted latitude — correct (using geocentric up would bias elevation by up to 0.19°).

### ECSS-E-ST-60-10C applicability note

- **Code**: no file in oo_v1 references ECSS (repo-wide grep: zero hits).
- **Verdict**: ❓ Not applicable to this section — the standard is "Space engineering — Control performance" (ECSS, 2008): pointing/control performance indices (APE/MPE/RPE) and error-index budgeting, with no orbital force-model content. The orbital code neither cites it nor makes claims that would need to trace to it. If the thesis later quotes pointing-error indices for the beamforming story, that is where this standard would attach — outside orbital dynamics.

#### References (APA 7)

- Clohessy, W. H., & Wiltshire, R. S. (1960). Terminal guidance system for satellite rendezvous. *Journal of the Aerospace Sciences, 27*(9), 653-658. [EXTERNAL]
- European Cooperation for Space Standardization. (2008). *Space engineering — Control performance* (ECSS-E-ST-60-10C). ESA-ESTEC. [Paper/Error Calculation]
- Kaplan, E. D., & Hegarty, C. J. (Eds.). (2006). *Understanding GPS: Principles and applications* (2nd ed.). Artech House. [Paper/Fundamental Books]
- Misra, P., & Enge, P. (2006). *Global Positioning System: Signals, measurements, and performance* (2nd ed.). Ganga-Jamuna Press. [Paper/Fundamental Books; scanned copy, limited text extraction]
- Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications*. Springer. [Paper/Fundamental Books — primary source; pp. 64, 69-72, 77-81, 110, 118-129, 163-165, 191, 235-243, 377 used]
- National Imagery and Mapping Agency. (2000). *Department of Defense World Geodetic System 1984* (NIMA TR8350.2, 3rd ed.). [EXTERNAL — WGS-84 defining constants]
- Petit, G., & Luzum, B. (Eds.). (2010). *IERS Conventions (2010)* (IERS Technical Note No. 36). Verlag des Bundesamts für Kartographie und Geodäsie. [EXTERNAL — Ch. 5 EOP, Ch. 7 Eq. (7.5), h2/l2 nominal values]
- Sabol, C., Burns, R., & McLaughlin, C. A. (2001). Satellite formation flying design and evolution. *Journal of Spacecraft and Rockets, 38*(2), 270-278. [EXTERNAL — projected circular orbit]
- Tapley, B. D., et al. (1996). The Joint Gravity Model 3. *Journal of Geophysical Research, 101*(B12), 28029-28049. [via Montenbruck & Gill Table 3.3 — JGM-3 C̄2,0]
- Vallado, D. A. (2013). *Fundamentals of astrodynamics and applications* (4th ed.). Microcosm Press. [EXTERNAL — explicit Cartesian J2 component form, Eq. 8-30]

---

# Section: Measurement Models & Error Chain

This section traces the physical measurement chain of the oo_v1 reverse-GNSS simulation — pseudorange, carrier phase, Doppler, light-time/Sagnac, relativity, thermal noise, multipath, and antenna geometry — line-by-line against the primary GNSS literature. The geometry is inverted relative to classical GNSS (ground towers **transmit**, GEO satellites **receive**), so every sign convention was checked in the uplink sense: the receiver clock is the spacecraft clock (+b_rx) and the transmitter clock is the tower clock (−b_twr), the mirror image of Enge's user/satellite roles. Overall verdict: the observation equations, the iono sign flip, the light-time/Sagnac double-count guard, and the Shapiro formula are **correct**; the frequency-independent multipath, the zero-magnitude default PCO, the constant-sigma default thermal noise (contradicting the repo's own ERROR_BUDGET wording), the missing eccentricity clock term, and the absent phase wind-up are the genuine weaknesses. One repo-doc claim (relativistic clock "disabled by the v1 sanitiser") is stale. All physical constants funnel from a single source (`+revgnss/Constants.m:11-21`: c = 2.99792458e8 m/s, μ = 3.986004418e14 m³/s², ω_E = 7.2921150e-5 rad/s; re-exported at `config/masterConfig.m:2073-2091`), which are the exact WGS84/IERS values.

---

### 1. Pseudorange observation equation (uplink sign conventions)

- **Code**: `+models/+measurements/CodeMeasurementBuilder.m:140` — truth: `z(mi) = rho_true + b_rx_true − b_twr_truth_h + errStruct.truthTotal_m(mi)`; model: line 189 `h(mi) = rho_est + b_rx_est − b_twr_h + errStruct.modelTotal_m(mi)`. `truthTotal_m` is assembled in `+models/+errors/ErrorChain.m:311-321` as code noise + troposphere + ionosphere (+ at code) + hardware delay + multipath (+ higher-order iono when enabled); DCB added at `CodeMeasurementBuilder.m:229-241`. Jacobian clock columns: `CodeJacobianBuilder.m:68` (`H(mi, blk.b) = 1`), line 74 (tower clock −1), line 81 (tx code bias +1). The tower clock is additionally propagated to the **transmit epoch**: `CodeMeasurementBuilder.m:134-139` (`b_twr_truth_h = b_twr − bdot_twr·tau`), and the model side re-evaluates the clock product at `t_tx` (lines 152-179).
- **Verdict**: ✅ Term-for-term identical to the standard pseudorange equation with the transmitter/receiver roles correctly swapped for the uplink; the transmit-time clock evaluation is a genuinely correct (and often-omitted) detail.
- **Sources**:
  - Enge (1994): "The quantity in parentheses is the true pseudorange, which equals the true range (|X_u,g|) from the user (u) to satellite g, plus an unknown offset between the user clock (b_u) and the satellite clock (B_g)" (p. 95, describing ρ = (|X| + b_u − B_g) + I + T + ν, his Eq. 3).
  - Xie et al. (2021), for the uplink specifically: the satellite-side counter equation TI(2) = TS(2) − TS(1) + TX(1) + SPU + SCU + RX(2), "SPU is the propagation delay of the uplink signal transmitted by the ground station; SCU is the Sagnac effect correction of the ground station uplink" (p. 76).
- **Critical analysis**: The structure ρ + b_rx − b_twr + T + I + hw + mp + ε matches Enge Eq. (3) exactly, with I entering **positive** on code as required. The uplink book confirms the same chain (propagation + Sagnac + transmit/receive hardware delays + both clocks) for BeiDou's real uplink measurement. Three honest caveats: (i) the receiver hardware delay defaults to the 'absorbedInReceiverClock' convention (`MeasurementModelUtils.rxCodeBiasModel`, lines 186-206 return 0) — legitimate, since an uncalibrated common rx delay is unobservable from one receiver, but it means the reported clock bias is clock+delay; (ii) the tower survey/PCO/PCV contributions are computed as **range-domain differences of shifted geometries** (lines 77-121), which is exact rather than linearized — good; (iii) the shared-tower off-diagonal R block (lines 743-779) correctly promotes the common tower-clock product error to a block covariance instead of leaving R diagonal, an uncommonly honest choice.

### 2. Carrier-phase equation and the ionosphere sign flip

- **Code**: `+models/+measurements/CarrierMeasurementBuilder.m:245` — `z_phi = rho_t + b_rx_true − b_twr_t + trop_t − iono_t_sig + B_true + noise_phi + phaseScint_m + b_ia_m`; model at line 263 with the same −iono; header contract lines 16-21 ("CRITICAL: ionosphere sign is NEGATIVE for carrier (phase advance), opposite to +iono for code"). The slant-iono EKF H column is also negative: lines 344-350 (`H_phi(rowOut, blk.iono(ti)) = −(fL1c/fSigc)^2`), consistent with the +(f_L1/f)² code column in `MeasurementModel.m:217-243`. Per-signal iono scaling via `ionoScaleRelativeToL1 = (f_L1/f)²` (`SignalDefinition.m:131`). Float ambiguity B is one per (tower, antenna, signal) arc, born from a persistent keyed draw (lines 141-153). Carrier sigma default 0.005 m (line 59; `masterConfig.m:2711`).
- **Verdict**: ✅ The iono sign is negative on carrier in z, h, **and** H; troposphere is positive on both observables; the λN term is a float-metres ambiguity per arc — all textbook-correct.
- **Sources**:
  - Enge (1994): "ionospheric refraction delays the envelope of the signal and adds the term I_u,g to the code-phase observation. The ionosphere is dispersive, so I_u,g is subtracted from the carrier-phase observation" (p. 96).
  - Kaplan & Hegarty (2006): "the magnitude of the error on the pseudorange measurement and the error on the carrier-phase measurement (both in meters) are equal—only the sign is different" (p. 302).
- **Critical analysis**: The equal-magnitude/opposite-sign property (code-carrier divergence) is exactly implemented because both observables read the **same** `bySource` iono realisation. Two design choices deserve scrutiny. First, R for carrier rows deliberately excludes the tower-clock product sigma (lines 279-282) on the argument that the float ambiguity absorbs any constant per-arc bias — correct reasoning, and the time-varying part is separately charged through the age-weighted product-drift block (lines 366-377); this is more careful than the common practice of inflating carrier R. Second, the truth-only inter-antenna carrier bias (R-6, lines 227-242) is added to z but never to h, so the estimator genuinely does not know it — a proper truth/model separation. The 5 mm carrier sigma is conservative against Kaplan's 1.2-1.6 mm PLL noise (p. 319), appropriate for a feasibility study. Remaining gap: no carrier multipath and no wind-up term (see §8, §11), so the carrier error budget is thinner than the code budget.

### 3. Doppler / range-rate model

- **Code**: `+models/+measurements/DopplerMeasurementBuilder.m:174` — `zd = rhoDot_true + bdot_rx_true − bdot_twr + noise`; model line 193. Range rate from `+revgnss/OneWayRangeRateModel.m:58-61`: `rhoDot = u_los'·v_rx_ecef + sagnacRate` with `sagnacRate = ω_e(u_y·Δx − u_x·Δy) = u'·(ω×Δ)` (line 55), equivalent to the ECI formulation u'·(v_rx,eci − v_tx,eci) (header lines 9-11); the tower ECI velocity (≈465 m/s equatorial) is explicit (line 50). H columns: `Hd(mi, blk.v) = u_e'`, `Hd(mi, blk.bdot) = 1` (lines 203-204); the d(ρ̇)/dr partial is implemented (`OneWayRangeRateModel.positionPartial`, lines 78-105: (v_eff' − ρ̇u')/ρ + u'[ω×]) but **gated off by default** (`masterConfig.m:2128`). Light-time rate: `lightTimeRateHandling = 'metadataOnlyV1'` (line 250). Doppler rows are excluded outright if an iono rate term is enabled without a dispersive-rate model (lines 63-76). Sigma default 0.01 m/s (`masterConfig.m:2122`).
- **Verdict**: ⚠️ The observable (LOS velocity projection + receiver clock drift − transmitter clock drift + Earth-rotation rate term) is correct and frame-consistent; the approximations (no position partial in H by default, no light-time rate, no relativistic Doppler) are real but small at GEO and are explicitly declared in metadata rather than silently absorbed.
- **Sources**:
  - Enge (1994): "Carrier frequency or Doppler shift, which measures the time rate of change of the pseudorange" (p. 92).
  - Kaplan & Hegarty (2006): "This offset can be related to the drift rate ṫ_u of the user clock relative to GPS system time" (p. 59, Eq. 2.40 context, received frequency f_Rj = f_j(1 + ṫ_u)).
- **Critical analysis**: The clock-drift term with the correct signs (+ḃ_rx − ḃ_twr) matches Kaplan's §2.5 velocity formulation transposed to the uplink. The Sagnac-rate term u'·(ω×Δ) is the exact time derivative of the first-order Sagnac range correction, and carrying it in **both** z and h ('capturedByTowerVelocityTerm', line 249) prevents a systematic ~0.1-0.8 m/s bias. The omitted d(ρ̇)/dr Jacobian column is a documented approximation whose magnitude (~1e-5/m per the code comment, i.e. <1 mm/s for 100 m position error) is genuinely negligible at GEO — and the gated implementation lets a non-GEO run enable it. The light-time rate correction (order v·ρ̇/c ~ 1e-8 of ρ̇) is honestly declared metadata-only. Weakness: the truth Doppler carries **no atmospheric rate contribution at all** (tropo/iono rates are zero in zd), which is optimistic for low-elevation links during scintillation; the guard at lines 63-76 at least refuses the configuration where this would matter most. Note also the earlier audit's "Doppler + towerClockStates R gap" now has an explicit fix: the drift-column mask `maskStateTowerSigma_(…, col=2)` at lines 141-150 prevents charging the product drift sigma into R when the drift is an EKF state.

### 4. Iterative light-time solution and the Sagnac double-count guard

- **Code**: `+models/+frames/LightTimeSolver.m:77-100` — fixed-point iteration: initial `tau = |r_rx − r_twr|/c`, then per iteration `r_twr_rot = Rz(ω·tau)·r_twr_nominal` with `Rz = [cosθ sinθ 0; −sinθ cosθ 0; 0 0 1]` (lines 84-88) and `tau_new = |r_rx − r_twr_rot|/c`, to `tol_s = 1e-12` (max 5 iterations; default config 2, `masterConfig.m:93-94`). The additive first-order Sagnac `dR = (ω/c)(x_tx·y_rx − y_tx·x_rx)` lives in `+models/+corrections/RangeCorrections.m:24-37` and is **skipped in iterative mode**: `RangeCorrections.m:108-115` ("skip when iterative mode handles it via rotation"); `LightTimeSolver` comment line 33 ("Do NOT also rotate the tower position if using this correction"); and `+revgnss/ConfigFactory.m:1025-1037` (mode 'iterativeOneWay' → forcibly `sagnac.truth/model.enable = false` + the Stage-80 warning "separate Sagnac truth/model disabled to prevent double counting"). Iterative mode also forces a finite-difference H (`MeasurementModelUtils.m:68-76`) because dρ/dr = u' is no longer exact.
- **Verdict**: ✅ The iteration is the textbook fixed-point light-time solution; the rotation matrix is the standard ECEF-transmit→ECEF-receive frame transport R₃(+ωτ); and the double-count guard is enforced at **three** independent levels (config sanitiser, correction router, solver doc).
- **Sources**:
  - Montenbruck & Gill (2000): "Starting from an initial value of τ(0) = 0 the light time is consecutively determined using the fixed-point iteration τ(i+1) = 1/c · |r(t − τ(i)) − R(t)|" (p. 210, Eqs. 6.22-6.23).
  - Kaplan & Hegarty (2006): "If left uncorrected, the Sagnac effect can lead to position errors on the order of 30m [12]. Corrections for the Sagnac effect are often referred to as Earth rotation corrections" (pp. 306-307).
  - Li et al. (2023) give the receiver-side maximum as "about 153 ns" (p. 1714), i.e. ~46 m — consistent with the tens-of-metres magnitude at GEO ((ω/c)·x_tx·y_rx ≈ 65·sin Δλ m for an equatorial tower).
- **Critical analysis**: I verified the two paths agree analytically: linearising |r_rx − Rz(ωτ)r_tx| in ωτ reproduces (ω/c)(x_tx·y_rx − y_tx·x_rx) exactly, so the first-order and iterative modes are mutually consistent and the forced-disable prevents the classic double-count. Convergence is guaranteed (contraction factor ~|ρ̇|/c ≈ 1e-8), so 2 iterations reach machine noise; tol 1e-12 s ≈ 0.3 mm is appropriate. Honest limitations, correctly documented in the header (lines 8-13): the tower is rotated rather than solving a full ECI two-body problem (exact for an ECEF-static tower, which these are), and polar motion/UT1 are not in the rotation (only ω_E about z) — consistent with the truth-EOP displacement being a separate gated effect (`MeasurementModelUtils.towerPositionEcef:99-105`). One subtlety: in iterative mode `contrib.sagnac` stays 0, so the per-effect "Sagnac contribution" diagnostic vanishes from reports even though the physics is present in ρ — a reporting quirk, not an error.

### 5. Shapiro delay

- **Code**: `+models/+corrections/RangeCorrections.m:40-59` — `dR = (2μ/c²)·log((rr + rt + R)/(rr + rt − R))` with μ = `cfg.physics.muEarth_m3ps2` = 3.986004418e14; degenerate-geometry guard (denominator < 1 m → 0). Enabled truth+model by default (`masterConfig.m:95` master enable expanded to the pair).
- **Verdict**: ✅ Formula and constant exactly match the standard (IERS/textbook) two-way logarithmic form; magnitude ~17 mm for a ground-to-GEO ray (2μ/c² = 8.87 mm, ln-factor ≈ 1.9 at nadir).
- **Sources**:
  - Li et al. (2023): "the Schwarzschild space–time bending adds a time delay on the propagation of electromagnetic waves, known as the Shapiro delay" (p. 1713); "This ranging delay reaches about 60 picoseconds for a MEO satellite and is a little larger for IGSO satellites (~70 picoseconds)" (p. 1714).
- **Critical analysis**: 60-70 ps (18-21 mm) at MEO/IGSO brackets the ~17 mm ground-GEO value the code produces, confirming both formula and order of magnitude. Because truth **and** model apply it identically, it cancels in the innovation and contributes zero estimation error — physically complete but statistically decorative; the ERROR_BUDGET row ("mm-level … enabled") is accurate. The `denom < 1.0` guard is crude (1 m in a ~1e7 m sum) but unreachable for any physical tower-satellite pair. Correctly, this is the **path-delay** term only; clock-potential terms are handled separately (§6), so there is no relativistic double count.

### 6. Relativistic clock corrections

- **Code**: `+revgnss/Relativity.m:27-54` — constant fractional-frequency offset `y = (GM/c²)(1/Re − 1/r) − v²/(2c²) [+ v_g²/(2c²)]`; header derives +5.39e-10 (+46.6 µs/day, ~2.3 km bias over 4 h) for GEO. Wired into the truth clock as a rate term: `ConfigFactory.m:1537-1548` (gated on `physics.relativity.clock.truth.enable`) → `+models/+clocks/ClockModel.m:286-289` (`new_bias_s = bias_s + dt·(fracFreq + relativisticFracFreq) + …`). Default **OFF** (`masterConfig.m:96`). The periodic eccentricity term is explicitly not implemented: `Relativity.m:66` hardcodes `s.periodicResidual_m = 0` ("exactly 0 for a circular orbit").
- **Verdict**: ⚠️ The constant term is correctly derived and correctly argued observable (absorbed by the estimated clock-drift state); its default-off status is defensible; but the −2√(μa)/c²·e·sin E periodic term is absent and is **not** strictly negligible against a 3 cm ambition, and `docs/ERROR_BUDGET.md:57` still claims the effect is "disabled by the v1 sanitiser," which is stale.
- **Sources**:
  - Kaplan & Hegarty (2006): "This effect can be compensated for by [4]: Δt = F e √a sin E_k … F = −4.442807633 × 10⁻¹⁰ s/m^1/2 … this relativistic effect can reach a maximum of 70 ns (21m in range)" (pp. 306-307).
  - Li et al. (2023): "the satellite clock runs faster by about 38 μs per day than a clock on the ground, corresponding to about −4.4647·10⁻¹⁰ s/s for frequency shift" (p. 1712); "A maximum eccentricity of 0.02 for the GPS constellation corresponds to an added relativistic effect of about 45 ns" (p. 1712).
- **Critical analysis**: The GEO number checks out independently: grav term 5.90e-10, SR term −0.53e-10, ground rotation +0.12e-11 → +5.39e-10 = 46.6 µs/day, larger than GPS's 38 µs/day because GEO sits higher (Kaplan's −4.4647e-10 is the *pre-launch frequency-offset* convention; sign conventions are mutually consistent). The code's observability argument is sound: a constant rate is exactly a clock-drift state and the EKF absorbs it, so default-off changes no estimation result — only truth completeness. The gap is the **periodic** term: a real GEO holds e ≈ 1e-4-1e-3 under station-keeping; 2√(μa)/c²·e ≈ 2.9 µs per unit e gives 0.3-3 ns (9 cm-1 m) peak sinusoid at the orbital period. That is above the stated ~3 cm/100 ps target for the high-e end and, being orbit-periodic, it aliases into the radial/clock subspace this simulation already identifies as its weakest direction (radial-clock correlation −1.000). The omission should be listed in ERROR_BUDGET's "Absent terms" with a magnitude, and line 57 should be updated: the current code (ConfigFactory comment lines 1049-1056) *supports* the gated truth-side model — the "sanitiser" claim describes a previous state.

### 7. Thermal noise (code and elevation dependence)

- **Code**: `+models/+errors/ErrorChain.m:364-423` (`computeCodeSigmaVec_`) and per-signal twin `MeasurementModelUtils.codeSignalSigma:144-184`. Three models: `'constant'` σ = σ0; `'elevation'` σ = σ0/max(sin el, sin 5°)^p (p default 1); `'cn0'` σ = σ0·10^(−(C/N0−45)/20) with C/N0 = base + 6·sin(el) dB. Defaults: `masterConfig.m:129` `model='constant'`, `masterConfig.m:1818` `signals.L1.codeSigma0_m = 0.30`, `:1822` L2 = 0.45 m, `:1808` `errors.codeNoise.sigma_m = 0.3`. Truth noise drawn per (tower, antenna, epoch) keyed stream (`ErrorChain.m:270-271`); the same σ enters R (`CodeMeasurementBuilder.m:222-223` with `sigmaFloor`).
- **Verdict**: ⚠️ 0.30 m at L1 is defensible-to-conservative against the literature, and the truth-draw/R pairing is consistent; but the **default is elevation-independent**, contradicting `docs/ERROR_BUDGET.md:18` which advertises "White, elevation-dependent" — the elevation and C/N0 shapings exist only as opt-ins.
- **Sources**:
  - Kaplan & Hegarty (2006): "Typical modern receiver 1σ values for the noise and resolution error are on the order of a decimeter or less in nominal conditions" (p. 319); "the dominant sources of range error in a GPS receiver code tracking loop (DLL) are thermal noise range error jitter and dynamic stress error" (pp. 193-194, introducing the σ_tDLL formula, his Eq. 5.22).
  - Borre et al. (2007): Table 8.6, "Multipath and receiver noise: 1" [m, 1σ] (p. 125).
- **Critical analysis**: 0.30 m sits between Kaplan's "decimeter or less" for modern receivers and Borre's lumped 1 m — a reasonable conservative choice for an uplink receiver whose C/N0 budget differs from GPS downlink. The C/N0 model's mapping σ ∝ 10^(−ΔdB/20) is exactly the 1/√(C/N0) leading dependence of Kaplan's noncoherent DLL formula, but drops the squaring-loss factor [1 + 2/(T·C/N0)] — negligible above ~35 dB-Hz, so acceptable; and no dependence on chip rate or correlator spacing is modelled anywhere (no chip-rate field exists in `SignalDefinition.m`), meaning the L1-vs-L2 noise ratio (0.30/0.45) is an assumption, not a derived quantity. The bigger issue is the default: with `'constant'`, low-elevation links are statistically identical to zenith links, which flatters multi-tower geometries that leans on low-elevation rays; standard practice (elevation weighting 1/sin el or C/N0 weighting) is implemented but must be switched on. The ERROR_BUDGET wording should either say "constant by default, elevation/C/N0 opt-in" or the default should change. Elevation floor 5° (`Constants.ELEVATION_FLOOR_RAD`) consistently guards all mappings.

### 8. Multipath (legacy sinusoid vs WP5 colored Gauss-Markov)

- **Code**: `+models/+errors/ErrorChain.m:711-766` (`multipath_`). WP5 path (opt-in, `coloredGM.enable`, `masterConfig.m:2020-2025`): per-link (tower×antenna) first-order GM state, τ = 60 s, σ_ss = 0.30 m at L1, elevation envelope σ_el = σ_ss/sin(el)^exp (lines 736-737); realised value → truth z, σ_el → R (lines 748-749). Legacy path (when `multipath.enable` with coloredGM off): `amp·sin(0.01·t + el) + 0.1·white` (lines 754-761, amp = 0.3 m, `masterConfig.m:2008-2010`). Both default OFF (`masterConfig.m:131`). Frequency handling: the L1 multipath value is copied **unscaled** onto every other signal's row (`CodeMeasurementBuilder.m:409` reads `truth_m.mp(pi)` per pair; line 415 adds the same `mp_t` into the L2 z; line 437 logs it). Carrier multipath: none — `coloredGM.carrierScale = 0.01` is annotated "(reserved)" (`masterConfig.m:2024`) and no mp term appears in `CarrierMeasurementBuilder`.
- **Verdict**: ⚠️ The colored-GM structure (correlated truth bias + steady-state σ in R) is the right stochastic shape and its magnitude is conservative; but the model is frequency-independent, carrier multipath is entirely absent, and the 60 s correlation time is a moving-constellation number that is physically wrong for a static GEO-tower geometry.
- **Sources**:
  - Kaplan & Hegarty (2006): "we will use typical 1-sigma multipath levels in a relatively benign environment of 20 cm and 2 cm, respectively, for a wide bandwidth C/A code receiver's pseudorange and carrier-phase measurements" (p. 319).
  - Zhang et al. (2024): "The multipath errors produced by carrier signals of different wavelengths are also different" (p. 4); reflection phase θ = 4πH sin z/λ (p. 3, Eq. 1); "for the coarse acquisition (C/A) code, the impact of the multipath may reach 10~20 m" (p. 2).
- **Critical analysis**: σ_ss = 0.30 m vs Kaplan's benign 0.20 m is suitably conservative, and putting the elevation-scaled steady-state σ in R while the filter never sees the realisation is the correct information treatment. Three substantive criticisms. (1) *Frequency independence*: Zhang et al.'s Eq. (1) makes the multipath phase explicitly λ-dependent, and code multipath additionally depends on chip rate; copying the identical metres onto L1 and L2 rows makes multipath behave like a non-dispersive (troposphere-like) error, so the IF combination passes it at unit gain instead of the amplified but decorrelated reality — the repo's own ERROR_BUDGET flags this honestly ("Partially (frequency-independent in this model)", line 23). (2) *Correlation time*: τ = 60 s encodes fading driven by GNSS satellite motion. In this scenario both endpoints of the geometry are quasi-static (tower fixed, GEO station-kept), so θ in Eq. (1) barely moves and the true correlation time is hours — meaning a 3600 s arc contains ~1, not 60, independent multipath samples, and any averaging benefit the filter extracts at τ = 60 s is optimistic. The repo's own `masterConfig.m:1370-1372` comment shows awareness ("the correlation time matters more than the sigma") for the ground-rotation solver but the ErrorChain default was not revisited. (3) *Carrier*: Kaplan's 2 cm carrier multipath is 4× the 5 mm carrier noise σ, i.e. would be the **dominant** carrier error if modelled; its absence materially flatters every carrier-based result (float ambiguities, attitude rows, differenced-carrier rotation studies). The legacy sinusoid (fixed 0.01 rad/s, amplitude 0.3 m) is a deterministic toy and should never be cited as a multipath result; both being default-off at least keeps the golden baseline honest.

### 9. Antenna PCO / lever arms / attitude coupling (audit finding)

- **Code**: Tower side: `+revgnss/GroundTower.m:38-41, 118-126` (ENU `antennaOffset_enu_m` → ECEF phase centre; default zero) plus config-level tower PCO added on top of survey error (`CodeMeasurementBuilder.m:86-99`). Receiver side: body-frame lever arms per antenna (`ReceiverGeometry.m:15-35` default non-collinear ±1 m cross pattern; `MeasurementModel.m:92-131` builds truth/model antenna positions via `applyLeverArm` with separate truth/model lever sets and an optional truth-only calibration residual, lines 109-127). Per-effect range contributions logged separately (`CodeMeasurementBuilder.m:101-121`). Attitude coupling: attitude Jacobian by finite difference, gated (`CodeJacobianBuilder.m:61-65`, `CarrierMeasurementBuilder.m:307-315`). **Audit finding check**: the MEKF default is `quaternionErrorState` (`masterConfig.m:239`), where the euler slots of x are a post-reset error state ≡ 0. The main measurement path is **fixed**: `ReverseGNSSSimulation.m:508-511` passes `obj.ekf.getMeasurementState()`, and `+filter/ReverseGNSSEKF.m:395-411` substitutes the **nominal-quaternion** Euler angles into the euler slots ("so that h and H are evaluated at the nominal attitude"). The secondary consumer is also fixed: `GroundDifferencedRotationSolver.estimatedEuler_` (`:616-641`) reads `history.nominalQuat_wxyz` and its comment documents the failure mode it replaces ("identically zero at every epoch … would place the lever prediction at IDENTITY attitude while the observable carries the truth attitude").
- **Verdict**: ⚠️ The lever-arm/PCO machinery is symmetric and correct, and the previously-reported "prediction at identity attitude" systematic is fixed on both audited paths; but the **default PCO magnitudes are zero** — `masterConfig.m:2051-2052` sets `receiverOffset_body_m = [0;0;0]`, `towerOffset_enu_m = [0;0;0]` — so `docs/ERROR_BUDGET.md:29` ("Antenna PCO | cm-level | enabled") describes enabled machinery, not an enabled error.
- **Sources**:
  - Schmid (2010): "The PCO describes the vector from the receiver antenna reference point (ARP) or the satellite's center of mass to the mean phase center, whereas the PCV values provide additional zenith- and/or azimuth-dependent corrections" (Tech Talk, ¶2).
  - Li et al. (2023): "Neglecting these millimeter- or even decimeter-level biases could lead to significant errors in other relevant parameters, especially in the station height (up to decimeter-level)" (p. 1723).
  - Leica Geosystems (2014): reference antennas achieve "type-mean phase centre offsets below 1mm" (p. 9) — i.e. calibrated PCO residuals are sub-mm-to-mm, while *uncalibrated* offsets are cm-dm.
- **Critical analysis**: The structure — CoM state, attitude-rotated body lever arm, additive PCO, elevation-dependent PCV hook — mirrors the ANTEX decomposition Schmid describes, and computing each contribution as a difference of full geometric ranges avoids small-angle linearization errors. The honest gaps: (i) with zero default offsets the PCO rows of every default/golden run carry exactly 0 m, so the "cm-level, enabled" budget line overstates the exercised realism; nonzero values (5 cm class) exist only in `ValidationCaseFactory.m:67-161`; (ii) no ANTEX-style PCV by default (`antennaPCV.enable=false`; the 'toy' cos²(el)·5 mm and elevation-only 'table' models exist, azimuth-dependent tables are rejected — `RangeCorrections.m:189-219`), which the repo declares correctly as absent; (iii) the residual attitude risk is well-contained but real: any *future* consumer reading the raw euler rows of `history.x` under `quaternionErrorState` will silently regress to the identity-attitude bug — the defensive error in `estimatedEuler_` ('noEstimatedAttitude') only protects that one path. A repo-wide accessor (all attitude reads through `getMeasurementState`/`nominalQuat`) would close the class of bug rather than the instances.

### 10. Signal definitions (frequencies, wavelengths, chip rates, ISL)

- **Code**: `+revgnss/SignalDefinition.m:107-132` — L1 = 1575.42e6 Hz, L2 = 1227.60e6, L5 = 1176.45e6, wavelength = c/f with c = 299792458 (line 108), `ionoScaleRelativeToL1 = (f_L1/f)²`; guarded experiment-only frequency override (default empty → canonical). `SignalCatalog.m` masks these per config. ISL crosslinks: 26 GHz Ka defaults consistently across the config (`masterConfig.m:2251-2252, 2329, 2397, 2436`; `ISLLinkBudget.m:88`). IF coefficients α = f1²/(f1²−f2²), β = −f2²/(f1²−f2²) (`IonoFreeCombination.m:16-25`) with the √(α²+β²) ≈ 2.98 amplification documented in `docs/ERROR_BUDGET.md:32-44`.
- **Verdict**: ✅ All frequency digits match the ICD/textbook values exactly (λ_L1 = 0.1903 m, λ_L2 = 0.2442 m follow from exact c); chip rates are simply not part of the model (noise is σ-level, not correlator-derived), which is consistent but should be understood as an assumption.
- **Sources**:
  - Kaplan & Hegarty (2006): "there are only two frequencies in use by the system, called L1 (1,575.42 MHz) and L2 (1,227.6 MHz)" (p. 2); "The L5 frequency that was eventually settled upon was 1,176.45 [MHz]" (p. 82).
- **Critical analysis**: Digit-check passes. The single-sourcing through `SignalDefinition.get()` (finalizeConfig, iono scaling, wavelengths, IF diagnostics all funnel through one lookup) is good hygiene, and the process-local override for the uplink frequency battery is correctly documented as experiment-only with golden byte-identity when unset. Two observations: (i) using GPS L-band labels for what is physically an **uplink** service is a modelling convenience — a real reverse-GNSS uplink would sit in an uplink allocation (cf. Xie et al.'s BeiDou uplink chapter), and the repo's own frequency-sweep memory confirms the radial-clock wall is frequency-independent, so the label choice does not distort conclusions; (ii) because chip rate and bandwidth are unmodelled, per-signal code sigmas (0.30/0.45 m) carry the entire signal-structure burden — acceptable for a σ-level simulator, but it means nothing in the code would flag an inconsistent (frequency, chip-rate, sigma) triple.

### 11. Phase wind-up — ABSENT

- **Code**: No implementation anywhere: `grep -r windup/wind-up` over `+models/`+`+revgnss/` returns only declarations of absence — `docs/ERROR_BUDGET.md:55` ("Phase wind-up — absent (no effects.phaseWindup). cm-level on carrier for rotating platforms") and `config/masterConfig.m:2170` ("Phase wind-up and antenna PCV are also declared not-implemented").
- **Verdict**: ❌/✅ Absent (❌ as physics), but honestly declared (✅ as scientific traceability) — and the omission is *material* precisely for the carrier-based rotation/attitude studies this project pursues.
- **Sources**:
  - Li et al. (2023): "This effect is known as Phase Wind-Up (PWU) or phase wrap-up … while it does not exist in pseudo-range observables" (p. 1727); "the effect of PWU … can reach up to one half of the wavelength (Kouba 2015), or more specifically, about 9–10 cm for L1" (p. 1727); Table 9: phase wind-up "~Few cm (up to one-half cycle of wavelength)", residuals "depend on the wavelength and attitude errors" (p. 1738).
  - Wu, J. T., Wu, S. C., Hajj, G. A., Bertiger, W. I., & Lichten, S. M. (1993) [EXTERNAL, the canonical model reference; cited within Li et al. 2023 as Wu et al. (1992)].
- **Critical analysis**: For circularly-polarized signals, any relative rotation between transmit and receive antennas about the boresight shifts the carrier phase 1 cycle per revolution — up to λ/2 ≈ 9-10 cm at L1 before the model correction. In this simulation the receiver is a nadir-pointing GEO whose antenna frame rotates a full 360° per sidereal day relative to each fixed tower: the wind-up is a slow, systematic, arc-correlated carrier drift of ~0.19 m/day/link, **not** noise. A constant part would be absorbed by float ambiguities, but the drift over a 6-24 h arc (the very arcs the turn-angle law says are needed for rotation observability) is exactly the kind of arc-correlated signal the memory shows leaking into rotation estimates at 0.30°/m. Its omission therefore does not merely bound the 3 cm feasibility claim — it is a missing systematic in the ground-referenced orientation observable itself, and should be prioritized above PCV among the absent terms. The declaration in ERROR_BUDGET is accurate; the quantitative statement ("cm-level") should be sharpened to "up to λ/2 per link, drifting one cycle per revolution of relative antenna orientation."

---

### Cross-cutting findings (correct implementations worth highlighting)

- **Correlation-aware IF variance** (`CodeMeasurementBuilder.m:578-663`): instead of the naive R_IF = α²R₁ + β²R₂ (which over-charges non-dispersive sources ~8.9×), the code rebuilds R_IF per source: independent sources at α²/β², troposphere/tower-clock/hardware at unit gain, first-order iono at exactly zero, higher-order iono as the signed α/β combination. This is more rigorous than most textbook treatments and matches the physics of each source class.
- **Truth/model separation discipline**: every effect has separate truth/model gates; 'sameAsTruth' oracle modes are hard errors (`EnvironmentModel.m:250-254, 286-293`); truth draws use identity-keyed RNG streams so realisations are order-independent.
- **Variance double-count guards**: tower-clock product σ masked from R when the clock is an EKF state (`CodeMeasurementBuilder.maskStateTowerSigma_:793-814`, applied to code/carrier-drift/Doppler-drift); ZWD/slant-iono steady-state variance moved out of R when the corresponding state is estimated (`ErrorChain.m:492-512, 656-673`).
- **Documentation drift found**: ERROR_BUDGET.md is stale in three places — relativistic clock "disabled by sanitiser" (now gated-supported, §6), code noise "elevation-dependent" (constant by default, §7), and "Antenna PCO … enabled" (enabled at zero magnitude by default, §9). The Klobuchar row ("notImplemented") is also outdated: a Klobuchar-shaped vertical model exists as `errors.ionosphere.model.correction='klobuchar'` (`EnvironmentModel.m:558-571`).

#### References (APA 7)

- Borre, K., Akos, D. M., Bertelsen, N., Rinder, P., & Jensen, S. H. (2007). *A software-defined GPS and Galileo receiver: A single-frequency approach*. Birkhäuser.
- Enge, P. K. (1994). The Global Positioning System: Signals, measurements, and performance. *International Journal of Wireless Information Networks, 1*(2), 83–105.
- Kaplan, E. D., & Hegarty, C. J. (Eds.). (2006). *Understanding GPS: Principles and applications* (2nd ed.). Artech House.
- Leica Geosystems. (2014). *Leica reference antennas* [White paper]. Leica Geosystems AG.
- Li, X., Barriot, J.-P., Lou, Y., Zhang, W., Li, P., & Shi, C. (2023). Towards millimeter-level accuracy in GNSS-based space geodesy: A review of error budget for GNSS precise point positioning. *Surveys in Geophysics, 44*(6), 1691–1780. https://doi.org/10.1007/s10712-023-09785-w
- Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications*. Springer.
- Schmid, R. (2010, February 3). How to use IGS antenna phase center corrections. *GPS World Tech Talk*.
- Wu, J. T., Wu, S. C., Hajj, G. A., Bertiger, W. I., & Lichten, S. M. (1993). Effects of antenna orientation on GPS carrier phase. *Manuscripta Geodaetica, 18*(2), 91–98. [EXTERNAL]
- Xie, J., Wang, H., Li, P., & Meng, Y. (2021). *Satellite navigation systems and technologies*. Springer. (Chapter 3: Satellite Navigation Uplink and Reception Technology.)
- Zhang, Q., Zhang, L., Sun, A., Meng, X., Zhao, D., & Hancock, C. (2024). GNSS carrier-phase multipath modeling and correction: A review and prospect of data processing methods. *Remote Sensing, 16*(1), 189. https://doi.org/10.3390/rs16010189

---

# Section: Kalman Filter & Attitude Estimation

This section traces the estimation core of the oo_v1 reverse-GNSS simulation — the extended Kalman filter in `+filter/ReverseGNSSEKF.m` (2 301 lines), its dynamics predictor, the multiplicative error-state (MEKF) attitude machinery, the gyro/star-tracker sensor models, and the NEES/NIS consistency apparatus — against the primary sources in the Paper/ folder (Brown & Hwang 3rd ed., Montenbruck & Gill, Naqvi 2013, Naqvi/Abbas 2012, NASA SoA Small Spacecraft 2024, ECSS-E-ST-60-10C, PEET 2013) and, where the folder lacks the canonical reference, external sources (Markley 2003; Solà 2017; Bar-Shalom et al. 2001; IEEE Std 952-1997). Note on Brown & Hwang: `Paper/Error Calculation/KalmanFilter/Brown.pdf` is a scanned image PDF (no text layer, two book pages per PDF sheet; PDF page n = book pages 2n−12/2n−11); all its quotes below were transcribed from rendered page images and are marked accordingly. Headline result: the filter core is textbook-faithful — gain, Joseph form, covariance propagation, clock Q, and the entire MEKF injection/reset cycle match their sources equation-for-equation, and the previously reported `estimatedEuler_` error-state defect is confirmed FIXED in the current working tree. The genuine gaps are calibration-grade, not equation-grade: no chi-square innovation gate on the main measurement stack, an isotropic star-tracker noise model that ignores the 5–10× boresight/twist anisotropy every real unit exhibits, and gyro defaults that are MEMS-class rather than the spacecraft grade the scenario implies.

---

### EKF measurement update: gain and Joseph-form covariance

- **Code**: `+filter/ReverseGNSSEKF.m:703–835` (`update`). Innovation `nu = z − h` (l. 723); innovation covariance `S = H*Pminus*H' + R`, symmetrized (l. 726–727); gain `K = Pminus*H'/S` (right division, no explicit inverse; l. 730); state `x + K*nu` (l. 733); Joseph posterior `Pplus = (I−K*H)*Pminus*(I−K*H)' + K*R*K'`, symmetrized (l. 737–739). All innovation/gain/Joseph operations use the saved prior `Pminus` (l. 719), and step ordering (state, covariance, then attitude reset) is explicit.
- **Verdict**: ✅ Exact implementation of Brown & Hwang Eqs. (5.5.8), (5.5.17), (5.5.18), with the numerically preferred stabilized form as the *only* P-update path.
- **Sources**: Brown, R. G., & Hwang, P. Y. C. (1997). *Introduction to random signals and applied Kalman filtering* (3rd ed.). Wiley. — "Kₖ = Pₖ⁻Hₖᵀ(HₖPₖ⁻Hₖᵀ + Rₖ)⁻¹" (Eq. 5.5.17, p. 217, transcribed from scanned page); "Pₖ = (I − KₖHₖ)Pₖ⁻(I − KₖHₖ)ᵀ + KₖRₖKₖᵀ" (Eq. 5.5.18, p. 218); "Three of these … are only valid for the optimal gain condition. However, Eq. (5.5.18) is valid for any gain, optimal or suboptimal." (p. 218). Montenbruck, O., & Gill, E. (2000). *Satellite orbits*. Springer. — "K = P₀⁻Hᵀ(W⁻¹ + HP₀⁻Hᵀ)⁻¹" (Eq. 8.93, p. 278) corroborates the gain in the orbit-determination setting.
- **Critical analysis**: The implementation is stronger than the textbook minimum: B&H present the short form P = (I−KH)P⁻ as "the usual way to update" (p. 218), while the code hard-wires the Joseph form, which stays valid for suboptimal gain and preserves symmetry/PSD to first order — the right choice given that this same `update()` is reused for pseudo-measurements (clock gauges, ambiguity fixes) where R is artificially tiny and the short form would be fragile. Symmetrization `(P+P')/2` after both predict and update, plus an eigenvalue-classified PSD guard (l. 807–827: benign `tol−minEig` diagonal nudge vs. a genuine nearest-SPD projection with a warning) is defensive numerics beyond the source. The nearest-SPD helper (l. 2283–2289) is a simple eigenvalue clip at 1e−12, not Higham's polar-factor algorithm — adequate for the tiny violations actually observed, and honestly logged via `repairKind`.

### Covariance prediction and the state-transition matrix

- **Code**: `+filter/ReverseGNSSEKF.m:694–695`: `P = F*P*F' + Q` then symmetrize. `buildF_` (l. 1146–1268): position/velocity block from `EkfDynamicsPredictor.finiteDiffStm6` when J2/two-body dynamics are on, else `F(r,v) = dt*I` (l. 1161–1168); clock coupling `F(b, ḃ) = dt` (l. 1220); ZWD/iono first-order Gauss–Markov `phi = exp(−dt/tau)` (l. 1237–1267). `+filter/EkfDynamicsPredictor.m:150–196`: 6×6 STM by *central* finite differences (steps 1.0 m / 1e−3 m/s) about the RK4-propagated J2 trajectory; `propagateEcef` (l. 42–148) converts ECEF↔inertial with a constant-Earth-rotation model and checks energy drift.
- **Verdict**: ✅ Correct P-propagation per Brown & Hwang Eq. (5.5.25); the finite-difference STM is a legitimate (if costly) alternative to variational equations, with honest documented limitations.
- **Sources**: Brown & Hwang (1997) — "Pₖ₊₁⁻ = φₖPₖφₖᵀ + Qₖ" (Eq. 5.5.25, p. 219, transcribed from scanned page). Montenbruck & Gill (2000) — the EKF "may be derived from the basic Kalman filter by resetting the reference state … to the estimate … at the start of each step" (§8.3.3, p. 282), which is exactly the relinearization scheme used here; and P⁻ᵢ = ΦᵢP⁺ᵢ₋₁Φᵢᵀ (Eq. 8.109, p. 283).
- **Critical analysis**: Montenbruck & Gill obtain Φ from the variational equations (§8.1); the code replaces this with 12 extra RK4 propagations per step for a central-difference STM — numerically robust and force-model-agnostic (it automatically picks up the scaled-SRP column, `srpStmColumn` l. 198–218, which exploits the exact linearity of SRP in the scale state with a deliberately large ds = 10), but it is the simulation's known performance bottleneck (~34% per the performance memory) and its accuracy floats on the fd steps. The header block (l. 9–14) plainly lists what the frame model omits (EOP, precession/nutation, drag, relativity) — good scientific hygiene. One structural caveat: when the J2 STM is active, Q for the r/v block is still the constant-velocity white-acceleration Q (state-noise-compensation practice); this is standard but means Q and F are derived from different dynamics assumptions — mitigated by the gated `modelMismatch` inflation (l. 1287–1298), which the audit memory flags as being silently overwritten by a finalizeConfig auto-tuner (config-layer issue, out of this section's scope but load-bearing here).

### Process-noise discretization (white-noise acceleration, exact polynomial form)

- **Code**: `+filter/ReverseGNSSEKF.m:1299–1307`: `q_r = sa²·dt³/3`, `q_v = sa²·dt`, `q_rv = sa²·dt²/2` with both off-diagonal cross terms placed; identically structured attitude/rate block `q_eul = saa²·dt³/3`, `q_omg = saa²·dt`, cross `saa²·dt²/2` (l. 1317–1337, the cross term explicitly called out as "new" in the header, l. 20–25). Random-walk states get `σ²·dt` (ambiguities l. 1406–1434, tx bias l. 1474–1489, SRP scale l. 1374–1376); Gauss–Markov states get the exact steady-state form `σ_ss²(1−phi²)` (ZWD l. 1436–1453, iono l. 1455–1472).
- **Verdict**: ✅ These are the exact closed-form evaluations of Brown & Hwang's Qₖ integral for the double-integrator and Gauss–Markov cases — not an Euler approximation.
- **Sources**: Brown & Hwang (1997) — "Formally, we can write Qₖ in integral form as Qₖ = E[wₖwₖᵀ] = ∫∫ φ(ξ)G E[u uᵀ] Gᵀφᵀ(η) dξ dη" (Eq. 5.3.6, p. 200, transcribed from scanned page; abridged); the worked Gauss–Markov Qₖ with its 2×2 cross-covariance structure is Eqs. (5.3.14)–(5.3.17), pp. 202–203. The identical dt³/3, dt²/2, dt triple appears as their clock Q, Eqs. (11.3.1)–(11.3.3), p. 429.
- **Critical analysis**: Digit-check passes: for ẍ = w with PSD σ², the exact discrete Q is σ²[dt³/3, dt²/2; dt²/2, dt] — matching all six placements in both the translational and attitude blocks. Including the position–velocity and Euler–rate cross terms matters: dropping them (a common shortcut) under-correlates the state and slowly de-tunes the filter; the header even documents that the Euler–omega cross term was a later correctness fix. Freezing disabled states by scaling their Q by 1e−20 rather than zeroing (l. 1323–1330) keeps P invertible for the NEES diagnostics — a pragmatic, documented trick, though it technically leaves an epsilon random walk on "frozen" states.

### Two-state receiver-clock process noise (Brown–Hwang h-parameter model)

- **Code**: `+models/+clocks/ClockModel.m:353–413` (`getProcessNoiseQ`): `q1 = h.h0/2`, `q2 = 2*pi^2*h.hMinus2`, `q_ffm = 2*log(2)*h.hMinus1`; `Q_s = [(q1+q_ffm)*dt + q2*dt³/3, q2*dt²/2; q2*dt²/2, q2*dt (+ q_ffm*dt if driftFlickerInQ)]`, converted to meters via `diag([c,c])`. Consumed at `ReverseGNSSEKF.m:1345–1354` (receiver) and 1357–1368 (tower clocks), filling the full 2×2 including cross terms.
- **Verdict**: ✅ Exact match to Brown & Hwang's GPS receiver-clock model, including the h-parameter mapping; ⚠️ the flicker (h₋₁) handling is a different heuristic than B&H's own compromise model — defensible, documented, but not source-exact.
- **Sources**: Brown & Hwang (1997) — "A suitable clock model that makes good sense intuitively is a 2-state random-process model." (p. 429, transcribed from scanned page); "E[x_p²(Δt)] = S_f Δt + S_g Δt³/3", "E[x_f²(Δt)] = S_g Δt", "E[x_p x_f] = S_g Δt²/2" (Eqs. 11.3.1–11.3.3, p. 429); "S_f ∼ h₀/2, S_g ∼ 2π²h₋₂" (Eq. 11.3.5, p. 431); "Flicker noise gives rise to a term in the variance expression that is of the order of Δt², and it is impossible to model this term exactly with a finite-order state model" (p. 430).
- **Critical analysis**: Digit-check: q1 = h₀/2 ↔ S_f = h₀/2 ✓; q2 = 2π²h₋₂ ↔ S_g = 2π²h₋₂ ✓; all three Q entries match Eqs. (11.3.1)–(11.3.3) term-for-term ✓. The deviation is flicker: B&H's footnote (p. 430, from van Dierendonck) elevates q₁₁ by 2h₋₁Δt² (quadratic in Δt) and q₂₂ by 4h₋₁, whereas the code adds 2·ln 2·h₋₁ = 1.386·h₋₁ per second to the *phase* rate (linear in Δt) — the Allan-flicker-floor coefficient repurposed as a conservative inflation. At the simulation's dt = 1 s the two agree within a factor ~1.4, and B&H themselves declare exact flicker impossible in finite state; the code further exposes `driftFlickerInQ` (default false) with an honest A/B note that enabling it inflates Q₂₂ ~26× without fixing drift-sigma coverage (an observability limit, not a Q bug). This is careful engineering — but any thesis claim should cite the model as "Brown–Hwang WFM+RWFM with a heuristic FFM inflation", not as an exact flicker model. (Separate known truth-side defect from the standing audit — FFT colored-noise synthesis 2/N too quiet — lives in the truth generator, not in this Q.)

### Innovation gating

- **Code**: `update()` computes `NIS = nu'*(S\nu)` (l. 834) *after* unconditionally applying the measurement; no row is ever rejected on a chi-square basis. The only innovation gate in the estimation path is `+revgnss/DiffAttitudeBuilder.m:443,470`: differential-attitude carrier rows are dropped when `abs(z_row − h_row) > 1.0` m (documented at `ReverseGNSSSimulation.m:933–936` as the substitute for the slip detector on those rows).
- **Verdict**: ⚠️ NIS is diagnostic-only; there is no Mahalanobis/chi-square measurement-editing gate anywhere in the filter, and the one existing gate is a fixed 1 m threshold, unsourced.
- **Sources**: Bar-Shalom, Y., Li, X. R., & Kirubarajan, T. (2001). *Estimation with applications to tracking and navigation*. Wiley. (EXTERNAL) — §5.4 defines the normalized innovation squared ε_ν = νᵀS⁻¹ν as chi-square with n_z DOF, which is both the consistency statistic and the standard gating statistic (gate: ε_ν ≤ γ from the chi-square quantile).
- **Critical analysis**: For a clean simulation without outliers, editing-free updates are acceptable and even preferable (a gate can mask model errors that the NEES/NIS diagnostics are supposed to expose — arguably a deliberate design choice here). But the asymmetry should be stated in the paper: the code computes exactly the statistic (`ν'S⁻¹ν`) a textbook gate thresholds, then never thresholds it, while the diffAtt path uses a hand-tuned metric gate (1 m ≈ 10.5 L1 half-wavelengths) whose value is justified only by an inline comment about slip magnitudes. If measurement faults are ever simulated (multipath spikes, cycle slips leaking through), an S-scaled gate at, e.g., χ²₀.₉₉₉ would be the sourced mechanism.

### NEES / NIS chi-square consistency testing

- **Code**: `ReverseGNSSEKF.computeNEES` (l. 838–897): per-block and joint NEES `err'*(P_blk\err)` with backslash and an rcond guard, explicitly citing Bar-Shalom §5.4 in the docstring (l. 842–845); attitude error taken in the MEKF error space via the error-DCM vee operator, not raw Euler subtraction (l. 915–929: `aErr = 0.5*[dC(3,2)−dC(2,3); dC(1,3)−dC(3,1); dC(2,1)−dC(1,2)]`). `+revgnss/ChiSquareConsistency.m:21–47`: two-sided interval `[chi2inv(α/2,dof), chi2inv(1−α/2,dof)]` with a Wilson–Hilferty cube-root fallback (l. 64–68: `(X/dof)^(1/3) ∼ N(1−2/(9dof), 2/(9dof))`) and Acklam's rational normal-inverse (l. 74–98). `+revgnss/MonteCarloConsistency.m:63–158`: multi-seed pooling of post-burn-in NIS (dof = measurement rows) and raw 3-dof position NEES, band-checked against the two-sided interval; one time-averaged centroid sample per seed to avoid over-counting correlated epochs (l. 108–122). `+revgnss/ConsistencyStatistics.m:90–131`: single-run grouped NIS/dof with heuristic 0.5/2.0 warn bands.
- **Verdict**: ✅ The consistency machinery is correctly defined, correctly dof-counted, and unusually self-aware about what a single run can and cannot prove; the single-run 0.5/2.0 bands are heuristics, but the code says so.
- **Sources**: Bar-Shalom, Li & Kirubarajan (2001), §5.4 (EXTERNAL) — NEES ε = x̃ᵀP⁻¹x̃, chi-square with n_x DOF, E[ε] = n_x; NIS ε_ν = νᵀS⁻¹ν, chi-square with n_z DOF; consistency checked by two-sided chi-square probability regions over independent Monte-Carlo runs. Wilson, E. B., & Hilferty, M. M. (1931). The distribution of chi-square. *PNAS, 17*(12), 684–688. (EXTERNAL) — cube-root normal approximation as implemented. Acklam, P. J. (2003). *An algorithm for computing the inverse normal cumulative distribution function.* (EXTERNAL) — all 19 rational coefficients in `normInv_` verified digit-for-digit against Acklam's published values (max abs error 1.15e−9, as the comment claims).
- **Critical analysis**: Three things are done *right* that are frequently done wrong: (1) the code documents that "NIS ≈ M" checks only the mean and replaces it with the two-sided interval (`ChiSquareConsistency.m:10–13`); (2) the R-7 fix in `MonteCarloConsistency.m:100–105` un-does a per-dof double normalization that had produced a spurious "conservative" 0.33 verdict — an instructive, memorialized bug; (3) the centroid gate pools one time-mean per seed precisely because per-epoch centroid NEES samples are time-correlated, and refuses to issue a verdict at all when the realism guards are off ('inconclusiveMatchedCrutch'). Residual nit: the sum of per-seed *time-means* is treated as χ²(3M), but a time-mean has smaller variance than a single χ²(3)/3 draw, so that particular band is mildly conservative in width — direction-safe. The persistent NEES≫1 finding of earlier audits is a real observability wall, not a defect in this machinery (see stochastic-audit memory).

### MEKF: multiplicative error quaternion, injection, covariance reset

- **Code**: `+revgnss/AttitudeErrorStateKinematics.m` — `deltaQuat` (l. 60–72): δq = [cos(‖δθ‖/2); sin·axis], first-order [1; δθ/2] below 1e−10; `injectRight` (l. 74–82): `q_new = normalize(q_nominal ⊗ δq(δθ))`; Hamilton product (l. 160–168). In the filter: nominal quaternion propagated, error state held at zero in predict (`ReverseGNSSEKF.m:533–538`); error-state F blocks `F(θ,θ) = I − [ω]×dt`, `F(θ,ω) = I·dt`, and with gyro `F(θ,b_g) = −I·dt`, `F(θ,ω) = 0` (l. 1170–1190); after each Joseph update the error is injected into the nominal, zeroed, and the covariance reset Jacobian `G = I − 0.5[δθ]×` is applied to the *posterior* P (l. 750–797, reset at 763–770), with a 10° injection guard and condition-number bookkeeping. Measurements are evaluated at the nominal attitude via `getMeasurementState` (l. 395–410).
- **Verdict**: ✅ A textbook local-error (body-frame, right-multiplicative) ESKF/MEKF, including the second-order covariance reset most implementations skip; order of operations (correct → inject → reset, on the posterior) is exactly canonical.
- **Sources**: Markley, F. L. (2003). Attitude error representations for Kalman filtering. *Journal of Guidance, Control, and Dynamics, 26*(2), 311–317. (EXTERNAL; NTRS 20020060647) — "The MEKF represents the true nonlinear state as the quaternion product q(t) = δq(a(t)) ⊗ q_ref(t)" (Eq. 15); "the reset operation moves the attitude information from â(+) to q̂(+), after which â is reset to zero. Since [the] true quaternion is not changed by this operation…" (Eq. 17 context). Solà, J. (2017). *Quaternion kinematics for the error-state Kalman filter* (arXiv:1711.02508). (EXTERNAL) — error injection "q ← q ⊗ q{δθ̂}" (Eq. 282c); reset "δx̂ ← 0, P ← G P Gᵀ" (Eqs. 284–285) with "∂δθ⁺/∂δθ = I − [½δθ̂]×" (Eq. 293); "In major cases, the error term δθ̂ can be neglected … This is what most implementations of the ESKF do." (§6.3). Naqvi (2013, AIAA 2013) in Paper/ cites Lefferts, Markley & Shuster (1982), "Kalman Filtering for spacecraft attitude estimation" — the historical root of this architecture — as its EKF reference.
- **Critical analysis**: Convention consistency was checked explicitly: Markley writes the error on the *left* of an inertial-to-body reference quaternion; the code multiplies on the *right* of a body-to-ECEF quaternion. These are the *same* body-frame local error (C_E_B(true) = C_E_B(nom)·C(δθ) ⇔ A(q_true) = A(δq)A(q_ref)), and the code's F(θ,θ) = I − [ω]×dt, the star-tracker Jacobian C_B_Sᵀ, and the reset sign I − ½[δθ]× are all mutually consistent with Solà's *local*-error column (his Table 4 shows the global-error variant would flip the reset sign to I + ½[δθ]× — the code correctly does not mix columns). The reset is applied to the posterior after Joseph — matching Solà's step order — and the epoch-transition retention machinery folds G into its contraction operator (l. 765–768) so the distributed-covariance layer sees the same algebra. The injection guard warns above 10° rather than failing: correct, since the first-order reset Jacobian degrades with large δθ, and the `maxAttitudeInjectionNorm_rad` history makes abuse observable. The quaternionErrorState/eulerZYX duality is guarded at the constructor (l. 347–353): gyro-bias estimation is *refused* on the Euler path with an error message explaining b_g would be unobservable there — a hard guard where a silent wrong answer used to be possible.

### Known audit finding: `estimatedEuler_` reading the MEKF error state — VERIFIED FIXED

- **Code**: `+revgnss/GroundDifferencedRotationSolver.m:616–679` (`estimatedEuler_`). The current implementation takes the attitude from `history.nominalQuat_wxyz` (written by `logStep` under both parameterizations, `ReverseGNSSEKF.m:2094–2104`), and only falls back to the Euler rows of `history.x` for legacy payloads — where it now *refuses* an all-zero block: "An estimated attitude is never exactly zero at every epoch; an all-zero block is the quaternionErrorState error-state signature … Refuse it so leverArm_ falls back to the symmetric centreOfMass mode instead of an identity-attitude lever." (l. 674–679, reason code `eulerHistoryAllZeroLikelyErrorState`). The docstring (l. 619–626) memorializes the original defect verbatim. The same class of bug is also fixed at the DiffAtt call site: `ReverseGNSSSimulation.m:937–939` uses `getMeasurementState()` "so DiffAttitudeBuilder receives nominal euler (not near-zero error state)".
- **Verdict**: ✅ The audit finding was real and is fixed in the working tree (branch `feature/ground-orientation-exec`, `GroundDifferencedRotationSolver.m` modified in git status); the failure mode (lever-arm prediction at identity attitude re-creating the B1 asymmetry) is now structurally unreachable — an error is raised if `estimatedAttitude` mode is forced without a usable estimate (l. 594–600).
- **Sources**: Internal audit trail (memory: ground-rotation audit 2026-08-05); code comments cited above document the defect and its guard.
- **Critical analysis**: The fix is the right *kind* of fix: instead of patching the one consumer, the attitude source was moved to a representation (`nominalQuat_wxyz`) that is valid under both parameterizations, the poisonous-but-finite signature (all zeros) is detected and named, and the fallback degrades to the symmetric centre-of-mass mode rather than an asymmetric half-fix. The residual risk is legacy `.mat` payloads that predate the quaternion history *and* genuinely hover at zero attitude — rejected as false negatives, which is the safe direction. Whether the paper's headline runs were produced before or after this fix must be checked against run dates; any pre-fix ground-differenced-rotation numbers with `leverArm.mode='estimatedAttitude'` are suspect.

### Gyroscope model: ARW, RRW, units, and the grade of the defaults

- **Code**: `+models/+sensors/IMUModel.m:145–166`: truth gyro `omega_meas = ω_B/I + b_g + (ARW/√dt)·randn` with bias random walk `b_g += RRW·√(biasStep)·randn`; per-sample white covariance `(ARW²/dt)·I` and bias PSD `RRW²·I` handed to the observation (l. 163–166); separate mt19937ar streams per channel (l. 196–203). Same structure in `GyroscopeMeasurementModel.m:61–95`. Filter side: `ReverseGNSSEKF.applyGyroProcessNoise_` (l. 2056–2070): `Qθ = (ARW²·dt + RRW²·dt³/3)·I`, `Qθb = −RRW²·dt²/2·I`, `Qb = RRW²·dt·I`; strapdown propagation with `ω = ω_gyro − b̂_g` (l. 475–482); Earth-rate conversion `ω_B/I = ω_B/E + C_B_Eᵀω_E/I` (`IMUModel.m:179–192`) and its inverse at the nominal attitude (`ReverseGNSSEKF.m:424–449`). Defaults: `config/masterConfig.m:1670–1676` — ARW 1e−4 rad/√s, RRW 1e−6 rad/(s·√s), initial bias 1σ 1e−5 rad/s, truth = filter values; realism grade (`config/internal/realismGradeConfig.m:373–374`) *raises* ARW to 2e−4.
- **Verdict**: ✅ Model equations and their discrete covariances are the standard Farrenkopf/IEEE-952 forms, signs included; ⚠️ the default noise grade is MEMS/industrial, one to three orders worse than the FOG/RLG/HRG units a GEO mission would fly, and bias *instability* (flicker floor) is not modelled at all — the known concern is confirmed.
- **Sources**: IEEE Std 952-1997 (R2008), *Standard Specification Format Guide and Test Procedure for Single-Axis Interferometric Fiber Optic Gyros*. (EXTERNAL) — defines angle random walk as the white angular-rate noise whose Allan deviation slope is −1/2 (σ(τ) = N/√τ, Annex B/C), measured in deg/√h, and rate random walk as the +1/2-slope process — exactly the two stochastic terms modelled. NASA (2024). *State-of-the-Art of Small Spacecraft Technology* (Paper/NASAcomponentReferenceError.pdf) — "Table 5-9 only includes bias stability and angle random walk for gyros … as these are often the driving performance parameters." (p. 158); Table 5-9 (p. 159): Honeywell MIMU (RLG) bias stability 0.05 °/hr, ARW ~0.01 °/√hr; HG1700 ARW 0.125 °/√hr. Farrenkopf, R. L. (1978). Analytic steady-state accuracy solutions for two common spacecraft attitude estimators. *J. Guidance and Control, 1*(4), 282–284. (EXTERNAL) — origin of the ARW/RRW two-parameter gyro error model and its discrete Q.
- **Critical analysis**: Digit-by-digit unit conversion (the task's explicit request): 1e−4 rad/√s × (180/π) °/rad × 60 √s/√h = **0.3438 °/√h** ARW; realism grade 2e−4 → **0.6875 °/√h**; RRW 1e−6 rad/(s·√s) × (180/π) × 3600 × 60 = **12.38 °/h/√h**; initial bias 1e−5 rad/s = **2.063 °/h**. Against NASA Table 5-9: the default ARW is ~3× worse than a tactical HG1700 (0.125 °/√h), ~30× worse than a navigation RLG (MIMU ~0.01 °/√h), and ~10³× worse than a space FOG (Astrix-class, ~1e−4 °/√h); the 2 °/h bias is consumer-MEMS territory. So the simulated "star tracker + gyro" attitude is *pessimistic* on the gyro side while the star tracker (below) dominates steady-state accuracy — a defensible conservative stance, but the thesis must not describe these defaults as representative of a GEO-grade IRU. The Q algebra itself is exact: for δθ̇ = −δb + n_ARW, ḃ = n_RRW the discrete covariance is [ARW²dt + RRW²dt³/3, −RRW²dt²/2; −RRW²dt²/2, RRW²dt] — all three entries and the negative cross-sign match the code. The 1/√dt white-noise discretization in the truth model is the correct sampled-PSD form (R = ARW²/dt), and truth-vs-filter parameter symmetry (same numbers, independent streams) makes the sensor honestly matched. Not modelled (and disclosed in the header, `IMUModel.m:36–37`): scale factor, misalignment, g-sensitivity, quantization, and — more importantly for multi-hour arcs — bias *instability* as a distinct flicker process; RRW alone makes the bias wander unboundedly, which over 24 h arcs overstates bias growth while understating the short-term flicker floor.

### Star-tracker model and its EKF rows

- **Code**: `+models/+sensors/StarTrackerMeasurementModel.m:112–125`: measured quaternion `q_I_S = (q_I_B_true ⊗ q_B_S_true) ⊗ δq(n)`, right-multiplicative angular noise drawn from a full 3×3 covariance via eigendecomposition (l. 220–226); alignment error quaternion with fixed bias, deterministic drift rate, and random-walk drift, plus calibration validity windows and a hard consistency assert that a 'fixedCalibration' cannot carry nonzero uncertainty (l. 177–182). Residual: `+models/+sensors/StarTrackerObservationModel.m:20–51` — innovation `Log(q_I_S_pred⁻¹ ⊗ q_I_S_meas)` expressed in S; `model.attitudeErrorJacobian = C_B_S_modelᵀ`; explicit warning that "alignment is a persistent calibration parameter; do not add its covariance as independent noise at every epoch" (l. 48–49). EKF wiring: `+revgnss/AttitudeSensorSuite.m:121–178` — 3 rows per spacecraft, `H(:,θ) = C_B_Sᵀ`, `h = 0`, `R = blkdiag(whiteAngularCovariance)`. Default `whiteAngularSigma_rad = deg2rad(10/3600)` = 10 arcsec, isotropic (masterConfig l. 248); realism grade 30 arcsec (realismGradeConfig l. 373).
- **Verdict**: ✅ The quaternion-residual measurement model and its MEKF Jacobian are exactly right (δz ≈ C_S_B δθ + n); ⚠️ per-axis isotropic noise ignores the boresight/cross-axis anisotropy that every unit in the NASA reference exhibits (twist typically 5–10× worse).
- **Sources**: NASA (2024), Table 5-5 "Star Trackers Suitable for Small Spacecraft" (p. 150): Blue Canyon NST 6″ cross-axis / 40″ twist (3σ); Berlin ST400 15″/150″; Arcsec Sagitta 6″/30″; Redwire 10–27″/51″ — cross-axis and twist are separate columns precisely because they differ by ~an order. Markley (2003) (EXTERNAL) for the residual-in-sensor-frame convention. ECSS-E-ST-60-10C (2008), *Control performance* (Paper/) — the pointing-error budgeting framework (AKE/APE error indices) under which such sensor anisotropy must be carried per axis.
- **Critical analysis**: The interface supports the fix already — `whiteAngularCovariance_rad2` accepts a full matrix and the Gaussian draw handles anisotropy — so this is purely a *default parameterization* gap: setting σ_twist ≈ 5–8× σ_cross about the boresight axis (rotated by q_B_S) would make the attitude covariance realistically cigar-shaped instead of spherical, which matters for the lever-arm observable (yaw-like errors project differently onto tower baselines). Comparing numbers: 10 arcsec 1σ per axis ≈ 30 arcsec 3σ — conservative against NST cross-axis (6″), roughly in-family with its 40″ twist; so the isotropic default happens to average the two, which is exactly why it slides through validation while distorting the error geometry. The calibration treatment is sophisticated for a simulation (persistent alignment as a consider/estimated parameter with a stable identifier, cross-epoch correlation preserved) and the epoch scheduling (updatePeriod/phase, outages) is realistic. One conscious simplification: no field-of-view/occultation model — availability is an externally supplied flag.

### Attitude kinematics and quaternion conventions

- **Code**: `+revgnss/AttitudeQuaternion.m:10–19` (`convention()`): "scalar-first [w;x;y;z]", "Hamilton", "q_A_B maps B-frame coordinates into A-frame", composition "q_A_C = q_A_B ⊗ q_B_C", local error "q_true = q_nominal ⊗ Exp(δθ_B)". Products (l. 32–40) implement `[aw·bw − av·bv; aw·bv + bw·av + av×bv]` — Hamilton, right-handed (ij = k). `AttitudeErrorStateKinematics.quatMul_` (l. 160–168) is the identical expansion. DCM (both files, element-identical): standard homogeneous Hamilton body→A matrix. Euler bridge: `AttitudeKinematics.bodyToEcefRotation` C = Rz(ψ)Ry(θ)Rx(φ) (l. 15–36); `eulerToQuatZYX` (`AttitudeErrorStateKinematics.m:23–37`) digit-checked against the closed form qw = cy·cp·cr + sy·sp·sr etc. ✓; `quatToEulerZYX` (l. 39–49) with asin clamp ✓. Propagation: filter side `q̇ = ½Ω(ω)q`, first-order + normalize (l. 84–100, Ω verified as [0, −ωᵀ; ω, −[ω]×]); truth side exact exponential `q ⊗ q{ω·dt}` (`AttitudeQuaternion.propagateBodyRate`, l. 84–94) with a Taylor-stabilized small-angle branch in `fromRotationVector` (l. 61–63: scale = ½ − θ²/48 ✓ matches sin(θ/2)/θ expansion).
- **Verdict**: ✅ One convention, declared in machine-readable form, implemented consistently across all four attitude files; the filter/truth propagator mismatch (first-order vs. exact) is O((ωdt)²) ≈ 2.7e−9 rad per step at GEO rates — negligible and normalized away.
- **Sources**: Solà (2017) (EXTERNAL) — "CAUTION: Not all quaternion definitions are the same. … this document concentrates on the Hamilton convention" (§1.1, pp. 4–5) — precisely the trap the `convention()` methods exist to prevent; his q̇ = ½q⊗[0;ω] and Ω-matrix forms match the code. Markley (2003) (EXTERNAL) for the MEKF-side usage; the JPL-vs-Hamilton distinction (Shuster's convention vs. Hamilton) is the classic failure mode the explicit `c.algebra = 'Hamilton'` declaration guards against.
- **Critical analysis**: The strongest design feature is that the convention is *code*, not a comment: two independent `convention()` structs plus asserts on norm/finiteness make the Hamilton/scalar-first/body-to-ECEF choice testable. The one subtlety worth a sentence in the paper: `AttitudeQuaternion.toRotationVector` canonicalizes q(1) < 0 → −q (l. 72–74) so geodesic distances stay in [0, π], while `quatNormalize` does not sign-canonicalize — harmless since all consumers are sign-agnostic, but a reviewer will ask. Earth-rotation bridging (`ecefBodyToInertial`, l. 96–102) uses the same constant-Ω frame as the dynamics — consistent, with the non-IERS limitation declared in `convention().inertialFrame`.

### Euler-rate Jacobian (analytic, WP7) and gimbal-lock guard

- **Code**: `+revgnss/AttitudeKinematics.m:73–105` (`eulerRateJacobian`): closed-form J = ∂[T(φ,θ)ω]/∂(φ,θ,ψ) with a = sr·ω₂ + cr·ω₃, b = cr·ω₂ − sr·ω₃: J = [tp·b, sec²·a, 0; −sr·ω₂ − cr·ω₃, 0, 0; b/cp, (tp/cp)·a, 0]; cp clamped at ±1e−6 near the pole; used as `F(eul,eul) = I + dt·J` (`ReverseGNSSEKF.m:1197–1198`). T itself (`eulerRatesFromBodyRates`, l. 38–66): [1, sr·tp, cr·tp; 0, cr, −sr; 0, sr/cp, cr/cp] with a gimbal-lock warning; `gimbalMetric = |cos θ|` (l. 155–158).
- **Verdict**: ✅ Symbol-by-symbol differentiation of the standard ZYX kinematic matrix confirms every entry, including the exactly-zero yaw column (T is yaw-independent); the singularity is guarded, warned, and — decisively — routed around by making quaternionErrorState the default.
- **Sources**: The ZYX kinematic relation [φ̇;θ̇;ψ̇] = T(φ,θ)·ω_body with T singular at θ = ±90° is standard flight-dynamics kinematics (e.g., Wertz [ed.], *Spacecraft Attitude Determination and Control*, 1978, App. E; EXTERNAL); the code's own docstring derivation reference `tests/test_euler_jacobian_analytic.m` provides the in-repo symbolic verification.
- **Critical analysis**: Verified by hand: row 1 ∂/∂φ = tp(cr·ω₂ − sr·ω₃) ✓, ∂/∂θ = sec²θ·(sr·ω₂ + cr·ω₃) ✓; row 2 ∂/∂φ = −sr·ω₂ − cr·ω₃ ✓, ∂/∂θ = 0 ✓; row 3 ∂/∂φ = b/cp ✓, ∂/∂θ = a·sp/cp² = (tp/cp)a ✓. The clamp `sign(cp+eps)·1e−6` bounds sec² at 1e12 — the F entry stays finite but enormous near the pole, so the *practical* protection is that the legacy Euler path is only exercised away from gimbal lock; the docstring says exactly this ("the singularity-free path is the quaternion error-state parameterisation"). Replacing the earlier 1e−7 central difference with the closed form removed FD round-off from F — a small but genuine numerical-quality improvement, and the analytic/FD agreement is regression-tested.

### Observability diagnostics

- **Code**: `+revgnss/AttitudeObservability.m:23–155`: per-epoch SVD of the attitude columns of H — Frobenius norm, numerical rank with tolerance `max(M,n)·eps(‖H_att‖)`, condition number, sensitive-row count — gated first on lever-arm geometry (zero lever arm ⇒ 'unobservable-zero-lever-arm', l. 91–95), with an explicit warning that a weak-geometry attitude covariance is "process-noise-limited (sigma_angAccel), not measurement-constrained" (l. 46–50, 146–154). `+revgnss/ObservabilityDiagnostics.m:9–120+`: full-H rank/condition/connectivity per epoch. The structural fact both encode — pseudorange carries attitude only through the lever arm — is also asserted at the filter (`ReverseGNSSEKF.m:34, 359–366`, zero-lever-arm warning).
- **Verdict**: ✅ Correct and honest as *instantaneous* (single-epoch) observability audits; ❓ neither builds a multi-epoch local observability Gramian (Σ Φᵀ Hᵀ R⁻¹ H Φ), and no literature source is cited for the classification scheme, which is bespoke.
- **Sources**: Montenbruck & Gill (2000), §8.1–8.3 — estimability of parameters through the H/Φ structure in orbit determination (the framework these diagnostics instantiate). Naqvi/Abbas (2012, AIAA 2012-4419, Paper/) — "GPS attitude determination system use three or more GPS receivers and antenna pairs separated by known baseline" (p. 4): the baseline/lever-arm requirement the rank gates operationalize.
- **Critical analysis**: The single-epoch rank test can *understate* observability (states unobservable instantaneously can be observable through the dynamics — the classic radial/clock example elsewhere in this project) and the code half-acknowledges this by classifying rather than auto-disabling. The genuinely valuable part is the process-noise-limited warning: it prevents the most seductive misreading of this simulation's outputs — a small attitude sigma that is really just small sigma_angAccel. A per-arc accumulated Gramian (even over 10–100 epochs) would upgrade the diagnostic from "geometry now" to "information over the arc" and directly serve the rotation-observability storyline of the current branch; the epoch-transition retention machinery (F, K, H retained per epoch, `ReverseGNSSEKF.m:2137–2237`) already stores every operator needed to compute it.

---

#### Cross-cutting strengths (explicitly noted)

1. **Dual bookkeeping with a hard cross-check**: the constructor's nx arithmetic and `buildStateMap_`'s index walk are independent implementations reconciled by an assert (`ReverseGNSSEKF.m:318–321, 1139–1142`) — a silent state-vector mismatch is structurally impossible.
2. **The watermark fence** (`requireWatermarkCurrent_`, l. 2189–2203): any covariance write outside the accounted paths throws instead of silently corrupting retained operators — rare rigor for research code.
3. **Golden-safety discipline**: every optional state block appends strictly last with empty-sentinel maps, so enabling features cannot shift indices (l. 1028–1066).
4. **Honest degradation**: dynamics failures fall back to constant velocity with a warning and a logged reason (l. 519–527); PSD repairs are classified and counted; every attitude-injection is norm-tracked.
5. **The applyIslDifferencedAmbiguityFix docstring** (l. 1602–1620) explicitly names and blocks the information double-counting trap (deterministic constraint applied once per arc) and identifies the update as the Teunissen (1995) conditional mixed-integer estimator expressed as a pseudo-measurement.

#### Residual weaknesses (ranked)

1. Isotropic star-tracker noise vs. real cross-axis/twist anisotropy (parameterization, interface already supports the fix).
2. Gyro defaults MEMS-class; no bias-instability (flicker) term — conservative direction, but must be labelled as such in the paper.
3. No chi-square innovation gate; the one gate present (1 m, diffAtt) is unsourced.
4. Flicker-FM clock approximation differs in Δt-power from B&H's own compromise model (documented, gated, same order at dt = 1 s).
5. Q for the r/v block remains CV-based when the J2 STM is active (standard SNC practice, but F/Q dynamics-inconsistent).
6. Observability audits are single-epoch; no arc-accumulated Gramian despite the operators being retained.

#### References (APA 7)

- Acklam, P. J. (2003). *An algorithm for computing the inverse normal cumulative distribution function*. [EXTERNAL; algorithm note, coefficients verified digit-for-digit]
- Bar-Shalom, Y., Li, X. R., & Kirubarajan, T. (2001). *Estimation with applications to tracking and navigation: Theory, algorithms and software*. Wiley. [EXTERNAL] https://doi.org/10.1002/0471221279
- Brown, R. G., & Hwang, P. Y. C. (1997). *Introduction to random signals and applied Kalman filtering: With MATLAB exercises and solutions* (3rd ed.). Wiley. [Paper/Error Calculation/KalmanFilter/Brown.pdf — scanned; quotes transcribed from rendered page images]
- European Cooperation for Space Standardization. (2008). *Control performance* (ECSS-E-ST-60-10C). ESA-ESTEC. [Paper/Error Calculation/]
- Farrenkopf, R. L. (1978). Analytic steady-state accuracy solutions for two common spacecraft attitude estimators. *Journal of Guidance and Control, 1*(4), 282–284. [EXTERNAL] https://doi.org/10.2514/3.55779
- IEEE. (1997). *IEEE standard specification format guide and test procedure for single-axis interferometric fiber optic gyros* (IEEE Std 952-1997). IEEE. [EXTERNAL]
- Markley, F. L. (2003). Attitude error representations for Kalman filtering. *Journal of Guidance, Control, and Dynamics, 26*(2), 311–317. [EXTERNAL; NASA NTRS 20020060647] https://doi.org/10.2514/2.5048
- Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications*. Springer. [Paper/Fundamental Books/04_Montenbruck_2000_SatelliteOrbits.pdf] https://doi.org/10.1007/978-3-642-58351-3
- Naqvi, N. A., Ke, Z., Masood, K., & Meibo, L. (2013). *Design and simulation of GNSS phase based attitude determination of spacecraft: LAMBDA and EKF combination technique* (AIAA paper). [Paper/Error Calculation/Atmospheric Errors/]
- Naqvi, N. A., Sun, Y., & YanJun, L. (2012). *Design and mathematical modeling of GNSS based attitude determination of ICUBE-1* (AIAA 2012-4419). [Paper/Error Calculation/Atmospheric Errors/] https://doi.org/10.2514/6.2012-4419
- NASA. (2024). *State-of-the-art of small spacecraft technology*. NASA Ames Research Center. [Paper/Error Calculation/NASAcomponentReferenceError.pdf]
- Ott, T., et al. (2013). *Precision pointing H∞ control design for absolute, window-, and stability-time errors* (PEET, AIAA GNC 2013). [Paper/Error Calculation/Pointing_Error_PEET_AIAA_GNC_2013.pdf; consulted for pointing-error index framework]
- Solà, J. (2017). *Quaternion kinematics for the error-state Kalman filter* (arXiv:1711.02508). [EXTERNAL] https://doi.org/10.48550/arXiv.1711.02508
- Wilson, E. B., & Hilferty, M. M. (1931). The distribution of chi-square. *Proceedings of the National Academy of Sciences, 17*(12), 684–688. [EXTERNAL] https://doi.org/10.1073/pnas.17.12.684

---

# Section: Two-Way Time Transfer & Four-Timestamp Observables

This section verifies the simulation's two-way / TWSTFT time-transfer stack against the canonical literature: the four-timestamp clock-difference observable and its sign convention, the light-time event chain and its constant-velocity assumption, which non-reciprocity terms (Sagnac, ionosphere, hardware asymmetry, motion) are physically generated vs. asserted away, the coherent two-way code model, the covariance treatment of the observable, achievable-precision plausibility, and relativistic terms. The stack has THREE distinct layers that must not be conflated: (i) the **legacy first-order reciprocal mode** (`firstOrderReciprocal`) — a *synthetic* observable that constructs z directly as a truth clock difference plus an optional reciprocity term; (ii) the **four-timestamp physical mode** (`fourTimestampClockDifference`) — a genuine event-chain simulation that solves four retarded-time events in an inertial frame and reduces raw local clock tags; and (iii) the **relay session layer** (ground-station↔relay↔ground-station TWSTFT). The physical layer (ii) is scientifically strong — it reproduces the ITU-R TF.1153 observable including the Sagnac asymmetry *by construction* rather than by bolt-on correction. The legacy layer (i) is a twin-consistent abstraction in which most non-reciprocity physics is absent from both z and h, so nothing can leak — but nothing can be validated either.

---

### 1. The four-timestamp clock-difference combination and its sign convention

- **Code**: `+revgnss/FourTimestampObservableBuilder.m:219` —
  `value_s = 0.5*((tags_s(2)-tags_s(1)) - (tags_s(4)-tags_s(3)));`
  with chain-role order {origin(t1 tx), destination(t2 rx), destination(t3 tx), origin(t4 rx)} (line 183–189), i.e. Δ = ½[(T2−T1) − (T4−T3)]. Metres conversion `value_m = c · value_s` at line 82. Sign documented at lines 216–218: *"tags_s(1)/(4) (origin, the reference) subtract, tags_s(2)/(3) (destination, the remote) add"*, matching `ReciprocalTimeTransferModel.m:64–65` (`referenceClockPartial = -1`, `remoteClockPartial = +1`). The range counterpart ½[(T2−T1)+(T4−T3)]·c lives on the coherent-code path: `+revgnss/CoherentTwoWayCodeRangingModel.m:68–70`, `processedRange_m = 0.5·c·(measuredDelay − terminalCal − turnaroundEquivalent)`.
- **Verdict**: ✅ The combination is the canonical TWTT equation; the algebra is exact (substituting the affine tag model `TwoWayCodeEndpointModel.localTimeAt`, Δ = (b_B − b_A) + ½(τ_fwd − τ_ret), i.e. clock difference plus half the path asymmetry). The sign is **remote − reference** — identical to Merlo et al.'s responder-minus-initiator form, but *opposite* to the ITU-R TF.1153 station-1-minus-station-2 (reference-minus-remote) convention; the code documents its own convention consistently at every consumer, so this is a convention choice, not an error.
- **Sources**:
  - Merlo, J. M., Mghabghab, S. R., & Nanzer, J. A. (2023). Wireless picosecond time synchronization for distributed antenna arrays. *IEEE Transactions on Microwave Theory and Techniques, 71*(4), 1720–1731 — "the offset between the local clock at node n and node 0 can be deduced by Δ0n = [(tRX0 − tTXn) − (tRXn − tTX0)]/2" (p. 1722, Eq. 3); "If the link is symmetric, the propagation delay can also be deduced simply by τ0n = [(tRX0 − tTXn) + (tRXn − tTX0)]/2" (p. 1722, Eq. 4).
  - Shen, D., Chen, G., Pham, K., & Blasch, E. (2022). Enhanced multi-way time transfer for high-precision time synchronization among UASs. *MILCOM 2022*, 501–506 — Eq. (5): "Δt = (R2 − R1)/2c + (2tRX_M − tTX_S − tRX_S + TTX_M + TRX_S − TRX_M − TTX_S)/2" (p. 502).
  - ITU-R. (2015). *Recommendation ITU-R TF.1153-4: The operational use of two-way satellite time and frequency transfer employing PN codes* [EXTERNAL, itu.int] — "The time-scale difference is thus given by the so-called two-way equation: TS(1) – TS(2) = 0.5 [TI(1)] … −0.5 [TI(2)] … The last seven terms are the corrections for non-reciprocity" (p. 4).
- **Critical analysis**: The sim's reduction is a *pure function of the four tag numbers* (never calls the truth clock model — line 212–214 comment), which is exactly the discipline a real modem has: it sees only timestamps. The auto-memory's standing trap note ("four-timestamp sign is b_remote − b_reference, opposite") is confirmed as a convention inversion relative to ITU-R TF.1153, correctly and uniformly handled in-repo. One structural note: the observable Δ = ½(T2+T3) − ½(T1+T4) senses each endpoint's TX and RX terminal delays only through their *per-endpoint sum weighted ½*, so the sim's single `originTerminalGroupDelay_s`/`anchorTerminalGroupDelay_s` per endpoint (allocated to receive, transmit, or split — `FourTimestampObservableBuilder.m:183–202`) spans the observable-relevant delay space; it cannot, however, represent an ITU-style ½[TX(k)−RX(k)] asymmetry *independently of* the range observable, which uses the orthogonal combination. For the clock-difference-only EKF row this is benign.

### 2. The event-chain solver and the constant-velocity light-time oracle

- **Code**: `+revgnss/ReciprocalTimestampEventModel.m:87–151` (`solveEventChain_`): anchored at final reception t4, solves the return leg retarded (`solveRetardedLeg_`, fixed-point, tol 1e-13 s ≈ 0.03 mm, lines 153–173), derives t2 = t3 − turnaround (converted from proper to coordinate duration, line 114–116), solves the forward leg retarded, then enforces light-time closure residual < 10×tol (line 129) and event ordering (line 133). `+revgnss/ConstantVelocityFourEventLightTimeOracle.m:105–129` is an independent closed-form check: the retarded time is the positive root of the light-cone quadratic, computed in the numerically stable rationalized form `lightTime = ρ²/(√(p² + (c²−v²)ρ²) − p)` with p = d·v — algebraically exact for linear motion (verified by expansion: (√−p)(√+p) = (c²−v²)ρ²).
- **Verdict**: ✅ Exact within the constant-velocity assumption, whose error is quantified and negligible: endpoints are rebuilt from the true state at every epoch (`ReciprocalEndpointTruthProvider.spacecraft/fixedStation`), so linearization spans only the ~0.13 s one-way light time. Trajectory-curvature position error over that span is ½·a·τ² ≈ ½·0.224 m/s²·(0.13 s)² ≈ 1.9 mm for GEO (a = ω²r) and ≈ 0.3 mm for the ground station — ~6 ps of one-way light time, and it largely cancels between the forward and return legs of the *difference* combination, leaving sub-ps in Δ.
- **Sources**: Surof, J., et al. (2026). Precise time transfer and ranging for next-generation GNSS. *GPS Solutions, 30*, 101 — "∆TAB = ½(pA − pB) = +δtA − δtB" (Eq. 18, p. 8), the identical pseudorange-difference reduction; Merlo et al. (2023), Eq. (3)–(4) above.
- **Critical analysis**: The convergence guard requiring maximumIterations ≥ 3 (line 200–210) and the closure-residual check are genuine numerical hygiene rarely seen in simulation code. The known duplication (three copies of the same retarded-leg idiom in `CoherentTwoWayCodeRangingModel`, `ReciprocalTimestampEventModel`, `FourTimestampObservableBuilder`) is documented in-file as a truth/estimate-separation tradeoff — acceptable, but a divergence risk if one copy is ever edited alone.

### 3. Sagnac and frame handling — the decisive difference between the two modes

- **Code**: Four-timestamp mode: `+revgnss/ReciprocalEndpointTruthProvider.m:54–62` — *"A ground tower is fixed IN ECEF (zero ECEF-frame velocity); its real inertial velocity is entirely the Earth-rotation term ecefStateToInertial already applies"*. The event chain is then solved in the **inertial frame with the tower moving at Ω×r (~465·cos λ m/s)**, so the up/down path asymmetry that the terrestrial-frame formulation calls the Sagnac correction is generated *physically* in the truth timestamps, and the estimator-side prediction (`FourTimestampEstimatorEndpointBridge.m:134`, same `ecefStateToInertial` pipeline) models it identically. Legacy mode: `+revgnss/TwoWayTimeTransferBuilder.m:212–224` builds truth and model states in **ECEF with tower velocity zeros(3,1)**; z is constructed as (b_rx − b_tower) + recip — no Sagnac term exists on either side. Same for the synthetic ISL time transfer (`InterSatelliteTimeTransferBuilder.m:83–95`). (The *one-way* GNSS path is separate and does apply Sagnac: `+models/+frames/LightTimeSolver.m:12–16`, audited elsewhere as equivalent to the analytic first-order term.)
- **Verdict**: ✅ for the four-timestamp mode (Sagnac captured by construction — the correct way to do it); ❌-as-physics / ✅-as-honest-twin for the legacy and synthetic-ISL modes (the ~10²-ns-class term is absent from both z and h, so it cannot alias — but the channel can never validate a real receiver's Sagnac-correction sensitivity, e.g. to station-coordinate error).
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] — "Due to the movement both of the earth stations and of the satellite around the rotation axis of the Earth during the propagation of a time signal … a correction has to be applied" (§ 3.2, p. 4); "SCD(k) = (Ω/c²)[Y(k)X(s) − X(k)Y(s)]" (p. 5); worked example: "SCD(VSL) = +99.10 ns", "SCD(USNO) = −95.22 ns", "SCT … = +194.32 ns" (pp. 5–6) — i.e. **~100–200 ns for real Ku-band geostationary links**; also "a periodic variation of the Sagnac effect with a maximum peak to peak amplitude of a few hundred ps" from daily satellite motion (p. 6). Shen et al. (2022) — "For satellite applications, the Sagnac effect needs to be compensated to high-precision time synchronization results" (p. 502). Fridelance, P., Samain, E., & Veillet, C. (1996). T2L2 – Time transfer by laser link. — "τrelativity is a relativity correction term corresponding to the Sagnac effect" (p. 3).
- **Critical analysis**: For a single tower↔satellite round trip the Sagnac terms of the two legs have *opposite sign* (ITU: "SCU(k) = −SCD(k)", p. 5), so they cancel in the half-SUM (ranging) but **add in the half-DIFFERENCE** — the clock observable carries the full one-way SCD, order 100 ns. The sim's inertial-frame formulation reproduces exactly this without ever naming "Sagnac", which is scientifically superior to a bolt-on correction because it cannot be applied twice or with the wrong sign. The residual concern is the linear-motion approximation of the tower's rotation (curvature ≈ 0.3 mm over a leg, mostly common-mode between legs — sub-ps in Δ). The legacy mode's absence is a *documented modelling boundary*, not a bug, but any thesis claim built on `firstOrderReciprocal` runs should state that geometric non-reciprocity was not exercised.

### 4. The first-order reciprocity residual term — wrong factor for any single protocol

- **Code**: `+revgnss/ReciprocalTimeTransferModel.m:44–46` — `reciprocity_m = -(deltaPosition.'*deltaVelocity)/c` = −ρρ̇/c, applied identically to truth and model (`TwoWayTimeTransferBuilder.m:209–224`, comment: "recip = -(rhoDot * rho)/c : the leading two-way asymmetry from the spacecraft moving during the round trip"). Off by default (`includeReciprocityResidual = false`); when on, `reciprocitySigma_m` (5 mm default) is added to R.
- **Verdict**: ⚠️ First-order expansion of the sequential four-event chain (anchored at t4, turnaround → 0) gives ½(τf−τr)c = −ρρ̇/(2c) − ρ·û·(v_A+v_B)/(2c) − ρ̇Δturn/2 : the code's −ρρ̇/c is **2× the relative-velocity part** and **omits the common-velocity (Sagnac/aberration) part entirely**; for the classical *simultaneous-transmission* TWSTFT protocol the relative-velocity part cancels altogether and only the common-velocity part survives. So the implemented term matches neither protocol exactly.
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] § 3.3 — "Two-way paths … are not reciprocal if the satellite is in motion … If the signals from the two stations arrive at the satellite within 5 ms, the delay difference is at the level of only a few tens of ps" (p. 6) — i.e. the motion term is tens of ps, far below the 100 ps measurement σ. Merlo et al. (2023) — the quasi-static assumption: "assuming that the channel was quasi-static over the synchronization epoch" (p. 1722).
- **Critical analysis**: Three mitigations keep this from mattering numerically: (a) the identical expression is used in z and h, so it cancels to state-error level — the *filter* is unaffected; (b) at GEO in ECEF coordinates ρ̇ ≈ 0, so the term is ~0 in the shipped scenarios; (c) the only test (`tests/test_four_timestamp_static_limit_matches_first_order_reciprocal.m`) verifies the **static limit only** and uses the moving case merely as a negative control ("disagreement grows with velocity"), so the factor was never validated against the exact four-event chain — this is precisely the kind of untested-coefficient gap the audit should record. The four-timestamp mode makes the term obsolete, and `validateConfig` (TwoWayTimeTransferBuilder.m:375–381) correctly *refuses* `includeReciprocityResidual` under that mode rather than silently ignoring it.

### 5. Hardware delays, calibration split, and the terminal-delay allocation

- **Code**: `+revgnss/ReciprocalLinkHardwareModel.m` — immutable delay chain with `parameterSource ∈ {physicalTruth, calibrationProduct}` (line 66) and hard `assertParameterSource` at every solver entry (`ReciprocalTimestampEventModel.m:99`, `FourTimestampObservableBuilder.m:60/64`): the truth chain and the calibration product are *different objects*, so a Tx/Rx calibration error is exactly the truth−product difference, mirroring TWSTFT station calibration. `applyTerminalDelayAllocation_` (`FourTimestampObservableBuilder.m:183–202`) applies delays as post-hoc tag corrections in three frozen allocations. Calibration validity windows are enforced at the final-reception tag (`DirectReciprocalTimeTransferBuilder.m:171`; `assertValidAt`).
- **Verdict**: ✅ Structurally faithful to the ITU error model (TX(k), RX(k), transponder delay as separately calibrated terms with validity intervals); the coherent-code path even decomposes the injected error (`CoherentTwoWayCodeRangingModel.m:130–137`: `terminalCalibrationError_s`, `turnaroundCalibrationErrorInInitiatorTime_s`).
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] — "TX(k): Transmitter delay, including the modem delay; RX(k): Receiver delay, including the modem delay … SPT(k): Satellite path delay through the transponder" (p. 3); § 3.6 station-delay measurement by co-location (p. 6). Shen et al. (2022) — "the RX and TX processing functions are usually implemented in a field-programmable gate array (FPGA), so the processing times are fixed on the local clocks" (p. 502).
- **Critical analysis**: One deliberate, loudly-guarded gap: declared calibration *uncertainties* (`calibration.originTerminalSigma_s/anchorTerminalSigma_s`) are **not wired into R** and `validateConfig` errors on any nonzero value (`FourTimestampGroundSpaceTimeTransferBuilder.m:316–328`) instead of silently dropping them — the correct refusal pattern (an inert toggle must fail, not no-op). A persistent-calibration-state treatment is explicitly declared out of scope. Until it exists, four-timestamp runs implicitly assume *perfectly calibrated* terminal delays whenever the truth and product hardware objects carry the same numbers — the same "assumed-perfect" caveat class as the audited ISL beacon.

### 6. Coherent two-way code ranging — what "coherent" means and the noise convention

- **Code**: `+revgnss/CoherentTwoWayCodeRangingModel.m:57–70` — the initiator's clock tags both t1 and t4; `measuredDelay_s = localClockRate·(τf + turnaround + τr) + initiatorTerminalDelay + propagationGroupDelay + trackingError`; range = ½c·(measured − calibratedTerminal − turnaroundEquivalent). "Coherent" = the transponder retransmits the PN code phase-coherently (`CoherentTwoWayCodeHardwareModel` hard-asserts `codeRateTurnaroundRatio == 1`), so **the transponder's clock never enters the observable** and the initiator clock *bias* cancels in the local round-trip interval while its *rate* correctly scales the interval (diagnosed at `ISLTimingModel.m:87–89`: "initiator clock offset cancels in the local round-trip interval; clock rate and event-time mapping remain modeled"). Noise: a single draw scaled 2σ/c injected on the round-trip delay (`TwoWayISLMeasurementBuilder.m:579–581`), which the ½c reduction maps back to exactly σ of range.
- **Verdict**: ✅ Physically correct for a coherent transponder: only ONE tracking receiver exists, so a single noise draw (not a σ/√2 two-receiver RSS) is the right structure; the *magnitude* is a declared total-budget convention rather than a derived split, and the repo says so (thermal + `nonThermalSigma_m` floor with a "floorless sigma" warning, `TwoWayISLMeasurementBuilder.m:~550–571`).
- **Sources**: Surof et al. (2026) — the analogous one-tracking-loop-per-direction architecture: "pA = uDLL = −τ = ∆t + δtA − δtB" (Eq. 16, p. 7); ITU-R TF.1153-4 [EXTERNAL] — the transponder as a common, cancelling path element: "usually the two stations use the same transponder … SPT(1) = SPT(2)" context, with the XPNDR(k) term required otherwise (p. 4). Schaefer, W., Pawlitzki, A., & Kuhn, T. (2000). Two-way frequency transfer via satellite using carrier phase. *32nd PTTI Meeting* — "C/No: 40...60 dBHz -> noise 500 ps (PN 2.5 MChip/s, t = 1 s)" (p. 2) as the code-noise class.
- **Critical analysis**: In a genuine *four-timestamp* exchange with independent counters at both ends, tag-noise propagation gives σ_Δ = ½·√(Σ₁⁴σᵢ²) (= σ_tag for four equal tags) — the sim bypasses this by refusing nonzero `counterTag.sigma_s` (see §7) and drawing one processed-domain σ instead; defensible, but it means the per-tag noise anatomy of e.g. Merlo's CRLB analysis is not exercised. The turnaround proper→coordinate→initiator-time conversion chain (`transponderTruth.properTimeRate` at line 62–67) is a subtle correctness detail most simulators skip — credit where due.

### 7. Covariance modelling of the observable

- **Code**: `+revgnss/ReciprocalTimeTransferCovarianceBuilder.m` — named blocks (counter/tag noise diag(σ²), terminal/modem delay from the hardware's own `calibrationCovariance_s2`, product calibration with an enforced `priorVarianceUnits=='s^2'` guard at line 83–89, atmosphere, relay, session common-mode), assembled block-diagonal with a PSD check (line 188–194). `zeros(0,0)` = "undeclared, not fabricated zero" (`ReciprocalLinkHardwareModel.m:17–21`). EKF R on the ground-space four-timestamp path: `Ri = sigma_m² + nCorr·towerClockSigma_m²` (`FourTimestampGroundSpaceTimeTransferBuilder.m:181`); legacy path identical structure (`TwoWayTimeTransferBuilder.m:243–245`).
- **Verdict**: ⚠️ Mixed — the *structure* is disciplined and the product-error correlation treatment is honestly conservative, but the assembled record covariance is largely decorative (the EKF never reads it), the two one-way tag noises are modelled as independent (no common-clock correlation across T1/T4 or T2/T3), and the audited ISL white-noise defect stands.
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] — the non-reciprocity terms that a covariance must carry are enumerated in the two-way equation (p. 4); Song, W., Zheng, F., Wang, H., & Shi, C. (2023). 100 picosecond/sub-10⁻¹⁷ level GPS differential precise time and frequency transfer. *Applied Sciences, 13*(19) — correlated-error awareness as the route to "the standard deviations (STDs) of the four baselines were all less than 100 ps within one month" (p. 1).
- **Critical analysis**: Four specific findings. (1) **Piecewise-constant product error inflated by nCorr** (`TwoWayTimeTransferBuilder.m:137–149`; mirrored at `FourTimestampGroundSpaceTimeTransferBuilder.m:82–93`): the broadcast tower-clock product is constant over each update interval, so charging it as white would let the EKF average it down √N below the reference-clock floor; the nCorr inflation is the documented conservative cure — correct, and its omission in the first cut of the 4TS builder was caught in review (header lines 70–81). (2) **Confirmed known issue**: the *one-way ISL* product error is still charged as white R with no nCorr (latent, product.enable=false in shipped JSONs — prior full-audit finding, unchanged), and the synthetic ISL time transfer's R is pure per-epoch white σ² (`InterSatelliteTimeTransferBuilder.m:92–95`); only the federated `multiAsset.twoWayTimeTransferISL` variant models a per-link calibration bias (const + random-walk, `masterConfig.m:1588–1591` with an `nCorrCap` honest gate). (3) **counterTag.sigma_s and atmosphereVariance_s2 feed only the truth record's covarianceBlock, never R** — and rather than silently dropping declared values, `validateConfig` hard-errors on nonzero declarations (`FourTimestampGroundSpaceTimeTransferBuilder.m:330–365`, incl. the measured "byte-identical on vs off" statement for applyAtmosphere); this is the right failure mode, but it means **no four-timestamp run has ever carried tag noise or atmosphere in its filter weighting**. (4) Common-mode clock noise between T1..T4 (the origin clock's instability over the ~0.25 s round trip appearing in both T1 and T4) is unmodelled; at the 100 ps/epoch measurement floor and good-oscillator ADEV this is ≪1 ps — negligible, but worth stating. Credit: the m²-vs-s² unit refusal for common-source groups (`DirectReciprocalTimeTransferBuilder.m:179–185`, "wrong by c²" measured live) is exemplary unit discipline.

### 8. Ionosphere and troposphere asymmetry

- **Code**: Absent from the two-way z/h everywhere. Legacy mode: no atmosphere at all. Four-timestamp mode: `applyAtmosphere=true` is *refused* (`FourTimestampGroundSpaceTimeTransferBuilder.m:356–365`) because it would only ever have filled the inert truth-record covariance.
- **Verdict**: ❌ as physics / ✅ as honesty — the up/down frequency-asymmetric ionospheric delay and the tropospheric residual are real TWSTFT error terms that the simulation does not generate; the guard converts a silent no-op into a loud refusal.
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] § 3.4 — "For a high TEC of 1×10¹⁸ electrons/m² and fu = 14.5 GHz and fd = 12.5 GHz this ionospheric delay is equal to 0.859 ns − 0.639 ns = 0.220 ns" so "0.5[SPU(k) − SPD(k)] is typically smaller than −0.11 ns" (p. 6); § 3.5 troposphere: "its influence on the difference between the up and down propagation delays is < 10 ps" (p. 6). Schaefer et al. (2000) — for carrier *frequency* transfer: "Ionosphere: <300 ps / day (4 E-15), under pessimistic assumptions" and "Troposphere: none (frequency independent)" (p. 4).
- **Critical analysis**: The missing iono asymmetry (~0.1 ns worst-case at Ku band; larger at the sim's 2.2 GHz S-band default where TEC delay is ~40× Ku) is the largest unmodelled physical term after the (captured) Sagnac effect. At the S-band default `carrierFrequency_Hz = 2.2e9` (`masterConfig`), a 10 TECU path gives ~18 ns per leg; the up/down *difference* for a realistic frequency split would be nanoseconds — an order of magnitude above the 100 ps noise floor. Any claim that the four-timestamp S-band link achieves 100 ps-class *accuracy* (as opposed to twin precision) therefore requires either a dual-frequency iono correction or Ku/Ka carriers; the report should say so.

### 9. Ground relay session (station↔relay↔station TWSTFT)

- **Code**: `+revgnss/GroundRelaySessionObservableBuilder.m:142–156` — realizable combination `classicalReciprocityValue_s = 0.5*(deltaF_s − deltaR_s)` from station-delay- and atmosphere-corrected tags alone, plus a separately-labelled truth-geometry-assisted reference `0.5*((ΔF−τF)−(ΔR−τR))`; `GroundRelaySessionClockDifferenceObservable` documents that the two differ by exactly ½·coordinateAsymmetry_s and that the relay clock is "marginalized out STRUCTURALLY — its own clock bias/group delay never enters the combiner formula" (header, with property-based tests `tests/test_relay_twstft_clock_gauge.m`).
- **Verdict**: ✅ Exemplary — the B1-review split between the truth-assisted "exact" value and the realizable classical value is precisely the "could a real receiver compute this?" discipline the project's own standing lesson demands, and the relay-transponder marginalization mirrors the ITU common-transponder cancellation (with `relayGroupDelayAsymmetry_s` moving only the realizable value, as it physically must).
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] — transponder-delay cancellation and its failure mode: "This is not the case when different frequencies, transponders or different spot beams are used … SPT(1) − SPT(2), designated as XPNDR(k), should be measured" (p. 4). Fridelance et al. (1996) — the analogous ground-truth-free optical combination "X = (tstart + treturn)/2 − tboard + τrelativity" (p. 3).
- **Critical analysis**: The exactness statement is carefully scoped (affine clocks, effective epochs differing under drift) — this level of epistemic precision about *what* is exact is rare and should be quoted in the thesis rather than paraphrased into a stronger claim.

### 10. Light-time asymmetry for a co-moving formation (the 0.68 µm claim)

- **Code**: measured result recorded in the federated four-timestamp port (memory: "light-time is NEGLIGIBLE for a co-moving formation (0.68 µm)"); the mechanism is §2's event chain applied to two `ReciprocalEndpointTruthProvider.spacecraft` endpoints.
- **Verdict**: ✅ The physics checks out: the invariant (processing-irremovable) part of the sequential-exchange asymmetry is ½·ρρ̇/c; for ρ ≈ 2 km and CW relative rate ρ̇ ≈ ω·ρ ≈ 0.15 m/s this gives 2000·0.15/(2·3×10⁸) ≈ 0.5 µm — the same order as the measured 0.68 µm.
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] § 3.3 (motion non-reciprocity "a few tens of ps" even for 5 ms arrival offsets on a 36 000 km link, p. 6) — scaling to a 2 km link with ms-class turnaround gives sub-ps trivially. Surof et al. (2026) — ISL TWTT budgets at "σTWTT = 0.37 ps" (p. 10) never list light-time asymmetry as a term, consistent with negligibility.
- **Critical analysis**: One caveat: in the *inertial* frame the asymmetry also contains a common-velocity term ρ·û·(v_A+v_B)/(2c) that can reach tens of µm for along-track baselines at GEO orbital velocity; it is frame-consistent between truth and prediction (both solve the same chain), so it never appears in a residual, and it vanishes for the helix formation's mostly radial/cross-track baselines — which is why the measured value lands on the relative-motion part alone. The 0.68 µm number is geometry-specific, not universal.

### 11. Achievable precision: sim assumptions vs. demonstrated systems

- **Code**: `config/masterConfig.m:646` — `sigma_m = 0.03` m "(~100 ps)" per 1 s epoch for ground two-way; same 0.03 m default for four-timestamp ground-space (`FourTimestampGroundSpaceTimeTransferBuilder.m:50–51`) and ISL 4TS (`masterConfig.m:2395`). Sim results on record: receiver clock 39 ns (one-way, radial-degenerate) → **15 ps** with two-way rows (WP-A); federated swarm relative clock **2 cm / 73 ps** via TWSTFT relay sessions.
- **Verdict**: ✅ Plausible and, if anything, conservative at the observable level: the assumed 100 ps/s modem noise is *5× better than* the classical 2.5 Mchip/s TWSTFT modem (500 ps @ 1 s) but ~40× worse than modern carrier/optical systems; the filtered 15–73 ps clock errors sit inside the envelope demonstrated by carrier-phase GPS, T2L2 and far above (i.e., worse than) optical TWTT.
- **Sources**: Schaefer et al. (2000) — "C/No: 40...60 dBHz -> noise 500 ps (PN 2.5 MChip/s, t = 1 s)" (p. 2). Fridelance et al. (1996) — "the synchronisation of remote clocks on Earth, and the monitoring of a satellite clock of the order of 50 ps" (p. 1). Song et al. (2023) — "intra-day accuracy of within 20 ps" and "STDs of the four baselines were all less than 100 ps within one month" (p. 1). Merlo et al. (2023) — "obtaining a timing precision of 2.26 ps" over a 90 cm 5.8 GHz link (p. 1720). Surof et al. (2026) — "the standard deviation of TWTT is σTWTT = 0.37 ps, and for ranging σrange = 121 µm" (p. 10). Lewandowski, W., Petit, G., & Thomas, C. (1993). Precision and accuracy of GPS time transfer. *IEEE TIM, 42*(2) — "reaches 3-4 ns for a single 13 min measurement" (p. 474) — the one-way baseline the two-way rows beat, exactly as the code's own header argues.
- **Critical analysis**: The 15 ps steady-state figure implies ~40–50-epoch effective averaging of 100 ps white noise — legitimate *only because* the correlated tower-product error is nCorr-inflated on this path (§7.1); on any path that charges correlated error as white (the audited one-way ISL case) the same arithmetic would be an optimism artefact. The honest comparison sentence for the thesis: the sim assumes a modem an order of magnitude better than 1990s TWSTFT and an order worse than demonstrated carrier-phase/optical links, and its filtered results scale accordingly.

### 12. Relativistic terms on the satellite clock

- **Code**: Three partial mechanisms: (1) `ReciprocalEndpointTruthProvider.properTimeRate_` (lines 92–107) — first post-Newtonian dτ/dt = 1 − (GM/r + v²/2)/c², used to convert the transponder turnaround proper duration to coordinate duration (`TwoWayCodeEndpointModel.coordinateDurationForProperDuration`, division by rate — sign correct); (2) the ground station's properTimeRate is hard-set to 1 with a documented fidelity note (`ReciprocalEndpointTruthProvider.m:58–60`); (3) the receiver-clock relativistic *rate* offset is a gated truth-side constant fractional-frequency offset, **default OFF** (`+revgnss/ConfigFactory.m:1048–1056`: "the constant offset is observable and absorbed by the estimated receiver clock-drift state, so the estimation residual for a circular orbit is zero").
- **Verdict**: ⚠️ Partially modelled, honestly gated. Magnitude for GEO: (GM/c²)(1/R⊕ − 1/r_GEO) − (v_GEO² − v⊕²)/2c² ≈ +5.4×10⁻¹⁰ (≈ 46 µs/day, clock runs fast relative to ground) — enormous relative to ps-level claims, but constant for a circular orbit, hence genuinely absorbed by the drift state exactly as the code argues; only an eccentric orbit's periodic term (and the neglected ground-potential offset in properTimeRate) would survive into residuals.
- **Sources**: Fridelance et al. (1996) — "τrelativity is a relativity correction term" in the observable equation (p. 3), and the relativistic framework reference "[11] Petit G., Wolf P., Relativistic theory for time transfer" (p. 10). Surof et al. (2026) — the same scoping practice: "Relativistic effects or biases are not considered in the laboratory verification, but are addressed further in (Trainotti et al. 2022)" (p. 5).
- **Critical analysis**: The turnaround-conversion effect of properTimeRate is ~1.6×10⁻¹⁰ × 1 ms ≈ 0.16 fs — decorative at current fidelity, yet it is the *only* place the 1PN rate is live by default, which risks giving a reviewer the impression relativity is "on". The consequential term (the 5×10⁻¹⁰ rate offset) is off by default and, when on, is truth-side only by design. This is defensible for *estimation* studies (the drift state soaks it up) but means the sim cannot make absolute-timescale claims (e.g., UTC steering, TAI contribution) without enabling and validating the gate — a sentence the thesis should contain. The endpoint `localClockRate = 1 + drift/c` conflates clock drift with rate in a purely affine way that is consistent across truth and estimate; fine at these arc lengths.

---

#### Cross-cutting summary

**What is right and worth crediting**: the four-timestamp mode is a genuinely physical TWSTFT simulation — retarded-time event chains in an inertial frame with Earth-rotation station velocity (Sagnac by construction, matching the ITU worked example's ~100–200 ns class), affine local-clock tagging, truth/product hardware separation, an exact closed-form oracle, the classical ½[(T2−T1)−(T4−T3)] reduction, structurally relay-marginalized session processing with an honest realizable-vs-truth-assisted split, and a conservative nCorr treatment of correlated product error. The refuse-don't-drop guard pattern for inert config leaves is a model of scientific software honesty.

**The defects and boundaries**: (1) legacy first-order reciprocity coefficient −ρρ̇/c is 2× the sequential-protocol asymmetry and omits the common-velocity term, and no test constrains it (mitigated: twin-cancelling, default-off, superseded); (2) ionosphere/troposphere asymmetry entirely absent from every two-way z/h — nanosecond-class at the S-band default, so accuracy (not precision) claims are frequency-unsupportable as configured; (3) counter-tag noise and atmosphere never reach R (guarded, but no run has carried them); (4) the audited one-way-ISL white-product-error defect persists outside the TWSTFT path; (5) relativistic clock rate (≈46 µs/day at GEO) gated off by default — estimation-safe, absolute-timescale-unsafe; (6) legacy and synthetic-ISL modes contain no geometric non-reciprocity at all, so their agreement with prediction is twin consistency, not physics validation.

#### References (APA 7)

- Fridelance, P., Samain, E., & Veillet, C. (1996). *T2L2 – Time transfer by laser link: A new generation optical time transfer*. Observatoire de la Côte d'Azur / CERGA.
- ITU-R. (2015). *Recommendation ITU-R TF.1153-4: The operational use of two-way satellite time and frequency transfer employing pseudorandom noise codes* (08/2015). International Telecommunication Union. [EXTERNAL — retrieved from itu.int]
- Lewandowski, W., Petit, G., & Thomas, C. (1993). Precision and accuracy of GPS time transfer. *IEEE Transactions on Instrumentation and Measurement, 42*(2), 474–479.
- Merlo, J. M., Mghabghab, S. R., & Nanzer, J. A. (2023). Wireless picosecond time synchronization for distributed antenna arrays. *IEEE Transactions on Microwave Theory and Techniques, 71*(4), 1720–1731. https://doi.org/10.1109/TMTT.2022.3227878
- Schaefer, W., Pawlitzki, A., & Kuhn, T. (2000). Two-way frequency transfer via satellite using carrier phase. *Proceedings of the 32nd Annual Precise Time and Time Interval (PTTI) Systems and Applications Meeting*, Reston, VA.
- Shen, D., Chen, G., Pham, K., & Blasch, E. (2022). Enhanced multi-way time transfer for high-precision time synchronization among UASs. *MILCOM 2022 — IEEE Military Communications Conference*, 501–506. https://doi.org/10.1109/MILCOM55135.2022.10017881
- Song, W., Zheng, F., Wang, H., & Shi, C. (2023). 100 picosecond/sub-10⁻¹⁷ level GPS differential precise time and frequency transfer. *Applied Sciences, 13*(19).
- Surof, J., et al. (2026). Precise time transfer and ranging for next-generation GNSS. *GPS Solutions, 30*, 101. https://doi.org/10.1007/s10291-026-02064-2
- Alshaykh, M., et al. (n.d.). *Picosecond clock synchronization across a 7-node metropolitan scale quantum network*. [ELSTAB sub-ps TDEV; WR-PTP 10 ps TDEV — supporting benchmark]

---

# Section: Integer Ambiguity Resolution

This section audits the carrier-phase ambiguity chain of the oo_v1 reverse-GNSS simulation: double-difference (DD) formation and its correlated covariance, the LAMBDA 4.0 wrapper, the new native decorrelated-bootstrap resolver, acceptance testing (success rate + ratio test), wide-lane/narrow-lane/Melbourne-Wübbena machinery, cycle-slip detection and arc management, the float-ambiguity-in-EKF convention, and the new ground-carrier fixing cascade. Every formula was checked digit-by-digit against Joosten & Tiberius (2000), Teunissen (2001, fetched EXTERNAL), Hofmann-Wellenhof et al. (2008), Tagliaferro (2021), Enge (1994) and Naqvi et al. (2013). Headline finding: the mathematically load-bearing pieces — the bootstrapped success-rate formula, the LDLᵀ conditioning convention, the unimodular Z-transform invariant, the correlated DD covariance, and the Melbourne-Wübbena combination — are implemented **correctly** and, unusually for research code, are property-tested against brute force and Monte Carlo. The genuine weaknesses are (i) fixed ratio-test thresholds that the acceptance-testing literature has explicitly deprecated, (ii) several *stale hard-coded claims* ("LAMBDA not implemented in v1") in older diagnostics that now contradict the new `+revgnss/+integer` package, and (iii) a class named `IslDoubleDifference` that forms *single* differences.

Provenance note: quotes from Hofmann-Wellenhof et al. (2008) were extracted from the PDF's embedded text layer (verified twice, byte-identical, e.g. p. 180 eq. 6.72–6.79); "The Global Positioning System- Signals, measurements, and performance.pdf" in the Paper folder is **not** the Misra & Enge textbook but Per Enge's 1994 journal article of the same title, and is cited as such below.

---

### Double-difference formation and the correlated DD covariance

- **Code**: `+revgnss/GroundCarrierAmbiguityResolver.m:262` — DD as `(mw(i,m,k) − mw(1,m,k)) − (mw(i,refTw,k) − mw(1,refTw,k))` (between-satellite, between-tower); `GroundCarrierAmbiguityProbe.m:130-132` — same construction on ranges. Covariance: `GroundCarrierAmbiguityResolver.m:283-314` (`ddCovariance_`) builds `Q = S·Sᵀ·varLink` from a **signed incidence matrix over (link, epoch)**, then normalises to arc means (`Q ./ (cc*cc.')`), explicitly refusing the diagonal assumption ("Assuming it were would understate it and therefore OVERSTATE the success rate", :290-292). `IslDoubleDifference.m:83-87` propagates `QD = D·QU·Dᵀ` through the differencing matrix.
- **Verdict**: ✅ The DD algebra is textbook-correct and — the part most codes get wrong — the between-DD correlation from the shared reference satellite and reference tower is built exactly, not approximated.
- **Sources**: Hofmann-Wellenhof, Lichtenegger & Wasle (2008) — single differences: "Σ_S = 2σ² I … single-differences are uncorrelated" (p. 179, eq. 6.71); double differences: "Σ_D = 2σ² [2 1; 1 2] … This shows that double-differences are correlated" (p. 180, eq. 6.77). Teunissen (2001, EXTERNAL) — "The method of bootstrapping performs relatively poor, for instance, when applied to the DD ambiguities. This is due to the usually high correlation between the DD ambiguities" (p. 252).
- **Critical analysis**: Digit check against Hofmann-Wellenhof's canonical structure: for two DDs at one epoch sharing the reference satellite and reference tower, the incidence construction yields `var = 4·v`, `cov = 2·v` (two shared links, both with sign product +1) → correlation 0.5 — exactly the `2σ²[2 1;1 2]` pattern of eq. (6.77) (there written per satellite pair; here per link, so 4v on the diagonal because a ground DD combines **four** links). The incidence-matrix formulation (`sparse(r,c,v)` then `S·Sᵀ`) is exact for arbitrary sharing patterns and O(rows) rather than O(rows²) — a genuinely good engineering choice for the 21601-epoch arcs. The arc-mean normalisation `cov(mean_p, mean_q) = Σ cov /(n_p·n_q)` is correct because `S` sums over each ambiguity's epochs. One naming defect: **`IslDoubleDifference` computes a single difference** (one common receiver; the header admits "with one primary receiver only the single difference is available", :30-31) — honest in content, misleading in name, and the surviving transmitter-clock term is quantified in `reportBiasBudget` (:136-152) as `√2·σ_txClock/λ`. The in-code figure "sigmaClock_m = 0.02 m … ~0.1 cycle" (:29-30) is stale: `masterConfig.m` sets `sigmaClock_m = 0.03`, which is `√2·0.03/0.1903 ≈ 0.22` L1 cycles — a bias approaching the half-cycle danger zone, correctly computed at runtime but understated in the comment.

### LambdaResolver — the LAMBDA 4.0 wrapper

- **Code**: `+revgnss/+integer/LambdaResolver.m:56-75` — metres→cycles for vector **and full covariance** (`Qa_cyc = D·Qa_m·Dᵀ`); :108-113 positive-definiteness gate; :120 `Ps_LAMBDA(Qa_cyc, 1, 1)` success-rate gate **before** fixing; :135-136 `LAMBDA(aHat, Qa, method, nCands)` with method 3 (ILS) default; :162-170 hard refusal of partial (PAR) fixes; :174-181 ratio test `sqnorm(2)/sqnorm(1) ≥ 2.0`; :188-202 `assertIntegerParametrisation` contract; :209-210 defaults `minSuccessRate = 0.999`, `ratioThreshold = 2.0`.
- **Verdict**: ✅/❓ The wrapper's own algebra and gating logic are correct and unusually defensive; the toolbox internals (Ps_LAMBDA method codes, `LAMBDA.m:155` PAR threshold 0.99) are **unverifiable** here because the toolbox is deliberately not vendored (no licence grant — `docs/LAMBDA_SETUP.md:8-18`).
- **Sources**: Teunissen (1995, EXTERNAL): the Z-transformation "aim[s] at decorrelating the least-squares ambiguities and [is] based on an integer approximation of the conditional least-squares transformation" (J. Geodesy 70, 65–82, abstract). Naqvi et al. (2013): "the ambiguities are decorrelated with an admissible transformation i.e., which preserves the integerness of the variables, resulting in a much less elongated search space" (p. 6). Joosten & Tiberius (2000): "Only when the success rate is close enough to 1 is one allowed to proceed as if the estimated integer ambiguities are non-stochastic" (p. 50).
- **Critical analysis**: Three things deserve explicit credit. (1) The full-covariance unit conversion (:71-74) is load-bearing — "ILS decorrelation lives or dies on the off-diagonals" — and is exactly what the older `IntegerAmbiguityFixer` (diag-only) lacks. (2) The precondition assertion is scientifically the most important line in the file: undifferenced ambiguities here are `B = λN + bias` (they absorb the per-arc clock bias, `CarrierMeasurementBuilder.m:280-282`), so their truth is **not** integer, and LAMBDA on them would fabricate integers — the assert plus the SR gate is the right two-layer defence, matching this project's own measured Route-1 failure. (3) The partial-fix refusal (:162-170) is a correct reading of a real trap: PAR returns conditioned floats for unfixed components and LAMBDA 4.0 reports only the *count* fixed, so rounding the remainder would inject fabricated integers at millimetre sigma. The 0.999 SR floor is squarely inside the literature's "say 99 or 99.9 percent" guidance (Joosten & Tiberius, p. 51). Remaining ❓: the claim "Ps_LAMBDA method 1 = Integer Bootstrapping (exact)" and the hardcoded 0.99 PAR threshold at `LAMBDA.m:155` describe an absent external artefact and cannot be audited from the repo — they should be re-verified once against an installed toolbox and the check recorded.

### DecorrelatedBootstrap — decorrelation, exact bootstrap success rate, bounded ILS

- **Code**: `+revgnss/+integer/DecorrelatedBootstrap.m:191-205` (`ldl_`) — hand-rolled forward `Q = L·diag(d)·Lᵀ`, refusing MATLAB's pivoting `ldl()`; :123-166 (`reduce_`) — integer Gauss reductions (`mu = round(L(i,j))`, drive |L(i,j)| < ½) plus adjacent permutations when `dbar = d(k)·L(k+1,k)² + d(k+1) < d(k)`, with **full re-factorisation after each swap**; :72 — the success rate `prod(2*normcdf(1./(2*sig)) − 1)` with `sig = sqrt(d)` of the **decorrelated** factorisation; :207-218 (`bootstrap_`) — sequential conditional rounding `w_i = cond_i − z_i`, `cond_i = ẑ_i − Σ_{j<i} L(i,j)·w_j`; :220-282 (`ils_`) — depth-first search-and-shrink with node budget, initial ellipsoid `chi2 = (ratioThreshold+1)·cost(bootstrap)` (:244); :168-177 `verifyTransform` asserts Z unimodular and `Zᵀ·Q·Z = L·D·Lᵀ`; :307-312 ADOP `det(Q)^(1/2n)`.
- **Verdict**: ✅ Digit-perfect against the literature: the success-rate product, the conditioning convention, the decorrelate-then-bootstrap order, the Schnorr–Euchner-style zig-zag enumeration and the ADOP definition are all correct, and the file's documented convention matches its algebra.
- **Sources**: Teunissen (2001, EXTERNAL), Corollary 5: "P(ǎ_B = a) = ∏_{i=1}^{n} (2Φ(1/(2σ_{â_i|I})) − 1)" (p. 250, eq. 19); order dependence: "Bootstrapping of DD ambiguities … will produce an integer solution which generally differs from the integer solution obtained from bootstrapping of reparametrized ambiguities" (p. 252); "Bootstrapping should therefore be used in combination with the decorrelating Z-transformation of the LAMBDA method" (p. 252); ILS bound: "the bootstrapped lower bound is presently the best available lower bound of the least-squares success rate" (p. 253). Joosten & Tiberius (2000): "The conditional standard deviations follow directly from the triangular decomposition of the float ambiguity variance-covariance matrix" (p. 51); "it is essential that the variance–covariance matrix of the LAMBDA-transformed ambiguities be used to compute the conditional standard deviations" (p. 51). Tagliaferro (2021): "A lower bound for the success rate can be compute as [107]: P(ẑ_r = ẑ) = ∏_i (1 − 2·∫_{−∞}^{−1/2} Ψ(x,0,γ_i²) dx)" (p. 35, eq. 3.33 — algebraically identical to eq. 19); "Such a procedure is called search and shrink strategy" (p. 37).
- **Critical analysis**: I verified the algebra independently. (1) **Formula**: `2Φ(1/(2σ))−1` with Φ implemented as `0.5·erfc(−x/√2)` (:314-316) is the exact standard-normal CDF — matches Teunissen's eq. (19) symbol for symbol, and 1−2∫_{−∞}^{−1/2}N(0,γ²) in Tagliaferro's form is the same quantity. (2) **Convention**: with `Q = LDLᵀ` (L unit lower), `w = L⁻¹e` gives `eᵀQ⁻¹e = Σ w_i²/d_i` and `d_i = var(component i | 1..i−1)` — the code's stated invariant (:26-32) is right, and, critically, the SR is computed from the `d` of the *reduced* (Z-transformed) factorisation (:60-72), satisfying Joosten & Tiberius's sharpness condition — **order matters, and the code gets the order right**. Note the convention differs from Teunissen's `Qâ = LᵀDL` (conditioning from the last ambiguity); both are valid, and the file documents its choice "because getting it wrong is silent". (3) **Swap criterion**: after permuting k,k+1 the new leading conditional variance is exactly `d_k·L(k+1,k)² + d_{k+1}`, so the test at :153-154 swaps iff it decreases — the LAMBDA reduction condition in this convention. Re-factorising O(n³) after each swap instead of the closed-form 2×2 update trades speed for guaranteed consistency at n ≲ tens — defensible and documented. (4) **The safety ellipsoid argument is correct and clever**: since `cost(boot) ≥ cost(ILS best)`, any runner-up missed outside `chi2 = (ratio+1)·cost(boot)` has `c₂/c₁ ≥ c₂/cost(boot) > ratio+1 > ratio` — a missed candidate can only make the ratio test *harder* to pass, never produce a false accept. (5) Two weaker spots: on node-budget exhaustion the **bootstrapped fix is accepted without any ratio test** (:92-97) — the failure probability is still bounded by 1−P_s and the condition is reported, but the discrimination guarantee is silently weaker on that path; and "decorrelation cannot lower the SR" is *empirically tested* (20 random cases, test 3) rather than proven — consistent with Teunissen (2001) but the code cites no proof. Also note the Tagliaferro thesis itself (p. 35) states the bootstrap/rounding SR ordering backwards ("never greater to the one of the rounding operator" — the established result, e.g. Teunissen 2001, is P_rounding ≤ P_bootstrap ≤ P_ILS); the repo does **not** inherit this error.

### Acceptance testing — success-rate gate and fixed ratio thresholds

- **Code**: `LambdaResolver.m:127` SR ≥ 0.999 else `reject-lowSuccessRate`; :174-181 `ratio = sqnorm(2)/sqnorm(1)`, reject < 2.0. `DecorrelatedBootstrap.m:75-79` same SR gate; :101-113 same ratio test. `config/masterConfig.m:313-314` (`minSuccessRate = 0.999`, `ratioThreshold = 2.0`); `:331/:1691` diffAtt `ratioThreshold = 3.0`; `:1520-1522` groundCarrier `0.999 / 2.0`.
- **Verdict**: ⚠️ The two-gate design (covariance-only SR floor **and** discrimination test) is stronger than common practice, but the ratio thresholds (2.0, 3.0) are the fixed critical values the acceptance-testing literature explicitly deprecates, and no source for them is given in the code.
- **Sources**: Tagliaferro (2021): "The test checks whether the ratio between the objective function Ω() … computed using the ILS (ž₁) and computed using the second best integer vector (ž₂) is greater than a certain threshold: Ω(ž₂)/Ω(ž₁) > γ" (p. 20, eq. 2.56). Verhagen & Teunissen (2013, EXTERNAL, GPS Solutions 17:535–548): the fixed-critical-value ratio test is "not sustainable" and "the model-driven ratio test with fixed failure rate is proposed" (abstract). Joosten & Tiberius (2000): "even with a high enough success rate, fixing to the wrong integer ambiguities is still possible when one or more observations are grossly erroneous" (p. 50).
- **Critical analysis**: The ratio convention (`sqnorm(2)/sqnorm(1) ≥ c`, larger = safer) matches Tagliaferro's eq. 2.56. But c = 2.0/3.0 are folklore values: Verhagen & Teunissen showed the failure rate achieved by a fixed c varies by orders of magnitude with model strength, and recommend the fixed-failure-rate ratio test (FFRT) with model-driven look-up tables. Two mitigating facts deserve credit: the *primary* gate here is the covariance-driven bootstrapped SR — which is itself model-driven and is exactly the "compute before measurement" diagnostic Joosten & Tiberius advocate — and the two gates are conjunctive, so the fixed-ratio weakness only bites in the regime SR ≥ 0.999 but geometry near-degenerate, which the SR bound already limits to ≤ 10⁻³ failure. Still, the reported `failureRate` is the IB failure rate, not the failure rate *of the composite accept rule*; a reader could over-trust it. Recommended text for the paper: quote the SR as "P(false fix) ≤ 1 − P_s,IB (a rigorous ILS lower bound), with an additional heuristic ratio ≥ 2 screen". `BaselineCarrierAmbiguityResolver.m:170-183` uses a different, unsourced ratio (RMS of second-best/best candidate over an arc, default 2.0, masterConfig 3.0) — this is a *residual-domain screening heuristic*, not the ILS ratio test; the class honestly labels the result `falseFixClassification = 'screenedNotFormal'` (:54).

### Wide-lane / narrow-lane / Melbourne-Wübbena

- **Code**: `+revgnss/WideLaneNarrowLaneDiagnostics.m:49-50` — `λ_WL = c/(f1−f2)`, `λ_NL = c/(f1+f2)`; :168 — `D = [1/λ1, −1/λ2; 1/λ1, 1/λ2]`, :192 `P_N = D·P_pair·Dᵀ` (full 2×2, not diagonal). `GroundCarrierObservationSet.m:67-68` same wavelengths; :137-140 observation model with the iono sign flip (`phase … − Ik`, `code … + Ik`, L2 scaled by `(f1/f2)²`); :159-163 `N_WL = N1 − N2`, `N_NL = N1 + N2` derived from exactly two integers per link. `GroundCarrierAmbiguityResolver.m:255-256` — `MW = (f1·L1 − f2·L2)/(f1−f2) − (f1·P1 + f2·P2)/(f1+f2)`; :270-271 — `varMW = (f1²+f2²)·σ_φ²/(f1−f2)² + (f1²σ_P1²+f2²σ_P2²)/(f1+f2)²`. `GroundCarrierAmbiguityProbe.m:88-90` — `amp_WL = √(f1²+f2²)/(f1−f2)`, `amp_NL = √(f1²+f2²)/(f1+f2)`.
- **Verdict**: ✅ Every number checks out: λ_WL = 299792458/347.82e6 = 0.86192 m (≈86.2 cm), λ_NL = 0.10695 m (≈10.7 cm), and I verified by direct algebra that the implemented MW combination is geometry-free (ρ cancels identically) **and** ionosphere-free (both terms carry +I·f1/f2, which cancels in the difference), with ambiguity term exactly λ_WL·N_WL.
- **Sources**: Hofmann-Wellenhof et al. (2008): "the combination Φ₁ + Φ₂ is denoted as narrow lane and Φ₁ − Φ₂ as wide lane. The lane signals are used for ambiguity resolution" (p. 112); "the noise level for the linear combination differs by the factor √(n₁²+n₂²)" (p. 112); "a wide lane with a wavelength of 86 cm (cf. Table 7.4)" (p. 218); "The only disadvantage of using the wide lane is that the measurement is significantly noisier than the single phase" (p. 218). Enge (1994): "This signal has a wavelength of approximately 84 cm and can be used to help resolve L₁ cycle ambiguities … This technique is known as 'wide-laning'" (p. 90).
- **Critical analysis**: The noise-amplification convention warrants one clarification for the paper: Hofmann-Wellenhof's √(n₁²+n₂²) = √2 is in **cycles** with equal per-band cycle noise; the code's `√(f1²+f2²)/(f1−f2) ≈ 5.74` is the metre-domain amplification with equal per-band **metre** noise — internally consistent, since `GroundCarrierObservationSet.m:137-138` draws σ_φ in metres per band. (Enge's "approximately 84 cm" is a loose rounding; the exact value 86.19 cm matches the code and Hofmann-Wellenhof's Table 7.4.) The structurally important fix is F3 (`GroundCarrierObservationSet.m:16-23`): the truth carries exactly **two** integers (N1, N2) per link/arc and all lanes are derived — the earlier probe drew four independent per-band integers, which destroys the N_WL = N1 − N2 constraint that makes a WL→L1 cascade meaningful at all. That defect-and-fix is correctly documented in the code. The narrow-lane noise amplification (÷(f1+f2), i.e. *attenuation* in metres, but ~19× in NL cycles relative to λ_NL) is present via `amp_NL`; the WL/NL diagnostics propagate the full 2×2 pair covariance including the WL/NL correlation term (`corrWideNarrow`, :204-205), which for L1/L2 is structurally near ±1 — correctly reported rather than assumed away.

### Cycle-slip detection and arc management

- **Code**: `+revgnss/CycleSlipDetector.m:40-64` — `|Δprefit| ≥ threshold` after warmup; :9-38 `detectCompensated` subtracts deterministic tower-clock product steps. `CarrierTrackManager.m:109-219` — per-track history, arc IDs increment on slip, `resetAndSkip`/`resetAndUse` actions; :416-468 common-mode and baseline-differenced metric overrides. `IslCarrierTrackManager.m:182-219` — auto threshold `5·√2·σ_carrier` (NaN default), warning below `0.8×` auto; :77-84 tracks only EKF-used rows (the 878-false-slip acquisition loop fix). Truth-side slip process: `GroundCarrierObservationSet.m:94` — `pSlip = 1 − exp(−rate·dt/3600)` (Poisson-consistent). Slip → covariance reset to `initialSigma_m²` (masterConfig:2200, `= 100 m`).
- **Verdict**: ⚠️ Internally consistent and honest about its limits, but the detector is a bare time-differenced-residual test — none of the standard geometry-free / Melbourne-Wübbena detectors (e.g. TurboEdit) is implemented or cited, and the threshold scaling is derived from first principles in comments rather than sourced.
- **Sources**: Hofmann-Wellenhof et al. (2008) treat cycle slips as arc-breaking discontinuities requiring repair or re-initialisation of the ambiguity (ch. 7); Tagliaferro (2021): a continuous ambiguity is defined "For each continuous set of phase data (no Cycle Slip no loss of tracking)" (p. ~103). (No repo source claims more than is implemented.)
- **Critical analysis**: The physics is right where it matters for this simulation: (1) a slip **starts a new arc and re-inflates P** — without which the filter is "confidently wrong" (`IslCarrierTrackManager.m:20-24`), the same failure mode the project measured for missing warmup; (2) the `√2·σ` prefit-difference noise scaling and the resulting auto threshold are correct error propagation, and the masterConfig comment (:2214-2217) honestly concedes the consequence: at σ = 0.20 m the auto threshold is ~7 L1 cycles, so single-cycle slips are **undetectable** — a real, stated limitation rather than a hidden one; (3) the model-step compensation (`detectCompensated`) removing deterministic product-boundary jumps before testing is a sound, if bespoke, refinement. What is missing relative to practice: dual-frequency geometry-free (L1−L2) and MW-based detection would see slips far below the code threshold and are standard in the cited literature; since `GroundCarrierObservationSet` now synthesises dual-frequency observables, an MW-jump detector would be cheap and would materially lower the detectable-slip floor for the ground-carrier cascade (its arc keying at `GroundCarrierAmbiguityResolver.m:199-242` — one ambiguity per tuple of the four link arcs — is exact and slip-safe, so only detection sensitivity, not bookkeeping, is the gap).

### Float ambiguity as EKF state, and the birth-at-geometry-error trap

- **Code**: `+models/+measurements/CarrierMeasurementBuilder.m:280-283` — "Float ambiguity B_est absorbs constant clock bias per arc; inflating R would incorrectly degrade carrier…"; :334 — `H_phi(rowOut, ambStateIdx) = 1` (ambiguity in metres, unit Jacobian); masterConfig:2203 — `processNoiseSigma_m_per_sqrt_s = 0` (constant within arc), :211/:2745 — `initialSigma_m = 100`. Mitigation of the birth trap: `+revgnss/ISLMeasurementBuilder.m:133-140` — **hard error** if `warmup_s ≤ 0` with carrier in the EKF ("the ambiguity settles 100s of metres from truth while reporting sigma(B) ~ 12 mm"); :96-101 measured 300 s default → "1-4 cm with sigma ~ 29 mm, i.e. error ~ sigma (consistent)".
- **Verdict**: ✅ The float-ambiguity-as-constant-state convention is standard filter practice, correctly implemented (zero process noise within an arc, reset per arc), and the repo's own measured lesson — "a bias state is born carrying the geometry error at its birth epoch" — is enforced by a hard configuration error, not a comment.
- **Sources**: Teunissen (2001, EXTERNAL): the float solution treats ambiguities as real-valued parameters of the linear model `y = Aa + Bb + e` with `a ∈ Zⁿ` relaxed (p. 246). Joosten & Tiberius (2000): "In the first step … The parameter-estimation problem is solved without taking into account the special integer characteristic of the ambiguities. The result so obtained is often referred to as the float solution" (p. 46). Tagliaferro (2021) builds its entire undifferenced-uncombined adjustment on per-arc constant float ambiguities (ch. 5).
- **Critical analysis**: Two conventions are worth flagging as *correct but non-obvious*. (1) Storing B in metres with H-coefficient +1 (rather than N in cycles with coefficient λ) is self-consistent throughout the ground and ISL paths and is documented at masterConfig:2190-2192, together with the crucial corollary: the undifferenced B "is NOT an integer (it absorbs the clock bias per arc) — integer resolution needs a differenced parametrisation". This is exactly the LAMBDA validity precondition and matches the wrapper's assert. (2) The warmup guard converts a silent failure (tight R collapsing P around an invalid linearisation at km-level position error) into a hard error with measured numbers in the message — the correct engineering response to the project's Route-1 "float ambiguity absorbs the rotation" finding. Residual gap: the warmup addresses birth at *filter start*; an ambiguity re-born mid-run by a slip reset inherits the *current* (converged) geometry, so the 100 m reset sigma is defensible — but nothing prevents a slip reset during a geometry excursion from re-absorbing that excursion; only the SR gates downstream would catch it.

### GroundCarrierAmbiguityResolver — the MW → WL-fix → conditioned-geometry → L1 cascade

- **Code**: `+revgnss/GroundCarrierAmbiguityResolver.m:80-99` — arc-averaged MW DD → float N_WL with full correlated covariance → `fixIntegers_` (LAMBDA if installed, else DecorrelatedBootstrap, :427-440, engine recorded); :101-111 — fixed WL published as an unambiguous per-link pseudo-range (gauge choice: integer 0 on reference satellite/tower, :316-345); :113-129 — geometry re-conditioned through `JointGeometrySolver` on the fixed-WL range; :131-149 — L1 float against conditioned geometry with `N2 = N1 − N_WL` halving the search; :393-402 — L1 covariance: phase part via `ddCovariance_` plus geometry error charged **fully correlated** (`+ varCyc·ones(n)`, "arc-correlated and therefore does not average away … effective sample count of one"); :453-476 — truth integers used for **scoring only**, after all decisions.
- **Verdict**: ⚠️ The cascade architecture (MW wide lane first, then L1 with the WL constraint) is textbook and the no-truth-in-decisions discipline is genuinely enforced; but two numerical inputs are ad hoc heuristics — `geometryDdSigma_`'s `0.23·√3·f·2` chain and its 0.15 m fallback (:405-425) — and the WL-conditioned-geometry step makes the L1 covariance partially self-referential.
- **Sources**: Hofmann-Wellenhof et al. (2008): "Many OTF implementations use the wide lane to resolve integer ambiguities and then use the resulting position to directly compute the ambiguities on the original carrier phase" (p. 218) — precisely this cascade. Joosten & Tiberius (2000): computing the SR "without having the actual measurements available" and only proceeding when it is close to 1 (p. 50) — the F5 discipline. Teunissen (2001, EXTERNAL) p. 253 grounds quoting the IB rate as the ILS lower bound.
- **Critical analysis**: What is right: MW is geometry-free, so the WL float sigma is `σ_MW/(λ_WL·√n)` — the fix probability is decoupled from the very geometry error the programme is trying to improve, breaking the circularity the header itself criticises in the earlier wavelength-margin argument (:9-22); the DD covariance is built correlated (see above); the failure direction of every approximation is stated (diagonal ⇒ SR overstated ⇒ refused); realised correctness is computed but quarantined ("REGISTER (not a decision input)", :192). What is weak: (1) `geometryDdSigma_` converts a posterior shape sigma to a DD sigma via `0.23·√3·f·2` — the 0.23 tower-geometry demagnification is measured elsewhere in the project but is hardcoded here without derivation, and the 0.15 m default is a magic number; since this sigma *dominates* the L1 float covariance, the L1 SR inherits its uncertainty. (2) Preferring the WL-conditioned posterior sigma for the L1 gate (:414-419) is the legitimate point of a cascade, but it means the L1 SR is conditional on the WL geometry update being honest — the chain is only as strong as `JointGeometrySolver`'s own acceptance test, which is outside this section's audit. (3) The charge of the geometry error as rank-one fully-correlated (`ones(n)`) is conservative in trace but idealised in structure; a per-tower/per-satellite correlation model would be more faithful. None of these breaks the design; they cap how literally the printed `P(false fix)` for **L1** should be read, whereas the **WL** number rests only on MW noise and is solid.

### IntegerAmbiguityFixer (legacy) and BaselineCarrierAmbiguityResolver / BaselineAmbiguityLambda

- **Code**: `+revgnss/IntegerAmbiguityFixer.m:104-107` — rounding with ad hoc gates: `maxSigma_cycles = 0.15`, `maxDistanceToInteger_cycles = 0.20`, `minArcLength_s = 300`, residual-RMS non-worsening check (:177-204); header (:2-7): "NOT LAMBDA/MLAMBDA. NOT carrier-IF fixing. NOT WL/NL. NOT false-fix-risk." `BaselineCarrierAmbiguityResolver.m:160-183` — per-baseline scalar candidate search over ±5 cycles, RMS/ratio/float-distance gates, dual-frequency joint cost `J = n₁·rms₁² + n₂·rms₂²` (:213-218), WL-consistency screen `|N_WL,float − (N1−N2)| < 0.5` (:221-234). `+revgnss/+integer/BaselineAmbiguityLambda.m:69-71` — Qa is diagonal by construction, recorded as `'diagonal-separablePerBaseline'`; :15-19 — "For a diagonal Qa, integer least squares provably degenerates to bootstrapping and to plain rounding".
- **Verdict**: ✅/⚠️ All three are honest about being heuristics; the diagonal-Qa degeneracy claim in `BaselineAmbiguityLambda` is mathematically correct (pull-in regions of ILS under a diagonal covariance are the unit hypercubes, so ILS ≡ rounding), and its role as a *formal-SR annotator* over the heuristic fixer is the right division of labour — but the heuristic thresholds themselves (0.15/0.20 cycles, ratio 2–3) are nowhere sourced.
- **Sources**: Teunissen (2001, EXTERNAL): rounding SR "P(ǎ_R = a) = ∏(2Φ(1/(2σ_âᵢ))−1)" holds with *unconditional* sigmas for the diagonal case, where all admissible estimators coincide (pp. 249–250). Joosten & Tiberius (2000): "different methods of integer estimation will generally result in different success rates" (p. 49) — the reason the diagonal-case equivalence is worth pinning in a test.
- **Critical analysis**: Worth stating in the paper: the legacy fixer's `maxSigma_cycles = 0.15` implicitly corresponds to a per-component rounding success of `2Φ(1/(2·0.15))−1 = 2Φ(3.33)−1 ≈ 0.9991` — i.e. it is *numerically* aligned with the 0.999 SR floor of the modern gates, but only per component: with m components the joint rate is ≈ 0.999^m and no joint gate exists there. The code never claims otherwise ("falseFixRisk:false"), so this is a documented limitation, not an error. `BaselineAmbiguityLambda`'s compare-only-where-production-fixed guard (:169-176) closes a real false-alarm hole (preallocated zeros read as disagreements). The one theoretically load-bearing subtlety — that adding LAMBDA to a separable problem *cannot* change the integers — is exactly right and prevents the false claim "LAMBDA improved the attitude fix" from ever being made.

### AmbiguityFixingReadinessGate and stale "not implemented" claims

- **Code**: `+revgnss/AmbiguityFixingReadinessGate.m:209-212` — unconditional blockers: "No integer strategy implemented (LAMBDA/MLAMBDA not available in v1)", "Integer fixing not implemented in v1", "False-fix-risk control not implemented (ratio test absent)"; :255 terminal classification `'float-diagnostics-ready-integer-blocked'`; header (:5-7): "Hard facts always false: … integerFixingImplemented, lambdaImplemented, falseFixRiskControlled". Same frozen strings in `AmbiguityArcState.m:127-129,150-158` and `WideLaneNarrowLaneDiagnostics.m:230-233,277-287`.
- **Verdict**: ❌ (traceability, not physics) These hard-coded claims are now **false as global statements**: the repo contains a LAMBDA 4.0 wrapper with a bootstrapped-SR gate and ratio test (`LambdaResolver`), a native IB+ILS resolver (`DecorrelatedBootstrap`), and a no-truth fixing cascade (`GroundCarrierAmbiguityResolver`) — all with explicit false-fix-risk control.
- **Sources**: repo-internal contradiction; cf. `docs/LAMBDA_SETUP.md:50-63` ("A success-rate gate … This is the false-fix protection `IntegerAmbiguityFixer` explicitly lacks") — the docs are current, the gate strings are not.
- **Critical analysis**: The gate remains *locally* true for the v1 ground-to-space EKF pipeline it audits (no integer fix is applied inside that EKF, and phase-bias products indeed do not exist), but a reader of the printed report will see "LAMBDA/MLAMBDA not available in v1" and "ratio test absent" in the same run that prints a LAMBDA/bootstrap decision with a ratio value — a direct internal contradiction that would be flagged in review. The strings should be scoped ("not applied in the ground EKF path; see ground-carrier resolver for the integer path") or driven from the actual config gates. The readiness *score* itself (6 evidence items: pair metadata, Pamb, IF traceability, WL/NL, arc quality, residual/NIS) is a sensible bespoke construction with no literature analogue claimed — acceptable as engineering telemetry, provided it is not presented as a standard metric. Note also the SR-floor comparison requested by the audit brief: the gate has **no** SR threshold at all (it predates the SR machinery); the SR floors live in the resolvers (0.999, matching Joosten & Tiberius's "99 or 99.9 percent" and stricter than many RTK defaults).

### Test coverage — tests/test_decorrelated_bootstrap.m

- **Code**: `tests/test_decorrelated_bootstrap.m:26-39` — invariant `ZᵀQZ = LDLᵀ`, |det Z| = 1, L unit-lower, over 20 random SPD matrices; :41-84 — ILS solution equals exhaustive enumeration (n ≤ 4, ±4 box, 12 trials); :86-100 — decorrelation never lowers the bootstrapped SR (20 cases); :102-131 — Monte Carlo (4000 draws from N(a, Q)) confirms predicted SR is a valid lower bound on the measured fix rate, with the sigma regime deliberately scaled to ~0.1 cycles "where the test can actually discriminate".
- **Verdict**: ✅ These are the four properties that matter (transform validity, search optimality, decorrelation benefit, SR as a real probability), tested against ground truth rather than against the implementation's own outputs.
- **Sources**: Joosten & Tiberius (2000): "One way of obtaining the success rate is by simulation … The percentage of integer solutions that coincide with the origin yields the success rate" (p. 51) — test 4 is exactly this procedure, inverted into an assertion. Teunissen (2001, EXTERNAL) eq. 28 (P_IB ≤ P_ILS) justifies the one-sided `measured ≥ predicted − tol` check at :123-128.
- **Critical analysis**: The one-sidedness of test 4 is correctly reasoned (resolve() returns the ILS answer, so the IB prediction must be a lower bound — asserting closeness would be wrong). Gaps: no test exercises the ratio-test *rejection* path, the node-budget-exhaustion fallback, or an adversarial ill-conditioned Q (condition numbers here are benign by construction, `+0.01·eye`); and the brute-force box (±4) could in principle miss the true minimiser for extreme correlation, though at n ≤ 4 with these matrices it will not. The property "counted trials are not independent trials" is tested nowhere for the *probe's* Wilson-on-effective-count machinery (`GroundCarrierAmbiguityProbe.m:189-223`), whose AR(1) `n_eff = n(1−ρ)/(1+ρ)` and Wilson interval (z = 1.95996) are nonetheless digit-correct standard formulas.

---

#### References (APA 7)

- Enge, P. K. (1994). The Global Positioning System: Signals, measurements, and performance. *International Journal of Wireless Information Networks, 1*(2), 83–105. [PDF in Paper/Fundamental Books — note: this is the 1994 article, not the Misra & Enge textbook]
- Hofmann-Wellenhof, B., Lichtenegger, H., & Wasle, E. (2008). *GNSS — Global Navigation Satellite Systems: GPS, GLONASS, Galileo, and more*. Springer. [PDF in Paper/Fundamental Books; quotes pp. 112, 179–180, 218]
- Joosten, P., & Tiberius, C. C. J. M. (2000). Fixing the ambiguities: Are you sure they're right? *GPS World, 11*(5), 46–51. [PDF in Paper/Positioning Technologies]
- Massarweh, L., Verhagen, S., & Teunissen, P. J. G. (2024). *New LAMBDA toolbox for mixed-integer models: Estimation and evaluation* (LAMBDA 4.0). TU Delft. [EXTERNAL — cited by docs/LAMBDA_SETUP.md; toolbox not vendored, internals unverified]
- Naqvi, N. A., Zhang, K., Masood, K., & Lv, M. (2013). *Design and simulation of GNSS phase based attitude determination of spacecraft: LAMBDA and EKF combination technique* (AIAA 2013-4832). AIAA Guidance, Navigation, and Control Conference. [PDF in Paper/Error Calculation/Atmospheric Errors]
- Tagliaferro, G. (2021). *On the development of a general undifferenced uncombined adjustment for GNSS observations* [Doctoral dissertation, Politecnico di Milano]. [PDF in Paper/Fundamental Books; quotes pp. 20, 35–37]
- Teunissen, P. J. G. (1995). The least-squares ambiguity decorrelation adjustment: A method for fast GPS integer ambiguity estimation. *Journal of Geodesy, 70*(1–2), 65–82. https://link.springer.com/article/10.1007/BF00863419 [EXTERNAL]
- Teunissen, P. J. G. (1998). Success probability of integer GPS ambiguity rounding and bootstrapping. *Journal of Geodesy, 72*(10), 606–612. https://link.springer.com/article/10.1007/s001900050199 [EXTERNAL]
- Teunissen, P. J. G. (2001). GNSS ambiguity bootstrapping: Theory and application. *Proceedings of KIS 2001, International Symposium on Kinematic Systems in Geodesy, Geomatics and Navigation*, 246–254. https://gnss.curtin.edu.au/wp-content/uploads/sites/21/2016/04/Teunissen2001GNSS.pdf [EXTERNAL — fetched and quoted verbatim: eq. 19 p. 250, pp. 252–253]
- Verhagen, S., & Teunissen, P. J. G. (2013). The ratio test for future GNSS ambiguity resolution. *GPS Solutions, 17*(4), 535–548. https://link.springer.com/article/10.1007/s10291-012-0299-z [EXTERNAL — abstract-level claims only]

---

# Section: ISL, Link Budget, Beamforming & Swarm Solvers

This section traces the inter-satellite-link RF chain (free-space path loss, C/N0, code-tracking
noise), the beamforming diagnostics (exact phasor sum, Ruze envelope, near-field focus,
expected-gain budget), and the swarm/relative estimation solvers (free-network shape solve, joint
shape+rotation solve, ground-differenced rotation solve, split covariance intersection) of the
oo_v1 simulation against their primary sources. The overall picture: the RF/link-budget arithmetic
is textbook-correct to the digit (FSPL, Boltzmann, plasma delay, aperture gain), the beamforming
phasor mathematics is correct and unusually honest about its own regime (near-field focus, Ruze as
envelope only, incoherent floor), and the estimation solvers respect the fundamental
rigid-motion-blindness of range data. Three findings need flagging: (1) the "classical MDS" the
project memory attributes to `SwarmRelativeSolver` is not what is implemented — the shipped code is
an iterative Gauss-Newton free-network least-squares adjustment with a truncated-SVD min-norm
gauge, with Kabsch/Procrustes used only in the truth-side metric; (2) the one-way ISL builder still
charges a piecewise-constant broadcast-product error as white per-epoch measurement noise
(overconfident R), in direct tension with the repo's own stated rule, which the two-way builder and
the relative solver both enforce; (3) most solver-layer "observables" are re-synthesised from
recorded truth (declared, but it bounds what the results can claim). All code paths below are
gated off by default and documented as such.

Repo root: `oo_v1/`. All line numbers refer to the working tree of 2026-08-06
(branch `feature/ground-orientation-exec`).

---

### 1. Free-space path loss and the C/N0 chain

- **Code**: `+revgnss/InterSatelliteRFLinkModel.m:142-168` —
  `fspl = 20*log10(4*pi*distance*frequency/c)` with `c = 299792458`;
  `receivedCarrier = eirp + rxAntenna.gain_dBi - fspl - losses`;
  `noiseDensity = 10*log10(kBoltzmann*noiseTemperature)` with `kBoltzmann = 1.380649e-23`;
  `cn0_dBHz = receivedCarrier - noiseDensity`. The simplified anchored model
  `+revgnss/ISLLinkBudget.m:7-8` documents the same chain
  (`L_fs = 20*log10(4*pi*d*f/c)`, `C/N0 = EIRP + G/T - L_fs - k_boltz`).
- **Verdict**: ✅ Digit-exact against ITU-R P.525 and the standard link-budget identity; every
  constant checks out.
- **Sources**:
  - International Telecommunication Union. (2024). *Recommendation ITU-R P.525-5: Calculation of
    free-space attenuation*. — "Introducing free-space attenuation between isotropic antennas, also
    known as the free-space basic transmission loss (symbols: Lbf or Abf), it can be calculated as
    follows" (p. 3), Eq. (5): L_bf = 20 log10(4πd/λ) dB. The code's `20*log10(4πdf/c)` is the
    identical quantity with λ = c/f. P.525's frequency form "L_bf = 32.4 + 20 log10 f + 20 log10 d
    dB" (p. 3, Eq. (6), f in MHz, d in km) digit-checks against the code:
    20·log10(4π·10⁶·10³/c) = 32.45.
  - Arias, M., & Aguado, F. (2016). *Small satellite link budget calculation* [Slides,
    Universidade de Vigo]. — "C/N0: Relation between the power of the modulated carrier C and the
    noise power spectral density N0 = k · t … C/N0 = EIRP/(Lb) · (gr/t) · (1/k)" (slide 33). In dB
    this is exactly the code's C/N0 = EIRP + G/T − L − 10log10(k), and the same deck attributes the
    underlying law: "Friis formula was first published in 1946: H. T. Friis, 'A note on a simple
    transmission formula,' Proc. IRE 34, 254–256 (1946)".
  - Friis, H. T. (1946). A note on a simple transmission formula. *Proceedings of the IRE, 34*(5),
    254–256. [EXTERNAL]
- **Critical analysis**: `10*log10(1.380649e-23) = −228.599` dBW/(K·Hz), the exact CODATA-2018
  Boltzmann constant, so the −228.6 dB "k" term is implicit and exact rather than the usual rounded
  constant — good practice. The antenna model (`antenna_`, lines 236-254) uses the circular-aperture
  gain G = η(πD/λ)² and the 70λ/D beamwidth rule, both standard (e.g., any antenna text; the 70°
  coefficient is an approximation and is labelled as such in the code). The `ISLLinkBudget` anchored
  design is scientifically careful: σ is defined *relative to a trusted anchor* (σ = σ₀ at the
  reference distance, `ISLLinkBudget.m:15-18`), so the link budget perturbs rather than replaces a
  validated number, and the default `model='fixed'` keeps golden runs byte-identical. The
  fixed-aperture/fixed-gain dichotomy (`ISLLinkBudget.m:20-28`) is physically right: a fixed
  aperture has G ∝ f², which cancels the f² path loss exactly, so claiming Ka is "automatically"
  noisier than L-band would indeed be wrong. One caveat: `ISLLinkBudget.sigma()` (line 32-44)
  applies only the distance ratio; the fixedGain frequency term lives solely in
  `sigmaAtFrequency()` (line 57-65), so a caller that changes frequency but calls `sigma()` gets a
  frequency-independent answer even in fixedGain mode. `describe()` advertises
  `frequencyDependent=true` for that mode, which slightly overstates what the default path does.

### 2. Ranging noise from C/N0 (code-tracking σ)

- **Code**: `+revgnss/InterSatelliteRFLinkModel.m:170-171` —
  `sigma = trackingCoefficient * c / (2 * rangingBandwidth * sqrt(cn0_Hz * integrationTime))`, with
  `rangingBandwidth` either a declared effective bandwidth or the chip rate (lines 267-284), and
  self-declared at lines 209-214: "Tracking sigma = coefficient*c/(2*B_ranging*sqrt((C/N0)*T)); the
  coefficient declares waveform and discriminator effects."
- **Verdict**: ✅⚠️ The formula is the standard thermal delay-tracking jitter family, algebraically
  identical to the coherent early-late DLL expression for spacing d = 1 chip and B_L = 1/(2T); the
  σ ∝ 1/√(C/N0) scaling that `ISLLinkBudget` inherits (σ = σ₀·10^(−ΔC/N0/20), `ISLLinkBudget.m:43`)
  follows directly. ⚠️ because the discriminator/waveform physics is compressed into one declared
  coefficient rather than derived, and no in-repo citation names the DLL source.
- **Sources**:
  - Standard coherent DLL thermal jitter σ_DLL = T_c·√(d·B_L/(2·C/N0)) (metres: ×c). Substituting
    B_L = 1/(2T), d = 1: σ = c·T_c/(2√(C/N0·T)) = c/(2·f_chip·√(C/N0·T)) — exactly the code with
    coefficient 1 and B_ranging = chip rate. Kaplan, E. D., & Hegarty, C. J. (2017).
    *Understanding GPS/GNSS: Principles and applications* (3rd ed.). Artech House. [EXTERNAL];
    Betz, J. W., & Kolodziejski, K. R. (2009). Generalized theory of code tracking with an
    early-late discriminator, Part I. *IEEE Transactions on Aerospace and Electronic Systems,
    45*(4), 1538–1556. [EXTERNAL]
  - The C/N0-threshold link-budget methodology the repo mirrors is the one in the acquisition
    paper: "This section computes the C/N0 acquisition link budget margins for the different
    signals to be acquired. The link budget margin is defined in (30)" (Article seuils acquisition,
    p. 24 of PDF), with the effective-noise construction N0,eff of Eqs. (28)–(29) — the same
    "declared total budget vs thermal-only" distinction the repo enforces.
- **Critical analysis**: The PLL formula σ_PLL = λ/(2π)·√(B_L/(C/N0)) does not appear anywhere in
  the ISL chain, correctly so: the ISL carrier observable is handled with a declared total σ
  (`measurements.isl.carrier.sigma_m`, default 2 mm) plus a float ambiguity state, never a derived
  thermal number. The repo's own rule — "sigma_m is the TOTAL error budget, not thermal noise
  alone" (`+revgnss/ISLMeasurementBuilder.m:126-131`) — is scientifically the right posture, and
  `TwoWayISLMeasurementBuilder.m:549-561` applies it with teeth: a thermal-only physicalRF σ
  ("1.9e-05 m with a 99.9 dB margin" at 1 km/26 GHz — arithmetic checks out) is named a "floorless
  claim" and a `nonThermalSigma_m` floor is provided. The two-way composite
  `0.5*sqrt(σf² + σr² + 2ρσfσr)` (`InterSatelliteRFLinkModel.m:73-75`) is the exact variance of the
  half-round-trip observable (ρf+ρr)/2 with correlation ρ — correct. The first-order plasma group
  delay 40.3·TEC/f² m (line 178) is the standard dispersive term (coefficient 40.308; e.g.,
  Hofmann-Wellenhof et al., *GNSS — Global Navigation Satellite Systems*, §5.3 [EXTERNAL]). What is
  *missing* from the thermal model — multipath, dynamic stress, oscillator jitter — is declared
  missing (lines 209-214, 76-82), which is the honest form of the omission.

### 3. Beamforming phasor sum, Ruze envelope, near-field focus

- **Code**: `+revgnss/BeamformingPhasorDiagnostics.m:12-17` (contract), 481-488 (implementation):
  `psi = -2*pi*pathError_m/lambda; psi = psi - mean(psi); AF = abs(mean(exp(1i*psi)));
  lossDb = 20*log10(AF); ruzeDb = -4.342944819*rms(psi)^2; fresnel_m = 2*D^2/lambda;
  nearField = fresnel > slantRange`. Per-epoch series: lines 206-268 with
  `e_i = (|p − r̂_i| − |p − r_i|) + (b̂_i − b_i)`, mean removed (152-154, 215-224). Focused-beam
  pattern: lines 765-783 use spherical-wave weights `exp(−i·k·range)` per element, not a plane-wave
  steering vector. Report text: `+revgnss/+report/beamformingPhasor.m:23-31, 101-105`.
- **Verdict**: ✅ The array factor, the phase mapping, the Ruze envelope, the incoherent floor, and
  the near-field criterion are all correct; the geometry+clock error currency (metres of path) is
  the right one, and the mean-removal (common phase is free) is exactly right.
- **Sources**:
  - Ruze, J. (1966). Antenna tolerance theory — A review. *Proceedings of the IEEE, 54*(4),
    633–640. [EXTERNAL] Ruze's G/G₀ = e^(−δ̄²) with δ̄ the RMS phase error is precisely the code's
    `ruzeDb = −4.3429·σ_ψ²` (10·log10 e = 4.34294...); the code's insistence that this is only the
    small-error *envelope* of the exact phasor sum, invalid past σ_ψ ≈ 1 rad
    (`BeamformingPhasorDiagnostics.m:15-17`, `beamformingPhasor.m:101-105`), matches Ruze's own
    derivation domain. Note Ruze's *reflector* form carries (4πε/λ)² — the factor 2 for reflection;
    the code correctly uses the one-way 2πe/λ since the path error here is traversed once.
  - Merlo, J. M., Mghabghab, S. R., & Nanzer, J. A. (2023). Wireless picosecond time
    synchronization for distributed antenna arrays. *IEEE Transactions on Microwave Theory and
    Techniques, 71*(4), 1720–1731. — "Achieving good performance in distributed antenna systems
    requires stringent synchronization at the wavelength and information levels to ensure that the
    transmitted signals arrive coherently at the target" (p. 1720). This is the literature basis
    for treating position error and clock error as one currency of path metres: the code adds
    `(b̂_i − b_i)` directly to the geometric path error (`computeSeries`, line 222), which is what
    two-way-time-transfer-based array coherence work does.
  - Fraunhofer distance 2D²/λ: standard antenna theory (e.g., Balanis, *Antenna Theory*, 4th ed.,
    §2.2.4). [EXTERNAL]
- **Critical analysis**: The near-field claim is *physically verified*: for the run22 formation
  (D ≈ 5.6 km) at S-band (λ = 0.143 m), 2D²/λ ≈ 4.4×10⁸ m, five orders of magnitude beyond the
  35 786 km GEO slant range — the ground target is deep inside the radiating near field and a
  plane-wave array factor would be the wrong model. The code uses exact per-element ranges
  throughout ("focused, not steered", lines 156-159, 765-783), which is correct in *both* regimes,
  so nothing depends on the classification flag. Two further points of quality: the beam-move vs
  beam-dim decomposition (lines 237-252) — fitting the best tangent-plane wavefront tilt and
  reporting only the residual as gain loss — is the correct separation of pointing error (which is
  calibratable) from decoherence (which is not); and the "honesty gate"
  (`coherenceClaimStatus`, line 32-35 and report lines 114-126) refuses to present a loss figure as
  a capability when no physical range row constrained the relative DOF, which directly addresses
  the classic self-simulation trap. One conceptual subtlety is handled explicitly and correctly:
  the exact phasor sum of one realisation can fall below the 1/N incoherent floor (specific phases
  can cancel), whereas the *expected* gain cannot — the two classes are kept separate (see §5).

### 4. Expected coherent gain from an orientation σ (OrientationCoherenceBudget)

- **Code**: `+revgnss/OrientationCoherenceBudget.m:100-127` — lever `sqrt(2/3)*Rrms`;
  `sigPhi = 2*pi*rim/lambda`; `gainLoss_dB = 10*log10((1+(n−1)*exp(−sigPhi²))/n)`;
  `mispointBeamwidths = 2*rim/lambda`; `coherentUpTo_Hz = c/(20*rim)`.
- **Verdict**: ✅ Exact expected array gain for i.i.d. Gaussian phase errors, with the correct
  incoherent floor; the √(2/3) rotation lever and the array-size cancellation argument both check
  out analytically.
- **Sources**:
  - Mudumbai, R., Brown, D. R., Madhow, U., & Poor, H. V. (2009). Distributed transmit
    beamforming: Challenges and recent progress. *IEEE Communications Magazine, 47*(2), 102–110.
    [EXTERNAL] The expected received power of an N-element array with i.i.d. phase errors,
    E|Σe^{jφ}|² = N + N(N−1)e^{−σ²}, giving normalized gain (1+(N−1)e^{−σ²})/N with floor 1/N, is
    the standard distributed-beamforming result this line implements.
- **Critical analysis**: Derivation check: E[(1/N)|Σe^{jφᵢ}|²] = (1/N²)(N + N(N−1)e^{−σ²}) for
  zero-mean Gaussian φᵢ with variance σ² — the code's formula is exact, and its floor
  −10log10(N) is the true incoherent limit, unlike the bare Ruze e^{−σ²}, whose misuse the code
  explicitly declines (lines 104-110). The G2 lever: E|n̂×q|² = (2/3)|q|² over an isotropic axis,
  so RMS rim displacement = θ·R_rms·√(2/3) — correct, and the observation that quoting the bare
  radius overstates by 22 % (1/√(2/3) = 1.225) is right. The G5 cancellation: mispointing angle
  ≈ rim/R, beamwidth ≈ λ/(2R), ratio = 2·rim/λ, independent of R — verified; the conclusion
  ("enlarging the array does not help") is correct *for orientation-induced* rim error of fixed
  absolute size, and the docs state the scope correctly. The deliberate separation from
  `BeamformingPhasorDiagnostics` (realised phasor sum of one realisation vs expected gain from a
  sigma; header lines 29-36) is a distinction most published mission studies fail to make.

### 5. Swarm shape solver — "classical MDS" vs what is actually implemented

- **Code**: `+revgnss/SwarmRelativeSolver.m:732-808` (`solveEpoch_`): per-epoch Gauss-Newton
  weighted least squares on residuals `zK(p) − |r_i − r_k|` with rows `H(p,ci)=+u'`, `H(p,ck)=−u'`,
  solved by a truncated SVD pseudo-inverse of the normal matrix (`truncPinv_`, lines 810-822) that
  zeroes the 6-D rigid null space (min-norm inner gauge) and any weakly observable shape DOF.
  Kabsch/orthogonal-Procrustes alignment appears only in the truth-side metric
  (`alignToTruth_`, lines 842-852: SVD of the cross-covariance, det-sign correction, no scale).
  Rigidity counting: `out.topology.shapeDof = 3N−6` and `rigidityMargin = nLinks − (3N−6)`
  (lines 100-103).
- **Verdict**: ⚠️ Scientifically sound as implemented — but it is **not classical MDS**. There is
  no Gram matrix, no double centering B = −½·J·D²·J, and no eigendecomposition-to-coordinates
  anywhere in the shipped file (repo-wide grep for cmdscale/Torgerson/double-centering finds only
  unrelated hits). The project memory's description of this solver as "classical MDS" is a
  provenance error that should not propagate into the paper.
- **Sources**:
  - Torgerson, W. S. (1952). Multidimensional scaling: I. Theory and method. *Psychometrika,
    17*(4), 401–419. [EXTERNAL] — the double-centered-Gram construction the code does *not* use.
  - Schönemann, P. H. (1966). A generalized solution of the orthogonal Procrustes problem.
    *Psychometrika, 31*(1), 1–10. [EXTERNAL]; Kabsch, W. (1976). A solution for the best rotation
    to relate two sets of vectors. *Acta Crystallographica A, 32*(5), 922–923. [EXTERNAL] — the
    SVD alignment in `alignToTruth_` is the Kabsch/Schönemann solution verbatim (including the
    determinant-sign guard against reflections).
  - For the iterative-WLS/anchor-free-localization framing that *does* match the code: Mao, G.,
    Fidan, B., & Anderson, B. D. O. (2007). Wireless sensor network localization techniques.
    *Computer Networks, 51*(10), 2529–2553. [EXTERNAL]
- **Critical analysis**: What is implemented is a free-network trilateration adjustment — the
  geodesy "inner-constraint / free-network adjustment" solution (minimum-norm datum via truncated
  pseudo-inverse), which is *equivalent in what it can observe* to MDS-then-Procrustes but
  statistically superior for noisy, incomplete graphs (MDS needs a complete distance matrix or
  completion; the ≤5-neighbour cone/nearest graph here is deliberately incomplete). So the
  implementation choice is defensible and arguably better than what the memory claims; only the
  *label* is wrong. Details verified: the rigidity margin bookkeeping (edges vs 3N−6) states the
  necessary condition without claiming sufficiency — correct, since edge count alone does not imply
  generic rigidity (that requires the Laman/Maxwell condition plus genericity; see §6 source). The
  truncated pinv (RANK_TOL=1e-6) is the right guard against the measured planar-helix degeneracy
  (untruncated pinv blew N=3 up to 32 m, `docs/federated_swarm_architecture.md:89`). The
  `radialStiff` gauge prior (lines 738-753) is physically argued (ground link pins radial;
  crosslinks are transverse chords) and deliberately *not* the filter's own covariance because that
  covariance is measured 25× optimistic — an unusually honest weighting decision. Caveats that
  belong in the paper: the range observable is synthesised from truth trajectories plus modelled
  bias/thermal (lines 127-137, 1005-1024) unless the four-timestamp replay validates
  (lines 1026-1159 — which at least self-checks sign and geometry to 0.10 m RMS before being
  believed), and the per-link delay-bias self-calibration (lines 183-229) correctly leaves the
  common bias component in (it is a pure scale change, indistinguishable from real scale — the
  code says so and scores only the differential part).

### 6. The rotation wall: ranges are blind to rigid rotation (observability core)

- **Code**: `+revgnss/SwarmRelativeSolver.m:14-18` ("two-way ISL observes |r_i − r_k| only …
  formation SHAPE is observable; the absolute translation + rotation of the whole formation are
  NOT"); `+revgnss/GroundDifferencedRotationSolver.m:4-10` ("the range Jacobian along a rotation
  direction is 1.0e-16, i.e. machine zero"); `docs/ground_referenced_orientation_summary.md:36-41`.
- **Verdict**: ✅ Exactly correct, and provable in one line from the code's own H rows: for a rigid
  rotation δp_i = θ×p_i, the range row gives u'(θ×(p_i−p_k)) = θ·((p_i−p_k)×u), and u is by
  construction parallel to (p_i−p_k), so the sensitivity is identically zero — the measured 1e-16
  is arithmetic noise around an analytic zero. The DOF count (15 pairwise ranges at N=6 vs
  15 relative DOF minus 6 gauge = shape only) is consistent.
- **Sources**:
  - Eren, T., Goldenberg, D. K., Whiteley, W., Yang, Y. R., Morse, A. S., Anderson, B. D. O., &
    Belhumeur, P. N. (2004). Rigidity, computation, and randomization in network localization.
    *Proceedings of IEEE INFOCOM 2004*, 2673–2684. [EXTERNAL] — distance measurements determine a
    network only up to congruence (rotation, translation, reflection); anchors are required to fix
    the remaining gauge, which is precisely the repo's "only an Earth-referenced observable can set
    orientation".
  - Julier & rigidity aside, the aerospace-side statement: in relative navigation, inter-satellite
    range-only measurement leaves the formation attitude unobservable without external direction
    references — consistent with the standard treatment of range-only relative navigation
    observability. [EXTERNAL, textbook-level]
- **Critical analysis**: This claim is the scientific core of the repo's architecture (it motivates
  the federated pivot, the ground-DD rotation route, and the joint solver), and it is airtight.
  One caution for the paper: reflection. Distance data is blind to reflections as well as
  rotations/translations (congruence includes the improper part); the code's rigid null space in
  `truncPinv_` is the 6-D *continuous* null space and cannot flip chirality mid-solve because it
  starts from the EKF estimate, but a statement of the claim in the paper should say "rigid
  motions (and reflection)" for mathematical completeness. The 1e-16 Jacobian measurement quoted
  in the docs is presented as an empirical fact; it is better than that — it is analytic — and
  stating so strengthens the argument.

### 7. JointGeometrySolver — arc-constant 3N+3 shape+rotation least squares

- **Code**: `+revgnss/JointGeometrySolver.m` — parameters [α; θ′] with dp = B·α over an orthonormal
  basis of the 3N−6 shape subspace (`shapeBasis_`, lines 641-652: null space of [rotation
  generators, translations]ᵀ) and θ′ = L_rot·θ in metres of rim (L_rot = √(2/3)·R_rms,
  lines 190-195); rotation generator per epoch G_k = −skew(q_i)/L_rot (lines 487-491); real DD
  covariance whitening R_DD = D·R·Dᵀ via cached Cholesky (`ddWhitener_`, lines 711-739); ISL prior
  as information on α only, truth forbidden (`shapePrior_`, lines 582-613); Schur-complement
  rotation covariance and absolute SNR acceptance (lines 276-296, 315-330); coupled acceptance
  invariant — rotation never applied without an accepted shape, and a rotation-rejected case
  triggers a θ=0-constrained re-solve (lines 86-111, 334-401); measured-not-asserted separation
  penalties, with and without the prior (lines 784-826); shape-frame question made testable via
  `shapeFrame='formationBody'` and `ShapeFrameSeparationProbe` (lines 34-46).
- **Verdict**: ✅ Internally consistent least squares: the Jacobians check out (DD row structure at
  `buildEpochRows_` lines 689-709 matches the differencing scheme; the rotation generator is the
  correct −skew(q)/L linearisation), the unit equilibration is the right cure for mixing radians
  with metres in one rank tolerance, and the weighting (B2 fix: weighted SSE for the variance
  factor, lines 521-526) is now dimensionally correct. The identifiability reasoning is honest to
  an unusual degree.
- **Sources**:
  - No direct literature analogue implements this exact 3N+3 arc-constant parameterisation; the
    nearest families are free-network/S-transformation adjustment in geodesy (datum-free networks
    with minimal constraints; e.g., Blaha, G. (1971). *Inner adjustment constraints with emphasis
    on range observations*, OSU Report 148 [EXTERNAL]) and anchored graph localization (§6 source).
    The Schur-complement treatment of nuisance blocks is standard estimation theory (e.g., Bierman,
    G. J. (1977). *Factorization methods for discrete sequential estimation*. Academic Press.
    [EXTERNAL]).
- **Critical analysis**: The physically load-bearing claim is the **turn-angle law**: an
  arc-constant ECEF shape offset and an arc-constant rotation are separated only because the
  rotation generator turns with the formation while the ECEF shape vector does not; hence
  separation improves with total formation turn (14.5× penalty at 7.5° of turn → 1.0× at 360°,
  `docs/ground_referenced_orientation_summary.md:158-177`, reproduced on a real 6 h run at 2.22×
  vs 2.1× predicted). This is physically sensible — it is the same mechanism by which any two
  parameters with different time signatures decorrelate — but the code itself documents the
  Achilles heel (lines 34-46): a *physical* deformation is constant in the body frame, i.e. it
  turns *with* the formation exactly as the rotation generator does, in which case the separation
  would be a parameterisation artefact. The repo's answer, `ShapeFrameSeparationProbe.m` (A4:
  inject known rotation+shape in {ECEF, body} × solve in {ECEF, body}, off-diagonal cells are the
  test), is the correct falsification experiment, and its design note that the experiment is
  vacuous on the code observable (1 of 12 shape DOF constrained) and needs the fixed wide-lane
  carrier (9-12 of 12) is a genuinely important methodological point. Also verified: the C2
  observability diagnosis — gain_j = √(1 + e_j/p_j) per eigen-direction of the rotation-free Schur
  complement of the shape block — is a proper "what did the data add over the prior" measure, and
  the dual separation penalties (prior-in-force vs shape-free, lines 784-826) prevent exactly the
  confusion that produced the earlier 1.53× headline. The acceptance coupling (a rotation is never
  the partner of a rejected shape step; measured counterexample: 8.66° rotation at SNR 40.8
  alongside a 31 m rejected shape step moved the geometry 171 m) is estimation-theoretically
  correct — correlated blocks of one joint estimate cannot be applied piecewise. Remaining honest
  weaknesses, all declared: the observable is re-synthesised from recorded truth
  (`GroundDifferencedRotationSolver.buildObservable`, see §8); the prior renormalises the ISL
  layer's formal covariance, which this project has measured to be optimistic elsewhere; and
  `minTurnAngle_deg` (default 30°) gates `separable` as a report flag, not as a hard refusal.

### 8. GroundDifferencedRotationSolver — DD → rotation; shape-leakage guard

- **Code**: `+revgnss/GroundDifferencedRotationSolver.m` — DD observable
  DD_ij,ml = (ρ_i,m − ρ_1,m) − (ρ_i,ref − ρ_1,ref) (lines 331-345); rotation Jacobian
  d(ρ)/dθ = (q×u)ᵀ implemented as `cross(Pe_i−cP, uP)` differences (lines 339-341) — the
  small-rotation linearisation δρ = (θ×b)·e, verified correct; what DD removes: tower clock, tower
  survey error, per-satellite differential clock (68 439 nuisance parameters at G5S20R4), receiver
  group delay (lines 14-27, 66-69 of the summary doc); shape-leakage guard: leakage operator
  inv(N_θθ)·N_θp restricted to the shape subspace, *measured per run* (E3, lines 386-395), refusal
  when predicted leakage exceeds measurable rotation (lines 439-472); significance (SNR ≥ 3) guard
  (lines 474-496); lever-arm symmetry (B1): observable at the truth antenna phase centre,
  prediction at the *estimated-attitude* phase centre, or lever removed from both sides — never
  mixed (lines 147-177, 573-681, including the MEKF error-state trap at lines 616-680).
- **Verdict**: ✅ The observable, the linearisation, and the differencing algebra are correct, and
  the two guards (leakage, SNR) plus the `GuardDecision` dead-band close real, *measured* failure
  modes. ⚠️ The observable is re-synthesised from recorded truth — a declared architectural
  necessity (no stored pseudoranges survive a federated run, lines 32-40), but it means the
  rotation results are simulation-internal demonstrations, not end-to-end measurement processing.
- **Sources**:
  - GNSS attitude determination via DD carrier transfers directly: Naqvi, N. A., et al. (2013).
    *Design and simulation of GNSS phase based attitude determination of spacecraft: LAMBDA*
    (AIAA 2013-4832). — "Base line is calculated by applying the Least Square Solution after
    resolving the ambiguity and performing the method of differential positioning using double
    difference measurements to find the slave antenna positions" (p. 1).
  - Abbas, N. A., et al. *Design and mathematical modeling of GNSS based attitude determination of
    ICUBE-1* (AIAA). — "The receiver clock bias is common to the single difference for all
    satellites at each epoch. This term can be eliminated by taking the difference between two
    single difference equations, which is referred to as the double difference" (p. 7).
  - The roles are exactly transposed: in GNSS attitude, multiple antennas on one rigid body +
    multiple satellites; here, multiple satellites (a rigid-ish formation) + multiple ground
    towers. The differencing algebra and the (θ×b)·e sensitivity are identical, which makes this a
    legitimate literature anchor for the method.
- **Critical analysis**: The DD-vs-SD trade is quantified rather than assumed (DD ~15 % worse than
  a perfect-clock SD, better than a code-bias-estimating SD; header lines 28-30) — the right
  analysis. The shape-leakage story is the scientifically strongest part: a 3-parameter rotation
  solve with no shape freedom converts arc-correlated deformation into spurious rotation at a
  *measured* ~0.30°/m while its formal σ is blind to it (0.0115° in every row of the injection
  ladder, lines 365-381) — a textbook example of why formal covariance under model
  mis-specification is meaningless, and the reason the class is retained only as the measuring
  instrument for the coefficient while `JointGeometrySolver` is the estimator. The atmosphere
  caveat block (lines 42-58) is exemplary: it computes that two satellites 2 km apart at GEO view
  one tower through ray paths diverging 11 arcsec (differencing to 0.006–1.6 mm, far below code
  noise), identifies the per-asset independent atmosphere in the simulator as a modelling artefact
  three orders of magnitude larger, and gates the physically-correct shared-atmosphere fix rather
  than silently choosing either. The remaining exposure, stated in the docs
  (`ground_referenced_orientation_summary.md:228-231`): shipped scenarios have zero EKF attitude
  error, so the estimated-attitude lever-arm mode is currently exercised only in its trivially
  exact regime, and the tower-motion/Sagnac term is inert only while observable and prediction
  share one range helper.

### 9. Split covariance intersection (SplitCovarianceIntersectionBound + network)

- **Code**: `+revgnss/SplitCovarianceIntersectionBound.m:14-48` — bound
  B(K,ω) = (1/ω₁)(I−KH_i)P_i(I−KH_i)ᵀ + (1/ω₂)K(H_jP_jH_jᵀ)Kᵀ + Σ_g(1/ω_g)KW_gKᵀ +
  Σ_k(1/ω_k)KU_kKᵀ + KR_indKᵀ, with R_ind = R_tot − ΣW_g − ΣU_k built only by subtraction and
  required PD (lines 401-418); validity claimed for *every* K and every ω in the open simplex, via
  the n-term Young/Jensen inequality (lines 25-48, `describeDerivation` lines 365-392); ω
  optimised by exact bounded-simplex water-filling ω_l = max(lb, √(a_l/λ)) + coordinate descent
  (`waterFillWeights`, lines 272-302; `selectGainAndWeights`, lines 191-270); observables admitted
  only from a proven allowlist (lines 78-116); numerical Loewner-domination checker (lines
  328-345). `DistributedCovarianceNetwork.m` maintains *exact* pairwise cross-covariance blocks
  (`PairwiseCrossCovarianceBlock.m`: one canonical unordered pair, P_ji = P_ijᵀ structural, never
  symmetrized) and applies the conservative bound only on the owner-only path, explicitly
  refusing a fleet-level conservativeness claim for mixed assemblies (lines 25-27, 785-827).
- **Verdict**: ✅ This is a correct split covariance intersection: the independent-noise term
  carries coefficient 1 (the "split"), every unknown-correlation term carries 1/ω_l, and the
  Young/Jensen route is a valid proof device for arbitrary jointly-PSD cross moments. ω *is*
  optimised (trace-minimising), and — correctly — the bound's validity is decoupled from the
  optimiser's convergence.
- **Sources**:
  - Julier, S. J., & Uhlmann, J. K. (1997). A non-divergent estimation algorithm in the presence
    of unknown correlations. *Proceedings of the American Control Conference*, 2369–2373.
    [EXTERNAL] — classical CI, P⁻¹ = ωP₁⁻¹ + (1−ω)P₂⁻¹; consistency (no double counting) for any
    unknown correlation is the theorem the repo's bound generalises.
  - Julier, S. J., & Uhlmann, J. K. (2001). General decentralized data fusion with covariance
    intersection. In D. Hall & J. Llinas (Eds.), *Handbook of multisensor data fusion*. CRC Press.
    [EXTERNAL] — split CI: known-independent components excluded from the ω-inflation, exactly the
    code's coefficient-1 KR_indKᵀ term.
  - Li, H., Nashashibi, F., & Yang, M. (2013). Split covariance intersection filter: Theory and
    its application to vehicle localization. *IEEE Transactions on Intelligent Transportation
    Systems, 14*(4), 1860–1871. [EXTERNAL] — the split form and its consistency proof.
- **Critical analysis**: Three design choices deserve credit. (i) The additive-folding shortcut
  (summing H_jP_jH_jᵀ and correlated common sources into one term with coefficient 1) is made
  *structurally inexpressible* — the module refuses pre-summed blocks and the tests carry the
  numerical counterexample (under-reports by up to a factor n, lines 33-40) — this is the exact
  failure mode of naive federated fusion. (ii) The `assumeIndependent` posterior exists but is a
  differently-named, attestation-gated method (lines 147-180), so the test-only path cannot be
  selected by a config typo. (iii) The per-observable allowlist (five entries, each backed by its
  own Jacobian/independence reference tests, lines 78-116) turns "the bound applies" from an
  assumption into a per-observable proof obligation. The one honest gap is documented in-file:
  after any conservative conditioning, the network's cross blocks are conditioned on a *bounded*
  remote marginal, and no fleet-level joint-covariance conservativeness claim is made
  (`DistributedCovarianceNetwork.m:25-27`) — this is the correct epistemic position (a collection
  of pairwise-conservative marginals does not imply a conservative joint), and stating it
  distinguishes this implementation from most published federated filters, which silently claim
  it. Note also the classical-CI *form* (P⁻¹ convex combination) never appears verbatim; the code
  implements CI in the measurement-update (gain) form. The two are equivalent families, but a
  reader looking for the textbook formula will not find it — worth one sentence in the paper.

### 10. ISL timing: product-interval clock error charged as white R (audit item)

- **Code**: `+revgnss/ISLMeasurementBuilder.m:216-217` — legacy branch:
  `Rii = codeSigma² + sigmaPos² + product.sigmaClock²` added per epoch as white noise, while
  `productBias_`/`productInterval_` (lines 587-612) hold the drawn product error
  *piecewise-constant over `updateInterval_s` (default 300 s)*. The in-code justification
  (lines 588-592): "its error is piecewise-constant (correlated within an interval, independent
  across intervals) -> it averages down over the run and the white-R model stays consistent."
- **Verdict**: ❌ Confirmed defect (matches the standing audit). A constant-within-interval error
  declared as per-epoch white noise lets the filter believe it averages as 1/√n_epochs when it
  actually averages as 1/√n_intervals: at dt = 1 s and a 300 s interval the filter's implied
  information about that error component is up to ×300 too large (σ overconfident by up to √300 ≈
  17 within an interval; over a 3600 s arc, 12 independent draws vs 3600 assumed). The comment's
  "stays consistent" claim is only true asymptotically across many intervals, not for the
  covariance the filter reports at any epoch.
- **Sources**: This is the standard time-correlated-measurement-error result; e.g., Brown, R. G.,
  & Hwang, P. Y. C. (2012). *Introduction to random signals and applied Kalman filtering*
  (4th ed.). Wiley. [EXTERNAL] (colored measurement noise must be state-augmented or R inflated by
  the effective correlation length).
- **Critical analysis**: The repo demonstrably knows the rule and enforces it everywhere else:
  `TwoWayISLMeasurementBuilder.m:242-278` hard-errors on "a recurring calibration error … repeated
  as white R" unless a persistent bias state exists or the declared σ covers the bias;
  `SwarmRelativeSolver.islNoise_` (lines 883-918) and `clockNoise_` (lines 1180-1202) inflate R by
  nCorr = min(τ/dt, cap) precisely so "the sequential white-R weight cannot average the bias below
  ~√nCorr". The one-way product path is the single surviving violation, and the fix is mechanical
  (either the nCorr inflation with τ = updateInterval_s, or a per-interval bias state). The
  consequence is bounded in practice — the product is disabled by default (σ = 0, line 575-583)
  and hard-forbidden in 'position' estimate mode (lines 40-47) — but any 'clocks'-mode run with a
  non-zero product budget carries an optimistic R and therefore an optimistic primary covariance.
- Also verified in this area: the one-way light-time/Sagnac correction
  (`geometry_`, lines 505-534) — ρ + (u·v_tx_inertial)(ρ/c) with v_inertial = v_ecef + ω×r — is
  the correct first-order retarded-time term, its equivalence to the standard first-order Sagnac
  is stated and was cross-validated sub-mm against Orekit; the two-way reciprocity cancellation of
  the Sagnac term in `twoWayLightTime_` (`SwarmRelativeSolver.m:854-881`) is likewise correct and
  the surviving (u·Δv)(ρ/c) term is honestly reported as micrometres, i.e. inert at these
  baselines. `OneWayRangeRateModel.m:39-67` — ρ̇ = u'v_rx + ω_e(u_yΔx − u_xΔy) — is algebraically
  identical to the ECI form u'(v_rx,eci − v_tx,eci); verified by expansion.

### 11. Helix formation from Clohessy-Wiltshire dynamics

- **Code**: `+revgnss/SwarmFormation.m:17-19, 84-99` — bounded projected-circular member:
  x = (ρ/2)sin(nt+φ), y = ρcos(nt+φ), z = crossAmp·ρ·sin(nt+φ), with the no-drift condition
  ẏ(0) = −2n·x(0) asserted; Hill frame R = r/|r|, W = (r×v)/|r×v|, S = W×R (lines 13-15,
  184-189); rotating→inertial velocity via +ω×dr (lines 147-148, 198-199); multiRingHelix layout
  holds inter-satellite *spacing* fixed instead of ring radius (lines 37-82).
- **Verdict**: ✅ Dimension- and algebra-checked: the 2:1 radial/along-track ratio (radial
  amplitude ρ/2 vs along-track ρ) is the classic CW bounded ellipse; the no-drift condition
  verifies (ẏ(0) = −ρn·sinφ = −2n·(ρ/2)sinφ); y²+z² = ρ² gives the projected circle for
  crossAmp = 1; the frame algebra and the ω×r transport term are correct.
- **Sources**:
  - Clohessy, W. H., & Wiltshire, R. S. (1960). Terminal guidance system for satellite rendezvous.
    *Journal of the Aerospace Sciences, 27*(9), 653–658. [EXTERNAL] — the linearised relative
    dynamics whose bounded solutions have exactly the 2:1 in-plane ellipse and independent
    cross-track harmonic the code parameterises.
- **Critical analysis**: Two non-obvious, correct refinements: (i) the planar-degeneracy fix —
  a shared-amplitude projected-circular formation is instantaneously planar (z = 2x), leaving
  out-of-plane shape only second-order observable from ranging; `crossTrackSpread` gives members
  distinct z:x ratios while each remains a valid bounded CW orbit (lines 88-99, and
  `docs/federated_swarm_architecture.md:89` records the measured 8.9 m → 4.6 cm consequence);
  (ii) the ring-layout defect note (lines 40-52) that `baseline_m` was a ring *radius*, so
  nearest-neighbour chords shrank as 2ρ·sin(π/n) with member count — an honest, quantified
  correction (328 m at N = 20, 27× shape dilution) rather than a silent re-tune. The memory note
  "CW forces radial = half along-track" is consistent with the code.

### 12. Guard determinism (GuardDecision) — cross-cutting

- **Code**: `+revgnss/GuardDecision.m` — three-outcome threshold test with a 10 % relative
  dead-band; near-threshold comparisons return 'indeterminate' and take the conservative branch.
- **Verdict**: ✅ Not physics, but scientifically important: it closes a *measured*
  reproducibility defect (a 1e-14 serial-vs-parallel arithmetic difference flipped a binary guard
  and moved 33 of 148 reported fields, solvedPos by 0.55 m, the beam spot by 3.8 km). Reporting
  the margin alongside every pass/fail is the right practice for any threshold that gates a
  published number.
- **Critical analysis**: The dead-band moves the flip risk from "any 3 %-margin case" to "cases
  within 1e-14 of the band edge", which the header states precisely rather than overclaiming
  determinism. The conservative branch on 'indeterminate' is the correct default for guards that
  decide whether a correction is *applied*.

---

## Summary of verdicts

| Feature | Verdict |
|---|---|
| FSPL / C/N0 / Boltzmann chain | ✅ digit-exact vs ITU-R P.525, Friis |
| Code-tracking σ from C/N0 | ✅ standard DLL-family form; ⚠️ coefficient declared, not derived; no in-repo citation |
| Two-way σ composition, plasma delay | ✅ |
| Phasor sum / Ruze / near-field focus | ✅ exact AF; Ruze correctly demoted to envelope; near-field physically verified |
| Expected-gain orientation budget | ✅ matches Mudumbai et al. expected-gain result; √(2/3) lever verified |
| "MDS" shape solver | ⚠️ sound as built, but it is GN free-network WLS + Kabsch metric, **not** classical MDS — fix the label |
| Rotation wall (ranges blind to rotation) | ✅ analytic zero, provable from the code's own H rows |
| JointGeometrySolver 3N+3 | ✅ internally consistent; turn-angle law physically sensible, and its body-frame caveat is honestly probed |
| GroundDifferencedRotationSolver | ✅ algebra correct, guards close measured failures; ⚠️ observable re-synthesised from truth |
| Split covariance intersection | ✅ valid split-CI bound, ω optimised, no-double-count claim correctly scoped |
| Product-interval error as white R | ❌ confirmed overconfident-R defect (one-way legacy path only; rule enforced everywhere else) |
| CW helix formation | ✅ 2:1 ellipse, no-drift condition, frames all verified |

#### References (APA 7)

- Abbas, N. A., et al. (2013). *Design and mathematical modeling of GNSS based attitude
  determination of ICUBE-1: The technology experiment*. AIAA. (Paper/Positioning Technologies.)
- Arias, M., & Aguado, F. (2016). *Small satellite link budget calculation* [Lecture slides].
  Universidade de Vigo. (Paper/Link BUdget/Link_budget_uvigo.pdf.)
- Betz, J. W., & Kolodziejski, K. R. (2009). Generalized theory of code tracking with an
  early-late discriminator, Part I: Lower bound and coherent processing. *IEEE Transactions on
  Aerospace and Electronic Systems, 45*(4), 1538–1556. [EXTERNAL]
- Bierman, G. J. (1977). *Factorization methods for discrete sequential estimation*. Academic
  Press. [EXTERNAL]
- Brown, R. G., & Hwang, P. Y. C. (2012). *Introduction to random signals and applied Kalman
  filtering* (4th ed.). Wiley. [EXTERNAL]
- Clohessy, W. H., & Wiltshire, R. S. (1960). Terminal guidance system for satellite rendezvous.
  *Journal of the Aerospace Sciences, 27*(9), 653–658. [EXTERNAL]
- Eren, T., Goldenberg, D. K., Whiteley, W., Yang, Y. R., Morse, A. S., Anderson, B. D. O., &
  Belhumeur, P. N. (2004). Rigidity, computation, and randomization in network localization.
  *Proceedings of IEEE INFOCOM 2004*, 2673–2684. [EXTERNAL]
- Friis, H. T. (1946). A note on a simple transmission formula. *Proceedings of the IRE, 34*(5),
  254–256. [EXTERNAL]
- International Telecommunication Union. (2024). *Recommendation ITU-R P.525-5: Calculation of
  free-space attenuation*. ITU-R. (Paper/Error Calculation/Atmospheric Errors.)
- Julier, S. J., & Uhlmann, J. K. (1997). A non-divergent estimation algorithm in the presence of
  unknown correlations. *Proceedings of the American Control Conference*, 2369–2373. [EXTERNAL]
- Julier, S. J., & Uhlmann, J. K. (2001). General decentralized data fusion with covariance
  intersection. In D. L. Hall & J. Llinas (Eds.), *Handbook of multisensor data fusion*.
  CRC Press. [EXTERNAL]
- Kabsch, W. (1976). A solution for the best rotation to relate two sets of vectors. *Acta
  Crystallographica Section A, 32*(5), 922–923. [EXTERNAL]
- Kaplan, E. D., & Hegarty, C. J. (Eds.). (2017). *Understanding GPS/GNSS: Principles and
  applications* (3rd ed.). Artech House. [EXTERNAL]
- Li, H., Nashashibi, F., & Yang, M. (2013). Split covariance intersection filter: Theory and its
  application to vehicle localization. *IEEE Transactions on Intelligent Transportation Systems,
  14*(4), 1860–1871. [EXTERNAL]
- Mao, G., Fidan, B., & Anderson, B. D. O. (2007). Wireless sensor network localization
  techniques. *Computer Networks, 51*(10), 2529–2553. [EXTERNAL]
- Merlo, J. M., Mghabghab, S. R., & Nanzer, J. A. (2023). Wireless picosecond time synchronization
  for distributed antenna arrays. *IEEE Transactions on Microwave Theory and Techniques, 71*(4),
  1720–1731. (Paper/Time Synchronisation/04.)
- Mudumbai, R., Brown, D. R., III, Madhow, U., & Poor, H. V. (2009). Distributed transmit
  beamforming: Challenges and recent progress. *IEEE Communications Magazine, 47*(2), 102–110.
  [EXTERNAL]
- Naqvi, N. A., et al. (2013). *Design and simulation of GNSS phase based attitude determination
  of spacecraft: LAMBDA* (AIAA 2013-4832). AIAA. (Paper/Positioning Technologies.)
- Ruze, J. (1966). Antenna tolerance theory — A review. *Proceedings of the IEEE, 54*(4),
  633–640. [EXTERNAL]
- Schönemann, P. H. (1966). A generalized solution of the orthogonal Procrustes problem.
  *Psychometrika, 31*(1), 1–10. [EXTERNAL]
- Torgerson, W. S. (1952). Multidimensional scaling: I. Theory and method. *Psychometrika,
  17*(4), 401–419. [EXTERNAL]
- [Article seuils acquisition version finale]. (n.d.). *GNSS acquisition thresholds and C/N0 link
  budget margins for civil-aviation DFMC receivers*. (Paper/Link BUdget; C/N0,eff and acquisition
  link-budget-margin methodology, Eqs. (27)–(30).)

Not relevant to this domain (checked one page each, per instruction): IAC-23-B2.1.7 (Fazzoletto
et al., topic not ISL/beamforming-adjacent on inspection), CislunarXNAV_v3 (pulsar time transfer),
remotesensing-16-00189 (GNSS carrier multipath review — tangentially supports the coloured
multipath τ = 60 s device in §7/§8 but was not needed as a primary source). The remaining Link
BUdget folder papers (interference/OFDMA/receiver-evaluation) concern RFI margins and receiver
performance under interference; the simulation deliberately has no interference model, so they
verify nothing here and were not force-fitted.

---

# Section: Simulation Architecture, Stochastics & Validation Methodology

All paths relative to repo root `/Users/ludwigmatuschka/Library/CloudStorage/OneDrive-Persönlich/Dokumente/ICH/Karriere/Cranfield/IRP/Codes/IRP_Simulation/oo_v1`.

The simulation is a single-entry-point, truth-then-estimate architecture: `run_oo_v1.m` resolves one canonical configuration (`masterConfig` → optional realism profile → exactly one scenario JSON overlay → validation → `finalizeConfig`), hands it to `revgnss.ReportRunner.runSingle`, which drives `revgnss.ReverseGNSSSimulation`. Each epoch advances the true world first, then runs the estimator against synthesized observables; the truth→estimator boundary is enforced by *loud ordering guards* (`ReverseGNSSSimulation.m:321–325, 407–411` throw if truth and estimation epochs interleave incorrectly) and by an immutable results store (`+data/SimulationDataStore.m:662–666` `freeze()`; every writer checks `frozen_`, e.g. lines 386, 649, 672, 1850). The stated design contract, written directly in the code, is that measurements are "the ONLY channel through which truth enters the estimator" (`ReverseGNSSSimulation.m:481–486`) — with the exceptions inventoried below.

## Epoch loop — order of operations (verifiable against `+revgnss/ReverseGNSSSimulation.m`)

```
run() :280-306  →  for k = 1..N:  step(k) :312-315
│
├─ advanceTruthEpoch(k) :318-329            ── TRUTH STAGE (generateTruth_ :446-477)
│   ├─ orbit truth: precomputed cache r,v(k) :452-455   (cache built once :106-124)
│   ├─ k>1: step tower clocks (dt) :462-465; asset attitude+clock propagate :466-470
│   ├─ log truth state :474; secondary (helix CW) truth from cache :475,1394-1412
│   └─ attitudeSensors.generate(...) :476   (gyro/star-tracker observations drawn
│                                            from TRUTH + bias + noise, truth side)
│
└─ runLocalEstimationEpoch(k) :332-342      ── ESTIMATION STAGE (runEstimation_ :480-985)
    ├─ k>1: ekf.predict(dt, towerClockModels, gyro input) :490-506
    │        gyro = omega_true + bias + ARW  (noisy control input, "architecturally
    │        identical to a real INS", comment :483-486)
    ├─ measModel.computeMeasurements(asset[truth], towers, ekf.getMeasurementState(),
    │        t, stateMap) :510-511      z from truth+ErrorChain; h,H at EKF estimate
    ├─ ground-carrier cycle-slip detect + ambiguity resets :516-558
    ├─ secondary-asset ground rows (joint mode only) + inter-asset R blocks :561-595
    ├─ one-way ISL rows :599-621; ISL slip detect/reset BEFORE update :627-635
    ├─ two-way ISL records → linearize :641-687; ISL time transfer :689-731
    ├─ ground TWSTFT rows :743-760; one-shot attitude init (gated 'none') :771-782
    ├─ clock/tx-delay GAUGE rows appended to EKF stack ONLY (z/h/H/R stay
    │        physical for diagnostics) :787-792
    ├─ if #z ≥ minMeasurementsForUpdate: ekf.update(z_ekf,...) → NIS :801-807
    ├─ post-update: Route-B ISL integer fix, held once per arc :852,1035-1087;
    │        raw-carrier integer fixing :864-887; postfit residuals (h recomputed
    │        at UPDATED state via the same model path) :889-897,1149-1296
    ├─ star-tracker sequential update :904-911; differential-attitude update :916-959
    └─ STAGE row → commitPendingEpochHistory(): simData.recordEpoch + ekf.logStep
             :365-391,972-984
finishRun() :421-443  → simData.freeze() :441  (post/report stages read-only)
```

Order-of-operations audit: (i) the same epoch's truth is used only to *synthesize* `z`; `h`/`H` are linearized at the EKF's predicted state (`getMeasurementState()` — deliberately, so quaternion-error-state mode does not linearize at identity attitude, `:508–511, 736–742`), so there is no linearization-at-truth shortcut. (ii) Slip-driven covariance resets are applied *before* the update that would use the tight carrier R (`:622–635` comment is explicit about why). (iii) The Route-B integer fix is applied once and *held* per arc — the comment (`:1039–1044`) correctly identifies re-application as a covariance-collapsing error class. (iv) Gauge rows never inflate measurement counts or NIS (`:784–792, 829–846`). (v) Star-tracker and diffAtt updates occur after the main NIS is computed; their NIS is tracked separately (`:907–910`). This is a coherent, guard-heavy loop; the ordering hazards a reviewer would look for are actively defended against in code, not just by convention.

---

### Truth/estimate separation & truth-leakage inventory
- **Code**: contract at `ReverseGNSSSimulation.m:446–448, 480–486`; store immutability `+data/SimulationDataStore.m:662–666`; per-item refs below.
- **Verdict**: ⚠️ Architecture is clean and unusually self-documenting, but the **default configuration is truth-assisted in one load-bearing place** (tower clocks), and several truth-rooted shortcuts exist — all gated and documented, none hidden.
- **Sources**: NASA. (2016). *NASA-STD-7009A: Standard for models and simulations.* — validation is "the process of determining the degree to which a model or a simulation is an accurate representation of the real world from the perspective of the intended uses of the model or the simulation" (§3.2, definitions). [EXTERNAL]
- **Critical analysis** — itemized, with gate + default:
  1. **Tower clock 'perfectCorrection' — truth-assisted, ON by default.** `config/masterConfig.m:1739–1740` sets `cfg.estimator.towerClockMode='perfectCorrection'`; `+models/+clocks/TowerClockCorrectionProvider.m` (case `'perfectCorrection'`, ~line 90) sets the model correction equal to the *true* tower clock bias, so tower clock error cancels exactly in z−h. This is the single most consequential truth shortcut: the headline baseline assumes an oracle ground-clock product. Alternatives exist and are honest about themselves: `'noisyCorrection'` carries a code comment "It is NOT a model of what a real receiver produces" (`TowerClockCorrectionProvider.m:44–49`); `'truthHistoryProductNoisy'` models a delayed, quantized broadcast product (deterministic per (tower, product-epoch) noise — closest to reality, still rooted in truth history rather than a network estimate). Any reported accuracy must state which mode was active.
  2. **Gyro control input — honest by construction.** The MEKF prediction consumes ω_true + bias + angular-random-walk drawn on the truth side (`ReverseGNSSSimulation.m:483–486`; observation objects built in `+revgnss/AttitudeSensorSuite.m:60–72,100–120`). This is exactly how a real INS mechanization works; not a leak.
  3. **Attitude initialization guard — exemplary.** `masterConfig.m:1727–1729`: `attitudeInitMode='none'` with the comment "Simulated truth is not an allowed estimator input", and `attitudeInit.knownAttitudeCalibration.allow=false`. The search-based initializer is the only allowed path.
  4. **TruthEndpointReplay (post-processor).** `+revgnss/TruthEndpointReplay.m:1–26` replays recorded truth position/velocity/attitude/clock so `SwarmRelativeSolver` can synthesize the four-timestamp observable with the real physics chain (phase-centre offsets up to ~0.9 m demand true attitude). Using truth to *generate observables* is legitimate; the audited risk is asymmetry — the prior ground-rotation audit found the lever arm present in the observable but absent from the *prediction* model (a 0.18 mm DD systematic aliasing onto rotation). The replay class itself is well-guarded (`isUsable` rejects payloads missing attitude rather than defaulting, `:44–59`).
  5. **Matched truth/model pairs — the "inverse crime by configuration" class.** Default orbit is `stationaryEcef` with `useOrbitPropagator=false` (`masterConfig.m:978–980`); several enabled effects apply identical constants on both truth and model side and cancel exactly in z−h. The repo *knows* this: `+revgnss/ImperfectionAudit.m:1–11` implements predicates ("does an effect leave a real truth≠model residual?") so matched effects are not advertised as active imperfections, and `+revgnss/MonteCarloConsistency.m:52–61,169–186` refuses to certify absolute trustworthiness when realism guards are off, returning `'inconclusiveMatchedCrutch'`. This level of self-awareness about matched crutches is rare and is the correct scientific posture.
  6. **NEES uses truth — diagnostics only.** `+filter/ReverseGNSSEKF.m:838–887` (`computeNEES(truth)`) reads truth exclusively for consistency scoring; nothing feeds back.
  7. **Secondary assets in joint mode** get per-asset seed offsets `seed + 1000*ai` (`ReverseGNSSSimulation.m:153–158`) — additive offsets are a weaker guarantee than identity-keyed substreams (collision-free only by convention), but bounded: they scope only the secondary ground-observation chains.

### Config architecture & the finalizeConfig override (J2 auto-tuner) — verified current state
- **Code**: `run_oo_v1.m:16–19` (single entry; exactly one JSON overlay); `config/resolveSimulationConfig.m:12–49` (order: `masterConfig` → realism profile → scenario overlay wins → `validateMasterConfig` → `revgnss.ConfigFactory.finalizeConfig`; scenario SHA-256 recorded, `:26, 92–102`); auto-tuner at `+revgnss/ConfigFactory.m:1875–1886`.
- **Verdict**: ⚠️ The audited trap is **still present but bounded**: with j2 truth + two-body EKF, `finalizeConfig` force-enables `processNoise.modelMismatch` (`:1880–1882`) and **silently replaces** `sigma_mps2` with `max(1e-8, 0.25·|a_J2|)` whenever the configured value ≤ 1e-6 — which includes the shipped default 1e-6 and any deliberately smaller user value (`:1884–1886`). No warning is emitted at the overwrite.
- **Sources**: Montenbruck, O., & Gill, E. (2000). *Satellite orbits* — "In practical applications the Q-matrix may be determined by simulations in order to find a proper balance between process and measurement noise and ensure an optimum filter performance." (p. 286).
- **Critical analysis**: The tuning itself is defensible (Montenbruck & Gill sanction simulation-tuned Q, and the code comment `:1845–1852` correctly argues j2 truth / two-body EKF is a modelling choice, not an artificial mismatch). The *silence* is the defect: a value the user wrote in `masterConfig` is not the value the EKF runs with, which breaks "config text = run definition" traceability. Mitigations now in place: (a) values > 1e-6 are respected; (b) the canonical name `residualAccelerationUncertainty` is a one-way, read-only mirror written *after* auto-scaling (`:1916–1920`), so reports display the resolved value; (c) the fully resolved cfg is persisted in the run .mat. Also verified: the tuner is **inert on the default path** (default orbit `stationaryEcef` fails the `isJ2Truth` test); it fires on orbit-class scenarios. Residual risk: reproducing a paper number from the masterConfig text alone can fail by the sigma factor; a one-line `warning()` at `:1885` would close it. The opt-in family guard (`:1929–1935`, `enforceModelFamilyConsistency`) hard-blocks silent truth-vs-EKF family mismatch at the single chokepoint every run path traverses.

### RNG architecture — counter-based, identity-keyed streams
- **Code**: `+models/+noise/RngRegistry.m:78–93` — `RandStream(engine,'Seed',masterSeed)` with `s.Substream = idx`, engine default `'threefry'` (MATLAB's Threefry4x64-20); collision-free positional key `idx = src·2^44 + node·2^28 + ant·2^24 + sig·2^20 + (epoch+1)` (`:95–108`); integer source codes in `RngSource.m` (29 sources, truth/model separated, e.g. `ENV_TROP_TRUTH=7` vs `ENV_TROP_MODEL=8`); persistent streams for Gauss-Markov states vs fresh per-epoch streams for white noise (`:55–74`); enable/engine at `masterConfig.m:897–905` (default ON).
- **Verdict**: ✅ A genuine methodological strength — verified to use MATLAB's counter-based `'threefry'` generator with O(1) substream access, and the identity-keying is the textbook-correct application of counter-based PRNG design.
- **Sources**: [EXTERNAL] Salmon, J. K., Moraes, M. A., Dror, R. O., & Shaw, D. E. (2011). *Parallel random numbers: As easy as 1, 2, 3.* SC'11 — "We demonstrate that independent, keyed transformations of counters produce a large alternative class of PRNGs with excellent statistical properties (long period, no discernable structure or correlation)." (p. 1); "All our PRNGs pass rigorous statistical tests (including TestU01's BigCrush) and produce at least 2^64 unique parallel streams of random numbers, each with period 2^128 or more." (p. 1). [EXTERNAL] MathWorks RandStream documentation: Threefry 4x64 ('Threefry4x64_20') is one of the generators supporting multiple independent streams and substreams.
- **Critical analysis**: Identity-keying makes each draw a pure function of *(source, node, antenna, signal, epoch)* rather than of draw order, which (a) prevents the resolved "secondaries share seed 100" bug class — two entities can no longer collide onto one stream because keys, not positional seeds, separate them; (b) gives order-independence: toggling one effect cannot perturb any other source's realization, which is precisely what one-factor-at-a-time and common-random-number comparative studies require (`RngRegistry.m:5–12`; `masterConfig.m:897–904`). The `mt19937ar` fallback (hashed seed, "statistical, not guaranteed, independence", `:84–88`) is honestly labelled. Two residual weaknesses: the substream key has **no asset field**, so per-asset independence rests on per-asset master seeds (additive offsets — see leakage item 7); and `SharedAtmosphereRng.m` fixes the formation-atmosphere artefact by **re-rooting** at a formation-wide seed (default OFF, `masterConfig.m:736`), correctly reasoning that adding an asset field would not work *because* master seeds already separate assets (`SharedAtmosphereRng.m:33–35`). The physics argument in that header (11 arcsec ray divergence ⇒ one air column ⇒ common-mode delay) is quantitative and sound; note the default therefore still draws independent atmospheres per formation member, invalidating between-satellite differenced ground observables unless the gate is on — flagged in the config text itself (`masterConfig.m:715–729`).

### Gauss-Markov discretization
- **Code**: `+models/+noise/StochasticProcess.m:38–41` — `phi = exp(-dt/tau); q = sigma_ss^2*(1-phi^2); xNew = phi*x + sqrt(max(q,0))*randn(stream,...)`; limiting cases documented (`:31–33`); explicit RandStream required, "no bare randn" (`:4`).
- **Verdict**: ✅ Formula verified exactly against Brown & Hwang; the steady-state-variance parameterization is the correct exact discretization of the exponentially correlated process.
- **Sources**: Brown, R. G., & Hwang, P. Y. C. (1997). *Introduction to random signals and applied Kalman filtering* (3rd ed.) — "A stationary Gaussian process X(t) that has an exponential autocorrelation is called a Gauss-Markov process." (p. 94); transition element e^(−βΔt) (Eq. 5.3.9, p. 201); driven-noise variance E[x₂x₂] = σ²(1 − e^(−2βΔt)) (Eq. 5.3.16, p. 202).
- **Critical analysis**: With β = 1/τ, the code's φ = e^(−Δt/τ) matches Eq. (5.3.9) and q = σ²(1−φ²) matches Eq. (5.3.16) exactly — this is the exact discrete solution, not an Euler approximation, so it is valid for any Δt/τ ratio. The stationary variance is preserved identically (Var = φ²σ² + σ²(1−φ²) = σ²). The `tau→0`/`tau→∞` limit comments are correct. `randomWalkStep` (`:57–60`, σ√Δt) is the standard Wiener increment. One nit: the `tau→Inf` comment gives the RW limit as `2σ²dt/τ` which is the *first-order expansion* of q, fine as documentation. Separately, the FFT-synthesis path for power-law clock noise (`+models/+clocks/ClockModel.m` `precomputeNoise`) — flagged in the prior audit as 2/N too quiet — **is fixed in the working tree** (uncommitted diff: `A_frac = sqrt(Sy*fs*N)/2` replacing `sqrt(Sy*fs/N)`, with a derivation comment tying the scaling to MATLAB's 1/N ifft convention); this fix should be committed with a regression note, since flicker-floor amplitude affects every clock-sensitive result.

### Monte-Carlo NEES/NIS consistency machinery
- **Code**: `+revgnss/MonteCarloConsistency.m:25–159` — M-seed ensemble re-running the *real* pipeline; initial error drawn from P0 (`:74–80`); seeds varied via `simulation.seed = baseSeed+j` and `mcSeedOffset = j·1000` (clock truth realizations, `:70–71`); post-burn-in pooling; `initErrorScale>1` documented as a deliberate negative control (`:32–35`). Bounds: `+revgnss/ChiSquareConsistency.m:21–31` two-sided `[chi2inv(α/2,dof), chi2inv(1−α/2,dof)]`, Wilson-Hilferty fallback (`:58–69`, cited to Wilson & Hilferty 1931).
- **Verdict**: ✅ with one strong caveat inherited from the shipped default: the machinery is correct and includes two subtle fixes done *right*, but it is **off by default** — the shipped verdict comes from a single deterministic run (a single χ² sample), which the code itself admits (`:2–5`).
- **Sources**: Bar-Shalom, Y., Li, X. R., & Kirubarajan, T. (2001). *Estimation with applications to tracking and navigation*, §5.4 (cited directly in `ChiSquareConsistency.m:2–4`; average-NEES over M runs ~ χ² with M·n dof, two-sided test — no verbatim quote reproducible from available copies). [EXTERNAL] Chen, Z. et al. (2023). arXiv:2306.07225 — "In practice, NEES/NIS χ2 tests are conducted using multiple offline Monte Carlo 'truth model' simulations to obtain ground truth xk values." (§III-B). Brown & Hwang (1997) — "these methods involve setting up a statistical experiment that matches the physical problem of interest, then repeating the experiment over and over with typical sequences of random numbers, and finally, analyzing the results of the experiment statistically." (p. 210).
- **Critical analysis**: Three details show real statistical care. (1) The header of `ChiSquareConsistency` correctly notes the common "NIS ≈ M" mean-check passes mildly inconsistent filters and implements the proper two-sided interval instead (`:10–13`). (2) The R-7 fix (`MonteCarloConsistency.m:100–105`) documents a previously *wrong* pooling — per-dof NEES pooled against 3·count collapsed to ~0.33 and manufactured a spurious "conservative" verdict — and pools raw block NEES correctly; recording the bug in place is good forensic practice. (3) The centroid gate pools **one time-averaged sample per seed** (3 dof each) precisely because per-epoch centroid samples are time-correlated and would over-count dof (`:41–48`) — this independence discipline is the point most Monte-Carlo NEES implementations get wrong (per-epoch NIS pooling at `:95–97` does assume epoch-independence, which is standard but optimistic for time-correlated innovations; the centroid gate shows the authors know the distinction). The verdict logic refusing certification without realism guards (`'inconclusiveMatchedCrutch'`, `:169–186`) prevents the classic matched-twin false positive. Caveat: `cfg.validation.statistics.monteCarlo.enable=false` and `scientificCampaign.enable=false` by default (`ConfigFactory.m:1830–1842`, `masterConfig.m:460`), and the known NEES≫1 observability wall (radial↔clock) is a *real* finding the ensemble machinery confirms rather than an artifact — the honest interpretation label `'partialCovarianceAwareSynthetic'` (`ScientificValidationCampaign.m:5–7`, `MonteCarloConsistency.m:126`) is carried into results.

### Golden-run regression, test gate & verification-vs-validation framing
- **Code**: `+revgnss/GoldenRunFingerprint.m` (new) — ordered scalar fingerprints frozen in `tests/golden/`; scenario JSON pinned by SHA-256 (`:21–24, 176–186`); numbers stored as `%.17g` strings for exact NaN/Inf round-trip (`:77–83`); rel+abs tolerance compare (`:119–158`); the inert fixture doctrine ("if that fingerprint shifts, a supposedly gated change has leaked into the default path", `:16–19`). Gate: `tests/run_all_tests.m` runs every `tests/test_*.m` with a worktree-shadowing guard (`:7–26` — asserts `which('masterConfig')` resolves outside `.claude/`, after a measured incident where a stale worktree silently shadowed the suite). `revgnss.ValidationRunner` is a separate 2–5-test random smoke selector (seed 29), not the full gate.
- **Verdict**: ✅ Verification machinery is strong and honestly scoped; **validation in the NASA-STD-7009 sense has not been performed and the repo says so** — this must be stated plainly in any paper.
- **Sources**: [EXTERNAL] NASA. (2016). *NASA-STD-7009A* — Verification: "The process of determining that a computational model accurately represents the underlying mathematical model and its solution from the perspective of the intended uses of M&S."; Validation: "the process of determining the degree to which a model or a simulation is an accurate representation of the real world..." (§3.2). ECSS. (2008). *ECSS-E-ST-60-10C* — "In general error budgeting is not sufficient to extensively demonstrate the final performance of a complex control system. The performance validation process also involves appropriate, detailed simulation campaign using Monte-Carlo techniques, or worst-case simulation scenarios." (p. 19); "the only way to include ensemble type errors (see A.1.2) is to have some form of Monte-Carlo campaign with a large number of simulations covering the parameter space." (p. 35). Montenbruck & Gill (2000) — "While answers to the above questions might also be obtained from a Monte-Carlo simulation, a large number of cases would be required to obtain the desired statistical information." (p. 294). Winkel, J. Ó. (2003). *Modeling and simulating GNSS signal structures and receivers* — "it is necessary to model the whole system (satellite constellation, signal transmission, receiver, environment etc.), not just parts of it" (p. 13).
- **Critical analysis**: The evidence sorts cleanly into the NASA-STD-7009 dichotomy. **Verification (equations solved right):** golden fingerprints with the exactly correct epistemic claim — "It is not a claim that the numbers are RIGHT. It is a claim that they have not MOVED" (`GoldenRunFingerprint.m:13–15`); byte-identical gating of every new feature (default-off, inert fixture); manifest numeric thresholds (light-time closure 1e-11 s, Jacobian 1e-5 rel, covariance symmetry 1e-10; `masterConfig.m:442–450`); and the Orekit cross-validation bridge (12/12 tiers: EKF-vs-Orekit KalmanEstimator agreement 6.8e-6 m in state *and* relative covariance, Orekit BatchLS recovering the sim's truth to 8.7e-8 m from the sim's own pseudoranges). Critically — and the repo's own documentation concedes this — the Orekit comparison **zeroed Q by construction** to make the filter comparison clean, so it proves *implementation equivalence*, not statistical validity of the process-noise model; covariance honesty is untested by that bridge. **Validation (represents reality):** does not exist. `cfg.validation.manifest.status = 'declaredNotStatisticallyExecuted'` (`masterConfig.m:435–437`) is a predeclared campaign, not an executed one; all consistency evidence is labelled synthetic; no real-world measurement data is ingested anywhere. Against ECSS-E-ST-60-10C the sim's *design* aligns (it has exactly the Monte-Carlo campaign apparatus the standard's notes call for) but its *default execution* does not — a paper claim of "validated performance" from the default single-seed run would fail both the ECSS note and the repo's own labels. Also correct per this standard's spirit: `ModelCoverageAudit` enforces that all 22 model categories be implemented/disabled/guarded with `missingUnsafe = 0` and blocks real-world claims via a claim gate. Checked and deemed marginal: Suttor (2020), the ArcMap GNSS planning-tool thesis, contains no simulation-V&V or stochastic-modelling content relevant here (GIS mission-planning only).

### Reproducibility & parallel determinism
- **Code**: master seed 42 + fixed per-source seeds (`masterConfig.m:895, 250, 1679, 1842, 1853, 1986, 2025, 2070, 2136`); scenario SHA-256 + explicit-path provenance recorded at resolve time (`resolveSimulationConfig.m:26, 39–41, 44–49`); resolved cfg persisted in the run .mat; fingerprint stores seed + scenario hash (`GoldenRunFingerprint.m:210–215`). Parallel federated fan-out: per-asset `matlab -batch` workers, gathered results claimed **bit-identical to the serial loop** because assets are per-asset seeded and results are pure numeric, verified by `tests/regression/run_swarm_relative_regression.m`; worker failure falls back to in-process serial re-run "never changes the answer — only the speed" (`+revgnss/ReportRunner.m:2287–2295`); RAM-aware `maxWorkers` heuristic with measured calibration (16 GB → 2 workers optimum; `:2246–2285`).
- **Verdict**: ✅ Reproducibility is well-engineered end-to-end (deterministic seeds, provenance hashes, order-independent streams, bit-identical parallel path); minor residual risks only.
- **Sources**: Salmon et al. (2011) [EXTERNAL] (counter-based streams are what make the per-worker determinism cheap — no state hand-off between processes is needed).
- **Critical analysis**: The combination (counter-based identity-keyed streams) + (process-level fan-out with per-asset seeds) + (a regression test that asserts serial/parallel equality) is the right architecture: parallelism is pure orchestration, never a stochastic degree of freedom. Residual risks worth recording: (1) the J2 auto-tuner (above) means the masterConfig *text* alone under-determines one Q parameter on j2/two-body scenarios — the persisted resolved cfg is the authoritative record; (2) MC ensemble seeds enter through three mechanisms (`simulation.seed`, `mcSeedOffset`, an mt19937ar draw at `baseSeed+j+500000` for initial errors) — all deterministic, but the offset arithmetic is convention-based rather than identity-keyed, the same weaker pattern as the per-asset `+1000*ai` offsets; (3) cross-MATLAB-version stability of fingerprints depends on library numerics (the RNG itself is counter-based and stable; `chi2inv` has a toolbox-independent fallback); (4) the worktree-shadowing incident shows path hygiene was a real, silent threat — the durable fix (genpath filter + `which` assertion in `run_all_tests.m:17–26`) is the correct one, since deleting a stale copy merely promotes the next shadow.

---

#### References (APA 7)

- Bar-Shalom, Y., Li, X. R., & Kirubarajan, T. (2001). *Estimation with applications to tracking and navigation: Theory, algorithms and software.* Wiley. [EXTERNAL — cited in-code at `ChiSquareConsistency.m:2–4`; §5.4 consistency tests]
- Brown, R. G., & Hwang, P. Y. C. (1997). *Introduction to random signals and applied Kalman filtering* (3rd ed.). Wiley. [Paper/Error Calculation/KalmanFilter/Brown.pdf — pp. 94–95 (Gauss-Markov), 200–202 (discrete φ, Q), 210–211 (Monte Carlo)]
- Chen, Z., Biggie, H., Ahmed, N., Julier, S., & Heckman, C. (2023). *Kalman filter auto-tuning through enforcing chi-squared normalized error distributions with Bayesian optimization* (arXiv:2306.07225). [EXTERNAL]
- European Cooperation for Space Standardization. (2008). *ECSS-E-ST-60-10C: Control performance* (pp. 19, 35). ESA-ESTEC. [Paper/Error Calculation/ECSS-E-ST-60-10C(15November2008).pdf]
- MathWorks. (n.d.). *RandStream — Random number stream* [Documentation: Threefry4x64_20, multiple streams and substreams]. https://www.mathworks.com/help/matlab/ref/randstream.html [EXTERNAL]
- Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications.* Springer. [Paper/Fundamental Books/04_Montenbruck_2000_SatelliteOrbits.pdf — pp. 286–287 (Q tuning by simulation), 294 (Monte-Carlo vs covariance analysis)]
- NASA. (2016). *NASA-STD-7009A: Standard for models and simulations.* National Aeronautics and Space Administration. https://standards.nasa.gov/standard/NASA/NASA-STD-7009 [EXTERNAL — §3.2 verification/validation definitions]
- Salmon, J. K., Moraes, M. A., Dror, R. O., & Shaw, D. E. (2011). Parallel random numbers: As easy as 1, 2, 3. In *Proceedings of SC'11* (Article 16, p. 1). ACM. https://www.thesalmons.org/john/random123/papers/random123sc11.pdf [EXTERNAL]
- Suttor, D. (2020). *Programmierung eines GNSS Planning Tools als Erweiterung für ArcMap* [Master's thesis, Universität Innsbruck]. [checked — marginal; no simulation-V&V content]
- Wilson, E. B., & Hilferty, M. M. (1931). The distribution of chi-square. *PNAS, 17*(12), 684–688. [cited in-code at `ChiSquareConsistency.m:15–17`]
- Winkel, J. Ó. (2003). *Modeling and simulating GNSS signal structures and receivers* [Doctoral dissertation, Universität der Bundeswehr München] (p. 13). [Paper/Error Calculation/ClockError/ModelingandSimulatingGNSSSignalStructuresandReceivers-JOW.pdf]

---

# Appendix: Complete Paper/ Folder Coverage Map

Every document in `IRP/Paper/` (84 files), classified by topic, relevance to the oo_v1 simulation, and where it is used in this analysis. Duplicates and unreadable files are flagged. "Section" refers to the domain sections of this analysis: §1 Clocks, §2 Atmosphere, §3 Orbits, §4 Measurements, §5 Filter/Attitude, §6 Time Transfer, §7 Ambiguity, §8 ISL/Swarm, §9 Simulation Flow.

## Legend
- **CORE** — primary quoted source for at least one simulation feature
- **SUPPORT** — corroborating/background source, quoted where useful
- **CONTEXT** — application or mission context; not simulation physics
- **N/A** — not applicable to any implemented simulation feature
- **DUP** — duplicate of another file in the folder
- **SCAN** — scanned PDF, no text layer (quotes require visual page reading/transcription)

## Fundamental Books/
| File | Identification | Relevance | Section |
|---|---|---|---|
| 02_Understanding GPS Principles and Applications.pdf (723p) | Kaplan & Hegarty (2006), *Understanding GPS*, 2nd ed., Artech House | **CORE** — receiver thermal noise (DLL/PLL), signal structure, error budgets | §4, §8 |
| understanding-gps-principles-and-applications-2006.pdf | same book | DUP of above | — |
| 03_gnss-global-navigation-satellite-systems-...-2008.pdf (546p) | Hofmann-Wellenhof, Lichtenegger & Wasle (2008), *GNSS*, Springer. **SCAN** (no text layer) | **CORE** — observation equations, double differencing, linear combinations | §4, §7 |
| 04_Montenbruck_2000_SatelliteOrbits.pdf (378p) | Montenbruck & Gill (2000), *Satellite Orbits*, Springer | **CORE** — force models (J2, third-body, SRP), integrators, STM, sequential estimation | §3, §5, §9 |
| 05_Tesi_tagliaferro.pdf (137p) | Tagliaferro PhD thesis (Politecnico di Milano), undifferenced uncombined GNSS adjustment | SUPPORT — ambiguity/bias parameterization theory | §7 |
| A Software-Defined GPS and Galileo Receiver.pdf (185p) | Borre, Akos, Bertelsen, Rinder & Jensen (2007), Birkhäuser | SUPPORT — tracking-loop noise, signal processing | §4 |
| The Global Positioning System- Signals, measurements, and performance.pdf (23p) | **NOT the Misra & Enge textbook** — Enge (1994) journal article of the same title, *Int. J. Wireless Information Networks* 1(2) | SUPPORT — observation equations overview | §4 |
| Satellite Navigation Uplink and Reception Technology.pdf (412p) | Xie, Wang, Li & Meng (eds.) (2021), *Satellite Navigation Systems and Technologies*, Springer | **CORE** — uplink/reverse-direction navigation technology (closest analogue to the reverse-GNSS concept in the folder) | §4, §6 |
| 01_phase-noise-in-signal-sources_compress.pdf (338p) | Robins (1984), *Phase Noise in Signal Sources*, IET Telecom Series 9 | SUPPORT — oscillator phase-noise fundamentals | §1 |
| phase-noise-in-signal-sources_compress.pdf | same book | DUP | — |
| PBTE009E_fm.pdf (15p) | front matter of the Robins book only | DUP (fragment) | — |
| Synchronization_in_digital_communication_systems_p.pdf (285p) | digital-receiver synchronization text (up/down-conversion, timing recovery) | SUPPORT — background for timestamping/receiver sync; not directly implemented | §6 |
| CislunarXNAV_v3.pdf (1p) | Ray, Mitchell & Majid — pulsars for clock steering/time transfer (abstract) | CONTEXT — alternative time-transfer concept, not simulated | — |
| - VleReader.pdf (83p) | unidentifiable — **SCAN**, no extractable text | N/A (unreadable) | — |

## Error Calculation/ClockError/ → §1
| File | Identification | Relevance |
|---|---|---|
| nistspecialpublication1065.pdf (136p) | Riley (2008), NIST SP 1065, *Handbook of Frequency Stability Analysis* | **CORE** — Allan variance definitions, power-law noise types |
| 2220.pdf.pdf (136p) | same NIST SP 1065 (cleaner text extraction) | DUP (preferred copy) |
| ModelingandSimulatingGNSSSignalStructuresandReceivers-JOW.pdf (249p) | Winkel (2003), PhD, Univ. FAF Munich — *Modeling and Simulating GNSS Signal Structures and Receivers* | **CORE** — the `jowTable2p1` oscillator h-parameter source |
| A STABLE CLOCK ERROR MODEL USING COUPLED FIRST- AND SECOND-ORDER GAUSS-MARKOV PROCESSES.pdf (13p) | Carpenter & Lee (2008), AAS 08-109 | **CORE** — stable clock error modeling alternative to unstable RW models |
| 2011T-IFCS-Leeson-effect.pdf (101p) | Rubiola (2011), Leeson-effect lecture slides | SUPPORT — oscillator phase-noise physics |
| AN-756.pdf (12p) | Brannon (Analog Devices AN-756), clock phase noise & jitter in sampled systems | SUPPORT — jitter background |

## Error Calculation/KalmanFilter/ → §5
| File | Identification | Relevance |
|---|---|---|
| Brown.pdf (248p) | Brown & Hwang, *Introduction to Random Signals and Applied Kalman Filtering*. **SCAN** (no text layer) | **CORE** — EKF equations, Joseph form, Gauss-Markov processes, two-state clock Q |

## Error Calculation/Ionosphere/ → §2
| File | Identification | Relevance |
|---|---|---|
| 01_Impact of higher-order ionospheric terms on GPS estimates.pdf (5p) | Fritsche et al. (2005), GRL 32, L23311 | **CORE** — 2nd/3rd-order ionosphere magnitudes |
| 02_Towards MillimeterLevel Accuracy...pdf (90p) | Zajdel? — *Surveys in Geophysics* 44:1691–1780 (2023) PPP error-budget review | **CORE** — completeness benchmark for the error budget |
| Lai_ION_ITM_2023_Tropo.pdf (19p) | Lai, Blanch & Walter (2023), ION ITM — troposphere model error | **CORE** — tropo residual statistics |

## Error Calculation/Troposhpere/ → §2
| File | Identification | Relevance |
|---|---|---|
| 01_1-s2.0-S0273117725011214-main.pdf (19p) | *Adv. Space Res.* 77:310–328 (2026) — regional real-time ZTD | SUPPORT — ZTD variability magnitudes |
| 02_ajol-...pdf (24p) | Osah et al. (2021), S. Afr. J. Geomatics 10(2) — tropo delay model comparison (Ghana) | SUPPORT — Saastamoinen formula statement |
| 03_ijg_2016051817585715.pdf (10p) | Elsobeiey & El-Diasty (2016), Int. J. Geosciences 7 — tropo delay impact | SUPPORT |
| OA_2023_0314.pdf (10p) | Barba et al. (2023) — tropo/iono GNSS time series (La Palma) | SUPPORT |

## Error Calculation/Antenna Offset/ → §4
| File | Identification | Relevance |
|---|---|---|
| Accuracy of Current and Future Satellite Navigation Systems.pdf (147p) | Steigenberger habilitation (TU München) | **CORE** — PCO/PCV, system accuracy |
| igs-pcvs_gpsworld10.pdf (4p) | GPS World Tech Talk — IGS antenna phase center corrections | SUPPORT |
| leica_reference_antennas_whitepaper_tpa.pdf (11p) | Leica whitepaper — reference antennas | SUPPORT |

## Error Calculation/Atmospheric Errors/ → mostly §2 (mixed folder)
| File | Identification | Relevance | Section |
|---|---|---|---|
| 01_Springer_Satellite Navigation Systems and Technologies.pdf (412p) | Xie et al. (2021) | DUP of Fundamental Books/Satellite Navigation Uplink... | §4/§6 |
| 02_abbas-et-al-2012-...icube-1....pdf (13p) | Abbas/Naqvi (2012), AIAA — GNSS attitude determination of ICUBE-1 | **CORE** — GNSS attitude concept | §5, §7 |
| naqvi-jun-2013-...lambda-and-ekf.pdf (12p) | Naqvi et al. (2013), AIAA — LAMBDA+EKF attitude | **CORE** — LAMBDA+EKF attitude method | §5, §7 |
| 03_GNSS Carrier-Phase Multipath Modeling and Correction....pdf (22p) | Zhang et al. (2024), *Remote Sens.* 16:189 | **CORE** — multipath modeling review | §4 |
| 04_GNSS_NASA.pdf (47p) | Ashman (NASA GSFC) — Introduction to GNSS | SUPPORT — spaceborne GNSS overview | §4 |
| 1 (1).pdf (1p) | single page "Part A Principles of GNSS" (Springer Handbook of GNSS fragment) | N/A (fragment) | — |
| GNSS for High-Precision and Reliable Positioning...pdf (41p) | Sukhenko et al. (2025) review | SUPPORT — correction techniques | §2 |
| Multipath signal modelling and simulation....pdf (115p) | Paoli, Cranfield MSc thesis — multipath modelling & simulation | **CORE** — multipath simulation methodology | §4 |
| R-REC-P.525-5-202411-I!!PDF-E.pdf (6p) | ITU-R Rec. P.525-5 (11/2024) — free-space attenuation | **CORE** — FSPL | §8 |
| Regional Ionospheric Corrections for High Accuracy GNSS Positioning.pdf (18p) | Dao et al. (2022), *Remote Sens.* 14:2463 | SUPPORT — iono residual magnitudes | §2 |
| Springer_Global Navigation Satellite System.pdf (434p) | Walker & Awange, *Surveying for Civil and Mine Engineers* (Springer) | SUPPORT — GNSS error chapters | §2 |
| xx_10.1201_9781003148753_previewpdf.pdf (50p) | CRC *Global Navigation Satellite Systems* preview | SUPPORT (preview only) | §2 |
| xx_bousquet-2012-...binary-offset-carrier-signals.pdf (15p) | Ries et al. — BOC signal simulators | N/A — BOC signal structure not modeled in oo_v1 | — |
| xx_drones-08-00690-v2.pdf (27p) | Isik, Petrunin & Tsourdos (2024), *Drones* 8:690 — ML GNSS integrity for UAM | N/A — integrity monitoring not modeled | — |

## Error Calculation/ (root) → mixed
| File | Identification | Relevance | Section |
|---|---|---|---|
| ECSS-E-ST-60-10C(15November2008).pdf (57p) | ECSS-E-ST-60-10C, *Control performance* standard | **CORE** — performance-verification terminology and budgeting practice | §5, §9 |
| Multi-constellation GNSS precise point positioning....pdf (13p) | An et al. (2020), *Satell. Navig.* 1:7 | **CORE** — iono-free combination definition | §2 |
| NASAcomponentReferenceError.pdf (441p) | NASA/TP-2024-10001462, *State-of-the-Art Small Spacecraft Technology* | **CORE** — gyro/star-tracker component reference specs | §5 |
| Pointing_Error_PEET_AIAA_GNC_2013.pdf (21p) | Casasco et al. (2013), AIAA GNC — Pointing Error Engineering Tool | SUPPORT — pointing-error budgeting method | §5 |
| Two-Way_Frequency_Transfer_via_Satellite_Using_Carrier_Phase.pdf (6p) | PTTI 2000 — TWSTFT with carrier phase | **CORE** — two-way transfer equations | §6 |
| Receiver clock error determination.pdf (3p) | **SCAN**, no text layer | limited use | §1 |
| Towards Millimeter-Level Accuracy....pdf (90p) | *Surveys in Geophysics* 44 (2023) | DUP of Ionosphere/02 | §2/§4 |
| micromachines-15-00455.pdf (45p) | Naumann & Sands (2024), *Micromachines* 15:455 — micro-satellite systems design | CONTEXT — smallsat design; marginal | — |
| Programmierung eines GNSS Planning Tools...pdf (79p) | German MSc thesis — GNSS planning tool for ArcMap | N/A — planning/DOP tooling, not simulation physics | — |
| A_Sensitivity_Study_of_POD_Using_Dual-Frequency_GP.pdf (21p, in ClockError/) | Wang & Allahvirdi-Zadeh — CubeSat POD sensitivity | SUPPORT — POD/clock sensitivity | §5 |

## Time Synchronisation/ → §6
| File | Identification | Relevance |
|---|---|---|
| 03_Enhanced_Multi-Way_Time_Transfer....pdf (6p) | Shen & Chen — multi-way time transfer among UASs | **CORE** — four-timestamp two-way equations |
| 04_Wireless_Picosecond_Time_Synchronization....pdf (12p) | Merlo, Mghabghab & Nanzer (2023), IEEE TMTT 71(4):1720 | **CORE** — ps sync for distributed arrays; beamforming coherence requirement (also §8) |
| Two-Way_Frequency_Transfer... | (listed above, root) | **CORE** |
| 100 Picosecond:Sub-10−17 Level GPS Differential....pdf (15p) | Song et al. (2023), *Appl. Sci.* 13:10694 | **CORE** — achieved GPS time-transfer precision benchmark |
| Precise time transfer and ranging for next-generation GNSS.pdf (10p) | *GPS Solutions* 30:101 (2026) — Kepler-style OISL time transfer | **CORE** — next-gen ISL time-transfer architecture benchmark (also §8) |
| Precision_and_accuracy_of_GPS_time_transfer.pdf (6p) | Lewandowski et al. (1993), IEEE TIM 42(2) | SUPPORT — classical GPS time transfer |
| 01_Sub-Picosecond_Software_Defined_Radio....pdf (4p) | Friedt et al. — sub-ps SDR synchronization | SUPPORT |
| 02_T2L2_-_Time_transfer_by_Laser_link....pdf (10p) | Fridelance, Samain & Veillet — T2L2 optical time transfer | SUPPORT — optical alternative |
| Picosecond Clock Synchronization Across a 7-node....pdf (6p) | McKenzie et al. — quantum-network clock sync | CONTEXT |
| Precise point positioning for ground-based navigation systems without accurate time synchronization.pdf (12p) | *GPS Solutions* 22:34 (2018) | **CORE** — ground-transmitter navigation without sync (closest published analogue to reverse GNSS!) |
| Synchronization_Performance_Assessment_of_GNSS-Based_Time_Source_in_5G....pdf (12p) | IEEE Access (2025) | CONTEXT |
| Time_and_Frequency_Measurements_with_Picosecond_Precision....pdf (2p) | Swabian Instruments note | CONTEXT — instrument precision benchmark |
| EGU25-7197-print.pdf (2p) | EGU 2025 abstract — common clock for GNSS receivers | CONTEXT |
| IAC-23%2CB2%2C1%2C7%2Cx77319.pdf (9p) | Fazzoletto et al. (2023), IAC-23-B2.1.7 | SUPPORT — (topic: satellite timing/navigation payload; checked in §8) |
| s43020-022-00075-1.pdf (15p) | Lou et al. (2022), *Satell. Navig.* 3:15 — real-time multi-GNSS POD filter review | SUPPORT — filter-method benchmark (also §5) |

## Syncrhonisation Techniques/ → background only
| File | Identification | Relevance |
|---|---|---|
| An Overview of Phase-Locked Loop....pdf (43p) | Nguyen et al. (2025) PLL review | SUPPORT — receiver tracking background; oo_v1 abstracts tracking loops into σ values (no PLL simulated) |
| phase-locked-loop-pll-fundamentals.pdf (6p) | Collins (2018), Analog Dialogue 52-07 | SUPPORT — same |

## Link BUdget/ → §8
| File | Identification | Relevance |
|---|---|---|
| Link_budget_uvigo.pdf (46p) | Arias & Aguado (2016) — small-satellite link budget course notes | **CORE** — link-budget equation chain |
| Analysis of GNSS radio frequency interference....pdf (23p) | *GPS Solutions* 29:196 (2025) | SUPPORT — interference/jamming impacts (not modeled — gap) |
| Interference_and_Link_Budget_Analysis....pdf (6p) | Bi, Yang & Wang (2018), IEEE | SUPPORT |
| Article seuils acquisition version finale.pdf (27p) | ENAC (2023, HAL) — acquisition thresholds | SUPPORT — C/N0-to-tracking-threshold formulas |
| Load_Dependent_Interference_Margin....pdf (3p) | Fernekeß et al. (2008), IEEE Comm. Letters — OFDMA interference margin | N/A — OFDMA-specific |
| __scisearchnet__Evaluation_of_GNSS_Receiver_Performance....pdf (15p) | Thapa & Adhikari — receiver performance under multipath/iono/interference | SUPPORT |

## Positioning Technologies/ → mixed
| File | Identification | Relevance | Section |
|---|---|---|---|
| Fixing the AmbiguitiesAre You Sure They're Right?.pdf (6p) | Joosten & Tiberius, *GPS World* — ambiguity success rate | **CORE** — bootstrapped success-rate formula | §7 |
| Characterisation of GNSS Carrier Phase Data on a Moving Zero-Baseline....pdf (22p) | Ruwisch et al., *Sensors* | SUPPORT — carrier-phase noise characterization | §7 |
| 01_Quality analysis of multi-GNSS raw observations....pdf (20p) | Liu et al. — smartphone GNSS quality | CONTEXT | — |
| Satellite availability and point positioning accuracy....pdf (15p) | Pan et al. — multi-constellation availability | CONTEXT — multi-constellation not modeled | — |
| Sentinel-1A Product Geolocation Accuracy.pdf (19p) | *Remote Sens.* 7:9431 (2015) | CONTEXT — mission application (why GEO positioning accuracy matters), not simulation physics | — |
| The Photogrammetric Record...Ikonos.pdf (15p) | Fraser et al. (2002) | CONTEXT — same | — |

## Root
| File | Identification | Relevance |
|---|---|---|
| remotesensing-16-00189-v2.pdf (22p) | Zhang et al. (2024) multipath review | DUP of Atmospheric Errors/03 |

## Coverage summary
- **84 files**: ~30 CORE, ~25 SUPPORT, ~10 CONTEXT, ~8 N/A, ~8 DUP, 4 SCAN (no text layer: Brown & Hwang, Hofmann-Wellenhof 2008, Receiver clock error determination, VleReader).
- **Notable absences from Paper/** (features implemented in oo_v1 with no in-folder source — external literature required): LAMBDA original theory (Teunissen 1995), integer bootstrapping success-rate theory beyond the GPS World article (Teunissen 1998), classical MDS (Torgerson 1952/Borg & Groenen), covariance intersection (Julier & Uhlmann 1997), Clohessy-Wiltshire relative motion (Clohessy & Wiltshire 1960), IERS Conventions 2010 (solid earth tides, EOP), Saastamoinen 1972 / Davis et al. 1985 / Niell 1996 originals, Klobuchar 1987, colored-noise synthesis (Kasdin 1995), counter-based RNG (Salmon et al. 2011), phase wind-up (Wu et al. 1993), MEKF (Markley 2003), Shapiro delay (Shapiro 1964 / IERS), Ruze antenna-tolerance law (Ruze 1966).

---

## Master Reference List (APA 7)

- [Article seuils acquisition version finale]. (n.d.). *GNSS acquisition thresholds and C/N0 link budget margins for civil-aviation DFMC receivers*. (Paper/Link BUdget; C/N0,eff and acquisition link-budget-margin methodology, Eqs. (27)–(30).)
- Acklam, P. J. (2003). *An algorithm for computing the inverse normal cumulative distribution function*. [EXTERNAL; algorithm note, coefficients verified digit-for-digit]
- McKenzie, W., Richards, A. M., Li-Baboud, Y.-S., Burenkov, I. A., et al. (n.d.). *Picosecond clock synchronization across a 7-node metropolitan scale quantum network*. [ELSTAB sub-ps TDEV; WR-PTP 10 ps TDEV — supporting benchmark]
- An, X., Meng, X., & Jiang, W. (2020). Multi-constellation GNSS precise point positioning with multi-frequency raw observations and dual-frequency observations of ionospheric-free linear combination. *Satellite Navigation, 1*, 7. https://doi.org/10.1186/s43020-020-0009-x
- Arias, M., & Aguado, F. (2016). *Small satellite link budget calculation* [Lecture slides]. Universidade de Vigo. (Paper/Link BUdget/Link_budget_uvigo.pdf.)
- Bar-Shalom, Y., Li, X. R., & Kirubarajan, T. (2001). *Estimation with applications to tracking and navigation: Theory, algorithms and software.* Wiley. [EXTERNAL — cited in-code at `ChiSquareConsistency.m:2–4`; §5.4 consistency tests]
- Barba, P., Ramírez-Zelaya, J., Jiménez, V., Rosado, B., Jaramillo, E., Moreno, M., & Berrocoso, M. (2023). Tropospheric and ionospheric modeling using GNSS time series in volcanic eruptions (La Palma, 2021). *Engineering Proceedings, 39*(1), 47. https://doi.org/10.3390/engproc2023039047
- Betz, J. W., & Kolodziejski, K. R. (2009). Generalized theory of code tracking with an early-late discriminator, Part I: Lower bound and coherent processing. *IEEE Transactions on Aerospace and Electronic Systems, 45*(4), 1538–1556. [EXTERNAL]
- Bierman, G. J. (1977). *Factorization methods for discrete sequential estimation*. Academic Press. [EXTERNAL]
- Borre, K., Akos, D. M., Bertelsen, N., Rinder, P., & Jensen, S. H. (2007). *A software-defined GPS and Galileo receiver: A single-frequency approach*. Birkhäuser.
- Brannon, B. (2004). *Sampled systems and the effects of clock phase noise and jitter* (Application Note AN-756). Analog Devices.
- Brown, R. G., & Hwang, P. Y. C. (1997). *Introduction to random signals and applied Kalman filtering: With MATLAB exercises and solutions* (3rd ed.). Wiley. [Paper/Error Calculation/KalmanFilter/Brown.pdf — scanned; quotes transcribed from rendered page images]
- Brown, R. G., & Hwang, P. Y. C. (2012). *Introduction to random signals and applied Kalman filtering* (4th ed.). Wiley. [EXTERNAL]
- Carpenter, J. R., & Lee, T. (2008). *A stable clock error model using coupled first- and second-order Gauss-Markov processes* (AAS 08-109). AAS/AIAA Space Flight Mechanics Meeting.
- Carrano, C. S., & Rino, C. L. (2016). A theory of scintillation for two-component power law irregularity spectra: Overview and numerical results. *Radio Science, 51*(6), 789–813. https://doi.org/10.1002/2015RS005903 [EXTERNAL]
- Chen, Z., Biggie, H., Ahmed, N., Julier, S., & Heckman, C. (2023). *Kalman filter auto-tuning through enforcing chi-squared normalized error distributions with Bayesian optimization* (arXiv:2306.07225). [EXTERNAL]
- Clohessy, W. H., & Wiltshire, R. S. (1960). Terminal guidance system for satellite rendezvous. *Journal of the Aerospace Sciences, 27*(9), 653-658. [EXTERNAL]
- Conker, R. S., El-Arini, M. B., Hegarty, C. J., & Hsiao, T. (2003). Modeling the effects of ionospheric scintillation on GPS/Satellite-Based Augmentation System availability. *Radio Science, 38*(1), 1001. https://doi.org/10.1029/2000RS002604 [EXTERNAL]
- Davis, J. L., Herring, T. A., Shapiro, I. I., Rogers, A. E. E., & Elgered, G. (1985). Geodesy by radio interferometry: Effects of atmospheric modeling errors on estimates of baseline length. *Radio Science, 20*(6), 1593–1607. https://doi.org/10.1029/RS020i006p01593 [EXTERNAL]
- Enge, P. K. (1994). The Global Positioning System: Signals, measurements, and performance. *International Journal of Wireless Information Networks, 1*(2), 83–105. [PDF in Paper/Fundamental Books — note: this is the 1994 article, not the Misra & Enge textbook]
- Eren, T., Goldenberg, D. K., Whiteley, W., Yang, Y. R., Morse, A. S., Anderson, B. D. O., & Belhumeur, P. N. (2004). Rigidity, computation, and randomization in network localization. *Proceedings of IEEE INFOCOM 2004*, 2673–2684. [EXTERNAL]
- European Cooperation for Space Standardization. (2008). *ECSS-E-ST-60-10C: Control performance* (pp. 19, 35). ESA-ESTEC. [Paper/Error Calculation/ECSS-E-ST-60-10C(15November2008).pdf]
- European Space Agency. (n.d.). *Klobuchar ionospheric model*; *Mapping of Niell*. Navipedia. https://gssc.esa.int/navipedia/ [EXTERNAL]
- Farrenkopf, R. L. (1978). Analytic steady-state accuracy solutions for two common spacecraft attitude estimators. *Journal of Guidance and Control, 1*(4), 282–284. [EXTERNAL] https://doi.org/10.2514/3.55779
- Fridelance, P., Samain, E., & Veillet, C. (1996). *T2L2 – Time transfer by laser link: A new generation optical time transfer*. Observatoire de la Côte d'Azur / CERGA.
- Friis, H. T. (1946). A note on a simple transmission formula. *Proceedings of the IRE, 34*(5), 254–256. [EXTERNAL]
- Fritsche, M., Dietrich, R., Knöfel, C., Rülke, A., Vey, S., Rothacher, M., & Steigenberger, P. (2005). Impact of higher-order ionospheric terms on GPS estimates. *Geophysical Research Letters, 32*, L23311. https://doi.org/10.1029/2005GL024342
- Hofmann-Wellenhof, B., Lichtenegger, H., & Wasle, E. (2008). *GNSS — Global Navigation Satellite Systems: GPS, GLONASS, Galileo, and more*. Springer. [PDF in Paper/Fundamental Books; quotes pp. 112, 179–180, 218]
- IEEE. (1997). *IEEE standard specification format guide and test procedure for single-axis interferometric fiber optic gyros* (IEEE Std 952-1997). IEEE. [EXTERNAL]
- International Telecommunication Union. (2019). *Ionospheric propagation data and prediction methods required for the design of satellite services and systems* (Recommendation ITU-R P.531). [EXTERNAL]
- International Telecommunication Union. (2024). *Recommendation ITU-R P.525-5: Calculation of free-space attenuation*. ITU-R. (Paper/Error Calculation/Atmospheric Errors.)
- ITU-R. (2015). *Recommendation ITU-R TF.1153-4: The operational use of two-way satellite time and frequency transfer employing pseudorandom noise codes* (08/2015). International Telecommunication Union. [EXTERNAL — retrieved from itu.int]
- Joosten, P., & Tiberius, C. C. J. M. (2000). Fixing the ambiguities: Are you sure they're right? *GPS World, 11*(5), 46–51. [PDF in Paper/Positioning Technologies]
- Julier, S. J., & Uhlmann, J. K. (1997). A non-divergent estimation algorithm in the presence of unknown correlations. *Proceedings of the American Control Conference*, 2369–2373. [EXTERNAL]
- Julier, S. J., & Uhlmann, J. K. (2001). General decentralized data fusion with covariance intersection. In D. L. Hall & J. Llinas (Eds.), *Handbook of multisensor data fusion*. CRC Press. [EXTERNAL]
- Kabsch, W. (1976). A solution for the best rotation to relate two sets of vectors. *Acta Crystallographica Section A, 32*(5), 922–923. [EXTERNAL]
- Kaplan, E. D., & Hegarty, C. J. (Eds.). (2006). *Understanding GPS: Principles and applications* (2nd ed.). Artech House. [Paper/Fundamental Books]
- Kaplan, E. D., & Hegarty, C. J. (Eds.). (2017). *Understanding GPS/GNSS: Principles and applications* (3rd ed.). Artech House. [EXTERNAL]
- Kasdin, N. J. (1995). Discrete simulation of colored noise and stochastic processes and 1/f^α power law noise generation. *Proceedings of the IEEE, 83*(5), 802–827. (EXTERNAL; abstract verified, full text via JOW's [Kas95].)
- Leica Geosystems. (2014). *Leica reference antennas* [White paper]. Leica Geosystems AG.
- Lewandowski, W., Petit, G., & Thomas, C. (1993). Precision and accuracy of GPS time transfer. *IEEE Transactions on Instrumentation and Measurement, 42*(2), 474–479.
- Li, H., Nashashibi, F., & Yang, M. (2013). Split covariance intersection filter: Theory and its application to vehicle localization. *IEEE Transactions on Intelligent Transportation Systems, 14*(4), 1860–1871. [EXTERNAL]
- Li, X., Barriot, J.-P., Lou, Y., Zhang, W., Li, P., & Shi, C. (2023). Towards millimeter-level accuracy in GNSS-based space geodesy: A review of error budget for GNSS precise point positioning. *Surveys in Geophysics, 44*(6), 1691–1780. https://doi.org/10.1007/s10712-023-09785-w
- Mao, G., Fidan, B., & Anderson, B. D. O. (2007). Wireless sensor network localization techniques. *Computer Networks, 51*(10), 2529–2553. [EXTERNAL]
- Markley, F. L. (2003). Attitude error representations for Kalman filtering. *Journal of Guidance, Control, and Dynamics, 26*(2), 311–317. [EXTERNAL; NASA NTRS 20020060647] https://doi.org/10.2514/2.5048
- Massarweh, L., Verhagen, S., & Teunissen, P. J. G. (2024). *New LAMBDA toolbox for mixed-integer models: Estimation and evaluation* (LAMBDA 4.0). TU Delft. [EXTERNAL — cited by docs/LAMBDA_SETUP.md; toolbox not vendored, internals unverified]
- MathWorks. (n.d.). *RandStream — Random number stream* [Documentation: Threefry4x64_20, multiple streams and substreams]. https://www.mathworks.com/help/matlab/ref/randstream.html [EXTERNAL]
- Merlo, J. M., Mghabghab, S. R., & Nanzer, J. A. (2023). Wireless picosecond time synchronization for distributed antenna arrays. *IEEE Transactions on Microwave Theory and Techniques, 71*(4), 1720–1731. https://doi.org/10.1109/TMTT.2022.3227878
- Misra, P., & Enge, P. (2006). *Global Positioning System: Signals, measurements, and performance* (2nd ed.). Ganga-Jamuna Press. [Paper/Fundamental Books; scanned copy, limited text extraction]
- Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications.* Springer. [Paper/Fundamental Books/04_Montenbruck_2000_SatelliteOrbits.pdf — pp. 286–287 (Q tuning by simulation), 294 (Monte-Carlo vs covariance analysis)]
- Mudumbai, R., Brown, D. R., III, Madhow, U., & Poor, H. V. (2009). Distributed transmit beamforming: Challenges and recent progress. *IEEE Communications Magazine, 47*(2), 102–110. [EXTERNAL]
- Naqvi, N. A., Sun, Y., & YanJun, L. (2012). *Design and mathematical modeling of GNSS based attitude determination of ICUBE-1* (AIAA 2012-4419). [Paper/Error Calculation/Atmospheric Errors/] https://doi.org/10.2514/6.2012-4419
- Naqvi, N. A., Zhang, K., Masood, K., & Lv, M. (2013). *Design and simulation of GNSS phase based attitude determination of spacecraft: LAMBDA and EKF combination technique* (AIAA 2013-4832). AIAA Guidance, Navigation, and Control Conference. [PDF in Paper/Error Calculation/Atmospheric Errors]
- NASA. (2016). *NASA-STD-7009A: Standard for models and simulations.* National Aeronautics and Space Administration. https://standards.nasa.gov/standard/NASA/NASA-STD-7009 [EXTERNAL — §3.2 verification/validation definitions]
- NASA. (2024). *State-of-the-art of small spacecraft technology*. NASA Ames Research Center. [Paper/Error Calculation/NASAcomponentReferenceError.pdf]
- National Imagery and Mapping Agency. (2000). *Department of Defense World Geodetic System 1984* (NIMA TR8350.2, 3rd ed.). [EXTERNAL — WGS-84 defining constants]
- Naumann, P., & Sands, T. (2024). Micro-satellite systems design, integration, and flight. *Micromachines, 15*(4), 455. (Reviewed; not relevant.)
- Niell, A. E. (1996). Global mapping functions for the atmosphere delay at radio wavelengths. *Journal of Geophysical Research: Solid Earth, 101*(B2), 3227–3246. https://doi.org/10.1029/95JB03048 [EXTERNAL retrieval; cited by the code]
- Osah, S., Acheampong, A. A., Dadzie, I., & Fosu, C. (2021). Comparative evaluation and analysis of different tropospheric delay models in Ghana. *South African Journal of Geomatics, 10*(2), 115–134. https://doi.org/10.4314/sajg.v10i2.10
- Ott, T., et al. (2013). *Precision pointing H∞ control design for absolute, window-, and stability-time errors* (PEET, AIAA GNC 2013). [Paper/Error Calculation/Pointing_Error_PEET_AIAA_GNC_2013.pdf; consulted for pointing-error index framework]
- Petit, G., & Luzum, B. (Eds.). (2010). *IERS Conventions (2010)* (IERS Technical Note No. 36). Verlag des Bundesamts für Kartographie und Geodäsie. [EXTERNAL — Ch. 5 EOP, Ch. 7 Eq. (7.5), h2/l2 nominal values]
- Riley, W. J. (2008). *Handbook of frequency stability analysis* (NIST Special Publication 1065). National Institute of Standards and Technology.
- Robins, W. P. (1984). *Phase noise in signal sources* (IET Telecommunications Series 9). Peter Peregrinus.
- Rubiola, E. (2011, May). *The Leeson effect: Phase noise and frequency stability in oscillators* [Tutorial]. IEEE International Frequency Control Symposium, San Francisco.
- Ruze, J. (1966). Antenna tolerance theory — A review. *Proceedings of the IEEE, 54*(4), 633–640. [EXTERNAL]
- Sabol, C., Burns, R., & McLaughlin, C. A. (2001). Satellite formation flying design and evolution. *Journal of Spacecraft and Rockets, 38*(2), 270-278. [EXTERNAL — projected circular orbit]
- Salmon, J. K., Moraes, M. A., Dror, R. O., & Shaw, D. E. (2011). Parallel random numbers: As easy as 1, 2, 3. In *Proceedings of SC'11* (Article 16, p. 1). ACM. https://www.thesalmons.org/john/random123/papers/random123sc11.pdf [EXTERNAL]
- Schaefer, W., Pawlitzki, A., & Kuhn, T. (2000). Two-way frequency transfer via satellite using carrier phase. *Proceedings of the 32nd Annual Precise Time and Time Interval (PTTI) Systems and Applications Meeting*, Reston, VA.
- Schmid, R. (2010, February 3). How to use IGS antenna phase center corrections. *GPS World Tech Talk*.
- Schönemann, P. H. (1966). A generalized solution of the orthogonal Procrustes problem. *Psychometrika, 31*(1), 1–10. [EXTERNAL]
- Shen, D., Chen, G., Pham, K., & Blasch, E. (2022). Enhanced multi-way time transfer for high-precision time synchronization among UASs. *MILCOM 2022 — IEEE Military Communications Conference*, 501–506. https://doi.org/10.1109/MILCOM55135.2022.10017881
- Solà, J. (2017). *Quaternion kinematics for the error-state Kalman filter* (arXiv:1711.02508). [EXTERNAL] https://doi.org/10.48550/arXiv.1711.02508
- Song, W., Zheng, F., Wang, H., & Shi, C. (2023). 100 picosecond/sub-10⁻¹⁷ level GPS differential precise time and frequency transfer. *Applied Sciences, 13*(19).
- Surof, J., et al. (2026). Precise time transfer and ranging for next-generation GNSS. *GPS Solutions, 30*, 101. https://doi.org/10.1007/s10291-026-02064-2
- Suttor, D. (2020). *Programmierung eines GNSS Planning Tools als Erweiterung für ArcMap* [Master's thesis, Universität Innsbruck]. [checked — marginal; no simulation-V&V content]
- Tagliaferro, G. (2021). *On the development of a general undifferenced uncombined adjustment for GNSS observations* [Doctoral dissertation, Politecnico di Milano]. [PDF in Paper/Fundamental Books; quotes pp. 20, 35–37]
- Tapley, B. D., et al. (1996). The Joint Gravity Model 3. *Journal of Geophysical Research, 101*(B12), 28029-28049. [via Montenbruck & Gill Table 3.3 — JGM-3 C̄2,0]
- Teunissen, P. J. G. (1995). The least-squares ambiguity decorrelation adjustment: A method for fast GPS integer ambiguity estimation. *Journal of Geodesy, 70*(1–2), 65–82. https://link.springer.com/article/10.1007/BF00863419 [EXTERNAL]
- Teunissen, P. J. G. (1998). Success probability of integer GPS ambiguity rounding and bootstrapping. *Journal of Geodesy, 72*(10), 606–612. https://link.springer.com/article/10.1007/s001900050199 [EXTERNAL]
- Teunissen, P. J. G. (2001). GNSS ambiguity bootstrapping: Theory and application. *Proceedings of KIS 2001, International Symposium on Kinematic Systems in Geodesy, Geomatics and Navigation*, 246–254. https://gnss.curtin.edu.au/wp-content/uploads/sites/21/2016/04/Teunissen2001GNSS.pdf [EXTERNAL — fetched and quoted verbatim: eq. 19 p. 250, pp. 252–253]
- Torgerson, W. S. (1952). Multidimensional scaling: I. Theory and method. *Psychometrika, 17*(4), 401–419. [EXTERNAL]
- Tralli, D. M., & Lichten, S. M. (1990). Stochastic estimation of tropospheric path delays in Global Positioning System geodetic measurements. *Bulletin Géodésique, 64*(2), 127–159. https://doi.org/10.1007/BF02520642 [EXTERNAL]
- Vallado, D. A. (2013). *Fundamentals of astrodynamics and applications* (4th ed.). Microcosm Press. [EXTERNAL — explicit Cartesian J2 component form, Eq. 8-30]
- Van Dierendonck, A. J., McGraw, J. B., & Brown, R. G. (1984). Relationship between Allan variances and Kalman filter parameters. *Proceedings of the 16th Annual Precise Time and Time Interval (PTTI) Applications and Planning Meeting* (pp. 273–293). NASA Goddard Space Flight Center.
- Verhagen, S., & Teunissen, P. J. G. (2013). The ratio test for future GNSS ambiguity resolution. *GPS Solutions, 17*(4), 535–548. https://link.springer.com/article/10.1007/s10291-012-0299-z [EXTERNAL — abstract-level claims only]
- Wilson, E. B., & Hilferty, M. M. (1931). The distribution of chi-square. *Proceedings of the National Academy of Sciences, 17*(12), 684–688. [EXTERNAL] https://doi.org/10.1073/pnas.17.12.684
- Winkel, J. Ó. (2003). *Modeling and simulating GNSS signal structures and receivers* [Doctoral dissertation, Universität der Bundeswehr München] (p. 13). [Paper/Error Calculation/ClockError/ModelingandSimulatingGNSSSignalStructuresandReceivers-JOW.pdf]
- Wu, J. T., Wu, S. C., Hajj, G. A., Bertiger, W. I., & Lichten, S. M. (1993). Effects of antenna orientation on GPS carrier phase. *Manuscripta Geodaetica, 18*(2), 91–98. [EXTERNAL]
- Xie, J., Wang, H., Li, P., & Meng, Y. (2021). *Satellite navigation systems and technologies*. Springer. (Chapter 3: Satellite Navigation Uplink and Reception Technology.)
- Zhang, J., Liang, Q., & Huang, Y. (2026). Establishing high-precision regional real-time ZTD vertical models using ERA5 model-level data and GNSS observations. *Advances in Space Research, 77*(1), 310–328.
- Zhang, Q., Zhang, L., Sun, A., Meng, X., Zhao, D., & Hancock, C. (2024). GNSS carrier-phase multipath modeling and correction: A review and prospect of data processing methods. *Remote Sensing, 16*(1), 189. https://doi.org/10.3390/rs16010189
- Zucca, C., & Tavella, P. (2005). The clock model and its relationship with the Allan and related variances. *IEEE Transactions on Ultrasonics, Ferroelectrics, and Frequency Control, 52*(2), 289–296. (EXTERNAL; paywalled, cited for the instantaneous-frequency two-state form.)
