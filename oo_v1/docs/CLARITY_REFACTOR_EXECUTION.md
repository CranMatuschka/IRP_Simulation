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
- **2. One toggle per feature; reframe mismatch — DONE** (`8feaaae`, `8f49831`; full gate green).
  2.1: one master `.enable` per effect via `config/expandEnableToggles.m` (the config
  surface can no longer manufacture a truth!=model mismatch). 2.2: the dynamics
  "mismatch" is LOAD-BEARING (process-noise tuning for the unmodeled J2 accel) — reframed
  and documented in place, NOT deleted (deleting would change the EKF's Q and move the
  numbers). Findings: clean switch-grouping of the ~40 diagnostic flags (C-8) is NOT
  equivalence-safe — the golden uses a specific on/off mix with overrides + a conditional
  that a single group on/off cannot reproduce; left sectioned. C-12 default → Phase 3.
  (C-1, C-2 done; C-8 infeasible-clean; C-12 → P3)
- **3. Honest default + single control surface — DONE** (`baseConfig` off=off; gate green).
  C-5: `config/baseConfig.m` default is now honest off=off (troposphere/ionosphere and the
  hardwareDelay model enable are OFF; raw EKF rows were already the effective default).
  masterConfig sets every error explicitly, so the golden is unchanged (gate PASS);
  `matchedErrorBaselineConfig` re-asserts its matched meaning explicitly; `test_stage7a_config`
  T1/T3 updated to the new contract. C-11 already satisfied (masterConfig uses only
  `enabledMask`). C-4 mode strings: already-documented multi-way selections, left as-is (low
  value). FINDINGS (pre-existing on `main`, NOT caused by this refactor — verified in a `main`
  git worktree): `test_nis_accumulated_dof` is inconsistent for the zero-code-noise
  `idealConfig` (|sumNIS-dof|=2838 identically on main and here; matched-vs-off atmosphere
  cancels in the innovation, so C-5 cannot affect it), and `test_stage6_config_presets` T5
  asserted a pre-finalize derived field — fixed to check the canonical `enabledMask`. (C-4, C-5, C-11)
- **4. Immutable simData + pipeline split — DONE** (`6d6c435`, `b9ab1da`, + assert; full gate green).
  4a: `SimulationDataStore` is frozen after `run()` (`freeze()` + guard on all four write
  methods; the data arrays were already private) — post/report receive a read-only store;
  `test_simdata_freeze` asserts writes throw and reads still work. 4b.1: `step()` split into
  `generateTruth_` + `runEstimation_` (two real stages; no local variable crosses the boundary
  — they communicate via obj state — so numbers are unchanged). 4b.2:
  `test_no_truth_leak_in_prediction` proves the EKF prediction is invariant to tower-clock
  truth realization (truth enters only via the measurement). The `data/SimData.m` file
  relocation is deferred to Phase 5 (folderization); the immutability + no-leak CONTRACT is
  delivered here. (C-10)
- **5. Folderize physics behind single entry points** — `models/<domain>/<effect>.m`;
  per-effect equivalence + finite-difference Jacobian audits.
- **6. One runner — DONE** (`05003be`). `run_oo_v1.m` is the clean canonical runner
  (masterConfig -> runSingle -> `output/<configName>_YYYYMMDD_HHMM.{pdf,mat}` + latest
  pointers; NO env-vars). Verified: report builds end-to-end, naming honored. The legacy
  `run_oo_reverse_gnss_report.m` + `OO_V1_*` validation tooling is RETAINED for the
  validation suite (~8 tests + ValidationRunner/MainScriptValidationGate); full env-var
  retirement is a flagged coordinated migration. (C-6, canonical path)
- **7. Split the report — DONE** (`b700802`, 7.2). ClockExactReportBuilder decomposed: all
  10 section writers extracted verbatim into `+revgnss/+report/*.m`; `writeTexFile_` is now
  a thin ordered coordinator. ClockExactReportBuilder 2559 -> 1477 lines. Verified by a
  normalized `.tex` byte-diff harness (`tests/report/reportTexFingerprint.m` + frozen
  `golden_report_tex.txt`): report `.tex` byte-IDENTICAL before/after; metric gate
  unaffected. (LatexReportBuilder figure engine + the ReportRunner summary-lift are
  follow-ups.) (C-9)
- **8. Demote stage bookkeeping to read-only provenance.** (C-7)

Invariant for every commit: the gate is green, no guard is weakened, numbers do
not move. The gate certifies "done" — not any edit or model.
