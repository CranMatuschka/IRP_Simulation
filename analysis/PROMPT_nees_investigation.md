# Investigation prompt: why is the Monte-Carlo NEES 13.32?

Copy everything below the line into a fresh chat.

---

I need you to independently determine **why the Monte-Carlo NEES on our reference run is
13.32 per degree of freedom** when the innovation statistic on the same run is 0.866. Do not
take my framing on trust. Verify each fact yourself and tell me where I am wrong.

## Repository and data

- Code: `/Users/ludwigmatuschka/Library/CloudStorage/OneDrive-Persönlich/Dokumente/ICH/Karriere/Cranfield/IRP/Codes/IRP_Simulation/oo_v1`
- Branch `feature/ground-orientation-exec`. Run things via `run_oo_v1` only, per CLAUDE.md.
- Authoritative sweep: `oo_v1/IRP Ladder Results Final/` (108 rungs, 3600 s each, Monte
  Carlo forced on at 12 seeds x 900 s).
- Reference rung: `scene/scene008_G5S1R4_TW1_golden`. 105 measurement rows/epoch, 67 states
  (14 base + 3 gyro bias + 40 float ambiguity + 5 ZWD + 5 slant iono).
- The MC verdicts are **not** in any CSV and not in the `summary` struct. They exist only as
  `[WP-B]` lines in `IRP Ladder Results Final/_lane1.log` and `_lane2.log`. Associate each
  verdict with the preceding `RUN <ladder> <rung>` line in the same file.

## The numbers to explain

| quantity | value | source |
|---|---|---|
| arc innovation statistic (NIS/dof, 3600 s run) | 0.866 | `summary.arcNisOverallPerDof` |
| ensemble NEES/dof | **13.322** | `[WP-B]` line, 12 seeds |
| ensemble NIS/dof | 0.856 | same line |
| converged position error, last 20 % of 3600 s | 1.523 m | recomputed from `finalStateEstimate.posErrNorm_m` |
| same run, position error vs its own reported 1 sigma at 3600 s | ~1.19x | single-run diagonal |

A NEES of 13.3 implies the position error is sqrt(13.3) = 3.65x the reported sigma. The
single-run number says 1.19x. **Explain that gap.**

## What I believe I have already established (re-verify, do not assume)

1. `+revgnss/MonteCarloConsistency.m:105` pools `3 * nees` against `3 * count`, and the
   docstring says the pooled quantity is **position NEES with dof = 3**, not a 67-state NEES.
   If so, comparing 13.32 against a 67-state chi-square band is a category error.
   Confirm what `+data/SimulationDataStore.m:1903 getNEES()` actually returns: which states,
   which covariance block, and whether it is already divided by its dof.
2. `MonteCarloConsistency.m:75-80` draws the initial error from P0 for each seed, so this is
   **not** a fixed-offset artefact. Confirm.
3. `burnInFraction` defaults to **0.5** (line 29) and the MC arc is **900 s**, so the
   statistic is evaluated over roughly t = 450-900 s. The 3600 s reference run is still
   converging there: its position error is several metres at t = 900 s against a converged
   1.523 m. **My leading hypothesis is that the ensemble is measuring the filter mid-transient,
   where P has already collapsed but the error has not.**

## Hypotheses to test, in the order I would test them

- **H1, window.** The 900 s MC arc with 50 % burn-in never reaches convergence, so NEES is
  dominated by the transient. Test: re-run `MonteCarloConsistency.run` on the reference config
  with `duration_s = 3600` and the same 12 seeds, and compare. Also compute NEES as a function
  of epoch within the existing 900 s arc: if it falls monotonically, H1 is supported.
- **H2, dof and subspace.** The statistic is a 3-dof position NEES being read against a
  67-state band. Test: derive the correct per-epoch band for whatever dof it truly has, and
  restate the pass/fail.
- **H3, correlated errors charged as white.** Code multipath is truth-only with a 60 s
  correlation time and is charged to R as white. Removing it takes NEES from 13.32 to 1.438
  (rung `feat006_noMultipath`), which is the single largest mover in the sweep. Test whether
  that is a covariance effect or whether removing multipath also changes the convergence
  speed, which would make it an H1 effect in disguise.
- **H4, R inflated while P is too small.** NIS 0.866 means `S = HPH' + R` is too large, which
  normally implies P too large, not too small. Reconcile that with NEES > 1. A plausible
  mechanism is that R is inflated in the directions the measurements constrain while P is too
  small in a direction they do not. Test by looking at NEES per axis: radial, along-track,
  cross-track.
- **H5, PSD guard.** There is a positive-definiteness guard that floors small state variances
  and is known to have fired on 93.6 % of updates in one earlier configuration. If it inflates
  or deflates P, it would show here. Check whether it fires on this run.

## Traps that have already cost time on this project

- Three incompatible "converged" windows exist: `summary.finalPositionRMS_m` is the last
  **20 epochs**, `analysis/ladder_report.py` defaults to the last **50 %**, and the thesis uses
  the last **20 %**. Always state which you used.
- The clock error must come from `SimulationDataStore.getClockBiasErrors()`. Differencing the
  clock state against truth by hand measures a ~580 m relativistic ramp instead.
- On multi-asset federated rungs the Monte Carlo runs against a **reconstruction of the chief
  as a single-asset scenario**, so it is blind to the ISL and relative layers. Fourteen of the
  eighteen ISL rungs return a bit-identical band. Do not use an ISL rung's MC band as evidence
  about that rung. The reference rung here is single-asset, so this does not apply to it, but
  it will bite you if you widen the search.
- `report.monteCarlo.enable` resolves FALSE on 69 of the 110 ladder rungs. It must be set
  **after** `resolveSimulationConfig`, not in the JSON.
- If `biber` starts failing with RC=2 and no error message, its PAR cache is corrupt:
  `rm -rf $(biber --cache)`.

## What I want back

1. A definitive statement of **what quantity the 13.32 actually is**: which states, which
   covariance block, how many dof, over which epochs, pooled how.
2. The **correct acceptance band** for that quantity, derived rather than quoted.
3. A ranked, evidenced explanation of the magnitude, with the decisive test for each
   hypothesis and what it showed.
4. A recommendation: is 13.32 a real covariance defect, a measurement-window artefact, or
   both, and in what proportion?
5. If it is partly an artefact, what the honest reported number should be instead.

Show the commands and the numbers. Where you disagree with my hypotheses, say so directly.
