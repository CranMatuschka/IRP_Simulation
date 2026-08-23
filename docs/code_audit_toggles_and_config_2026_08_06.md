# Code audit — toggles, config hierarchy, sigma constants, dead code, comments

**Date:** 2026-08-06 · **Branch:** `feature/ground-orientation-exec` (uncommitted working tree)
**Method:** 15-agent audit (inventory → 6 audit dimensions → adversarial verification of every critical/major claim → completeness critic). 441 toggles and 161 sigma/noise configurables inventoried from `masterConfig.m`. **All 89 critical/major findings below were independently re-verified against the current code by adversarial verifier agents instructed to refute them; none were refuted.** Line numbers refer to the current working tree.

**Golden gate status (run before/during audit):** all three smoke gates PASS — `run_oo_v1_regression('smoke')`, `('smoke','headline')`, `('smoke','realism')`: 166/166 metrics within rtol 1e-9 vs the frozen goldens. No code was changed by this audit. The swarm-relative regression was not run (300 s swarm run, slower tier).

**The rule audited:** `masterConfig.m` is the single configuration source; it may be overridden only by one scenario JSON through `run_oo_v1` → `resolveSimulationConfig`. Everything below is measured against that rule.

---

## 1. Critical findings (4)

### C1. `finalizeConfig` silently clobbers scenario-owned signal frequencies
`+revgnss/ConfigFactory.m:1189-1192` — the signal-table rebuild unconditionally overwrites `cfg.signals.<name>.frequency_Hz` / `.lambda_m` with the canonical L-band values from `revgnss.SignalDefinition` (`fL1 = 1575.42e6`). This writer is **not** wrapped in `preserveScenarioOwned` (unlike the four writers at `ConfigFactory.m:618-621`), so a JSON frequency override is silently reverted after the overlay was applied.

### C2. The Ka-band scenarios actually run at L-band ⚠ scientific flaw
`config/scenarios/ka_c1_singleKa.json:99` sets `signals.L1.frequency_Hz = 30 GHz` (ka_c2: 30 GHz, ka_c3: 30/28 GHz). Because of C1 those values are clobbered back to 1575.42 MHz before the simulation reads them (`MeasurementModel.m:231`, `ErrorChain.m:259` consume the clobbered field). **Every result produced from the ka_c1/ka_c2/ka_c3 scenarios is an L-band result, not a Ka-band result.**

### C3. ka_c3's ionosphere-free mode is silently reverted ⚠ scientific flaw
`config/scenarios/ka_c3_kaIonoFree.json:90` sets `measurements.codeMode = 'ionosphereFree'`, and line ~16 sets `atmosphere.realistic = true` — which activates `ConfigFactory.applyAtmosphereProfile` (`ConfigFactory.m:501-553`). Since the scenario does not set `atmosphere.ionosphereFree = true`, the profile's else-branch forces `codeMode = 'singleFrequency'` (line 551-552). **The declared "Ka pair 30.0/28.0 GHz in the ionosphere-free combination" falsification run performs no iono-free combination at all — and runs at L-band (C2).** Any conclusion drawn from ka_c3 is invalid on two counts.

### C4. The J2 auto-tuner silently rewrites the configured process noise
`+revgnss/ConfigFactory.m:1875-1886` — whenever `orbit.truth.mode` ∈ {j2Rk4, j2} and `estimator.dynamics.mode = 'twoBody'`, `finalizeConfig` force-enables `modelMismatch` and replaces any user-set `processNoise.modelMismatch.sigma_mps2 ≤ 1e-6` with `max(1e-8, 0.25·|a_J2|)` (~2.1e-6 at GEO). `masterConfig.m:1761` sets exactly `1e-6` — right at the threshold — so in that model combination the configured value is always replaced. No `warning()`, no `cfg.validation.warnings` entry (neighbouring blocks do both). A deliberately tiny/zero mismatch sigma set to study raw dynamics mismatch is silently discarded. (Known from the 2026-08-05 audit; re-confirmed unchanged.)

---

## 2. Silent config overrides inside the sanctioned chain

These run inside `finalizeConfig`/`ReportRunner`, i.e. they fire even on a perfectly rule-abiding `run_oo_v1` run.

| Where | What is silently replaced | Condition |
|---|---|---|
| `ConfigFactory.m:699-705` | `cfg.estimator.towerClockMode` is unconditionally overwritten from `cfg.clocks.tower.product.mode` (which always exists). The documented direct knob (`masterConfig.m:1740`, `'perfectCorrection'`) is dead — this decides the truth-assistance level of the run. | every run |
| `ConfigFactory.m:545-553` | `applyAtmosphereProfile` replaces user-set `measurements.codeMode`, `estimation.ionosphereMode`, `errors.ionosphere.model.correction` from the two atmosphere booleans, no conflict check. `run_error_ladder.m:308` contains an explicit in-repo workaround comment ("prevent the finalize auto-apply double-enabling") — two layers fighting. | `atmosphere.realistic=true` |
| `ConfigFactory.m:1500-1534` | Tower and receiver **clock structs are regenerated** from `clockType`+`clockFactors` on every finalize; only name/deterministic/bias_s/fracFreq (+ non-default receiver seed) survive. Any clock leaf set directly in a JSON (h-coefficients, noise params) is discarded without warning. | every run |
| `ConfigFactory.m:1570-1596` | nReceivers==1: lever arms forced to `[0;0;0]`; nReceivers>1: `estimateAttitude` and `estimateAttitudeFromPseudorange` **forced true** regardless of user setting (only `attitude.useCodePartials=false` can veto the partials); a lever-arm matrix with the wrong column count is silently replaced by the hard-coded default cross. | every run |
| `ReportRunner.m:144-149` | Five `cfg.plots.*` toggles rewritten before every run: `plots.enable` slaved to `report.writePdf`; `saveIndividualFigures`/`saveFigures`/`savePdf`/`closeAfterSave` forced false. The masterConfig defaults (true/true/true/false) are permanently inert on the sanctioned path. | every run |
| `ReverseGNSSSimulation.m:147-171` | Joint multi-asset secondaries get carrier **force-disabled** (`carrierMode='none'`, `carrierPhase.enable=false`) per-asset regardless of configuration — comment only, no warning. Secondaries generate code+Doppler even when carrier is configured on. | joint mode, secondaries |
| `MonteCarloConsistency.m:73-80` | Per-realisation, configured `estimator.initialError.*` replaced by random draws from P0 (methodologically required for NEES — but the MC verdict characterises a different initial-error distribution than configured; comment only). *Downgraded to minor by the verifier.* | `report.monteCarlo.enable` |
| `ConfigFactory.m:1612-1614` | User `P0_euler_rad` auto-inflated to `max(5°, 2·initEulerMax)` when smaller than the initial attitude error; warning string appended to `cfg.validation.warnings` but no MATLAB warning printed. | attitude runs |
| `ConfigFactory.m:836` | `estimator.estimateTowerClocks` silently re-derived from `cfg.clock.mode` whenever the latter exists. | every run |
| `ConfigFactory.m:1103` | `carrierMode` 'off'/'diagnostic' silently forces `carrierPhase.useInEKF=false` (the legacy branch at 1114-1124 warns; this one does not). | those modes |
| `ConfigFactory.m:1199-1214` | A wrong-length user `enabledByFrequency` mask is silently replaced by the signal mask (code/carrier/doppler), making the length-check error at 1216-1219 unreachable. | wrong-length mask |

---

## 3. Toggles that are OFF but the feature still runs (disabled-but-active)

| Toggle (masterConfig) | Reality |
|---|---|
| `measurements.pseudorange.enable` (:2120) | Gates nothing. `MeasurementModel.m:189-196` builds code rows unconditionally; the flag is only echoed into report labels. `carrierPhase.enable` IS gated — the asymmetry invites false confidence. |
| `errors.ionosphere.scintillation.affectsCodeNoise` (:1915) | Never consulted. `ErrorChain.m:299-307` injects scintillation into the code chain whenever `scintillation.enable` is true; `CodeMeasurementBuilder.m:527-544` adds it to R. Setting false removes nothing. |
| `carrierSlip.resetAmbiguityOnConfirmedSlip` (:363) | Never read. `ReverseGNSSSimulation.m:542` applies ambiguity resets unconditionally; the actual gate is `measurements.carrier.slipDetection.action`. |
| `estimator.integerAmbiguity.resetOnSlip` (:293) | Never read; held-fix removal on slip runs unconditionally (`ReverseGNSSSimulation.m:545`). |
| `hardware.rxCodeBias.enable` (:2849) | Never read as a gate — `MeasurementModelUtils.m:192-205` keys entirely off `.mode`; `mode='fixed'` applies the bias even with enable=false. |
| `diagnostics.ekfInnovationAccounting.enable` (:423) | Innovation accounting computed unconditionally (`ReverseGNSSSimulation.m:836-838`); worse, the manifest report row claims this flag gates it. |

## 4. Toggles that are ON (or settable) but do nothing (enabled-but-inert)

48 confirmed major + ~21 minor. The dominant pattern: the only "reader" is a report echo or `SimulationToggleManifest` — which itself has **zero production callers** (see §7). Grouped:

**Doppler model-selection surface — entirely decorative.** `measurements.doppler.modelLevel` (:386), `.jacobianMode` (:391), `.includeSagnacRate` (:388), `.includeLightTimeRate` (:389), and `physics.lightTime.dopplerDerivative` (:2104): none is dispatched on. The real switch is `includeTowerRotationalVelocity` alone (`OneWayRangeRateModel.m:46-66`). Setting `modelLevel` makes the report echo contradict actual behavior.

**Cycle-slip config split-brain.** `measurements.carrierPhase.cycleSlip.enable` (:2137), `measurements.carrier.cycleSlipMode` (:2713), `carrierSlip.method` (:351), `carrierSlip.syntheticSlipInjection.enable` (:366), `carrierSlip.ignoreKnownProductBoundaryJumps` (:364), `carrierSlip.logDiagnostics` (:365), plus the three step-compensation flags (:355-357) and `diffAttitudeBaselineMode` (:358) — all unread. Actual control lives in `measurements.carrier.slipDetection.*` and truth injection in `cfg.validation.stress.slips`.

**`multiAsset.towerSecondary.*` block — promised features not wired.** `atmosphere.enable` (:1207) injects nothing (only flips a validator guard and report labels — the report can claim Guard A enabled while nothing was injected); `atmosphere.chargeR` (:1213) + `nCorrCap` (:1214) unread; `carrier.enable` (:1220), `doppler.enable` (:1236), `multiAntenna.enable`/`attitude.enable` (:1246/1248), `estimateAtmosphere` + `zwd.*` (:1262-1265), `code.sigmaModel` (:1193) — zero consumers. A `validateMasterConfig.m:~299` comment claims MeasurementModel "now owns this validation"; MeasurementModel contains no `secondary` reference at all.

**Shared-error covariance policy strings.** `covariance.sharedErrors.mode` (:377), `.applyTowerClockToCarrier` (:379), `.applyTowerClockToDoppler` (:380), `.carrierPolicy`/`.dopplerPolicy` (:381-382), `.ensureSPD` (:383), `.reportDiagnostics` (:385), `covariance.productClock.carrierPolicy`/`.dopplerPolicy` (:397-398) — no algorithm branches on any of them. Note `ScenarioPresets.m:346-349` *sets* several expecting an effect that does not exist.

**Ambiguity/attitude selection strings.** `estimator.integerAmbiguity.mode` (:287), `estimator.diffAtt.ambiguityResolution.method` (:326, duplicated :1686), `.allowExternalReferenceFallback` (:333), `estimator.estimateCarrierAmbiguities` (:1649 — ambiguity states are actually gated by `carrierMode='ekfFloat'` + `estimation.ambiguityMode`), `estimator.attitude.primaryMode` (:242), `.useRawCarrierForAttitude` (:270).

**Data/diagnostics namespace.** `cfg.data.backend` (:2925 — real switch is `diagnostics.storage.backend`), `cfg.data.snapshots.*` (:2928-2931 — real switch is `diagnostics.storage.fullSnapshot`), `cfg.data.legacyDiagnosticsEnable` (:2934), `diagnostics.sampling.computeConditionEveryEpoch`/`computeAttitudeSvdEveryEpoch`/`computeClockObservabilityEveryEpoch` (:2952-2954), plus 8 dead `diagnostics.*.enable` flags (:203, :204, :207, :241, :413, :421, :424, :425, :558) that are only ever *assigned*, never read. `diagnostics.sampling.heavyDiagnosticsInterval_s` is nullified by the default `computeRankEveryEpoch=true` (`Diagnostics.m:145-151`) — and the resulting property is itself write-only.

**Environment/physics.** `environment.weather.enable` (:1852 — parameters consumed unconditionally by `EnvironmentModel.m:751-760`), `.hydrostaticModelAssumption` (:1861), `errors.towerClock.driftCorrSigma_m_per_s` (:1951 — a sigma that can never reach R), `errors.ionosphere.scintillation.affectsPseudorangeBias` (:1916), `measurements.codeNoise.cn0.enable` (:1845 — model chosen by `codeNoise.model` string only), `cfg.signals.primary`/`.secondary` (:1823-1824 — L1/L2 hardwired; a test asserts the inert field equals 'L1', enshrining it), `effects.antennaPCV.modelType` (:2063 — real path is `effects.antenna.pcvModel`, :2767), `orbit.truth.cache.mode` (:985), `report.compactFinalReport`/`suppressStageSections`/`deduplicateFigures` (:70-72), `report.includeRawDiagnostics` (:2989).

**Hard-guard overrides (loud, not silent — but the toggle can never be used):** `estimator.enforceCarrierArcConsistency.enable=true` always errors (`ConfigFactory.m:656-666`, ignores `unsupportedFeaturePolicy`; its consumer `CarrierIonoFreeRowBuilder.m:64` is unreachable via the sanctioned chain); `multiAsset.twoWayTimeTransferISL.enable/useInEKF` always error (`validateMasterConfig.m:58-68` — the working key is `measurements.isl.twoWay.timeTransfer.enable`); `measurements.isl.oneWay.code/doppler.useInEKF` are rejected on the fleet path and unread on all others (`IndependentFleetCoordinator.m:657-679`); `isl.twoWay.doppler.enable` (validator :37), `estimator.attitude.useDopplerPartials` (validator :82 — despite a functional consumer existing in `LinkGeometry.m:173-175`), `secondaryTwoWayTimeTransfer.*` (validator :73, siblings unread), `diffAtt...requirePhaseBiasCalibrationForFix=false` always errors (`ConfigFactory.m:674`).

**Partial enforcement:** `multiAsset.twoWayISL.*` honored only by `SwarmRelativeSolver` on the federated path — silently ignored in `multiAsset.mode='joint'` (:1281); `multiAsset.federated.parallel=true` silently ignored when `savePerAssetMat=true` (`ReportRunner.m:2216`); `report.writeTex=false` ignored on the default `clockExact` layout (`ClockExactReportBuilder.m:105-107` writes unconditionally; only the non-default latex layout honors it); ISL carrier `slipDetection.action`: only `'resetAndUse'` implemented, other values noted-then-ignored (`IslCarrierTrackManager.m:61`); `validation.unsupportedFeaturePolicy` honored on exactly two legacy branches, unconditional errors everywhere else (`ConfigFactory.m:1118/1368`).

---

## 5. Sigma / noise constants outside masterConfig

| Where | Issue |
|---|---|
| `TowerClockCorrectionProvider.m:414` + `ProductClockCovarianceBuilder.m:266` | **Three inconsistent defaults for the same physical quantity**, each behind a silent try/catch: tower product clock sigmas masterConfig 0.01 m / 2e-4 m/s; provider fallback 0.05 / 1e-3; covariance builder fallback 0.10 / 1e-3. Harmless while masterConfig defines the fields; misleading the moment any caller passes a partial cfg. |
| `ScenarioFactory.m:171` | Tower-clock P0 built from unconditional literals 1000 m / 10 m/s with **no masterConfig entry at all** — the only P0 block in that function that cannot be configured. |
| `JointGeometrySolver.m:168` | Carrier-observable path hardcodes `multipathSigma_m=0` and `differentialAtmosphereSigma_m=0` in the DD weight — understates `out.ddSigma_m` whenever the scenario injects carrier multipath / un-cancelled differential atmosphere. ⚠ scientific flaw |
| `ErrorChain.m:80` | Legacy constructor shim synthesises `fullCfg.simulation.dt_s = 1.0` hardcoded — any legacy/test caller with dt ≠ 1 s gets wrong time-correlated error integration silently. Inert on the sanctioned path. |
| `CodeMeasurementBuilder.m:733` | `sharedErrors.enable`/`applyTowerClockToCode` read in one try/catch falling back to **false** — opposite of masterConfig's true. A missing field silently drops the shared tower-clock off-diagonal R block (EKF overconfident) instead of erroring. |
| `ReverseGNSSEKF.m:86` | Property default `estimateAngularRate=true` vs masterConfig false; cfg applied only via isfield — partial cfg silently estimates angular rate. |
| `BaselineCarrierAmbiguityResolver.m:432` | `useExternalReferenceAsSearchCenter` try/catch fallback **true** — opposite of masterConfig's false. |
| `SimulationToggleManifest.m:637` | Manifest fallback defaults for doppler modelLevel/jacobianMode (`'ecefOnlyV1'`) differ from masterConfig's actual defaults — would misreport if fields were absent. |

**Re-verified prior findings:**
- `ClockModel.m:214` — the FFT colored-noise 2/N amplitude defect is **FIXED** on this branch (`A_k = sqrt(N*fs*S_k)/2` now reproduces the one-sided PSD target). Not yet MATLAB-runtime re-measured.
- `ISLMeasurementBuilder.m:589-608` — one-way ISL product error still drawn once per 300 s interval but charged as per-epoch white R (filter averages a constant error as 1/√n). **Still open.** ⚠ scientific flaw
- `TwoWayISLMeasurementBuilder.m:264` — the same defect on the two-way path is now guarded (refuses to run when a persistent calibration error would be whitened) — partially remediated.
- `DopplerMeasurementBuilder.m:141-193` — when tower drift is an EKF state, the product-drift sigma is removed from R but no state coupling is added to h/H: tower-drift error entirely uncharged on Doppler rows. **Still open.** ⚠ scientific flaw

---

## 6. Config-bypass surfaces (the "parallel config universes")

These violate the "masterConfig + JSON via run_oo_v1 only" rule by construction. All are deliberate tooling, but they are standing mutation surfaces that skip `resolveSimulationConfig` **and therefore `validateMasterConfig`**:

- **`run_oo_reverse_gnss_report.m`** — self-described "Main user-facing" script competing with `run_oo_v1`; instructs users to edit toggles in-script; force-enables ~45 toggles (lines 53-96) behind `stageAllToggles` **or the env var `OO_V1_ALL_TOGGLES`**; scientific campaign with its own seed list; `compileTex` from env var.
- **Hidden env-var config channels** (no audit dimension, doc, or config file mentions them): `OO_V1_ALL_TOGGLES`, `OO_V1_REPORT_COMPILE_TEX`, `OO_V1_VALIDATE_REPORT` (+ stage/seed/count in `MainScriptValidationGate.m:33-41`, which also silently rewrites `report.compileTex`), `OO_V1_RANDOM_TEST_SEED`/`_COUNT` (`ValidationRunner.m:20`).
- **Battery/ladder family**: `run_oo_v1_battery.m:130+` (kills five frequency-dependent truth error sources for 'matched' grade, force-enables five effects, rebuilds lever arms), `run_ladder.m:99+` (documents the two-universe problem itself at 125-130), `run_error_ladder.m:160+` (~90 overrides; line 308 works around `applyAtmosphereProfile` — direct evidence the in-chain override is a hazard), `analysis/run_attitude_ablation_ladder.m:164+` (largest surface; zeroes dozens of noise fields; **line 278 writes `cfg.measurement.sigmaFloor_m` — singular 'measurement', a typo'd dead field whose intended floor silently never applies**).
- **Direct runners**: `run_swarm_check.m:10-15`, `run_geo_realworld_truth_comparison.m:4-17` (preset + re-stamped fields + own `finalizeConfig` call).
- **Factory presets**: 16 `ConfigFactory` preset builders (idealConfig etc., lines 82-399) rewriting physics/noise from `defaultConfig()`; `ScenarioPresets` mutators; `StressScenarioFactory` (3× tower clock sigma multiply, signal mask rewrites — gated on the science campaign); `ValidationCaseFactory`, `TriageScenarioFactory`, `tests/run_stage24_validation.m` (119 cfg writes) + sibling harnesses.
- **Regression fixtures** (acceptable practice, but note): `goldenScenarioConfig.m` (~28 overrides define what "golden" means), `run_swarm_relative_regression.m:52-73` (frozen priors 0.58 / 0.0736; file itself declares the 300 s rotation numbers "MEANINGLESS AS SCIENCE", determinism only).

**Latent trap (verified, currently inactive):** `ISLMeasurementBuilder.m:701` `getBool_` requires `islogical` — a numeric 1 silently reads as **false** for every `measurements.isl.*` toggle, while the ground-orientation solvers coerce numerics via `logical(getNum_)`. The same numeric-style override enables ground-orientation features but silently disables ISL/swarm features. All shipped JSONs currently decode to logicals, so nothing is broken today.

---

## 7. Dead code (assessed critically — nothing deleted)

- **`SimulationToggleManifest.m` (1477 lines): zero production callers.** Only 6 tests call `fromConfig`. This matters beyond dead code: the manifest is the *only reader* of dozens of toggles in §4, so it manufactures the illusion those toggles are consumed — and its own report row for `ekfInnovationAccounting` misstates a gate that doesn't exist.
- **GroundRelay TWSTFT subsystem (7 files, 1595 lines): test-only.** `measurements.groundRelayTimeTransfer.enable=true` in a JSON changes nothing in a real run.
- **Iono-free code cluster (~1166 lines, test-only):** `CodeIonoFreeRowBuilder`, `CodeIonoFreeConsistencyDiagnostics`, `CodeIonoFreeEkfDiagnostics`, `CarrierIonoFreeEkfDiagnostics`, `CarrierIonoFreeAmbiguityTraceability`, `IonosphereFreeBiasBudget`. (`CarrierIonoFreeRowBuilder` itself IS live.)
- **Attitude/ambiguity readiness cluster (~1681 lines, 8 files, stage-test-only):** `CarrierAttitudePreparation`, `AttitudeScenarioReadiness`, `AttitudeEvidenceReport`, `L2CarrierArchitectureDiagnostics`, `AmbiguityReadinessDiagnostics`, `AmbiguityArcState`, `CarrierRowMetadataInventory`, `OrbitDiagnostics`.
- **Permanently dormant production hook:** `AttitudeJacobianAudit` is invoked from `SimulationDataStore.m:1447` but its enable defaults false and **no config source can set it** — nine such cfg gate paths are read in code but never set anywhere in the sanctioned chain (`diagnostics.{attitudeJacobianAudit, attitudeScenarioReadiness, ambiguityStateMetadata, ifBiasBudget, ionosphereFreeCombination, l2CarrierArchitecture}.enable`, `estimator.integerAmbiguityFixing.enable`, `measurements.carrier.ionoFreeRows.enable`, `cfg.ar.l2CarrierEkfRows.enable`).
- **Orphans:** `+revgnss/+report/activePhysicsConfig.m` (the physics appendix never appears in any generated PDF — siblings are wired, this one is not; a test masks the disconnection); `GyroscopeMeasurementModel.m` (parallel gyro truth model; production uses `IMUModel` → can drift silently from what runs); `models/atmosphere/ionosphere.m`/`troposphere.m` facades (self-declared unwired); `ReportEquations.m`/`ReportTables.m` (the equations a test asserts on never reach any report); `StressScenarioFactory.m:66-73` disables gates that exist nowhere.
- **Duplicate assignment inside masterConfig itself:** `estimation.tropoZwd.initialSigma_m` set 0.3 at :406, overwritten to 0.10 at :2751 — the first declaration is dead and misleads a reader.
- **Resolved on this branch:** `GroundCarrierAmbiguityProbe` now has a production caller; all seven new ground-orientation files are wired (only `GoldenRunFingerprint` is test-only, by design). No accidental `if false` branches; no tests reference deleted classes; no dynamic dispatch outside tests (so the caller analysis is sound).

---

## 8. Comment quality

- **Stage references (the "deep layer" of the known cleanup):** worst comment-level offenders `IndependentFleetCoordinator.m` (12: lines 29, 363, 369, 502, 1074, 1190, 1276, 1329, 1724, 1849, 1890), `ReverseGNSSEKF.m` (5: 126, 747, 2134, 2248, 2262), `masterConfig.m` (5: 1091, 1100, 1107, 1121, 1324), long tail of ~20 files in the distributed/reciprocal layer with 1-5 each. `ReportRunner.m` has 221 hits but they are mostly `stageNN` *identifiers* and ~61 user-facing warning strings (renaming identifiers would break the golden metric names — do not touch without regenerating goldens). `StageHistory.m` is a sanctioned provenance ledger. The runtime log still prints "Stage 80:"/"Stage-85" strings.
- **Development-narrative comments** (describe the edit, not the code): `masterConfig.m` 14 lines ('previously UNDECLARED', 'The local override is deleted', :817-819, :1037-1043, :1052, :1151-1153, :1991) plus an open design question as prose (:821); `FourTimestampGroundSpaceTimeTransferBuilder.m:21-24,151`; `ClockExactReportBuilder.m:1539` ('SUPERSEDED — DO NOT EXTEND' block kept because its locals are still used), :1638, :1691; `IndependentFleetCoordinator.m:291,905,2117`; `SimulationDataStore.m:675,1586`.
- **Factually wrong/broken comments (mislead science):** `TwoWayTimeTransferBuilder.m:43-45` — sentence breaks off mid-parenthetical, leaving the H-row-dominance claim unreadable; `validateMasterConfig.m:~299` claims MeasurementModel owns tower→secondary validation (it contains none); the `SimulationToggleManifest` row asserting `ekfInnovationAccounting.enable` gates a computation that is unconditional; masterConfig comment at :2859 promises `rxCarrierBias` 'fixed' mode applies `fixedValue_m` — no consumer implements it.
- **Non-neutral register:** `GroundCarrierAmbiguityResolver.m:4-22` header debates a prior document ('WHY IT IS NOT THE ARGUMENT THE SUMMARY MADE', 'THAT is why…') and carries F2/F4/F5/F6 plan codes; `GroundDifferencedRotationSolver.m:42` all-caps 'READ THIS BEFORE BELIEVING ANY NUMBER THIS CLASS PRINTS.' (valid caveat, wrong register).
- **Overlong headers (>40 contiguous comment lines):** `TwoWayTimeTransferBuilder` 89 (longest), `JointGeometrySolver` 71, `GroundRelaySessionObservableBuilder` 71, `honestCovarianceConfig` 69, `GroundDifferencedRotationSolver` 66, `ClockModel.getProcessNoiseQ` A/B-test narrative, plus ~5 more 54-62.
- Positive: no TODO/FIXME/XXX anywhere in source; essentially no first-person or hype language (two benign hits).

---

## 9. Scenario-JSON overlay machinery — verified sound, with edge holes

**Verified working:** `deepMergeConfig` **errors** on any JSON path with no masterConfig counterpart; the full chain was executed in MATLAB over **all 125 scenario JSONs with zero load errors** — no typo'd/inert path exists in any shipped scenario. The new `ground_orientation_*.json` family is fully wired: every leaf has a live read-site and zero finalize clobbers were measured. Realism profile applies before the overlay (explicit JSON always wins); `preserveScenarioOwned` protects the four re-resolved finalize writers (but **not** the signal-table rebuild — C1). `tests/golden/*.json` are fingerprints, not overlays, and pin the SHA-256 of their scenario twins.

**Edge holes (latent):** struct-array overlays are replaced wholesale — a partial `towers` override silently drops base defaults for omitted fields, and a scalar-struct overlay onto a 5-entry array silently shrinks it to 1 (`deepMergeConfig.m:30-40`); any JSON key decoded to a leading `x_` is silently skipped as a comment (typos like `_enable` vanish, :17); the `realism.resolvePostMerge` guard checks `islogical` while the consumer uses `logical()` — numeric `1` evades the validator (`validateMasterConfig.m:26/386`).

---

## 10. Scientific flaws — collected

1. **Ka-band scenario family invalid (C2+C3):** ka_c1/c2/c3 run at L-band; ka_c3 additionally performs no iono-free combination. Any frequency-sweep conclusion drawn from them must be re-derived after fixing C1 (wrap the signal rebuild in `preserveScenarioOwned` or read scenario-owned frequencies).
2. **J2 auto-tuner (C4):** in j2-truth/twoBody-EKF runs the effective process noise is not the configured one; Q-sensitivity studies in that regime are contaminated.
3. **One-way ISL product-interval error whitened** (`ISLMeasurementBuilder.m:589-608`): piecewise-constant 300 s error charged as per-epoch white R — filter overconfidence by ~1/√n within each interval. (Two-way path now guarded.)
4. **Doppler tower-drift gap** (`DopplerMeasurementBuilder.m:141-193`): with tower clock states in the EKF, product-drift sigma leaves R but no H coupling is added — tower-drift error entirely uncharged on Doppler rows.
5. **`JointGeometrySolver.m:168`:** DD weight assumes zero multipath and zero differential atmosphere on the carrier-observable path — `ddSigma_m` understated when either is injected.
6. **Truth-assistance opacity:** `estimator.towerClockMode` is not a real knob (§2) — the truth-assistance level is decided by `clocks.tower.product.mode` alone; documentation/report text implying otherwise overstates configurability.
7. **Report-vs-behavior divergences:** the toggle manifest and summary echoes report `pseudorange.enable`, doppler `modelLevel`/`jacobianMode`, `ekfInnovationAccounting.enable`, towerSecondary 'Guard A' etc. as if they controlled the run — a report reader can believe a configuration that was not what executed.
8. **Silent secondary carrier disable in joint mode** (`ReverseGNSSSimulation.m:162`): joint-mode multi-asset results with carrier configured include secondaries that never produced carrier — measurement content differs from the configured scenario without notice.
9. **Fixed (verified):** ClockModel FFT colored-noise amplitude (2/N defect) is corrected on this branch — flicker floors now reach the simulated clocks. Prior runs' clock realism caveat still applies to their archived results.

---

## 11. Residual risk (not covered by this audit)

- docs/ claims vs code (`ground_referenced_orientation_*.md`, the .docx) — zero coverage; memory records prior unreproducible claims (1.53×, 99.9963 %), highest-value follow-up.
- A systemic sweep that every `ReportRunner.runSingle` caller either passes `validateMasterConfig` or is a sanctioned exception (three violators found by spot-check; the full caller list not enumerated).
- `ConfigFactory` preset bodies' hardcoded sigmas (skipped by the sigma pass); ~4000 unread lines of `ReportRunner`; method-level dead-method analysis inside large classes; the 26 `distributedEstimator` toggle polarities inside `IndependentFleetCoordinator`; dead-key analysis for the ~1200 masterConfig paths not touched by any scenario (only the ground-orientation family was fully traced).
- All 7 golden `.mat` baselines are modified on this branch — the smoke gates pass against them, but no one has verified the regeneration was itself intentional and fingerprinted.
- The ClockModel PSD fix is code-verified but not runtime re-measured; `De440Ephemeris.m:59-60` hard-depends on `$HOME/orekit-bridge`.
