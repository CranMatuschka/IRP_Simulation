# Tests_All_1623 — deep-dive analysis (verified)

Investigation of 7 questions on the error-ladder results. Each answer was produced by a code+data
investigator and then independently, adversarially verified (verdicts below). All CONFIRMED.

## Unifying theme: the GEO radial↔clock observability wall

One mechanism explains Q1, Q2, Q3 and Q6. On a GEO, all ground-tower lines of sight are nearly
parallel to the satellite radial (nadir) direction, so a **radial position shift and a receiver-clock
bias are indistinguishable** in the range equation. Evidence, every run: `corr(radial,clock) = −1.000`,
physical observability `rank = 2` (deficient), `cond ≈ 4600`, and the clock error in metres ≈ the
radial error in metres. The position error is ~99% **radial** (S1R4 baseline: rad 11.98 of 11.99 m).
Everything below is a consequence of how tightly this degenerate radial↔clock mode is pinned.

---

## Q1 — Why do idealised vs realism ionosphere differ so much?  ✅ CONFIRMED (config-choice)

**Answer.** The atmosphere is *identical* in both grades — `realismGradeConfig.m` touches no
tropo/iono/atmosphere/Klobuchar field. What differs is the **clock stiffness** in the degenerate
mode. Realism swaps the idealised "legacy" clock (CESIUM1 h0≈1e-26, an unphysically quiet maser) for
the real caesium `jowTable2p1` template (h0≈1e-19, ~7 decades noisier) and loosens tower-product
sigma / measurement floors / C-N0 weighting. A looser clock covariance lets the common-mode iono
delay grow to a larger steady-state error that lands equally in radial and clock.

- Filter's own clock 1σ (`sig_clk_final`): default S1R1 **1.81 m** → realism **8.22 m** (4.5× looser).
- Iono-only increment (baseline removed in quadrature): **6.5 m** (default S1R1) → **95.1 m** (realism) = **14.6×**.
- `realismGradeConfig.m:31-49, 80-82`; `masterConfig.m:146-147` (default `templateSource='legacy'`); `tests/test_clock_template_sourcing.m` (h0 1e-26 vs 1e-19).
- **Correction (verifier):** the *ranking* "clock dominant over floors/cn0/tower-σ" is unproven — no clock-only rung exists to isolate it. The direction (looser common-mode → larger iono) is solid; the attribution to the clock specifically is directional.

## Q2 — Is the ionospheric error size realistic?  ✅ CONFIRMED (real-physics)

**Answer.** Two magnitudes, both correct. (a) The injected **ranging** iono is realistic: 30/6 TECU
diurnal VTEC → ~4.9 m day / ~1 m night vertical L1 (K_L1 = 0.1624 m/TECU), ×2–3 obliquity at low
elevation, Klobuchar removing ~50–65%, leaving a **metre-level single-frequency residual** — textbook.
(b) The **7–150 m position** error is legitimate amplification of that metre-scale range residual by
the radial↔clock wall, not an oversized iono.

- `clk_ns × c` reproduces `rad_rms` to <0.5% (default S1R4: 378.3 ns → 113.4 m vs rad 113.87 m; realism S1R4: 488.3 ns → 146.4 m vs 147.0 m) — pure common-mode absorption.
- Same iono, different geometry → 7.5 m (S1R1) vs 114 m (S1R4): output scales with geometry/state-dim, **not** iono size.
- `realisticAtmosphereConfig.m:50-51,54,75,77-83,85-89`.
- **Correction (verifier):** the exact surviving *slant* residual (~5–15 m) was not measured directly, so the "~10×" amplification is order-of-magnitude, not exact. Classification unaffected.

## Q3 — Why is R4 (4 receivers) worse than R1 (1 receiver)?  ✅ CONFIRMED — NOT A BUG (real-physics)

**Answer.** An adversarial verifier specifically hunted for a lever-arm/attitude/ambiguity/covariance
defect and found **none**. R1 and R4 have **identical tower geometry and identical radial
observability** (`obsCond = 4565.07747` byte-identical, rank 2, corr −1). The entire 24→54 state jump
is **30 extra float carrier-ambiguity states** (5 towers × 3 extra receivers × 2 signals), each with a
**100 m prior**. In the degenerate baseline these loosely-constrained nuisance states project into the
radial↔clock null space and inflate it. The single receiver at the CoM (lever arm [0;0;0]) adds no
attitude/ambiguity states, so it is genuinely **better-conditioned** — the user's "that should not make
a difference" is, in this degenerate regime, incorrect: it does, and legitimately.

- Filter's own radial 1σ grows `sig_rad` 1.58 → 4.30 m; true radial 1.95 → 11.98 m.
- **No implementation defect** (all verified): lever arm applied identically to truth and model (`MeasurementModel.m:100-124`); each carrier row gets exactly ONE ambiguity column, no double-count (`CarrierMeasurementBuilder.m:156,314,322-324`); process noise per-axis, nReceivers-independent (`buildQ_ 767-809`); ambiguity `initialSigma_m=100` (`masterConfig.m:185`).
- **It flips sign once real radial observability exists:** S6R4 (ISL aiding) baseline rad = **0.012 m**, and with all errors on, R4 (2.62 m) < R1 (3.82 m). More antennas *help* when the radial mode is actually observable; they *hurt* only in the pristine, fully-degenerate baseline.
- **Corrections (verifier):** (1) R1 attitude states are *frozen* (Q×1e-20), not absent — immaterial (±1 m lever × ~0.1–2° → mm radial). (2) "over-counts info → overconfident" is imprecise: sigma *grows*; NEES crosses 1 because the true error grows faster than the (growing) sigma. (3) per-antenna float ambiguities are physically *mandated* (one integer per antenna), not an over-rich choice.
- **Lever for improvement (not a fix):** the pathology is the null space, so the cures are the ones that break the degeneracy — two-way time transfer, ISL, ambiguity resolution/tighter priors — not a code change.

## Q4 — Is default↔realism only sigma/noise/bias?  ✅ CONFIRMED (mostly, but 2 structural)

**Answer.** No — mostly sigma (R/Q) and injected-truth magnitude changes, but **two are genuinely
structural**: (1) **C/N0 code weighting** replaces a constant R with an elevation/C-N0-dependent R
(different functional form of R); (2) **luni-solar + SRP** adds new force terms to *both* the truth and
the EKF equations of motion (different dynamics). The **clock template is NOT structural** — default
and realism both use `CESIUM1` with the identical 5-coefficient IEEE-1139 power-law PSD state model;
only the h-coefficient magnitudes change (a noise-strength rescale).

- Sigma-only: towerProductSigma, honestFloors, islProductSigma. Injected-truth: multipath(coloredGM), hardwareDelay, PCV, survey, dcb, relativity, eop, tide, interAntennaCarrierBias.
- `realismGradeConfig.m:30-34` (clock), `:92-104` (luni-solar both sides + SNC 5e-6→1e-6); `MeasurementModelUtils.m:149` (constant) vs `:159-174` (cn0); `ConfigFactory` clock templates share the identical field set.
- **Correction (verifier):** "C/N0 = structural" is borderline (it changes the functional form of R, not a state/observable/dynamics) — fair but a slightly strong word.

## Q5 — Does the ground segment have a hardware bias?  ✅ CONFIRMED (config-choice)

**Answer.** Hardware group-delay is a **ground/tower** effect only (`ErrorChain.hardwareDelay_` is keyed
per-tower `towerIds`); there is **no space-receiver hardware delay** in this path. In **both** grades the
*deterministic* group delay is **zero** (`truth.default_m = model.default_m = 0`). Default → exactly 0.
Realism → a **matched white** residual (σ = 0.5 m/tower, injected on truth *and* carried in R) — honest
noise, **not a constant bias**. So there is **no constant per-tower group-delay bias** anywhere.

- `ErrorChain.m:621,650`; `masterConfig.m:991-1002` (default all zero); `realismGradeConfig.m:57-61` (σ=0.5 + residualStochastic, `default_m` untouched → stays 0); `expandEnableToggles.m:15-18` (slaves truth=model).
- Other ground systematics: tower clock products = R-only σ inflation (clocks are perfectCorrection/perfectTruth, no truth bias); DCB inert on the raw single-frequency code path; survey matched → ~0 residual; **only tide/EOP** tower displacement is genuinely truth-only.
- **If you want a real ground hardware bias:** it is not modelled — set `errors.hardwareDelay.truth.default_m` (or a per-tower array) to inject a constant group delay.

## Q6 — Compare true clock vs corrected RX clock  ✅ CONFIRMED (plotted)

Delivered: `rxClock_truth_vs_corrected.png/pdf`. Accessors verified: `getRxClockBiasTrue`→`tr_cbs_`
(**seconds**), `getClockBiasErrors`→`er_cb_` (**metres** = estimate−truth, `SimulationDataStore.m:746`),
`getTimeVector`. Reconstruction `estimate = truth·c + error` is valid (the unit trap is the c-scale of
truth). The quiet-truth / wandering-estimate whose metre-residual = radial RMS is the degeneracy, not an
extraction error. **Caveats:** default and realism are *different physical clocks* (legacy vs jowTable2p1)
— don't overlay them as one truth (the plot keeps them in separate columns). `tr_cbm_` (truth already in
metres) exists and would avoid the manual c-scale.

## Q7 — Can an IMU be added for attitude?  ✅ feasible-design (high confidence)

**Answer.** Yes — the codebase is ~80% of the way there and your proposed architecture (gyro absorbs
fast changes; receivers still provide absolute attitude) is exactly right. The EKF state **already
carries body angular rate** `omega` (x(10:12)) alongside attitude (x(7:9)), but `omega` has **no
observation** — it is a constant-rate random walk (`omg_new = omg`, `ReverseGNSSEKF.m:309`) and is frozen
in the headline scenario (`estimateAngularRate=false`, `masterConfig.m:375`). A gyro supplies the
missing rate observable → a standard **MEKF**, not a redesign.

Design sketch:
- **(a) States:** add 3 gyro-bias states `b_g` (random-walk); keep the quaternion nominal (`masterConfig.m:197`).
- **(b) Integration:** strapdown *control input* — propagate with `ω = ω_meas − b_g` via the existing `propagateQuatBodyRate` (`ReverseGNSSEKF.m:298`); error-state F gets `F(θ,b_g) = −dt·I`, Q gets ARW on attitude + RRW on bias. (Alt: keep `omega`, add a direct `z = ω` measurement row.)
- **(c) Benefit:** smoother attitude, absorbs slews the constant-rate model can't, and an **independent** attitude source that weakens the R4 attitude↔position/lever-arm coupling (the attitude analogue of how two-way breaks radial↔clock); gives R1 the rate info it currently lacks.
- **(d) Touchpoints:** `masterConfig` estimator block (194-391) new `cfg.estimator.imu.*`; `ReverseGNSSEKF` `buildStateMap_/buildF_/buildQ_/propagate:294-309`; a truth `GyroModel` mirroring `ClockModel` wired into `ReverseGNSSSimulation:279`; `SimulationDataStore` logging + attitude-NEES.
- **(e) Risks:** gyro bias is unobservable without an external attitude source (R1 would dead-reckon/drift); it does **not** touch the radial↔clock degeneracy (position stays corr=−1); the truth must inject honest ARW/bias or it's an oracle (the same sameAsTruth trap as PCO/atmosphere); keep the quaternion path (Euler is gimbal-singular); default OFF for golden safety.

---

*Method: 7 investigators + 5 adversarial verifiers (xhigh on Q3), 613k tokens, all file:line-grounded and CSV-checked. Verdicts: all CONFIRMED with only minor citation/wording corrections noted inline.*
