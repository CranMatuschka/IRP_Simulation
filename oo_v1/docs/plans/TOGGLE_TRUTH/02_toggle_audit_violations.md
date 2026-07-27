# Full toggle audit — violations of "one toggle, written only in masterConfig"

552 config keys audited across 5 of 6 domains (the `global` sweep — `atmosphere/realism/clock/
covariance/signals/report/data/...` — died on an output-size limit and must be re-run).
Repo scale: **69 scenario JSONs, 191 production .m, 268 test .m**.
`[M]` = measured in MATLAB this session.

---

## The root cause: eight things write toggles outside masterConfig

```
run_oo_v1.m:31   cfg = masterConfig()
                    ├─ :163  expandEnableToggles            ── PRE
                    ├─ :632  orbitClassConfig               ── PRE
                    ├─ :665  realismGradeConfig             ── PRE
                    ├─ :672  applyMultiAssetMode            ── PRE
                    ├─ :677  applyLuniSolar                 ── PRE
                    ├─ :678  applyInjectTruthSideDynamics   ── PRE
                    └─ :679  applyPerTowerHwBias            ── PRE
run_oo_v1.m:42   cfg = i_deepMerge(cfg, scenarioJSON)   <-- THE USER'S INPUT LANDS HERE
                 ConfigFactory.finalizeConfig(cfg)      ── POST, runs >= 2x
                    ├─ :604  applyAtmosphereProfile -> realisticAtmosphereConfig
                    ├─ :610  applyMultiAssetMode
                    ├─ :1573 MultiAssetConfig.normalize
                    └─ ~90 further derivations (:571-:1930)
                 ReportRunner.m:473, :2111, :2169-2236  per-asset leaf rewrites  ── POST
```

**PRE-merge writes** = the user's JSON can never influence that key.
**POST-merge writes** = the write silently *overrides* the user's JSON.
Both violate "masterConfig defines, JSON overrides, nothing in between" — in opposite directions.

---

## R2a — written PRE-merge (the toggle is inert from a JSON)

| writer | invoked | keys | what becomes inert |
|---|---|---|---|
| `expandEnableToggles.m:16-20` | masterConfig.m:163 | 24 | the 12 master `errors/effects/physics.<x>.enable` |
| `realismGradeConfig.m:35-237` | masterConfig.m:665 | 62 in 17 blocks | `realism.grade` + all 15 `realism.include.*` |
| `orbitClassConfig.m:41-134` | masterConfig.m:632 | 8 | `scenario.orbitClass` — the documented "SINGLE switch" — **and it overwrites masterConfig.m:489-493's own values** |
| `applyLuniSolar.m:19-35` | masterConfig.m:677 | 11 (2 undeclared) | `perturbations.sunMoon.{enable,ephemeris}` |
| `applyInjectTruthSideDynamics.m:33-44` | masterConfig.m:678 | 7 | `multiAsset.injectTruthSideDynamics` |
| `applyPerTowerHwBias.m:26-35` | masterConfig.m:679 | 7 (2 undeclared) | `errors.hardwareDelay.perTowerBias.*` — and it **forces `model.enable=false` (:31)**, deliberately undoing the invariant `expandEnableToggles` created 500 lines earlier |

### This is felt, not theoretical — measured across the committed scenarios

- **46 JSONs set `realism.grade=true`** → dead
- **24 set `realism.include.{hardwareDelay,multipath}=false`** → dead
- **43 set `realism.directOverlay=true`** → a key with **ZERO readers anywhere**
- …and each then hand-writes **59–66 flattened keys** to reproduce what the overlay would have done.

The decisive diff: `scene_G5S1R4_ts3600_TW1_inc.json` vs `..._caut.json` differ *exactly* by
`{realism.include.hardwareDelay, realism.include.multipath}` on one side versus **9 explicit
`errors.hardwareDelay.*` / `errors.multipath.*` keys** on the other. **The `_inc` scenes only
work by omission** — they get the right answer because they leave the dead toggles out and write
the real keys, not because the toggles work.

Also: `config/scenarios/max_realism_G5S6R4_ts3600.json` (mine) sets
`perturbations.sunMoon.enable` — a **silent no-op** by this table.

---

## R2b — written POST-merge (overrides what the user set)

`realisticAtmosphereConfig` via `ConfigFactory.m:604` rewrites **13 declared keys and adds 17
undeclared ones**. `[M]` on the untouched default: trop/iono `enable` false→**true**,
`modelType` `simpleMapped`→`localWeatherGM`/`tecGaussMarkov`, `stochastic.tau_s` 3600→10800 and
1800→600, `higherOrder.enable` false→**true**, `estimation.troposphereMode` `none`→`perTowerZwd`.

Around twenty more sites in `finalizeConfig` alone. Measured examples:

| key | user writes | resolves to |
|---|---|---|
| `measurements.codeMode` | `'ionosphereFree'` | `'singleFrequency'` |
| `estimator.towerClockMode` | `'perfectCorrection'` | `'truthHistoryProductNoisy'` |
| `measurements.carrier.slipDetection.threshold_m` | 7.35 | **0.1** |
| `estimator.estimateTowerClocks` | true | **0** |
| `effects.lightTime.model` | `sagnacFirstOrder` | `iterative` |
| `estimator.estimateAttitude*` (4 keys) | false | **1** (and true → 0) |
| `estimator.P0_euler_rad` | a tight value | **raised** |
| `estimator.estimateGyroBias` | false | **1** |
| `estimation.ionosphereMode` | `'none'` | `'perTowerSlant'` |
| `physics.sagnac.{truth,model}.enable` | — | forced **false** while `physics.sagnac.enable` still reads **true** |

That last row is the pattern in miniature: **the toggle reports one thing and the physics does
another**, which is the same class of defect as the ionosphere report row fixed in `2f30967`.

---

## Golden fixtures bypass the flag entirely

`[M]` `goldenRealismScenarioConfig` has **`realism.grade = 0`** yet calls `realismGradeConfig(cfg)`
**directly** at `goldenRealismScenarioConfig.m:46`. So even the realism golden does not use the
realism toggle. `goldenScenarioConfig(120).atmosphere.realistic = 0`;
`goldenHeadlineScenarioConfig` also `realistic = 0, nReceivers = 4`.

Consequence for the migration: the single-asset goldens run with the atmosphere overlay OFF, so
folding `realisticAtmosphereConfig`'s values into masterConfig cannot move them.

---

## What to do, in order

**Step 1 — stop the POST-merge overrides.** Fold `realisticAtmosphereConfig`'s values into
masterConfig as plain defaults and delete the overlay call. `[M]` proven a no-op:
`atmosphere.realistic` already defaults true, so the overlay's values ARE the effective
defaults. This alone makes `errors.{tropo,iono}.*` mean something from a JSON.

**Step 2 — move the PRE-merge writers after the merge.** `expandEnableToggles`,
`realismGradeConfig`, `orbitClassConfig`, `applyLuniSolar`, `applyInjectTruthSideDynamics`,
`applyPerTowerHwBias` — all six relocate into one `resolveCoupledDefaults(cfg)` at the top of
`finalizeConfig`. Then `realism.grade`, `scenario.orbitClass` and the 12 master `.enable` keys
work from a JSON for the first time.

**Step 3 — audit the remaining ~20 `finalizeConfig` overrides case by case.** Each is either a
legitimate *derivation* (fine — it computes something from inputs) or an *override* (must go).
`physics.sagnac` and `estimateAttitude*` look like overrides; `enabledByFrequency` looks like a
derivation.

**Step 4 — delete the dead keys and rename for consistency.** Only after 1–3, because until then
a rename changes behaviour rather than just text.

**Step 5 — re-run the campaign.** Every number produced before step 1 was produced with toggles
that may not have meant what the scenario said.

---

## Not yet audited

The `global` domain sweep failed on an output-size limit: `atmosphere.*`, `realism.*`, `clock*`,
`clocks.*`, `covariance.*`, `signals.*`, `carrierSlip.*`, `hardware.*`, `frames.*`, `data.*`,
`diagnostics.*`, `report.*`, `validation.*`, `rng.*`. Re-run it split into two or three smaller
sweeps. Everything above is from the other five domains plus targeted verification.
