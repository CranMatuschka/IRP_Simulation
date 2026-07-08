# Step-wise scenario ladder — oo_v1

A plan for running the simulation across a ladder of scenarios. Every run goes
through the **normal main script** (`run_oo_v1.m`) and produces the **full report
(PDF + MAT + TEX)**. **Only `config/masterConfig.m` is edited** between runs — nothing
else. Ground network is **fixed at 5 towers** throughout.

The ladder:

1. Start with **1 space asset, all toggles on**.
2. Sweep **receivers 1 → 4** (space assets fixed at 1).
3. Sweep **space assets 1 → 6** (receivers fixed at 4).
4. One final run at **3600 × 24 s = 86 400 s (24 h)**.

Every run is **3600 s** except the last.

---

## 0. How a run works

```
edit config/masterConfig.m   →   run run_oo_v1   →   report written to
                                 output/Report_YYYYMMDD/Report_v<tag>_HHMM/
                                     report or <scenario>_v<tag>_HHMM  .pdf / .mat / .tex
```

- The runner reads `config/masterConfig.m` fresh each time (it takes no arguments),
  so a scenario is made **purely by editing that file** and re-running.
- `cfg.report.writePdf = true`, `cfg.report.writeMat = true`, `cfg.report.layout =
  'clockExact'` are already the defaults → each run builds the complete LaTeX report.
  *(clockExact needs `pdflatex`/`xelatex` on PATH. If LaTeX is unavailable the MAT still
  writes; set `cfg.report.compileTex = 'auto'` to fall back gracefully.)*
- **View any run's `.mat` in one window** with the companion script (see §5):
  `plot_mat_report` in MATLAB.

---

## 1. The knobs (all in `config/masterConfig.m`)

| Quantity | Field | Default | This ladder |
|---|---|---|---|
| Ground towers | `cfg.scenario.nTowers` | `5` | **5 (unchanged)** |
| Space assets | `cfg.scenario.nSpaceAssets` | `6` | `1 … 6` |
| Receivers / antennas | `cfg.scenario.nReceivers` | *(assembly builds 4)* | `1 … 4` |
| Run length | `cfg.simulation.duration_s` | `3600` | `3600`, then `86400` |
| Per-run folder tag | `cfg.report.runVersion` | `1` | a scenario label |
| "All toggles on" | 5 error-source flags | mixed | all `true` |

`cfg.scenario.nTowers = 5` is already the baseConfig default — **leave it alone** for
the whole ladder.

---

## 2. One-time baseline edits (do these once, before run A1)

These three edits set up "all toggles on" and make the receiver count fully
controllable (needed for the single-receiver case). After them, each run only
touches `nSpaceAssets`, `nReceivers`, `duration_s`, and `runVersion`.

### 2a. Turn all toggles on

In the **`%% Error sources`** block (≈ lines 92–98), flip these five to `true`:

```matlab
cfg.errors.hardwareDelay.enable    = true;   % was false
cfg.errors.multipath.enable        = true;   % was false
cfg.effects.towerSurvey.enable     = true;   % was false
cfg.effects.antennaPCV.enable      = true;   % was false
cfg.effects.correlatedNoise.enable = true;   % was false
```

Everything else physical is already on (sagnac, light-time, Shapiro, Doppler,
troposphere, ionosphere + scintillation, antenna PCO). Two flags are intentionally
**left as-is**: `physics.relativity.clock` (guarded off in `finalizeConfig` — not
validated in v1) and `carrierSlip.syntheticSlipInjection` (a fault-injection test, not
a physics effect).

### 2b. Make the receiver count controllable (enables R1)

In the **`%% Receiver geometry and lever arms`** block (≈ line 306), relax the guard so
a request of 1 receiver is honoured (otherwise it silently snaps to 4):

```matlab
% before:
if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers') && cfg.scenario.nReceivers > 1
% after:
if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers') && cfg.scenario.nReceivers >= 1
```

`finalizeConfig` then does the right thing automatically: `nReceivers == 1` forces a
zero lever arm and turns **all attitude estimation off** (single-antenna case, fully
handled — not an error); `nReceivers > 1` enables attitude.

### 2c. Add the receiver-count line

In the **`%% Scenario`** block (just after the `cfg.scenario.orbitClass` line, ≈ line 36),
add:

```matlab
cfg.scenario.nReceivers = 4;   % ladder knob: 1..4  (set per run below)
```

> After the ladder, **revert `masterConfig.m`** (or run on a scratch branch / `git stash`)
> so the frozen Stage-85 regression golden is not disturbed. These edits are for
> experiments, not for committing.

---

## 3. The runs

10 runs total. Each run changes only the four lines in the table, saves
`masterConfig.m`, and runs `run_oo_v1`. `A4` and the start of the asset sweep are the
same topology (S1 R4), so the asset sweep begins at S2.

| # | Label | `nSpaceAssets` | `nReceivers` | `duration_s` | `runVersion` |
|---|---|---|---|---|---|
| A1 | G5 S1 R1 | `1` | `1` | `3600` | `'S1R1'` |
| A2 | G5 S1 R2 | `1` | `2` | `3600` | `'S1R2'` |
| A3 | G5 S1 R3 | `1` | `3` | `3600` | `'S1R3'` |
| A4 | G5 S1 R4 | `1` | `4` | `3600` | `'S1R4'` |
| B2 | G5 S2 R4 | `2` | `4` | `3600` | `'S2R4'` |
| B3 | G5 S3 R4 | `3` | `4` | `3600` | `'S3R4'` |
| B4 | G5 S4 R4 | `4` | `4` | `3600` | `'S4R4'` |
| B5 | G5 S5 R4 | `5` | `4` | `3600` | `'S5R4'` |
| B6 | G5 S6 R4 | `6` | `4` | `3600` | `'S6R4'` |
| C1 | G5 S6 R4 24 h | `6` | `4` | `86400` | `'S6R4-24h'` |

Setting `cfg.report.runVersion = 'S3R4'` puts the output in a self-describing folder
`Report_YYYYMMDD/Report_vS3R4_HHMM/`, so runs never overwrite each other and are easy
to find.

---

## 4. Copy-paste prompts for Claude Code (one per run)

Each block is a self-contained instruction. Run them **in order**. Do the
**one-time baseline edits in §2 before A1** (they stay in place for the whole ladder).

> **Phase A — receiver sweep (1 space asset, all toggles on):**

```text
Scenario A1 — G5 S1 R1. In config/masterConfig.m set cfg.scenario.nSpaceAssets = 1,
cfg.scenario.nReceivers = 1, cfg.simulation.duration_s = 3600, cfg.report.runVersion =
'S1R1'. Leave the §2 baseline edits (all toggles on + the nReceivers >= 1 guard) in
place. Save, then run run_oo_v1. Confirm the report PDF + MAT were written under
output/Report_*/Report_vS1R1_*/ and report the final position/clock error from the run
summary.
```

```text
Scenario A2 — G5 S1 R2. In config/masterConfig.m set cfg.scenario.nSpaceAssets = 1,
cfg.scenario.nReceivers = 2, cfg.simulation.duration_s = 3600, cfg.report.runVersion =
'S1R2'. Save, run run_oo_v1, confirm PDF + MAT under Report_vS1R2_*, report the summary.
```

```text
Scenario A3 — G5 S1 R3. In config/masterConfig.m set cfg.scenario.nSpaceAssets = 1,
cfg.scenario.nReceivers = 3, cfg.simulation.duration_s = 3600, cfg.report.runVersion =
'S1R3'. Save, run run_oo_v1, confirm PDF + MAT under Report_vS1R3_*, report the summary.
```

```text
Scenario A4 — G5 S1 R4. In config/masterConfig.m set cfg.scenario.nSpaceAssets = 1,
cfg.scenario.nReceivers = 4, cfg.simulation.duration_s = 3600, cfg.report.runVersion =
'S1R4'. Save, run run_oo_v1, confirm PDF + MAT under Report_vS1R4_*, report the summary.
```

> **Phase B — space-asset sweep (4 receivers, all toggles on):**

```text
Scenario B2 — G5 S2 R4. In config/masterConfig.m set cfg.scenario.nSpaceAssets = 2,
cfg.scenario.nReceivers = 4, cfg.simulation.duration_s = 3600, cfg.report.runVersion =
'S2R4'. (nSpaceAssets > 1 turns on the helix ISL swarm aiding the primary EKF.) Save,
run run_oo_v1, confirm PDF + MAT under Report_vS2R4_*, report the summary.
```

```text
Scenario B3 — G5 S3 R4. In config/masterConfig.m set cfg.scenario.nSpaceAssets = 3,
cfg.scenario.nReceivers = 4, cfg.simulation.duration_s = 3600, cfg.report.runVersion =
'S3R4'. Save, run run_oo_v1, confirm PDF + MAT under Report_vS3R4_*, report the summary.
```

```text
Scenario B4 — G5 S4 R4. In config/masterConfig.m set cfg.scenario.nSpaceAssets = 4,
cfg.scenario.nReceivers = 4, cfg.simulation.duration_s = 3600, cfg.report.runVersion =
'S4R4'. Save, run run_oo_v1, confirm PDF + MAT under Report_vS4R4_*, report the summary.
```

```text
Scenario B5 — G5 S5 R4. In config/masterConfig.m set cfg.scenario.nSpaceAssets = 5,
cfg.scenario.nReceivers = 4, cfg.simulation.duration_s = 3600, cfg.report.runVersion =
'S5R4'. Save, run run_oo_v1, confirm PDF + MAT under Report_vS5R4_*, report the summary.
```

```text
Scenario B6 — G5 S6 R4. In config/masterConfig.m set cfg.scenario.nSpaceAssets = 6,
cfg.scenario.nReceivers = 4, cfg.simulation.duration_s = 3600, cfg.report.runVersion =
'S6R4'. Save, run run_oo_v1, confirm PDF + MAT under Report_vS6R4_*, report the summary.
```

> **Phase C — the 24-hour run:**

```text
Scenario C1 — G5 S6 R4, 24 hours. In config/masterConfig.m keep cfg.scenario.nSpaceAssets
= 6 and cfg.scenario.nReceivers = 4, set cfg.simulation.duration_s = 86400 (= 3600*24),
cfg.report.runVersion = 'S6R4-24h'. Optionally raise cfg.diagnostics.storage.snapshot.
interval_s to 900 to keep the MAT smaller. Save, run run_oo_v1 (this is long — 86 400
1-s EKF epochs), confirm PDF + MAT under Report_vS6R4-24h_*, report the summary.
```

---

## 5. Viewing a run — `plot_mat_report.m`

After any run, open its `.mat` in **one window with one tab per topic** (each tab has at
most two related subplots):

```matlab
plot_mat_report                 % pick a .mat with a file dialog (DEFAULT)
plot_mat_report('pick')         % same, explicit
plot_mat_report('latest')       % newest report .mat under output/
plot_mat_report('output/Report_20260707/Report_221005_S6R4_G5S6R4/report.mat')  % a file
plot_mat_report('output/Report_20260707/Report_221005_S6R4_G5S6R4')             % a folder
```

Tabs (each ≤ 2 subplots):

| Tab | Subplot 1 | Subplot 2 |
|---|---|---|
| Position (RAC) | radial / along / cross error | position error norm |
| Attitude | roll / pitch / yaw error | attitude error norm |
| Clock bias | truth vs estimate [m] | bias error [ns] |
| Clock drift | frac-freq truth vs estimate | drift error [m/s] |
| PR residuals | prefit innovation RMS | postfit residual RMS |
| Doppler & NIS | Doppler prefit/postfit RMS | NIS |
| Measurements | visible towers | total measurements |

The **position error is decomposed into RAC** (radial / along-track / cross-track) via
`revgnss.OrbitFrame.ecefToRacGeo` — the GEO-safe projection also used by the report
builder — which is far more interpretable than raw ECEF X/Y/Z. All series come from the
diagnostics store saved in the `.mat` (the same data source as `revgnss.Plotter`).

---

## 6. Notes & expectations

- **Ground network is fixed at 5 towers** for the entire ladder (`cfg.scenario.nTowers`
  is never touched).
- **R1 (single antenna)** produces a position + clock solution with **attitude
  automatically reported as unobservable** — the attitude panels will be flat/empty by
  design; that is correct, not a bug.
- **Space-asset sweep**: `nSpaceAssets = 1` is the ground-only golden path; `2…6` switch
  on the helix ISL swarm (`N−1` secondaries) whose one-way ISL code+Doppler aids the
  primary EKF. Expect the position/clock error to tighten as `N` grows.
- **24-hour run** is heavy: 86 400 one-second EKF epochs and a large `.mat`.
  `cfg.diagnostics.storage.mode = 'compact'` (already the default) keeps it bounded;
  raising the snapshot interval trims it further.
- **Protect the regression golden**: revert `config/masterConfig.m` after the ladder (or
  work on a throwaway branch / `git stash`). The frozen Stage-85 golden assumes the
  committed default config.
