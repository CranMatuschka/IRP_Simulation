# Full toggle audit — violations of "one toggle, written only in masterConfig"

552 config keys audited across 5 of 6 domains. Repo scale: **69 scenario JSONs, 194 production
.m, 270 test .m** (+3 production, +2 test added by this plan).
`[M]` = measured in MATLAB. **Findings first, the numbered plan last** — every `[M]` result is
attached to the section it revises, so the plan at the end reads as one unbroken list.

---

## The root cause: writers outside masterConfig, on BOTH sides of the merge

```
run_oo_v1.m:31   cfg = masterConfig()
                    ├─ :163  expandEnableToggles            ── PRE
                    ├─ :632  orbitClassConfig               ── PRE
                    ├─ :688  realismGradeConfig             ── PRE  (gated on realism.grade)
                    ├─ :695  applyMultiAssetMode            ── PRE
                    ├─ :700  applyLuniSolar                 ── PRE
                    ├─ :701  applyInjectTruthSideDynamics   ── PRE
                    └─ :702  applyPerTowerHwBias            ── PRE
run_oo_v1.m:42   cfg = deepMergeConfig(cfg, scenarioJSON)  <-- THE USER'S INPUT LANDS HERE
                 ConfigFactory.finalizeConfig(cfg)      ── POST, runs >= 2x, spans :580-:2073
                    ├─ :607  resolveEnablePairsPostMerge          [fix, step 2]
                    ├─ :617  applyAtmosphereProfile -> realisticAtmosphereConfig
                    ├─ :623  applyMultiAssetMode
                    ├─ :653  preserveScenarioOwned(@orbitClassConfig)             [fix]
                    ├─ :654  preserveScenarioOwned(@applyLuniSolar)               [fix]
                    ├─ :655  preserveScenarioOwned(@applyInjectTruthSideDynamics) [fix]
                    ├─ :656  preserveScenarioOwned(@applyPerTowerHwBias)          [fix]
                    ├─ :669  preserveScenarioOwned(@realismGradeConfig)  [fix, GATED OFF]
                    ├─ :1633 MultiAssetConfig.normalize
                    └─ 178 inline `cfg.<key> =` assignment sites
                 ReportRunner.m:472, :2111, :2157-2236  per-asset leaf rewrites  ── POST
```

**PRE-merge writes** = the user's JSON can never influence that key.
**POST-merge writes** = the write silently *overrides* the user's JSON.
Both violate "masterConfig defines, JSON overrides, nothing in between" — in opposite directions.

**Note the fix DUPLICATED rather than relocated.** No pre-merge call was deleted; the five
writers now run twice, the second time provenance-guarded. That is deliberate — `masterConfig()`
is called directly by `goldenRealismScenarioConfig`, `run_oo_v1_battery`, `run_error_ladder` and
several tests that never call `finalizeConfig`, so the pre-merge arm still has to supply defaults.

---

## R2a — written PRE-merge (the toggle was inert from a JSON)

| writer | invoked | keys | what became inert | status |
|---|---|---|---|---|
| `expandEnableToggles.m:16-20` | masterConfig.m:163 | 24 | the 12 master `errors/effects/physics.<x>.enable` | **FIXED** `ConfigFactory.m:607` |
| `realismGradeConfig.m:35-255` | masterConfig.m:688 | 62 in 17 blocks | `realism.grade` + all `realism.include.*` | **FIXED but GATED OFF** `ConfigFactory.m:669`, `cfg.realism.resolvePostMerge=false` |
| `orbitClassConfig.m:41-134` | masterConfig.m:632 | 8 | `scenario.orbitClass` — the documented "SINGLE switch" — **and it overwrites masterConfig.m:489-493's own values** | **FIXED** `ConfigFactory.m:653` |
| `applyLuniSolar.m:19-35` | masterConfig.m:700 | 11 (2 undeclared) | `perturbations.sunMoon.{enable,ephemeris}` | **FIXED** `ConfigFactory.m:654` |
| `applyInjectTruthSideDynamics.m:33-44` | masterConfig.m:701 | 7 | `multiAsset.injectTruthSideDynamics` | **FIXED** `ConfigFactory.m:655` |
| `applyPerTowerHwBias.m:26-35` | masterConfig.m:702 | 7 (2 undeclared) | `errors.hardwareDelay.perTowerBias.*` — and it **forces `model.enable=false` (:31)**, deliberately undoing the invariant `expandEnableToggles` created 500 lines earlier | **FIXED** `ConfigFactory.m:656` (must run LAST — D1) |
| `applyMultiAssetMode` | masterConfig.m:695 | **0** | nothing — writes no cfg key, and already ran post-merge at `ConfigFactory.m:623` | no work needed |

Order in the post-merge block is load-bearing: `orbitClassConfig` FIRST (the LEO path replaces
`cfg.towers` wholesale and `applyPerTowerHwBias` draws one bias per tower from
`numel(cfg.towers)`); `applyPerTowerHwBias` LAST (its `model.enable=false` would otherwise be
re-slaved to the master by `resolveEnablePairsPostMerge`).

### This is felt, not theoretical — measured across the committed scenarios

- **46 JSONs set `realism.grade=true`** → still dead while `resolvePostMerge=false` (the default)
- **24 set `realism.include.{hardwareDelay,multipath}=false`** → same
- **43 set `realism.directOverlay=true`** → a key with **ZERO readers anywhere** (re-verified)
- …and each then hand-writes **59–66 flattened keys** to reproduce what the overlay would have done.

The decisive diff: `scene_G5S1R4_ts3600_TW1_inc.json` vs `..._caut.json` differ *exactly* by
`{realism.include.hardwareDelay, realism.include.multipath}` on one side versus **9 explicit
`errors.hardwareDelay.*` / `errors.multipath.*` keys** on the other. **The `_inc` scenes only
work by omission** — they get the right answer because they leave the dead toggles out and write
the real keys, not because the toggles work. (This turns out to be what *saves* the migration —
see the measured delta below.)

~~Also: `max_realism_G5S6R4_ts3600.json` sets `perturbations.sunMoon.enable` — a silent no-op.~~
**No longer true:** `preserveScenarioOwned(@applyLuniSolar)` at `ConfigFactory.m:654` now reaches
it. `[M]` from a JSON: `truthLS=1 truthSRP=1 ekfLS=1 ekfSRP=1 snc=1e-06`, ephemeris `mg`. That
scenario's results **will move** on its next run.

### `[M]` The measured delta — all 69 scenarios resolved both ways

Config-only (no sim): `masterConfig` → `deepMergeConfig(scenario)` → `finalizeConfig`, flag off
vs on, then diff. Seconds instead of a 69-run campaign. `i_deepMerge` was extracted from
`run_oo_v1` into `config/internal/deepMergeConfig.m` to make this possible (`[M]` goldens and
`scene_G5S1R1_ts3600_TW0_inc` byte-identical after the extraction).

| real changed keys | scenarios | which |
|---|---|---|
| **0** | **45** | every single-asset (S1) scene, every non-realism scene |
| **10** — ISL keys only ⚠️ see correction | **20** | every `scene_G5S3R4_*` and `scene_G5S6R4_*` |
| **52–70** — full realism body + ISL | **4** | `swarm_smoke_realism`, `swarm_G5S6R4_realism`, `swarm_G5S6R4_TW0_realism_point34`, `max_realism_G5S6R4_ts3600` |

**The blast radius is 24 scenarios, not 46 — and it is entirely swarm.** Of the 46 scenarios
setting `realism.grade=true`, **42 hand-write the realism keys themselves**, so
`preserveScenarioOwned` restores them and the net delta is zero. The provenance guard converts
what would have been a campaign-wide upheaval into a change confined to the swarm scenes.

> ⚠️ **RETRACTED:** an earlier draft said the 20 swarm scenes "newly get ISL code+carrier in
> their EKFs — the lever that moves swarm shape error from ~14.8 m to ~1.3 cm." That is **wrong**
> — see the correction immediately below. The 20-scene row above counts *top-level* config keys
> that are stripped before they reach any EKF.

### `[M]` CORRECTION — the config diff OVERSTATED the blast radius

The table above diffs the **top-level** config. A federated swarm run does not estimate with
that config: `ReportRunner.singleAssetBase_` (`+revgnss/ReportRunner.m:2157`) forces
`base.scenario.nSpaceAssets = 1` for every per-asset leaf unless `keepIslInPerAssetEkf` is set.
`realismGradeConfig`'s ISL blocks are gated `nSA_isl_ >= 2`, so **in the per-asset EKFs they
never fire regardless of this flag**.

Measured on `swarm_smoke_realism` (300 s, 6 assets), flag OFF vs ON — the resolved per-asset
config is *identical*:

```
flag=0  islEnable=0 islCode=0 islCarrier=0 carrInEKF=0 twoWayISL=1
flag=1  islEnable=0 islCode=0 islCarrier=0 carrInEKF=0 twoWayISL=1
```

Only `max_realism_G5S6R4_ts3600` sets `multiAsset.keepIslInPerAssetEkf: true` — and it also
hand-writes the whole ISL block, so the provenance guard keeps its own values either way.

**Lesson for the rest of this plan: a resolved-config diff is a screen, not a verdict.** Config
keys can be written and then neutered downstream; only a run settles it.

### `[M]` What the realism overlay actually moves — and what it does not reach

Same A/B, results this time (`swarm_smoke_realism`, flag OFF → ON):

| metric | OFF | ON | change |
|---|---|---|---|
| `rel_shapeErrRaw_m` | 11.800242 | 20.117415 | **+70 %** |
| `rel_relClockErrRaw_m` | 41.569766 | 57.622936 | **+39 %** |
| `rel_baselineErrRaw_m` | 11.040544 | 14.520694 | **+31 %** |
| `rel_shapeErrSolved_m` | 0.034846907 | 0.034846485 | 1.2e-5 |
| `rel_baselineErrSolved_m` | 0.013028296 | 0.013028291 | 4e-7 |
| `rel_relClockErrSolved_m` | 0.018335765 | 0.018335765 | **identical** |

**RAW** = differences of the W1 federated per-asset EKF solutions (ground pseudoranges).
**SOLVED** = the W2 free-network shape adjustment from two-way ISL ranging. By explicit design
these use **disjoint measurements** and W1's covariance is *not* injected as a shape prior
(`+revgnss/SwarmRelativeSolver.m:20-21`).

So raw degrades because realism lands entirely on the **ground** path, and solved does not move
because **it does not use that path at all**. That is architectural independence, *not*
demonstrated robustness to a harder world.

> **FINDING — the swarm shape number is not realism-graded.** `SwarmRelativeSolver.islNoise_`
> (`:380-409`) draws its measurement sigma from `multiAsset.twoWayISL.sigma_m` (0.01 m),
> `delayCal.sigma_const_m` (0.01 m) and `delayCal.sigma_rw_m` (0.003 m) — `masterConfig.m:1085-1087`.
> **No realism block writes any of them**: `realismGradeConfig` touches `twoWayISL` only at
> `:179-194` (`enable`, `links`, `linkBudget.model`, `antennaModel`, `refDistance_m`,
> `refFrequency_Hz`, `lightTime.enable`). The headline raw→solved reduction (20.1 m → 0.0348 m,
> **578×**) is therefore set almost entirely by an *assumed* cm-class crosslink that
> `realism.grade` never challenges. Either extend realism to the crosslink (a
> `realism.include.islRangingNoise` block) or state plainly that the shape result is conditional
> on that assumption. This is the same defect class as the rest of this document: a toggle that
> says "physically representative" while a decisive path stays idealised.

---

## The three undeclared realism includes — and `point34`

`masterConfig.m:649-663` declared 15 `realism.include.*` keys. `i_resolveIncludes`
(`realismGradeConfig.m:260`) knew **18**, inventing `islCarrier`, `islLinkBudget` and `point34`
with default `true`. Three toggles that shape a run and appeared nowhere in the config file.

All are now declared in masterConfig at their existing values (zero behaviour change), and
`point34` is split:

| old | new | what it actually does |
|---|---|---|
| `point34` | `carrierArcSurvival` | `carrierSlip.commonModeCompensation` (minRows 4) + `baselineDifferencedMode` (refAntenna 1) |
| `point34` | `phaseBiasHonesty` | `enforcePhaseBiasStatus`, `requirePhaseBiasCalibrationForFix`, and `phaseBiasStatus = InterAntennaPhaseBias.resolvedStatus(cfg)` |

`point34` was named after `docs/attitude_improvement_review/point_3_*.md` and `point_4a_*.md` —
**a citation of where the idea was written down, not of what it does** — and it bundled two
unrelated concerns. A deprecated alias maps it to both halves with a warning, because an
out-of-tree `point34 = false` would otherwise hit the unknown-include path and silently leave
both ON, the opposite of the intent.

**The deeper point: these two differ in KIND from every other include.** The others add
physical error sources to the TRUTH. These change ESTIMATOR behaviour (arc survival) and REPORT
honesty. Turning them off does not make the world less realistic — it makes the filter worse
and the report more optimistic than the run earns. In particular `phaseBiasHonesty` is the
switch that stops a run whose calibration corrects by exactly zero from still reporting
`calibratedExternalProduct`. **A fix for a known silent misreport currently sits behind an
undeclared sub-toggle of an opt-in flag that is itself inert from a scenario** — four layers of
indirection on a correctness fix. Worth revisiting whether it belongs under `realism.grade` at all.

`[M]` The overlay is applied ONCE and is **not self-undoing**: skipping a block on a second call
leaves the first call's writes in place. Any test of an `include` must therefore start from a
config whose keys are still at masterConfig's defaults (all four are `false` at
`masterConfig.m:290-291, :312-314`), never from `goldenRealismScenarioConfig`, which has already
applied the overlay at its line 46. (This also explains the internal
`expandEnableToggles(expandList)` at `realismGradeConfig.m:255`: it re-slaves only the effects
this call flipped ON, and the outer provenance guard restores any pair member the scenario owns
— which is why the measured delta shows no pair-member churn.) Measured, one clean application each:

| include setting | cmc | bdm | enforce | reqCal |
|---|---|---|---|---|
| baseline, no overlay | 0 | 0 | 0 | 0 |
| full overlay | 1 | 1 | 1 | 1 |
| `carrierArcSurvival=false` | **0** | **0** | 1 | 1 |
| `phaseBiasHonesty=false` | 1 | 1 | **0** | **0** |
| `point34=false` (alias) | 0 | 0 | 0 | 0 (+ deprecation warning) |

Guarded by `tests/test_realism_include_split.m`.

### `[M]` Where `islCarrier` / `islLinkBudget` actually bite

| call path | `nSpaceAssets` seen | effect |
|---|---|---|
| federated swarm per-asset EKF (all `scene_*`, `swarm_*`) | forced **1** by `singleAssetBase_` | **none** |
| single-asset | 1 | none |
| **`run_oo_v1_battery.m` (`:166` then `:231`), `run_error_ladder.m` (`:164` then `:258`)** | **3 or 6** | **LIVE**: `islEnable/code/carrier/carrInEKF/amb/lightTime` all → 1 |

Those two tools set `scenario.nSpaceAssets` and then call `realismGradeConfig` DIRECTLY,
bypassing the federated per-asset stripping — so they are the only surface where these two
includes change anything. Declared `true` for now (status quo preserved); the open question is
whether `realism.grade` should be switching ISL measurements into an EKF at all, given its own
description promises only "realistic ISL *product sigma*". Deciding that needs a battery/ladder
swarm A/B on results, not just keys.

---

## R2b — written POST-merge (overrides what the user set) — **NONE FIXED**

`realisticAtmosphereConfig` via `ConfigFactory.m:617` rewrites **13 declared keys and adds 17
undeclared ones**. `[M]` on the untouched default: trop/iono `enable` false→**true**,
`modelType` `simpleMapped`→`localWeatherGM`/`tecGaussMarkov`, `stochastic.tau_s` 3600→10800 and
1800→600, `higherOrder.enable` false→**true**, `estimation.troposphereMode` `none`→`perTowerZwd`.
Step 1 has **not** been started; only the provenance wrapper from `b1c35b7` limits it.

| key | user writes | resolves to | site |
|---|---|---|---|
| `measurements.codeMode` | `'ionosphereFree'` | `'singleFrequency'` | `:570/:572/:576` |
| `estimator.towerClockMode` | `'perfectCorrection'` | `'truthHistoryProductNoisy'` | `:719, :742-761` |
| `measurements.carrier.slipDetection.threshold_m` | 7.35 | **0.1** | `:784` (warns at `:772`, overrides anyway) |
| `estimator.estimateTowerClocks` | true | **0** | `:851/:853` |
| `effects.lightTime.model` | `sagnacFirstOrder` | `iterative` | `:1031/:1039` |
| `estimator.estimateAttitude*` (4 keys) | false | **1** (and true → 0) | `:1553-1562` |
| `estimator.P0_euler_rad` | a tight value | **raised** | `:1591` |
| `estimator.estimateGyroBias` | false | **1** | `:679` |
| `estimation.ionosphereMode` | `'none'` | `'perTowerSlant'` | `:573` |
| `physics.sagnac.{truth,model}.enable` | — | forced **false** while `physics.sagnac.enable` still reads **true** | `:1046-1047` |

That last row is the pattern in miniature: **the toggle reports one thing and the physics does
another**. It is now *worse*, not better: `physics.sagnac` was added to
`resolveEnablePairsPostMerge` at `:608`, so a scenario's master enable propagates to the pair at
`:607` — and is then **re-forced to false 440 lines later at `:1046-1047`, inside the same
function**. A fix landed upstream of an override without removing the override.

### Step-3 worklist — the `finalizeConfig` override sites

`finalizeConfig` spans `:580-:2073` with **178** `cfg.<key> =` sites (not "~90"). Roughly 60 are
`~isfield`-guarded default-fills that **cannot fire** in the real path, because masterConfig
declares the key — those are ruled out cheaply. The genuine override candidates:

| # | site | key |
|---|---|---|
| 1 | `:570, :572-574, :576` | `measurements.codeMode`, `estimation.ionosphereMode`, `errors.ionosphere.model.correction` |
| 2 | `:679` | `estimator.estimateGyroBias` |
| 3 | `:714` | `errors.towerClockCorrection.mode` ← `clocks.tower.product.mode` (alias wins) |
| 4 | `:719`, `:742-761` | `estimator.towerClockMode` (6 branches) |
| 5 | `:782`, `:784` | `measurements.carrier.slipDetection.{enable,threshold_m}` (warns, then overrides) |
| 6 | `:814, :840, :843, :846` | `clock.gauge.{mode,referenceTowerIndex}` (alias wins) |
| 7 | `:851/:853` | `estimator.estimateTowerClocks` |
| 8 | `:925` | `hardware.txCodeBias.enable = true` |
| 9 | `:955` | `hardware.rxCodeBias.enable = true` |
| 10 | `:1019-1057` | `physics.lightTime.*`, `effects.lightTime.*`, **`physics.sagnac.{truth,model}.enable` forced false** |
| 11 | `:1113/:1131` | `measurements.carrierPhase.useInEKF = false` (deprecation path) |
| 12 | `:1251`, `:1259` | `measurements.code.l2Rows.enable`, `measurements.carrier.l2EkfRows.enable` |
| 13 | `:1284` | `estimator.diffAtt.ambiguityResolution.phaseBiasStatus` (the `phaseBiasHonesty` include) |
| 14 | `:1355` | `measurements.carrierCombinationMode = 'raw'` |
| 15 | `:1391/:1395` | `estimator.attitudeCarrierMode = 'off'` (= C3 in `01_toggle_dependencies.md`) |
| 16 | `:1458` | `measurements.doppler.useInEKF = false` |
| 17 | `:1482` | `clockScaling.templateSource` (mirror) |
| 18 | `:1553-1562`, `:1567` | `estimator.estimateAttitude{,AngularRate,FromPseudorange,AngularRateFromPseudorange}` |
| 19 | `:1591` | `estimator.P0_euler_rad` |
| 20 | `:1844/:1848` | `estimator.processNoise.modelMismatch.{enable,sigma_mps2}` (value-guarded, not provenance-guarded) |

**Verified DERIVATIONS — leave alone:** `:1191-1202` `signals.*`, `:1234-1236`
`enabledByFrequency`, `:1276` `diffAtt…enabledByFrequency`, `:1474` tower trim, `:1575/:1582`
lever arms, `:1626/:1630` `surveyError_ENU_m`, `:1827-1907` dynamics-mismatch diagnostics,
`:1903/:2022/:2060` freshness stage.

---

## R2c — two config surfaces for the same knob

`[M]` `data.SimulationDataStore.parseHeavyDiagCfg_` (`+data/SimulationDataStore.m:2165`) reads
`cfg.data.*` and **`elseif`**-falls-back to `cfg.diagnostics.storage.*`. It never reads
`cfg.diagnostics.sampling.*`. So:

| key | masterConfig | effect |
|---|---|---|
| `cfg.data.heavyDiagnosticsInterval_s` | `:1992` = **300** | wins |
| `cfg.data.computeHeavyDiagnosticsEveryEpoch` | `:1993` = **false** | wins |
| `cfg.diagnostics.sampling.heavyDiagnosticsInterval_s` | `:2010` = **0**, commented *"0 = every epoch"* | **no effect on any real run** |

> **CORRECTION to an earlier draft of this section.** It claimed these sampling keys have "zero
> readers". **False.** `+revgnss/Diagnostics.m:145` reads `sa.heavyDiagnosticsInterval_s` and
> `:150` reads `sa.computeRankEveryEpoch`. The conclusion survives only because
> `revgnss.Diagnostics` is constructed in **7 tests and zero production sites** — it is a
> test-only class. The three siblings `computeConditionEveryEpoch`,
> `computeAttitudeSvdEveryEpoch`, `computeClockObservabilityEveryEpoch` *are* genuinely unread.
> This matters for step 4: deleting the first two on a "zero readers" basis would break
> `Diagnostics.m` and `config/scenarios/default.json:116-120`.

**Measured consequence, and the reason this was found:** the report's DOP figure was blank.
Geometry/DOP was gated on `heavyDiag_`, so on a 3600 s run it was computed at **13 of 3601
epochs** — every finite sample isolated between NaNs. A line plot needs two *adjacent* finite
samples to draw a segment, so the figure rendered as an empty axes while GDOP ~ 930–2500 sat
in the store. The report said "no data" about data it had.

Fixed (not deferred to step 4): the geometry block is no longer gated — it is a rank of an
`M_pr x 4` plus one `4 x 4` inverse, not a full-Jacobian rank/`cond(S)`/SVD. Benchmarked, the
DOP block is **3–23× CHEAPER** than the heavy diagnostics it was gated with, and the gap widens
with problem size (DOP is fixed at 4 columns; `rank(H)`/`cond(S)` grow with the full state). At
G5S1R1: 11.4 µs × 3588 extra epochs = **0.041 s on a ~99 s run = 0.04 %**. Storage cost is
**zero** — `n1 = @() nan(N,1)` at `SimulationDataStore.m:288` already allocated all 3601 slots.
(An earlier draft quoted "+3.9 % wall"; that was single-sample run-to-run noise, not the change.)
`[M]` EKF byte-identical: `finalPositionRMS_m` 13.930001 both sides, and the 13 previously
computed GDOP values reproduce to 10 significant digits.

Two further defects fixed in the same figure: `ClockExactReportBuilder.plotSparse_` falls back to
markers so a sparse series can never again render blank; and the RAC triad was built from
`cross(r, v_ecef)`, which is the **zero vector** for a geostationary asset — `uC_ = 0/0 = NaN`,
and since `max(NaN,0) = 0` in MATLAB the report published **HDOP = 0**, i.e. *perfect* horizontal
geometry, exactly where it had none. The orbit normal now uses the inertial velocity
`v_ecef + omega_E x r_ecef`. `[M]` `VDOP^2 + HDOP^2` vs `PDOP^2`: was off by 1.6e-3, now 8.8e-16.
The DOP table's hard-coded `HDOP / VDOP / condition number = not available` row — false since
`680beaa` computed all three — now reads the store per row. Guarded by
`tests/test_dop_series_dense_and_plottable.m`.

---

## Golden fixtures bypass the flag entirely

`[M]` `goldenRealismScenarioConfig` has **`realism.grade = 0`** yet calls `realismGradeConfig(cfg)`
**directly** at `goldenRealismScenarioConfig.m:46`. So even the realism golden does not use the
realism toggle. `goldenScenarioConfig(120).atmosphere.realistic = 0`;
`goldenHeadlineScenarioConfig` also `realistic = 0, nReceivers = 4`.

Consequence for the migration: the single-asset goldens run with the atmosphere overlay OFF, so
folding `realisticAtmosphereConfig`'s values into masterConfig cannot move them.

---

## The dead-key register (step 4's input)

| key | verdict | evidence |
|---|---|---|
| `realism.directOverlay` | **DEAD** — 43 JSONs set it, zero readers repo-wide | re-verified |
| `cfg.diagnostics.sampling.computeConditionEveryEpoch` | **DEAD** | zero readers |
| `cfg.diagnostics.sampling.computeAttitudeSvdEveryEpoch` | **DEAD** | zero readers |
| `cfg.diagnostics.sampling.computeClockObservabilityEveryEpoch` | **DEAD** | zero readers |
| `cfg.diagnostics.sampling.heavyDiagnosticsInterval_s` | **NOT dead** — read by a test-only class | `Diagnostics.m:145` |
| `cfg.diagnostics.sampling.computeRankEveryEpoch` | **NOT dead** — same | `Diagnostics.m:150` |
| `cfg.diagnostics.storage.{heavyDiagInterval_s, heavyDiagEveryEpoch}` | **UNREACHABLE** while `cfg.data` exists (`elseif` branch) | `SimulationDataStore.m:2175` |
| `realism.include.point34` | **DEPRECATED ALIAS** | `realismGradeConfig.m:301-310` |
| `cfg.realism.resolvePostMerge` | scaffolding, one reader | `ConfigFactory.m:665` |
| `measurements.code.ionosphereFreeRows.{enable,useInEkf}` | flagged dead in `01_*.md:137-146`, **not yet in this doc's scope** | `SimulationToggleManifest.m:295-315` |
| `measurements.carrier.ionosphereFreeRows.{enable,useInEkf}` | same | `SimulationToggleManifest.m:342-369` |
| `cfg.ionosphere.mode`, `measurements.carrierPhase.enable` | same | `01_*.md` |

---

## Coverage map — what is audited and what is not

The original `global` domain sweep died on an output-size limit and was never re-run. Current
state per namespace:

| namespace | coverage | where / what is missing |
|---|---|---|
| `realism.*` | **SUBSTANTIAL** | R2a, the include split, the measured delta |
| `atmosphere.*` | PARTIAL | R2b names 13+17 keys but never lists them |
| `carrierSlip.*` | PARTIAL | only `commonModeCompensation` / `baselineDifferencedMode`; ~15 more at `masterConfig.m:302-320` |
| `data.*` | PARTIAL | R2c covers 2 keys |
| `diagnostics.*` | PARTIAL | R2c covers `sampling.*`/`storage.*`; ~35 `dynamicsMismatch.*`/`doppler.*` writes at `ConfigFactory.m:1827-1907, :1976-1985` unaudited |
| `clock*` | INCIDENTAL | `cfg.clock.gauge.*` (`ConfigFactory.m:814-846`) unaudited |
| `clocks.*` | INCIDENTAL | `clocks.tower.product.*` unaudited |
| `covariance.*` | **ZERO** | 11 write sites `ConfigFactory.m:1944-1971, :2018` |
| `signals.*` | **ZERO** | 9 write sites `ConfigFactory.m:1191-1202` |
| `hardware.*` | **ZERO** | `:925`/`:955` force `txCodeBias`/`rxCodeBias` enable true |
| `frames.*` | **ZERO** | |
| `report.*` | **ZERO** | |
| `validation.*` | **ZERO** | `:684, :687, :1684, :1793-1804, :2027-2058` |
| `rng.*` | **ZERO** | |

**7 of 14 namespaces are still completely unaudited.** Re-run the sweep split into two or three
smaller passes.

---

## Historical implementation notes — superseded by Part II below

**Step 1 — stop the POST-merge overrides.** `NOT STARTED.` Fold `realisticAtmosphereConfig`'s
values into masterConfig as plain defaults and delete the overlay call. `[M]` proven a no-op:
`atmosphere.realistic` already defaults true, so the overlay's values ARE the effective
defaults. This alone makes `errors.{tropo,iono}.*` mean something from a JSON. (`b1c35b7` added
a provenance wrapper that *limits* the damage; the overlay call itself is still at
`ConfigFactory.m:617`.)

**Step 2 — make the PRE-merge writers reachable from a JSON.** `DONE except realismGradeConfig,
which is gated OFF.` Note the shipped design differs from the original text: the writers were
**duplicated** under `preserveScenarioOwned`, not relocated, and no `resolveCoupledDefaults()`
exists — the pre-merge arm must stay for callers that never reach `finalizeConfig`. Remaining:
decide whether to default `cfg.realism.resolvePostMerge = true` (needs the battery/ladder A/B).

**Step 3 — audit the `finalizeConfig` overrides case by case.** Worklist above: ~20 genuine
override candidates out of 178 assignment sites, with ~60 ruled out as `~isfield` default-fills.
Each is either a legitimate *derivation* (fine) or an *override* (must go).

**Step 4 — delete the dead keys and rename for consistency.** Register above. Only after 1–3,
because until then a rename changes behaviour rather than just text. **Do not** delete on a
"zero readers" claim without re-checking — one such claim in this document was wrong.

**Step 5 — re-run the campaign.** Every number produced before step 1 was produced with toggles
that may not have meant what the scenario said. Known movers already: `max_realism_G5S6R4_ts3600`
(luni-solar now reachable), and anything run through `run_oo_v1_battery` / `run_error_ladder`
with `nSpaceAssets >= 2` if the ISL includes are ever flipped off.

---

# Part II — issue-by-issue resolution programme

**Plan date:** 2026-07-28

**Status:** design and execution plan only; none of the work below is claimed implemented by
this section.

**Authority:** the measured findings above remain evidence. This programme supersedes the
earlier `What to do` implementation recommendations wherever they conflict. In particular,
do not make the current complex atmosphere the master default, do not turn on
`realism.resolvePostMerge`, and do not preserve duplicate pre/post profile writers as the
final architecture.

**Scope:** resolve the audit findings above, establish a simple scientifically credible
default, replace the hidden realism machinery with a directly callable JSON overlay, and
upgrade W2 from range-only epoch-wise adjustment to the full multi-observable relative
estimator ("Whole Deal").

This programme deliberately preserves the findings above. It does not erase a measured
failure merely because a later work package intends to fix it.

## A. Non-negotiable scientific and configuration invariants

All work packages below must satisfy these invariants.

1. **The run contract is fixed.**

   ```text
   run_oo_v1.m
       -> masterConfig()                    canonical complete base
       -> one selected scenario JSON        explicit leaf overrides
       -> resolve derived fields once
       -> validate once
       -> simulate truth and measurements
       -> estimate without truth access
       -> report
   ```

2. **An enabled physical error exists in truth.** A top-level effect/measurement enable must
   never mean "change only a report label" or "change only estimator behaviour".

3. **The estimator never receives the realised truth error.** It may receive:

   - a deterministic physical law evaluated from its own state;
   - a separately generated calibration/product, its covariance, and any declared
     truth/product cross-correlation;
   - an explicit nuisance state and process model;
   - or a justified `Q`/`R` representation of unresolved uncertainty.

   Sharing a known equation is valid. Sharing the same random draw, uncertain coefficient,
   clock history, survey displacement, atmospheric state, or hidden truth state is not.
   Statistical independence is not required universally: real products are correlated with
   the quantity they estimate. The simulation must declare the joint truth/product error
   model and prevent estimator access to the latent truth; independent product error is only
   one explicit simplifying choice.

4. **Generation and use are distinct.** For an observable, `enable=true` means that the
   simulator generates and records it. A separate `useInEstimator` gate may withhold it for an
   ablation. The validator enforces `useInEstimator => enable`.

5. **No silent completion claims.** Missing, placeholder, diagnostic-only, or scientifically
   incomplete paths are disabled and hard-error if selected. A warning is insufficient when
   the run would otherwise publish a result as estimated or validated.

6. **No covariance laundering.** A constant or coloured bias must not be represented as
   independent per-epoch white noise merely so it averages down. Shared measurements must
   retain their cross-correlation or use an explicit latent state.

7. **Attitude estimation is on for every supported default/C3 asset.** Every spacecraft must
   carry a valid multi-antenna geometry. Insufficient phase-centre, line-of-sight, or
   windowed-information rank—or an undeclared truth-derived initial reference—is a
   configuration error; the resolver must not silently turn attitude off.

8. **Configuration levels and implementation status are different axes.** C1--C4 describe
   model complexity/evidence. `implemented`, `guarded`, and `missing` describe software
   availability. A C4 field does not make a C4 simulation.

## B. Dependency order

The work must be completed in this order; later gates depend on earlier ones.

| Order | Work package | Why it is prerequisite |
|---:|---|---|
| 0 | Freeze evidence and add config-resolution tests | prevents accidental redefinition of current behaviour |
| 1 | Canonical `masterConfig -> JSON -> resolve -> validate` pipeline | every later toggle depends on deterministic ownership |
| 2 | Define C2 default and C3 realism JSON | establishes which paths later tests must exercise |
| 3 | Honest simple atmosphere | removes the default oracle cancellation |
| 4 | Carrier-arc survival, phase-bias product contract, integer gates | prerequisite for any defensible carrier fixing |
| 5 | Tower survey, dynamics, and remaining truth/model separations | closes known shared-realisation and double-count defects |
| 6 | Multiasset cleanup and simple W2 baseline | establishes one supported swarm architecture |
| 7 | W2 observation boundary and float factor graph | prerequisite for code/carrier/Doppler coexistence |
| 8 | W2 slips, biases, time transfer, and integer AR | builds on a consistent joint float covariance |
| 9 | Monte Carlo, NEES/NIS, false-fix and stress validation | required before changing scientific claims |
| 10 | Campaign migration, documentation, and removal of legacy writers | only safe after result deltas are measured |

## Issue 0 — preserve evidence before changing semantics

### Current evidence

The working tree already contains changes to `masterConfig.m`, `ConfigFactory.m`,
`realismGradeConfig.m`, `run_oo_v1.m`, this audit, and related tests. The measured tables in
this document are therefore evidence for a specific in-progress code state, not necessarily
for repository `HEAD`.

### Resolution steps

1. Record the commit ID, dirty-file list, MATLAB release, platform, and external toolbox
   availability in a machine-readable validation manifest.
2. Save resolved-config snapshots for:

   - `masterConfig()` with no JSON, as a diagnostic base snapshot only—not a supported run;
   - `default.json`;
   - `realism.json`;
   - one single-asset scenario;
   - one N=4 swarm scenario;
   - every scenario currently setting `realism.grade`;
   - every scenario setting `keepIslInPerAssetEkf`.

3. Save the existing single-asset golden and federated relative-regression outputs before
   changing defaults. Do not re-freeze them to make a failure disappear.
4. Add a resolver-only test that records every scenario-owned leaf and asserts that its final
   value is unchanged unless that leaf is explicitly documented as a derived output.
5. Tag every baseline as `legacy-reference`, not `scientifically-approved`.

### Acceptance criteria

- The exact pre-migration configuration and result state is reproducible.
- A later result change can be attributed to one work package.
- No dirty user file is overwritten or reset during the migration.

## Issue 1 — make `masterConfig` the only base and JSON the only profile mechanism

### Current defect

`masterConfig` is not currently a passive canonical base. It invokes `orbitClassConfig`,
`realismGradeConfig`, `applyLuniSolar`, `applyInjectTruthSideDynamics`,
`applyPerTowerHwBias`, and `applyMultiAssetMode` before the JSON merge. `finalizeConfig`
then invokes several of them again after the merge. `realisticAtmosphereConfig` is another
post-merge writer. The provenance wrappers reduce damage but preserve two configuration
languages: direct leaf values and imperative profile writers.

`config/scenarios/default.json` is also a large snapshot of `masterConfig`, while
`config/scenarios/realism.json` contains direct leaves plus dead metadata
(`realism.directOverlay`) and a second, partially live realism mechanism
(`realism.grade`). This creates drift instead of a single source of truth.

### Target contract

- `masterConfig.m` declares every user-facing key and the complete C2 default value.
- A scenario JSON contains only differences from that base.
- A no-argument `run_oo_v1()` selects the minimal `default.json` internally; no run bypasses
  the one-JSON stage.
- `realism.json` is a normal JSON containing only C3 overrides. It is directly callable:

  ```matlab
  run_oo_v1('realism.json')
  ```

- No MATLAB function named "realism" writes configuration during a run.
- The resolver may compute non-user-facing derived quantities, but may not replace an
  explicitly supplied leaf.
- Validation may reject a configuration; it may not silently repair it.

### Resolution steps

1. **Classify every post-base assignment.** For all 178 `cfg.<key> =` sites currently noted in
   `ConfigFactory.finalizeConfig`, classify the output as one of:

   - canonical user input: move the default to `masterConfig`, never overwrite;
   - pure derivation: retain under a documented `cfg.resolved.*` or read-only mirror;
   - deprecated alias: translate once with conflict detection, then remove;
   - validation repair: replace with a hard error and an actionable message;
   - dead write: delete after the reader audit.

2. **Create one resolver entry point.** Conceptually:

   ```matlab
   [cfg, provenance] = loadScenario(masterConfig(), jsonPath);
   cfg = resolveConfig(cfg, provenance);   % once
   validateResolvedConfig(cfg);            % once
   ```

   `ReverseGNSSSimulation.initialize` and subsidiary factories must consume the already
   resolved config and must not run profile writers again.

3. **Remove imperative profile application.**

   - Move the desired C2 atmosphere leaves into `masterConfig`.
   - Keep C3 atmosphere leaves in `realism.json`.
   - Move all surviving `realismGradeConfig` values into `realism.json`.
   - Remove `realism.grade`, `realism.include.*`, `realism.directOverlay`, and
     `realism.resolvePostMerge` after scenario migration.
   - Replace `applyLuniSolar` and `applyInjectTruthSideDynamics` with explicit truth,
     estimator, and process-noise leaves in the chosen JSON.
   - Replace `applyPerTowerHwBias` with a runtime truth-error generator; configuration
     resolution must not draw physical errors.

4. **Make `default.json` minimal.** It should contain only a scenario name and any intentional
   override. Generate a separate, ignored diagnostic export when a full resolved config is
   needed; do not use that export as an input profile.

5. **Resolve aliases without precedence surprises.** If both canonical and legacy fields are
   supplied with different values, fail. Do not let `errors.towerClockCorrection.mode`,
   `clock.gauge.*`, carrier aliases, or atmosphere aliases silently win.

6. **Handle orbit-class convenience safely.** Either use explicit GEO/MEO/LEO JSON files, or
   retain `scenario.orbitClass` only as a pure default provider whose derived leaves are
   written under `cfg.resolved.orbit.*`. Explicit orbit leaves always win.

7. **Keep runtime loading single-file.** Do not add `extends` or nested profile composition
   during this migration. The runtime merge remains exactly
   `masterConfig -> selected JSON`. If repeated scenario fragments later become a maintenance
   problem, an offline generator may materialize a complete override JSON, but the run still
   receives one file and never invokes another profile writer.

8. **Add a schema/unknown-key gate.** JSON comment keys may be ignored deliberately; every
   other unknown path is an error. This replaces try/catch defaults that currently hide
   misspellings.

### Tests

- Resolver idempotence: resolving twice gives no change and consumes no random numbers.
- Scenario precedence: every explicit JSON leaf survives resolution.
- Default equivalence: `run_oo_v1()` and minimal `default.json` resolve identically.
- Direct realism: `run_oo_v1('realism.json')` resolves to the documented C3 leaves without
  calling `realismGradeConfig`.
- Unknown/dead keys hard-error, including `realism.directOverlay`.
- No production simulation/factory calls `realisticAtmosphereConfig`,
  `realismGradeConfig`, or any profile writer.

### Acceptance criteria

- There is exactly one runtime configuration flow.
- Every canonical input is visible in `masterConfig`.
- A diff of `masterConfig` against the selected JSON is sufficient to explain the run.
- Configuration resolution contains no truth RNG draw and no estimator execution.

## Issue 2 — define a simple C2 default and a separate C3 realism scenario

### Current defect

The current names mix three different ideas:

1. whether a physical effect exists in truth;
2. whether the estimator models or estimates that effect;
3. whether the numerical values are optimistic or conservative.

Consequently, `masterConfig` currently enables the complex atmosphere and both integer
fixing paths, while `realism.json` modifies selected values and systematics without defining
a complete scientific profile. The existing Step 1 above proposed making the current
realistic-atmosphere overlay the master default only to preserve behaviour. That proposal is
**superseded by this programme**: the user requires the default to be the simplest
scientifically credible nominal mission, not the current behaviour-preserving profile.

### Profile definitions

- **C1 ideal/unit profile:** deterministic analytic fixtures used to verify equations,
  Jacobians, signs, and units against independently constructed expected values. Even C1
  does not feed a simulated truth realization into an estimator. C1 is not a mission result.
- **C2 default/nominal profile:** the simplest honest mission. It may use optimistic but
  defensible noise and calibration assumptions, but truth and estimator never share a
  stochastic realization. It is the content of `masterConfig`.
- **C3 realism profile:** a controlled synthetic challenge with more systematics,
  correlations, parameter uncertainty, and conservative noise. It is the explicit content
  of `realism.json`.
- **C4 external-data profile:** real products, calibrated hardware data, measured spectra,
  or an event reconstruction. It remains unavailable until those inputs and readers exist.

These labels describe model and evidence complexity. They must not become another runtime
`grade` switch.

### Proposed C2/C3 decision table

This is the target policy. Numerical values are initial engineering hypotheses and must pass
the validation gates below before becoming claim values. At any repository revision every
cell resolves to one explicit value—there is no runtime “if validated” logic. “Until gate,
then versioned release” means the leaf remains false now and is changed explicitly only in a
later reviewed `realism.json` version after the named gate passes.

| Feature | C2 `masterConfig` default | C3 `realism.json` override | Reason |
|---|---|---|---|
| Number of spacecraft | 4 | explicit mission value, initially 4 | Four noncoplanar assets are the minimum volumetric tetrahedral case; three assets can still form a useful planar relative formation; N=1 remains explicit |
| Ground observations | enabled for every asset | enabled for every asset unless an outage is explicitly requested | anchored tower coordinates/frame provide the orbit datum; clocks remain relative to the declared tower/product time scale |
| Antennas per spacecraft | 4 declared phase centres whose stacked noise-weighted attitude information passes rank/conditioning/error gates | same, or an explicit calibrated geometry | observability depends on baselines, LOS diversity, time, dynamics, and any attitude sensor—not antenna count alone |
| Attitude estimation | `true`; invalid geometry or windowed information rank hard-errors | `true` with the same hard gate | attitude is estimated, never copied from truth or silently disabled |
| GNSS code, Doppler, carrier | enabled individually | enabled individually, with larger honest floors where justified | preserves simple raw observables and explicit controls |
| Carrier ambiguities | float states | float states | carrier is useful without integer fixing |
| All integer fixing | disabled | disabled until calibration and false-fix gates pass | a realistic scenario must not imply a trustworthy fix |
| Troposphere | simple first-order truth plus a separate non-oracle nominal estimator model | local-weather/GM truth and a product/model with declared joint error | no matched realization |
| Ionosphere | simple first-order truth plus a separate non-oracle nominal estimator model | time-varying TEC truth and a broadcast/product-like model with declared joint error | no matched realization |
| Scintillation | off | off in base realism; a standalone moderate synthetic stress may enable it after its gate | it is a disturbance, not universal realism |
| Multipath | off | coloured truth process on | C2 assumes a benign calibrated site |
| Hardware/group delay residual | off | false until Issue 5 passes; then explicit static/slow truth biases and calibration products with joint covariance in a versioned realism release | biases must not be white-noise inflation |
| Antenna PCO | simple declared geometry/calibration | separate calibrated-product uncertainty with declared correlation | geometry and product are distinct |
| Antenna PCV | off | off in base realism; `syntheticToyPcv` is a standalone sensitivity scenario; calibrated ANTEX remains C4 | current implementation is not ANTEX |
| Tower survey residual | off | false until Issue 5 passes; then explicit static truth/product joint error in a versioned realism release | a C2 network may assume ideal coordinates; C3 tests residual survey error |
| Clock model | sourced nominal oscillator with validated coefficient units and mission-timescale variance | sourced conservative JOW template with the same validation | “legacy” is not evidence merely because it is simple |
| Earth orientation | simple declared nominal transform | truth perturbation plus a separate estimator EOP product with declared joint error | one hidden EOP truth value must not drive both sides |
| Orbit dynamics | minimum force set whose bounded omission is below the C2 duration/accuracy budget; a four-hour GEO case is expected to require at least J2 and luni-solar gravity | richer separately parameterized truth/estimator force set with residual uncertainty | J2-only is a short-duration/reduced-dynamics case unless its omission bound passes |
| SRP | include a separately parameterized truth and estimator/product treatment when its omission bound exceeds the C2 budget; otherwise document the bound | false until Issue 6 passes; then explicit truth/product/state inputs in a versioned realism release | a copied unknown `Cr` is not realism; deliberate omission belongs to a separate stress |
| W1 estimators | one ground-based estimator per asset | same | simple, scalable absolute solution |
| W1 ISL rows | off | off | avoids double use and unknown cross-covariance |
| W2 two-way range | off during migration; enabled with fixed conservative sigma after WD4 | enabled after WD4 plus explicit correlated delay states | simple relative layer must pass the truth-boundary/covariance repair first |
| W2 one-way code/Doppler/carrier | disabled until the Whole Deal milestones land | enabled individually only after their milestone passes | no inert controls |
| W2 time transfer | disabled until raw timing/covariance milestone | enabled only after that milestone | range and time from one exchange are correlated |
| Unsupported paths | hard error | hard error | realism never activates unfinished software |

### Resolution steps

1. Convert this table into a machine-readable capability/profile matrix. Each row records:
   canonical config paths, truth generator, estimator consumer, stochastic independence,
   implementation status, tests, and maximum defensible C-level.
2. Put every C2 value directly in `masterConfig`.
3. Put only the C3 differences in `realism.json`; do not store a second full config.
4. Add named, orthogonal stress JSONs such as `disturbed_iono.json`,
   `reduced_dynamics.json`, `clock_outage.json`, and `carrier_slips.json`. Do not silently
   bundle every adverse condition into realism. Each stress file is a standalone selected
   override relative to `masterConfig`; the runtime never stacks it on `realism.json`.
5. Make every scenario report the resolved C-level and a list of active stressors. Compute
   those labels from the capability matrix; do not trust a user-entered claim label.
6. Run the profile comparison tool and publish the complete leaf diff. A review must explain
   every C2-to-C3 change as one of: additional truth effect, non-oracle estimator model,
   conservative uncertainty, or changed mission geometry.

### Acceptance criteria

- During migration, `masterConfig` is C2-safe but the default release remains provisional
  while repaired W2 is off. After WD4, the releasable final C2 is N ground-only W1 filters
  plus the repaired two-way-range W2.
- `realism.json` is a readable, direct C3 overlay rather than a function call.
- Neither profile enables integer fixing or unfinished features.
- No leaf becomes "realistic" merely by assigning identical truth and estimator values.
- Every adverse event not intrinsic to nominal realism is a separately named stressor.

## Issue 3 — replace the matched atmosphere with an honest simple default

### What “matched” means, and why it is prohibited here

In this audit, *matched* means that truth and estimator use the same exact atmosphere value
or the same stochastic draw, so the correction cancels the simulated delay by construction.
It is prohibited in every runtime profile, including C1, because the estimator has been
given the answer. A C1 equation test instead evaluates the production equation against an
independently constructed analytic expected value; it does not pass a truth realization
through the estimator interface.

Truth and estimator may use the same published equation or climatological family. They may
not share the hidden realization or true parameters. An estimator atmosphere state is also
allowed, because it is inferred from measurements rather than read from truth.

### Current defect

`masterConfig` currently sets `atmosphere.realistic=true`, while the base `simpleMapped`
configuration carries equal truth/model values. Existing regression logic also treats exact
truth/model cancellation as a success. The more complex implementation is scientifically
better separated—`localWeatherGM` and `tecGaussMarkov` prohibit a `sameAsTruth` model—but it
is too complex to be the requested default. A further risk is representing a slowly varying
residual as independent white measurement variance, allowing it to average down
incorrectly.

### C2 atmosphere design

Use a simple, explicit first-order observation model:

\[
y = \rho + m_T(e)\,T_\mathrm{true}(t)
          + s_f\,m_I(e)\,I_\mathrm{true}(t) + \epsilon ,
\]

where \(m_T\) and \(m_I\) are documented elevation mappings and
\(s_f\propto 1/f^2\) changes sign for carrier phase. The estimator uses
\(\widehat T(t)\) and \(\widehat I(t)\), obtained from nominal products or estimated nuisance
states, never \(T_\mathrm{true}\) and \(I_\mathrm{true}\).

The simplest defensible default is:

- dry troposphere from nominal pressure/height plus one slowly varying wet residual per
  tower in truth;
- a separately generated estimator wet-delay product/prior, or a per-tower ZWD state;
- first-order ionosphere only, with a slowly varying truth VTEC/slant residual;
- a separately generated nominal ionosphere correction or observable ionosphere state;
- no higher-order ionosphere and no scintillation;
- elevation mask and mapping-domain checks;
- explicit shared latent variables/cross-correlation where justified, plus dedicated RNG
  streams for the error components declared independent.

The process correlation belongs in a state or correlated-error model. It must not be replaced
only by a larger diagonal `R`.

### C3 atmosphere design

Retain the useful existing structure, after renaming it explicitly:

- truth troposphere: local-weather-driven hydrostatic/wet components plus per-tower
  Gauss–Markov variation;
- estimator troposphere: a non-oracle product/model with declared joint error, or estimated
  ZWD;
- truth ionosphere: diurnal/spatial TEC plus a Gauss–Markov residual and first-order
  dispersive mapping;
- estimator ionosphere: a non-oracle Klobuchar/product-like model or estimated states;
- optional higher-order terms only when their inputs and signs are validated;
- moderate scintillation as a separately named synthetic stress.

The current `30 TECU` nominal, `6 TECU` diurnal, `S4=0.3`, and fixed day-of-year values may
seed a synthetic case, but they do not by themselves define a validated disturbed-GEO
environment.

### Resolution steps

1. Write the C2 measurement equations and units in the atmosphere module documentation,
   including code/carrier sign, \(1/f^2\) scaling, mapping, and which quantity is vertical
   versus slant.
2. Add distinct configuration namespaces:

   - `atmosphere.truth.*`;
   - `atmosphere.estimatorModel.*`;
   - `atmosphere.estimatorStates.*`;
   - `atmosphere.measurementUncertainty.*`.

   Delete the ambiguous `atmosphere.realistic` selector after migration.

3. Implement a per-tower truth-state generator and a separate estimator-product generator
   with a declared joint error/cross-correlation model. Configuration resolution stores
   parameters, covariance and seeds—not sampled delays.
4. Provide either non-oracle nominal product values or nuisance-state priors. Add a validator
   that rejects object identity, copied truth time series, `sameAsTruth`, undeclared shared
   RNG streams, and perfect error-free truth disclosure in every profile.
5. Preserve temporal correlation in the estimator using ZWD/ionosphere states, a consider
   parameter, or a validated block covariance. Diagonal `R` inflation alone is not accepted
   for the default correlated residual.
6. Gate atmosphere states on the stacked information matrix. Per-tower ZWD copies estimated
   by separate W1 filters remain cross-correlated through the shared physical tower process
   and must not later be combined as independent. Free slant-ionosphere states require
   dual-frequency information, constrained VTEC/spatial structure, or informative product
   priors to avoid confounding with range, clock, code bias, and ambiguity.
7. Give C3 an explicit spatial cross-tower/ionospheric-pierce-point correlation model rather
   than only independent tower processes.
8. Move the existing complex leaves into `realism.json` with explicit names. Remove the
   post-merge `realisticAtmosphereConfig` writer.
9. Split disturbed ionosphere and scintillation into explicit stress files so a quiet C3
   case remains possible.
10. Replace the exact-cancellation regression with:

   - a C1 analytic sign/unit test with independently constructed expected outputs;
   - a C2 no-oracle and declared joint-product-error test;
   - sensitivity tests over elevation, frequency, wet delay, and TEC;
   - seeded Monte Carlo innovation/consistency tests.

### Acceptance criteria

- C2 has nonzero atmosphere residual variance and no identically cancelling truth/model
  series without using an adversarial disturbance; an individual residual may cross zero.
- Truth and estimator atmosphere inputs have separate provenance, no truth access, and the
  declared cross-correlation/RNG structure.
- Enabling atmosphere always creates a truth delay; estimator correction/state controls are
  separate.
- Low-elevation and dual-frequency trends have the correct sign and scale.
- Correlated atmosphere does not acquire \(1/\sqrt{N}\) confidence through diagonal
  covariance laundering.

## Issue 4 — keep carrier float by default; make integer fixing a gated capability

### Clarification: which part needs which?

Carrier measurement, ambiguity estimation, phase-bias calibration, and integer fixing are
four distinct capabilities:

1. **Carrier measurement** needs a tracking-noise model and a continuous phase arc.
2. **Float ambiguity estimation** needs carrier measurements and one ambiguity state per
   valid arc, but it does not need the ambiguity to be an integer.
3. **Phase-bias calibration** estimates or supplies the fractional hardware phase offset. It
   does not require integer fixing.
4. **Integer fixing** needs a well-conditioned float ambiguity and covariance **plus** a
   valid treatment of fractional phase biases (calibrated, identifiably estimated, or
   provably cancelled), correct wavelength/sign conventions, surviving arcs, and a validated
   acceptance test.

Thus fractional phase bias must be **calibrated, estimated under identifiable constraints, or
provably cancelled by an integer-preserving combination** before a defensible integer fix.
Fixing is not a prerequisite for calibration, bias estimation, or useful float carrier
estimation.

### Current defect

Both `estimator.integerAmbiguity.enable` and
`estimator.diffAtt.ambiguityResolution.enable` are true in `masterConfig`. The differential
attitude path describes its method as a constrained search and its false-fix protection as
`screenedNotFormal`; it can also accept a `syntheticKnownZero` phase-bias status. A second
LAMBDA wrapper exists, but availability of a solver does not make its ambiguity vector
integer-valid. The current ISL differencing path also leaves transmitter clock/bias content
in the combination while treating the result as an integer ambiguity.

The initial attitude “external reference” is currently synthesized from truth plus noise.
That is not an external sensor and must not centre or rescue an integer search in a mission
claim.

### Target policy

- C2 and C3: raw carrier on, float ambiguity states on, all integer fixing off.
- C1: controlled known-integer cases allowed for algorithm verification.
- A future advanced AR scenario may enable fixing only after all readiness gates pass.
- `requirePhaseBiasCalibrationForFix` and `enforcePhaseBiasStatus` are replaced by an
  unconditional bias-disposition readiness rule whenever any fixing mode is requested:
  validated calibration, identifiable bias estimation, or a proven integer-preserving
  cancellation.
- A string such as `calibratedExternalProduct` is not proof. A calibration product must carry
  provenance, antenna/receiver/signal identity, reference convention, covariance, validity
  interval, and checksum/version.

Integer least-squares should minimize

\[
(\hat{\mathbf a}-\mathbf z)^\mathsf{T}
Q_{\hat a}^{-1}(\hat{\mathbf a}-\mathbf z),\qquad
\mathbf z\in\mathbb Z^n ,
\]

using the joint float covariance after all retained clock, ionosphere, and phase-bias terms
are handled. The LAMBDA method is appropriate for this search
([Teunissen, 1995](https://doi.org/10.1007/BF00863419)); it does not replace the physical
integer-validity and false-fix gates.

### Resolution steps

1. Set both current integer-enable leaves false in `masterConfig` and `realism.json`.
   Keep `estimator.lambda.enable=false` until its exact supported call path is selected.
2. Build a single ambiguity-capability registry covering ground carrier, differential
   attitude carrier, and future W2 ISL carrier. Eliminate overlapping enable/method controls.
3. Define an immutable carrier-arc record:

   - receiver, transmitter, antenna and signal IDs;
   - start/end epochs and wavelength;
   - ambiguity-state ID;
   - phase-bias product ID;
   - slip/loss-of-lock events;
   - fix/hold/release history.

4. Validate the carrier equation and Jacobians for code/carrier ionosphere sign, clock sign,
   phase wind-up, antenna phase centres, and cycles-to-metres conversion.
5. Replace truth-derived coarse attitude with an explicit sensor/product interface. Until a
   star-tracker or other coarse-attitude measurement model exists, initialization must use a
   documented prior distribution and AR must not use an oracle search centre/fallback.
6. Make slip detection preserve common clock motion while detecting localized phase jumps.
   Use common-mode and baseline-differenced statistics, multiple signals where available,
   and explicit loss-of-lock flags. Reset only affected ambiguity states and release any
   dependent fix.
7. For the calibration route, define a real phase-calibration product schema and reject
   missing, stale, identity-mismatched, convention-mismatched, or overly uncertain products.
   For estimation/cancellation routes, require an observability or symbolic cancellation
   proof and its own evidence ID.
8. Obtain the float ambiguity subvector and **joint** covariance from the estimator. Do not
   manufacture a diagonal covariance from per-state sigmas.
9. Implement decorrelated integer least squares, best/second-best candidate evaluation,
   residual revalidation, aperture/ratio policy, partial-fix policy, and immediate fix
   release after a slip or failed residual check.
10. Validate with controlled C1 integers, then independent C2/C3 Monte Carlo. Report fix
    availability, time to first fix, conditional success rate, false-fix rate, wrong-hold
    duration, and float-versus-fixed navigation error. Never report only “fix rate.”

### Acceptance criteria

- Default and realism never fix an integer.
- Float carrier continues to contribute without claiming integer validity.
- No fix is possible without a validated phase-bias disposition; synthetic-known-zero,
  missing/stale calibration, an unobservable bias state, or an unproven differencing
  cancellation is rejected.
- A truth-derived attitude reference cannot enter the estimator or ambiguity resolver.
- A localized slip resets the correct arc; common clock motion does not cause fleet-wide
  false resets.
- An advanced AR scenario remains disabled until its predeclared false-fix bound and
  independent Monte Carlo coverage are met.

## Issue 5 — separate static and coloured truth errors from calibration products

### Current defect

Several toggles are nominally split into `truth` and `model`, but the underlying data are
not separated by an explicit product/joint-error contract:

- tower survey currently draws one ENU error per tower and exposes that realization to both
  truth and model, so enabling both can cancel exactly;
- per-tower hardware errors may be sampled while resolving configuration rather than by the
  runtime truth generator;
- a static or Gauss–Markov bias can be folded into diagonal `R`, allowing it to average down
  as though it were fresh thermal noise;
- antenna PCV is a toy azimuth/elevation pattern, not an ANTEX calibration;
- inter-antenna phase bias can be labelled calibrated without a product identity,
  uncertainty, reference convention, or validity period.

### Common target pattern

Every physical systematic follows the same four-object contract:

1. **Nominal physical quantity** known to scenario construction.
2. **Actual truth quantity**, created once by a truth-side process.
3. **Estimator product or state**, generated through a separate non-oracle interface with a
   declared joint error model, and visible to the estimator.
4. **Residual uncertainty representation**, retaining static, shared, or temporal
   correlations.

For a surveyed tower coordinate, for example:

\[
\mathbf r_\mathrm{true}=\mathbf r_\mathrm{nominal}+\delta\mathbf r_\mathrm{construction},
\qquad
\mathbf r_\mathrm{product}=\mathbf r_\mathrm{true}
                         +\boldsymbol\epsilon_\mathrm{survey}.
\]

The estimator may receive \(\mathbf r_\mathrm{product}\) and its covariance. It may not
receive \(\delta\mathbf r_\mathrm{construction}\). Since
\(\boldsymbol\epsilon_\mathrm{survey}\) is static, all measurements from that tower share its
effect.

### Resolution steps by effect

#### 5.1 Tower survey

1. Replace `surveyError_ENU_m` with distinct truth coordinate, estimator coordinate product,
   latent/error-source IDs, seeds where applicable, joint covariance, reference frame,
   epoch, and product ID.
2. Rotate ENU covariance into the frame used by the observation Jacobian.
3. In C2, use a declared ideal/known tower network and leave residual survey error off.
4. In C3, use separately generated static survey-product residuals with declared
   cross-tower correlation. The present `[0.01, 0.01, 0.03] m` values are
   plausible for a generic/degraded synthetic site but must not be called IGS-grade merely
   because they are centimetric. IGS station guidance requires documented marker-to-ARP
   geometry and calibrated antenna setup
   ([IGS antenna guidance](https://igs.git-pages.gfz-potsdam.de/igs-cors-guidelines/en/equipment/antenna/)).
5. Treat coordinate error as an estimated/consider parameter or a shared covariance block.

#### 5.2 Hardware and code group delay

1. Create receiver/tower/transmitter hardware-delay truth at runtime, indexed by terminal,
   signal, and direction.
2. Create a separate calibration product with joint truth/product bias covariance and
   validity period.
3. Use a constant or slow state for residual group delay. Do not redraw it per observation.
4. Separate differential code bias, inter-frequency code bias, and common group delay;
   document which linear combinations cancel which component.
5. Keep any `estimatePerTower` mode disabled until the state, process model, Jacobian,
   observability check, and covariance reporting all exist.

#### 5.3 Multipath and correlated receiver noise

1. Keep C2 multipath off as a benign-site assumption.
2. In C3, generate truth-only link/site-dependent code multipath with a declared correlation
   time and elevation dependence.
3. Never apply the same multipath series as an estimator correction. The estimator may use a
   robust residual model, elevation-dependent covariance, or a nuisance state where
   observable.
4. Keep the reserved carrier-multipath part disabled until its carrier sign, wavelength,
   antenna/site dependence, and temporal spectrum are implemented and tested.
5. Track RNG identity by receiver, transmitter, signal, and error source so adding an
   unrelated link does not change existing histories.

#### 5.4 Antenna PCO and PCV

1. Separate actual phase-centre geometry from the estimator antenna-calibration product.
2. PCO affects both endpoint geometry and attitude Jacobians; apply it at the antenna phase
   centre, not as independent scalar noise.
3. Retain the current toy PCV only under an honest name such as `syntheticToyAzEl`. It may be
   a C3 sensitivity model but not a calibrated antenna claim.
4. Keep `antex` or equivalent C4 modes disabled until a parser, frequency/radome lookup,
   convention validation, interpolation, product provenance, and independent tests exist.
5. Represent product uncertainty as shared by all observations using that antenna/product.

#### 5.5 Inter-antenna carrier phase bias

1. Create truth phase bias per receiver channel and signal, including optional slow drift.
2. Give float estimation either an explicit bias state or a real calibration product.
3. Do not let the ambiguity state silently absorb an arbitrary fractional bias and then call
   it integer.
4. Reuse the product contract and AR gates from Issue 4.

#### 5.6 Measurement noise, floors, and cross-observable covariance

1. Keep code, Doppler, and carrier generation toggles and sigmas independent. Disabling one
   observable must not disable the others or their required states.
2. Use fixed, documented sigmas for C2 unless the receiver/link inputs needed by the C/N0
   model are all present. C3 may use C/N0-dependent weighting only after that mapping is
   validated.
3. Define floors per observable with correct units. A metre-valued code/carrier floor must
   not be reused silently for Doppler in metres per second.
4. Draw measurement noise only in the truth/measurement generator. The estimator receives
   covariance, not the draw.
5. Model cross-correlation created by common clocks, products, differencing, or a common raw
   tracking process. Do not assume code, carrier, Doppler, signals, antennas, or assets are
   independent merely because they occupy different rows.
6. Do not charge a residual fully in both an estimated nuisance state and `R`.
7. Retain the current optimistic C2 and conservative C3 sigma values only after documenting
   bandwidth/integration/C/N0 assumptions and passing seeded residual-variance tests.

### Tests

- Seed-isolation and metamorphic independence tests for every truth/product pair.
- Static-bias non-averaging tests over increasing epoch count.
- Shared-covariance tests across measurements using the same tower, terminal, or antenna.
- ENU/ECEF rotation and finite-difference Jacobian tests.
- Frequency/sign tests for common delay, DCB, PCO, PCV, and phase bias.
- Per-observable variance/unit tests and joint covariance whitening tests.
- Negative tests proving that a copied truth realization is detected.

### Acceptance criteria

- Enabling an effect always creates a physical truth contribution.
- Turning on an estimator product never exposes the hidden truth realization.
- Static and coloured components retain their correlations.
- Toy models are labelled synthetic, and unimplemented calibration modes hard-error.

## Issue 6 — separate physical dynamics from estimator mismatch and process noise

### What an “unmatched estimator stressor” should mean

There are two scientifically different cases:

- **Honest nominal estimation:** truth and estimator implement the same known force family,
  but the estimator uses only legitimate products/priors with declared joint uncertainty
  and no latent truth access.
- **Reduced-model stress:** truth deliberately contains a force that the estimator omits or
  approximates. This tests robustness and must be named explicitly, for example
  `reduced_dynamics.json`.

The second case is useful, but it should not be the hidden definition of realism. A C3
realism run may model third-body gravity on both sides while giving the estimator a
separately generated ephemeris/product and SRP prior with declared joint errors. A separate
stress may omit the estimator term and compensate with stochastic acceleration.

### Current defect

The current realism machinery enables luni-solar gravity and SRP on both truth and estimator,
copies SRP parameter values, and also increases model-mismatch process noise. This can create
near cancellation while charging uncertainty for the same source twice. Elsewhere,
`ConfigFactory` can automatically change process noise after seeing a truth/estimator model
combination, overriding a scenario decision.

Earth orientation, solid-Earth tide, Sagnac, relativistic propagation, relativity in the
clock, and oscillator stochastic models also span physical truth, estimator products, and
correction terms. Their enable paths must obey the same ownership rule.

### Resolution steps

#### 6.1 Force models

1. Declare truth and estimator force models separately in `masterConfig`:
   two-body, J2, higher zonals if supported, luni-solar, SRP, shadow, and any empirical
   acceleration.
2. Before freezing C2, bound the displacement/velocity from every omitted force over the
   declared mission duration and accuracy requirement. For the intended multi-hour GEO
   case, treat J2-only as unreleased unless it passes; the expected minimum is J2 plus
   luni-solar gravity, with SRP included through a separately parameterized truth and
   estimator/product treatment when its bound is material.
3. For C3, enable third-body and SRP only after defining separate truth and estimator inputs:
   ephemeris/product ID, `Cr`, area-to-mass, shadow model, covariance, and validity.
4. Prefer estimating an SRP scale/bias state where the geometry and duration make it
   observable. Otherwise declare its uncertainty as a consider parameter.
5. Put intentional omission of third-body/SRP only in a named reduced-dynamics stress.
6. Test force magnitude, direction, frame, eclipse transitions, and energy/orbit trends
   against independent references.

#### 6.2 Process noise

1. Build a process-noise budget by physical source.
2. Partition every uncertainty source into explicit, non-overlapping components or frequency
   bands. A parameter state and residual stochastic acceleration may coexist only when they
   represent documented disjoint components; reject double counting of the same component.
3. Stop post-merge auto-retuning. The resolver may calculate a documented
   `cfg.resolved.Q` from explicit spectral densities but cannot switch it on.
4. Distinguish continuous-time spectral density from per-step covariance and verify the
   discretization versus time step.
5. Run timestep-scaling and zero-noise limiting tests.

#### 6.3 Earth orientation, tides, and measurement relativity

1. Separate true EOP from the estimator EOP product; include epoch, convention, covariance,
   and interpolation.
2. Treat solid-Earth tide as a displacement of the physical station and its estimator
   correction/product, not as independent white range noise.
3. Keep the existing synthetic EOP perturbation as C3 only. A value becoming numerically
   smaller when enabled may represent a post-correction residual, but its name and reference
   must say so.
4. Verify Sagnac and propagation-relativity terms by independent equations and sign-reversal
   tests. Correct deterministic physics normally belongs on both sides; equal equations are
   not an oracle if they use only legitimately known states/products.
5. Keep real IERS-product modes at C4 and disabled until readers and provenance exist. Use
   the current [IERS Conventions, Chapter 7](https://iers-conventions.obspm.fr/chapter7.php)
   as the reference contract for station displacement implementations.

#### 6.4 Clocks and time scale

1. Separate physical oscillator truth, estimated clock state/process model, and external
   clock product.
2. Validate oscillator coefficients, units, Allan-deviation/PSD conversion, discretization,
   and sample interval. A seven-order change in `h0` requires a source and a sensitivity
   result, not just a realism label.
3. Give every asset its own clock truth stream and model shared reference/product errors
   explicitly.
4. Define the clock gauge in multiasset solutions and report which time scale/reference
   anchors it.
5. Keep unimplemented external clock-product modes off.

### Tests and acceptance criteria

- Truth and estimator force calls do not share mutable state or hidden parameters.
- Setting an estimator parameter uncertainty to zero reproduces the deterministic reference;
  changing a truth parameter affects an estimator product only through the declared joint
  product model, never by hidden direct copy.
- Every acceleration uncertainty has an explicit non-overlapping state/consider/Q partition.
- EOP/tide errors remain temporally and spatially correlated.
- Clock Allan-deviation and ensemble variance tests match the configured template.
- Nominal C2, C3, and reduced-dynamics stress are separate, reproducible configurations.

## Issue 7 — disable incomplete modes and replace silent repair with validation

### Current defect

The normal configuration can select `validation.unsupportedFeaturePolicy =
'disableWithWarning'`. `ConfigFactory` then silently rewrites unsupported carrier-IF,
attitude-carrier, or Doppler choices. A run may therefore finish with behaviour different
from its JSON. In other places, a field exists and a report row is emitted even though the
physical generator, estimator consumer, or validation evidence is missing.

### Required capability states

Every selectable mode must have exactly one state:

- `supported`: generator, estimator/correction, covariance, reporting, and tests exist;
- `experimentalGuarded`: callable only from explicit development tests and barred from
  scientific claims;
- `unsupportedDisabled`: declared false/off in `masterConfig` and all supported JSONs;
- `retired`: rejected with a migration message.

`implemented`, C1--C4 complexity, and enabled/disabled are independent columns.

### Resolution steps

1. Set `validation.unsupportedFeaturePolicy='error'` once in `masterConfig`; remove
   production `disableWithWarning`.
2. Make enum parsing exhaustive. Unknown values and fall-through defaults hard-error.
3. Replace every silent disable, mode rewrite, and missing-field `try/catch` with a
   path-specific validation error.
4. Hard-disable at least the following until their named milestones pass:

   - external/C4 product modes without readers and provenance;
   - ANTEX PCV and any full physical ISL link-budget claim;
   - strong/disturbed scintillation without Doppler, lock-loss, and reacquisition support;
   - hardware-delay estimator state placeholder;
   - carrier-ionosphere-free integer fixing if no valid integer parameterization exists;
   - all uncalibrated integer fixing;
   - `multiAsset.keepIslInPerAssetEkf=true`;
   - retired joint `multiAsset.mode='honest'` and no-op `mode='fast'`;
   - Whole Deal W2 code/Doppler/carrier/time transfer before the corresponding milestone;
   - old primary-centric two-way/ISL builders as production estimators.

5. Add a generated capability report listing for each mode: config path, current state,
   reason, prerequisite issue, evidence tests, and claim ceiling.
6. Make inactive parameters visible but explicitly inert. For example, carrier sigma may
   remain declared while carrier is off; the report must say why it was not used.

### Acceptance criteria

- A requested unsupported feature stops before truth generation.
- No supported run silently changes a user-owned leaf.
- C2 and C3 resolved configurations contain no enabled unsupported/guarded feature.
- A report distinguishes off, unavailable, generated-only, estimated, and validated.

## Issue 8 — define GEO and disturbed-ionosphere scenarios without overclaiming

### Current capability

The mission geometry is GEO-oriented and the tower network is usable for synthetic GEO
experiments. The existing ionosphere can vary with longitude/local time and add TEC
Gauss–Markov variation. The configured `30 TECU` nominal, `6 TECU` diurnal amplitude, and
`S4=0.3` describe a synthetic moderate case.

They do **not** define a validated geomagnetic disturbance because there is no UTC event
epoch, geomagnetic latitude/context, F10.7/Kp/Dst input, storm evolution, measured reference
event, or complete loss-of-lock/reacquisition response.

### Resolution steps

1. Define a quiet/nominal C2 GEO scenario:

   - explicit GEO longitude and UTC start epoch;
   - explicit tower coordinates and elevation mask;
   - simple first-order tropo/iono per Issue 3;
   - scintillation off;
   - nominal oscillator, measurement, and visibility assumptions.

2. Rename the currently supportable C3 case `syntheticSolarModerate`, not
   `disturbed`, `storm`, or `realWorld`.
3. Add required context fields: UTC epoch, season/day-of-year, local solar time, pierce-point
   geometry, geomagnetic-coordinate model/version, solar/geomagnetic indices or explicit
   synthetic values, and scenario validity range.
4. For a future synthetic disturbed model, define a bounded spatiotemporal envelope:

   \[
   VTEC_i(t)=\operatorname{clip}_{[0,VTEC_\max]}
   \left\{VTEC_\mathrm{quiet}(LT_i,\phi_{m,i},\lambda_{m,i},s)
   [1+A(t)g(LT_i,\phi_{m,i},\lambda_{m,i},\mathbf r_{\mathrm{pp},i})]
   +x_{i,\mathrm{GM}}(t)\right\}.
   \]

   Here \(\phi_m,\lambda_m\) and \(\mathbf r_\mathrm{pp}\) are the declared geomagnetic
   latitude/longitude and pierce point. Generate a separate estimator forecast with a
   declared joint error model; it must not receive \(x_{i,\mathrm{GM}}\).
5. Couple amplitude scintillation, carrier phase scintillation, Doppler phase rate,
   cycle-slip probability, loss of lock, outage, and reacquisition consistently. Until all
   are present, restrict the model to a bounded phenomenological noise stress. The commonly
   used Conker tracking model is most defensible in moderate rather than severe scintillation
   regimes ([Conker et al., 2003](https://agupubs.onlinelibrary.wiley.com/doi/10.1029/2000RS002604)).
6. Keep a historical-event/C4 scenario hard-disabled until external data, preprocessing,
   provenance, and independent reference truth are available.

### Tests and acceptance criteria

- Local-time/longitude and \(1/f^2\) mappings pass analytic cases.
- Truth disturbance and estimator forecast have separate provenance, no truth access, and a
  declared joint error/correlation model.
- Carrier phase time derivative is consistent with simulated Doppler.
- Lock-loss/slip statistics vary plausibly with declared C/N0 and severity.
- Reports say `synthetic`, list all indices/assumptions, and never infer a real storm from
  `S4` alone.

## Issue 9 — replace ambiguous multiasset modes with one simple supported baseline

### What the code does at present

For `nSpaceAssets > 1`, the active architecture is not one large EKF:

1. it runs **one algorithmically separate W1 EKF for every spacecraft**; their posterior
   errors are still statistically correlated through common towers, products, atmosphere,
   survey, and hardware;
2. by default, those W1 filters use ground measurements and have their ISL rows stripped;
3. it then runs a separate W2 relative solver using synthetic two-way ranges.

Turning W1 ISL carrier off leaves its configured carrier sigma, slip thresholds, and ambiguity
parameters inert. It does not turn multiasset estimation off. The W1 filters still estimate
all assets; the W2 range sigma remains active because two-way range is a separate observable.
Parallel execution can reduce wall-clock time, but it does not replace any asset's EKF.

The present `multiAsset.mode='fast'` is effectively a no-op label.
`multiAsset.mode='honest'` refers to a retired primary-centric joint path and hard-errors.
`keepIslInPerAssetEkf=true` is not the Whole Deal: it can double-use information without
cross-covariance and can construct inconsistent neighbour geometry for non-chief filters.

### Selected simple architecture: `federatedSimple`

The supported C2 target is:

- N=4 spacecraft by default, with an explicit N=1 single-asset scenario;
- four validated phase centres on every spacecraft;
- attitude and angular rate estimated by each W1 filter whenever the array/measurement
  observability gate passes;
- every asset observed by the ground network;
- one algorithmically separate ground-only W1 filter per asset;
- W1 one-way ISL code, Doppler, and carrier off;
- one W2 two-way-range relative estimator;
- fixed, conservative range sigma;
- integer ambiguity fixing off.

This is deliberately simpler than Whole Deal but remains an honest multiasset solution if
ground and ISL observations have disjoint ownership and W2 covariance/geometry are repaired.

### Current W2 defects that block immediate default approval

The current `SwarmRelativeSolver`:

- creates its measurements directly from stored truth inside the estimator;
- solves each epoch independently, with no dynamics or temporal covariance;
- ignores the configured link list and rebuilds a nearest-neighbour graph;
- uses a pseudoinverse gauge whose zero nullspace entries can look falsely precise;
- draws a nominal “random-walk” delay as a constant and then uses heuristic `R` inflation;
- uses truth finite-difference velocity for an optional light-time term;
- solves clock differences from another synthetic observation set.

Therefore `federatedSimple` is the target default, but its W2 range toggle must remain off
during migration until the repair gate below passes. This is the direct application of
“if it is not complete, disable it.”

### Resolution steps

1. Replace `mode='fast'`, retired `mode='honest'`, `estimateMode`, and
   `keepIslInPerAssetEkf` with one explicit architecture enum:

   - `singleAsset`;
   - `federatedSimple`;
   - `wholeDealW2`.

2. Create one fleet truth universe. Every spacecraft, ground terminal, shared clock/product,
   and ISL observation must be generated once, independent of how many estimators consume
   the journal.
3. Make all secondary spacecraft use the same declared antenna/attitude capability as the
   chief unless a scenario explicitly supplies a different complete asset definition.
4. Validate attitude observability per asset:

   - declared phase-centre geometry, noise, and any attitude-sensor factors;
   - adequate line-of-sight/time/dynamics diversity;
   - rank three, acceptable conditioning, and acceptable predicted attitude covariance in
     the stacked noise-weighted Jacobian/Fisher information over the declared window;
   - a non-oracle prior or explicit coarse-attitude sensor.

5. Enforce measurement ownership:

   - `federatedSimple`: ground rows belong to W1; two-way ISL range rows belong to W2;
   - `wholeDealW2`: raw ground and ISL rows belong to W2; W1 outputs initialize only.

6. Repair simple W2 through Whole Deal milestones WD1–WD4 below; WD4 depends on both the
   observation journal and graph core.
7. For the default N=4 case, use all six pairwise links unless a validated rigidity/rank
   checker approves a sparser graph. Rigidity-matrix rank proves local/infinitesimal
   rigidity, not unique global realization; also check nondegeneracy and reflection/global
   ambiguity. Do not infer observability from connectedness alone.
8. Report per-asset absolute position/clock/attitude performance from W1 and
   gauge-invariant relative shape/baseline performance from W2 separately.
9. Never derive a fleet centroid/baseline covariance by combining separate W1 `P` matrices
   as independent blocks unless shared-source cross-correlations have been reconstructed.

### Simple-mode acceptance gate

- No estimator reads truth to construct a measurement or prediction.
- Every ground/ISL measurement ID has exactly one estimator owner.
- All configured links are honoured.
- Link-delay biases do not average down as white noise.
- Graph connectivity and 3-D rigidity rank are reported.
- W2 covariance is reported only in the observable/gauge-fixed subspace.
- Every asset's attitude is estimated and passes its own observability/consistency tests.
- N=1 behaviour remains unchanged apart from deliberate C2 default changes.

## Issue 10 — implement the Whole Deal W2 upgrade as a staged joint estimator

### Architecture decision

Implement `wholeDealW2` as a centralized sparse batch factor graph, followed later by a
fixed-lag smoother using the same factor interfaces. Do not resurrect the retired
primary-centric shared EKF.

`federatedSimple` runs N W1 filters plus its disjoint W2 range layer.
`wholeDealW2` produces one joint graph solution. W1 bootstrap trajectories are optional
during development and are not factors or priors; after graph initialization from declared
state priors/propagation is validated, the production Whole Deal path does not need to run N
W1 filters first.

A factor graph is the safer scientific architecture because carrier arcs, slips, event-time
links, coloured calibration states, sparse multiasset coupling, relinearization, and selected
cross-covariance are explicit. W1 trajectories may initialize the nonlinear solution, but
their posterior means/covariances must not be inserted as priors while the same raw ground
measurements are reprocessed. That would double count information. A small dense joint EKF
may be retained only as a linear-Gaussian test oracle. The general factor-graph formulation
and sparse smoothing rationale are described by
[Dellaert and Kaess](https://www.borg.cc.gatech.edu/papers/gtsam.html).

### Canonical observable controls

Consolidate `measurements.isl.*`, `measurements.isl.twoWay.*`,
`multiAsset.twoWayISL.*`, and `multiAsset.twoWayTimeTransferISL.*` into one ownership-aware
surface declared in `masterConfig`, conceptually:

```matlab
cfg.multiAsset.mode = 'federatedSimple';       % or 'wholeDealW2'
cfg.multiAsset.w2.backend = 'rangeBatch';       % later batchFactorGraph/fixedLagFactorGraph

cfg.measurements.isl.code.enable = false;
cfg.measurements.isl.code.useInEstimator = false;
cfg.measurements.isl.doppler.enable = false;
cfg.measurements.isl.doppler.useInEstimator = false;
cfg.measurements.isl.carrier.enable = false;
cfg.measurements.isl.carrier.useInEstimator = false;
cfg.measurements.isl.twoWay.range.enable = true;
cfg.measurements.isl.twoWay.range.useInEstimator = true;
cfg.measurements.isl.twoWay.timeTransfer.enable = false;
cfg.measurements.isl.twoWay.timeTransfer.useInEstimator = false;

cfg.estimator.w2.integer.enable = false;
```

`enable=true` generates and records an observable. `useInEstimator=true` additionally
requires `enable=true` and assigns exactly one estimator owner/factor. Generated-only
observables are valid ablations and must be reported as such; they are not “unused by
accident.” Carrier use allocates float ambiguity states automatically. Carrier off leaves
code, Doppler, or two-way range usable. Integer fixing remains a separate estimator decision.

### Target observation equations

For directed link \(i\rightarrow j\), with transmit time \(t_t\), receive time \(t_r\), and
antenna phase-centre range \(\rho_{ij}\), define clock range
\(b_i=c\,\delta t_i\) in metres and \(\dot b_i\) in metres per second:

\[
P_{ij} =
\rho_{ij}(t_t,t_r)
+b_j(t_r)-b_i(t_t)
+d^P_{\mathrm{rx},j}+d^P_{\mathrm{tx},i}+\epsilon_P ,
\]

\[
L_{ij} =
\rho_{ij}(t_t,t_r)
+b_j(t_r)-b_i(t_t)
+\lambda N_{ij,a}
+b^\phi_{\mathrm{rx},j}+b^\phi_{\mathrm{tx},i}
+\delta\rho_\mathrm{PCO/PCV}
+\delta\rho_\mathrm{windup}
+\epsilon_L ,
\]

\[
D_{ij} =
\dot{\rho}_{ij}
+\dot b_j-\dot b_i
+\dot d_{\mathrm{rx},j}+\dot d_{\mathrm{tx},i}+\epsilon_D .
\]

The displayed hardware terms use one declared additive delay convention. A different
receiver/transmitter convention may change their signs; the implementation must derive and
test those signs by terminal role. Endpoint biases do not generally form `receiver minus
transmitter`, and differencing cancellation must be derived from the actual exchange.

Each endpoint phase centre is

\[
\mathbf r_{\mathrm{APC},i} =
\mathbf r_{\mathrm{COM},i}+\mathbf C_i(\boldsymbol\theta_i)\boldsymbol\ell_i .
\]

Carrier-quality ISL therefore couples both endpoints' position, clock, attitude, lever arm,
calibration, and ambiguity. An estimator that treats the remote endpoint as known truth is
not the Whole Deal.

### Target graph variables and gauges

At each retained knot, asset \(i\) has at least the manifold-valued variable set:

\[
\mathcal X_{i,k} =
\{\mathbf r_i,\mathbf v_i,\mathbf R_i\in SO(3),\boldsymbol\omega_i,
 b_i,\dot b_i\}.
\]

Store attitude as \(SO(3)\) or a normalized quaternion with a fixed sign convention.
\(\delta\boldsymbol\theta_i\) is only the local tangent perturbation used during optimization,
not the persistent attitude state. Define injection/reset, normalization, and tangent-space
covariance explicitly.

Optional observable states include gyro bias, ZWD/ionosphere, tower/product biases, and SRP
scale. Link/terminal variables include:

- float ambiguity per directed link, signal, and continuous arc;
- code group-delay residual;
- carrier phase-bias residual;
- terminal-shared delay/bias where several links use one transceiver;
- two-way turnaround delay;
- slowly varying calibration states only where physically justified.

The graph must compute the nullspace of the stacked active spatiotemporal Jacobian/information
matrix and then declare the resulting gauges. A range-only free network normally has
rigid-body position/rotation gauge; depending on dynamics it may also expose common
translation velocity. Ground factors generally anchor those degrees. Common clock bias/
drift and ambiguity gauges may remain depending on the active factors. Never hard-code a
gauge that the current factor set has already removed or introduced.

Covariance and NEES are evaluated in the observable subspace or on gauge-invariant
baselines/shape. A pseudoinverse zero in a null direction is not information.

### WD0 — quarantine incomplete and misleading paths

1. Keep W2 code, Doppler, carrier, time transfer, light time, link-budget mode, slips, and
   integer fixing off.
2. Reject `keepIslInPerAssetEkf=true` and the retired primary-centric modes.
3. Prevent `realism.json` from enabling any of these paths automatically.
4. Mark old one-way and two-way builders `experimentalLegacy`, with no scientific claim.
5. Freeze the current range-only outputs as `legacy-reference`, not acceptance truth.

**Gate:** all incomplete switches hard-error and supported profiles report them as disabled.

### WD1 — consolidate configuration and measurement ownership

1. Introduce the canonical controls above in `masterConfig`.
2. Migrate aliases with conflict detection; then delete the old controls.
3. Add an observation-owner enum derived from `multiAsset.mode`, not user-set independently.
4. Permit generated-only observations when `useInEstimator=false`; reject every **used**
   observation scheduled for zero or multiple estimators.
5. Add per-observable capability/prerequisite validation.

**Gate:** every observation type has one canonical generation/use pair and one generator;
every used measurement has exactly one owner and reported consumer.

### WD2 — build an immutable multiasset observation journal

Generate truth and measurements during simulation, before estimation. Each record contains:

- unique measurement ID and units;
- observable type;
- transmitter, receiver, terminal, antenna, and signal IDs;
- link direction, session, and arc IDs;
- transmit/receive/event timestamps;
- measured value, covariance-block/group ID, and the relevant covariance/cross-covariance
  entries; a scalar thermal variance is sufficient only when independence is declared and
  tested;
- shared-error-source and calibration-product IDs;
- validity, availability, lock, C/N0, outage, and quality flags.

Store truth-only decomposition in a separate diagnostic object that prediction code cannot
access. Generate shared tower/terminal processes once across the fleet.

**Gate:**

- changing estimator configuration does not change observation values;
- same seed is bit-reproducible;
- adding an unrelated link does not perturb existing RNG histories;
- static analysis and interface tests prove solver code cannot access truth fields;
- shared biases retain the intended cross-observation identity.

### WD3 — implement the sparse graph core

1. Implement sparse batch Gauss–Newton/Levenberg–Marquardt error-state optimization.
2. Add symmetric per-asset state blocks, dynamics factors, clock process factors, robust
   factor bookkeeping, and nuisance-state support.
3. Implement an explicit gauge/nullspace manager and report rank, nullity, conditioning, and
   chosen constraints.
4. Add selected marginal and cross-covariance extraction.
5. Initialize from declared priors or W1 trajectories, never truth.
6. Keep a pure-Gaussian/no-rejection consistency mode in which the inverse information
   matrix has its usual covariance interpretation.
7. If robust M-estimation or data-dependent rejection is active, use a justified robust/
   sandwich covariance treatment or cap the covariance claim explicitly; do not report the
   inverse reweighted Gauss–Newton Hessian automatically as a calibrated posterior.

**Gate:**

- linear-Gaussian cases match dense batch and reference Kalman solutions;
- asset/factor ordering permutations leave the result unchanged;
- several reasonable initializations converge to the same optimum;
- covariance is symmetric positive semidefinite under the documented gauge, and robust-mode
  claims pass their separate covariance evidence gate.

### WD4 — repair two-way range and graduate `federatedSimple`

1. Generate processed two-way-range records in the journal rather than inside the solver.
2. Define a reference epoch and a validated symmetric/same-epoch range approximation. Keep
   raw timestamp factors, time transfer, and W2 light time off at this stage; bound the
   neglected motion/light-time error below the declared simple-mode budget or reject the
   geometry.
3. Honour the configured links and schedule.
4. Model turnaround/terminal delay as calibrated states/products with a declared joint
   truth/product error model; do not use `nCorrCap` diagonal inflation.
5. Add dynamics across epochs.
6. Include both endpoint Jacobian blocks with the correct opposite signs.
7. Compute baseline/shape covariance as \(GPG^\mathsf T\).
8. Detect disconnected and locally non-rigid graphs using the 3-D rigidity-matrix rank. Also
   check nondegeneracy and discrete reflection/global ambiguities; for N=4 use all six links
   and a noncoplanar formation as the safe reference case. Do not rely on a hard maximum
   neighbour count. Treat static rigidity as a diagnostic and also evaluate the stacked
   spatiotemporal information matrix because dynamics can make a sparse scheduled graph
   observable.
9. Do not create a time-transfer observation/factor in WD4; that belongs to WD10.
10. Give the fixed range sigma a cited specification/empirical provenance and a validity
    envelope covering separation, C/N0 or received-signal assumptions, integration/schedule,
    and receiver mode; test sensitivity at the envelope bounds. “Conservative” without this
    evidence is not an acceptance argument.

A constant turnaround-delay error creates an additive range bias that can be exactly or
strongly confounded with baseline length depending on geometry, schedule, dynamics, and
terminal sharing. Analyze each delay state's observability/correlation; its calibration prior
can set the baseline accuracy floor. Time-transfer calibration is a primary metrology
requirement, not a cosmetic realism setting
([BIPM TWSTFT calibration guidelines](https://webtai.bipm.org/ftp/pub/tai/publication/twstft-calibration/guidelines/tw_clb_guideline2015-v1.0.pdf)).

**Gate:**

- thermal-noise and constant-delay contributions have the expected different averaging
  behaviour;
- delay truth and calibration product obey their declared joint error/correlation model;
- link/schedule and geometry-rank tests pass;
- Monte Carlo baseline coverage and gauge-projected NEES are consistent.

After WD4, `federatedSimple` may enable two-way range by default.

### WD5 — establish the centralized ground-observation graph

For `wholeDealW2`, add every raw ground observation to the graph:

1. code, Doppler, and float carrier factors for every asset;
2. tower clock/product states or covariance blocks;
3. shared tower survey, hardware delay, PCO/PCV, and atmosphere treatment;
4. all position/clock/attitude cross-correlations created by those common factors.

W1 trajectories are now initialization only. Do not add their `P` matrices as block-diagonal
priors because W1 filters share tower/systematic sources and the graph reuses their raw data.

**Gate:**

- every used measurement ID occurs in exactly one active factor;
- removing W1 after graph initialization does not remove information;
- changing the W1 initialization within its plausible prior converges to the same solution;
- full per-asset, centroid, relative, clock, and attitude covariance blocks are available;
- common tower errors do not appear as independent diagonal noise.

### WD6 — add one-way ISL code and network clocks

Using the graph convention \(b=c\delta t\) in metres, for a simultaneous-state
approximation the leading Jacobian blocks are:

\[
H_{\mathbf r_j}=+\mathbf u^\mathsf T,\quad
H_{\mathbf r_i}=-\mathbf u^\mathsf T,\quad
H_{b_j}=+1,\quad H_{b_i}=-1 .
\]

The event-time implementation must also differentiate state interpolation/light time.

1. Add code factors with both endpoint position and clock states.
2. Add clock bias/drift and oscillator process factors for every asset.
3. Add terminal/link group-delay calibration states or products.
4. Implement link schedules, outages, direction, and signal identity.
5. Constrain or explicitly retain the common clock gauge.
6. Treat any “remote ephemeris product” as a measurement with covariance; never substitute
   remote truth.

**Gate:** finite-difference Jacobians pass, clock-graph rank is correct, disconnected clocks
are detected, and code-only Monte Carlo NIS/NEES is consistent.

### WD7 — add one-way ISL Doppler

1. Implement event-time range rate using both endpoint positions and velocities.
2. Include both clock drifts and any declared frequency-transfer/oscillator terms.
3. For simultaneous Euclidean range use the exact identity
   \(\dot\rho=\mathbf u^\mathsf T(\mathbf v_j-\mathbf v_i)\). For event-time range, derive
   the additional implicit transmit-time/light-time and interpolation terms; do not add a
   spurious standalone \(\dot{\mathbf u}\) scalar term.
4. Define whether the observable is pseudorange rate in m/s or RF Doppler in Hz, including
   sign convention, and convert using the actual signal frequency.
5. Confirm the ambiguity derivative is zero for an independent instantaneous Doppler
   observable within an uninterrupted arc. TDCP spanning an arc boundary contains the
   ambiguity jump and must be rejected/reset.
6. Couple phase scintillation to the time derivative consistently before allowing that
   stress.

**Gate:** constant-velocity closed forms, Hz/metres-per-second equivalence, full
finite-difference Jacobians, and Doppler-only observability limitations all pass/report.

### WD8 — add float ISL carrier and attitude coupling

1. First support one uninterrupted locked arc per directed link and signal, with a stable
   arc ID and one float ambiguity variable. Any outage, lock transition, or injected slip
   hard-errors in WD8; WD9 adds dynamic arc lifecycle and promotes those cases.
2. Use both endpoint antenna phase centres and both attitude Jacobians.
3. Add PCO, supported PCV, phase wind-up, and fractional phase-bias states/products; hard-
   disable carrier if a selected correction is missing.
4. Use code/two-way range or other coarse factors to separate geometry/clock from ambiguity.
5. Keep the carrier thermal sigma physical. The current experimental `0.20 m` value mixes
   initialization/systematic uncertainty into thermal `R`; solve those uncertainties with
   priors/states instead of hiding them in carrier noise.
6. Keep each asset's attitude state active because attitude is a mission output. ISL carrier
   contributes attitude information only when non-colocated phase centres and line-of-sight
   geometry make the corresponding Jacobian observable; otherwise ground carrier or an
   explicit attitude sensor/prior must supply it.

**Gate:**

- a noise-free correctly initialized carrier residual is zero;
- carrier and attitude analytic Jacobians match finite differences;
- placing the phase centre at COM produces a zero attitude partial;
- float ambiguity covariance and carrier residual coverage are consistent;
- the validator rejects an attitude claim with a rank-deficient array/geometry.

### WD9 — implement truth slips, lock state, and arc management

The present ISL path can detect/reset some events but lacks a complete truth-side ISL slip
and lock generator. Implement:

1. explicit truth lock state, scheduled outages, C/N0-dependent loss of lock, integer cycle
   jumps, and reacquisition;
2. a new ambiguity ID and variable at every new arc;
3. detector inputs from receiver lock flags, Doppler-aided time-differenced carrier, and
   dual-frequency geometry-free combinations when available;
4. exclusion/new-arc handling at the transition epoch;
5. reset/release only for variables supported by the affected arc.

**Gate:** measure false alarms with zero injected slips; measure detection delay and missed
slips by C/N0 and jump size; verify a slip on one link changes no unrelated ambiguity; verify
post-slip covariance coverage recovers.

### WD10 — implement raw two-way timing and honest link calibration

1. Represent the primitive transmit, receive, and turnaround timestamps, including the
   transceiver time scale and event ordering.
2. Derive two-way range and time-transfer observables from those events only for reporting,
   or use a joint factor/covariance if both enter estimation.
3. Model terminal-shared delays separately from pair-specific delays.
4. Carry calibration covariance, validity, reference convention, and provenance.
5. Validate reciprocity/asymmetry assumptions and motion during light time.
6. Cross-check zero-motion symmetric cases and moving-endpoint cases against an independent
   implementation.

BIPM guidance treats calibration and traceability as essential for TWSTFT; a simulated
time-transfer mode must likewise state its delay calibration and uncertainty
([BIPM directive](https://www.bipm.org/documents/20126/27085544/bipm%20publication-ID-2187/5241a2c4-bc0e-e96a-37ef-7d599db86dd1)).

The current `ISLLinkBudget` is only distance scaling around an assumed reference sigma. Keep
`model='fixed'` for the supported simple mode. A physical link-budget mode remains disabled
until it includes at least waveform/bandwidth or chip rate, integration and loop bandwidth,
frequency, modulation, antenna pointing/gain, EIRP, G/T, implementation losses, tracking
thresholds, and the mapping from C/N0 to code/carrier/Doppler jitter and lock probability.

**Gate:** range/time covariance is not double counted, constant delays do not average away,
terminal-shared correlations appear in covariance, and the model's claimed scope matches its
inputs.

### WD11 — implement integer ambiguity resolution only after float calibration

The existing class named `IslDoubleDifference` is not presently a full double difference: it
cancels a common receiver term but retains transmitter clock/bias content. It is therefore
not yet an integer-safe fixing observable.

1. Select and derive one integer-preserving architecture:

   - calibrated undifferenced ambiguities;
   - a genuinely synchronous two-transmitter/two-receiver double difference; or
   - a reciprocal/network-cycle combination whose clock and hardware cancellation follows
     from the actual transceiver timing architecture.

2. Prove the integer property symbolically and with noiseless simulation.
3. Marginalize continuous graph variables to obtain the full float ambiguity covariance.
4. Run LAMBDA and predeclared success/discrimination/integrity gates.
5. Condition and re-optimize once; retain parallel float and fixed solutions.
6. Roll back immediately after slip, calibration expiry, or residual-integrity failure.
7. Reuse all calibration gates in Issue 4.

**Gate:** integer fixing remains off in default and realism; correct-fix and false-fix rates
are separate; biased calibration stresses reject fixing. If the target is a false-fix rate
below \(10^{-3}\), the campaign size and one-sided binomial confidence bound must actually
support that claim—approximately 3,000 independent zero-failure trials are needed for a 95%
upper bound near \(10^{-3}\).

### WD12 — add fixed-lag operation after batch correctness

1. Keep batch optimization as the scientific reference.
2. Reuse the same variables/factors in a fixed-lag smoother.
3. Carry active ambiguity and calibration variables across the lag boundary.
4. Marginalize with Schur complements while retaining induced correlations.
5. Label outputs as batch/post-processed or fixed-lag/operational.

**Gate:** long-lag output converges to batch, marginal covariance remains symmetric positive
semidefinite, and runtime/memory scale with window size and active graph sparsity.

### WD13 — Whole Deal validation and promotion

Run, in order:

1. analytic/noiseless equation tests;
2. finite-difference Jacobian tests;
3. dense linear-Gaussian and Kalman-oracle comparisons;
4. graph rank, gauge, connectivity, and rigidity tests;
5. measurement ownership and duplicate-ID negative tests;
6. observable ablations: code, code+Doppler, code+float carrier, two-way range, time transfer,
   then optional integer fixing;
7. independent-seed Monte Carlo over initial state, clocks, dynamics, atmosphere,
   calibration, measurement noise, schedules, and slips;
8. gauge-projected NIS/NEES and empirical covariance coverage;
9. false-slip, missed-slip, false-fix, and wrong-hold campaigns;
10. batch-versus-fixed-lag and asset-order invariance;
11. N=1 and `federatedSimple` regressions.

Promote `wholeDealW2` from `experimentalGuarded` only when every active factor is supported,
the joint covariance is statistically credible, absolute and relative metrics are separated,
and no integrity decision depends on truth. Its first supported release uses float carrier;
integer fixing is a later independent promotion.

## Issue 11 — make coverage and validation measure evidence rather than configuration labels

### Current audit defects

`ModelCoverageAudit` currently:

- hard-codes a single-asset topology and an OCXO description;
- inspects selected model enables but not truth generation, estimator independence, shared
  covariance, or runtime activation;
- labels ambiguity resolution implemented regardless of the active readiness path;
- reports `modelCoverageStatus='complete'` whenever nothing is classified
  `missingUnsafe`, even if components are guarded or disabled;
- allows claim logic to depend too heavily on configured strings rather than loaded
  products/evidence.

The toggle manifest and prose notes also contain stale single-asset, matched-atmosphere, and
integer-method assumptions.

### Target evidence model

For every capability, record independent axes:

1. `configured`: requested mode/value;
2. `runtimeActivation`: generated/consumed counters and observation/state/factor IDs;
3. `maturity`: supported, experimental, unsupported, or retired;
4. `truthEstimatorRelation`: off, known-deterministic-both, independent-error-model,
   declared-joint-product-model, estimated-state, truth-only-stress, or oracle-violation;
5. `covarianceTreatment`: white, block-correlated, latent-state, consider, or missing;
6. `validationEvidence`: tests, campaign ID, seed count, revision, and date;
7. `claimCeiling`: C1, C2, C3, or unavailable C4.

Rename `complete` to `allCategoriesAccountedFor`. A run is scientifically eligible only if
all required active categories have suitable evidence at the requested level. The weakest
required component limits the run; enabling one complex feature cannot upgrade the whole
scenario.

### Resolution steps

1. Build coverage from the central capability registry introduced in Issue 7.
2. Derive topology, clock type, atmosphere, ambiguity, attitude, W1/W2, and observable
   status from the resolved live configuration and runtime manifest.
3. Fail the audit when:

   - an enabled truth effect has no estimator/covariance treatment;
   - truth and estimator share an unknown realization;
   - an enabled toggle has zero runtime activations;
   - an undeclared reader/factor activates;
   - the claimed level exceeds the evidence ceiling.

4. Make external-product readiness depend on a successfully loaded, time-valid,
   identity-matched, checksummed product—not a mode/status string.
5. Use the same registry for resolver validation, toggle manifest, coverage report, and
   scientific report so they cannot disagree.

### Current validation-campaign defects

`ScientificValidationCampaign` presently:

- uses the first available run's NIS/NEES result instead of aggregating all seeds;
- initializes `slipsDetected` without populating the actual detector count;
- computes “ambiguity fix rate” from active-baseline count divided by 15 rather than real
  fix decisions;
- uses an `OR` in the warning gate, allowing one tolerable metric to mask another severely
  failed metric;
- uses hard-coded RMS gates not tied to a mission requirement.

`MonteCarloConsistency` pools many temporally correlated epochs as if they were independent
chi-square samples for some NIS/NEES totals. That makes confidence intervals too narrow.

### Statistical validation plan

1. Predeclare mission-level accuracy, integrity, availability, continuity, and covariance
   criteria separately for C2, C3, and each stress case.
2. Use independent Monte Carlo seeds as the replication unit.
3. Compute ANEES/ANIS across independent runs at fixed epochs, or estimate an effective
   sample size/block-bootstrap when temporal aggregation is required.
4. Use the correct degrees of freedom:

   - three-dimensional tangent error for quaternion attitude;
   - observable-subspace/gauge-projected error for W2;
   - baseline/shape functions with covariance \(GPG^\mathsf T\);
   - joint degrees of freedom for correlated measurement blocks.

5. Add innovation autocorrelation/whiteness, empirical 1/2/3-sigma coverage, calibration
   reliability, and bias-versus-time plots.
6. Report each observable group separately, then the joint result. Never let a large code
   residual be hidden by many carrier rows or vice versa.
7. Record real event statistics:

   - injected/detected/missed slips and false resets;
   - created/closed arcs;
   - fix attempts, accepted correct fixes, false fixes, releases, and wrong-hold duration;
   - measurement outages and estimator availability.

8. Add negative controls that the validation **must** fail:

   - understated `R`;
   - understated `Q`;
   - duplicated W1 observation in W2;
   - rank-deficient link graph;
   - truth series injected into an estimator product;
   - static bias represented as white noise;
   - stale/mismatched phase calibration.

9. Separate a stress pass from a nominal accuracy pass. A severe stress may pass stability,
   integrity, and covariance-honesty criteria while deliberately missing nominal RMS.
10. Store the resolved-config hash, code revision, seed list, toolbox versions, and evidence
    artifact with every release decision.

### Kalman/filter implementation gates

1. Validate every active state block's units, prior mean/covariance, dynamics, process noise,
   measurement Jacobian, reset rule, and report extraction from one state registry.
2. Check continuous-to-discrete \(F,Q\) against analytic small systems and timestep changes.
3. Preserve covariance symmetry and positive semidefiniteness; use a numerically stable
   covariance update and test conditioning rather than clipping negative eigenvalues
   silently.
4. For multiplicative quaternion error states, test the three-component injection/reset
   Jacobian and score attitude in the tangent space.
5. When an ambiguity arc or calibration state is added/removed, preserve its cross-
   covariance and do not reinitialize unrelated states.
6. Align prediction and observation timestamps explicitly, including delayed ISL events.
7. Define innovation gating and robust-loss behaviour before simulation. Log every rejected
   row and ensure gating uses the correct correlated innovation covariance.
8. Tune \(P_0,Q,R\) from declared uncertainty models and independent campaigns; never tune
   from the hidden truth of the run being scored.

### Tests and promotion gates

- `test_model_coverage_audit_profiles`
- `test_model_coverage_tracks_live_activation`
- `test_model_coverage_no_string_spoof`
- `test_scientific_campaign_aggregates_all_seeds`
- `test_scientific_campaign_failure_logic`
- `test_mc_fixed_epoch_anees_anis`
- `test_w2_gauge_invariant_nees`
- `test_scientific_campaign_negative_controls`
- C2 release campaign
- C3 synthetic-realism release campaign
- `federatedSimple` release campaign
- Whole Deal float release campaign
- separate future integer-AR integrity campaign

No profile or W2 milestone is promoted by re-freezing a golden alone.

## Issue 12 — migrate scenarios, tests, documentation, and legacy code without hiding deltas

### Migration rule

Separate structural refactoring from scientific behaviour changes. First prove that the new
single resolver can reproduce each legacy resolved configuration; then apply one documented
scientific change at a time.

### Step-by-step migration

1. **Inventory all callers and inputs.**

   - `run_oo_v1`;
   - test/golden configuration factories;
   - battery/ladder/campaign scripts;
   - GEO comparison runners;
   - every JSON and MATLAB scenario helper.

2. **Install the resolver and schema in behaviour-preserving mode.**

   - route every caller through it;
   - record deprecated alias use;
   - compare resolved hashes and leaf diffs.

3. **Migrate profile ownership.**

   - reduce `default.json`;
   - make `realism.json` the explicit C3 diff;
   - convert every `realism.grade/include` use;
   - remove duplicate `realism_default.json`;
   - remove comment fields from runtime config.

4. **Apply deliberate C2 changes one issue at a time.**

   - simple non-oracle atmosphere with a declared truth/product joint error model;
   - all integer fixing off;
   - hard-error unsupported policy;
   - multiantenna attitude on for each default asset;
   - W2 off until WD4, then repaired fixed-range W2 on;
   - tower survey/systematics off unless their honest path has passed.

5. **Build C3 explicitly.**

   Add each conservative noise or truth effect only after its non-oracle estimator/joint-
   covariance path and test pass. Do not enable incomplete W1 ISL carrier, link-budget, light-time,
   slips, or integer paths as a shortcut.

6. **Migrate and rename tests.**

   - replace exact-cancellation atmosphere tests with `idealC1` analytic expected-value
     equation tests that never expose truth realizations to estimator code;
   - route golden realism construction through `realism.json`;
   - replace hidden-profile expectation tests with resolver-contract tests;
   - retain old numerical goldens as `legacy-reference`;
   - establish new C2/C3 goldens only after statistical acceptance.

7. **Update stale documentation and report language.**

   - `docs/atmosphere_realism.md`;
   - scientific validation ladder;
   - matched-atmosphere test slice name;
   - GEO “real-world” comparison names;
   - multiasset `fast/honest` descriptions;
   - W2 covariance/accuracy claims;
   - LAMBDA, phase-bias, and ambiguity-readiness descriptions.

8. **Remove legacy writers only after zero callers remain.**

   - `realismGradeConfig`;
   - `realisticAtmosphereConfig` as a config writer;
   - duplicate `finalizeConfig` calls;
   - `expandEnableToggles`;
   - `applyLuniSolar`;
   - `applyInjectTruthSideDynamics`;
   - `applyPerTowerHwBias`;
   - `preserveScenarioOwned`;
   - retired multiasset builders/modes after archived regression coverage.

9. **Version the scientific schema and results.**

   Increment a config/report schema version, provide migration errors for old keys, and embed
   the resolved configuration and hash in every result.

10. **Run final acceptance in dependency order.**

    Config-only suite → equation/Jacobian suite → C1 regressions → C2 Monte Carlo →
    C3 Monte Carlo → `federatedSimple` → Whole Deal stages → performance/long-run tests.

### Final acceptance criteria

- The only user workflow is: `run_oo_v1` selects exactly one JSON (`default.json` when
  omitted) → constructs the `masterConfig` base → overlays that JSON once → resolves once →
  validates once → simulates.
- No runtime writer changes an explicit scenario leaf.
- Default is the simple honest C2 mission; realism is an explicit C3 JSON diff.
- Every enabled effect creates truth and has an honest estimator/covariance disposition.
- Incomplete features are off and hard-error when requested.
- Integer fixing is off unless a separately validated advanced scenario passes all gates.
- `federatedSimple` and `wholeDealW2` have disjoint, documented measurement ownership.
- Every claimed result carries reproducible configuration and statistical evidence.

## Issue 13 — mode-by-mode disposition register

This register converts the audit into implementation decisions. It covers the current
user-visible feature families; the schema inventory in Issue 1 must expand each family to
individual leaves and reject any unregistered mode.

The implementation deliverable is an **exhaustive generated leaf/enum registry**, not only
this family summary:

1. Traverse every leaf declared by `masterConfig`.
2. Scan every accepted enum/mode branch and every canonical JSON reader.
3. Assign each leaf and enum value a capability ID, owner, truth generator, estimator
   consumer, maturity, C-level, prerequisites, and evidence tests.
4. Generate an appendix/table from that machine-readable registry into this audit.
5. Fail CI unless:

   - registered leaf count equals the resolved `masterConfig` leaf count;
   - every accepted enum value is registered;
   - every registered user input has at least one validated reader or is explicitly inert
     while its parent is off;
   - there are zero unregistered, unknown, duplicate-owner, or undocumented mode values.

| Domain / current mode family | C2 default target | C3 realism target | Resolution / governing issue |
|---|---|---|---|
| `realism.grade/include`, profile writers | absent | absent; explicit JSON leaves | retire hidden expansion; Issues 1–2 |
| `default.json` full snapshot | minimal/empty override | n/a | master is the base; Issue 1 |
| orbit-class helper | explicit GEO JSON or read-only derivation | explicit mission geometry | no post-merge writer; Issue 1 |
| asset topology N=1/N>1 | N=4 `federatedSimple`; explicit N=1 test/scenario | explicit N, initially 4 | no hard-coded single-asset audit; Issues 2, 9 |
| `formation.mode='helix'` | allowed synthetic geometry | explicit geometry/covariance | add rank/rigidity check; Issues 9–10 |
| truth orbit `stationaryEcef`, `j2Rk4` | `j2Rk4` GEO mission; stationary only C1 | richer explicit truth as supported | validate each propagator; Issue 6 |
| estimator dynamics `constantVelocity`, `j2` | explicit force set passing the duration/accuracy omission budget | separate non-oracle third-body/SRP products/priors, or named reduced-model stress | constant velocity/J2-only is C1 or short-duration stress unless justified; Issue 6 |
| luni-solar/SRP truth and estimator | include each term whose omission bound is material; four-hour GEO likely needs luni-solar | false until separate product/parameter treatment passes, then explicit on in a versioned profile | no copied unknown parameters; Issue 6 |
| SRP coefficient state | false until observability gate; then explicit if required by C2 budget | false until observability gate; then explicit estimated/consider treatment | no runtime conditional; Issue 6 |
| baseline/model-mismatch process noise | one explicit physical budget | one explicit residual budget | remove auto-enable/double count; Issue 6 |
| Earth rotation `constantOmegaV1` | supported simple convention | same or synthetic EOP residual | external IERS product remains C4; Issue 6 |
| solid-Earth tide | off | separate truth/correction with declared joint error if supported | static/geophysical correlation preserved; Issue 6 |
| light time `iterativeOneWay`, `sagnacFirstOrder` | one canonical supported model | same plus validated refinements | remove duplicate surfaces/double counting; Issues 1, 6 |
| Sagnac `firstOrderCorrection` | on exactly once | on exactly once | sign/rate tests; Issue 6 |
| Shapiro/clock relativity | simplest known terms as validated | additional validated known terms | uncertain inputs use a declared joint truth/product model; Issue 6 |
| spacecraft clock `legacy`, JOW templates | sourced nominal template with mission-duration validation | sourced conservative JOW template | validate PSD/Allan conversion; Issue 6 |
| tower-clock product/gauge aliases | one canonical product and gauge | separate biased product/state with joint covariance | preserve shared covariance; Issues 1, 6 |
| tropo `simpleMapped`, `localWeatherGM` | simple truth + non-oracle model/prior | local-weather/GM truth + product/state with declared joint error | never `sameAsTruth`; Issue 3 |
| iono `off`, `simpleMapped`, `tecGaussMarkov` | simple first-order truth/model | TEC-GM truth + product-like model with declared joint error | higher order separate; Issues 3, 8 |
| simplified “Klobuchar” model | off | standalone C3 `KlobucharLike` climatology after evidence | full ICD model needs implementation evidence; Issue 8 |
| ionosphere-free/raw code modes | raw L1/L2 default | explicit raw or validated IF | reject invalid signal/mode combinations; Issues 4, 7 |
| higher-order ionosphere | off | on only with validated inputs/signs | otherwise unsupported off; Issues 3, 8 |
| scintillation | off | off in base realism; bounded moderate standalone stress after gate | disturbed/severe off until lock/Doppler coupling; Issue 8 |
| ground code | on | on | declared noise/systematic covariance; Issue 2 |
| ground Doppler | on | on with conservative sigma | no silent disable; Issues 2, 7 |
| ground carrier | on, float arcs | on, float arcs | physical thermal sigma; Issues 4–5 |
| fixed versus C/N0 noise/floors | simple fixed/declared floor | supported C/N0 model with validated link inputs | larger sigma alone is not realism; Issues 2, 5 |
| float ambiguities | on when carrier is on | on | one state per valid arc; Issue 4 |
| `controlledRawCarrier` heuristic fix | off; C1 experimental only | off | not integer-safe enough for claims; Issue 4 |
| differential-attitude constrained integer search | off | off until phase-bias-disposition/integrity gate | float attitude remains on; Issue 4 |
| LAMBDA methods/feedback | off | off until advanced AR profile | solver only after integer-valid formulation; Issues 4, 10 WD11 |
| carrier-slip detector/compensations | supported ground mode after false-alarm validation | stress enabled only with truth slips/lock | ISL version waits for WD9; Issues 4, 10 |
| hardware/group delay | off/known ideal calibration | static/slow truth and product/state with joint covariance after gate | no config-time RNG or white laundering; Issue 5 |
| tx/rx code bias, DCB/inter-frequency bias | simplest absorbed/off contract | explicit signal-indexed truth/product/state | unimplemented state modes off; Issue 5 |
| multipath sinusoidal/coloured GM | off | truth-only bounded coloured site/link model | reserved carrier part off; Issue 5 |
| tower survey | off | static truth/product joint covariance after gate | current shared draw must be replaced; Issue 5 |
| antenna PCO | declared geometry/product | separate calibrated-product uncertainty with declared correlation | endpoint/attitude geometry; Issue 5 |
| PCV `toyAzEl` / ANTEX | off | toy only as labelled sensitivity | ANTEX remains C4 disabled; Issue 5 |
| inter-antenna phase bias | float bias state/product as needed | separate truth/product joint model; no fixing | product/bias-disposition schema required; Issues 4–5 |
| block/shared covariance | on for represented common sources | on and expanded | no diagonal substitution for bias; Issues 5, 11 |
| W1 multiasset `fast/honest/estimateMode` | replace with `federatedSimple` | same or `wholeDealW2` | retire/no-op modes; Issue 9 |
| towers observing secondaries | on for all assets in default architecture | on unless explicit outage | one W1 per asset; Issue 9 |
| secondary multiantenna/attitude | four phase centres; attitude estimated | same with explicit asset geometry | hard observability gate; Issue 9 |
| W1 one-way ISL code/Doppler/carrier | off | off | never the Whole Deal or W2 prior; Issue 9 |
| W2 two-way range | off until WD4, then on | on after WD4 with calibration states | fixed sigma first; Issues 9–10 |
| W2 one-way code | off until WD6 | individually selectable after WD6 | Whole Deal only; Issue 10 |
| W2 Doppler | off until WD7 | individually selectable after WD7 | Whole Deal only; Issue 10 |
| W2 carrier | off until WD8 | float individually selectable after WD8 | Whole Deal only; Issue 10 |
| W2 time transfer | off until WD10 | selectable with joint event covariance | calibrated raw timing required; Issue 10 |
| W2 slips | off until WD9 | selectable after truth/arc validation | event statistics required; Issue 10 |
| W2 integer fixing | off | off | separate advanced promotion after WD11; Issue 10 |
| ISL link budget `fixed/linkBudget` | fixed sigma with cited validity envelope | same fixed model until physical model is complete | current range scaling is not an RF budget; Issue 10 |
| W2 light time | off until event-time implementation | on only after WD10 tests | no truth finite-difference velocity; Issue 10 |
| report `complete`/real-world labels | evidence-based C2 | evidence-based synthetic C3 | C4 unavailable; Issue 11 |
| NIS/NEES and Monte Carlo surfaces | one canonical surface | same with C3 thresholds | independent-run/gauge-correct statistics; Issue 11 |

## Issue 14 — consolidated current error and contradiction list

The following are existing defects or scientifically unsafe behaviours to resolve. “Blocker”
means it can change or overstate a scientific result; it does not imply a software crash.

### Blockers

1. **Configuration is mutable after JSON merge.** Repeated profile/finalizer writers can
   override scenario-owned leaves.
2. **There are two base configurations.** The large `default.json` duplicates and already
   disagrees with `masterConfig`.
3. **The default violates the selected policy.** It currently resolves to complex atmosphere,
   enables two integer-fixing paths, and permits `disableWithWarning`.
4. **Tower survey can cancel by oracle.** Truth and estimator use the same sampled ENU
   vector.
5. **Integer fixing can bypass genuine calibration.** A heuristic raw path remains enabled
   while realism tightens only the differential-attitude path.
6. **Phase-bias status can be asserted rather than demonstrated.** Product completeness,
   covariance, validity, and provenance are insufficient.
7. **The coarse attitude reference reads truth plus noise.** It is not an implemented
   external attitude sensor.
8. **Current W2 synthesizes observations from truth inside the solver.** This violates the
   measurement/estimator boundary.
9. **W1 ISL reuse is not honest federation.** `keepIslInPerAssetEkf` risks duplicate
   information and inconsistent non-chief geometry without cross-covariance.
10. **Unsupported requests can be silently rewritten or disabled.** The completed run may
    not match its JSON.
11. **Coverage “complete” does not mean implemented or validated.** Guarded and disabled
    components can still yield that label.

### Major scientific/covariance defects

12. **Current W2 solves epochs independently.** There is no relative dynamics, arc history,
    or temporal covariance.
13. **Current W2 gauge covariance can appear overconfident.** Pseudoinverse null directions
    are not real zero-variance information.
14. **Configured W2 links are ignored.** The solver constructs its own nearest-neighbour
    topology, and connectedness alone does not prove 3-D rigidity.
15. **W2 delay “random walk” is not a state/process.** A constant draw plus diagonal
    inflation does not preserve the intended correlation.
16. **Optional W2 light time uses truth velocity.** The estimator cannot use truth-derived
    motion.
17. **The current ISL “double difference” is not clock/bias free.** Its remaining transmitter
    terms invalidate an automatic integer interpretation.
18. **The active ISL carrier sigma conflates thermal noise and model/initialization
    uncertainty.**
19. **The link-budget mode is not a complete physical link budget.** EIRP and G/T fields do
    not yet drive a full C/N0/tracking model.
20. **Dynamics realism can double count uncertainty.** Identical truth/estimator parameters
    are combined with extra model-mismatch Q, sometimes auto-enabled post-merge.
21. **Slow/static errors can be laundered into diagonal R.** This creates false
    \(1/\sqrt{N}\) confidence.
22. **The simple atmosphere's equal truth/model values are an oracle nominal case.**
23. **The current disturbed-ionosphere label would overclaim.** Its numerical TEC/S4 values
    lack event, geomagnetic, product, and receiver-lock context.

### Validation and maintenance defects

24. **Scientific campaign NIS/NEES is taken from the first available run**, not the full
    ensemble.
25. **Some temporal NIS/NEES samples are treated as independent**, narrowing statistical
    bands incorrectly.
26. **Slip detection count is not populated** in the campaign summary.
27. **Reported ambiguity fix rate is not a fix rate**; it is derived from active baselines.
28. **The warning gate uses an `OR`**, so one acceptable metric can mask another failed one.
29. **RMS gates are hard-coded rather than requirement-derived.**
30. **Audit/report descriptions are stale** for topology, oscillator, atmosphere, LAMBDA,
    realism, and multiasset behaviour.
31. **Golden realism fixtures bypass the production configuration path.**
32. **Duplicate aliases and inert/dead fields obscure ownership**, including profile,
    clock/gauge, slip, light-time, validation, and multiasset surfaces.
33. **Configuration resolution can sample physical errors**, coupling configuration order to
    truth RNG state.
34. **JSON comment-like fields can enter runtime configuration**, while unknown-key checking
    is not strict.
35. **The default force set is not selected from a duration/accuracy omission budget.**
    J2-only cannot be assumed credible for a multi-hour precision GEO claim.
36. **Separate W1 filters are not statistically independent.** Shared tower clocks,
    atmosphere, survey, hardware, and products correlate their posteriors.
37. **The planned/current observation covariance cannot be scalar-only.** Tracking channels
    and timestamp-derived observables may carry thermal as well as systematic
    cross-correlations.
38. **A robust/reweighted Hessian is not automatically a calibrated posterior covariance.**
    Robust estimation needs a separate covariance rule and claim gate.
39. **Attitude observability cannot be inferred from antenna count alone.** It needs a
    stacked, noise-weighted rank/conditioning/expected-error test over the active geometry
    and time window.

Every numbered item maps to Issues 0–13. An implementation pull request must name the item(s)
it resolves and the evidence gate it adds; no item is closed solely by changing a default.
