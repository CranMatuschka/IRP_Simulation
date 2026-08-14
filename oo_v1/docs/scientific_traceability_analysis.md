# oo_v1 Scientific Traceability & Verification Analysis

**Round 2 — re-verified against `feature/ground-orientation-exec` @ `170e37d`, 2026-08-13.**
Supersedes the 2026-08-06 edition (baseline commit `3489075`), which is retained in git history.

---

## What this document is

A verification of the scientific content of the `oo_v1` reverse-GNSS simulation — every formula, physical
constant, model, estimator and element of simulation logic — against the project's own literature
collection (`IRP/Paper/`, 84 documents) and external authorities where the collection is silent. For each
feature it records the implementation (`file:line`), a verdict, one or more sources with an **exact
verbatim quote** and page number, and a critical analysis of what is right and what is wrong.

Round 2 adds three registers the first edition did not have, in direct response to the question
*"check for double counts in error, sigma, noise, R, Q, S or any other values; check for logical flaws;
list the limits"*:

- **Register A — Variance accounting** (double counts, omitted correlations, mis-colourings): §A
- **Register B — Logical flaws** (gates that do not gate, silent degradation, stale contracts): §B
- **Register C — Limits** (123 statements of what the simulation cannot legitimately claim): §C

## Why a second round was necessary

Between the two editions **137 `.m` files changed**, two new physics modules appeared
(`+models/+atmosphere/GaseousAbsorption.m`, `+models/+clocks/RelativisticClockCorrection.m`), and eight
further commits landed after the document's last update. Re-verification found the first edition stale in
both directions: several of its findings had been **fixed** and several of its **line citations had
drifted by 88–212 lines**. A traceability document that is not re-verified against HEAD is a liability,
because every stale `file:line` looks authoritative.

## Method, and what makes each claim checkable

1. **Nine domain re-verifications.** One agent per domain re-read the current code and re-tested every
   claim of the previous edition, marking each STILL-VALID / DRIFTED / SUPERSEDED / NOW-WRONG / NEW.
2. **Adversarial verification.** Every defect claim was handed to an independent agent instructed to
   *refute* it — to read the code itself, check config gates, look for guards the claimant missed, and
   default to "refuted" unless the defect could be positively confirmed. Claims that survived carry the
   evidence that survived the attack, including corrections where the original claimant overstated size,
   severity or scope. **The first adversarial pass refuted 49 of 72 claims (68 %).** A second pass covered
   the remaining claims and audited a sample of the refutations themselves for soundness.
3. **Live resolution, not reading alone.** Where it mattered, verifiers resolved the actual shipped
   configuration in MATLAB (`resolveSimulationConfig('golden_baseline.json')`) and, in several cases,
   instrumented a live run rather than inferring from source. Findings therefore carry a
   **liveness label**: LIVE-IN-GOLDEN, LIVE-IN-LADDER-ONLY, LATENT-DEFAULT-OFF, or UNREACHABLE.
4. **Quotes are verbatim and page-referenced.** PDF text was extracted mechanically; the four scanned
   sources without a text layer (Brown & Hwang; Hofmann-Wellenhof 2008; and two others) were read as
   rendered page images and transcribed, and every such quote is marked as transcribed.

**Verdict key.** ✅ verified correct against sources · ⚠️ partially correct, honest simplification, or
correct-but-unsourced · ❌ defect confirmed · ❓ unverifiable from available material.

---

## Executive summary

**The deterministic physics remains the strong part, and it got stronger.** Re-verification against HEAD
confirms the two-body/J2 dynamics, the Montenbruck & Gill analytic ephemerides, the solid-Earth tide
(IERS 2010 Eq. 7.5), Saastamoinen/Davis, all 45 Niell coefficients, the thin-shell obliquity, the
iono-free invariants, the FSPL/C-N₀ chain, the classical TWSTFT reduction, Teunissen's bootstrapped
success rate, Melbourne-Wübbena, the Clohessy-Wiltshire helix, the Joseph-form update and the exact
Gauss-Markov discretisation. Several implementation choices remain better than common practice: Sagnac
generated *by construction* in the four-timestamp event chain, fully correlated double-difference
covariances, per-source rebuilding of the iono-free measurement variance, and hard errors on oracle modes.

**Four findings of the previous edition are now dead, and that is to the codebase's credit.** The 2/N
flicker-synthesis defect is fixed **and committed** (`5995bfa`); the dual `legacy`/`jowTable2p1` clock
templates were removed outright, leaving a single catalogue whose 24 coefficients are digit-exact against
Winkel (2003) Table 2.1; the mislabelled TCXO/RUBIDIUM rows died with it; and the flicker-Q approximation
was replaced by an Allan-equivalent formulation that reproduces all three Brown & Hwang entries with the
correct Δt powers. The previous edition's own sourcing is corrected here too: **Van Dierendonck et al.
(1984) is not in `Paper/`**, so round 1's quotes of it were unverifiable in-repo — and Brown & Hwang state
that VD's eq. (60) q₁₂/q₂₂ are wrong, meaning round 1 anchored the clock Q on a known-erroneous form.
Round 2 re-anchors it on Brown & Hwang Ch. 11 directly, transcribed from the scan.

**The live problems have moved decisively into variance accounting.** This is also where the maintainer's
own recent work is concentrated (`03da4fb`, `6566cff`, `fe31d5b`), and the register in §A should be read
as continuing that programme rather than contradicting it. The single most consequential result:

> **The ionosphere R fix replaced one double count with a subtler one.** Commit `6566cff` correctly
> stopped R charging the full slow-ionosphere amplitude that the slant-iono state already carries, and
> derived the replacement factor as `√(1−e^(−2Δt/τ))`. But that factor times `σ_ss` is **exactly
> `√Q`** for the same state — verified numerically as `R_iono / q_iono = 1.000` at the golden's
> resolved values, and structurally so because both read the same `estimation.slantIono.tau_s`. R is
> therefore now charged with the state's own one-step process increment, which the predict step has
> already added to P. `S = H(FPFᵀ+Q)Hᵀ + R` counts that increment twice.

Alongside it, §A records: the troposphere twin of the guard that `03da4fb` proved inert (still unfixed,
and the code comment cites the troposphere as the *good* example to copy); an omitted correlation that
lets the filter average a per-tower hardware delay down by √8 using information it does not possess
(live in the golden baseline, one-word fix); an iono-free code row whose Jacobian asserts unit sensitivity
to a state its own `h` provably does not contain (demonstrated by finite difference, `|H − ∂h/∂x| = 1.0`);
an iono-free R that under-charges multipath by (α²+β²) — 8.87× at L1/L2 and **105.9× at Ka**; and a
multipath chain stepped four times per epoch on every non-primary signal, shortening its effective
correlation time from 60 s to 15 s in all three golden baselines.

**The most important structural lesson is about silent degradation.** Commit `889dcf6` records that the
four-timestamp chain threw an exception every epoch for every pair, was caught, and silently fell back to
a synthetic observable — so *"the real four-timestamp physics had never once run"* while the run honestly
recorded `shapeObservationSource = 'syntheticTwoWayISL'` and nobody read it. Verification confirms the
pattern is structural, not incidental: five silent-fallback returns in one solver, **zero assertions on
either fallback reason anywhere in the tree**, and the one test that reads the source string asserts the
*degraded* value — so it would have stayed green forever. Two of those five returns are self-validation
failures (a sign check and a metre-level range check) that downgrade rather than raise.

**What the simulation may claim, and what it may not.** §C is the honest boundary. The headline
constraints: the estimator is handed the truth's own process statistics (state σ = truth σ for both
atmosphere channels, and the EKF clock Q is built from the same h-parameters as the truth clock), so
NEES/NIS consistency is a perfectly-tuned-filter result and not evidence of consistency against a real
process; **no shipped configuration puts an ISL row into any EKF**, so every ISL-in-EKF number comes from
ladder rungs outside the regression gate; **no regression golden is collected by the automated test gate
at all** (`run_all_tests.m` globs `tests/test_*.m` only); validation in the NASA-STD-7009 sense has still
not been performed, and the repo's own manifest says so (`declaredNotStatisticallyExecuted`); and
Monte-Carlo consistency runs on the single-asset golden only — it is **hard-disabled on every multi-asset
path**, so every federated, swarm, distributed and attitude result rests on one deterministic run.

## Verification statistics, and how much weight each finding carries

| | Round 2 |
|---|---|
| Domain re-verifications | 9 |
| Defect claims raised | 163 (54 variance, 109 logical) |
| Claims adversarially verified | 163 (72 with a dedicated verifier each, 91 batched) |
| **Confirmed** | 96 |
| **Refuted** | 67 |
| Refutations re-audited for soundness | 8 — **none overturned** |
| Agents run | 102 (81 + 21), 13.3 M tokens, 0 errors |
| Quotes sampled against source PDFs | all sampled quotes verbatim; every apparent mismatch traced to a ligature or line-break hyphen |

The two passes were not equally adversarial and the document says so where it matters: the first assigned
**one verifier per claim** and refuted 68 %; the second batched seven claims per verifier and confirmed
80 %. §A and §B carry the hard-tested findings. §B2 carries the second-pass findings, flagged as such.
Findings labelled "measured" or "proven numerically" had a probe actually run and are the most solid in
the document, irrespective of which pass produced them.

**A worked example of the process correcting itself**, since that is the best evidence it functions: an
earlier draft of this executive summary stated that Monte-Carlo consistency is off by default. That was
read from `masterConfig.m`, where it is indeed `false`. `config/golden_baseline.json:355` overrides it to
`true` with 12 seeds. The claim was caught by a verifier that resolved the config instead of reading the
default — the exact discipline Appendix C prescribes — and the corrected finding (§B2-4) is more
interesting than the original: the Monte-Carlo gate that *does* run contradicts its own stated pooling
methodology.

---

# §0 What was fixed since the first edition — findings now dead

A traceability document that only accumulates defects becomes misleading. These entries from the
2026-08-06 edition were re-tested at `170e37d` and are **no longer true**. Each was verified by reading
the current code, not by trusting a commit message.

| First-edition finding | Status now | Evidence |
|---|---|---|
| **F1** — FFT colored-noise amplitude 2/N too small; "fix present in working tree, **uncommitted**"; flicker floor absent from every archived run | **DEAD — fixed and committed** | `+models/+clocks/ClockModel.m:234` now reads `A_frac = sqrt(max(Sy_frac,0) * fs * N) / 2`, the correct discrete one-sided synthesis. Committed in `5995bfa` (2026-08-08). The first edition's "uncommitted" sentence is now wrong. |
| **F3** — default asset clock `CESIUM1` + `legacy` template ~7 orders quieter than Winkel's caesium; headline sub-100-ps results ride on it | **DEAD — the dual catalogue was removed** | `cfg.clock.templateSource` was deleted on 2026-08-10 (`masterConfig.m:3317`, `realismGradeConfig.m:37`, `ConfigFactory.m:1913-1919` all record the removal). There is now **one** oscillator table, and re-verification checked **all 24 numbers (8 classes × 3 coefficients) digit-by-digit against Winkel (2003) Table 2.1, p. 100 — every one exact.** |
| **F6** — `jowTable2p1` TCXO and RUBIDIUM rows match no row of Winkel Table 2.1; OCXO retains a legacy `h₋₁` | **DEAD** — died with the dual catalogue. The removal commentary in `getClockTemplate_` documents precisely the mislabelling the first edition found. |
| **F7** — flicker Q term ≈14× below Van Dierendonck eq. (60) with the wrong Δt-scaling and no Q₁₂ term | **SUPERSEDED** | Replaced by an Allan-equivalent-RWFM formulation that reproduces **all three** Brown & Hwang flicker entries with the **correct Δt powers**, ratios 0.69 / 2.08 / 1.04. (The first edition's premise was also unsound — see Appendix B: VD's `q₁₂`/`q₂₂` are stated to be wrong by Brown & Hwang, and VD 1984 is not in `Paper/`.) |
| **F19 (part)** — `klobucharStatus='notImplemented'` printed over a shipped Klobuchar kernel | **FIXED** | `ErrorChain.m:648-653` now states the correct claim explicitly: the *mapping* is not Klobuchar's obliquity, but "Klobuchar itself IS implemented (models.atmosphere.Klobuchar) and is applied on the model side of the 'tecGaussMarkov' branch"; the old wording is called out as having "contradicted the shipped kernel". |
| **Iono variance owned in two places** (not in the first edition; found by the maintainer) | **FIXED, then partially re-opened** | `03da4fb` named and measured it; `6566cff` fixed the R half with a derived factor. See **A1**: the replacement factor is exactly `√Q` for the same state, so the increment is now charged in both Q and R. |
| **Four-timestamp chain throwing every epoch and falling back silently** | **FIXED** | `889dcf6` supplies the missing `getOscillatorDriftMetersPerSecond` and — importantly — **requires** `truthRelativisticFracFreq` rather than defaulting it to 0, so a silent 0 cannot re-create a `y_rel` double count. The structural pattern remains (see **B1**). |
| **ISL code and Doppler rows never carried the relativistic term** | **FIXED** | `9a52cfc`, at all five sites. Measured mean NIS 735,108 → 95.35 against ~105 rows/epoch. |

## Practices worth crediting explicitly

Several habits in this repository are better than normal research-code practice, and the registers above
should not obscure them:

- **Refuse, don't silently drop.** Config leaves that are declared but unwired raise errors rather than
  no-op: `FourTimestampGroundSpaceTimeTransferBuilder.validateConfig` loudly refuses five separate
  unwired features; `EnvironmentModel.m:250` hard-errors on the `sameAsTruth` oracle read;
  `ClockModel.m:142-151` warns that a removed knob is being ignored rather than accepting it.
- **Name the defect in place.** `ErrorChain.m:829-843` carries a full forensic account of the ionosphere
  double count — what was measured, when, why the old guard protected nothing, and what the correct fix
  would require — inside the code it describes. `9650bcd`, `03da4fb` and `6566cff` do the same in their
  commit messages, including an explicit **retraction** of an earlier claim (`fe31d5b`'s
  `H·P·Hᵀ ≈ 1.01·R`) once its algebra was found invalid.
- **Derive, don't tune.** `6566cff` insists the R scale be derivable from two config lines and states
  plainly that picking it by "tuning until one run's NIS reaches 1" would be fitting R to truth. That is
  the right instinct even though this audit finds the particular derivation lands on `√Q`.
- **Measure the blast radius before claiming safety.** `9a52cfc` resolves *every* shipped config to show
  `measurements.isl.enable = 0` everywhere before asserting zero impact.
- **Record when a golden is stale.** `889dcf6` states that `swarm_relative_baseline.mat` already fails on
  a clean tree, verified by stashing, and was not recaptured — rather than quietly re-cutting it.

---

# §A Register A — Variance accounting: double counts, omitted correlations, mis-colourings

Every entry below survived an adversarial pass whose instruction was to refute it. Each carries a
**liveness** label decided by resolving the actual shipped configuration, not by reading source alone:

- **LIVE-IN-GOLDEN** — active in `golden_baseline.json` and therefore in the headline results
- **LIVE-IN-LADDER-ONLY** — active in one or more shipped ladder rungs, not in any golden
- **LATENT-DEFAULT-OFF** — real, but no shipped configuration reaches it
- **CLEARED** — investigated and found *not* to be a defect (recorded so it is not re-litigated)

A note on direction, which matters more than magnitude: an **over-charge** de-weights a row and is
conservative; an **under-charge** or an **omitted correlation** makes the filter over-trust a measurement
and is anti-conservative. Both are defects, but only the second can make a covariance dishonest in the
optimistic direction.

---

## A1 — The ionosphere R fix charges the state's own process increment in R as well as Q  ⚠️ LIVE-IN-GOLDEN

**The finding.** `S = H(FPFᵀ + Q)Hᵀ + R` carries the slant-iono one-step Gauss-Markov increment twice.

- **Q side**: `+filter/ReverseGNSSEKF.m:1615-1616` — `phi_iono = exp(-dt/tau_iono);
  q_iono = sigma_iono^2 * (1 - phi_iono^2)`, added to P⁻ on every predict step (F = φ at `:1415`).
- **R side**: `+revgnss/ConfigFactory.m:2692` derives `rScaleF_ = sqrt(1 - exp(-2*dt/tau))` from the
  **same** `estimation.slantIono.tau_s` and the same `dt`; `+models/+errors/ErrorChain.m:875` applies it
  as `sigmaBase = sigmaBase * rScale_`.

Because `σ_ss · √(1−e^(−2Δt/τ)) = √Q` identically, the R term **is** `√Q` for that state. Verified live
on the resolved `golden_baseline.json` (ionosphereMode = perTowerSlant, τ = 600 s, σ_ss = 1 m, dt = 1 s,
rScale = 0.0576869477913): `q_iono = 0.00332778394548 m²`, `R_iono (zenith-equivalent) =
0.00332778394548 m²`, **ratio exactly 1.000** — structural, not coincidental.

**Why this is subtle rather than obvious.** Commit `6566cff` is right that a quantity carried by a state
must not also be charged in R, and right that the correct residual is "what the state fails to absorb".
Its error is in identifying that residual with the process increment. The increment is what the *state's
own uncertainty grows by* between updates; it is already inside P by the time the update runs. What R is
supposed to hold is the **measurement** error of the row — the part of the observable that no state
explains — which for a perfectly tracked GM process tends to the *measurement noise floor*, not to √Q.

**Consequence.** Conservative in direction (S is inflated, NIS depressed), and small in absolute terms:
the term is 0.0033 m² against a mean code R of 7.8–8.0 m². It matters because it is the analytical
justification, not the number: the commit presents the factor as "the standard Kalman statement" and a
reviewer who re-derives it will find it is √Q. Recommend restating the derivation, or setting R's
ionosphere term from the measurement-side residual the model pair actually leaves.

**Adversarial note.** The verifier confirmed the identity is exact and structural, and independently
resolved the config rather than trusting the commit message.

---

## A2 — The troposphere ZWD double-count guard protects nothing  ❌ LIVE-IN-GOLDEN

**The finding.** `+models/+errors/ErrorChain.m` assembles the troposphere R term at `:627` as
`sigma_m = sqrt(sigmaBase.^2 + sigmaStochR.^2)` from two independent feeders:

- `sigmaBase` (`:592-597`) — `tc.sigma_m * mappingFn(elv)` with `errors.troposphere.sigma_m = 0.15` m
  (`masterConfig.m:141`). **Never scaled by any state-aware factor.**
- `sigmaStochR` (`:618-626`) — zero unless `residualOn = stochastic.enable && modelResidual.enable`.

The ZWD guard at `:599-617` computes `sigmaWetR = σ_ss·√(1−e^(−2Δt/τ))` when
`estimation.troposphereMode == 'perTowerZwd'`, but `sigmaWetR` reaches R **only** through `sigmaStochR`
(`:623`). Since `errors.troposphere.stochastic.modelResidual.enable = false` everywhere shipped
(`masterConfig.m:2318`, and `:944` in the realistic profile), `sigmaStochR ≡ 0` and the guard's output is
multiplied into nothing — while `sigmaBase` charges the full 0.15 m × mapping for a slow wet delay the
ZWD state is tracking.

**The state is genuinely active**: `config/golden_baseline.json:57` sets
`"troposphereMode": "perTowerZwd"`, asserted by `tests/test_golden_baseline.m:147`
(also `golden_baseline_multi.json:53`, `golden_baseline_attitude.json:43`, realistic profile `:945`).
Repo-wide search finds **no second location** that reduces R for the ZWD state; there is no
`rScaleWhenStateActive` twin for the troposphere (that lever exists only for the ionosphere,
`masterConfig.m:174`).

**This is the identical defect the ionosphere had, and the code says so in the wrong direction.**
`ErrorChain.m:829-843` documents for the ionosphere: *"the guard reduces a quantity that is already nil
and protects nothing, while the term it does not touch is the entire charge"*. The fix (`6566cff`)
applied `rScale_` **to `sigmaBase`** (`:875`). The troposphere never received that treatment — and the
comment introducing the ionosphere fix (`:791`) calls it *"twin of the ZWD case in troposphere_"*, i.e.
the ZWD case was taken as the model to copy when it has the same blindness.

**Measured consequence** (project's own instrumentation, `03da4fb`, 200 epochs on `golden_baseline`):
troposphere charged 0.0445 m² against 0.00109 m² actual = **40.7×**, the largest per-source ratio in that
table; ~1–2 % of code R. Direction conservative.

**Honest scope limit.** Unlike the ionosphere case — where `estimation.slantIono.sigma_ss_m` and
`errors.ionosphere.sigma_m` were literally the same number (1 m), i.e. provably the same physical
quantity — here the state σ (0.05 m wet) and the R σ (0.15 m declared zenith model uncertainty) are
different quantities that only **partially** overlap. The ZWD state absorbs the slow wet part, not the
whole declared model bias, so the correct scaling applies to the wet fraction only and should be
characterised over the model pair exactly as `6566cff` prescribes — never tuned until NIS reaches 1.

*(Found independently by the coordinator and by the atmosphere domain agent; confirmed adversarially.)*

---

## A3 — Hardware delay: R treats as independent what the truth makes perfectly correlated  ❌ LIVE-IN-GOLDEN

**The finding.** An omitted correlation, not a double count — the opposite sign, and anti-conservative.

- **Truth side is ρ = +1 by construction.** `+models/+errors/ErrorChain.m:926-931` draws the hardware
  delay with an **empty antenna argument**, so `drawWhiteVec_` (`:433-440`) calls
  `registry.epochStream(src, node, 0, 0, ep)` and every row of the same tower gets a bit-identical
  substream and therefore an identical draw. `+models/+measurements/CodeMeasurementBuilder.m:544-545`
  then reuses `hw_t`/`hw_m` unchanged on every signal row (deliberately: the dispersive part is the
  separate DCB channel at `:541`). Net: **8 code rows per tower per epoch** (4 antennas × 2 signals)
  carry a bit-identical hardware-delay error.
- **R side treats them as independent.** `ErrorChain.m:394-407` sums `hwDelay` into `sigmaTotal` →
  `sigmaExtra_m`; `CodeMeasurementBuilder.m:590-594` adds it to every signal row's diagonal. The only two
  off-diagonal writers in the code block are `:1089` (tower clock) and `:1130` (`corrSrcs_`), and
  `corrSrcs_ = {'trop','iono'}` at `:1118` — **no hwDelay off-diagonal exists anywhere in the tree**.

**Live in the golden baseline**, verified by resolving it: `hw.truth.enable = 1`, `hw.sigma_m = 0.05`
(set explicitly in `golden_baseline.json`), `codeMode = singleFrequency` with two signals enabled, so the
raw dual-frequency path plus the common-mode block at `:1115` is the live path.

**Consequence.** R charges 0.05² = 2.5e-3 m² on each of the 8 diagonal entries and **0 on all 56
off-diagonal entries** of that tower's block, where the correct R adds 2.5e-3 m² to each. The EKF can
therefore average a per-tower common bias down by **√8 = 2.83** (0.050 m → 0.018 m) using information it
does not possess. In context the missing covariance is ~0.1–0.2 % of a row's variance, so the effect is
real but small — it would become significant if a hardware-delay ablation raised σ toward the realism
overlay's 0.5 m (`realismGradeConfig.m:69`), where the term reaches 0.25 m² per row.

**The file contradicts itself.** `golden_baseline.json`'s own `hardwareDelay._why` states the error *"is a
per-TOWER error and is therefore common to all four antennas, which the code already models correctly"* —
true of the truth side, false of R. The iono-free path proves the intended treatment is understood:
`CodeMeasurementBuilder.m:857-862` comments that hardware delay *"passes the IF at unit gain, NOT
(alpha^2+beta^2)"* and `:939` implements it.

**Fix.** One list entry: `corrSrcs_ = {'trop','iono','hwDelay'}` at `:1118`. The correctly shaped
unscaled M×1 vector the block needs is already produced at `:663-669`. That the fix is a one-word
omission with all plumbing present is itself evidence it was an oversight, not a modelling decision.

---

## A4 — Iono-free code R under-charges multipath by (α²+β²)  ❌ LIVE-IN-LADDER-ONLY

**The finding.** The IF rebuild strips multipath from both constituent rows and re-adds **one** copy at
unit gain, on the premise that one realisation is copied onto both rows — a premise that stopped being
true 24 minutes after it was written.

- Strip: `+models/+measurements/CodeMeasurementBuilder.m:890-891` (`+ sigMp_.^2` inside
  `corrBaked_L1_`/`corrBaked_L2_`); re-add: `:937` (`+ sigMp_.^2`, commented *"multipath: one realisation
  on both rows -> unit gain"*).
- But the truth side draws **independently per signal**: `+models/+errors/ErrorChain.m:106-117`
  (`multipathForSignal`) keys a separate GM state `ti*1e6 + aiKey*1000 + si` with its own substream,
  consumed at `CodeMeasurementBuilder.m:561-563`. The base chain at `ErrorChain.m:968` uses a different
  key — genuinely different chains, and independence does not even depend on the RNG-registry gate.

Net gain applied `(α+β)² = 1` against a true IF variance of `(α²+β²)σ²`.

**Chronology, from git.** `05a3fa2` "fix(R): one tower clock is ONE error" (2026-08-10 18:04:57)
introduced the strip; `9650bcd` "fix(multipath): L1 and L2 must be independent realisations, not one
copy" landed at 18:28:22 — **24 minutes later**. The comment's premise was true when written and false
24 minutes on; its own instruction (*"If multipath is ever drawn per signal, move it back into the
bundle"*) was never executed. The file holds both models at once: `combineIfSources_:1282-1283` reports
`sqrt(α²s₁² + β²s₂²) = 2.978σ` while R charges `σ` — reporting-only, but it proves the contradiction is
internal.

**Consequence.** Shortfall per IF row `(α²+β² − 1)σ_el² = 7.870 σ_el²` for GPS L1/L2
(α = 2.545727, β = −1.545727, √(α²+β²) = 2.9782 — the same 2.98× the golden baseline documents). At
`sigmaCodeL1_ss_m = 0.30`: at 22.6° elevation, charged 0.6095 m² against a correct 5.406 m² (short
4.80 m²). **For the Ka 30/28 GHz pair of `test009` the factor is 105.9× in variance, not 8.87×.**
Direction: R too small → the filter over-trusts IF code rows → optimistic covariance.

**Liveness.** Both gates must be on and `masterConfig` defaults **both** off
(`coloredGM.enable = false` at `:2414`, `codeMode = 'singleFrequency'` at `:3143`). Not live in any
golden — `golden_baseline.json:39` states explicitly that `ionosphereFree=false` leaves
`codeMode='singleFrequency'`, chosen because "IF halves the code rows and amplifies noise by 2.98x"; only
the *carrier* rows are IF there. It **is** live in four shipped rungs:
`config/ladder/freq/freq003_L1L2ionoFree.json`, `freq004_L1L2ionoFreeNoIonoState.json`,
`freq006_L1L5ionoFree.json` (all `_extends: golden_baseline.json`, inheriting `coloredGM.enable=true`),
and `config/ladder/test/test009_kaIonoFree.json` (via `realism.grade`).

**Fix.** Delete `+ sigMp_.^2` from `:890-891` and `:937`, letting `α²·Rindep_L1 + β²·Rindep_L2` carry it —
which also makes R agree with what `combineIfSources_` already reports.

---

## A5 — The per-signal multipath chain is stepped once per row, shortening its correlation time  ❌ LIVE-IN-GOLDEN

**The finding.** `multipathForSignal` (`+models/+errors/ErrorChain.m:102-117`) has no `sharedThisCall`
memo. Its single call site (`+models/+measurements/CodeMeasurementBuilder.m:561-562`) sits inside
`for pi = 1:M_pairs` inside `for si = 1:N_sig`, so the state is read, stepped and written **on every
row**. The base chain has exactly the guard that is missing: `ErrorChain.m:963` creates a
`sharedThisCall` map, `:972-976` reuse the already-stepped value and `continue`, and its own comment at
`:956-962` states the reason — stepping once per row *"would advance the chain N times per epoch and give
the antennas N successive samples instead of one shared one"*.

**Live in all three golden baselines**, contrary to the expectation that they are single-frequency:
resolving them gives `N_sig = 2`, `enabled = {L1,L2}`, `nReceivers = 4`, `mpShared = 1`.

**Measured** (resolved `golden_baseline`, tower 1, 300 epochs, dt = 1 s, τ = 60 s, elev 35.8°):
L1 inter-antenna spread exactly 0; L2 spread 0.4236 m. Lag-1 autocorrelation L1 0.9721 (theory
φ = 0.98347 less finite-sample bias = 0.9704); L2 0.9239 (theory φ⁴ = 0.93551 less bias = 0.9228). Both
match to < 0.002, confirming the L2 chain is stepped **exactly 4× per epoch**: **τ_eff = 15 s instead of
60 s**. R is unchanged (the tiling at `:667` copies the L1 σ and 4× stepping preserves stationary
variance), so **NIS is blind to it**.

**The consequence is temporal, not spatial** — the verifier corrected the original claim here. Four
successive AR(1) samples are 94–98 % correlated, so the inter-antenna averaging artefact the gate exists
to remove is ~98 % still removed on L2 (measured `std(mean of 4)/std(ant1) = 0.9988` against 0.5 for
independent draws). The real cost is that shortening the correlation time from 60 s to 15 s reduces the
variance of any **time average** of the L2 multipath over an arc by 4× (Var of an OU time-average
≈ 2σ²τ/T), i.e. a genuine free factor of 0.50 in σ on L2 rows. Ironically the antenna-sharing gate
*introduces* it: with the gate off the key is `(ti,ai,si)` and each chain steps once per row, so τ is
correct.

**Corroborating detail.** `golden_baseline.json:120`'s note "measured inter-antenna spread exactly 0" can
only have been measured on the L1 row.

**Fix.** Give `multipathForSignal` the same `sharedThisCall` memo, keyed `(ti, si)`.

---

## A6 — The same broadcast-product realisation is charged independently to the ISL code and carrier rows  ❌ LATENT

`+revgnss/ISLMeasurementBuilder.m` draws one product bias per (tx, interval) at `:187`; `rTxProd`/
`btxProd` are formed once at `:189`/`:191`. The code legacy branch consumes them at `h:233`/`Rii:234` and
the carrier legacy branch at `hc:318`/`Rc:319`, so both residuals carry the identical `+u'·pb.pos + pb.clk`
term (correlation exactly +1 on that component). `append_:730` is an unconditional `blkdiag` and
`ReverseGNSSSimulation.m:643` blkdiags `R_isl` into the stack with no post-processing — **no off-diagonal
is ever written for ISL rows.** Two rows carrying an identical error term are presented to the filter as
independent measurements. Latent: `measurements.isl.enable = 0` in every shipped configuration.

## A7 — ISL piecewise-constant product error charged as per-epoch white R  ❌ LATENT (standing finding, re-confirmed)

`ISLMeasurementBuilder.m:234` (code), `:260` (Doppler), `:319` (carrier) add
`product.sigmaPos_m^2 + product.sigmaClock_m^2` as white per-epoch variance, while `productInterval_`
(`:637-647`) / `productBias_` (`:649-662`) draw that error **once per `updateInterval_s`**. Measured on
the public accessor at `isl017`'s settings (σ_pos 0.03, σ_clk 0.02, interval 300 s, dt 1 s, seed 42):
`pb.pos(1) = +0.042588422990` identically at t = 0, 1, 2, 150, 299, stepping to `−0.031176762628` at
t = 300 and holding to 599. Over a 3600 s arc: **3601 epochs but 13 distinct draws — ratio 277, √ = 16.64**.
The filter is permitted to average the error down by up to 16.6× more than the physics allows.
The rule is enforced elsewhere in the same repo (`TwoWayISLMeasurementBuilder.m:242-278` hard-errors on
exactly this pattern; `SwarmRelativeSolver.islNoise_` inflates by `nCorr`), which makes this the
surviving exception rather than an oversight of principle.

## A8 — Tower-clock error charged as two independent nuisances across code and Doppler  ⚠️ LIVE-IN-GOLDEN

The same broadcast-product realisation reaches the code diagonal (`CodeMeasurementBuilder.m:594`, and at
unit gain in the IF collapse at `:938` — which is the row the golden EKF actually inverts, since
`measurements.code.ionosphereFreeRows.useInEkf = true`) and the Doppler diagonal
(`DopplerMeasurementBuilder.m:276-282`), while `cfg.covariance.productClock.crossCodeDoppler` defaults
**false**, so the cross-block that would tie them is never written. The bias and its own drift are
physically one error observed two ways; treating them as independent lets the filter extract information
that is not there. Direction: anti-conservative.

## A9 — Four-timestamp builder inflates the oscillator wander by nCorr  ❌ LATENT

`+revgnss/FourTimestampGroundSpaceTimeTransferBuilder.m:181` computes
`Ri = sigma_m^2 + nCorr * towerClockSigma_m^2`, charging `nCorr` copies of the **whole** provider sigma —
product bias *and* free-running oscillator wander. The legacy sibling 70 lines away does it correctly:
`TwoWayTimeTransferBuilder.m:262-292` calls `productOnlySigma`, forms
`wanderVar_ = sig_prod^2 − sConst_^2`, and applies `Ri + nCorr*sConst_^2 + wanderVar_`. Root cause at
`:109-110`: the four-timestamp builder calls `TowerClockCorrectionProvider.compute` with only three
outputs, so it never receives `t_prod`, cannot form the correction age, and **cannot call
`productOnlySigma` at all** (that function's own header names the legacy builder as its consumer, and it
has exactly two callers, both in the legacy file). Measured at resolved defaults (nCorr = 30, OCXO):
σ_legacy 2.4172 m vs σ_4ts 13.2337 m at age 34 s — **5.47× in sigma, 29.9× in variance**, reproducing the
legacy file's own pre-fix pair to four digits. Chronology: the four-timestamp file predates the legacy
split (`1ec5894`, 2026-08-10), which was never back-ported. Direction conservative; latent because no
shipped scenario selects `mode='fourTimestampClockDifference'`.

## A10 — Model-side relativistic clock bias omitted on the four-timestamp channel  ❌ LATENT

The published relativistic term is applied on the code (`CodeMeasurementBuilder.m:73-74`), carrier
(`CarrierMeasurementBuilder.m:72-73`), Doppler (`DopplerMeasurementBuilder.m:139-140`), ISL
(`ISLMeasurementBuilder.m:179-180`) and legacy two-way (`TwoWayTimeTransferBuilder.m:166-167`) channels,
but **not** on the four-timestamp ground-space channel: `FourTimestampEstimatorEndpointBridge.m:98,161`
take `clockBiasOverride_m = x(blk.b)` with no relativistic term, while the truth side of the same row
carries the full ramp (`ReciprocalEndpointTruthProvider.m:35` → `ClockModel.m:335`). The two families
therefore define the EKF state `x(b_rx)` incompatibly — oscillator-only versus total. Confirmed
empirically with a 60-epoch live run: at t = 59 s the per-row difference is 9.509 m against a predicted
`c·y_rel·t = 9.5297 m` (the 0.02 m deficit is exactly the half-round-trip light time), and identically
zero with relativity off. Worth `c·y_rel = 0.1615 m/s`, **581 m over a 3600 s arc**, against a declared
row sigma of 0.03 m. The proper-time machinery covers the **rate** half of the convention deliberately
and correctly (`TwoWayCodeEndpointModel.m:105-117`) and the **bias** half not at all. `validateConfig`
loudly refuses five other unwired features on this path and says nothing about relativity. Latent: the
two preconditions never co-occur in any shipped configuration.

---

## Cleared — investigated and found not to be defects

- **Clock flicker is not double counted between truth and filter.** The truth-side coloured sequence
  (`ClockModel.m:227,244-247`) is independent of the two-state Cholesky draw at `:295-315`, which uses
  only `q1 = h0/2` and `q2 = 2π²h₋₂` — `hMinus1` appears nowhere in it. The coloured value is read as an
  absolute sample and added exactly once by each accessor. The filter's `q2_ffm = 6·ln2·h₋₁/dt` is the
  Allan-equivalent representation of the same physics in Q, which is the correct place for it.
- **Scintillation is added exactly once per row.** The multi-signal branch adds it per signal
  (`CodeMeasurementBuilder.m:449` primary, `:594` secondary); the single-frequency branch adds it once at
  `:752-755`. These are the two arms of one `if/else` (the `else` opens at `:723`).
- **Tower-clock variance is charged once per row.** Base R includes it with an inline state-aware mask
  (`:316-322`); secondary rows **rebuild** R from components and add it explicitly (`:593-594`) rather
  than inheriting the base value.
- **`measurements.isl.product.enable=false` removes the R contribution as well as the injected bias.**
  `ISLMeasurementBuilder.m:531` is the only construction of `info.product` in the tree; `productCfg_`
  (`:631-633`) zeroes every sigma when disabled and `productBias_` (`:656`) short-circuits to zeros, and
  every R site reads the zeroed struct. So `isl016` charges `carrierSigma_m^2` only and does not inflate
  R for an error it never injected.
- **Truth-side and model-side relativity subtract by design** rather than double counting;
  `RelativisticClockCorrection` returns exactly 0 unless `physics.relativity.clock.model.enable`.
- **The replay path correctly avoids a real double count.** `SimulationDataStore` records the *total*
  clock rate including `y_rel`, while the four-timestamp endpoint separately supplies
  `properTimeRate`; feeding the total would count `y_rel` twice at `c·y_rel = 0.1615 m/s` per endpoint.
  `889dcf6` subtracts it in the replay clock and **requires** the field rather than defaulting it to 0,
  precisely so a silent 0 cannot re-create the double count. This is the model treatment of the class.

## Latent inconsistency noted in passing

The measurement sigma **floor** has different semantics on primary and secondary rows: base/primary
applies `max(sigma_i, sigmaFloor)^2` to the **total** including the tower clock (`:322`), whereas
secondary rows apply the floor to the **code component only** and add scintillation, extra and
tower-clock variance on top (`:593-594`). When the floor binds, secondary rows receive systematically
more variance than primary rows for the same physical link. `fe31d5b`'s measured budget reports no floor
hits, so this is currently unreachable, but the floor's meaning should be made uniform.

---

# §B Register B — Logical flaws

Defects of *reasoning* rather than of arithmetic: gates that do not gate, contracts that no longer
describe the code, failures that degrade silently, and tests that cannot fail. These matter
disproportionately in a simulation, because each one makes some other evidence untrustworthy.

---

## B1 — Silent degradation is the default failure mode of the four-timestamp replay  ❌ LIVE

**The pattern, with proof it has already bitten once.** Commit `889dcf6` records that
`TruthEndpointReplayClock` lacked `getOscillatorDriftMetersPerSecond`, which
`ReciprocalEndpointTruthProvider.spacecraft` calls on the proper-time path. It threw *"Unrecognized
method"* **for every pair and every epoch**; `SwarmRelativeSolver.fourTimestampObservables_` caught it and
the federated relative layer fell back to the synthetic observable throughout. In the commit's own words:
*"The real four-timestamp physics had never once run. shapeObservationSource honestly recorded
'syntheticTwoWayISL' the whole time; nobody was reading it."*

**The pattern is structural, not incidental.** Verified at HEAD in
`+revgnss/SwarmRelativeSolver.m` (1421 lines, **zero `error()` calls**): `fourTimestampObservables_`
(from `:1211`) returns empty-plus-reason at five sites — `:1244` (unusable payload), `:1262` (setup
catch), `:1297` (observable-build catch), `:1319` (sign check failed), `:1342` (range check failed).
**The last two are self-validation**: the code detects a sign error or a metre-level range-bookkeeping
error and then *downgrades to the synthetic observable rather than raising*.

**Nothing asserts on the outcome.** Repo-wide search for `shapeObservationSource`,
`relClockObservableSource` and `*FallbackReason` finds only reporting consumers
(`FederatedSwarmSummary.m:85,110` — which carries the *source* but never either reason;
`SwarmReportReplay.m:382,384`; `BeamformingPhasorDiagnostics.m:315-316`; `RelativeErrorFigures.m:147`)
and two evidence-row formatters. **Zero assertions on either fallback reason exist anywhere in the tree.**

**The one test that reads the source string locks in the degraded path.**
`tests/test_swarm_two_way_isl_gating.m:37` asserts
`strcmp(relOn.shapeObservationSource,'syntheticTwoWayISL')`. Its fixture supplies no `truthVelTraj`, so
`TruthEndpointReplay.unusableReason` returns `'missing:truthVelTraj'` and the solver takes the `:1244`
return. The assertion is correct for that input but **would have stayed green even if the real chain were
broken for every input — which is exactly what happened.** The indirect numeric gate does not cover it
either: `tests/regression/run_swarm_relative_regression.m` digests only numeric fields (no source string,
no reason), is not collected by `tests/run_all_tests.m` (which globs `tests/test_*.m` only), and its
baseline `swarm_relative_baseline.mat` was captured while the path was silently falling back — `889dcf6`
states it already fails on a clean tree and was not recaptured.

**Consequence.** Provenance, not magnitude: `889dcf6`'s own A/B gives shape 0.0457 m either way and
relative clock 0.0218 → 0.0239 m (+9.6 %). But the reported observable is *labelled* a real
four-timestamp two-way range carrying retarded-time light travel, endpoint motion, terminal and turnaround
delays and attitude-rotated phase centres, while the delivered number was `|r_i − r_k|` from truth plus
bias and thermal noise. **That small delta is precisely why a bit-exact numeric digest is a poor proxy
gate.** Any pre-`889dcf6` four-timestamp result is invalid.

**Fix.** A `tests/test_*.m` file that, on a real recorded federated result with both gates on, asserts
`isempty(shapeFallbackReason) && isempty(relClockFallbackReason)` and that both source strings equal their
four-timestamp values.

---

## B2 — An iono-free code row's Jacobian asserts sensitivity its own `h` does not contain  ❌ LIVE-IN-LADDER-ONLY

**Proven by finite difference, not by reading.** On a resolved `dualFrequencyIFConfig` with
`estimation.ionosphereMode='perTowerSlant'`:

```
row |  H(:,ionoIdx(1))  |  (h(x+10m)-h(x))/10  |  mismatch
  1 |      1.000000000  |       0.000000000    |   1.000e+00
max|H - dh/dx| = 1.000000e+00
```

**Mechanism.** `h` adds `freqScale · x_iono` per signal (`CodeMeasurementBuilder.m:646-649`, with
`freqScale = (f_L1/f_sig)²` at `:423`); the IF collapse at `:806` cancels it **exactly**
(`α·1 + β·(f1/f2)² = −4.4e-16`). But `errStruct.frequencyHz_perMeas` is then compressed to the L1 rows
(`:967-979`), and `H` is rebuilt **afterwards** off that compressed vector
(`+models/+measurements/MeasurementModel.m:229-237`), so `f_row = f_L1` and
`H(row, ionoIdx) = (f_L1/f_row)² = 1.0`. This is correct for every **non-dispersive** state (geometry, rx
clock, tower clock, ZWD) because `α + β = 1`, and wrong for exactly the one dispersive state.

**Consequence** (resolved `freq003`, 20 IF code rows): `P₀(iono,iono) = 25 m²` per tower
(`slantIono.initialSigma_m = 5 m`) against `R = 1.577–4.208 m²`. The phantom column adds the full 25 m²
to `S = HPHᵀ + R`, inflating S by roughly **7× to 16×** at t = 0, and the gain
`K = PHᵀ/S ≈ 25/(25+R) ≈ 0.86–0.94` routes ~90 % of every IF code residual into a state that provably
cannot move that residual. The state is driven purely by residuals carrying zero ionospheric information.

**The guard that names this precondition does not implement it.**
`+revgnss/CodeIonoFreeConsistencyDiagnostics.m` `hCompatibility` returns 'assumption-compatible' with the
prose *"...and no ionosphere state or signal-dependent code-bias states are active"*, but the only
condition it tests is `estimator.estimateTxCodeBias`. It never reads `estimation.ionosphereMode`, so it
classifies `freq003` as compatible. Nor does config forbid the pair: `ConfigFactory.m:555-558` errors only
on `atmosphere.ionosphereFree && atmosphere.estimateIono`, while the ionoFree branch sets only
`cfg.measurements.codeMode` and never touches `cfg.estimation.ionosphereMode`. Resolved for real:
`freq003` → `codeMode=ionosphereFree` **and** `ionosphereMode=perTowerSlant`. (`freq004` and `freq006`
both resolve to `ionosphereMode=none`, so they are unaffected; the golden resolves to
`codeMode=singleFrequency`, where `H = 1.0` **is** correct.)

**No test pins it either way** — `test_if_ekf_row_count.m`, `test_stage45/46`,
`test_code_dcb_active_path` and `test_code_iono_higher_order_multisignal` assert row counts, the
`ifCombination` flag and z-side cancellation; none finite-differences `H` against `h`.

**Second site, same root cause.** `+revgnss/PseudorangeModelOnlyBuilder.m:103-110` repeats the pattern on
the postfit path, adding `1.0 · x_iono` to a postfit `h` whose `modelTotal_m` was already overwritten with
the IF-combined total (in which the ionosphere cancelled), so postfit residuals on IF rows are
contaminated by the raw state value.

**Fix.** Set `H(row, ionoIdx) = 0` on IF code rows (equivalently `α·1 + β·(f1/f2)²`), or gate the iono
state off whenever `codeMode='ionosphereFree'`, as `freq004` and `freq006` already do by hand.
**The correct treatment already exists in the carrier path**: `CarrierIonoFreeRowBuilder.m:193` does
`H_IF = α·H(idx1,:) + β·H(idx2,:)`.

---

## B3 — `getProcessNoiseQ`'s docstring describes a Q the function no longer computes  ❌ LIVE

Three separate comment blocks in `+models/+clocks/ClockModel.m` (`:53-55` class docstring, `:462-467`
method docstring, `:473-477`) state `Q_11 = (h0/2 + 2ln2·h₋₁)·dt`, `Q_22 = 2π²h₋₂·dt` with **no flicker
term in Q₁₂ or Q₂₂**, define `q_f = 2ln2·h₋₁`, and say the flicker path is *"Gated by driftFlickerInQ
(default false)"*. The implementation 30 lines below computes
`q2_ffm = 6·ln2·h₋₁/dt` and `q2_eff = q2 + q2_ffm` (`:519-524`), then uses `q2_eff` in **all four**
entries (`:538-539`). No variable named `q_f` exists. `driftFlickerInQ` has been **removed** — supplying
it raises `ClockModel:driftFlickerInQRemoved` and the value is ignored (`:142-151`) — and the real gate
`flickerAsEquivalentRwfmInQ` defaults **true** (`:102`) and is referenced nowhere outside the file, so
the flicker term is **on in every run**. The documented default is exactly inverted.

**Numerical consequence at the shipped operating point** (`asset.clockType='CESIUM1'`, dt = 1 s;
h₀ = 1e-19, h₋₁ = 1e-25, h₋₂ = 2e-32): documented `Q₂₂ = 3.948e-31` versus actual `4.159e-25` — a ratio of
**1.05e6 in variance, 1026× in sigma**, which is precisely the "predicted 1027×" the code itself cites at
`:506`. Q₁₂ carries the same factor. Across the catalogue the doc-to-actual variance ratio is RUBIDIUM1
3.7e4, RUBIDIUM2 1622, OCXO1 11.5, OCXO2 1.02, TCXO 1.11, QUARTZ 1.07 — so the docstring is nearly right
for the OCXO towers and wrong by six decades for the CESIUM1 asset, **the worst possible failure mode for
a reader**, since the tower case "checks out" by inspection. (Q₁₁ happens to agree at dt = 1 s, because
`q2_ffm·dt³/3 = 2ln2·h₋₁·dt²` equals the documented `2ln2·h₋₁·dt` only there; they diverge linearly in dt.)

---

## B4 — The toggle manifest reports the ZWD state inactive in every run, testing enum values that cannot exist  ❌ LIVE

`+revgnss/SimulationToggleManifest.m:975`:

```matlab
tropoZwd_en_ = strcmp(tropoMode_,'ekf') || strcmp(tropoMode_,'zwdEkf');
```

The legal values of `estimation.troposphereMode` are `{'none','perTowerZwd'}`, pinned by
`config/internal/configEnumRegistry.m:62`, whose own note reads: *"Compared by strcmp against
'perTowerZwd' in ReverseGNSSEKF, TroposphereModel and ErrorChain; anything else silently means 'no ZWD
state'."* Neither `'ekf'` nor `'zwdEkf'` is legal, so **`tropoZwd_en_` is always false**. At `:997-1000`
the manifest therefore renders the `troposphereMode` row as permanently **inactive** — including on
`golden_baseline`, where `tests/test_golden_baseline.m:147` asserts the state *is* active — advertises an
impossible precondition string (`'estimation.troposphereMode=ekf'`), and describes modes that cannot be
set. Any traceability table generated from the manifest under-reports the estimator's state vector.
The enum registry cannot catch this, because it validates **config values**, not the manifest's
comparison strings.

---

## B5 — A formation guard that does not protect the target it names, and a docstring the test cannot contradict  ❌ LIVE

`+revgnss/SwarmFormation.m:176-179` warns only `if baseline < 500`, never consulting
`crossTrackSpread`. At the shipped `cfg.formation.crossTrackSpread = 1.0`, `:111`
(`ca = 1 + s·(2(i−1)/(nSec−1) − 1)`) fans the cross-track amplitude over `[1−s, 1+s]`, so member 1 gets
`ca = 0` **exactly** (verified: `crossAmp = [0, 0.5, 1.0, 1.5, 2.0]` for `nSec = 5`), and with `ca = 0`
the phase-minimum separation is `ρ/2` exactly. There is no clamp on `ca` anywhere. So `baseline_m = 800`
yields a **400 m** minimum separation with no warning, and the class docstring's asserted range
`[baseline, 1.118·baseline]` is in fact `[0.5·baseline, 2.0616·baseline]` at the shipped default.
`cfg.formation.crossTrackSpread = 1` survives the whole `finalizeConfig` chain (only three files touch
`cfg.formation`: `masterConfig` declares, `SimulationToggleManifest:518` reports, `SwarmFormation`
consumes — there is no override layer). The guarding test `tests/test_swarm_formation.m` T2 **cannot
fail**, because it constructs `cfg.formation` without the `crossTrackSpread` field.

---

## B6 — The LAMBDA ratio test is skippable  ⚠️

`+revgnss/+integer/LambdaResolver.m:174` guards the discrimination block with
`if numel(sqnorm) >= 2 && sqnorm(1) > 0` and has **no `else`**: when the configured method returns a
single candidate, control falls to `:183-185`, `info.ratio` stays `NaN`, and `info.accepted = true` is set
on the success-rate gate alone. `o.nCands = max(2,...)` guards the count *requested*, not the count
*returned* — and the toolbox reads the candidate-count argument only for `METHOD ∈ {3,4,5}`, defaulting to
`nCands = 1` otherwise. So selecting a non-ILS method silently disables the second of the two acceptance
gates that the document credits as "stronger than common practice".

## B7 — A gated feature declared only inside a dead config branch  ❌ UNREACHABLE

`cfg.measurements.isl.lightTime.enable` is declared at `config/masterConfig.m:768` **only**, inside a
branch guarded by `cfg.scenario.nSpaceAssets > 1` at `:749` — but `nSpaceAssets = 1` is set at `:44` and
never reassigned before `:749`, and `masterConfig`'s only argument is `'baseOnly'`, so the branch is
unreachable on every call. The `i_baseDefaults` re-declaration block re-declares every other
`measurements.isl.*` leaf but contains no `lightTime` entry, and no other file writes that path. The
field therefore never exists in a resolved config, and any scenario JSON that sets it hits
`deepMergeConfig:unknownConfigPath`. A toggle that cannot be turned on.

## B8 — The realistic-atmosphere mirror bypasses enum validation  ❌ LIVE

`atmosphere.realisticProfile.*` mirrors `errors.*` and is merged **after** `validateMasterConfig` runs, so
it is outside `configEnumRegistry`'s reach. Demonstrated live: setting
`cfg.atmosphere.realisticProfile.errors.troposphere.modelType = 'localWeatherGMXq'` (a typo) is **accepted**
by `validateMasterConfig`, and `finalizeConfig` then returns
`errors.troposphere.modelType = localWeatherGMXq` with the troposphere enabled — whereas the same typo on
the canonical path is correctly rejected with `validateMasterConfig:unknownModeValue`. The registry works;
the mirror is simply not covered by it, and the mirror is reachable from a scenario override layer. Since
an unrecognised `modelType` falls through to an `otherwise` that yields **zero delay**, a typo here
silently removes the troposphere rather than failing.

## B10 — The NIS dof budget-closure check cannot detect dof over-counting  ⚠️ LIVE

`+revgnss/ConsistencyStatistics.m:66-68` is the guard that exists to catch measurement-row
mis-accounting in the per-channel NIS verdict:

```matlab
unclassified = max(allRows - codeDof - doppDof - carrRows - twttRows, 0);
result.nisUnclassifiedRowsMean = mean(unclassified(isfinite(unclassified)));
result.nisRowBudgetCloses      = result.nisUnclassifiedRowsMean < 1e-9;
```

The `max(..., 0)` makes the test **one-sided**. If the per-channel degrees of freedom sum to *more* than
the total row count — which is precisely the signature of a row classified into two channels, i.e. a
**double-counted dof** — the bracket is negative, `max` clamps it to 0, and `nisRowBudgetCloses` reports
**true**. The guard can only ever detect rows belonging to *no* group, never rows belonging to *two*.

This matters because the defect it was written for was of exactly the mis-accounting family: the in-code
comment at `:61-65` explains that *"the whole defect above was an unaccounted remainder being silently
attributed to whichever group happened to be computed by subtraction"* (the earlier bug fixed in
`d42ee0d`, "per-channel NIS divided by rows it never summed"). Having caught the under-counting half, the
guard leaves the over-counting half invisible — and a double-counted dof deflates NIS/dof, which reads as
*conservative* and therefore attracts no suspicion.

**No evidence of a live overlap was found**; this is a weakness in the detector, not a confirmed
mis-count. But the detector is the only thing standing between a future channel addition and a silently
wrong covariance verdict.

**Fix.** Report the *signed* remainder and flag on magnitude:
`rem = allRows - codeDof - doppDof - carrRows - twttRows; budgetCloses = all(abs(rem) < 1e-9)`, so an
overlap surfaces as a negative remainder instead of being clamped away.

## B9 — The previous edition of this document had drifted  ✅ FIXED BY THIS EDITION

The filter section cited `+filter/ReverseGNSSEKF.m` as 2301 lines; the file at HEAD is **2513**. Every
body-level citation in that section was off by 88–212 lines (`update` 703 → 791; `computeNEES` 838 → 968;
`buildF_` 1146 → 1285; `applyIslDifferencedAmbiguityFix` 1602 → 1766), and two post-baseline features were
unaudited. Recorded here because it is the failure mode a traceability document is most prone to: a stale
`file:line` still looks authoritative. All citations in this edition were re-read at `170e37d`.

---

# §B2 Register B2 — Additional verified findings (second adversarial pass)

These emerged from the second adversarial pass, which covered the 91 claims the first pass did not reach.

**A methodological caveat, stated plainly.** The first pass assigned **one dedicated verifier per claim**
and refuted 68 % of them. The second pass batched seven claims per verifier and confirmed 80 %. Some of
that difference is real (the batched set contained more documentation-and-gating defects, which are easier
to establish than variance-accounting ones), but some of it is certainly reduced adversarial pressure per
claim. **Treat §B2 findings as verified but less hard-tested than §A and §B.** Where a §B2 entry says
"measured" or "proven numerically", a probe was actually run and that entry is as solid as any.

Separately, eight of the first pass's 49 refutations were re-audited by independent agents instructed to
overturn them. **None was overturned** — the refutations held.

---

## B2-1 — Retracted findings survive verbatim as live doctrine in the code  ❌ LIVE-IN-GOLDEN (prose)

Commit `6566cff` explicitly **retracted** `fe31d5b`'s conclusion that `H·P·Hᵀ ≈ 1.01·R` on code rows,
because the algebra held the innovations fixed while changing R (changing R changes the gain, hence the
estimates, hence the innovations). It also superseded the earlier per-source budget: the ionosphere is
**61–62 %** of code R measured at the true assembly points, not the 87.3 % measured in the wrong place,
and the striking "0.4696 predicted vs 0.4701 measured" agreement was a coincidence of the fixed elevations
and single band probed.

Those retracted sentences are still present, as assertions, in `config/masterConfig.m`,
`+models/+errors/ErrorChain.m` (notably the block at `:836-843`) and `+revgnss/ConfigFactory.m` — files
that every `resolveSimulationConfig` call executes and every reader of the code consults. They now
contradict the shipped behaviour, since `rScaleWhenStateActive` resolves to 0.0577 in all three goldens.
A reader who trusts the in-code commentary will quote a number its own author has withdrawn.

The same block also states that multipath is "copied verbatim onto both rows", a premise falsified 24
minutes after it was written (see §A4). **Recommendation:** in a codebase whose great strength is naming
defects in place, retracted analysis must be marked retracted in place too.

## B2-2 — A process-noise consistency audit applies a two-body rule to the shipped J2/J2 pairing  ❌ LIVE-IN-GOLDEN

`+revgnss/ConfigFactory.m:2373-2387` compares `sigma_accel_mps2` against `0.1·|a_J2|` **unconditionally** —
a rule written for a two-body EKF, where the unmodelled J2 acceleration is the thing process noise must
cover. The shipped pairing is `orbit.truth.mode = j2Rk4` with `estimator.dynamics.mode = j2`, i.e. J2 is
**fully modelled on both sides** and is not a mismatch at all. Resolving `golden_baseline.json` runs the
audit and writes `diagnostics.dynamicsMismatch.dynamicsProcessNoiseConsistency = 'consistent'` from the
ratio `1e-6 / 8.331e-7 = 1.200`, and that verdict is then rendered in the report
(`ReportRunner.m:971-976`, `+report/activePhysicsConfig.m:60`). The verdict is meaningless for the
configuration it is computed on: it certifies process noise against an acceleration the filter already
models. (Two further cases — MEO and LEO — would produce false FAILs, but are latent: no shipped JSON
sets `scenario.orbitClass` to anything but `GEO`.)

## B2-3 — The model-family guard reads the mode string, not the force model  ❌ LIVE-IN-LADDER-ONLY

`+revgnss/GeoRealWorldScenarioGuard.assertModelFamilyConsistent` (`:113-138`, and the
`auditImperfectionSources` honesty audit at `:204-214`) derives the "dynamics family" from the mode
**string** alone. A run whose truth carries Sun, Moon and SRP while the EKF carries none therefore passes
the family-parity guard and is labelled *"same J2 force family"*. Demonstrated by resolving
`config/ladder/test/test004_jointCoherentTwoWayCodeRealism.json`: truth `luniSolar/srp = 1`, EKF
`luniSolar/srp = 0`, both modes `j2Rk4`/`j2`, and
`diagnostics.dynamicsMismatch.j2DefaultPolicy = 'j2TruthJ2EstimatorSameForceFamily'`. The three goldens
and the LEO override all close the gap (EKF perturbations on), so this is ladder-only — but it is exactly
the guard that is supposed to prevent an undeclared truth/model force gap, and it cannot see one.

## B2-4 — The Monte-Carlo consistency gate contradicts its own stated methodology  ❌ LIVE-IN-GOLDEN

`+revgnss/MonteCarloConsistency.m:40-48` argues, correctly, that per-epoch samples are time-correlated and
therefore pools **one time-averaged sample per seed** for the centroid gate. The NIS and NEES gates 50
lines later (`:96`, `:105`) pool **exactly per-epoch**, which is the practice the header rejects. Since
per-epoch innovations are strongly autocorrelated (the repo's own diagnostics report `N_eff` of order
1–2 against thousands of epochs), the effective sample count is far below the nominal dof and the χ²
bands are correspondingly too tight.

**This is live**: `config/golden_baseline.json:355-360` sets `report.monteCarlo.enable = true` with
`nSeeds = 12`, `duration_s = 900`, `confidence = 0.99`, and `ReportRunner.m:1849` runs it. *(This
corrects a statement in the previous edition, and an earlier draft of this one, that Monte-Carlo
consistency is off by default: it is off in `masterConfig`, but the single-asset golden JSON turns it on.
The lesson is the one in Appendix C — resolve the config, never read the default.)*

## B2-5 — Monte-Carlo consistency cannot run on any multi-asset architecture  ⚠️ LIVE

`ReportRunner.m:1849` is the sole caller, and the multi-asset paths return early (`:112-116`, `:117-124`)
with Monte Carlo hard-coded disabled at `:1890` and `:1957`. `golden_baseline_multi.json:357` and
`golden_baseline_attitude.json:253` also set it false. Consequence: **every federated, swarm, distributed
and attitude result in this project is supported by a single deterministic run**, and the only
ensemble evidence that exists anywhere is for the single-asset golden. Any covariance-honesty claim made
about the multi-asset architectures rests on one χ² sample.

## B2-6 — An observability warning names a parameter that provably has no effect  ❌ LIVE-IN-GOLDEN

`+revgnss/AttitudeObservability.m:48-50` tells the reader that a weak-geometry attitude covariance is
*"process-noise-limited (sigma_angAccel), not measurement-constrained"*. But with `estimateGyroBias = true`
— the resolved default in every shipped scenario — `applyGyroProcessNoise_` **overwrites** the
`sigma_angAccel` attitude block, so the parameter the warning names has no influence on attitude at all.
Proven numerically rather than by inspection: on the golden-resolved EKF, sweeping `sigma_angAccel` over
**eight orders of magnitude** leaves `trace(Q_euler)` bit-identical at `1.200090e-07` (ratio exactly 1,
where σ² scaling would give 1e16). The diagnostic points the reader at the wrong knob, and it fires every
epoch on the golden (`diagnostics.attitudeObservability.enable = 1`, attitude H columns zero).

## B2-7 — The Conker S4 clamp is a singularity guard standing in for a model  ❌ LIVE-IN-GOLDEN

`+models/+errors/EnvironmentModel.m:675` clamps `S4` at `min(0.7, ·)` to keep `1/√(1−2S4²)` finite. At the
golden's real elevations (`S4zen = 0.3`, `obliquityModel = 'matchIonoMapping'`) the clamp **fires on ~12 %
of (epoch, tower) pairs**, and on those the scintillation sigma is pinned at a band constant — blind to
elevation and blind to the amplitude state that is supposed to drive it. The geometry reconstruction
reproduces the repo's own published figures exactly (Stockholm S4 = 0.7101 with 1/sin against 0.5770
thin-shell, matching the `masterConfig` comment). A numerical guard is doing the work of a physical model
on an eighth of the sample.

## B2-8 — The rotation solver weights correlated double differences as if independent  ❌ LIVE-IN-LADDER-ONLY

`+revgnss/GroundDifferencedRotationSolver.m:349` forms unweighted normal equations `Nmat = Jth'*Jth` and
`:361-363` reports an OLS covariance `Cth = (sse/(nObs−3))·inv(Nmat)` — on **double differences**, which
are correlated by construction (the shared reference satellite and reference tower give the classic
`2σ²[2 1; 1 2]` structure this very document verifies elsewhere). The result understates `σ_θ` on exactly
the scalar that **both** acceptance guards consume, so the significance test and the leakage test are both
run against an optimistic uncertainty. The solver builds a correct correlated DD covariance elsewhere in
the project; it is not used here.

## B2-9 — No chi-square measurement editing exists anywhere in the filter  ⚠️ LIVE-IN-GOLDEN

Re-confirmed structurally at HEAD and in every shipped configuration: NIS is computed
(`ReverseGNSSEKF.m`, post-update) and never thresholded, and the only outlier gate in the estimation path
is the unsourced fixed **1 m** threshold on the differential-attitude channel — whose own slip detector is
deliberately disabled. For a clean simulation this is defensible and arguably preferable (a gate can mask
the model errors the NEES/NIS diagnostics exist to expose), but it must be stated, because the code
computes exactly the statistic a textbook gate would threshold and then does not threshold it.

## B2-10 — Three mutually inconsistent headline numbers for the same two ladder rungs  ❌ LIVE-IN-LADDER-ONLY

The documented headline numbers for `isl016_carrierFloatAmbiguity` and `isl017_carrierHonestProduct` do
not match their frozen goldens under `tests/regression/golden/`, and three different, mutually
inconsistent pairs of numbers for the same two rungs exist in quotable-looking prose. Any of them could be
cited in good faith. These rungs carry the project's "what an assumed-known neighbour is worth" result, so
the discrepancy sits directly under a headline scientific claim.

## B2-11 — A Jacobian finite-differenced below the floor, and a test oracle that shares the floor  ❌ LATENT-DEFAULT-OFF

The four-timestamp ground-space Jacobian's position and velocity columns are finite-differenced with a
step below the floating-point floor of the timestamp reduction itself, so the derivative is quantization
noise. The named test's "independent oracle" computes the same quantity with the **same** stencil and the
same `t4_s` exposure, so it shares the identical floor and **cannot fail on it**. Measured by evaluating
the shipped `groundSpaceJacobian` and the test's oracle verbatim at `t4_s ∈ {0, 100, 1800, 3600, 43200}`.
Latent: the mode is not selected by any shipped configuration. The sibling `islTwoEndpointJacobian` shares
the stencil and is gated on an adapter whose default is `'none'`. Note that the **value** path does run in
ladder rungs and carries ~1.4e-4 m quantization at t = 3600 s — negligible against that layer's ~9 mm
shape floor, so no shipped number is presently wrong.

## B2-12 — Two product epochs for one broadcast, so a cross term is silently dropped  ❌ LATENT-DEFAULT-OFF

`TowerClockCorrectionProvider.compute()` and `computeDrift()` publish **different** product epochs for the
explicit-product modes, so the code↔carrier rank-1 tower-clock cross term in R is dropped with reason
`'noTowerEpochOverlap'` — a correlation the code goes to some trouble to model elsewhere. Correctly
downgraded during verification from "ladder-only" to **latent**: all shipped configs resolve
`towerClock.correctionMode = 'truthHistoryProductNoisy'`, whose own `computeDrift` branch (`:479-513`)
uses the same `t_prod_scalar` grid formula as `compute()`, so the epochs agree and the cross term is
formed correctly. Reaching the defect requires explicitly setting `correctionMode='product'`/`'productNoisy'`
**and** populating `cfg.towerClock.products`, which nothing shipped does.

## B2-13 — No regression golden is in the automated test gate  ❌ LIVE

`tests/run_all_tests.m:43` collects only `tests/test_*.m`. The four regression runners —
`run_oo_v1_regression`, `run_swarm_relative_regression`, `run_distributed_fleet_regression`,
`run_multi_islcarrier_regression` — are therefore **never invoked by the gate** and must be run by hand.
This is config-independent and true on every invocation. It is the mechanism behind two other findings in
this document: the stale `swarm_relative_baseline.mat` (which `889dcf6` records as already failing on a
clean tree) went unnoticed, and the silent four-timestamp fallback (§B1) survived because the only
automated test that reads the observable-source string asserts the degraded value.

---

# §C Register C — Limits of the simulation
The 123 statements below are the honest boundary of this simulation: things it cannot legitimately claim,
each tied to a specific mechanism in the code or configuration. They are grouped by domain. A claim that
contradicts one of these is not supported by the simulation as it stands, however good the number looks.

Read them as the counterpart to the verification sections: those establish that the implemented physics
matches its sources; these establish what implementing that physics correctly does *not* buy you.


## Measurements & Error Chain  (13 limits)

1. No relativistic-correction error bound: ConfigFactory derives the truth y (line 1980) and the model y (lines 2002-2005) from the same cfg.orbit.altitudeMean_m, so the 581 m/hour ramp cancels to machine precision in golden_baseline and no run bounds the residual of a real broadcast-derived correction.

2. No eccentricity-term claim: Relativity.m:69 hardcodes periodicResidual_m = 0. At a station-kept GEO's e of 1e-4 to 1e-3, 2*sqrt(mu*a)/c^2*e leaves an unmodelled 9 cm to 1 m orbital-period sinusoid in the truth, sitting in the radial/clock subspace where the correlation is already -1.000.

3. No carrier claim below about 1 cm: carrier multipath is absent (coloredGM.carrierScale still 'reserved', no mp term in CarrierMeasurementBuilder), phase wind-up is absent, and PCV cancels between truth and model. Kaplan's benign-environment carrier multipath alone is 2 cm, 4x the bare 5 mm sigma and 2x the baseline's 10 mm. The 10 mm sigma declares those terms unmodelled; it does not bound them.

4. No arc-correlated carrier systematics claim: wind-up drifts about 0.19 m/day/link at L1 for a nadir-pointing GEO rotating once per sidereal day relative to each fixed tower. A white sigma cannot represent it, and the long arcs the turn-angle law requires for rotation observability are exactly where it integrates.

5. No credible multipath statistics: tau = 60 s is a moving-constellation number applied to a quasi-static GEO-to-fixed-tower geometry whose true fading time is hours; the sigma is frequency-independent while the realisations are independent (a physically incoherent hybrid); the L2 chain runs at an effective tau of 15 s; and no chip rate or correlator spacing exists anywhere. Any 'multipath contributes X m' statement describes this parameterisation only.

6. No Doppler channel consistency statement: R is 2x over-charged, the truth carries no tropospheric or ionospheric rate at all so those terms cancel by construction rather than by modelling, the position partial is off by default, and there is no relativistic Doppler. The Doppler NIS is structurally biased low.

7. No ionosphere-free code result: the IF code R under-charges multipath by 8.87x in variance, and the one rung combining IF code with a slant-iono state (freq003) has an H/h mismatch. Neither freq003 nor any IF code rung with multipath enabled can be quoted.

8. No cross-signal information claim: scintillation and hardware delay are common-mode across L1 and L2 in physics but independent in this model, so a dual-frequency run gets up to sqrt(2) of free averaging on the largest truth-only term in the baseline (0.618 m rms scintillation at L1). Any 'dual frequency buys X' statement inherits that gain.

9. No claim about the composition of R: the only instrument that measured it has no consumer, was never reset, and its published numbers predate the factor-300 change to the ionosphere term. At HEAD the composition of the R the filter inverts is unmeasured.

10. No elevation-mask claim: the code/carrier/Doppler visibility gate reads a top-level cfg.elevationMask_rad that nothing writes and always runs at 5 degrees. Results are valid only for networks whose lowest elevation already exceeds 5 degrees.

11. The receiver clock-bias state is not a clock-bias estimate: rxCodeBiasModel returns 0 under the default absorbedInReceiverClock convention, so every reported bias is clock plus uncalibrated receiver delay.

12. Chip-rate-free noise: per-signal sigma0 (0.30 / 0.45 m) carries the entire signal-structure burden, the C/N0 model omits the squaring loss [1 + 2/(T*C/N0)], and nothing would flag an inconsistent (frequency, chip rate, sigma) triple. The L1:L2 noise ratio is an input, not a result.

13. Elevation-dependent thermal noise is a baseline property, not a default: masterConfig ships codeNoise.model = 'constant' while every shipped baseline sets 'cn0'. Statements about 'the default' must name which resolution path they mean, because ConfigFactory.defaultConfig and masterConfig also disagree on light-time mode and Shapiro.

## Time Transfer  (11 limits)

1. No ACCURACY claim at S-band. The four-timestamp ground-space default is 2.2 GHz (masterConfig.m:2945) and the ionospheric up/down asymmetry is absent from every two-way z and h. Scaling ITU's Ku example (0.220 ns at 100 TECU, 14.5/12.5 GHz, p. 6) to 2.2 GHz gives ~18.5 ns per leg at 10 TECU, so a realistic frequency split yields nanosecond-class asymmetry against a 100 ps (0.03 m) declared sigma. Every two-way S-band result is a PRECISION, never an accuracy, figure. The 26 GHz ISL four-timestamp link (masterConfig.m:2831) is exempt.

2. No claim that the four-timestamp physical chain was exercised in the federated swarm before 889dcf6. The real replay threw every epoch for every pair; every pre-fix federated relative-clock and shape number came from the synthetic observable z = (b_i - b_k) + bias + noise (SwarmRelativeSolver.m:1161), which contains no round trip at all. Post-fix: shape 0.0457 m unchanged, relative clock 0.0218 -> 0.0239 m.

3. No claim of calibrated hardware delays. truth.originTerminalCalibrationError_s, truth.anchorTerminalCalibrationError_s, calibration.originTerminalSigma_s and calibration.anchorTerminalSigma_s are all zero by default on both hosts (masterConfig.m:2848-2851, :2962-2965) and nonzero sigmas are REFUSED (FourTimestampGroundSpaceTimeTransferBuilder.m:316-328). Every four-timestamp run assumes perfectly calibrated terminals, while ITU section 3.6 (p. 6) makes station-delay determination the central accuracy problem of TWSTFT.

4. No claim that counter/tag noise has been carried in the filter. counterTag.sigma_s is refused nonzero on both hosts (FourTimestampGroundSpaceTimeTransferBuilder.m:335-342; InterSatelliteFourTimestampTimeTransferBuilder.m:43-52, which additionally discards the truth record's covariance block and sets covarianceBlock = sigma_m^2 at :138). Merlo's per-tag CRLB anatomy (sigma_Delta = 0.5*sqrt(sum sigma_i^2)) is never exercised.

5. No absolute-timescale claim. physics.relativity.clock is a RATE offset absorbed by the estimated drift state, and the ground station's properTimeRate is hard-set to 1 (ReciprocalEndpointTruthProvider.m:85), so Earth's own potential offset (about -6.97e-10) is unmodelled. UTC steering, TAI contribution and absolute-frequency statements are out of scope. With DC-1/DC-2 open, even the RELATIVE four-timestamp ground-space channel is not internally consistent when physics.relativity.clock.model.enable is true.

6. No non-reciprocity validation from the legacy or synthetic-ISL modes. In firstOrderReciprocal (TwoWayTimeTransferBuilder.m:219-232) and InterSatelliteTimeTransferBuilder (:544-552) the geometry is ECEF with zero tower velocity and no light time, so the ~100 ns Sagnac term and the ~micrometre motion term exist on neither side. Agreement between z and h there is twin consistency, not physics validation.

7. No claim on the four-timestamp row's position/velocity/attitude sensitivity. True |dh/dr| is about 6e-6 (dimensionless) against an FD noise floor reaching ~4.5e-5 by t_s = 3600 s (LF-6). Treat the row as clock-only. Doubly unsupported under the shipped commonAperture geometry, where transmit and receive phase-centre offsets are identical (masterConfig.m:2973-2974, both [0.8;0.2;0.3]) so the attitude columns are near zero by construction.

8. The motion non-reciprocity coefficient is untested. -rho*rhodot/c is 2x the derived and Shen-corroborated -rho*rhodot/(2c) and omits the common-velocity term entirely; the only test constrains the static limit. Do not claim motion non-reciprocity was modelled for firstOrderReciprocal runs; state instead that it is default-off, twin-cancelling and ~0 at GEO in ECEF.

9. The 0.68 micrometre co-moving light-time asymmetry is geometry-specific: it is the relative-motion part rho*rhodot/(2c) for a radial/cross-track baseline. The common-velocity part rho*u.(v_A+v_B)/(2c) reaches ~20 micrometres for a 2 km along-track baseline at GEO. Quote the mechanism, not the number.

10. NIS is not a validity test on these channels. The four-timestamp R is sigma^2 + nCorr*sigma_prod^2 with the wander inflated (DC-3), the ISL two-way R declares plasma and non-thermal terms the truth does not inject (DC-5), and the swarm relative-clock formal sigma is documented to have run 2.72x high before the nCorr removal (SwarmRelativeSolver.m:1372-1377). Any consistency statement must name which R convention produced it.

11. Page/quote corrections to the existing doc that must be carried into the thesis: Surof et al. (2026) Eq. 16 is on article p. 5 (doc said p. 7) and sigma_TWTT = 0.37 ps is on p. 9 (doc said p. 10); the ITU Sagnac worked example (SCD(VSL) = +99.10 ns, SCD(USNO) = -95.22 ns, SCT = -194.32 ns) is entirely on p. 5 (doc said pp. 5-6); Shen's source text reads 'field-programmable gate array (FGPA)' with the source's own typo, which the doc silently corrected; Schaefer's string is 'C/No: 40...60 dBHz ->noise 500ps (PN 2.5 MChip/s, t = 1s)' without the spaces the doc inserted. ITU-R TF.1153-4 citations at pp. 3, 4, 5, 6 and 7 were all re-verified as correct.

## Clocks & Oscillators  (12 limits)

1. No oscillator-specification error is ever simulated: the EKF's Q is built from the SAME h-coefficients as the truth clock (ScenarioFactory.m:49 -> ReverseGNSSEKF.m:1498), so every clock-channel NIS/NEES statement is a perfectly-tuned-filter result. A real receiver knows its datasheet, not its realisation, and nothing in the repo measures sensitivity to that mismatch.

2. Flicker is representable in Q only to within a factor 0.69-2.08 (q11 31% light, q12 2.08x heavy, q22 1.04x against Brown & Hwang p.430). Their own verdict - 'it is impossible to model this term exactly with a finite-order state model' - is the ceiling. No claim of exact clock-covariance consistency is supportable for a flicker-dominated class (RUBIDIUM2, OCXO2, CESIUM2).

3. Flicker below f = fs/N is not represented at all. Single-segment circular FFT synthesis truncates the 1/f divergence at the run length: on a 3600 s / 1 Hz run that is f < 2.8e-4 Hz. No ADEV point beyond tau ~ 900 s (AllanDeviation.compute caps m <= (N-1)/4) is evidence of long-tau behaviour.

4. Every clock realisation carries a strictly positive frequency offset from the abs()-forced DC bin, mean 0.627*sqrt(h-1): 1.98e-13 (CESIUM1), 3.14e-12 (OCXO2), 6.27e-11 (TCXO). It is absorbed by bdot_rx and by the product drift term and has zero Allan variance, but the synthesised process is NOT zero-mean in frequency, contrary to the model it claims to implement.

5. The ground-clock contribution to code R is set by the broadcast-product cadence, not by oscillator quality, and it is large: at the stale end of one cycle (age 34 s from floor((t-5)/30)*30) the uncorrectable wander is 2.416 m for the default OCXO2 - 22.9x the golden product sigma of 0.1056 m - and even the best catalogue class (RUBIDIUM2) leaves 0.121 m. No sub-decimetre ground-segment claim is supportable at a 30 s/5 s product cadence without estimating the tower clocks or shortening the interval.

6. The default ground oscillator is a consequential choice: 'OCXO' aliases to OCXO2, Winkel's short-term-optimised crystal (best at 1 s, worst at 4 h). OCXO1 would give 1.158 m at age 34 s instead of 2.416 m. Any error-budget table must name the catalogue row (OCXO2), not the class (OCXO).

7. The periodic relativistic clock term is still absent. revgnss.Relativity models the constant offset only and returns periodicResidual_m = 0. For a real GEO with e = 1e-4 to 1e-3 the -2*sqrt(GM*a)*e*sinE/c^2 term is 0.3-3 ns (9 cm to 1 m), orbit-periodic, aliasing into the radial-clock weak direction.

8. Two-way / four-timestamp clock claims inherit an uncorrected y_rel*delta term: TwoWayCodeEndpointModel.localTimeAt applies neither y_rel nor properTimeRate across the propagation interval, so each timestamp is short by up to 5.388e-10 * 0.24 s = 1.3e-10 s (3.9 cm). Any sub-100-ps two-way accuracy claim must either disable the relativistic clock or fix this path.

9. Tower-clock product errors do not re-randomise across Monte-Carlo seeds: productNoise_ is seeded on (towerIdx, t_prod) alone, outside RngRegistry (TowerClockCorrectionProvider.m:872-882). An ensemble over master seeds re-randomises the oscillators but not the broadcast-product errors, so ensemble statistics under-sample this error source.

10. cfg.clocks.tower.product.sharedErrorCorrelation is INERT - read into pc and consumed by nothing but a report row (TowerClockCorrectionProvider.m:696-705). The actual cross-consumer sharing is unconditional. It must not be cited as a control.

11. The truthHistoryProduct* family reads the tower's TRUTH history to build the correction (clockAtProductEpoch reads tower.history.clockBias_m at t_prod). This is a simulated product, not a receiver-realisable one; its defensibility rests entirely on the injected (sigma_b, sigma_d) and the age-grown wander, and those sigmas are UNSOURCED in the repo (0.01 m in masterConfig vs 0.10 m in golden_baseline.json - a 10x difference in the number a publication would quote). Independently, perfectCorrection remains a pure oracle in both the bias and the drift channel.

12. Nothing in this domain constrains the ISL truth-leak. With isl.product.enable = false (the default), ISLMeasurementBuilder.m:227/253 reads the neighbour's TRUE clock via tx.clock.getBiasMeters()/getDriftMetersPerSecond(). The relativistic term cancels correctly through that path, so the 9a52cfc fix is right - but it does not reduce, and must not be described as reducing, the known 3.585 mm -> 130.9 mm honesty cost.

## Orbits & Frames  (10 limits)

1. No absolute-frame accuracy. The ECI<->ECEF map is a single z-rotation at constant omega = 7.2921150e-5 rad/s with no precession, nutation, polar motion or UT1 (FrameTimeUtils.m:6-15, L1-L5). Against the IERS ERA rate this accrues 5.35 m/day of ECEF longitude at GEO, against the GMST rate 31.2 m/day. Truth, measurement model and EKF share the constant so internal consistency is exact and no result is affected, but no 'the satellite is at longitude X' statement is defensible beyond that drift, and nothing may be compared against a real ephemeris product without a full EOP chain.

2. No realistic GEO station-keeping behaviour. J2,2 - the tesseral that actually drives GEO longitudinal drift toward the stable points - is absent, as are all higher zonals, drag, manoeuvres and station-keeping (OrbitPropagator.m:13-16). The truth GEO does not drift the way a real one does. Nothing about east-west stationkeeping, longitude slots, or long-arc orbit prediction may be claimed.

3. Force-model conclusions are conditional on the same-family default. At the shipped configuration truth and EKF are both J2 (masterConfig.m:734,737), so convergence and filter-consistency results are NOT force-model-limited and must never be quoted as evidence that the estimator's dynamics are adequate. The only declared gap is applyLuniSolar's truth-only 1.07e-5 m/s^2, and its 1e-5 m/s^2 white-noise sigma covers that gap only at the 1 s update interval: the coherent drift outruns the SNC as 0.927*sqrt(t), i.e. by 55x over a 3600 s coast. No claim that the filter tolerates unmodelled luni-solar forces during an outage is supported.

4. The luni-solar truth is epoch-locked to J2000. The lunar mean-longitude precession term -1.3972*T is omitted (OrbitPerturbations.m:111). At epochJD_TT = 2451545.0 the error is 0.138 arcsec/day and irrelevant; at a 2026 epoch it is 0.3703 deg of lunar longitude -> 8.42e-8 m/s^2 -> 0.55 m/h and 8.7 m over 4 h of truth-orbit error. The '~0.6 m / 4 h analytic-vs-DE-440 gap' quoted at masterConfig.m:1229-1231 is an at-J2000 number and must not be generalised.

5. The formation is not a '1 km formation'. MEASURED at the shipped crossTrackSpread = 1.0, nSec = 5, baseline_m = 1000: chief-to-member separations at t=0 are 1000, 740, 1042, 1232, 1985 m, sweeping [708.0, 1984.9] m over the 3600 s arc and [500.0, 2061.5] m over a full orbit; minimum pairwise separation 964.2 m (max 2835.8 m). Any ISL, shape-solve or beamforming result quoted 'at a 1 km baseline' is really quoted at a 0.7-2.0 km spread with a factor-2.7 range, and the 500 m minimum-separation target is met only marginally (500.05 m measured) and only because the run is shorter than a quarter orbit.

6. No relativistic orbit dynamics, and no relativistic residual. The Schwarzschild term (M&G Sect 3.7.3) is absent - re-derived at 7.08e-11 m/s^2 at GEO, 0.46 mm over 3600 s, correctly negligible. Separately the relativistic clock term is applied with the same constant on truth and model, so the run contains zero relativistic modelling error. The correct claim is 'the simulation applies the published relativistic clock offset consistently', never 'the simulation demonstrates achievable accuracy in the presence of relativistic clock error'.

7. The solid-Earth tide models the in-phase degree-2 term only. Omitted: degree-3, latitude-dependent Love numbers, out-of-phase/anelastic terms, frequency-dependent corrections, ocean loading, atmospheric loading, and the permanent-tide (tide-free vs mean-tide) convention. It captures >=95% of a 10-30 cm signal, is truth-only and default-OFF, and must not be presented as an IERS dehanttideinel-equivalent station-displacement model. Nothing about sub-cm station positioning follows from it.

8. EOP realism is an injected residual, not a correction chain. TruthEarthOrientation injects a first-order rotation and optionally removes a published one; it does not implement R3(-s')R2(xp)R1(yp), does not read an EOP series, and models UT1 error only as a constant LOD rate. The realism grade's 0.005 arcsec (realismGradeConfig.m:411) is 0.155 m of tower displacement - a post-correction residual, not the raw ~9 m offset the class header uses to motivate itself.

9. The truth formation itself has a model floor, though a small one. Differential J2 across the formation is ~7.9e-10 m/s^2 (a 0.5*a*t^2 bound of ~5 mm over 3600 s, ~0.74 m over 12 h); the MEASURED departure of the J2-propagated truth from the CW closed form is 5 cm over 12 h, because most of that force is periodic. Truth-cache substepping is self-consistent to ~26 nm, and the CW initial conditions use the two-body mean motion while the truth propagates J2. A 'formation shape' number below ~5 cm over a long arc describes the integrator's relationship to the CW idealisation, not a physical property of the formation.

10. LEO and MEO are illustrative, not validated. orbitClassConfig documents that drag - the dominant force below ~600 km - is absent from the truth (lines 21-26) and that the 20-site network yields ~0.3 satellites-in-view (lines 82-89, 'not a working continuous-coverage network'); it additionally reverts ground-clock stochasticity (LF-9) and carries a 2104 km tower-position divergence from the golden set (LF-8). No LEO or MEO number may be quoted as a result.

## Filter & Attitude  (13 limits)

1. No statistical consistency claim from a single run. The shipped verdict (ConsistencyStatistics.nisStatus_, l.270-275: warn below 0.5, warn above 2.0) is exactly the mean-only heuristic that ChiSquareConsistency's own docstring says 'passes a mildly inconsistent filter'. The two-sided machinery is driven only by MonteCarloConsistency, which is OFF by default (cfg.report.monteCarlo.enable = false). Every consistency statement in the thesis must name the number of seeds.

2. No consistency claim stronger than N_eff. Measured lag-1 autocorrelations are 0.09-0.30 on code/carrier/doppler and 0.7254 on twoWay, giving ~2000-3000 and ~573 independent samples of 3601 epochs; because rho is measured on a squared series the error-domain figures are a further 2-4x smaller. A per-channel NIS/dof of 0.65 must be quoted off N_eff, not off 3601, and the Monte-Carlo bands are 1.36-2.5x too narrow as computed.

3. No claim about attitude-sensor realism. Gyro defaults are 0.34377 deg/sqrt(h) ARW and 2.06265 deg/h initial bias - 2.75x worse than a Honeywell HG1700, 4.9x worse than an LN-200S and 34x worse than a Honeywell MIMU per NASA Table 5-9 (p.159). That is MEMS/industrial class, not GEO-grade. Bias instability (the flicker floor) is not modelled, so RRW alone over-states long-arc bias growth while under-stating the short-term floor.

4. No claim about star-tracker error geometry. The default is isotropic 10 arcsec 1-sigma (30 arcsec 3-sigma) per axis: 5x CONSERVATIVE against a Blue Canyon NST cross-axis (6 arcsec 3-sigma) but 1.33x OPTIMISTIC against its twist (40 arcsec) and 5x optimistic against a Berlin ST400 twist (150 arcsec), per NASA Table 5-5 (p.150). Real trackers differ 5-11x between the two axes; the simulated attitude covariance is spherical where reality is a cigar, which mis-projects onto the lever-arm observable.

5. No claim that the gyro-bias state 'works'. imu.truth.* and imu.filter.* carry identical ARW/RRW/initial-bias-sigma in the default AND the realism grade (verified live in the resolved config), so bias convergence is a property of the matched construction, not evidence about a real IRU.

6. No claim that the clock Q 'models flicker'. It carries flicker as its Allan-equivalent random walk at tau = dt, so over N steps the filter accumulates N*6ln2*h-1 of frequency variance where true flicker grows logarithmically - increasingly conservative on the drift state by ~N/ln N over a 3601 s arc. Separately Q22 omits the h0/(2*dt) term of Brown & Hwang's own van-Dierendonck-derived footnote (p.430), which for the caesium template in use is 1.2e5 times the code's entire Q22. The standing conclusion that 'no Q magnitude restores drift +/-3 sigma coverage' was never A/B-tested against that term and must be narrowed to 'no FLICKER Q magnitude'.

7. No claim about tower-clock-enabled NIS. Whenever estimateTowerClocks = true with a fixReferenceTower or meanGroundClockGauge datum, OVERALL NIS/dof is inflated ~1.9% by counting gauge innovations against a physical-only dof, in the optimistic direction. Every ladder rung that estimates tower clocks carries that bias.

8. No claim from the calibration / consider-parameter machinery. The star-tracker alignment model (fixed bias, deterministic drift, random walk, three treatments, validity windows, stable identifier) is inert at every shipped configuration including the realism grade. It is correctly written and contributes nothing to any number in the thesis.

9. No claim that the attitude covariance is measurement-constrained unless AttitudeObservability reports rank >= 3 with a non-zero lever arm for the epochs in question. The audit is single-epoch only: no arc-accumulated observability Gramian (sum of Phi' H' R^-1 H Phi) is built, despite beginEpochTransition_/accumulateEpochTransition_ (l.2301-2352) retaining every operator required. A single-epoch rank test systematically UNDER-states observability that accrues through the dynamics.

10. No claim of outlier robustness. There is no chi-square measurement-editing gate anywhere in the filter; the code computes exactly the statistic (nu' S^-1 nu) a textbook gate would threshold and never thresholds it. Results are valid only for the outlier-free synthetic environment they were produced in.

11. No claim of a converged initial-condition test. ScenarioFactory.m:88-113 seeds x0 = truth + perturbation and MonteCarloConsistency.m:75-80 draws that perturbation from the filter's own P0, so initial NEES is 1 by construction. Only the post-burn-in segment (default burnInFraction = 0.5) carries information, and the initErrorScale > 1 negative control must be reported alongside any consistency verdict.

12. F and Q are dynamically inconsistent by design. With estimator.dynamics.mode = 'j2' the r/v STM is the finite-difference J2 STM while Q stays the constant-velocity white-acceleration form at sigma_accel = 1e-6 m/s^2, with the mismatch inflation enable = 0 in the resolved default. This is standard state-noise compensation and must be labelled as such, not as a matched process model. The FD STM's accuracy also floats on step sizes of 1.0 m and 1e-3 m/s that no test ever varies.

13. The MEKF conventions and algebra ARE equation-grade correct and can be asserted without hedging: the update is Brown & Hwang Eqs. (5.5.8)/(5.5.17)/(5.5.18) exactly with the any-gain Joseph form as the sole P-update path; covariance prediction is Eq. (5.5.25); the discrete Q for every state class is the exact closed-form integral, verified numerically to all significant figures at dt = 1 s across six placements; the reset Jacobian I - 0.5*[dtheta]x was re-derived from BCH independently of any source and matches line 853; the quaternion convention is declared in machine-readable form and implemented identically across four files.

## Atmosphere  (12 limits)

1. No absolute atmospheric-delay accuracy claim: ZWD = 0.15*RH*exp(-h/2000) is uncited and temperature-blind, returns 0.075 m for every golden tower from Libreville (0.04 N) to Stockholm (59.3 N), and understates a physical Saastamoinen evaluation of the same (T,RH) by about 35%. The temperature model that would fix it is computed and discarded. Only the residual after a matched model is meaningful, and that residual is 0.021 m RMS by construction.

2. The ionosphere result is a result about a mis-calibrated Klobuchar, not about the ionosphere: the realistic profile injects a sign-definite +1.196 m mean vertical model bias (+0.525 to +2.623 m over 24 h). Any statement of the form 'the ionosphere contributes X m' from a feat or freq rung measures the 20 ns against 30 TECU mismatch.

3. Code-channel noise is 1.39x-2.17x the model that names it, because the Conker sigma and the C/N0 sigma are the same tracking noise charged twice. No absolute code-ranging-noise figure and no 'position RMS achievable at 45 dB-Hz' claim can be made; rung-versus-rung comparisons at fixed configuration are unaffected.

4. NIS/NEES cannot validate this domain: every defect found is either symmetric on truth and R (the scintillation duplicate, invisible to NIS) or an over-charge against a matched model (troposphere, giving NIS below 1 which reads as conservative). The code-channel NIS/dof of 0.65 quoted in 6566cff is dominated by the 138x troposphere over-charge and the 4.7x scintillation variance, not by the ionosphere.

5. R is diagonal and white while the atmosphere is neither: the slant ionosphere is shared by the L1 and L2 rows of one tower and is time-correlated with tau = 600 s, the ZWD with tau = 10800 s, and both are charged as independent white noise. Innovation autocorrelation, not variance, is the diagnostic, and it is not computed for these channels.

6. Dual-frequency scintillation is understated by 45% on the lower band: s4FrequencyExponent ships at 0 while weak-scatter theory gives about 1.5, and (f_L1/f_L2)^1.5 = 1.45. Every L1/L2 and IF result assumes band-independent S4.

7. No higher-order ionosphere on the carrier: CarrierMeasurementBuilder carries no second or third-order term, so the -1/2 * d2 phase advance (Fritsche et al., 2005, eq. 11, p. 2) is absent, bounded by 1.5 x 5 cm = 7.5 cm at L1 with the shipped caps. The second-order sign is tied to sign(I_L1) rather than B0 dot k, so it cannot support bias studies.

8. Phase scintillation is injected but not charged: under the realistic profile the truth carrier carries 6.1 mm (zenith) to 15.4 mm (20.9 deg) of correlated jitter against a flat 10 mm carrier R that excludes it. Carrier-channel covariance claims are not honest below about 30 deg elevation.

9. Gaseous absorption is enable=false by default, so no shipped golden or realism-grade result includes it at all; it reaches only the code sigma, only at nine tabulated frequencies, and 915 MHz sits below P.676's stated 1 GHz validity floor. The freq013 61.25 GHz rung runs with absorption off and its link margin is fiction; that exclusion must travel with every number quoted from it.

10. Mapping functions are validated, the atmosphere they map is not: Niell (1996) is exact to eight digits and Orekit-cross-validated, but it is applied to a two-parameter invented weather state with one global relative humidity, no gradients, no azimuthal asymmetry and no NWP/VMF3/GPT3 input. Mapping-function accuracy is not the limiting error and must not be presented as evidence of tropospheric fidelity.

11. f_seen = 1 is the only path that executes (topside.enable is set nowhere), so every result is a full-column GEO result and no LEO or MEO ionospheric-column claim is supported.

12. The formation-shared atmosphere is off by default, so any between-satellite differenced observable in the shipped goldens inherits about sqrt(2) times the full atmospheric error rather than about 0. Differenced-observable results are only meaningful with cfg.atmosphere.sharedAcrossFormation.enable = true.

## Ambiguity Resolution  (13 limits)

1. No integer fix is ever applied inside the ground-to-space EKF. The integer machinery is a post-processing/diagnostic layer (GroundCarrierAmbiguityResolver) plus one gated ISL constraint (estimator.lambda.isl.applyFix, default false). Nothing here may be quoted as 'the EKF solution with fixed ambiguities'.

2. The wide-lane success rate is a statement about averaging WHITE code noise, not about field ambiguity resolution. GroundCarrierObservationSet.m:139-140 draws code noise as sigCode*randn with no multipath, no differential code bias and no DCB, so sigma_MW averages as 1/sqrt(n) with NO floor: varMwLink = 0.0674 m^2 gives 0.602 WL cycles per DD per epoch, falling to 0.010 cycles over a 3601-epoch arc, whence P_s -> 1 trivially. Real MW is limited by correlated multipath (tau of minutes) and constant DCBs, neither of which averages away.

3. The entire ground-carrier cascade computes GPS L1/L2 lane wavelengths regardless of the scenario band (GroundCarrierObservationSet.m:47-48). No result from config/ladder/freq/freq009-013 passing through the cascade is band-correct: lambda_WL 861.9 mm is used where freq013's true wide lane is ~8.1 mm, a factor of 106.

4. The band-invariant carrier sigma and slip threshold are implemented and unit-tested but enabled on NO scenario (every config leaves measurements.carrier.sigma_cycles and carrierSlip.threshold_cycles at NaN). All reported band sweeps therefore run a metre-fixed 5 mm sigma (1.02 cycles at 61.25 GHz) and a 0.1 m slip threshold (20.4 cycles at 61.25 GHz).

5. Single-cycle slips are undetectable at the realism-grade carrier sigma: the ISL auto threshold is 5*sqrt(2)*sigma = 1.41 m ~ 7 L1 cycles at sigma = 0.20 m (masterConfig.m:2645-2650). The ground default (threshold_m = 0.1, minEpochsBeforeDetect = 3) was never migrated to the auto idiom. No geometry-free (L1-L2) or Melbourne-Wubbena slip detector exists, so the detectable-slip floor is set by thermal noise, not by the observable's dispersion.

6. isl016 must never be quoted as a result: with product.enable=false each leaf EKF's h reads its five neighbours' TRUE position and clock. Measured cost of removing the leak: 0.003562 m -> 0.094562 m RMS absolute position, a factor of 26.5 (frozen goldens, 3600 s).

7. isl017 may be quoted for accuracy but not for uncertainty: its formal 3-D 1sigma (0.010181 m) understates its realised RMS (0.094562 m) by 9.3x, and by 17x on the worst asset (0.176744 m). The mechanism is the 300 s piecewise-constant product error charged as white R.

8. The ISL 'carrier' rows on isl016/isl017 are not carrier-phase observables in the ambiguity-resolution sense: with processNoiseSigma_m_per_sqrt_s = 0.01 m/sqrt(s) against a 0.002 m sigma the ambiguity's steady-state Kalman gain is 0.963 and it can wander ~52 cycles per hour at 26 GHz. They deliver delta-range information only.

9. The between-satellite ISL 'double' difference is a SINGLE difference and its surviving transmitter-clock residual is 0.223 cycles at GPS L1 (sigma_clk 0.03 m) but 2.453 cycles at the 26 GHz crosslink band the ladder actually uses (sigma_clk 0.02 m). Integer resolution on that parametrisation is invalid at Ka band, and nothing in the code refuses it.

10. The acceptance rule is untested: both gates are set to zero in every property test. The reported P(false fix) is a bound on the integer-bootstrapping failure probability UNDER THE ASSUMED COVARIANCE, not the failure rate of the composite accept rule, and not a bound at all in the presence of a deterministic bias (Joosten & Tiberius 2000, p. 50).

11. The ratio thresholds have no source: 2.0, 3.0, 3.0 and 1.20 appear in four places in masterConfig with no derivation. Verhagen & Teunissen (2013) show a fixed critical value gives a failure rate varying by orders of magnitude with model strength. The defensible formulation is 'P(false fix) <= 1 - P_s,IB, a rigorous ILS lower bound under the assumed covariance (Teunissen 2001, p. 253), with an additional heuristic ratio >= 2 screen'.

12. Phase wind-up and antenna PCV are absent from every carrier path (declared at ISLMeasurementBuilder.m:283-285). A constant part of either is absorbed by the float ambiguity; a DRIFT would leave a real residual and could pull an integer fix, and no bound on that drift is computed anywhere.

13. The LAMBDA 4.0 toolbox is not vendored, so Ps_LAMBDA's method codes and LAMBDA.m's internal PAR threshold remain unverifiable from this repository; every claim about them is a claim about an absent artefact.

## ISL / Link Budget / Swarm  (27 limits)

1. No absolute ISL sigma is derived anywhere. ISLLinkBudget is ANCHORED (:15-18): it returns exactly sigma0 at refDistance_m and moves only by the distance ratio, and its default model='fixed' returns sigma0 unchanged. The repo may claim 'sigma scales as d' and 'a fixed aperture cancels the f^2 path loss'; it may NOT claim 'the crosslink achieves X mm'.

2. InterSatelliteRFLinkModel returns thermal jitter only (:209-214). At 1 km / 26 GHz / 10.23 MHz it returns 1.9e-5 m - that is not a ranging accuracy, it is the absence of models for multipath, group-delay drift, quantisation and timing granularity. TwoWayISLMeasurementBuilder.m:549-556 correctly calls a thermal-only R a 'floorless claim'.

3. The 15 mm code and 2 mm carrier figures in isl016/isl017 are TERMINAL DESIGN ASSUMPTIONS against masterConfig's 0.50 m and 0.20 m, and must be declared as such at every citation.

4. No interference/RFI, rain, gaseous-absorption, polarisation-mismatch or pointing-loss model exists on the crosslink; losses_dB is one declared scalar. The Paper/Link BUdget interference papers verify nothing in this domain.

5. The DLL coefficient is declared, not derived, so no waveform-specific claim (BOC vs BPSK, discriminator spacing, squaring loss) is supportable from this code.

6. BeamformingPhasorDiagnostics reports the gain of ONE realisation of a SOLVED geometry; OrientationCoherenceBudget reports the EXPECTED gain from a SIGMA. They are not interchangeable, and only the first can legitimately fall below the 10*log10(1/N) floor.

7. Every beamforming number is gated by coherenceClaimStatus. When it is not 'claimable', beamformingPhasor.m:122-125 prints that the dB figures are 'a property of this particular run's initial condition and propagation, not a measured beamforming capability'. No paper sentence may outrun that gate.

8. The near-field classification (2D^2/lambda ~ 4.4e8 m for D ~ 5.6 km at S-band against a 35786 km slant) is real but nothing depends on it: exact element-to-target ranges are used in both regimes. It explains why a plane-wave array factor would be wrong; it is not a result.

9. Coherence claims are bounded by demonstrated hardware: Merlo, Mghabghab and Nanzer (2023) achieved 2.26 ps over a 90 cm 5.8 GHz laboratory link (p. 1720). Any picosecond-class formation claim must be framed against that, not against a simulated sigma.

10. Ranges are ANALYTICALLY blind to rigid rotation AND reflection. No number of crosslinks, at any precision, at any epoch, changes this. Orientation comes only from an Earth-referenced observable. State the claim as 'rigid motions (and reflection)' for completeness.

11. rigidityMargin = nLinks - (3N-6) is a NECESSARY condition only; edge count does not imply generic rigidity (Laman/Maxwell plus genericity is required). The code states the count without claiming sufficiency and the paper must not upgrade it.

12. Rotation results are simulation-internal: the DD observable is re-synthesised from recorded truth because nothing measurement-side survives a federated run (GroundDifferencedRotationSolver.m:32-40). They are not end-to-end measurement processing.

13. The 3-parameter rotation stage converts arc-correlated deformation into spurious rotation at a measured ~0.30 deg per metre while its formal sigma sits at 0.0115 deg in every row of the injection ladder. Its sigma is meaningless under model mis-specification.

14. minTurnAngle_deg (default 30) gates 'separable' as a REPORT FLAG, not a refusal (JointGeometrySolver.m:204). A 3600 s GEO arc turns 15 deg, where golden_baseline_multi.json:326 records a 9.9x CRLB penalty for separating rotation from shape. Shape/rotation separation on a one-hour arc is not established.

15. arcAverage_ removes the thermal term and leaves the per-link delay-calibration bias exactly where it was (:519-521); once bias dominates, longer windows buy nothing. It is also default-off and publishes no covariance.

16. tests/regression/golden/swarm_relative_baseline.mat is STALE and fails on a clean tree (commit 889dcf6: assetFinalPos max|d| = 6.198e+01 with and without the change). No relative-layer number may be cited from it.

17. No fleet-level joint-covariance conservativeness is claimed, and correctly so (DistributedCovarianceNetwork.m:25-30, centralReferenceEquivalenceClaim:780-815): a collection of pairwise-conservative marginals does not imply a conservative joint.

18. Split CI guarantees the bound is CONSERVATIVE, never that it is BENEFICIAL. Measured on the golden: accuracy improved 19.16 m while the covariance LOOSENED on 27 of 27 owner states and tightened on none.

19. ownerPolicy='initiator' updates ONE endpoint, so exactly one satellite in a 2-asset fleet benefits; both endpoints need the Stage 3.2 synchronized pair update.

20. The conservative bound is proven for exactly FIVE observables (SplitCovarianceIntersectionBound.m:114-116). Admitting a sixth is a per-observable proof obligation about its own H and R, never a re-proof of the formula.

21. The acceptance gates use an absolute tolerance floor tol*max(1,norm_F) and are therefore NOT scale-invariant; a sub-micron-scale R could be rejected as numerically non-PD (declared at :56-61).

22. With the shipped default (product.enable = false, per the dead-branch finding), h reads the neighbour's TRUE position and clock. The measured cost of honesty is 0.003585 m -> 0.095183 m at 3600 s (factor 27), or -> 0.130883 m at 600 s (factor 36). Any absolute accuracy quoted from an ISL-aided run must state which side of that line it is on, and isl016 must never be quoted as a result.

23. Even on the honest side, a satellite CANNOT beat its knowledge of its neighbour: range is |r_A - r_B|, so the product's sigma_pos maps ~1:1 along the line of sight. At sigmaPos_m = 0.03 the measured baselineRMS is 0.036 m - the floor is visible in the number.

24. ISL integer ambiguity resolution does not survive: realismGradeConfig.m:162-164 records a measured success rate of ~0.001 (sigma 2.3-3.7 cycles), which is why LAMBDA is deliberately not enabled under the realism flag. Every ISL carrier result in this repository is FLOAT.

25. Phase wind-up and ISL antenna PCO/PCV are ABSENT and declared (ISLMeasurementBuilder.m:283-285, :514-515). A constant part of either is absorbed by the float ambiguity; only a drift would leave a residual.

26. The ~1 cm/km one-way inter-satellite light-time term is default off and is NOT settable from any scenario JSON (its only declaration sits in dead code and deepMergeConfig rejects the undeclared path), and the shared-kernel one-way adapter cannot model it at all. No published ISL result in this repository has it applied.

27. ISLMeasurementBuilder deliberately drops the light-time position partial from H (:571-574), justified by a measured 3.1e-6 m response to a 1 m position error, ~640x below the 2 mm carrier floor. Valid at km-class baselines only; the margin closes as baselines grow.

## Simulation Flow & Validation  (12 limits)

1. No validation in the NASA-STD-7009A sense has been performed and none is currently possible: no real-world measurement data is ingested anywhere, and ModelCoverageAudit.claimGate_ blocks the claim on seven missing product parsers (SP3, CLK, RINEX, ANTEX, IONEX, IERS EOP, bias). Only Verification - 'determining the extent to which an M&S is compliant with its requirements and specifications' (NASA-STD-7009A, p. 15) - is in evidence.

2. No multi-asset result is statistically supported. The Monte-Carlo ensemble is hard-off for every federated, distributed and swarm architecture (LF-2), so every ISL, formation-shape, relative-clock, beamforming and distributed-EKF number is ONE deterministic sample. Against ECSS-E-ST-60-10C p. 35 ('the only way to include ensemble type errors ... is to have some form of Monte-Carlo campaign with a large number of simulations covering the parameter space') that is insufficient by the standard's own words.

3. The single-asset headline rests on 12 seeds x 900 s (golden_baseline.json), against a manifest declaring 200 short-ensemble and 50 full-scenario independent runs (masterConfig.m:597-601) and labelling itself 'declaredNotStatisticallyExecuted' (:596). Gap: ~17x in seeds, 4x in arc length. Every acceptanceCriteria field is NaN (:626-629), so no pass/fail threshold has ever been declared for position or clock accuracy.

4. Any ISL-aided absolute accuracy quoted from a rung that leaves measurements.isl.product.enable=false is an ORACLE result: h is handed the neighbours' true position and clock. The honest twin is 27x worse at 3600 s (0.003585 -> 0.095183 m RMS) and 36x worse at 600 s (-> 0.130883 m). Because of LF-1 this is the RESOLVED DEFAULT for any swarm scenario enabling ISL without explicitly writing the product block, not an opt-in mistake.

5. The relativistic clock ramp cannot be claimed as 'modelled and estimated'. Truth and model both derive y_rel from cfg.orbit.altitudeMean_m through revgnss.Relativity.geoClockFracFreq, so 581 m of clock bias over a 3600 s arc cancels EXACTLY in z-h. It is a legitimate published-constant correction but a matched pair; the residual the filter estimates is the oscillator's own error only.

6. The federated relative layer is a simulation-internal demonstration, not end-to-end measurement processing. TruthEndpointReplay feeds recorded truth position, velocity, attitude and clock into the four-timestamp chain, and since 889dcf6 it feeds MORE truth-derived physics than before because the real chain now runs. The sign/scale check at SwarmRelativeSolver.m:1305-1330 validates the observable against the same recorded truth it was built from - it can catch a sign error and nothing else.

7. The enum guard covers roughly 40% of the string-valued dispatch surface: 28 registry entries against >=65 mode/modelType/model/policy/kind/protocol/observable leaves in masterConfig.m alone. A typo in any unregistered leaf (e.g. measurements.twoWayTimeTransfer.mode, clock.gauge.mode, multiAsset.twoWayISL.gauge.mode, effects.antennaPCV.modelType) still takes a silent default branch and is still printed verbatim as the active model. The atmosphere.realisticProfile.* mirror is a live bypass even for registered paths.

8. 'The goldens pass' is not a per-change statement: none of the four regression scripts runs in run_all_tests, and the default 'fast' mode skips the Monte-Carlo harness. What a golden does assert is correctly scoped by GoldenRunFingerprint.m:13-15 - 'It is not a claim that the numbers are RIGHT. It is a claim that they have not MOVED.' The one place the new goldens exceed that is linkUpdateMovedState=1, which does assert the sanctioned ISL link update still moves the owner's state (max|dX|=56.957 m, max|dPdiag|=2.44e5).

9. Per-epoch NIS pooling assumes epoch independence, which is measured false for at least one channel. MonteCarloConsistency.m:95-97 pools per-epoch NIS as independent; the per-channel table added in 91faccb reports lag-1 rho 0.09-0.30 for code/carrier/Doppler (N_eff ~ 1960-3006 of 3601 epochs) but rho=0.7254, N_eff=573 for the two-way channel, consistent with the 30 s broadcast-product cadence. Any two-way consistency verdict rests on ~573 independent samples, not 3601.

10. Joint multi-asset mode is disallowed by policy only. Nothing in config resolution rejects multiAsset.mode='joint' outside the distributed path; three shipped test fixtures select it and the joint branches in ReverseGNSSSimulation are live. If the constraint is real it belongs in validateMasterConfig.

11. The RNG guarantees an arc of at most 1,048,575 epochs. Beyond that the epoch field wraps (RngRegistry.m:106, ep = mod(epochIdx+1, 2^20)) and at exactly epochIdx = 2^20-1 an epoch stream collides with the persistent stream of the same identity. 12.1 days at dt=1 s - far outside any run, but a modular wrap with no guard, not a bound.

12. Config text alone does not determine a run on any j2-truth/two-body-EKF scenario: finalizeConfig silently replaces modelMismatch.sigma_mps2 <= 1e-6 with max(1e-8, 0.25*|a_J2|), and with useOrbitPropagator false would silently replace it with 1e-8, i.e. 100x SMALLER than the shipped default. The persisted resolved cfg in the run .mat is the only authoritative record.

---

# Contents — domain verification sections

Each section re-verifies the previous edition's claims against `170e37d`, marking every one
STILL-VALID / DRIFTED / SUPERSEDED / NOW-WRONG, and traces features that are new or were not covered.
Each carries its own APA 7 reference list with the page-referenced verbatim quotes used in it.

1. Clocks & Oscillators
2. Atmosphere
3. Orbits & Frames
4. Measurements & Error Chain
5. Filter & Attitude Estimation
6. Two-Way Time Transfer
7. Integer Ambiguity Resolution
8. ISL, Link Budget & Swarm Solvers
9. Simulation Flow, Stochastics & Validation

Appendix A — Complete `Paper/` folder coverage map (84 documents)
Appendix B — Round-2 corrections to the source inventory
Master Reference List (APA 7)

---

# Round-2 re-verification — Section: Clock & Oscillator Models

**Tree audited**: branch `feature/ground-orientation-exec`, HEAD `170e37d`, 2026-08-13. Every file:line below was re-read at HEAD; every line number in the 2026-08-06 document was re-checked and is reported as STILL-VALID / DRIFTED / SUPERSEDED / NOW-WRONG / NEW.

**Headline for this domain.** The clock section of the existing document is now **substantially out of date, and almost entirely in the code's favour**. Four of its findings are dead:

- **F1 (2/N flicker amplitude)** — fixed and **committed** in `5995bfa` (2026-08-08). The section body at doc line 135 still says "present but **uncommitted**"; that sentence is NOW-WRONG.
- **F3 (default asset clock ~7 orders quieter than JOW caesium)** — dead. `cfg.clock.templateSource` was **removed** on 2026-08-10 and the `legacy` table deleted. There is now ONE catalogue, and I verified **all 24 numbers (8 classes × 3 coefficients) digit-by-digit against Winkel (2003) Table 2.1, p. 100 — every one exact**.
- **F6 (TCXO/RUBIDIUM mislabelled under a "jowTable2p1" banner)** — dead for the same reason; the removal commentary in `getClockTemplate_` documents exactly the mislabelling the audit found.
- **F7 (flicker Q ≈14× below Van Dierendonck, wrong Δt-scaling, no Q12 term)** — SUPERSEDED. The Allan-equivalent-RWFM formulation now reproduces **all three** Brown & Hwang flicker entries with the **correct Δt powers** and ratios 0.69 / 2.08 / 1.04.

Two things the old section did **not** have, and which I obtained this round: (a) **Brown & Hwang (1997) Ch. 11 has a text-free scan but is fully legible** — I transcribed eqs. (11.3.1)–(11.3.5), the flicker footnote, and Table 11.2, which turn the two-state Q from "cited indirectly" into a **primary, page-referenced verification**, and independently corroborate three of the eight catalogue rows; (b) **Van Dierendonck et al. (1984) is NOT in `Paper/`** — the old section's "transcribed from the page scan" quotes of it are unverifiable in-repo, and Brown & Hwang explicitly state that VD's eq. (60) `q12`/`q22` are **wrong**, which means the old document transcribed a known-erroneous form.

What is genuinely new and worth an audit: a whole **tower-oscillator-wander layer in R** (three new variance functions, four new gates, two new tests), and a **relativistic clock chain** touching seven builders. Both are unusually careful. I found **no live double-count** in either; I did find three latent ones and eight logical flaws, listed at the end.

---

### Power-law noise model and h-parameter convention

- **Code**: `+models/+clocks/ClockModel.m:7` — `S_y(f) = h2*f^2 + h1*f + h0 + hMinus1/f + hMinus2/f^2` (one-sided PSD of fractional frequency); ADEV slope table at `:15–20`.
- **Status vs doc**: STILL-VALID (line numbers unchanged).
- **Verdict**: correct — the canonical IEEE/NIST five-term power law, and the h-coefficients carry the same meaning as both sources (verified through the ADEV mapping, which is convention-sensitive).
- **Sources**:
  - Riley, W. J. (2008). *Handbook of frequency stability analysis* (NIST Special Publication 1065). NIST. — "It has been found that the instability of most frequency sources can be modeled by a combination of power-law noises" (p. 5, §3.2). *(Correction to the old document, which cited "p. 8, §4.3" — the printed page is 5 and the section is 3.2; verified in the clean-text duplicate `2220.pdf.pdf`, PDF page 15.)*
  - Winkel, J. Ó. (2003). *Modeling and simulating GNSS signal structures and receivers* [Doctoral dissertation, Universität der Bundeswehr München]. — eq. (2.154), transcribed p. 99: `S_y(ω) = 2π²h−2/ω² + πh−1/ω + h0/2`, with the surrounding text "the one-sided spectral density of the fractional frequency fluctuation is assumed to be in the form" (p. 99).
- **Critical analysis**: The docstring slope table (WPM τ⁻¹, FPM τ⁻¹, WFM τ⁻¹ᐟ², FFM τ⁰, RWFM τ⁺¹ᐟ²) is exact. Winkel's ω-domain form and the code's f-domain one-sided form give the same Allan mapping, so the catalogue values are convention-compatible with both the synthesis and Q. Every shipped class has `h2 = h1 = 0` (`ConfigFactory.m:2804–2815`), so the WPM/FPM branches remain inert in all default runs — the colored component is flicker-FM only.

---

### Two-state EKF process-noise Q — now verified against a PRIMARY source

- **Code**: `+models/+clocks/ClockModel.m:493–494, 538–539, 544–550` —
  `q1 = h.h0/2; q2 = 2*pi^2*h.hMinus2;`
  `Q_s = [q1*dt + q2_eff*dt^3/3, q2_eff*dt^2/2; q2_eff*dt^2/2, q2_eff*dt]`, then `T = diag([c,c]); Q = T*Q_s*T'`.
- **Status vs doc**: DRIFTED (was `:389–401`, now `:457–551`) **and** SUPERSEDED in substance (the flicker handling changed completely — see next entry).
- **Verdict**: correct — now matched **term-for-term and symbol-for-symbol** to Brown & Hwang's own two-state derivation, including the metres conversion.
- **Sources**:
  - Brown, R. G., & Hwang, P. Y. C. (1997). *Introduction to random signals and applied Kalman filtering* (3rd ed.). Wiley. §11.3, "Receiver Clock Modeling". — "A suitable clock model that makes good sense intuitively is a 2-state random-process model." (p. 429; *transcribed from scanned page*, PDF page 220 of `Paper/Error Calculation/KalmanFilter/Brown.pdf`). Equations (11.3.1)–(11.3.3), transcribed from the same page:
    `E[x_p²(Δt)] = S_f·Δt + S_g·Δt³/3` ; `E[x_f²(Δt)] = S_g·Δt` ; `E[x_p(Δt)x_f(Δt)] = S_g·Δt²/2`.
    Equation (11.3.5), transcribed p. 431: `S_f ~ h0/2` ; `S_g ~ 2π²h−2`.
  - Brown & Hwang (1997) — "the numbers given in Table 11.2 correspond to clock error in units of seconds. When used with clock error in units of meters, the values … must be multiplied by the square of the speed of light" (p. 431; *transcribed from scanned page*).
  - Carpenter, J. R., & Lee, T. (2008). *A stable clock error model using coupled first- and second-order Gauss-Markov processes* (AAS 08-109). — "Clearly, the clock drift variance increases linearly with elapsed time, and the clock bias increases as the cube of elapsed time." (Appendix, p. 11).
- **Critical analysis**: With `S_f ≡ q1 = h0/2` and `S_g ≡ q2 = 2π²h−2`, the code's three RWFM/WFM entries are **identical** to (11.3.1)–(11.3.3): `q1·dt + q2·dt³/3`, `q2·dt²/2`, `q2·dt`. The `T = diag([c,c])` similarity is exactly the `c²` scaling Brown & Hwang prescribe for metre units. This is the strongest verification in the section and it replaces the old document's indirect citation (which had wrongly reported the in-repo Brown scan as unusable — it has no text layer, but it renders and transcribes cleanly at 150 dpi). One residual honesty point unchanged from the old audit: the filter's Q is built from the **same h-coefficients** as the truth clock (`ScenarioFactory.m:49` hands `asset.clock` to the EKF), so no oscillator-spec mismatch is ever simulated. That is a perfectly-tuned-filter idealisation, and it must be stated wherever NIS/NEES consistency is claimed.

---

### Flicker FM carried as an Allan-equivalent random walk (`flickerAsEquivalentRwfmInQ`) — NEW

- **Code**: `+models/+clocks/ClockModel.m:519–524` — `q2_ffm = 6*log(2)*h.hMinus1/dt_s; q2_eff = q2 + q2_ffm;`. Default ON (`:102`). The old `driftFlickerInQ` knob is **removed with a loud warning** rather than silently remapped (`:142–151`).
- **Status vs doc**: NEW (replaces the old "2·ln2·h−1·Δt in Q11 only" heuristic that F7 criticised).
- **Verdict**: correct — a derivation, not a tuning constant, and it lands within a factor 2 of Brown & Hwang's corrected flicker terms in **all three** matrix entries with the **right Δt powers**.
- **Sources**:
  - Brown & Hwang (1997), p. 430 — "Flicker noise gives rise to a term in the variance expression that is of the order of Δt², and it is impossible to model this term exactly with a finite-order state model." (*transcribed from scanned page*).
  - Brown & Hwang (1997), p. 430 — "an approximate solution is to simply elevate the theoretical V of the 2-state model so as to obtain a better match in the flicker floor region" (*transcribed from scanned page*).
  - Brown & Hwang (1997), p. 430 footnote — "There are mistakes in the **Q** matrix given by Eq. (60) in the reference. The correct expressions for the q12 and q22 terms are" followed by (transcribed): `q12 = q21 = h−1·Δt + π²h−2·Δt²` ; `q22 = h0/(2Δt) + 4h−1 + (8/3)π²h−2·Δt` ; and "The q11 term is correct in the reference": `q11 = (h0/2)Δt + 2h−1Δt² + (2/3)π²h−2Δt³`.
  - Winkel (2003), p. 100 — "There is no problem generating the white and random walk frequency noise. However, the flicker term poses a major problem that cannot be solved satisfactorily in time domain."
  - Winkel (2003), eq. (2.156), transcribed p. 99: `Aσ²_y(τ) = h0/(2τ) + 2ln2·h−1 + (2π²/3)τ·h−2`.
- **Critical analysis**: I re-derived the equivalence independently. Setting the RWFM Allan variance `(2π²/3)h−2τ` equal to the flicker floor `2ln2·h−1` at `τ = dt` gives `h−2_eq = 3ln2·h−1/(π²dt)`, hence `q2_ffm = 2π²h−2_eq = 6ln2·h−1/dt` — the code's line exactly. Feeding it through `q2_eff` then produces flicker contributions `2ln2·h−1·Δt²` (Q11), `3ln2·h−1·Δt` (Q12) and `6ln2·h−1` (Q22). Against Brown & Hwang's **corrected** footnote the ratios are **0.693 / 2.079 / 1.040** — i.e. Q22 within 4 %, Q12 2× conservative, Q11 31 % light, and crucially the **Δt exponents (2, 1, 0) now match**, which the old heuristic did not (it put a `Δt¹` term in Q11 and nothing in Q12).
  Two important corrections to the existing document follow. First, its transcription of VD1984 eq. (60) as `Q12 = 2h−1Δt` and `Q22 = 2h−1` reproduces the form Brown & Hwang explicitly call **mistaken**; the "code is 14× smaller than VD" arithmetic was therefore computed against a wrong reference as well as against superseded code. Second, the code's approach — inflate the 2-state model to cover the flicker floor — is **precisely what Brown & Hwang recommend** on p. 430, so this is now a sourced design rather than an unsourced heuristic. The equivalence is also validated numerically rather than asserted: `tests/test_clock_truth_matches_filter_q.m:87–96` holds `std(e_b)/√Q11` and `std(e_d)/√Q22` inside **[0.75, 1.30]** for **all eight** catalogue classes plus a deliberately flicker-heavy custom oscillator, measuring the truth's own two-state prediction residual (with the tracked `bdot` predicted out at `:74` — a subtlety the test's own header records as a trap).

---

### Truth-side clock propagation `step` — exact two-state discretisation

- **Code**: `+models/+clocks/ClockModel.m:295–316` — `q1 = h0/2; q2 = 2π²h−2;` then a hand-rolled Cholesky of the **same** `Q_s` the filter charges: `v11 = q1*dt + q2*dt^3/3; v12 = q2*dt^2/2; v22 = q2*dt; L11 = sqrt(v11); L21 = v12/L11; L22 = sqrt(v22 - L21^2);` with `n_bias = L11*g1`, `dn_freq = L21*g1 + L22*g2`. Update at `:335–338`.
- **Status vs doc**: **SUPERSEDED**. The old section described forward Euler with independent WFM/RWFM draws (`:258–296`) and called its one-part-in-n error "standard and harmless". That code is gone (commit `09716ec`).
- **Verdict**: correct — the truth now draws from *exactly* the discrete covariance the EKF charges, so the two are the same process by construction.
- **Sources**: Brown & Hwang (1997), eqs. (11.3.1)–(11.3.3), p. 431 (as above) — the covariance being Cholesky-factored is literally that matrix. Winkel (2003), p. 100 — "There is no problem generating the white and random walk frequency noise."
- **Critical analysis**: The in-code justification is measured, not asserted: `sqrt(Q11)/empirical` was **0.01 for OCXO2 and 0.17 for TCXO** before the fix (`:288–290`), i.e. the filter charged a phase process noise its own truth never generated — invisible for WFM-dominated caesium (where `q2·dt³/3` is ~11 decades below `q1·dt`) and 100× wrong for RWFM-dominated crystals. The draw order (`g1` then `g2`) and `L(1,1)` are deliberately preserved so a caesium golden moves only in the last digits. One genuine consequence for the old document's F30-adjacent claims: the truth/filter clock pairing is now **exact for WFM+RWFM and approximate only for flicker**, which is the honest scope statement. Note also `tests/test_clock_truth_matches_filter_q.m:7–16` carries an explicit anti-overclaim warning: fixing this moved the clock-ladder NIS by <0.1 in all six controlled runs, so the test "guards a correctness property of the clock pairing, nothing more".

---

### FFT colored-noise synthesis — the 2/N amplitude fix is COMMITTED

- **Code**: `+models/+clocks/ClockModel.m:234` — `A_frac = sqrt(max(Sy_frac,0) * fs * N) / 2;` with the derivation comment at `:229–233`. Target PSD at `:227`; Hermitian symmetrisation `:239`; `y = real(ifft(...))` `:240`; phase by `cumtrapz` `:244`.
- **Status vs doc**: **NOW-WRONG in the doc body**. Doc line 135 states the fix is "present but **uncommitted**" and that "`git diff` shows HEAD still has `sqrt(... * fs / N)`". `git blame -L 228,240` attributes the corrected line to **`5995bfa` (2026-08-08 10:59)**, and `git status --porcelain +models/+clocks/` is clean. (The doc's own F1 register row was already corrected on 2026-08-09; the section body was not.)
- **Verdict**: correct.
- **Sources**:
  - Winkel (2003), p. 100 — "The most sensible way to generate the flicker noise (or in general colored noises with a spectral density of the form 1/f α) is perhaps to perform the simulation in frequency domain and transform the result back to time domain".
  - Kasdin, N. J. (1995). Discrete simulation of colored noise and stochastic processes and 1/f^α power law noise generation. *Proceedings of the IEEE, 83*(5), 802–827. (EXTERNAL — cited by Winkel as `[Kas95]`; not held in `Paper/`.)
- **Critical analysis**: I re-derived the scaling once more from the callee's side rather than trusting the comment: MATLAB's `ifft` carries `1/N`; each Hermitian-paired bin is `X_k = A_k(g1 + i·g2)` with unit-variance reals, so `Var(y_n) = (4/N²)ΣA_k²`; matching `Σ S_y(f_k)·Δf` with `Δf = fs/N` bin-by-bin requires `A_k = sqrt(N·fs·S_k)/2`. That is the committed line. The practical consequence remains as the audit stated: **every archived run predating 2026-08-08 had no flicker floor** (amplitude low by 2/N, i.e. ~5×10⁻⁷ in power at N = 4096) — which matters when re-citing any pre-08-08 clock ladder result.

---

### DC and Nyquist bins of the synthesised spectrum

- **Code**: `+models/+clocks/ClockModel.m:670–680` — `X_sym(1) = abs(X(1));` and `X_sym(N/2+1) = abs(X(N/2+1));`; the DC PSD dodge is `f_pos(1) = f_pos(2)` at `:222`.
- **Status vs doc**: STILL-VALID as a finding, DRIFTED in line numbers (was `:532–542` and `:202`), and now **materially larger** than when written, because the amplitude fix multiplied it by N/2.
- **Verdict**: partially correct — a real non-standard construction whose practical consequence is small for the shipped configuration but is *not* small for the crystal classes.
- **Sources**: Kasdin (1995) (EXTERNAL) — standard practice zeroes the DC bin; no in-repo source prescribes `abs()`.
- **Critical analysis**: `abs()` on a complex Gaussian gives a **Rayleigh** magnitude, strictly positive, with mean `√(π/2)`. Reconstructing: `A(1) = sqrt(S_y(f_2)·fs·N)/2` and `S_y(f_2) = h−1·N/fs`, so `A(1) = N√h−1/2`, and the DC contribution to `y_n` is `(1/N)·A(1)·|g| = 0.5√h−1·|g|`, mean `0.6267·√h−1` — the doc's "≈0.63·√h−1" **re-derived and confirmed**. Numerically, per realisation: CESIUM1 `1.98×10⁻¹³` (0.21 m of bias ramp over 3600 s), OCXO2 `3.14×10⁻¹²` (3.4 m), **TCXO `6.27×10⁻¹¹` (67.6 m)**. Two mitigations make this benign in practice rather than merely small: a constant fractional-frequency offset is exactly what the receiver `bdot_rx` state estimates, and for the towers it is captured exactly by the product's drift term `bd_p` (`clockAtProductEpoch` returns `getClockDriftMetersPerSecond`, which includes the coloured component). It also has **zero Allan variance**, so it corrupts no ADEV figure. It should nevertheless be zeroed: it is a one-sided (never negative) frequency bias injected into every realisation, which is not what the model claims to generate. Nyquist is likewise `abs()`-forced but contributes `√(2h−1/N)/2` — negligible. Circular-FFT truncation below `f = fs/N` remains inherent and undocumented in the docstring.

---

### Theoretical Allan deviation overlay

- **Code**: `+models/+clocks/ClockModel.m:604–612` — `3*h2/(4π²τ²)` (WPM), `1.038*h1/(4π²τ²)` (FPM), `h0/(2τ)` (WFM), `2*ln2*hMinus1` (FFM), `(2π²/3)*hMinus2*τ` (RWFM).
- **Status vs doc**: DRIFTED (was `:466–474`).
- **Verdict**: correct, with the WPM/FPM measurement-bandwidth factors deliberately dropped (documented `:601–603`) and inert because `h2 = h1 = 0` everywhere.
- **Sources**:
  - Riley (2008), NIST SP 1065, §7.1 — "A = 4π²/6   B = 2·ln2   C = 1/2   D = 1.038 + 3·ln(2πfhτ0)/4π²   E = 3fh /4π²" (p. 74), applied to the table row form `σ²y(τ) = A·f²·Sy(f)·τ` etc. (p. 74).
  - Winkel (2003), eq. (2.156), p. 99 (transcribed): `Aσ²_y(τ) = h0/(2τ) + 2ln2·h−1 + (2π²/3)τ·h−2`.
- **Critical analysis**: Digit checks re-run from the NIST row forms, not from the old document: RWFM `A·f²·(h−2f⁻²)·τ = (4π²/6)h−2τ = (2π²/3)h−2τ` ✓; FFM `B·f·(h−1f⁻¹) = 2ln2·h−1` ✓; WFM `C·h0/τ = h0/(2τ)` ✓; WPM `E·f⁻²·(h2f²)τ⁻² = 3f_h h2/(4π²τ²)` → code takes `f_h = 1 Hz` ✓. **One nuance the old document glossed**: NIST's typography `D = 1.038 + 3·ln(2πfhτ0)/4π²` is ambiguous; the standard IEEE-1139/Barnes form divides the *whole bracket* by 4π², and the code's `1.038/(4π²)` follows the standard reading. Worth stating explicitly rather than claiming a bare match. Two stale comment values the old audit flagged in the *legacy* template annotations are gone with that table.

---

### Empirical Allan deviation estimators — one exact, one non-standard

- **Code**: (a) `+revgnss/AllanDeviation.m:49–51` — `d2 = x_s(2m+1:N) - 2*x_s(m+1:N-m) + x_s(1:N-2m); sig = sqrt(sum(d2.^2)/(2*n_terms*(m*dt)^2));`  (b) `+models/+clocks/ClockModel.m:574–587` — block **means** of phase over `m` samples, non-overlapped stride, second difference of the block means, normalised as ordinary AVAR.
- **Status vs doc**: (a) STILL-VALID, DRIFTED (`:48–51` → `:49–51`). (b) STILL-VALID, DRIFTED (`:436–449` → `:574–587`).
- **Verdict**: (a) correct — matches NIST eq. (11) symbol-for-symbol including the `N−2m` term count. (b) flawed as an AVAR estimator; it is a non-overlapped modified-Allan-like statistic normalised as AVAR.
- **Sources**:
  - Riley (2008), NIST SP 1065 — "In terms of phase data, the overlapping Allan variance can be estimated from a set of N = M + 1 time measurements as" (p. 16, §5.2.4), followed by eq. (11), transcribed: `σ²_y(τ) = 1/(2(N−2m)τ²) Σ [x_{i+2m} − 2x_{i+m} + x_i]²`. *(Correction: the old document cited §5.2.3; the section is 5.2.4 in the printed text.)*
  - Riley (2008) — "The overlapped Allan deviation is the most common measure of time-domain frequency stability." (p. 16, margin note).
  - Robins, W. P. (1984). *Phase noise in signal sources*. Peter Peregrinus/IET. — used as the independent statement of the two-sample variance definition (§9.4.2).
- **Critical analysis**: The report path (`+revgnss/+report/oscillatorValidation.m` → `revgnss.AllanDeviation.compute`) is on the **exact** estimator, so published ADEV figures are trustworthy; `compute` uses `median(diff(t))` so a dropped epoch cannot corrupt `dt`, and caps `m ≤ (N−1)/4`. The `ClockModel` internal estimator's √2 WFM underestimate is unfixed and will make the empirical curve sit visibly below the theoretical overlay on its own diagnostic figure. **New this round**: `AllanDeviation.getRxClockBiasTrue` reads `truth.rxClockBias_s`, which since the relativity work carries the `c·y_rel·t` ramp. A *linear* ramp has identically zero second difference, so the ADEV is unaffected — I checked this specifically because it is the obvious way the relativity change could have silently corrupted a published figure. It does not.

---

### Oscillator catalogue vs Winkel Table 2.1 — ONE table, all 24 numbers exact

- **Code**: `+revgnss/ConfigFactory.m:2766–2820` (`oscillatorCatalog_`), `:2711–2764` (`getClockTemplate_`), `:2822–2842` (`normaliseOscillator_`), threaded via `makeClockConfig` `:420–465`. The removed selector errors loudly at `:1920–1927`.
- **Status vs doc**: **SUPERSEDED**. The doc's entire "h-parameter templates vs. JOW Table 2.1 — digit-by-digit" entry, and register rows **F3 and F6**, describe a two-table architecture that no longer exists.
- **Verdict**: correct — I transcribed Winkel's table from the PDF text layer independently of the code and compared all 24 coefficients; **every one matches exactly**.
- **Sources**:
  - Winkel (2003), Table 2.1, p. 100 — caption "Table 2.1.: Parameters for the Allan variance of several oscillators"; column heads "White freq. noise (h0) | Flicker (h−1) | Integrated freq. noise (h−2)"; rows (verbatim): "Standard quartz 2· 10−19 s 7· 10−21 2· 10−20 Hz"; "TCXO 1· 10−21 s 1· 10−20 2· 10−20 Hz"; "OCXO1 8· 10−20 s 2· 10−21 4· 10−23 Hz"; "OCXO2 2.51· 10−26 s 2.51· 10−23 2.51· 10−22 Hz"; "Rubidium1 2· 10−20 s 7· 10−24 4· 10−29 Hz"; "Rubidium2 1· 10−23 s 1· 10−22 1.3· 10−26 Hz"; "Cesium1 1· 10−19 s 1· 10−25 2· 10−32 Hz"; "Cesium2 2· 10−20 s 7· 10−23 4· 10−29 Hz".
  - Brown & Hwang (1997), Table 11.2, p. 431 — "Typical Power Spectral Density Coefficients for Various Timing Standards" (*transcribed from scanned page*): Compensated crystal `2(10⁻¹⁹) / 7(10⁻²¹) / 2(10⁻²⁰)`; Ovenized crystal `8(10⁻²⁰) / 2(10⁻²¹) / 4(10⁻²³)`; Rubidium `2(10⁻²⁰) / 7(10⁻²⁴) / 4(10⁻²⁹)`.
- **Critical analysis**: All eight rows verified: QUARTZ ✓✓✓, TCXO ✓✓✓, OCXO1 ✓✓✓, OCXO2 ✓✓✓, RUBIDIUM1 ✓✓✓, RUBIDIUM2 ✓✓✓, CESIUM1 ✓✓✓, CESIUM2 ✓✓✓. **An independent corroboration the old document did not have**: Brown & Hwang's Table 11.2 rows are *numerically identical* to Winkel's Standard quartz, OCXO1 and Rubidium1 — three of the eight rows are therefore double-sourced. `ZERO` is honestly declared as not from the source (`:2816–2819`). `getClockTemplate_` **errors** on an unknown name (`:2756–2762`) where it previously warned and substituted OCXO, so a campaign can no longer be labelled with an oscillator it never ran; and `cfg.clock.templateSource` now throws `ConfigFactory:templateSourceRemoved` rather than being ignored. `tests/test_clock_template_sourcing.m:32–45` carries its own independent transcription of the source table, so the gate is a *source* comparison, not a self-comparison. The aliases `OCXO→OCXO2` and `RUBIDIUM→RUBIDIUM1` (`:2740–2743`) preserve pre-2026-08-10 scenarios — see the next entry for why the first one matters more than it looks.
  Residual documentation drift: `makeClockConfig`'s own docstring at `:425` still lists `'TCXO'|'OCXO'|'Rubidium'|'AtomicLike'|'Custom'` — three of those five would now **throw**.

---

### Default oscillator choices, and what the `OCXO → OCXO2` alias costs — NEW

- **Code**: asset `cfg.asset.clockType = 'CESIUM1'` (`config/masterConfig.m:232`, again `:1183`); towers `cfg.towers(k).clockType = 'OCXO'` (`masterConfig.m:1918`) → aliased to **OCXO2**; `cfg.clock.tower.deterministic = false` (`masterConfig.m:223`) applied **unconditionally** to every tower in `ConfigFactory.m:715–721`.
- **Status vs doc**: NEW (the doc's F3 concerned a template table that no longer exists; the live question is now which *catalogue row* the defaults select).
- **Verdict**: partially correct — the values are perfectly sourced, but the **selection** puts the noisiest long-τ crystal in the catalogue on the ground segment, where a 30 s broadcast product makes its wander the dominant term in code R.
- **Sources**: Winkel (2003), Table 2.1, p. 100 (as above). `ConfigFactory.m:2786–2802` states the inversion in-code: "OCXO2 best short-term of all (4.1e-11 at 1 s), worst long-term drift (4.9e-9 at 4 h)".
- **Critical analysis**: I computed the uncorrectable oscillator wander `c·σ_y(age)·age` at the two ends of one product cycle (age 5 s just after a broadcast, age 34 s just before the next, from `t_prod = floor((t−5)/30)·30`):

  | class | σ_y(1 s) | wander @ age 5 s | wander @ age 34 s |
  |---|---|---|---|
  | QUARTZ | 4.91e-10 | 1.24 m | **21.59 m** |
  | TCXO | 3.82e-10 | 1.23 m | **21.59 m** |
  | OCXO1 | 2.07e-10 | 0.165 m | 1.158 m |
  | **OCXO2 (the default)** | 4.11e-11 | 0.137 m | **2.416 m** |
  | RUBIDIUM1 | 1.00e-10 | 0.067 m | 0.178 m |
  | RUBIDIUM2 | 1.20e-11 | 0.018 m | 0.121 m |
  | CESIUM1 | 2.24e-10 | 0.150 m | 0.391 m |
  | CESIUM2 | 1.00e-10 | 0.069 m | 0.202 m |

  Against the golden product sigma at age 34 s, `sqrt(0.10² + 34²·0.001²) = 0.1056 m`, the default ground clock contributes **2.416 m — 22.9× the product's own error**, and it is by construction the largest single entry in the code-R diagonal. Both figures reproduce the code's own claims (`CarrierMeasurementBuilder.m:219` quotes 2.4161 m; `masterConfig.m:220` quotes 2.5 m and "~24×") to 4 significant figures, so the implementation and its commentary agree.
  Two consequences worth stating in any publication. (1) The `OCXO` alias silently selects **OCXO2**, the *short-term-optimised* crystal, not the flatter OCXO1 — a defensible reading of "OCXO" but one that costs a factor 2.1 in the quantity that actually matters here (34 s wander), and Winkel's own naming does not privilege either. (2) Even the *best* catalogue class leaves **0.12–0.18 m** of uncorrectable ground-clock wander at a 34 s product age; this is an architectural floor of the 30 s/5 s broadcast-product design, not an oscillator-quality problem, and it cannot be reduced by choosing a better clock.
  Also verified: `masterConfig.m:1928` still writes `cfg.towers(k).clock.deterministic = true` with the comment "Tower clock: OCXO, deterministic for convergence test" — that comment is **NOW-WRONG**, because `ConfigFactory.m:718` overwrites it from `cfg.clock.tower.deterministic = false` about 700 lines later. Reading `masterConfig` alone gives the wrong answer about whether the ground oscillators run. They do.

---

### Relativistic clock, truth side — NEW

- **Code**: `+models/+clocks/ClockModel.m:80–91` (property), `:335` — `new_bias_s = obj.bias_s + dt_s*(obj.fracFreq + obj.relativisticFracFreq) + n_bias_wfm;`, and `:388` — `y = obj.fracFreq + obj.coloredFracFreq_current + obj.relativisticFracFreq;`. Armed only when `physics.relativity.clock.truth.enable` is true, at `+revgnss/ConfigFactory.m:1977–1983`, from `revgnss.Relativity.geoClockFracFreq(alt)`.
- **Status vs doc**: NEW (the old document listed the periodic term as absent, F13, and said nothing about the constant term's channel consistency because the truth accessor then excluded it).
- **Verdict**: correct for a circular orbit; the periodic `e·sinE` term remains absent (F13 STILL-VALID).
- **Sources**:
  - Ashby, N. (2003). Relativity in the Global Positioning System. *Living Reviews in Relativity, 6*, 1. (EXTERNAL, web-sourced) — the standard statement that a GPS-orbit clock's rate offset comprises a gravitational blueshift and a second-order Doppler term, plus a periodic eccentricity correction `−2√(GM a)·e·sinE/c²` that vanishes for `e = 0`.
  - Brown & Hwang (1997), §11.3 (p. 426–431) — establishes the receiver-clock error as a directly estimated state; the relativistic offset here is a deterministic rate on that state.
- **Critical analysis**: I re-derived `y_rel` from `revgnss/Relativity.m` constants: `y = (GM/c²)(1/Re − 1/r) − v²/(2c²) + (ωRe)²/(2c²)` with `r = Re + 35 786 km`, `v = √(GM/r)` gives **`y_rel = 5.3877×10⁻¹⁰`**, `c·y = 0.161521 m/s`, **581.474 m over 3600 s**, **+46.55 µs/day** — matching every number quoted in the code comments (`0.1615`, `581.4741`, `+46.6 µs/day`) to the digits printed. The sign convention is right: gravitational blueshift dominates, the satellite clock runs **fast**, and the bias ramps positive.
  The genuinely important part is the *consistency* fix. `getFractionalFrequency` now includes the term, so the truth Doppler and the truth pseudorange describe one clock. Before, they did not: the range ramped at 0.1615 m/s while the Doppler reported exactly zero, and because the EKF enforces `b' = bdot`, the difference was projected into **position** by the Kalman gain — 13.07 m on an OCXO Q against 0.20 m on a caesium Q, with `cos(error, K·1) = 0.9997` and the reported sigma identical to 4 s.f. in both, so **the covariance could not see it and `err/σ` reached 34** (`ClockModel.m:374–383`). That is a textbook example of an inconsistency that NIS is blind to, and it is worth citing as such.

---

### Relativistic clock, model side (`RelativisticClockCorrection`) — NEW

- **Code**: `+models/+clocks/RelativisticClockCorrection.m:36–63` (`fracFreq`, gated on `physics.relativity.clock.model.enable`, explicit `model.fracFreq` wins, else derived from `cfg.orbit.altitudeMean_m`), `:65–70` (`bias_m = c·y·t_s`), `:72–77` (`rate_mps = c·y`). Resolved into the config at `ConfigFactory.m:1992–2007`.
- **Status vs doc**: NEW.
- **Verdict**: correct, and correctly argued as **not** truth assistance.
- **Sources**: Ashby (2003) (EXTERNAL) — `y_rel` for a nominally circular orbit is computable from the broadcast semi-major axis alone; GPS applies the analogous correction as a *published* frequency offset applied at the satellite, not as a measured quantity.
- **Critical analysis**: The provenance argument in the class docstring (`:9–12`) is sound and I checked it against the code rather than accepting it: `fracFreq` reads only `cfg.orbit.altitudeMean_m` and never any truth object, and an explicitly configured `model.fracFreq` is never overwritten (`ConfigFactory.m:1996–2006`), which is the supported way to configure a deliberate model-minus-truth residual — the same pattern as `frames.eopModel` against `frames.truthEop`. The reference epoch is shared by construction (`t_s = 0` at the first epoch for both the correction and the truth `ClockModel`), documented at `:29–32` and pinned by `tests/test_wpD_relativistic_clock.m:134–135` (vanishes at `t=0`, exactly doubles from 3600 s to 7200 s). Gating is hard: every method returns exactly 0 when off, so a relativity-off run is byte-identical.
  **One inert-config finding**: `cfg.physics.relativity.clock.enable` (`masterConfig.m:97`, `:2533`) is a *master* with **no direct consumer** — every reader is `.truth.enable` or `.model.enable`. It works only because `expandEnableToggles` (`masterConfig.m:265–270`) slaves the pair to it. `config/ladder/feat/feat014_noRelativity.json:11` says so explicitly ("the master reaches no consumer"), and `tests/test_wpD_relativistic_clock.m:94` has to call `expandEnableToggles` by hand. Setting the master on an already-resolved config therefore does nothing — a live trap for anyone writing an ablation by struct assignment rather than through the resolver.

---

### Relativistic term consistency across all seven consumers — NEW, prime double-count site

- **Code**: `CodeMeasurementBuilder.m:73` (`b_rx_est = x(b) + bias_m(cfg,t_s)`); `CarrierMeasurementBuilder.m:72–73` (same term, same epoch); `DopplerMeasurementBuilder.m:138–139` (`bdot_rx_est = x(bdot) + rate_mps(cfg)`); `ISLMeasurementBuilder.m:167–181, 227, 253` (legacy broadcast branch only); `TwoWayTimeTransferBuilder.m:364–366` (postfit); `PseudorangeModelOnlyBuilder.m:44–46` (postfit); `ScenarioFactory.m:102–113` (initial state seeded in the **residual** domain); `SimulationDataStore.m:719–732` (adds it back for estimate-vs-truth reporting).
- **Status vs doc**: NEW.
- **Verdict**: correct — **no double count found**. I traced every site from both directions (what the caller passes, what the callee assumes) and re-derived the ISL cancellation algebraically.
- **Sources**: internal consistency requirement; no external formula. Brown & Hwang (1997), §11.3 (p. 428) — "this receiver clock error is the same on all measurements", the property that makes an additive known term cancel out of `z − h` without touching **H**.
- **Critical analysis**: The invariant is: *the truth clock carries `c·y_rel·t` once (integrated into `bias_s`), the estimator adds the same published constant to whichever state the channel observes, and the clock states therefore estimate only the oscillator residual.* Each of the seven sites implements exactly one leg of that.
  The ISL case is the subtle one and commit `9a52cfc` gets it right. `z = ρ_true + b_rx,true − b_tx,true + n`; both spacecraft inherit the same `relativisticFracFreq` (`MultiAssetConfig.finalizeAsset_` copies the primary's clock struct), so **the relativistic term cancels identically in z**. Two `h` branches follow: when the secondary clock is an estimated state, both sides are residual-domain and *nothing is added* (`:227`, `h = ρ_model + x(b_rx) − x(b_tx)`); when the legacy broadcast product is used, `b_tx,prod` is built from the *truth* accessor and so carries the full term while `x(b_rx)` does not, so `h` must rebuild it — `h = ρ_model + (x(b_rx) + relClkBias_m) − b_tx,prod`. I verified `z − h = (ρ−ρ_model) + b_osc,rx − x(b_rx) + pb.clk` — the term cancels and the state stays residual-domain. Without the fix, `h` ran **581 m short** on a row weighted at its thermal sigma; `config/ladder/ISL/isl016_carrierFloatAmbiguity.json:10` records mean NIS **735 109 → 95.35**.
  The `ScenarioFactory.m:110–113` initialisation is the least obvious and most necessary: the drift state is seeded as `getDriftMetersPerSecond() − rate_mps`, because seeding the full value against a residual-domain state with `P0 ~ 1e-3 m/s` opens the run **~160σ out**. `t = 0` makes the bias leg identically zero, so the bias line is unchanged.
  **Where I looked hardest and found nothing**: an "extra correction plus iterative solution" double count. `RelativisticClockCorrection` is never applied inside the light-time iteration (which works in geometric range), and the Shapiro delay is a separate, independently gated term (`physics.relativity.shapiro`), so the two relativistic effects cannot collide.

---

### Oscillator-only accessors and the proper-time split — NEW

- **Code**: `+models/+clocks/ClockModel.m:396–430` (the "WHICH ONE DO I WANT?" block and `getOscillatorFractionalFrequency` / `getOscillatorDriftMetersPerSecond`); `+revgnss/TruthEndpointReplayClock.m:40–57`; consumers `ReciprocalEndpointTruthProvider.m:43` and `TwoWayISLMeasurementBuilder.m:1212`.
- **Status vs doc**: NEW.
- **Verdict**: partially correct — the *rate* split is exactly right and prevents a real 0.1615 m/s double count; the surrounding justification overstates what `properTimeRate` actually carries (see Logical flaws L2/L3).
- **Sources**: Ashby (2003) (EXTERNAL) — the proper-time rate of an orbiting clock is `dτ/dt = 1 − (GM/r + v²/2)/c²` to first post-Newtonian order; the *difference* against a ground clock is the observable frequency offset.
- **Critical analysis**: The algebraic identity in the docstring (`:411–416`) is exact and I verified it numerically: `properTimeRate(r_sat, v_sat) − properTimeRate(Re, v_ground) = (1 − 1.5778×10⁻¹⁰) − (1 − 6.9648×10⁻¹⁰) = +5.3870×10⁻¹⁰ = y_rel` to 4 s.f. So a coordinate-time channel must use the *total* rate and a proper-time channel the *oscillator-only* rate, and the split is correct in principle. The split also fixed a silent catastrophic failure: before `getOscillatorDriftMetersPerSecond` existed on the replay clock, `ReciprocalEndpointTruthProvider` threw "Unrecognized method" every epoch, `SwarmRelativeSolver.fourTimestampObservables_` caught it, and the federated relative layer fell back to the **synthetic** observable for every pair and epoch (`TruthEndpointReplayClock.m:48–55`, commit `889dcf6`). That is a first-class example of a `try/catch` laundering a hard failure into a plausible-looking result, and it is now memorialised in place.

---

### Tower clock correction products (`TowerClockCorrectionProvider.compute`)

- **Code**: `+models/+clocks/TowerClockCorrectionProvider.m:85–93` (`t_prod = floor((t_s − latency)/interval)·interval`, floored at 0); mode switch `:99–221`; `truthHistoryProductNoisy` at `:147–170` with `towerClkModel = (b_p + b_noise) + (bd_p + d_noise)·age` and `var_corr = σ_b² + age²σ_d² + 2·age·covBD + extrapolationWanderVar_`; explicit-product evaluation `:283–341`.
- **Status vs doc**: DRIFTED in every line number (was `:72–80`, `:108`, `:110–113`, `:258`, `:447–483`) and **EXTENDED** by the wander term, which did not exist.
- **Verdict**: correct — the prediction variance is the exact error propagation of `b̃ + d̃·age` with `Cov(b̃,d̃) = covBD`, now with the physically necessary fourth term.
- **Sources**: standard broadcast/IGS clock-product prediction; no external formula. The σ values are declared as "IGS real-time-service class, not IGS-final" in `config/golden_baseline.json` (0.10 m ≈ 0.33 ns bias, 1e-3 m/s drift, 30 s update, 5 s latency, 120 s validity) — plausible but ❓ **unsourced in the repo**, unchanged from the old audit.
- **Critical analysis**: The resolved default remains `truthHistoryProductNoisy` (`masterConfig.m:3287`), and `cfg.estimator.towerClockMode = 'perfectCorrection'` at `masterConfig.m:2036` is still a **derived placeholder** carrying an explicit "DERIVED, NOT A KNOB" comment (`:2031–2035`) — the old document's **F4 withdrawal is re-confirmed**. Product noise is drawn ONCE per `(tower, t_prod)` from a pure function of that pair (`:863–899`), which is the right correlation structure for a broadcast product and is what makes the shared-error R blocks meaningful; the persistent cache is memoisation of a deterministic value, not the source of the sharing, and the code now says so at `:872–882`. The `covBD` field is a genuine, separate quantity (the product's own bias/drift estimate covariance) and is kept distinct from oscillator wander throughout — I checked, because conflating them is the obvious way this could double-count.
  Two sharp edges: `sigmaBias_m` differs between `masterConfig` (0.01 m) and `golden_baseline.json` (0.10 m), a 10× difference in the number every publication would quote; and `productConfig_`'s internal fallbacks (0.05 m / 0.001 m/s, `:689–690`) match neither — reachable only if a cfg omits `cfg.clocks.tower.product` entirely, which no shipped path does.

---

### Oscillator wander in the bias channel (`extrapolationWanderVar_`) — NEW

- **Code**: `+models/+clocks/TowerClockCorrectionProvider.m:748–780` — `var_m2 = (c · σ_y(age) · age)²` using the **theoretical** ADEV, zero for a deterministic clock, gated by `cfg.covariance.productClock.includeOscillatorWander` (default true, `masterConfig.m:559`).
- **Status vs doc**: NEW.
- **Verdict**: correct, and provably **exact** (not approximate) for the two noise types that dominate every shipped class.
- **Sources**: Winkel (2003), eq. (2.156), p. 99 (the `σ_y(τ)` used). Riley (2008), NIST SP 1065, §7.1, p. 74 (the same mapping).
- **Critical analysis**: The code calls `x_rms(τ) ≈ σ_y(τ)·τ` "a standard engineering approximation". I re-derived it and it is **better than that for this model**. The residual after a product correction that extrapolates with the *true* frequency at `t_prod` is `∫₀^τ (y(s) − y(0)) ds`. For frequency random walk with driving density `q2 = 2π²h−2`, `Var = q2τ³/3 = (2π²/3)h−2τ³`, and `[σ_y(τ)·τ]²` for the RWFM branch is `(2π²/3)h−2τ · τ² ` — **identical**. For WFM the truth accumulates `(h0/2)τ` of phase-jump variance and the branch gives `(h0/2τ)·τ² = h0τ/2` — **identical**. Only the flicker branch is approximate, which is unavoidable. This is a stronger statement than the code makes for itself and should be recorded.
  The approximation is nevertheless **measured**, not assumed: `tests/test_tower_clock_product_age_wander_in_R.m:165–195` (T5) compares the charge against the truth generator's own linear-prediction residual `b(t0+age) − [b(t0) + bdot(t0)·age]` over 24 seeds for all eight classes, printing the ratio and gating it to [0.4, 2.5]. The band is deliberately wide and the test says so ("this gate exists to catch an approximation that is WRONG, not one that is imprecise").
  One inherited hazard: the branch sums the **full** theoretical ADEV including `h2`/`h1`, which are zero for every built-in but reachable via `cfg.clock.customOscillators`. The *frequency* twin refuses in that case (see next entry); the bias twin does not — see Logical flaw L5.

---

### Oscillator wander in the frequency channel (`frequencyWanderVar_`) — NEW

- **Code**: `+models/+clocks/TowerClockCorrectionProvider.m:782–861` — `var_y = 2π²·h−2·age + 16·ln2·h−1`, times `c²`; explicit refusal on nonzero `h2`/`h1` at `:837–857`.
- **Status vs doc**: NEW.
- **Verdict**: correct — and it corrects two errors an obvious implementation would have made, both in the right direction, both measured.
- **Sources**: Winkel (2003), eq. (2.156), p. 99 — establishes `Aσ²_y(τ) = … + (2π²/3)τh−2`, against which the instantaneous-difference variance is 3×. Riley (2008), NIST SP 1065, p. 15 — the Allan variance is defined on **adjacent τ-averages**, not instantaneous samples.
- **Critical analysis**: I re-derived the factor 3. For frequency random walk, `Var(y(t+τ) − y(t)) = q2·τ = 2π²h−2τ`, while `Aσ²_y(τ) = (2π²/3)h−2τ` — a ratio of exactly 3 in variance, √3 = 1.732 in sigma. Using the Allan value here (the natural mistake) would have left R optimistic by 3× on exactly the crystals the ground segment uses; the code's own A/B measurements against the generator (OCXO2 1.81/1.75, TCXO 1.83/1.78, QUARTZ 1.72/1.81) bracket √3 as predicted. The second correction is subtler and equally right: the `h0/(2τ)` white-FM term **does not belong in a frequency difference at all**, because `ClockModel.step` applies `h0` as a phase jump (`:314`) and never to the frequency state — including it over-charged the atomic classes ~37×. This is a genuinely careful piece of reasoning that ties the R term to the *specific generator*, not to a textbook formula.
  The `16·ln2·h−1` flicker coefficient is honestly labelled **calibrated, not derived** (`:806–809`) — flicker FM has no stationary variance, so `Var(Δy)` has no closed form — and T6 of `tests/test_tower_clock_product_age_wander_in_R.m:216–246` holds it to the generator within [0.5, 2.0] at two ages for all eight classes. The `h2`/`h1` refusal (`:837–857`) is the right stance: `precomputeNoise` **does** fold `h2`/`h1` into the truth frequency series, so a silent omission would make R knowingly optimistic; the code errors unless `cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning'`.

---

### Carrier bias-wander sizing and the removed subtraction — NEW

- **Code**: `+models/+clocks/TowerClockCorrectionProvider.m:368–402` (`carrierBiasWanderVar`, delegates to `extrapolationWanderVar_` at the **row's own age**); `+models/+measurements/CarrierMeasurementBuilder.m:199–289`, where `sbias_carrier = sqrt(sigBiasProd² + wanderVar(age))` (`:268`) and the drift sigma is **rebuilt from the product config alone** at `:270–273`, `:289`.
- **Status vs doc**: NEW.
- **Verdict**: correct — this is the site where a real double count existed and was removed, and the removal is correct in both directions.
- **Sources**: internal; standard rank-1 correlated-error propagation.
- **Critical analysis**: The pre-2026-08-10 code derived the carrier bias sigma by **subtracting** the drift contribution: `sbias = sqrt(towerClkSigma² − (age·dsig)²)`. That worked only while the drift term was the product's own `sigmaDrift_mps` (0.0002 → `age·σ = 0.0068 m`), negligible against a 0.1 m bias sigma. Once the tower oscillators were switched on, **both sides carried the same oscillator wander** and the two expressions are algebraically identical — `(c·σ_y(τ)·τ)²` versus `τ²·(c·σ_y(τ))²` — so the subtraction cancelled the entire wander out of the carrier bias term (measured: `2.4161² − 2.4161² → 0.0100 m`, the bare product bias). Worse, once the drift sigma was sized *correctly* (√3 larger), the subtraction went **negative**, clamped to zero and destabilised R assembly. This is an unusually clean example of two defects locked together such that fixing either alone makes things worse; the file records it at `:206–229` and it is worth citing as a methodological lesson.
  The resolution charges each contribution exactly once: bias block ← `product σ_b² + oscillator wander(age)`; drift block ← **the product's own drift uncertainty only** (`:273` overwrites `dsig_carrier` with `cfg.clocks.tower.product.sigmaDrift_mps`). I verified by reading the callee (`addCarrierDriftBlock` uses `cpInfo.sigmaDrift_mps`, set at `:516` from `dsig_carrier`) that the wander-inflated value from `computeDrift` genuinely does **not** reach the carrier drift block. **No double count.**
  One internal inconsistency: the header comment at `:373–375` says "Max age bounds that sawtooth", while `:380` and the code use "THE ROW'S OWN INSTANTANEOUS AGE". The code is right (the identity with the code path requires it) and the max-age sentence is a stale fragment of the superseded version; it reads as a direct contradiction three lines apart.

---

### `computeDrift` truth anchoring across all modes — NEW

- **Code**: `+models/+clocks/TowerClockCorrectionProvider.m:404–614`. `bdot_truth` is now the drift **at `t_s`** in every mode (`:473`, `:501`, `:525`, `:548`, `:586`); `drift_sigma` carries `frequencyWanderVar_` in the product modes (`:509–511`, `:530–531`, `:563–565`); `perfectCorrection` sets truth = model, σ = 0 (`:473–477`).
- **Status vs doc**: NEW.
- **Verdict**: correct — the physical argument is right and the defect it fixes was structurally invisible.
- **Sources**: internal physics — a range-rate observable at `t_s` depends on the transmitter's fractional frequency **at `t_s`**; the product epoch is a property of the *correction*, not of the measurement.
- **Critical analysis**: Anchoring both truth and model at `t_prod` made the tower clock cancel **identically** out of the Doppler residual. No gate could see it while the tower clocks were deterministic, because both quantities were then exactly zero — a perfect illustration of why "all tests pass" is not evidence when the fixture zeroes the quantity under test. The `perfectCorrection` regression is instructive: its bias path was already an oracle (model = truth at `t_s`), but its *drift* path anchored the model at the product epoch, so the oscillator's whole frequency excursion survived in the residual with R = 0 — measured aggregate ratio `f_dop = 0.362…0.370` against a predicted 1/3 for a 5-tower single-signal stack, reproduced across a 500× span in `h−2` (`:466–471`). `tests/test_tower_clock_all_modes_charge_wander.m:86–104` (T4) now covers **all six** modes including `perfectCorrection`, with an explicit anti-vacuity assertion that the fixture's drift at `t_s` is nonzero.

---

### `towerClockMode = 'none'` silence guard (`isSilentClock_`) — NEW

- **Code**: `+models/+clocks/TowerClockCorrectionProvider.m:112–131` (the refusal) and `:639–684` (the predicate: nonzero h with `deterministic=false`, OR `driftRate_fracPerSec ≠ 0`, OR `relativisticFracFreq ≠ 0`). Escape hatch `cfg.towerClock.allowUncorrectedStochasticClock` (`masterConfig.m:3300`).
- **Status vs doc**: NEW.
- **Verdict**: correct — and it is one of the few gates in the codebase that tests the *property* rather than a proxy flag.
- **Sources**: internal. The underlying statement — a random walk has no stationary variance, so no finite R covers an uncorrected one — is standard.
- **Critical analysis**: The predicate deliberately does **not** test `clk.deterministic` alone, and the reasoning is exactly right in both directions. `clockType='ZERO'` with `deterministic=false` is provably silent (all h are zero) and would have been refused by a flag test, by an error message that recommends `ZERO` as the remedy; conversely `driftRate_fracPerSec` is a deterministic ramp that the flag does **not** suppress and that a finite R covers no better than a random walk. `tests/test_tower_clock_all_modes_charge_wander.m:133–166` (T6) enumerates five `(clockType, deterministic, drift)` triples with expected accept/refuse and a plain-English reason per row, and `:175–178` additionally asserts the escape hatch is **declared in masterConfig** so that `deepMergeConfig` will accept it from a scenario JSON — closing the "the error message recommends a knob the config system rejects" failure mode. `isSilentClock_` prints the h-coefficients, not just a verdict, because `ClockModel` treats `clockType` as a **label only** (the catalogue lookup lives in `ConfigFactory`), so a clock reporting `'ZERO'` while carrying caesium coefficients is legible here rather than looking like a guard malfunction.

---

### Product-clock covariance blocks (`ProductClockCovarianceBuilder`)

- **Code**: `+models/+clocks/ProductClockCovarianceBuilder.m:22–70` (Doppler, `R(g,g) += sd²·ones`), `:72–125` (carrier drift, `R(g,g) += (age·age')·sd²`), `:127–190` (**carrier bias, NEW**, `R(g,g) += sb²·ones`), `:192–461` (cross-observable stack), `:497–513` (`productCfg_` now delegating to one resolver).
- **Status vs doc**: DRIFTED and EXTENDED. The old F17 ("code-carrier cross omits `carAge·covBiasDrift`") is **SUPERSEDED**: that formula is gone entirely, replaced by the rank-1 identity below.
- **Verdict**: correct — structurally right rank-1 correlated-error models, with an SPD guard that is now argued as a postcondition rather than a hope.
- **Sources**: standard multivariate error propagation; no external source required.
- **Critical analysis**: The premise the old carrier policy rested on — "a constant product bias is absorbed by the float ambiguity per arc" — is **refuted by the generator** and the refutation is now in the code (`:130–140`): `productNoise_` keys its draw on `(tower, productEpoch)` with `productEpoch = floor(t/updateInterval)`, so the bias is a **fresh independent draw every interval — a step, not an arc constant**, and with `ambiguity.processNoiseSigma_m_per_sqrt_s = 1e-5` the float ambiguity can move ~0.055 mm across a 30 s interval against a 10–100 mm step. That is a well-made argument and it is checked against the actual noise generator rather than against intuition. The `productCfg_` delegation (`:497–513`) closes a real three-way divergence: this class carried its own 0.10 m / 1e-3 m/s fallbacks, `productConfig_` had 0.05 m / 0.001 m/s, and `masterConfig` ships 0.01 m / 0.0002 m/s — three homes for one physical quantity, reachable whenever a cfg omitted `cfg.clocks.tower.product`.

---

### The rank-1 code ↔ carrier tower-clock cross term — NEW

- **Code**: `+models/+clocks/ProductClockCovarianceBuilder.m:338–424` — `cov_ij = sCode(i)·sCar(j)` for same `(tower, productEpoch)`, gated by six explicit presence/length/application checks with a distinct `suppressedReason` per branch and a once-per-run warning (`:425–440`). Sigmas published by the builders that installed them: `CodeMeasurementBuilder.m:1080`, `CarrierMeasurementBuilder.m:665–690`.
- **Status vs doc**: NEW.
- **Verdict**: correct — and I verified the claimed identity arithmetically rather than accepting it.
- **Sources**: internal; `Cov = ρ·σ_i·σ_j` with `ρ = +1` for a shared scalar error entering both rows at sensitivity −1.
- **Critical analysis**: A code row and a carrier row of the same tower at the same epoch contain the **identical** term `−(b_twr,true − b_twr,model)` with sensitivity −1 on both, so `ρ = +1` and `Cov = s_code·s_car` exactly. I checked the two sigmas really are equal: code installs `σ_b² + age²σ_d² + 2·age·covBD + wander(age)`; carrier installs `[σ_b² + wander(age)] + [age·σ_d]²`. **Equal at the default `covBD = 0`.** The measured shortfall of the formula this replaced was **1.15×10³× at age 5 s and 5.06×10³× at age 34 s** — R was declaring three independent multi-metre nuisances where the physics has one, so the filter could not form the between-observable difference that cancels a common clock and averaged it down by √N instead.
  The PSD reasoning is also correct and load-bearing: per group `R = D + s·s'`, which is PSD for any `s` — **but only if all four blocks of the outer product are present**. With the code off-diagonal absent the added matrix is `s·s'` minus that block, which is indefinite for ≥2 code rows per tower. That is why the gates at `:393–404` are mandatory rather than defensive, and why the carrier and code gates must agree. The D12 fix at `:366–373` (test field **presence**, not just length, because `fieldOr_` returns a correctly-sized zeros vector for a missing field) is the kind of defect that would otherwise silently return the term to zero past four guards written specifically to catch it.

---

### The code ↔ Doppler cross term and the √3/2 correlation — NEW

- **Code**: `+models/+clocks/ProductClockCovarianceBuilder.m:288–328` — `cov_ij = pc.covBiasDrift + (√3/2)·sCodeXD_(i)·dopSigma(j)`. **Default OFF** (`cfg.covariance.productClock.crossCodeDoppler = false`, `masterConfig.m:546`).
- **Status vs doc**: NEW.
- **Verdict**: correct as a PSD-safe repair of an indefinite formula; **incomplete** as physics, and honestly labelled so.
- **Sources**: internal derivation from the RWFM model this repo already uses.
- **Critical analysis**: I re-derived the constant. For frequency random walk with `s² = 2π²h−2`: `Var(W) = c²s²a³/3`, `Var(Ẇ) = c²s²a`, and `Cov(W,Ẇ) = c²s²a²/2` — i.e. **half** of `a·Var(Ẇ)`, which is what the old formula used. That old form implies `ρ = a²/√((a³/3)·a) = √3 = 1.732 > 1`, giving `det Σ = c⁴s⁴(a⁴/3 − a⁴) < 0` — an **indefinite 2×2 for every code/Doppler pair sharing a tower**. The replacement `ρ·s_bias·s_rate` with `ρ = √3/2 = 0.866` keeps `det Σ = (1−ρ²)s_bias²s_rate² > 0` for any positive sigmas, PSD by construction rather than by the RWFM special case. The scope note at `:302–315` is honest: `s_bias`/`s_rate` are the **total** installed sigmas, not the RWFM-only components the √3/2 is derived from, and isolating them would need the tower's h-coefficients plumbed into an `errStruct`-only function.
  **Being off by default is not conservative.** Omitting a *positive* off-diagonal makes R more independent than the truth, which lets the filter average a common tower-clock error down by √N when it cannot. The correct label for the default is "a small, dormant optimism", not "a safe default"; it belongs in the limits list.

---

### `addToR`, `includeOscillatorWander` and `maskStateTowerSigma_` — the three R gates

- **Code**: `addToR` master at `TowerClockCorrectionProvider.m:233–235` and `:604–606` (zeros the returned **sigma** only, never the correction value or the age) and ANDed into the carrier at `CarrierMeasurementBuilder.m:626–631`; `includeOscillatorWander` inside both wander functions (`:773–777`, `:819–821`); `maskStateTowerSigma_` at `CodeMeasurementBuilder.m:1180+`, applied at `:355–356`, `:1078–1079`, `DopplerMeasurementBuilder.m:205–206`, `CarrierMeasurementBuilder.m:292–293`.
- **Status vs doc**: NEW (`addToR` had **no reader at all** before 2026-08; `includeOscillatorWander` is new with the wander terms).
- **Verdict**: correct, with one design point worth stating.
- **Sources**: internal; the masking rule is the standard Kalman statement that a quantity carried by a state must not also be charged in R.
- **Critical analysis**: `addToR` is the model of how an R switch should be written: it zeros only the **sigma**, because zeroing the correction value or the product epoch would *inflate* R by letting the age grow from the true 5–34 s to the whole elapsed arc — exactly the pathology the `productClock.enable` gate once had. The two ladder rungs whose purpose is an empty R (`config/ladder/test/test001_idealFlat.json`, `test002`) were silently not getting one until this was wired. `includeOscillatorWander` is deliberately **orthogonal** to `clk.deterministic`: the flag controls whether a genuinely stochastic clock's wander is *charged*, and must never be inferred from or substituted for the truth-side suppression flag — the exact conflation `isSilentClock_` exists to prevent elsewhere.
  `maskStateTowerSigma_` is column-disciplined and `tests/test_wpI_tower_clock_R_double_count.m:33–37` (T2) pins the under-count trap in the other direction: with a bias-only state model the **drift** sigma must survive. The carrier path deliberately does **not** mask column 2 (`CarrierMeasurementBuilder.m:274–288`), and the justification checks out: masking assumes `h`/`H` carry a matching drift term, and the carrier path has no `h_phi -= x(towerClockIdx(ti,2))·age` branch and never sets a column-2 entry in `H_phi`. Masking there was a straight under-charge.

---

### Gauss-Markov clock modelling — still absent

- **Code**: none. `+models/+clocks/` implements only the random-walk (integrated Wiener) two-state model.
- **Status vs doc**: STILL-VALID.
- **Verdict**: acceptable omission for this use case; worth one sentence of justification in the thesis.
- **Sources**:
  - Carpenter & Lee (2008), AAS 08-109 — "Current clock error models based on the random walk idealization may not be suitable in these circumstances, since the covariance of the clock errors may become large enough to overflow flight computer arithmetic." (p. 1).
  - Carpenter & Lee (2008) — "The random walk model developed in Brown and Hwang makes use of the frequency noise terms only, i.e. ho, hWl, and h-2." (p. 1; OCR of h₀, h₋₁, h₋₂).
- **Critical analysis**: The second quote is **new to this section and directly supportive**: the three-coefficient set the code's Q now uses (h₀, h₋₁ via the Allan equivalence, h₋₂) is exactly the set Carpenter & Lee attribute to Brown & Hwang's random-walk model. The Carpenter-Lee FOGM/SOGM alternative exists to bound covariance through multi-hour outages; this simulation runs seconds-to-minutes cadence with continuous tower visibility at GEO, so the RW model's unbounded growth is never stressed. State the outage caveat if the thesis discusses long GNSS-denied arcs.

---

### The EKF's live handle to the truth clock object — NEW

- **Code**: `+revgnss/ScenarioFactory.m:49` — `ekf = filter.ReverseGNSSEKF(cfg, nT, asset.clock);` stored at `+filter/ReverseGNSSEKF.m:377` in a `models.clocks.ClockModel` property (`:138`), read at `:1497–1498`. Tower analogue: `ReverseGNSSSimulation.m:493` passes `cellfun(@(t) t.clock, obj.towers)` into `predict`, read at `ReverseGNSSEKF.m:1513`.
- **Status vs doc**: NEW.
- **Verdict**: partially correct — currently only the **h-coefficients** are read, which is a design parameter and not a truth value; but the architecture puts `getBiasMeters()` one method call from the filter.
- **Sources**: standing project constraint (a), "no truth in the estimator".
- **Critical analysis**: `ClockModel` is a **handle** class, so the EKF holds a live reference to the truth oscillator, including its instantaneous `bias_s` and `fracFreq`. I grepped every production reference to `rxClockModel` and `towerClockModels`: they appear only in `buildQ_`, and only `getProcessNoiseQ` is called. So the constraint is **not violated today**. Two things follow. (1) It should be narrowed — passing a stripped `struct` of h-coefficients would make the constraint structural rather than conventional, and would cost nothing. (2) It means the filter's Q is *by construction* matched to the truth process, so **no oscillator-specification error is ever simulated**. Any consistency claim (NIS in band, ±3σ coverage) inherits that idealisation and must say so.

---

### Ancillary sources reviewed, and one that is missing

- *AN-756* (Brannon, Analog Devices): sampled-system clock jitter — background only; no simulation formula derives from it. STILL-VALID.
- *Rubiola (2011), Leeson-effect tutorial* (`2011T-IFCS-Leeson-effect.pdf`): power-law table, used only as a third independent statement of the ADEV coefficients. STILL-VALID.
- *Robins (1984), Phase Noise in Signal Sources* (`Fundamental Books/01_phase-noise-in-signal-sources_compress.pdf`, and a duplicate): AVAR definition. STILL-VALID.
- *2220.pdf.pdf* is a duplicate of NIST SP 1065 with a **much cleaner text layer** — use it for quoting; `nistspecialpublication1065.pdf` OCRs "2 ln 2" as "21n2" and "4π²/6" as "47tV6".
- **Van Dierendonck, McGraw & Brown (1984) is NOT in `Paper/`.** The old document quoted it seven times with page numbers (273, 278, 280, 284, 285) as "transcribed from the page scan"; there is no such scan in the collection. Every one of those quotes must be marked EXTERNAL, and the eq. (60) transcription in particular reproduces a form that **Brown & Hwang p. 430 explicitly identifies as containing mistakes**. Where the old document needed VD1984, Brown & Hwang §11.3 (in-repo, legible) now serves better and is primary for this code.

---

## Double-count candidates

Severity: **H** affects headline numbers · **M** affects specific configurations · **L** latent/cosmetic.

| # | Name | Location A | Location B | Mechanism | Size | Severity |
|---|---|---|---|---|---|---|
| DC1 | **Carrier tower-clock wander charged in both the bias and the drift block** — *fixed, verify it stays fixed* | `CarrierMeasurementBuilder.m:268` (`sbias = √(σ_b² + wander(age))`) | `ProductClockCovarianceBuilder.m:108` via `cpInfo.sigmaDrift_mps` | `computeDrift` returns a drift sigma **inflated by `frequencyWanderVar_`**. If that value reached the carrier drift block, the same oscillator wander would be charged as `wander(age)` in the bias block *and* `age²·c²Var(Δy)` in the drift block. The guard is one line: `CarrierMeasurementBuilder.m:273` overwrites `dsig_carrier` with `cfg.clocks.tower.product.sigmaDrift_mps` alone. | Would be ~3× the wander variance: at OCXO2/age 34 s, `2.416²` charged twice → R inflated from 5.84 m² to ~23 m² on carrier rows | **H (latent)** — one line stands between the current state and a 4× carrier-R error |
| DC2 | **Product bias `σ_b` counted on the code diagonal and again in the shared block** — *correctly avoided* | `CodeMeasurementBuilder.m:594` (`R_diag += towerClkSigma²`) | `CodeMeasurementBuilder.m:1088` | The shared-tower block adds `sig²·(ones − eye)` — **off-diagonal only**, with the diagonal explicitly excluded and commented. Verified by reading both sites. | 0 | none (verified clean) |
| DC3 | **Doppler product drift counted on the diagonal and again in the block** — *correctly avoided* | `DopplerMeasurementBuilder.m:270` (`Rd = diag(Rd_diag)`, tracking only) | `ProductClockCovarianceBuilder.m:56` (`sd²·ones`, includes diagonal) | `addDopplerDriftBlock` owns the **full** drift contribution; the builder explicitly does not pre-add it (`DopplerMeasurementBuilder.m:277–278`, "Do NOT pre-add drift sigma to Rd_diag — that would double-count"). The `elseif` fallbacks at `:291`/`:301` add `diag(σ²)` only when the block was **not** applied. | 0 | none (verified clean) |
| DC4 | **Relativistic offset counted in both `localClockRate` and `properTimeRate`** — *correctly avoided on the rate* | `ClockModel.m:388` (total rate) | `ReciprocalEndpointTruthProvider.m:43` (oscillator-only rate) + `:44` (`properTimeRate`) | Coordinate-time channels use `getDriftMetersPerSecond`; proper-time endpoints use `getOscillatorDriftMetersPerSecond` because the endpoint supplies `properTimeRate` separately. Getting this wrong costs `c·y_rel` on every endpoint rate. | avoided; would be **0.1615 m/s** | none (verified clean) — but see L2/L3 for what `properTimeRate` actually carries |
| DC5 | **`covBiasDrift` charged as both product covariance and oscillator correlation** — latent | `ProductClockCovarianceBuilder.m:320` (`pc.covBiasDrift + ρ·s_b·s_d`) | `TowerClockCorrectionProvider.m:167` (`2·age·covBD` inside the bias variance) | These are legitimately different objects (the product's own bias/drift estimate covariance vs. the oscillator's post-epoch wander correlation) and the code says so at `:311–315`. But `covBD` also enters the **code** sigma while the **carrier** sigma omits it, so at `covBD ≠ 0` the rank-1 identity `s_code = s_car` breaks and R over-trusts the code-minus-carrier direction. | 0 at the shipped `covBiasDrift = 0`; grows as `2·age·covBD` (34 s × covBD) | **M (latent)** — add an assertion or include the term on the carrier side |
| DC6 | **Tower-clock error charged as two independent nuisances across code and Doppler** — *inverse* of a double count, same class of defect | `CodeMeasurementBuilder.m:594` | `DopplerMeasurementBuilder.m:280` | `crossCodeDoppler` is **false by default** (`masterConfig.m:546`), so R contains no code↔Doppler tower-clock correlation. Missing a *positive* off-diagonal is not conservative: it lets the filter average one physical clock error down by √N. | For 5 towers × 4 antennas the code block already correlates; the missing term is `0.866·s_bias·s_rate` per pair | **M** — dormant, zero test references, but mislabelled if called "safe" |
| DC7 | **Flicker charged in the truth twice (FFT series and Q)** — *correctly avoided* | `ClockModel.m:227` (`Sy_frac` includes `hMinus1/f`) | `ClockModel.m:295–296` (`step` uses only `h0`, `hMinus2`) | The truth's flicker comes **only** from the FFT path; `step`'s Cholesky uses `q1`/`q2` and never `q2_eff`. The Allan equivalence lives exclusively in `getProcessNoiseQ`. Verified by reading both. | 0 | none (verified clean) |

---

## Logical flaws

| # | Name | Where | Mechanism | Severity |
|---|---|---|---|---|
| L1 | **`getProcessNoiseQ`'s own docstring describes a Q the function no longer computes** | `ClockModel.m:52–59` and `:464–483` | Three separate blocks state `Q_11 = (h0/2 + 2ln2·hm1)·dt`, `Q_22 = 2π²hm2·dt`, `q_f = 2ln2·hm1`, and "Gated by `driftFlickerInQ` (default false)". The implementation 30 lines below uses `q2_eff = q2 + 6ln2·h−1/dt` in **all four** entries and `driftFlickerInQ` has been **removed** (it now raises `ClockModel:driftFlickerInQRemoved`). A reader who trusts the docstring gets both the magnitude and the default backwards. | **M** (documentation contradicts code inside the same function) |
| L2 | **`fixedStation` hardcodes `properTimeRate = 1`, so the identity the design rests on does not hold as instantiated** | `ReciprocalEndpointTruthProvider.m:85` vs `ClockModel.m:411–416` | The docstring's justification for excluding `y_rel` from `localClockRate` is that `properTimeRate(sat) − properTimeRate(ground) = y_rel`. That identity is exact (I verified `−1.5778e−10 − (−6.9648e−10) = +5.3870e−10`), but the ground endpoint uses `1`, not `1 − 6.9648e−10`. The *implemented* difference is `−1.578e−10`, wrong in magnitude **and sign**. | **L** — `properTimeRate` is consumed only by `coordinateDurationForProperDuration`, so the error is `6.965e−10 × 1 ms = 0.209 mm`, and `masterConfig.m:2846` notes the turnaround error is inert for the clock-difference observable anyway |
| L3 | **`localTimeAt` never applies `properTimeRate`, so the satellite's clock ticks at the wrong rate across the light-time interval** | `TwoWayCodeEndpointModel.m:105–107` vs `:115–116` | `localTimeAt = clockLocalTimeAtReference + localClockRate·(t − t_ref)`. `clockLocalTimeAtReference` carries the **full** accumulated `y_rel·t_s` (via `getBiasMeters`), but `localClockRate` deliberately excludes `y_rel`, and `properTimeRate` is applied **only** to hardware turnaround durations. So within an epoch the satellite endpoint under-ticks by `y_rel·Δ`. | **M (latent)** — `5.388e−10 × 0.12 s ≈ 1.9 cm` on a one-way timestamp, up to ~3.9 cm over a round trip; partly cancels in the four-timestamp reductions. Latent because `measurements.twoWayTimeTransfer.mode` defaults to `firstOrderReciprocal` (`masterConfig.m:803`) |
| L4 | **`compute()` and `computeDrift()` return different product epochs for the explicit-product modes** | `TowerClockCorrectionProvider.m:87` / `:454` (grid `floor((t−lat)/dT)·dT`) vs `:566–568` (`t_prod_out = prod.epoch_s`) | The code path publishes `errStruct.towerClockProductEpoch_s` from `compute()` (grid), while the carrier path takes `cpInfo.productEpoch_s` from `computeDrift()` (struct epoch). For `product`/`productNoisy` with `epoch_s` off the grid, (i) the code↔carrier cross term's `abs(codeEpoch − carEpoch) < 1e-6` test **never matches**, so a several-m² term is dropped with reason `noTowerEpochOverlap`, and (ii) the two sides' wander ages differ, so `s_code ≠ s_car` and the rank-1 identity breaks. `tests/test_tower_clock_all_modes_charge_wander.m:209` sets `epoch_s = 30.0`, which happens to land exactly on the grid — the test cannot see this. | **M (latent)** — explicit-product modes are not the default |
| L5 | **The bias-wander charge silently accepts `h2`/`h1` that its frequency twin refuses** | `TowerClockCorrectionProvider.m:778` vs `:837–857` | `frequencyWanderVar_` **errors** on nonzero `h2`/`h1` because `precomputeNoise` folds them into the truth frequency series and it has no rate-domain charge for them. `extrapolationWanderVar_` calls the full `theoreticalAllanDeviation`, whose WPM/FPM branches deliberately drop the `f_h` bandwidth factors (`ClockModel.m:601–603`) — so on a custom oscillator with `h2 ≠ 0` the bias channel charges a **knowingly wrong** magnitude while the frequency channel refuses to run at all. Asymmetric treatment of the same defect. | **L** — reachable only through `cfg.clock.customOscillators`; no shipped class sets `h2`/`h1` |
| L6 | **`precomputeNoise`'s monotonicity check does not check monotonicity** | `ClockModel.m:200–203` | `dt = mean(diff(tVec_s)); if dt <= 0; error('tVec_s must be strictly increasing'); end`. A mean is positive for many non-monotonic grids. The subsequent `fs = 1/dt` and the whole PSD scaling silently assume uniform sampling that is never verified. | **L** — every production caller passes `(0:dt:duration)` |
| L7 | **The coloured series is indexed by step count, not by time, and freezes silently past the grid** | `ClockModel.m:323–329` | `nextIdx = obj.sampleIndex + 1` advances by exactly one per `step()` **regardless of `dt_s`**, and `if nextIdx > numel(...)` the comment says "colored component keeps its last value" — i.e. a run longer than the precomputed grid turns flicker into a *constant frequency offset* with no warning. A `step(dt)` with `dt ≠` the precompute grid spacing desynchronises the coloured series from time with no diagnostic. | **M (latent)** — production always precomputes on the sim `tVec`, but nothing enforces it |
| L8 | **`cfg.physics.relativity.clock.enable` is a master with no consumer** | `masterConfig.m:97`, `:2533`; readers are only `.truth.enable`/`.model.enable` | It works only via `expandEnableToggles` at resolve time (`masterConfig.m:265–270`). Setting it on an **already-resolved** cfg does nothing — `tests/test_wpD_relativistic_clock.m:94` has to call `expandEnableToggles` by hand, and `config/ladder/feat/feat014_noRelativity.json:11` writes the pair out explicitly for exactly this reason. This is the same `_extends`-ownership trap that made six `feat/*` ablation rungs inert. | **M** — a hand-written ablation that flips only the master measures nothing |
| L9 | **`masterConfig` states the tower clocks are deterministic and is overruled 700 lines later** | `masterConfig.m:1924–1928` ("Tower clock: OCXO, deterministic for convergence test", `deterministic = true`) vs `ConfigFactory.m:715–721` | `cfg.clock.tower.deterministic = false` (`masterConfig.m:223`) is applied **unconditionally** to every tower in `finalizeConfig`. Reading `masterConfig` alone gives the wrong answer about whether the ground oscillators run — and that single flag is worth 2.4 m of code-R sigma. | **L** (comment only) but high consequence for a reader |
| L10 | **`carrierBiasWanderVar`'s header contradicts its own code three lines later** | `TowerClockCorrectionProvider.m:373–375` ("Max age bounds that sawtooth") vs `:380` ("THE ROW'S OWN INSTANTANEOUS AGE") and `:401` | Stale fragment of the superseded max-age sizing. The code is right — the row's own age is what makes `s_code = s_car` an identity — but the paragraph above says the opposite. | **L** |
| L11 | **T1/T3 of the wander test re-derive the expectation with the production formula** | `tests/test_tower_clock_product_age_wander_in_R.m:270–277` (`i_expected` calls `clkRef.theoreticalAllanDeviation`) | The wander leg is `c·adev·age` — the same call `extrapolationWanderVar_` makes. T1/T3 therefore verify the **composition** (`√(product² + wander²)`), the gating, and the age arithmetic, but not the wander magnitude. Independent verification lives in T5/T6, which measure against the generator with wide bands ([0.4, 2.5] and [0.5, 2.0]). Not a "test that cannot fail", but it is weaker than it reads. | **L** — disclosure, not a defect |
| L12 | **`makeClockConfig`'s docstring lists three oscillator names that now throw** | `ConfigFactory.m:425` | `'Rubidium'`, `'AtomicLike'`, `'Custom'` are no longer catalogue keys (only `RUBIDIUM` is an alias); `getClockTemplate_` now **errors** rather than substituting OCXO. | **L** |

---

## Limits of this domain

What the clock and oscillator layer **cannot** legitimately claim, stated quantitatively.

1. **No oscillator-specification error is ever simulated.** The EKF's Q is built from the *same* h-coefficients as the truth clock (`ScenarioFactory.m:49` → `ReverseGNSSEKF.m:1498`). Every NIS/NEES statement about the clock channel is a *perfectly-tuned-filter* result. A real receiver knows its oscillator's datasheet, not its realisation, and a factor-2 error in `h0` or `h−2` is routine. Nothing in the repo measures the sensitivity to that mismatch.

2. **Flicker is representable in Q only to within a factor 0.69–2.08.** Against Brown & Hwang's corrected footnote (p. 430) the Allan-equivalent RWFM gives `q11` 31 % light, `q12` 2.08× heavy, `q22` 1.04× — with the correct Δt powers. Brown & Hwang's own verdict, "it is impossible to model this term exactly with a finite-order state model" (p. 430), is the ceiling. Any claim of *exact* clock-covariance consistency is unsupportable for a flicker-dominated class (RUBIDIUM2, OCXO2, CESIUM2).

3. **Flicker below `f = fs/N` is not represented at all.** Single-segment circular FFT synthesis truncates the 1/f divergence at the run length, so the flicker floor is under-represented for `τ` approaching the arc. On a 3600 s / 1 Hz run that is `f < 2.8×10⁻⁴ Hz`. No ADEV point beyond `τ ≈ 900 s` (`AllanDeviation.compute` caps `m ≤ (N−1)/4`) should be quoted as evidence of the model's long-τ behaviour.

4. **Every clock realisation carries a strictly positive frequency offset from the DC bin.** Mean `0.627·√h−1`: 1.98×10⁻¹³ (CESIUM1), 3.14×10⁻¹² (OCXO2), 6.27×10⁻¹¹ (TCXO). It is absorbed by `bdot_rx` and by the product's drift term, and has zero Allan variance — but the synthesised process is **not zero-mean in frequency**, contrary to the model it claims to implement.

5. **The ground-clock contribution to code R is set by the broadcast-product cadence, not by oscillator quality, and it is large.** At the stale end of one product cycle (age 34 s from `floor((t−5)/30)·30`) the uncorrectable wander is 2.416 m for the default OCXO2 — **22.9×** the golden product sigma of 0.1056 m — and even the best catalogue class (RUBIDIUM2) leaves 0.121 m. No sub-decimetre ground-segment claim is supportable at a 30 s/5 s product cadence without either estimating the tower clocks or shortening the product interval.

6. **The default ground oscillator is a deliberate but consequential choice.** `'OCXO'` aliases to **OCXO2**, Winkel's short-term-optimised crystal (best at 1 s, worst at 4 h). OCXO1 would give 1.158 m at age 34 s instead of 2.416 m. Any error-budget table must name the catalogue row (`OCXO2`), not the class (`OCXO`).

7. **The periodic relativistic clock term is still absent.** `revgnss.Relativity` models the constant offset only and returns `periodicResidual_m = 0` "exactly 0 for a circular orbit". For a real GEO with `e = 1×10⁻⁴…1×10⁻³` the `−2√(GM a)·e·sinE/c²` term is 0.3–3 ns (9 cm–1 m), orbit-periodic, and aliases into the radial↔clock weak direction. This is unchanged from the old F13.

8. **Two-way / four-timestamp clock claims inherit an uncorrected `y_rel·Δ` term.** Because `TwoWayCodeEndpointModel.localTimeAt` applies neither `y_rel` nor `properTimeRate` across the propagation interval, each timestamp is short by up to `5.388×10⁻¹⁰ × 0.24 s ≈ 1.3×10⁻¹⁰ s (3.9 cm)`. Any sub-100-ps two-way accuracy claim must either disable the relativistic clock or fix this path.

9. **Tower-clock product errors do not re-randomise across Monte-Carlo seeds.** `productNoise_` is seeded on `(towerIdx, t_prod)` alone, outside `RngRegistry` (`TowerClockCorrectionProvider.m:872–882`). An ensemble over master seeds re-randomises the oscillators but **not** the broadcast-product errors — deliberate (they are genuinely shared across the fleet), but it means ensemble statistics under-sample this error source, and `IndependentFleetCoordinator`'s `towerClockProductReachableButRejected` guard exists precisely because the correlation network cannot yet treat it.

10. **`sharedErrorCorrelation` is inert.** `cfg.clocks.tower.product.sharedErrorCorrelation` is read into `pc` and consumed by nothing but a report row (`TowerClockCorrectionProvider.m:696–705`, `masterConfig.m:246–262`). The actual sharing is unconditional. It must not be cited as a control.

11. **The `truthHistoryProduct*` family reads the tower's truth history to build the correction.** `clockAtProductEpoch` reads `tower.history.clockBias_m` at `t_prod`. This is a *simulated* product, not a receiver-realisable one; its defensibility rests entirely on the injected `(σ_b, σ_d)` and the age-grown wander being an honest model of a real broadcast product's error, and those sigmas are **unsourced in the repo**. Independently of that, `perfectCorrection` (still selectable, and still the placeholder literal in `masterConfig.m:2036`) is a pure oracle: model = truth at `t_s`, σ = 0, in both the bias and the drift channel.

12. **Nothing in this domain constrains the ISL truth-leak.** With `isl.product.enable = false` (the default), `ISLMeasurementBuilder.m:227/253` reads the neighbour's **true** clock via `tx.clock.getBiasMeters()` / `getDriftMetersPerSecond()`. The relativistic term cancels correctly through that path, so the fix in `9a52cfc` is right — but it does not reduce, and must not be described as reducing, the known 3.585 mm → 130.9 mm honesty cost.

---

# Round-2 re-verification — TROPOSPHERE, IONOSPHERE, SCINTILLATION, GASEOUS ABSORPTION, IONO-FREE

**Scope.** `+models/+atmosphere/{TroposphereModel,MappingFunctions,NiellCoefficients,IonosphereModel,Klobuchar,GaseousAbsorption}.m`;
`+models/+errors/{EnvironmentModel,ErrorChain,HigherOrderIonosphere}.m`;
`+revgnss/{IonoFreeCombination,IonosphereFreeBiasBudget,IonosphereFreeCombinationDiagnostics}.m`;
`models/atmosphere/{troposphere,ionosphere}.m`; `analysis/p676_annex1.m`, `analysis/p676_annex2.m`,
`analysis/generate_gas_absorption_table.m`; the atmosphere call sites in
`+models/+measurements/{MeasurementModelUtils,CodeMeasurementBuilder,CarrierMeasurementBuilder}.m`;
config in `config/masterConfig.m`, `config/golden_baseline.json`, `+revgnss/ConfigFactory.m`.
HEAD = `170e37d`. Doc baseline = `3489075`, doc section starts at line 234.

**Method.** Every line citation re-read at HEAD. Every numeric claim re-computed in a live MATLAB
session against the **resolved** `golden_baseline.json` (not against `masterConfig` defaults — they
differ on almost every knob in this domain). Verbatim quotes re-extracted from the PDFs in `Paper/`
with page numbers re-checked; ITU-R P.676 quotes taken from the ITU's own P.676-10 release, whose
text layer is readable (P.676-13's is a scan), with the wording confirmed unchanged in the -13 tables
by the repo's own `analysis/verify_p676_tables.py`.

**Headline.** The *deterministic physics* remains the strongest part of this codebase: Saastamoinen/Davis,
the complete Niell tables, the thin-shell obliquity, the ±dispersion signs, the IF invariants and the
newly added ITU-R P.676-13 line-by-line integration all verify exactly, and the frozen absorption table
regenerates bit-for-bit from its committed generator (re-run this session, 0.50 s). Four of the doc's
older criticisms are now genuinely fixed. But three of the eight commits since the doc moved the
*stochastic* layer, and two of them changed it in ways that do not survive scrutiny:

1. **The iono R "derivation" of `6566cff` charges the state's own process noise a second time.**
   `q_iono = σ_ss²(1−φ²)` (`+filter/ReverseGNSSEKF.m:1616`) and R's iono base
   `σ_m · rScale = 1.0 · 0.057686948` (`+revgnss/ConfigFactory.m:2693`) are the *same number to nine
   digits*. The commit message calls this "the standard Kalman statement that a quantity carried by a
   state must not also be charged in R". The one-step Gauss-Markov increment is precisely what Q
   carries; it is not what the state fails to model.
2. **The troposphere has the identical, still-unfixed double count, and it is now the larger one.**
   Measured this session on the resolved golden: charged trop σ = 0.242 m against an actual
   (truth − model) residual of 0.0206 m RMS → **11.7× over-charged in σ, 138× in variance**, while the
   ionosphere went from 2.39× over to **11.6× under** (0.082 m charged, 0.959 m actual). The commit
   message's post-fix budget ("ionosphere 61%, … troposphere 1%") is stale: re-measured it is
   ionosphere 0.86%, troposphere 8.1%, multipath 32%, scintillation 54%.
3. **`3489075`'s humidity "sharing" fix has the wrong sign.** It scales P.676's wet column by
   `ZWD_tower/ZWD_ref = 0.075/0.095669 = 0.784` on the strength of `ZWD = 0.15·RH·exp(−h/2000)`, an
   uncited parameterisation. Computing the *same* atmosphere physically (RH = 0.50 at T = 293.15 K,
   P = 1013.25 hPa) gives e = 11.66 hPa, ρ_w = 8.62 g/m³ and ZWD ≈ 0.115 m — **wetter** than P.835's
   7.5 g/m³ / 0.0957 m, not 22 % drier. The correction is applied 1.47× in the wrong direction.

And one defect that predates the doc and was never caught: **the Conker scintillation σ and the C/N0
code σ are the same tracking noise, charged twice.** Measured, the implemented row noise is
**1.39×–2.17×** the Conker-consistent value.

---

## A. Troposphere

### Saastamoinen / Davis zenith hydrostatic delay (ZHD)

- **Code**: `+models/+errors/EnvironmentModel.m:892-893`
  `fLat = 1 - 0.00266*cos(2*lat_rad) - 0.00028*h_km;  ZHD_k = 0.0022768 * P_k / fLat;`
  Surface pressure `EnvironmentModel.m:868` `P_k = P0*(1 - 2.2557e-5*alt_m)^5.2559`; validity guard
  `EnvironmentModel.m:856-863` (`[-500, 11000] m`, warn + clamp).
- **Status vs doc**: DRIFTED — physics unchanged, line numbers moved (802-811 → 892-893; 787 → 868;
  775-781 → 856-863; the stale docstring the doc flagged at 741 is now at **807**).
- **Verdict**: correct — the full-precision Davis et al. (1985) form; recomputed
  `0.0022768·1013.25/(1−0.00266·cos 90°) = 2.3070 m`, matching the docs' 2.307 m.
- **Sources**:
  - Osah et al. (2021) — "9.784(1 − 0.00266cos2φ − 2.8×10⁻⁷ H)" (p. 122) — confirms 0.00266 and
    2.8e-7 per m ≡ 0.00028 per km. *Page re-verified this session (PDF page 8, printed 122).*
  - Osah et al. (2021) — refined Saastamoinen "0.002277 … 1255 … 0.05" (p. **119**, printed page
    header verified; the doc's "p. 117" is wrong).
  - Li et al. (2023) — "A typical accuracy at 2–6 mm level in the zenith direction has been
    demonstrated" (p. 1718).
  - Davis, Herring, Shapiro, Rogers & Elgered (1985) — canonical 0.0022768 ± 5e-7 m/hPa. [EXTERNAL]
- **Critical analysis**: Right, and better than its in-repo sources. Two carried-over blemishes, both
  still live at HEAD: (i) the function docstring at `EnvironmentModel.m:807` still advertises
  `ZHD = 2.3*P(h)/1013.25` and `P(h) = P0*exp(-h/hScale)`, neither of which the body computes — and
  `cfg.environment.weather.heightScale_m = 8400` (`masterConfig.m:2213`) is the parameter of that
  abandoned exponential, now an inert knob with no reader; (ii) the ISA exponent pair
  (2.2557e-5, 5.2559) is the standard barometric formula and correct, but the guard message calls it
  "Saastamoinen validity range", conflating the *pressure model's* troposphere-layer validity with
  Saastamoinen's.

### Zenith **wet** delay parameterisation `ZWD = 0.15·RH·exp(−h/2000)`

- **Code**: `+models/+errors/EnvironmentModel.m:894` `ZWD_k = 0.15 * RH_k * exp(-alt_m / 2000);`
  Exposed to the measurement path by `EnvironmentModel.m:684-704` `zenithWetDelay_m(towerIdx)`.
- **Status vs doc**: NEW as a standalone entry. The doc mentioned it in one clause of the ZHD entry
  ("an ad-hoc parameterisation … acceptable because the wet residual is carried stochastically").
  That mitigation **no longer holds**: since `3489075` this number is load-bearing for gaseous
  absorption, where it is used as an absolute humidity proxy, not as a delay the estimator absorbs.
- **Verdict**: unsourced — no citation exists anywhere in the repo for the constants 0.15 m or 2000 m,
  and the formula is dimensionally a delay while it is now consumed as a water-vapour column.
- **Sources**:
  - Osah et al. (2021), quoting Black (1978) — "0.28 m for summer in tropic or mid-latitude regions,
    0.20 m for spring or fall in mid-latitudes, 0.12 m for winter in maritime mid-latitudes, 0.06 m
    for winter in continental mid-latitudes" (p. 121). The shipped value 0.075 m is the *polar-winter*
    end of that range for a network that includes Libreville at 0.04° N.
  - Li et al. (2023) — the wet part "generally varies between 0 and 40 cm in the zenith direction"
    (p. 1809 of the extracted text; printed p. 1718).
  - Bevis, Businger, Chiswell, Herring, Anthes, Rocken & Ware (1994) — the `k2' + k3/Tm` mapping from
    integrated water vapour to ZWD, which `analysis/generate_gas_absorption_table.m:66-68` uses for
    the *reference* atmosphere but which `EnvironmentModel` does not use for the towers. [EXTERNAL]
- **Critical analysis**: Recomputed physically for the shipped defaults (RH = 0.50, T = 293.15 K):
  saturation vapour pressure at 20 °C is 23.3 hPa (Magnus), so e = 11.66 hPa, and Saastamoinen's wet
  term `0.002277·(1255/T + 0.05)·e` gives **0.115 m** — 53 % more than the 0.075 m the code assigns.
  Equivalently ρ_w = 216.7·e/T = **8.62 g/m³**, against P.835's 7.5 g/m³. So the model's own weather
  state is *wetter* than the reference table, while the code (and `test_per_tower_atmosphere.m:95-98`)
  asserts it is "22 % drier". Everything downstream of that assertion inherits the error.
  The root cause is structural, not a bad constant: **the formula has no temperature dependence at
  all.** `initWeatherFromTowers_` computes `T_k` with a lapse rate and clamps it to [220, 320] K
  (`EnvironmentModel.m:869-875`), stores it in `weatherState(k).temperature_K`
  (`EnvironmentModel.m:903`) — and then never reads it again. Grep at HEAD: the only consumer of
  `temperature_K` anywhere in the repo is `tests/test_orekit_composed_observable_crossvalidation.m:200`.
  Temperature is the dominant control on how much water vapour a column can hold, and it is computed
  and discarded, which is exactly why a linear-in-RH proxy inverts the comparison: P.835's 7.5 g/m³ at
  288.15 K corresponds to RH ≈ 58 %, while the repo's RH = 50 % at the 5 K warmer 293.15 K is
  8.62 g/m³ — *lower* relative humidity, *more* water. The fix is one line: derive ZWD from (T, RH, P)
  through Saastamoinen or Bevis instead of scaling 0.15 m by RH.

### Per-tower humidity and the absorption/troposphere "one atmosphere" claim

- **Code**: `config/masterConfig.m:2212` `perTowerRelativeHumidity = []` (default);
  size guard `EnvironmentModel.m:832-837`; accessor `EnvironmentModel.m:684-704`; threading
  `ErrorChain.m:506-509` and `CodeMeasurementBuilder.m:1289-1301`; consumption
  `MeasurementModelUtils.m:282-286` → `GaseousAbsorption.m:144`
  `A_dB = A_dry_dB*m_h + A_wet_dB*m_w*(zwd/zwdRef)`.
- **Status vs doc**: NEW (landed in `3489075`, after the doc's snapshot; the doc's entry said the
  per-tower scaling was "available in the class but not wired at the call sites").
- **Verdict**: partially correct — the *plumbing* is right and well guarded; the *physics* of the ratio
  is wrong because its numerator and denominator come from two incompatible models.
- **Sources**:
  - Recommendation ITU-R P.835 — mean annual global reference atmosphere, ρ(h) = 7.5·exp(−h/2) g/m³,
    the profile `generate_gas_absorption_table.m:59-60` integrates. [EXTERNAL]
  - Bevis et al. (1994) `k2' = 22.1 K/hPa`; Bevis et al. (1992) `k3 = 3.776×10⁵ K²/hPa`. [EXTERNAL]
- **Critical analysis**: `ZWD_REF_M = 0.095669` re-derived by hand and reproduced exactly:
  IWV = 7.5/1000·2000 = 15 kg/m², Tm = 70.2 + 0.72·288.15 = 277.668 K,
  `1e-6·(0.221 + 3776/277.668)·461.5·15 = 0.0956696 m` ✓. Two problems.
  (i) **Mixed-vintage constants**: `k2'` is Bevis (1994) and `k3` is Bevis (1992); the matching 1994
  pair (`k3 = 3.739×10⁵`) gives 0.09475 m, a 0.97 % shift in the denominator of every wet scaling.
  Small, but it means the "reference" is not a single citable atmosphere.
  (ii) **The numerator is not the same physical quantity as the denominator** (see the previous
  entry). Net: at 24.125 GHz the code scales A_wet from 0.317082 dB to 0.2486 dB; a consistent
  treatment would scale it *up* to ≈ 0.365 dB. The error factor on the wet column is ≈ 1.47, i.e.
  0.116 dB, i.e. 1.35 % on code σ at 24 GHz. Numerically minor; the problem is that the change was
  merged *as a correctness fix* with a confident comment ("so absorption and the troposphere describe
  ONE atmosphere rather than two") that the code does not deliver.
  Also: `cfg.atmosphere.gaseousAbsorption.mappingKind` defaults to `'simple'` (`masterConfig.m:2190`)
  while the realistic troposphere uses `mappingType = 'niell'` (`masterConfig.m:938-939`), so the
  claim in `GaseousAbsorption.m:105-107` that the two "can never disagree about the obliquity of the
  atmosphere they share" is false at the shipped default. (The `'simple'` cosecant is nonetheless the
  right choice on its own terms — it is exactly what P.676 § 2.2.1 prescribes above 5° elevation.)

### Niell (1996) mapping-function coefficient tables

- **Code**: `+models/+atmosphere/NiellCoefficients.m:25-52` (tables), `MappingFunctions.m:71-99`
  (`niellHydrostatic`, `niellWet`) and `MappingFunctions.m:152-163` (`marini_`).
- **Status vs doc**: DRIFTED — values unchanged, one provenance label wrong.
- **Verdict**: correct — every constant re-read digit by digit against the doc's transcription of
  Niell (1996) Tables 3 and 4; `a_ht = 2.53e-5`, `b_ht = 5.49e-3`, `c_ht = 1.14e-3` ✓.
- **Sources**:
  - Niell (1996), Tables 3 and 4 (p. 3235) — "Eight digits are given in order to be exactly
    equivalent to the FORTRAN implementation already in use" (p. 3235). [EXTERNAL]
  - Osah et al. (2021) — continued fraction "m(ε) = (1 + a/(1 + b/(1+c))) / (sinε + a/(sinε + b/(sinε
    + c)))" (p. **122**; the doc says 123, off by one page).
- **Critical analysis**: Re-computed live: `m_w(5°, 45°N) = 10.7509` vs `1/sin 5° = 11.4737`, matching
  the doc's 10.751/11.474. The one real defect is a **provenance mislabel**: the class header
  (`NiellCoefficients.m:5`) cites "Tables 1-2" and the property comments say "Niell 1996 Table 1" /
  "Table 2", while the hydrostatic/wet coefficient tables in that paper are **Tables 3 and 4**
  (Tables 1-2 are the site list and the data summary). A reader checking the citation looks at the
  wrong tables and concludes the numbers are fabricated. One-line fix, but it matters for a
  traceability claim.

### Niell seasonal term — the sign question

- **Code**: `NiellCoefficients.m:81-83` `a = a_avg - a_amp*cosArg;` with
  `cosArg = cos(2*pi*(doy - doy0)/365.25)` (line 79) and `doy0 += SOUTH_SHIFT (182.625)` for
  `lat_rad < 0` (lines 76-78).
- **Status vs doc**: STILL-VALID — code and line numbers unchanged; the doc's numerical argument
  re-verified independently this session.
- **Verdict**: correct — the minus convention is the physical one and matches every reference
  implementation, even though the printed equation in the journal shows a plus.
- **Sources**:
  - Niell (1996) — "a(λi,t) = aavg(λi) + aamp(λi) cos(2π(t−T0)/365.25)", T0 = DOY 28 (p. 3234) —
    **plus** as printed. [EXTERNAL]
  - Niell (1996) — "the inversion of the seasons has been accounted for simply by adding half a year
    to the phase for southern latitudes" (p. 3234) — matches SOUTH_SHIFT = 182.625. [EXTERNAL]
  - Osah et al. (2021), eq. [39] (p. 123) — also plus.
  - ESA Navipedia, *Mapping of Niell* — "ξ(φ,t) = ξ_avg(φ) − ξ_amp(φ) cos(2π(t−T₀)/365.25)" — minus.
    [EXTERNAL]
- **Critical analysis**: Recomputed at HEAD: `m_h(5°, 45°N)` = **10.1518** at DOY 28 (winter) and
  **10.1057** at DOY 210 (summer). Winter-max is the physically correct behaviour for a cold,
  compressed atmosphere, so the minus sign is right. The doc's residual criticism survives verbatim:
  `tests/test_niell_mapping_function.m` still evaluates only where the cosine is null, so **no test in
  the repo can detect a sign flip in this term**. Given the paper is written against a source that
  prints the opposite sign, the thesis must state the convention explicitly.

### ZWD Gauss-Markov truth process and the `perTowerZwd` EKF state

- **Code**: truth `EnvironmentModel.m:256-274` (`gaussMarkovStep` on `ENV_TROP_TRUTH`),
  parameters `masterConfig.m:942-943` (realistic profile: τ = 10800 s, σ_ss = 0.04 m);
  estimator `masterConfig.m:945` `troposphereMode = 'perTowerZwd'`; resolved golden values measured
  this session: **τ = 10800 s, σ_ss = 0.04 m, initial σ = 0.10 m**; filter Q
  `+filter/ReverseGNSSEKF.m:1596-1597` `q_zwd = sigma_ss^2*(1 - phi_zwd^2)`.
- **Status vs doc**: SUPERSEDED. The doc's headline criticism ("the EKF process τ = 1 h contradicts
  both the truth process (3 h) and the repo's own documentation") is **no longer true at any shipped
  scenario**: the resolved golden runs τ = 10800 s on *both* sides and σ_ss = 0.04 m on both sides.
  The 1 h / 0.05 m pair survives only as the bare `masterConfig.m:3222-3223` default, which no
  shipped JSON uses.
- **Verdict**: correct — truth and filter now share one process model, with an honest τ inside the
  3–24 h band the repo's own docs prescribe.
- **Sources**:
  - `docs/atmosphere_realism.md:205` — "ZWD correlation time (corrected) | hours to tens of hours
    (~3–24 h), **not** 0.5–2 h".
  - Li et al. (2023) — residuals of estimated ZWD "can reach up to several millimeters (~ 2–7 mm)"
    (printed p. 1719).
  - Tralli & Lichten (1990) — canonical random-walk / FOGM ZWD estimation. [EXTERNAL]
- **Critical analysis**: This is the cleanest thing in the domain now. The `sameAsTruth` oracle is
  still a hard error (`EnvironmentModel.m:250-254`) and the ionosphere has a symmetric defensive twin
  (`EnvironmentModel.m:286-293`) — both re-verified present at HEAD. Two remaining nits: (i) neither
  0.04 m nor 10800 s carries a citation to a measured ZWD structure function, only to a range; (ii)
  the ZWD **H-column** mapping is `cfg.effects.troposphere.mappingModel = 'simple'`
  (`masterConfig.m:3202`, read by `MeasurementModelUtils.zwdMappingKind`), i.e. `1/sin e`, while the
  delay it is estimating is injected through Niell `m_w`. Measured at the golden's four visible tower
  elevations the discrepancy is **0.40 % at 20.94°, 0.05 % at 46.9°, 0.00 % at 78.9 °** — negligible,
  but it is a partial-derivative that does not match its own observable, and `masterConfig.m:3201`
  still asserts "VMF3, GPT3, and Niell are NOT implemented", which is now false.

### Troposphere R base sigma — an unfixed double count (the ionosphere's twin)

- **Code**: `ErrorChain.m:593-596`
  `sigmaBase = zeros(N,1); … if isfield(tc,'sigma_m') && tropPresent; sigmaBase = tc.sigma_m * mappingFn(elv); end`
  then `ErrorChain.m:608-616` computes `sigmaWetR = sigSs*sqrt(1-exp(-2*dt/tau))` — but that value is
  only ever used at `ErrorChain.m:622-626`, inside `if residualOn`, and **never touches `sigmaBase`**.
  Final `ErrorChain.m:627` `sigma_m = sqrt(sigmaBase.^2 + sigmaStochR.^2)`.
- **Status vs doc**: NEW.
- **Verdict**: flawed — the guard the file documents as a "variance double-count fix" operates
  entirely on a quantity that is identically zero in every shipped configuration, exactly the failure
  mode commit `03da4fb` diagnosed for the ionosphere and then fixed only for the ionosphere.
- **Sources**: this is an internal-consistency finding; the governing statement is the code's own —
  `ErrorChain.m:600-607`, "Charging the full sigmaWet_ss into R as well would count that same variance
  twice (estimate it AND pay for it)."
- **Critical analysis**. Three facts, each measured at HEAD on the resolved golden:
  1. `residualOn = stochOn && tc.stochastic.modelResidual.enable`. The golden resolves
     `stochastic.enable = 1` but `modelResidual.enable = 0` (`masterConfig.m:944`), so
     `residualOn = false` → `sigmaStochR ≡ 0` → the ZWD-state reduction at line 616 changes nothing.
  2. `estimation.troposphereMode = 'perTowerZwd'` **is** active, i.e. the condition the guard exists
     for is satisfied, and `sigmaBase = 0.15 m · m(e)` goes into R at full amplitude.
  3. Under `localWeatherGM` the truth and model tropospheres are *the same climatology*:
     `EnvironmentModel.m:443` `delay = zhd*m_h + (zwdMean + wetRes)*m_w`, with `wetRes` the truth GM on
     the truth side and **identically 0** on the model side (`EnvironmentModel.m:270-272`, mode
     `'zero'`). So `truth − model = wetResidualTruth · m_w`, an error whose steady-state σ is 0.04 m
     at zenith, not 0.15 m.
     The 0.15 m is inherited from `masterConfig.m:141`, where it was justified for the **`simpleMapped`**
     configuration as "truth 2.45 − model 2.30·biasFraction = 0.15 m at zenith". That truth/model
     split does not exist under `localWeatherGM`. It is a stale carry-over.

  **Measured (3600 epochs, golden config, four visible tower elevations 20.94°/46.87°/52.30°/78.88°):**

  | quantity | troposphere | ionosphere |
  |---|---|---|
  | actual (truth − model) RMS | **0.0206 m** | 0.9588 m |
  | actual mean | +0.0095 m | **−0.6583 m** |
  | charged σ in R (mean) | **0.2419 m** | 0.0823 m |
  | charged / actual (σ) | **11.7× over** | **11.6× under** |
  | charged / actual (variance) | **138× over** | 0.0074× (135× under) |

  So `6566cff` did not remove the double count from the code channel; it moved which source carries it.
  Severity: **high** — 8.1 % of the (non-tower-clock) code R is a term whose committed model error is
  two centimetres, and the fix is the exact one-line analogue of `rScaleWhenStateActive`.

---

## B. Ionosphere

### First-order ionosphere: 40.308, signs, thin-shell obliquity

- **Code**: `EnvironmentModel.m:531` `K_L1 = 40.308e16 / f_L1_Hz^2;`; signs
  `IonosphereModel.m:81-99` (`applyCodeSign` **+**, `applyCarrierSign` **−**, both × `ionoScale`);
  thin shell `MappingFunctions.m:134-142`
  `arg = (Re.*cosE)./(Re + shellHeight_m); denom = sqrt(max(1 - arg.^2, 1e-6)); m = 1./denom;`
  default `hI = 350e3` (`MappingFunctions.m:121-123`), `Re = revgnss.Constants.EARTH_RADIUS_M`.
- **Status vs doc**: DRIFTED (525 → 531; 30-48 → 81-99; 131-139 → 134-142). Physics unchanged.
- **Verdict**: correct — recomputed live: `K_L1 = 0.162405 m/TECU`, `K_L2 = 0.267471 m/TECU`,
  `M_thinShell(5°) = 3.0406`, `M(15°) = 2.4881`, `M(30°) = 1.7514`, all matching the docs' table.
- **Sources**:
  - Kaplan & Hegarty (2006), eq. (7.21) — "F = [1 − (Re cos φpp/(Re + hI))²]^(−1/2)"; "The height of
    the maximum electron density, hI, in this model is 350 km" (p. 312).
  - Fritsche et al. (2005) — "q = 40.3 ∫ N dL" (eq. 3, p. **1**; the doc says p. 2 — the equation
    block is on the article's first page, L23311, verified this session).
  - Enge (1994) — "changes in the total electron content will introduce equal but opposite changes in
    the phase and [group delay]" (sec. 2.4).
- **Critical analysis**: Verified again. Two nits carried over and one new. Carried over: the
  `40.3` literal in `+revgnss/InterSatelliteRFLinkModel.m` still coexists with `40.308e16` here (0.02 %);
  `ErrorChain.m:658-660` still cites "Leick et al. 2015 eq. 9.11", which is not in `Paper/`. New: the
  `max(1 - arg.^2, 1e-6)` floor at `MappingFunctions.m:141` caps the mapping at 1000; it can only bite
  below the horizon (arg → 1 at e = 0), so it is dead in practice — but it silently converts a
  geometric impossibility into a finite number rather than refusing.

### `climatologyAnchorScale` — the L1-anchor conversion

- **Code**: `+models/+atmosphere/IonosphereModel.m:34-79`
  `scale = (revgnss.Constants.IONO_ANCHOR_L1_HZ / f_ref_Hz)^exponent;` (default exponent 2), applied at
  `EnvironmentModel.m:486, 503, 520, 549, 557, 585` and `ErrorChain.m:686`, and deliberately **not**
  applied to the diurnal branch (`EnvironmentModel.m:539-541`, whose `K_L1` already carries `1/f_ref²`).
- **Status vs doc**: NEW (landed after the doc snapshot; the doc predates the fix and its Klobuchar
  entry silently assumed the band-blind behaviour).
- **Verdict**: correct — the composition `(f_canon/f_ref)^n · (f_ref/f_sig)^n = (f_canon/f_sig)^n`
  is exact for every caller, and is exactly 1.0 in floating point at the canonical band so goldens
  cannot move.
- **Sources**: Kaplan & Hegarty (2006) — the 1/f² dispersion the exponent 2 implements (p. 312);
  Fritsche et al. (2005) — the f⁻³ / f⁻⁴ laws used for exponents 3 and 4 (eqs. 4-5, p. 1).
- **Critical analysis**: This retires the project note "Klobuchar MODEL side is band-blind — flat
  2.426 m at every band" for the *model* side too: `EnvironmentModel.m:585` now reads
  `delay = fSeen * vModel * anchorScale * mapping * freqScale`. `tests/test_iono_band_scaling.m` pins
  the right invariant — that the delay at a **fixed signal frequency** is independent of the reference
  band — which is the property that catches a double conversion of the diurnal branch, and it pins
  61.25 GHz to sub-5 mm. The one thing it does not pin is that the *reference* choice cannot leak
  through the **σ** path when `frequencyExponent ≠ 1`; the same composition is used for σ
  (`EnvironmentModel.m:643-644`), so it is correct, but no test sweeps the exponent.

### Klobuchar kernel

- **Code**: `+models/+atmosphere/Klobuchar.m:19-47` — `PEAK_LOCALTIME_S = 50400`,
  `NIGHT_DC_S = 5e-9`, `MIN_PERIOD_S = 72000`, `CUTOFF_X = 1.57`,
  `Iv_s = dc_s + amp_s*(1 - x^2/2 + x^4/24)` for `|x| < 1.57`, else `dc_s`.
  Wiring `EnvironmentModel.m:570-585`, local time `ltS = mod(tNow_s + lonR*(43200/pi), 86400)`.
- **Status vs doc**: SUPERSEDED on the doc's only real complaint. The status flag is fixed:
  `+revgnss/ConfigFactory.m:2283-2293` now stamps
  `'appliedModelSideBroadcastClimatology'` when `model.correction == 'klobuchar'` and the model side is
  on, `'notSelected'` otherwise. The stale comment at `MappingFunctions.m:116` is rewritten
  (`MappingFunctions.m:116-119` now says "Klobuchar itself IS implemented … Only the obliquity
  differs"), and `ErrorChain.m:645-653` likewise.
- **Verdict**: correct as an implementation of the reduced ICD kernel.
- **Sources**:
  - Kaplan & Hegarty (2006) — vertical delay "approximated by half a cosine function of the local
    time during daytime and by a constant level during nighttime"; "the Klobuchar model, which removes
    (on average) about 50% of the ionospheric delay at midlatitudes" (p. 313).
  - ESA Navipedia, *Klobuchar Ionospheric Model* — night value 5·10⁻⁹ s; `X_I = 2π(t−50,400)/P_I`;
    "if P_I < 72,000 then P_I = 72,000"; "if A_I < 0, then A_I = 0". [EXTERNAL, transcribing
    IS-GPS-200]
- **Critical analysis**: All digits match. **One stale claim remains at HEAD**: `config/masterConfig.m:3210`
  still reads "NOTE: This is NOT a Klobuchar model. Klobuchar is not implemented." — the last surviving
  copy of the sentence the other two sites fixed. The 4th-order truncated cosine's edge discontinuity
  (0.0207 at |x| = 1.57 against cos(1.57) = 0.0008) is the ICD's own behaviour, not a bug.

### Klobuchar **calibration** against the configured truth — systematic over-correction

- **Code**: truth `masterConfig.m:953-956` (`diurnal.enable`, `vtecDay_TECU = 30`, `vtecNight_TECU = 6`,
  `peakLocalTime_h = 14`) → `EnvironmentModel.m:759-773` `diurnalVTEC_`; model
  `masterConfig.m:2245-2247` (`amplitude_ns = 20`, `period_h = 24`, `dc_ns = 5`) → `Klobuchar.m:36`.
- **Status vs doc**: NEW.
- **Verdict**: flawed — the model is not a 50 %-removal climatology of this truth, it is a 154 %
  over-correction at every hour of the day.
- **Sources**: Kaplan & Hegarty (2006), p. 313 (quoted above) — the ~50 % removal the design intends.
- **Critical analysis**. Measured this session, vertical L1 delay at lon = 0, sampled every 600 s over
  24 h:

  | | min | max | mean |
  |---|---|---|---|
  | truth vertical | 0.974 m | 4.872 m | — |
  | Klobuchar model vertical | 1.499 m | 7.495 m | — |
  | **model − truth** | **+0.525 m** | **+2.623 m** | **+1.196 m** |

  The residual never changes sign. Arithmetic: truth peak = 30 TECU × 0.162405 = 4.872 m; model peak =
  (5 + 20) ns × c = 7.495 m; night: truth = 6 × 0.162405 = 0.974 m, model = 5 ns × c = 1.499 m.
  A self-consistent broadcast climatology for **this** truth would carry `AMP ≈ 11.25 ns` and
  `DC ≈ 5 ns` (removing ~69 % at the peak) or, for a literal 50 % removal, `AMP ≈ 5.6 ns`,
  `DC ≈ 2.5 ns`. As shipped, the realistic profile injects a sign-definite **+1.2 m vertical /
  +1.4 to +3.4 m slant** ionospheric model bias. That bias is the origin of the −0.658 m mean
  (truth − model) I measured in the table above, it is common-mode across towers to first order (so it
  is mostly absorbed by the receiver-clock state rather than by position), and it is *not* covered by
  R after `6566cff`. `docs/atmosphere_realism.md:95` claims a "single-frequency Klobuchar ~1–3 m
  (a slowly-varying bias)" residual, which is numerically in the right band — but as an
  over-correction, not the under-correction the reader will assume.

### `rScaleWhenStateActive` — the slant-iono R reduction of `03da4fb` + `6566cff`

- **Code**: derivation `+revgnss/ConfigFactory.m:2687-2694`
  `rScaleF_ = sqrt(max(1 - exp(-2*dtF_/max(tauF_, eps)), 0));` (with `tauF_ =
  cfg.estimation.slantIono.tau_s`, `dtF_ = cfg.simulation.dt_s`);
  application `ErrorChain.m:864-875`
  `if ionoStateActive … sigmaBase = sigmaBase * rScale_; end`, on
  `sigmaBase = ic.sigma_m * mapping` (`ErrorChain.m:786-788`);
  default `masterConfig.m:174` `cfg.errors.ionosphere.rScaleWhenStateActive = [];` (= derive).
  Filter Q for the same state: `+filter/ReverseGNSSEKF.m:1615-1616`
  `phi_iono = exp(-dt_s/tau_iono); q_iono = sigma_iono^2*(1 - phi_iono^2);`
- **Status vs doc**: NEW (the whole lever postdates the doc).
- **Verdict**: partially correct — the *direction* is right and the previous 1.0 was provably wrong,
  but the stated derivation is not a derivation, and the resulting number is itself a (much smaller)
  double count.
- **Sources**:
  - Bar-Shalom, Li & Kirubarajan (2001), *Estimation with Applications to Tracking and Navigation* —
    the innovation covariance `S = H P⁻ Hᵀ + R` with `P⁻ = F P⁺ Fᵀ + Q`: the process increment enters
    S through Q, so a term placed in both Q and R is counted twice. [EXTERNAL — standard result, no
    copy in `Paper/`]
  - Brown & Hwang, *Introduction to Random Signals and Applied Kalman Filtering* (`Paper/Error
    Calculation/KalmanFilter/Brown.pdf`, scanned, no text layer) — the same decomposition.
- **Critical analysis**. Resolved golden: `tau_s = 600`, `dt_s = 1`, `slantIono.sigma_ss_m = 1.0`,
  `errors.ionosphere.sigma_m = 1.0`. Then
  - filter process noise: `sqrt(q_iono) = 1.0·sqrt(1 − exp(−2/600)) = 0.057686948 m`
  - R's ionosphere base at zenith: `1.0 · rScale = 0.057686948 m`

  **The same nine digits.** The commit message says R "keeps only what the state does not model: the
  one-step Gauss-Markov increment". The one-step increment *is* what the state models — it is Q, and Q
  is already in `P⁻`. Under the filter's own assumptions the correct residual R contribution from a
  perfectly modelled GM state is **zero**; what R legitimately owns is the *mismatch* between the truth
  process (σ_ss = 0.3 m, τ = 600 s, `masterConfig.m:960-961`) and the filter's (σ_ss = 1.0 m,
  τ = 600 s) plus the deterministic Klobuchar bias — neither of which is what was computed. Two
  further observations:
  - The scale is derived from **`estimation.slantIono.tau_s`** but applied to
    **`errors.ionosphere.sigma_m`**. They are numerically both 1.0 at the golden, which is why the
    substitution passes unnoticed; set `sigma_m = 2` and the "derived" factor silently becomes a
    2·sqrt(1−e^{−2dt/τ}) charge with no meaning.
  - The residual conservatism the commit declines to chase is now *anti*-conservatism on this term:
    charged 0.082 m against a measured 0.959 m truth-model residual (mean −0.658 m).
  Numerically the double count is small — 0.0033 m² per zenith row, ≈ 0.4 % of the row R — so the
  severity is **low for results, high for the record**: the derivation is written into `masterConfig`
  and into the commit history as a first-principles result and will be quoted as one.

### Higher-order ionosphere (2nd/3rd order)

- **Code**: `+models/+errors/HigherOrderIonosphere.m:26-42` —
  `d2_L1 = sign(I)·min(fractionL1·|I|, cap); d = d2_L1·(f_L1/f)^3` and
  `d3_L1 = sign(I)·min(coeff·I², cap); d = d3_L1·(f_L1/f)^4`;
  defaults `masterConfig.m:2260-2263` (0.003, 0.05 m, 5e-5, 0.005 m);
  driver `ErrorChain.m:1009-1063` (`higherOrderIono_`); per-signal re-evaluation
  `CodeMeasurementBuilder.m:508-538`.
- **Status vs doc**: SUPERSEDED on the R side. The doc recorded `sigma_m = |truth|`; HEAD reads
  `ErrorChain.m:1044-1046`
  `sigma_m = abs(HigherOrderIonosphere.totalDelay(ionoL1_model_m(:)/anchor2, f_L1, fCanon, ic.higherOrder));`
  with a cap fallback when the model supplies no ionosphere (`ErrorChain.m:1048-1062`).
- **Verdict**: correct now on the sigma, still incomplete on the carrier.
- **Sources**:
  - Fritsche et al. (2005) — "ΔI(2)_pi = −½ ΔI(2)_gi" (eq. 11, p. **2** — verified verbatim in the
    extracted text this session) and "s = 7527·c ∫N|B0| cos θB dL" (eq. 4, p. 1).
  - Li et al. (2023) — "The second-order term S2 … is typically only 0.1% of the first order value in
    magnitude"; third order "less than 10% of the second-order value for GPS L1" (printed p. 1716).
- **Critical analysis**: The truth-leak fix is genuinely important and correctly reasoned in the code
  comment — `sigma = |truth|` made every higher-order residual a 1σ event by construction, i.e. it
  made NIS look calibrated on a term the receiver cannot know. What remains, unchanged from the doc:
  **`CarrierMeasurementBuilder` has no higher-order term at all** (grep of `iono` over that file at
  HEAD returns only first-order handling at lines 389-398, 455-456, 480-492, 563-569). So the truth
  carrier is missing the −½·d2 phase advance that Fritsche eq. (11) requires, and code and carrier
  rows of the same epoch disagree by (1 + ½)·d2 in a way no state can absorb. With the shipped caps
  that is bounded by 1.5 × 5 cm = 7.5 cm at L1, and the sign is tied to `sign(I_L1)`, i.e. always
  positive for code, where the real 2nd-order sign follows `B₀·k`.

### Ionosphere-free combination

- **Code**: `+revgnss/IonoFreeCombination.m:16-40` (`coefficients`, `combine`, `combineVariance`);
  identical algebra `IonosphereModel.m:101-119`; a third inline copy
  `IonosphereFreeCombinationDiagnostics.m:46`; a fourth as a fallback in
  `IonosphereFreeBiasBudget.m:57-59`; "Noise amplification factor approx 2.98" at
  `IonosphereFreeCombinationDiagnostics.m:182`.
- **Status vs doc**: DRIFTED (`IonosphereModel` 50-68 → 101-119; diagnostics 163 → 182) and the
  duplication count is now **four**, not three.
- **Verdict**: correct — recomputed live at f1 = 1575.42 MHz / f2 = 1227.60 MHz:
  α = +2.545728, β = −1.545728, **α + β = 1.0000000000000000**,
  **α/f1² + β/f2² = 0.000e+00 exactly**, √(α²+β²) = **2.9783**.
- **Sources**:
  - Kaplan & Hegarty (2006), eq. (7.22) — "ρ_ionospheric_free = (ρ_L2 − γρ_L1)/(1 − γ), where
    γ = (f_L1/f_L2)²"; "measurement errors are significantly magnified through the combination"
    (p. 312).
  - An et al. (2020) — dual-frequency IF PPP versus raw observations with ionospheric constraints
    (pp. 1-3).
- **Critical analysis**: Unchanged and clean. `IonosphereFreeBiasBudget` correctly notes the
  amplification of inter-frequency hardware biases and that IF ambiguities are float-valued. The
  maintenance liability is now worse (four copies); the `_id` note in
  `config/ladder/freq/freq013_ism24125_61250.json` also independently states "the ionosphere-free
  combination of this pair would amplify uncorrelated code noise by 1.198 x, against 2.975 x for GPS
  L1/L2" — a fifth place where the same formula is asserted, this time as prose.

### Uplink column fraction `f_seen`

- **Code**: `EnvironmentModel.m:738-757` —
  `fSeen = B + T*(1 - exp(-(hSat - hPeak)/Htop)); fSeen = max(0, min(1, fSeen));`
  defaults B = 0.30, T = 0.55, hPeak = 350 km, Htop = 100 km, hSat = 550 km, guarded by
  `ic.topside.enable`; scalar path `ic.topsideFraction` (default 1, `masterConfig.m:2237` and
  `masterConfig.m:957`).
- **Status vs doc**: STILL-VALID (738-691 → 738-757), with one addition.
- **Verdict**: correct on the GEO default; the exponential branch is **unreachable**.
- **Sources**: Kaplan & Hegarty (2006), Fig. 7.4 (p. 313) — the single-shell geometry presumes the
  receiver above the layer; the code's own `[ILLUSTRATIVE]` label at `EnvironmentModel.m:743`.
- **Critical analysis**: Grep at HEAD over `config/` and `tests/`: `topside.enable` is set **nowhere** —
  only `topsideFraction` (= 1 in `masterConfig`, in all three golden JSONs, and in
  `realismGradeConfig.m:402`). So the B/T/hPeak/Htop parameterisation the doc criticised as uncited is
  dead code in every shipped path, and the only live behaviour is `f_seen = 1`, which is the exact GEO
  limit. The doc's naming criticism (the docstring says a LEO sees "only a topside fraction" when the
  quantity is the fraction *below* the satellite) is still present verbatim at
  `EnvironmentModel.m:739-743`.

---

## C. Scintillation

### Amplitude scintillation, Conker fading factor, and the σ-composition defect

- **Code**: unit-amplitude GM `EnvironmentModel.m:311-322` (τ = 30 s, `abs()` clamp);
  σ builder `EnvironmentModel.m:604-682`, Conker branch
  `EnvironmentModel.m:675-676`
  `S4 = min(0.7, abs(scintAmplitude)*S4zen*s4Scale*sec^0.9); sigma = sigmaL1*freqFactor/sqrt(1 - 2*S4^2);`
  Composition into the row: `ErrorChain.m:381-391` returns `scintSigmaL1_m` separately;
  `CodeMeasurementBuilder.m:449` `R_diag_new(mi) = R_diag(pi) + scintSig_si^2;` and
  `CodeMeasurementBuilder.m:593-594`
  `R_diag_new(mi) = max(sigma_code_si, sigmaFloor)^2 + scintSig_si^2 + sigma_extra_si2 + towerClkSigma(pi)^2;`
  with the truth injection `CodeMeasurementBuilder.m:442-447, 569` adding an **independent** draw
  `scint_t` on top of `code_t`.
- **Status vs doc**: SUPERSEDED on the doc's "degenerate default" finding, NEW on the composition
  defect.
- **Verdict**: flawed — the Conker factor is applied to a *second, duplicate* copy of the code-tracking
  noise instead of to the C/N0-derived one, so the same thermal jitter enters the row twice.
- **Sources**:
  - Conker, El-Arini, Hegarty & Hsiao (2003), *Radio Science 38*(1), 1001 — the tracking-error variance
    with effective (C/N0)·(1 − 2S4²), valid for S4 < 1/√2. [EXTERNAL — the model the code names]
  - Kaplan & Hegarty (2006) — "the S4 index … is equal to the standard deviation of the power
    variation"; phase scintillation PSD "T f^−p with p in the range of 2.0–3.0" (p. 296).
- **Critical analysis**. The doc's finding (1) — `S4zen = 0` making 'conker' a flat 0.3 m floor — is
  now only true of the bare `masterConfig.m:2266` default; the resolved golden runs
  **S4zen = 0.3, model = 'conker', obliquityModel = 'matchIonoMapping'**, measured this session. The
  real defect is the composition. `getScintillationSigma` returns the **total** Conker-degraded
  tracking σ (`sigmaL1/sqrt(1−2S4²)`), whose S4 → 0 limit is the full 0.30 m nominal code noise, and
  the builders add that in quadrature to the C/N0 code σ, which is *the same physical noise*:

  ```
  cn0.sigmaAt45dBHz_m = 0.30   signals.L1.codeSigma0_m = 0.30   scintillation.sigmaCodeL1_m = 0.30
  ```

  Three knobs, one number, one physical quantity. Measured at the golden's tower elevations:

  | elevation | σ_cn0 | σ_scint | implemented √(σ_cn0²+σ_scint²) | Conker-consistent σ_cn0/√(1−2S4²) | ratio |
  |---|---|---|---|---|---|
  | 20.94° | 0.2344 | 0.5615 | **0.6085** | 0.4387 | **1.39×** |
  | 46.87° | 0.1812 | 0.3570 | **0.4004** | 0.2156 | **1.86×** |
  | 52.30° | 0.1737 | 0.3488 | **0.3896** | 0.2019 | **1.93×** |
  | 78.88° | 0.1523 | 0.3324 | **0.3657** | 0.1688 | **2.17×** |

  Because the duplicate is injected into the truth *and* charged in R, NIS is blind to it — the filter
  is consistent with a world whose code noise is ~2× what Conker's model says. The consequence is a
  headline position error that is systematically pessimistic, and a code-R budget in which
  **scintillation is 54.2 %** of the non-tower-clock total (re-measured this session; see the budget
  below). Fix: pass `σ_cn0` into the Conker factor rather than `sigmaCodeL1_m`, i.e. make scintillation
  a *multiplier* on the C/N0 σ, which is what the class docstring at `EnvironmentModel.m:611-613`
  already says it is ("amplitude fading raises the tracking noise by the Conker et al. (2003) factor").

### Scintillation obliquity gate (`obliquityModel`)

- **Code**: `EnvironmentModel.m:911-953` `scintObliquity_` — `'simpleSecant'` (literal
  `1/max(sin(el), sin(elvFloor))`, kept bit-identical), `'thinShell'`, `'matchIonoMapping'`;
  default `masterConfig.m:2290` `'matchIonoMapping'`; test
  `tests/test_scintillation_obliquity_gated.m`.
- **Status vs doc**: NEW (the doc predates the gate; its "obliquity exponent 0.9 … uncited" criticism
  still stands).
- **Verdict**: correct and well-tested — S4 and the first-order slant delay now pierce one shell with
  one obliquity.
- **Sources**: Conker et al. (2003) — validity requires S4 < 1/√2 [EXTERNAL]; Klobuchar (1987) shell
  geometry via Kaplan & Hegarty (2006, p. 312).
- **Critical analysis**: The change is a genuine consistency fix and the config comment
  (`masterConfig.m:2267-2289`) is unusually honest about why the default moved and what it costs. Two
  things remain unsourced: the exponent **0.9** on `sec` (plausible as a Rino-type `(sec θ)^((p+1)/4)`
  with p ≈ 2.6, but written as a literal in three places — `EnvironmentModel.m:367`, `:675`, and the
  config comment) and the **`min(0.7)` clamp**, which is not a modelling choice but a singularity
  guard: measured this session at the golden's elevations the clamp fires on **11.1 %** of
  (epoch, tower) pairs, and when it fires the row σ is pinned at `0.30/sqrt(0.02) = 2.1213 m`,
  independent of elevation *and* of the amplitude state. One row in nine is therefore not a model
  output but a constant.

### S4 frequency exponent (`s4FrequencyExponent`)

- **Code**: `EnvironmentModel.m:670-673`
  `s4Scale = climatologyAnchorScale(f_L1_Hz, s4Exp) * (f_L1_Hz/freqHz)^s4Exp;` default 0
  (`masterConfig.m:2311`); test `tests/test_link_closure_and_s4_frequency.m:85-109`.
- **Status vs doc**: NEW (the doc records it as "[UPDATED 2026-08-11]" prose inside the scintillation
  entry; it is now shipped code with a test).
- **Verdict**: correct, and correctly left inert.
- **Sources**: Carrano & Rino (2016) / ITU-R P.531 — weak-scatter S4 ∝ f^−n with n = (p+3)/4, nominal
  ~1.5. [EXTERNAL]
- **Critical analysis**: The test pins the direction explicitly — exponent 1.5 **raises** L2
  scintillation by 45 % because L2 is below L1 — which is the counter-intuitive half and exactly the
  thing a future maintainer would silently invert. Well done. The honest reading is that the correct
  physical exponent is ~1.5 and the shipped value is 0, so **every dual-frequency result understates
  the L2 scintillation by 45 %**; enabling it would push more L2 rows into the 11 % clamp band above.
  That is a limit to declare, not a defect to hide.

### Phase scintillation — truth-only, and **not charged in R**

- **Code**: state `EnvironmentModel.m:330-342` (per-tower unit GM, τ = 1.5 s);
  scaling `EnvironmentModel.m:346-369` `phi_rad = state * sigmaPhiZen * (1/max(sin e, sin floor))^0.9`;
  injection `+models/+measurements/CarrierMeasurementBuilder.m:434`
  `phaseScint_m = errorChain.envModel.getPhaseScintRad(ti, elv) * lambda/(2*pi);`
  added to `z_phi` at `CarrierMeasurementBuilder.m:456`. Carrier R is a flat
  `R_phi = sigma_phi^2 * eye(Mp_total)` (`CarrierMeasurementBuilder.m:79`).
- **Status vs doc**: NEW. The doc called this "gated off by default with zero RNG consumption". At HEAD
  the **resolved golden has `phaseScint.enable = 1`, `sigmaPhi_rad = 0.2`, `tau_s = 1.5`** (measured;
  it arrives through `atmosphere.realisticProfile`, `masterConfig.m:970-972`, and the golden resolves
  `realism.grade = 1`).
- **Verdict**: partially correct — the physics (time-correlated, not white) is right; the covariance
  accounting is missing.
- **Sources**: Kaplan & Hegarty (2006), p. 296 — the f^−p phase-scintillation PSD, which is why a
  correlated GM is the right process and white noise in R would be the wrong colour.
- **Critical analysis**: With λ_L1 = 0.1903 m, the zenith 1σ phase perturbation is
  `0.2 · 0.1903/(2π) = 6.06 mm`, and `(1/sin e)^0.9` takes it to **15.4 mm at 20.94°** and 6.2 mm at
  78.88°. The carrier R is a flat **10 mm** (`cfg.measurements.carrier.sigma_m = 0.01`, measured), and
  it does **not** include the phase-scintillation term at all. So on low-elevation carrier rows the
  charged σ is ~1.5× too small (variance ~2.4× too small), on high rows roughly right — an
  elevation-dependent under-charge that will show up as a carrier-channel NIS above 1 and be
  mis-attributed. This is the *opposite* sign to the code-channel defects and is worth stating in the
  same breath: the code channel over-injects noise and over-charges the troposphere, the carrier
  channel under-charges scintillation.

---

## D. Gaseous absorption (ITU-R P.676)

### `+models/+atmosphere/GaseousAbsorption.m` — the frozen table and its slant composition

- **Code**: `GaseousAbsorption.m:48-60` (frozen `TABLE_F_HZ`, `TABLE_A_DRY_DB`, `TABLE_A_WET_DB`,
  `ZWD_REF_M = 0.095669`); composition `GaseousAbsorption.m:144`
  `A_dB = A_dry_dB*m_h + A_wet_dB*m_w*(zwd/zwdRef);`; hard error off-table
  `GaseousAbsorption.m:86-94`; mapping `GaseousAbsorption.m:168-198`.
  Consumption: `MeasurementModelUtils.m:246`
  `cn0_dBHz = base_dBHz + elevGain_dB*sin(elevation_rad) - A_gas_dB;` and
  `MeasurementModelUtils.m:247` `sigma = sigma0_m * 10^(-(cn0_dBHz - 45)/20);`
  Gate `MeasurementModelUtils.m:258-266`, `cfg.atmosphere.gaseousAbsorption.enable` default **false**
  (`masterConfig.m:2186`).
  Generator `analysis/generate_gas_absorption_table.m`; kernel `analysis/p676_annex1.m`.
- **Status vs doc**: NOW-WRONG on one claim (the humidity sharing, see A.3 above), otherwise
  re-verified and extended.
- **Verdict**: correct as an implementation of P.676-13 Annex 1; the *sharing* rationale is wrong and
  one design claim ("the same mapping the troposphere uses") is contradicted by the default config.
- **Sources** (all verbatim from the ITU's readable P.676-10 release; the -13 tables were separately
  diffed row-by-row by `analysis/verify_p676_tables.py` against the P.676-13 Word release):
  - Recommendation ITU-R P.676-10 (2013), Annex 1 §1 — "an estimate of gaseous attenuation computed by
    summation of individual absorption lines that is valid for the frequency range 1-1 000 GHz"
    (Scope, p. 1). [EXTERNAL]
  - Recommendation ITU-R P.676-10, eq. (2) note — "for frequencies, f, above 118.750343 GHz oxygen
    line, only the oxygen lines above 60 GHz complex should be included in the summation; the
    summation should begin at i = 38 rather than at i = 1" (p. 2). [EXTERNAL] — implemented verbatim
    at `p676_annex1.m:146-150`.
  - Recommendation ITU-R P.676-10, eq. (4) — "The water-vapour partial pressure, e, may be obtained
    from the water-vapour density ρ using the expression: e = ρT/216.7" (p. 5). [EXTERNAL] —
    `p676_annex1.m:124`.
  - Recommendation ITU-R P.676-10, eq. (3) definitions — "p: dry air pressure (hPa)"; "θ = 300/T"
    (p. 2). [EXTERNAL] — `p676_annex1.m:122-123`, and `generate_gas_absorption_table.m:62`
    `Pd_hPa = max(P_hPa - e_hPa, 1e-9)` correctly passes **dry-air**, not total, pressure.
  - Recommendation ITU-R P.676-10, §2.2.1.1 — "For an elevation angle, ϕ, between 5° and 90°, the path
    attenuation is obtained using the cosecant law" (p. 18). [EXTERNAL] — which is what
    `mappingKind = 'simple'` implements, and is the reason that default is defensible even though it
    contradicts the class's own stated rationale.
  - Recommendation ITU-R P.835 — mean annual global reference atmosphere. [EXTERNAL]
- **Critical analysis**. **What I could verify directly.** Every one of equations (1) and (3)–(9) was
  re-derived against the Recommendation text and matches, including the two non-obvious ones: the
  oxygen Zeeman broadening `Δf = sqrt(Δf² + 2.25e-6)` (`p676_annex1.m:129`) and the water-vapour
  Doppler form `Δf = 0.535Δf + sqrt(0.217Δf² + 2.1316e-12·f_i²/θ)` (`p676_annex1.m:136`). The
  line-shape factor `p676_annex1.m:156-162` carries both the resonance and image terms with the
  overlap correction, with δ = 0 for water vapour, as the Recommendation prescribes. **I re-ran the
  generator this session (0.50 s, no toolbox) and it reproduced the frozen table to the last digit**,
  including `ZWD_REF_M = 0.095669`, which I also re-derived by hand from the Bevis relation. The
  P.835 layer polynomials at `generate_gas_absorption_table.m:45-57` are the US Standard Atmosphere
  1976 layers and check out (288.15 − 6.5h, 216.65 isothermal, etc.).

  **Sanity against published magnitudes**: zenith total 0.034 dB at L1 and 0.390 dB at 24.125 GHz are
  the standard L-band and K-band figures; 161.47 dB at 61.25 GHz is the 60 GHz oxygen complex, and the
  resolve-time refusal is the right response.

  **What is wrong or overstated.**
  1. The `(zwd/zwdRef)` humidity ratio (A.3) — 1.47× in the wrong direction.
  2. `GaseousAbsorption.m:105-107` claims absorption and the troposphere "can never disagree about the
     obliquity of the atmosphere they share"; at the default they use different mappings.
  3. Mapping *absorption* with a *delay* mapping function is an approximation the code does not flag.
     The hydrostatic delay's weighting is ∝ density; oxygen absorption near the Debye continuum goes as
     p², so its equivalent height (~5.5 km in P.676 Annex 2) is below the hydrostatic delay's (~8 km).
     At the golden's elevations the difference between `m_h` and `1/sin e` is under 1 %, so this is
     immaterial here — but it becomes a real error below ~10° and should be labelled.
  4. **Absorption reaches only the code channel.** `cn0CodeSigma` is called from
     `codeSignalSigma` and `ErrorChain.computeCodeSigmaVec_` only; the carrier σ is the flat
     `cfg.measurements.carrier.sigma_m` and the Doppler σ is likewise independent. So a band that
     costs 4.6 % on code σ costs 0 % on carrier σ, and the 61.25 GHz link that "does not close" would
     still deliver a 10 mm carrier if the refusal guard were bypassed.
  5. 915 MHz is below P.676's own 1 GHz validity floor (the class says so at
     `GaseousAbsorption.m:38-41`; the Scope quote above confirms it). The value is 0.030 dB and
     changes nothing, but `freq009` must carry the caveat.

### Resolve-time link-closure refusal

- **Code**: `cfg.measurements.codeNoise.cn0.minTrackable_dBHz = 25` (measured on the resolved golden);
  refusal identifier `ConfigFactory:linkDoesNotClose`; test
  `tests/test_link_closure_and_s4_frequency.m:33-83`.
- **Status vs doc**: NEW (mentioned in the doc's absorption entry; now traced as its own feature).
- **Verdict**: correct — and unusually good practice.
- **Sources**: Recommendation ITU-R P.676-10, Fig. 2 and §1 — "Near 60 GHz, many oxygen absorption
  lines merge together, at sea-level pressures, to form a single, broad absorption band" (p. 2).
  [EXTERNAL]
- **Critical analysis**: The guard fires only when absorption **and** the `cn0` code model are both on
  (test corner 2 pins the three inert corners), and it uses the **zenith** value, i.e. the best case,
  so it refuses only the genuinely impossible. The refusal message is required by test to carry the
  number ("161.", "dB-Hz") and the phrase "physical result" — i.e. the test enforces that a refusal is
  quantitative rather than a bare "unsupported band". The honest limitation, stated in
  `freq013_ism24125_61250.json` itself: with absorption **off**, which is the default, freq013 still
  runs and produces 61.25 GHz numbers whose link margin is fiction. That exclusion has to travel with
  every figure quoted from that rung.

---

## E. Cross-cutting

### Formation-shared atmosphere gate

- **Code**: `+models/+noise/SharedAtmosphereRng.m`; `EnvironmentModel.m:99-110` (construction),
  `:131-147` (`envStream_`), `:174-209` (`stepShared_` with grid-dt catch-up and the
  `MAX_SHARED_CATCHUP_EPOCHS = 1e6` guard at `:67-70`); per-measurement scintillation draw
  `ErrorChain.m:256-263` (`drawKeyedAtmosphere`), consumed at `CodeMeasurementBuilder.m:442-444`.
- **Status vs doc**: STILL-VALID.
- **Verdict**: correct — a genuine correctness feature, default-off for golden stability.
- **Sources**: `SharedAtmosphereRng.m` header (recomputed: 2000/36e6 rad = 11.5″, 0.56 m at 10 km,
  19.4 m at a 350 km pierce point, against an L-band Fresnel scale √(λz) ≈ 260 m); Li et al. (2023),
  pp. 1716-1721 — spatial correlation is the basis of all differential correction.
- **Critical analysis**: Unchanged and sound. Note the *antenna* twin `sharedAcrossAntennas` is now
  wired into the scintillation truth draw via `errorChain.antennaKey(...)`
  (`CodeMeasurementBuilder.m:444`), with the right physical argument (a 2 m antenna cross is ≤ 8e-3
  Fresnel scales). The one simplification remains: sharing makes the atmosphere *perfectly* common
  mode where reality leaves a mm-level decorrelated residual.

### Legacy façades and documentation claims

- **Code**: `models/atmosphere/ionosphere.m:1-42`, `models/atmosphere/troposphere.m` — mode-dispatched
  shims delegating verbatim; both hard-error on `mode='truth'`.
- **Status vs doc**: DRIFTED — two of the three stale claims the doc listed are fixed
  (`ConfigFactory` `klobucharStatus`, `MappingFunctions.m:116`), one is not.
- **Verdict**: correct as code; the surviving documentation claims are wrong.
- **Critical analysis**: Still live at HEAD and contradicted by the shipped code:
  - `config/masterConfig.m:3201` — "NOTE: VMF3, GPT3, and Niell are NOT implemented." Niell **is**
    implemented and is the realistic profile's default mapping.
  - `config/masterConfig.m:3210` — "NOTE: This is NOT a Klobuchar model. Klobuchar is not
    implemented." Klobuchar **is** implemented and is the realistic profile's model correction.
  - `config/masterConfig.m:3230` — "Pair with `errors.ionosphere.model.correction='none'` so the state
    supplies the model iono (not double-counted)." The shipped golden pairs `perTowerSlant` with
    `correction = 'klobuchar'` (both measured). That is not in fact a double count — the state is free
    and absorbs whatever the deterministic model leaves — but the config's own guidance says the
    opposite of what the config does.
  - `EnvironmentModel.m:807` — the ZHD docstring describes a model the body abandoned.

---

## Double-count candidates

Severity is judged on the *result*, not the elegance. All numbers measured this session on the
resolved `golden_baseline.json` unless stated.

**Re-measured code-R budget** (mean charged variance per source over 400 epochs at the four visible
tower elevations 20.94°/46.87°/52.30°/78.88°; tower-clock term excluded because it is another domain's):

| source | variance [m²] | share | σ [m] |
|---|---|---|---|
| scintillation | 0.4642 | **54.19 %** | 0.6813 |
| multipath | 0.2777 | 32.42 % | 0.5270 |
| **troposphere** | 0.0694 | **8.11 %** | 0.2635 |
| code noise (C/N0) | 0.0353 | 4.12 % | 0.1878 |
| **ionosphere** | 0.0074 | **0.86 %** | 0.0860 |
| hardware delay | 0.0025 | 0.29 % | 0.0500 |
| higher-order iono | 0.00005 | 0.01 % | 0.0070 |

This supersedes the budget quoted in `6566cff`'s message ("ionosphere 61%, tower clock 22%,
scintillation 10%, multipath 4%, troposphere 1%, code noise 0.8%"), which was measured before the
rScale fix and does not describe HEAD.

1. **Scintillation σ duplicates the C/N0 code σ.** — SEVERITY **HIGH**
   - A: `+models/+errors/EnvironmentModel.m:676` `sigma = sigmaL1 * freqFactor / sqrt(1 - 2*S4^2)`
     with `sigmaL1 = cfg.errors.ionosphere.scintillation.sigmaCodeL1_m = 0.30`.
   - B: `+models/+measurements/MeasurementModelUtils.m:247`
     `sigma = sigma0_m * 10^(-(cn0_dBHz - 45)/20)` with
     `cfg.measurements.codeNoise.cn0.sigmaAt45dBHz_m = 0.30`.
   - Mechanism: Conker (2003) models scintillation as a **degradation of the same tracking loop**, so
     the correct total is `σ_cn0/√(1−2S4²)`. The code instead builds a second full tracking σ from a
     duplicate 0.30 m constant and adds it in quadrature —
     `CodeMeasurementBuilder.m:449` and `:593-594` — with an independent truth draw at `:442` on top of
     the code draw. At S4 = 0 the row would still carry two copies of the thermal floor.
   - Size: implemented / Conker-consistent σ = **1.39× (20.9°) to 2.17× (78.9°)**; variance 1.9× to
     4.7×. Scintillation is 54 % of the code-R budget above.
   - Why it is invisible: symmetric on truth and R, so NIS cannot see it. It biases every reported
     position RMS pessimistic.

2. **Troposphere: the model-uncertainty base `σ_m` is charged in R while the ZWD state carries the
   same wet delay in P/Q.** — SEVERITY **HIGH**
   - A: `+models/+errors/ErrorChain.m:596` `sigmaBase = tc.sigma_m * mappingFn(elv)` (σ_m = 0.15 m),
     unreduced.
   - B: `+filter/ReverseGNSSEKF.m:1596-1602` `q_zwd = sigma_ss^2*(1 - phi_zwd^2)` with
     `estimation.tropoZwd.sigma_ss_m = 0.04`, `tau_s = 10800`, plus the state's own P.
   - Mechanism: the guard at `ErrorChain.m:608-616` reduces only `sigmaWetR`, which reaches R through
     `sigmaStochR`, which is **identically zero** because `residualOn = false`
     (`stochastic.modelResidual.enable = 0`). Exactly the defect pattern `03da4fb` named for the
     ionosphere — "the guard runs, changes a quantity that is already nil, and reads as protection" —
     and it was fixed only for the ionosphere.
   - Size: charged σ 0.2419 m vs actual (truth − model) 0.0206 m RMS → **11.7× in σ, 138× in
     variance**; 8.1 % of code R. Compounding it, the 0.15 m itself is sized for a `simpleMapped`
     truth/model split (2.45 − 2.30) that `localWeatherGM` does not use.

3. **Slant-iono: the one-step process increment is charged in Q and again in R.** — SEVERITY
   **MEDIUM** (small numerically, but it is documented as a first-principles derivation)
   - A: `+filter/ReverseGNSSEKF.m:1616` `q_iono = sigma_iono^2*(1 - phi_iono^2)` → √q = **0.057686948 m**.
   - B: `+revgnss/ConfigFactory.m:2693` `rScaleF_ = sqrt(1 - exp(-2*dtF_/tauF_))` = **0.057686948**,
     applied at `ErrorChain.m:875` `sigmaBase = sigmaBase * rScale_` to `σ_m = 1.0`.
   - Mechanism: `S = H(FPFᵀ+Q)Hᵀ + R`. Q already contains the increment; putting it in R too counts it
     twice. The value R legitimately owns is the *truth-vs-filter model mismatch* (truth σ_ss = 0.3
     vs filter 1.0) plus the Klobuchar bias, neither of which was computed.
   - Size: 0.0033 m² per zenith row, ≈ 0.4 % of the row R. Also note the substitution error: the
     factor is derived from `estimation.slantIono.tau_s` but multiplies `errors.ionosphere.sigma_m` —
     harmless only because both σ's are 1.0 at the golden.

4. **Absorption's wet column and the troposphere's ZWD are two different water models used as one
   ratio.** — SEVERITY **MEDIUM** (wrong direction, small magnitude at the shipped bands)
   - A: `+models/+errors/EnvironmentModel.m:894` `ZWD_k = 0.15 * RH_k * exp(-alt_m/2000)` → 0.075 m.
   - B: `analysis/generate_gas_absorption_table.m:65-68` → `ZWD_REF_M = 0.095669` m from the Bevis
     relation over P.835's 7.5 g/m³.
   - Mechanism: `GaseousAbsorption.m:144` forms `zwd/zwdRef = 0.784` and scales A_wet by it, on the
     stated basis that the run is "22 % drier". A physical evaluation of the same (T, RH, P) gives
     ρ_w = 8.62 g/m³ and ZWD ≈ 0.115 m, i.e. **wetter**.
   - Size: wet column off by a factor ≈ 1.47; at 24.125 GHz that is 0.116 dB of 0.39 dB, ≈ 1.35 % on
     code σ. At L-band, 0.0001 dB — nil. It is a *direction* error, not a magnitude one.

5. **Three config leaves hold the same code-tracking σ.** — SEVERITY **LOW** (latent)
   `cfg.measurements.codeNoise.cn0.sigmaAt45dBHz_m = 0.30`, `cfg.signals.L1.codeSigma0_m = 0.30`,
   `cfg.errors.ionosphere.scintillation.sigmaCodeL1_m = 0.30`. The L1 row's σ comes from the first
   (via `ErrorChain.computeCodeSigmaVec_`), the L2 row's from the second (via
   `CodeMeasurementBuilder.m:496`), and the scintillation floor from the third. They agree today by
   coincidence; nothing relates them. This is the enabling condition for defect 1.

6. **The IF coefficient formula lives in four code sites plus one JSON prose assertion.** — SEVERITY
   **LOW** (maintenance, not numerics). `IonoFreeCombination.m:16-25`,
   `IonosphereModel.m:112-118`, `IonosphereFreeCombinationDiagnostics.m:46`,
   `IonosphereFreeBiasBudget.m:59`, and `config/ladder/freq/freq013_ism24125_61250.json:2`.

7. **Not a double count, checked and cleared:** the frequency-scaling composition
   `climatologyAnchorScale(f_ref, n) · (f_ref/f_sig)^n` applied in `EnvironmentModel` and then
   `(f_L1/f_sig)^scintExpF` again in `CodeMeasurementBuilder.m:433` — the first factor is evaluated
   with `freqHz = f_L1` by `ErrorChain.m:388`, so the product telescopes to `(f_canon/f_sig)^n`
   exactly. Verified by `tests/test_iono_band_scaling.m` and by hand.

---

## Logical flaws

1. **A guard that guards nothing, twice.** `ErrorChain.m:608-616` (troposphere) reduces `sigmaWetR`,
   which reaches R only through `sigmaStochR`, which is `zeros` whenever `residualOn` is false —
   which is every shipped configuration (`modelResidual.enable = 0`). The ionosphere twin at
   `ErrorChain.m:801-808` has the same structure and was rescued by `rScaleWhenStateActive`; the
   troposphere was not. The comment block at `ErrorChain.m:826-841` even *names* this failure mode for
   the ionosphere and does not notice it applies verbatim two hundred lines above.

2. **A derivation that proves the opposite of what it claims.** `masterConfig.m:160-174` and
   `ConfigFactory.m:2680-2694` assert that `sqrt(1-exp(-2dt/τ))` is "the standard Kalman statement
   that a quantity carried by a state must not also be charged in R". That factor is `√Q/σ_ss`. Q is
   the state's own model of that increment. The correct statement is that R should carry the *model
   mismatch*, which is not a function of τ and dt alone.

3. **A derived scale applied to the wrong knob.** `ConfigFactory.m:2687-2694` computes the factor from
   `cfg.estimation.slantIono.tau_s` and writes it to `cfg.errors.ionosphere.rScaleWhenStateActive`,
   which `ErrorChain.m:875` multiplies onto `cfg.errors.ionosphere.sigma_m`. Two different σ's, one
   factor. Undetectable at the golden because both are 1.0.

4. **Sign error in a "consistency" fix.** `3489075` scales the P.676 wet column *down* on the strength
   of an uncited ZWD parameterisation, where the same atmosphere evaluated physically is *wetter* than
   the reference. `tests/test_per_tower_atmosphere.m:95-98` then hard-codes the wrong conclusion
   (`ratio ≈ 0.784`, "repo default is 0.784 of the table reference humidity") as an assertion, so the
   test now *locks in* the error: it can only fail if someone fixes the physics.

5. **Tests that pin arithmetic and cannot see physics.** `test_per_tower_atmosphere.m` verifies
   `A = dry + wet·(ZWD/ZREF)` to 1e-12 and that "every tower now has a DISTINCT zenith wet delay" —
   both true of any formula. `test_niell_mapping_function.m` evaluates only at
   `doy = 28 + 365.25/4`, where the seasonal cosine is exactly zero, so the sign of the Niell seasonal
   term is untestable. `test_gaseous_absorption.m` compares the frozen table against values
   transcribed from the generator's own output, i.e. it cannot detect a wrong generator.

6. **Inert configuration presented as physics.**
   - `cfg.environment.weather.hydrostaticModelAssumption` — set to `'fixedNominalMapping'`
     (`masterConfig.m:2217`) and overridden to `'perfectSurfaceMeteorology'` under the realistic
     profile (`masterConfig.m:946-947`). **No reader anywhere in the repo.** It reads as a statement
     about how surface meteorology is treated and does nothing.
   - `cfg.errors.ionosphere.scintillation.affectsCodeNoise` and `.affectsPseudorangeBias`
     (`masterConfig.m:2312-2313`) — declared, never read. A reader will believe scintillation can be
     routed to a bias channel; it cannot.
   - `cfg.errors.ionosphere.scintillation.process = 'gaussMarkov'` (`masterConfig.m:2291`) — appears
     only in `configEnumRegistry`; `EnvironmentModel` hardcodes `gaussMarkovStep`.
   - `cfg.environment.weather.heightScale_m = 8400` (`masterConfig.m:2213`) — the parameter of the
     exponential pressure profile the ZHD docstring still describes and the body no longer uses. Grep
     at HEAD: no reader outside `masterConfig`.
   - `cfg.environment.weather.{defaultTemperature_K, lapseRate_K_per_m, minTemperature_K,
     maxTemperature_K}` — a full temperature model is evaluated (`EnvironmentModel.m:869-875`) and
     stored (`:903`), and **no delay, absorption or noise term reads it**. Its only consumer in the
     repo is an Orekit cross-validation test. Turning the lapse rate off changes nothing.
   - `cfg.errors.ionosphere.topside.*` (B, T, hPeak_km, Htop_km, hSat_km) — the branch at
     `EnvironmentModel.m:746-756` is never entered because `topside.enable` is set nowhere.

7. **Claims contradicted by shipped code**, all still at HEAD: `masterConfig.m:3201` ("Niell … NOT
   implemented"), `masterConfig.m:3210` ("Klobuchar is not implemented"), `masterConfig.m:3230` (pair
   `perTowerSlant` with `correction='none'`, while the golden pairs it with `'klobuchar'`),
   `EnvironmentModel.m:807` (`ZHD = 2.3*P/1013.25`), `GaseousAbsorption.m:105-107` ("can never
   disagree about the obliquity"), `NiellCoefficients.m:5,29,34,39` ("Table 1"/"Table 2" for what are
   Niell's Tables 3 and 4), and the code-R budget quoted in `6566cff` and `masterConfig.m:3236-3243`.

8. **Elevation-floor asymmetry, still latent.** `ErrorChain.m:495-497` passes the raw elevation to
   `cn0CodeSigma` while `MeasurementModelUtils.m:189` floors it. Documented and deliberately
   preserved for bit-identity, unreachable under a 10° mask — but it means the L1 row and the L2 row of
   the same measurement use different elevation conventions below the floor.

9. **A model correction that is not a correction.** With `amplitude_ns = 20` against a 30 TECU truth
   peak, the Klobuchar "correction" makes the ionospheric error *larger in magnitude* at every hour
   than doing nothing would at night (truth 0.974 m vs residual 0.525 m — better) but the reverse is
   not checked anywhere, and at the peak it converts a +4.872 m error into a −2.623 m one. Any
   ablation rung that turns the model side off will show the ionosphere *improving*, which will be
   read as an ionosphere result rather than a calibration artefact.

10. **`min(0.7)` is a singularity guard doing duty as a model.** `EnvironmentModel.m:675`. Measured
    clamp rate at the golden: **11.1 %** of (epoch, tower) pairs, where σ pins at 2.1213 m
    independent of elevation and amplitude. The config comment
    (`masterConfig.m:2280-2285`) is candid about this for the *legacy* obliquity, but the clamp still
    fires one time in nine with the thin-shell obliquity that was adopted to avoid it.

---

## Limits of this domain

Concrete statements of what the atmosphere models in this repo **cannot** support.

1. **No absolute atmospheric-delay accuracy claim.** The zenith wet delay is
   `0.15·RH·exp(−h/2000)`, an uncited, temperature-blind, linear-in-RH parameterisation that returns
   0.075 m for every golden tower from Libreville (0.04° N) to Stockholm (59.3° N) and understates a
   physical Saastamoinen evaluation of the same (T, RH) by ~35 %. The temperature model that would
   fix it is computed and discarded. Nothing in this simulation constrains the absolute ZTD; only the
   *residual after a matched model* is meaningful, and that residual is 0.021 m RMS by construction.

2. **The ionosphere result is a result about a mis-calibrated Klobuchar, not about the ionosphere.**
   The shipped realistic profile injects a sign-definite +1.196 m mean vertical model bias
   (+0.525 to +2.623 m over 24 h). Any statement of the form "the ionosphere contributes X m" from a
   `feat`/`freq` rung is measuring the 20 ns-vs-30 TECU mismatch, not ionospheric physics.

3. **Code-channel noise is ~2× the model that names it.** Because the Conker σ and the C/N0 σ are the
   same tracking noise charged twice (1.39×–2.17× measured), no absolute code-ranging-noise figure and
   no "position RMS achievable at 45 dB-Hz" claim can be made from these runs. Relative comparisons
   between rungs that share the configuration are unaffected.

4. **NIS/NEES cannot validate this domain.** Every atmospheric defect found here is either symmetric
   on truth and R (scintillation duplicate → invisible to NIS) or an over-charge against a matched
   model (troposphere → NIS below 1, read as "conservative"). The code-channel NIS/dof of 0.65 quoted
   in `6566cff` is dominated by the 138× troposphere over-charge and the 4.7× scintillation variance,
   not by anything about the ionosphere.

5. **R is diagonal and white; the atmosphere is neither.** The slant ionosphere at one tower is shared
   by the L1 and L2 rows and is time-correlated with τ = 600 s; the ZWD with τ = 10800 s. Both are
   charged as independent white noise on the diagonal. Innovation autocorrelation, not variance, is
   the diagnostic, and it is not computed for these channels.

6. **Dual-frequency scintillation is understated by 45 % on the lower band.** `s4FrequencyExponent`
   ships at 0; the weak-scatter value is ~1.5, and `(f_L1/f_L2)^1.5 = 1.45`. Any L1/L2 or IF result
   assumes band-independent S4.

7. **No higher-order ionosphere on the carrier.** `CarrierMeasurementBuilder` carries no 2nd/3rd-order
   term, so the −½·d2 phase advance (Fritsche et al., 2005, eq. 11) is absent. Bounded by
   1.5 × 5 cm = 7.5 cm at L1 with the shipped caps. Carrier-phase millimetre claims must exclude it.
   The 2nd-order sign is also tied to `sign(I_L1)`, not to `B₀·k`, so it cannot support bias studies.

8. **Phase scintillation is injected but not charged.** Under the realistic profile the truth carrier
   carries 6.1 mm (zenith) to 15.4 mm (20.9°) of correlated phase jitter against a flat 10 mm carrier
   R. Carrier-channel covariance claims are not honest below ~30° elevation.

9. **Gaseous absorption reaches only the code σ, and only at nine tabulated frequencies.** The carrier
   and Doppler channels are absorption-blind. The table hard-errors off-table (correctly), 915 MHz
   is below P.676's 1 GHz validity floor, and the whole feature is `enable = false` by default — so
   **no shipped golden or realism-grade result includes gaseous absorption at all**. The freq013
   61.25 GHz rung runs with absorption off and its link margin is fiction; the exclusion must travel
   with every number quoted from it.

10. **Mapping functions are validated, the atmosphere they map is not.** Niell (1996) is exact to eight
    digits and cross-validated against Orekit, but it is being applied to a two-parameter invented
    weather state with one global relative humidity, no gradients, no azimuthal asymmetry, and no
    NWP/VMF3/GPT3 input. The mapping-function accuracy is not the limiting error and should not be
    presented as evidence of tropospheric fidelity.

11. **`f_seen = 1` is the only path that runs.** The uplink column-fraction parameterisation is dead
    code; every result is a full-column GEO result. No LEO/MEO ionospheric-column claim is supported.

12. **The formation-shared atmosphere is off by default**, so any between-satellite differenced
    observable in the shipped goldens inherits ~√2× the full atmospheric error rather than ~0. Results
    from differenced observables are only meaningful with
    `cfg.atmosphere.sharedAcrossFormation.enable = true`.

---

## References (APA 7)

- An, X., Meng, X., & Jiang, W. (2020). Multi-constellation GNSS precise point positioning with
  multi-frequency raw observations and dual-frequency observations of ionospheric-free linear
  combination. *Satellite Navigation, 1*, 7. https://doi.org/10.1186/s43020-020-0009-x
- Bar-Shalom, Y., Li, X.-R., & Kirubarajan, T. (2001). *Estimation with applications to tracking and
  navigation: Theory, algorithms and software*. Wiley. [EXTERNAL]
- Bevis, M., Businger, S., Chiswell, S., Herring, T. A., Anthes, R. A., Rocken, C., & Ware, R. H.
  (1994). GPS meteorology: Mapping zenith wet delays onto precipitable water. *Journal of Applied
  Meteorology, 33*(3), 379–386. [EXTERNAL]
- Carrano, C. S., & Rino, C. L. (2016). A theory of scintillation for two-component power law
  irregularity spectra: Overview and numerical results. *Radio Science, 51*(6), 789–813.
  https://doi.org/10.1002/2015RS005903 [EXTERNAL]
- Conker, R. S., El-Arini, M. B., Hegarty, C. J., & Hsiao, T. (2003). Modeling the effects of
  ionospheric scintillation on GPS/Satellite-Based Augmentation System availability. *Radio Science,
  38*(1), 1001. https://doi.org/10.1029/2000RS002604 [EXTERNAL]
- Davis, J. L., Herring, T. A., Shapiro, I. I., Rogers, A. E. E., & Elgered, G. (1985). Geodesy by
  radio interferometry: Effects of atmospheric modeling errors on estimates of baseline length.
  *Radio Science, 20*(6), 1593–1607. https://doi.org/10.1029/RS020i006p01593 [EXTERNAL]
- Enge, P. K. (1994). The Global Positioning System: Signals, measurements, and performance.
  *International Journal of Wireless Information Networks, 1*(2), 83–105.
  https://doi.org/10.1007/BF02106512
- European Space Agency. (n.d.). *Klobuchar ionospheric model*; *Mapping of Niell*. Navipedia.
  https://gssc.esa.int/navipedia/ [EXTERNAL]
- Fritsche, M., Dietrich, R., Knöfel, C., Rülke, A., Vey, S., Rothacher, M., & Steigenberger, P.
  (2005). Impact of higher-order ionospheric terms on GPS estimates. *Geophysical Research Letters,
  32*, L23311. https://doi.org/10.1029/2005GL024342
- International Telecommunication Union. (2013). *Attenuation by atmospheric gases* (Recommendation
  ITU-R P.676-10). [EXTERNAL — used for verbatim quotation because its text layer is readable]
- International Telecommunication Union. (2022). *Attenuation by atmospheric gases and related
  effects* (Recommendation ITU-R P.676-13). [EXTERNAL — the version the tables are taken from]
- International Telecommunication Union. (2017). *Reference standard atmospheres* (Recommendation
  ITU-R P.835). [EXTERNAL]
- International Telecommunication Union. (2019). *Ionospheric propagation data and prediction methods
  required for the design of satellite services and systems* (Recommendation ITU-R P.531). [EXTERNAL]
- Kaplan, E. D., & Hegarty, C. J. (Eds.). (2006). *Understanding GPS: Principles and applications*
  (2nd ed.). Artech House.
- Li, X., Barriot, J.-P., Lou, Y., Zhang, W., Li, P., & Shi, C. (2023). Towards millimeter-level
  accuracy in GNSS-based space geodesy: A review of error budget for GNSS precise point positioning.
  *Surveys in Geophysics, 44*(6), 1691–1780. https://doi.org/10.1007/s10712-023-09785-w
- Niell, A. E. (1996). Global mapping functions for the atmosphere delay at radio wavelengths.
  *Journal of Geophysical Research: Solid Earth, 101*(B2), 3227–3246.
  https://doi.org/10.1029/95JB03048 [EXTERNAL retrieval; cited by the code]
- Osah, S., Acheampong, A. A., Dadzie, I., & Fosu, C. (2021). Comparative evaluation and analysis of
  different tropospheric delay models in Ghana. *South African Journal of Geomatics, 10*(2), 115–134.
  https://doi.org/10.4314/sajg.v10i2.10
- Tralli, D. M., & Lichten, S. M. (1990). Stochastic estimation of tropospheric path delays in Global
  Positioning System geodetic measurements. *Bulletin Géodésique, 64*(2), 127–159.
  https://doi.org/10.1007/BF02520642 [EXTERNAL]

---

# Round 2 — Section: Orbital Dynamics, Perturbations, Frames, Tides, Formation Geometry

**Scope**: `+models/+orbit/{OrbitDynamics,OrbitPerturbations,OrbitPropagator,De440Ephemeris}.m`;
`+models/+frames/{FrameTimeUtils,TruthEarthOrientation,SolidEarthTide,GeometryUtils,LightTimeSolver}.m`;
`+revgnss/{SwarmFormation,MultiAssetGeometry,OrbitFrame,Relativity,Constants}.m`;
`+filter/EkfDynamicsPredictor.m`; `config/internal/{applyLuniSolar,orbitClassConfig}.m`;
plus the relativity wiring in `+models/+clocks/{RelativisticClockCorrection,ClockModel}.m` and
`+revgnss/ConfigFactory.m`.

**HEAD at review**: `170e37d` (branch `feature/ground-orientation-exec`). Doc baseline: `3489075`.

**Git delta in this domain**: `git diff --stat 3489075..HEAD` over every `+models/+orbit`,
`+models/+frames`, `+revgnss/{SwarmFormation,MultiAssetGeometry,OrbitFrame,Relativity,Constants}`,
`+filter/EkfDynamicsPredictor.m`, `config/internal/{applyLuniSolar,orbitClassConfig}.m` path returns
**empty** — not one line of orbital-dynamics or frames source changed in the 8 commits since the doc.
Every file:line citation into those files is therefore expected to hold, and I re-checked each one
anyway. What *did* change is `config/masterConfig.m` (+34/−10) and `+revgnss/ConfigFactory.m`
(+21/−3), which shifted every masterConfig line number the doc quotes, and `170e37d` introduced a
**new cross-file inconsistency in the tower geometry** (see NEW-4).

**Headline of this re-verification**

1. The physics is still right. Every constant re-checked digit by digit against the extracted
   Montenbruck & Gill text; J2 = 1.08262668e-3 reproduces √5·484.165368e-6 to the last digit; the J2
   Cartesian expansion, the third-body direct+indirect form, the M&G Sun/Moon series coefficients,
   the RK4 tableau, the IERS-2010 degree-2 tide, and the polar-motion small-angle sign all re-derive
   correctly. Nine of the fourteen existing feature verdicts are STILL-VALID unchanged.
2. **One existing verdict is NOW-WRONG**: the Clohessy–Wiltshire "separation stays in
   [baseline, 1.118·baseline]" claim — verified in round 1 — is false at the **shipped default**
   `cfg.formation.crossTrackSpread = 1.0`. Measured by running the real J2-propagated truth:
   **[500.0, 2061.5] m** over an orbit and **[708.0, 1984.9] m** over the 3600 s headline arc
   against a 1000 m "baseline". The test that guards the bound builds its own `cfg.formation`
   *without* the field, so it silently tests the ca = 1 case (measured 1000.00 / 1118.02 m, all
   assertions pass) — a test that cannot fail on the configuration the product ships.
3. **One existing verdict is NOW-WRONG in the other direction (a defect that isn't one)**: the doc's
   cross-referenced "finalizeConfig J2 auto-tuner can silently overwrite the modelMismatch sigma" is
   unreachable at every shipped configuration — double-guarded by a branch that requires a two-body
   EKF and by a `<= 1e-6` threshold that `applyLuniSolar`'s 1e-5 never satisfies.
4. **Relativity is now a five-site story, not one.** `revgnss.Relativity` (the number),
   `models.clocks.RelativisticClockCorrection` (the model-side applier, NEW),
   `ClockModel.relativisticFracFreq` (the truth-side integrator), and **four independent copies** of
   `properTimeRate_ = 1 − (GM/r + v²/2)/c²`. They do not double-count on the ground↔space channels —
   the `getFractionalFrequency` / `getOscillatorFractionalFrequency` split is exactly the right
   guard and I verified the underlying identity numerically to 1e-17. But the identity the guard
   rests on requires a ground endpoint carrying its own proper-time rate, and
   `ReciprocalEndpointTruthProvider.fixedStation` hard-sets it to 1 (test-enforced). See DC-1.
5. Two numbers in the round-1 doc are quantitatively wrong by orders of magnitude (differential J2
   across the formation; the relativistic orbit-dynamics acceleration). Corrected below.

---

## Re-verified existing features

### Two-body + J2 acceleration
- **Code**: `+models/+orbit/OrbitDynamics.m:31-51`. Two-body `a = -(mu/r^3)*r_i_m(:)` (line 35).
  J2 (lines 48-50):
  `fac = -1.5*J2*mu*Re^2/r^5; zr2 = (z/r)^2; a = fac*[(1-5*zr2)*x; (1-5*zr2)*y; (3-5*zr2)*z]`.
- **Status vs doc**: STILL-VALID (line numbers identical, file unchanged since `3489075`).
- **Verdict**: correct — the factorisation expands term-by-term to the standard C₂,₀ Cartesian
  gradient including the asymmetric `(3−5z²/r²)` z-component.
- **Sources**: Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and
  applications*. Springer. Table 3.3 header: "JGM-3 normalized gravitational coefficients up to
  degree and order 20, in units of 10⁻⁶ (GM⊕ = 398 600.4415 km³s⁻², R⊕ = 6378.13630 km) (Tapley et
  al. 1996)" (p. 64); table entry "2 0 −484.165368" (p. 64).
  Vallado, D. A. (2013). *Fundamentals of astrodynamics and applications* (4th ed.), Eq. 8-30
  [EXTERNAL — explicit Cartesian J2 components].
- **Critical analysis**: Re-derived independently: `fac·(1−5(z/r)²)·x` = −(3/2)J₂(μ/r²)(Rₑ/r)²(x/r)(1−5(z/r)²).
  Magnitude at GEO (r = 42 164 137 m, z = 0): |a_J2| = 1.5·J2·μ·Rₑ²/r⁴ = **8.3315e-6 m/s²**,
  confirming the file header's "~8.5e-6". The `Re` used is the WGS-84 semi-major axis 6 378 137.0 m,
  while JGM-3 defines its C̄₂,₀ against R⊕ = 6 378 136.30 m. Because the physical quantity is the
  product J₂·Rₑ², using the 0.70 m larger radius overstates the J2 acceleration by
  2·(0.70/6 378 136.3) = 2.20e-7 relative → **δa = 1.83e-12 m/s²**, i.e. 12 µm of free drift over
  3600 s, and it enters truth and EKF identically so it cancels. Correct to declare negligible;
  worth one code comment. Higher zonals and the J₂,₂ tesseral that actually drives GEO longitudinal
  drift remain absent (`OrbitPropagator.m:13-16`) — shared by truth and EKF, so it is a realism gap,
  not a mismatch.

### Physical constants (GM, Rₑ, J2, ω_E, and the "(EGM2008)" mislabel)
- **Code**: `+revgnss/Constants.m:14-23`:
  `EARTH_GM_M3PS2 = 3.986004418e14`, `EARTH_RADIUS_M = 6378137.0`,
  `EARTH_OMEGA_RADPS = 7.2921150e-5`, `EARTH_J2 = 1.08262668e-3` with the line-22 comment
  `% Earth J2 zonal-harmonic coefficient (EGM2008)`. Re-exported at `config/masterConfig.m:2482-2486`
  and `2513-2514` (doc cited 2073-2091 → **DRIFTED**).
- **Status vs doc**: STILL-VALID for the values and for the mislabel; DRIFTED for the masterConfig
  re-export line numbers.
- **Verdict**: correct values, single-sourced; the J2 provenance comment is wrong.
- **Sources**: Montenbruck & Gill (2000), back-matter constants table (p. 377): "GM 398 600.4415
  km³/s² JGM-3"; "R 6378.137 km WGS-84 (NIMA 1997)"; "0.7292115·10⁻⁴ rad/s Moritz 1980";
  "1.32712440018·10¹¹ km³/s² DE405 (Standish 1998)"; "4 902.801 km³/s² DE405"; "4.560·10⁻⁶ N/m²
  IERS 1996 (McCarthy 1996)". Also (p. 191): "ω⊕ = d(GAST)/dt ≈ 1.002737909350795 · 2π/86400 s =
  7.2921158553·10⁻⁵ s⁻¹". Appendix Table A.3 (p. 353 region, printed): "ω⊕ 7.2921151467·10⁻⁵ s⁻¹
  WGS84 Earth rotation rate".
- **Critical analysis**:
  - **J2 digit check (redone)**: √5 × 484.165368e-6 = 2.2360679775 × 484.165368e-6. Long-hand:
    484.165368×2 = 968.330736; 484.165368×0.2360679775 = 114.295940; sum = **1082.626676e-6**
    → 1.08262668e-3. **Digit-exact** against M&G's JGM-3 C̄₂,₀. EGM2008's tide-free C̄₂,₀ =
    −484.16514379e-6 gives J2 = 1.08262618e-3 — differs in the 7th significant figure, so the
    "(EGM2008)" comment is a **mislabel with zero numerical consequence** (δa_J2 = 3.9e-12 m/s²).
    Still worth fixing because it is the only provenance statement a reader gets.
  - **ω_E**: 7.2921150e-5 is now sourceable *directly* to M&G p. 377 ("0.7292115·10⁻⁴ rad/s, Moritz
    1980") — a stronger citation than "WGS-84 nominal". Re-verified the doc's drift numbers:
    against the IERS ERA rate 7.292115146706979e-5 the difference is 1.46707e-12 rad/s →
    1.46707e-12 × 42 164 137 m = 6.186e-5 m/s → **5.35 m/day**; against the GMST rate
    7.2921158553e-5 the difference is 8.553e-12 rad/s → **31.2 m/day**. Both doc figures confirmed.
    Pure absolute-frame realism offset; zero truth-model mismatch.
  - **GM/Rₑ**: WGS-84 rather than M&G's JGM-3 (398600.4415 vs .4418 km³/s²; 6378136.30 vs 6378137.0 m).
    Fractional differences 7.5e-10 and 1.1e-7; using WGS-84 keeps gravity consistent with the WGS-84
    geodetic conversion in `GeometryUtils`. Fine, and now cross-checked against p. 377.

### Luni-solar third-body acceleration
- **Code**: `+models/+orbit/OrbitPerturbations.m:140-144`:
  `d = r_body - r_sat; a = GM*(d/norm(d)^3 - r_body/norm(r_body)^3)`. Constants lines 20-21:
  `GM_SUN = 1.32712440018e20`, `GM_MOON = 4.9028e12`. Truth-only, gated, default OFF (lines 2-9, 46-61).
- **Status vs doc**: STILL-VALID (line numbers identical).
- **Verdict**: correct — literal M&G Eq. (3.37), direct attraction minus the indirect acceleration
  of the Earth itself.
- **Sources**: Montenbruck & Gill (2000): "Both values have to be subtracted to obtain the second
  derivative" (p. 69, immediately preceding Eq. 3.37); the equation itself is
  "r̈ = GM · ((s−r)/|s−r|³ − s/|s|³)" (Eq. 3.37, p. 69). Constants from the p. 377 table quoted above.
- **Critical analysis**: Recomputed the tidal (differential) magnitudes at GEO with the code's own
  constants: **Moon 7.28e-6 m/s²**, **Sun 3.34e-6 m/s²** (2GM·r_sat/d³). Header claim "~7e-6 …
  comparable to J2's ~8.5e-6" confirmed. GM_moon = 4.9028e12 rounds M&G's DE405 4 902.801 km³/s² at
  5 s.f. (2e-7 relative); GM_sun is digit-exact DE405. Omitting the indirect term is the classic
  error here and is **not** made.

### Sun/Moon ephemeris — M&G analytic series and DE-440
- **Code**: `OrbitPerturbations.m:87-134`. Sun (95-97): `M = 357.5256 + 35999.049*T`,
  `lam = 282.9400 + M + (6892/3600)*sind(M) + (72/3600)*sind(2*M)`,
  `rm = (149.619 - 2.499*cosd(M) - 0.021*cosd(2*M))*1e9`; obliquity `23.43929111 - 0.0130042*T`
  (lines 98, 131). Moon arguments 111-115, 14-term longitude 117-120, 8-term latitude 123-125,
  9-term distance 128-130. `De440Ephemeris.m:27-45` — real JPL DE-440 through the Orekit bridge.
- **Status vs doc**: STILL-VALID (all line numbers identical); analysis EXTENDED with a quantified
  consequence the doc left qualitative.
- **Verdict**: correct within the model's advertised class; two documented-class truncations, one of
  which is larger in metres than the doc implied.
- **Sources**: Montenbruck & Gill (2000): "λ⊙ = Ω + ω + M + 6892″ sin M + 72″ sin 2M" and
  "r⊙ = (149.619 − 2.499 cos M − 0.021 cos 2M) · 10⁶ km" (Eq. 3.43, p. 71); "L0 = 218°.31617 +
  481267°.88088 · T − 1°.3972 · T" (Eq. 3.47, p. 72); "βM = 18520″ sin(F + λM − L0 + 412″ · sin 2F +
  541″ · sin l′)" (Eq. 3.49, p. 72); "rM = (385 000 − 20 905 cos(l) − 3 699 cos(2D−l) …) km"
  (Eq. 3.50, p. 72); accuracy class "a typical accuracy of several arcminutes and about 500 km in
  the lunar distance" (p. 72); precession note "one has to add a correction of 1°.3972 · Teqx"
  (p. 71). All extracted verbatim from the PDF text layer and matched character by character against
  the code's numerals.
- **Critical analysis**: Every coefficient re-checked against the extracted source. Sun: all five
  numbers exact. Moon longitude: all fourteen sine amplitudes (22640, 769, −4586, +2370, −668, −412,
  −212, −206, +192, −165, +148, −125, −110, −55) exact and in the same argument pairings; latitude
  eight terms exact; distance nine terms exact (M&G note "terms smaller than 150 km have been
  neglected", p. 72 — the code stops at −152 km, exactly M&G's own cut).
  **Truncation (a), quantified — this is the correction to the round-1 doc.** `moonPositionEci`
  line 111 is `L0 = 218.31617 + 481267.88088*T`, **omitting M&G's −1.3972·T**. At the shipped
  `epochJD_TT = 2451545.0` (`masterConfig.m:1220`) the omission is 0.138″ after 24 h — negligible,
  as the doc said. But if a user moves the epoch to 2026 (T = 0.265), the lunar-longitude error is
  0.3703°, and I integrated the consequence rather than leaving it as an angle: rotating the Moon by
  0.3703° changes the third-body acceleration at GEO by **|δa| = 8.42e-8 m/s²**, i.e. free-drift
  **0.55 m over 1 h and 8.7 m over 4 h**. That is ~14× the "~0.6 m / 4 h luni-solar truth-fidelity
  gap vs DE-440" quoted at `masterConfig.m:1229-1231`, which was measured at T ≈ 0. The quoted gap
  is therefore **epoch-specific and not a property of the analytic model**; a 2026-epoch run would
  be dominated by this one missing term. It stays below the 1e-5 m/s² `modelMismatch` sigma so it
  cannot break the filter, but any claim of the form "the analytic ephemeris costs 0.6 m per 4 h"
  must be qualified with "at J2000".
  **Truncation (b)**: the latitude leading term is coded `18520*sind(F + dLam/3600)`, dropping the
  inner `+412″ sin 2F + 541″ sin l′` argument correction — ≤0.26° of argument, ≤85″ in β, inside
  M&G's own "several arcminutes" class.
  DE-440 path is a genuine reader (`CelestialBodyFactory.getSun()/getMoon()`, EME2000, TT epoch,
  `De440Ephemeris.m:19-21, 39-45`), lazily loaded and persistently cached, with clear errors for a
  missing JVM or bridge. Correctly declared as a prototype backend.

### Solar radiation pressure (cannonball + cylindrical shadow)
- **Code**: `OrbitPerturbations.m:22` `P_SRP_1AU = 4.56e-6`; line 19 `AU_M = 1.495978707e11`;
  `srpAccel_` (146-157): `d = r_sat - r_sun; P = P0*(AU/dist)^2; a = nu*Cr*(A/m)*P*(d/dist)`;
  `cylShadow_` (159-169) binary ν∈{0,1}; defaults Cr = 1.3, A/m = 0.02 (line 48).
- **Status vs doc**: STILL-VALID (line numbers identical).
- **Verdict**: correct — equivalent to M&G Eq. (3.75) with the correct 1-AU normalisation and sign;
  cylindrical shadow is a declared simplification.
- **Sources**: Montenbruck & Gill (2000): "P⊙ ≈ 4.56·10⁻⁶ Nm⁻²" (Eq. 3.69, p. 77);
  "r̈ = −P⊙ CR (A/m) (r⊙/r⊙³) AU²" (Eq. 3.75, p. 79); "CR = 1+ε" (Eq. 3.76, p. 79); "Equation (3.75)
  is commonly used in orbit determination programs with the option of estimating CR as a free
  parameter" (p. 79); "the half cone angle of the umbra is 0.264° and 0.269° for the penumbra"
  (p. 81); back-matter "4.560·10⁻⁶ N/m² IERS 1996 (McCarthy 1996)" (p. 377).
- **Critical analysis**: Sign verified (acceleration along Sun→satellite). Magnitude with defaults:
  4.56e-6 × 1.3 × 0.02 = **1.186e-7 m/s²**, matching the header's "~1e-7". The code uses the
  *satellite*-to-Sun distance where Eq. (3.75) uses the geocentric Sun distance — ≤2.8e-4 relative
  at GEO and the code's form is the more physical one. `AU_M = 1.495978707e11` is the IAU 2012
  defining value [EXTERNAL: International Astronomical Union (2012). *Resolution B2 on the
  re-definition of the astronomical unit of length*], 9 m larger than M&G's DE405 AU = 149 597 870.691
  km — 6e-11 relative, and SRP scales as AU², so 1.2e-10. Immaterial, and the modern value is the
  better one; the only nit is that the file cites M&G for the block while using a post-M&G constant.
  Cylindrical shadow drops the penumbra (~2 min per eclipse transit at GEO, in ~45-day equinox
  seasons); `shadow` is a config parameter so a conical upgrade has a seam.

### Numerical integrator (RK4 + step size)
- **Code**: `OrbitDynamics.m:63-96` — classical RK4 with `(dt/6)(k1+2k2+2k3+k4)`; the time-aware
  variant `rk4StepWithAccel` (79-96) evaluates the extra acceleration at each stage's absolute time
  (lines 89-92). `OrbitPropagator.m:204` truth substepping `nSub = max(1, ceil(dt/10))`.
- **Status vs doc**: DRIFTED — the code lines are unchanged, but the doc's "dt = 1 s,
  `masterConfig.m:35`" and the truth-cache reference `masterConfig.m:983-984` are now
  **`masterConfig.m:1210-1212`** (`cfg.orbit.truth.cache.enable/mode = 'precomputeVector'`).
- **Verdict**: correct — textbook-exact Butcher tableau; step sizes far inside the accuracy regime.
- **Sources**: Montenbruck & Gill (2000): "ΦRK4 = 1/6(k1 + 2k2 + 2k3 + k4)" (Eq. 4.7, p. 119);
  "k2 = f(t0 + h/2, y0 + hk1/2), k3 = f(t0 + h/2, y0 + hk2/2), k4 = f(t0 + h, y0 + hk3)"
  (Eq. 4.8, p. 119); "Its local truncation error … is bound by a term of order h⁵" (Eq. 4.9, p. 119).
- **Critical analysis**: Stage-by-stage match including the half-step time arguments in the
  time-aware variant — the classic bug of freezing a time-varying force at t₀ is avoided at lines
  90-92. Step-size adequacy re-derived: at h = 10 s and GEO ω = 7.292e-5, (ωh)⁵/120 ≈ 1.7e-18 per
  step × r = 4.2e7 m ≈ 7e-11 m/step, ~2.6e-8 m over a 3600 s arc. **Consequence worth stating**:
  `integrateAndRotate_` substeps *between consecutive requested times*, so a scalar call
  (`nSub = ceil(t/10)`, h = 10 s) and a 1-Hz vector call (h = 1 s) are **not bit-identical** —
  they differ at the ~26 nm level. `tests/test_orbit_truth_cache_equivalence.m` therefore has to be
  a tolerance test, not an equality test, and the "Science unchanged" comment at
  `masterConfig.m:1210-1211` is accurate to ~1e-8 m rather than exactly.

### State transition matrix (finite difference vs variational equations)
- **Code**: `+filter/EkfDynamicsPredictor.m:150-196` — 6×6 STM by central finite differences,
  ±1 m and ±1e-3 m/s (lines 167-168), configurable via `fdPositionStep_m` / `fdVelocityStep_mps`
  (169-173); analytic `[I dtI; 0 I]` for constant-velocity (line 162); SRP-scale column by a second
  FD pass with a deliberately large `ds = 10` (lines 198-218).
- **Status vs doc**: STILL-VALID (line numbers identical).
- **Verdict**: partially correct — numerically sound, but non-standard and the known performance
  bottleneck; M&G's variational equations are the documented upgrade path.
- **Sources**: Montenbruck & Gill (2000): "one … has to solve a special set of differential
  equations – the variational equations – by numerical methods" (Sect. 7.2, p. 240); "the concept of
  the variational equations offers the advantage that it is not limited to the computation of the
  state transition matrix, but may also be extended to the treatment of partial derivatives with
  respect to force model parameters" (p. 240); dΦ/dt = ∂f/∂y · Φ with Φ(t₀,t₀) = I₆ (Eqs. 7.41-7.42,
  p. 240).
- **Critical analysis**: The FD is taken in **ECEF**, with `propagateEcef` doing ECEF→inertial at t₀
  and inertial→ECEF at t₁, so the STM correctly includes the frame rotation for an ECEF state
  vector. Truncation error O(h²·∂³f) is negligible for smooth J2 over dt = 1 s, and the GEO
  round-off floor (4.2e7 × eps ≈ 1e-8 m) is four orders below the 1 m step. The `srpScale`
  passthrough (lines 154-155, 182-183, 191-192) keeps the STM about the *same* dynamics as the
  prediction. The `ds = 10` trick is exact because SRP is exactly linear in Cr and it lifts the
  difference above the round-off floor — clever and justified. Cost: 12 extra propagations per step.

### Clohessy–Wiltshire helix formation — **NOW-WRONG at the shipped default**
- **Code**: `+revgnss/SwarmFormation.m:84-99` (`helixOffsetHill`):
  `dr_hill = [(rho/2)*sin(ph); rho*cos(ph); crossAmp*rho*sin(ph)]`,
  `dv_hill = [(rho/2)*n*cos(ph); -rho*n*sin(ph); crossAmp*rho*n*cos(ph)]`.
  `crossAmp_` (101-112): `ca = 1 + s*(2*(i-1)/max(nSec-1,1) - 1)` with
  `s = cfg.formation.crossTrackSpread`, **absent → 0**.
  Hill basis lines 138-141 / 185-189; rotating→inertial `dv_eci = A*(dv_h + cross(omega, dr_h))`
  (lines 148, 199); ICs then propagated with the full J2 truth dynamics (line 202).
  Class header lines 8-10 claim separation "stays in [baseline, 1.118*baseline] (bounded, never
  below the configured minimum)". Guard at lines 176-179 warns only when `baseline < 500`.
  **Shipped default**: `config/masterConfig.m:1271` `cfg.formation.crossTrackSpread = 1.0`
  (and `config/golden_baseline_multi.json:28` sets it explicitly, calling it "REQUIRED, not
  cosmetic").
- **Status vs doc**: **NOW-WRONG** on the boundedness sub-claim; the CW-solution verification itself
  is STILL-VALID.
- **Verdict**: the CW dynamics are correct; the class's *boundedness documentation* and the 500 m
  guard are wrong for the configuration the project actually ships.
- **Sources**: Clohessy, W. H., & Wiltshire, R. S. (1960). Terminal guidance system for satellite
  rendezvous. *Journal of the Aerospace Sciences, 27*(9), 653–658 [EXTERNAL — ẍ−2nẏ−3n²x = 0,
  ÿ+2nẋ = 0, z̈+n²z = 0]. Sabol, C., Burns, R., & McLaughlin, C. A. (2001). Satellite formation
  flying design and evolution. *Journal of Spacecraft and Rockets, 38*(2), 270–278 [EXTERNAL —
  projected-circular orbit].
- **Critical analysis**:
  - **CW substitution re-done**: x-equation gives (−½ + 2 − 3/2)ρn² sin = 0 ✓; y-equation
    (−1 + 1)ρn² cos = 0 ✓; z-equation trivial for any `crossAmp` ✓. No-drift condition
    ẏ(0) = −ρn sin φ = −2n·(ρ/2) sin φ = −2n x(0) ✓, so the secular term −(6nx₀+3ẏ₀)t vanishes
    identically. **All of this is right and unchanged.**
  - **The bound, re-derived with `crossAmp`**:
    |Δr|² = ρ²[(¼ + ca²) sin²(nt+φ) + cos²(nt+φ)]. Only for ca = 1 does this collapse to
    ρ²[1 + ¼sin²] ∈ [ρ², 1.25ρ²], i.e. the doc's [1, √1.25] = [1, 1.11803]. For **ca ≠ 1** the
    envelope is [min(1, √(¼+ca²)), max(1, √(¼+ca²))]·ρ, so it **drops below the baseline whenever
    ca < √0.75 = 0.866**, i.e. whenever `crossTrackSpread > 0.134` for the first member.
  - **Numbers at the shipped default — MEASURED, not derived.** I ran
    `revgnss.SwarmFormation.buildSecondaryCaches` against the real `j2Rk4` propagated truth
    (`matlab -batch`, GEO chief, nSec = 5, `baseline_m` = 1000, `crossTrackSpread` = 1.0,
    `phase0_rad` = 0, 10 s sampling). The measured envelope matches my closed-form CW re-derivation
    to the metre at every horizon:

    | horizon | chief-sep min | max | per-member min | per-member max |
    |---|---|---|---|---|
    | 3600 s (headline arc) | **708.0 m** | **1984.9 m** | 974, 708, 1016, 1232, 1812 | 1000, 740, 1042, 1381, 1985 |
    | 14 400 s (4 h) | **660.0 m** | **1984.9 m** | 660, 707, 1000, 1232, 1066 | 1000, 852, 1042, 1581, 1985 |
    | full orbit (86 164 s) | **500.0 m** | **2061.5 m** | 500, 707, 1000, 1000, 1000 | 1000, 1000, 1118, 1581, 2062 |

    Chief-to-member separations at t = 0 are **1000, 740, 1042, 1232, 1985 m** — the "1 km ring" is
    really a **0.74–1.99 km** spread, a factor 2.7. Measured minimum *pairwise* separation at t = 0
    is **964.2 m** (max 2835.8 m), not the 1176 m the `masterConfig.m:1249-1251` comment computes
    from 2ρ sin(π/nSec): that chord formula is the **projected** (along/cross-plane) chord for the
    planar ca = 1 case; including the radial term gives 1268 m at ca = 1, and the shipped ca-fan
    gives 964 m.
  - **The 500 m guard does not guard.** `SwarmFormation.m:176-179` fires only when
    `baseline_m < 500`, but at the shipped default the *actual* minimum separation is
    ≈ baseline/2 over a full orbit. A user setting `baseline_m = 800` (no warning) gets a 400 m
    minimum separation, below the stated target, silently.
  - **The test that guards the bound cannot fail — executed both ways to confirm.**
    `tests/test_swarm_formation.m:33` builds
    `cfg.formation = struct('mode','helix','baseline_m',1000,'phase0_rad',0)` — **no
    `crossTrackSpread`**. `crossAmp_` reads a missing field as `s = 0` → ca = 1 for every member.
    I ran the test's exact T2 configuration through `buildSecondaryCaches` (12 h, nSpaceAssets = 4)
    with the field absent, with `crossTrackSpread = 0`, and with the shipped `crossTrackSpread = 1.0`:

    | `cfg.formation.crossTrackSpread` | min sep | max sep | `min>=500` | `min>=0.99·base` | `max<=1.13·base` |
    |---|---|---|---|---|---|
    | field absent (what the test builds) | 1000.00 m | 1118.02 m | PASS | PASS | PASS |
    | 0.0 (explicit) | 1000.00 m | 1118.02 m | PASS | PASS | PASS |
    | **1.0 (shipped default)** | **500.05 m** | **2061.51 m** | PASS (by 5 cm) | **FAIL** | **FAIL** |

    The measured 1118.02 m in the absent/zero rows is √1.25 × 1000 to five figures, independently
    confirming the doc's round-1 bound *for that configuration*. At the shipped default two of the
    three assertions fail, and the third survives by 5 cm. The test protects a configuration the
    product does not ship. This is the same trap `masterConfig.m:1264-1269` records having already
    been hit once ("Absence therefore meant 3-D in the federated path and PLANAR in the single-EKF
    path"); the fix landed in the config, not in this test.
  - **Differential J2 — correcting a round-1 number, then measuring it.** The doc states "the
    *differential* J2 across a 1 km formation at 42 164 km is ~1e-12 m/s²-scale". That is the
    **gradient** ∂a_J2/∂r ≈ 4·a_J2/r = 7.9e-13 **s⁻²**, not an acceleration. Multiplied by the 1 km
    separation the differential acceleration is **≈ 7.9e-10 m/s²** — three orders larger than
    stated, with a ½at² free-drift *bound* of 5.1 mm over 3600 s and ≈0.74 m over 12 h. The
    **measured** departure of the J2-propagated truth from the closed-form CW solution is far
    smaller than that bound because most of the differential force is periodic, not secular: over
    12 h the propagated minimum separation is 500.05 m against the CW analytic 500.00 m, i.e.
    **5 cm of deviation**, and the propagated maximum 2061.51 m against the analytic 2061.55 m.
    So the helix is bounded and the code's decision to re-propagate truthfully rather than trust the
    CW closed form is validated; only the doc's magnitude needs correcting. Note also that
    `test_swarm_formation` T2's drift check compares t = 0 with t = 43 200 s ≈ T/2 = 43 082 s —
    half a period apart, where the CW periodic part returns to its starting value — so
    `abs(sep0−sepEnd) < 10 m` is structurally weak as a secular-drift test.
  - `OrbitFrame.ecefToRacGeo`'s `v_eff = v_ecef + ω×r` (lines 48-71) is still the correct inertial-
    velocity restoration for the degenerate GEO ECEF velocity. STILL-VALID.

### Earth orientation / ECI–ECEF transformation
- **Code**: `+models/+frames/FrameTimeUtils.m:24-98` — `rotMatEcefToInertial` = R3(+θ) with
  θ = ω·t (lines 34-41); state transforms `v_i = R(v_e + ω×r_e)` (72-80) and
  `v_e = R'v_i − ω×r_e` (82-90); `roundTripStateError` (92-98); limitations L1–L5 in the header
  (6-15). `OrbitPropagator.m:219-222` uses θ = `epochGMST_rad + ω·t`.
  `+models/+frames/TruthEarthOrientation.m` — truth EOP error (32-40), **model-side EOP correction
  (42-74)**, shared `displacementFor_` (76-81) with `phi = [-yp; -xp; omegaExtra*t]`.
- **Status vs doc**: DRIFTED (the truth displacement is now at 32-40 with the algebra factored into
  `displacementFor_` at 76-81) **plus NEW** (`modelConfigFrom` / `towerDisplacementModel`, lines
  42-74, were never traced).
- **Verdict**: correct within a declared simplification; the polar-motion sign convention is right;
  the model-side counterpart is a legitimate published-data correction, not truth assistance.
- **Sources**: Montenbruck & Gill (2000), full ICRS↔ITRS chain U = Π·Θ·N·P (Ch. 5); "ω⊕ = d(GAST)/dt
  ≈ 1.002737909350795 · 2π/86400 s = 7.2921158553·10⁻⁵ s⁻¹" (Eq. 5.92 region, p. 191).
  Petit, G., & Luzum, B. (Eds.). (2010). *IERS Conventions (2010)* (IERS Technical Note No. 36),
  Ch. 5, polar-motion matrix W(t) = R₃(−s′)·R₂(x_p)·R₁(y_p) [EXTERNAL; cited in-code at
  `TruthEarthOrientation.m:13`].
- **Critical analysis**: **Sign re-derived from scratch.** With the IERS frame-rotation convention
  Rᵢ(θ) ≈ I − θ·skew(eᵢ), W = R₃(−s′)R₂(x_p)R₁(y_p) ≈ I − skew([y_p; x_p; −s′]), so
  W·r − r = [−y_p; −x_p; s′] × r. The code's `phi = [-yp; -xp; omegaExtra*t]` matches term for
  term, with the third component replaced by an accumulated ERA/UT1 spin error instead of s′.
  **Correct.** The ms/day → rad/s mapping (`w * (msPerDay*1e-3/86400)`, lines 27 and 53) is
  dimensionally verified. `towerDisplacementModel` uses the *same* `displacementFor_`, so setting
  `cfg.frames.eopModel = cfg.frames.truthEop` cancels the residual exactly and offsetting it by the
  IERS uncertainty leaves the realistic residual — the pattern is sound and is the one
  `RelativisticClockCorrection` explicitly imitates.
  **NEW latent defect**: `FrameTimeUtils` has **no `epochGMST` concept at all** (θ = ω·t), while
  `OrbitPropagator` uses θ = `epochGMST_rad + ω·t`. At the shipped `cfg.orbit.epochGMST_rad = 0`
  (`masterConfig.m:730`) this is inert. If it is ever set non-zero, the two "inertial" frames differ
  by a constant z-rotation. Two-body and J2 are both invariant under a z-rotation, so the EKF
  propagation stays *correct* — but anything that mixes the two frames with a Sun/Moon direction
  breaks: the EKF's optional luni-solar/SRP path (`EkfDynamicsPredictor.m:120-123`) would place the
  Sun at the truth's ECI longitude while the satellite sits rotated by −GMST₀, and
  `SolidEarthTide.eci2ecef_` (lines 53-58) would mis-phase the tide by the same angle. Inert today,
  a silent trap tomorrow.

### Solid Earth tide
- **Code**: `+models/+frames/SolidEarthTide.m:26-48`, formula at **43-46**:
  `cphi = dot(rh,Rbh); fac = (GM_b/GM_E)*(Re^4/Rbn^3);`
  `dr += fac*(h2*rh*(1.5*cphi^2 - 0.5) + 3*l2*cphi*(Rbh - cphi*rh))`.
  Nominal `h2 = 0.6078`, `l2 = 0.0847` (line 16). Truth-only, gated
  (`cfg.effects.solidEarthTide.truth.enable`), default OFF.
- **Status vs doc**: DRIFTED (doc cited 15-48 and "43-47"; the formula is at 43-46, `configFrom` at
  15-24). Verdict unchanged.
- **Verdict**: correct — a term-by-term match with the IERS-2010 degree-2 in-phase formula and
  the nominal Love/Shida numbers.
- **Sources**: Petit & Luzum (2010), *IERS Conventions (2010)*, Ch. 7, Eq. (7.5):
  Δr = Σⱼ [GMⱼRₑ⁴/(GM⊕Rⱼ³)]·{h₂ r̂ (3(R̂ⱼ·r̂)²−1)/2 + 3l₂ (R̂ⱼ·r̂)[R̂ⱼ −(R̂ⱼ·r̂)r̂]}, with nominal
  degree-2 h₂ = 0.6078, l₂ = 0.0847 (Sect. 7.1.1) [EXTERNAL].
- **Critical analysis**: (3cφ²−1)/2 = 1.5cφ²−0.5 ✓; the transverse projection 3l₂cφ(R̂−cφr̂) ✓;
  the amplitude factor ✓. Omitted (honestly, per the header "in-phase term"): degree-3, latitude
  dependence of the effective Love numbers, out-of-phase/anelastic terms, frequency-dependent
  corrections, and the permanent-tide convention — all sub-cm against a ~10–30 cm modelled signal.
  **Two NEW notes.** (i) Lines 37-38 hard-code a **second copy** of `GM_SUN = 1.32712440018e20` and
  `GM_MOON = 4.9028e12` (the originals are `private Constant` properties of `OrbitPerturbations`,
  so they cannot be reused). Values currently agree digit for digit; it is a divergence site, not a
  present defect. (ii) Lines 37-38 call `sunPositionEci(jd)` / `moonPositionEci(jd)` with **one
  argument**, so the tide always uses the M&G analytic series **even when
  `cfg.perturbations.sunMoon.ephemeris = 'de440'`**. A run that pays for DE-440 in the force model
  silently keeps the analytic ephemeris in the tide. Consequence: sub-mm on a 10–30 cm tide
  (the analytic Sun/Moon direction is good to arcminutes; 3′ of direction on a 20 cm tide is
  ≲0.2 mm), so it is a consistency wart rather than an accuracy problem — but it should be
  either wired or documented. (iii) The doc's caveat that `eci2ecef_` ignores `epochGMST_rad`
  is STILL-VALID and is now shown to be systemic (see Earth orientation above).

### Relativistic orbital clock terms — **SUPERSEDED**
- **Code**: `+revgnss/Relativity.m:27-69` — unchanged:
  `grav = (GM/c^2)*(1/Re - 1/r_m); sr = -v^2/(2c^2); y = grav + sr [+ (omega*Re)^2/(2c^2)]`,
  circular inertial speed `v = sqrt(GM/r)` (line 52).
  **NEW**: `+models/+clocks/RelativisticClockCorrection.m` (81 lines) — the estimator-side applier:
  `fracFreq` (36-63) reads `cfg.physics.relativity.clock.model.enable`, prefers an explicit
  `…model.fracFreq`, else falls back to `revgnss.Relativity.geoClockFracFreq(cfg.orbit.altitudeMean_m)`;
  `bias_m = c*y*t_s` (65-70); `rate_mps = c*y` (72-77).
  Truth side: `ConfigFactory.m:1972-1983` writes `cfg.asset.clock.relativisticFracFreq`;
  `ClockModel.m:335` adds it to the phase increment and `ClockModel.m:388` now includes it in
  `getFractionalFrequency`; `ClockModel.m:419-427` adds oscillator-only accessors.
  Model side resolution: `ConfigFactory.m:1985-2007`. Consumers:
  `CodeMeasurementBuilder.m:73`, `CarrierMeasurementBuilder.m:72-73`,
  `DopplerMeasurementBuilder.m:138-139`, `ISLMeasurementBuilder.m:179-180`,
  `TwoWayTimeTransferBuilder.m:161-167, 359-367`, `PseudorangeModelOnlyBuilder.m:41-47`,
  `CarrierModelOnlyBuilder.m:51-55`, `SimulationDataStore` (report-domain restoration).
  Gates: `masterConfig.m:2533-2539` all default false; `realismGradeConfig.m:146-148` turns them on.
- **Status vs doc**: **SUPERSEDED** — the doc traced only `Relativity.m` and described the term as
  a passive constant. It is now a wired, gated truth/model pair with a documented 13.1 m → 1.2 m
  filter consequence (`git show 3ece3b8`).
- **Verdict**: correct, and the guard against double counting is the right one — but the identity
  the guard rests on is not realised for ground endpoints (DC-1).
- **Sources**: Kaplan, E. D., & Hegarty, C. J. (Eds.). (2006). *Understanding GPS: Principles and
  applications* (2nd ed.). Artech House: "the satellite clock frequency is adjusted to
  10.22999999543 MHz prior to launch" (p. 306); "Exactly half of the periodic effect is caused by
  the periodic change in the speed of the satellite relative to the ECI frame and half is caused by
  the satellite's periodic change in its gravitational potential" (p. 306);
  "F = −4.442807633 × 10⁻¹⁰ s/m^½" (Eq. 7.4, p. 306). Montenbruck & Gill (2000), relativistic time
  scales Sect. 5.1.3 (pp. 163-165) and the relativistic orbit correction Sect. 3.7.3 (p. 110).
- **Critical analysis**:
  - **Numbers re-derived from the code's own constants** at alt = 35 786 km (r = 42 164 137 m,
    v = 3074.661 m/s): grav = **+5.901637e-10**, SR = **−5.259242e-11**, ground rotation
    = **+1.203437e-12**, total **y = 5.3877468e-10** = **46.550 µs/day**; c·y = **0.1615206 m/s**;
    c·y·3600 = **581.474 m**. Every figure quoted in `Relativity.m:20-22`,
    `RelativisticClockCorrection.m:5-7`, and commit `3ece3b8` reproduces exactly.
  - **The eccentricity term** is genuinely zero here: −2(r·v)/c² is the instantaneous form of
    Kaplan Eq. (7.4) F·e·√a·sin Eₖ and r·v ≡ 0 on a circular orbit. The truth orbit is J2-perturbed,
    not exactly circular; the J2-induced |r·v| at GEO is ~1e-2 m²/s-scale, giving a periodic clock
    term ≲1e-19 — still nothing.
  - **The oscillator/total split is exactly right, and I verified its identity numerically**:
    properTimeRate(r_sat, v_sat) − properTimeRate(Rₑ, v_ground)
    = (1 − 1.5777724e-10) − (1 − 6.9655193e-10) = **5.3877469e-10**, equal to
    `Relativity.clockFracFreq` to 1e-17. `ClockModel.m:404-417` states this identity and it is true.
  - **Is there a double count?** On the ground↔space one-way channels, **no**: the truth clock
    carries y_rel in both phase and rate (`ClockModel.m:335, 388`), the model applies the same
    published constant on both (`…bias_m` for code/carrier, `…rate_mps` for Doppler), and it cancels
    in z − h. On the two-way/four-timestamp channels, **no** for satellite endpoints, because
    `localClockRate` deliberately uses `getOscillatorDriftMetersPerSecond` while `properTimeRate`
    carries the relativistic rate. But see **DC-1** for the ground endpoint.
  - **Inverse-crime note**: `ConfigFactory` derives the model-side `fracFreq` from the *same*
    `geoClockFracFreq(cfg.orbit.altitudeMean_m)` call as the truth side, so the relativistic
    residual in z − h is **identically zero by construction** unless a scenario writes an explicit
    `…model.fracFreq`. That is defensible (y_rel is a published constant), the mechanism to inject a
    residual exists and is documented (`ConfigFactory.m:1985-1991`), and no shipped scenario uses
    it — so no run in the repo currently carries a relativistic model error. That is a **limit**,
    not a bug.
  - **Correcting a round-1 number**: the doc says the omitted relativistic *orbit-dynamics*
    correction (M&G Sect. 3.7.3) is "~1e-9 m/s² scale". Re-derived: the Schwarzschild term
    a = (GM/c²r²)[(4GM/r − v²)r̂ + 4(r·v)v/r] gives at GEO
    (3.986e14/(c²·r²))·(3.7817e7 − 9.4535e6) = **7.08e-11 m/s²**, ~14× smaller than stated
    (0.46 mm of free drift over 3600 s). Conclusion unchanged — absent and negligible — but the
    magnitude should be corrected.
  - Ground-clock potential uses point-mass GM/Rₑ rather than the geoid W₀ (J2 contributes ≈3.8e-13
    fractional); constant, absorbed by the clock-drift state. Honest.

### Truth vs EKF force-model separation — **DRIFTED, and the auto-tuner claim is NOW-WRONG**
- **Code**: `config/masterConfig.m:723-738` (doc cited 568-580) — "Truth and EKF share the J2 family
  (not a mismatch)" (line 724), truth `j2Rk4` (734), EKF `dynamics.mode = 'j2'` (737),
  `cfg.validation.enforceModelFamilyConsistency = true` (738). Base defaults at
  `masterConfig.m:1205-1208` (doc cited 977-979) set `stationaryEcef`, and the headline block
  (which runs *after* `i_baseDefaults()`, called at line 24) upgrades to `j2Rk4`.
  `config/internal/applyLuniSolar.m:11-24` — truth gains Sun/Moon+SRP (17-18), EKF explicitly kept
  without them (19-20), `modelMismatch.sigma_mps2 = 1e-5` (16).
  `config/internal/realismGradeConfig.m:136-143` + `403` — the *same* 1e-5 via a second leaf.
  `+revgnss/ConfigFactory.m:2348-2359` — the J2 auto-tuner. `GeoRealWorldScenarioGuard.m:113-138`
  + `204-214` — the family guard.
- **Status vs doc**: DRIFTED on every line number; the "known config-order defect" cross-reference
  is **NOW-WRONG**.
- **Verdict**: correct and well guarded; the sigma is correctly sized in magnitude but wrong in
  colour; the family guard is narrower than its docstring claims.
- **Sources**: Montenbruck & Gill (2000), Ch. 7-8 force-model/consider framing; the perturbation
  magnitudes verified above (7.28e-6 + 3.34e-6 + 1.19e-7 = **1.07e-5 m/s²**).
- **Critical analysis**:
  - **The auto-tuner cannot fire at any shipped configuration.** `ConfigFactory.m:2348` requires
    `isJ2Truth82_ && isTwoBodyEkf82_`; the shipped EKF mode is `'j2'`, so `isTwoBodyEkf82_` is
    false and the branch is skipped entirely. Even inside the branch, line 2357 overwrites only when
    `sigma_mps2 <= 1e-6` — exactly the untouched masterConfig default (line 2057) — while
    `applyLuniSolar` and `realismGradeConfig` both write 1e-5. **Double-guarded.** The doc's claim
    that it "can quietly invalidate regime (2)'s noise sizing" should be withdrawn. What remains
    true, and is worth one sentence: the overwrite is **silent** (no warning at 2356-2359), so a
    user who *deliberately* configures a smaller sigma (say 5e-7) in a two-body-EKF run gets it
    raised to `0.25·|a_J2| = 2.083e-6 m/s²` with no notice. **No warning was added.**
  - **The process-noise consistency audit measures the wrong thing.** Lines 2380-2387 compare
    `sigma_accel_mps2` against `0.1·|a_J2|` **unconditionally**, but that rule only makes sense in
    the j2-truth / two-body-EKF branch where J2 is unmodelled. Computed thresholds:
    GEO |a_J2| = 8.331e-6 → threshold 8.33e-7, shipped sigma 1e-6 → passes by 1.2×;
    MEO |a_J2| = 5.277e-5 → threshold 5.28e-6, `orbitClassConfig.m:47` ships 5e-6 → **fails, warning
    fires, `dynamicsProcessNoiseConsistency = 'marginalBelowThreshold'`**;
    LEO |a_J2| = 1.111e-2 → threshold 1.11e-3, `orbitClassConfig.m:55` ships 5e-5 → **fails by 22×**.
    Both failures are **spurious**: truth and EKF both propagate J2 in all three classes, so J2 is
    not an unmodelled force and the threshold is meaningless. The MEO and LEO rungs therefore ship
    tripping their own audit, and the GEO rung passes for the wrong reason.
  - **The family guard is blind to the perturbation gap.** `dynamicsFamily_`
    (`GeoRealWorldScenarioGuard.m:204-214`) maps only the mode *string* (`j2rk4`/`j2` → 'J2', etc.).
    `applyLuniSolar` leaves both strings at J2 while opening a 1.07e-5 m/s² truth-only force gap, so
    `assertModelFamilyConsistent` — whose docstring promises it "Errors when the truth dynamics
    family differs from the EKF dynamics family" — passes silently. That is arguably intended
    (`applyLuniSolar` is the *declared* stressor), but the guard's name and docstring overpromise.
  - **The sigma's magnitude is right; its colour is not.** 1e-5 m/s² matches my computed 1.07e-5
    total unmodelled acceleration, so the doc's "well-sized" holds **per step**. But a
    white-acceleration Q charges a *coherent*, 12-h/24-h-periodic luni-solar acceleration as white
    noise. Over a coast of duration t the deterministic offset is ½·a·t² while the SNC standard
    deviation is σ·√(t³/3); the ratio is 0.927·√t — they agree at t ≈ 1 s (the update interval,
    which is why the filter works) and diverge to **55× at t = 3600 s**. So the honest statement is
    "sized to the one-step white-equivalent, not a bound on the coherent drift"; any measurement
    outage longer than a few tens of seconds is not covered. This is the same class of finding as
    the project's existing "R's maths is right, its colour is wrong".

### Geodetic conversion and local frames (supporting)
- **Code**: `+models/+frames/GeometryUtils.m:6-62` — 5 fixed-point iterations
  `lat = atan2(z + e2*N*sin(lat), p)` (16-19), `alt = p/cos(lat) - N` (21); `enu2ecef` (49-56);
  `elevationAngle` (34-47). `Constants.m:26-29` `f = 1/298.257223563`, `e2 = 2f − f²`.
- **Status vs doc**: STILL-VALID (line numbers identical).
- **Verdict**: correct — standard WGS-84 machinery, converging to sub-mm in 5 iterations.
- **Sources**: National Imagery and Mapping Agency. (2000). *Department of Defense World Geodetic
  System 1984* (NIMA TR8350.2, 3rd ed.) [EXTERNAL — defining f = 1/298.257223563, a = 6 378 137 m].
  Montenbruck & Gill (2000), p. 377: "f 1/298.257223563 WGS-84 (NIMA 1997)".
- **Critical analysis**: `e² = 2f − f²` is definitionally exact. Naming nit STILL-VALID: the comment
  says "Bowring iteration" but the scheme is the plain geodetic fixed point (Bowring uses the
  parametric latitude). The elevation uses **geodetic** up from the converted latitude — correct;
  geocentric up would bias elevation by up to f/2 ≈ 11.5′ = **0.192°** at φ = 45°, confirming the
  doc's 0.19°. `alt = p/cos(lat) − N` degrades near the poles; the highest shipped tower is
  Kiruna at 67.88°N (`masterConfig.m:1897` region), so it is never exercised there.

### ECSS-E-ST-60-10C applicability
- **Code**: repo-wide grep for `ecss` over `*.m` and `*.json`, excluding worktrees: **zero hits**.
- **Status vs doc**: STILL-VALID.
- **Verdict**: not applicable to this section — the standard covers pointing/control performance
  indices (APE/MPE/RPE), not orbital force models.

---

## New / previously untraced features

### NEW-1 — `models.clocks.RelativisticClockCorrection` (estimator-side relativistic clock)
- **Code**: `+models/+clocks/RelativisticClockCorrection.m:36-77`.
  `fracFreq`: gate on `cfg.physics.relativity.clock.model.enable`; explicit
  `…model.fracFreq` wins; else `revgnss.Relativity.geoClockFracFreq(cfg.orbit.altitudeMean_m)`
  with a hard-coded 35 786 000 m fallback (line 60). `bias_m = c*y*t_s` (69);
  `rate_mps = c*y` (76). Everything returns exactly 0 when the gate is off.
- **Status vs doc**: NEW.
- **Verdict**: correct — a published-ephemeris correction, correctly gated, with the reference epoch
  argued explicitly (lines 29-32: `t_s = 0` at the first epoch, shared with the truth `ClockModel`).
- **Sources**: Kaplan & Hegarty (2006): "the satellite clock frequency is adjusted to
  10.22999999543 MHz prior to launch" (p. 306) — i.e. a real GNSS system applies exactly this
  constant on the *hardware* side, which is the operational precedent for applying it model-side.
- **Critical analysis**: The gating is genuinely byte-safe (`try/catch` → `y = 0` on any missing
  field). Two structural remarks. (i) The class is `+models/+clocks` but its physics comes entirely
  from `+revgnss/Relativity` — the split is correct (number vs applier) and worth keeping.
  (ii) The catch-all `try; alt_m = cfg.orbit.altitudeMean_m; catch; end` at line 61 silently falls
  back to a GEO altitude for a MEO/LEO run whose `cfg.orbit` is malformed; since `orbitClassConfig`
  always writes `altitudeMean_m` this is unreachable in practice, but a hard-coded 35 786 km inside
  a "safety net" branch in a class that also serves MEO/LEO deserves an assert rather than a
  default. The header calls it "the safety net" and notes ConfigFactory normally resolves it — true
  (`ConfigFactory.m:1994-2007`).

### NEW-2 — `properTimeRate_` exists in **four** independent copies
- **Code**: identical bodies `rate = 1 - (GM/radius + 0.5*dot(v,v))/c^2` at
  `+revgnss/TwoWayISLMeasurementBuilder.m:1576-1591`,
  `+revgnss/CoherentTwoWayRangeLinkUpdateAdapter.m:340-356`,
  `+revgnss/FourTimestampEstimatorEndpointBridge.m:178-196`,
  `+revgnss/ReciprocalEndpointTruthProvider.m:99-...`. Each is `Access = private` and each carries a
  comment acknowledging the duplication.
- **Status vs doc**: NEW.
- **Verdict**: correct formula, four times; the duplication is declared but is a divergence site.
- **Sources**: The first post-Newtonian coordinate→proper time rate dτ/dt = 1 − (U + v²/2)/c² is
  standard; Montenbruck & Gill (2000), Sect. 5.1.3 "Relativistic time scales" (pp. 163-165).
  Petit & Luzum (2010), *IERS Conventions (2010)*, Sect. 10.1 [EXTERNAL].
- **Critical analysis**: All four bodies are character-identical in the arithmetic, so there is no
  present divergence — I diffed them. Numerically at GEO the rate is 1 − 1.5778e-10; at the Earth's
  surface it would be 1 − 6.9655e-10. The formula is a **spherical-Earth** potential (`GM/r`), so it
  omits the J2 contribution to the potential (≈3.8e-13 fractional at the surface, ≈1e-16 at GEO) and
  the ground station's rotation velocity is supplied only through `ecefStateToInertial`. Fine at this
  fidelity. The real issue is not the formula but who is given one — see DC-1.

### NEW-3 — Model-side EOP correction (`TruthEarthOrientation.towerDisplacementModel`)
- **Code**: `+models/+frames/TruthEarthOrientation.m:42-56` (`modelConfigFrom`, reading
  `cfg.frames.eopModel`) and `58-74` (`towerDisplacementModel`), sharing `displacementFor_` (76-81)
  with the truth path. Default OFF.
- **Status vs doc**: NEW (present at doc time, untraced).
- **Verdict**: correct — the residual geometry error is exactly (φ_truth − φ_model) × r_tower, so
  matching the two leaves cancels it and offsetting by the IERS uncertainty leaves the realistic
  residual, as the docstring (65-67) claims.
- **Sources**: Petit & Luzum (2010), *IERS Conventions (2010)*, Ch. 5 [EXTERNAL] — polar motion is
  published to ~0.1 mas, so a real receiver genuinely has these values.
- **Critical analysis**: This is the architectural template `RelativisticClockCorrection` explicitly
  copies ("It has exactly the standing of `cfg.frames.eopModel`",
  `RelativisticClockCorrection.m:11-12`). Because truth and model share one algebra function, they
  cannot drift apart — the right design. Realism sizing: `realismGradeConfig.m:411` sets
  x_p = y_p = 0.005″, i.e. Rₑ·5e-3/206265 = **0.155 m** of tower displacement — a *residual after
  correction*, not the raw 0.3″ ≈ 9 m offset the class header uses as its motivating number. Both
  are correct in their own context; the header should say which one the shipped grade uses.

### NEW-4 — `orbitClassConfig` LEO network diverged from the golden tower set (`170e37d`)
- **Code**: `config/masterConfig.m:1896` now reads
  `'Libreville', 0.0355, 9.4496, 0.0; % 5 (frozen golden)` — commit `170e37d` flipped the sign.
  `config/internal/orbitClassConfig.m:97` still reads
  `'Libreville', 0.0355, -9.4496, 0.0; % 5 golden set`, under a block comment (lines 76-77) that
  promises "The first 5 sites match the frozen-golden network (continuity)".
- **Status vs doc**: NEW (introduced by the last commit).
- **Verdict**: flawed — a duplicated coordinate table where one copy was fixed and the other was not.
- **Sources**: Libreville, Gabon is at 0.39°N, **9.45°E** [EXTERNAL — standard gazetteer]; the
  masterConfig value is the corrected one, the orbitClassConfig value places the site in the Gulf of
  Guinea.
- **Critical analysis**: Δlon = 18.8992° at latitude 0.0355°N → the LEO "golden" tower 5 sits
  **2104 km** west of the real site, in open ocean. This is inert for GEO/MEO (both take the
  `case 'GEO'` strict no-op or leave `cfg.towers` alone), so no shipped headline result moves — but
  the file's own continuity claim is now false, and any LEO-vs-GEO comparison silently changes one
  of the five "common" stations. Two further problems in the same rebuild:
  (i) `orbitClassConfig.m:129` sets `towers(k).clock.deterministic = true` for all 20 rebuilt LEO
  towers, **reverting the project-wide switch to stochastic ground oscillators** — selecting
  `orbitClass = 'LEO'` silently turns the ground clock noise off, which is exactly the axis the
  clock campaign found dominant.
  (ii) The rebuilt towers get `hardwareDelay_m = 0` and `antennaOffset_enu_m = [0;0;0]`
  (lines 122-123), discarding whatever the template carried. Both are "rebuild loses configuration"
  bugs of the same family.

### NEW-5 — Light-time / Sagnac double-count guard (the one place a double count is *prevented*)
- **Code**: `+revgnss/ConfigFactory.m:1188-1215` — with `cfg.physics.lightTime.mode` =
  `'iterativeOneWay'`, it sets `cfg.effects.lightTime.model = 'iterative'`, force-disables
  `cfg.physics.sagnac.truth.enable` and `.model.enable` (lines 1207-1208), pushes a
  `cfg.validation.warnings` entry if Sagnac had been on (1203-1206), and records
  `doubleCountGuard = 'pass'`. Runtime backstop:
  `+models/+corrections/RangeCorrections.m:109` — `if ~strcmp(ltModel,'iterative') && … sagnac`.
  `+models/+frames/LightTimeSolver.m:82-100` iterative rotation.
- **Status vs doc**: NEW as a traced item (the doc's measurement section names the guard; the
  config-level half was not traced).
- **Verdict**: correct — belt and braces, and one of the strongest pieces of engineering in the
  frames layer.
- **Sources**: Kaplan & Hegarty (2006): "a relativistic error is introduced, known as the Sagnac
  effect, when computations for the satellite positions are made in an ECEF coordinate system"
  (p. 306) — the Sagnac term and an iterative Earth-rotation light-time solution model the *same*
  physics, hence the guard.
- **Critical analysis**: **Sign re-derived** for `LightTimeSolver.m:85-88`:
  `Rz = [cos dθ, sin dθ, 0; −sin dθ, cos dθ, 0; 0,0,1]` with dθ = ω·τ is R₃(+ωτ) in the
  frame-rotation sense = a backward *active* rotation of the tower, which is exactly
  R(t_rx)ᵀR(t_tx)·r_e — the tower's inertial position at transmit time expressed in the receive-time
  ECEF axes. **Correct.** Two nits: (i) on exit, `r_twr_at_tx` corresponds to the *previous*
  iteration's τ while `tau_s` is the new one — self-inconsistent by ω·|Δτ|·Rₑ ≈ 4.6e-10 m at the
  1e-12 s tolerance, i.e. irrelevant; (ii) exhausting `maxIter` without converging is silent (no
  warning), though 5 iterations is comfortably enough (τ ≈ 0.127 s, ωτ = 9.3e-6 rad, tower moves
  ~59 m, second-order correction ~5e-4 m).
  **Gate semantics**: a consequence of the guard is that `cfg.physics.sagnac.*.enable` is a
  **derived** field, not a knob, at the shipped default (`masterConfig.m:93` sets
  `mode = 'iterativeOneWay'`, and the headline block runs after `i_baseDefaults()` which set
  `'sagnacFirstOrder'` at line 2525). Any ablation rung that toggles Sagnac measures **nothing**.
  See LF-3.

### NEW-6 — `SwarmFormation` multi-ring layout and the `meta.mode` mislabel
- **Code**: `+revgnss/SwarmFormation.m:37-82` (`ringLayout_`): ring k has radius `k*spacing` and
  holds `nk = max(1, round(2*pi*k))` members, staggered by `mod(k,2)*pi/nk`.
  `buildSecondaryCaches` line **210**: `meta.mode = 'helix';` — hard-coded.
- **Status vs doc**: NEW (the doc mentioned `ringLayout_` exists; the arithmetic and the label bug
  were not traced).
- **Verdict**: the ring arithmetic is correct; the reported mode label is wrong.
- **Sources**: standard formation-flying practice; Sabol et al. (2001) [EXTERNAL].
- **Critical analysis**: Verified the constant-chord property: ring 1 (6 members, ρ = 1000 m) chord
  = 2·1000·sin(π/6) = **1000 m**; ring 2 (13 members, ρ = 2000 m) chord = 2·2000·sin(π/13) =
  **957 m**; ring 3 (19 members, ρ = 3000 m) chord = **987 m**. The header's "6, 13, 19" is right and
  the design does hold spacing ~constant. Two defects: (i) `meta.mode` is hard-coded to `'helix'`
  at line 210 regardless of the configured mode, so a `multiRingHelix` run is reported as `helix`
  in every downstream report that reads `meta.mode`; (ii) `crossAmp_` fans over the **global**
  member index, not per ring, so in `multiRingHelix` the cross-track amplitude is correlated with
  ring radius rather than being independent of it — harmless for observability but not what the
  docstring describes.

---

## Double-count candidates

**DC-1 — Ground endpoint has no proper-time rate, so the identity that licenses the
`getOscillatorDriftMetersPerSecond` split does not close.** *(cross-domain: shared with Time
Transfer; found while auditing item (f))*
- **Location A**: `+models/+clocks/ClockModel.m:404-417` — the guard's stated justification:
  "properTimeRate(r_sat,v_sat) − properTimeRate(Re,v_ground) = … = revgnss.Relativity.clockFracFreq
  == y_rel. An endpoint that already supplies properTimeRate is therefore ALREADY carrying y_rel;
  adding it again through localClockRate counts the same physics twice."
- **Location B**: `+revgnss/ReciprocalEndpointTruthProvider.m:65-77` (`fixedStation`) — the ground
  endpoint is constructed **without** `properTimeRate`, so it takes the default `1`
  (`TwoWayCodeEndpointModel.m:37`). Test-enforced at
  `tests/test_reciprocal_endpoint_truth_provider.m:94-95`: "fixedStation() must default
  properTimeRate to 1 (Section 4.2 does not model gravitational potential)".
- **Mechanism**: the identity holds only when the ground endpoint carries
  properTimeRate(Rₑ, v_ground) = 1 − 6.9655e-10. With the ground rate pinned at 1, the modelled
  sat-minus-ground proper-time-rate difference is **−1.5778e-10** instead of **+5.3877e-10** — the
  wrong sign and wrong magnitude, short by **6.9655e-10** (c·δ = **0.2088 m/s**).
- **Size**: `properTimeRate` is consumed **only** by
  `TwoWayCodeEndpointModel.coordinateDurationForProperDuration` (line 116), i.e. it converts the
  responder's turnaround delay from proper to coordinate time. The realised error is therefore
  6.9655e-10 × T_turnaround: **0.21 mm for a 1 ms turnaround, 0.21 m for a 1 s turnaround**. In
  addition, `localTimeAt` (line 106) extrapolates with `localClockRate` = 1 + y_osc only, so within
  a session the satellite's modelled clock rate is short by y_rel = 5.388e-10; over a two-way GEO
  transit of ~0.25 s that is 1.35e-10 s = **4.0 cm** of tag error. Because truth and estimate
  endpoints use the *same* convention this cancels in z − h for satellite-to-satellite ISL (both
  ends share y_rel) — so it is not currently biasing any shipped result — but it is a real
  asymmetry the moment a ground endpoint enters the same chain.
- **Severity**: **Medium**. Not a live double count; a *broken premise* under a guard against one.
  Two clean fixes: give `fixedStation` its own `properTimeRate_(r_ground, v_ground)`, or restate
  the `ClockModel` comment to say the convention is "coordinate time referenced to the ground
  clock", in which case the satellite endpoint should keep the full rate. Today the code says one
  thing and does the other.

**DC-2 — `modelMismatch` process noise is written by two config leaves with the same value.**
- **Location A**: `config/internal/applyLuniSolar.m:15-16` — `enable = true`, `sigma_mps2 = 1e-5`.
- **Location B**: `config/internal/realismGradeConfig.m:136-138` with `V.luniSolar = struct('sigma_mps2', 1e-5)` at line 403.
- **Mechanism**: **assignment**, not accumulation, so whichever applier runs last wins and the value
  is 1e-5 either way. There is **no numerical double count**. A third writer,
  `config/internal/applyInjectTruthSideDynamics.m:42-44`, correctly uses `max(cur, g)` rather than
  adding — the right pattern.
- **Size**: 0 m today; the risk is that a future edit to one leaf leaves the other at 1e-5.
- **Severity**: **Low** (divergence risk, not a defect). Worth one comment pointing each leaf at the
  other.

**DC-3 — `modelMismatch` enters Q at two sites; verified disjoint.**
- **Location A**: `+filter/ReverseGNSSEKF.m:1441-1449` — `sa = sqrt(sa^2 + sm_^2)` for the **primary**
  asset's r/v block.
- **Location B**: `+filter/ReverseGNSSEKF.m:2126-2135` (`addJointAssetProcessNoise_`) —
  `primaryAccelSigma = hypot(primaryAccelSigma, mismatchSigma)` for assets **2..N**.
- **Mechanism**: the two loops write **disjoint** state indices (`sm.r_idx/v_idx` vs
  `sm.asset(assetIdx).r/v` for `assetIdx = 2:nSpaceAssets`), so the same variance is never added
  twice to one state. Additionally `addJointAssetProcessNoise_` is the **joint** multi-asset path,
  which is disallowed under the standing constraints (federated only).
- **Size**: 0.
- **Severity**: **None** — verified clean. Recorded so a future reader does not re-flag it.

**DC-4 — Three config leaves for one ephemeris epoch.**
- **Location A**: `config/masterConfig.m:1220` `cfg.orbit.truth.perturbations.epochJD_TT = 2451545.0`.
- **Location B**: `config/masterConfig.m:2051` `cfg.estimator.dynamics.perturbations.epochJD_TT =
  2451545.0; % match cfg.orbit.truth.perturbations`.
- **Location C**: `config/masterConfig.m:2456` `cfg.effects.solidEarthTide.epochJD_TT = 2451545.0`.
- **Mechanism**: no code keeps them in sync. A scenario that moves the truth epoch (the only reason
  to touch it) leaves the EKF's optional perturbation path and the solid-Earth tide at J2000. If the
  EKF perturbation path or the SRP-scale state is active (`EkfDynamicsPredictor.m:105-119`), the
  filter would compute its SRP direction from a Sun at a different epoch than the truth's, creating
  an **undeclared** truth-model mismatch inside a feature whose whole purpose is to *close* the gap.
- **Size**: for a 1-year epoch offset the Sun moves ~360°, so the SRP direction error is unbounded;
  for the realistic case of a scenario moving only the truth epoch to 2026 the EKF Sun would be
  0.265 cy = 26.5 years stale → the SRP acceleration would point essentially at random relative to
  truth, an O(1.19e-7 m/s²) unmodelled force. Zero at the shipped configuration (all three equal).
- **Severity**: **Low-Medium** (inert today, silent and unbounded if the epoch ever moves). Fix:
  derive B and C from A in `ConfigFactory.finalizeConfig`, or assert equality.

**DC-5 — Solid-Earth tide re-declares GM_sun / GM_moon.**
- **Location A**: `+models/+orbit/OrbitPerturbations.m:20-21` (private constants).
- **Location B**: `+models/+frames/SolidEarthTide.m:37-38` (literals inside the `bodies` cell).
- **Mechanism**: `OrbitPerturbations`' constants are `Access = private`, so the tide cannot reuse
  them and copies the literals. Values currently identical to the digit.
- **Size**: 0 today; a one-digit divergence would scale the tide by GM_b/GM_E linearly.
- **Severity**: **Low** (divergence site). Same class as DC-2.

**DC-6 — Sagnac vs iterative light-time: verified NOT double-counted (both halves of the guard hold).**
- **Location A**: `+revgnss/ConfigFactory.m:1199-1211` — config-level force-disable of
  `physics.sagnac.truth/model.enable` in the `iterativeOneWay` branch, plus a validation warning.
- **Location B**: `+models/+corrections/RangeCorrections.m:109` — runtime `~strcmp(ltModel,'iterative')`
  skip.
- **Mechanism**: two independent guards; either alone would suffice.
- **Size**: 0. (If the guard failed, the double count would be the full first-order Sagnac term,
  |Ω×r_tx·(r_rx−r_tx)|/c, up to ~30 m at GEO geometry.)
- **Severity**: **None** — verified clean and worth stating positively.

---

## Logical flaws

**LF-1 — The CW boundedness claim is contradicted by the shipped default, and the test that would
catch it tests a different configuration.**
`SwarmFormation.m:8-10` claims "[baseline, 1.118*baseline] (bounded, never below the configured
minimum)"; at `cfg.formation.crossTrackSpread = 1.0` (`masterConfig.m:1271`, confirmed resolved =
1 from `masterConfig()`) the **measured** envelope is [0.500, 2.062]·baseline over an orbit and
[0.708, 1.985]·baseline over the 3600 s headline arc. `tests/test_swarm_formation.m:33` omits the
field, so `crossAmp_` reads `s = 0` and the assertions at lines 40-42 hold vacuously (measured
1000.00 / 1118.02 m); executed at the shipped default they measure 500.05 / 2061.51 m and two of
the three fail. **Severity: High** (a documented physical property of the truth model is wrong, the
guard is inert, and every swarm result is quoted against the wrong baseline description).
*Category: claim contradicted by code + test that cannot fail.* **Empirically confirmed by
execution, not inference.**

**LF-2 — The `baseline < 500` warning does not protect the 500 m target it names.**
`SwarmFormation.m:176-179` warns on `baseline_m < 500`, but the physical minimum separation at the
shipped `crossTrackSpread` is ≈ baseline/2. `baseline_m = 800` produces a 400 m minimum with no
warning. **Severity: Medium.** *Category: gate that does not gate.*

**LF-3 — `cfg.physics.sagnac.*.enable` is a derived field, not a knob.**
`ConfigFactory.m:1194-1195` force-*enables* Sagnac in the `sagnacFirstOrder` branch and lines
1207-1208 force-*disable* it in the `iterativeOneWay` branch (the shipped default, set at
`masterConfig.m:93`). Whatever a scenario writes into `physics.sagnac.truth/model.enable` is
overwritten. Any Sagnac ablation rung therefore measures nothing at the default configuration. The
iterative branch at least emits a `cfg.validation.warnings` entry; the `sagnacFirstOrder` branch
silently ORs the flag on. **Severity: Medium** (correct physics, misleading toggle — and it matches
the project's existing "feat ablation rungs disable nothing" pattern). *Category: gate semantics.*

**LF-4 — The process-noise consistency audit applies a two-body-EKF rule to a J2 EKF.**
`ConfigFactory.m:2380-2387` compares `sigma_accel_mps2` to `0.1·|a_J2|` unconditionally. With the
shipped j2/j2 pairing J2 is fully modelled, so the threshold has no physical meaning: MEO
(5e-6 vs 5.28e-6) and LEO (5e-5 vs 1.11e-3) both trip `ConfigFactory:processNoiseTooSmall` and
record `dynamicsProcessNoiseConsistency = 'marginalBelowThreshold'` for no real reason, while GEO
(1e-6 vs 8.33e-7) passes for no real reason. **Severity: Medium** (a named diagnostic that does not
measure what it names, and two shipped rungs failing it). *Category: claim contradicted by code.*

**LF-5 — `assertModelFamilyConsistent` is blind to the perturbation gap it exists to police.**
`GeoRealWorldScenarioGuard.m:204-214` derives "family" from the mode *string* only.
`applyLuniSolar` leaves both strings at J2 while opening a 1.07e-5 m/s² truth-only force gap — five
times the J2 gradient the guard's own auto-tuner considers significant — and the guard passes
silently. **Severity: Low-Medium** (intended behaviour, overpromising docstring). *Category: gate
semantics / claim contradicted by code.*

**LF-6 — The J2 auto-tuner overwrites without a warning, and the round-1 doc's description of it is
wrong.** `ConfigFactory.m:2356-2359` silently replaces a user-set `modelMismatch.sigma_mps2 <= 1e-6`
with `max(1e-8, 0.25·|a_J2|)` = 2.083e-6 m/s² at GEO. It is unreachable at every shipped
configuration (the branch requires a two-body EKF, and the shipped appliers write 1e-5), so the
doc's "can quietly invalidate regime (2)'s noise sizing" should be **withdrawn**. **No warning was
added.** **Severity: Low.** *Category: silent config override + a doc claim that must be corrected.*

**LF-7 — `FrameTimeUtils` has no `epochGMST`, `OrbitPropagator` does.**
`FrameTimeUtils.m:29-32` uses θ = ω·t; `OrbitPropagator.m:219` uses θ = `epochGMST_rad + ω·t`. Inert
at the shipped `epochGMST_rad = 0` (`masterConfig.m:730`), and harmless for the force model (both
two-body and J2 are z-rotation invariant). It breaks the moment a Sun/Moon direction is mixed in via
the FrameTimeUtils-based path (`EkfDynamicsPredictor.m:94, 120-123`) or in
`SolidEarthTide.eci2ecef_` (lines 53-58). **Severity: Low** (inert, latent). *Category: order-of-
operations / frame inconsistency.*

**LF-8 — Duplicated tower table, one copy fixed and one not (`170e37d`).**
`config/internal/orbitClassConfig.m:97` still carries Libreville at −9.4496° while
`config/masterConfig.m:1896` was corrected to +9.4496°, under a comment claiming the first five
sites match the golden network. **Severity: Medium for LEO runs, None for GEO/MEO.**
*Category: claim contradicted by code.*

**LF-9 — The LEO tower rebuild silently reverts ground-clock stochasticity and discards template
fields.** `orbitClassConfig.m:129` sets `deterministic = true` on all 20 rebuilt clocks;
lines 122-123 zero `antennaOffset_enu_m` and `hardwareDelay_m`. Selecting `orbitClass = 'LEO'`
therefore turns off the ground-oscillator noise the clock campaign identified as dominant, without
saying so. **Severity: Medium** (for LEO runs). *Category: unreachable/inert configuration.*

**LF-10 — `SolidEarthTide` ignores `cfg.perturbations.sunMoon.ephemeris`.**
`SolidEarthTide.m:37-38` calls `sunPositionEci(jd)` / `moonPositionEci(jd)` with one argument, so
the tide always uses the M&G analytic series even under `ephemeris = 'de440'`. Consequence ≲0.2 mm
on a 10–30 cm tide, but it means "the run used DE-440" is not true of every consumer.
**Severity: Low.** *Category: inert configuration.*

**LF-11 — `meta.mode` is hard-coded.** `SwarmFormation.m:210` writes `'helix'` regardless of
`cfg.formation.mode`, so a `multiRingHelix` run mislabels itself in every downstream report.
**Severity: Low.** *Category: claim contradicted by code.*

**LF-12 — The relativistic model-vs-truth residual is zero by construction.**
`ConfigFactory.m:1982` and `2004-2005` both call `revgnss.Relativity.geoClockFracFreq` with the
*same* altitude, so with relativity on, `z − h` carries exactly zero relativistic residual unless a
scenario writes an explicit `physics.relativity.clock.model.fracFreq`. No shipped scenario does.
This is a deliberate, documented "published constant" position and it is defensible — but it is also
an **inverse-crime shortcut** for any claim about the *cost* of relativistic modelling error.
**Severity: Low** as implemented, **High** if a result is ever quoted as "relativity is handled".
*Category: inverse-crime shortcut.*

**LF-13 — Two exit paths of `LightTimeSolver` return a mutually inconsistent (position, τ) pair.**
`LightTimeSolver.m:93-99`: `r_twr_at_tx` corresponds to the previous iterate's τ. Error
≈ ω·|Δτ|·Rₑ ≈ 4.6e-10 m at the 1e-12 s tolerance. Also, exhausting `maxIter` without convergence is
silent. **Severity: Negligible / cosmetic.** Recorded for completeness.

---

## Limits of this domain

What the orbital-dynamics, frames and formation layer **cannot** legitimately claim:

1. **No absolute-frame accuracy.** The ECI↔ECEF map is a single z-rotation at a constant
   ω = 7.2921150e-5 rad/s with no precession, nutation, polar motion or UT1
   (`FrameTimeUtils.m:6-15`, L1–L5). Against the IERS ERA rate this accrues **5.35 m/day** of ECEF
   longitude at GEO, and against the GMST rate **31.2 m/day**. Truth, measurement model and EKF all
   read the same constant, so internal consistency is exact and no *result* is affected — but no
   statement of the form "the satellite is at longitude X" is defensible beyond ~5–30 m/day of
   drift, and nothing may be compared against a real ephemeris product without a full EOP chain.

2. **No realistic GEO station-keeping behaviour.** J₂,₂ — the tesseral that actually drives GEO
   longitudinal drift toward the stable points — is absent, as are all higher zonals, drag,
   manoeuvres and station-keeping (`OrbitPropagator.m:13-16`). The truth GEO does not drift the way
   a real one does. Nothing about east-west stationkeeping, longitude slots, or long-arc orbit
   prediction may be claimed.

3. **Force-model conclusions are conditional on the same-family default.** At the shipped
   configuration truth and EKF are both J2 (`masterConfig.m:734, 737`), so convergence and
   filter-consistency results are **not force-model-limited** and must never be quoted as evidence
   that the estimator's dynamics are adequate. The only declared gap is `applyLuniSolar`'s
   truth-only 1.07e-5 m/s², and its 1e-5 m/s² white-noise sigma covers that gap only at the 1 s
   update interval — the coherent drift outruns the SNC as **0.927·√t**, i.e. by 55× over a 3600 s
   coast. **No claim of the form "the filter tolerates unmodelled luni-solar forces during an
   outage" is supported.**

4. **The luni-solar truth is epoch-locked to J2000.** The lunar mean-longitude precession term
   −1.3972·T is omitted (`OrbitPerturbations.m:111`). At `epochJD_TT = 2451545.0` the error is
   0.138″/day and irrelevant; at a 2026 epoch it is 0.3703° of lunar longitude →
   **8.42e-8 m/s²** → **0.55 m/h, 8.7 m over 4 h** of truth-orbit error. The
   "~0.6 m / 4 h analytic-vs-DE-440 gap" quoted at `masterConfig.m:1229-1231` is therefore an
   **at-J2000** number and must not be generalised.

5. **The formation is not a "1 km formation".** MEASURED at the shipped `crossTrackSpread = 1.0`,
   nSec = 5, `baseline_m = 1000`: chief-to-member separations at t = 0 are **1000, 740, 1042, 1232,
   1985 m**, sweeping **[708.0, 1984.9] m** over the 3600 s arc and **[500.0, 2061.5] m** over a
   full orbit; the minimum *pairwise* separation is **964.2 m** at t = 0 (max 2835.8 m). Any ISL,
   shape-solve or beamforming result quoted "at a 1 km baseline" is really quoted at a
   **0.7–2.0 km spread with a factor-2.7 range**, and the 500 m minimum-separation target is met
   only marginally (500.05 m measured) and only because the run is shorter than a quarter orbit.
   `cfg.formation.baseline_m` is the **ring radius**, and with the cross-track fan it is not even
   that for four of the five members.

6. **No relativistic orbit dynamics, and no relativistic *residual*.** The Schwarzschild term
   (M&G Sect. 3.7.3) is absent — re-derived at **7.08e-11 m/s²** at GEO, 0.46 mm over 3600 s,
   correctly negligible. Separately, the relativistic clock term is applied with the *same* constant
   on truth and model, so the run contains **zero relativistic modelling error**. The correct claim
   is "the simulation applies the published relativistic clock offset consistently", never "the
   simulation demonstrates the achievable accuracy in the presence of relativistic clock error".

7. **The solid-Earth tide models the in-phase degree-2 term only.** Omitted: degree-3, latitude-
   dependent Love numbers, out-of-phase/anelastic terms, frequency-dependent corrections, ocean
   loading, atmospheric loading, and the permanent-tide (tide-free vs mean-tide) convention. The
   model captures ≳95 % of a 10–30 cm signal and is truth-only and default-OFF; it must not be
   presented as an IERS `dehanttideinel`-equivalent station-displacement model, and nothing about
   sub-cm station positioning follows from it.

8. **EOP realism is an injected residual, not a correction chain.** `TruthEarthOrientation` injects
   a first-order rotation and (optionally) removes a published one. It does not implement
   R₃(−s′)R₂(x_p)R₁(y_p), does not read an EOP series, and models UT1 error only as a constant LOD
   rate. The realism grade's 0.005″ (`realismGradeConfig.m:411`) is **0.155 m** of tower
   displacement — a post-correction residual, not the raw ~9 m offset the class header uses to
   motivate itself.

9. **The truth formation itself has a model floor, though a comfortably small one.** Differential
   J2 across the formation is **≈7.9e-10 m/s²** (a ½at² bound of ≈5 mm over 3600 s, ≈0.74 m over
   12 h); the **measured** departure of the J2-propagated truth from the CW closed form is
   **5 cm over 12 h**, because most of that force is periodic rather than secular. The truth-cache
   substepping is self-consistent to ~26 nm, and the CW initial conditions use the two-body mean
   motion while the truth propagates J2. None of this limits a mm-class *measurement* claim, but it
   does mean a "formation shape" number below ~5 cm over a long arc is describing the integrator's
   relationship to the CW idealisation, not a physical property of the formation.

10. **LEO and MEO are illustrative, not validated.** `orbitClassConfig` documents that drag — the
    dominant force below ~600 km — is absent from the truth (lines 21-26), that the 20-site network
    yields ~0.3 satellites-in-view (lines 82-89, "not a working continuous-coverage network"), and
    it additionally reverts ground-clock stochasticity (LF-9) and carries a 2104 km tower-position
    divergence from the golden set (LF-8/NEW-4). No LEO or MEO number may be quoted as a result.

---

## Reference list (APA 7)

- Clohessy, W. H., & Wiltshire, R. S. (1960). Terminal guidance system for satellite rendezvous.
  *Journal of the Aerospace Sciences, 27*(9), 653–658. [EXTERNAL]
- International Astronomical Union. (2012). *Resolution B2 on the re-definition of the astronomical
  unit of length*. XXVIII General Assembly. [EXTERNAL — AU = 149 597 870 700 m exactly]
- Kaplan, E. D., & Hegarty, C. J. (Eds.). (2006). *Understanding GPS: Principles and applications*
  (2nd ed.). Artech House. [Paper/Fundamental Books — p. 306 used]
- Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications*. Springer.
  [Paper/Fundamental Books — primary source; printed pp. 64, 69, 71–72, 77, 79, 81, 110, 119, 163–165,
  191, 240, 377 used; PDF-page offset +11]
- National Imagery and Mapping Agency. (2000). *Department of Defense World Geodetic System 1984*
  (NIMA TR8350.2, 3rd ed.). [EXTERNAL — WGS-84 defining constants]
- Petit, G., & Luzum, B. (Eds.). (2010). *IERS Conventions (2010)* (IERS Technical Note No. 36).
  Verlag des Bundesamts für Kartographie und Geodäsie. [EXTERNAL — Ch. 5 polar motion,
  Ch. 7 Eq. (7.5) and nominal h₂ = 0.6078, l₂ = 0.0847, Sect. 10.1 proper time]
- Sabol, C., Burns, R., & McLaughlin, C. A. (2001). Satellite formation flying design and evolution.
  *Journal of Spacecraft and Rockets, 38*(2), 270–278. [EXTERNAL — projected circular orbit]
- Tapley, B. D., Watkins, M. M., Ries, J. C., Davis, G. W., Eanes, R. J., Poole, S. R., … Schutz,
  B. E. (1996). The Joint Gravity Model 3. *Journal of Geophysical Research, 101*(B12),
  28029–28049. [via Montenbruck & Gill Table 3.3, p. 64 — JGM-3 C̄₂,₀ = −484.165368e-6]
- Vallado, D. A. (2013). *Fundamentals of astrodynamics and applications* (4th ed.). Microcosm Press.
  [EXTERNAL — explicit Cartesian J2 component form, Eq. 8-30]

---

# Round-2 re-verification — Measurement models & error chain

**Domain**: pseudorange, carrier, Doppler, light-time/Sagnac, Shapiro, thermal noise, multipath, PCO
**Doc section re-verified**: `docs/scientific_traceability_analysis.md:506-631` (11 features + cross-cutting block)
**Code state**: HEAD = `170e37d`, branch `feature/ground-orientation-exec`; doc was written at `3489075`
**Method**: every file:line re-read at HEAD; every formula re-derived; every quote re-extracted from the PDF and located by printed folio.

**Headline**: the *physics* of this domain survives re-verification almost intact — the observation equations, the iono sign flip, the light-time/Sagnac equivalence, the Shapiro formula and the relativistic constant are all still correct, and three of them I re-derived symbolically rather than trusting the comments. What has **not** survived is the *bookkeeping around them*. Two commits landed after the doc (`9650bcd` per-signal multipath, `1db31e7` per-signal Doppler keying) that changed the correlation structure of the truth side without updating the R side that was built for the old structure. The result is one live under-charge of ~8.9x, one live 2x over-charge, one live GM chain running 4x too fast, and one H/h mismatch that makes a whole ladder rung measure an artefact. Separately, the two commits the prompt asked about (`fe31d5b`, `6566cff`) are **not** what their messages claim: the budget diagnostic has no consumer anywhere in the repository, and the "derived" iono R factor is the *process-noise* increment, which is charged in Q at the same time.

---

## Status ledger for the 11 existing doc features

| # | Feature | Status | Note |
|---|---|---|---|
| 1 | Pseudorange observation equation | **DRIFTED** | `:140`→`:209`, `:189`→`:288`, `:229-241`→`:328-340`, `:134-139`→`:203-208`, `:152-179`→`:221-278`, `:743-779`→`:1000-1095`, `MeasurementModelUtils:186-206`→`:289-309`. Physics unchanged. One **new** term: model-side relativistic clock at `:73-74`. |
| 2 | Carrier equation + iono sign flip | **DRIFTED** | `:245`→`:456`, `:263`→`:473`, `:344-350`→`:563-570`, `:141-153`→`:337-348`, `:227-242`→`:436-453`, `:279-282`→`:231-269`, `:366-377`→`:589-608`. Sign still negative in z, h and H. New: relativistic clock `:72-73`; new tower-clock-state branch `:382-387`. |
| 3 | Doppler / range-rate model | **DRIFTED + EXTENDED** | `:174`→`:230`, `:193`→`:249`, `:203-204`→`:259-260`, `:63-76`→`:81-94`, `:141-150`→`:205-206`, `:250`→`:321`. `OneWayRangeRateModel:55`→`:54`, `:58-61`→`:56-67`, `:78-105`→`:76-102`. New: per-signal noise keying (`sig_list`, `:29-45`, `:232`) and model-side relativistic drift (`:138-139`). |
| 4 | Light-time + Sagnac double-count guard | **STILL VALID** | `LightTimeSolver:77-100` unchanged; `RangeCorrections:108-115` unchanged; `ConfigFactory:1025-1037`→`:1199-1211`. All three guard levels present. First-order↔iterative equivalence re-derived below. |
| 5 | Shapiro delay | **STILL VALID** | `RangeCorrections:40-59` unchanged, constant unchanged, guard unchanged. Confirmed *not* inside the light-time iteration. |
| 6 | Relativistic clock corrections | **SUPERSEDED** | Default is still OFF in `masterConfig`, but `golden_baseline.json` now sets truth **and** model ON, and a new class `+models/+clocks/RelativisticClockCorrection.m` applies it on the estimator side of code, carrier and Doppler. Doc's "default OFF, decorative" framing no longer describes the baseline. Eccentricity term still absent. |
| 7 | Thermal noise (code) | **DRIFTED + partially SUPERSEDED** | `ErrorChain:364-423`→`:447-521`; `MeasurementModelUtils:144-184`→`:153-195`. `masterConfig` default is still `'constant'`, **but** `golden_baseline.json` sets `codeNoise.model = 'cn0'`, so the doc's "default is elevation-independent, contradicting ERROR_BUDGET" is true of masterConfig and **false of every shipped baseline**. New third term in the C/N0 chain: gaseous absorption. |
| 8 | Multipath | **NOW-WRONG (in part)** | `ErrorChain:711-766`→`:936-1006`, `masterConfig:2020-2025`→`:2414-2434`. The doc's "L1 multipath copied unscaled onto every other signal's row" was fixed by `9650bcd` on 2026-08-10 — L1/L2 are now **independent** realisations. The R side was not updated (see DC-1) and the antenna-sharing guard was not ported (see LF-1). Frequency-independent *sigma* and τ=60 s criticism both still stand. |
| 9 | Antenna PCO / lever arms | **DRIFTED** | `masterConfig:2051-2052`→`:2460-2461` (still `[0;0;0]`), `MeasurementModel:92-131`→`:104-131`, `CodeMeasurementBuilder:86-99`→`:156-174`, `:101-121`→`:171-191`. Doc's "zero default magnitude" claim **still valid** for masterConfig; `golden_baseline.json` adds a truth-only 2 mm/axis calibration residual (`effects.antennaPCO.calibrationResidual`), which the doc predates. |
| 10 | Signal definitions | **STILL VALID** | `SignalDefinition.m:107-132` — *identical line numbers*. All three frequencies and `c` re-checked digit-by-digit. |
| 11 | Phase wind-up — ABSENT | **STILL VALID** | No implementation at HEAD. `golden_baseline.json` now *explicitly* budgets for it inside the 10 mm carrier sigma, which is an improvement in honesty over the doc's state. |

Cross-cutting block: correlation-aware IF variance **NOW-WRONG for multipath** (DC-1); `sameAsTruth` oracle guards **STILL VALID** at `EnvironmentModel.m:246-254, 282-293`; variance double-count guards **STILL VALID** but see DC-3/DC-4.

---

## Re-verified features (physics)

### 1. Pseudorange observation equation (uplink sign conventions)

- **Code**: `+models/+measurements/CodeMeasurementBuilder.m:209`
  `z(mi) = rho_true + b_rx_true - b_twr_truth_h + errStruct.truthTotal_m(mi);`
  `:288` `h(mi) = rho_est + b_rx_est - b_twr_h + errStruct.modelTotal_m(mi);`
  Transmit-epoch tower clock, truth side `:203-208` (`b_twr_truth_h = towerClkTruth(mi) - bdot_twr*(t_s - t_tx)`), model side `:221-278` (five correction modes, each back-propagated with its *own* drift, never the truth's — except the two declared oracle modes at `:255-263`). `truthTotal_m` assembled at `ErrorChain.m:394-404` from `{code, trop, iono, hwDelay, mp, ionoHO}`; DCB added separately at `CodeMeasurementBuilder.m:328-340`. Jacobian `CodeJacobianBuilder.m:68` (`H(mi, blk.b) = 1`), `:74` (tower clock `-1`), `:81` (tx code bias `+1`) — *unchanged line numbers*.
- **Status vs doc**: DRIFTED (line numbers only) + NEW sub-term
- **Verdict**: correct — term-for-term the standard equation with transmitter/receiver roles swapped for the uplink, and the transmit-time clock evaluation (which most simulators omit) is right on both sides.
- **Sources**:
  - Enge, P. K. (1994). The Global Positioning System: Signals, measurements, and performance. *International Journal of Wireless Information Networks, 1*(2), 83–105. — "pseudorange, which equals the true range (|X_u,g|) from the user (u) to satellite g, plus an unknown offset between the user clock (b_u) and the satellite clock (B_g)" (p. 95; verified by printed folio, OCR text layer).
  - Xie, J., Wang, H., Li, P., & Meng, Y. (2021). *Satellite navigation systems and technologies*. Springer. — "SPU is the propagation delay of the uplink signal transmitted by the ground station; SCU is the Sagnac effect correction of the ground station uplink" (p. 76; folio verified).
- **Critical analysis**: The **new** term is `b_rx_est = x_est(blk.b) + models.clocks.RelativisticClockCorrection.bias_m(cfg, t_s)` (`:73-74`). I checked the epoch alignment two ways. Callee: `RelativisticClockCorrection.bias_m` returns `c*y*t_s` exactly. Caller: `ReverseGNSSSimulation.advanceTruthEpoch` (`:317-327`) steps the truth clock at the *start* of epoch k and only for `k > 1`, so after (k−1) steps the truth bias is `b0 + y*(k−1)*dt = b0 + y*t_s` — exact, no half-step offset. Had the truth clock been stepped after the measurement, the mismatch would have been `c*y*dt = 0.1615 m` per epoch, i.e. 16 cm of pure bias. It is not. Good.
  Remaining honest caveats, all confirmed at HEAD: (i) `rxCodeBiasModel` (`MeasurementModelUtils.m:289-309`) still returns 0 for `absorbedInReceiverClock`, so the reported clock bias is clock+delay — legitimate but must be stated; (ii) survey/PCO/PCV contributions are still range-domain differences of shifted geometries (`:146-191`), exact rather than linearised; (iii) the shared-tower off-diagonal R block is still there (`:1067-1095`) and still correctly *off-diagonal only*.
  One **new inconsistency** I did not find in the doc: the carrier builder does **not** back-propagate the tower clock to transmit time (`CarrierMeasurementBuilder.m:370`, `b_twr_t = towerClkTruth(mi)` with no `- bdot*tau`), while the code builder does. MATLAB passes `towerClkModel` by value, so `CodeMeasurementBuilder`'s re-anchoring never reaches the caller's copy. The two observables therefore evaluate the same tower clock at epochs 0.12 s apart. At an OCXO drift of ~3e-3 m/s that is ~0.36 mm — 7% of the 5 mm carrier sigma, and *slowly varying*, so the float ambiguity absorbs nearly all of it. Real but not material; worth one line in the limits.

### 2. Carrier-phase equation and the ionosphere sign flip

- **Code**: `+models/+measurements/CarrierMeasurementBuilder.m:456`
  `z_phi = rho_t + b_rx_true - b_twr_t + trop_t - iono_t_sig + B_true + noise_phi + phaseScint_m + b_ia_m;`
  `:473` `h_phi = rho_e + b_rx_est - b_twr_m + trop_m - iono_m_sig + B_est + b_ia_model_m;`
  Slant-iono partial `:492` (`h -= (fL1c/fSigc)^2 * x_iono`) and `:569` (`H_phi(row, blk.iono(ti)) = -(fL1c/fSigc)^2`), both from the **resolved** band via `SignalUtils.frequency(cfg,'L1')`. Truth-only inter-antenna bias `:436-453` (added to z only). Carrier sigma default 0.005 m (`:59-63`; `masterConfig.m:3182`), `golden_baseline.json` raises it to 0.010 m.
- **Status vs doc**: DRIFTED
- **Verdict**: correct — negative on carrier in z, h **and** H; troposphere positive on both; λN a float-metres ambiguity per (tower, antenna, signal) arc.
- **Sources**:
  - Enge (1994) — "ionospheric refraction delays the envelope of the signal and adds the term I_u,g to the code-phase observation. The ionosphere is dispersive, so I_u,g is subtracted from the carrier-phase observation" (p. 96; folio verified).
  - Kaplan, E. D., & Hegarty, C. J. (Eds.). (2006). *Understanding GPS: Principles and applications* (2nd ed.). Artech House. — "the magnitude of the error on the pseudorange measurement and the error on the carrier-phase measurement (both in meters) are equal—only the sign is different" (**p. 311**, not p. 302 as the doc states; folio read from the page footer "7.2 Measurement Errors 311").
- **Critical analysis**: **Doc citation error found and corrected**: the equal-magnitude/opposite-sign quote is on p. 311 of the 2nd edition, not p. 302. The physics claim is unaffected. Two further checks. First, the tower-clock treatment changed since the doc: `:382-387` now reads the **EKF state** for `b_twr_m` when `towerClockIdx(ti,1) > 0`, closing the inconsistent triple (H said −1, R charged 0, h used the product) that the doc did not know about. Second, the carrier IF row builder combines **H as well as z, h and R** (`CarrierIonoFreeRowBuilder.m:191-218`), which is what makes the iono column cancel exactly. The code IF path does not — see **LF-2**, which is the single most serious finding in this section.
  Still absent and still material: carrier multipath (§8) and phase wind-up (§11). The baseline now names both inside its 10 mm sigma, which is the honest treatment.

### 3. Doppler / range-rate model

- **Code**: `+models/+measurements/DopplerMeasurementBuilder.m:230-232`
  `zd(mi) = rhoDot_true + bdot_rx_true - bdot_twr + sigma_dop*drawKeyed(DOPPLER, ti, ai, sig_list(mi)-1, epoch);`
  `:249` `hd(mi) = rhoDot_est + bdot_rx_est - twr_drift_model(mi);`
  `+revgnss/OneWayRangeRateModel.m:54` `sagnacRate = omega_e*(u(2)*delta(1) - u(1)*delta(2));`, `:58` `rhoDot = u'*v_rx_ecef + sagnacRate;`, position partial `:76-102` (gated off, `masterConfig.m:2556`). H columns `:259-260`. Sigma default 0.01 m/s (`masterConfig.m:2550`); `golden_baseline.json` uses 0.0424 m/s.
- **Status vs doc**: DRIFTED + EXTENDED
- **Verdict**: correct observable, correct frame algebra; H is a documented approximation; **R is now 2x over-charged in the shipped baseline** (see DC-2).
- **Sources**:
  - Enge (1994) — "Carrier frequency or Doppler shift, which measures the time rate of change of the pseudorange" (p. 92; folio verified).
  - Kaplan & Hegarty (2006) §2.5 — received-frequency/user-clock-drift formulation, p. 59.
- **Critical analysis**: I re-derived both formulas rather than trusting the header. **Sagnac rate**: with ω = (0,0,ω)ᵀ, ω×Δ = (−ωΔy, ωΔx, 0)ᵀ, so u'(ω×Δ) = ω(u_y Δx − u_x Δy) — exactly line 54. **Frame equivalence**: ρ̇ = u'·(dΔ/dt)|inertial = u'·(dΔ/dt|ECEF + ω×Δ) = u'v_rx,ecef + u'(ω×Δ), because the tower's ECEF velocity is zero. The header's claim is therefore an identity, not an approximation. **Position partial**: dρ̇/dΔ = v_eff'(I − uu')/ρ + u'[ω×] = (v_eff' − ρ̇u')/ρ + (ωu_y, −ωu_x, 0) — exactly lines 94-101. All three correct.
  The **new** feature is `sig_list` (`:29-45`), which keys the thermal draw on the signal so the L1 and L2 Doppler rows no longer share one realisation. This is right, and it is the direct cause of DC-2. The truth Doppler still carries **no** atmospheric rate at all (neither trop nor iono rate appears in `zd`), and neither does `hd`, so the two cancel identically — an inverse-crime shortcut for the atmospheric part of the Doppler observable. The guard at `:81-94` refuses the one configuration where it would bite hardest.

### 4. Iterative light-time solution and the Sagnac double-count guard

- **Code**: `+models/+frames/LightTimeSolver.m:82-100` — `Rz = [cosθ sinθ 0; -sinθ cosθ 0; 0 0 1]` with θ = ωτ, applied to `r_twr_nominal`, iterated to `tol_s = 1e-12` (max 5, config default 2). Guard level 1: `+revgnss/ConfigFactory.m:1199-1211` forces `physics.sagnac.truth/model.enable = false` for `iterativeOneWay`/`iterative` and emits the Stage-80 warning. Guard level 2: `+models/+corrections/RangeCorrections.m:109` `if ~strcmp(ltModel,'iterative') && ... ph.sagnac.(side).enable`. Guard level 3: solver header `:33` and `RangeCorrections:76`. Resolved default (`masterConfig.m:92-94` overriding `i_baseDefaults` at `:2521-2527`): `mode = 'iterativeOneWay'`, 2 iterations.
- **Status vs doc**: STILL VALID (all three levels present, verbatim)
- **Verdict**: correct — I verified analytically that no path can apply both, and that the two paths agree to first order.
- **Sources**:
  - Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications*. Springer. — "Starting from an initial value of τ(0) = 0 the light time is consecutively determined using the ﬁxed-point iteration τ(i+1) = 1/c · |r(t − τ(i)) − R(t)|" (p. 210, Eqs. 6.22–6.23; folio verified — pdf page 270 carries the printed header "210 / 6. Satellite Tracking and Observation Models").
  - Kaplan & Hegarty (2006) — "If left uncorrected, the Sagnac effect can lead to position errors on the order of 30m [12]. Corrections for the Sagnac effect are often referred to as Earth rotation corrections" (p. 307; folio verified).
  - Li, X., Barriot, J.-P., Lou, Y., Zhang, W., Li, P., & Shi, C. (2023). Towards millimeter-level accuracy in GNSS-based space geodesy. *Surveys in Geophysics, 44*(6), 1691–1780. — "The maximum effect is about 153 ns and 133 ns for Galileo satellites and GPS satellites, respectively, for a stationary receiver on the geoid" (p. 1714; folio verified).
- **Critical analysis**: **Re-derived the equivalence from scratch.** Rz(−ωτ)r ≈ r − ωτ(ẑ×r), so δ = ωτ(y_t, −x_t, 0)ᵀ and ρ' − ρ = −u·δ = ωτ(u_y x_t − u_x y_t). Substituting τ = ρ/c and u = (r_rx − r_twr)/ρ gives Δρ = (ω/c)(x_t y_rx − x_rx y_t) — **identical** to `RangeCorrections.sagnacCorrectionMeters:36`. So the first-order and iterative modes are mutually consistent and the forced-disable is exactly the right guard, not a conservative over-reaction. The rotation *direction* is also right: the tower is rotated **backward** (clockwise about +z), which is where the Earth was at transmit time as seen in the receive-time ECEF frame.
  Two differences from Montenbruck & Gill worth stating: the code initialises τ from the receive-time geometric range rather than τ=0 (strictly better; contraction factor ~|ρ̇|/c ≈ 1e-8, so 2 iterations are machine-exact), and the code rotates a fixed ECEF tower instead of propagating an ECI trajectory (exact for a station that is static in ECEF, which these are). The `contrib.sagnac` diagnostic still reports 0 in iterative mode — a reporting quirk, unchanged.

### 5. Shapiro delay

- **Code**: `+models/+corrections/RangeCorrections.m:40-59` — `dR = (2*mu/c^2)*log((rr + rt + R)/(rr + rt - R))`, `mu = cfg.physics.muEarth_m3ps2 = 3.986004418e14`, degenerate guard `denom < 1.0 → 0`. Applied at `:117-124` to `tx_ecef_eff` (i.e. after any light-time rotation), on both `truth` and `model` sides via the expanded enable pair (`masterConfig.m:96`, `expandEnableToggles` at `:266-271`).
- **Status vs doc**: STILL VALID
- **Verdict**: correct — formula, constant, guard and placement all confirmed.
- **Sources**:
  - Li et al. (2023) — "This ranging delay reaches about 60 picoseconds for a MEO satellite and is a little larger for IGSO satellites (~70 picoseconds), therefore it is not neglectable in order to achieve millimeter level accuracy" (p. 1714; folio verified).
- **Critical analysis**: I specifically checked the prompt's question (f): **the Shapiro term is not inside the light-time iteration.** `LightTimeSolver.solve` computes `tau_new = norm(r_rx - r_twr_rot)/c` from the *geometric* norm only (`:90-91`); Shapiro is added afterwards to `rho` at `RangeCorrections:123`. So there is no feedback of the ~17 mm path delay into τ, and no double count. Truth and model apply it identically, so it cancels exactly in the innovation — physically complete, statistically decorative. The `denom < 1.0` guard remains unreachable (the sum rr+rt−R is ~1.3e7 m for any tower–GEO pair).
  One subtlety I re-checked: because Shapiro depends on position, it also forces the finite-difference Jacobian via `MeasurementModelUtils.needsFiniteDiffH_:50-55`. With the default resolved config that FD is already forced by iterative light-time anyway, so this is not an extra cost.

### 6. Relativistic clock corrections — **SUPERSEDED, now a two-sided model**

- **Code**: `+revgnss/Relativity.m:27-46` `y = (GM/c²)(1/Re − 1/r) − v²/(2c²) + v_g²/(2c²)`; truth side wired at `ConfigFactory.m:1977-1983` (`cfg.asset.clock.relativisticFracFreq`) into `ClockModel.m:335` (`new_bias_s = bias_s + dt*(fracFreq + relativisticFracFreq) + ...`) and `:388` (`getFractionalFrequency` now **includes** the term). Model side is the **new** class `+models/+clocks/RelativisticClockCorrection.m:36-77`, resolved at `ConfigFactory.m:1992-2006`, consumed at `CodeMeasurementBuilder.m:73-74`, `CarrierMeasurementBuilder.m:72-73`, `DopplerMeasurementBuilder.m:138-139` and the postfit path `ReverseGNSSSimulation.m:1259-1263`.
- **Status vs doc**: SUPERSEDED (doc describes a truth-only, default-off term)
- **Verdict**: correct arithmetic, defensible standing, **but an inverse-crime cancellation as configured**.
- **Sources**:
  - Li et al. (2023) — "the satellite clock runs faster by about 38 μs per day than a clock on the ground, corresponding to about −4.4647·10⁻¹⁰ s/s for frequency shift" (**p. 1711**, not p. 1712 as the doc states; folio verified).
  - Li et al. (2023) — "A maximum eccentricity of 0.02 for the GPS constellation corresponds to an added relativistic effect of about 45 ns" (p. 1712; folio verified).
  - Kaplan & Hegarty (2006) — "Reference [9] states that this relativistic effect can reach a maximum of 70 ns (21m in range)" (p. 307; folio verified), with `F = −4.442807633 × 10⁻¹⁰ s/m^1/2`.
- **Critical analysis**: **Digit-by-digit re-derivation** with `Constants` GM = 3.986004418e14, Re = 6378137, c = 2.99792458e8, ω = 7.2921150e-5, alt = 35786000 (r = 42164137):
  grav = 4.43506e-3 × (1.5678559e-7 − 2.3716352e-8) = **+5.9016e-10**;
  SR = −(3074.6)²/(2c²) = **−5.259e-11**;
  ground rotation = (465.10)²/(2c²) = **+1.204e-12**;
  y = **+5.3877e-10** → 46.55 µs/day → c·y = **0.16152 m/s** → 581.5 m over 3600 s, 2326 m over 14400 s. Every figure in the class header checks out.
  **The problem is the configuration, not the arithmetic.** `ConfigFactory:1980` derives the truth `y` from `cfg.orbit.altitudeMean_m` and `:2002-2005` derives the model `y` from *the same field*. Unless a scenario writes `physics.relativity.clock.model.fracFreq` explicitly, the two are bit-identical and the term cancels to machine precision in z − h. `golden_baseline.json` enables both and sets no explicit value, so the shipped baseline has **exactly zero** relativistic clock residual. That is an inverse crime: the estimator is handed the truth constant. It is a *defensible* one — a real receiver derives y from the broadcast ephemeris to ~1e-14 fractional, so the true residual really is negligible — but it means **no result from this simulator bounds the relativistic-correction error**, and the class header's "Offset model.fracFreq from the truth value to simulate a residual" describes a capability nothing exercises.
  The eccentricity term is still hardcoded to zero (`Relativity.m:69`, `s.periodicResidual_m = 0`). At e ≈ 1e-4–1e-3 for a station-kept GEO, 2√(µa)/c²·e gives 0.3–3 ns (9 cm–1 m) peak sinusoid at orbital period. That is still above the 3 cm ambition at the high-e end and still aliases into the radial/clock subspace. **Unchanged criticism, still valid.**

### 7. Thermal noise (code and elevation dependence) — **partially SUPERSEDED**

- **Code**: `+models/+errors/ErrorChain.m:447-521` (`computeCodeSigmaVec_`) and the per-signal twin `+models/+measurements/MeasurementModelUtils.m:153-195` (`codeSignalSigma`), both now delegating the C/N0 branch to the single shared `cn0CodeSigma` at `:197-248`:
  `cn0_dBHz = base_dBHz + elevationGain_dB*sin(el) - A_gas_dB;  sigma = sigma0_m * 10^(-(cn0_dBHz-45)/20);`
  Defaults: `masterConfig.m:179` `model='constant'`, `:2123` L1 σ0 = 0.30 m, `:2127` L2 = 0.45 m, `:2104` `errors.codeNoise.sigma_m = 0.3`, `:2093` `sigmaFloor_m = 1e-3`. **`golden_baseline.json` sets `measurements.codeNoise.model = 'cn0'`, base 45 dB-Hz, gain 6 dB, σ@45 = 0.30 m.**
- **Status vs doc**: DRIFTED + partially SUPERSEDED
- **Verdict**: partially correct — the model is right and now elevation-dependent in every shipped baseline, but the two call sites still disagree on the elevation floor and on which σ0 they read.
- **Sources**:
  - Kaplan & Hegarty (2006) — "Typical modern receiver 1σ values for the noise and resolution error are on the order of a decimeter or less in nominal conditions" (p. 319; folio verified).
  - Kaplan & Hegarty (2006) — "the dominant sources of range error in a GPS receiver code tracking loop (DLL) are thermal noise range error jitter and dynamic stress error" (p. 194; folio verified from the running footer at p. 195).
  - Borre, K., Akos, D. M., Bertelsen, N., Rinder, P., & Jensen, S. H. (2007). *A software-defined GPS and Galileo receiver*. Birkhäuser. — Table 8.6, "Multipath and receiver noise | 1" [m] (p. 125; folio verified in-page).
- **Critical analysis**: The doc's charge that "the default is elevation-independent, contradicting `ERROR_BUDGET.md`" needs **splitting**. Against `masterConfig.m:179` it is true. Against `golden_baseline.json` it is false: the baseline runs `cn0`, and its own comment says why ("This is what stops a low-elevation tower being weighted as if it were overhead"). The correct statement for the thesis is *"constant in the bare default, C/N0-weighted in every shipped baseline"*.
  What remains genuinely wrong, and is now documented in the code itself (`MeasurementModelUtils.m:214-220`): the two callers pass **different** elevations (`codeSignalSigma` floors at `ELEVATION_FLOOR_RAD`, `ErrorChain` does not) and **different** σ0 (per-signal `codeSigma0_m` vs `cn0.sigmaAt45dBHz_m`). At the golden's 10° mask and 22.6° minimum elevation the floor never bites, so this is latent. But there is a *live* consequence: for the primary signal, R is built from `ErrorChain`'s vector while the **reported** `bySource.sigma_m.code` is overwritten at `CodeMeasurementBuilder.m:489` with `codeSignalSigma`'s value. In the golden the two coincide (both 0.30 m at 45 dB-Hz) — but nothing enforces that, and any scenario setting `signals.L1.codeSigma0_m ≠ cn0.sigmaAt45dBHz_m` will silently report a code sigma that is not the one in R.
  Chip rate and correlator spacing are still unmodelled, so the L1/L2 ratio 0.30/0.45 remains an assumption, not a derivation. The C/N0 model still drops the squaring-loss factor [1 + 2/(T·C/N0)] — negligible above ~35 dB-Hz.
  **New since the doc**: `A_gas_dB` from `+models/+atmosphere/GaseousAbsorption.m` now enters the C/N0 chain (`MeasurementModelUtils.m:250-287`), scaled by the per-tower ZWD so absorption and troposphere share one humidity. Gated off by default and a hard zero when off. This is a strict improvement and correctly does *not* double count: absorption changes the noise σ, it does not add a delay term to z.

### 8. Multipath — **NOW-WRONG in part; the truth side moved and R did not**

- **Code**: base chain `+models/+errors/ErrorChain.m:936-1006` (`multipath_`, one GM state per (tower, antenna), τ from `coloredGM.tau_s`, σ_el = σ_ss/sin(el)^exp, realised value → z, σ_el → R). **New** per-signal chain `+models/+errors/ErrorChain.m:74-118` (`multipathForSignal`, returns `[]` for si == 1, its own GM state and RNG stream per (tower, antenna, **signal**)), consumed at `+models/+measurements/CodeMeasurementBuilder.m:560-563`. Defaults `masterConfig.m:2399, 2414-2419, 2434` (all off); `golden_baseline.json` turns `multipath.truth` + `coloredGM` on with τ = 60 s, σ = 0.30 m, exp = 1, `sharedAcrossAntennas = true`.
- **Status vs doc**: NOW-WRONG (the "copied unscaled onto every other signal's row" claim), rest STILL VALID
- **Verdict**: partially correct — the per-signal fix is physically defensible, but it invalidated two downstream assumptions that were never updated (DC-1, LF-1).
- **Sources**:
  - Kaplan & Hegarty (2006) — "we will use typical 1-sigma multipath levels in a relatively benign environment of 20 cm and 2 cm, respectively, for a wide bandwidth C/A code receiver's pseudorange and carrier-phase measurements" (p. 319; folio verified).
  - Zhang, Q., Zhang, L., Sun, A., Meng, X., Zhao, D., & Hancock, C. (2024). GNSS carrier-phase multipath modeling and correction. *Remote Sensing, 16*(1), 189. — "The multipath errors produced by carrier signals of different wavelengths are also different" (p. 4; folio verified) and "for the coarse acquisition (C/A) code, the impact of the multipath may reach 10~20 m" (p. 2; folio verified).
- **Critical analysis**: `9650bcd` (2026-08-10) made L1 and L2 **independent** GM realisations. Its stated justification — "the reflected path length in CYCLES differs with wavelength" — is a *carrier*-multipath argument applied to *code*. It is nonetheless defensible for code, because the composite code-multipath error depends on the relative carrier phase of direct and reflected components (θ = 4πH sin z/λ, Zhang et al. Eq. 1), which cycles rapidly with λ. The measured increment correlation of +0.068 against a ±0.098 independence band supports near-decorrelation. **Verdict: the truth-side change is right.** What was not done is the accounting that followed from it (DC-1) and the antenna-scope guard that had to be ported with it (LF-1).
  Unchanged criticisms, all re-verified at HEAD: the *sigma* is still frequency-independent (`multipathForSignal:105` uses `sigmaCodeL1_ss_m` for every signal, so σ_L1 = σ_L2 while the realisations differ — an odd hybrid: decorrelated but equal-variance); **carrier multipath is still entirely absent** (`coloredGM.carrierScale = 0.01` at `masterConfig.m:2418` is still annotated "(reserved)" and no `mp` term appears anywhere in `CarrierMeasurementBuilder`); τ = 60 s is still a moving-constellation number applied to a geometry where both endpoints are quasi-static, so a 3600 s arc holds ~1 independent multipath sample, not 60, and any averaging benefit the filter extracts is optimistic. The `golden_baseline.json` comment ("tau = 60 s means a 3600 s arc holds ~60 independent multipath samples") states this as a feature; it is an unphysical parameterisation for a GEO-to-fixed-tower link.

### 9. Antenna PCO / lever arms / attitude coupling

- **Code**: tower side `+revgnss/GroundTower.m:37, 118-126` (ENU offset → ECEF, default zero) plus config-level tower PCO at `CodeMeasurementBuilder.m:156-174`; receiver side `+revgnss/ReceiverGeometry.m:15-35` (non-collinear cross `[1 −1 0 0; 0 0 1 −1; 0.2 0.2 −0.2 −0.2]` m) and `MeasurementModel.m:104-131` with the truth-only calibration residual at `:117-120`. Per-effect contributions logged at `CodeMeasurementBuilder.m:146-191`. Defaults `masterConfig.m:2460-2461` both `[0;0;0]`, master `enable = true` at `:183`.
- **Status vs doc**: DRIFTED
- **Verdict**: correct machinery, still zero-magnitude in the bare default; the baseline now injects a small truth-only residual the doc predates.
- **Sources**:
  - Schmid, R. (2010, February 3). How to use IGS antenna phase center corrections. *GPS World Tech Talk*. — "The PCO describes the vector from the receiver antenna reference point (ARP) or the satellite's center of mass to the mean phase center, whereas the PCV values provide additional zenith- and/or azimuth-dependent corrections" (¶2; verified in extracted text).
  - Leica Geosystems. (2014). *Leica reference antennas* [White paper]. — "Both the AR25 and AR20 antennas have type-mean phase centre offsets below 1mm, whilst the AR10 is within 2mm" (Phase Centre Offsets/Variations section; verified in extracted text).
  - Li et al. (2023) — "Neglecting these millimeter- or even decimeter-level biases could lead to significant errors in other relevant parameters, especially in the station height" (p. 1723).
- **Critical analysis**: The doc's core claim ("`ERROR_BUDGET.md` says cm-level enabled; the default magnitude is zero") is **still true of `masterConfig`**, and the flagged attitude/`getMeasurementState` fix is still in place. What is new is `golden_baseline.json`'s `effects.antennaPCO.calibrationResidual.receiverOffset_body_m = [0.002, 0.002, 0.002]` — a truth-only 2 mm/axis mis-calibration added to `leverArms_truth` only (`MeasurementModel.m:117-120`), measured at 2.75 mm peak / 1.97 mm rms. Two honest limitations the baseline itself declares and I confirmed in code: it is **one body-frame vector broadcast to all four antenna columns** (`off * ones(1, N_ant)` at `:121`), so it is exactly common-mode across the array and cancels identically in any inter-antenna baseline; and PCV (`pcvModel='toy'`) is applied to **both** sides because `RangeCorrections.pcvCorrection_:171-178` treats an explicit `pcvModel` as authoritative and bypasses the `antennaPCV.(side).enable` gate — so PCV is a perfectly-calibrated antenna, not an injected error. Both statements verified against the code, both correctly declared in the config.

### 10. Signal definitions

- **Code**: `+revgnss/SignalDefinition.m:107-132` — `c = 299792458`, `fL1 = 1575.42e6`, `L2 = 1227.60e6`, `L5 = 1176.45e6`, `wavelength_m = c/f`, `ionoScaleRelativeToL1 = (fL1/f)^2`. Process-local override at `:93-105`, default empty.
- **Status vs doc**: STILL VALID (line numbers *identical*)
- **Verdict**: correct.
- **Sources**:
  - Kaplan & Hegarty (2006) — "there are only two frequencies in use by the system, called L1 (1,575.42 MHz) and L2 (1,227.6 MHz)" (**p. 3**, not p. 2; folio verified from the footer "1.3 GPS Overview 3").
  - Kaplan & Hegarty (2006) — "The L5 frequency that was eventually settled upon was 1,176.45 MHz" (**p. 83**, not p. 82; folio inferred from the adjacent page's footer "84 / GPS System Segments").
- **Critical analysis**: Digits re-checked. Derived quantities re-computed: λ_L1 = 0.190293673 m, λ_L2 = 0.244210213 m, (f_L1/f_L2) = 1.283331, (f_L1/f_L2)² = **1.646938**, its square **2.712405**. The `CodeMeasurementBuilder.m:584` comment "freqScale^2 (2.712x for GPS L1/L2)" is therefore **exactly right**, and the IF coefficients α = 2.545728, β = −1.545728, α²+β² = **8.869770**, √(α²+β²) = **2.978216** confirm both the "8.870x" and "2.98x" figures used throughout the repo. Two doc page numbers are off by one; the physics claim is unaffected. The "GPS L-band labels for an uplink service" observation stands.

### 11. Phase wind-up — ABSENT

- **Code**: no implementation. `grep -r windup` over `+models/` and `+revgnss/` returns only declarations of absence.
- **Status vs doc**: STILL VALID
- **Verdict**: flawed as physics, honest as traceability, and now *quantified* by the baseline.
- **Sources**:
  - Li et al. (2023) — "This effect is known as Phase Wind-Up (PWU) or phase wrap-up, notated as φ_pw in carrier-phase observation equations while it does not exist in pseudo-range observables" (**p. 1729**, not p. 1727; folio verified).
  - Li et al. (2023) — "the effect of PWU is more significant when fixing IGS precise orbit and clock, which can reach up to one half of the wavelength (Kouba 2015), or more specifically, about 9–10 cm for L1/G1a/E1/B1" (p. 1729; folio verified).
  - Wu, J. T., Wu, S. C., Hajj, G. A., Bertiger, W. I., & Lichten, S. M. (1993). Effects of antenna orientation on GPS carrier phase. *Manuscripta Geodaetica, 18*(2), 91–98. [EXTERNAL — canonical model, cited within Li et al. as Wu et al. (1992)]
- **Critical analysis**: Unchanged in substance. The one thing that improved: `golden_baseline.json` now explicitly budgets ~8 mm of wind-up over a 1 h GEO arc inside its 10 mm carrier sigma, rather than leaving the omission silent. That is the right disclosure. The criticism that remains is that wind-up is a *systematic arc-correlated drift* (~0.19 m/day/link at L1 for a nadir-pointing GEO rotating once per sidereal day relative to each fixed tower), not white noise, so inflating a white σ does not represent it — and the arcs where it matters most are exactly the long ones the turn-angle law says are needed for rotation observability.

---

## Double-count candidates

### DC-1 — Ionosphere-free code R charges multipath at unit gain against a source that is now independent per signal  **[HIGH]**

- **Location A** (truth, independent per signal): `+models/+errors/ErrorChain.m:74-118` `multipathForSignal` — own GM state and own RNG substream keyed `(tower, antenna, signal)`; consumed at `+models/+measurements/CodeMeasurementBuilder.m:560-563`.
- **Location B** (R, assumes perfect correlation): `+models/+measurements/CodeMeasurementBuilder.m:865-877` and `:937` — `sigMp_` is stripped out of the independent bundle and re-added as `+ sigMp_.^2`, i.e. gain (α+β)² = 1.
- **Mechanism**: the comment at `:865-875` states the premise explicitly — "This simulator copies ONE realisation onto both rows unscaled — the L2 row is built with `+ mp_t +` straight from the L1 draw (:424)". That premise was **falsified by `9650bcd` on 2026-08-10**, which is *after* the R rebuild was written. The same comment even leaves the instruction: "(If multipath is ever drawn per signal, move it back into the bundle.)" That was never done. Line `:424` no longer exists in the form cited.
- **Size**: this is an **under-charge**, not an over-charge. Correct gain for an independent source is α²σ_L1² + β²σ_L2² = (α²+β²)σ² = **8.8698σ²**; charged is σ². At the golden's σ_ss = 0.30 m with a 1/sin(el) envelope: at el = 22.6° σ_el = 0.781 m → charged 0.609 m², should be **5.40 m²** (short by 4.79 m² per IF row); at el = 59° σ_el = 0.350 m → charged 0.123 m², should be **1.087 m²**.
- **Corroboration inside the same file**: `combineIfSources_` at `:1282-1283` puts multipath through the `otherwise` branch, i.e. `sqrt(α²s1² + β²s2²) = 2.978σ`. So the **reported** IF multipath sigma is 2.978σ while the **charged** one is σ. The file already disagrees with itself by a factor 2.978 in σ, 8.87 in variance.
- **Reachability**: `codeMode = 'ionosphereFree'` with multipath on → `config/ladder/freq/freq003`, `freq004`, `freq006`, `config/ladder/test/test009`. The golden baselines run `codeMode = 'singleFrequency'`, so **no golden moves** — but every ionosphere-free code rung is over-confident on the dominant non-atmospheric error.
- **Severity**: HIGH for the freq/test IF rungs; NONE for the goldens.

### DC-2 — Doppler σ still carries the √2 inflation for a duplicate draw that was fixed two days before the config was written  **[MEDIUM-HIGH, live in every baseline]**

- **Location A** (the fix): `+models/+measurements/DopplerMeasurementBuilder.m:29-45, 232` — `sig_list` keys the thermal draw on the signal; `+models/+errors/ErrorChain.m:216-221` `drawKeyed` uses the signal field of the substream key when `rng.independentStreams.enable` is true (the default). Landed `1db31e7`, **2026-08-06**.
- **Location B** (the compensation): `config/golden_baseline.json`, `measurements.doppler.sigma_mps = 0.0424`, whose own `_sigmaInflation` note reads: "0.0424 m/s = 0.03 × √2. … the L1 and L2 Doppler rows are generated from an IDENTICAL noise draw, so two rows carry one row of information while R claims two. Inflating each row's sigma by √2 halves the claimed information and restores the correct total." Written `68c1f2a`, **2026-08-08** — *two days after* the defect it compensates was fixed.
- **Mechanism**: the same missing-independence error is corrected twice — once structurally (independent substreams) and once numerically (σ × √2). With independent draws, two rows genuinely carry two rows of information, so halving it is a straight 2x over-charge of variance.
- **Size**: 40 of 105 filter rows per epoch. R_doppler = 0.0424² = 1.798e-3 (m/s)² against an honest 0.03² = 9.0e-4 — **exactly 2.0x**. The config note even predicted the transition: "If the duplicate draw is ever fixed, this line becomes merely conservative rather than corrective."
- **Severity**: MEDIUM-HIGH. Conservative, not dangerous, but it de-weights 38% of the row budget by 2x and it silently corrupts any per-channel NIS verdict on the Doppler channel (`91faccb`) — the Doppler channel *must* read ~0.5 for structural reasons, and that will look like a real finding.

### DC-3 — The "derived" iono R factor is the process-noise increment, which Q already charges  **[LOW numerically, MEDIUM logically]**

- **Location A** (R): `+models/+errors/ErrorChain.m:875` `sigmaBase = sigmaBase * rScale_` with `rScale_` resolved at `+revgnss/ConfigFactory.m:2679-2694` to `sqrt(1 - exp(-2*dt/tau))`.
- **Location B** (Q): `+filter/ReverseGNSSEKF.m:1615-1616` `phi_iono = exp(-dt_s/tau_iono); q_iono = sigma_iono^2 * (1 - phi_iono^2);` — the **identical** one-step Gauss-Markov increment variance, on the same τ.
- **Mechanism**: `6566cff`'s stated justification is "the standard Kalman statement that a quantity carried by a state must not also be charged in R: R keeps only what the state does not model, the one-step Gauss-Markov increment." That inverts the decomposition. In a correct formulation the one-step increment **is** what the state models — it is literally Q, and it reaches S through H·P·Hᵀ after the prediction step. What belongs in R is the part of the ionosphere the state's *model class* cannot represent at all (mis-specified τ, mis-specified mapping, higher-order spatial structure, un-modelled gradients). By putting the GM increment into R as well, the same increment is now charged in both Q and R.
- **Size**: `sqrt(1 - exp(-2·1/600)) = 0.05768695` (digit-verified against the commit's 0.057687). R's iono term becomes (1.0 m × M(el))² × 3.3278e-3 ≈ 0.004–0.014 m² per row against a post-fix mean R of ~3 m², i.e. **0.1–0.5%**. Q's term is 3.3278e-3 m² per state per step. Negligible in magnitude.
- **Secondary inconsistency**: `rScale_` multiplies `errors.ionosphere.sigma_m` (the *declared model uncertainty*, 1.0 m) while the sibling guard at `ErrorChain.m:808` correctly uses `estimation.slantIono.sigma_ss_m` (the *state's* steady state, also 1.0 m). They coincide only because the golden sets both to 1.0. `masterConfig.m:3235-3243` calls them "THE SAME PHYSICAL QUANTITY", which is true — and is precisely why deriving one from the other's τ while scaling the other's amplitude is a coincidence, not a derivation.
- **Severity**: LOW numerically, MEDIUM logically. The *direction* of `6566cff` is right (R was over-charging by ~300x and that had to stop); the *justification* is written into `masterConfig` as doctrine and is wrong as stated, so the next person to reason from it will reason wrongly.

### DC-4 — Scintillation is drawn independently per signal with no common-mode block, on the largest truth term in the baseline  **[MEDIUM-HIGH]**

- **Location A** (truth, independent per signal): `+models/+measurements/CodeMeasurementBuilder.m:442-444` — `drawKeyedAtmosphere(SCINT_TRUTH, tower, antennaKey(ant), si, epoch)`, keyed on `si`, so L1 and L2 draw from different substreams (`ErrorChain.m:243-264` → `:216-221`).
- **Location B** (R, no off-diagonal): `+models/+measurements/CodeMeasurementBuilder.m:1118` — the L1↔L2 atmospheric common-mode block covers `corrSrcs_ = {'trop','iono'}` **only**. Scintillation gets no cross-signal covariance.
- **Mechanism**: amplitude scintillation is a diffraction pattern imposed on one wavefront by one set of ionospheric irregularities. L1 and L2 intensity fluctuations from the same irregularity are strongly correlated (they share the TEC realisation; only the diffraction scale differs), yet the simulation draws them as two independent realisations and R declares them independent to match. Truth and R agree, so **no NIS or NEES check can see this** — it is the exact information-gain artefact that `atmosphere.sharedAcrossAntennas` was created to close across antennas, unclosed across signals.
- **Size**: `golden_baseline.json` records scintillation as "the largest truth-only term in this configuration", 7.58 m peak / 0.618 m rms at L1. With `frequencyExponent = 1.5`, σ_L2 = 0.618 × (1575.42/1227.60)^1.5 = 0.618 × **1.4538** = 0.898 m. A perfectly-correlated pair needs an off-diagonal of σ_L1·σ_L2 = **0.555 m²** on every (L1, L2) row pair; the code puts 0. The filter therefore averages the dominant error down by up to √2.
- **Severity**: MEDIUM-HIGH, and **live in the golden baseline**. This is the same class of defect the config file documents at length for antennas, on a larger term.

### DC-5 — Hardware delay is copied verbatim across signals with no cross-signal covariance (latent twin of DC-4)

- **Location A**: `+models/+measurements/CodeMeasurementBuilder.m:544-545` — `hw_t = errStruct.bySource.truth_m.hwDelay(pi)` reuses the base-row value on every signal; sigma tiled unchanged at `:663-669`.
- **Location B**: `:1118` — `corrSrcs_` excludes `hwDelay`.
- **Mechanism**: identical to DC-4 but with the correlation the other way round: the truth is perfectly correlated and R treats it as independent, so the filter averages a *constant per-tower bias* down by √2 in the raw dual-frequency path. The IF path handles it correctly at unit gain (`:939`, with the explicit comment at `:857-862`).
- **Size**: `errors.hardwareDelay.sigma_m` defaults to 0 and `golden_baseline` does not set it, so **latent**. Would become live for any hardware-delay ablation.
- **Severity**: LOW (latent), but it is the same missing entry in the same list as DC-4, so both should be fixed together.

### DC-6 — The code-R budget accumulator records overlapping fields and never resets

- **Location**: `+models/+measurements/CodeMeasurementBuilder.m:17-39` (`rBudgetAccumulate`, `persistent ACC`), written at `:457-475` and `:606-622`.
- **Mechanism**: the struct carries both a **partition** (`codeNoise`, `scint`, `extraTotal`, `towerClock`, which sum to `total`) and its **decomposition** (`trop`, `ionoScaled`, `mp`, `hwDelay`, `ionoHOScaled`, which are already inside `extraTotal`). Any consumer that sums all fields double counts the whole extra bundle. There is no consumer (see LF-3), so today this is a trap rather than a defect. `ACC` is also never reset by any caller — `rBudgetAccumulate('reset')` is defined and called nowhere — so two enabled runs in one MATLAB session silently pool their rows.
- **Size**: `extraTotal` is ~62–66% of the total in the fe31d5b measurement, so a naive sum would report ~1.65x the true R.
- **Severity**: LOW today, MEDIUM the moment a consumer is written.

---

## Logical flaws

### LF-1 — `multipathForSignal` has no `sharedThisCall` guard, so the L2 multipath chain runs 4x too fast and defeats the antenna-sharing gate  **[HIGH, live in the golden baseline]**

`+models/+errors/ErrorChain.m:102-117`:
```matlab
aiKey = ai;
if obj.sharedMultipathAcrossAntennas; aiKey = 1; end
...
key = int64(round(ti)*1000000 + round(aiKey)*1000 + round(si));
if isKey(obj.mpState, key); xPrev = obj.mpState(key); else; xPrev = 0; end
xNew = models.noise.StochasticProcess.gaussMarkovStep(xPrev, dt_s, g.tau_s, sigma_m, mpStream);
obj.mpState(key) = xNew;
```
Compare the base chain `multipath_` at `:963, 972-976, 987`, which maintains a `sharedThisCall` map precisely so that a shared key is **stepped once per epoch** and its value reused. Its own comment states the failure mode: "stepping it once per row would advance the chain N times per epoch and give the antennas N successive samples instead of one shared one." `multipathForSignal` is called once per `(tower, antenna)` row in the si ≥ 2 loop (`CodeMeasurementBuilder.m:561-562`) and has **no such guard**.

Consequences with the golden's configuration (4 antennas, `coloredGM.enable = true`, `sharedAcrossAntennas.enable = true`, L1+L2):
1. The `(tower, 1, 2)` chain is stepped **four times per epoch**. With dt = 1 s and τ = 60 s, φ = 0.98347 and φ⁴ = 0.93516, so the L2 multipath has an **effective correlation time of 15.0 s**, not 60 s. The stationary variance is preserved, so no σ check catches it.
2. The four antennas receive four *successive* samples of the same chain instead of one shared one, so the free √4 = 2 averaging gain that `sharedAcrossAntennas` exists to remove is **still present on L2**.
3. `golden_baseline.json` claims the gate delivers "measured inter-antenna spread exactly 0, antenna 1 bit-identical". That measurement can only have been made on the L1 row (si = 1 returns `[]` and falls through to `multipath_`, which *is* guarded). The claim is **false for signal 2** and should not be quoted as configuration-wide.

Severity HIGH: this is live in the shipped baseline, on one of the two largest truth-only terms, and it is invisible to NIS/NEES because R is unchanged.

### LF-2 — Code ionosphere-free rows: H claims unit sensitivity to a slant-iono state that h does not contain  **[HIGH for freq003; makes that rung unquotable]**

- **h side**: `+models/+measurements/CodeMeasurementBuilder.m:646-649` adds `freqScale * x_iono` to **each signal's** row before combination. After the IF combination at `:806`, the iono content of h is α·1·x + β·1.646938·x = (2.545728 − 2.545728)·x = **0** — correct, the state cancels.
- **H side**: `+models/+measurements/MeasurementModel.m:227-239` runs **after** `CodeMeasurementBuilder.build` has already collapsed M to M_pairs and set N_sig = 1. It reads `errStruct.frequencyHz_perMeas`, which the IF block compressed to the L1 values at `:974-979`, so `f_row = f_L1` and it writes `H_pr(row, ionoIdx) = (f_L1/f_L1)^2 = 1.0`.
- **Result**: ∂h/∂x_iono = 0 while H says 1. The filter is told each IF code row responds one-for-one to the slant-iono state; moving that state changes nothing in h, so the residual never shrinks. Simultaneously the state's variance (initial σ = 5 m, converged P ≈ 0.047 m²) is injected into S = HPHᵀ + R on every IF code row, and the Kalman gain drives the state from residuals containing no ionospheric information — corrupting position and clock through the cross-covariance.
- **Contrast**: the **carrier** IF path does this correctly, combining H with the same α, β as z/h (`+revgnss/CarrierIonoFreeRowBuilder.m:193`, `H_IF = alpha*H(idx1,:) + beta*H(idx2,:)`). The asymmetry is the tell.
- **Reachability**: exactly one shipped rung — `config/ladder/freq/freq003_L1L2ionoFree.json` sets `measurements.codeMode = 'ionosphereFree'` while inheriting `estimation.ionosphereMode = 'perTowerSlant'` from `golden_baseline.json`. `freq004` and `freq006` both set `ionosphereMode = 'none'`; `test009` leaves it at the masterConfig default `'none'`.
- **Why it matters beyond one rung**: freq003's own `_id` says it "exists to measure the cost of that inconsistency" and describes the inconsistency as "the state has almost nothing left to estimate". That is a **misdiagnosis**. Any number quoted from freq003 measures an H/h mismatch, not the cost of an idle state.

### LF-3 — The code-R budget diagnostic has no consumer anywhere in the repository  **[MEDIUM]**

`fe31d5b` touched exactly two files (`CodeMeasurementBuilder.m`, `masterConfig.m`). `grep -r rBudgetAccumulate` outside `CodeMeasurementBuilder.m` returns nothing: no report writer, no test, no `'get'` call, no `'reset'` call. The gate `diagnostics.codeRBudget.enable` exists, defaults false, and when set true the accumulator writes into a `persistent` that is **never read and never cleared**. The measured budget in the commit message (ionosphere 61%, tower clock 22%, scintillation 10%, multipath 4%, troposphere 1%, code noise 0.8%, mean R 7.79–7.97 m²) must have come from an ad-hoc interactive session that no longer exists in the tree, and it is **not reproducible from a clean checkout**. That is exactly the property the commit was written to establish ("the decomposition can never disagree with the R the filter actually inverts").

It is also now **stale**: those numbers were measured *before* `6566cff` cut the ionosphere R base by a factor 0.0577 in σ (0.00333 in variance). Post-fix, the ionosphere term is essentially zero and the composition is dominated by the tower clock and scintillation — a completely different budget.

### LF-4 — Two retracted claims survive verbatim in `masterConfig` and `ErrorChain` as live doctrine  **[MEDIUM]**

- `config/masterConfig.m:157-158`: "That is a measured double count -- code-channel NIS/dof 0.47, **ionosphere 87.3% of code R at 2.39x over-charge**" — retracted six lines above its own resolution note, and explicitly retracted by `fe31d5b` ("87% was overstated, 61% is the number").
- `config/masterConfig.m:3241-3242`: "ionosphere is 87.3% of code R at 2.39x over-charge, and **the whole budget closes to 0.4696 predicted vs 0.4701 measured**" — `fe31d5b` calls this exact match "a coincidence of the fixed elevations and single band probed, and I trusted it instead of testing it".
- `config/masterConfig.m:154-156`: "**DEFAULT 1.0** = the historical behaviour, byte-identical" — contradicted by line 174, `cfg.errors.ionosphere.rScaleWhenStateActive = [];`, twenty lines later in the same block.
- `+models/+errors/ErrorChain.m:829-852`: the whole comment block still asserts "DEFAULT 1.0 so this change is byte-identical", "87.3%", and "the measured residual implying ~0.63 m" — all superseded by `6566cff`.
- `+models/+measurements/CodeMeasurementBuilder.m:865-875`: the multipath-correlation comment states a premise falsified by `9650bcd` and cites a line number (`:424`) that no longer exists.

Each is a claim contradicted by code in the same file. For a traceability document these matter more than usual: they are the sentences a reader would quote.

### LF-5 — The si == 1 branch of the R budget hardcodes `floorHit = 0` against a floored R

`+models/+measurements/CodeMeasurementBuilder.m:474` records `'floorHit', 0` unconditionally, but the primary row's `R_diag(pi)` was built with `max(sigma_i, sigmaFloor)^2` at `:322`. If the floor bites on a primary row, the recorded partition no longer sums to `total` and the report has no way to know. The si > 1 branch computes it honestly (`:621`). Latent at `sigmaFloor_m = 1e-3`.

### LF-6 — Gate semantics: `errors.hardwareDelay.enable` is deliberately not read

`+models/+errors/ErrorChain.m:888-897` documents that `enable` is bypassed and only `truth.enable`/`model.enable` are honoured, because `geoRealWorldTruthComparisonConfig` resolves to `enable = 0, truth.enable = 1` and a smoke test asserts the residual is non-zero. This is honestly declared, but it means the master toggle of one error family **does not gate it**, and any ablation script that flips `enable` will report "no effect" for the wrong reason. Same class as the `_extends`-inheritance trap already in the project memory.

### LF-7 — `cfg.elevationMask_rad` is read but never set

`+models/+measurements/MeasurementModel.m:39` defaults `elevMask_rad = 5°` and `:53` overrides from a **top-level** `cfg.elevationMask_rad` that nothing in the repository writes (`estimator.elevationMask_deg` is the field scenarios actually set). The visibility gate at `:74` and `:145` therefore always runs at 5°. `golden_baseline.json` declares this defect itself; it is inert only because the lowest tower sits at 22.6°. Any scenario with a genuinely low tower would silently ignore its configured mask on the code/carrier/Doppler rows while the two-way rows honour it.

### LF-8 — `ConfigFactory.defaultConfig` resolves a *different* light-time and Shapiro default from `masterConfig`

`masterConfig('baseOnly')` returns `i_baseDefaults` only (`config/masterConfig.m:24`), which sets `lightTime.mode = 'sagnacFirstOrder'`, `lightTime.enable = false`, `sagnac.truth/model = true` and `relativity.shapiro.truth/model = **false**` (`:2517-2531`). The full `masterConfig` path then overrides all four at `:91-96` to iterative light-time and Shapiro on. So a config built through `revgnss.ConfigFactory.defaultConfig` runs **first-order Sagnac and no Shapiro**, while one built through `masterConfig` runs **iterative light-time and Shapiro on both sides**. Both are internally consistent (no double count either way — I checked the guard covers both), but the doc's blanket "enabled truth+model by default" is only true of the second path. Unit tests built on `defaultConfig` are exercising a different physics configuration from the goldens.

---

## Limits of this domain

Concretely, what this measurement chain **cannot** legitimately claim:

1. **No relativistic-correction error bound.** Truth and model both derive y from `cfg.orbit.altitudeMean_m` (`ConfigFactory.m:1980` and `:2002-2005`), so the ~581 m/hour ramp cancels to machine precision. Nothing in any run bounds the residual of a real broadcast-derived correction. Additionally the **periodic eccentricity term is identically zero** (`Relativity.m:69`), so for any orbit with e ≳ 1e-4 an unmodelled 9 cm–1 m orbital-period sinusoid is missing from the truth — and it lives in the radial/clock subspace this system already identifies as its weakest (corr = −1.000).

2. **No carrier-phase error budget below ~1 cm.** Carrier multipath is absent (`coloredGM.carrierScale` reserved, no `mp` term in `CarrierMeasurementBuilder`), phase wind-up is absent, and PCV cancels between truth and model. Kaplan's benign-environment carrier multipath alone is 2 cm — 4x the bare 5 mm σ and 2x the baseline's 10 mm. The 10 mm σ is a *declaration* that those terms are unmodelled, not a *bound* on them. **No sub-cm carrier claim is supportable**, and no claim at all is supportable about arc-correlated carrier systematics (wind-up drifts one cycle per relative antenna revolution ≈ 0.19 m/day/link at L1, which is precisely the signal a long-arc rotation study integrates).

3. **No credible multipath statistics.** τ = 60 s is a moving-constellation parameter applied to a static GEO-to-fixed-tower geometry whose true fading time is hours; the σ is frequency-independent while the realisations are independent (a physically incoherent hybrid); the L2 chain runs at an effective τ of 15 s (LF-1); and no chip rate or correlator spacing exists anywhere in the model. Multipath here is a *plausible-magnitude coloured disturbance*, not a multipath model. Any statement of the form "multipath contributes X m" is a statement about this parameterisation only.

4. **No Doppler channel consistency statement.** R is 2x over-charged (DC-2), the truth carries no atmospheric rate at all (so the tropospheric and ionospheric rate terms cancel by construction rather than by modelling), the position partial is off by default, and there is no relativistic Doppler. The Doppler channel's NIS is structurally biased low and must not be read as evidence about the model.

5. **No ionosphere-free code result.** The IF code R under-charges multipath by 8.87x in variance (DC-1), and the one rung that combines IF code with a slant-iono state has an H/h mismatch (LF-2). Neither `freq003` nor any IF code rung with multipath enabled can be quoted.

6. **No cross-signal information claim.** Scintillation (DC-4) and hardware delay (DC-5) are common-mode across L1 and L2 in physics but independent in this model, so a dual-frequency run gets up to √2 of free averaging on the largest truth-only term in the baseline. Any "dual frequency buys X" statement inherits that gain.

7. **No claim about the *composition* of R.** The only instrument that measured it has no consumer, was never reset, and its published numbers predate the factor-300 change to the ionosphere term (LF-3). The composition of the R the filter actually inverts is, at HEAD, **unmeasured**.

8. **No elevation-mask claim.** The code/carrier/Doppler visibility gate ignores every configured mask (LF-7). Results are valid only for networks whose lowest elevation already exceeds 5°.

9. **Absorbed, not observed, receiver hardware delay.** `rxCodeBiasModel` returns 0 under the default `absorbedInReceiverClock` convention, so every reported receiver clock bias is clock + uncalibrated delay. Correct practice, but the clock-bias state is not a clock-bias estimate.

10. **Chip-rate-free noise.** Per-signal σ0 (0.30 / 0.45 m) carries the entire signal-structure burden. Nothing in the code would flag an inconsistent (frequency, chip rate, σ) triple, and the C/N0 model omits the squaring loss. The L1:L2 noise ratio is an input, not a result.

---

# Round-2 re-verification — EKF core, process noise Q, MEKF attitude, gyro/star tracker, NEES/NIS

Domain: `+filter/ReverseGNSSEKF.m`, `+filter/EkfDynamicsPredictor.m`, `+revgnss/{AttitudeErrorStateKinematics, AttitudeQuaternion, AttitudeKinematics, AttitudeInitializer, AttitudeObservability, ChiSquareConsistency, ConsistencyStatistics, MonteCarloConsistency, EkfInnovationAccounting, AttitudeSensorSuite}.m`, `+models/+sensors/{GyroscopeMeasurementModel, IMUModel, StarTrackerMeasurementModel, StarTrackerObservationModel}.m`, plus the NIS/NEES recording layer in `+data/SimulationDataStore.m`.

Re-verified against working tree at `170e37d` (branch `feature/ground-orientation-exec`). Doc section under review: `docs/scientific_traceability_analysis.md:635–767`.

---

## 0. Meta-finding you must fix before anything else: the doc's line numbers were never taken at 3489075

**`+filter/ReverseGNSSEKF.m` has not changed since the doc was written** (last touched at `7b877a2`, which predates `3489075`), yet **every line citation in the doc's filter section is wrong by 88–212 lines.** The doc calls the file "2 301 lines". Measured file lengths by commit:

| commit | `+filter/ReverseGNSSEKF.m` lines |
|---|---|
| `0ce01f7` (Section 3.3 common-information) | **2301** |
| `2060e9d` (empirical RTN accel states) | 2466 |
| `c6fcff9` (scale-invariant PSD guard) | 2508 |
| `7b877a2` = HEAD | **2513** |

Spot-check: the doc says `update` is at `703–835`; at `0ce01f7` `update` begins at exactly line 703 and its `NIS = nu' * (S \ nu)` is at exactly 833. At HEAD they are 791 and 964.

**Consequence.** The filter section was traced against a checkout at `0ce01f7` — i.e. *before* the empirical-acceleration state block and *before* the scale-invariant PSD guard. That is not a "line numbers drift" nuisance: two whole features postdate the trace and were never audited, and one audited feature (the PSD guard) was described in its pre-fix form. This matches the standing memory note `project_stale_worktree_shadows_genpath` — there are four `.claude/worktrees/*` copies of this file on disk (2525 / 2513 / 1460 / 2513 lines). **Any re-issue of the doc must re-anchor from the main tree, not a worktree.**

All line numbers below are HEAD.

---

### EKF measurement update: gain and Joseph-form covariance

- **Code**: `+filter/ReverseGNSSEKF.m:791–965` (`update`). Prior saved `Pminus = obj.P` (l. 807) behind the watermark fence (l. 808); `nu = z − h` (l. 811); `S = H*Pminus*H' + R`, symmetrised (l. 814–815); `K = Pminus*H'/S` right division (l. 818); `xUpdated = obj.x + K*nu` (l. 821); Joseph `Pplus = (I−K*H)*Pminus*(I−K*H)' + K*R*K'`, symmetrised (l. 825–827); `NIS = nu'*(S\nu)` (l. 964).
- **Status vs doc**: DRIFTED (703–835 → 791–965; all sub-line references shift by ~+88..+131).
- **Verdict**: correct — exact Brown & Hwang gain and general (any-gain) covariance form, with the stabilised form as the *only* P-update path.
- **Sources**:
  - Brown, R. G., & Hwang, P. Y. C. (1997). *Introduction to random signals and applied Kalman filtering* (3rd ed.). Wiley. — "**K_k = P_k^- H_k^T(H_k P_k^- H_k^T + R_k)^{-1}**" (Eq. 5.5.17, p. 217, transcribed from scanned PDF page 114); "**P_k = (I − K_k H_k)P_k^-(I − K_k H_k)^T + K_k R_k K_k^T**" (Eq. 5.5.18, p. 218, transcribed from PDF page 115); "**Three of these, Eqs. (5.5.20), (5.5.21), and (5.5.22), are only valid for the optimal gain condition. However, Eq. (5.5.18) is valid for any gain, optimal or suboptimal.**" (p. 218, transcribed); "**we will list the simplest update equation, that is, Eq. (5.5.22), as the usual way to update the error covariance**" (p. 218, transcribed).
  - Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications*. Springer. — Eq. 8.93, p. 278 (same gain in the orbit-determination setting).
- **Critical analysis**: Correct and *re-verified against the scan this time*. Two citation corrections for the doc: (i) the identical Joseph expression first appears as **Eq. (5.5.11) on p. 216** and is *repeated* as (5.5.18) on p. 218 — the doc's "(5.5.18), p. 218" is right but the p. 216 first statement (with the sentence "Notice here that Eq. (5.5.11) is a perfectly general expression for the updated error covariance matrix, and it applies for any gain K_k, suboptimal or otherwise", p. 216) is the stronger citation; (ii) the doc's abridged quote of the "three of these" sentence silently drops the equation numbers — the verbatim above is what should be printed. The implementation choice remains stronger than the textbook minimum, and the reason given in the doc (the same `update()` is reused for pseudo-measurements with artificially tiny R) is confirmed: `appendClockGaugeRows` (l. 1857) and `applyAmbiguityPseudoMeasurement` (l. 1820) both route through it.

### PSD repair after the update — SCALE-INVARIANT, on the correlation matrix

- **Code**: `+filter/ReverseGNSSEKF.m:900–957`. `dP = diag(P)`, `sd = sqrt(max(dP,0))`, `C = (sInv*sInv')·P` (unit-diagonal correlation matrix, l. 923), `minEigC = min(eig(C))`, `tolC = 1e-12`; `minEigC < −tolC` → `nearestSPD_(C)` then `P = (sd*sd').*C` (`repairKind='nearestSpdProjection'`); `−tolC ≤ minEigC < 0` → `C + I·(tolC−minEigC)` (`'benignDiagonalNudge'`). Fallback for a zero/non-finite variance keeps the **absolute** test on P itself (l. 941–957). Helper `nearestSPD_` at l. 2495–2501 (eigenvalue clip at 1e−12).
- **Status vs doc**: **SUPERSEDED** — the doc describes the pre-`c6fcff9` absolute guard ("benign tol−minEig diagonal nudge … tol = 1e−12·max(diag(P))") at lines 807–827 and `nearestSPD_` at 2283–2289. Both are stale.
- **Verdict**: correct, and a genuine improvement over what the doc credits.
- **Sources**: Higham, N. J. (1988). Computing a nearest symmetric positive semidefinite matrix. *Linear Algebra and its Applications, 103*, 103–118. [EXTERNAL] — the polar-factor algorithm the helper deliberately does **not** implement; the code uses the simpler eigenvalue clip, documented in-file.
- **Critical analysis**: The fix is real and its rationale is measured in-file (l. 900–917): with a 100 m carrier-ambiguity prior, `max(diag(P)) = 7306`, the old absolute floor was 7.3e−9, which set an empirical-acceleration prior of variance 1e−14 to a 5-significant-figure match with the floor — 855× too wide. Repairing the correlation matrix makes the nudge a *relative* variance inflation, and `P = D C D` is a congruence, so PSD is preserved. **One residual**: the `else` branch (any variance exactly 0 or non-finite) still applies the old absolute clip via `nearestSPD_(obj.P)` with a 1e−12 floor, so the original trap survives on that path. It is reachable: `buildQ_` freezes disabled states by multiplying Q by 1e−20 rather than zeroing (l. 1475–1481) precisely to keep variances non-zero, i.e. the codebase *avoids* the branch rather than fixing it. Measured at HEAD, `Q(ω,ω) = 1e−34` with `estimateAngularRate=false` — non-zero, so the scalable path is taken. Acceptable, but the paper should not claim the guard is scale-invariant unconditionally.

### Covariance prediction and the state-transition matrix

- **Code**: `+filter/ReverseGNSSEKF.m:782–783` `P = F*P*F' + Q`, then `(P+P')/2`. `buildF_` at `1285–1419`: r/v block from `EkfDynamicsPredictor.finiteDiffStm6` when J2/two-body is on (l. 1303–1308), else `F(r,v)=dt·I`; clock coupling `F(b,ḃ)=dt` (l. 1360); ZWD/iono `phi = exp(−dt/tau)` (l. 1389–1418); empirical-accel column (l. 1376–1385). `EkfDynamicsPredictor.propagateEcef` at `42–148`, `finiteDiffStm6` at `150–196`, `srpStmColumn` at `198–218`, limitations header at `9–14`.
- **Status vs doc**: DRIFTED for `ReverseGNSSEKF` (694–695 → 782–783; `buildF_` 1146–1268 → 1285–1419); **STILL-VALID** for every `EkfDynamicsPredictor` line (42–148, 150–196, 198–218, 9–14 are exact).
- **Verdict**: correct.
- **Sources**: Brown & Hwang (1997) — "**P_{k+1}^- = E[e_{k+1}^- e_{k+1}^{-T}] = E[(φ_k e_k + w_k)(φ_k e_k + w_k)^T] = φ_k P_k φ_k^T + Q_k**" (Eq. 5.5.25, p. 219, transcribed from PDF page 115); "**Analytical methods for finding the state transition matrix are well known … However, evaluation of the Q_k matrix that describes w_k may not be so obvious.**" (p. 200, transcribed from PDF page 106). Montenbruck & Gill (2000), §8.3.3, p. 282 and Eq. 8.109, p. 283.
- **Critical analysis**: Unchanged and correct. The 12-propagation count is confirmed (`finiteDiffStm6` runs 3 position + 3 velocity columns × 2 central-difference evaluations = 12 `propagateEcef` calls, l. 180–195); `srpStmColumn` adds 2 more when the SRP scale state is on, and `predict` adds 3 more empirical-accel algebra terms (no extra propagations — the empirical acceleration enters analytically through `gmAccelIntegrals_`, l. 2440). The doc's structural caveat stands and is now measurable: at HEAD's resolved default, `sigma_accel_mps2 = 1e−6` and `processNoise.modelMismatch.enable = false, sigma_mps2 = 1e−6`, so the r/v Q is the pure CV white-acceleration form `Q(r,r)=3.3333e−13, Q(v,v)=1e−12, Q(r,v)=5e−13` at dt = 1 s (verified live in MATLAB) while F carries the full J2 STM — F and Q are derived from different dynamics assumptions, and the inflation lever that would paper over it is **off** by default. The doc said the mismatch inflation is "silently overwritten by a finalizeConfig auto-tuner"; at HEAD the *resolved* default is simply `enable = 0`, so nothing is being overwritten — that clause should be dropped.

### Process-noise discretisation (white-noise acceleration, exact polynomial form)

- **Code**: `+filter/ReverseGNSSEKF.m:1450–1458` — `q_r = sa²·dt³/3`, `q_v = sa²·dt`, `q_rv = sa²·dt²/2`, both cross terms placed. Attitude/rate block at `1467–1488` — `q_eul = saa²·dt³/3`, `q_omg = saa²·dt`, cross `saa²·dt²/2`, with the 1e−20 freeze at `1474–1481`. Random-walk states `σ²·dt`: ISL ambiguity `1542–1555`, ground ambiguity `1557–1585`, SRP scale `1525–1527`, two-way calibration bias `1528–1534`, tx code bias `1640–1653`. Gauss–Markov steady-state `σ_ss²(1−φ²)`: ZWD `1587–1604`, slant iono `1606–1623`, empirical accel `1625–1636`.
- **Status vs doc**: DRIFTED (1299–1307 → 1450–1458; 1317–1337 → 1467–1488; every sub-block shifts).
- **Verdict**: correct — exact closed-form discrete Q, verified numerically at HEAD.
- **Sources**: Brown & Hwang (1997) — "**Formally, we can write Q_k in integral form as**" followed by Eq. (5.3.6) (p. 200, transcribed from PDF page 106); the worked 2×2 discrete Q for the integrated Gauss–Markov process is Eqs. (5.3.14)–(5.3.17), pp. 202–203 (PDF page 107), whose frequency-channel entry is "**E[x_2 x_2] = σ²(1 − e^{−2βΔt})**" (Eq. 5.3.16, p. 202, transcribed) — **this is the exact source for the code's ZWD / slant-iono / empirical-accel `σ_ss²(1−φ²)`, which the doc did not cite.** The dt³/3, dt²/2, dt triple also appears as B&H's clock Q, Eqs. (11.3.1)–(11.3.3), p. 429.
- **Critical analysis**: Live digit-check at dt = 1 s on the resolved default (nx = 27), `P` seeded to zero so `P_after_predict ≡ Q`:

  | entry | measured | closed form |
  |---|---|---|
  | `Q(r,r)` | 3.33333e−13 | `sa²dt³/3`, sa = 1e−6 ✓ |
  | `Q(v,v)` | 1e−12 | `sa²dt` ✓ |
  | `Q(r,v)` | 5e−13 | `sa²dt²/2` ✓ |
  | `Q(ω,ω)` | 1e−34 | `saa²dt·1e−20`, saa = 1e−7 ✓ (frozen) |
  | `Q(b,b)` | 4.49379e−3 m² | `q1·dt + q2_eff·dt³/3` ✓ |
  | `Q(b,ḃ)` | 1.86891e−8 | `q2_eff·dt²/2` = ½·Q(ḃ,ḃ) ✓ |
  | `Q(ḃ,ḃ)` | 3.73782e−8 | `q2_eff·dt` ✓ |

  All six placements confirmed. The 1e−20 freeze is a documented pragmatism; note it is also what keeps the PSD guard on its scale-invariant branch (above), so it is load-bearing for numerics, not only for NEES.

### Attitude/gyro-bias process-noise block — it OVERWRITES, it does not add (NEW)

- **Code**: `+filter/ReverseGNSSEKF.m:2220–2234` (`applyGyroProcessNoise_`), called from `buildQ_` at l. 1491–1494 **after** the `sigma_angAccel` block has already written `Q(euler,euler)`, `Q(omega,omega)` and both cross terms. The gyro block **assigns** (`=`, not `+=`): `Q(θ,θ) = (ARW²·dt + RRW²·dt³/3)I`, `Q(θ,ω) = Q(ω,θ) = 0`, `Q(θ,b_g) = Q(b_g,θ)ᵀ = −RRW²·dt²/2·I`, `Q(b_g,b_g) = RRW²·dt·I`.
- **Status vs doc**: NEW (the doc quoted the formula but did not check add-vs-assign — the obvious double-count candidate).
- **Verdict**: correct — **no double count**, verified numerically.
- **Sources**: Farrenkopf, R. L. (1978). Analytic steady-state accuracy solutions for two common spacecraft attitude estimators. *Journal of Guidance and Control, 1*(4), 282–284. [EXTERNAL] — the origin of the two-parameter ARW/RRW gyro error model and its discrete covariance. IEEE Std 952-1997 (R2008) [EXTERNAL] — ARW is the −1/2-slope Allan term (σ(τ) = N/√τ), RRW the +1/2-slope term.
- **Critical analysis**: Measured at HEAD with ARW = 1e−4, RRW = 1e−6, dt = 1: `Q(θ,θ) = 1.00003e−8` (= 1e−8 + 3.333e−13 ✓), `Q(θ,ω) = 0` exactly, `Q(θ,b_g) = −5e−13` ✓, `Q(b_g,b_g) = 1e−12` ✓. The angular-acceleration contribution `saa²dt³/3 = 3.33e−15` is *replaced*, not stacked — so `sigma_angAccel` is **inert on the attitude channel whenever `estimateGyroBias` is true** (which is the resolved default). That is the right physics (the gyro supersedes the kinematic random walk) but it is a silently-inert knob: turning `sigma_angAccel` up in a gyro-enabled run changes nothing on attitude and only touches the frozen `omega` state. This deserves a sentence in the paper — `AttitudeObservability`'s central warning ("*reported attitude covariance is process-noise-limited (sigma_angAccel), not measurement-constrained*", `+revgnss/AttitudeObservability.m:48–50`) names a parameter that, in the shipped default, does not drive the attitude covariance at all. The correct statement is "ARW-limited", not "sigma_angAccel-limited".

### Two-state receiver-clock process noise — the doc's formula is NOW WRONG

- **Code**: `+models/+clocks/ClockModel.m:457–...` (`getProcessNoiseQ`): `q1 = h0/2`; `q2 = 2π²·h₋₂`; **`q2_ffm = 6·ln(2)·h₋₁ / dt`** when `flickerAsEquivalentRwfmInQ` (property default **`true`**, l. 102); `q2_eff = q2 + q2_ffm`; `Q_s = [q1·dt + q2_eff·dt³/3, q2_eff·dt²/2; q2_eff·dt²/2, q2_eff·dt]`, symmetrised, then `diag([c,c])·Q_s·diag([c,c])` for metres. The legacy `driftFlickerInQ` knob is **removed** and warns if set (l. 142–150). Consumed at `ReverseGNSSEKF.m:1496–1505` (receiver) and `1507–1520` (tower clocks), full 2×2 including cross terms.
- **Status vs doc**: **NOW-WRONG.** The doc states `q_ffm = 2*log(2)*h.hMinus1` added to the **phase** entry as `(q1+q_ffm)*dt`, gated by `driftFlickerInQ` (default false). Neither the formula, the placement, nor the gate exists at HEAD.
- **Verdict**: correct as implemented, and **better** sourced than the doc's version.
- **Sources**: Brown & Hwang (1997) — "**A suitable clock model that makes good sense intuitively is a 2-state random-process model.**" (p. 429, transcribed from PDF page 220); "**E[x_p²(Δt)] = S_f Δt + S_g Δt³/3**" (Eq. 11.3.1, p. 429), "**E[x_f²(Δt)] = S_g Δt**" (Eq. 11.3.2, p. 429), "**E[x_p(Δt)x_f(Δt)] = S_g Δt²/2**" (Eq. 11.3.3, p. 429); "**S_f ~ h_0/2**", "**S_g ~ 2π²h_{−2}**" (Eq. 11.3.5, p. 431, transcribed from PDF page 221); "**Flicker noise gives rise to a term in the variance expression that is of the order of Δt², and it is impossible to model this term exactly with a finite-order state model (17).**" (p. 430, transcribed); "**an approximate solution is to simply elevate the theoretical V of the 2-state model so as to obtain a better match in the flicker floor region**" (p. 430, transcribed). The corrected van-Dierendonck-derived footnote (p. 430, transcribed) reads `q₁₂ = q₂₁ = h₋₁Δt + π²h₋₂Δt²`, `q₂₂ = h₀/(2Δt) + 4h₋₁ + (8/3)π²h₋₂Δt`, `q₁₁ = (h₀/2)Δt + 2h₋₁Δt² + (2/3)π²h₋₂Δt³`.
- **Critical analysis**: I re-derived the equivalence rather than trusting the comment. RWFM Allan variance `σ_y²(τ) = (2π²/3)h₋₂τ`; flicker-FM `σ_y²(τ) = 2ln2·h₋₁`. Equating at τ = dt gives `h₋₂,eq = 3ln2·h₋₁/(π²dt)` and `q2_ffm = 2π²h₋₂,eq = 6ln2·h₋₁/dt` — **exactly the code**, and self-consistent with the fact that the frequency-variance increment is 3× the Allan variance for a random walk. Expanding the code's Q in seconds:

  - `Q₁₁ = (h₀/2)Δt + (2/3)π²h₋₂Δt³ + **2ln2·h₋₁Δt²**` vs B&H footnote `(h₀/2)Δt + (2/3)π²h₋₂Δt³ + **2h₋₁Δt²**` → identical h₀ and h₋₂ terms; the flicker term is now the **same power of Δt** and 0.693× the coefficient.
  - `Q₂₂ = 2π²h₋₂Δt + **4.159·h₋₁**` vs footnote `h₀/(2Δt) + **4h₋₁** + (8/3)π²h₋₂Δt` → flicker agrees to **4 %**.

  So the doc's central criticism ("the code adds a term *linear* in Δt where B&H's is quadratic") is **retracted by the current code**: the powers now match. Two residuals remain and must be stated instead:
  1. `Q₂₂` omits the footnote's `h₀/(2Δt)` term. That is *correct* for the model the code claims — B&H's own Eq. (11.3.2) has no S_f term, because in Fig. 11.6 `u₇` enters the phase derivative, not the frequency integrator. But it is numerically enormous: for the caesium template in use (`h₀/2 = 5.0e−20`, back-derived from the measured `Q(b,b) = 4.49379e−3 m²` ÷ c²), `h₀/(2Δt) = 5.0e−20` against the code's whole `Q₂₂/c² = 4.159e−25` — a factor **1.2e5**. The repo's standing conclusion that "no Q magnitude restores drift ±3σ coverage" was A/B-tested only against the old `2ln2·h₋₁` term, never against the footnote's `h₀/(2Δt)`. The claim should be narrowed accordingly.
  2. The equivalence is exact only at the τ used to build it. Because `q2_ffm ∝ 1/dt`, `Q₂₂`'s flicker contribution is `6ln2·h₋₁` **independent of dt** — so over N steps the filter accumulates `N·6ln2·h₋₁` of frequency variance (a random walk) where true flicker grows only logarithmically. Over a 3601 s arc at dt = 1 s the filter is therefore increasingly *conservative* on the drift state by a factor ~N/ln N. Direction-safe, but it must not be described as "carrying flicker".

### Empirical RTN acceleration states — NEW, untraced by the doc

- **Code**: `+filter/ReverseGNSSEKF.m:575–609` (operator-split state propagation, exact GM integrals `c1 = τ(1−e^{−dt/τ})`, `c2 = τ(dt − c1)`, l. 581–583), `1376–1385` (F block `F(rv, a) = [c2·s·B; c1·s·B]`, `F(a,a) = e^{−dt/τ}I`), `1625–1636` (Q block `q = (σ_ss/scale)²(1−φ²)`), `gmAccelIntegrals_` at `2440`, `rtnBasis_` at `2424`. Default **off** (`cfg.estimator.empiricalAccel.enable = false`, `masterConfig.m:338`; τ = 1800 s, σ_ss = 1e−7 m/s²).
- **Status vs doc**: **NEW** — this block landed at `2060e9d`, after the tree the doc was traced against.
- **Verdict**: correct; standard reduced-dynamic filtering with exact GM integrals.
- **Sources**: Wu, S. C., Yunck, T. P., & Thornton, C. L. (1991). Reduced-dynamic technique for precise orbit determination of low Earth satellites. *Journal of Guidance, Control, and Dynamics, 14*(1), 24–30. [EXTERNAL] — the canonical source for exponentially-correlated empirical accelerations in the RTN frame. Brown & Hwang (1997), Eq. (5.3.16), p. 202 (transcribed) for the `σ²(1−e^{−2βΔt})` discrete GM noise the Q block uses.
- **Critical analysis**: Three things done right: the state, the STM column and the GM decay all use the **same** exact integrals rather than agreeing only as dt→0 (l. 583–585); the RTN basis is built from the **estimated** r, v, not truth (l. 587–589) — clean against the "no truth in the estimator" constraint; the state is normalised by `empAccScale_` so its steady-state variance is exactly 1, which is what makes it survive the PSD guard (see `7b877a2`, "restate why empAccScale_ exists now the PSD guard no longer floors"). The operator-splitting error is self-bounded in-file at ~5e−8 m/step. Caveat for the paper: with a 1e−7 m/s² prior and a 1800 s correlation time, this state can absorb exactly the kind of constant radial bias the standing memory `project_empirical_accel_states` says it *cannot* fix ("a constant offset is not an acceleration") — the default-off setting is the honest choice and should stay.

### Declared common-acceleration process-noise group — NEW, and an additive-by-design overlap

- **Code**: `+filter/ReverseGNSSEKF.m:1460–1465`: `Q = Q + declaredCommonProcessNoiseGroup_.ownDiagonalContribution(dt_s, schemaIdx, nx)`, i.e. **added on top of** the `sigma_accel` r/v block written five lines earlier. `+revgnss/CommonProcessNoiseCovarianceGroup.m:131–137,144–152`: `qCommon = σ_common²·[dt³/3, dt²/2; dt²/2, dt]` placed per axis on `[r_a, v_a]`. Set only by `IndependentFleetCoordinator.initialize()` when `correlationNetwork.commonProcessNoiseTreatment == 'declaredCommonAccelerationGroup'`. Default `cfg.estimator.processNoise.commonAcceleration.enable = false, sigma_mps2 = 0` (`masterConfig.m:2066–2068`).
- **Status vs doc**: NEW (landed at `0ce01f7`, at the very boundary of the doc's trace).
- **Verdict**: partially correct — the algebra is right and deliberately shares one implementation with the joint reference; the *semantics* invite a double count.
- **Sources**: none required (internal construction); the design intent is stated in-file at `CommonProcessNoiseCovarianceGroup.m:14–27`.
- **Critical analysis**: The class docstring is explicit that this reproduces `addJointAssetProcessNoise_`'s diagonal placement "by construction, not two independently-written formulas kept in sync by a test" — genuinely good engineering. The hazard is interpretive: enabling the group **does not reduce** each leaf's own `sigma_accel`, so the total per-asset acceleration PSD becomes `sigma_accel² + sigma_common²`. Anyone reading the pair as "split the total unmodelled acceleration into a common part and an independent part" would be charging the common part twice. Dormant at defaults (σ = 0), so no shipped number is affected — but the distributed-fleet golden (`507c1f0`) is the first fixture that could turn it on, and the correct guidance is: if `sigma_common` is set, `sigma_accel` must be re-set to `sqrt(sigma_total² − sigma_common²)`.

### Innovation gating

- **Code**: `update()` computes `NIS = nu'*(S\nu)` at `+filter/ReverseGNSSEKF.m:964` **after** unconditionally applying the measurement; no row is ever rejected. The only innovation gate in the estimation path remains `+revgnss/DiffAttitudeBuilder.m:443` (`if abs(z_row − h_row) > 1.0` → `info.rejectedRows++`, `continue`) and its L2 twin at `:470` (`if abs(...) <= 1.0` to admit).
- **Status vs doc**: **STILL-VALID** — line numbers 443 and 470 are exact at HEAD, and a repo-wide grep confirms `chi2inv` appears **only** inside `ChiSquareConsistency` (a diagnostic), never in a measurement path.
- **Verdict**: partially correct as a design choice / unsourced as a threshold.
- **Sources**: Bar-Shalom, Y., Li, X. R., & Kirubarajan, T. (2001). *Estimation with applications to tracking and navigation: Theory, algorithms and software*. Wiley. [EXTERNAL] — §5.4 defines ε_ν = νᵀS⁻¹ν as χ²(n_z), which is simultaneously the consistency statistic and the standard gating statistic.
- **Critical analysis**: Unchanged. Worth adding: the 1 m gate is now provably load-bearing in a way the doc did not note — `ReverseGNSSSimulation.m:975–978` documents that the IF slip detector is **disabled** on the diffAtt path precisely because diffAtt injections cause O(deg) attitude changes that the detector misreads, so the unsourced 1 m threshold is the *only* outlier protection on those rows. That is a single unsourced constant carrying the whole editing burden for one channel.

### NEES: per-block and joint, in the MEKF error space

- **Code**: `+filter/ReverseGNSSEKF.m:968–1027` (`computeNEES`) — per-block `neesBlock_` (file-local helper at `2503–2512`, `err'*(P_blk\err)/dof` with `rcond > 1e-15`), joint core over the concatenated index set at `1018–1026`. Attitude error via `attitudeSmallAngleError_` at `1045–1059`: `dC = C_nom'·C_tru; aErr = 0.5·[dC(3,2)−dC(2,3); dC(1,3)−dC(3,1); dC(2,1)−dC(1,2)]`. Mirrored in `+data/SimulationDataStore.m:1071–1105` for the per-epoch record, where `NEES_clk` carries the relativistic domain correction (l. 1088–1089).
- **Status vs doc**: DRIFTED (838–897 → 968–1027; 915–929 → 1045–1059).
- **Verdict**: correct.
- **Sources**: Bar-Shalom, Li & Kirubarajan (2001), §5.4 [EXTERNAL] — NEES ε = x̃ᵀP⁻¹x̃ ~ χ²(n_x), E[ε] = n_x.
- **Critical analysis**: The vee-operator form is the correct first-order extraction of the rotation vector from a small error DCM, and taking the attitude error in P's own space rather than by Euler subtraction is right. New observation the doc missed: `SimulationDataStore.m:1088–1089` scores the clock NEES on `(x(b_rx) + relClockBias_m) − truth`, i.e. it *adds back* the modelled relativistic ramp before differencing. That is correct — the state carries only the residual (see `ScenarioFactory.m:110–113`) — and it is model-side data (`RelativisticClockCorrection.bias_m(ekf.cfg, t_s)`, a published constant times t), not truth. **No truth leak.** Without the correction the clock NEES would score the whole 581 m ramp against a covariance that never claimed it, exactly as the in-file comment says.

### Per-channel NIS dof accounting (commit `d42ee0d`) and the residual OVERALL mismatch

- **Code**: `+revgnss/ConsistencyStatistics.m:23–72` — `codeDof = d_.meas.nCodeRows`, `doppDof = nDopplerRows`, `carrRows` from `carrierDof_` (l. 155–179, prefers the **stored** `nCarrierRows`, falls back to subtraction only for a pre-`nCarrierRows` store and labels the source), `twttRows` from `rowCount_`; `unclassified = max(allRows − code − dopp − carr − twtt, 0)` **reported**, never absorbed (l. 66–68). Numerators: `+data/SimulationDataStore.m:1033–1069`, S-normalised from Stage-57 (`entry.NIS_code = errStruct.codeNisS57`, which merges `code|ifCode` at `ReverseGNSSSimulation.m:882–883`), R-only `localNis_` only as a fallback. `EkfInnovationAccounting.nisForMask_` (l. 199–229) uses the **submatrix of S**, `y_subᵀ(S_sub \ y_sub)`.
- **Status vs doc**: **NEW** — postdates the doc entirely.
- **Verdict**: correct for code / carrier / doppler / twoWay; **the OVERALL row is still mis-normalised** (see below).
- **Sources**: Bar-Shalom et al. (2001), §5.4 [EXTERNAL] — a marginal of a Gaussian is Gaussian with the sub-covariance, so `y_subᵀ S_sub⁻¹ y_sub ~ χ²(|sub|)` exactly; the submatrix form (not a Schur complement) is the right one.
- **Critical analysis**: I checked the numerator/denominator *scopes* pairwise, which is the only way this class of bug is caught:
  - **code**: numerator masks `codeMask | codeIonoFreeMask`; denominator is `entry.numPseudorangeMeasurements = errStruct.nPseudorange = M`, and `CodeMeasurementBuilder.m:707,991` set `nPseudorange = M` for both the raw and the IF branch. **Scopes agree.** ✓
  - **doppler**: `sum(measType == 'doppler')` on both sides. ✓
  - **carrier**: `sum(measType == 'carrier')` on both sides (`SimulationDataStore.m:943`). ✓
  - **twoWay**: `sum(measType == 'twoWayTimeTransfer')` on both sides. ✓
  - **OVERALL**: numerator is `d_.consistency.NIS` = `entry.NIS` = the value returned by `obj.ekf.update(z_ekf, h_ekf, H_ekf, R_ekf)` — the **augmented** stack, gauge rows included. Denominator is `d_.meas.nRows = numel(z)` — **physical only**, as `ReverseGNSSSimulation.m:820–822` states explicitly ("z/h/H/R stay physical-only for diagnostics (no count inflation)"). **Scopes disagree whenever gauge rows exist.**

  This is the *same defect class* `d42ee0d` fixed one layer down, and the honest decomposition is already stored: `entry.physicalNIS57` / `entry.physicalDof57` / `entry.gaugeNIS57` / `entry.gaugeDof57` (`SimulationDataStore.m:1136–1160`) — recorded every epoch and never read by `ConsistencyStatistics`. "Stored all along; simply not read", again.

  Size: gauge rows appear only when `estimateTowerClocks = true` **and** `cfg.clock.gauge.mode ∈ {fixReferenceTower, meanGroundClockGauge}` (`ReverseGNSSEKF.m:1894–1896, 1918+`), adding 2 rows (bias + drift). Against the golden's 105 physical rows that is a **+1.9 %** inflation of OVERALL NIS/dof — small, systematic, and in the *optimistic* direction, i.e. the one the table's own legend says matters. Dormant at the resolved default (`estimateTowerClocks = false`), which is why `91faccb`'s printed table shows a closing budget. It is live on every tower-clock ladder rung.

  Two further gaps, both reachable today:
  - `getNISByType` (`SimulationDataStore.m:1883–1896`) exposes `C.starTracker` and `C.starTrackerDof`, but `ConsistencyStatistics` builds **no group for them** and `formatNisTable`'s `rows` list (l. 112–116) omits the channel. With the star tracker ON in the resolved default, the one observable that actually constrains attitude is the one channel the per-channel verdict is silent about. Same pattern, one layer up.
  - `EkfInnovationAccounting.classifyRows`'s switch (l. 53–61) has **no case that ever sets `carrierIonoFreeMask`** — there is no `'ifCarrier'` label anywhere in the tree (`MeasurementStackMetadata.m:39–52` emits only `code`/`ifCode`/`doppler`/`carrier`). So `carrierIonoFreeNIS`/`Dof` are permanently `NaN`/0 and `compact()` publishes them (l. 169–178). Inert reporting field, not a numerical bug.

### The per-channel NIS verdict table (commit `91faccb`) and its N_eff column

- **Code**: `+revgnss/ConsistencyStatistics.m:96–149` (`formatNisTable`) and `216–253` (`groupStat_`). Verdict banding: `r < 1` → "conservative 1/r×" with `σ× = √(1/r)`; `r ≥ 1` → "OPTIMISTIC r×" with `σ× = √r`; **then** overridden to "consistent" if `0.8 ≤ r ≤ 1.25` (l. 138). AR(1) effective sample size at l. 236–244: `ρ = Σx_kx_{k+1}/Σx_k²` on the mean-removed series, clipped to ±0.999, `nEff = N(1−ρ)/(1+ρ)`. Printed from `+revgnss/ReportRunner.m:3552–3553` and stored as `summary.arcNisTable`.
- **Status vs doc**: **NEW**.
- **Verdict**: correct as a diagnostic; the bands are heuristics and the code says so.
- **Sources**: Bar-Shalom et al. (2001), §5.4 [EXTERNAL] for E[NIS]/dof = 1. Thiébaux, H. J., & Zwiers, F. W. (1984). The interpretation and estimation of effective sample size. *Journal of Climate and Applied Meteorology, 23*(5), 800–811. [EXTERNAL] — the standard `N_eff = N(1−ρ₁)/(1+ρ₁)` AR(1) form as implemented.
- **Critical analysis**: This is the most valuable addition to the domain since the doc was written, and the commit message is unusually honest (it retracts the author's own "two-way is 31× over-charged" claim as a `clk006` deterministic-tower-clock artefact). Four specifics:
  1. `nisPerDof = mean(NIS)/mean(dof)` (l. 249) is a **ratio of means**, not the mean of per-epoch ratios. That is the *right* choice (it is the pooled χ² estimator) and differs from `fractionInside` at l. 250–251, which uses per-epoch ratios. Both are reported; only the first is the statistic.
  2. The `nEff` estimate is applied to the NIS series, whose lag-1 autocorrelation is not the same as the autocorrelation of the underlying error — a NIS series is a squared quantity, so ρ(NIS) ≈ ρ(error)² for a Gaussian. **The reported N_eff is therefore an over-estimate of the independent information** (measured ρ = 0.09–0.30 on code/carrier/doppler implies error autocorrelations of ~0.30–0.55, i.e. N_eff on the error is ~2–4× smaller than printed). The column's warning is right in direction and optimistic in magnitude.
  3. `N_eff` is computed but **never used**: no band widens, no verdict is suppressed. `twoWay` at ρ = 0.7254 / N_eff = 573 still prints a verdict in the same typeface as `doppler` at N_eff = 3006. The docstring says "a channel with N_eff of a few cannot support a confident verdict" — nothing enforces that.
  4. `formatNisTable` reads `g.lag1Autocorr` and `g.nEff` unguarded (l. 140), but `defaultResult_`'s `empty` struct (l. 193–195) **omits both fields**. A channel that never reaches `groupStat_` but does reach the finite-`nisPerDof` branch would throw. Unreachable today (the `empty` sentinel always has `nisPerDof = NaN`, which takes the early-continue branch at l. 125), but it is one field-order change away from a crash in the reporting path.

### `ChiSquareConsistency` — two-sided bands, Wilson–Hilferty and Acklam fallbacks

- **Code**: `+revgnss/ChiSquareConsistency.m:21–47` (`bounds`, `normalisedBounds`, `inBand`), `58–69` (`quantile_`: `chi2inv` when available, else Wilson–Hilferty `q = dof(1 − t + z√t)³`, `t = 2/(9dof)`), `71–99` (`normInv_`, Acklam's 19-coefficient rational approximation).
- **Status vs doc**: **STILL-VALID** — every line reference is exact at HEAD (21–47, 64–68, 74–98).
- **Verdict**: correct.
- **Sources**: Wilson, E. B., & Hilferty, M. M. (1931). The distribution of chi-square. *Proceedings of the National Academy of Sciences, 17*(12), 684–688. [EXTERNAL]. Acklam, P. J. (2003). *An algorithm for computing the inverse normal cumulative distribution function*. [EXTERNAL]. Bar-Shalom et al. (2001), §5.4 [EXTERNAL].
- **Critical analysis**: Unchanged and correct. The class docstring's own statement — "**the common 'NIS ≈ M' heuristic only checks the MEAN and passes a mildly inconsistent filter**" (l. 10–12) — is worth quoting in the thesis, because the shipped single-run verdict (`nisStatus_`, l. 270–275: warn below 0.5, warn above 2.0) is exactly the mean-only heuristic the class exists to replace. The two-sided machinery is only exercised by `MonteCarloConsistency`, which is off by default (see next).

### `MonteCarloConsistency` — correct architecture, one dead gate, one over-counted dof

- **Code**: `+revgnss/MonteCarloConsistency.m:25–159`. Per-seed: draws the initial error from P0 (l. 74–80), varies `simulation.seed` and `mcSeedOffset`, runs the real pipeline, pools post-burn-in per-epoch NIS against `sum(measurement rows)` (l. 95–97) and 3× the per-dof position NEES against 3 dof/epoch (l. 99–105, the memorialised R-7 fix), and pools **one time-mean per seed** for the centroid gate (l. 108–122). Bands from `ChiSquareConsistency` at l. 188–197. Default `cfg.report.monteCarlo.enable = false` (`masterConfig.m:79`, restated `3494`).
- **Status vs doc**: **SUPERSEDED in part.**
- **Verdict**: partially correct — the NIS/NEES pooling is right in form but over-counts dof; the centroid gate is now structurally unreachable.
- **Sources**: Bar-Shalom et al. (2001), §5.4 [EXTERNAL].
- **Critical analysis**:
  1. **The Guard-C centroid gate is dead.** `MonteCarloConsistency` calls `diag.getCentroidNEES()`; `SimulationDataStore.getCentroidNEES` (l. 1874–1877) returns `nan(1, nEpochs)` when `cn_NEEScen_` is empty, and a repo-wide grep finds **four** occurrences of `cn_NEEScen_` in the main tree — a property declaration (l. 236), the getter (l. 1875–1876) and one export (l. 2231). **It is never written.** The upstream producer, `ReverseGNSSEKF.computeSwarmNEES` (l. 1030–1042), is explicitly RETIRED by the federated-swarm pivot and "always returns the empty/NaN sentinel struct". So `centroidAvailable` is always false and `centroidVerdict` is always `'notApplicable'`. The doc's praise of the centroid gate as "the authoritative cross-seed absolute-trustworthiness test" describes machinery that can no longer fire, and its careful one-mean-per-seed pooling protects nothing.
  2. **The NIS/NEES pooling contradicts the centroid gate's own reasoning.** Lines 42–48 argue at length that per-epoch pooling would "over-count dof and narrow the band into a false verdict" because the samples are time-correlated — and then lines 95–105 pool NIS and NEES exactly per-epoch. With `91faccb`'s own measured ρ₁ = 0.30 on the overall NIS, N_eff/N ≈ 0.54, so the two-sided band is **≈1.36× too narrow**; on the `twoWay` channel (ρ = 0.7254) it would be ≈2.5× too narrow. The direction is dangerous: a too-narrow band manufactures "inconsistent" verdicts, and (worse) an in-band verdict from a too-narrow band reads as stronger evidence than it is.
  3. **The MC setup is matched by construction.** `cfg.estimator.initialError.* = P0 * randn(rs,...)` (l. 75–80) draws the truth error from the *same* P0 the filter is initialised with, and `ScenarioFactory.m:88–113` seeds `x0 = truth + perturbation`. That is the textbook MC-NEES setup and is *correct* — but it means the initial NEES is 1 by construction, so early-epoch consistency is not evidence about anything. `initErrorScale > 1` is the provided negative control and should be reported alongside any consistency claim.

### MEKF: multiplicative error quaternion, injection, covariance reset

- **Code**: `+revgnss/AttitudeErrorStateKinematics.m` — `deltaQuat` **60–72** (first-order `[1; δθ/2]` below 1e−10), `injectRight` **74–82**, `propagateQuatBodyRate` **84–100**, `quatMul_` **160–168**. In the filter: nominal quaternion propagated / error state held at zero in predict (`ReverseGNSSEKF.m:614–627`); error-state F blocks `F(θ,θ) = I − [ω]×dt`, `F(θ,ω) = I·dt`, and with gyro bias `F(θ,b_g) = −I·dt`, `F(θ,ω) = 0` (l. 1310–1330); injection + reset after Joseph at l. 838–893, with `resetJacobian = eye(3) − 0.5*skewDelta` (l. 853) applied as `P(θ,:) ← G·P(θ,:)` then `P(:,θ) ← P(:,θ)·G'` (l. 857–858) and a re-symmetrisation (l. 872); 10° guard from `cfg.estimator.attitude.maxErrorStateInjection_rad` (l. 839–840, 860–866); measurements evaluated at the nominal attitude via `getMeasurementState` (l. 441–456); `initState` converts `x0(euler)` into `nominalQuat_wxyz` and zeroes the error state (l. 418–438). Constructor refuses gyro-bias estimation on the Euler path.
- **Status vs doc**: DRIFTED for `ReverseGNSSEKF` (533–538 → 614–627; 1170–1190 → 1310–1330; 750–797/763–770 → 838–893/850–858; 395–410 → 441–456; 347–353 → constructor, see below); **STILL-VALID** for every `AttitudeErrorStateKinematics` line (60–72, 74–82, 160–168 are exact).
- **Verdict**: correct — a textbook local (body-frame, right-multiplicative) MEKF, including the second-order covariance reset.
- **Sources**: Markley, F. L. (2003). Attitude error representations for Kalman filtering. *Journal of Guidance, Control, and Dynamics, 26*(2), 311–317. [EXTERNAL; NTRS 20020060647]. Solà, J. (2017). *Quaternion kinematics for the error-state Kalman filter* (arXiv:1711.02508). [EXTERNAL] — Eqs. 282c (injection), 284–285 (reset), 293 (reset Jacobian `I − [½δθ̂]×`). *These two are carried forward from the previous pass; I did not re-open the sources in this round.* **Instead I re-derived the reset Jacobian independently**, which is stronger evidence: with `q = q_nom ⊗ Exp(δθ)` and `q_nom⁺ = q_nom ⊗ Exp(δθ̂)`, we need `Exp(δθ⁺) = Exp(−δθ̂) ⊗ Exp(δθ)`; BCH to first order gives `δθ⁺ = δθ − δθ̂ − ½ δθ̂ × δθ`, hence `∂δθ⁺/∂δθ = I − ½[δθ̂]×` — **exactly** l. 853.
- **Critical analysis**: The algebra checks out end to end. Two verifications the doc did not do:
  1. **The reset is a full congruence, not a half-application.** Line 857 rewrites the θ rows *including* the θ×θ block, and line 858 then post-multiplies the θ columns of the already-modified matrix, so `P(θ,θ) → G·P(θ,θ)·Gᵀ`, `P(θ,rest) → G·P(θ,rest)`, `P(rest,θ) → P(rest,θ)·Gᵀ`. Correct. A common bug (applying only the rows) is absent.
  2. **`Ω(ω)` in `propagateQuatBodyRate` is the right-multiplication form.** Expanding `q ⊗ [0;ω]` gives scalar row `−qᵥ·ω` and vector rows `q_w ω + qᵥ×ω = q_w ω − [ω]× qᵥ`, i.e. `Ω = [0, −ωᵀ; ω, −[ω]×]` — matching l. 94–97 element for element. The truth side (`AttitudeQuaternion.propagateBodyRate`, l. 84–94) uses the **exact** exponential `q ⊗ Exp(ω dt)`; the filter side uses first-order + renormalise. At GEO rates (ω ≈ 7.29e−5 rad/s, dt = 1 s) the per-step discrepancy is O((ωdt)²/8) ≈ 6.6e−10 rad — negligible, and the doc's ~2.7e−9 figure is the same order.
  3. **`initState` handles the seeding correctly** (l. 421–434): `x0(euler)` is converted to `nominalQuat_wxyz` and the error state zeroed, so the ScenarioFactory's Euler-domain perturbation lands in the nominal, not in the error state. One convention conflation remains: `P0_euler_rad` is used directly as the **body-frame small-angle** covariance without the `∂δθ_B/∂δ(rpy)` Jacobian. I checked whether this matters at the shipped attitude: for a nadir-pointing GEO (`AttitudeKinematics.nadirEulerFromEcef`, l. 120–166) at longitude 0 the DCM is `[[0,0,−1];[1,0,0];[0,−1,0]]`, giving roll = −90°, pitch = 0, yaw = +90°, at which `T = [1,0,0; 0,0,1; 0,−1,0]` is **orthogonal with det = +1**. An isotropic Euler covariance therefore maps to an isotropic body covariance *exactly*. The conflation is harmless at the shipped attitude and would only bite at a non-nadir attitude — worth one sentence, not a defect.
  4. `attitudeInjectionCount` (l. 873) increments per `update()` **call**, and there are up to three sequential updates per epoch (main stack, star tracker at `ReverseGNSSSimulation.m:943–946`, diffAtt at `:991`). The counter is therefore an update count, not an epoch count, and `maxAttitudeInjectionNorm_rad` is a per-update maximum. Reporting must say so.

### `estimatedEuler_` reading the MEKF error state — still fixed

- **Code**: `+revgnss/GroundDifferencedRotationSolver.m:616–679` (`estimatedEuler_`). Reads `a.history.nominalQuat_wxyz` first (l. 634–652); the legacy `history.x` Euler path is entered only when the quaternion history is absent, and an all-zero block is **refused** with reason `eulerHistoryAllZeroLikelyErrorState` (l. 674–679). The defect is memorialised verbatim in the docstring (l. 617–627). The DiffAtt call site uses `getMeasurementState()` (`ReverseGNSSSimulation.m:979–980`).
- **Status vs doc**: **STILL-VALID** — 616–679 and 674–679 are exact at HEAD.
- **Verdict**: correct.
- **Sources**: internal audit trail (memory `project_ground_rotation_audit_findings`); the in-file docstring is the primary record.
- **Critical analysis**: Unchanged. The doc's residual caution still applies verbatim: **any pre-fix ground-differenced-rotation number with `leverArm.mode='estimatedAttitude'` is suspect and must be re-dated against this commit.**

### Gyroscope model: ARW, RRW, units, and the grade of the defaults

- **Code**: `+models/+sensors/IMUModel.m:145–166` (truth: `ω_meas = ω_B/I + b_g + (ARW/√dt)·randn`; bias walk `b_g += RRW·√(biasStep)·randn`; observation carries `R = (ARW²/dt)I` and bias PSD `RRW²I`), `179–192` (Earth-rate bridge `ω_B/I = ω_B/E + C_B_Eᵀ ω_E/I`), `196–203` (separate `mt19937ar` streams at `seed`, `seed+1`), disclosure of what is not modelled at `36–37`. Same structure in `GyroscopeMeasurementModel.m:61–95`. Filter side `ReverseGNSSEKF.applyGyroProcessNoise_` at `2220–2234`; strapdown `ω = ω_gyro − b̂_g` at `692–701`/`predict`; inverse Earth-rate bridge at `470–496`.
- **Status vs doc**: **STILL-VALID** for every `IMUModel` line (145–166, 179–192, 196–203, 36–37 exact) and `GyroscopeMeasurementModel` (61–95 exact); **DRIFTED** for the filter side (2056–2070 → 2220–2234; 475–482 → 692–701; 424–449 → 470–496) and for the config (`masterConfig.m:1670–1676` → **370–378**; `realismGradeConfig.m:373–374` → **217–229** with the value table at **419–423**).
- **Verdict**: correct equations, matched truth/filter parameters, **defaults are MEMS/industrial-class**.
- **Sources**: IEEE. (1997). *IEEE standard specification format guide and test procedure for single-axis interferometric fiber optic gyros* (IEEE Std 952-1997). [EXTERNAL]. NASA. (2024). *State-of-the-art of small spacecraft technology*. NASA Ames. — "**Table 5-9 only includes bias stability and angle random walk for gyros, and bias stability and velocity random walk for accelerometers, as these are often the driving performance parameters.**" (p. 158); Table 5-9 (p. 159) rows verified from the PDF text layer: Honeywell **MIMU (RLG): bias stability 0.05 °/hr, ARW 0.01 °/√hr**; Honeywell **HG1700 (RLG): 1.000 °/hr (1σ), ARW 0.125 °/√hr**; **L3 CIRUS (FOG): ARW 0.100 °/√hr**; **Northrop Grumman LN-200S (FOG): 1.000 °/hr, ARW 0.070 °/√hr**. Farrenkopf (1978) [EXTERNAL].
- **Critical analysis**: Unit conversions re-done digit by digit and confirmed against the doc:

  | quantity | SI default | converted | realism grade | converted |
  |---|---|---|---|---|
  | ARW | 1e−4 rad/√s | **0.34377 °/√h** | 2e−4 | **0.68755 °/√h** |
  | RRW | 1e−6 rad/(s·√s) | **12.3758 °/h/√h** | 3e−6 | **37.127 °/h/√h** |
  | initial bias 1σ | 1e−5 rad/s | **2.06265 °/h** | 3e−5 | **6.1879 °/h** |

  (ARW: 1e−4 × 180/π × 60 = 0.343775; RRW: 1e−6 × 180/π × 3600 × 60 = 12.3759; bias: 1e−5 × 180/π × 3600 = 2.06265.) Against Table 5-9 the default ARW is **2.75× worse than HG1700**, **4.9× worse than LN-200S**, **34× worse than MIMU**; the 2.06 °/h initial bias is **41× worse than MIMU** and 2× worse than HG1700. "MEMS/industrial" is the right label; "GEO-grade IRU" is not.

  Two things the doc missed. (i) The realism grade **does not only raise ARW**: it also triples RRW (1e−6 → 3e−6) and the initial bias sigma (1e−5 → 3e−5). Quoting "realism grade raises ARW to 2e−4" understates the degradation. (ii) `realismGradeConfig.m:221–228` sets `imu.truth.*` and `imu.filter.*` to the **same values** — confirmed live in the resolved config (`truth.arw = filter.arw = 1e−4`, `truth.rrw = filter.rrw = 1e−6`). So the gyro is a **matched-parameter (inverse-crime) sensor in both grades**: the estimated gyro bias converging to the truth bias is a property of the construction, not evidence about a real IRU. Bias instability (flicker floor) remains unmodelled, so RRW alone makes the bias wander unboundedly — over-stating long-arc bias growth while under-stating the short-term floor. All of this is disclosed in-file; none of it is disclosed in the doc.

### Star-tracker model and its EKF rows

- **Code**: `+models/+sensors/StarTrackerMeasurementModel.m:112–125` (measured `q_I_S = (q_I_B_true ⊗ q_B_S_true) ⊗ δq(n)`, noise drawn by eigendecomposition at `220–225`), alignment truth propagation at `190–211` (fixed bias + deterministic drift rate + random walk), validity windows and the `fixedCalibration`-cannot-carry-uncertainty assert at `177–182`. Residual: `+models/+sensors/StarTrackerObservationModel.m:20–51` — `Log(q_I_S_pred⁻¹ ⊗ q_I_S_meas)` in S; `model.attitudeErrorJacobian = C_B_S_modelᵀ` (l. 34); the correlation policy at l. 48–49. EKF wiring: `+revgnss/AttitudeSensorSuite.m:121–178` — 3 rows/spacecraft, `H(:,θ) = C_B_Sᵀ` (l. 152), `h = 0` (l. 158), `R = blkdiag(whiteAngularCovariance)` (l. 161); applied as a **separate sequential update** at `ReverseGNSSSimulation.m:941–948`.
- **Status vs doc**: **STILL-VALID** for the model/observation/suite line references (112–125, 220–226→220–225, 177–182, 20–51, 48–49, 121–178 all exact); **DRIFTED** for the config (`masterConfig.m:248` → **356**; `realismGradeConfig.m:373` → **219–220 / 420**).
- **Verdict**: correct residual and Jacobian; **the noise default is isotropic and the entire alignment-calibration model is inert**.
- **Sources**: NASA (2024), Table 5-5 "Star Trackers Suitable for Small Spacecraft" (p. 150), verified from the PDF text layer: **Blue Canyon Standard NST 6″ cross-axis / 40″ twist (3σ)**; **Berlin Space Technologies ST400 15″/150″**; **Arcsec Sagitta 6″/30″**; **Redwire Star Tracker 10/27″ / 51″**; NanoAvionics ST-1 8″/50″; Rocket Lab ST-16RT2 5″/55″; Ball CT-2020 1.5″/1″. Markley (2003) [EXTERNAL] for the residual-in-sensor-frame convention. ECSS-E-ST-60-10C (2008), *Control performance* — the AKE/APE pointing-error index framework under which per-axis anisotropy must be carried.
- **Critical analysis**: The measurement model is right and the sequential-update placement is right (the star tracker's `S` correctly uses the posterior P of the main update, so the two-block sequential decomposition is exact for independent R). Corrections and additions to the doc:
  1. **The anisotropy comparison must be stated in matched sigmas.** The default is `whiteAngularSigma_rad = deg2rad(10/3600)` = 4.84814e−5 rad = **10″ 1σ per axis = 30″ 3σ per axis**. Against Table 5-5 (3σ columns): 30″ is **5× conservative** against an NST cross-axis (6″) but **1.33× optimistic** against its twist (40″) and **5× optimistic** against ST400 twist (150″). The doc's "roughly in-family with its 40″ twist" is too generous — the isotropic default is optimistic on twist, which is the axis that matters least for pointing but most for a yaw-like lever-arm projection onto tower baselines. Realism grade (30″ 1σ = 90″ 3σ) is conservative on cross-axis and in-family on twist.
  2. **The whole alignment-calibration model is inert at defaults.** `masterConfig.m:359–369`: `fixedAlignmentBias_rad = 0`, `alignmentDriftRate_radps = 0`, `alignmentDriftRandomWalk = 0`, `drawAlignmentFromCalibrationCovariance = false`, `calibration.covariance_rad2 = zeros(3)`, `treatment = 'fixedCalibration'`. `realismGradeConfig.m:217–229` changes **only** `whiteAngularSigma_rad` and the IMU triple — it does not enable any alignment error. So `alignmentErrorQuaternion` is identity for the entire run, `q_B_S_truth ≡ q_B_S_model`, and the sophisticated consider-parameter machinery (stable identifier, cross-epoch correlation, validity windows, the three treatments) contributes **nothing to any shipped number**. It is correctly built and completely unexercised; the paper must not present it as a modelled error source.
  3. **No alignment covariance is added to R** — `AttitudeSensorSuite.m:161` uses `model.whiteAngularCovariance_rad2` only, honouring `StarTrackerObservationModel.m:48–49` ("*alignment is a persistent calibration parameter; do not add its covariance as independent noise at every epoch*"). **Correct, and explicitly not a double count.** But the corollary is that if item 2 were ever switched on, the alignment error would be an unmodelled, uncharged bias in the residual with no consider term anywhere — the interface promises a treatment it does not implement.
  4. No FOV/occultation model; availability is an external flag (`isStarTrackerOutage_`, l. 297).

### Attitude kinematics and quaternion conventions

- **Code**: `+revgnss/AttitudeQuaternion.m:10–19` (`convention()`), `32–40` (Hamilton product), `47–53` (DCM), `55–68` (`fromRotationVector`, small-angle `scale = 0.5 − θ²/48`, `q_w = 1 − θ²/8`), `70–82` (`toRotationVector`, sign canonicalisation `q(1) < 0 → −q` at l. 72–74), `84–94` (exact `propagateBodyRate`), `96–108` (ECEF↔inertial bridges). `+revgnss/AttitudeKinematics.m:15–36` (`C = Rz(ψ)Ry(θ)Rx(φ)`), `38–66` (`T`), `172–182` (`convention()`), `203–207` (`gimbalMetric`). `+revgnss/AttitudeErrorStateKinematics.m:23–37` / `39–49` (Euler↔quaternion, asin clamp at l. 45).
- **Status vs doc**: **STILL-VALID** for `AttitudeQuaternion` and `AttitudeErrorStateKinematics` (10–19, 32–40, 61–63, 72–74, 84–94, 96–102, 23–37, 39–49 exact) and for `AttitudeKinematics.bodyToEcefRotation`/`eulerRatesFromBodyRates` (15–36, 38–66 exact); **DRIFTED** for `gimbalMetric` (155–158 → **203–207**).
- **Verdict**: correct — one convention, machine-readable, implemented consistently across all four files.
- **Sources**: Solà (2017) [EXTERNAL] — "*CAUTION: Not all quaternion definitions are the same*", §1.1 (carried forward, not re-opened this round). Wertz, J. R. (Ed.). (1978). *Spacecraft attitude determination and control*. Reidel. [EXTERNAL] — App. E for the ZYX kinematic matrix.
- **Critical analysis**: Digit-checks redone. `eulerToQuatZYX`: `qw = cy cp cr + sy sp sr`, `qx = cy cp sr − sy sp cr`, `qy = sy cp sr + cy sp cr`, `qz = sy cp cr − cy sp sr` — the standard ZYX closed form ✓. `fromRotationVector` small-angle branch: `sin(θ/2)/θ = ½ − θ²/48 + O(θ⁴)` ✓ and `cos(θ/2) = 1 − θ²/8 + O(θ⁴)` ✓. Two independent `convention()` structs (`AttitudeQuaternion.m:10–19`, `AttitudeKinematics.m:172–182`) make the Hamilton / scalar-first / body-to-A choice *testable* rather than commented — the strongest single design feature in this domain. The sign-canonicalisation asymmetry (`toRotationVector` canonicalises, `quatNormalize` does not) is real, harmless (all consumers are sign-agnostic), and a reviewer will ask about it.

### Euler-rate Jacobian (analytic) and the gimbal guard — and a guard that does not guard

- **Code**: `+revgnss/AttitudeKinematics.m:73–105` (`eulerRateJacobian`): with `a = sr·ω₂ + cr·ω₃`, `b = cr·ω₂ − sr·ω₃`, `J = [tp·b, sec²·a, 0; −sr·ω₂ − cr·ω₃, 0, 0; b/cp, (tp/cp)·a, 0]`; `cp` clamped by `sign(cp + eps)*1e-6` (l. 95–97) and `tp = sp/cp` recomputed **from the clamped cp** (l. 98). Used as `F(eul,eul) = I + dt·J` at `ReverseGNSSEKF.m:1337–1338`. `eulerRatesFromBodyRates` at `38–66` builds `T = [1, sr·tp, cr·tp; 0, cr, −sr; 0, sr/cp, cr/cp]`.
- **Status vs doc**: **STILL-VALID** (73–105 exact; the filter call site drifts 1197–1198 → 1337–1338).
- **Verdict**: correct for the Jacobian; **the guard inside `eulerRatesFromBodyRates` is defective**.
- **Sources**: Wertz (Ed.) (1978), App. E [EXTERNAL]; the in-repo symbolic check is `tests/test_euler_jacobian_analytic.m`.
- **Critical analysis**: Every entry re-differentiated by hand and confirmed: row 1 `∂/∂φ = tp(cr ω₂ − sr ω₃) = tp·b` ✓, `∂/∂θ = sec²θ(sr ω₂ + cr ω₃) = sec²·a` ✓; row 2 `∂/∂φ = −sr ω₂ − cr ω₃` ✓, `∂/∂θ = 0` ✓; row 3 `∂/∂φ = b/cp` ✓, `∂/∂θ = a·sp/cp² = (tp/cp)a` ✓; yaw column exactly zero because T is yaw-independent ✓.

  **New defect, in the sibling function.** `eulerRatesFromBodyRates` (l. 53–58) does:
  ```
  if abs(cp) < 1e-6
      warning(...);
      cp = sign(cp) * 1e-6;
      tp = tan(pitch);      % <-- re-assigns tp to the SAME unclamped value as line 51
  end
  ```
  Two problems. (a) `tp = tan(pitch)` inside the guard is a **no-op** — it recomputes exactly what line 51 already set — so `T(1,2) = sr·tp` and `T(1,3) = cr·tp` remain **unbounded** at gimbal lock even though `T(3,2)`/`T(3,3)` are protected. The analytic Jacobian gets this right (`tp = sp/cp` with the clamped `cp`, l. 98); the kinematics function does not. (b) `sign(cp)` returns **0** when `cp` is exactly 0, so the clamp sets `cp = 0` and the next line divides by zero. `eulerRateJacobian` avoids this with `sign(cp + eps)`; `eulerRatesFromBodyRates` does not. Both are legacy-Euler-path-only (the resolved default is `quaternionErrorState`), so no shipped number is affected — but they are a five-character fix and the inconsistency between two functions that share a guard comment is exactly the kind of thing a reviewer finds.

### Observability diagnostics

- **Code**: `+revgnss/AttitudeObservability.m:23–155` (`audit`): lever-arm gate first (`'unobservable-zero-lever-arm'`, l. 91–96), then Frobenius norm (l. 103–110), SVD rank with tolerance `max(M, n)·eps(‖H_att‖)` (l. 113–119), sensitive-row count at 1 % of the max row norm (l. 121–126), classification (l. 128–144), and the process-noise-limited warning at l. 46–50 / 146–154. `leverArmStats` at 157–169 via `ReceiverGeometry`.
- **Status vs doc**: **STILL-VALID** — 23–155, 91–95→91–96, 46–50, 146–154 all exact.
- **Verdict**: correct as an instantaneous audit; the classification scheme remains bespoke and unsourced.
- **Sources**: Montenbruck & Gill (2000), §8.1–8.3 (estimability through the H/Φ structure). Naqvi, N. A., Sun, Y., & YanJun, L. (2012). *Design and mathematical modeling of GNSS based attitude determination of ICUBE-1* (AIAA 2012-4419) — the baseline/lever-arm requirement the rank gates operationalise.
- **Critical analysis**: Unchanged, with one correction that matters: the warning text names `sigma_angAccel` as the parameter that limits the attitude covariance, but as established above, `applyGyroProcessNoise_` **overwrites** the `sigma_angAccel` attitude block whenever `estimateGyroBias` is true — which is the resolved default. The covariance in the shipped configuration is **ARW-limited**, not `sigma_angAccel`-limited. The warning points a reader at the wrong knob. Also unchanged: no multi-epoch observability Gramian `Σ Φᵀ Hᵀ R⁻¹ H Φ`, despite `beginEpochTransition_`/`accumulateEpochTransition_` (l. 2301–2352) retaining every F, K, H and gauge `H_gauge`/`R_gauge_diag` needed to build one.

### `test_clock_truth_matches_filter_q.m` — an inverse-crime test, and honest about it

- **Code**: `tests/test_clock_truth_matches_filter_q.m`. Runs every oscillator in `ConfigFactory.oscillatorCatalog_` (minus `ZERO`) plus one flicker-heavy custom class, 8 seeds × 901 s, and asserts `std(e_b)/√Q₁₁ ∈ (0.75, 1.30)` and `std(e_d)/√Q₂₂ ∈ (0.75, 1.30)` where `e_b = b(k+1) − b(k) − ḃ(k)dt` (l. 74) and `e_d = d(k+1) − d(k)` (l. 75). Then re-checks the algebra `Q₂₂ = (2π²h₋₂ + 6ln2·h₋₁/dt)·dt` at dt ∈ {0.1, 1, 10} (l. 106–119), the metres/seconds scaling by c², and that a deterministic clock is bit-exactly silent (l. 122–129).
- **Status vs doc**: **NEW**.
- **Verdict**: correct as a *pairing* test; **yes, the agreement it proves is an inverse crime**, and the file says so more clearly than any doc would.
- **Sources**: Brown & Hwang (1997), Eqs. (11.3.1)–(11.3.3), p. 429 (transcribed) — the discretisation both sides must implement.
- **Critical analysis**: What the test proves: `ClockModel.step`'s Cholesky draw and `getProcessNoiseQ` implement the **same** discrete 2×2 covariance, and the flicker Allan-equivalence numerically matches the truth's coloured FFM sequence to within 30 % on the frequency channel across all shipped templates. That is a real correctness property — the pre-fix forward-Euler step gave 0.01 for RWFM-dominated classes, a 100× mismatch. What it does **not** prove: anything about whether either side resembles a real oscillator. Truth and filter are, by construction, the same process; a filter tuned to its own truth generator will always look NIS-consistent on the clock channel. The header is admirably explicit that this "guards a correctness property of the clock pairing, nothing more" and forbids closing the ladder-NIS investigation on it (l. 7–16). The one methodological point worth borrowing for the thesis is l. 27–30: `e_b` must have the **tracked** `ḃ` predicted out, because `std(diff(b))` charges Q for the drift state the filter already estimates and returns a spurious 12× on OCXO. Two residual weaknesses: the band is symmetric (0.75–1.30) despite the comment claiming an asymmetric floor for the deliberately-conservative flicker equivalence, and the whole test runs at **dt = 1 s only** for the stochastic part — the `1/dt` scaling of `q2_ffm` is checked algebraically but never against a truth realisation at another dt.

### `test_pertype_nis_dof_accounting.m`

- **Code**: `tests/test_pertype_nis_dof_accounting.m`. T1 asserts `nisCarrierDofSource == 'stored'` **and** guards against a vacuous pass (`subDof > storedDof + 1e-9`, l. 72–74). T2 asserts the budget closes and independently re-derives `nAll == nCode + nDopp + nCarr + nTwtt`. T3 asserts TWTT is its own group. T4 asserts the split reaches `summary.arcNis*PerDof` with the campaign off.
- **Status vs doc**: **NEW**.
- **Verdict**: correct — this is a well-built test.
- **Sources**: n/a (regression guard).
- **Critical analysis**: The anti-vacuity assert at l. 72–74 is the feature that makes this test worth having: it fails loudly if the fixture is ever changed to one where the subtraction and the stored count agree, which is exactly the condition that hid the original defect. T2 re-derives the decomposition from the store rather than trusting `nisRowBudgetCloses`, so the test cannot be satisfied by a bug in the very field it checks. **Gap:** nothing in it exercises the case that is still broken — `estimateTowerClocks = true` with gauge rows, where `numMeasurementRows` and the augmented NIS disagree. Adding `cfg.estimator.estimateTowerClocks = true; cfg.clock.gauge.mode = 'fixReferenceTower'` and asserting `sum(gaugeDof57) == 0 || nisOverall uses physicalNIS57` would close it.

### `test_nis_accumulated_dof.m` — a test that cannot practically fail

- **Code**: `tests/test_nis_accumulated_dof.m`. Runs `ConfigFactory.idealConfig()` for 600 s, then asserts **one-sidedly** `(sumNIS − dof) ≤ 3√(2·dof)`. Header and body both state the ratio is empirically **0.05–0.5** on this fixture. Branch at the end: `dof == 0` → "No valid NIS epochs — vacuous PASS".
- **Status vs doc**: **NEW** (the doc did not audit the tests).
- **Verdict**: partially correct — the statistic and reference are right; the fixture and the one-sidedness make it near-untriggerable.
- **Sources**: Bar-Shalom et al. (2001), ch. 5 [EXTERNAL] — cited in the file for the two-sided test the file then declines to run.
- **Critical analysis**: The file is honest about why (`idealConfig` has truth measurement noise ~0 while R uses a 0.3 m code sigma, so innovations are deterministic convergence residuals, not N(0,S) draws). But the consequence is that the primary NIS regression gate sits at ratio 0.05–0.5 against a threshold at ratio ≈ 1 + 3√(2/dof) ≈ 1.02 for dof ~ 10⁴ — a regression would have to make the filter **20–200× overconfident** before this test noticed. It is a divergence alarm, not a consistency test. Two additional issues: the `dof == 0` branch converts a total instrumentation failure into a PASS, and `dof = sum(getNumMeasurementRows())` is the physical count while `sumNIS` sums the augmented NIS — the same scope mismatch as `nisOverall` (dormant here because `idealConfig` does not estimate tower clocks). `tests/test_filter_consistency_nees_nis.m` does run a genuine two-sided band, but only on a synthetic linear-Gaussian filter (Part B); on the real pipeline (Part C) it too is one-sided (`meanNIS <= hiReal`). `tests/test_mc_consistency_harness.m` is the strongest of the three because it carries a negative control (`initErrorScale` inflated → `mcBad.nisPerDof > 5×`), but it too asserts only `~mc.nisAboveBand`.

---

## Double-count candidates

| # | Name | Location A | Location B | Mechanism | Size | Severity |
|---|---|---|---|---|---|---|
| D1 | **Augmented NIS over physical dof** | `+revgnss/ReverseGNSSSimulation.m:840` (`obj.ekf.update(z_ekf,...)` returns the NIS of physical **+ gauge** rows) → `+data/SimulationDataStore.m:850` `entry.NIS = NIS` | `+data/SimulationDataStore.m:932` `entry.numMeasurementRows = numel(z)` (physical only) → `+revgnss/ConsistencyStatistics.m:70–72` `nisOverall = groupStat_(nisAll, allRows)` | The gauge rows' innovations are counted in the numerator but their degrees of freedom are not counted in the denominator, so OVERALL NIS/dof is inflated by `(nPhys + nGauge)/nPhys`. The honest split is already stored as `entry.physicalNIS57`/`physicalDof57` (`SimulationDataStore.m:1136–1160`) and never read. | 2 gauge rows against 105 physical rows on the golden budget → **+1.9 %**, in the OPTIMISTIC direction. Dormant when `estimateTowerClocks = false` (the resolved default); live on every tower-clock rung. | **Medium** — small magnitude, but it is the exact defect class `d42ee0d` fixed one layer down, and it biases the one number the report calls "OVERALL". |
| D2 | **Per-epoch pooling of correlated NIS/NEES treats each epoch as an independent χ² sample** | `+revgnss/MonteCarloConsistency.m:95–97` (`dofNIS += sum(mrK)` over every kept epoch) and `:99–105` (`dofNEES += 3*sum(gE)`) | `+revgnss/MonteCarloConsistency.m:42–48` and `:108–122` — the centroid gate argues in the same file that per-epoch pooling "would over-count dof and narrow the band into a false verdict", and uses one time-mean per seed instead | The same information is counted once per epoch rather than once per independent sample. `ChiSquareConsistency.bounds(dof)` then returns a band of half-width ∝ √dof that is too narrow by `√(N/N_eff)`. | With `91faccb`'s own measured ρ₁ = 0.3011 on OVERALL NIS, `N_eff/N = 0.537` → band **1.36× too narrow**; on `twoWay` (ρ = 0.7254) → **2.5× too narrow**. | **Medium-high** — it inflates the apparent significance of every Monte-Carlo verdict, and the file already contains the correct alternative. |
| D3 | **Common-acceleration Q added on top of `sigma_accel` without reducing it** | `+filter/ReverseGNSSEKF.m:1450–1458` (`sa²` block on r/v) | `+filter/ReverseGNSSEKF.m:1460–1465` (`Q = Q + declaredCommonProcessNoiseGroup_.ownDiagonalContribution(...)`, formula at `+revgnss/CommonProcessNoiseCovarianceGroup.m:131–137`) | Both terms model *unmodelled acceleration*. Because the common group is additive, total per-asset PSD becomes `σ_accel² + σ_common²`; reading the pair as "split the total" double-charges the common part. | Dormant: `cfg.estimator.processNoise.commonAcceleration.{enable,sigma_mps2} = {false, 0}` (`masterConfig.m:2066–2067`). If enabled at `σ_common = σ_accel`, Q(r,r) and Q(v,v) **double**. | **Low today, high the moment the distributed-fleet path enables it.** |
| D4 | **`modelMismatch` and the empirical-acceleration state both absorb the same unmodelled force** | `+filter/ReverseGNSSEKF.m:1442–1449` (`sa = sqrt(sa² + σ_mismatch²)`) | `+filter/ReverseGNSSEKF.m:575–609` + `1625–1636` (empirical RTN acceleration state, GM, σ_ss = 1e−7) | An inflated white-acceleration Q and an estimated coloured acceleration state are two representations of the same residual force. Enabling both charges the residual dynamics twice, once as noise and once as an estimated state, which will make the state under-converge and the covariance over-wide. | Both **off** by default (`modelMismatch.enable = 0`; `empiricalAccel.enable = false`). At `σ_mismatch = 1e−6` and `σ_ss = 1e−7` the mismatch term dominates by 100× in PSD, so the state would learn ~nothing. | **Low** (both dormant), but it must be a documented mutual exclusion before either is used in a headline run. |
| D5 | **NOT a double count — verified and cleared (record it as such)** | `+filter/ReverseGNSSEKF.m:1467–1488` (`sigma_angAccel` writes `Q(θ,θ)`, `Q(θ,ω)`, `Q(ω,ω)`) | `+filter/ReverseGNSSEKF.m:2220–2234` (`applyGyroProcessNoise_`) | The gyro block **assigns** rather than accumulates, so ARW/RRW *replace* the angular-acceleration terms instead of stacking. Verified numerically at HEAD: `Q(θ,θ) = 1.00003e−8` = `ARW²dt + RRW²dt³/3` exactly, with no `saa²dt³/3 = 3.33e−15` residue, and `Q(θ,ω) = 0`. | none | **None — cleared.** The side effect (`sigma_angAccel` inert on attitude whenever the gyro is on) belongs in the flaw list, not here. |
| D6 | **NOT a double count — verified and cleared** | `+models/+sensors/StarTrackerObservationModel.m:42–45` exposes `alignmentPriorCovariance_rad2` | `+revgnss/AttitudeSensorSuite.m:161` `R = blkdiag(R, model.whiteAngularCovariance_rad2)` | The alignment consider-covariance is deliberately **not** added to R at every epoch, honouring the in-file policy string at `StarTrackerObservationModel.m:48–49`. | none | **None — cleared**, and this is the correct treatment. |
| D7 | **NOT a double count — verified and cleared** | truth flicker via the coloured FFM sequence in `ClockModel.step` (`coloredBias_s_current`, `coloredFracFreq_current`) | filter flicker via `q2_ffm = 6ln2·h₋₁/dt` in `getProcessNoiseQ` | Flicker appears **once** on each side: as a synthesised coloured sequence in truth, as an Allan-equivalent random walk in Q. The truth's 2-state Cholesky draw uses `q2 = 2π²h₋₂` **without** the flicker term (`ClockModel.step`), so it is not added twice on the truth side either. | none | **None — cleared.** |

---

## Logical flaws

1. **The doc's own line-number baseline is a different commit** (`0ce01f7`, 2301 lines) from the one it claims (`3489075`). Two features (empirical RTN acceleration states, scale-invariant PSD guard) postdate the trace and were never audited; one audited feature was described in its pre-fix form. Any re-issue must be re-anchored from the main tree — there are four worktree copies of `ReverseGNSSEKF.m` on disk at 2525 / 2513 / 1460 / 2513 lines.

2. **`ConsistencyStatistics` normalises the augmented NIS by the physical row count** (D1). The correct series is stored and unread.

3. **The per-channel verdict table omits the star-tracker channel.** `SimulationDataStore.getNISByType` (l. 1883–1896) publishes `C.starTracker` and `C.starTrackerDof`; `ConsistencyStatistics.computeFromDiag` builds no group for them and `formatNisTable`'s `rows` list (l. 112–116) does not include them. With `starTracker.enable = 1` in the resolved default, the only observable that directly constrains attitude is invisible in the covariance verdict. Identical pattern to the defect `d42ee0d` fixed.

4. **`carrierIonoFreeMask` can never be set.** `EkfInnovationAccounting.classifyRows` (l. 50–62) has cases for `code`, `ifCode`, `doppler`, `carrier`, `twoWayTimeTransfer`, `islTwoWayRange` — and no producer anywhere emits an `ifCarrier` label (`MeasurementStackMetadata.m:39–52` is the only writer of `measType_perRow` for the ground stack). `carrierIonoFreeNIS`/`Dof` are therefore permanently `NaN`/0 yet are published by `compact()` (l. 169–178). Inert reporting field. Note that ionosphere-free **carrier** rows genuinely exist in the golden (per the golden-baseline memory) — they are simply labelled `'carrier'`, so the label does not distinguish them.

5. **The Guard-C centroid gate is doubly unreachable.** (a) `cn_NEEScen_` and `cn_NEESseccen_` in `SimulationDataStore` are declared (l. 236–237), read by two getters (l. 1875–1880) and exported once (l. 2231–2232) but **never allocated and never assigned** — so `isempty(...)` is always true and both getters return all-NaN. (b) Their nominal producer `ReverseGNSSEKF.computeSwarmNEES` (l. 1030–1042) was retired to a NaN sentinel by the federated-swarm pivot, and a repo-wide grep finds it has **zero callers** — its own definition is the only occurrence in the tree, so even the docstring's claim that it is "kept ONLY so its existing callers (SimulationDataStore, MonteCarloConsistency) keep working" is stale. `MonteCarloConsistency.centroidVerdict` is therefore permanently `'notApplicable'`, and ~40 lines of careful one-mean-per-seed pooling (`MonteCarloConsistency.m:108–122, 139–158`) protect nothing. The doc presents this gate as the authoritative absolute-trustworthiness test.

6. **`MonteCarloConsistency` contradicts its own stated methodology** (D2): it forbids per-epoch pooling in the centroid gate and then does exactly that for NIS and NEES.

7. **`N_eff` is computed and never used.** `ConsistencyStatistics.groupStat_` (l. 236–244) produces `lag1Autocorr`/`nEff`; `formatNisTable` prints them; nothing widens a band, downgrades a verdict, or suppresses a channel with low `N_eff`, despite the docstring saying such a channel "cannot support a confident verdict". Additionally, ρ measured on a **squared** series under-states the underlying error autocorrelation (ρ_NIS ≈ ρ_err² for Gaussian errors), so the printed `N_eff` is itself optimistic by roughly 2–4× at the observed ρ values.

8. **`ConsistencyStatistics.defaultResult_`'s sentinel struct lacks `lag1Autocorr`/`nEff`** (l. 193–195) while `formatNisTable` reads them unguarded (l. 140). Currently unreachable (the sentinel has `nisPerDof = NaN`, which takes the early-continue path at l. 125), but a one-field change away from throwing inside the report writer.

9. **The gimbal guard in `eulerRatesFromBodyRates` does not guard row 1.** `+revgnss/AttitudeKinematics.m:53–58`: the guard clamps `cp` but then re-assigns `tp = tan(pitch)` — a no-op that leaves `T(1,2) = sr·tp` and `T(1,3) = cr·tp` unbounded at pitch → ±90°. The analytic Jacobian (l. 95–98) gets this right with `tp = sp/cp` on the clamped `cp`. Separately, `sign(cp)` returns 0 at `cp == 0`, so the clamp can set `cp = 0` and the following `sr/cp` divides by zero; `eulerRateJacobian` uses `sign(cp + eps)` and `eulerRatesFromBodyRates` does not. Legacy-Euler path only.

10. **The observability warning names the wrong parameter.** `AttitudeObservability.m:48–50` warns that a weak-geometry attitude covariance is "process-noise-limited (sigma_angAccel)". With `estimateGyroBias = true` (the resolved default), `applyGyroProcessNoise_` **overwrites** the `sigma_angAccel` attitude block, so the covariance is ARW-limited and `sigma_angAccel` has no effect on attitude at all. A reader following the warning would tune an inert knob.

11. **The entire star-tracker alignment-calibration model is inert**, in both the default and the realism grade (`masterConfig.m:359–369` all zeros / `fixedCalibration`; `realismGradeConfig.m:217–229` touches only `whiteAngularSigma_rad` and the IMU triple). Three treatments, validity windows, a stable calibration identifier and a truth-side drift random walk are implemented and never exercised. If enabled, the alignment error would be an unmodelled, uncharged bias with no consider term in R or P — the interface promises a treatment it does not implement.

12. **Truth and filter share gyro parameters exactly, in both grades** (`realismGradeConfig.m:221–228` sets `imu.truth.*` and `imu.filter.*` from the same values; verified live in the resolved config). The gyro channel is an inverse crime: bias convergence is guaranteed by construction.

13. **`test_nis_accumulated_dof.m` is a near-untriggerable gate**: one-sided, on a fixture whose statistic is 0.05–0.5 against a threshold at ≈1.02, with a `dof == 0 → vacuous PASS` branch that turns total instrumentation failure into a green tick.

14. **`test_clock_truth_matches_filter_q.m` proves an inverse crime and is honest about it**, but its stochastic band is exercised at **dt = 1 s only**, while the flicker equivalence is explicitly `dt`-dependent (`q2_ffm ∝ 1/dt`). The `dt ∈ {0.1, 10}` checks are algebraic identities against the same formula, not against a truth realisation.

15. **`attitudeInjectionCount` counts `update()` calls, not epochs.** Up to three sequential updates run per epoch (main stack `ReverseGNSSSimulation.m:840`, star tracker `:943`, diffAtt `:991`), each performing its own MEKF injection and covariance reset. The reported injection count and max-norm must be described as per-update.

16. **The only outlier gate in the estimation path is an unsourced 1 m threshold** (`DiffAttitudeBuilder.m:443, 470`) on a channel whose cycle-slip detector is deliberately disabled (`ReverseGNSSSimulation.m:975–978`). One hand-tuned constant carries the entire editing burden for that channel.

17. **The scale-invariant PSD guard has an absolute-clip fallback.** `ReverseGNSSEKF.m:941–957` reverts to the old `1e−12·max(|diag P|)` test on P itself whenever any variance is zero or non-finite. The codebase avoids the branch by freezing states with a 1e−20 Q multiplier rather than zeroing (l. 1474–1481) — an avoidance, not a fix.

---

## Limits of this domain

**What the filter core CAN legitimately claim.** The measurement update is Brown & Hwang Eqs. (5.5.8)/(5.5.17)/(5.5.18) exactly, with the any-gain Joseph form as the sole P-update path; covariance prediction is Eq. (5.5.25); the discrete Q for every state class is the exact closed-form integral, verified numerically to all significant figures at dt = 1 s (six placements checked live); the MEKF is a canonical local-error ESKF whose reset Jacobian I re-derived from BCH independently of any source; the quaternion convention is declared in machine-readable form and implemented identically in four files. **These are equation-grade correct and can be asserted without hedging.**

**What it CANNOT claim, concretely:**

1. **No statistical consistency claim from a single run.** The shipped verdict (`nisStatus_`, `ConsistencyStatistics.m:270–275`) is the mean-only heuristic that `ChiSquareConsistency`'s own docstring says "*passes a mildly inconsistent filter*". The two-sided machinery exists but is driven only by `MonteCarloConsistency`, which is **off by default** (`cfg.report.monteCarlo.enable = false`). Any consistency statement in the thesis must name the number of seeds.

2. **No consistency claim stronger than ~N_eff.** With ρ₁ = 0.09–0.30 on code/carrier/doppler and 0.7254 on twoWay, the 3601-epoch arcs carry roughly 2000–3000 and ~573 independent samples respectively — and because ρ is measured on a squared series, the true error-domain figures are ~2–4× smaller again. A per-channel NIS/dof of 0.65 quoted "off 3601 epochs" must be quoted off N_eff, and the Monte-Carlo bands are 1.36–2.5× too narrow as computed (D2).

3. **No claim about attitude sensor realism.** Gyro defaults are 0.344 °/√h ARW and 2.06 °/h initial bias — 2.75–34× worse than the RLG/FOG units in NASA Table 5-9, i.e. MEMS/industrial-class, not GEO-grade. Bias instability (the flicker floor) is not modelled at all, so long-arc bias growth is over-stated and the short-term floor under-stated. Star-tracker noise is isotropic at 10″ 1σ (30″ 3σ): **5× conservative** on cross-axis versus a Blue Canyon NST, **1.33× optimistic** on twist versus the same unit and **5× optimistic** versus a Berlin ST400. Real trackers differ 5–11× between the two axes; the sim's attitude covariance is spherical where reality is a cigar, which mis-projects onto the lever-arm observable.

4. **No claim that the gyro-bias state "works".** `imu.truth.*` and `imu.filter.*` carry identical ARW/RRW/bias-sigma in both the default and the realism grade. Bias convergence is a property of the matched construction.

5. **No claim that the clock Q "models flicker".** It carries flicker as its **Allan-equivalent random walk at τ = dt**. Over an arc of N steps the filter accumulates `N·6ln2·h₋₁` of frequency variance where true flicker grows logarithmically — increasingly conservative on the drift state by ~N/ln N. Separately, `Q₂₂` omits the `h₀/(2Δt)` term of Brown & Hwang's own van-Dierendonck-derived footnote (p. 430), which for the caesium template in use is **1.2 × 10⁵ times** the code's entire `Q₂₂`. The repo's standing conclusion that "no Q magnitude restores drift ±3σ coverage" was never A/B-tested against that term and must be narrowed to "no *flicker* Q magnitude".

6. **No claim about tower-clock-enabled NIS.** Whenever `estimateTowerClocks = true`, the OVERALL NIS/dof is inflated ~1.9 % by counting gauge innovations against a physical-only dof (D1). Every ladder rung that estimates tower clocks carries that bias, in the optimistic direction.

7. **No claim from the calibration/consider-parameter machinery.** The star-tracker alignment model — fixed bias, deterministic drift, random walk, three treatments, validity windows, stable identifier — is inert at every shipped configuration. It is correctly written and contributes nothing to any number in the thesis.

8. **No claim that the attitude covariance is measurement-constrained** unless `AttitudeObservability` reports rank ≥ 3 with a non-zero lever arm for the epochs in question. The audit is **single-epoch only**: no arc-accumulated Gramian `Σ Φᵀ Hᵀ R⁻¹ H Φ` is built, despite `beginEpochTransition_`/`accumulateEpochTransition_` (l. 2301–2352) retaining every operator required. A single-epoch rank test systematically *under-states* observability that accrues through the dynamics.

9. **No claim of outlier robustness.** There is no chi-square measurement-editing gate anywhere in the filter (repo-wide grep: `chi2inv` occurs only inside `ChiSquareConsistency`). The code computes exactly the statistic a textbook gate would threshold, and never thresholds it. Results are valid only for the outlier-free synthetic environment they were produced in.

10. **No claim of a converged initial-condition test.** `ScenarioFactory.m:88–113` seeds `x0 = truth + perturbation`, and `MonteCarloConsistency.m:75–80` draws that perturbation from the filter's own P0. Initial NEES is 1 by construction; only the post-burn-in segment (default `burnInFraction = 0.5`) carries information, and the `initErrorScale > 1` negative control must be reported alongside any consistency verdict.

11. **F and Q are dynamically inconsistent by design.** With `estimator.dynamics.mode = 'j2'` the r/v STM is the finite-difference J2 STM while Q remains the constant-velocity white-acceleration form with `σ_accel = 1e−6 m/s²` and the mismatch inflation `enable = 0`. This is standard state-noise-compensation practice and must be labelled as such, not as a matched process model. The FD STM's accuracy also floats on the step sizes (1.0 m, 1e−3 m/s), which are never varied in any test.

---

# Round 2 re-verification — Domain 6: Two-way / TWSTFT, four-timestamp observables, relay sessions, ISL time transfer

Re-verified against HEAD `170e37d` (branch `feature/ground-orientation-exec`). The doc section under review is
`docs/scientific_traceability_analysis.md` lines 770–884 (12 features + cross-cutting summary), written at
`3489075`. Every file:line citation was re-opened; every verdict re-derived from the current source rather
than assumed; every quote re-extracted from the PDF text layer (ITU-R TF.1153-4 fetched EXTERNAL from itu.int
and text-extracted with PyMuPDF).

**Headline for this round.** The doc's 12 verdicts survive almost intact at the *structural* level — the
four-timestamp reduction, the event chain, the Sagnac-by-construction argument, the relay-session split and
the refuse-don't-drop guards are all still correct, and several are now verified *harder* than before (see
§1 and §3). But three things changed materially since `3489075` and one long-standing doc claim is simply
backwards:

1. **NEW, HIGH severity.** `+models/+clocks/RelativisticClockCorrection.m` (new module) is applied on the
   model side of the one-way code, carrier, Doppler, ISL and **legacy** two-way rows, but **not** on the
   four-timestamp ground-space rows. `x(b_rx)` is therefore an *oscillator-only* bias state everywhere
   except `FourTimestampGroundSpaceTimeTransferBuilder`, whose `h` reads it raw. With
   `physics.relativity.clock` on — which is the case in **all three shipped golden baselines** — the
   four-timestamp ground-space channel carries an unmodelled `c·y_rel·t` ramp reaching **581 m at 3600 s**.
   Latent only because no shipped config selects `mode='fourTimestampClockDifference'` yet.
2. **NEW, MEDIUM severity.** Commit `889dcf6`'s stated rationale is wrong. It changed the four-timestamp
   truth endpoints to `getOscillatorDriftMetersPerSecond` on the grounds that "the endpoint is already
   carrying `y_rel` via `properTimeRate`". It is not: `properTimeRate` never enters `localTimeAt`
   (`TwoWayCodeEndpointModel.m:105-108`); its only consumer is the transponder-turnaround unit conversion
   (`:115-117`), worth **0.16 fs**. The change therefore removed real physics rather than preventing a
   double count, leaving the truth tags internally inconsistent (bias ramps, rate does not) at the
   **~2 cm** level on a 3 cm-σ row for ground-space links. Benign (< 1 µm) on sat-sat links, where `y_rel`
   is common-mode.
3. **NEW, MEDIUM.** The silent-fallback class that `889dcf6` fixed is **still structurally present and
   still ungated**. There is no test anywhere that asserts `shapeFallbackReason`/`relClockFallbackReason`
   is empty; the one test that touches the label (`tests/test_swarm_two_way_isl_gating.m:37`) *asserts the
   fallback value*. Five distinct return paths in `SwarmRelativeSolver.fourTimestampObservables_` degrade
   to the synthetic observable without erroring.
4. **NOW-WRONG doc claim.** Doc §5 says the observable "senses each endpoint's TX and RX terminal delays
   only through their per-endpoint *sum* weighted ½" and "cannot represent an ITU-style ½[TX(k)−RX(k)]
   asymmetry". Both halves are inverted. The observable senses exactly the ITU quantity `RX(k) − TX(k)`
   and is *blind* to `RX+TX`; verified algebraically and against ITU-R TF.1153-4's own two-way equation
   (p. 4). The conclusion ("benign for the clock row") is unaffected, but the reasoning must not be
   reproduced in the thesis.

---

## Feature-by-feature

### 1. The four-timestamp clock-difference combination and its sign convention

- **Code**: `+revgnss/FourTimestampObservableBuilder.m:219`
  `value_s = 0.5*((tags_s(2)-tags_s(1)) - (tags_s(4)-tags_s(3)));`
  chain-role order `{origin, destination, destination, origin}` supplied at `:72-73`; metres conversion
  `value_m = 299792458 * value_s` at `:82` (class constant `SpeedOfLight_mps` at `:35`); sign contract
  documented at `:212-218`; consumer partials `referenceClockPartial=-1`, `remoteClockPartial=+1` at
  `+revgnss/ReciprocalTimeTransferModel.m:64-65`. Range counterpart on the coherent-code path at
  `+revgnss/CoherentTwoWayCodeRangingModel.m:68-70`.
- **Status vs doc**: STILL-VALID (`:219`, `:82`, `:183-202`, `ReciprocalTimeTransferModel.m:64-65` all
  exact). DRIFTED on one pointer: the doc cited "lines 183–189" for the chain-role order; the order is
  actually *constructed* at `:72-73` and only *described* in the comment at `:185-186`.
- **Verdict**: **correct**, and now verified to a stronger standard than the doc claimed. Substituting the
  affine tag model `T_k = T0_e + rate_e·(t_k − t0)` gives
  `Δ = (b_dest − b_orig) + ½(τ_fwd − τ_ret) + ½[y_d(t2+t3−2t0) − y_o(t1+t4−2t0)]`,
  i.e. remote-minus-reference clock difference plus half the path asymmetry plus a rate term. Re-derived
  independently; matches the code exactly.
- **Sources**:
  - Merlo, J. M., Mghabghab, S. R., & Nanzer, J. A. (2023). Wireless picosecond time synchronization for
    distributed antenna arrays. *IEEE Transactions on Microwave Theory and Techniques, 71*(4), 1720–1731.
    — "the offset between the local clock at node n and node 0 can be deduced by" (p. 1722, preceding
    Eq. 3); "If the link is symmetric, the prop- agation delay can also be deduced simply by" (p. 1722,
    preceding Eq. 4); "the goal is to find 10n = δ0 −δn" (p. 1722; "10n" is the PDF text layer's rendering
    of "Δ0n").
  - Shen, D., Chen, G., Pham, K., & Blasch, E. (2022). Enhanced multi-way time transfer for high-precision
    time synchronization among UASs. *MILCOM 2022*, 501–506 — Eq. (5) as extracted:
    `Δt = (R₂−R₁)/(2c) + (2t_RX^M − t_TX^S − t_RX^S + T_TX^M + T_RX^S − T_RX^M − T_TX^S)/2` (p. 502).
  - ITU-R. (2015). *Recommendation ITU-R TF.1153-4* [EXTERNAL, itu.int] — "The time-scale difference is
    thus given by the so-called two-way equation:" (p. 4); "The last seven terms are the corrections for
    non-reciprocity." (p. 4).
- **Critical analysis**. The doc asserted the sim's sign matches Merlo and is *opposite* to ITU. Both halves
  are now **proved**, not asserted. Merlo's node *n* initiates (t_TXn, t_RX0, t_TX0, t_RXn) so his
  timestamps map one-to-one onto the sim's (t1,t2,t3,t4), his Eq. (3) is literally the sim's `value_s`, and
  his `Δ0n = δ0 − δn` = responder-minus-initiator = the sim's remote-minus-reference. Exact match including
  sign. ITU's `TS(1) − TS(2)` is station-1-minus-station-2 with station 1 the local reference, i.e. the
  opposite ordering — a convention choice, uniformly and correctly handled in-repo.
  Shen independently confirms the *structure* (raw tag combination + a motion correction) and, decisively,
  the *coefficient* of that correction — see §4.
  Two structural notes the doc did not have: (a) the reduction is a pure function of the four tag numbers
  and never calls a truth clock model (`:212-214`) — this is the discipline a real modem has, and it is
  genuinely rare in simulation code; (b) the ordering guard `requireFiniteOrderedTags_` (`:204-210`) is
  applied to the **delay-corrected** tags, so a terminal delay larger than the transponder turnaround
  (default 1 ms) will hard-error rather than silently produce a non-causal chain.

### 2. The event-chain solver and the constant-velocity light-time oracle

- **Code**: `+revgnss/ReciprocalTimestampEventModel.m:87-151` (`solveEventChain_`), retarded-leg fixed point
  at `:153-173` (tol `1e-13` s ≈ 0.03 mm, cap 50), `t2 = t3 − turnaroundCoordinate_s` at `:114-116`,
  closure residual guard `> 10×tol` at `:129`, event-ordering guard at `:133`, `maximumIterations >= 3`
  hard floor at `:200-210`. Estimator-side third copy at
  `+revgnss/FourTimestampObservableBuilder.m:248-331`. Closed-form oracle at
  `+revgnss/ConstantVelocityFourEventLightTimeOracle.m:105-129`:
  `discriminant = p² + (c²−v²)d²; lightTime = d²/(√disc − p)` with `p = d·v`.
- **Status vs doc**: STILL-VALID — every cited line is exact.
- **Verdict**: **correct**. Re-derived the oracle from scratch: the retarded condition `|d + vτ| = cτ` gives
  `τ²(c²−v²) − 2τ(d·v) − d² = 0`, positive root `τ = [p + √(p²+(c²−v²)d²)]/(c²−v²)`, rationalised to
  `τ = d²/(√(p²+(c²−v²)d²) − p)`. Bit-for-bit the implemented expression. The rationalised form is the
  numerically stable branch (it avoids cancellation when `p > 0`), which is the right engineering choice.
- **Sources**: Surof, J., Poliak, J., Wolf, R., Mata Calvo, R., Blümel, L., & Günther, C. (2026). Precise
  time transfer and ranging for next-generation GNSS. *GPS Solutions, 30*, 101 — "The clock offset ∆TAB was
  estimated from the difference of the pseudoranges" and "∆TAB = 1 2 (pA −pB) = +δtA −δtB." (p. 8 of 10);
  "pA = uDLL = −τ = ∆t + δtA −δtB." (p. 5 of 10). **Page correction to the doc**: these are on article pages
  8 and **5**, not 8 and 7.
- **Critical analysis**. The curvature bound the doc quotes still holds (½·a·τ² ≈ 1.9 mm at GEO over a
  0.127 s leg, largely common-mode between legs). What the doc did not say and should: the oracle is
  *test-only* and is fed `coordinateTurnaroundDelay_s` already in coordinate time
  (`ConstantVelocityFourEventLightTimeOracle.m:33-36, :54`), so it does **not** exercise the
  proper→coordinate turnaround conversion at all — the one place `properTimeRate` is live is outside the
  oracle's reach. Also worth stating: Surof's ΔTAB is a *pseudorange-difference* of two independent one-way
  DLL loops, not a four-timestamp round trip, and its sign is local-minus-remote (`+δtA − δtB`) — a third
  convention. It supports the sim's ½-combination structure, not its sign.

### 3. Sagnac and frame handling

- **Code**: four-timestamp mode — `+revgnss/ReciprocalEndpointTruthProvider.m:59-69` (`fixedStation`:
  `ecefStateToInertial(towerTruth_ecef_m, zeros(3,1), t_s)`, comment at `:61-67`), so the tower carries its
  full inertial `Ω×r` velocity and the up/down asymmetry is generated physically; estimator mirror at
  `+revgnss/FourTimestampEstimatorEndpointBridge.m:134-136` (tower) and `:158-159`
  (`buildEstimatorEndpoint_`, spacecraft) using the identical pipeline. Legacy mode —
  `+revgnss/TwoWayTimeTransferBuilder.m:219-229` builds ECEF states with `'velocity_mps', zeros(3,1)` for
  the tower; no Sagnac term on either side. Synthetic ISL —
  `+revgnss/InterSatelliteTimeTransferBuilder.m:544-552` (`truthState_`), ECEF, no light time.
- **Status vs doc**: DRIFTED (line numbers moved: `54-62`→`59-69`, `212-224`→`219-229`, `83-95`→`544-552`);
  the verdict itself is STILL-VALID.
- **Verdict**: **correct** for the four-timestamp mode; honest-twin-but-not-physics for the legacy and
  synthetic-ISL modes.
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] — "SCU(k): Sagnac correction in the uplink / SCD(k): Sagnac
  correction in the downlink." (p. 3); "SCD(k)  (Ω / c2) [Y(k) X(s) – X(k) Y(s)]" (p. 5); "the sign of the
  Sagnac correction for the downlink is opposite to the sign of the Sagnac correction for the uplink due to
  the opposite propagation directions of the signals: SCU(k) = −SCD(k)" (p. 5); worked example
  "SCD(VSL)  + 99.10 ns", "SCD(USNO)  – 95.22 ns", "SCT(VSLUSNO): – SCD(VSL)  SCD(USNO)  – 194.32 ns"
  (all p. 5 — **page correction**: the doc said pp. 5–6); "This causes a periodic variation of the Sagnac
  effect with a maximum peak to peak amplitude of a few hundred ps" (p. 6). Shen et al. (2022) — "For
  satellite applications, the Sagnac effect needs to be compensated to high-precision time synchronization
  results." (p. 502). Fridelance, P., Samain, E., & Veillet, C. (1996). *T2L2 — Time transfer by laser
  link*. — "τrelativity is a relativity correction term corresponding to the Sagnac effect [11]." (p. 3).
- **Critical analysis**. The doc's structural claim — cancels in the half-sum, adds in the half-difference —
  is now **independently derived and confirmed**. Expanding both legs to first order in v/c with
  `û` the unit vector from A (origin) to B (destination):
  `τ_f ≈ (ρ/c)(1 + û·v_A/c)`, `τ_r ≈ (ρ/c)(1 − û·v_B/c)`, so
  `½(τ_f + τ_r) = (ρ/c)[1 + û·(v_A − v_B)/(2c)]` — the **relative** velocity, and
  `½(τ_f − τ_r) = (ρ/2c²)·û·(v_A + v_B)` — the **common** velocity. Exactly as the doc says.
  Numerically for the sim's geometry: `ρ ≈ 3.8×10⁷ m`, `û·(v_A+v_B)` up to ≈ 500 m/s for an 8.7°-off-nadir
  tower (tower 465 m/s + GEO 3075 m/s, both eastward, projected onto a near-radial line of sight), giving
  `ρ·û·(v_A+v_B)/(2c) ≈ 31.7 m ≈ 106 ns` in the clock observable. That lands squarely in the ITU worked
  example's 99–194 ns class — the doc's "order 100 ns" is confirmed by construction, not by analogy.
  One caution the doc missed: ITU's own two-way equation groups the Sagnac terms as
  `−0.5[SCD(1)+SCU(1)] + 0.5[SCD(2)+SCU(2)]`, which with `SCU = −SCD` collapses to `SCD(2) − SCD(1)` — a
  *between-station* difference. The sim's topology is tower↔satellite, not station↔transponder↔station, so
  the ITU worked example is an order-of-magnitude corroboration, **not** a term-by-term correspondence. Do
  not present it as one in the thesis.

### 4. The first-order reciprocity residual term — wrong factor, now source-confirmed

- **Code**: `+revgnss/ReciprocalTimeTransferModel.m:44-46`
  `reciprocity_m = -(deltaPosition.'*deltaVelocity)/SpeedOfLight_mps;` = `−ρρ̇/c`, with position/velocity
  partials at `:47-52`. Applied identically to truth and model at
  `+revgnss/TwoWayTimeTransferBuilder.m:219-232`. Default OFF
  (`config/masterConfig.m:2929 includeReciprocityResidual = false`); when on, `reciprocitySigma_m` (5 mm,
  `masterConfig.m:2930`) is added to R at `TwoWayTimeTransferBuilder.m:294`. Refused under the
  four-timestamp mode at `TwoWayTimeTransferBuilder.m:432-437`.
- **Status vs doc**: STILL-VALID for `:44-46`, `:64-65`; DRIFTED for the builder line refs
  (`209-224`→`219-232`, `375-381`→`432-437`).
- **Verdict**: **flawed** — confirmed, and now with an external check the doc did not have.
- **Sources**: Shen et al. (2022) — Eq. (5) `Δt = (R₂−R₁)/(2c) + [tag combination]/2` and Eq. (6)
  `R₂−R₁ = v̂ₛ·x̂ₛ(t_RX^S − t_TX^M − T_RX^S + T_RX^M)` (both p. 502). ITU-R TF.1153-4 [EXTERNAL] § 3.3 —
  "Two-way paths between earth stations via the satellite are not reciprocal if the satellite is in motion
  relative to the Earth's surface and if the two arriving signals do not pass through the satellite at the
  same instant." and "If the signals from the two stations arrive at the satellite within 5 ms, the delay
  difference is at the level of only a few tens of ps, and it shows a diurnal pattern." (p. 6). Merlo et
  al. (2023) — "assuming that the channel was quasi-static over the synchronization epoch" (p. 1722,
  Fig. 2 caption).
- **Critical analysis**. My independent first-order expansion of the sequential four-event chain (anchored
  at t4, turnaround Δ) gives, in metres,
  `c·½(τ_f − τ_r) = −ρρ̇/(2c) − ρ̇Δ/2 + ρ·û·(v_A+v_B)/(2c)`.
  The code's `−ρρ̇/c` is therefore **exactly 2× the relative-velocity part**, and the common-velocity
  (Sagnac/aberration) part is **absent**. Shen closes the loop from the literature: rearranging his Eq. (5),
  the *raw* observable equals the clock difference minus `(R₂−R₁)/(2c)`, and with `R₂−R₁ ≈ ρ̇·ρ/c` that is
  `−ρρ̇/(2c)` in metres — the same coefficient I derived, and half the code's. Note the doc's own
  expansion had the sign of the common-velocity term opposite to mine; that is a `û`-orientation ambiguity
  in the doc's text, not a disagreement about the physics, and should be rewritten with `û` defined.
  Three mitigations still stand and should be repeated in the thesis: (a) the identical expression appears
  in `z` and `h` (`TwoWayTimeTransferBuilder.m:219-232`), so the *filter* only ever sees the state-error
  residual; (b) with the tower velocity forced to `zeros(3,1)` in ECEF and a geostationary asset, `ρ̇ ≈ 0`,
  so the term is ~0 in every shipped scenario; (c) `validateConfig` refuses it under the four-timestamp mode
  rather than ignoring it. The gap is that `tests/test_four_timestamp_static_limit_matches_first_order_reciprocal.m`
  tests only the **static** limit and uses the moving case as a negative control, so the coefficient itself
  has never been constrained by a test. That remains true at HEAD.

### 5. Hardware delays, calibration split, and the terminal-delay allocation — doc reasoning NOW-WRONG

- **Code**: `+revgnss/ReciprocalLinkHardwareModel.m` — immutable chain, `parameterSource ∈
  {physicalTruth, calibrationProduct}` validated at `:66-69`, `assertParameterSource` at `:136-142`,
  `assertValidAt` at `:144-154`, PSD/symmetry check on `calibrationCovariance_s2` at `:90-102`. Source
  assertions at every solver entry: `ReciprocalTimestampEventModel.m:96-99`,
  `FourTimestampObservableBuilder.m:60/64/255-257`. Truth-vs-product split built at
  `+revgnss/FourTimestampPhysicalLinkConfig.m:73-101` (`physicalTruth` folds
  `truth.originTerminalCalibrationError_s`/`anchorTerminalCalibrationError_s` into the nominal delays;
  `calibrationProduct` returns the nominal). Allocation at
  `FourTimestampObservableBuilder.m:183-202`:
  `receiveEvent: tags + [0, A, 0, O]`; `transmitEvent: tags − [O, 0, A, 0]`;
  `splitEvenly: tags + 0.5*[−O, A, −A, O]`. Validity window enforced at
  `DirectReciprocalTimeTransferBuilder.m:171` and `FourTimestampObservableBuilder.m:74/140`.
  Declared calibration *uncertainties* refused at `FourTimestampGroundSpaceTimeTransferBuilder.m:316-328`.
- **Status vs doc**: code STILL-VALID (all cited lines exact); **doc reasoning NOW-WRONG**.
- **Verdict**: code **correct** and, once the algebra is done properly, *more* ITU-faithful than the doc
  claimed; the doc's explanatory sentence is inverted.
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] — "TX(k): Transmitter delay, including the modem delay" /
  "RX(k): Receiver delay, including the modem delay" / "SPT(k): Satellite path delay through the
  transponder" (p. 3); the two-way equation's terminal terms
  "[TX(1)  RX(1)] (Transmit/receive difference at station 1)" and
  "−0.5 [TX(2)  RX(2)] (Transmit/receive difference at station 2)" (p. 4 — the ± glyphs are lost in the
  PDF text layer; the section headings make the intent unambiguous); § 3.6 "The difference of the transmit
  and receive section [TX(k) – RX(k)] … has to be determined at each station." (p. 6); calibration methods
  "co-location of both stations; or subsequent co-location of a third (transportable) earth station at both
  stations; the use of a calibrator" (p. 7). Shen et al. (2022) — "the RX and TX processing functions are
  usually implemented in a field-programmable gate array (FGPA), so the processing times are fixed on the
  local clocks" (p. 502; "FGPA" is the source's own typo — the doc silently corrected it to "FPGA", which
  breaks verbatimness). Zhao et al. / *Precise point positioning for ground-based navigation systems
  without accurate time synchronization*, GPS Solutions — "accurate time synchronization requires accurate
  calibration of equipment delays and thus significantly increases the difficulty of engineering
  implementation" (p. 1, abstract).
- **Critical analysis**. Physical tagging: a receive tag is recorded *after* antenna arrival by `RX(k)`, a
  transmit tag *before* antenna emission by `TX(k)`, so the full model is
  `corrected = raw + [−TX_o, +RX_d, −TX_d, +RX_o]`. Substituting into the reduction:
  `Δ' = Δ + ½[(RX_d − TX_d) − (RX_o − TX_o)]`.
  The observable senses **`RX(k) − TX(k)` per endpoint — precisely the ITU quantity — and is completely
  blind to `RX(k) + TX(k)`**, which is the range-relevant combination. The doc says the opposite on both
  counts.
  The three frozen allocations are therefore three physical hypotheses, and their effect is exactly right:
  `receiveEvent` ⇒ `RX=D, TX=0` ⇒ `Δ' = Δ + ½(A − O)`; `transmitEvent` ⇒ `Δ' = Δ − ½(A − O)`;
  `splitEvenly` ⇒ `RX = TX = D/2` ⇒ `RX−TX = 0` ⇒ **`Δ' = Δ` exactly, the delays are inert**. That last
  one is physically correct (a symmetric station contributes no non-reciprocity) but is worth flagging as
  a config leaf under which `originTerminalGroupDelay_s`/`anchorTerminalGroupDelay_s` change nothing at all
  in the clock row.
  What the single-scalar-per-endpoint model genuinely *cannot* do (and the doc should have said) is
  represent `RX` and `TX` independently: with one `D` and a 3-valued allocation you get
  `RX−TX ∈ {+D, 0, −D}` and `RX+TX ≡ D` — you cannot set, say, `RX = 3 ns, TX = 1 ns`. For a
  clock-difference-only row that is sufficient; for a joint clock+range treatment it is not.
  Finally, `config/masterConfig.m:2848-2851` and `:2962-2965` set every
  `truth.*CalibrationError_s` and `calibration.*Sigma_s` to zero, so **every shipped four-timestamp run
  assumes perfectly calibrated terminal delays** — the truth and product hardware objects carry identical
  numbers. The guard at `FourTimestampGroundSpaceTimeTransferBuilder.m:316-328` correctly refuses a
  declared-but-unwired sigma rather than dropping it.

### 6. Coherent two-way code ranging — what "coherent" means and the noise convention

- **Code**: `+revgnss/CoherentTwoWayCodeRangingModel.m:57-70` —
  `measuredDelay_s = localClockRate·(τ_f + turnaroundCoordinate + τ_r) + initiatorTerminalGroupDelay + propagationGroupDelay + trackingError`;
  `trueTurnaroundEquivalent_s = localClockRate · turnaroundProperTime_s / transponderTruth.properTimeRate` (`:62-64`);
  `processedRange_m = 0.5·c·(measuredDelay − calibrationProduct.initiatorTerminalGroupDelay_s − appliedTurnaroundEquivalent)` (`:68-70`);
  injected error decomposition at `:130-137`. Noise draw at
  `+revgnss/TwoWayISLMeasurementBuilder.m:579-582`: `trackingError_s = 2·thermalSigma/c · draw`.
  Diagnostic string at `+revgnss/ISLTimingModel.m:84-88`. Floorless-sigma rationale at
  `TwoWayISLMeasurementBuilder.m:549-571`, warning at `:1374-1378`.
- **Status vs doc**: STILL-VALID for `:57-70`, `:130-137`, `:579-581`; DRIFTED for `ISLTimingModel.m:87-89`
  → `:84-88`.
- **Verdict**: **correct**. Re-checked the noise scaling: the `½c` reduction maps a `2σ/c` delay draw to
  exactly `σ` of range — a single draw, which is the right structure for a coherent transponder because
  only one tracking receiver exists. `trueTurnaroundEquivalent_s` is algebraically identical to
  `localClockRate · turnaroundCoordinate_s`, so the truth path is self-consistent and the residual is
  exactly `trueTurnaround − appliedTurnaround` (the calibration error), as `:134-135` declares.
- **Sources**: Schaefer, W., Pawlitzki, A., & Kuhn, T. (2000). Two-way frequency transfer via satellite
  using carrier phase. *32nd PTTI Meeting* — "C/No: 40...60 dBHz ->noise 500ps (PN 2.5 MChip/s, t = 1s)"
  (PDF p. 2 / deck slide 4; **quote correction** — the doc's version inserted spaces the source does not
  have); "Measurement unaffected by … Transponder delay / Ionosphere / Troposphere" (PDF p. 3). ITU-R
  TF.1153-4 [EXTERNAL] § 3.1 — "the satellite signal delays are equal, i.e. SPT(1)  SPT(2). This is not the
  case when … In this case SPT(1) and SPT(2) or at least the difference SPT(1)  SPT(2), designated as
  XPNDR(k), should be measured" (p. 4).
- **Critical analysis**. Unchanged and still sound. One thing to add: at
  `TwoWayISLMeasurementBuilder.m:571-573`,
  `observationVariance = thermalSigma² + plasmaResidualSigma² + nonThermalSigma²` while the *injected*
  noise at `:579-582` is `thermalSigma` alone. R therefore declares two error terms that `z` does not
  carry. That is conservative (NIS runs low), not a double count, but it means the ISL two-way channel's R
  is not the variance of its own residual whenever `plasma.residualSigma_m` or `nonThermalSigma_m` is
  nonzero — a fact any NIS-based consistency claim on that channel must state.

### 7. Covariance modelling of the observable — SUPERSEDED on the legacy path

- **Code**: `+revgnss/ReciprocalTimeTransferCovarianceBuilder.m` — named blocks, `priorVarianceUnits=='s^2'`
  guard at `:83-89`, block-diagonal assembly with symmetrisation and a PSD check at `:188-194`,
  `zeros(0,0)` for undeclared blocks at `:199-201`. Four-timestamp ground-space R:
  `Ri = sigma_m^2 + nCorr * towerClockSigma_m^2` at
  `+revgnss/FourTimestampGroundSpaceTimeTransferBuilder.m:181`, `nCorr` at `:82-93`.
  **Legacy path is no longer the same structure**: `+revgnss/TwoWayTimeTransferBuilder.m:252` starts
  `Ri = sigma_m^2`, then `:255-293` splits the tower-product sigma into a piecewise-constant part
  (`TowerClockCorrectionProvider.productOnlySigma(cfg, age_2w)`) and a sawtooth oscillator-wander part,
  and charges `Ri = Ri + nCorr * sConst_^2 + wanderVar_` at `:292`, with a one-shot inversion warning at
  `:275-288`. `+recip: Ri = Ri + recipSig^2` at `:294`.
- **Status vs doc**: **SUPERSEDED** for the legacy path (the doc's "`TwoWayTimeTransferBuilder.m:243-245`,
  identical structure" no longer describes the code); STILL-VALID for
  `FourTimestampGroundSpaceTimeTransferBuilder.m:181`, `:82-93`, `:316-328`, `:330-342`, `:344-365` and for
  `ReciprocalTimeTransferCovarianceBuilder.m:83-89`, `:188-194`.
- **Verdict**: **improved to partially correct**. The new bias/wander split is a genuine scientific
  improvement and its rationale is measured and recorded in-file ("Charging n_corr = 30 copies of it took
  the two-way row from 2.42 m to 13.25 m of sigma at age 34 s: a 24x de-weighting of the ONE observable
  that breaks the GEO radial-clock degeneracy", `:263-268`). The **four-timestamp** path did **not**
  receive the same split: `FourTimestampGroundSpaceTimeTransferBuilder.m:181` still charges
  `nCorr · towerClockSigma_m²` on the *whole* provider sigma, i.e. it inflates the sawtooth wander
  component too. That is exactly the defect the legacy path measured at 24× de-weighting — see
  Double-count candidate **DC-3**.
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] — the enumerated non-reciprocity corrections that a covariance
  must carry (p. 4). Song, W., Zheng, F., Wang, H., & Shi, C. (2023). 100 picosecond/sub-10⁻¹⁷ level GPS
  differential precise time and frequency transfer. *Applied Sciences, 13*(19), 10694 — correlated-error
  treatment as the route to 100 ps-class STDs.
- **Critical analysis**. The doc's four sub-findings are re-checked:
  (1) nCorr inflation of the piecewise-constant product error — **still correct and now better on the
  legacy path, still crude on the four-timestamp path**.
  (2) One-way ISL product error charged as white with no nCorr — **unchanged**; synthetic ISL time transfer
  R is still pure white `sigma_m²` (`InterSatelliteTimeTransferBuilder.m:91-94`, doc said `:92-95`).
  (3) `counterTag.sigma_s` and `atmosphereVariance_s2` never reach R, and `validateConfig` hard-errors on a
  nonzero declaration — **unchanged and still the right failure mode**. The consequence stands: **no
  four-timestamp run has ever carried tag noise or atmosphere in its filter weighting.** The ISL
  four-timestamp builder repeats the same refusal
  (`InterSatelliteFourTimestampTimeTransferBuilder.m:43-52`) and additionally *discards* the truth record's
  covariance block outright, setting `covarianceBlock = info.sigma_m^2` (`:138`).
  (4) Common-mode clock noise between T1/T4 unmodelled — **unchanged**, and still ≪ 1 ps.
  New: the m²-vs-s² refusal at `DirectReciprocalTimeTransferBuilder.m:179-185` is exemplary, but note the
  *builder* refuses it while `ReciprocalTimeTransferCovarianceBuilder.sessionCommonModeBlock` (`:132-162`)
  would happily place an m² `sharedCovarianceContribution_m2` into a block the record then labels `s^2`
  (`DirectReciprocalTimeTransferBuilder.m:246`). The guard is at the caller, not at the unit-mixing site.
  The relay session sidesteps this entirely by carrying its own `sessionCommonCovariance_s2`
  (`GroundRelaySessionObservableBuilder.m:184`), so nothing live is wrong — but the class-level invariant
  is one refactor away from being violated.

### 8. Ionosphere and troposphere asymmetry

- **Code**: absent from every two-way `z`/`h`. `applyAtmosphere=true` refused at
  `+revgnss/FourTimestampGroundSpaceTimeTransferBuilder.m:356-365`, with the measured
  "byte-identical on vs off" statement at `:344-355`. Legacy mode has no atmosphere path at all.
  Four-timestamp carrier frequency defaults: ground-space **2.2 GHz** (`masterConfig.m:2945`), ISL
  **26 GHz** (`masterConfig.m:2831`).
- **Status vs doc**: STILL-VALID.
- **Verdict**: **flawed as physics / correct as declared scope**.
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] § 3.4 — "Example: For a high TEC of 1  1018 electrons/m2 and
  fu = 14.5 GHz and fd = 12.5 GHz this ionospheric delay is equal to 0.859 ns – 0.639 ns = 0.220 ns. So the
  difference 0.5[SPU(k) – SPD(k)] is typically smaller than −0.11 ns." (p. 6); § 3.5 — "up to 20 GHz this
  delay is only frequency dependent to a very small extent. So its influence on the difference between the
  up and down propagation delays is < 10 ps." (p. 6). Schaefer et al. (2000) — "Troposphere: none
  (frequency independent)" and "Ionosphere: <300 ps / day (4 E-15), under pessimistic assumptions /
  asymmetry effect assuming absolute ion. delay of 50 cm in Ku band" (PDF p. 4); "Long-term stability
  (ô = 1 day) affected by link asymmetries (variation of ionosphere)" (PDF p. 6).
- **Critical analysis**. The doc's scaling argument holds and I re-derived it. ITU's example is Ku-band
  (14.5/12.5 GHz) giving 0.220 ns of up/down difference at 10¹⁸ e/m² (100 TECU). The sim's ground-space
  default is 2.2 GHz. First-order delay scales as `1/f²`, so at 2.2 GHz a 10 TECU path gives
  `40.3·10·10¹⁶/(c·(2.2×10⁹)²) ≈ 18.5 ns` per leg. Any realistic up/down frequency split at S-band
  therefore produces a **nanosecond-class** asymmetry — one to two orders above the 100 ps (0.03 m)
  declared σ. **This is the single largest unmodelled physical term in the domain**, and it means the
  four-timestamp S-band link's 100 ps figure is a *precision*, never an *accuracy*, claim. The ISL
  four-timestamp default (26 GHz, vacuum path) is unaffected — that link genuinely has no ionosphere.

### 9. Ground relay session (station↔relay↔station TWSTFT)

- **Code**: `+revgnss/GroundRelaySessionObservableBuilder.m:147-152` —
  `rawCombination_s = (deltaF_s − tauF_s) − (deltaR_s − tauR_s)`;
  `clockDifferenceValue_s = 0.5*rawCombination_s`;
  `classicalReciprocityValue_s = 0.5*(deltaF_s − deltaR_s)`.
  Station-delay corrections at `:133-141` (net = truth − calibration, per station, per direction);
  session-level `assertValidAt` on both passes at `:125-126`; independent-variance propagation at
  `:161-163` / `:197-…`. Relay-clock marginalisation documented in
  `+revgnss/GroundRelaySessionClockDifferenceObservable.m:39-52`. Property tests at
  `tests/test_relay_twstft_clock_gauge.m`.
- **Status vs doc**: DRIFTED (doc cited `:142-156`, actual `:147-152`); verdict STILL-VALID.
- **Verdict**: **correct**, and the exactness claim is verifiable. With `ΔF = corrected_t4(B) −
  corrected_t1(A) = (b_B − b_A) + τ_F` and `ΔR = (b_A − b_B) + τ_R`:
  `0.5[(ΔF − τ_F) − (ΔR − τ_R)] = b_B − b_A` exactly, while
  `0.5(ΔF − ΔR) = (b_B − b_A) + 0.5(τ_F − τ_R)`. The two differ by exactly
  `½·coordinateAsymmetry_s`, which is precisely what `:180` records. Confirmed algebraically.
  The relay clock and relay group delay cancel structurally because they enter both one-way passes
  identically and the combiner never reads them.
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] § 3.1 (transponder-delay cancellation and its failure mode, p. 4,
  quoted in §6). Fridelance et al. (1996) — "X = (tstart + treturn)/2 - tboard + τrelativity + τatmosphere
  - <τcalibration>/2 + τgeometric/2" (p. 3) — the analogous truth-geometry-free optical combination;
  "τatmosphere reflects the time difference produced by the atmosphere, between the station-satellite
  journey and the return journey of the light pulse. The mean value of this interval is equal to 0."
  (p. 3).
- **Critical analysis**. Still the strongest single piece of scientific hygiene in the domain: the
  truth-assisted "exact" value (which uses `record.coordinateTimeEvents_s`, i.e. truth coordinate times) is
  computed *alongside*, and separately labelled from, the realizable classical value that a real modem
  could form from tags and station-delay calibration alone. Verified that no estimator consumes
  `clockDifferenceValue_*`: the only non-test readers are the observable class's own unit-consistency
  assertions (`GroundRelaySessionClockDifferenceObservable.m:180-183`). One thing to state explicitly in
  the thesis: `atmosphereDelayForward_s`/`atmosphereDelayReturn_s` are added to the *corrected station tags*
  (`:137, :139`), so the relay path **does** carry an atmosphere delay — it is the only two-way path in the
  repo that does — but it is a caller-supplied scalar, not a physical model.

### 10. Light-time asymmetry for a co-moving formation (the 0.68 µm claim)

- **Code**: mechanism is §2's chain applied to two `ReciprocalEndpointTruthProvider.spacecraft` endpoints
  via `+revgnss/DirectReciprocalTimeTransferBuilder.m:51-86` (`buildFromIsl`); replayed in
  `+revgnss/SwarmRelativeSolver.m:1268-1286`.
- **Status vs doc**: STILL-VALID.
- **Verdict**: **correct**. Re-derived: the processing-irremovable relative-motion part of the sequential
  asymmetry is `ρρ̇/(2c)`; for `ρ = 2000 m` and `ρ̇ ≈ 0.15 m/s`, that is
  `2000 × 0.15 / (2 × 2.998×10⁸) = 5.0×10⁻⁷ m = 0.50 µm` — the same order as the recorded 0.68 µm.
- **Sources**: ITU-R TF.1153-4 [EXTERNAL] § 3.3 (p. 6, quoted in §4); Surof et al. (2026) — "the standard
  devi- ation of TWTT is σTWTT = 0.37 ps, and for ranging σrange = 121 µm." (p. **9** of 10 — the doc said
  p. 10).
- **Critical analysis**. Unchanged, and the doc's caveat is important and correct: in the inertial frame the
  asymmetry *also* contains `ρ·û·(v_A+v_B)/(2c)`, which for an along-track 2 km baseline at GEO
  (`|v_A+v_B| ≈ 6150 m/s`, `û` along-track) reaches `2000 × 6150 / (2 × 2.998×10⁸) ≈ 20.5 µm` — 30× the
  quoted number. It never appears in a residual because both truth and prediction solve the same chain, and
  it vanishes for radial/cross-track baselines. **The 0.68 µm figure is geometry-specific and must not be
  quoted as a general bound.**

### 11. Achievable precision: sim assumptions vs demonstrated systems

- **Code**: `config/masterConfig.m:805` and `:2928` — `twoWayTimeTransfer.sigma_m = 0.03` "% two-way time
  uncertainty 1-sigma [m] (~100 ps)"; `:2943` four-timestamp ground-space `sigma_m = 0.03`; `:2829` ISL
  four-timestamp `sigma_m = 0.03`; `:1879` federated ISL TWSTFT `sigma_m = 0.03` with
  `delayCal.sigma_const_m = 0.01`, `sigma_rw_m = 0.003`, `tau_s = 3600`, `nCorrCap = 60` (`:1880-1883`).
- **Status vs doc**: **SUPERSEDED** on the line references (`masterConfig.m:646` and `:2395` no longer point
  at these leaves); the numeric values are unchanged.
- **Verdict**: **correct** — plausible and conservative at the observable level.
- **Sources**: Schaefer et al. (2000) — "C/No: 40...60 dBHz ->noise 500ps (PN 2.5 MChip/s, t = 1s)"
  (PDF p. 2). Fridelance et al. (1996) — "monitoring of a satellite clock of the order of 50 ps" (p. 1);
  "integrated over 10 days is evaluated at 50 ps" (p. 5). Merlo et al. (2023) — "obtaining a timing
  precision of 2.26 ps" (p. 1720, abstract). Surof et al. (2026) — "σTWTT = 0.37 ps, and for ranging
  σrange = 121 µm" (p. 9 of 10); "At a time scale of 1 ms the TWTT and ranging precision is extrapolated
  from the measured dataset to be around 2 ps and 600 µm" (p. 9). Lewandowski, W., Petit, G., & Thomas, C.
  (1993). Precision and accuracy of GPS time transfer. *IEEE TIM, 42*(2), 474–479 — "The precision of time
  transfer over intercontinen- tal distances by the GPS common-view method reaches 3-4 ns for a single
  13 min measurement, and decreases to 2 ns when averaging several measurements over a period of one day."
  (p. 474, abstract).
- **Critical analysis**. The framing sentence is right and should go in the thesis verbatim: the sim assumes
  a modem ~5× better than the classical 2.5 Mchip/s TWSTFT (500 ps @ 1 s) and ~40–80× worse than
  demonstrated carrier-phase/optical links (0.37–2.26 ps). Two additions. First, the doc's claim that the
  15 ps steady-state figure is legitimate "only because the correlated tower-product error is
  nCorr-inflated on this path" is **still true for the legacy path but weaker than stated**: since the
  bias/wander split (`TwoWayTimeTransferBuilder.m:255-293`), only the piecewise-constant part is inflated,
  so the effective averaging floor moved. Any 15 ps number from before that change is not comparable with
  one after it. Second, `SwarmRelativeSolver.clockNoise_` (`:1367-1390`) explicitly **does not** apply the
  `nCorrCap = 60` inflation, with a correct justification (the consumer is a per-epoch weighted least
  squares with no temporal averaging) and an honest note that the omission previously made
  `relClockFormalSigma_m` run `√7.37 = 2.72×` high. That is exactly the right level of disclosure.

### 12. Relativistic terms on the satellite clock — SUPERSEDED, and now the domain's biggest defect

- **Code**:
  - `+revgnss/ReciprocalEndpointTruthProvider.m:43` —
    `localClockRate = 1 + asset.clock.getOscillatorDriftMetersPerSecond()/c;` with the rationale comment at
    `:36-42`; `properTimeRate_` at `:99-115`:
    `rate = 1 - (EARTH_GM_M3PS2/radius + 0.5*dot(v,v))/c^2`. Ground station forced to
    `properTimeRate = 1` at `:85` (comment `:65-67`).
  - `+revgnss/TwoWayCodeEndpointModel.m:105-108` — `localTimeAt` uses **only** `localClockRate`.
    `:115-117` — `coordinateDurationForProperDuration = properDuration_s / properTimeRate` is the **sole**
    consumer of `properTimeRate` anywhere in the repo (verified by exhaustive grep).
  - `+models/+clocks/ClockModel.m:335` — `new_bias_s = bias_s + dt*(fracFreq + relativisticFracFreq) + n_wfm`
    (the truth bias **does** ramp); `:388` `getFractionalFrequency` includes `relativisticFracFreq`;
    `:420-430` the new oscillator-only accessors; accessor-choice note at `:400-418`.
  - **NEW MODULE** `+models/+clocks/RelativisticClockCorrection.m` — `fracFreq` (`:36-63`, gated on
    `cfg.physics.relativity.clock.model.enable`), `bias_m = c·y·t_s` (`:65-70`), `rate_mps = c·y` (`:72-77`).
    Applied in `h` at `CodeMeasurementBuilder.m:73-74`, `CarrierMeasurementBuilder.m:73`,
    `DopplerMeasurementBuilder.m:139`, `ISLMeasurementBuilder.m:179-180`,
    `TwoWayTimeTransferBuilder.m:166-167` (prefit) and `:366-367` (postfit).
    **Not** applied anywhere in `FourTimestampGroundSpaceTimeTransferBuilder` /
    `FourTimestampEstimatorEndpointBridge`.
  - **NEW FILES** `+revgnss/TruthEndpointReplay.m`, `+revgnss/TruthEndpointReplayClock.m` (commit
    `889dcf6`): the replay clock subtracts `relativisticFracFreq · c` from the recorded total drift
    (`TruthEndpointReplayClock.m:57-58`); `truthRelativisticFracFreq` is a *required* field
    (`TruthEndpointReplay.m:70-76`).
- **Status vs doc**: **SUPERSEDED**. The doc's three mechanisms are now four, the accessor changed, a new
  model-side module exists, and the line refs moved (`:92-107`→`:99-115`, `:58-60`→`:65-67`).
- **Verdict**: **flawed** — two independent defects, both verified twice from opposite directions
  ("what does the caller pass?" and "what does the callee actually use?").
- **Sources**: Fridelance et al. (1996) — "τrelativity is a relativity correction term corresponding to the
  Sagnac effect [11]." (p. 3); "The relativity corrections are well" [known] (p. 5). Surof et al. (2026) —
  "Relativistic effects or biases are not consid- ered in the laboratory verification, but are addressed
  further in (Trainotti et al. 2022)." (p. 5 of 10) — the same explicit scoping practice the sim should
  adopt. ITU-R TF.1153-4 [EXTERNAL] does not treat the relativistic rate offset at all (it is a
  ground-to-ground recommendation), which is itself worth stating.
- **Critical analysis** — two defects.

  **(12a) The four-timestamp ground-space `h` omits the model-side relativistic clock correction.**
  Every other EKF channel adds `c·y_rel·t` to `b_rx` in `h`, which by construction makes the EKF state
  `x(b_rx)` an *oscillator-only* bias. `FourTimestampGroundSpaceTimeTransferBuilder.m:154-157` (prefit) and
  `:253-256` (postfit) call `FourTimestampEstimatorEndpointBridge.fromAssetStateBlock(x, stateMap, 1, …)`
  with no override, so `buildEstimatorEndpoint_` (`:161`) reads `clockBias_m = x(blk.b)` raw. Meanwhile the
  truth tag reference `clockLocalTimeAtReference_s = t_s + asset.clock.getBiasMeters()/c`
  (`ReciprocalEndpointTruthProvider.m:35, :54`) **does** carry the accumulated ramp. Residual
  `z − h = c·y_rel·t`.
  Magnitude: `y_rel = GM/c²(1/R⊕ − 1/r_GEO) − (v_sat² − v_gnd²)/2c²`
  `= 4.4351×10⁻³ × 1.33068×10⁻⁷ − 5.2596×10⁻¹¹ + 1.203×10⁻¹² = 5.3877×10⁻¹⁰`; `c·y_rel = 0.16152 m/s`;
  over 3600 s that is **581 m** — matching `masterConfig.m:107` and `RelativisticClockCorrection.m:7`
  ("581 m over a 3600 s arc") digit for digit.
  Gating: fires only when `physics.relativity.clock.model.enable = true`. `config/golden_baseline.json`,
  `golden_baseline_multi.json` and `golden_baseline_attitude.json` **all** set
  `physics.relativity.clock.{enable, truth.enable, model.enable} = true`, and
  `config/internal/realismGradeConfig.m:146-148` turns it on too. No shipped config yet selects
  `mode='fourTimestampClockDifference'` on the ground-space path (only tests do), so the defect is
  **latent today and immediate on the first thesis run that flips the mode.** Severity: HIGH.

  **(12b) Commit `889dcf6`'s "double count" does not exist; the fix removed real physics.**
  The commit, `ClockModel.m:400-418`, `ReciprocalEndpointTruthProvider.m:36-42`,
  `TwoWayISLMeasurementBuilder.m:1205-1212` and `TruthEndpointReplayClock.m:36-58` all assert: "An endpoint
  that already supplies `properTimeRate` is therefore ALREADY carrying `y_rel`; adding it again through
  `localClockRate` counts the same physics twice." That is false as implemented. `properTimeRate` is a
  property of `TwoWayCodeEndpointModel` whose **only** method is
  `coordinateDurationForProperDuration` (`:115-117`), called from exactly three places
  (`ReciprocalTimestampEventModel.m:115`, `FourTimestampObservableBuilder.m:273`,
  `CoherentTwoWayCodeRangingModel.m:64/67/227`) — all of them the *transponder turnaround* conversion.
  `localTimeAt` (`:105-108`) never touches it. With the default 1 ms turnaround, the entire
  `properTimeRate` contribution to the observable is `1×10⁻³ × 1.578×10⁻¹⁰ = 1.6×10⁻¹³ s = 0.16 fs`.
  Consequence: after `889dcf6`, the four-timestamp truth endpoints have a *bias* that ramps at
  `c·(y_osc + y_rel)` and a *rate* of only `1 + y_osc` — the same internal inconsistency that
  `ClockModel.m:374-380` documents (and fixed) for the code-vs-Doppler pair, transposed onto the
  four-timestamp channel.
  Magnitude on a ground-space link: the rate enters the observable as
  `½[y_d(t2+t3−2t0) − y_o(t1+t4−2t0)] ≈ −½·Δy·T_rt` with `T_rt = τ_f + Δ_turn + τ_r ≈ 0.254 s`, so the
  missing term is `½ × 5.3877×10⁻¹⁰ × 0.254 × 2.998×10⁸ = **2.05 cm**` — a constant 0.68σ bias on a
  σ = 0.03 m row.
  Magnitude on a sat-sat link: `y_rel` is common to both endpoints of a 2 km formation
  (`∂y/∂r = GM/(c²r²) = 2.5×10⁻¹⁸ m⁻¹`, so `Δy_rel ≈ 5×10⁻¹⁵` over 2 km), giving `< 1 µm`. **Negligible —
  which is why the commit's own end-to-end check ("the numbers barely move") could not see the problem.**
  The correct fix is `localClockRate = properTimeRate · (1 + y_osc)` with the total-drift accessor removed
  from the endpoint, **or** keeping `getDriftMetersPerSecond` and documenting `properTimeRate` as a
  turnaround-only unit conversion. The current arrangement is neither. Severity: MEDIUM (HIGH once 12a is
  fixed and the four-timestamp ground-space mode goes live).

  **Still valid from the doc**: the `properTimeRate_` formula itself is the correct first post-Newtonian
  spherical-Earth `dτ/dt`, four independent re-implementations agree
  (`ReciprocalEndpointTruthProvider.m:109-110`, `FourTimestampEstimatorEndpointBridge.m:190-191`,
  `TwoWayISLMeasurementBuilder.m:1576+`, `CoherentTwoWayRangeLinkUpdateAdapter.m:340+`), and the ground
  station is honestly hard-set to 1 with an in-file fidelity note. The doc's warning that the sim cannot
  make absolute-timescale claims (UTC steering, TAI contribution) is unchanged and correct.

### 13. NEW — silent-fallback machinery in the four-timestamp replay path

- **Code**: `+revgnss/SwarmRelativeSolver.fourTimestampObservables_` (`:1211-1345`). Five degradation
  returns, none of which errors: `isUsable` precheck (`:1239-1245`), `catch setupErr` (`:1259-1262`),
  `catch obsErr` (`:1294-1298`), sign-check failure (`:1321-1326`), range-check failure (`:1337-1343`).
  Callers set `shapeObservationSource='syntheticTwoWayISL'` / `relClockObservableSource=
  'syntheticClockDifference'` plus a reason string (`:157-161`, `:1143-1147`) and continue.
  `TruthEndpointReplay.unusableReason` (`:59-94`) enumerates the required fields.
- **Status vs doc**: **NEW** (the doc predates `889dcf6`).
- **Verdict**: **partially correct** — the labelling is honest, the gating is absent.
- **Sources**: n/a (software-engineering finding).
- **Critical analysis**. (i) **Is the fix complete?** Yes for the specific cause: `TruthEndpointReplayClock`
  now implements `getOscillatorDriftMetersPerSecond` (`:39-58`), and `truthRelativisticFracFreq` is
  *required* rather than defaulted, which is the right call. (ii) **Can a silent fallback still happen?**
  Yes — all five paths above remain, and two of them (`catch setupErr`, `catch obsErr`) will swallow *any*
  future exception in the physics chain exactly as the missing-accessor one did. (iii) **What does the
  fallback do now?** Identical to before: `z = (b_i − b_k) + pairBias + thermal` (`:1161`) for the clock
  layer and `‖r_i − r_k‖ + pairBias + thermal` (`:1198-1204`) for the shape layer — an exact clock
  difference and an exact instantaneous geometric range with no round trip in them at all.
  **The gap that matters**: there is no automated gate. Grepping the whole test tree for
  `shapeFallbackReason`/`relClockFallbackReason` returns **zero** assertions, and the only test that reads
  `shapeObservationSource` (`tests/test_swarm_two_way_isl_gating.m:37`) *asserts the fallback string*
  because its synthetic fixture cannot be replayed. `889dcf6` was verified by a manual run recorded in the
  commit message. If the replay breaks again — and this repo has already had two instances of exactly this
  failure mode, the second documented at `tests/test_four_timestamp_exactly_once_consumption.m:5-18`, where
  a missing allow-list entry made *every* update throw inside a try block and the catch handler itself
  throw, masking the real error — the suite stays green and the label silently reverts.
  Also worth recording: the runtime sign check (`:1310-1327`) compares `errSame` with `errFlip` and only
  fails when the *negated* truth matches better. It has **no absolute tolerance**, so a constant offset of
  any size in the four-timestamp clock value passes as long as the sign is right. The range check
  immediately below it *does* have one (`residRms < 0.10` m, `:1338`). The asymmetry is unexplained and the
  clock check should get a tolerance of its own — the physical difference between the four-timestamp value
  and the truth clock difference is `½(τ_f − τ_r)`, i.e. sub-µm for a co-moving formation, so a
  millimetre-level tolerance would be both safe and diagnostic.

---

## Double-count candidates

**DC-1 — `relativisticFracFreq` counted once in the truth bias and zero times in the truth rate
(an UNDER-count masquerading as a double-count fix).** SEVERITY: **HIGH**.
- Location A: `+models/+clocks/ClockModel.m:335` — `new_bias_s = bias_s + dt*(fracFreq + relativisticFracFreq) + n_bias_wfm;`
  (the truth clock **bias** accumulates the relativistic ramp).
- Location B: `+revgnss/ReciprocalEndpointTruthProvider.m:43` (and the identical
  `+revgnss/TwoWayISLMeasurementBuilder.m:1212`, `+revgnss/TruthEndpointReplayClock.m:57-58`) —
  `localClockRate = 1 + getOscillatorDriftMetersPerSecond()/c` (the **rate** deliberately excludes it).
- Mechanism: the exclusion is justified by the claim that `properTimeRate` already carries `y_rel`, but
  `properTimeRate` reaches the observable only through
  `TwoWayCodeEndpointModel.coordinateDurationForProperDuration` (`:115-117`), never through `localTimeAt`
  (`:105-108`). The claimed double count is worth `1 ms × 1.578×10⁻¹⁰ = 0.16 fs`; the removed physics is
  worth `½ · y_rel · T_rt · c`.
- Size: **2.05 cm** constant bias per ground-space four-timestamp row (σ = 3 cm ⇒ 0.68σ); `< 1 µm` on
  sat-sat links (common-mode).
- Severity: HIGH as a correctness/consistency defect, currently latent because no shipped config selects
  the ground-space four-timestamp mode.

**DC-2 — the model-side relativistic bias is applied on five channels and omitted on one.**
SEVERITY: **HIGH (latent)**.
- Location A: `+models/+measurements/CodeMeasurementBuilder.m:73-74`,
  `CarrierMeasurementBuilder.m:73`, `DopplerMeasurementBuilder.m:139`,
  `+revgnss/ISLMeasurementBuilder.m:179-180`, `+revgnss/TwoWayTimeTransferBuilder.m:166-167` and `:366-367`
  — all add `RelativisticClockCorrection.bias_m(cfg,t_s)` (or `rate_mps`) to `h`.
- Location B: `+revgnss/FourTimestampGroundSpaceTimeTransferBuilder.m:154-157` and `:253-256` →
  `+revgnss/FourTimestampEstimatorEndpointBridge.m:161-162` — `clockBias_m = x(blk.b)`,
  `localClockRate = 1 + x(blk.bdot)/c`, **no correction**.
- Mechanism: this is not literally a double count, it is the *inverse* — an inconsistent definition of the
  same state across channels. Because the code rows define `x(b_rx)` as oscillator-only, the
  four-timestamp rows implicitly define it as total. Both cannot hold; the EKF resolves the conflict
  through the Kalman gain and pushes the residue into position, which is the exact failure mode
  `ClockModel.m:374-386` and `RelativisticClockCorrection.m:14-23` document (13.07 m of position error,
  `cos(error, K·1) = 0.9997`).
- Size: `c·y_rel·t` = 0.1615 m/s ramp, **581 m at 3600 s**.
- Severity: HIGH the moment `measurements.twoWayTimeTransfer.mode='fourTimestampClockDifference'` is used
  with any golden-baseline-derived or realism-grade config (all of which enable
  `physics.relativity.clock`).

**DC-3 — the four-timestamp ground-space R inflates the tower clock's *oscillator wander* by `nCorr`.**
SEVERITY: **MEDIUM**.
- Location A: `+revgnss/TwoWayTimeTransferBuilder.m:255-293` — the legacy path splits
  `towerClkSigmaVec` into `sConst_` (piecewise-constant product bias, `productOnlySigma`) and
  `wanderVar_ = sig_prod² − sConst_²` (sawtooth oscillator wander) and charges
  `Ri = σ² + nCorr·sConst_² + wanderVar_`.
- Location B: `+revgnss/FourTimestampGroundSpaceTimeTransferBuilder.m:181` —
  `Ri = sigma_m^2 + nCorr * towerClockSigma_m^2`, i.e. `nCorr` copies of the **whole** provider sigma.
- Mechanism: the wander component is zero at the product epoch and maximal just before the next, so it is
  *not* shared across an interval's rows and must not be inflated. The legacy path measured the cost of
  getting this wrong in-file: "Charging n_corr = 30 copies of it took the two-way row from 2.42 m to
  13.25 m of sigma at age 34 s: a 24x de-weighting" (`TwoWayTimeTransferBuilder.m:263-268`).
- Size: up to a **24× de-weighting** (σ 2.42 m → 13.25 m at age 34 s with `nCorr = 30`) of the one
  observable that breaks the GEO radial↔clock degeneracy.
- Severity: MEDIUM — conservative (never optimistic), but it throws away most of the four-timestamp row's
  information, and the fix already exists 70 lines away in the sibling builder.

**DC-4 — the same physical delay-calibration error is generated twice, from two independent RNG streams,
for the same physical ISL terminal.** SEVERITY: **LOW–MEDIUM**.
- Location A: `+revgnss/SwarmRelativeSolver.clockNoise_` (`:1367-1390`) — `pairBias(p)` drawn from
  `N(0, sigma_const_m² + sigma_rw_m²)` on stream `baseSeed + 2000 + node`, added to the clock observable at
  `:1167`.
- Location B: `+revgnss/SwarmRelativeSolver.islNoise_` (the shape layer's equivalent) — a second,
  independently seeded `pairBias` added to the range observable at `:1204`.
- Mechanism: one physical transponder chain has one delay error. Modelling the clock layer's and the
  range layer's calibration bias as statistically independent understates their true correlation (they are
  the *same* `RX+TX` / `RX−TX` combinations of one delay chain). It is not a variance double count within
  either layer, but it does make the two layers' errors artificially uncorrelated, which flatters any joint
  clock+geometry (beamforming) figure that sums them.
- Size: `sqrt(0.01² + 0.003²) = 10.4 mm` per pair per layer; the beamforming phasor series sums clock and
  geometry error per element, so the flattery is `√2` in the summed term when the truth would be `2×`.
- Severity: LOW–MEDIUM; a truth-consistency defect, not an R defect. Belongs to the ISL/swarm domain too.

**DC-5 — `plasmaResidualSigma` and `nonThermalSigma` are charged in R but not injected in `z`
(an over-count, i.e. R > residual variance).** SEVERITY: **LOW**.
- Location A: `+revgnss/TwoWayISLMeasurementBuilder.m:571-573` —
  `observationVariance = thermalSigma^2 + plasmaResidualSigma^2 + nonThermalSigma^2;`
- Location B: `+revgnss/TwoWayISLMeasurementBuilder.m:579-582` —
  `trackingError_s = 2*thermalSigma/C_mps * drawNormal_(...)` — only `thermalSigma`.
- Mechanism: R declares a total error budget the truth does not produce.
- Size: both terms default to 0, so the shipped runs are unaffected; any run that sets them makes NIS
  read low by `(σ_th² + σ_pl² + σ_nt²)/σ_th²`.
- Severity: LOW (conservative, and default-inert), but it means **NIS on this channel is not a validity
  test whenever those leaves are nonzero** and must be stated wherever NIS is cited.

**Explicitly checked and found NOT to be double counts** (worth recording so they are not re-litigated):
- The clock difference `(b_rx − b_tower)` appearing in both the one-way pseudorange and the two-way row —
  independent measurements of the same quantity, i.e. fusion. The tower-product variance is charged in R
  **only** when the tower clock is not an EKF state (`TwoWayTimeTransferBuilder.m:203-217`), so it is never
  in both P and R. Verified at HEAD.
- `reciprocitySigma_m` added to R (`:294`) alongside the reciprocity term in both `z` and `h` — the σ
  covers the *residual* after twin cancellation, not the term itself.
- The relay session's `sessionCommonCovariance_s2` vs `independentVariance_s2`
  (`GroundRelaySessionObservableBuilder.m:161-163`, `:184`) — disjoint by construction
  (t1/t4 station tags and atmosphere propagate to the independent block; t2/t3 relay tags do not).

---

## Logical flaws

**LF-1 — Silent degradation is still the default failure mode of the four-timestamp replay, and no test
gates it.** `SwarmRelativeSolver.m:1239-1245, 1259-1262, 1294-1298, 1321-1326, 1337-1343`. Five returns
drop to a synthetic observable without erroring; `shapeFallbackReason`/`relClockFallbackReason` are recorded
but asserted nowhere in `tests/`. `tests/test_swarm_two_way_isl_gating.m:37` asserts
`shapeObservationSource == 'syntheticTwoWayISL'`, encoding the fallback as expected. This is the exact class
of defect `889dcf6` and `tests/test_four_timestamp_exactly_once_consumption.m` each fixed one instance of.
**Recommended gate**: a regression test that runs the federated swarm on a real recorded result and asserts
`isempty(rel.shapeFallbackReason) && isempty(rel.relClockFallbackReason)`.

**LF-2 — Claim contradicted by code: "the endpoint already carries `y_rel` via `properTimeRate`."**
Asserted in `ClockModel.m:404-418`, `ReciprocalEndpointTruthProvider.m:36-42`,
`TwoWayISLMeasurementBuilder.m:1205-1212`, `TruthEndpointReplayClock.m:41-52`,
`TruthEndpointReplay.m:126-129` and the `889dcf6` commit message. `properTimeRate` reaches the observable
only through the turnaround conversion (`TwoWayCodeEndpointModel.m:115-117`), worth 0.16 fs. Five files and
a commit message state the same wrong premise. See DC-1.

**LF-3 — Truth/estimate asymmetry created by LF-2.** The four-timestamp truth endpoint uses the
*oscillator* rate (`ReciprocalEndpointTruthProvider.m:43`); the estimator endpoint uses the raw state drift
(`FourTimestampEstimatorEndpointBridge.m:162`), which the EKF drives towards the *total* rate because the
truth bias ramps. `z` and `h` therefore disagree by construction at the ~2 cm level on ground-space links.

**LF-4 — Doc claim inverted (§5).** "the observable … senses each endpoint's TX and RX terminal delays only
through their per-endpoint *sum* weighted ½" and "cannot represent an ITU-style ½[TX(k)−RX(k)] asymmetry
independently of the range observable". The observable senses `RX − TX` and is blind to `RX + TX`; it is the
*range* observable that uses the sum. Derived twice and cross-checked against ITU-R TF.1153-4 p. 4.

**LF-5 — `splitEvenly` is a terminal-delay allocation under which the terminal delays are exactly inert.**
`FourTimestampObservableBuilder.m:195-197`: `tags + 0.5*[−O, A, −A, O]` leaves
`Δ` algebraically unchanged. This is *physically correct* (a symmetric station has no non-reciprocity), but
it is a config value under which two declared hardware leaves have provably zero effect on the observable,
and nothing says so. Contrast the repo's own strict "an inert toggle must fail validation" invariant
(`FourTimestampGroundSpaceTimeTransferBuilder.m:353-355`).

**LF-6 — The four-timestamp Jacobian's small columns are finite-differenced below the reduction's
floating-point floor, and the test's "independent oracle" shares the same floor.**
`FourTimestampObservableLinearization.groundSpaceJacobian` 5-point-stencils
`FourTimestampObservableBuilder.predictFromEndpointModels` with `positionStep_m = 0.25`
(`FourTimestampObservableLinearization.m:47-49`). The tags are formed as
`clockLocalTimeAtReference_s + rate*(t_k − t0)` with `clockLocalTimeAtReference_s = t_s + bias/c`
(`TwoWayCodeEndpointModel.m:106-107`), so each tag carries a representation granularity of `eps(t_s)`:
at `t_s = 3600 s`, `eps = 2⁻⁴¹ = 4.547×10⁻¹³ s = 1.36×10⁻⁴ m`. The reduction differences four such tags, so
`value_m` has a ~10⁻⁴ m noise floor; divided by `12h = 3 m` the position columns inherit ~`4.5×10⁻⁵` of
noise. The *true* position sensitivity of a clock-difference observable is
`∂h/∂r = c·½·∂(τ_f − τ_r)/∂r ≈ (v_A + v_B)/(2c) ≈ 6×10⁻⁶` — **below the noise from about `t_s ≈ 30 s`
onward**. `tests/test_four_timestamp_ground_space_finite_difference_jacobian.m` cannot detect this: it runs
at `t4_s = 100` (`:157`) and its "independent oracle" (`:248-252`) rebuilds the tags with the *identical*
`t4_s + bias_s + rate*(Δt)` expression, so the cancellation error is common to both sides and subtracts out
of `err = abs(H - oracleH)`. **This is an analytic estimate, not a measurement** — it should be measured by
evaluating `groundSpaceJacobian` at `t4_s ∈ {0, 100, 1800, 3600}` and comparing the position columns. The
structural fix is to reduce the tags relative to `t4` before differencing.

**LF-7 — The runtime four-timestamp clock sign check has no absolute tolerance.**
`SwarmRelativeSolver.m:1316-1327` fails only when the *negated* truth matches better. Any same-sign
constant offset passes. The sibling range check (`:1337-1343`) has a 0.10 m tolerance. A test that can only
detect a sign flip cannot detect a delay-bookkeeping error, which is the stated purpose of the neighbouring
range check.

**LF-8 — `TruthEndpointReplay`'s own header is stale.** `:10-12` still says the chain reads
"`clock.getBiasMeters()` and `clock.getDriftMetersPerSecond()`". Since `889dcf6` the four-timestamp path
reads `getOscillatorDriftMetersPerSecond`. Cosmetic, but it is the exact sentence a reader would use to
decide which accessor to implement on a new duck-typed clock — i.e. the sentence that caused the original
bug.

**LF-9 — `ReciprocalTimeTransferModel.validateMode` reserves `'fourTimestampPhysical'` for a scheme that
does not exist, while the implemented mode is `'fourTimestampClockDifference'` and is dispatched *before*
this method is reached** (`ReciprocalTimeTransferModel.m:81-90`, `TwoWayTimeTransferBuilder.m:117-122`).
The error message is unusually good about explaining this, but it remains a two-string vocabulary for one
concept and is a live trap for anyone reading the mode enum rather than the dispatcher.

**LF-10 — The ledgered-rejection path in the distributed coordinator is a softer version of LF-1.**
`IndependentFleetCoordinator.applyOneLinkUpdate_` (`:987-1040`) throws on any adapter failure and
`applyOwnerOnlyLinkUpdate_` converts it into `recordRejectedFromEligible`. That is much better than a bare
catch (the reason is recorded and typed), but the run still completes with rows silently missing, and the
same "nobody was reading it" exposure applies. `tests/test_four_timestamp_exactly_once_consumption.m:5-18`
documents that this path previously masked a real error entirely.

---

## Limits of this domain

Concrete statements the thesis may **not** make from the current code, with the numbers that bound them.

1. **No accuracy claim at S-band.** The four-timestamp ground-space default is 2.2 GHz
   (`masterConfig.m:2945`) and the ionospheric up/down asymmetry is absent from every two-way `z` and `h`.
   Scaling ITU's Ku-band example (0.220 ns at 100 TECU, 14.5/12.5 GHz, p. 6) to 2.2 GHz gives ~18.5 ns per
   leg at 10 TECU, so a realistic frequency split yields nanosecond-class asymmetry against a 100 ps
   (0.03 m) declared σ. **Every two-way result at S-band is a precision, never an accuracy, figure.**
   The 26 GHz ISL four-timestamp link (`masterConfig.m:2831`) is exempt — no ionosphere on that path.
2. **No claim that the four-timestamp physical chain has been exercised in the federated swarm before
   `889dcf6`.** By the project's own admission the real replay threw every epoch and every pair; every
   pre-`889dcf6` federated relative-clock and shape number was produced by the synthetic observable
   (`z = (b_i − b_k) + bias + noise`, `SwarmRelativeSolver.m:1161`), which contains no round trip at all.
   Post-fix the numbers are shape 0.0457 m (unchanged) and relative clock 0.0218 → 0.0239 m.
3. **No claim of calibrated hardware delays.** `truth.originTerminalCalibrationError_s`,
   `truth.anchorTerminalCalibrationError_s`, `calibration.originTerminalSigma_s` and
   `calibration.anchorTerminalSigma_s` are all zero by default on both hosts
   (`masterConfig.m:2848-2851`, `:2962-2965`) and nonzero sigmas are *refused*
   (`FourTimestampGroundSpaceTimeTransferBuilder.m:316-328`). Every four-timestamp run assumes perfectly
   calibrated terminals. ITU's own § 3.6 (p. 6) makes station-delay determination the central accuracy
   problem of TWSTFT; the sim does not model it.
4. **No claim that counter/tag noise has been carried in the filter.** `counterTag.sigma_s` is refused
   nonzero on both hosts (`FourTimestampGroundSpaceTimeTransferBuilder.m:335-342`;
   `InterSatelliteFourTimestampTimeTransferBuilder.m:43-52`). The per-tag CRLB anatomy of Merlo's analysis
   (`σ_Δ = ½√(Σσ_i²)`) is not exercised; a single processed-domain σ = 0.03 m is drawn instead.
5. **No absolute-timescale claim.** `physics.relativity.clock` is a *rate* offset absorbed by the estimated
   drift state; the ground station's `properTimeRate` is hard-set to 1
   (`ReciprocalEndpointTruthProvider.m:85`), i.e. the Earth's own potential offset (`≈ −6.97×10⁻¹⁰`) is not
   modelled. UTC steering, TAI contribution and any absolute-frequency statement are out of scope. With
   defects 12a/12b open, even the *relative* four-timestamp ground-space channel is not internally
   consistent under `physics.relativity.clock.model.enable = true`.
6. **No non-reciprocity validation from the legacy or synthetic-ISL modes.** In `firstOrderReciprocal`
   (`TwoWayTimeTransferBuilder.m:219-232`) and `InterSatelliteTimeTransferBuilder` (`:544-552`) the geometry
   is ECEF with zero tower velocity and no light time, so the ~100 ns Sagnac term and the ~µm motion term
   exist on neither side. Agreement between `z` and `h` there is twin consistency, not physics validation.
7. **No claim on the four-timestamp row's position/velocity/attitude sensitivity.** True
   `|∂h/∂r| ≈ 6×10⁻⁶` (dimensionless) versus an FD noise floor reaching ~`4.5×10⁻⁵` by `t_s = 3600 s`
   (LF-6). The row should be treated as clock-only; any statement that the four-timestamp observable
   "also constrains position through the lever arm" is unsupported at long arc lengths, and is doubly
   unsupported under the shipped `commonAperture` geometry, where the transmit and receive phase-centre
   offsets are identical (`masterConfig.m:2973-2974`, both `[0.8;0.2;0.3]`) so the attitude columns are
   near zero by construction.
8. **The motion non-reciprocity coefficient is untested.** `−ρρ̇/c` is 2× the derived and
   Shen-corroborated `−ρρ̇/(2c)` and omits the common-velocity term entirely; the only test constrains the
   static limit. Do not quote a "motion non-reciprocity was modelled" claim for `firstOrderReciprocal`
   runs; quote instead that it is default-off, twin-cancelling, and ~0 at GEO in ECEF.
9. **The 0.68 µm co-moving light-time asymmetry is geometry-specific.** It is the relative-motion part
   `ρρ̇/(2c)` for a radial/cross-track baseline. The common-velocity part
   `ρ·û·(v_A+v_B)/(2c)` reaches ~20 µm for a 2 km along-track baseline at GEO. Quote the mechanism, not
   the number.
10. **NIS is not a validity test on these channels.** The four-timestamp R is
    `σ² + nCorr·σ_prod²` with the wander inflated (DC-3), the ISL two-way R declares plasma and
    non-thermal terms the truth does not inject (DC-5), and the swarm relative-clock formal sigma is
    known to have run 2.72× high before the `nCorr` removal (`SwarmRelativeSolver.m:1372-1377`). Any
    consistency statement must name which R convention produced it.

---

## Status counts (this section, 12 documented features + 1 new)

| Status | Count | Which |
|---|---|---|
| STILL-VALID | 5 | §1 (combination/sign), §2 (event chain/oracle), §8 (atmosphere absent), §9 (relay session — verdict), §10 (0.68 µm) |
| DRIFTED (line numbers only) | 4 | §3 (Sagnac), §4 (reciprocity), §6 (coherent code), §9 (relay line refs) |
| SUPERSEDED | 3 | §7 (legacy R now bias/wander split), §11 (masterConfig line refs), §12 (relativity — new module + accessor change) |
| NOW-WRONG | 1 | §5 (doc's TX/RX sum-vs-difference reasoning; the code is fine) |
| NEW | 1 | §13 (silent-fallback machinery + `TruthEndpointReplay`/`TruthEndpointReplayClock`/`RelativisticClockCorrection`) |

## Files read in full or in relevant part

`+revgnss/`: `FourTimestampObservableBuilder.m`, `FourTimestampObservableLinearization.m`,
`FourTimestampGroundSpaceTimeTransferBuilder.m`, `FourTimestampEstimatorEndpointBridge.m`,
`FourTimestampPhysicalLinkConfig.m`, `FourTimestampClockDifferenceObservable.m` (header),
`ReciprocalTimestampEventModel.m`, `ReciprocalEndpointTruthProvider.m`, `ReciprocalTimeTransferModel.m`,
`ReciprocalTimeTransferCovarianceBuilder.m`, `ReciprocalLinkHardwareModel.m`,
`DirectReciprocalTimeTransferBuilder.m`, `TwoWayTimeTransferBuilder.m`, `TwoWayCodeEndpointModel.m`,
`CoherentTwoWayCodeRangingModel.m`, `ConstantVelocityFourEventLightTimeOracle.m`, `ISLTimingModel.m`,
`InterSatelliteTimeTransferBuilder.m`, `InterSatelliteFourTimestampTimeTransferBuilder.m`,
`GroundRelaySessionObservableBuilder.m`, `TruthEndpointReplay.m`, `TruthEndpointReplayClock.m`,
`SwarmRelativeSolver.m` (time-transfer sections), `TwoWayISLMeasurementBuilder.m` (endpoint/noise sections),
`IndependentFleetCoordinator.m` (`applyOneLinkUpdate_`).
`+models/`: `+clocks/ClockModel.m`, `+clocks/RelativisticClockCorrection.m`,
`+measurements/CodeMeasurementBuilder.m` (relativistic block).
`config/`: `masterConfig.m` (relevant leaves), `golden_baseline*.json`, `internal/realismGradeConfig.m`.
`tests/`: `test_four_timestamp_ground_space_finite_difference_jacobian.m`,
`test_four_timestamp_exactly_once_consumption.m`, `test_swarm_two_way_isl_gating.m`,
`test_four_timestamp_ground_space_time_transfer_builder.m` (scan).
Git: `git show 889dcf6` in full; `git log -S` for `RelativisticClockCorrection.bias_m` in
`TwoWayTimeTransferBuilder.m` (added by `3ece3b8`, i.e. **after** the four-timestamp builder was created in
`6fa292e` — which is why the four-timestamp path was never updated).

---

# Round 2 re-verification — Carrier-phase ambiguity resolution, LAMBDA, bootstrap, wide-lane, cycle slips

Scope: `+revgnss/+integer/{LambdaResolver, DecorrelatedBootstrap, BaselineAmbiguityLambda, IslDoubleDifference}.m`;
`+revgnss/{IntegerAmbiguityFixer, AmbiguityFixingReadinessGate, AmbiguityArcState, AmbiguityStateRegistry,
WideLaneNarrowLaneDiagnostics, CycleSlipDetector, GroundCarrierAmbiguityResolver, GroundCarrierObservationSet,
GroundCarrierAmbiguityProbe, BaselineCarrierAmbiguityResolver, CarrierTrackManager, IslCarrierTrackManager}.m`;
the ISL carrier float-ambiguity path in `+revgnss/ISLMeasurementBuilder.m` and `+filter/ReverseGNSSEKF.m`;
`config/ladder/ISL/isl016_carrierFloatAmbiguity.json`, `config/ladder/ISL/isl017_carrierHonestProduct.json`,
`tests/regression/run_multi_islcarrier_regression.m`, and the two new band-following tests.

**Provenance of the code state.** `git diff --stat 3489075..HEAD` over this domain shows **zero source changes**:
the eight new commits added only the two ladder JSONs, the regression driver and three golden `.mat` files.
Every `+revgnss/+integer/*.m` and every ambiguity/carrier class is byte-identical to the state the doc audited.
Line-number drift below is therefore *doc drift* (the original citations were already 1–20 lines off in places),
not code drift — except for `+models/+measurements/CarrierMeasurementBuilder.m`, which has grown to 786 lines
and whose citations have moved a long way.

**Measured facts read out of the frozen goldens** (`matlab -batch`, working-tree `.mat`, 3600 s, G5S6R4):

| rung | product | RMS |pos err| | mean per-axis σ | err / (√3·σ) |
|---|---|---|---|---|
| isl016 (oracle) | `enable=false` → h reads neighbour TRUTH | **0.003562 m** | 0.003102 m | 0.66 (consistent) |
| isl017 (honest) | `enable=true`, 3 cm pos / 2 cm clk | **0.094562 m** | 0.005878 m | **9.3× overconfident** |

`nx = 72`, 5 ISL ambiguity states per leaf, in both.

---

### Double-difference formation and the correlated DD covariance

- **Code**: `+revgnss/GroundCarrierAmbiguityResolver.m:262` — `v = (mw(i,m,k) - mw(1,m,k)) - (mw(i,refTw,k) - mw(1,refTw,k));`
  Covariance `ddCovariance_` at **:283–314** (doc said 283–314 ✓; the "understate/OVERSTATE" comment is at **:289–291**, doc said 290–292).
  Signed incidence over (link, epoch): `r = repmat(idx.amb(:),4,1)`, `v = [+1;-1;-1;+1]`, `S = sparse(r,c,v,n,nLink*max(idx.epoch))`,
  `Q = full(S*S.')*varLinkCyc`, then arc-mean normalisation `Q = Q./(cc*cc.')` (:306–310) and a `1e-12` ridge (:313).
  `IslDoubleDifference.m:83–87` propagates `QD = D*QU*D.'`. Probe DD at `GroundCarrierAmbiguityProbe.m:137–139` (doc said 130–132).
- **Status vs doc**: DRIFTED (line numbers only; substance unchanged).
- **Verdict**: correct — the between-DD correlation from the shared reference satellite and reference tower is constructed exactly, not approximated, and the arc-mean division by `n_p·n_q` is the right propagation for a sum over epochs.
- **Sources**:
  - Hofmann-Wellenhof, B., Lichtenegger, H., & Wasle, E. (2008). *GNSS — GPS, GLONASS, Galileo, and more*. Springer. — "ΣS = 2σ2 I … This shows that single-diﬀerences are uncorrelated." (p. 179, eq. 6.71)
  - Hofmann-Wellenhof et al. (2008) — "This shows that double-diﬀerences are correlated." (p. 180, immediately after eq. 6.77 `ΣD = 2σ² [2 1; 1 2]`)
  - Teunissen, P. J. G. (2001). GNSS ambiguity bootstrapping: Theory and application. *KIS 2001*, 246–254. [EXTERNAL, re-fetched and re-verified this round] — "The method of bootstrapping performs relatively poor, for instance, when applied to the DD ambiguities. This is due to the usually high correlation between the DD ambiguities." (p. 252)
- **Critical analysis**. Re-derived independently: for two DDs at one epoch sharing reference satellite and reference tower, the incidence construction gives diagonal `4v` and off-diagonal `2v`, i.e. correlation 0.5 — the exact `2σ²[2 1;1 2]` structure of eq. (6.77), with `4v` rather than `2v` on the diagonal because a *ground* DD spans four links rather than two single differences. The sparse `S·Sᵀ` form is exact for arbitrary sharing patterns and linear in row count. One naming defect survives: **`IslDoubleDifference` forms a SINGLE difference** — `transform` (:35–49) builds `(nLinks-1) × nLinks` with `+1` on link j and `-1` on the reference, one common receiver only; the header admits it at :29–31. The stale figure in that header ("sigmaClock_m = 0.02 m … ~0.1 cycle", :27–28) is now doubly misleading: `masterConfig.m:2678` ships 0.03 m, `isl017` sets 0.02 m, and the ISL band on those rungs is 26 GHz, not L1 — see the Limits section for the 2.45-cycle consequence.

### LambdaResolver — the LAMBDA 4.0 wrapper

- **Code**: `+revgnss/+integer/LambdaResolver.m:56–75` `toCycles` (`D = diag(1./lam); Qa_cyc = D*Qa_m*D';` full matrix, symmetrised); **:104–113** finiteness + `any(ev<=0)` gate; **:120** `[SR,FR] = Ps_LAMBDA(Qa_cyc,1,1)`; **:127** `SR < o.minSuccessRate → reject-lowSuccessRate`; **:135–136** `LAMBDA(aHat_cyc, Qa_cyc, o.method, o.nCands)`; **:162–170** hard refusal of partial fixes; **:174–181** `ratio = sqnorm(2)/sqnorm(1)`; **:188–202** `assertIntegerParametrisation`; **:209–210** defaults `method 3, minSuccessRate 0.999, nCands 2, ratioThreshold 2.0`.
- **Status vs doc**: STILL-VALID (every cited line confirmed at the same number).
- **Verdict**: partially correct — the algebra and the two-layer gate are right; one acceptance hole (below) and the toolbox internals remain unverifiable.
- **Sources**:
  - Joosten, P., & Tiberius, C. C. J. M. (2000). Fixing the ambiguities: Are you sure they're right? *GPS World, 11*(5), 46–51. — "Only when the success rate is close enough to 1 is one allowed to proceed as if the estimated integer ambiguities are non-stochastic." (p. 50)
  - Joosten & Tiberius (2000) — "if it is sufficiently large, say 99 or 99.9 percent, it is guaranteed that the actual success rate of the integer least-squares method is at least equally high" (p. 51)
  - Naqvi, N. A., Zhang, K., Masood, K., & Lv, M. (2013). *Design and simulation of GNSS phase based attitude determination of spacecraft* (AIAA 2013-4832). — "the ambiguities are decorrelated with an admissible transformation i.e., which preserves the integerness of the variables, resulting in a much less elongated search space" (p. 6)
- **Critical analysis**. Three things remain right and worth crediting: the *full-covariance* unit conversion (off-diagonals are what ILS lives on), the explicit precondition assert, and the refusal of partial fixes. **NEW DEFECT (logical flaw L-1): the ratio test is conditional and therefore skippable.** Line 174 reads `if numel(sqnorm) >= 2 && sqnorm(1) > 0`. When LAMBDA returns a single candidate — `cfg.estimator.lambda.method = 1` (rounding) or `2` (bootstrapping), both documented as legal at `masterConfig.m:419` — `sqnorm` has one element, the whole `if` block is skipped, `info.ratio` stays `NaN`, and the fix is **accepted with no discrimination test at all**. `o.nCands = max(2, round(L.nCands))` (:216) guards the *count requested*, not the count *returned*. A caller reading `info.accepted` cannot distinguish "ratio passed" from "ratio never computed" except by testing `isnan(info.ratio)`, which nothing does. Contrast `DecorrelatedBootstrap`, which always computes a ratio or explicitly reports `searchExhausted`. Severity medium: the default `method = 3` returns two candidates, so this is a config-reachable hole rather than a live one.

### DecorrelatedBootstrap — decorrelation, exact bootstrap success rate, bounded ILS

- **Code**: `+revgnss/+integer/DecorrelatedBootstrap.m:191–205` `ldl_` (hand-rolled `Q = L·diag(d)·Lᵀ`, refusing MATLAB's pivoting `ldl()`); **:123–166** `reduce_` (integer Gauss `mu = round(L(i,j))`, adjacent swap when `dbar = d(k)*L(k+1,k)^2 + d(k+1) < d(k) - 1e-12*max(1,d(k))`, full re-factorisation after each swap, `MAX_SWEEPS = 40`); **:71–73** `sig = sqrt(max(d,realmin)); info.successRate = prod(2*D.normcdf_(1./(2*sig)) - 1);`; **:207–218** `bootstrap_`; **:220–282** `ils_` with `chi2 = max((ratioThreshold+1)*bootCost, 1e-9*n)` at **:244**; **:168–177** `verifyTransform`; **:307–312** `adop_ = exp(sum(log(eig))/(2n))`; **:314–316** `normcdf_ = 0.5*erfc(-x/sqrt(2))`.
- **Status vs doc**: STILL-VALID for every cited line. **One doc claim is NOW-WRONG** (attribution, see below).
- **Verdict**: correct — the success-rate product, the conditioning convention, the decorrelate-then-bootstrap order, the swap criterion and the ADOP definition all check out symbol-for-symbol.
- **Sources**:
  - Teunissen (2001) [EXTERNAL, re-fetched] — Corollary 5: "P( ǎB = a ) = ∏_{i=1}^{n} ( 2Φ( 1 / (2σ_{âi|I}) ) − 1 )" (p. 250, eq. 19)
  - Teunissen (2001) — "L denotes the unique unit lower triangular matrix of the ambiguity vc-matrix' decomposition Q â = LDLT" (p. 249, after eq. 15)
  - Teunissen (2001) — "Bootstrapping should therefore be used in combination with the decorrelating Z-transformation of the LAMBDA method." (p. 252)
  - Teunissen (2001) — "the bootstrapped lower bound is presently the best available lower bound of the least-squares success rate" (p. 253)
  - Teunissen (2001) — LAMBDA search sizing: "χ2 = ( â − ǎB )T Q−1 â ( â − ǎB )" with "In this way one can work with a very small search space and still guarantee that the sought for integer least-squares solution is contained in it." (p. 253)
  - Joosten & Tiberius (2000) — "The conditional standard deviations follow directly from the triangular decomposition of the float ambiguity variance-covariance matrix Qâ =LTDL as the square root of the elements of diagonal matrix D." (p. 51)
  - Joosten & Tiberius (2000) — "it is essential that the variance–covariance matrix of the LAMBDA-transformed ambiguities be used to compute the conditional standard deviations" (p. 51)
  - Tagliaferro, G. (2021). *On the development of a general undifferenced uncombined adjustment for GNSS observations* [PhD thesis, Politecnico di Milano]. — "A lower bound for the success rate can be compute as [107]: P(ˆzr = ˆz) = ∏i ( 1 − 2 · ∫−1/2−∞ Ψ(x, 0, γ2i)dx )" (p. 35, eq. 3.33)
  - Tagliaferro (2021) — "Such a procedure is called search and shrink strategy" (p. 37)
- **Critical analysis**.
  1. **Formula**: `2Φ(1/(2σ))−1` with `Φ = 0.5·erfc(−x/√2)` is the exact standard normal CDF; identical to Teunissen eq. (19).
  2. **Convention — the doc's attribution is NOW-WRONG and the code is *better* placed than the doc said.** The doc states "the convention differs from Teunissen's `Qâ = LᵀDL` (conditioning from the last ambiguity)". Re-reading Teunissen (2001) p. 249 verbatim, he writes **`Q â = LDLT` with L unit lower triangular** and defines `σ²_{âi|I}` as "the variance of the ith least-squares ambiguity obtained through a conditioning on the previous I = {1,…,(i−1)} ambiguities" — *exactly* the code's convention. The `LᵀDL` form belongs to **Joosten & Tiberius (2000) p. 51**, not to Teunissen (2001). The code therefore matches its primary source *bit-for-bit*; only the secondary source uses the transposed notation.
  3. **Swap criterion re-derived**: conditioning on 1..k−1 leaves the 2×2 block `[[d_k, d_k·l],[d_k·l, d_k·l²+d_{k+1}]]`. Reversing the order makes the leading conditional variance `d_k·l² + d_{k+1}`, precisely `dbar` at :153. Swapping iff `dbar < d_k` is the LAMBDA reduction condition in this convention. ✓
  4. **Search ellipsoid** — the safety argument holds: a missed runner-up has `c₂ ≥ (γ+1)·bootCost` and `c₁ ≤ bootCost`, so `c₂/c₁ ≥ γ+1 > γ`; a miss can only make the test *harder*. Note this is a documented **superset** of Teunissen's canonical `χ² = cost(bootstrap)` (p. 253) — correct, and necessary because the code also needs the runner-up.
  5. **NEW: `conditionBefore` and `conditionAfter` are mathematically identical.** `info.conditionBefore = adop_(Qa) = det(Qa)^{1/2n}`; `info.conditionAfter = exp(mean(log d))^{0.5} = (∏d)^{1/2n} = det(ZᵀQZ)^{1/2n} = det(Q)^{1/2n}` because `|det Z| = 1`. ADOP is *invariant* under an admissible transformation (that is a correct and well-known property), so the pair reported as "condition before / after decorrelation" is a no-op diagnostic. It is right as ADOP and vacuous as a before/after. A reader shown two equal numbers and told they bracket the decorrelation will misread them.
  6. **Degenerate accept**: if `sqn(1) == 0` (float exactly integer) the guard at :101 makes `info.ratio = Inf` and the fix is accepted without a discrimination test. Measure-zero in practice; still an unguarded branch.
  7. On node-budget exhaustion the bootstrapped fix is accepted with *no* ratio test (:92–97). The class says so in `info.message` and `info.searchExhausted`, and the failure probability is still bounded by `1 − P_s`, but the discrimination guarantee is silently weaker on that path.
  8. Tagliaferro (2021) p. 35 states the ordering backwards — "the success rate of the bootstrap estimator is never greater to the one of the rounding operator" — the opposite of Teunissen's established `P_rounding ≤ P_bootstrap ≤ P_ILS` (eq. 28, p. 253). Re-confirmed verbatim this round. The repo does **not** inherit the error.

### Acceptance testing — success-rate gate and fixed ratio thresholds

- **Code**: `LambdaResolver.m:127` and `DecorrelatedBootstrap.m:75–79` — SR floor; `LambdaResolver.m:176` and `DecorrelatedBootstrap.m:108–113` — ratio test. Config: `config/masterConfig.m:421–422` (`estimator.lambda.minSuccessRate = 0.999`, `ratioThreshold = 2.0`); **:439** and **:1983** (`estimator.diffAtt.ambiguityResolution.ratioThreshold = 3.0`); **:1804/:1806** (`multiAsset.groundCarrier.minSuccessRate = 0.999 / ratioThreshold = 2.0`); **:384/:2025** (`attitudeInit.search.ratioThreshold = 1.20`).
- **Status vs doc**: DRIFTED — every masterConfig citation in the doc has moved (doc said 313–314 → now 421–422; 331/1691 → 439/1983; 1520–1522 → 1804/1806).
- **Verdict**: partially correct — the two-gate design is stronger than common practice; the fixed critical values are the ones the acceptance-testing literature explicitly deprecates, and no source is cited in the code.
- **Sources**:
  - Tagliaferro (2021) — "The test checks whether the ratio between the objective function Ω() (the least squares principle) computed using the ILS (ˇz1) and computed using the second best integer vector (ˇz2) is greater than a certain threshold" (p. 20, eq. 2.56)
  - Verhagen, S., & Teunissen, P. J. G. (2013). The ratio test for future GNSS ambiguity resolution. *GPS Solutions, 17*(4), 535–548. [EXTERNAL, abstract] — "it is demonstrated that the current usage of the ratio test with fixed critical value is not sustainable in light of the enhanced variability that future global navigation satellite system (GNSS) ambiguity resolution will bring. As its replacement, the model-driven ratio test with fixed failure rate is proposed."
  - Joosten & Tiberius (2000) — "even with a high enough success rate, fixing to the wrong integer ambiguities is still possible when one or more observations are grossly erroneous" (p. 50)
- **Critical analysis**. Convention (`sqnorm(2)/sqnorm(1) ≥ c`, larger = safer) matches Tagliaferro eq. 2.56. The mitigating structure stands: the *primary* gate is the covariance-driven bootstrapped SR, which is model-driven and is precisely the "compute before measurement" diagnostic Joosten & Tiberius advocate, and the gates are conjunctive. The residual weakness is unchanged and now sharpened by L-1: the reported `failureRate` is the IB failure rate, **not** the failure rate of the composite accept rule, and on the `method ∈ {1,2}` path the composite rule reduces to the SR gate alone. Four different ratio thresholds live in `masterConfig` (2.0, 3.0, 3.0, 1.20) with no derivation for any of them; `attitudeInit.search.ratioThreshold = 1.20` is far below anything in the literature.

### Wide-lane / narrow-lane / Melbourne-Wübbena

- **Code**: `WideLaneNarrowLaneDiagnostics.m:46–53` — **band-following now**: `[~,~,f1_,f2_] = revgnss.SignalUtils.ionosphereFreeCoefficients(cfg); s.lambdaWideLane_m = c_/(f1_-f2_); s.lambdaNarrowLane_m = c_/(f1_+f2_);` (doc cited :49–50 for the wavelengths — DRIFTED); **:171** `D = [1/lam1, -1/lam2; 1/lam1, 1/lam2]`, **:195** `P_N = D*P_pair*D'` (doc said 168 / 192 — DRIFTED).
  `GroundCarrierObservationSet.m:137–140` — observation model with the sign flip:
  `phase(1)=rho+trop-Ik+lam1*n1+eps; phase(2)=rho+trop-Ik*r2+lam2*n2+eps; code(1)=rho+trop+Ik+eps; code(2)=rho+trop+Ik*r2+eps` with `r2=(f1/f2)^2`; **:159–163** `deriveLaneIntegers: wl = N1-N2; nl = N1+N2`.
  `GroundCarrierAmbiguityResolver.m:255–256` MW; **:270** `varMwLink = (f1^2*sp^2 + f2^2*sp^2)/(f1-f2)^2 + (f1^2*s1^2 + f2^2*s2^2)/(f1+f2)^2`; **:271** `mwSigma = sqrt(4*varMwLink)`.
  `GroundCarrierAmbiguityProbe.m:96–97` — **band-following now**: `ampWL = sqrt(F1^2+F2^2)/(F1-F2); ampNL = sqrt(F1^2+F2^2)/(F1+F2)` with `F1/F2` from `SignalUtils.frequency(cfg,·)` (:88–89) (doc cited :88–90 — DRIFTED).
- **Status vs doc**: DRIFTED (numbers) + **SUPERSEDED in part** — the doc's "band-blind" flag no longer applies to the diagnostics or the probe; it *does* still apply to the resolver's observation set (see next entry).
- **Verdict**: correct — I re-derived the MW cancellation symbolically against the code's own sign convention.
- **Sources**:
  - Hofmann-Wellenhof et al. (2008) — "the combination Φ1 + Φ2 is denoted as narrow lane and Φ1 −Φ2 as wide lane. The lane signals are used for ambiguity resolution" (p. 112)
  - Hofmann-Wellenhof et al. (2008) — "the noise level for the linear combination diﬀers by the factor √(n2 1 + n2 2) which follows from the application of the error propagation law" (p. 112)
  - Hofmann-Wellenhof et al. (2008) — "a wide lane with a wavelength of 86 cm (cf. Table 7.4)" (**p. 217**, *not* p. 218 as the doc states — the printed page header on that page is 217)
  - Hofmann-Wellenhof et al. (2008) — "The only disadvantage of using the wide lane is that the measurement is signiﬁcantly noisier than the single phase." (p. 217)
  - Enge, P. K. (1994). The Global Positioning System: Signals, measurements, and performance. *International Journal of Wireless Information Networks, 1*(2), 83–105. — "This signal has a wavelength of approximately 84 cm and can be used to help resolve L~ cycle ambiguities … This technique is known as 'wide-laning'" (p. 90) [PDF has an OCR text layer; "L~" is "L₁", "car- tier-phase" is "carrier-phase"]
- **Critical analysis**. Symbolic re-derivation with `I` the L1-equivalent slant delay and `r2 = (f1/f2)²`:
  `MW_phase = (f1·L1 − f2·L2)/(f1−f2)`: the `(ρ+T)` term returns `ρ+T`; the ionosphere returns `+I·f1/f2`; the ambiguity returns `(c·N1 − c·N2)/(f1−f2) = λ_WL·N_WL` because `f_j λ_j = c`.
  `MW_code = (f1·P1 + f2·P2)/(f1+f2)`: `(ρ+T)` returns `ρ+T`; the ionosphere returns `+I·f1/f2` — **the same value**.
  Difference: `MW = λ_WL·N_WL + ε`. Geometry, **troposphere** and ionosphere all cancel *identically*, not approximately. ✓
  Digit check at the hardcoded GPS pair: `λ_WL = 299792458/347.82e6 = 0.861915 m`; `λ_NL = 299792458/2803.02e6 = 0.106952 m`; `√(f1²+f2²)/(f1−f2) = 1.99725e9/3.4782e8 = 5.7422`; `amp_NL = 0.71254`. All match the code's arithmetic.
  Noise-convention clarification for the write-up: Hofmann-Wellenhof's `√(n₁²+n₂²) = √2` is in **cycles** with equal per-band cycle noise; the code's 5.7422 is the **metre**-domain amplification with equal per-band metre noise (`GroundCarrierObservationSet.m:137–138` draws `sigPhase` in metres per band). Internally consistent; the two numbers are not comparable.
  Structural strength retained: the truth carries exactly two integers `(N1, N2)` per link/arc (`GroundCarrierObservationSet.m:107–109`) and every lane is derived, so the `N_WL = N1 − N2` constraint that makes a cascade meaningful actually holds.

### NEW — the ground-carrier observation set is still hard-wired to GPS L1/L2 (incomplete band-following fix)

- **Code**: `+revgnss/GroundCarrierObservationSet.m:46–49`
  ```
  properties (Constant)
      F1_HZ = 1575.42e6;
      F2_HZ = 1227.60e6;
  ```
  used at **:63–68** to set `lam1, lam2, lambdaWL_m, lambdaNL_m`, which are then the *only* wavelengths `GroundCarrierAmbiguityResolver` ever sees (`car.f1_Hz`, `car.f2_Hz`, `car.lambdaWL_m`, `car.lambda1_m` at :252–253, :325–334, :374, :386, :396–397).
  Meanwhile the *sigmas* in the same function do follow config: `sigCode1 = cfg.signals.L1.codeSigma0_m` (:71), `sigCode2 = cfg.signals.L2.codeSigma0_m` (:72).
- **Status vs doc**: **NEW** (the doc's global "carrier was band-blind" finding was recorded as fixed; this survivor was not identified).
- **Verdict**: flawed — the whole MW → WL-fix → conditioned-geometry → L1 cascade computes GPS lane wavelengths on every scenario, including the licence-exempt `config/ladder/freq/freq009…013` rungs (915 MHz to 61.25 GHz).
- **Sources**: repo-internal contradiction — `tests/test_carrier_phase_wavelength_follows_band.m:1–29` states the requirement ("must follow the band the scenario actually selected, not masterConfig's canonical GPS L1 seed") and covers `measurements.carrierPhase`, `SignalCatalog` and the iono scale, but never touches `GroundCarrierObservationSet`. `GroundCarrierAmbiguityProbe.m:84–87` and `WideLaneNarrowLaneDiagnostics.m:43–45` both carry comments explaining why the constants *were* removed from those two files.
- **Critical analysis**. Two failure modes, both silent. (a) **Mixed-band arithmetic**: at `freq013` the code sigma comes from the 24.125/61.25 GHz pair while `f1/f2` stay at 1575.42/1227.60 MHz, so `varMwLink` mixes a retuned noise budget with a GPS frequency ratio and `λ_WL` is 0.8619 m against the true 8.1 mm — a factor of 106. (b) **Wrong half-wavelength margin**: every "does the DD land within λ/2" statement the resolver prints is computed at the GPS lane. Nothing errors, nothing warns. The fix is one line (read `SignalUtils.frequency(cfg,'L1'/'L2')` exactly as the probe does at :88–89), but the gate must be counted as *incomplete* until it lands: the band-following fix covers `measurements.carrierPhase`, `SignalCatalog`, `IntegerAmbiguityFixer` (:122–123), `BaselineAmbiguityLambda` (`lambda_`, reads `cfg.signals.wavelength_m(1)`), `IslDoubleDifference` (`lambda_`, :167–177), the WL/NL diagnostics and the probe — and **not** the resolver's own observables.

### NEW — the carrier-sigma / slip-threshold "follows the band" fix is opt-in, and effectively nothing opts in

- **Code**: `config/masterConfig.m:3185–3187` — `cfg.measurements.carrier.sigma_m = 0.005; cfg.measurements.carrier.sigma_cycles = NaN; cfg.measurements.carrier.sigmaFloor_m = NaN;` and **:3192–3196** — `slipDetection.threshold_m = 0.1; minEpochsBeforeDetect = 3; resetSigma_m = 100; action = 'resetAndSkip'`.
  The derivation `sigma_m = sqrt((sigma_cycles*lambda)^2 + sigmaFloor_m^2)` fires in `ConfigFactory.finalizeConfig` only when `sigma_cycles` is set.
  A repo-wide grep for `sigma_cycles` / `threshold_cycles` in `config/` returns only `errors.interAntennaCarrierBias.sigma_cycles` (0.25 in `golden_baseline*.json`, 0.02 in `golden_baseline_attitude.json`) — a *different* leaf. **No scenario sets `measurements.carrier.sigma_cycles` or `carrierSlip.threshold_cycles`.**
- **Status vs doc**: NEW.
- **Verdict**: partially correct — the machinery is correct and well tested; the default path it protects is unchanged, by explicit design ("DEFAULT UNCHANGED … the frozen goldens cannot move", `masterConfig.m:3159–3160`; `tests/test_carrier_sigma_and_slip_threshold_follow_band.m:41–64`).
- **Sources**: `tests/test_carrier_sigma_and_slip_threshold_follow_band.m:4–8` states the measured consequence — "carrier sigma 5 mm → 0.026 cycles at GPS L1, 1.02 cycles at 61.25 GHz; slip threshold 0.10 m → 0.53 cycles at GPS L1, 20.4 cycles at 61.25 GHz".
- **Critical analysis**. The test suite proves the *derivation* is right and that golden safety holds. It does **not** prove any run uses it. Today, on every scenario in the repo, the ground carrier R is 5 mm and the slip threshold 0.1 m *in metres*, so at `freq013` R asserts 1.02 wavelengths of noise (ambiguity and noise become indistinguishable) and the slip detector is blind below 20.4 cycles. That is the state of the world for any band sweep quoted from this tree. The honest statement for the paper is: "the band-invariant carrier budget is implemented and unit-tested but is not enabled on any scenario; all reported band sweeps use a metre-fixed carrier sigma and slip threshold."

### Cycle-slip detection and arc management

- **Code**: `+revgnss/CycleSlipDetector.m:9–38` `detectCompensated` (`slipMetric = observedJump − expectedModelJump; isSlip = |slipMetric| >= threshold` after `epochCount >= minEpochsBeforeDetect`); **:40–64** `detect` (suppressed for `epochCount <= 1`); **:66–79** `detectWithMinEpochs`.
  `CarrierTrackManager.m:119–228` — per-track history keyed `T%03d_A%03d_S%02d`, three detection branches (override / compensated / legacy), arc-ID increment and `currentArcEpoch_` reset on slip, `resetAndSkip` drops the row (`keepMask(mi) = false`).
  `IslCarrierTrackManager.m:80–83` — tracks only rows with `carrierUsedInEkf` true (the 878-false-slip fix); **:196–198** `sigCar = cfg.measurements.isl.carrier.sigma_m; autoThresh = 5*sqrt(2)*sigCar;`; **:209–218** NaN → AUTO, and a `thresholdTooTight` warning below `0.8×` auto.
  Truth-side slips: `GroundCarrierObservationSet.m:94` `pSlip = 1 - exp(-max(0,slipRate)*dt/3600)`.
- **Status vs doc**: STILL-VALID for `CycleSlipDetector` (:9–38, :40–64 exact). DRIFTED for `IslCarrierTrackManager` (doc said :182–219 for `slipCfg_` ✓, :77–84 for the EKF-used gate → now :80–83). `masterConfig` citations DRIFTED (doc :2200/:2203/:2214–2217 → now :3192/:2635/:2645–2650).
- **Verdict**: partially correct — the arc/reset physics is right, the threshold propagation is right, and the limits are stated honestly; the detector remains a bare time-differenced-residual test with no geometry-free or MW detector, and the ground default is not slip-scaled.
- **Sources**:
  - Hofmann-Wellenhof et al. (2008), ch. 7, treats cycle slips as arc-breaking discontinuities requiring repair or ambiguity re-initialisation.
  - Tagliaferro (2021) defines a continuous ambiguity "For each continuous set of phase data (no Cycle Slip no loss of tracking)" (ch. 5).
- **Critical analysis**. `pSlip = 1 − exp(−λ·dt/3600)` is the exact Poisson first-arrival probability for rate `λ` per hour over `dt` seconds. ✓ `√2·σ` for a prefit *difference* is exact error propagation for two independent draws. ✓ The stated consequence is real and remains stated: at `σ = 0.20 m` the ISL auto threshold is ≈ 1.41 m ≈ 7 L1 cycles, so single-cycle slips are undetectable (`masterConfig.m:2645–2650`). **NEW asymmetry**: `detect` guards `epochCount <= 1` but `detectCompensated` does **not** — at `minEpochsBeforeDetect <= 1` it would difference against an uninitialised `prevPrefit = 0`. All live callers pass `minEpochsBeforeDetect ≥ 3`, so this is latent, but the two functions do not share a contract. **NEW default-value gap**: the *ground* slip threshold (`0.1 m`) and warm-up (`3` epochs) were never migrated to the ISL idiom (NaN→auto, 30 epochs), even though `masterConfig.m:2651–2655` records the measurement that 3 epochs produced a self-sustaining false-slip loop. What is still missing relative to practice: dual-frequency geometry-free (L1−L2) and MW-jump detection. Since `GroundCarrierObservationSet` now synthesises both bands, an MW-jump detector is nearly free and would lower the detectable-slip floor by two orders of magnitude.

### Float ambiguity as EKF state, and the birth-at-geometry-error trap

- **Code**: `+models/+measurements/CarrierMeasurementBuilder.m:553` — `H_phi(rowOut, ambStateIdx) = 1;` (ambiguity in metres, unit Jacobian) — **doc said :334, now :553 (file grew 350 → 786 lines)**.
  **:586–588** — the R policy: `% Policy: timeVaryingProductResidualOnly — constant bias absorbed by float ambiguity; only age-weighted residual (from arc start) enters R.` (doc cited :280–283 — SUPERSEDED by a rewritten and much longer block).
  **:439–441** — inter-antenna bias: "Added to z only (NOT to h_phi) … a constant part is absorbed by the float ambiguity B, a drift leaves a real residual and can pull an integer fix."
  Config: `masterConfig.m:2619–2622` — the metres convention and the "undifferenced B is NOT an integer" corollary (doc said :2190–2192); **:2635** `isl.carrier.ambiguity.processNoiseSigma_m_per_sqrt_s = 0`; **:3219** `estimation.ambiguity.processNoiseSigma_m_per_sqrt_s = 1e-5`; **:297/:3218/:2634** `initialSigma_m = 100`.
  Guard: `ISLMeasurementBuilder.m:133–140` — hard error if `warmup_s <= 0` with carrier in the EKF; **:96–101** measured 300 s default.
  Q application: `+filter/ReverseGNSSEKF.m:1542–1555` (ISL) and **:1560+** (ground).
- **Status vs doc**: DRIFTED (all line numbers) and **one substantive claim NOW-WRONG**.
- **Verdict**: partially correct.
- **Sources**:
  - Joosten & Tiberius (2000) — "The parameter-estimation problem is solved without taking into account the special integer characteristic of the ambiguities. The result so obtained is often referred to as the float solution" (p. 46)
  - Teunissen (2001) — the float model `y = Aa + Bb + e` with `a ∈ Zⁿ` relaxed (pp. 246–247)
- **Critical analysis**. The conventions the doc credits are still right: `B` in metres with `∂h/∂B = +1`, one ambiguity per arc, reset per arc, and the warm-up converted from a comment into a hard configuration error. **NOW-WRONG in the doc**: "masterConfig:2203 — `processNoiseSigma_m_per_sqrt_s = 0` (constant within arc)" is the **ISL** knob (`:2635`). The **ground** float ambiguity carries `1e-5 m/√s` (`:3219`), i.e. a random walk of `1e-5·√3600 = 0.6 mm` over a one-hour arc. Negligible numerically, but the doc's blanket "zero process noise within an arc, standard filter practice" is not what the ground path does. **Far more consequential, NEW**: `config/ladder/ISL/isl016_carrierFloatAmbiguity.json` sets `measurements.isl.carrier.ambiguity.processNoiseSigma_m_per_sqrt_s = 0.01`, and `isl017` inherits it. With `dt = 1 s`, `q = (0.01)² = 1e-4 m²` per epoch against `R = (0.002)² = 4e-6 m²`. Solving the scalar steady state `x² − qx − qR = 0` gives `x = 1.039e-4`, `P⁺ = 3.9e-6 m²` (σ_B ≈ 1.97 mm) and **Kalman gain on the ambiguity `K = x/(x+R) = 0.963`**. The ambiguity absorbs 96.3 % of every carrier innovation; only 3.7 % is available to position, clock and everything else. The rung's own `_whyProcessNoiseOnTheAmbiguity` note justifies this as un-freezing a state that otherwise sat "10.42 cycles from truth while REPORTING 0.2434 cycles", which is a real and correctly diagnosed problem — but the cure converts the carrier row into a near-pure **delta-range** observable and destroys the integer interpretation outright (`0.01·√3600 = 0.6 m ≈ 52 cycles` of admissible wander at 26 GHz over the arc). Any claim that isl016/isl017 demonstrate "carrier phase" must be qualified: they demonstrate a *time-differenced* carrier.

### GroundCarrierAmbiguityResolver — the MW → WL-fix → conditioned-geometry → L1 cascade

- **Code**: `+revgnss/GroundCarrierAmbiguityResolver.m:80–99` (MW float + fix); **:101–111** (fixed WL published as a per-link pseudo-range, gauge = integer 0 on the reference satellite and reference tower, `laneRange_` at :316–345); **:113–129** (geometry re-conditioned through `JointGeometrySolver` with `cfgJ.multiAsset.jointGeometry.enable = true`); **:131–149** (L1 float against the conditioned geometry, `out.n2Fix = l1Fix - wlFix`); **:391–402** (L1 covariance: `varPhaseCyc = 4*(phaseSigma/lambda1)^2`, `ddCovariance_(idx, varPhaseCyc/4, ...)`, then `Q = Q + varCyc*ones(n)`); **:405–425** `geometryDdSigma_`; **:427–460** `fixIntegers_` (config gates checked *before* toolbox availability, engine recorded); **:473–496** truth used for scoring only (doc said :453–476 — DRIFTED).
- **Status vs doc**: DRIFTED; substance largely STILL-VALID with two new defects.
- **Verdict**: partially correct.
- **Sources**:
  - Hofmann-Wellenhof et al. (2008) — "Many OTF implementations use the wide lane to resolve integer ambiguities and then use the resulting position to directly compute the ambiguities on the original carrier phase data" (pp. 217–218; the sentence begins on p. 217 and completes on p. 218)
  - Joosten & Tiberius (2000) — the success rate "can be computed without having the actual measurements available, that is, before actual field operations" (p. 50)
- **Critical analysis**. What is right, verified again: MW is geometry-free (proved above), so the WL float sigma decouples from the very geometry error the programme is trying to improve; the DD covariance is correlated; the failure direction of each approximation is stated; realised correctness is quarantined behind "REGISTER (not a decision input)" (:192) and `trueLaneIntegers_` is only reachable after every decision (:91–93, :138–140). The gauge argument is **exactly correct** — I verified it algebraically: `idx.rows` never covers `(1,m)` or `(i,refTw)`, so `DD(rho) = DD(lane) − λ·N̂ = DD(range) + λ(N_true − N̂)`, which equals `DD(range)` iff the fix is right, for any per-link gauge.
  **NEW defect D-1 (unit inconsistency in `geometryDdSigma_`).** Two branches disagree by `√3`:
  - :416–418 `f = rel.shapeSigmaPosterior_m/sqrt(3)` then :423 `s = 0.23*sqrt(3)*f*2` ⇒ `s = 0.46·shapeSigmaPosterior_m` (the `√3` cancels — the "per-point norm → per axis → norm" round trip is a no-op).
  - :419–420 `f = rel.formalShapeSigma_m` (no `/√3`) then :423 ⇒ `s = 0.7967·formalShapeSigma_m`.
  Whichever field happens to be present changes the L1 float covariance by 1.73×, and this sigma *dominates* `Q` at :400. Nothing records which branch fired.
  **NEW defect D-2 (the fixed-carrier observable is charged code multipath and code atmosphere).** `JointGeometrySolver.solve` at **:166–167** replaces only two things — `obs.rhoObs = observableOverride.rhoObs; obs.codeSigma_m = observableOverride.rawSigma_m;` — while `varRaw` at **:211–213** is `obs.codeSigma_m^2 + obs.multipathSigma_m^2*(tauMp/dt) + obs.differentialAtmosphereSigma_m^2`. `multipathSigma_m` and `differentialAtmosphereSigma_m` are left at their **code** values. With the masterConfig defaults (`:1628` `multipathSigma_m = 0.0`, `:1638` `differentialAtmosphereSigma_m = 0.0`) this is numerically inert, so it is **latent**, not live. But those two knobs exist precisely so the cost can be injected and measured (`GroundDifferencedRotationSolver.m:57`), and the moment either is turned on the wide-lane observable (rawSigma ≈ 11.5 mm) is charged `σ_mp²·(τ/dt)` — at `σ_mp = 0.2 m`, `τ = 60 s`, `dt = 1 s` that is `2.4 m²`, an over-charge of ~18,000× in variance. The step-3b acceptance test would then refuse to let the wide lane sharpen the geometry, and the cascade would silently fail to demonstrate its own benefit — the exact failure mode `geometryDdSigma_`'s own comment (:411–414) warns about.
  **Not a double count (checked and cleared)**: `varPhaseCyc = 4*(σ_φ/λ1)²` at :397 is divided by 4 before being handed to `ddCovariance_` at :399, which then re-multiplies by the 4 non-zero entries of each incidence row. Net: exactly `4·(σ_φ/λ1)²` on a single-epoch diagonal. Correct, no double count.
  **Self-reference, conservatively signed**: the geometry `rel` used at :380–385 was conditioned on the wide-lane range built from the *same* `car.phase_m`, and `Q` adds phase noise and the geometry term as if independent. Because a residual about a fit has variance `(1−h)σ² < σ²`, this over-states rather than under-states — safe direction, but it means the printed L1 `P(false fix)` is not a clean out-of-sample number.

### IntegerAmbiguityFixer (legacy) and BaselineCarrierAmbiguityResolver / BaselineAmbiguityLambda

- **Code**: `IntegerAmbiguityFixer.m:104–107` — `maxSigma_cycles = 0.15`, `maxDistanceToInteger_cycles = 0.20`, `minArcLength_s = 300`, `fixVariance_cycles2 = 1e-4`; **:120–123** — now band-following (`sigId = SignalCatalog.signalId(si); lambda = SignalUtils.wavelength(cfg, sigId);`); **:179–206** residual-RMS non-worsening check (doc said :177–204 — DRIFTED); header **:6** "NOT LAMBDA/MLAMBDA. NOT carrier-IF fixing. NOT WL/NL. NOT false-fix-risk."
  `BaselineCarrierAmbiguityResolver.m:160–183` scalar ±`searchHalfWidth` search with rms/ratio/float-distance gates; **:213–218** dual-frequency joint cost `J = n₁·rms₁² + n₂·rms₂²` and `J_2nd = min(J1_2nd+J2_best, J1_best+J2_2nd)`; **:221–234** WL-consistency screen `|N_WL,float − (N1−N2)| < maxWideLaneFloatDistance_cycles`.
  `BaselineAmbiguityLambda.m:69–71` `Qa_cyc = diag(var_cyc); s.covarianceStructure = 'diagonal-separablePerBaseline';`; **:15–19** the degeneracy claim; **:169–176** compare only where the production resolver actually fixed.
- **Status vs doc**: DRIFTED; substance STILL-VALID.
- **Verdict**: correct as heuristics, unsourced as thresholds.
- **Sources**:
  - Teunissen (2001) — "Bootstrapping of DD ambiguities, for instance, will produce an integer solution which generally differs from the integer solution obtained from bootstrapping of reparametrized ambiguities." (p. 252) — the order-dependence that vanishes for a diagonal `Qa`.
  - Joosten & Tiberius (2000) — "because different methods of integer estimation will generally result in different success rates, we might wish to use the method that maximizes the success rate" (p. 49)
- **Critical analysis**. Unchanged and still worth stating: the legacy fixer's `maxSigma_cycles = 0.15` corresponds to a per-component rounding success of `2Φ(1/(2·0.15))−1 = 2Φ(3.333)−1 = 0.99914`, numerically aligned with the 0.999 floor of the modern gates but **per component only** — with `m` components the joint rate is ≈ `0.99914^m` and no joint gate exists (`falseFixRisk:false` is printed at `:82`, so the code never claims otherwise). `BaselineAmbiguityLambda`'s "for a diagonal `Qa`, ILS provably degenerates to bootstrapping and to plain rounding" is correct (pull-in regions under a diagonal covariance are unit hypercubes, and Teunissen (2001) p. 249 shows the bootstrapped pull-in parallelogram reduces to the unit square "in the absence of correlation between the two ambiguities"). Its role as a *formal-SR annotator* over a heuristic fixer is the right division of labour, and the compare-only-where-fixed guard closes a real false-alarm hole. The `J_2nd = min(...)` construction is a coordinate-wise runner-up, not the true second-best over the joint lattice — correct as an upper bound on the joint cost only if the two lanes are independent, which they are by construction here (separable accumulators). Fine, but it should not be called a joint ILS ratio.

### AmbiguityFixingReadinessGate, AmbiguityArcState, WideLaneNarrowLaneDiagnostics — the stale "not implemented" strings

- **Code**: `AmbiguityFixingReadinessGate.m:210–212`
  ```
  bl{end+1} = 'No integer strategy implemented (LAMBDA/MLAMBDA not available in v1).';
  bl{end+1} = 'Integer fixing not implemented in v1.';
  bl{end+1} = 'False-fix-risk control not implemented (ratio test absent).';
  ```
  and **:227** `'  IntegerFixing      : false | LAMBDA/MLAMBDA: false | FalseFixRisk: false'`; header **:5–6** "Hard facts always false". Same strings at `AmbiguityArcState.m:127–129` and **:155–159**; `WideLaneNarrowLaneDiagnostics.m:233–236` and **:285–290**; `IntegerAmbiguityFixer.m:82`.
  Doc cited :209–212/:255, :127–129/:150–158, :230–233/:277–287 — all DRIFTED by 2–8 lines.
- **Status vs doc**: DRIFTED, and the verdict **STILL-VALID** — the strings are still there, still false as global statements, and now *more* contradicted: since the doc was written, `run_multi_islcarrier_regression.m` freezes goldens for a configuration that carries five float ambiguities per leaf, and `ReverseGNSSSimulation.m:1105–1157` runs a live LAMBDA integer fix on ISL differences.
- **Verdict**: flawed (traceability, not physics).
- **Sources**: repo-internal contradiction — `docs/LAMBDA_SETUP.md`; `+revgnss/+integer/LambdaResolver.m` (Ps_LAMBDA gate + ratio test); `+revgnss/+integer/DecorrelatedBootstrap.m`; `+revgnss/GroundCarrierAmbiguityResolver.m`.
- **Critical analysis**. The strings remain *locally* true for the v1 ground-to-space EKF the gate audits (no integer fix is applied inside that EKF and phase-bias products genuinely do not exist), but a reader of the printed report can now see "False-fix-risk control not implemented (ratio test absent)" in the same run that prints a ratio value and a `P(false fix)`. In a viva or review that reads as a contradiction, not as scoping. They should be scoped ("not applied in the ground-to-space EKF path; see `GroundCarrierAmbiguityResolver` and `IslDoubleDifference` for the integer routes") or driven from the config gates. The readiness *score* (6 evidence items) has no literature analogue and none is claimed; acceptable as engineering telemetry provided it is never presented as a standard metric. The gate itself has **no SR threshold** — the SR floors live in the resolvers.

### NEW — isl016 / isl017: what the "honest product" rung actually changes, and what it costs

- **Code**:
  - Gate: `ISLMeasurementBuilder.m:625–633` `productCfg_` — reads `product.enable`, then `if ~p.enable; p.sigmaPos_m = 0; p.sigmaClock_m = 0; p.sigmaVel_mps = 0; p.sigmaClockDrift_mps = 0; end`.
  - Bias: **:649–662** `productBias_` — `if ~p.enable; return; end` (zeros), else `pb.pos = p.sigmaPos_m*randn(s,3,1); pb.clk = p.sigmaClock_m*randn(s,1);` on a stream keyed `(seed, txi, 555, intervalIdx)`.
  - Injection: **:189–191** `rTxProd = rTxTruth + pb.pos; btxProd = btxTruth + pb.clk;`; **:212** `rTxModel = rTxProd` when the neighbour orbit is *not* a state.
  - Carrier row: **:289** `zc = rhoTruth + brxTruth - btxTruth + Btruth + nzc;` (truth side, **no** product error); **:318–319** `hc = rhoModel + (x(b_rx)+relClkBias_m) - btxProd; Rc = carrierSigma_m^2 + sigPos2c + product.sigmaClock_m^2;`.
  - `isl017` sets `product.enable=true, sigmaPos_m=0.03, sigmaClock_m=0.02, updateInterval_s=300`; `isl016` leaves `enable=false`.
- **Status vs doc**: NEW.
- **Verdict**: correct in mechanism (isl017 genuinely closes the truth leak; the gate *does* gate, in both directions), but the rung's covariance is not defensible and its documented headline numbers are stale.
- **Sources**: repo-internal; `isl017_carrierHonestProduct.json` `_id`; `tests/regression/run_multi_islcarrier_regression.m:2–7`; the two frozen goldens (read this round).
- **Critical analysis**.
  1. **The leak is real and is closed.** With `enable=false`, `productBias_` returns zeros, `btxProd ≡ btxTruth`, `rTxProd ≡ rTxTruth`, and `h` is handed each neighbour's **true** position and clock. With `enable=true` the residual carries `−pb.clk` and `−u'·pb.pos`, and R charges `sigmaClock_m² + sigmaPos_m²`. The projection arithmetic is right: `pb.pos` is isotropic with per-axis σ, so `u'·pb.pos ~ N(0, sigmaPos_m²)` — charging `sigmaPos_m²` (not `3·sigmaPos_m²`) is exactly correct.
  2. **The R gate is honest.** Because `productCfg_` zeroes the sigmas when disabled, isl016 does **not** charge R for an error it never injected. I checked this specifically: `Rc` reduces to `carrierSigma_m² = 4e-6 m²`. Good.
  3. **The measured cost, from the frozen goldens** (not from the JSON prose): 0.003562 m → **0.094562 m** RMS absolute position, a factor of **26.5**. The JSONs quote 0.003585 / 0.095183 m and the regression header quotes 0.003585 / 0.130883 m "at 600 s". Three different pairs of numbers for two rungs; the working-tree goldens (uncommitted, post-`170e37d` Libreville longitude change) agree with none of them. **The `_id` prose in both JSONs and the header of `run_multi_islcarrier_regression.m` are stale and must not be quoted.**
  4. **isl017's covariance is 9.3× optimistic.** Mean per-axis σ is 0.005878 m ⇒ a 3-D 1σ of `√3·0.005878 = 0.010181 m` against an RMS error norm of 0.094562 m. Worst asset: 0.176744 m, i.e. 17σ. isl016 by contrast is consistent (0.003562 vs 0.005372, ratio 0.66). So the pair is: **oracle = accurate but leaking truth; honest = truth-clean but badly overconfident.** Neither rung may be quoted as "0.0036 m with a defensible sigma". This corroborates the project's standing "σ is 13.7× optimistic" note by an independent route.
  5. **Mechanism of the overconfidence** — see double-count DC-1 and DC-2 below.

### NEW — the ISL Route-B integer path: a gate that cannot fail, on a parametrisation that is not integer at Ka band

- **Code**: `+revgnss/+integer/IslDoubleDifference.m:99–102`
  ```
  % The differenced vector IS an integer parametrisation (up to the tx-clock
  % residual documented above), so the precondition is satisfied by construction.
  revgnss.integer.LambdaResolver.assertIntegerParametrisation(true, ...
      'between-satellite differenced ISL ambiguity');
  ```
  and **:136–152** `reportBiasBudget` → `b.sigmaDiff_cycles = sqrt(2)*b.sigmaTxClock_m/lam;` — never called from `assess`.
  Live path: `ReverseGNSSSimulation.m:1135` `s = IslDoubleDifference.assess(...)`, **:1142–1148** `applyIslDifferencedAmbiguityFix(D, s.fixedDiff_cycles, s.wavelength_m, sig)` with `sig = cfg.estimator.lambda.isl.fixSigma_m` (default `1e-3 m`, `masterConfig.m:432`).
- **Status vs doc**: NEW (the doc noted the bias term but not that nothing gates on it).
- **Verdict**: flawed.
- **Sources**: `LambdaResolver.m:188–202` — the assert's own contract: "LAMBDA is only VALID on a parametrisation whose truth is integer."
- **Critical analysis**. `assertIntegerParametrisation` is passed a **hardcoded `true`**, so it can never fire. It is a documentation device wearing an assertion's clothes. The quantity that would decide the question is computed one function away and thrown at the reader instead of at the gate:
  `σ_diff [cycles] = √2·σ_txClock / λ`.
  At GPS L1 (`λ = 0.190294 m`) with `masterConfig`'s `sigmaClock_m = 0.03`: **0.223 cycles** — already a fifth of the pull-in half-width.
  At the ISL band the new rungs actually use, 26 GHz (`λ = c/26e9 = 0.01153048 m`), with `isl017`'s `sigmaClock_m = 0.02`: **2.453 cycles**. With `masterConfig`'s 0.03: **3.680 cycles**.
  At 2.45 cycles the differenced ISL ambiguity is not integer in any useful sense; LAMBDA will fix it to a *wrong* integer with near-certainty, and `applyIslDifferencedAmbiguityFix` will then inject that wrong integer as a **1 mm** hard constraint. The SR gate does not save this: `Ps_LAMBDA` is computed from the *covariance*, which knows nothing about a deterministic bias — a tight `Qa` gives SR ≈ 1 while the float sits 2.45 cycles from truth. This is the textbook failure mode Joosten & Tiberius warn about — "even with a high enough success rate, fixing to the wrong integer ambiguities is still possible when one or more observations are grossly erroneous" (p. 50). The minimal fix: gate `assess` on `reportBiasBudget(cfg).sigmaDiff_cycles < some fraction of 0.5` and refuse otherwise. In mitigation: `estimator.lambda.enable`, `.isl.enable` and `.isl.applyFix` all default false (`masterConfig.m:417`, `:426`, `:431`), so this path is off unless deliberately switched on, and the hold logic (below) is correct.
  **What is right here and deserves credit**: `applyIslIntegerFix_` (`ReverseGNSSSimulation.m:1105–1157`) applies the deterministic constraint **once per arc and holds it**, re-applying only when the slip counter moves. The header states the reason exactly — "re-applying them every epoch would inject the same information over and over and drive P toward zero, producing a confidently-wrong covariance". That is the correct defence against the most common double-count in integer-constrained filtering, and it is implemented, not merely described.

### Test coverage

- **Code**: `tests/test_decorrelated_bootstrap.m:26–39` (invariant `ZᵀQZ = LDLᵀ`, `|det Z| = 1`, unit-lower `L`, 20 random SPD); **:41–84** (ILS vs exhaustive enumeration, `n ≤ 4`, ±4 box, 12 trials, ties allowed at :77); **:86–100** (decorrelation never lowers SR, 20 cases); **:102–130** (4000-draw Monte Carlo, one-sided `srMeas >= srPred - tol`, `tol = 4·√(p(1−p)/n)`).
  Also `tests/test_lambda_resolver.m`, `tests/test_isl_double_difference.m`, `tests/test_baseline_ambiguity_lambda.m`, `tests/test_orekit_lambda_integer_crossvalidation.m`, plus the two new band tests.
- **Status vs doc**: STILL-VALID (every cited line confirmed).
- **Verdict**: correct — the four properties tested are the four that matter, and they are tested against ground truth rather than against the implementation's own outputs.
- **Sources**: Joosten & Tiberius (2000) — "One way of obtaining the success rate is by simulation. Using a random number generator, we can obtain a large number of real-valued ambiguity vectors from the origin-centered probability distribution … The percentage of integer solutions that coincide with the origin yields the success rate." (p. 51). Teunissen (2001) eq. (28), `P(ǎB = a) ≤ P(ǎLS = a)` (p. 253), justifies the one-sided assertion.
- **Critical analysis**. The one-sidedness is correctly reasoned. **NEW gap, and it is the important one: every property test disables the acceptance gates.** `opts = struct('minSuccessRate', 0, 'ratioThreshold', 0, ...)` at :52 and :115. So nothing in the suite exercises `reject-lowSuccessRate`, `reject-ratioTest`, the node-budget fallback, `reject-partialFix`, or the `numel(sqnorm) < 2` hole (L-1). The *estimator* is well tested; the *accept rule* — which is what every reported `P(false fix)` depends on — is tested nowhere. Second-order note: with `ratioThreshold = 0` the initial ellipsoid degenerates to `chi2 = bootCost` with a strict `<` comparison, so when the ILS optimum equals the bootstrap answer nothing is found and the run is rescued only by the `if ~isfinite(bestCost)` fallback at :280. The tests therefore also exercise a search regime the production configuration never sees.

---

## Double-count candidates

**DC-1 — ISL carrier: the product bias is absorbed by the float ambiguity AND charged in R** *(severity: high for isl017; the mechanism behind its 9.3× overconfidence)*
- Location A: `+revgnss/ISLMeasurementBuilder.m:345` — `rowC(ambIdxC) = 1;` — the float ambiguity has a unit Jacobian on the carrier row, so it can absorb any per-link bias that is constant over the arc.
- Location B: `+revgnss/ISLMeasurementBuilder.m:319` — `Rc = info.carrierSigma_m^2 + sigPos2c + info.product.sigmaClock_m^2;` — the *same* bias's full variance is charged in R.
- Mechanism: `pb.clk` and `pb.pos` are piecewise-constant over `updateInterval_s = 300 s` (`productBias_` is keyed on `intervalIdx`). Within an interval the residual carries a constant `−pb.clk − u'·pb.pos`, which the ambiguity state absorbs — with `isl016/017`'s `processNoiseSigma = 0.01 m/√s` it absorbs 96.3 % of it per epoch (steady-state `K = 0.963`, derived above). R nonetheless charges the whole `0.03² + 0.02² = 1.3e-3 m²`.
- Size: `Rc = 4e-6 + 9e-4 + 4e-4 = 1.304e-3 m²` (σ = 36.1 mm) against a carrier whose own noise is 2 mm — a **326× variance inflation**, 99.7 % of it for a bias the state removes.
- Severity: **high**. The repo's *own ground path* takes the opposite and correct position — `+models/+measurements/CarrierMeasurementBuilder.m:586–588`: "Policy: timeVaryingProductResidualOnly — constant bias absorbed by float ambiguity; only age-weighted residual (from arc start) enters R." The ISL path never adopted that policy. The two carrier builders in the same repository charge the same physical error two different ways.

**DC-2 — the ISL product error is correlated but charged white; it therefore averages out of P far faster than out of the truth** *(severity: high)*
- Location A: `+revgnss/ISLMeasurementBuilder.m:637–647` `productInterval_` — `idx = floor(t_s/dt)` with `dt = 300 s`: the error is deliberately piecewise-constant.
- Location B: `+revgnss/ISLMeasurementBuilder.m:319` (and `:234`, `:260` for code/Doppler) — the same error's variance enters R as a white, per-epoch term.
- Mechanism: over a 3600 s arc there are 12 independent product draws per link, but the filter is fed 3600 independent samples. P shrinks like `σ/√3600` where the information supports at most `σ/√(12·nLinks)`.
- Size: with 5 links, `σ_pos = 0.03 m`: honest floor ≈ `0.03/√60 = 3.9 mm`; the filter reports 5.9 mm per axis (10.2 mm 3-D) but the realised RMS is **94.6 mm** — the goldens make the mismatch measurable at **9.3×**. The comment at `masterConfig.m:2683–2685` claims the piecewise-constant structure means the error "averages down over the run and the white-R model stays consistent"; the frozen goldens say otherwise.
- Severity: **high** — it is the reason the honest rung's σ cannot be quoted. Note this is *not* the same as DC-1 and is not cancelled by it: DC-1 makes R too big, DC-2 makes P shrink too fast, and the goldens show DC-2 wins by an order of magnitude.

**DC-3 — the fixed-carrier observable inherits the code observable's multipath and differential-atmosphere variance** *(severity: medium, currently latent)*
- Location A: `+revgnss/JointGeometrySolver.m:166–167` — only `rhoObs` and `codeSigma_m` are overridden.
- Location B: `+revgnss/JointGeometrySolver.m:211–213` — `varRaw = obs.codeSigma_m^2 + obs.multipathSigma_m^2*(tauMp/dt) + obs.differentialAtmosphereSigma_m^2;`.
- Mechanism: the wide-lane carrier observable published by `GroundCarrierAmbiguityResolver.laneRange_` (`rawSigma_m = amp·σ_φ ≈ 11.5 mm`) is charged the *code* multipath variance scaled by `τ/dt`, plus the code differential-atmosphere variance, neither of which was replaced.
- Size: zero at masterConfig defaults (`multipathSigma_m = 0.0` at `:1628`, `differentialAtmosphereSigma_m = 0.0` at `:1638`). At `σ_mp = 0.2 m`, `τ = 60 s`, `dt = 1 s`: `+2.4 m²` against `1.3e-4 m²` — an **18,000× over-charge**. Also asymmetric on the truth side: `GroundCarrierObservationSet` builds `phase_m` from `rhoTruth + atmDiff` and never adds a multipath draw, so the carrier is charged for an error it does not carry.
- Severity: **medium** — inert today, but it fires the moment anyone measures "the cost of multipath" on the cascade, which is what those knobs exist for.

**DC-4 — cleared: the L1 covariance does NOT count the geometry error twice**
- Checked because the brief asked. `GroundCarrierAmbiguityResolver.m:396–400`: `varCyc = (geomSigma/λ1)²` is added once, as a rank-one fully-correlated block `varCyc*ones(n)`; the phase term enters through `ddCovariance_` with the per-link variance `varPhaseCyc/4`, which the incidence matrix re-multiplies by 4. No term appears twice. The `geomSigma` is drawn from the WL-*conditioned* posterior (:411–419), which is the point of a cascade, not a double count. The remaining criticism is structural (rank-one `ones(n)` is idealised) and self-referential (the posterior came from a solve fed the same phase data) — the latter biases the covariance **up**, i.e. safe.

**DC-5 — cleared: `product.enable=false` really does zero the R contribution**
- Checked because it is the classic pattern. `ISLMeasurementBuilder.m:631–633` zeroes `sigmaPos_m`, `sigmaClock_m`, `sigmaVel_mps`, `sigmaClockDrift_mps` when disabled, so isl016 does not charge R for an error it never injected. This is a gate that gates. Worth recording as correct.

## Logical flaws

**L-1 — the LAMBDA ratio test is skippable** (`+revgnss/+integer/LambdaResolver.m:174`). `if numel(sqnorm) >= 2 && sqnorm(1) > 0` — when the configured `method` returns one candidate (`method = 1` rounding or `2` bootstrapping, both documented at `masterConfig.m:419`), the discrimination test is silently omitted, `info.ratio` stays `NaN`, and `info.accepted` is set on the SR gate alone. Severity: medium (default `method = 3` is safe).

**L-2 — `assertIntegerParametrisation` is called with a literal `true`** (`+revgnss/+integer/IslDoubleDifference.m:101`), so the one precondition LAMBDA's validity rests on is asserted, never tested. `reportBiasBudget` computes the deciding number (`√2·σ_txClock/λ`) and no caller consults it. At 26 GHz with `σ_clk = 0.02 m` that number is **2.453 cycles**. Severity: high on the paths where `estimator.lambda.isl.applyFix` is on; those default off.

**L-3 — `geometryDdSigma_` applies two different unit conventions** (`+revgnss/GroundCarrierAmbiguityResolver.m:416–424`). The `shapeSigmaPosterior_m` branch yields `0.46·σ`; the `formalShapeSigma_m` branch yields `0.797·σ`. A `√3` that is divided in and multiplied back out in one branch is simply absent in the other. Since this sigma dominates the L1 float covariance, the printed L1 `P(false fix)` depends on which field the caller happened to populate. Severity: medium.

**L-4 — `conditionBefore` and `conditionAfter` are provably equal** (`+revgnss/+integer/DecorrelatedBootstrap.m:64–65`). `det(ZᵀQZ) = det(Q)` for unimodular `Z`, so `(∏d)^{1/2n} ≡ det(Q)^{1/2n}`. The ADOP itself is correct; the before/after framing is a diagnostic that cannot move. Severity: low (misleading, not wrong).

**L-5 — the fixed-carrier gauge is only valid on epochs where the resolver's reference tower is visible.** `GroundCarrierAmbiguityResolver.ddIndex_:208–222` picks `refTw` = lowest ever-visible tower index and **skips** epochs where `refTw ∉ okTw`. `JointGeometrySolver.buildEpochRows_:691–696` uses `mr = okTw(1)` and skips nothing. Because `okTw` is ascending and `refTw` is the lowest ever-visible index, `okTw(1) == refTw` whenever `refTw` is visible — so the two agree on every epoch the resolver used. But at an epoch where `refTw` drops out and ≥2 other towers remain, `JointGeometrySolver` consumes links whose integers were **never removed**, so its DD carries `λ_WL·N_true` (up to ±1000 cycles ≈ ±860 m) while weighted at 11.5 mm. Latent, conditional on the visibility pattern; from GEO with a 13° tower spread it will not fire on the current scenarios. Severity: low-but-catastrophic-if-triggered; the guard is one `ismember(refTw, okTw)` check away.

**L-6 — `detectCompensated` has no first-epoch guard** (`+revgnss/CycleSlipDetector.m:31–37`) while `detect` does (`:56–60`). At `minEpochsBeforeDetect <= 1` it would difference against an uninitialised `prev = 0`. All live callers pass ≥ 3. Severity: low.

**L-7 — every property test disables the acceptance gates.** `tests/test_decorrelated_bootstrap.m:52` and `:115` set `minSuccessRate = 0` and `ratioThreshold = 0`. No test can fail because a gate misbehaved. Severity: medium — the acceptance rule is the part of this domain the paper actually quotes.

**L-8 — the stale "not implemented" strings now contradict a frozen golden.** `AmbiguityFixingReadinessGate.m:210–212`, `AmbiguityArcState.m:127–129/155–159`, `WideLaneNarrowLaneDiagnostics.m:233–236/285–290`, `IntegerAmbiguityFixer.m:82`. Severity: medium (traceability).

**L-9 — the ISL float ambiguity is given random-walk process noise 5× larger than the measurement sigma.** `config/ladder/ISL/isl016_carrierFloatAmbiguity.json` → `processNoiseSigma_m_per_sqrt_s = 0.01` against `carrier.sigma_m = 0.002`, applied at `+filter/ReverseGNSSEKF.m:1546–1553` as `Q(idx,idx) = q^2*dt`. Steady-state ambiguity gain `K = 0.963`. The state is no longer an ambiguity in any physical sense; the row is a delta-range. Severity: high for interpretation, and it must be declared wherever isl016/isl017 are cited.

**L-10 — the documented headline numbers for isl016/isl017 do not match the frozen goldens.** JSON `_id` says 0.003585 / 0.095183 m at 3600 s; `run_multi_islcarrier_regression.m:6–7` says 0.003585 / 0.130883 m at 600 s; the working-tree goldens give **0.003562 / 0.094562 m at 3600 s**. The goldens are uncommitted and post-date `170e37d` (Libreville longitude), which moved everything. Severity: medium (a citation hazard, not a physics error).

**L-11 — `knownAmbiguityAttitudeValidation` is a truth-in-the-estimator path.** `+models/+measurements/CarrierMeasurementBuilder.m:576–582` subtracts the **true** ambiguity from `z` and the estimated one from `h` and zeroes the Jacobian column. It is labelled "ATTITUDE VALIDATION ONLY — not operational" and no file in `config/` sets it (grep: zero hits), so it is inert by default — but it is reachable by an override and would silently produce an inverse-crime result. Severity: low, given the labelling; worth an explicit refusal rather than an `isfield` test.

## Limits of this domain

1. **No integer fix is applied inside the ground-to-space EKF, ever.** The integer machinery is a post-processing/diagnostic layer (`GroundCarrierAmbiguityResolver`) plus one gated ISL constraint (`estimator.lambda.isl.applyFix`, default false). Nothing in this domain may be quoted as "the EKF solution with fixed ambiguities".

2. **The wide-lane success rate is a statement about averaging white code noise, not about ambiguity resolution in the field.** `GroundCarrierObservationSet.m:139–140` draws code noise as `sigCode*randn` — pure white, with **no multipath, no differential code bias, no DCB, no pseudorange smoothing**. Therefore `σ_MW` averages down as `1/√n` with **no floor**. Numerically: per-link `varMwLink = 0.0674 m²` at `σ_P1 = 0.30 m, σ_P2 = 0.45 m, σ_φ = 2 mm`, so one DD at one epoch has `σ = 0.519 m = 0.602 WL cycles`; over a 3601-epoch arc that is **0.010 cycles**, and `P_s → 1` trivially. In reality MW is limited by *correlated* code multipath (τ of minutes) and by *constant* differential code biases, neither of which averages away. Any quoted WL `P(false fix)` from this code is an idealisation, and its smallness is a property of the noise model, not of the geometry.

3. **The entire ground-carrier cascade is computed at GPS L1/L2 regardless of the scenario band** (`GroundCarrierObservationSet.m:47–48`). No result from `config/ladder/freq/freq009…013` passing through this cascade is band-correct. At `freq013` the true wide lane is ~8.1 mm against the 861.9 mm the code uses — a factor of 106.

4. **The band-invariant carrier sigma and slip threshold are implemented and tested but enabled nowhere.** Every scenario in `config/` leaves `measurements.carrier.sigma_cycles` and `carrierSlip.threshold_cycles` at `NaN`. Reported band sweeps therefore use a metre-fixed 5 mm sigma and 0.1 m slip threshold, which is 1.02 cycles and 20.4 cycles respectively at 61.25 GHz.

5. **Single-cycle slips are not detectable at the realism-grade carrier sigma.** The ISL auto threshold is `5√2·σ`; at `σ = 0.20 m` that is 1.41 m ≈ 7 L1 cycles (`masterConfig.m:2645–2650`). The ground default (`threshold_m = 0.1`, `minEpochsBeforeDetect = 3`) was never migrated to the auto idiom. No geometry-free or Melbourne-Wübbena slip detector exists, so the detectable-slip floor is set by thermal noise rather than by the observable's own dispersion.

6. **isl016 must never be quoted as a result.** With `product.enable=false` each leaf EKF's `h` reads its five neighbours' true position and clock. The measured cost of removing that leak is 0.003562 m → 0.094562 m (26.5×).

7. **isl017 may be quoted for accuracy but not for uncertainty.** Its formal 3-D 1σ (10.2 mm) understates its realised RMS (94.6 mm) by 9.3×, and by 17× on the worst asset. DC-2 is the mechanism.

8. **The ISL "carrier" rows on isl016/isl017 are not carrier-phase observables in the ambiguity-resolution sense.** With `processNoiseSigma_m_per_sqrt_s = 0.01 m/√s` the ambiguity absorbs 96.3 % of each innovation and can wander ~52 cycles per hour at 26 GHz. They deliver delta-range information.

9. **The between-satellite ISL "double" difference is a single difference**, and its surviving transmitter-clock residual is 0.223 cycles at L1 (`σ_clk = 0.03 m`) and **2.45 cycles at 26 GHz** (`σ_clk = 0.02 m`). Integer resolution on that parametrisation is invalid at the crosslink band the ladder actually uses, and nothing in the code refuses it.

10. **The acceptance rule is untested.** Every property test in `tests/test_decorrelated_bootstrap.m` sets both gates to zero. The reported `P(false fix)` is a bound on the *integer bootstrapping* failure probability under the assumed covariance, **not** the failure rate of the composite accept rule, and not a bound at all in the presence of a deterministic bias (Joosten & Tiberius, p. 50).

11. **The ratio thresholds have no source.** 2.0, 3.0, 3.0 and 1.20 appear in four places in `masterConfig` with no derivation. Verhagen & Teunissen (2013) demonstrate that a fixed critical value yields a failure rate that varies by orders of magnitude with model strength and propose the fixed-failure-rate ratio test as its replacement. The honest formulation for the paper is: "P(false fix) ≤ 1 − P_s,IB, a rigorous ILS lower bound under the assumed covariance (Teunissen 2001, p. 253), with an additional heuristic ratio ≥ 2 screen."

12. **Phase wind-up and antenna PCV are absent from every carrier path** (`ISLMeasurementBuilder.m:283–285` declares this). A constant part of either is absorbed by the float ambiguity; a drift would leave a real residual and could pull an integer fix. No bound on that drift is computed anywhere.

---

### References (APA 7) — verified this round

- Enge, P. K. (1994). The Global Positioning System: Signals, measurements, and performance. *International Journal of Wireless Information Networks, 1*(2), 83–105. [PDF in `Paper/Fundamental Books/The Global Positioning System- Signals, measurements, and performance.pdf`; OCR text layer, quote p. 90]
- Hofmann-Wellenhof, B., Lichtenegger, H., & Wasle, E. (2008). *GNSS — Global Navigation Satellite Systems: GPS, GLONASS, Galileo, and more*. Springer. [PDF in `Paper/Fundamental Books/03_gnss-…-2008.pdf`; embedded text layer with fi/ff ligatures; quotes verified pp. 112, 179, 180, **217**]
- Joosten, P., & Tiberius, C. C. J. M. (2000). Fixing the ambiguities: Are you sure they're right? *GPS World, 11*(5), 46–51. [PDF in `Paper/Positioning Technologies/`; quotes verified pp. 46, 49, 50, 51]
- Massarweh, L., Verhagen, S., & Teunissen, P. J. G. (2024). *New LAMBDA toolbox for mixed-integer models: Estimation and evaluation* (LAMBDA 4.0). TU Delft. [EXTERNAL — not vendored; `Ps_LAMBDA` method codes and the internal PAR threshold remain unverified from this repository]
- Naqvi, N. A., Zhang, K., Masood, K., & Lv, M. (2013). *Design and simulation of GNSS phase based attitude determination of spacecraft: LAMBDA and EKF combination technique* (AIAA 2013-4832). [PDF in `Paper/Error Calculation/Atmospheric Errors/`; quote verified p. 6]
- Tagliaferro, G. (2021). *On the development of a general undifferenced uncombined adjustment for GNSS observations* [Doctoral dissertation, Politecnico di Milano]. [PDF in `Paper/Fundamental Books/05_Tesi_tagliaferro.pdf`; quotes verified pp. 20, 35, 37 — note the p. 35 rounding/bootstrap ordering is stated backwards in the source]
- Teunissen, P. J. G. (1995). The least-squares ambiguity decorrelation adjustment: A method for fast GPS integer ambiguity estimation. *Journal of Geodesy, 70*(1–2), 65–82. [EXTERNAL]
- Teunissen, P. J. G. (2001). GNSS ambiguity bootstrapping: Theory and application. *Proceedings of KIS 2001*, 246–254. https://gnss.curtin.edu.au/wp-content/uploads/sites/21/2016/04/Teunissen2001GNSS.pdf [EXTERNAL — re-fetched and re-verified this round; quotes pp. 249, 250 (eq. 19), 252, 253 (eq. 28)]
- Verhagen, S., & Teunissen, P. J. G. (2013). The ratio test for future GNSS ambiguity resolution. *GPS Solutions, 17*(4), 535–548. https://doi.org/10.1007/s10291-012-0299-z [EXTERNAL — abstract only; full text paywalled]

---

# Round-2 re-verification — ISL, link budget, beamforming, swarm/relative solvers, distributed fusion

Tree verified: `feature/ground-orientation-exec` @ `170e37d` (working tree, 2026-08-13).
Doc under review: `docs/scientific_traceability_analysis.md`, section "ISL, Link Budget, Beamforming &
Swarm Solvers", lines 989–1556. That section declares its line numbers refer to the 2026-08-06 tree.

**Scope of code change in this domain since the doc's baseline `3489075`:** exactly one file,
`+revgnss/ISLMeasurementBuilder.m` (+23/−10, commit `9a52cfc`). Every other file in the domain is
byte-identical to `3489075`. **Line drift nonetheless exists** because the doc's numbers were taken
from a 2026-08-06 snapshot and several files moved between 2026-08-06 and `3489075`.

Headline result: the section's *verdicts* survive almost intact, but three of its supporting factual
claims are now wrong, and the single defect it flagged (❌ product-interval error as white R) has been
**escalated, not fixed** — it is now live in `isl017`, the rung the repository itself nominates as
"the defensible half, and the one to quote".

---

## 1. Free-space path loss and the C/N0 chain

- **Code**: `+revgnss/InterSatelliteRFLinkModel.m:142-144` —
  `c = 299792458; kBoltzmann = 1.380649e-23; fspl = 20*log10(4*pi*distance*frequency/c);`
  `:145` `receivedCarrier = eirp + rxAntenna.gain_dBi - fspl - losses;`
  `:167-169` `noiseDensity = 10*log10(kBoltzmann*noiseTemperature); cn0_dBHz = receivedCarrier - noiseDensity; cn0_Hz = 10^(cn0_dBHz/10);`
  `:158` `receiverGT = rxAntenna.gain_dBi - 10*log10(noiseTemperature);`
  `:251-252` `gain = 10*log10(efficiency*(pi*diameter/wavelength)^2); beamwidth = 70*wavelength/diameter;`
  Anchored twin at `+revgnss/ISLLinkBudget.m:7-9`.
- **Status vs doc**: **STILL-VALID** (doc cited 142-168; the chain now spans 142-169 — same statements,
  one line of drift on `cn0_Hz`). The antenna model the doc cited as "lines 236-254" is now
  `antenna_` at **217-265**, gain at **:251**, beamwidth at **:252** → **DRIFTED**.
- **Verdict**: **correct** — every constant is digit-exact and the identity is the textbook one.
- **Sources**:
  - International Telecommunication Union. (2024). *Recommendation ITU-R P.525-5: Calculation of
    free-space attenuation*. ITU-R. — "Introducing free-space attenuation between isotropic
    antennas, also known as the free-space basic transmission loss (symbols: Lbf or Abf), it can be
    calculated as follows" (PDF p. 5 = printed p. 3, immediately preceding Eq. (5)). **Quote
    re-extracted and verified verbatim this pass.** Eq. (5) is `L_bf = 20 log10(4πd/λ) dB`;
    Eq. (6) on the same page is `L_bf = 32.4 + 20 log10 f + 20 log10 d dB` with "f : frequency
    (MHz)" and "d : distance (km)".
  - Arias, M., & Aguado, F. (2016). *Small satellite link budget calculation* [Lecture slides].
    Universidade de Vigo. — "C/N0: Relation between the power of the modulated carrier C and the
    noise power spectral density N0 = k · t. It can characterize the channel without the final
    information about the bandwidth" (slide 33 of 46). **Verified verbatim this pass.** The same
    deck, slide 5: "Friis formula was first published in 1946: H. T. Friis, 'A note on a simple
    transmission formula,' Proc. IRE 34, 254–256 (1946)". **Verified verbatim this pass.**
  - Friis, H. T. (1946). A note on a simple transmission formula. *Proceedings of the IRE, 34*(5),
    254–256. [EXTERNAL, cited through the Vigo deck; no verbatim quote obtained]
- **Critical analysis**: Digit checks re-run from scratch this pass.
  `20·log10(4π·10⁶·10³/299792458) = 20·log10(41.9169) = 32.447` → matches P.525 Eq. (6)'s 32.4 ✓.
  `10·log10(1.380649e-23) = −228.5991` dBW/(K·Hz), the CODATA-2018 exact Boltzmann value, so the
  usual rounded −228.6 constant is never typed ✓. The mutually-exclusive input checks
  (`transmitPower_dBW` XOR `eirp_dBW`, `systemNoiseTemperature_K` XOR `receiverGT_dB_per_K`,
  `bandwidth_Hz` XOR `chipRate_Hz`, lines 125-129 / 149-153 / 270-274) are a genuinely good
  guard against silently double-declaring the same quantity.
  **NEW defect (minor, inert config)**: `ISLLinkBudget.cfg_` lines **95-96** read
  `linkBudget.EIRP_dBW` and `linkBudget.GT_dBK` into the struct, `describe()` publishes them, and
  **no code anywhere multiplies or adds them** (repo-wide grep over `*.m`: only `config/masterConfig.m`
  declares them and `ISLLinkBudget.m` reads them). They cancel identically in
  `cn0Delta_dB = −20·log10(d/d_ref)`, which is mathematically why they can be inert — but a report
  that prints EIRP = 15 dBW and G/T = 5 dB/K next to a σ implies they drove it, and they did not.
  The doc's caveat that `sigma()` is frequency-blind while `describe()` advertises
  `frequencyDependent = true` for `fixedGain` (`ISLLinkBudget.m:71`) is **STILL-VALID**.

## 2. Ranging noise from C/N0 (code-tracking σ)

- **Code**: `+revgnss/InterSatelliteRFLinkModel.m:170-171` —
  `sigma = trackingCoefficient*c/(2*rangingBandwidth*sqrt(cn0_Hz*integrationTime));`
  self-declared at `:209-214`; ranging bandwidth resolved at `:267-284`.
- **Status vs doc**: **STILL-VALID** (identical line numbers).
- **Verdict**: **partially correct** — the functional form is the standard coherent-DLL thermal
  jitter family; the discriminator/waveform physics is compressed into one declared coefficient and
  the code carries no in-repo citation for that family.
- **Sources**:
  - [Article seuils acquisition version finale]. (n.d.). *GNSS acquisition thresholds and C/N0 link
    budget margins for DFMC receivers*. (Paper/Link BUdget.) — "This section computes the C/N0
    acquisition link budget margins for the different signals to be acquired. The link budget margin
    is defined in (30)." (p. 24). **Verified verbatim this pass** (page index 24 of the PDF).
    This anchors the *methodology* (declared effective-noise budget vs thermal-only), not the DLL
    coefficient.
  - Kaplan, E. D., & Hegarty, C. J. (Eds.). (2017). *Understanding GPS/GNSS* (3rd ed.). Artech
    House. [EXTERNAL — no verbatim quote obtained this pass]
  - Betz, J. W., & Kolodziejski, K. R. (2009). Generalized theory of code tracking with an
    early-late discriminator, Part I. *IEEE TAES, 45*(4), 1538–1556. [EXTERNAL — no verbatim quote
    obtained this pass]
- **Critical analysis**: Algebra re-derived independently. The coherent DLL result
  `σ_DLL = T_c·√(d·B_L/(2·C/N0))` in metres is `c·T_c·√(d·B_L/(2·C/N0))`; substituting `B_L = 1/(2T)`
  and `d = 1` chip gives `c·T_c/(2√(C/N0·T)) = c/(2·f_chip·√(C/N0·T))`, i.e. exactly line 170-171
  with coefficient 1 and `rangingBandwidth = chipRate` ✓. So the shipped expression is the
  1-chip-spacing coherent-DLL special case, and `modulationTrackingCoefficient` is the only place
  BOC/BPSK, non-coherent squaring loss, and discriminator spacing can enter. That is a legitimate
  parameterisation but it means **no ISL σ in this repository is derived from a waveform** — it is
  declared. The self-documentation at `:209-214` states this.
  **DOC CORRECTION**: the doc's §2 states the ISL carrier uses "a declared total σ
  (`measurements.isl.carrier.sigma_m`, default 2 mm)". That is **NOW-WRONG**. The shipped default is
  `config/masterConfig.m:2606` → `cfg.measurements.isl.carrier.sigma_m = 0.20` m. The 2 mm figure is
  an *unreachable in-file fallback* at `ISLMeasurementBuilder.m:495` (`getNum_(..., 0.002)`). See
  LF-3 below: the same file's `validateConfig` uses a *different* fallback (0.20) at `:124`.

## 3. Two-way composite σ and first-order plasma delay

- **Code**: `+revgnss/InterSatelliteRFLinkModel.m:73-75` —
  `result.codeRangeSigma_m = 0.5*sqrt(max(0, forwardSigma^2 + returnSigma^2 + 2*trackingCorrelation*forwardSigma*returnSigma));`
  with `trackingCorrelation = 0` unless declared (`:58-68`); `:178` `plasmaDelay_m = 40.3*tec/frequency^2;`
- **Status vs doc**: **STILL-VALID** (identical lines).
- **Verdict**: **correct**. Re-derived: the half-round-trip observable is `(ρ_f+ρ_r)/2`, whose
  variance is `(σ_f²+σ_r²+2ρσ_fσ_r)/4`, so σ is `0.5·sqrt(...)` ✓. Sanity limits: ρ=1, σ_f=σ_r=σ
  gives σ (correlated errors average not at all) ✓; ρ=0 gives σ/√2 ✓.
- **Sources**: Hofmann-Wellenhof, B., Lichtenegger, H., & Wasle, E. (2008). *GNSS — Global Navigation
  Satellite Systems*. Springer, §5.3 (first-order group delay `40.3·TEC/f²`, coefficient 40.308).
  [EXTERNAL — no verbatim quote obtained this pass]
- **Critical analysis**: This is the answer to **double-count question (a)**: **NO double count.**
  Three independent confirmations: (i) both `forwardSigma` and `returnSigma` come from
  `evaluateLeg_`'s *thermal* `codeRangeSigma_m` only — no calibration term is inside either leg;
  (ii) `forwardReturnTrackingErrorCorrelation` defaults to **0** (`config/masterConfig.m:2768`) and
  the name/validation restrict it to *tracking* error; (iii) the calibration variance is charged in
  a *different* place and is explicitly mutually exclusive with the bias state —
  `+revgnss/TwoWayISLMeasurementBuilder.m:573-575`:
  `if ~biasStateEnabled; observationVariance = observationVariance + calibrationVariance; end`.
  That is the textbook-correct anti-double-count (a systematic is either estimated as a state or
  charged to R, never both).
  Also **STILL-VALID**: the "floorless claim" guard at `TwoWayISLMeasurementBuilder.m:549-561`
  (same lines as the doc) and the hard refusal at `:242-278` (same lines) —
  "A recurring calibration error or uncertainty cannot be repeated as white R".
  One asymmetry worth recording: `nonThermalSigma_m` and `plasma.residualSigma_m` are added to
  `observationVariance` (`:572`) but the truth-side draw at `:579` uses `thermalSigma` alone, so those
  two terms are charged to R with **no matching injected error**. That is conservative (deflates NIS),
  not optimistic, and both default to 0.

## 4. Beamforming phasor sum, Ruze envelope, near-field focus

- **Code**: `+revgnss/BeamformingPhasorDiagnostics.m:481-491` —
  ```
  psi = -2*pi*pathError_m/wavelengths_m(index);  psi = psi - mean(psi);
  arrayFactor(index) = abs(mean(exp(1i*psi)));
  lossDb(index)      = 20*log10(max(arrayFactor(index),realmin));
  ruzeDb(index)      = -4.342944819*CE.rms_(psi)^2;
  fresnel_m(index)   = 2*apertureExtent_m^2/wavelengths_m(index);
  nearField(index)   = fresnel_m(index) > slantRange_m;
  ```
  Contract at `:9-24`; per-epoch series `computeSeries` at `:141-320` with the path-error map at
  `:215-223` (`geom = rangeTo(P)-truthRange; geom -= mean; clk -= mean; e = geom+clk; e -= mean`);
  `series.nearField` at `:286`; incoherent floor `payload.incoherentFloor_dB = 10*log10(1/nAssets)`
  at `:545`; focused beam pattern at `:917-973`; honesty gate `claim_` at `:1105-1134`;
  report text `+revgnss/+report/beamformingPhasor.m:22-31` and `:100-105`.
- **Status vs doc**: **STILL-VALID** for the implementation block (481-488 → 481-491, same
  statements), the contract (12-17), the series loop (206-268), and the mean-removal citations
  (152-154, 215-224). **DRIFTED** for the focused-beam pattern: doc said 765-783, it is now
  **917-973** (`plotBeamPattern`). Also **DRIFTED**: the honesty gate the doc cited at "line 32-35"
  is the header at **32-37**, and its implementation is `claim_` at **1105-1134**.
- **Verdict**: **correct**.
- **Sources**:
  - Ruze, J. (1966). Antenna tolerance theory — A review. *Proceedings of the IEEE, 54*(4), 633–640.
    [EXTERNAL — no verbatim quote obtained this pass]. Standard result `G/G₀ = e^(−δ̄²)`.
  - Merlo, J. M., Mghabghab, S. R., & Nanzer, J. A. (2023). Wireless picosecond time synchronization
    for distributed antenna arrays. *IEEE Transactions on Microwave Theory and Techniques, 71*(4),
    1720–1731. — "Achieving good performance in distributed antenna systems requires stringent
    synchronization at the wavelength and information levels to ensure that the transmitted signals
    arrive coherently at the target" (p. 1720). **Verified verbatim this pass.** Same abstract:
    "obtaining a timing precision of 2.26 ps" (p. 1720) — the demonstrated hardware bound against
    which any picosecond claim in this repo must be measured.
  - Balanis, C. A. (2016). *Antenna theory: Analysis and design* (4th ed.). Wiley, §2.2.4
    (Fraunhofer distance `2D²/λ`). [EXTERNAL — no verbatim quote obtained this pass]
- **Critical analysis**: Constant re-checked digit by digit: `10/ln10 = 4.3429448190325175`, so
  `-4.342944819` at `:485` is correct to 10 significant figures ✓, and it is the **power** form
  (`10·log10(e^{−σ²}) = −4.3429·σ²`) consistent with `lossDb = 20·log10|AF| = 10·log10|AF|²` ✓.
  The **one-way** 2π/λ (not the reflector 4π/λ) is right because the path error is traversed once ✓.
  The focused-beam pattern was re-verified from the code rather than the comment: `:945-953`
  `idealWeights = exp(-1i*k*rangeAt(target)); steering = exp(1i*k*ranges); pattern = |mean(w.*steering)|²`
  — at the target `ranges == rangeAt(target)` so the product is identically 1 and the pattern peaks at
  1. That is a **conjugate-phase focused** array, not a plane-wave steering vector ✓, exactly as
  claimed. Triple mean-removal at `:216/:221/:223` is idempotent (the mean of a zero-mean sum is
  zero), so it is harmless, not a bug.
  The honesty gate is real and has teeth: `claim_` returns
  `'notClaimableNoPhysicalRangeRows'` when `physicalRangeRowsConsumed <= 0` and
  `'notClaimableInsufficientConstraints'` when `physicalRangeLinkCount < relativePositionDof`, and
  `beamformingPhasor.m:117-126` prints a boxed "NOT SUPPORTED … must not be quoted as one". This is
  the single most important epistemic device in the domain and it is implemented, not asserted.

## 5. Expected coherent gain from an orientation σ (OrientationCoherenceBudget)

- **Code**: `+revgnss/OrientationCoherenceBudget.m:100-127` —
  `b.rotationLever_m = sqrt(2/3)*Rrms_m;` `:102 b.rimDisplacement_m = sigmaTheta_rad*b.rotationLever_m;`
  `:112 sigPhi = 2*pi*b.rimDisplacement_m ./ lam;`
  `:115 b.gainLoss_dB = 10*log10((1 + (n-1)*exp(-sigPhi.^2))/n);`
  `:121 b.mispointBeamwidths = 2*b.rimDisplacement_m ./ lam;`
  `:122 b.beamwidth_rad = lam ./ max(2*Rrms_m, realmin);`
  `:127 b.coherentUpTo_Hz = c / max(20*b.rimDisplacement_m, realmin);`
- **Status vs doc**: **STILL-VALID** (identical lines 100-127).
- **Verdict**: **correct** in the code; **partially correct** in the class header (see below).
- **Sources**: Mudumbai, R., Brown, D. R., III, Madhow, U., & Poor, H. V. (2009). Distributed transmit
  beamforming: Challenges and recent progress. *IEEE Communications Magazine, 47*(2), 102–110.
  [EXTERNAL — no verbatim quote obtained this pass].
- **Critical analysis**: Derivation re-done from scratch. For i.i.d. zero-mean Gaussian φᵢ with
  variance σ², `E|Σe^{jφ}|² = Σ_i Σ_k E[e^{j(φᵢ−φ_k)}] = N + N(N−1)|E e^{jφ}|² = N + N(N−1)e^{−σ²}`,
  so the normalised gain is `(1+(N−1)e^{−σ²})/N` with floor `1/N` ✓ — line 115 exactly.
  The G2 lever: for a unit rotation axis uniform on the sphere, `E|n̂×q|² = (2/3)|q|²`, so
  RMS rim displacement `= θ·R_rms·√(2/3)` ✓, and quoting the bare radius overstates by
  `1/√(2/3) = 1.2247`, i.e. 22.5 % ✓.
  The G5 cancellation as **implemented**: `mispointBeamwidths = (rim/R_rms)/(λ/(2R_rms)) = 2·rim/λ`,
  independent of R ✓ (lines 121 and 122 are mutually consistent).
  **NEW — LF-4, header contradicts code.** The class header at `:18-20` states the flowdown as
  `mispointing in beamwidths = 2*sigma_abs/(lambda*sqrt(N))`, and the in-body comment at `:119-120`
  repeats it as what the code does. **There is no `sqrt(N)` at line 121, and `N` is not even in
  scope of that expression.** The two formulas answer different questions: `2σ/(λ√N)` is the
  *fitted-tilt uncertainty* from N i.i.d. per-element errors; `2·rim/λ` is the *deterministic* tilt
  of a rigid rotation. The code computes the second (correct for this class); the header advertises
  the first. Any paper sentence lifted from that header will be wrong by `√N` (a factor of 2.45 at
  N=6). The "array size cancels" conclusion is correct for the R-cancellation and is unaffected.
  Second-order note: for a rigid rotation the physical boresight tilt is the *component of θ
  perpendicular to boresight*, whereas `rim/R_rms = θ·√(2/3) = 0.8165·θ` is the isotropic-axis RMS.
  Understates a worst-case tilt by ~18 %. Declared nowhere; small, but state it.

## 6. Swarm shape solver — the "classical MDS" label

- **Code**: `+revgnss/SwarmRelativeSolver.m:906-982` (`solveEpoch_`): per-epoch Gauss-Newton WLS with
  `H(p,ci) = u.'; H(p,ck) = -u.'; res(p) = zK(p) - rho;` (`:941-943`), normal matrix
  `Nmat = H.'*W*H` (`:946`), solved by `truncPinv_` (`:984-996`, `RANK_TOL = 1e-6` at `:41`).
  Kabsch/Procrustes appears **only** in `alignToTruth_` (`:1016-1026`: SVD of `E*T.'`,
  `dsign = sign(det(V*U.'))`, no scale). Rigidity counting at `:100-103`
  (`shapeDof = max(0, 3*N-6)`, `rigidityMargin = size(pairs,1) - max(0,3*N-6)`).
  Directional prior (`radialStiff`) documented at `:912-927`, applied `:948-953`.
  Per-link delay-bias self-calibration at `:192-238`.
- **Status vs doc**: verdict **STILL-VALID**; every line number **DRIFTED**
  (solveEpoch_ 732-808 → **906-982**; truncPinv_ 810-822 → **984-996**;
  alignToTruth_ 842-852 → **1016-1026**; radialStiff prior 738-753 → **912-927**;
  delay-bias pass 183-229 → **192-238**). Topology 100-103 unchanged.
- **Verdict**: **correct as implemented, mislabelled in project memory.** Re-grepped this pass:
  no Gram matrix, no `−½·J·D²·J` double centering, no `cmdscale`, no eigendecomposition-to-coordinates
  anywhere in the file. It is a free-network (inner-constraint) trilateration adjustment.
- **Sources**:
  - Torgerson, W. S. (1952). Multidimensional scaling: I. Theory and method. *Psychometrika, 17*(4),
    401–419. [EXTERNAL] — the construction the code does **not** use.
  - Kabsch, W. (1976). *Acta Crystallographica A, 32*(5), 922–923; Schönemann, P. H. (1966).
    *Psychometrika, 31*(1), 1–10. [EXTERNAL] — `alignToTruth_` is this solution verbatim, including
    the determinant-sign reflection guard.
  - Mao, G., Fidan, B., & Anderson, B. D. O. (2007). Wireless sensor network localization techniques.
    *Computer Networks, 51*(10), 2529–2553. [EXTERNAL] — the iterative-WLS anchor-free family that
    does match.
  - Blaha, G. (1971). *Inner adjustment constraints with emphasis on range observations*
    (OSU Report 148). [EXTERNAL] — the min-norm/inner-constraint datum.
  (None of the four is in `Paper/`; all remain EXTERNAL with no verbatim quote obtained.)
- **Critical analysis**: unchanged from the doc and re-confirmed. One addition: the header at
  `:20-21` claims *"NO double-count — ground pseudoranges and ISL use disjoint measurements; the
  ground covariance P_i is deliberately NOT injected as a shape prior."* That is now **contradicted
  by shipped configuration** — see LF-7 and DC-3.

## 7. The rotation wall (ranges blind to rigid rotation)

- **Code**: `+revgnss/SwarmRelativeSolver.m:14-18`; `+revgnss/GroundDifferencedRotationSolver.m:4-10`
  ("the range Jacobian along a rotation direction is 1.0e-16, i.e. machine zero").
- **Status vs doc**: **STILL-VALID** (identical lines).
- **Verdict**: **correct, and provable rather than measured.** Re-derived independently this pass
  from the shipped H rows: for a rigid rotation `δr_i = θ×(r_i − c)` about *any* centre `c`,
  row·δ = `u'(θ×(r_i−c)) − u'(θ×(r_k−c)) = u'(θ×(r_i−r_k)) = u'(θ×(ρu)) = ρ·θ·(u×u) = 0`.
  Identically zero for every pair and every choice of centre. The reported `1e-16` is floating-point
  dust around an analytic zero.
- **Sources**: Eren, T., Goldenberg, D. K., Whiteley, W., Yang, Y. R., Morse, A. S., Anderson,
  B. D. O., & Belhumeur, P. N. (2004). Rigidity, computation, and randomization in network
  localization. *Proceedings of IEEE INFOCOM 2004*, 2673–2684. [EXTERNAL — no verbatim quote
  obtained this pass]. Distance data determines a network only up to congruence.
- **Critical analysis**: The doc's caution about **reflection** stands: congruence includes the
  improper part, and `truncPinv_`'s 6-D null space is the *continuous* one. `alignToTruth_:1023`
  carries an explicit determinant-sign guard, so the *metric* cannot silently reflect; the *solve*
  cannot flip chirality because it Gauss-Newtons from the EKF estimate. Say "rigid motions (and
  reflection)" in the paper.

## 8. JointGeometrySolver — arc-constant 3N+3 shape + rotation

- **Code**: `+revgnss/JointGeometrySolver.m` — `acceptance` `:86`, `solve` `:113`,
  `shapePrior_` call `:141`, `shapeBasis_` build `:186` / definition `:641-652`
  (`B = null([G, T].')` with `G(3(i−1)+(1:3),:) = −skew(q_i)`),
  `Lrot = sqrt(2/3)*Rrms` `:191-194`, `minTurnAngle_deg` `:204`,
  rotation generator `:486-491`, `buildEpochRows_` `:689-709`, `ddWhitener_` `:711-739`,
  `shapePrior_` `:582-613`, `priorInformation_` `:615-624`, `shapeObservability_` `:743`,
  `separationPenalty_` `:784-826`, shapeFrame contract `:34-46`.
- **Status vs doc**: **STILL-VALID** — every cited range still lands on the same construct
  (rotation generator 487-491 → 486-491 is the only ±1 drift).
- **Verdict**: **correct** as an internally consistent least squares.
- **Sources**: Blaha (1971) [EXTERNAL]; Bierman, G. J. (1977). *Factorization methods for discrete
  sequential estimation*. Academic Press. [EXTERNAL] (Schur complement of nuisance blocks).
  No literature analogue implements this exact 3N+3 arc-constant parameterisation.
- **Critical analysis**: `shapeBasis_` re-verified: `null([G, T].')` with G the stacked rotation
  generators and T the stacked identities is exactly the orthogonal complement of the 6-D rigid
  subspace, so `dim = 3N−6` ✓ and the shape parameter provably cannot absorb the rotation. The
  prior is information on α only (`priorInformation_:619` `S = eye/sig^2`, anisotropic branch
  `B'*diag(1./pc.^2)*B`) and θ carries **no** prior — the correct posture, since ranges supply zero
  rotation information (§7).
  **Double-count question (b) — answered, with one caveat.** `shapePrior_:595-597` reads
  `rel.formalShapeSigma_m`, which is the *ISL-only* normal matrix (`Pshape = diag(Clast)` from
  `SwarmRelativeSolver.solveEpoch_:969`, built from `H'WH + S_gauge` and **not** including the
  per-asset EKF prior). The starting geometry `rel.solvedPos` *is* the ISL solve applied to the
  EKF estimates. So prior = ISL information, data = ground DD: each appears once, and because the
  prior ignores the ground contribution already inside `solvedPos` it is **looser than the truth**,
  i.e. conservative. **No ISL double count.** The caveat is a *ground* double count, not an ISL one
  — see DC-4.
  The turn-angle law and its `ShapeFrameSeparationProbe` falsification design are unchanged and
  remain the strongest methodological feature in the domain.

## 9. GroundDifferencedRotationSolver — DD → rotation

- **Code**: `+revgnss/GroundDifferencedRotationSolver.m` — header/atmosphere caveat `:1-63`,
  `buildObservable` `:103`, `predictedAntenna` `:268`, `solveRotationOnly_` `:286-506`;
  DD at `:336-338`
  `ddObs = (rhoObs(i,m,k)-rhoObs(1,m,k)) - (rhoObs(i,ref,k)-rhoObs(1,ref,k));`
  rotation Jacobian `:340-341`
  `Jth(row,:) = (cross(Pe(:,i)-cP, uP(:,i,m)) - cross(Pe(:,1)-cP, uP(:,1,m)) - cross(Pe(:,i)-cP, uP(:,i,ref)) + cross(Pe(:,1)-cP, uP(:,1,ref))).';`
  normal equations `:349-351` `Nmat = Nmat + (Jth.'*Jth); Ntp = Ntp + (Jth.'*Jsh);`
  variance factor `:361-363` `dof = max(1,nObs-3); s2 = sse/dof; Cth = s2*inv(Nmat);`
  measured leakage operator `:390-395` `Lop = (Nmat\Ntp)*Bshape; leakDegPerMetre = norm(Lop)*sqrt(N)*180/pi;`
  leak guard `:435-442`, refusal `:464-472`, SNR guard `:474-496`,
  lever-arm modes `:573-615`, MEKF error-state trap `:616-683`.
- **Status vs doc**: **DRIFTED** (doc's 331-345 → 336-345; 339-341 → 340-341; 386-395 → 390-395;
  439-472 → 435-472; 474-496 → 474-496 ✓; 573-681 → 573-683).
- **Verdict**: **partially correct** — the observable, the linearisation and the differencing
  algebra are right; the *weighting and the covariance of the 3-parameter solve* are not.
- **Sources**:
  - Naqvi, N. A., et al. (2013). *Design and simulation of GNSS phase based attitude determination of
    spacecraft: LAMBDA and EKF* (AIAA 2013-4832). (Paper/Error Calculation/Atmospheric Errors.)
  - Abbas, N. A., et al. (2012). *Design and mathematical modeling of GNSS based attitude
    determination of ICUBE-1*. AIAA. (Same folder.) — "The receiver clock bias is common to the
    single difference for all satellites at each epoch. This term can be eliminated by taking the
    difference between two single difference equations, which is referred to as the double
    difference" (p. 7). [Quote carried forward from round 1; not re-extracted this pass.]
- **Critical analysis**: The Jacobian sign was re-derived: with `Pe = cP + R(θ)(Pk − cP)`,
  `δP_i = δθ×p_i` and `δρ = u'(δθ×p_i) = δθ·(p_i×u)`, so `dρ/dθ = (p_i×u)'` — line 340 is correct,
  and the four-term DD combination matches `ddObs` term for term ✓. Using the centre-of-mass moment
  arm `Pe(:,i)−cP` while predicting at the antenna `Ae` is deliberate and documented at `:314-317`
  (the antenna offset comes from the asset's own Earth-referenced attitude and therefore does not
  turn with the formation-rotation parameter) — defensible ✓.
  **NEW — LF-5: the normal equations are unweighted over correlated observations.**
  `Nmat = Jth.'*Jth` (`:349`) contains no `R_DD⁻¹`. Double differences built against one reference
  satellite and one reference tower are correlated *by construction*: with equal raw variance σ²,
  `var(DD) = 4σ²` and `cov(DD_a, DD_b) = σ²` for two DDs sharing both references, i.e. correlation
  0.25. `Cth = s2·inv(Nmat)` with `s2 = sse/(nObs−3)` is the ordinary-least-squares variance
  estimate, which is *not* the correct covariance for correlated errors (the correct object is the
  sandwich `(J'J)⁻¹ J'R_DD J (J'J)⁻¹`). Consequence: `nObs` counts `(T−1)(N−1)` DDs per epoch as
  independent when the effective count is a few times smaller, so σ_θ is optimistic by roughly
  1.4–2×. The *sister* class does this correctly: `JointGeometrySolver.ddWhitener_:711-739` builds
  `R_DD = D·R·D'` and whitens by its Cholesky factor. The 3-parameter stage is documented as
  "kept because it is the thing that MEASURED the shape-leakage coefficient" (`:287-288`), which
  mitigates but does not remove the issue, because σ_θ still gates two decisions:
  the leak guard `predLeak ≤ sigTheta` (`:439`) becomes **harder** to pass (conservative) while the
  SNR guard `|θ|/σ ≥ 3` (`:483-488`) becomes **easier** to pass (anti-conservative). The two guards
  therefore move in opposite directions under the same bias — an unstable configuration for a test
  that decides whether ~0.5 m of geometry correction is applied.
  **NEW — LF-6: the significance test is not a Mahalanobis test.**
  `:483` `snrRot = norm(theta)/max(norm(sqrt(abs(diag(Cth)))),realmin)` compares the *norm of θ* to
  the *norm of the three marginal sigmas*. The correct statistic for a 3-vector is `θ'Cth⁻¹θ` against
  χ²₃. With an anisotropic Cth — and `JointGeometrySolver`'s own header at `:62` records that the
  raw rotation block "overstates information by 288x on the weakest axis" — the two can disagree in
  either direction. `JointGeometrySolver` uses the same `minRotationSnr` knob (`:485-487` reads it
  from the joint block first), so the approximation propagates.
  The atmosphere caveat block (`:41-58`) remains exemplary and quantitatively right: 2 km at GEO is
  `2000/36e6 = 5.6e-5 rad = 11.5 arcsec` ✓, and calling the per-asset independent atmosphere a
  modelling artefact rather than physics is correct.

## 10. Split covariance intersection (SplitCovarianceIntersectionBound + network)

- **Code**: `+revgnss/SplitCovarianceIntersectionBound.m:14-48` (claim), `:29-31` (formula),
  `:78-116` (five-entry allowlist), `:114-116`
  `ObservablesWithDemonstratedConservativeBound = {'coherentTwoWayCodeRange','firstOrderReciprocalClockTransfer','oneWayCode','oneWayDoppler','fourTimestampClockDifference'}`,
  `:147-180` (`ownerPosteriorAssumingIndependence`, attestation-gated),
  `:191-270` (`selectGainAndWeights`), `:272-302` (`waterFillWeights`),
  `:304-326` (`evaluateBound`), `:328-345` (`requireLoewnerDominates`),
  `:396-429` (`assembleYoungTerms_`), `:490-494` (the flag must be literally `true`).
  `+revgnss/DistributedCovarianceNetwork.m:25-30` (no fleet-level claim), `:780-815`
  (`centralReferenceEquivalenceClaim`, computed from counters).
  `+revgnss/PairwiseCrossCovarianceBlock.m:8-12` (P_ji never stored; never symmetrized).
- **Status vs doc**: **STILL-VALID**; the doc's "401-418" for the R_ind PD check is now **:401-418**
  ✓ exactly, and "365-392 describeDerivation" is now `:365-...` ✓. Only "785-827" for the network's
  claim function → **:780-815** (**DRIFTED**).
- **Verdict**: **correct**.
- **Sources**: Julier & Uhlmann (1997, 2001); Li, H., Nashashibi, F., & Yang, M. (2013). Split
  covariance intersection filter. *IEEE T-ITS, 14*(4), 1860–1871. [all EXTERNAL — no verbatim
  quotes obtained this pass].
- **Critical analysis**: **Double-count question (c) — answered NO, and structurally so.**
  Traced end to end: `assembleYoungTerms_:401-408` builds
  `Rind = Rtot − Σ_g W_g − Σ_k U_k` **by subtraction only**, then `:420-428` assembles
  `terms = {P_i, H_j P_j H_j', W_1..W_G, U_1..U_P}`. `evaluateBound:315-323` then sums
  `K·Rind·K'` with coefficient **1** and every `terms(idx)` with coefficient `1/ω_idx`. No matrix
  appears in both places: the `W_g` are inside the ω-inflated list and have been *removed* from
  `Rind`. The consistency of that accounting is enforced, not assumed: `:412-418` errors when
  `min(eig(Rind)) <= tol`, i.e. when the declared common sources over-subtract. And `:490-494`
  requires `totalMeasurementCovarianceIncludesDeclaredCommonSources` to be **literally true**, which
  closes the mirror failure (declaring a common source that was never inside `Rtot`, which would
  under-subtract). The water-filling weights (`:288-296`, `ω_l = max(lb, √(a_l/λ))` with λ found by
  bisection on a monotone `g`) minimise `Σ a_l/ω_l` on the bounded simplex — a genuine KKT solution,
  and validity is correctly decoupled from its convergence (`:194-196`).
  One residual conservatism, not a defect: if a remote's prior error and a declared common source are
  physically the same error, it appears in both `H_j P_j H_j'` and `W_g` — that *over*-counts and the
  bound stays valid, only looser.

## 11. ISL timing: product-interval clock error charged as white R — **ESCALATED**

- **Code**: `+revgnss/ISLMeasurementBuilder.m:234` (code row)
  `Rii = info.codeSigma_m^2 + sigPos2 + info.product.sigmaClock_m^2;`
  `:260` (Doppler) `Rii = info.dopplerSigma_mps^2 + sigVel2 + info.product.sigmaClockDrift_mps^2;`
  `:319` (carrier) `Rc = info.carrierSigma_m^2 + sigPos2c + info.product.sigmaClock_m^2;`
  against `productInterval_:637-647` `idx = floor(t_s/dt)` with `dt = updateInterval_s` (default 300)
  and `productBias_:649-662` drawing from `stream_(seed, txi, 555, intervalIdx)`. R is assembled by
  `append_:728-731` `R = blkdiag(R, ri)`.
  In-code justification `:637-641`: *"its error is piecewise-constant (correlated within an interval,
  independent across intervals) -> it averages down over the run and the white-R model stays
  consistent."*
- **Status vs doc**: verdict **STILL-VALID** (the defect is unfixed); line numbers **DRIFTED**
  (216-217 → **234**, 587-612 → **637-662**, 575-583 → **631-633**, 588-592 → **637-641**);
  and the doc's two mitigating claims are **NOW-WRONG or inverted** (below).
- **Verdict**: **flawed** — confirmed defect, now with a live consumer.
- **Sources**: Brown, R. G., & Hwang, P. Y. C. (2012). *Introduction to random signals and applied
  Kalman filtering* (4th ed.). Wiley. [EXTERNAL — no verbatim quote obtained this pass]. Time-
  correlated measurement error must be state-augmented or R inflated by the effective correlation
  length.
- **Critical analysis**:
  **(i) The doc's claim that the rule "is enforced everywhere else" is NOW-WRONG.** The doc cited
  `SwarmRelativeSolver.islNoise_ (883-918)` and `clockNoise_ (1180-1202)` as inflating R by
  `nCorr = min(τ/dt, cap)`. At HEAD those functions are `:1057-1103` and `:1365-1390`, and both
  carry an explicit removal note: *"This previously carried an extra nCorr = min(tau/dt, nCorrCap) =
  60 factor on the bias term … That justification does not apply to this consumer: solveEpoch_ is a
  PER-EPOCH weighted least squares … inflating it 60x simply overstates R by ~7.4x"* (`:1066-1073`).
  The removal landed in `e6d2085` (2026-08-06) — *before* `3489075`, so the doc was already stale on
  this point when written. **The removal is itself correct**: I re-checked from both ends. Callee —
  `solveEpoch_` runs inside `for kk = 1:nEp` with no temporal accumulation, so the per-epoch error
  really is `thermal(p,kk) + pairBias(p)` with variance `sP² + sConst² + sRW²` exactly. Caller —
  every reported metric is a *tail RMS of per-epoch errors* (`tailIdx_:1399-1402`), and the one
  temporal-averaging stage, `arcAverage_:491-598`, is default-off (`:524-527`) and reports no formal
  covariance at all, while its own header at `:519-521` states that the per-link bias "is CONSTANT
  over the arc and survives untouched". So the swarm layer is now correct and the *only* surviving
  violation is the one-way ISL builder. But the doc's rhetorical support for the finding is gone.
  **(ii) The doc's mitigation "the product is disabled by default (σ = 0)" is true but its meaning is
  inverted.** With `product.enable = false` the builder does not merely zero a nuisance variance — it
  makes `productBias_` return identically zero (`:656`), so `btxProd` collapses to `btxTruth`
  (`:191`) and `rTxProd` to `rTxTruth` (`:189`), and `h` at `:233` is handed **the neighbour's true
  position and true clock**. The two states are not "defect present / defect absent"; they are
  "white-R defect" versus "truth leak". `config/ladder/ISL/isl016_carrierFloatAmbiguity.json` is the
  second case and says so in its own `_id`; `isl017` is the first.
  **(iii) Size, at the rung the repo nominates for quotation.** `isl017` sets `sigmaPos_m = 0.03`,
  `sigmaClock_m = 0.02`, `updateInterval_s = 300`, with `dt = 1 s` and a 3600 s arc. The code row's
  R is `0.015² + 0.03² + 0.02² = 1.525e−3 m²`, of which the *piecewise-constant* part is
  `1.3e−3 m²`, i.e. **85 % of the charged variance is not white**. Over the arc the filter is told it
  has 3600 independent samples of that component and has **12**; the implied information is up to
  ×300 too large, i.e. σ optimistic by up to **√300 = 17.3×** on that direction.
  Commit `6077d49` reports `isl017` at "0.095183 m RMS absolute, sigma 0.005895, **16.1x**". The
  proximity of the measured 16.1× to √300 = 17.3× is a strong, testable indication that the missing
  `nCorr` inflation is the dominant term in that rung's overconfidence. Stated as a prediction, not
  a proof: inflating the two product terms by `nCorr = updateInterval_s/dt` should collapse the
  16.1× toward ~1.
  Also **STILL-VALID** in this area and re-checked: the one-way light-time/Sagnac term
  `geometry_:555-584` (`rho += (u'·(v_tx + ω×r_tx))·(rho/c)`, default off) and the two-way
  reciprocity cancellation `twoWayLightTime_:1028-1055`; `OneWayRangeRateModel.compute:39-67`
  (`rhoDot = u'v_rx + ω_e(u_yΔx − u_xΔy)`) — re-derived: `u'(ω×Δ) = −ω u_x Δy + ω u_y Δx` ✓
  identical to the ECI form `u'(v_rx,eci − v_tx,eci)`.

## 12. **NEW** — the relativistic term on the ISL code and Doppler rows (commit `9a52cfc`)

- **Code**: `+revgnss/ISLMeasurementBuilder.m:179-182`
  ```
  relClkBias_m   = models.clocks.RelativisticClockCorrection.bias_m(cfg, t_s);
  relClkRate_mps = models.clocks.RelativisticClockCorrection.rate_mps(cfg);
  info.relClockBias_m = relClkBias_m;  info.relClockRate_mps = relClkRate_mps;
  ```
  applied at **five** sites: `:233` (code, `build`), `:259` (Doppler, `build`), `:318` (carrier,
  `build` — the only one that already had it), `:441` / `:447` / `:455` (`predictEkfRows`, all three
  legacy branches). Correction source: `+models/+clocks/RelativisticClockCorrection.m:65-77`
  (`b_m = c·y·t_s`, `bdot = c·y`), `y` from `+revgnss/Relativity.clockFracFreq:27-44`:
  `grav = (GM/c²)(1/Re − 1/r); sr = −v²/(2c²); y = grav + sr + vg²/(2c²)`.
- **Status vs doc**: **NEW** (post-dates the doc entirely).
- **Verdict**: **correct** — the term is carried, applied exactly once, with the right sign and size,
  and the convention is verified consistent with the ground rows.
- **Sources**: IAU/IERS relativistic clock-rate convention; the code's own derivation. The magnitude
  was re-derived independently from first principles this pass (below). [EXTERNAL for the convention;
  no in-`Paper/` source, and no verbatim quote obtained.]
- **Critical analysis**:
  **Applied once — verified from both ends.** *Callee side*: `ISLMeasurementBuilder` adds
  `relClkBias_m` to `x(b_rx)` only in the **legacy broadcast-product** branches, and adds nothing in
  the estimated-secondary branches (`:230`, `:256`, `:294`). *Caller side*: the state's domain is
  fixed by the ground row — `+models/+measurements/CodeMeasurementBuilder.m:73-74`
  `b_rx_relModel_m = models.clocks.RelativisticClockCorrection.bias_m(cfg, t_s); b_rx_est = x_est(blk.b) + b_rx_relModel_m;`
  — so `x(b_rx)` is *residual-domain* (truth minus the modelled ramp), and the ISL legacy branch
  rebuilding the full clock as `x(b_rx) + relClkBias_m` is the same convention, not a second
  application. `CarrierMeasurementBuilder.m:73` and `DopplerMeasurementBuilder.m:139` do the same.
  **No double count against the truth ramp.** In `z` (`:222`, `:251`, `:289`) the term cancels
  exactly between rx and tx because every space asset inherits one `relativisticFracFreq`
  (`ConfigFactory.m:1982`), so the ISL sat–sat difference needs no correction on the measurement
  side; the correction appears **only** in `h`, where the residual-domain rx state is differenced
  against a full-truth tx clock. That is exactly the asymmetry the header at `:167-178` describes.
  **Size and sign re-derived from scratch.** `GM = 3.986004418e14`, `Re = 6378137`,
  `r = 6378137 + 35786000 = 42164137`:
  `grav = (GM/c²)(1/Re − 1/r) = 4.43503e−3 × 1.330687e−7 = +5.90162e−10`;
  `v² = GM/r = 9.45360e6` (v = 3074.7 m/s, matching the header's "~3.07 km/s"),
  `sr = −5.25896e−11`; `vg = Ω·Re = 465.10 m/s`, `vg²/(2c²) = +1.20344e−12`.
  `y = +5.38836e−10` → the header's "+5.39e-10" ✓ to 3 s.f.;
  `c·y = 0.161533 m/s` → the commit's "0.161521 m/s" ✓ to 5 s.f. (my constants rounded);
  over 3600 s, `581.5 m` → the commit's "581 m" and
  `run_multi_islcarrier_regression.m:126`'s "581.4741 m" ✓.
  Sign: the GEO clock runs **fast**, so `y > 0`, so the correction **adds** to the rx clock — the
  code adds it ✓, and the commit's before/after NIS (735,109 → 95.35 against ~105 rows/epoch) is the
  behaviour of removing a linear ramp, not of adding one.
  **Limit**: the `(GM/c²)(1/Re − 1/r)` form uses a *spherical* Earth potential rather than the
  geoid potential `W₀`. Computing `y` the IERS way (`W₀/c² − 3GM/(2ac²)`, `W₀ = 6.26368560e7 m²/s²`)
  gives `5.3915e−10` against the code's `5.3884e−10` — a 0.06 % difference, ~0.1 m over a 3600 s arc.
  This is invisible in every shipped run because truth and model share the function (LF-10).

## 13. **NEW** — `tests/regression/run_distributed_fleet_regression.m` (commit `507c1f0`)

- **Code**: `tests/regression/run_distributed_fleet_regression.m:80-96` (two configurations plus their
  delta), `:99-135` (`fleetConfig_`: `mode='fast'`, `estimateMode='off'`, `keepIslInPerAssetEkf=false`,
  `distributedEstimator.enable=true`; configuration B adds the sanctioned tuple
  `coherentTwoWayCodeRange` / `ownerPolicy='initiator'` / `correlationPolicy='splitCovarianceIntersection'`
  with `isl.twoWay.range.useInEKF = false`), `:138-178` (digest), `:181-229` (`diff_`, PASS iff
  `max|delta| = 0` on 20 numeric fields and `isequal` on 10 text fields).
- **Status vs doc**: **NEW**.
- **Verdict**: **correct for what it is, and it is narrower than it reads.**
- **Sources**: n/a (a fixture, not physics).
- **Critical analysis**: **What it pins.** (a) That the coordinator's protocol machinery is a no-op
  when `linkUpdate` is disabled — configuration A's per-asset states must equal N independent local
  EKFs bit-for-bit. (b) That the split-CI owner update is bit-reproducible. (c) That the A→B delta
  is frozen, so a change moving both configurations equally still trips the gate. (d) Crucially,
  `linkUpdateMovedState` (`:95`) is a frozen numeric field, so a regression that made the sanctioned
  update *inert* would flip 1 → 0 and FAIL — this fixture cannot silently become vacuous, which is
  the failure mode most goldens of this kind have.
  **What it does NOT pin.** It never checks Loewner conservativeness of the resulting P against a
  reference, never scores against flown truth, and never asserts an accuracy threshold. It is a
  **determinism contract**, and the commit message says so. The 120 s arc against a ~1145 m initial
  error is deep in the transient, so the accompanying numbers (owner posErr 108.6450 → 89.4804 m)
  are not a performance claim. The most scientifically important observation in that commit —
  *"the covariance LOOSENS on 27 of 27 owner states and tightens on none"* — is the correct and
  expected behaviour of split CI (conservativeness is guaranteed, benefit is not) and deserves to be
  stated in the paper in exactly those terms.
  One line worth quoting into the methods section, `:127-129`: `useInEKF` is deliberately left
  **false** because "Setting it true would feed the same range into the owner's own onboard filter as
  well, double-counting it and making the A/B delta meaningless" — an explicit, correct
  double-count guard.

## 14. **NEW** — the `isl016` / `isl017` carrier ladder pair (commit `6077d49`)

- **Code**: `config/ladder/ISL/isl016_carrierFloatAmbiguity.json`,
  `config/ladder/ISL/isl017_carrierHonestProduct.json`,
  `tests/regression/run_multi_islcarrier_regression.m`. Both extend
  `config/golden_baseline_multi.json` (which sets `realism.grade = true`), set
  `keepIslInPerAssetEkf = true`, `isl.code.{enable,useInEKF} = true, sigma_m = 0.015`,
  `isl.carrier.{enable,useInEKF} = true, sigma_m = 0.002, frequency_Hz = 26e9`,
  `carrier.ambiguity.{enable=true, nSignals=1, processNoiseSigma_m_per_sqrt_s = 0.01}`.
  `isl017` adds `product.{enable=true, sigmaPos_m=0.03, sigmaClock_m=0.02, updateInterval_s=300}`
  and drops `multiAsset.twoWayISL.sigma_m` 0.05 → 0.015.
- **Status vs doc**: **NEW**.
- **Verdict**: **the pair's design is correct and its declared numbers are the right ones to quote —
  with two caveats the rungs themselves name and one they do not.**
- **Sources**: n/a (configuration).
- **Critical analysis**:
  **Config resolution order verified** (this was the obvious place for an order-of-operations trap
  and there is none). `config/resolveSimulationConfig.m:44-52`: the realism profile is applied
  **first** (`preResolutionConfig = realismGradeConfig(profileInput)`), then the flattened `_extends`
  overlay is `deepMergeConfig`'d on top — *"Scenario-owned values are applied after the profile and
  therefore win"* (`:50`). So `isl016`'s `processNoiseSigma_m_per_sqrt_s = 1e-2` correctly overrides
  `config/internal/realismGradeConfig.m:180`'s `= 0`, and `sigma_m = 0.002` overrides realism's 0.20.
  ✓ No stomping.
  **The ambiguity process-noise finding is real and important.** With `Q_B = 0` the float ambiguity
  is exactly constant, its covariance shrinks monotonically, its gain follows, and the state freezes:
  the commit measures "the float sat 10.42 cycles from truth while reporting 0.2434 cycles, a
  43-sigma lie" at 26 GHz. That is the canonical failure of an over-tight random-walk-free bias
  state, and `1e-2 m/√s` fixes it (bias/σ 42.8 → 0.7). **However**, `realismGradeConfig.m:178-180`
  still argues the opposite in a comment: *"0 = constant within an arc, which is what a true
  ambiguity IS. Any random walk here would let the state absorb real range error and flatter the
  result."* Both statements are defensible and they conflict; the repository now ships the
  realism default at 0 and the ladder rungs at 1e-2. That contradiction should be resolved before
  either number is cited.
  **Uncaveated exposure — DC-2 below.** Both rungs build a code row *and* a carrier row per link per
  epoch, each charging the *same realisation* of the product error, with R assembled by `blkdiag`.
  Neither rung mentions it.
  **Correctly caveated.** `isl016`'s truth leak, the `keepIslInPerAssetEkf` re-consumption, and the
  status of 15 mm / 2 mm as terminal *design assumptions* rather than derived values are all stated
  in the JSON `_id`/`_delta` blocks. The 27× oracle-vs-honest gap (0.003585 → 0.095183 m at 3600 s;
  0.003585 → 0.130883 m at 600 s per the harness header) is precisely the kind of number this
  project should be publishing.

## 15. **NEW** — OneWayInterSatelliteRangingModel (the shared one-way kernel)

- **Code**: `+revgnss/OneWayInterSatelliteRangingModel.m:37-67` —
  `pr = position + R_body2ecef·offset; delta = pr − pt; range = norm(delta); u = delta/range;`
  `rangeRate = u'(v_r − v_t);` `value = range + b_r − b_t` (code) or `rangeRate + ḃ_r − ḃ_t` (Doppler).
  `:70-86` `geometryPartials`: `dRange/dr_r = u'`, `dRangeRate/dr_r = Δv'(I − uu')/ρ`,
  `dRangeRate/dv_r = u'`. Constants at `:16-22`
  (`GeometryKernelIdentifier = 'instantaneousCoordinateEpochGeometry'`,
  `LightTimeCorrectionSupported = false`, `LeverArmRateTermSupported = false`).
- **Status vs doc**: **NEW** (not covered).
- **Verdict**: **correct as written, but structurally unable to expose modelling error.**
- **Sources**: standard range/range-rate geometry; frame-invariance argument re-derived below.
  [EXTERNAL, textbook-level; no verbatim quote obtained.]
- **Critical analysis**: The frame-invariance claim at `:9-14` is **exactly true** and I re-derived
  it: `Δv_eci = Δv_ecef + ω×Δ`, and `u'(ω×Δ) = u'(ω×ρu) = ρ·ω·(u×u) = 0`, so `u'Δv` is identical in
  ECEF and ECI ✓. `range` is trivially rotation-invariant ✓. The partials are correct
  (`d/dr (u'Δv) = Δv'(I−uu')/ρ` ✓).
  **Inverse-crime limit (LF-11).** The header states the design intent plainly: this kernel sits
  between the truth-reading `OneWayInterSatelliteObservationBuilder` and the truth-free
  `OneWayCodeRangeLinkUpdateAdapter`, "so that no physics equation lives in an adapter file and
  truth and model share one kernel by construction". That guarantees H↔h consistency — genuinely
  valuable — but it also guarantees that **every omitted physical effect cancels identically**.
  Concretely: `LightTimeCorrectionSupported = false` drops the one-way retarded-time term, which
  for a GEO transmitter is `(u·(ω×r_tx))·(ρ/c) ≈ 3070 × (1000/3e8) ≈ 1.0 cm` on a 1 km link —
  the same "~1 cm/km" `ISLMeasurementBuilder.geometry_:560-566` gates. Because truth and model both
  omit it, the residual is bit-zero and the split-CI adapters' `oneWayCode`/`oneWayDoppler`
  admission tests cannot detect a light-time modelling failure. Declared, but a hard limit on what
  those two allowlist entries prove.

## 16. Helix formation from Clohessy–Wiltshire dynamics

- **Code**: `+revgnss/SwarmFormation.m:17-19` (contract), `:84-99` (`helixOffsetHill`:
  `dr = [(ρ/2)sinφ; ρcosφ; crossAmp·ρ·sinφ]`, `dv = [(ρ/2)n·cosφ; −ρn·sinφ; crossAmp·ρn·cosφ]`),
  `:13-15` and `:184-189` (Hill frame `R = r/|r|`, `W = (r×v)/|r×v|`, `S = W×R`),
  `:147-148` and `:198-199` (`dv_eci = A*(dv_h + cross(omega, dr_h))`),
  `:37-82` (`ringLayout_`, `multiRingHelix`), `:101-118` (`crossAmp_`).
- **Status vs doc**: **STILL-VALID** (every cited line unchanged).
- **Verdict**: **correct.**
- **Sources**: Clohessy, W. H., & Wiltshire, R. S. (1960). Terminal guidance system for satellite
  rendezvous. *Journal of the Aerospace Sciences, 27*(9), 653–658. [EXTERNAL — no verbatim quote
  obtained this pass].
- **Critical analysis**: All four algebraic checks re-run. No-drift condition `ẏ(0) = −2n·x(0)`:
  LHS `= −ρn sinφ`, RHS `= −2n(ρ/2)sinφ = −ρn sinφ` ✓ exact. 2:1 in-plane ellipse (radial ρ/2,
  along-track ρ) ✓. Projected circle `y² + z² = ρ²` holds iff `crossAmp = 1` ✓ (and the class says
  so). Velocities are the exact time derivatives of the positions at `t = 0` with argument `nt+φ` ✓.
  Cross-track: CW gives `z̈ + n²z = 0`, so `z = A·sin(nt+ψ)` is a valid bounded solution independent
  of the in-plane pair ✓ — so `crossTrackSpread ≠ 0` fans members onto *distinct but still valid*
  bounded relative orbits, exactly as `:88-94` claims. The planar-degeneracy point (`z = 2x` for
  every member at `crossAmp = 1` ⇒ instantaneously planar ⇒ rank-2 LOS matrix) is restated in
  `config/golden_baseline_multi.json:25` with measured singular values (1.2566, 1.1920, **0.0000**)
  — a properly evidenced statement.

## 17. Guard determinism (GuardDecision)

- **Code**: `+revgnss/GuardDecision.m:1-40` — three outcomes, 10 % relative dead-band default,
  `'indeterminate'` is **not** a pass, margin always reported.
- **Status vs doc**: **STILL-VALID.**
- **Verdict**: **correct**, and the right practice for any threshold that gates a published number.
- **Critical analysis**: unchanged. Consumers verified live at
  `GroundDifferencedRotationSolver.m:435-442` (leak) and `:488` (SNR).

---

## Double-count candidates

**DC-1 — Piecewise-constant broadcast-product error charged as per-epoch white R. SEVERITY: HIGH.**
- Location A: `+revgnss/ISLMeasurementBuilder.m:234` (code), `:260` (Doppler), `:319` (carrier) —
  `Rii = codeSigma² + sigmaPos_m² + sigmaClock_m²` added **every epoch**.
- Location B: `+revgnss/ISLMeasurementBuilder.m:637-647` (`productInterval_`, `idx = floor(t_s/dt)`,
  `dt = updateInterval_s`, default 300 s) and `:649-662` (`productBias_`, one draw per interval).
- Mechanism: an error that is *constant within a 300 s interval* is declared white, so the filter
  believes it averages as `1/√n_epochs` when it averages as `1/√n_intervals`. This is not literally
  "the same variance added twice" but the same information counted `n_epochs/n_intervals` times.
- Size: at `dt = 1 s`, information over-count up to **×300** on that component; σ optimistic up to
  **√300 = 17.3×**. In `isl017` the affected part is `0.03² + 0.02² = 1.3e−3` of a total charged
  `1.525e−3 m²`, i.e. **85 % of the row variance**. Measured error/σ ratio in that rung: **16.1×**.
- Severity: HIGH. Live in the rung the repository nominates for citation. Fix is mechanical:
  multiply the two product terms by `nCorr = updateInterval_s/dt` (capped), or add a per-interval
  bias state. The identical inflation was *removed* from `SwarmRelativeSolver` (`e6d2085`) for a
  reason that does not apply here: `ReverseGNSSSimulation` is a *sequential* filter, not a per-epoch
  WLS.

**DC-2 — The same product realisation charged independently to the code row and the carrier row.
SEVERITY: MEDIUM-HIGH.**
- Location A: `+revgnss/ISLMeasurementBuilder.m:234` (`Rii` includes `sigPos2 + sigmaClock_m²`).
- Location B: `+revgnss/ISLMeasurementBuilder.m:319` (`Rc` includes `sigPos2c + sigmaClock_m²`).
- Mechanism: both rows for a given link at a given epoch consume the **same** `pb` from
  `productBias_(cfg, info.product, txi, info.productIntervalIdx)` (drawn once at `:187`), so their
  errors are perfectly correlated in the product component (`+u'·pb.pos + pb.clk` in each residual).
  R is nonetheless block-diagonal: `append_:730` `R = blkdiag(R, ri)`. The filter therefore treats
  two identical realisations as two independent measurements of that error.
- Size: information over-count **×2** on the product direction ⇒ σ optimistic **×√2** on top of
  DC-1; combined worst case **×600 information, ×24.5 in σ**. Applies to `isl016`/`isl017`, which
  enable code and carrier together.
- Severity: MEDIUM-HIGH. The correct fix is an off-diagonal R block of `sigPos2 + sigmaClock_m²`
  between the code and carrier rows of the same link, which `blkdiag` structurally cannot express.

**DC-3 — `keepIslInPerAssetEkf = true`: the same physical crosslink consumed by the leaf EKF and
re-consumed by the relative layer. SEVERITY: MEDIUM (declared, but the class header denies it).**
- Location A: `+revgnss/ISLMeasurementBuilder.build` rows entering each leaf EKF
  (`+revgnss/ReverseGNSSSimulation.m:636-641`), with noise drawn from
  `drawNoise_:664-669` (stream keyed on `epochIdx`).
- Location B: `+revgnss/SwarmRelativeSolver.rangeObservables_:1190-1210` re-synthesising the same
  link's range from truth with a *separate* noise realisation
  (`thermal(p,:) = pairSigma(p)*randn(rs, 1, nEp)` from the `baseSeed+7000+node` stream, `:129-133`).
- Mechanism: one physical terminal produces one measurement per epoch. Here it produces two, with
  independent noise, and both are used. The relative layer's formal covariance therefore double-counts
  the information already in the leaf posteriors it is priored on.
- Size: the repository does not measure it directly; `isl009` exists specifically to. The relative
  layer's `formalShapeSigma_m` is optimistic by up to √2 in the crosslink-constrained directions
  before any other effect.
- Severity: MEDIUM. It is stated in `isl009`, `isl016` and `isl017` (`_stillInheritsTheDoubleCount`)
  and the goldens keep it false. But `SwarmRelativeSolver.m:20-21` asserts *"NO double-count — ground
  pseudoranges and ISL use disjoint measurements"* **unconditionally**, and no code path checks
  `keepIslInPerAssetEkf`. Downgrade that header to a conditional, or add a guard.

**DC-4 — Ground pseudoranges counted twice across the pipeline: inside the per-asset EKFs, and again
as the re-synthesised DD observable. SEVERITY: MEDIUM.**
- Location A: the per-asset EKF absolute solutions → `rel.solvedPos`, i.e. the geometry both rotation
  solvers start from (`GroundDifferencedRotationSolver.m:310`, `JointGeometrySolver.solve` on
  `rel.solvedPos`).
- Location B: `+revgnss/GroundDifferencedRotationSolver.buildObservable:103-...`, which rebuilds the
  tower→satellite observable from recorded truth (declared at `:32-40`), and
  `solveRotationOnly_:336-337` / `JointGeometrySolver.buildEpochRows_:689-709` which then form DDs
  from it.
- Mechanism: those are the **same physical ground ranges at the same epochs** that already determined
  each satellite's absolute position — and hence the formation's orientation — inside the EKF. The
  joint solve gives θ **no prior at all** (`JointGeometrySolver.m:16-17`, deliberately, because ISL
  supplies zero rotation information) while the starting geometry already encodes a ground-derived
  orientation. The ground data is therefore used at two levels with no accounting between them.
- Size: not measured anywhere. Bounded above by the ratio of the per-asset EKF's orientation
  information to the DD's, which `GroundDifferencedRotationSolver.m:10-12` puts at
  `σ_θ ≈ σ_abs/(R√N) ≈ 0.028°` for the raw EKF at R = 1083 m, N = 20 — the same order as the
  rotations being estimated, so this is not negligible.
- Severity: MEDIUM. It does not make the estimate wrong (θ's estimate is a residual correction), but
  it makes `thetaSigma_rad` and the SNR guard optimistic, and it is the reason a paper cannot call
  the DD result an independent measurement of orientation.

**DC-5 — CANDIDATE, unresolved: product clock error charged in the carrier row's R while the float
ambiguity state can absorb it. SEVERITY: LOW-MEDIUM, needs an A/B.**
- Location A: `+revgnss/ISLMeasurementBuilder.m:319` `Rc += info.product.sigmaClock_m²`.
- Location B: the ISL float ambiguity state `x(ambIdxC)` (`:321`, `dh/dB = +1` at `:345`) driven by
  `q_isl_sigma = cfg.measurements.isl.carrier.ambiguity.processNoiseSigma_m_per_sqrt_s`
  (`+filter/ReverseGNSSEKF.m:1546`), set to `1e-2 m/√s` in `isl016`/`isl017`.
- Mechanism: over one 300 s product interval the ambiguity's process noise admits
  `σ_B = 1e-2·√300 = 0.173 m` of random walk, far more than the 0.02 m product clock step. The
  ambiguity will therefore track the piecewise-constant product clock error almost completely, so the
  carrier row carries essentially none of it into the residual — while R is charged for all of it.
  If so, this is the mirror image of DC-1: over-charged on the carrier row, under-charged on the code
  row.
- Size: unknown; the affected term is `0.02² = 4e−4 m²` against a charged `Rc = 0.002² + 0.03² + 0.02²
  = 1.304e−3 m²`, i.e. up to 31 % of the carrier row's variance.
- Severity: LOW-MEDIUM. Discriminator: run `isl017` with `sigmaClock_m` removed from `Rc` only and
  compare the carrier row's NIS. **Do not report this as confirmed without that measurement.**

**Confirmed NOT double counts (checked and cleared this pass):**
- **(a) Two-way composite `0.5·√(σf²+σr²+2ρσfσr)`** — thermal only; `ρ` defaults to 0
  (`masterConfig.m:2768`); the calibration variance is charged in R **only** when the residual-bias
  state is absent (`TwoWayISLMeasurementBuilder.m:573-575`). Clean.
- **(b) JointGeometrySolver shape prior** — the prior is the ISL-only normal matrix
  (`SwarmRelativeSolver.m:969`), which *excludes* the ground/EKF prior already in `solvedPos`, so the
  ISL information appears once and the prior is conservative, not doubled. (The *ground* re-use is
  DC-4, a different thing.)
- **(c) Split covariance intersection** — `Rind = Rtot − ΣW_g − ΣU_k` by subtraction only
  (`SplitCovarianceIntersectionBound.m:401-408`), then `evaluateBound:315-323` sums `K·Rind·K'` once
  at coefficient 1 and each `W_g` once at `1/ω`. Nothing is in both. Both directions of mis-declaration
  are trapped: over-subtraction by the PD check at `:412-418`, under-subtraction by the
  `totalMeasurementCovarianceIncludesDeclaredCommonSources` "literally true" requirement at `:490-494`.
- **Beamforming triple mean-removal** (`BeamformingPhasorDiagnostics.m:216/221/223`) — idempotent, no
  effect.

---

## Logical flaws

**LF-1 — `config/masterConfig.m:749-785`: the entire multi-asset ISL preset is unreachable dead code.
SEVERITY: HIGH.**
`cfg.scenario.nSpaceAssets = 1` at `:44`; the preset gate at `:749` is
`if cfg.scenario.nSpaceAssets <= 1`; nothing between line 44 and line 749 assigns `nSpaceAssets`
(grep over the whole file: `:41` comment, `:44`, `:749`, `:1036` comment, `:1129` inside
`i_baseDefaults`), and `masterConfig`'s only argument is the string `mode`. `resolveSimulationConfig.m:26`
calls `masterConfig()` **before** merging any JSON, so a scenario's `nSpaceAssets = 6` can never reach
that branch. `ConfigFactory.applyMultiAssetMode` (called at `:1038`, re-run by `finalizeConfig`) does
not touch ISL at all — verified. **Therefore every default in `:755-785` never executes**:
`isl.enable = true`, `code.useInEKF = true`, `code.sigma_m = 0.3`, `doppler.sigma_mps = 0.05`,
`carrier.enable = true`, and — most consequentially — `product.enable = true` with
`sigmaPos_m = 0.03` / `sigmaClock_m = 0.02`. The effective defaults are always `i_baseDefaults`':
`isl.enable = false`, `code.sigma_m = 0.5`, `doppler.sigma_mps = 0.02`, `carrier.sigma_m = 0.20`,
**`product.enable = false`** (`:2666`). Consequence: the comment at `:747-748` advertising
"product-aided, honest" ISL describes behaviour that has never run, and the shipped default for any
ISL-enabled scenario is the **truth-leak** path (`h` reads the neighbour's true position and clock).

**LF-1b — corollary, independently verified: the gated ISL light-time correction is unreachable from
any scenario file. SEVERITY: MEDIUM.**
`cfg.measurements.isl.lightTime.enable` is declared in **exactly one place**,
`config/masterConfig.m:768` — inside the dead branch (repo-wide grep over `config/` and
`+revgnss/ConfigFactory.m` returns that single hit; contrast `isl.transmitters`, which is safely
re-declared at `:2572` in `i_baseDefaults`). Since MATLAB never executes the untaken branch, the
field **does not exist in the resolved config**. Two consequences, both checked:
(i) `ISLMeasurementBuilder.defaultInfo:528` `getBool_(..., false)` walks to the default and returns
`false`, so runtime behaviour is the intended "off" — no crash, no silent wrong answer;
(ii) any scenario JSON writing `measurements.isl.lightTime.enable` hits
`config/internal/deepMergeConfig.m:34-36` `error('deepMergeConfig:unknownConfigPath', ...)` and the
run **hard-fails**. So the ~1 cm/km inter-satellite light-time term — documented at
`ISLMeasurementBuilder.m:560-579`, cross-validated sub-mm against Orekit, and covered by
`tests/test_isl_lighttime.m` and `tests/test_isl_lighttime_carrier.m` — **cannot be switched on from
the ladder at all**. The tests do not catch it because they build the cfg struct in MATLAB and assign
the field directly, bypassing `deepMergeConfig`. This is a clean, falsifiable prediction of LF-1 and
the cheapest way to confirm it: add `"lightTime": {"enable": true}` to any ISL rung and observe the
`unknownConfigPath` error.

**LF-2 — `ISLMeasurementBuilder.predictEkfRows` ignores the estimated secondary orbit and reads truth.
SEVERITY: MEDIUM.**
`build:207-218` chooses `rTxModel = x(orbPosIdx)` when the secondary orbit is an estimated state, and
sets the matching Jacobian column `row(orbPosIdx) = -u'` (`:244`). `predictEkfRows:432-434`
unconditionally uses `tx.r_ecef_m(:) + pb.pos` — there is **no branch on `secondaryOrbitIdx`**. So in
`estimateMode = 'position'` (where `validateConfig:40-47` forces `product.enable = false`, hence
`pb = 0`) the postfit prediction is computed against the neighbour's **true** position while the
prefit and H were computed against its estimated state. The two functions predict the same physical
row two different ways — the exact hazard the file's own carrier comment at `:301-302` warns about,
and the class of defect commit `9a52cfc` fixed for the relativistic term. Blast radius is limited to
the postfit residual series (`ReverseGNSSSimulation.m:1319-1320, 1354`), not the state update, so it
corrupts diagnostics rather than the solution — but a postfit residual that silently uses truth is
exactly the diagnostic one must not trust.

**LF-3 — Two different in-file fallback defaults for one config key. SEVERITY: LOW (latent).**
`ISLMeasurementBuilder.m:124` `getNum_(cfg, {...,'carrier','sigma_m'}, 0.20)` inside `validateConfig`
versus `:495` `getNum_(cfg, {...,'carrier','sigma_m'}, 0.002)` inside `defaultInfo`. If the key were
ever absent, `validateConfig` would see 0.20 and emit no warning while `build` would weight the row at
0.002 — a 100× tighter R than the guard believed it was checking. `masterConfig` always declares the
key, so this is latent, not live. It is also the source of the doc's "default 2 mm" error.

**LF-4 — `OrientationCoherenceBudget` header states a formula the code does not implement.
SEVERITY: MEDIUM (documentation, but the header is exactly what a paper would quote).**
Header `:18-20` and in-body comment `:119-120` state
`mispointing in beamwidths = 2*sigma_abs/(lambda*sqrt(N))`; line `:121` computes
`2*rimDisplacement_m/lam` with no `N` anywhere. The two are different quantities (fitted-tilt
uncertainty from N i.i.d. errors vs deterministic rigid-rotation tilt). Factor `√N` = 2.45 at N = 6.

**LF-5 — `GroundDifferencedRotationSolver` solves correlated double differences with unweighted normal
equations and reports an OLS covariance. SEVERITY: MEDIUM.**
`:349` `Nmat = Jth.'*Jth` (no `R_DD⁻¹`), `:361-363` `Cth = (sse/(nObs-3))·inv(Nmat)`. DDs sharing a
reference satellite and a reference tower have correlation ≈ 0.25 by construction, so `nObs` overstates
the effective sample size and `Cth` is not the correct covariance (the sandwich form is needed). σ_θ
optimistic by roughly 1.4–2×. `JointGeometrySolver.ddWhitener_:711-739` does this correctly with
`R_DD = D·R·D'`, which is the proof that the repository knows the right answer.

**LF-6 — The rotation significance test is a norm-ratio, not a Mahalanobis test. SEVERITY: LOW-MEDIUM.**
`:483` `snrRot = norm(theta)/norm(sqrt(abs(diag(Cth))))`. For a 3-vector the correct statistic is
`θ'Cth⁻¹θ` against χ²₃. With the anisotropy `JointGeometrySolver.m:62` records ("the raw rotation block
overstates information by 288x on the weakest axis") the two can disagree in either direction. This
gates whether a rotation is applied to the published geometry.

**LF-7 — A class-level "NO double-count" claim contradicted by shipped configuration, with no guard.
SEVERITY: MEDIUM.**
`SwarmRelativeSolver.m:20-21` asserts it unconditionally. `config/ladder/ISL/isl009`, `isl016`,
`isl017` all set `keepIslInPerAssetEkf = true`. No code in `SwarmRelativeSolver` reads that key.

**LF-8 — Inert link-budget config presented as active. SEVERITY: LOW.**
`ISLLinkBudget.cfg_:95-96` reads `EIRP_dBW` and `GT_dBK`; nothing consumes them (they cancel in the
anchored ratio). `describe():71` sets `frequencyDependent = strcmp(antennaModel,'fixedGain')`, but
`sigma()` — the default entry point — routes through `cn0Delta_dB:54`, which has no frequency term at
all; only `sigmaAtFrequency:57-65` does. A report reading `describe()` will say the model is
frequency-dependent when the shipped call path is not.

**LF-9 — R charged for errors that are never injected. SEVERITY: LOW (conservative, and inert by
default).** `TwoWayISLMeasurementBuilder.m:572` adds `plasmaResidualSigma² + nonThermalSigma²` to
`observationVariance`, while the truth draw at `:579` uses `thermalSigma` alone. NIS is deflated, not
inflated. Both default to 0.

**LF-10 — The relativistic clock term is an exact inverse crime by default. SEVERITY: LOW (declared).**
`ConfigFactory.m:1982` sets the **truth** `cfg.asset.clock.relativisticFracFreq =
revgnss.Relativity.geoClockFracFreq(alt_)` and `:2004` sets the **model**
`cfg.physics.relativity.clock.model.fracFreq = revgnss.Relativity.geoClockFracFreq(altM_)` — the same
function, the same `cfg.orbit.altitudeMean_m`. The residual is bit-zero unless a scenario explicitly
sets `model.fracFreq`. The class header (`RelativisticClockCorrection.m:12`) says so
("Offset model.fracFreq from the truth value to simulate a residual") and the epistemic argument
(y is a published constant, standing of `cfg.frames.eopModel`) is sound. But no shipped run
demonstrates robustness to a relativistic *modelling* error.

**LF-11 — `OneWayInterSatelliteRangingModel` is an inverse crime by design. SEVERITY: LOW (declared).**
Truth builder and estimator adapter share one kernel (`:3-7`), so `LightTimeCorrectionSupported = false`
and `LeverArmRateTermSupported = false` cancel identically. The omitted one-way light-time term is
~1 cm/km at GEO — the same magnitude `ISLMeasurementBuilder.geometry_` gates. The `oneWayCode` /
`oneWayDoppler` allowlist entries in `SplitCovarianceIntersectionBound` therefore prove Jacobian
correctness and noise independence, **not** geometric-model adequacy.

**LF-12 — `run_distributed_fleet_regression` is a determinism contract that reads like a correctness
contract. SEVERITY: LOW (correctly worded in the file, easily mis-cited).** PASS iff `max|delta| = 0`
on frozen numbers; no Loewner check, no truth scoring, no accuracy threshold; 120 s against a ~1145 m
initial error. Its one genuine anti-vacuity guard is the frozen `linkUpdateMovedState` (`:95`).

**LF-13 — Contradictory guidance on the ISL ambiguity process noise. SEVERITY: LOW.**
`realismGradeConfig.m:178-180` argues `0` is correct ("Any random walk here would let the state absorb
real range error and flatter the result"); `isl016`'s `_whyProcessNoiseOnTheAmbiguity` argues `1e-2`
is necessary ("the float sat 10.42 cycles from truth while REPORTING 0.2434 cycles, a 43-sigma lie").
Both ship. Resolve before citing either.

---

## Limits of this domain

**Link budget / RF.**
1. No absolute ISL σ is *derived* anywhere. `ISLLinkBudget` is **anchored** (`:15-18`): it returns
   exactly `sigma0` at `refDistance_m` and moves only by the distance ratio, and its default
   `model = 'fixed'` returns `sigma0` unchanged. So the repo can claim "σ scales as d" and "a fixed
   aperture cancels the f² path loss"; it cannot claim "the crosslink achieves X mm".
2. `InterSatelliteRFLinkModel` returns **thermal jitter only** — the file says so at `:209-214` and
   `TwoWayISLMeasurementBuilder.m:549-556` calls a thermal-only R a "floorless claim". At 1 km /
   26 GHz / 10.23 MHz it returns **1.9e−5 m**, which is not a ranging accuracy, it is an absence of a
   model for multipath, group-delay drift, quantisation and timing granularity.
3. The 15 mm code and 2 mm carrier figures in `isl016`/`isl017` are **terminal design assumptions**
   against `masterConfig`'s 0.50 m and 0.20 m. The rungs say so; any citation must too.
4. No interference/RFI, rain, gaseous absorption, polarisation-mismatch or pointing-loss model exists
   on the crosslink — `losses_dB` is a single declared scalar. The `Paper/Link BUdget` interference
   papers verify nothing here.
5. The DLL coefficient is declared, not derived (§2), so no waveform-specific claim (BOC vs BPSK,
   discriminator spacing, squaring loss) is supportable.

**Beamforming.**
6. `BeamformingPhasorDiagnostics` reports the gain of **one realisation** of a **solved geometry**;
   `OrientationCoherenceBudget` reports the **expected** gain from a **sigma**. They are not
   interchangeable, and the first can legitimately fall below the `10·log10(1/N)` floor while the
   second cannot. `OrientationCoherenceBudget.m:29-36` states this correctly.
7. Every beamforming number is gated by `coherenceClaimStatus`. When it is not `'claimable'`, the dB
   figures are "a property of this particular run's initial condition and propagation, not a measured
   beamforming capability" (`beamformingPhasor.m:122-125`). No paper sentence may outrun that gate.
8. The near-field classification is real (2D²/λ ≈ 4.4e8 m for D ≈ 5.6 km at S-band, versus a 35 786 km
   slant), but nothing *depends* on it: exact element-to-target ranges are used in both regimes.
   The classification is a statement about why a plane-wave array factor would be wrong, not a result.
9. Coherence claims are bounded by demonstrated hardware: Merlo et al. (2023) achieved **2.26 ps**
   over a 90 cm 5.8 GHz link in a laboratory. Any picosecond-class formation claim must be framed
   against that, not against a simulated σ.

**Swarm / relative solvers.**
10. Ranges are **analytically** blind to rigid rotation *and reflection*. No number of crosslinks, at
    any precision, at any epoch, changes this. Orientation comes only from an Earth-referenced
    observable.
11. `rigidityMargin = nLinks − (3N−6)` is a **necessary** condition only; edge count does not imply
    generic rigidity (Laman/Maxwell plus genericity is required). The code states the count without
    claiming sufficiency — correct, and the paper must not upgrade it.
12. Rotation results are **simulation-internal**: the DD observable is re-synthesised from recorded
    truth because nothing measurement-side survives a federated run
    (`GroundDifferencedRotationSolver.m:32-40`). They are not end-to-end measurement processing.
13. The 3-parameter rotation stage converts arc-correlated deformation into spurious rotation at a
    **measured ~0.30°/m** while its formal σ sits at 0.0115° in every row of the injection ladder.
    Its σ is meaningless under model mis-specification; that is why the class is retained as a
    measuring instrument, not an estimator.
14. `minTurnAngle_deg` defaults to 30° and gates `separable` as a **report flag, not a refusal**
    (`JointGeometrySolver.m:204`). A 3600 s GEO arc turns 15°, where
    `golden_baseline_multi.json:326` records a **9.9×** CRLB penalty for separating rotation from
    shape. Shape/rotation separation on a one-hour arc is not established.
15. `arcAverage_` removes the thermal term and leaves the per-link delay-calibration bias exactly
    where it was (`:519-521`). Once bias dominates, longer windows buy nothing.
16. `swarm_relative_baseline.mat` is **stale** and fails on a clean tree
    (`889dcf6`: `assetFinalPos max|d| = 6.198e+01` with and without the change). No relative-layer
    number may be cited from it.

**Distributed fusion.**
17. No fleet-level joint-covariance conservativeness is claimed, and correctly so
    (`DistributedCovarianceNetwork.m:25-30`, `centralReferenceEquivalenceClaim:780-815`): a collection
    of pairwise-conservative marginals does not imply a conservative joint.
18. Split CI guarantees the bound is **conservative**, never that it is **beneficial**. Measured on
    the golden: accuracy improved 19.16 m while the covariance **loosened on 27 of 27** owner states.
19. `ownerPolicy = 'initiator'` updates **one** endpoint. In a 2-asset fleet exactly one satellite
    benefits; both endpoints need the Stage 3.2 synchronized pair update.
20. The conservative bound is proven for exactly **five** observables
    (`SplitCovarianceIntersectionBound.m:114-116`). Admitting a sixth is a per-observable proof
    obligation about its own H and R, not a re-proof of the formula.
21. The acceptance gates use an absolute tolerance floor `tol·max(1,‖·‖_F)` and are therefore **not
    scale-invariant**; a sub-micron-scale R could be rejected as numerically non-PD. Declared at
    `:56-61`.

**ISL measurement chain.**
22. With the shipped default (`product.enable = false`, LF-1), `h` reads the neighbour's **true**
    position and clock. The measured cost of honesty is **0.003585 m → 0.095183 m** at 3600 s
    (a factor of 27), or **→ 0.130883 m** at 600 s (a factor of 36). Any absolute accuracy quoted from
    an ISL-aided run must state which side of that line it is on.
23. Even on the honest side, a satellite **cannot beat its knowledge of its neighbour**: range is
    `|r_A − r_B|`, so `σ_pos` of the product maps ~1:1 along the line of sight. At `sigmaPos_m = 0.03`
    the measured `baselineRMS` is 0.036 m — the floor is visible in the number.
24. ISL integer ambiguity resolution does not survive: `realismGradeConfig.m:163-165` records a
    measured success rate of **~0.001** (σ 2.3–3.7 cycles), which is why LAMBDA is deliberately not
    enabled under the realism flag. Every ISL carrier result in this repository is **float**.
25. Phase wind-up and ISL antenna PCO/PCV are **absent**, declared at
    `ISLMeasurementBuilder.m:283-285` and `:514-515`. A constant part of either is absorbed by the
    float ambiguity; only a drift would show.
26. The one-way inter-satellite light-time term (~1 cm/km) is **default off** and, per LF-1b, is
    **not settable from any scenario JSON** (its only declaration, `masterConfig.m:768`, is in the
    dead branch; `deepMergeConfig.m:34-36` rejects the undeclared path). The shared-kernel one-way
    adapter path cannot model it at all (LF-11). No published ISL result in this repository has the
    light-time term applied.
27. `ISLMeasurementBuilder` deliberately drops the light-time position partial from H
    (`:571-574`), justified by a measured 3.1e−6 m response to a 1 m position error — ~640× below
    the 2 mm carrier floor. Valid at km-class baselines only; the margin closes as baselines grow.

---

# Section 9 re-verification — Simulation Architecture, Stochastics, Truth-Leakage, Config Resolution, Validation Methodology

**Tree audited:** branch `feature/ground-orientation-exec`, HEAD `170e37d` (2026-08-13). Working tree has 11 modified
golden `.mat` fixtures and one untracked results folder; no `.m` file is dirty, so every line number below is
reproducible from the committed tree.

**Baseline document:** `docs/scientific_traceability_analysis.md` §9 (lines 1560–1668), last touched at `3489075`,
line numbers stated as "working tree 2026-08-06" with a 2026-08-09 re-audit note.

**Headline of this pass.** The architecture verdicts hold: the epoch loop is still guard-heavy and correct, the
Gauss–Markov discretisation is still exactly Brown & Hwang Eq. (5.3.16), the identity-keyed RNG is still
collision-free, and `configEnumRegistry.m` is a genuine, well-designed closure of the "inert toggle" bug class.
**Eight new defects were found, six of them in the silent-degradation family that commit `889dcf6` proved exists.**
The two most consequential are structural, not numerical:

1. **The Monte-Carlo ensemble cannot run on any multi-asset architecture.** `runIndependentFleet_` and
   `runFederatedSwarm_` both hard-code `monteCarlo = struct('enabled', false)` and never call
   `runMonteCarloConsistency_`. Every swarm, ISL, federated and distributed number the project publishes rests on a
   single deterministic run. The Guard-C cross-seed centroid gate that `MonteCarloConsistency` advertises for
   swarms is unreachable from the report pipeline.
2. **The entire `masterConfig` ISL scenario block is dead code for every JSON-driven run.** It is gated on
   `cfg.scenario.nSpaceAssets <= 1`, and `nSpaceAssets` is 1 at that point in `masterConfig` by construction
   (line 44); the JSON that sets it to 6 arrives afterwards, and `finalizeConfig` never re-resolves the block.
   This is the mechanism behind the known `isl.product.enable = false` truth-leak: the value that would have made
   the swarm honest (`= true`, masterConfig:777) is written in a branch that no scenario ever reaches.

Also newly established: `ModelCoverageAudit`'s `missingUnsafe = 0` acceptance criterion is structurally
unfailable, `cfg.realism.resolvePostMerge` is an unreachable knob, `ReverseGNSSEKF.computeNEES` is dead in
production but is the only NEES API a test exercises, the enum guard has a live bypass through
`atmosphere.realisticProfile.*`, and none of the four regression goldens is in the automated test gate.

---

## Part 1 — Re-verified features

### Epoch loop — order of operations (updated ASCII map at HEAD line numbers)

- **Code**: `+revgnss/ReverseGNSSSimulation.m`. Complete re-map below; every line number re-read at HEAD.
- **Status vs doc**: **DRIFTED** — the structure is unchanged, but `run()` moved 280–306 → 255–309,
  `generateTruth_` 446–477 → 448–479, `runEstimation_` 480–985 → 482–1023, `finishRun` freeze `:441` → `:443`.
  `step`, `advanceTruthEpoch` and `runLocalEstimationEpoch` did not move.
- **Verdict**: correct — the ordering audit (i)–(v) in the doc re-tested and all five points still hold, with
  **one exception**: point (iv) "gauge rows never inflate … NIS" is **NOW-WRONG for the recorded `NIS` field**
  (see double-count DC-1).

```
run() :255-309   →  for k = lastEstimatedEpoch+1 .. nEpochs :  step(k) :312-315
│
├─ advanceTruthEpoch(k) :318-329            ── TRUTH STAGE
│   │   loud order guard :321-325  (throws if truth/estimation epochs interleave)
│   └─ generateTruth_(k, t_s, dt) :448-479
│       ├─ orbit truth from precomputed cache r,v(:,k) :454-457   (cache built :108-124)
│       ├─ k>1: towers{ti}.stepClock(dt) :465-467
│       │        asset.propagateAttitudeAndClock(dt) :468-472
│       ├─ asset.logState(t_s) :476
│       ├─ stepSecondaryAssets_(k,t_s,dt) :477      (helix CW truth from cache)
│       └─ attitudeSensors.generate(assets,t_s,dt) :478
│                 ↑ gyro/star-tracker drawn from TRUTH + bias + noise, TRUTH side
│
└─ runLocalEstimationEpoch(k) :332-342      ── ESTIMATION STAGE
    └─ runLocalEstimationEpochCore_ :402-420   [guards :409-418, uncommitted-row guard :414-418]
        └─ runEstimation_(k,t_s,dt) :482-1023   [truth-channel contract comment :483-488]
            ├─ k>1  ekf.predict(dt, towerClockModels, t_s-dt, omega_gyro,
            │                    assetClockModels, omega_gyro_inertial) :492-508
            ├─ capturePriorSnapshot_() :516    (READ-ONLY, body :1026-1055)
            ├─ measModel.computeMeasurements(asset[TRUTH], towers,
            │        ekf.getMeasurementState(), t_s, stateMap) :520-521
            │        ↑ z from truth+ErrorChain;  h,H linearised at the EKF ESTIMATE
            ├─ ground-carrier slip detect + ambiguity/covariance resets :523-596
            │        (D12 row-count guard :534-571, LOUD on mask-shape mismatch :561-571)
            ├─ secondary-asset ground rows (joint mode only) + inter-asset R :598-632
            ├─ one-way ISL rows :634-658 ;  ISL carrier slip/reset BEFORE update :659-673
            ├─ two-way ISL records → linearizeRecordedObservations :678-724
            ├─ inter-satellite time transfer :726-768
            ├─ ground↔space TWSTFT rows :770-804
            ├─ one-shot attitude init (gated, default 'none') :806-819
            ├─ clock-gauge + tx-delay gauge rows → z_ekf ONLY :821-829
            │        (z/h/H/R stay physical for diagnostics)
            ├─ visibility for diagnostics :831-835
            ├─ if numel(z) >= minMeasurementsForUpdate :843
            │   ├─ [K,nu,S,NIS] = ekf.update(z_ekf,h_ekf,H_ekf,R_ekf) :844   ← NIS is AUGMENTED
            │   ├─ EkfInnovationAccounting physical/gauge/augmented split :865-883
            │   ├─ Route-B ISL integer fix, held once per arc :889
            │   ├─ raw-carrier integer fixing + pseudo-measurement :891-924
            │   └─ postfit residuals, h recomputed at the UPDATED state :926-934
            ├─ star-tracker sequential update (own NIS recorded) :941-948
            ├─ differential-attitude sequential update :950-996   ← NIS DISCARDED (LF-7)
            └─ stage pending history row :1002-1022
                    ↓
        commitPendingEpochHistory() :365-393  → simData.recordEpoch + ekf.logStep
finishRun() :423-445  → simData.freeze() :443   (post/report stages read-only)
```

- **Sources**: no external source needed — this is an implementation map. The truth-channel contract is stated
  in-code at `:483-488`.
- **Critical analysis.** What is right: the two order guards (`:321-325`, `:409-418`) are hard errors, not
  warnings; the staged-commit mechanism refuses a second commit and refuses to freeze with a row staged
  (`:432-437`); `getMeasurementState()` rather than raw `ekf.x` is used at every builder call site, with the reason
  documented (`:774-779`), so quaternion-error-state mode never linearises at identity attitude; the cycle-slip
  reset is applied before the tight carrier R (`:659-663`); the D12 mask-shape failure is a `warning` plus a
  recorded `errStruct.suppressed.slipRowRemoval` field rather than a silent skip (`:561-571`). One timing nit:
  `attitudeSensors.generate` samples ω at `t_s` (truth stage of epoch k) and `ekf.predict` is told the interval
  starts at `t_s - dt` (`:506`), i.e. the gyro is applied backward-Euler over `[t_s-dt, t_s]`. That is a
  legitimate strapdown mechanisation and not a leak, but it is first-order and should not be described as a
  mid-interval sample.

---

### Truth/estimate separation & truth-leakage inventory (full re-inventory at HEAD)

- **Code**: contract `ReverseGNSSSimulation.m:448-450, 482-488`; store immutability `+data/SimulationDataStore.m:24`
  (`frozen_`), `:676-681` (`freeze`), writer guards at `:395, :663, :687, :1955`.
- **Status vs doc**: **DRIFTED** on every line reference; **one item SUPERSEDED**, **two items NEW**.
- **Verdict**: partially correct — architecture remains clean and self-documenting, but the inventory the doc
  gives is now incomplete, and its single most consequential entry (item 1) was already withdrawn while a
  *different*, larger leak (ISL `h` reading the neighbour's truth) was never in the list at all.
- **Sources**: NASA. (2016). *NASA-STD-7009A w/Change 1: Standard for models and simulations.* — Empirical
  Validation is "The process of determining the degree to which an operating model or simulation is or provides
  an accurate representation of the real world from the perspective of the intended uses of the model or the
  simulation." (p. 12 of 72). Verification is "The process of determining the extent to which an M&S is compliant
  with its requirements and specifications as detailed in its conceptual models, mathematical models, or other
  constructs." (p. 15 of 72). [EXTERNAL — note this *corrects* the wording the doc attributes to §3.2.]

**Truth-leak inventory at HEAD — gate, resolved default, measured cost.**

| # | Leak | Gate | Resolved default | Measured cost | Status |
|---|------|------|------------------|---------------|--------|
| L1 | Tower clock `perfectCorrection` | `cfg.towerClock.correctionMode` (masterConfig:3287) | `'truthHistoryProductNoisy'` — a latency-delayed, quantised broadcast product | n/a | **SUPERSEDED** (F4 withdrawal confirmed: `cfg.estimator.towerClockMode` at masterConfig:2036 is a placeholder overwritten by `finalizeConfig`; `configEnumRegistry.m:115-124` now documents the derivation explicitly) |
| L2 | **ISL `h` reads the neighbour's TRUE position and clock** | `cfg.measurements.isl.product.enable` | **`false`** for every JSON-driven swarm run (i_baseDefaults masterConfig:2666; the `= true` at :777 is unreachable, see LF-1) | **0.003585 m → 0.095183 m RMS absolute at 3600 s (×27)**, and 0.130883 m at 600 s (×36). Source: `config/ladder/ISL/isl017_carrierHonestProduct.json` `_id`, and `isl016…json` `_id` | **NEW — absent from the doc's inventory.** Mechanism verified: `ISLMeasurementBuilder.m:187-191` builds `rTxProd = rTxTruth + pb.pos`, `btxProd = btxTruth + pb.clk`; with the gate off `productBias_` returns zero and `h` at `:233`/`:318` uses `btxProd == btxTruth`. The builder header calls it "an ASSUMED-KNOWN beacon" (`:17`) |
| L3 | Gyro control input | always on when `estimator.imu.enable` | noisy `ω_true + bias + ARW` | n/a | **STILL VALID** — honest by construction, `:483-488` |
| L4 | Attitude-init oracle refused | `estimator.attitudeInitMode` | `'none'`; `knownAttitudeCalibration.allow = false` | n/a | **STILL VALID** |
| L5 | `TruthEndpointReplay` (post-processor) | always, inside `SwarmRelativeSolver` | replays recorded truth r/v/attitude/clock | n/a | **DRIFTED + WORSE**: after `889dcf6` the replay now feeds the *real* four-timestamp chain, so more truth-derived physics flows through it than the doc describes. `unusableReason` now also requires `truthRelativisticFracFreq` to be *present* (`TruthEndpointReplay.m:70-76`) rather than defaulting it — correctly, because a silent 0 would double-count `c·y_rel = 0.1615 m/s` per endpoint |
| L6 | Matched truth/model pairs (inverse crime by configuration) | per-effect `truth`/`model` enable pairs | many matched | n/a | **STILL VALID**, plus **one NEW member**: the relativistic clock. Truth `y_rel` (`ConfigFactory.m:~1980`) and model `y_rel` (`models.clocks.RelativisticClockCorrection.fracFreq`, falling back to `revgnss.Relativity.geoClockFracFreq(cfg.orbit.altitudeMean_m)`) are computed from the **same constant**, so the 581 m/3600 s ramp cancels **exactly** in `z − h` by default. The class documents the escape hatch ("Offset model.fracFreq from the truth value to simulate a residual", `:12`) but no shipped config uses it |
| L7 | NEES uses truth (diagnostics only) | always | — | n/a | **DRIFTED**: the doc cites `+filter/ReverseGNSSEKF.m:838-887 computeNEES`. That function still exists (`:968`) but **has no production caller**; the live path is `+data/SimulationDataStore.m:1071-1075`, `entry.NEES_pos = (r_err'*(P_pos\r_err))/3`. Nothing feeds back — verdict unchanged |
| L8 | Per-asset seed separation | — | — | n/a | **SUPERSEDED**: no longer `seed + 1000*ai`. `+revgnss/IndependentFleetScenarioFactory.m:74` uses `baseSeed + 100000*(assetIndex-1)`, with the clock seed `100+ai` (siblings retained) or `300+ai` (`:67-73`). The header (`:60-66`) records a *measured* prior defect: a flat seed 100 gave every spacecraft a bit-identical truth clock and `max\|b_i − b_1\| = 0` exactly |

**Constraint checks demanded by the brief.**

- **(a) No truth in the estimator except through measurements** — holds for the ground/uplink chain. It does
  **not** hold for the ISL chain at the default gate (L2). This is the single largest live violation.
- **(b) Joint multi-asset mode disallowed** — this is **project policy, not an enforced invariant**.
  `revgnss.ConfigFactory.applyMultiAssetMode` (`:482-514`) accepts `'joint'` and only errors on `nSpaceAssets < 2`;
  `ReportRunner.runSingle:117-124` routes to federated only when `mode ~= 'joint'`. The only hard block is on the
  distributed path (`IndependentFleetCoordinator.m:631`: "Independent fleet execution requires
  multiAsset.mode='fast'"). Three shipped fixtures still select joint: `config/ladder/test/test003…`, `test004…`,
  `test005…`. The joint code path in `ReverseGNSSSimulation` (`:598-632`, `:929-931`) is live.
- **(c) `isl.product.enable = false` truth-leak** — confirmed and quantified, see L2 and LF-1.

---

### Config architecture and the resolution pipeline

- **Code**: `run_oo_v1.m:44-46` (single entry, duration injected as a run override, not scenario-owned);
  `config/resolveSimulationConfig.m:18-77`. Order at HEAD:
  `masterConfig()` `:26` → optional `realismGradeConfig` `:42-47` → `_extends` chain flattened base-first
  `:39-40, :86-131` → scenario leaves `:50-51` → caller overrides `:54-61` → provenance (flat + per-level)
  `:63-73` → `validateMasterConfig` `:76` → `revgnss.ConfigFactory.finalizeConfig` `:77`. Scenario SHA-256 at
  `:41` (`fileSha256_` `:236-247`).
- **Status vs doc**: **DRIFTED** (doc cited `:12-49`, `:26`, `:92-102`) and **EXTENDED** — the `overrides`
  argument and `provenance.explicitByLevel` are both new since the doc was written.
- **Verdict**: correct — the chain is depth-limited (`maxDepth = 8`, `:96`) and cycle-guarded (`:105-107`), the
  child always wins, and per-level provenance is exactly the information `resolveEnablePairsPostMerge` needs.
- **Sources**: implementation contract only; no external source required.
- **Critical analysis.** Genuinely strong: `readOverlayChain_` records `levelPaths{i}` per file so an *inherited*
  leaf can be distinguished from a *declared* one — the fix for the six inert `feat` rungs. `run_oo_v1` owning
  `duration_s` (`:44`) removes an entire class of scenario/run confusion. `validateMasterConfig` is called
  **twice** (once at `masterConfig.m:1071`, once at `resolveSimulationConfig.m:76`); harmless but worth knowing
  when reading a stack trace. Weakness: validation runs **before** `finalizeConfig`, and `finalizeConfig` then
  writes mode strings (`applyAtmosphereProfile` `:592`, `orbitClassConfig` `:633`, the towerClockMode derivation)
  that are never re-validated — this is the mechanism of LF-4.

---

### `config/internal/configEnumRegistry.m` — NEW module

- **Code**: `config/internal/configEnumRegistry.m:1-160`, **28 entries**, consumed by
  `config/internal/validateMasterConfig.m:20` → `i_validateEnums` `:523-548`, which raises
  `validateMasterConfig:unknownModeValue` on any *present* string that matches nothing.
  Config-derived legal sets: `i_oscillatorNames(cfg)` `:150-160` unions the built-in catalogue with
  `cfg.clock.customOscillators` plus the two documented aliases.
- **Status vs doc**: **NEW** — no coverage in the existing document.
- **Verdict**: correct, and the best single piece of defensive engineering added since the last audit — but
  **incomplete by design, with one live bypass** (LF-4).
- **Sources**: implementation contract; the file states every legal set was "read off the dispatch site, not from
  a comment" (`:40`).
- **Critical analysis.** What it closes: the exact failure the file names — `'singleMapped'` instead of
  `'simpleMapped'` silently produced a *troposphere-free* run while the report printed the typo as the active
  model (`:29-30`). It now errors at resolve time with the dispatch site and consequence in the message. Two
  design choices are right: absent knobs are skipped (`:526-529` — a missing path is declining a feature, not an
  error), and non-string values are skipped (`:534`). One entry is registered even though it already errors
  downstream (`atmosphere.gaseousAbsorption.mappingKind`, `:100-106`) with a stated reason — the run can be
  queued and started before the bad value is reached. The registry also *documents live inertness in place*:
  `'seededTruthResidual'` is listed as shipped-but-inert (`:57-61`), `'stationaryEcef'` as legal-but-rewritten
  (`:133-134`), `'noisyCorrection'` as a real mode reached only by verbatim passthrough (`:122-124`).
  **Quantified limit**: 28 entries against **≥65 distinct string-valued `mode`/`modelType`/`model`/`policy`/
  `kind`/`protocol`/`observable` leaves in `masterConfig.m` alone** (measured by pattern count), so roughly 40 %
  coverage of the plausible surface. Uncovered examples that change physics:
  `measurements.twoWayTimeTransfer.mode`, `measurements.isl.twoWay.timeTransfer.mode`,
  `measurements.isl.twoWay.terminalGeometry.mode`, `clock.gauge.mode`,
  `multiAsset.twoWayISL.gauge.mode`, `multiAsset.jointGeometry.observable`,
  `multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable`, `effects.antennaPCV.modelType`.

### `tests/test_config_mode_enum_validation.m` and `tests/test_enable_pair_extends_ownership.m`

- **Code**: `tests/test_config_mode_enum_validation.m:1-35` (five checks: legal values accepted, typos rejected,
  every shipped scenario still resolves, every config source satisfies the registry, plus the troposphere
  example); `tests/test_enable_pair_extends_ownership.m:1-33` (three unit cases + two integration cases, the
  second of which writes a temporary two-file `_extends` chain and resolves it end-to-end).
- **Status vs doc**: **NEW**.
- **Verdict**: correct — these are real tests with real negative controls, not smoke checks.
- **Critical analysis.** `i_typosRejected` (`:59-77`) builds the near-miss as `[values{1} 'Xq']`, so it can never
  accidentally be a legal value, and requires the specific identifier. `i_shippedScenariosStillResolve` is the
  right safety net: it prevents the registry from inventing a legal set that excludes a shipped file.
  `i_unitSameLevelKeepsPair` pins `golden_baseline.json`'s asymmetric `errors.multipath {enable:1, truth:1,
  model:0}`, which is what makes the fix golden-safe. **One softness**: `i_legalValuesAccepted` (`:38-58`) swallows
  any error whose identifier is not `unknownModeValue` ("Any OTHER error is a downstream contract the registry does
  not own"). That is defensible, but it means a legal value that hard-errors downstream passes silently, so the
  positive control is weaker than it reads.

### `resolveEnablePairsPostMerge` / `expandEnableToggles` — the enable-pair machinery

- **Code**: `config/internal/expandEnableToggles.m:16-22` (unconditional master → pair, called pre-merge at
  `masterConfig.m:266` and inside `realismGradeConfig.m:288`);
  `config/internal/resolveEnablePairsPostMerge.m:47-79` with `pairMemberWins_` `:81-92` and `lastLevel_` `:94-102`,
  called **once**, from `+revgnss/ConfigFactory.m:594-598` over 12 effect paths.
- **Status vs doc**: **NEW** in detail (the doc's F-register mentions the six inert rungs but §9 carries no entry).
- **Verdict**: correct — the specificity rule is the right rule and the ordering hazard around it is handled.
- **Critical analysis.** The rule is: pair member declared at level ≥ master's level → leave the pair; master
  declared at a strictly later level → expand it; same-level tie → keep the pair. Verified against the two shapes
  that matter. **The load-bearing ordering constraint is respected**: `resolveEnablePairsPostMerge` runs at
  `ConfigFactory.m:594`, `applyPerTowerHwBias` at `:636`, and the comment at `:625-628` states why that order is
  mandatory (`applyPerTowerHwBias` deliberately forces `hardwareDelay.model.enable = false` so the per-tower bias
  survives `z − h`; running the pair resolver afterwards would re-slave it to the master and silently calibrate the
  bias away). Residual: with no scenario JSON, `cfg.provenance.explicit` is empty and the function returns
  immediately (`:51`), so any driver that calls `masterConfig()` and mutates the struct — including
  `tests/regression/run_distributed_fleet_regression.m` — never exercises it.

### `finalizeConfig` J2 auto-tuner — the silent `sigma_mps2` overwrite

- **Code**: `+revgnss/ConfigFactory.m:2348-2359`:
  ```matlab
  if isJ2Truth82_ && isTwoBodyEkf82_
      if ~cfg.estimator.processNoise.modelMismatch.enable
          cfg.estimator.processNoise.modelMismatch.enable = true;      % :2353-2355
      end
      autoSigma82_ = max(1e-8, 0.25 * cfg82_j2Norm_);                  % :2356
      if cfg.estimator.processNoise.modelMismatch.sigma_mps2 <= 1e-6
          cfg.estimator.processNoise.modelMismatch.sigma_mps2 = autoSigma82_;   % :2357-2359
      end
  ```
- **Status vs doc**: **DRIFTED** (doc: `:1875-1886`, then `:2086-2097` in the register). Verdict unchanged.
- **Verdict**: partially correct — the tuning is defensible, the silence is not, and a **new** failure mode was
  found in the same block.
- **Sources**: Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications.* Springer.
  — "In practical applications the Q-matrix may be determined by simulations in order to find a proper balance
  between process and measurement noise and ensure an optimum filter performance." (p. 286). **[VERBATIM RE-VERIFIED
  by text extraction at PDF page index 296, printed page label "286".]**
- **Critical analysis.** Still un-warned at `:2357-2359`. Mitigations verified present: `residualAccelerationUncertainty`
  is a one-way read-only mirror written *after* auto-scaling (`:2392-2393`) with a comment forbidding the reverse
  write; the opt-in family guard is at `:2402-2408`. The inertness reason in the doc's F23 correction is
  re-confirmed: `masterConfig.m:732-737` (executed after `i_baseDefaults`, which is called first at `:24`) forces
  `orbit.truth.mode = 'j2Rk4'`, `orbit.mode` to match, and `estimator.dynamics.mode = 'j2'`, so
  `isTwoBodyEkf82_` is false on the default path. **NEW sub-defect**: `cfg82_j2Norm_` is only computed when
  `cfg.orbit.useOrbitPropagator` is true (`:2330`); otherwise it stays 0 and `autoSigma82_ = max(1e-8, 0) = 1e-8`.
  A scenario that reaches the tuner with the propagator off therefore has its process noise silently **reduced
  100×** below the shipped 1e-6 default — a change in the overconfident direction, with no warning. Latent
  (`useOrbitPropagator` resolves true), but it is a `max(1e-8, …)` floor doing the opposite of what a floor
  usually does.

### RNG architecture — counter-based, identity-keyed streams

- **Code**: `+models/+noise/RngRegistry.m:78-93` (`RandStream(engine,'Seed',masterSeed)`, `s.Substream = idx`,
  default `'threefry'`), key at `:95-108`:
  `idx = src·2^44 + node·2^28 + ant·2^24 + sig·2^20 + mod(epochIdx+1, 2^20)`;
  persistent vs epoch streams `:55-74`; 29 integer source codes in `+models/+noise/RngSource.m:12-43`, truth and
  model separated (`ENV_TROP_TRUTH = 7` vs `ENV_TROP_MODEL = 8`).
- **Status vs doc**: **DRIFTED** (doc: `:78-93`, `:95-108`, `:55-74` — the RngRegistry line numbers are in fact
  unchanged; `RngSource` grew from 29 documented codes to 29 actual, unchanged).
- **Verdict**: correct — field widths re-derived digit by digit and the encoding is collision-free.
- **Sources**: Salmon, J. K., Moraes, M. A., Dror, R. O., & Shaw, D. E. (2011). Parallel random numbers: As easy as
  1, 2, 3. In *Proceedings of SC'11* — "independent, keyed transformations of counters produce a large alternative
  class of PRNGs with excellent statistical properties" (p. 1). [EXTERNAL]
- **Critical analysis.** Re-derived: `src < 32` occupies bits 44–48, `node < 65536` bits 28–43,
  `ant < 16` bits 24–27, `sig < 16` bits 20–23, `epoch < 2^20` bits 0–19; maximum
  `idx < 32·2^44 = 2^49 ≪ 2^53`, so no field overlaps and no double-precision loss. Persistent streams use
  `epochIdx = -1 → ep = 0`, disjoint from epoch streams (`ep ≥ 1`). **Two bounded limits worth stating:**
  (1) `ep = mod(epochIdx+1, 2^20)` means `epochIdx = 1048575` maps to `ep = 0` and **collides with the persistent
  stream of the same identity** — unreachable at any arc this project runs (1 048 575 epochs = 12.1 days at
  dt = 1 s), but it is a wrap, not a guard;
  (2) the key carries **no asset field**, so per-asset independence rests entirely on distinct master seeds. The
  doc calls the additive offsets "collision-free only by convention"; that is **too harsh for a counter-based
  engine** — for Threefry4x64-20 the seed *is* the key, and Salmon et al.'s claim is precisely that distinct keyed
  transformations are independent. The 100 000 spacing at
  `IndependentFleetScenarioFactory.m:74` makes accidental equality impossible for any realistic N. The genuinely
  weaker path is `MonteCarloConsistency.m:74`, which uses **`mt19937ar` with adjacent seeds** (`baseSeed+j+500000`)
  for the initial-error draw — that is the classic correlated-seed pattern and is not covered by the counter-based
  guarantee.

### `SharedAtmosphereRng` — formation-shared atmosphere gate

- **Code**: `+models/+noise/SharedAtmosphereRng.m` — `isEnabled` `:58-70`, `isAntennaShared` `:72-91`,
  `seed` `:93-107` (default `DEFAULT_SEED = 7201`), `build` `:109-121`. Config default
  `cfg.atmosphere.sharedAcrossFormation.enable = false` (`masterConfig.m:896`),
  `sharedAcrossAntennas.enable = false` (`:930`).
- **Status vs doc**: **DRIFTED and materially UPDATED.**
- **Verdict**: correct — the physics argument and the re-rooting lever are both sound.
- **Critical analysis.** The doc says the gate is "default OFF … the default therefore still draws independent
  atmospheres per formation member". That remains true of `masterConfig`, but **`config/golden_baseline_multi.json`
  sets `atmosphere.sharedAcrossFormation = {enable: true, seed: 7201}`** — so the flagship swarm golden, and every
  ladder rung that extends it (including isl016/isl017), **does** share the atmosphere. F25's practical impact is
  therefore smaller than the register implies, in exactly the way F24's was. The `sharedAcrossAntennas` axis
  (`:72-91`) is genuinely new relative to the doc and is correctly reasoned: re-rooting cannot collapse the antenna
  field because the key carries it, so a separate lever is required.

### Gauss-Markov discretisation

- **Code**: `+models/+noise/StochasticProcess.m:34-41`:
  ```matlab
  if tau_s <= 0; error('StochasticProcess:invalidTau', 'tau_s must be > 0'); end
  phi  = exp(-dt / tau_s);
  q    = sigma_ss^2 * (1 - phi^2);
  xNew = phi * x + sqrt(max(q, 0)) * randn(stream, sz(1), sz(2));
  ```
  `randomWalkStep` `:44-61` (`σ√Δt`), `white` `:63-72`.
- **Status vs doc**: **DRIFTED** (doc: `:38-41`; now `:37-41`, limiting cases `:29-32`).
- **Verdict**: correct — exact discretisation, verified against the primary source page by page.
- **Sources**: Brown, R. G., & Hwang, P. Y. C. (1997). *Introduction to random signals and applied Kalman
  filtering* (3rd ed.). Wiley. — "A stationary Gaussian process X(t) that has an exponential autocorrelation is
  called a Gauss–Markov process." (p. 94) [**transcribed from scanned page**, PDF spread index 52];
  Eq. (5.3.9) gives the transition matrix with the `e^(−βΔt)` element (p. 201) [**transcribed from scanned page**,
  spread index 105]; Eq. (5.3.16) gives `E[x₂x₂] = σ²(1 − e^(−2βΔt))` (p. 202) [**transcribed from scanned page**,
  spread index 106].
- **Critical analysis.** With β = 1/τ the code's `phi` is Eq. (5.3.9)'s element exactly and `q` is Eq. (5.3.16)
  exactly, so the stationary variance is preserved identically (`φ²σ² + σ²(1−φ²) = σ²`) for **any** Δt/τ, not just
  small ones. `tau_s <= 0` is a hard error rather than a silent fallback — the right choice. One implementation
  nit unchanged from the doc: `randn(stream, sz(1), sz(2))` assumes `x` is at most 2-D, which is true at every
  call site but is not asserted.

### Monte-Carlo NEES/NIS consistency machinery

- **Code**: `+revgnss/MonteCarloConsistency.m:25-159`. Seeds `:70-71`
  (`cfg.simulation.seed = baseSeed + j`, `cfg.simulation.mcSeedOffset = j*1000`); initial error from P0 `:74-80`;
  NIS pooling `:95-97`; the R-7 raw-block NEES fix `:100-105`; centroid gate one-sample-per-seed `:108-122`;
  verdict logic `:169-186`; two-sided band `:188-197` via `+revgnss/ChiSquareConsistency.bounds`.
- **Status vs doc**: **STILL-VALID on every line number** — this file has not moved. But the doc's *reachability*
  claim is **NOW-WRONG** (see LF-2).
- **Verdict**: the statistics are correct; the plumbing is not.
- **Sources**: Brown & Hwang (1997) — Monte Carlo methods "involve setting up a statistical experiment that
  matches the physical problem of interest, then repeating the experiment over and over with typical sequences of
  random numbers, and finally, analyzing the results of the experiment statistically." (p. 210) [**transcribed from
  scanned page**, spread index 110]. ECSS. (2008). *ECSS-E-ST-60-10C: Control performance.* ESA-ESTEC — "the only
  way to include ensemble type errors (see A.1.2) is to have some form of Monte-Carlo campaign with a large number
  of simulations covering the parameter space." (p. 35) [**VERBATIM RE-VERIFIED**]; and "The performance validation
  process also involves appropriate, detailed simulation campaign using Monte-Carlo techniques, or worst-case
  simulation scenarios." (p. 19) [**VERBATIM RE-VERIFIED**]. Montenbruck & Gill (2000) — "While answers to the
  above questions might also be obtained from a Monte-Carlo simulation, a large number of cases would be required
  to obtain the desired statistical information." (p. 294) [**VERBATIM RE-VERIFIED**].
- **Critical analysis.** The three statistical details the doc praises all re-verified. The R-7 fix is *provably*
  right: `SimulationDataStore.m:1075` writes `entry.NEES_pos = (r_err'*(P_pos\r_err))/3`, i.e. per-dof, so
  `MonteCarloConsistency.m:105`'s `sumNEES += 3*sum(neesK)` against `dofNEES += 3*sum(gE)` restores the raw block
  statistic — `sum ~ χ²(3N)` as intended. The centroid gate correctly contributes **one** time-averaged 3-dof
  sample per seed (`:112-115`) because the centroid is a slowly varying rigid-body mode. The
  `'inconclusiveMatchedCrutch'` refusal (`:175-176`) is the correct posture. **What is new and bad**: (i) the whole
  harness is unreachable for multi-asset runs (LF-2); (ii) `MonteCarloConsistency.run` constructs
  `revgnss.ReverseGNSSSimulation` **directly** (`:82-84`), so even if called by hand with a swarm cfg it would
  exercise the *legacy chief-plus-represented-secondaries* estimator, not the federated architecture that produces
  the published swarm numbers; (iii) `mcSeedOffset` is applied to the receiver clock only when the existing seed is
  exactly 100 (`ConfigFactory.m:1957-1964`), so under any per-asset seeding it is silently ignored (LF-6).
  **`report.monteCarlo.enable` re-checked at HEAD**: `masterConfig.m:79` and `:3494` both `false`;
  `config/golden_baseline.json` sets `{enable: true, nSeeds: 12, duration_s: 900, confidence: 0.99}` — F24's
  correction **STILL VALID**; `config/golden_baseline_multi.json` sets `{enable: false}` — **NEW**, so the swarm
  flagship is single-seed by its own config as well as by the hard-coding.

### Validation manifest and campaign status

- **Code**: `config/masterConfig.m:596` `cfg.validation.manifest.status = 'declaredNotStatisticallyExecuted'`;
  `:597-601` declares 200 short-ensemble and 50 full-scenario independent runs; numeric thresholds `:602-616`
  (light-time 1e-11 s, zero-noise range closure 1e-3 m, Jacobian 1e-5 rel / 1e-7 abs, covariance asymmetry 1e-10);
  `:618` `cfg.validation.scientificCampaign.enable = false`; acceptance criteria all `NaN`
  (`unassessedAccuracyCriteria`, `:625-638`); `cfg.validation.statistics.*` written by
  `ConfigFactory.m:2302-2315` and read only as a report label.
- **Status vs doc**: **DRIFTED** (doc: `:435-437`, `:460`, `ConfigFactory.m:1830-1842`). Substance **STILL VALID**.
- **Verdict**: correct and honest — the manifest is a *predeclared* campaign, and the code says so in its own
  status string.
- **Critical analysis.** Two things to state plainly in any paper: every `acceptanceCriteria` field is `NaN`
  (`masterConfig.m:626-629`), so the manifest declares no pass/fail limit on position or clock accuracy at all;
  and the `declaredNotStatisticallyExecuted` string is now the *only* honest label left, because `report.monteCarlo`
  (the mechanism that could change it) is off for the swarm and hard-off for every non-single-asset architecture.

### Golden-run regression, fingerprints, and the new goldens

- **Code**: `+revgnss/GoldenRunFingerprint.m` — doctrine `:13-19`, `%.17g` round-trip `:81, :191-197`,
  rel+abs tolerance compare `:119-158` (`relTol = 1e-9`, `absTol = 1e-12`), scenario SHA-256 `:176, :214-215`.
  New goldens: `tests/regression/run_distributed_fleet_regression.m` (253 lines) and
  `tests/regression/run_multi_islcarrier_regression.m` (193 lines).
- **Status vs doc**: **DRIFTED** for `GoldenRunFingerprint`; **NEW** for the two regression scripts.
- **Verdict**: correct, with the epistemic scope stated exactly right by the code itself — but see LF-8 for what
  the gate does *not* cover.
- **Sources**: NASA-STD-7009A (verification vs validation, above). [EXTERNAL]
- **Critical analysis — what the new goldens actually pin.**
  - **`golden_distributed_fleet.mat`** (inspected directly): `nAssets = 2`, `nx = 27`, 120 s at dt = 1 s. It freezes
    two configurations — A with `linkUpdate` disabled, B with the Section 2.3.1 sanctioned tuple
    (`coherentTwoWayCodeRange`, `ownerPolicy = 'initiator'`,
    `correlationPolicy = 'splitCovarianceIntersection'`) — plus **the A→B delta**. Frozen values:
    `linkUpdateMovedState = 1`, `max|ΔX| = 56.957 m`, `max|ΔPdiag| = 2.4404e5`, counters
    `A = [0 0 0]`, `B = [121 121 121]`, `A.resultStatus = 'diagnosticOnlyNoLinkUpdate'`,
    `B.resultStatus = 'conservativeDistributedOwnerOnly'`.
    **This pins more than non-movement.** Because `linkUpdateMovedState` is in `numericFields` (`:186`) and its
    frozen value is 1, a future change that makes the sanctioned link update inert would move it to 0 and
    **FAIL** the gate — so the fixture does assert "the update still buys something", which is a physics-adjacent
    claim. It does not assert the update is *right*.
    Two things it does **not** cover: `relativeReportAvailable = 0` in *both* configurations
    (`reason = 'correlationNetworkDisabled'`), so the relative-covariance report is frozen in its unavailable
    state; and the fixture builds its config by calling `masterConfig()` and mutating the struct, bypassing
    `resolveSimulationConfig` — so there is no scenario SHA, no provenance, no `resolveEnablePairsPostMerge`, and
    no post-mutation `validateMasterConfig`. The "config text = run definition" traceability chain does not apply
    to it.
  - **`golden_multi_islcarrier_{,honest_}3600s.mat`**: freezes the six **per-asset absolute** states (final `x`,
    `diag(P)`, strided position series, position/clock error against flown truth) and deliberately freezes
    **nothing** from `SwarmRelativeSolver`, for two stated reasons: with `keepIslInPerAssetEkf = true` the relative
    layer re-consumes observations the leaves already absorbed so its covariance is not independently valid; and
    the relative layer's observable source depended on an uncommitted three-file fix at capture time
    (`run_multi_islcarrier_regression.m:26-41`). Refusing to freeze a number produced by an uncommitted tree is
    exactly the right instinct and directly answers the repo's own prior `ca3f8fc` incident.
    The digest also carries `relativisticClockBias_m` and applies a **domain correction** before differencing
    `x(b_rx)` (residual domain) against `truthClk` (full truth clock) — `:120-133` records the measured artefact
    (−581.474 m at 3600 s, exactly `RelativisticClockCorrection.bias_m(cfg, 3600) = 581.4741 m` at rate
    0.161521 m/s). That is a genuine double-count trap, found and fixed.
  - **Both are pinned to `max|delta| = 0`**, i.e. bit-identity, which is the correct claim for a deterministic
    pipeline and the strongest tolerance available.

### Reproducibility and parallel determinism

- **Code**: master seed `masterConfig.m` (`simulation.seed`), scenario SHA-256 + explicit-path provenance
  `resolveSimulationConfig.m:41, :63-73`; federated fan-out `ReportRunner.runFederatedEstimationParallel_` `:2346`,
  opt-in flag `federatedParallelEnabled_` `:2296-2301` (default false), RAM/core heuristic
  `federatedMaxWorkers_` `:2303-2344` (RESERVE_GB 6, PERWORKER_GB 4; 16 GB → 2 workers measured optimum),
  worker fallback to in-process serial re-run `:2452-2467`.
- **Status vs doc**: **DRIFTED** (doc: `:2287-2295`, `:2246-2285`). Substance **STILL VALID**.
- **Verdict**: correct.
- **Critical analysis.** The architecture is right: parallelism is pure orchestration, never a stochastic degree
  of freedom, and the fallback path prints `[swarm-parallel] %d/%d assets fell back to serial (result unchanged)`
  (`:2466`) rather than degrading quietly — one of the few fallbacks in the codebase that announces itself.
  Residual risks re-confirmed: (1) the J2 tuner still means the `masterConfig` text alone under-determines one Q
  parameter on any j2-truth/two-body-EKF scenario; (2) MC ensemble seeds still enter by three mechanisms, one of
  which is `mt19937ar` with adjacent seeds; (3) fingerprint stability across MATLAB versions still depends on
  library numerics.

---

## Double-count candidates

Ordered by how much a reader should worry.

### DC-1 — Recorded `NIS` is computed on the AUGMENTED stack; the dof recorded beside it counts PHYSICAL rows only
- **Location A**: `+revgnss/ReverseGNSSSimulation.m:844` —
  `[K57_, nu57_, S57_, NIS] = obj.ekf.update(z_ekf, h_ekf, H_ekf, R_ekf);` where `z_ekf` is the physical stack
  **plus** clock-gauge rows (`:824`) and tx-delay-gauge rows (`:828`).
- **Location B**: `+data/SimulationDataStore.m:932` — `entry.numMeasurementRows = numel(z);` where `z` is the
  **physical-only** stack staged at `ReverseGNSSSimulation.m:1012`. The NIS is stored at `:850`.
- **Mechanism**: `MonteCarloConsistency.m:95-97` pools `sum(nisK)` against `sum(mrK)`. Gauge rows contribute to the
  numerator and not to the denominator, biasing pooled NIS/dof **upward** — i.e. toward a false "overconfident"
  verdict.
- **Size**: `gaugeInfo.rowsAdded = 0` for the shipped configuration, because gauge rows require
  `estimateTowerClocks` **and** `clock.gauge.mode ∈ {fixReferenceTower, meanGroundClockGauge}`
  (`+filter/ReverseGNSSEKF.m:1893-1918`), whereas the resolved default and `golden_baseline.json` both use
  `'externalTowerCorrections'` → 0 rows. With `fixReferenceTower` and drift states it is 2 rows against ~105
  physical, i.e. a ~2 % dof deficit plus whatever the gauge innovations contribute.
- **Severity**: **low, latent** — but it directly contradicts the doc's ordering-audit point (iv) ("Gauge rows
  never inflate measurement counts or NIS"), which is true of the *counts* and false of the *NIS*. The correct
  quantity already exists: `errStruct.ekfAccounting57.physicalNIS57` (`ReverseGNSSSimulation.m:874`, stored at
  `SimulationDataStore.m:566`).

### DC-2 — `c·y_rel` in the four-timestamp endpoint (FIXED, worth recording as the canonical example)
- **Location A**: `+revgnss/ReciprocalEndpointTruthProvider.spacecraft` supplies
  `properTimeRate = 1 − (GM/r + v²/2)/c²` to the endpoint model, which therefore already carries `y_rel`.
- **Location B**: `+revgnss/TruthEndpointReplayClock.m:34-37` `getDriftMetersPerSecond` returns the **total**
  recorded rate, relativistic offset included (that is what `SimulationDataStore` records).
- **Mechanism**: feeding the total rate to a path that separately applies `properTimeRate` counts the same physics
  twice. Fixed in `889dcf6` by adding `getOscillatorDriftMetersPerSecond` (`:40-59`), which subtracts
  `relativisticFracFreq_ · c`.
- **Size**: `c·y_rel = 0.1615 m/s` on **every** endpoint rate.
- **Severity**: **fixed**; retained here because the guard chosen is the right pattern — `truthRelativisticFracFreq`
  is **required** by `TruthEndpointReplay.unusableReason` (`:70-76`) rather than defaulted to 0, precisely so a run
  with relativity on cannot silently double-count.

### DC-3 — `x(b_rx)` residual domain vs `truthClk` full domain (FIXED in the regression harness only)
- **Location A**: `tests/regression/run_multi_islcarrier_regression.m:120-133`.
- **Location B**: the same subtraction anywhere else that has not been corrected.
- **Mechanism**: `x(b_rx_idx)` is the **residual-domain** clock state (the relativistic ramp is carried
  model-side by `RelativisticClockCorrection`), while `asset.clock.getBiasMeters()` is the **full** truth clock.
  Differencing them raw reports the whole relativistic ramp as filter error.
- **Size**: **−581.474 m at 3600 s**, matching `RelativisticClockCorrection.bias_m(cfg, 3600) = 581.4741 m`
  (rate 0.161521 m/s) to six figures, against a true clock-bias RMS of 0.0634 m — a factor of ~9000.
- **Severity**: **medium** — the harness is fixed and carries a "DO NOT REMOVE THIS CORRECTION" comment, but the
  same raw subtraction is the natural thing for any analysis script to write, and nothing structurally prevents it.

### DC-4 — Three writers to the same `truth`/`model` enable pair
- **Location A**: `config/masterConfig.m:266` and `config/internal/realismGradeConfig.m:288`
  (`expandEnableToggles`, unconditional master → pair), both **pre-merge**.
- **Location B**: `+revgnss/ConfigFactory.m:594-598` (`resolveEnablePairsPostMerge`, provenance-aware),
  **post-merge**, followed by `applyPerTowerHwBias` at `:636` which forces one pair member back to `false`.
- **Mechanism**: three independent writers to the same leaves in one resolution. This is *not* currently a
  numerical double-count — the ordering is deliberate and documented at `:620-628` — but it is the shape in which
  one appears, and the ordering constraint is enforced only by comment and call order.
- **Size**: n/a (a boolean); the consequence of getting the order wrong is measured at
  masterConfig-vs-realism scale (an entire effect on or off).
- **Severity**: **low as built, high if the order is ever changed.** There is no test asserting that
  `applyPerTowerHwBias` runs after `resolveEnablePairsPostMerge`.

### DC-5 — Sequential updates whose innovations are never accounted
- **Location A**: `+revgnss/ReverseGNSSSimulation.m:944-946` — star-tracker update, NIS captured and recorded with
  its own dof (`SimulationDataStore.m:851-858`). Correct.
- **Location B**: `+revgnss/ReverseGNSSSimulation.m:991` — `obj.ekf.update(z_da, h_da, H_da, R_da);` with **no
  output captured**. The differential-attitude channel conditions `x` and `P` with no consistency statistic at all.
  Likewise `applyAmbiguityPseudoMeasurement` (`:909-910`) and the Route-B fix (`:889`).
- **Mechanism**: not a double count of variance, but a **single-count of information with zero accounting** — the
  filter is tightened three more times per epoch after the NIS that the report presents.
- **Size**: `diffAtt` is only active when `estimator.attitudeCarrierMode = 'calibratedDifferentialAmbiguity'`
  (default off); the ambiguity pseudo-measurement is gated on `estimator.integerAmbiguity.enable` (default off).
- **Severity**: **medium when those gates are on** — any NIS/NEES verdict quoted for such a run describes the
  filter *before* two-thirds of that epoch's conditioning.

### DC-6 — `atmosphere.realisticProfile.*` merged over `errors.*` after validation
- **Location A**: `config/masterConfig.m:818+` defines `cfg.atmosphere.realisticProfile.errors.{troposphere,
  ionosphere}.*` (a full mirror of the live paths; ten string-valued mode leaves among them).
- **Location B**: `config/internal/realisticAtmosphereConfig.m:12` —
  `[cfg, ~] = deepMergeConfig(cfg, cfg.atmosphere.realisticProfile);` reached from
  `ConfigFactory.applyAtmosphereProfile` at `:592`, i.e. **inside** `finalizeConfig` and therefore **after**
  `validateMasterConfig`.
- **Mechanism**: two config locations own the same physical setting, and the mirror is not enum-validated.
  This is both a duplication and the enum bypass described in LF-4.
- **Size**: a mistyped `atmosphere.realisticProfile.errors.troposphere.modelType` yields a
  **troposphere-free run** — the exact defect `configEnumRegistry` exists to prevent, at ~2.3 m zenith / metres of
  slant delay.
- **Severity**: **medium**, and **live**: `config/golden_baseline.json`, `golden_baseline_multi.json` and
  `config/realism.json` all set `atmosphere.realistic = true`, so the promotion runs on the flagship path.

### DC-7 — checked and found CLEAN
- `validateMasterConfig` runs twice (`masterConfig.m:1071`, `resolveSimulationConfig.m:76`). Pure assertions, no
  derivation, `cfg` returned unchanged by contract (`:4-7`). **No double-count.**
- `expandEnableToggles` is idempotent (`:16-22`); `applyAtmosphereProfile` documents and satisfies idempotence
  (`ConfigFactory.m:526-527`); the four re-resolved pre-merge writers are stated to be idempotent with the two
  `max` clamps converging (`:614-616`). **No double application.**
- The relativistic clock ramp is applied once truth-side and once model-side and cancels; it is a matched pair,
  not a double count (see L6).

---

## Logical flaws

### LF-1 — The `masterConfig` ISL block is unreachable from every JSON-driven run (gate that does not gate)
`config/masterConfig.m:749`: `if cfg.scenario.nSpaceAssets <= 1`. `cfg.scenario.nSpaceAssets` is set to **1** at
`masterConfig.m:44`, and `i_baseDefaults` (called first, `:24`) also sets 1 at `:1129`. The scenario JSON that sets
6 is merged **after** `masterConfig()` returns, and `finalizeConfig` re-resolves only `orbitClassConfig`,
`applyLuniSolar`, `applyInjectTruthSideDynamics` and `applyPerTowerHwBias` (`ConfigFactory.m:633-636`) — **not**
this block. Verified by grep: `finalizeConfig` touches `measurements.isl.*` only to stamp
`carrier.frequency_Hz` (`:1461-1468`).

Consequences, all confirmed against `i_baseDefaults`:
- `measurements.isl.product.enable` stays **false** (`:2666`) instead of the `true` at `:777` — **this is the
  mechanism of truth-leak L2**, whose honest cost is 0.003585 → 0.095183 m (×27 at 3600 s).
- `isl.code.sigma_m` stays 0.5 m (`:2576`) instead of 0.3 m; `isl.doppler.sigma_mps` stays 0.02 (`:2579`) instead
  of 0.05; `isl.enable`, `code.enable`, `doppler.enable`, `carrier.enable` all stay **false**.
- The block's own comment (`:747-748`) — "Helix swarm -> one-way ISL code+Doppler from each represented secondary
  aids the primary EKF (product-aided, honest)" — describes a configuration that **no scenario ever resolves to**.
  On isl016/isl017 the ISL Doppler row is absent entirely (the JSONs write `code` and `carrier`, never `doppler`).
- `config/golden_baseline_multi.json` is unaffected only because it explicitly writes
  `measurements.isl.enable = false`.

**Severity: high.** This is the single most consequential structural finding of this pass, because it is the root
cause of the known ISL truth-leak rather than a separate issue.

### LF-2 — The Monte-Carlo ensemble cannot run on any multi-asset architecture
`ReportRunner.runSingle` calls `runMonteCarloConsistency_` at `:1849`. But `runSingle` returns early to
`runIndependentFleet_` at `:112-116` and to `runFederatedSwarm_` at `:117-124`. Both of those functions construct
their output with **`'monteCarlo', struct('enabled', false)`** hard-coded — `:1890` and `:1957` respectively — and
neither calls `runMonteCarloConsistency_`. Therefore:
- `cfg.report.monteCarlo.enable = true` is **inert** for every swarm, federated or distributed run, regardless of
  what the JSON says.
- `MonteCarloConsistency`'s advertised Guard-C swarm centroid gate (`:12-18, :108-122, :139-158`) is unreachable
  from the report pipeline.
- Called by hand with a swarm cfg it would still be wrong: `:82-84` constructs
  `revgnss.ReverseGNSSSimulation(cfg)` directly, i.e. the legacy single-EKF-with-represented-secondaries path, not
  the federated architecture the swarm results come from.

**Severity: high.** Against ECSS-E-ST-60-10C p. 35 ("the only way to include ensemble type errors … is to have some
form of Monte-Carlo campaign"), every multi-asset result in this project is a single sample by construction.

### LF-3 — `ModelCoverageAudit`'s acceptance criterion cannot fail
`+revgnss/ModelCoverageAudit.m:15` states "nModelCategoriesMissingUnsafe must be 0 for complete model coverage
acceptance." The string `'missingUnsafe'` appears in exactly **two** quoted places in the file — the count at `:25`
and the blocking-items list at `:42`. **No `cat_(...)` call anywhere in `buildCategories_` ever assigns it.**
Therefore `nMiss` is structurally 0, `modelCoverageStatus` is always `'complete'`, and
`modelCoverageBlockingItems` is always empty. A test asserting `missingUnsafe == 0` is a tautology.

Two related defects in the same file:
- Category 1 hard-codes the literal note "single space asset; 5 ground towers; one-way uplink only;
  ISL/TWSTFT/two-way disabled and guarded" (`:56-58`) irrespective of `cfg`. On a G5S6R4 run with ISL enabled that
  sentence is false, and it is printed as audit output.
- `claimGate_`'s blocked-reason list (`:328-337`) is likewise hard-coded, including "Monte Carlo/NEES stochastic
  validation: disabled" — printed even on `golden_baseline.json`, where the ensemble does run.
- The header says "22 major model categories"; there are **29** `cat_` calls.

**Severity: medium.** The claim *gate* itself is honest — `allowRealWorldClaim` defaults false and the
`allowRealWorldClaim = true` branch requires seven real product modes that no parser exists for (`:341-372`), so it
blocks correctly. It is the *coverage* metric beside it that is decorative.

### LF-4 — The enum guard has a live bypass
`validateMasterConfig` (and therefore `i_validateEnums`) runs at `resolveSimulationConfig.m:76`, **before**
`finalizeConfig` at `:77`. `finalizeConfig` then writes mode strings that are never re-checked:
`applyAtmosphereProfile` (`:592`) promotes the whole `atmosphere.realisticProfile.*` mirror into the live
`errors.*` paths (see DC-6), `orbitClassConfig` (`:633`) can replace `cfg.towers` wholesale on the LEO path, and
the `towerClock.correctionMode → estimator.towerClockMode` derivation copies an unmatched string **verbatim**
(documented at `configEnumRegistry.m:119-124`). The registry validates the *input* to the derivation, which is the
right choice, but nothing validates the output of the profile promotion.
**Severity: medium** (live on the flagship path, which sets `atmosphere.realistic = true`).

### LF-5 — `cfg.realism.resolvePostMerge` is an unreachable knob
`ConfigFactory.m:646-652` reads `cfg.realism.resolvePostMerge` and, when true together with `realism.grade`,
applies `preserveScenarioOwned(cfg, @realismGradeConfig)` post-merge. The comment (`:640-645`) presents this as a
deliberately-default-off experiment: "Default OFF so it can be MEASURED (resolve each scenario both ways and diff)
before it is decided." But `validateMasterConfig.m:34-38` **hard-errors** on
`cfg.realism.resolvePostMerge = true` (`validateMasterConfig:postMergeRealismUnavailable`), and
`validateMasterConfig` runs on every production path (twice). The branch at `:651` is therefore **dead code via
`resolveSimulationConfig`**, and the measurement it invites cannot be performed without bypassing validation.

A second, related documentation defect: the comment at `ConfigFactory.m:630-632` justifies not relocating
`realismGradeConfig` on the grounds that "It is gated on nSpaceAssets >= 2 for its ISL blocks and masterConfig has
nSpaceAssets = 1 at call time." **`config/internal/realismGradeConfig.m` contains zero references to
`nSpaceAssets`** (verified: `grep -c` returns 0). Its ISL blocks are gated on `cfg.realism.include.{islProductSigma,
islCarrier, islLinkBudget}`, all defaulting true. The stated reason is wrong; the numbers quoted beside it (21 ISL
keys, 34 swarm scenarios, 62 keys, 46 scenarios) may or may not be, but they rest on that reason.
**Severity: medium** (a knob that documents an open scientific question and cannot be turned on; plus a
justification contradicted by the code it justifies).

### LF-6 — `mcSeedOffset` is silently ignored for every per-asset-seeded clock
`+revgnss/ConfigFactory.m:1957-1964`:
```matlab
receiverSeed = 100 + mcOff_;
if isfield(prev,'seed') && isnumeric(prev.seed) && isscalar(prev.seed) && ...
        isfinite(prev.seed) && prev.seed ~= 100
    receiverSeed = prev.seed;            % preserve an explicitly configured stream
end
```
`IndependentFleetScenarioFactory.assetConfigForIndex` sets `ci.asset.clock.seed = 100 + assetIndex` or
`300 + assetIndex` for `assetIndex >= 2` (`:67-73`) — never exactly 100 — so for every secondary the Monte-Carlo
offset is discarded and the clock truth realisation is **identical across all ensemble seeds**. Only asset 1
(`prev.seed == 100`) varies. The two intents ("preserve an explicit stream" and "vary the clock truth per MC
draw") collide, and the collision resolves silently in favour of the wrong one.
**Severity: medium, currently latent** — it can only bite through LF-2's unreachable path, which is itself the
larger problem. Fix them together or the fix for LF-2 activates this one.

### LF-7 — Silent-degradation survey (the `889dcf6` class), post-fix state
The four-timestamp fallback is now **recorded** (`SwarmRelativeSolver.m:157-161` sets
`shapeObservationSource` and `shapeFallbackReason`; `:1143-1147` the clock twin) and **printed**
(`FederatedSwarmSummary.m:110`, `SwarmReportReplay.m:382-384`). It is still not **asserted**:
- No test anywhere asserts `shapeObservationSource == 'fourTimestampTwoWayRange'` (verified by grep over
  `tests/`). The only test touching it, `tests/test_swarm_two_way_isl_gating.m:37`, **asserts the fallback**
  (`'syntheticTwoWayISL'`) — legitimately, since its fixture is synthetic with no replay payload, but the net
  effect is that the suite pins the degraded path and nothing pins the real one.
- The bug that ran for months (`getOscillatorDriftMetersPerSecond` missing → "Unrecognized method" → caught at
  `SwarmRelativeSolver.m:1294` → synthetic observable for every pair and epoch) would **not** be caught by the
  test suite today.
- Reachable-but-unaccounted updates: `ReverseGNSSSimulation.m:991` discards the diffAtt NIS (see DC-5).
- Counted, for calibration: `ReportRunner.m` contains 197 `catch` clauses, 130 of them bare `catch; end`.
  The overwhelming majority are optional config reads (`try; x = cfg.a.b; catch; end`) and are fine.
  `ReverseGNSSSimulation.m` has only 7, all documented, and the one that wraps computation
  (`capturePriorSnapshot_`, `:1039-1053`) explains in-comment why a failure must degrade only the new prior
  series — including a warning about the class's `diag` property shadowing `diag()`. That file is a model of how
  to do this; `ReportRunner` is not.

**Severity: medium.** The class is not closed; it is merely better instrumented.

### LF-8 — The regression goldens are not in the automated gate
`tests/run_all_tests.m:41-42` collects only `dir(fullfile('tests','test_*.m'))`. None of
`run_oo_v1_regression`, `run_swarm_relative_regression`, `run_distributed_fleet_regression` or
`run_multi_islcarrier_regression` matches that pattern, and no `tests/test_*.m` invokes them (verified by grep;
the single hit, `tests/test_isl_lighttime.m`, mentions a regression only in prose). Additionally, the **default
mode is `'fast'`**, which skips 11 tests including `test_mc_consistency_harness` (`:120`), so the Monte-Carlo
machinery is not exercised per change either. The path-shadowing guard (`:33-40`) is excellent and its incident
history is documented; the coverage gap is separate from it.
**Severity: medium** — the strongest regression evidence in the repository is opt-in and manual.

### LF-9 — Smaller items, verified
- `ReportRunner.runSingle:145` unconditionally sets `cfg.plots.enable = writePdf`, overriding whatever the caller
  configured. Harmless today (`MonteCarloConsistency` sets both false at `:66-68`) but it is an override without a
  warning.
- `ReverseGNSSEKF.computeNEES` (`:968`) has **no production caller** — the only invocation in the tree is
  `tests/test_filter_consistency_nees_nis.m:97`. The numbers that reach the report and the MC harness come from
  `SimulationDataStore.m:1071-1105`, a *different* implementation. So the tested API is not the shipped one; this
  is the same divergence the v4 review logged as M8 for `NEES_att`.
- `configEnumRegistry.m` correctly records `'seededTruthResidual'` as shipped-but-inert (`:57-61`), meaning two
  scenario presets silently mean `'zero'`. Documenting an inert value in the validator is better than nothing but
  is not the same as removing it.
- `config/internal/scenarioResolutionExceptionRegistry.m` is a **positive** finding: the one exception class it
  permits is an orientation-only normalisation with identical values, the reason is written out in full, and the
  header instructs that it be kept as close to empty as possible. That is the correct design for an
  exception list.

---

## Limits of this domain

Concrete and quantitative statements of what this architecture may **not** claim.

1. **No validation in the NASA-STD-7009A sense has been performed, and none is possible with the current code.**
   No real-world measurement data is ingested anywhere; `ModelCoverageAudit.claimGate_` blocks the claim on seven
   missing product parsers (SP3, CLK, RINEX, ANTEX, IONEX, IERS EOP, bias). Only *Verification* — "determining the
   extent to which an M&S is compliant with its requirements and specifications" (NASA-STD-7009A, p. 15) — is in
   evidence.

2. **No multi-asset result is statistically supported.** LF-2: the ensemble machinery is hard-off for every
   federated, distributed and swarm architecture. Every ISL, formation-shape, relative-clock, beamforming and
   distributed-EKF number in this project is **one deterministic sample**. Against ECSS-E-ST-60-10C p. 35 that is
   insufficient by the standard's own words for anything with ensemble-type error.

3. **The single-asset headline is supported by 12 seeds × 900 s, not by the declared campaign.**
   `golden_baseline.json` runs `nSeeds = 12, duration_s = 900, confidence = 0.99`; the manifest declares 200
   short-ensemble and 50 full-scenario independent runs (`masterConfig.m:597-601`) and labels itself
   `'declaredNotStatisticallyExecuted'`. The gap is a factor of ~17 in seeds and 4 in arc length. Every
   `acceptanceCriteria` limit is `NaN`, so no pass/fail threshold has ever been declared for position or clock
   accuracy.

4. **Any ISL-aided absolute accuracy quoted from a rung that leaves `measurements.isl.product.enable = false` is
   an oracle result.** The honest twin is a factor of **27 worse at 3600 s** (0.003585 → 0.095183 m) and **36 worse
   at 600 s** (→ 0.130883 m). Because of LF-1 this is the *resolved default* for any swarm scenario that enables
   ISL without explicitly writing the product block, not an opt-in mistake.

5. **The relativistic clock ramp cannot be claimed as "modelled and estimated".** Truth and model both derive
   `y_rel` from `cfg.orbit.altitudeMean_m` through the same function, so 581 m of clock bias over a 3600 s arc
   cancels **exactly** in `z − h`. That is a legitimate published-constant correction, but it is a matched pair,
   and the residual the filter actually estimates is the oscillator's own error only.

6. **The federated relative layer is a simulation-internal demonstration, not end-to-end measurement processing.**
   `TruthEndpointReplay` feeds recorded truth position, velocity, attitude and clock into the four-timestamp
   chain. Since `889dcf6` it feeds *more* truth-derived physics than before, because the real chain now runs. The
   sign/scale check at `SwarmRelativeSolver.m:1305-1330` validates the observable **against the same recorded
   truth** it was built from — it can catch a sign error and nothing else.

7. **The enum guard covers roughly 40 % of the string-valued dispatch surface.** 28 registry entries against ≥65
   `mode`/`modelType`/`model`/`policy`/`kind`/`protocol`/`observable` leaves in `masterConfig.m` alone. A typo in
   any unregistered leaf still takes a silent default branch and is still printed verbatim as the active model.
   The `atmosphere.realisticProfile.*` mirror is a live bypass even for registered paths (LF-4, DC-6).

8. **"The goldens pass" is not a per-change statement.** None of the four regression scripts runs in
   `run_all_tests`, and the default `'fast'` mode skips the Monte-Carlo harness. What a golden *does* assert is
   correctly scoped by `GoldenRunFingerprint.m:13-15`: "It is not a claim that the numbers are RIGHT. It is a
   claim that they have not MOVED." The one place the new goldens exceed that is
   `linkUpdateMovedState = 1`, which does assert that the sanctioned ISL link update still changes the owner's
   state (by `max|ΔX| = 56.957 m`, loosening covariance by `max|ΔPdiag| = 2.44e5`).

9. **Per-epoch NIS pooling assumes epoch independence, which is measured false for at least one channel.**
   `MonteCarloConsistency.m:95-97` pools per-epoch NIS as if independent. The per-channel table added in `91faccb`
   reports lag-1 autocorrelation 0.09–0.30 for code/carrier/Doppler (N_eff ≈ 1960–3006 of 3601 epochs) but
   **ρ = 0.7254, N_eff = 573** for the two-way channel, consistent with the 30 s broadcast-product cadence. Any
   two-way consistency verdict rests on ~573 independent samples, not 3601.

10. **Joint multi-asset mode is disallowed by policy only.** Nothing in the config resolution rejects
    `multiAsset.mode = 'joint'` outside the distributed path; three shipped test fixtures still select it and the
    joint branches in `ReverseGNSSSimulation` are live. If the constraint is real it should be an assertion in
    `validateMasterConfig`, where it would cost one line.

11. **The RNG guarantees an arc of at most 1 048 575 epochs.** Beyond that the epoch field wraps
    (`RngRegistry.m:106`), and at exactly `epochIdx = 2^20 − 1` an epoch stream collides with the persistent
    stream of the same identity. 12.1 days at dt = 1 s — far outside any run, but it is a modular wrap with no
    guard, not a bound.

12. **Config text alone does not determine a run** on any j2-truth/two-body-EKF scenario: `finalizeConfig`
    silently replaces `modelMismatch.sigma_mps2 ≤ 1e-6` with `max(1e-8, 0.25·|a_J2|)`, and with the propagator off
    would silently replace it with 1e-8 — 100× *smaller* than the shipped default. The persisted resolved `cfg`
    in the run `.mat` is the only authoritative record.

---

## Sources used in this section (APA 7)

- Brown, R. G., & Hwang, P. Y. C. (1997). *Introduction to random signals and applied Kalman filtering* (3rd ed.).
  Wiley. [`Paper/Error Calculation/KalmanFilter/Brown.pdf` — **SCAN, no text layer**; quotes transcribed from
  rendered pages: p. 94 (Gauss–Markov definition), p. 201 (Eq. 5.3.9), p. 202 (Eq. 5.3.16), p. 210 (Monte Carlo
  method). PDF is two-page spreads: printed page ≈ 2·(spread index) − 10.]
- European Cooperation for Space Standardization. (2008). *ECSS-E-ST-60-10C: Control performance* (pp. 19, 35).
  ESA-ESTEC. [`Paper/Error Calculation/ECSS-E-ST-60-10C(15November2008).pdf` — both quotes re-verified verbatim by
  text extraction; note the source uses a non-breaking hyphen in "Monte‐Carlo", which defeats a naive grep.]
- Montenbruck, O., & Gill, E. (2000). *Satellite orbits: Models, methods and applications.* Springer.
  [`Paper/Fundamental Books/04_Montenbruck_2000_SatelliteOrbits.pdf` — pp. 286, 294, both re-verified verbatim.]
- NASA. (2016). *NASA-STD-7009A w/Change 1: Standard for models and simulations.* National Aeronautics and Space
  Administration. https://standards.nasa.gov/sites/default/files/standards/NASA/w/CHANGE-1/1/nasa_std_7009a_change_1.pdf
  [EXTERNAL — Empirical Validation p. 12 of 72; Verification p. 15 of 72. **Corrects the wording the existing
  document attributes to §3.2.**]
- Salmon, J. K., Moraes, M. A., Dror, R. O., & Shaw, D. E. (2011). Parallel random numbers: As easy as 1, 2, 3.
  In *Proceedings of SC'11* (Article 16, p. 1). ACM. [EXTERNAL]
- Bar-Shalom, Y., Li, X. R., & Kirubarajan, T. (2001). *Estimation with applications to tracking and navigation.*
  Wiley. [EXTERNAL — cited in-code at `ChiSquareConsistency.m:2-4`, §5.4 consistency tests.]
- Wilson, E. B., & Hilferty, M. M. (1931). The distribution of chi-square. *PNAS, 17*(12), 684–688.
  [cited in-code at `ChiSquareConsistency.m:15-17` for the toolbox-free `chi2inv` fallback.]
- Effective sample size for an AR(1) series, `N_eff = N(1−ρ)/(1+ρ)`, as implemented in
  `ConsistencyStatistics.groupStat_` (added `91faccb`). [EXTERNAL — standard result; see e.g. the effective-sample-size
  treatment at https://andrewcharlesjones.github.io/journal/21-effective-sample-size.html and the general
  `N_eff = N/(1 + 2Σρ_t)` form in the Stan Reference Manual, §Effective Sample Size.]

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

---

# Appendix B — Round-2 corrections to the source inventory

The 84-document coverage map of the first edition (Appendix A) stands, with the following corrections and
additions established during re-verification.

## Sourcing corrections (first edition was wrong or unverifiable)

| Source | First edition | Corrected status |
|---|---|---|
| Van Dierendonck, McGraw & Brown (1984), *Relationship between Allan variances and Kalman filter parameters* | quoted as if read, "transcribed from the page scan" | **Not present in `Paper/`.** Those quotes were unverifiable in-repo. Worse, Brown & Hwang state that VD's eq. (60) `q₁₂`/`q₂₂` are **wrong**, so the first edition anchored the clock Q on a known-erroneous form. **Legitimate in-repo path**: Winkel (2003) eq. (2.154), p. 99 cites `[DMB84]` and gives `S_y(ω) = 2π²h₋₂/ω² + πh₋₁/ω + h₀/2`, which corroborates the `q₁ = h₀/2`, `q₂ = 2π²h₋₂` mapping directly. This edition re-anchors the clock Q on **Brown & Hwang Ch. 11**, transcribed from the scan. |
| Brown & Hwang (1997), Ch. 11 | "scan, no text layer" — used only indirectly | **Fully legible as rendered page images.** Eqs. (11.3.1)–(11.3.5), the flicker footnote and Table 11.2 were transcribed this round, turning the two-state clock Q from an indirect citation into a **primary, page-referenced verification**, and independently corroborating three of the eight catalogue rows. Page mapping for anyone re-checking: **PDF page n = book pages 2n−12 / 2n−11.** |
| Hofmann-Wellenhof, Lichtenegger & Wasle (2008) | listed as a scan with no text layer | **Has a usable text layer** (verified twice, byte-identical extraction). Quotes at pp. 112, 179–180, 218 were taken mechanically, not transcribed. |
| "The Global Positioning System — Signals, measurements, and performance" | corrected in the first edition already | Confirmed again: this is **Enge (1994)**, a 23-page journal article, **not** the Misra & Enge textbook. Cite accordingly. |

## External sources newly required in round 2

The two new physics modules pulled in standards that are not in `Paper/`:

- **ITU-R Recommendation P.676** (gaseous attenuation by atmospheric gases) — required by
  `+models/+atmosphere/GaseousAbsorption.m` and `analysis/p676_annex1.m` / `p676_annex2.m`. Retrieved
  externally (P.676-10 text; the repo's frozen table claims P.676-13 Annex 1). Note the validity floor:
  **P.676 states a lower frequency bound of 1 GHz**, so the 915 MHz entry in the frozen table sits below
  the recommendation's stated range.
- **ITU-R Recommendation TF.1153-4** (operational use of two-way satellite time and frequency transfer) —
  retrieved from itu.int for the TWSTFT equation, the Sagnac correction `SCD(k) = (Ω/c²)[Y(k)X(s) −
  X(k)Y(s)]` and its worked example (SCD +99.10 ns / −95.22 ns, SCT +194.32 ns), the ionospheric
  asymmetry bound (≈ −0.11 ns at Ku) and the tropospheric one (< 10 ps).

## Papers that remain unused, and why that is now a stated limit rather than an omission

The `Link BUdget/` interference papers (RFI, OFDMA margin, receiver performance under interference) still
verify nothing, because **the simulation has no interference or jamming model at all**. In the first
edition this was recorded as "N/A"; it is more honest to record it in the limits register: the link budget
closes against thermal noise and gaseous absorption only, so no availability, integrity or
interference-robustness claim is supportable from this simulation.

---

# Appendix C — How to re-verify this document

Everything asserted here is meant to be checkable by a third party without re-running the audit. This
appendix gives the mechanics. The document is pinned to **`feature/ground-orientation-exec` @ `170e37d`**;
if HEAD has moved, re-check line numbers first — that is the failure mode this edition itself had
(see §B9).

## 1. Pin the tree

```bash
cd oo_v1 && git log -1 --format='%h %s' && git status --short -- '*.m'
```

Every `file:line` in this document was read at `170e37d` with no dirty `.m` file. Line numbers drift; if
`git diff` shows movement in a cited file, locate the anchor by symbol rather than by number.

## 2. Re-check a code citation

Line references are of the form `+models/+errors/ErrorChain.m:875`. Prefer an anchored search over a
naked line number, because it survives drift:

```bash
grep -n "sigmaBase = sigmaBase \* rScale_" +models/+errors/ErrorChain.m
```

## 3. Resolve the configuration a finding claims to be live in

Liveness labels (LIVE-IN-GOLDEN / LIVE-IN-LADDER-ONLY / LATENT-DEFAULT-OFF / UNREACHABLE) were decided by
resolving the real config, not by reading `masterConfig` defaults — which is essential, because scenario
JSONs routinely override them:

```bash
matlab -batch "addpath('config','config/internal'); \
  cfg = resolveSimulationConfig('golden_baseline.json'); \
  disp(cfg.estimation.troposphereMode); disp(cfg.estimation.ionosphereMode); \
  disp(cfg.measurements.codeMode); disp(cfg.measurements.isl.enable)"
```

This is how §A2 established that the golden baseline really does run `perTowerZwd`, and how §A4
established that the golden runs `singleFrequency` (so the iono-free multipath defect is ladder-only).

## 4. Re-derive a numerical claim

The quantitative claims are closed-form and independent of any run. Two worked examples:

```matlab
% A1 - is R's ionosphere term exactly sqrt(Q) for the slant-iono state?
tau = 600; dt = 1; sigma_ss = 1.0;
q_iono  = sigma_ss^2 * (1 - exp(-2*dt/tau));      % ReverseGNSSEKF.m:1615-1616
rScale  = sqrt(1 - exp(-2*dt/tau));               % ConfigFactory.m:2692
R_iono  = (sigma_ss * rScale)^2;                  % ErrorChain.m:875
fprintf('ratio R/Q = %.15g\n', R_iono / q_iono);  % -> 1
```

```matlab
% A4 - iono-free multipath under-charge factor
f1 = 1575.42e6; f2 = 1227.60e6;
a = f1^2/(f1^2-f2^2); b = -f2^2/(f1^2-f2^2);
fprintf('alpha+beta = %.6f   alpha^2+beta^2 = %.4f\n', a+b, a^2+b^2);  % 1.000000, 8.8700
```

## 5. Verify a source quote

Quotes are verbatim with page numbers. Extract the text layer and search:

```bash
python3 -c "import fitz,sys; d=fitz.open(sys.argv[1]); \
  print(chr(12).join(p.get_text() for p in d))" "<path to pdf>" > /tmp/src.txt
grep -n "the fragment you are checking" /tmp/src.txt
```

**Two extraction traps cost this audit several false alarms** and will cost yours the same:
- **Ligatures.** "first" is often stored as "ﬁrst", "fluctuation" as "ﬂuctuation". Search on a substring
  that avoids `fi`, `fl`, `ff`.
- **Line-break hyphenation.** "wavelength" may appear as "wave- length", "one-sided" as "one- sided".
  Collapse whitespace before matching: `re.sub(r"\s+", " ", text)`.

Four sources have **no text layer** and must be read as rendered images (the Read tool renders PDF pages,
or use `fitz` `get_pixmap`): Brown & Hwang; and see Appendix B for the page mapping
(**PDF page n = book pages 2n−12 / 2n−11**). Quotes taken this way are marked "transcribed".

## 6. Reproduce a measured (run-dependent) claim

A minority of claims required a live run — the multipath correlation-time measurement (§A5), the
four-timestamp relativistic probe (§A10), the per-source charged-vs-actual variance table quoted from
`03da4fb`. These are labelled as measured and state their configuration. Re-running them means resolving
the named config and instrumenting the named function; they are the least portable claims here and should
be treated as the ones most in need of independent replication.

## 7. What the regression gate does and does not prove

```bash
matlab -batch "addpath('tests'); run_all_tests"
```

`tests/run_all_tests.m` globs `tests/test_*.m` only. Three consequences that recur throughout this
document:
- `tests/regression/run_swarm_relative_regression.m` and `run_distributed_fleet_regression.m` are **not**
  collected by it — they must be run by hand.
- The golden fingerprints assert that numbers **have not moved**, not that they are **right**
  (`GoldenRunFingerprint.m` says so in as many words).
- A test can be green and still pin a degraded path: `tests/test_swarm_two_way_isl_gating.m:37` asserts
  the *fallback* observable string (§B1).

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

### Added in round 2

- International Telecommunication Union. (2022). *Attenuation by atmospheric gases and related effects*
  (Recommendation ITU-R P.676-13). ITU-R. [EXTERNAL — required by `GaseousAbsorption.m`; note the
  recommendation's stated 1 GHz lower frequency bound]
- International Telecommunication Union. (2015). *The operational use of two-way satellite time and
  frequency transfer employing pseudorandom noise codes* (Recommendation ITU-R TF.1153-4). ITU-R.
  [EXTERNAL — TWSTFT equation, Sagnac correction and worked example, ionospheric/tropospheric asymmetry bounds]

### Corrected in round 2

- Van Dierendonck, A. J., McGraw, J. B., & Brown, R. G. (1984). Relationship between Allan variances and
  Kalman filter parameters. *Proceedings of the 16th PTTI Meeting*, 273–293. **Not held in `Paper/`.**
  Reachable in-repo only indirectly, as `[DMB84]` cited by Winkel (2003) eq. (2.154), p. 99. Brown & Hwang
  state that VD's eq. (60) `q₁₂`/`q₂₂` are wrong; the clock Q in this edition is anchored on Brown & Hwang
  Ch. 11 directly.
