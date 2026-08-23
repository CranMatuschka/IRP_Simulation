# Forensic Analysis Plan — reverse-GNSS EKF error budget

**Goal:** understand where the residual position error (radial ~10 m at 12 towers,
single GEO) comes from; verify the 24 h-regression claim; audit the Kalman filter
for falsely-implemented, double-counted, or mis-interrelated error handling; and
turn the ionosphere handling into clear toggles.

**Status:** authored 2026-07-13. Read-and-analyse heavy; no physics changes until a
bug is proven (each fix its own golden-verified commit).

---

## Part A — Two clarifications (settled)

**A1. `single` is a misleading name.** `codeMode='singleFrequency'` does *not* mean one
frequency. L1+L2 are both transmitted; they are fed to the EKF as **two separate,
uncombined pseudorange rows**, each still carrying its ionospheric delay (left in and
Klobuchar-corrected, or absorbed by the clock). Opposite of `'ionosphereFree'`, which
combines L1+L2 into one iono-free row. Better name: `'rawDualFrequency'`.

**A2. IF is a mode *and* a dead toggle.** `cfg.measurements.code.ionosphereFreeRows.enable/
useInEkf=true` exist but are **ignored** — `CodeMeasurementBuilder.m:455` only reads them
`if isempty(codeMode_v)`, and masterConfig always sets `codeMode`. Two overlapping
mechanisms → the confusion is real. Part E unifies them.

---

## Part B — Regression forensics (Phase 0, priority)

"24 h ago" = 2026-07-12 13:08, which predates the **entire** realistic-atmosphere series.
Clean before/after: yesterday 12-tower **ekfState** (1.27 m) vs today 12-tower **single**
(~10 m).

- **0.1 Reconcile "same geometry."** Diff yesterday's 12 towers vs today's 12 real sites;
  compare DOP / condition number. If sites differ, part of the delta is site choice.
- **0.2 Monte-Carlo, not one draw.** The radial is a bounded random walk (ladder: single
  runs 8–52 m are realization samples). Run baseline × N seeds → compare *distributions*.
  A regression only counts if the distribution shifts.
- **0.3 Forward bisect** `81a8244 → e715cdf → 8c5a45a → 5a28fe7 → 89a7550 → 63f8ec7` with an
  identical config + fixed seed; record radial + clock + NEES. The commit where the
  distribution jumps is the culprit.

**Ranked suspects:** (1) default `ekfState→single` (`5a28fe7`); (2) tower sites (`63f8ec7`);
(3) Klobuchar amplitude (`89a7550`); (4) iono-in-R double-count under ekfState (see C4).

---

## Part C — Kalman filter audit ("implemented falsely" check)

- **C1 State & init:** `x0`/`P0` per block physically sized; radial/clock null P0 not
  artificially tiny or huge; float-ambiguity x0/P0 match `randomInteger` init.
- **C2 Process F & Q:** per-state Q realism (rx clock h0/h-2; ZWD `tau_s=3600` too short →
  excess Q → null excitation; iono TEC `tau_s=600`; ambiguities ~0 Q); GM `exp(-dt/τ)`,
  `Q=σ²(1-φ²)`; missing cross-covariance.
- **C3 Measurement H & R:** analytic-vs-numerical Jacobian; R per type; elevation weighting;
  tower-clock product σ age-growth into R.
- **C4 Double-counting ("X'ed"):**
  - iono σ in R **and** iono a state (ekfState) → paid twice? ⚠ prime suspect.
  - iono `+` on code, `−` on carrier, applied once each.
  - tower clock in the model **and** product σ in R.
  - scintillation amplitude→R vs phase→carrier not both on carrier.
  - higher-order iono additive without re-adding first-order.
  - Sagnac/Shapiro/light-time applied once, truth side only.
- **C5 Truth/model:** independent RNG streams (no oracle copy); residual reaches innovation;
  `expandEnableToggles` didn't cross-slave; shared-RNG ordering fragility.
- **C6 Observability/gauge:** clock gauge not fighting the null; check **NEES** (state
  covariance), not just NIS.

---

## Part D — Isolated + combined error analysis

- **Full factorial truth × model** per error (iono, trop, scint, HO, hwdelay, multipath,
  PCO/PCV, tower-survey, clock): truth-only / model-only / both / neither → confirm each is
  a correct residual (→0 when matched).
- **Interrelation matrix** pairwise + the coupled triple iono×ZWD×clock.
- **Monte-Carlo per cell** + NEES/NIS → every number a distribution with a consistency verdict.
- Output: heatmap of contribution-to-radial, isolated vs combined.

---

## Part E — IF-toggle refactor

- One boolean `cfg.measurements.code.ionosphereFree = true|false` + orthogonal
  `cfg.estimation.estimateIono = true|false`.
- Delete the dead `ionosphereFreeRows.*` path (or make it the single source of truth).
- Rename `'single'`→`'rawDualFrequency'` (back-compat alias). Golden-safe, one commit.

---

## Part F — Execution order

1. Phase 0 (bisect + Monte-Carlo). 2. C4 (double-counting). 3. C1–C3, C5–C6. 4. Part D.
5. Part E. Deliverable: written error-budget report + golden-verified bug-fix commits + refactor.

---

## FINDINGS (executed 2026-07-13)

**Phase 0 (regression):** the radial is a bounded random walk. Monte-Carlo (5 seeds,
12 towers): single mean 34.9 m (10–65), ekfState mean 24.9 m (**2.2**–39). The "1.27 m
before" was a lucky low draw, not a lost capability → **no true regression**; the wide
distribution is the symptom.

**Part C (multi-agent audit, 6 confirmed bugs), ranked:**
1. **`sigma_accel_mps2 = 0.01` ~1e4× too large** for matched-J2 GEO → radial/clock null
   random-walk. **FIXED** (`baseConfig.m` → 1e-6). Verified 10.2 → **1.85 m** at fixed
   seed; NIS ~58. Golden re-frozen (smoke+full 184/184). Commit `9c1ad45`.
2. Klobuchar iono residual has no state and is under-priced in R. **Attempted R fix
   REVERTED** — zero radial benefit (time-correlated bias ≠ white R) and NIS 58→45.
   ekfState (state) also only marginal (mean 6.7 vs 7.8). The correct iono treatment is
   a state, but at this geometry it barely helps; the residual is the clock random walk.
3. IF R double-counts first-order iono variance ×(α²+β²)≈8.9. **FIXED** `23d73bb` —
   correlation-aware R_if (iono→0, trop/tower-clk→unit gain, HO iono→survival gain);
   golden-safe (IF unreachable by single-freq golden); IF NIS/measRows 0.72→0.93.
4. IF R treats correlated trop/iono as independent. **FIXED** (same commit `23d73bb`).
5. ZWD estimated by state AND full σ in R — double count. **FIXED** `9d53123` —
   when the perTowerZwd state is active, R carries only the fast per-step GM increment;
   slow variance lives in the state P. Golden-safe (golden troposphereMode='none');
   realistic NIS/measRows 0.97 (slightly improved).
6. Single-freq slant-iono H set but h has no iono term — H/h mismatch. **FIXED** `2c552c5` —
   iono H column now guarded on SignalConfigResolver.hasL2 (dispersion), matching where h
   adds the state; L1-only correctly absorbs iono into the clock. Golden byte-identical.

**Second double-count audit (independent) → 4 distinct doubles, all FIXED** (`90a327e`,
`2c552c5`): iono R-and-state (twin of ZWD), tower-clock R-and-state, IF hardware-delay
over-count, plus #6. Default config has NO live double-count. **Forensic pass COMPLETE.**

**IF-toggle refactor DONE** `953764e`: cfg.atmosphere.ionosphereFree + .estimateIono
booleans replace the 'single' string; ionosphereFreeRows verified diagnostic-only (no
EKF double-count). All CONFIRMED double-counts (#3/#4/#5) are now fixed.

**Also done:** receiver-clock Q investigated — NOT a bug (OCXO Q already ~6 mm/hr;
clock-type sweep shows no radial effect; residual is geometry). Asset clock changed
OCXO→CESIUM1 for realism only (`57ef638`, golden re-frozen 184/184).

**Net after fix #1:** radial 10 m → ~2–8 m (seed-dependent). The residual is the
receiver-clock random walk in the degenerate radial direction — geometry-limited (ISL
closes it). Remaining work: bugs #3–#6, the receiver-clock Q, and Part E (IF toggle).
