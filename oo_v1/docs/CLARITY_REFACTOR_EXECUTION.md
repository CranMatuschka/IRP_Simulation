# oo_v1 Clarity Refactor — Execution Runbook (grounded)

This is the working runbook for the oo_v1 clarity refactor. It supersedes the
planning document (`OO_V1_CLARITY_REFACTOR_PLAN_v2.md`) wherever that document's
assumptions differed from the actual code. The *destination* is unchanged (one
literal config, one toggle per feature, no mismatch machinery, immutable simData,
foldered physics, sectioned report); only the *baseline, fixture design, and gate
mechanics* were corrected against reality.

## Decisions that differ from the planning doc (with evidence)

1. **Baseline branch = `main`, not `feature/oo-reverse-gnss-v1`.**
   `main` strictly *contains* the validated branch (`git rev-list` = 32 ahead,
   0 behind); the validated branch HEAD is exactly the Stage-85 checkpoint
   ("Stage 85: add formal synthetic validation campaign"). The validated 3600 s
   runs live on `main`. Work branch `feature/oo-v1-clarity-refactor` is cut from
   `main`; `main` stays the untouched rollback point.

2. **The audit is accurate.** Verified: dual `.truth.enable`/`.model.enable`
   toggles in 20 files (C-1); `dynamicsMismatch`/`modelMismatch` machinery in 8
   files (C-2); `OO_V1_*` env-var control (C-6); `ClockExactReportBuilder.m`=2559,
   `ReportRunner.m`=2326, `ConfigFactory.m`=2512 lines (C-9, and C-3 is worse than
   stated). The refactor is warranted.

3. **The canonical golden run is `run_oo_reverse_gnss_report.m`** — the
   `singleAssetCarrierAttitude` GEO scenario (4 receivers, L1+L2, carrier-attitude
   quaternion error-state EKF, integer AR, Doppler, code+carrier IF rows). Every
   dual toggle is set explicitly there with **truth == model per effect**, which is
   what makes the Phase-2 collapse provably numerics-preserving on this scenario.

4. **The regression fixture pins an EXPLICIT config, and freezes numbers, not the
   PDF.** `tests/regression/goldenScenarioConfig.m` is a verbatim snapshot of the
   canonical config block (report writing disabled). The gate reads `out.summary`
   (collected before any PDF build) — no LaTeX needed. This is required so that the
   Phase-3 change to the *default* config cannot move the *pinned scenario's*
   numbers.

5. **Two-tier gate.** Full 3600 s compute ≈ 106 s; still too slow to run after all
   16 commits. So: `smoke` (120 s) after every commit for fast drift detection;
   `full` (3600 s) at phase boundaries and before declaring a phase done.

6. **Determinism is bitwise.** Two runs with a pinned global seed (`rng(42,
   'twister')`, set by the harness to also cover a stray `randn` in the attitude
   reference init) agree to `maxRelDiff = 0` across all 177 finite metrics. Gate
   tolerance is therefore tight (rel 1e-9 / abs 1e-12) — it admits only
   FP-reassociation noise, nothing scientific.

7. **Toggle collapse (Phase 2) is not purely mechanical.** The validated run
   *legitimately* keeps truth != model for dynamics (J2 truth vs two-body EKF,
   Stage 82). Collapsing per-effect dual toggles must preserve legitimate
   structural differences and remove only the config surface that *manufactures*
   arbitrary mismatches. Audit each effect against the golden scenario before
   collapsing.

8. **Model orchestration** (`.claude/agents/`) is kept **inside oo_v1/** only, as
   documentation of intent. Execution is a single Opus session delegating
   mechanical/bulk steps to subagents.

## The regression contract (Phase 0, DONE)

Files in `tests/regression/`:

| File | Role |
|---|---|
| `goldenScenarioConfig.m` | Frozen verbatim snapshot of the canonical config (writePdf/writeMat off; optional duration override). |
| `runGoldenScenario.m` | Pins `rng(42)`, builds the config, runs `ReportRunner.runSingle`. |
| `extractMetrics.m` | Map of every finite numeric-scalar summary metric (177 today). |
| `coreMetricNames.m` | The 39 hard-contract metrics (position/clock/attitude/NIS/residuals/rows/IF coeffs/energy/AR). |
| `captureGolden.m` / `capture_all_golden.m` | (Re)generate `golden/golden_{smoke,full}.mat`. |
| `run_oo_v1_regression.m` | The gate: PASS iff every core metric matches within tol and no core metric appeared/disappeared. Non-core diffs are reported, not failed. |
| `run_oo_v1_regression_3600s.m` | Full-tier wrapper that errors on FAIL. |
| `golden/golden_{smoke,full}.mat` | Frozen references (committed; override the root `*.mat` ignore). |

Frozen full-3600 s headline (the numbers that must not move):
`finalPositionRMS_m=0.296`, `finalClockBiasRMS_m=0.288`, `meanNIS=58.24`
(`expectedNIS≈100`), `initialAttitudeError_deg=1.501` → `finalAttitudeError_deg=0.082`
(`attitudeImprovementRatio=18.38`), `knownAmbImprovementRatio=6.31`, rows 40/40/20,
54 states, 40 ambiguities.

### Run the gate

```
cd oo_v1
matlab -batch "addpath('tests/regression'); run_oo_v1_regression('smoke')"   % per-commit
matlab -batch "addpath('tests/regression'); run_oo_v1_regression_3600s"       % phase boundary
```

## Phase plan (each step is one atomic commit ending green)

- **0. Freeze contract** — golden + gate above. **DONE.**
- **1. One literal `config/masterConfig.m`** — own every value as a literal; drop
  `ConfigFactory.defaultConfig/cleanConfig/matchedErrorBaselineConfig` +
  `ScenarioPresets` layering for the canonical path; necessary derivations →
  `validateMasterConfig.m`; `configGEO` becomes a small override. (C-3, C-5, C-7)
- **2. One toggle per feature; delete mismatch machinery** — collapse dual toggles
  (plan §6 mapping) after per-effect audit; delete `dynamicsMismatch`/`modelMismatch`
  scaffolding (keep J2-truth/two-body-EKF as a modelling choice); fold ~40
  diagnostic flags into grouped switches; pick one scientific default (raw rows in
  EKF, IF diagnostic). (C-1, C-2, C-8, C-12)
- **3. Honest default + single control surface** — off = off; mode strings →
  documented enums/booleans; one signal path (`enabledMask`), delete
  `twoFrequency.enable`. New default gets its own sanity test (separate from the
  frozen-scenario equivalence gate). (C-4, C-5, C-11)
- **4. Immutable simData + pipeline split** — `data/SimData.m` contract + runtime
  guard; `generateTruth.m` / `runEstimation.m`; no-truth-leakage assert. (C-10)
- **5. Folderize physics behind single entry points** — `models/<domain>/<effect>.m`;
  per-effect equivalence + finite-difference Jacobian audits.
- **6. One runner; retire env-var control** — `run_oo_v1.m`; delete `OO_V1_*`
  branches; naming contract `configName_YYYYMMDD_HHMM.{pdf,mat}`. (C-6)
- **7. Split the report** — `report/sections/*.m` + thin `buildReport.m`. (C-9)
- **8. Demote stage bookkeeping to read-only provenance.** (C-7)

Invariant for every commit: the gate is green, no guard is weakened, numbers do
not move. The gate certifies "done" — not any edit or model.
