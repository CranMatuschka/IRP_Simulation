# Toggle dependency list — "if I enable X, what else must be on?"

Reference for writing scenario JSONs. Each entry: **enable X ⟹ also set Y**, why, and what
happens if you don't. `MEASURED` = verified by a run this session. `READ` = verified in source.

Ordered by how badly a missing dependency misleads you: the top entries produce a **plausible
wrong number**; the bottom ones produce an obvious error or an inert flag.

---

## A. Silent no-ops — the flag is on, the run ignores it

### A1. `errors.<effect>.enable` ⟹ `.truth.enable` AND `.model.enable`
Applies to all twelve slaved effects: `physics.{sagnac,lightTime,relativity.shapiro,
relativity.clock,doppler}`, `errors.{troposphere,ionosphere,hardwareDelay,multipath}`,
`effects.{towerSurvey,antennaPCO,antennaPCV}`.

MEASURED — a JSON setting only the master enable:
```
errors.multipath.enable=true      -> enable=1 truth=0 model=0   NO-OP
errors.hardwareDelay.enable=true  -> enable=1 truth=0 model=0   NO-OP
effects.towerSurvey.enable=true   -> enable=1 truth=0 model=0   NO-OP
effects.antennaPCV.enable=true    -> enable=1 truth=0 model=0   NO-OP
physics.relativity.clock.enable=1 -> enable=1 truth=0 model=0   NO-OP
```
Cause: `expandEnableToggles` runs at `masterConfig.m:163`, BEFORE `run_oo_v1.m:42` merges the
JSON. Physics and report both read the PAIR, never the master.
**Workaround today:** write all three keys, as `config/scenarios/realism.json` already does.

### A2. `realism.grade = true` ⟹ nothing (complete no-op from a JSON)
MEASURED: `clock.templateSource=legacy` (realism wants `jowTable2p1`), `codeNoise.model=constant`
(wants `cn0`), `errors.multipath.enable=0` (wants 1), `clocks.tower.product.sigmaBias_m=0.01`
(wants 0.10). Same pre-merge cause as A1; `masterConfig.m:665` is the only reader in the repo.
**Workaround:** hand-write the values (what `scene_*_inc` does). `realism.directOverlay` has
ZERO consumers — it is a comment shaped like a switch.

### A3. Atmosphere: your value is OVERWRITTEN, not ignored
`atmosphere.realistic` defaults **true** and its overlay runs AFTER the merge, unconditionally.
MEASURED: `errors.ionosphere.enable=false` → resolves to **1**. Likewise `scintillation.enable`,
`stochastic.enable`, `estimation.troposphereMode='none'` → `'perTowerZwd'`,
`measurements.codeMode='ionosphereFree'` → `'singleFrequency'`.
**To actually change the ionosphere, use `atmosphere.ionosphereFree` / `atmosphere.estimateIono`,
not the `errors.ionosphere.*` keys.** This is why an ionosphere ablation can read back
"the ionosphere is not the cause" when it is.

### A4. `estimator.lambda.isl.enable` ⟹ `estimator.lambda.isl.applyFix = true`
MEASURED: with `applyFix=false`, `applyIslIntegerFix_` returns before assessing, so LAMBDA
reports nothing at all — the toggle looks enabled while doing nothing. The safety is the
resolver's own success-rate gate + ratio test, not leaving applyFix off.

### A5. `multiAsset.keepIslInPerAssetEkf` ⟹ `measurements.isl.enable = true`
MEASURED: without ISL enabled there is nothing to keep — nx stays 59, rows/epoch unchanged.
This is exactly why the `_islekf` campaign twins were byte-identical to their bases.

---

## B. Enabled but starved — produces a plausible WRONG number

### B1. `measurements.isl.carrier.enable` ⟹ `...carrier.ambiguity.enable = true`
Without the float ambiguity state the carrier row is BIASED by the arc ambiguity and the filter
is confidently wrong. A guard exists; do not bypass it.

### B2. `measurements.isl.carrier.useInEKF` ⟹ `measurements.isl.warmup_s > 0`
MEASURED: warmup 0 gave absolute errors of 153 / 330 / 531 m at sigma = 12 mm — confidently
wrong, not obviously broken. 300 s is the working default.

### B3. `...carrier.slipDetection.enable` ⟹ leave `threshold_m = NaN`
NaN auto-derives as `5*sqrt(2)*sigma`. MEASURED: a hard-coded threshold desynchronises from
`carrier.sigma_m` and produced **423 false slips**; tracking rows from t=0 instead of from
first EKF use produced **878**.

### B4. `errors.interAntennaCarrierBias.enable` (truth) ⟹ a working model
MEASURED: truth bias on with no model gives **9.08 deg** attitude error against a 1.5 deg prior
(diverging, q4/q1 = 1.29 on every seed); bias off gives **0.22 deg** converging. The model side
(`estimator.interAntennaCarrierBias`) exists but is INERT — `bias_cycles`/`bias_m` default `[]`
so `lookupMeters_` returns 0 while `resolvedStatus()` claims `calibratedExternalProduct`.
**Nothing populates those arrays.** Same root cause silently zeroes the diffAtt rows.

### B5. `nSpaceAssets > 1` ⟹ `formation.crossTrackSpread > 0`
MEASURED: at 0 the projected-circular helix puts z = 2x for every member, so the ISL LOS matrix
is EXACTLY rank-2 (sv3/sv1 = 2e-8) and the filter shrinks covariance in a blind direction.
Default is now 1.0.

### B6. `estimator.srpCoefficient.enable` ⟹ `.useInEKF = true`
`enable` alone does not append the state.

---

## C. Hard errors / structurally impossible

### C1. `measurements.isl.*` ⟹ `scenario.nSpaceAssets >= 2`
`ISLMeasurementBuilder.validateConfig` hard-errors: *"ISL requires at least two represented
space assets."* MEASURED — this is what broke `golden_realism_*` when the realism overlay
started enabling ISL at nSpaceAssets=1.

### C2. `measurements.twstft.enable` ⟹ `.code.enable = true` AND `measurements.isl.timing.enable`
MEASURED: `twstft.enable=true` with `code.enable=false` (the masterConfig default) emits **zero
rows** — enable alone is not enough. And `requireIslTiming` defaults true, so without
`isl.timing.enable` it hard-errors. Note sat-sat TWSTFT adds **no EKF rows** at all; it is a
diagnostic scaffold. The real time transfer is `measurements.twoWayTimeTransfer`
(tower↔spacecraft) and `multiAsset.twoWayTimeTransferISL` (sat-sat, relative layer).

### C3. `estimator.attitudeCarrierMode = 'calibratedDifferentialAmbiguity'` ⟹ `nReceivers >= 2` AND `carrierMode = 'ekfFloat'`
`finalizeConfig` (≈:1331/:1335) forces it to `'off'` otherwise, silently.

### C4. `estimator.lambda.ground.enable` ⟹ `nReceivers > 1` AND `attitudeCarrierMode ~= 'off'`
Otherwise there are no between-antenna baselines and `assess()` returns
`unavailable-noBaselines`.

### C5. `estimator.lambda.enable` ⟹ `estimator.lambda.toolboxPath` non-empty
External TU Delft LAMBDA, not vendored. Empty path = engine cannot run.

### C6. `atmosphere.ionosphereFree` ⟹ `atmosphere.realistic = true` AND two signals
MEASURED: with `realistic=false` it is silently ignored (`applyAtmosphereProfile` returns early).
With one signal there is no IF combination to form.

---

## D. Mutual exclusions — enabling BOTH is the error

### D1. `measurements.isl.code.useInEKF` XOR `multiAsset.twoWayISL` in the EKF
One-way ISL code and two-way ISL range cannot both be EKF-used without a joint covariance
model. `ReportRealityHelper` guards this (`islDoubleCounting`).

### D2. `measurements.codeMode = 'ionosphereFree'` XOR `estimation.ionosphereMode = 'perTowerSlant'`
Correcting the ionosphere twice. An explicit error already fires (`ConfigFactory.m:564-567`).

### D3. `multiAsset.keepIslInPerAssetEkf = true` ⟹ W1/W2 OVERLAP, disclose it
Not an error, but the per-asset EKFs (ground) and the relative layer (ISL/TWSTFT) then share
measurements, so the RELATIVE sigmas are optimistic by an unquantified factor. Default false
keeps them informationally disjoint.

---

## E. Things that look coupled but are NOT

- **`measurements.code.ionosphereFreeRows.{enable,useInEkf}` are DEAD keys.** Their only
  non-test consumer is unreachable (`codeMode` is never empty). The live code gate is
  `measurements.codeMode`; the live carrier gate is `CarrierIonoFreeRowBuilder.shouldCombine`.
  **They disagree by default: code raw, carrier IF.**
- **`cfg.ionosphere.mode`** has zero physics consumers. Documentary only.
- **`realism.directOverlay`** has zero consumers.
- **`measurements.carrierPhase.enable`** is only a FALLBACK; `measurements.carrierMode` is the
  authoritative gate and masterConfig always defines it.
- **`estimator.attitude.useCodePartials`** silently drives `estimateAttitudeFromPseudorange`
  (`ConfigFactory.m:1500-1506`) — setting the latter alone does nothing.

---

## F. The user's original rule, and why it is not implemented yet

> "if I have two frequencies I want IF enabled automatically; only explicitly disabled should be
> disabled"

Blocked by one fact: after the JSON merge, a `false` written by `masterConfig` is byte-identical
to a `false` written by you. A tri-state sentinel (`[]`/`'auto'`) plus a provenance set from
`i_deepMerge`, resolved post-merge, is the mechanism — designed, recorded, NOT applied because
adversarial review found the drafted auto-rules would hard-error three committed scenarios
(`ideal_G5S1R4_ts3600_flat*`, `baseline_G5S1R4_ts3600_clocksZero`, which legitimately set
`realistic=false` with explicit `ionosphereFree`) and the golden fixture.

The prerequisite is the resolution-order fix (see `00_status_and_plan.md` §3.0b): move
`expandEnableToggles` and `realismGradeConfig` after the merge, and fold
`realisticAtmosphereConfig`'s values into masterConfig — MEASURED to be a no-op, because
`atmosphere.realistic` already defaults true. Once nothing runs between masterConfig and the
JSON, A1–A3 disappear and the auto-rules become implementable.
