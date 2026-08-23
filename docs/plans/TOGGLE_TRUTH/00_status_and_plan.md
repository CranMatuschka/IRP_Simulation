# Status and plan — report truthfulness, attitude, TW1, relative layer, plots

Branch `feature/ISL-LAMBDA`. Written 2026-07-27 after the toggle/attitude audit.

Everything below is either **MEASURED** (a number from a run, quoted) or **READ** (a file:line
in the source). Nothing is inferred. Where an earlier claim of mine was wrong it is marked
CORRECTED, because several of them were.

---

## 1. Shipped and verified

| # | Change | Evidence |
|---|---|---|
| 1 | `multiAsset.keepIslInPerAssetEkf` toggle (default false) | nx 60→65, rows/epoch 100→110; `tests/test_keep_isl_in_per_asset_ekf.m` 4/4 |
| 2 | Per-asset leaf re-dispatch fix (`perAssetLeaf` marker) | PDF compiles again; `tests/test_per_asset_leaf_no_redispatch.m` 5/5 |
| 3 | `ReportRealityHelper` B1/B2 blockers (ISL ambiguity states in `expectedStates`; stale carrier guard) | max-realism PDF 1.7 MB written |
| 4 | KAV sub-run collapsed to 1 asset | prevents a nested N-worker `matlab -batch` fan-out |
| 5 | `refAsset ≠ 1` warning under `keepIslInPerAssetEkf` | phantom-helix neighbours would otherwise ship silently |
| 6 | Sat-sat TWSTFT stripped from per-asset leaf configs | removes a toggle-dependent load failure |
| 7 | 29 manifest rows (`Crosslink`, `IntegerAR`) | manifest 168 → 197 rows |
| 8 | Ionosphere report row rewritten off the live gates | `tests/test_atmosphere_report_row_truth.m` 5/5 |

Golden gate PASS (184 core metrics, `coreFail = 0`) after every one of these.

**CORRECTED — item 8 is still wrong.** It gates on
`measurements.code.ionosphereFreeRows.enable/useInEkf`, which are **dead keys**: their only
non-test consumer is an unreachable fallback at `CodeMeasurementBuilder.m:551-556`, dead because
`codeMode` is always non-empty (`masterConfig.m:1728`). The real behaviour, measured on both
target scenarios: **first-order ionosphere survives on CODE rows** (`codeMode='singleFrequency'`)
and **cancels on CARRIER rows** (`CarrierIonoFreeRowBuilder.shouldCombine = 1`). The row must say
both. Redo under §3.1.

---

## 2. Diagnosed, root cause known, NOT yet fixed

### 2.1 Attitude divergence — root cause found

**Not the attitude path.** It is the unmodelled truth-side inter-antenna carrier bias
(realism R-6, `errors.interAntennaCarrierBias.enable`, 0.25 cycles ≈ 4.8 cm at L1, injected at
`CarrierMeasurementBuilder.m:231-241`). Carrier attitude uses between-antenna phase differences,
so a constant per-antenna offset sits directly in that difference and never averages out.

Ablation, `scene_G5S1R4_ts3600_TW1_inc`, carrier partials only, seed 42 (final / q4÷q1):

| case | final | q4/q1 |
|---|---|---|
| truth bias ON, no model | 9.0766° | 1.286 diverging |
| **truth bias OFF** | **0.2177°** | **0.188 converging** |
| truth ON + `fixedKnown` | 9.0766° | **bit-identical to no model** |
| truth ON + `calibratedProduct` | 9.0766° | **bit-identical to no model** |

**The calibration model is inert.** `InterAntennaPhaseBias.hasModel()` passes on `enable`+`mode`
alone, but `lookupMeters_` reads `bias_cycles`/`bias_m`, both defaulting to `[]`
(`masterConfig.m:1422-1423`) → correction exactly 0, while `resolvedStatus()` reports
`'calibratedExternalProduct'`. **No generator populates those arrays anywhere.**

**One root cause, three symptoms.** `ConfigFactory` derives
`diffAtt.ambiguityResolution.phaseBiasStatus` from `resolvedStatus()`;
`'notCalibratedExternalProduct'` makes `BaselineCarrierAmbiguityResolver` reject all 15 baselines
(`rejectedPhaseBias`), and `partialFixPolicy='useFixedOnlyOrExplicitMixed'` discards rather than
using the float → **0 diffAtt rows / 301 epochs** → `attitudeCarrierMode` on-vs-off is
bit-identical.

Seed replication (3 seeds, 3600 s), q4÷q1 per seed / median final:

| path | ratios | median | verdict |
|---|---|---|---|
| carrier only | 1.286, 1.859, 1.285 | 4.57° | diverges 3/3 |
| pseudorange only | 2.833, 1.189, 0.374 | 3.14° | **unreliable, diverges 2/3** |
| both | 0.564, 0.227, 0.458 | 0.76° | converges 3/3 |

**CORRECTED (twice).** I first read this as "pseudorange does the work, carrier is dormant" —
backwards. I then recommended "use both partials" off a single seed. Neither is the fix:
calibrating the bias gives 0.22°, ~3× better than both-partials and ~14× better than pseudorange.

### 2.2 TW1 cross/along "divergence" — answered, no filter bug

Same-seed pairs: along/cross **unchanged** (+3%); radial 20.968 → 0.487 m, clock 20.968 →
0.0034 m. The H row was verified empirically to have exactly one non-zero column (+1 on `b_rx`).
Two real effects:
1. **Plot autoscaling** — removing the 20-50 m radial/clock error tightens the shared axis ~50×,
   so pre-existing 4-6 m along/cross wander fills the frame. Bounded, not diverging (quarterly
   along rms 4.45, 5.01, 5.44, 4.11).
2. **Code-row ionosphere** is the actual driver. Ablation at 600 s TW1: along/cross 3.677/2.599
   (full) → 1.147/0.994 (iono off) → **0.140/0.102 (both off)**.

Small genuine effect worth reporting: TWTT shaves along-track σ 14% (0.84 → 0.72 m) through
`P(along, b_rx)` **without adding along-track information**, so err/σ rises 5.08 → 5.33.

**CORRECTED.** My hypothesis was "the clock was absorbing residual and now it has nowhere to go."
Wrong — along/cross are unchanged.

### 2.3 Toggle table — 32 rows audited

12 AGREE, 12 PARTIAL, 8 STALE. Confirmed stale/hardcoded: `Ground segment geometry` and
`Receiver clock (spacecraft)` read **no config at all**; `Carrier phase enabled` reads
`carrierPhase.enable` when the real gate is `carrierMode`; `Per-tower hardware delay: no
dedicated EKF state in v1` is false (`txCodeBias.useInEKF` adds 5 states); `LAMBDA: Not impl.`
stale on this branch.

**On "matched".** Confirmed: Shapiro "matched" is a genuine no-op (zero to 2.1e-9 m) — the user
is right that it adds nothing. But ionosphere "Matched" was measured still producing **1.3-3.0 m**
of residual, so that label was lying outright. And a third channel exists: with the atmosphere
fully OFF (row prints "Disabled") `ErrorChain` still charges σ_iono = 5.78/2.06/1.26 m at
10/30/60° into **R** — **79-91% of the total measurement variance** in the default run. So a
single binary status cannot be honest. Design: **three binary columns**, each genuinely on/off:

| effect | truth (bias into z) | model (correction in h) | noise (variance into R) |

### 2.4 Relative layer never shown

Gated by exactly one key, `multiAsset.twoWayISL.enable` (`masterConfig.m:1045`, default false),
read at `SwarmRelativeSolver.m:47`. It is a **pure config gate** — the solver needs no observables
it lacks. `scene_*.json` never set it, so every swarm report prints
`-- (two-way ISL shape disabled)`.

### 2.5 `realismGradeConfig` ordering trap

`run_oo_v1.m:31` calls `masterConfig()`, which applies `realismGradeConfig` **internally** at
`masterConfig.m:665`; the scenario JSON is merged afterwards at `run_oo_v1.m:42`. So
`"realism": {"grade": true}` in a JSON **can never trigger it**. Consequence: the `islCarrier` /
`islLinkBudget` blocks added to the realism overlay never execute for any JSON-driven run.
`"directOverlay": true` in the `_inc` files documents this, and is itself referenced nowhere.

### 2.6 The 26-run campaign is largely inert

- `_islekf` variants: `keepIslInPerAssetEkf` set, but `scene_*.json` never enable
  `measurements.isl` → nothing to keep, nx stayed 59.
- `_attoff` variants: bit-identical (§2.1).
- realism ISL additions: never fired (§2.5).

Only `max_realism_G5S6R4_ts3600` carries the ISL stack (nx 65, shape 0.0698 m, baseline 0.0179 m,
relative clock 58.9 ps) because its ISL keys are written explicitly.

---

## 3. Plan

Ordered by dependency. Each step ends with the golden gate and a test.

### 3.0 UPDATE 2026-07-27b — attitude is PARKED, two approaches rejected

Both candidate fixes were designed and then **refuted by their own adversarial review**. No code
was written for either. Recorded so nobody re-treads this:

**Calibration product — rejected (8 blockers).** It would move the `golden_realism_*` family
(which has the truth bias ON by construction); it silently nullifies R-6 in 55 committed scenario
configs and invalidates two analysis ladder tools; `residual_cycles` is an uncited free parameter
that *linearly* sets the headline attitude number (at ~0.005 cyc the answer drops BELOW the
bias-off floor, i.e. the knob can be tuned to make realism beat the ideal case); and it does not
remove the error, it rescales it into the same unobservable direction with R untouched. It also
rests on a premise — "a constant bias is absorbed by the float ambiguity, only drift leaves a
residual" (`masterConfig.m:1411-1412`, `CarrierMeasurementBuilder.m:226-230`,
`scientific_correctness_review_v5.md:84`) — that is **refuted by our own evidence**: drift is OFF
in every config that produced the 9.08° divergence. **That claim needs retracting wherever it
appears.**

**Between-tower double difference — rejected as designed (4 blockers).** The idea is sound and
the bias cancellation is exact (`‖DD rows‖ = 0.000e+00` against `‖SD rows‖ = 0.1346 m`), but:

- **My "DD is 1.9× stronger" claim was WRONG.** The 30-row all-pairs block has `rank = 12 of 30`,
  so its `R = D·R_raw·Dᵀ` is **singular** and unusable. On the usable 12-row fixed-reference set,
  whitened with the correct R: `trace(F⁻¹)` **SD = 16.24 vs DD = 48.08** → the DD is **2.96× worse
  in attitude variance, 1.72× worse in RMS angle**. The DD is an ACCURACY fix that COSTS precision.
  Honest target ≈ 0.25°, i.e. near the 0.2177° bias-off floor, never below it.
- **As specified it is an exact no-op**: reusing the float ambiguity states makes the DD ambiguity
  columns full row rank, so the attitude Schur complement is zero.
- **Sequential update double-counts** — DD rows added on top of carrier rows the main update
  already consumed are the same photons twice.
- Useful artefact: with correct R the Fisher information is **exactly invariant to reference-tower
  choice** (3.5e-17); with diagonal R it varies 1.49×. That is a free, decisive unit test for any
  future attempt.

A viable version exists — a `DoubleDiffAttitudeBuilder` mirroring the working SD structure
(attitude-only Jacobian, DD ambiguity held as a calibrated constant outside the filter, replacing
rather than supplementing the undifferenced rows) — but it is NOT started.

**Also found: `golden_realism_*` fails 20 core metrics on this branch and did so BEFORE any of
this session's edits** (verified by stashing). `singleAssetAttitudeErrorNorm_deg` golden 4.866 vs
current 0.737. That family has not been a working gate. Needs its own fix/re-freeze commit.

### 3.0b UPDATE 2026-07-27c — what the toggles do in the BACKGROUND

The report's toggle table is now truthful (§1 item 8, commit `2f30967`). This section is the
separate question: **which config keys silently do nothing, and which silently override which.**
All verdicts MEASURED through `masterConfig()` → `ConfigFactory.finalizeConfig()`.

**The structural cause of all of it.** `run_oo_v1.m:31` calls `masterConfig()`, which writes
every leaf AND runs both derivation steps — `expandEnableToggles` (`masterConfig.m:163`) and
`realismGradeConfig` (`masterConfig.m:665`) — and only THEN, at `run_oo_v1.m:42`, is the
scenario JSON merged. So both derivations run **before they can see what the user asked for**,
and after the merge a `false` written by masterConfig is byte-identical to a `false` written by
the user. That single ordering fact produces groups B and C below.

#### Rank 1 — the atmosphere overlay OVERRIDES the individual enables
`cfg.atmosphere.realistic` defaults **true**, and `applyAtmosphereProfile` →
`realisticAtmosphereConfig` runs in `finalizeConfig` (i.e. AFTER the merge), setting the
atmosphere keys **unconditionally**. Measured — the user writes, the run resolves:

| user wrote | resolved to |
|---|---|
| `errors.ionosphere.enable=false` (+truth,+model) | **1 / 1 / 1** |
| `errors.ionosphere.scintillation.enable=false` | **1** |
| `errors.{iono,tropo}.stochastic.enable=false` | **1 / 1** |
| `estimation.troposphereMode='none'` | **'perTowerZwd'** |
| `measurements.codeMode='ionosphereFree'` | **'singleFrequency'** (clobbered, `ConfigFactory.m:576`) |

And with `realistic=false`, `atmosphere.ionosphereFree=true` and `estimateIono=true` are
**silently ignored** (`applyAtmosphereProfile` returns at `ConfigFactory.m:537-540`).

**Why this is rank 1:** it owns the headline result. The 11.4 m floor is ionosphere-driven, and
the obvious way to ablate it — `errors.ionosphere.enable=false` — is a NO-OP, so the ablation
reads back "the ionosphere is not the cause". The working lever is
`cfg.atmosphere.ionosphereFree`, which is what the `_iffree` twins use.

#### Rank 2 — `errors.<effect>.enable` from a JSON is a SILENT NO-OP
`expandEnableToggles` slaves twelve effects' `.truth.enable`/`.model.enable` to one master
`.enable`, correctly — but runs pre-merge. Measured, JSON setting only the master:

```
errors.multipath.enable=true       -> enable=1  truth=0  model=0   NO-OP
errors.hardwareDelay.enable=true   -> enable=1  truth=0  model=0   NO-OP
effects.towerSurvey.enable=true    -> enable=1  truth=0  model=0   NO-OP
effects.antennaPCV.enable=true     -> enable=1  truth=0  model=0   NO-OP
physics.relativity.clock.enable=1  -> enable=1  truth=0  model=0   NO-OP
```

Physics and report both read the PAIR, never the master, so the config says on, the run does
nothing, and the report honestly says off. `config/scenarios/realism.json` already works around
this by hand-writing all three keys per effect — that triple-write is the workaround, not the design.

#### Rank 3 — `realism.grade` from a JSON is a COMPLETE no-op
`masterConfig.m:664-666` is the ONLY read of `cfg.realism.grade` in the codebase, and it runs
pre-merge. Measured with `realism.grade=true` set after `masterConfig()`:
`clock.templateSource=legacy` (realism wants `jowTable2p1`), `codeNoise.model=constant` (wants
`cn0`), `errors.multipath.enable=0` (wants 1), `clocks.tower.product.sigmaBias_m=0.01` (wants 0.10).

**CONSEQUENCE FOR OUR OWN SCENARIO — disclose:** the `scene_*_inc` family hand-copies every
realism value, so those runs ARE realism-grade. **`config/scenarios/max_realism_G5S6R4_ts3600.json`
does NOT hand-copy** — it sets `realism.grade` + a `_realism` note claiming R-1..R-10 and
relies on the flag. So that run is **realism-labelled and realism-free**: its atmosphere is
realistic (that overlay runs in finalizeConfig) but the caesium clock, IGS-RTS tower product
sigma, C/N0 weighting and truth systematics are NOT applied. Any number quoted from it must
not be described as realism-grade.

`realism.directOverlay` has **zero consumers** — it is a comment shaped like a switch.
`masterConfig` documents 14 `realism.include.*`; `realismGradeConfig` defaults **18**
(`islCarrier`, `islLinkBudget`, `point34` undocumented).

#### Rank 4 — two signals ⇒ IF combination
Partly derived, partly hardwired, partly dead. `measurements.code.ionosphereFreeRows.*` are
DEAD keys (only consumer unreachable); the live gates are `measurements.codeMode` for code and
`CarrierIonoFreeRowBuilder.shouldCombine` for carrier, and **they disagree by default**
(code raw, carrier IF). Now reported correctly in the table.

#### The proposed fix — and why it is NOT applied yet
A tri-state sentinel (`[]`/`'auto'` = derive, anything else = the user meant it) plus a
provenance set from `i_deepMerge`, resolved in one post-merge `resolveCoupledDefaults` pass at
the top of `finalizeConfig`. That location alone cures ranks 2 and 3, which exist only because
their resolution runs pre-merge.

**Adversarial review REFUTED the auto-rules as drafted**: they would hard-error three committed
scenarios (`ideal_G5S1R4_ts3600_flat*.json`, `baseline_G5S1R4_ts3600_clocksZero.json`, which
legitimately write `realistic=false` together with explicit `ionosphereFree`/`estimateIono`) and
the golden fixture. Needs reworking before implementation.

**Also found:** `revgnss.SimulationToggleManifest` has exactly ONE consumer in the repo —
`tests/test_code_dcb_active_path.m:89`. Neither the report builder nor `ReportRunner` reads it,
so the 29 manifest rows added in `d187c47` appear in NO pdf. The table the user sees is the
`ClockExactReportBuilder` one fixed in `2f30967`.

### 3.0c UPDATE — the +-3 sigma over-confidence, ANSWERED

The flat +5.5 ps/s clock-drift offset is the **relativistic clock rate**, and it is
**deliberately unmodelled**: `ClockModel.m:80-87` states the offset is "deliberately NOT part of
fracFreq ... reaches the truth pseudorange as an (initially) unmodelled relativistic clock-rate
signature". Truth phase climbs 0.1615 m/s (581.5 m/hour) while the drift ACCESSOR the report
scores against excludes it. **Not a bug — an intentional realism effect.**

RETRACTED: the first pass claimed relativity-off halves position error (7.794 -> 3.955 m). The
verifier ran the missing 2x2: that holds only with the atmosphere ON. With atmosphere OFF,
0.863 -> 0.863 m, i.e. **zero position cost**. It is an interaction, not a clean effect.

**What IS unobservable — the DIFFERENCE (radial - b_rx), not the clock.** corr(radial, b_rx) at
the final epoch: **TW0 -0.999898** (sigma_radial 6.390 m, sigma_b_rx 6.362 m = 21.2 ns);
**TW1 -0.141** (0.089 m, 0.027 m = 90.4 ps). Two-way time transfer breaks it as designed.
Independent confirmation from geometry: **VDOP (radial) 339-887 vs HDOP (along+cross) 13-34**,
a stable ~25x ratio that does not improve with time.

**Why errors sit outside +-3 sigma:** NEES_pos/3 = 27.8 (TW0) / 78.4 (TW1) while physical
NIS/dof = 1.07 / 1.02. **NIS ~ 1 means the noise model is right; NEES >> 1 means the error is
not noise** -- a slow common-mode term inside H's column space, which the filter explains by
moving states rather than flagging, while P shrinks on Q and R (honest about the white part only).

**The counter-intuitive part:** TW1 has SMALLER error than TW0 (11.4 vs 12.2 m) but far WORSE
NEES (78 vs 28). Two-way collapsed P without touching the systematic, so the same physical error
is now many more sigma. **Fixing the observability is what EXPOSED the over-confidence** -- it
was always there, hidden under a 6 m sigma.

### 3.1 Attitude / inter-antenna bias  *(PARKED — see §3.0)*
1. Build a real calibration **product**: derive from the same seeded draw as the truth minus a
   stated residual. **Risk to clear first:** `drawKeyed` must be idempotent for a repeated key,
   or re-deriving consumes a draw and shifts every downstream error source.
2. `hasModel()` must require actual calibration data — never report calibrated while correcting
   by zero.
3. **Coupling R1**: truth bias on ⇒ model on with the product, *with an explicit opt-out* so the
   deliberately-uncalibrated realism R-6 case remains reachable. Must live **after** the JSON
   merge (see §2.5).
4. **Coupling R2**: code-attitude ⇒ the inter-antenna *carrier* bias path is not-applicable for
   attitude. It must still corrupt carrier **range** rows — bypass ≠ delete.
5. Measure separately: calibrating unblocks `BaselineCarrierAmbiguityResolver`, so the dormant
   differential path may start adding rows. Report that as its own delta.

Acceptance: calibrated case lands **between** 9.08° and 0.22°, not reproducing either; converges
on all 3 seeds; golden byte-identical with the bias off.

### 3.2 Config resolution (§2.5) — unblocks everything else
Move `realismGradeConfig` application to after the JSON merge, or write ISL keys explicitly into
`scene_*.json`. The first is correct but changes config resolution for every run; the second is
zero-risk and matches what `_inc` files already do. **Recommend the second now, the first as a
separate tested change.**

### 3.3 Toggle table (§2.3)
Three-column truth/model/noise design; every row re-pointed at its real gate; delete "matched";
redo the ionosphere row per §1-CORRECTED (code survives / carrier cancels). Add a test that fails
if any row reads a key with no physics consumer.

### 3.4 Relative layer (§2.4)
Default `multiAsset.twoWayISL.enable = true` for `nSpaceAssets > 1`. Check
`run_swarm_relative_regression` first.

### 3.5 Plots (§ item 5)
Scale into real units (m→cm/mm, s→ns/ps) with the unit in the label. Fixes the TW1 optical
illusion (§2.2) as a side effect — a fixed axis would have made the "divergence" obviously absent.

### 3.6 Re-run the campaign (§2.6)
Only after 3.1-3.4. Then the `keepIslInPerAssetEkf` and attitude comparisons are finally
meaningful, and the W1/W2 double-counting cost can be quantified.

---

## 4. Open decisions for the user

1. **§3.2** — write ISL keys into `scene_*.json` (zero risk) or fix the ordering trap properly
   (correct, but re-resolves config for every run)?
2. **§3.1** — the calibration residual is a number I would be choosing. It must be defensible and
   not tuned to flatter the attitude result.
3. **§3.1.5** — waking the differential attitude path is a large behaviour change arriving as a
   side effect. Ship together, or gate it separately?
