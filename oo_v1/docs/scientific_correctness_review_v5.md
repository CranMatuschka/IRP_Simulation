# oo_v1 Reverse-GNSS Simulation — Value Validation & Correctness Re-Audit (v5)

**Reviewer role:** Senior MATLAB developer / GNSS & Kalman-filter specialist
**Branch audited:** `feature/scientific-correctness-v2` (HEAD `9de0cdb`, plus the uncommitted realism working tree: `OrbitPerturbations`, `SolidEarthTide`, `TruthEarthOrientation`, `realismGradeConfig`, `honestCovarianceConfig`).
**Date:** 2026-07-15
**Scope (three questions):** (1) re-verify — on the *current* code, which now carries the realism-grade physics — the Kalman-filter logic, the whole error chain for **double-counting**, and **truth↔estimation separation**; (2) cross-check the physics against the reference PDFs; (3) **the centrepiece:** a **conservative + optimistic validation of every sigma, noise, bias, covariance, process-noise and limitation value**, each with a source and a plain-language "what happens if you change it."
**Relationship to v1–v4:** v1–v3 established internal correctness (no double-count; clean separation). v4 was the *realism* audit and found the default headline "pervasively optimistic." **Those v4 fixes are now implemented** as a single gated overlay, `config/realismGradeConfig.m` (switch `cfg.realism.grade=true`), default OFF so the frozen goldens stay byte-identical. v5 validates the current two-regime state and every number in it. **I did not invent values — every figure below is read from the code at the cited `file:line`, and every "realistic" bound is sourced.**

---

## 0. Executive summary

- **The simulation now has two honest regimes.** *Headline / idealised* (shipped default) and *realism-grade* (`cfg.realism.grade=true`, opt-in, gated → goldens unchanged). The realism grade de-optimises essentially every v4 finding at once (real clock, real ground-product σ, C/N0 weighting, truth multipath/hardware/PCV/survey/DCB, honest floors, closed force-gap, relativistic clock, EOP/tide, inter-antenna carrier bias, ISL product σ).
- **Internal correctness re-confirmed on the current code.** The error chain **does not double-count any effect**, including the new realism physics: the tower-clock product-σ guard is intact on every sink (WP-I), the inter-frequency DCB is **inert on the active raw dual-frequency path**, the hardware-delay residual is **white in R**, solid-Earth tide + EOP are **truth-only** one-sided residuals, luni-solar/SRP is **matched** on both truth and EKF, and the inter-antenna carrier bias is **z-only** (absorbed by the ambiguity). Truth↔estimation separation and the EKF logic (Joseph, right-division gain, quaternion-reset, PSD guard, NIS) are unchanged and correct. The v4 MC position-NEES normalisation bug (H11) is **fixed**. §3.
- **The default is optimistic; the realism grade is realistic-to-conservative.** The value tables in §2 give, for each parameter, the shipped default, the realism-grade value, a **conservative** and an **optimistic** bound, the source, and the effect. The one-directional asymmetry v4 found still holds: almost every default sits at the *optimistic* end.
- **The deepest, most important result is an observability wall, not a number.** With realistic values the one-way sparse-GEO run is honestly **over-confident** (state NEES ≫ 1 while innovation NIS ≈ 1). This is **not** a wrong-σ problem — it is the weakly-observable **radial↔receiver-clock** mode being fed **temporally-correlated** per-tower systematics (multipath, survey, PCV, frame residual) that the white-R filter averages away but the real world does not. Because a diagonal R scales the formal σ *and* the propagated error together, the over-confidence ratio is **invariant to any honest R/Q scaling** — no config knob fixes it. Only **geometry** does (two-way transfer or a co-observed swarm). §4.
- **Honest accuracy envelope (realism-grade, empirical).** One-way ground: **hundreds of m / hundreds of ns**, radial ≡ −clock, corr −1.000, a bounded random walk that does **not** converge (the idealised ~3 m was a perfect-dynamics artefact). ISL swarm S6R4: **~0.25 m / ~352 ps** (cross-links break the degeneracy). Two-way lowers the R1/R4 NEES ~25 %. §5.

---

## 1. How to read the value tables (§2)

For every parameter I give five things:

- **Default** — the shipped `masterConfig` headline value (what runs out of the box).
- **Realism-grade** — the value under `cfg.realism.grade=true` (`realismGradeConfig.m`), if different.
- **Conservative** — the *pessimistic / realistic-worst* value a cautious engineer would assume. Using it makes the covariance **honest** (rarely over-confident) at the cost of a looser-looking result.
- **Optimistic** — the *best-case* value that flatters the result and risks **over-confidence** (covariance smaller than the true error). The shipped default mostly sits here.
- **Effect** — in the simplest terms, what moving the value does.

Rule of thumb for the plain-language effect:
- Raise a **measurement noise σ** → the filter *trusts that measurement less* → looser but more honest covariance; lower it → tighter estimate, but if it drops below the true error the filter becomes **over-confident** (NEES/NIS climb).
- Raise a **truth-side error** (multipath, DCB, tide…) → a *bigger real error is injected into the world* → the estimate genuinely gets worse (this is what "realism" costs).
- Raise **P0** (initial covariance) or **Q** (process noise) → looser prior / more responsive filter → converges from a worse start / tracks faster, but with larger steady uncertainty.

---

## 2. The value-validation tables

### 2.1 Clock (receiver, tower, broadcast product, gauge, relativity)

| Parameter | Default (`file:line`) | Realism-grade | Conservative | Optimistic | Source | Plain effect of changing it |
|---|---|---|---|---|---|---|
| **Rx clock `CESIUM1` h0** (WFM) | `1e-26` (`ConfigFactory.m:2000`) via `templateSource='legacy'` (`masterConfig.m:147`) | **`1e-19`** (`jowTable2p1`) | `1e-19` (JOW Cs) | `1e-26` (ideal maser) | JOW Table 2.1; IEEE-1139; HP-5071A (h0≈1e-22, σ_y(1s)≈8.5e-12) | This is the single biggest realism lever. σ_y(1 s)=√(h0/2): legacy **7.1e-14** (better than an H-maser) vs JOW-Cs **2.2e-10** (≈3160×). Raising h0 → the clock genuinely wanders (free-run ~27 ns/4 h) **and** the EKF clock-Q grows, so the clock covariance stops being ~3 decades over-confident. Lowering → the filter believes the clock is frozen between updates. |
| Rx clock h₋₁ (FFM) | `1e-28` (`:2001`) | `1e-25` | 1e-25 | 1e-28 | JOW Table 2.1 | Sets the flicker floor of the Allan deviation; minor vs h0/h₋₂ here. |
| Rx clock h₋₂ (RWFM) | `1e-30` (`:2002`) | `2e-32` | 2e-32 (Cs) | 1e-30 | JOW Table 2.1 | Long-τ random-walk of frequency → the drift state's true wander. Drives `Q22=2π²h₋₂dt`. |
| Tower clock OCXO h₋₂ (RWFM) | `2e-29` (`:1986`) | **`2.51e-22`** (JOW OCXO2) | 2.51e-22 | 2e-29 | JOW Table 2.1 OCXO2 | Towers are deterministic by default (see below), so this bites only if tower clocks are made stochastic; the legacy value is ~7 orders too quiet. |
| Clock `templateSource` | `'legacy'` (`masterConfig.m:147`) | `'jowTable2p1'` | jowTable2p1 | legacy | JOW dissertation | One-string switch selecting the whole h-parameter set. `legacy` = "ideal-oscillator bound" (label it so); `jowTable2p1` = primary-source caesium. |
| Tower **broadcast-product σ_bias** | `0.01 m` ≈ 33 ps (`masterConfig.m:152`) | **`0.10 m`** ≈ 0.33 ns | 0.30 m (broadcast ~5 ns) | 0.01 m (IGS-final) | IGS product accuracy: broadcast ~5 ns, ultra-rapid-pred ~3 ns, **IGS-RTS ~0.1–0.3 ns**, IGS-final ~0.1 ns | Common-mode on every code row of a tower → maps almost 1:1 into the receiver-clock covariance. 33 ps is *post-processed* accuracy used at *real-time* 5 s latency; realistic real-time is 0.1–1 ns. Raising it lifts the achievable clock floor directly. |
| Tower product σ_drift | `2e-4 m/s` (`:153`) | `1e-3 m/s` | 1e-3 | 2e-4 | IGS-RTS clock-rate | Prediction-rate uncertainty between broadcasts; feeds Doppler/drift R. |
| Product cadence / latency / validity | 30 s / 5 s / 120 s (`:150–155`) | same | 30/5/120 s realistic | shorter | IGS-RTS stream cadence | Older product → larger age-grown prediction error (already folded into R). |
| Rx clock `deterministic` | `false` (stochastic) (`:139`) | same | stochastic | deterministic | — | Correct as-is; the realism is in the h-parameters, not this flag. |
| Tower clock `deterministic` | `true` (`masterConfig.m:434`) | true (h-params re-anchored but still deterministic) | stochastic | deterministic | JOW | Deterministic towers mean the broadcast prediction is exact except for the injected product noise; a real network has intra-interval wander (~2 ps legacy OCXO → ~ns OCXO2). Minor once product σ is realistic. |
| Clock-gauge σ (pseudo-meas) | 1e-6 m / 1e-9 m/s (`:1334–1335`) | same | — | — | Kaplan & Hegarty (datum) | Pins the clock datum when tower clocks are states; numerically small, correct. |
| Relativistic clock offset | `enable=false` (`:95`) | **`true`** (WP-D) | modelled | omitted | Ashby 2003 | Constant +5.39e-10 (+46.6 µs/day). Fully absorbed by the estimated drift state → **zero solution impact for the circular GEO** (§3); realism = present in truth for completeness. |

### 2.2 Measurement noise & R construction

| Parameter | Default | Realism-grade | Conservative | Optimistic | Source | Plain effect |
|---|---|---|---|---|---|---|
| **Code σ L1** (`codeSigma0_m`) | `0.30 m` (`masterConfig.m:851`) | 0.30 base + **C/N0 reweight** | 0.60 m (own guard) | 0.30 m | Kaplan §5.6 DLL; RTKLIB | Thermal-realistic for a high-C/N0 space receiver. The default's sin is the disabled **elevation/C/N0 weighting** (below), not the base value. Raise → looser horizontal position. |
| Code σ L2 | `0.45 m` (`:855`) | 0.45 base + C/N0 | 0.90 m | 0.45 m | Kaplan §5.6 | As L1; L2 noisier (weaker signal). |
| Code-noise **model** | `'constant'` (`:868`) | **`'cn0'`** (base 45 dB-Hz, +6 dB zenith) | cn0/elevation | constant | Kaplan DLL C/N0; RTKLIB elev model | `constant` over-trusts low-elevation towers (largest true thermal+tropo error) on a near-static GEO — a *spatial* mis-weighting. `cn0`: σ=σ₀·10^(−(C/N0−45)/20). **Better link = raise `cn0.base_dBHz`.** |
| Code **sigmaFloor** | `1e-3 m` (`masterConfig.m:838`) | **`0.01 m`** | ≥0.01 m | 1e-3 m | — (below carrier λ is non-physical) | A 1 mm code floor is physically impossible (below the carrier wavelength). Dormant at 0.30 m but must be ≥1 cm before any low-σ study. |
| **Carrier σ** (new-style) | `0.005 m` (5 mm) (`:1225`) | **`0.010 m`** | 0.010 m (guard) | 0.005 m | Kaplan §5.6 PLL (5 mm ≈ 0.026 cyc thermal-realistic) | Drives attitude/carrier accuracy. The two carrier fields (5 mm EKF vs 1.9 mm diagnostic) should be reconciled to one source. Raise → looser attitude. |
| Carrier σ (cycles) | `0.01 cyc` (`:1112`) | same | 0.01–0.02 | 0.01 | Kaplan PLL | ≈1.9 mm at L1; thermal-realistic. |
| **Doppler σ** | `0.01 m/s` (`:1100`) | **`0.03 m/s`** | 0.05–0.1 m/s (raw FLL) | 0.01 m/s (carrier-derived) | Kaplan §5.6 FLL | 0.01 m/s is only defensible if Doppler is carrier-derived; raw FLL is 0.03–0.1. Check it does not double-count the carrier phase. |
| Two-way transfer σ | `0.03 m` ≈ 100 ps (`:496`, feature OFF) | same | 0.03 m (code TWSTFT) | ps-class (carrier TWSTFT) | Merlo&Nanzer 2.26 ps; T2L2 ~50 ps; EM-WaTT ~100 ps | Only active when two-way is enabled. This is the *cure* for the clock/degeneracy — enabling it breaks the radial↔clock wall (§4). |
| Two-way reciprocity σ | `0.005 m` (`:1185`) | same | 0.005–0.02 m | 0.005 m | TWSTFT non-reciprocity budget | Residual after motion correction; small for GEO. |

### 2.3 Truth-side error stream (atmosphere, multipath, biases, frames)

*These are the errors the world actually contains. Raising them makes the estimate genuinely worse — that is the price of realism. In the default most are OFF (matched truth==model → zero residual); the realism grade turns them on **truth-only** so they survive z−h.*

| Parameter | Default | Realism-grade | Conservative | Optimistic | Source | Plain effect |
|---|---|---|---|---|---|---|
| **Multipath** (coloredGM σ) | off; GM σ `0.30 m`/τ `60 s` (`masterConfig.m:1003,1002`) | **on**, 0.30 m/60 s | 0.5 m (harsh) | 0.1 m (benign) | Kaplan §7.2.6 (multipath is the dominant code error, strongly time-correlated) | **The single biggest driver of the honest NEES ≫ 1** (§4): a ~1 ns time-correlated code error the white-R filter averages away but the world does not. Steady-state σ feeds R (conservative-correct). |
| **Hardware group delay** (residual σ) | off; `0.0 m` (`:974`) | **on**, `0.5 m` white, per tower | 1–5 ns (0.3–1.5 m) | 0 | receiver hardware; IGS | Truth-only **white** per-epoch residual (in R, *not* a constant bias — so it does **not** double-count with DCB). Frequency-independent part only. |
| **DCB** inter-frequency code truth L1/L2 | 0 / 0 (`masterConfig.m:126–127`) | **0.30 / 0.45 m** (~1 / 1.5 ns) | ±10 ns (P1-P2) | 0 | IGS DCB / Schaer | **Inert on the active raw dual-frequency path** (no IF carrier EKF, `carrierCombinationMode='raw'`) — it only bites the ionosphere-free *diagnostic*. So it is honestly present in truth but currently contributes ~nothing to the active z−h; a per-tower DCB on the raw path is the follow-up. |
| **Antenna PCV** | off; amp `0.005 m` (`:1043`) | **on** (~1 cm elev/az) | 1–2 cm (uncalibrated) | 0 (calibrated ANTEX) | Schmid et al. 2007 (igs05) | Does **not** common-mode-cancel between differently-oriented attitude antennas → a real attitude/carrier error. |
| **Tower survey** ENU σ | off; `[1;1;3] cm` (`:1016`) | **on**, truth-only static | [1;1;3] cm | 0 (perfect survey) | ITRF station coordinates | A static per-tower position offset the model doesn't know → constant range bias → aliases into radial↔clock (part of the NEES driver). |
| **Solid-Earth tide** | off; Love h2 0.6078 / l2 0.0847 (`:1025–1026`) | **on** (~0.11 m degree-2) | ~0.30 m radial (full) | 0 (perfect model) | IERS Conventions 2010 Ch.7; dehanttideinel | Truth-only per-tower displacement (via `towerPositionEcef(...,t_s)`); the model keeps static towers, so the ~dm displacement survives z−h. > λ_L1, so mandatory for cm-level claims. |
| **EOP** polar motion / UT1 | off; xp 0.2″/yp 0.3″/UT1 1 ms/day (`:1065–1067`) | **on**, xp/yp **0.005″** (~15 cm), UT1 0.05 ms/day | ~9 m (uncorrected pole) | 0 (perfect EOP) | IERS Conventions 2010 Ch.5 | Realism uses the **post-EOP-correction residual** (real-time/predicted-EOP grade), not the raw ~9 m pole. Truth-only frame residual → cm–dm range / sub-ns–ns clock floor. |
| **Inter-antenna carrier bias** | off; `0.25 cyc` (`:983`) | **on** | 0.1–0.5 cyc, temp-drifting | 0 (`syntheticKnownZero`) | Cohen 1992; Teunissen (LAMBDA) | The single hardest term in GPS attitude AR. Truth-only on z_φ (ref antenna = 0), constant part absorbed by the float ambiguity. Zeroing it lets the integer search fix trivially (the old optimism). |
| Troposphere ZWD mean | 0.15 m wet (`:893`) | ~7.5 cm effective | 0.10–0.20 m mid-lat | dry | Saastamoinen; Niell | Dry-side but absorbed by the estimated per-tower ZWD state → near-negligible residual. |
| Trop stochastic σ_wet / τ | 0.05 m / 3600 s (`:899,898`) | 0.04 m / 10800 s | 0.05 m | 0.02 m | GM wet-delay | The un-trackable wet increment charged to R; longer τ = slower wander. |
| Iono VTEC (truth) | 5 m (`:904`) | diurnal 30/6 TECU | 30 TECU day / 6 night | low solar | IS-GPS-200; mid-lat solar-moderate | Dual-frequency default removes 1st-order iono; residual is higher-order (below). |
| Iono σ_VTEC (stochastic) | 1.0 m (`:909`) | 0.3 m (~2 TECU) | 2–5 TECU | quiet | Klobuchar residual | Un-modelled TEC fluctuation to R. |
| Klobuchar skill | (matched off) | 0.75 (`realisticAtmosphereConfig.m:72`) | 0.5 (canonical) | 0.75 | IS-GPS-200 (~50 % RMS) | Optimistic but **dormant** under the dual-frequency default (iono removed by L1/L2). |
| Higher-order iono 2nd/3rd cap | 0.05 m / 0.005 m (`:919,921`) | on (truth) | full magnitude | 0 | Bassiri & Hajj; Hoque & Jakowski | Charged to R at **full unmodelled magnitude** — *conservative-correct*; keep. Survives the IF combination (∝f⁻³/f⁻⁴). |
| Scintillation S4 / σ_φ | 0.3 code / — | 0.3 S4zen, σ_φ 0.2 rad (~6 mm) (`realisticAtmosphereConfig.m:92,95`) | S4 0.3–0.7 | quiet | Conker et al. 2003 | Amplitude → inflated carrier/code σ; phase → truth carrier jitter. |

### 2.4 Process noise & dynamics (Q, force model)

| Parameter | Default | Realism-grade | Conservative | Optimistic | Source | Plain effect |
|---|---|---|---|---|---|---|
| **`sigma_accel_mps2`** (SNC) | `1e-6` (`masterConfig.m:793`) | 1e-6 (with force gap **closed**) | 5e-6–7e-6 (open gap) | 1e-6 | Tapley/Schutz/Born SNC; Montenbruck & Gill | White acceleration process noise. Sized to a perturbation-free truth in the default; harmless there (zero actual error). Raising it loosens radial (and thus clock). |
| **`modelMismatch`** enable / σ | `false`, 1e-6 (`:808`) | **`true`**, 1e-6 | 5e-6 (if gap open) | off | Tapley SNC | In the realism grade the **force gap is closed** (luni-solar+SRP on both truth and EKF), so the SNC is retuned *down* to 1e-6 (higher-order geopotential + SRP-model residual only) rather than covering an open gap. |
| **Luni-solar** (truth+EKF) | off (`masterConfig.m` pert block) | **on both sides** (matched) | matched | J2-only (optimistic) | Montenbruck & Gill; \|a_LS\|≈3.3e-6 m/s² (≈J2 at GEO) | The dominant post-J2 GEO perturbation. Default truth==EKF==pure-J2 gave the estimator *zero* force error (the "perfect-dynamics" artefact that falsely pinned radial). Matched luni-solar is the realistic filter; the residual (SNC) is the honest gap. *Known approximation:* EKF F/Q stay pure-J2 (third-body gradient ~1e-13 s⁻² is negligible over dt). |
| **SRP** Cr / area-to-mass | 1.3 / 0.02 (`:696,697`) | on both sides | 1.3 / 0.02 | off | Montenbruck & Gill; \|a_SRP\|≈1.2e-7 m/s² | Cannonball SRP; small vs luni-solar; matched. |
| **`sigma_angAccel`** | ~1e-7 rad/s² (torque budget) | same | 1e-7 (conservative end) | 1e-8 | Wertz (SADC), GEO environmental torques | Attitude process noise from τ=I·α. Sits at the **conservative end** of the Wertz budget — keep. |
| Attitude inertia / disturbance torque | 10 kg·m² / 1e-6 N·m (`:632,633`) | same | — | — | Wertz | Inputs to the α=τ/I budget above. |
| Ambiguity process σ | 1e-5 m/√s (`:1260`) | same | 1e-5 | smaller | — | Tiny random walk on the float ambiguity; correct. |

### 2.5 Initial covariance (P0) & initial error

| Parameter | Default (`file:line`) | Conservative | Optimistic | Source | Plain effect |
|---|---|---|---|---|---|
| P0 position | `1000 m` (`masterConfig.m:819`) | 1000 m | 100 m | cold-start prior | Initial position uncertainty; the filter converges from a worse start if larger. |
| P0 velocity | `1 m/s` (`:820`) | 1 m/s | 0.1 m/s | — | GEO velocity error prior. |
| P0 euler | `5°` (`:822`) | 5° | 1° | — | Initial attitude uncertainty. |
| P0 omega | `1e-12 rad/s` (`:823`) | 1e-6 (known-zero) / 1e-5 (est.) | 1e-12 | — | Cosmetically over-tight but inert (ω frozen at truth 0). Document as fixed known-zero. |
| P0 receiver clock bias | `100 m` (`:824`) | 100 m | 10 m | — | Initial clock offset prior. |
| P0 receiver clock drift | `0.01 m/s` (`:825`) | 0.01 | 0.001 | — | Initial drift prior; the relativistic offset (WP-D) is seeded consistently. |
| P0 tower-clock bias / drift | 1000 m / 10 m/s (`ScenarioFactory.m:124–125`) | draw from P0 | exact truth | — | Only when tower clocks are states (default off). WP-10 already draws the init from P0 (consistent NEES). |
| Initial error offset (pos / clk) | `[1000;−500;250] m` / `100 m` (`:828,833`) | MC-drawn from P0 | fixed | Bar-Shalom §5.4 | Fixed deterministic offset = a single NEES sample; the MC harness draws it from P0 for a real χ² test. |

### 2.6 Geometry & structural limitations

| Item | Value (`file:line`) | Conservative reading | Optimistic reading | Source | Plain effect |
|---|---|---|---|---|---|
| **nTowers** | 5 (`masterConfig.m:43`); 12 sites available | 5 co-visible → 64 m radial (App. E, v4) | 12 wide → ~10 m | Kaplan DOP; empirical ladder | More/wider towers *reduce* the radial↔clock degeneracy but never fully separate it one-way (all LOS within asin(Rₑ/R_g)=8.7° of radial → **87×** mode amplification; radial dilution PDOP ≈ 560). |
| Radial↔clock degeneracy | intrinsic to one-way GEO | one-way ⇒ degenerate | — | geometry | The structural reason the clock/radial are geometry-limited (§4). **Only two-way / swarm cures it.** |
| Two-way / swarm as cure | `twoWay OFF`; `nSpaceAssets=1` (`:42`) | enable for any ps claim | one-way sub-100 ps (false) | Merlo, T2L2, EM-WaTT (all two-way) | Enabling two-way or the ISL swarm breaks the wall — the empirical swarm S6R4 reaches 0.25 m/352 ps. |
| nReceivers | 4 (`:52`) | 4-antenna cross (attitude observable) | 1 (attitude off) | — | WP-1 made 4 the default so attitude is actually exercised. |
| ISL product σ_pos / σ_clock | 0.03 / 0.02 m (`baseConfig`) | **0.10 / 0.10 m** (realism) | 0.03 / 0.02 | SLR/broadcast reference | The S6R4 3σ coverage was 0 % because the filter believed the aiding was ~10× better than delivered; realism loosens it to broadcast-reference quality. |
| GEO altitude / mass | 35 786 km / 70 kg (`:425,623`) | — | — | GEO definition | Scenario geometry; correct. |

### 2.7 Diagnostics & numerical floors

| Item | Value (`file:line`) | Status | Source | Plain effect |
|---|---|---|---|---|
| MC position-NEES normalisation | `MonteCarloConsistency.m:79` pools raw block NEES vs matching dof | **FIXED** (v4 H11) | Bar-Shalom §5.4 | Was the origin of v3's spurious "NEES/dof≈0.36 CONSERVATIVE"; now `neesPerDof≈1` on a consistent filter. |
| Attitude NEES | `SimulationDataStore.m:851` via `attitudeSmallAngleError_` | **FIXED** (quaternion-aware) | Markley & Crassidis MEKF | Now scored in the small-angle error-state space P(euler_idx) covers, not a raw Euler difference. |
| SPD / frozen-Q floors | 1e-12 / 1e-20 (`masterConfig.m:282,298`) | numerical, below any physical variance | — | Keep — pure conditioning. |
| Single-run vs χ² band | fixed [0.5,2], MC off by default | ESS-aware / MC needed | Bar-Shalom | A 14 400 s run has only tens of *effective* samples (filter τ ~ hundreds of s); the band is tight. The MC harness (WP-B) is the honest test. |

---

## 3. Double-counting & truth↔estimation separation — re-verified on the current code

**Answer: no error is double-counted anywhere on the current (realism-grade) code, and truth is cleanly separated from estimation.** Independently re-verified against the current HEAD + the uncommitted realism working tree.

| Effect (realism-grade on) | Truth `z` | Model `h` | `R` | State | Verdict |
|---|---|---|---|---|---|
| Tower-clock broadcast-product σ | via product | via product/state | ✔ (guarded) | opt. | **once** — `maskStateTowerSigma_` zeros it on the bias col (`CodeMeasurementBuilder.m:209-213,231,659`), Doppler drift col (`:144`), carrier drift col (`:116`) when the tower clock is a state; gauge/non-estimated towers keep σ (WP-I). |
| Inter-frequency DCB (L1/L2) | truth-only | 0 | — | — | **once, inert on active path** — raw dual-frequency (`carrierCombinationMode='raw'`, no IF carrier EKF), so it only touches the IF *diagnostic*; does **not** double-count with hardware delay. |
| Hardware-delay residual (0.5 m) | truth-only white | 0 | ✔ (white) | — | **once** — a per-epoch white residual in R, not a constant bias. |
| Colored-GM multipath (0.30 m) | truth-only GM | 0 | ✔ (steady-state σ) | — | **once** — the correlated bias into z; its steady-state σ into R. |
| Solid-Earth tide + EOP (R-8) | truth-only (`towerPositionEcef(...,t_s)`) | static towers (4-arg, no `t_s`) | — | — | **once, one-sided** — a genuine truth-only frame residual; no H/R entry. |
| Luni-solar / SRP (R-3) | truth mean | EKF mean (matched) | — | — | **matched, not a mismatch** — same force on both propagators; F/Q stay J2 (negligible gradient). |
| Inter-antenna carrier bias (R-6) | z_φ only (ref=0) | 0 | — | absorbed by ambiguity | **once, z-only.** |
| Relativistic clock (WP-D) | truth bias ramp | — (drift state absorbs) | — | drift | **once** — observable, absorbed; zero solution bias for circular GEO. |

**Separation & KF logic:** the per-epoch order (`generateTruth_` writes world state only → `runEstimation_`; `z` from truth, `h`/`H` from `getMeasurementState()`) is intact; no local state crosses stages. The EKF core is unchanged and correct — Joseph update on the saved prior, right-division gain `K=P⁻Hᵀ/S`, quaternion injection + first-order covariance reset on the **posterior**, per-stage symmetrisation, nearest-SPD guard, NIS via backslash. The MC-NEES (H11) and attitude-NEES fixes are in.

**One honest note (not a bug):** with the optional EKF luni-solar enabled, only the state *mean* is perturbed; the covariance Jacobian `F`/`Q` stay pure-J2. The third-body gravity gradient (~1e-13 s⁻²) is negligible vs J2 over `dt`, and the feature is default-off — no correctness impact, worth a one-line disclosure.

---

## 4. The observability wall (the deepest realism finding)

With realistic values the one-way sparse-GEO run is honestly **over-confident**: innovation **NIS/dof ≈ 1** (0.94–1.15) but state **NEES/dof ≫ 1** (position 133–536, clock up to 250), and 3σ coverage collapses toward 0 %. This was investigated exhaustively (`honestCovarianceConfig.m`) and the conclusion is important and **not** a tuning bug:

- **NIS ≈ 1 means R is correctly sized** — the innovations `z−h` *are* consistent with `S=HPH'+R` (R ≈ 1.07 m² from the C/N0 model). Raising the R floor to 1 m moved NEES by < 2 % (ratio-invariant) — the R-floor hypothesis is **falsified**.
- **NEES ≫ 1 means the wrong error *model*.** The truth injects **temporally-constant / correlated** per-tower systematics — colored-GM multipath (~0.30 m), static survey error, PCV, the frame residual — that the filter treats as **white** and averages down over 3600 epochs (σ ∝ 1/√N), while the real error does **not** average. On the near-static GEO these alias into the weakly-observable radial↔clock mode (radial PDOP ≈ 560): 0.30 m × 560 ≈ 168 m, matching the observed ~185 m / 617 ns.
- **The over-confidence ratio is invariant to any honest scalar R/Q change** — a diagonal white R scales the formal σ *and* the propagated error together — so **no config knob makes NEES → 1**. State augmentation (estimating per-tower clocks to absorb the systematics) **diverges** on this geometry (378 km / 3400 km; one-way GEO gives only N pseudoranges for N tower + rx clocks + position and never separates them).
- **Only geometry cures it.** The empirical batteries show the swarm S6R4 at NEES ~50–60 vs ~140–540 for R1/R4, and two-way lowers R1/R4 NEES ~25 %.

This is the honest scientific truth about the one-way sparse-GEO architecture, and it re-frames the "accuracy" question: the limit is **observability**, not σ tuning.

---

## 5. Realistic accuracy envelope (empirical, realism-grade)

| Quantity | Idealised headline | Realism-grade (empirical) | Limiter |
|---|---|---|---|
| Receiver clock | sub-100 ps | **~350 ps (swarm S6R4) to ~600 ns (one-way ground)** | one-way degeneracy + realistic clock + product σ |
| Position — radial | sub-m | **~0.25 m (swarm) to ~190 m (one-way, non-converging random walk)** | radial↔clock degeneracy + closed force-gap unpins the perfect-J2 twin |
| Position — horizontal | sub-m | sub-m to a few m | code multipath/DCB, C/N0 weighting |
| Attitude | sub-0.1° | **~0.1° → ~2.4°** | carrier σ ×2 + PCV + unknown inter-antenna biases |

The idealised sub-100 ps / sub-wavelength headline required an ideal-maser clock **and** one-way geometry treated as if two-way **and** a truth-matched perfect orbit **and** a truth-anchored attitude reference *simultaneously*. Being honest on any one of them already leaves that regime.

---

## 6. PDF cross-check (this pass)

- **Clock (JOW *Modeling & Simulating GNSS…* Table 2.1, extracted).** Confirmed: Cesium1 h0=**1e-19**, h₋₁=1e-25, h₋₂=2e-32; OCXO2 h0=2.51e-26, h₋₂=2.51e-22. The legacy CESIUM1 h0=1e-26 is 7 orders below JOW Cs *and quieter than the code's own legacy OCXO* — physically inverted. Grounds the clock table (§2.1) at the primary source.
- **Time transfer (Merlo & Nanzer 2023; SDR; T2L2; EM-WaTT, extracted).** Every sub-100 ps figure is **two-way**: Merlo 2.26 ps (36-dB SNR wireless), White Rabbit <2 ps (1.6 GHz BW), single-pulse <2.5 ps, EM-WaTT ~100 ps, T2L2 ~50 ps. Confirms the one-way clock is a ns-class system (§2.6, §5).
- **Noise (Kaplan & Hegarty §5.6).** λ_L1=0.1903 m/cycle; the 5 mm carrier / 0.30 m code base sigmas are thermal-realistic — the optimism is in the *disabled elevation weighting* and *omitted correlated errors*, not the thermal floor. Grounds §2.2.
- **Frames/forces (domain refs cited inline).** IERS Conventions 2010 (Ch.5 EOP, Ch.7 tides); Montenbruck & Gill (luni-solar ≈ J2 at GEO); Ashby 2003 (relativity); Schmid 2007 (PCV); Schaer (DCB). Consistent with the realism-grade choices (§2.3–§2.4).

---

## 7. Prioritized forward plan

The physics fixes (R-1/R-3/R-4/R-5/R-6/R-8 + M7/R-10/WP-D + ISL-σ) are **implemented** and gated. What remains is presentation honesty, the correlated-error modelling that the wall exposes, and a default-regime decision.

| WP | Fix | Effort | Acceptance |
|----|-----|--------|-----------|
| **V5-1 (default regime)** | Given the "conservative > optimistic" directive: either make `cfg.realism.grade=true` the **reported headline** (freeze a realism-grade golden; keep the idealised golden as a labelled "ideal-oscillator/matched-frame bound"), or gate every report path so a one-way run never prints sub-100 ps / sub-wavelength. | S | No headline claims a regime the config doesn't support; realism golden frozen. |
| **V5-2 (report captions, R-2/R-9)** | One-way runs captioned **ns-class**; sub-100 ps only under `twoWayTimeTransfer`/swarm. Promote **run-wide + mismatched-atmosphere** RMS to the headline (already computed); relabel the single-run NEES as "one realization, not a χ² test." | S | Captions match the observability reality; MC verdict shown. |
| **V5-3 (correlated-error modelling — the honest NEES fix within a geometry)** | The wall says the filter must *model the correlation*, not average it: add **consider/Schmidt states or a colored-measurement-noise (Gauss-Markov per-tower bias) augmentation** for the multipath/survey/PCV/frame systematics — the honest way to stop the white-R over-averaging **without** the unobservable tower-clock states that diverge. Gate to observable geometries (≥ R4 / two-way / swarm). | L (filter code) | On a swarm/two-way run NEES/dof → ~1 with the correlated states; one-way documented as observability-limited. |
| **V5-4 (two-way / swarm as the observability cure)** | Wire two-way (WP-A) and/or the swarm as the *supported* path to sub-ns; report the radial-vs-horizontal split and the NEES improvement (swarm ~50–60 vs ~140–540). | M | A two-way/swarm run demonstrably breaks the degeneracy with consistent covariance. |
| **V5-5 (per-tower DCB on the raw path)** | The current DCB is inert on the active raw path; inject a per-tower differential code bias that the raw dual-frequency EKF actually sees (coordinate magnitude with hardware delay to avoid a freq-dependent double-count). | S–M | Innovations carry a per-tower code bias; NIS in-band with residual-to-R accounting. |
| **V5-6 (hygiene, R-10 tail)** | Reconcile the two carrier-σ fields to one source; document ω as fixed-known-zero; per-axis attitude covariance; relabel the pseudo-inertial frame. | S | Each default meets its `GeoRealWorldScenarioGuard`. |

**Sequencing:** V5-1/V5-2 are text/label changes that make the headline honest immediately; V5-3 is the one substantive filter task the wall demands (and the only honest way to reconcile NEES on a *cured* geometry); V5-4/V5-5 are physics-completion; V5-6 is hygiene. None disturbs the frozen goldens provided the realism physics stays gated with its own frozen realism-grade golden.

---

## Appendix A — What v4 flagged, and its current status

| v4 finding | Status now |
|---|---|
| C1 legacy clock too quiet | **implemented** (R-1: `jowTable2p1` under realism grade) |
| C2 sub-100 ps is one-way | **structurally confirmed** (empirical ladder + observability wall); report caption remains (V5-1/2) |
| H1 tower product σ | **implemented** (R-4: 0.10 m) |
| H3/M1 force-model gap | **implemented + refined** (R-3: luni-solar+SRP matched both sides, SNC retuned 5e-6→1e-6) |
| H4/H5/M2/M3 multipath/DCB/hardware/PCV | **implemented** (R-5), DCB noted inert on the active path (V5-5) |
| H6/H7 EOP / solid-Earth tide | **implemented** (R-8, truth-only, real-time-EOP-residual grade) |
| H8/H9 attitude truth-anchoring / inter-antenna bias | **partially** (R-6 injects the unknown inter-antenna bias; bias-calibration decoupling remains) |
| H11/M8 MC-NEES / attitude-NEES bugs | **fixed** |
| M5 relativistic clock | **implemented** (WP-D) |
| M7 code C/N0 weighting | **implemented** (`cn0`) |
| R-floor / tower-clock-state cures | **investigated and falsified** (`honestCovarianceConfig.m`): observability wall, geometry is the only cure |

## Appendix B — Empirical anchors (realism-grade battery, G5 TW0, 3600 s)

| Config | radial | clock | Reading |
|---|---|---|---|
| S1R1 (one-way, 1 antenna) | ~192 m | ~635 ns | ground-only collapses (radial ≡ −clock, corr −1.000, non-converging random walk) |
| S1R4 (one-way, 4 antenna) | ~187 m | ~617 ns | attitude adds antennas, not radial observability |
| S6R4 (ISL swarm) | ~0.25 m | ~352 ps | cross-link geometry breaks the degeneracy — the only sub-ns rung |

NIS/dof moved from ~0.90 (idealised) to ~1.0 (honest R/Q); attitude degraded 0.14° → 2.4° (carrier σ ×2 + PCV; inter-antenna bias adds more). The idealised ~3 m radial was the perfect-dynamics artefact; closing the truth force gap (R-3) un-pins radial from the EKF's formerly-identical J2.
