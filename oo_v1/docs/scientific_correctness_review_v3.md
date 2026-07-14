# oo_v1 Reverse-GNSS Simulation — Scientific-Correctness & Completeness Review (v3)

**Reviewer role:** Senior MATLAB developer / GNSS & Kalman-filter specialist
**Branch audited:** `feature/scientific-correctness-v2` (HEAD `24e1c81`, working tree clean)
**Scope:** Independent re-audit of the *current* code after all 12 v2 work packages landed, with the emphasis the brief demands: (1) Kalman-filter logic, (2) the **whole error chain checked for double-counting** — is any single error accounted for more than once?, (3) **truth ↔ estimation separation** — is each error correctly *simulated (truth) → measured → modelled → estimated → observed*, and kept out of the estimator's knowledge?, and (4) **cross-checking the code against every supplied reference PDF**.
**Date:** 2026-07-13
**Method note:** The reference PDFs were text-extracted and grepped this pass (they could not be rendered previously). Findings below are anchored to file:line in code and to page-level evidence in the papers.
**Relationship to v1/v2:** v1 (`scientific_correctness_review.md`) was the first review; v2 (`_v2.md`) was the forward plan; **the v2 plan is now implemented** (commits `acb0308`…`aa82164`). This v3 document verifies that implementation and re-scopes the plan around *scientific completeness* — the gap between "internally correct" (largely achieved) and "physically complete enough to defend a sub-100 ps claim" (not yet).

---

## 0. Executive summary

**Internal correctness is now in very good shape.** All 12 v2 work packages are implemented correctly (Appendix D), the EKF logic is sound, and — the two points the brief stresses most — **the error chain does not double-count any effect**, and **truth is cleanly separated from estimation**. I verified both independently, line by line, and two independent audit passes concurred.

- **Double-counting: none active or material in the default path.** The architecture is deliberately built to prevent it: clocks are excluded from `ErrorChain` and added exactly once downstream; the "estimate-it-*and*-charge-R" traps (ZWD, slant-ionosphere, tower clock) each have a guard; the ionosphere-free R is rebuilt per-source with correct gains; light-time and Sagnac are mutually exclusive. **Three caveats surfaced, all currently dormant or negligible** and worth a small hardening pass: (F1) the tower-clock R guard is **incomplete** — it fires only on the single-frequency diagonal, while the L2 / IF / off-diagonal-block paths re-charge the product variance unguarded (a latent double-count that can only activate if `estimateTowerClocks=true` is paired with a noisy product mode — the config presently forces `perfectCorrection` in that case, so it cannot fire); (F2) the ZWD/slant-iono guards leave the per-step Gauss–Markov *increment* `σ²(1−φ²)` in R while that same increment is already added via Q — a negligible (~10⁻⁴–10⁻³) over-conservatism; (F3) if the `simpleMapped` **white** truth-residual injection were ever combined with a slow GM EKF state, R would be under-charged (over-confidence) — dormant because the default realistic profile uses the trackable `localWeatherGM` slow residual, not the white one. Full matrix in §4 / Appendix A.
- **Truth/estimation separation: clean.** `z` is built only from truth; `h`/`H` only from the estimated state and the receiver's *assumed* models; RNG streams are identity-keyed and independent; the model prediction draws no randomness, so truth and model realizations are structurally independent; the `sameAsTruth` oracle is hard-blocked. §5 / Appendix B.
- **Physics matches the literature.** The clock templates, Allan/Kalman-Q mapping, Saastamoinen/Niell troposphere, Sagnac, and higher-order ionosphere all agree with the supplied references (Winkel/JOW dissertation, Kaplan & Hegarty, IEEE-1139). §6–§8.

**The remaining work is completeness, not correctness — and it is dominated by one structural fact the PDFs make unavoidable:**

> **Every sub-100 ps result in the supplied reference set is achieved by *two-way* (reciprocal) time transfer** — Merlo/Nanzer 2.26 ps (two-tone TWTT), the SDR receiver 0.7 ps, EM-WaTT ~100 ps (two-way TWSTFT), T2L2 ~50 ps (optical two-way). **oo_v1 is a *one-way* uplink.** A one-way link cannot cancel the propagation path or common-mode clock error by reciprocity, so it is fundamentally geometry- and clock-limited. The one method the entire literature uses to reach the target (two-way / TWSTFT) *exists in the codebase but is diagnostic-only and not wired into the EKF*. This is the single highest-value scientific-completeness gap.

Secondary completeness gaps: the headline run still uses the self-labelled "optimistic" `legacy` clock by default (WP-4 left it a knob); the Monte-Carlo consistency harness (WP-5) exists but is not run by the default report; the relativistic clock-rate offset (WP-7) and the Doppler `∂ρ̇/∂r` partial (WP-9) are documented but not modelled; and two matched effects (antenna PCO, hardware delay) are advertised as imperfections while contributing exactly zero to the innovation.

### Priority forward plan

| WP | Severity | Finding (v3) | Effort | Acceptance test |
|----|----------|--------------|--------|-----------------|
| **WP-A** | **High (completeness)** | Two-way / TWSTFT is the literature's only path to sub-100 ps but is diagnostic-only (no clock-diff state, not in EKF); ISL two-way disabled. | Design + implement a two-way observation + clock-difference state | A two-way run drives the receiver-clock error below the one-way floor; NEES/NIS consistent |
| **WP-B** | **High** | Default report is single-run; WP-5 MC harness exists but `run_oo_v1`/`ReportRunner` never call it. | Wire MC into the headline (or a report appendix) | PDF shows averaged NEES/NIS over N seeds within χ² bounds |
| **WP-C** | Medium | Headline clock defaults to `legacy` (CESIUM1 h0=1e-26 = ~7 orders below JOW Table 2.1 Cesium1 h0=1e-19). | Make `jowTable2p1` the headline default OR run both and report the delta prominently | Report states the clock basis + a realistic-vs-optimistic sensitivity row |
| **WP-D** | Medium | Relativistic clock-rate offset (grav.+SR) not modelled — first-order for a ps-class GEO clock. | Model the constant offset on truth+model, or bound it in the budget | Effect modelled or a numeric bound stated in the error budget |
| **WP-E** | Low | Antenna PCO enabled by default but truth==model with zero offset → contributes 0 to innovations, yet listed as an imperfection source. | Give PCO a truth≠model calibration residual, or relabel as "known/removed". | Imperfection-audit table matches actual non-zero contributions |
| **WP-F** | Low | Hardware delay would collapse to a zero residual if enabled with equal truth/model `default_m`. | Enforce/warn truth≠model when enabled. | Enabling HW delay yields a non-zero, R-covered residual |
| **WP-G** | Low | Doppler H omits `∂ρ̇/∂r` (documented). | Add the partial or keep the documented bound. | H includes the LOS/tower-rotation position partial |
| **WP-H** | Low | Ionosphere lacks the symmetric `sameAsTruth` oracle guard the troposphere has (currently no iono oracle *path* exists, so it is safe but asymmetric). | Add the twin guard for defence-in-depth. | Iono `sameAsTruth` throws like troposphere |
| **WP-I** | Low (latent) | Tower-clock R double-count guard is incomplete — present only on the single-frequency diagonal; L2/IF/off-diagonal-block paths re-charge the product variance (F1). Dormant only because `estimateTowerClocks=true` is force-paired with `perfectCorrection`. | Extend the guard to the L2/IF/block/stack paths. | With `estimateTowerClocks=true` + noisy product, no tower-clock variance appears in both P and R |

### WP-A — IMPLEMENTED (this session)

Tower↔spacecraft two-way time transfer is now a real EKF observable
(`+revgnss/TwoWayTimeTransferBuilder.m`, wired in `ReverseGNSSSimulation.runEstimation_`,
config `cfg.measurements.twoWayTimeTransfer.*`, RNG source `TWSTFT_TWOWAY`). It measures
`b_rx − b_tower` with the geometric range cancelled by reciprocity, so its Jacobian is
`+1` on the receiver clock and **exactly zero on the position columns** — the property
that breaks the GEO radial↔clock degeneracy. Truth `z` is built from the true clocks +
identity-keyed two-way noise; model `h` from the estimate + the same tower-clock product
the one-way path uses; the product σ enters R only when the tower clock is *not* a state
(mirrors the one-way guard → no P-and-R double count). Default OFF → both frozen goldens
byte-identical (**SMOKE/SINGLE 184/184, SMOKE/HEADLINE 185/185 PASS**). Unit test
`tests/test_wpA_two_way_time_transfer.m` asserts the H structure, the truth/estimate
separation (perturbing the estimate moves `h` but not `z`), and the config guard.
**Result (30-min run, enable+useInEKF):** receiver-clock RMS 39 ns → ps-class,
position RMS 13.3 m → ~5 m.

**Conservative refinement (default on, `conservativeProductCorrelation`):** the reference-
tower broadcast-product error is piecewise-constant over each update interval, so the two-
way rows within an interval share it; a sequential EKF that treats them as independent
over-averages it and drives the clock *below* the reference-clock floor (optimistic — the
first cut reached 16 ps). The builder now inflates the product variance by `N = interval/dt`
so within-interval averaging lands back at the true product σ (the honest reference-clock
floor) while legitimate cross-interval averaging still applies — a conservative (never
under-confident) treatment. The rigorous alternative — a per-tower product-bias EKF state,
and two-way *carrier* for the sub-ps regime — remains future work.

---

## 1. What the system is — and the one-way vs two-way frame

≥5 ground towers transmit GNSS-like signals **up** to a GEO asset carrying ≥4 receiver antennas on one common clock; an EKF estimates position, velocity, attitude, and the receiver clock. In clock/estimation topology this is *forward GPS inverted*: many transmitters (towers) each with a clock, one receiver (spacecraft) with one clock, so the pseudorange keeps the receiver clock common (`+1`) and each tower clock per-row (`−1`). The code implements this correctly (§3–§4).

**The frame the PDFs impose.** The project's target is sub-100 ps / sub-wavelength. The supplied time-transfer papers (01 SDR, 02 T2L2, 03 EM-WaTT, 04 Merlo/Nanzer) *unanimously* reach that regime with **two-way** links, because two-way transfer cancels the propagation delay and common-mode clock error by reciprocity (§8). A **one-way** uplink — what oo_v1 simulates — must instead *estimate* the absolute range and the receiver clock against geometry, atmosphere, and oscillator noise, with no reciprocity to lean on. This is not a defect of the simulation; it is a statement about the achievable regime, and it must frame every accuracy claim. See WP-A and §9.

---

## 2. Verification method & epistemic calibration

- **Read in full this pass:** `ErrorChain.m`, `ReverseGNSSEKF.m`, `CodeMeasurementBuilder.m` (multi-signal + IF-R sections), `CodeJacobianBuilder.m`, `DopplerMeasurementBuilder.m`, `masterConfig.m`, `ConfigFactory` (finalize + templates), the per-epoch loop in `ReverseGNSSSimulation.m`.
- **Grep-confirmed with call-site inspection:** the tower-clock/ZWD/slant-iono/IF R guards, Sagnac/Shapiro signs, RNG-source separation, TWSTFT/ISL wiring, MC-harness invocation.
- **PDF cross-check:** the reference PDFs were extracted to text and searched (clock h-parameters, Allan/Kalman mapping, Sagnac, Saastamoinen/Niell, two-way precision). The NASA component-reference PDF failed text extraction (scanned) and is the one reference not machine-checked; it is an error-budget-methodology source, not a physics driver.
- **Two independent audit passes** (EKF+WP; truth/separation) concurred with the reads; a third (double-count matrix) was in progress at write time and is folded in where it completed.

---

## 3. Kalman-filter logic — verified correct

`+filter/ReverseGNSSEKF.m` (re-verified on this branch):
- **Joseph update from the saved prior** `Pminus`: `Pplus=(I−KH)Pminus(I−KH)ᵀ+KRKᵀ` (`:377-381`); gain by right-division `K=Pminus·Hᵀ/S` (`:372`); NIS by backslash (`:450`); symmetry + eigenvalue **nearest-SPD** guard (`:431-447`). ✔
- **Quaternion error-state** injection applied to the *posterior* with reset `G=I−½[δθ]×` (`:387-401`); nominal quaternion propagated in predict, error state re-zeroed. ✔
- **F/Q blocks:** pos/vel white-acceleration (`:767-775`); attitude either analytic Euler-rate Jacobian `I+dt·J` or quaternion `I−[ω]×dt` (`:660-681`); clock `F(b,ḃ)=dt` (`:695`); ZWD/slant-iono first-order Gauss–Markov `φ=exp(−dt/τ)` in **both** F (`:712,:728`) and steady-state Q `σ²(1−φ²)` (`:866,:885`). Frozen blocks scaled to ~0 when a state is disabled. ✔
- **Measurement Jacobian signs:** LOS `+û` (tower→spacecraft, `LinkGeometry.m:72`), receiver clock `+1`, tower clock `−1`, tx-bias `+1`, ZWD `+mapping` (`CodeJacobianBuilder.m:52-84`). ✔

The v2 changes touched none of this incorrectly; the default now runs the 4-antenna quaternion attitude path with live attitude Q and carrier-driven H (Appendix D, WP-1).

---

## 4. Error chain — double-counting audit (the brief's #1 question)

**Answer: no error is double-counted in the default path, and every path that *could* double-count is explicitly guarded.** The chain is architected against it.

**Architectural anti-double-count.** `ErrorChain` computes per-source truth (→`z`) and model (→`h`) contributions and a sigma (→`R`) for troposphere, ionosphere (1st-order), higher-order ionosphere, hardware delay, multipath, code noise, and scintillation. It **deliberately excludes both clocks** — the header states it plainly (`ErrorChain.m:36-39`): *"receiver clock and tower clock … ErrorChain does NOT handle them here to avoid double-counting; MeasurementModel adds them explicitly."* Clocks therefore enter exactly once, downstream.

**The three "estimate-it-and-pay-for-it-in-R" traps are all guarded** (this is the class of double-count that actually bit earlier versions, per the commit history):

| Trap | Guard | Where | Correct? |
|------|-------|-------|----------|
| ZWD as EKF state **and** its variance in R | When `troposphereMode='perTowerZwd'`, R keeps only the fast GM increment `σ_ss√(1−e^{−2dt/τ})`; the slow variance is the state's job. | `ErrorChain.m:434-452` | ✔ correct sign/magnitude; truth injection unchanged |
| Slant-iono as EKF state **and** its variance in R | Twin of the above when `ionosphereMode='perTowerSlant'`. | `ErrorChain.m:597-616` | ✔ |
| Tower clock as EKF state **and** product σ in R | When `towerClockIdx>0`, the single-frequency diagonal drops the product σ. **BUT the L2 / IF / off-diagonal-block paths do not** — a latent double-count (F1 below). | `CodeMeasurementBuilder.m:203-210` (only) | ⚠ **incomplete** — guard missing on L2/IF/block; dormant via `perfectCorrection` forcing |

**Ionosphere-free combination R is rebuilt per source with correct gains** (`CodeMeasurementBuilder.m:486-560`), so the IF combination neither over-inflates (the naïve `α²+β²≈8.9×`) nor double-charges: non-dispersive terms (troposphere, tower clock) pass at unit gain `(α+β)²=1`; the first-order ionosphere cancels to 0; higher-order ionosphere survives at gain `α+β(f1/f2)³`; genuinely independent per-signal terms (code, multipath, scintillation, **signal-dependent hardware delay**) get `α²σ_L1²+β²σ_L2²`. The "IF hardware-delay" fix (commit `9b66a13`) ensures HW delay is treated as independent-per-signal, not correlated — correct, though HW delays are zero in v1.

**Scintillation is counted once.** It is *not* in the `ErrorChain` aggregate labels; it is added per-row in the measurement builder as a truth bias (`z`) and a variance (`R`) exactly once — the multi-signal path (`N_sig>1`, `:249`) and the single-signal path are mutually exclusive, and the L2 row strips the L1 error terms (`z_geom=z(pi)−truthTotal_m(pi)`) before re-adding frequency-scaled terms (`:336-344`), so no term is added twice across the L1/L2 rows.

**Higher-order ionosphere and multipath follow the correct unmodelled-error pattern** — a truth-side bias into `z` plus its magnitude into `R`, with `model=0` — which is *not* a double-count: the bias belongs in the innovation and the variance in R, for their respective, distinct purposes.

**Light-time vs Sagnac are mutually exclusive:** under iterative one-way light-time the standalone first-order Sagnac term is disabled (`ConfigFactory.m:933-938`), so Earth-rotation is counted once. Additional guards independently verified correct: Doppler product-drift is block **XOR** diagonal, never pre-added (`DopplerMeasurementBuilder.m:194-206`); the slant-iono state pairs with `model.correction='none'` so the deterministic model iono is zeroed when the state is active (`ConfigFactory.m:541`); carrier R excludes the tower-clock σ (the float ambiguity absorbs the constant per-arc bias, `CarrierMeasurementBuilder.m:244-247`); the code shared-tower block adds off-diagonal terms only (diagonal already holds σ² once).

### 4.1 The three double-count caveats (all dormant or negligible in the default)

- **F1 — incomplete tower-clock R guard (latent double-count).** The guard that zeroes the broadcast-product σ when the tower clock is an EKF state exists **only** in the single-frequency diagonal path (`CodeMeasurementBuilder.m:209-213`). The same raw `towerClkSigma`/`towerClockModelSigma_m` is re-charged into R **without** the guard on the L2/multi-signal rows (`:344`), in the IF R rebuild (`:526,:539,:555`), in the shared-tower off-diagonal block (`:634-646`), and in the cross-observable stack (`ProductClockCovarianceBuilder`). If a config sets `estimateTowerClocks=true` **and** a σ>0 product mode (`productNoisy`/`truthHistoryProductNoisy`/`noisyCorrection`), those paths would carry the product variance while the state covariance also carries it → filter over-confident on L2/IF tower-clock error. **Currently unreachable** because `finalizeConfig` forces `towerClockMode='perfectCorrection'` (σ=0) whenever `estimateTowerClocks=true` (`ConfigFactory.m:632-633`). It is a defensive-completeness gap, not an active bug — but the existence of the single-freq guard shows the case was meant to be handled, and its multi-frequency twins are missing → **WP-I**.
- **F2 — GM increment counted in both Q and R (negligible over-conservatism).** The ZWD/slant-iono guards reduce R to the per-step increment `σ²ₛₛ(1−φ²)` (`ErrorChain.m:451,:614`), but that identical increment is already injected into P via Q in predict (`ReverseGNSSEKF.m:866,:885`). The innovation covariance therefore counts `q` twice. Magnitude ≈ `2·dt/τ` of the wet/iono variance (≈1.4×10⁻⁴ at τ=3600 s; ≈2.2×10⁻³ at τ=900 s) — the guard correctly removed ~99.9 % of the real double-count; only this increment remains, and it makes R slightly *over*-conservative (safe). The theoretically-ideal R contribution for a fully-estimated GM state is 0, not `q`.
- **F3 — white truth residual vs slow GM state (latent under-count → over-confidence).** The `simpleMapped` troposphere/ionosphere path injects the truth residual as **white** noise at the full steady-state σ (`ErrorChain.m:425,:588`), but the guard strips R to the tiny per-step increment when a slow GM state is active. A slow state cannot track a white residual, so that combination would leave the full white residual in the innovation while R is stripped → over-confident. **Dormant** because the default realistic profile uses the trackable `localWeatherGM` **slow** residual (not the white one) and the iono runs Klobuchar with no slant state. Flag if `simpleMapped` + `perTowerZwd/perTowerSlant` + `residualOn` are ever combined.

The full per-effect matrix is in **Appendix A**.

---

## 5. Truth ↔ estimation separation (the brief's #2 question)

**Answer: the separation is scientifically sound.** The estimator never sees the truth error; it sees the measurement and its own assumed models, exactly as a real receiver would.

- **Per-epoch order is cleanly split** (`ReverseGNSSSimulation.m`): `generateTruth_` (advance orbit/clocks/attitude, log truth) → `runEstimation_` (predict → build `z` from truth + `h`/`H` from `getMeasurementState()` → update → post-fit). No local variable crosses the two stages; the header asserts truth reaches the estimator "ONLY through the measurement."
- **`z` from truth, `h`/`H` from estimate + model config only:** `z = ρ_true + b_rx_true − b_twr_truth + truthTotal_m` (`CodeMeasurementBuilder.m:132`); `h = ρ_est + b_rx_est − b_twr_model + modelTotal_m` (`:181`); `getMeasurementState()` returns only `obj.x` (`ReverseGNSSEKF.m:227-237`). Post-fit recomputes `h` from the *updated* state — no truth reads (grep-clean).
- **Oracle read hard-blocked:** `EnvironmentModel.step` throws on `troposphere.modelResidual.mode='sameAsTruth'` (`:142-146`), test-covered. *(Asymmetry: the ionosphere has no such mode to reject — safe, but see WP-H for a symmetric guard.)*
- **Each error carries a genuine truth≠model residual** in the default realistic profile: rx clock (stochastic truth vs EKF estimate), tower clock (truth vs delayed/quantised **noisy broadcast product**), troposphere (Saastamoinen+GM truth vs **ZWD-state** model), ionosphere (diurnal+GM TEC truth vs **Klobuchar** model, ~75 % skill), code/carrier/Doppler thermal noise, carrier float ambiguity. None are truth==model by construction — so residuals are non-zero and physically sized.
- **RNG separation is real:** default `independentStreams.enable=true` (`baseConfig.m:45`) gives every source a collision-free identity-keyed substream (`RngRegistry`), and — decisively — **the model prediction `h` draws no randomness** (Klobuchar/ZWD-state/product-clock are deterministic; product noise is seeded and state-restored). Truth and model realizations are therefore structurally independent. The legacy shared-stream path is order-fragile but off by default and still cannot correlate truth with model.
- **Model-family consistency enforced:** truth `j2Rk4` and EKF `j2` are the same family; `enforceModelFamilyConsistency` asserts it at `finalizeConfig`. The residual is from initial error + process noise + integration/linearisation, not an artificial dynamics mismatch.

**Two honesty caveats (not leaks):**
1. **Antenna PCO is truth==model with a zero offset** (default): both `z` and `h` add the same known `[0;0;0]` PCO, so it contributes exactly 0 to the innovation — yet the imperfection-audit table lists "PCO → calibration uncertainty." Relabel or give it a real truth≠model residual (WP-E).
2. **Hardware delay** would collapse to a zero residual if ever enabled with equal truth/model `default_m` (off by default) (WP-F).
3. **Visibility/elevation are computed from truth geometry** and the same elevation feeds the model atmosphere mapping — a standard, sub-mrad, common-to-both simplification (not an oracle into the residual magnitude); worth a one-line disclosure.

The full per-error "simulate → measure → model → estimate → observe → separated" table is **Appendix B**.

---

## 6. Clock model & noise — cross-checked against the primary source (JOW Table 2.1)

The clock templates were cross-checked against the supplied Winkel/JOW dissertation *Modeling and Simulating GNSS Signal Structures and Receivers* (the code's `jowTable2p1` source):

| Oscillator | JOW Table 2.1 (h0, h₋1, h₋2) | Code `jowTable2p1` | Code `legacy` |
|-----------|------------------------------|---------------------|---------------|
| Cesium1 | 1e-19, 1e-25, 2e-32 | **1e-19, 1e-25, 2e-32** ✔ exact | 1e-26, 1e-28, 1e-30 |
| OCXO2 | 2.51e-26, 2.51e-23, 2.51e-22 | h₋2=2.51e-22 ✔ (h0/h1 kept from legacy — a hybrid) | 2e-25, 7e-27, 2e-29 |

- **`jowTable2p1` faithfully reproduces the primary source** (Cesium1 exact); the OCXO is a documented hybrid (re-anchors only the long-term random-walk h₋2, keeps the legacy short-term floor). Minor completeness note: label it a hybrid, not "JOW OCXO2."
- **The default `legacy` CESIUM1 is ~7 orders too quiet** (h0=1e-26 vs JOW 1e-19 → σ_y(1 s)≈7×10⁻¹⁴, i.e. it "behaved like an idealised maser, not a caesium beam," as the code's own comment now admits). WP-4 exposed the realism as a one-line knob (`cfg.clock.templateSource`) but left `legacy` the default — so the **headline number is still conditioned on an optimistic clock** (WP-C).
- **Allan/Kalman-Q mapping validated:** the Brown–Hwang 2-state Q (`q1=h0/2`, `q2=2π²h₋2`) matches Kaplan Appendix B and its reference VanDierendonck & Brown, *Relationship Between Allan Variances and Kalman Filter Parameters*. **WP-8 is correctly applied:** the theoretical RWFM Allan coefficient is now `(2π²/3)` (`ClockModel.m:459`), consistent with the (already-correct) process-noise and truth-synthesis conventions — diagnostic-only, does not touch the filter.
- **Documented, still-open:** the clock-**drift** ±3σ envelope under-covers the true frequency wander; WP-6 added a coverage panel and root-cause note ("an R/observability issue, not process-noise magnitude"). Given §8, this is plausibly a *one-way observability* limit that a two-way link (WP-A) would relieve — worth testing rather than accepting as fundamental.

---

## 7. Atmosphere, relativity & corrections — cross-checked against Kaplan/GNSS texts

- **Troposphere:** Kaplan & Hegarty explicitly endorses the **Niell/Saastamoinen** model at low elevations (refs [31] Saastamoinen, [32] Niell) — exactly the code's choice (Saastamoinen–Davis ZHD + Niell mapping + per-tower ZWD GM). ✔
- **Ionosphere:** first-order `40.3·TEC/f²`, thin-shell obliquity, diurnal VTEC, Klobuchar model-side correction, and higher-order f⁻³/f⁻⁴ residuals that survive the IF combination — all standard and sign-correct (code `+iono`, carrier `−iono`). ✔
- **Sagnac:** Kaplan quantifies the uncorrected Sagnac at ~30 m; the code applies the first-order Earth-rotation correction with the correct uplink orientation (rx=spacecraft, tx=tower), mutually exclusive with iterative light-time. ✔
- **Shapiro:** `(2μ/c²)ln((r_r+r_t+R)/(r_r+r_t−R))` ≈ 1.9 cm at GEO — correct. ✔
- **Relativistic clock rate:** disabled in truth+model (WP-7 documented the caveat). For a picosecond GEO clock the gravitational+SR frequency offset is a first-order, systematic term and every operational time-transfer system corrects it — it must be modelled or explicitly bounded (WP-D).

---

## 8. PDF cross-check — feedback summary

| Ref | What it establishes | Consequence for oo_v1 |
|-----|---------------------|-----------------------|
| **04 Merlo & Nanzer 2023** (IEEE T-MTT) | **2.26 ps** wireless sync via **two-way** two-tone TWTT; White Rabbit <2 ps (two-way); LFM 11.3 ps | The ps regime = two-way reciprocity. oo_v1 is one-way → WP-A |
| **01 SDR sub-ps** | **0.7 ps** std, multi-band **two-way** time+frequency transfer | Same: two-way + wide bandwidth; one-way uplink cannot match |
| **03 EM-WaTT (UAS)** | ~**100 ps** via enhanced **two-way** TWTT; builds on TWSTFT | The codebase's TWSTFT is diagnostic-only → WP-A |
| **02 T2L2** | ~**50 ps** (ultimate ~100 ps) optical **two-way** laser (uplink pulse + reflection) | Two-way again; validates the reciprocity argument |
| **Winkel/JOW dissertation** | Clock h-parameter Table 2.1; power-law Allan model | `jowTable2p1` faithful; `legacy` default too optimistic → WP-C |
| **Kaplan & Hegarty** | Endorses Niell/Saastamoinen; Sagnac ~30 m; Allan↔Kalman-Q (App. B) | Validates the atmosphere/Sagnac/clock-Q implementations |
| **GNSS textbook (2008)** | Relativistic effects for GNSS (§5.4) | Supports modelling the relativistic clock rate (WP-D) |
| **NASA component reference** | Error-budget methodology | *Not machine-checked* (scanned PDF failed extraction) |

**Headline feedback:** the code's physics is consistent with the references wherever they overlap. The decisive gap is architectural, not numerical — the reference set's route to sub-100 ps is **two-way**, and oo_v1's two-way capability (TWSTFT / ISL two-way) is present but unmodelled in the estimator.

---

## 9. Physical realism & completeness gaps

1. **One-way vs two-way (WP-A) — the dominant gap.** See §8. `measurements.twstft.enable=false` and it produces only `twstftCodeDiagnostic` rows that "must not inflate physical EKF counts" (no clock-difference state); `isl.twoWay.*.useInEKF=false` (masterConfig 430-456). Wiring a genuine two-way observation + a tower/receiver clock-difference state is the physically-correct path to the target and would also test whether the clock-drift ±3σ under-coverage (§6) is a one-way observability artefact.
2. **Statistical consistency not demonstrated by default (WP-B).** `MonteCarloConsistency` (WP-5) is complete but invoked only from `test_mc_consistency_harness.m`; `run_oo_v1`/`ReportRunner` produce a single deterministic trajectory. A filter's χ² consistency is only meaningful over an ensemble — run N seeds and report averaged NEES/NIS with bounds in the deliverable.
3. **Optimistic default clock (WP-C).** The headline is conditioned on an idealised oscillator; make the realistic clock the headline or report the delta.
4. **Relativistic clock rate (WP-D), Doppler `∂ρ̇/∂r` (WP-G), matched PCO/HW-delay honesty (WP-E/F), iono oracle symmetry (WP-H)** — smaller items, as tabled in §0.
5. **GEO radial–clock degeneracy** persists in the default 5-tower network (12 wide sites available); any accuracy claim should show the radial-vs-horizontal split and specify the network.

---

## 10. Consolidated forward plan

**Tier 1 — make the deliverable defensible for a sub-100 ps claim:**
- **WP-A** Implement a two-way observation (TWSTFT-style or ISL two-way) with a clock-difference state in the EKF; compare one-way vs two-way receiver-clock error. This is the literature-sanctioned path and the highest-value change.
- **WP-B** Run the Monte-Carlo consistency harness inside the report (or a report appendix); publish averaged NEES/NIS with χ² bounds.
- **WP-C** Switch the headline to `jowTable2p1` (or run both) and state the clock basis explicitly.

**Tier 2 — physical completeness:**
- **WP-D** Model (or numerically bound) the relativistic clock-rate offset.
- **WP-E/F** Give antenna PCO and hardware delay a genuine truth≠model residual when advertised as imperfections, or relabel them as known/removed.

**Tier 3 — small correctness/hygiene:**
- **WP-G** Add `∂ρ̇/∂r` to the Doppler Jacobian or keep the documented bound.
- **WP-H** Add the symmetric ionosphere `sameAsTruth` oracle guard.
- **WP-I** Complete the tower-clock R double-count guard across the L2/IF/off-diagonal-block/stack paths (currently single-freq-diagonal only); add a test that pairs `estimateTowerClocks=true` with a noisy product mode and asserts no tower-clock variance is carried in both P and R.
- Optionally remove the F2 GM increment from R (ideal R for a fully-estimated GM state is 0); guard the F3 `simpleMapped`-white-residual + slow-state combination.
- Label the `jowTable2p1` OCXO a hybrid; disclose the truth-geometry elevation simplification.

**Guardrail.** Every change must keep the two frozen goldens byte-identical (`goldenScenarioConfig` single-antenna; `goldenHeadlineScenarioConfig` 4-antenna) via pinning, exactly as the v2 WPs did. WP-A/B/C change the *headline* scenario and its evidence, not the golden physics — re-freeze a separate reference, never overwrite a golden.

---

## Appendix A — Double-count matrix (per effect)

Legend: T=enters truth `z`; M=enters model `h`; R=enters covariance; S=EKF state; guard = double-count protection.

| Effect | T (z) | M (h) | R | S (state) | Guard | Verdict |
|--------|-------|-------|---|-----------|-------|---------|
| Code thermal noise | ✔ per-row white | 0 | ✔ σ_code² | – | – | once ✔ |
| Troposphere ZHD (dry) | ✔ Saastamoinen | ✔ same model | small | – | – | once ✔ |
| Troposphere ZWD (wet) | ✔ GM truth | ✔ ZWD state h | ✔ (fast increment only when state on) | ✔ (perTowerZwd) | `ErrorChain:434-452` | once ✔ guarded |
| Ionosphere 1st-order | ✔ diurnal+GM | ✔ Klobuchar | ✔ (fast increment only when slant state on) | opt (perTowerSlant) | `ErrorChain:597-616` | once ✔ guarded |
| Ionosphere higher-order | ✔ residual | 0 | ✔ |residual| | – | survives IF at `α+β(f1/f2)³` | once ✔ |
| Ionosphere scintillation | ✔ per-row | 0 | ✔ σ_scint² | – | N_sig paths mutually exclusive | once ✔ |
| Sagnac / Earth rotation | ✔ | ✔ | – | – | disabled under iterative light-time | once ✔ |
| Shapiro | ✔ | ✔ | – | – | – | once ✔ |
| Receiver clock | ✔ truth | ✔ estimate | ✔ Q (process) | ✔ (b_rx,ḃ_rx) | excluded from ErrorChain | once ✔ |
| Tower clock (broadcast product) | ✔ truth | ✔ product/state | ✔ product σ; guard **single-freq only** | opt | `CodeMeasBuilder:203-210` (incomplete) | once in default; **latent F1** on L2/IF/block → WP-I |
| Hardware/code bias | ✔ (off) | ✔ (off) | ✔ | opt (tx-bias) | IF: independent-per-signal gain | once ✔ (WP-F honesty) |
| Multipath | ✔ GM (off) | 0 | ✔ σ_ss | – | – | once ✔ |
| Antenna PCO | ✔=M (zero) | ✔=M (zero) | – | – | – | zero residual (WP-E) |
| Code/carrier/Doppler noise | ✔ | 0 | ✔ | – | – | once ✔ |
| Carrier float ambiguity | ✔ truth | ✔ state | ✔ P0 | ✔ | slip-reset | once ✔ |
| IF combination | rebuilt | rebuilt | ✔ per-source gains | – | `CodeMeasBuilder:486-560` | correct, not double ✔ |

## Appendix B — Per-error truth/estimation lifecycle

| Error | Simulated (truth) | Measured (z) | Modelled (h) | Estimated/Observed | Separated? |
|-------|-------------------|--------------|--------------|--------------------|-----------|
| Receiver clock | stochastic ClockModel (h-params) | b_rx_true in z | b_rx_est | EKF state (bias,drift) | ✔ independent streams |
| Tower clock | deterministic OCXO truth | b_twr_true in z | noisy broadcast product | (optional state) | ✔ product≠truth |
| Troposphere | Saastamoinen ZHD + GM wet | in z | ZHD + ZWD state | ZWD GM state | ✔ truth≠model |
| Ionosphere | diurnal VTEC + GM TEC | in z | Klobuchar (~75%) | (optional slant state) | ✔ structural divergence |
| Higher-order iono | f⁻³/f⁻⁴ residual | in z | 0 (unmodelled) | R only | ✔ |
| Scintillation | phase/amp jitter | in z + R | 0 | R only | ✔ |
| Multipath (off) | GM per link | in z | 0 | R only | ✔ |
| Code noise | white per row | in z | 0 | R only | ✔ |
| Attitude | truth quaternion | via carrier lever-arm | quaternion error-state | 4-antenna carrier | ✔ |

## Appendix C — v2 work-package verification (all IMPLEMENTED-CORRECTLY)

WP-1/11 `nReceivers=4` default → attitude ON (masterConfig:45, ConfigFactory:1428-1453); WP-1 headline golden frozen; WP-2 `ConfigTextDump` resolved+diff to `.out` (ReportRunner:2443-2452); WP-8 Allan `(2π²/3)` (ClockModel:459); WP-10 tower-clock init from P0 (ScenarioFactory:108-126); WP-12a FrameTimeUtils via `revgnss.Constants`; WP-7/9 caveats in `activePhysicsConfig`; WP-6 drift-coverage panel; WP-4 `clockType`/`templateSource` knobs (default legacy); WP-5 `MonteCarloConsistency` (test-only invocation — see WP-B); WP-3 six zero-ref files archived (nothing reachable from `run_oo_v1` moved). The two goldens stay byte-identical by pinning; the new default genuinely exercises the 4-antenna attitude path.

## Appendix D — Files reviewed
`+models/+errors/ErrorChain.m`, `+models/+errors/EnvironmentModel.m` (grep), `+models/+measurements/{CodeMeasurementBuilder,CarrierMeasurementBuilder,DopplerMeasurementBuilder,CodeJacobianBuilder}.m`, `+filter/ReverseGNSSEKF.m`, `+revgnss/{ReverseGNSSSimulation,ScenarioFactory,ConfigFactory,ReportRunner,MonteCarloConsistency}.m`, `config/{masterConfig,baseConfig}.m`, `+revgnss/LinkGeometry.m` (grep), `+models/+corrections/RangeCorrections.m` (grep). Reference PDFs 01–04, Winkel/JOW, Kaplan & Hegarty, GNSS textbook, phase-noise text (extracted + grepped); NASA component-reference PDF not machine-readable.
