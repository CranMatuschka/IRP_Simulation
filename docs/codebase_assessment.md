# oo_v1 Codebase Assessment — Scientific Completeness, Dead Code, Comment Freshness

Scope: the `oo_v1/` tree (431 `.m` files excluding `output/`). Method: a static reference
sweep (symbol-by-symbol, comments stripped, plus a dynamic-dispatch string check), a
comment-pattern scan over the library source (excluding `tests/` and `archive/`), and a
synthesis of the term-by-term validation carried out for the validation manual.

---

## 1. Scientific completeness — is it accurate enough, and how to prove it?

### 1.1 Verdict

**For its stated purpose — a proof of concept — the simulation is already scientifically
sound.** The estimator core, the orbit dynamics and the measurement geometry are correct
and internally consistent; the error models are physically grounded; the error chain is
double-count clean; and truth and estimation are strictly separated. What is missing is not
correctness but (a) a few *truth-scenario* realism choices that make the default kinder than
reality, (b) some *force-model / product* completeness items, and (c) *external* validation
evidence (statistical consistency over an ensemble, and cross-checks against an independent
reference). None of these is required for the concept to be valid; each is required to
*prove* it to a sceptical examiner.

### 1.2 What is already scientifically established (verification passed)

- Two-body + J2 orbit is genuinely integrated (RK4); two-body energy conserved to ~2e-14;
  truth and EKF share the same force family, so the Jacobian is self-consistent.
- EKF math is textbook-correct: Joseph covariance update, right-division gain, no explicit
  inverse, multiplicative quaternion (MEKF) attitude error-state with a consistent
  convention across all six touch-points.
- Physical corrections (Sagnac, iterative light-time, Shapiro, relativistic clock) carry the
  right signs and magnitudes and match the literature to order-of-magnitude.
- Atmosphere, clock, multipath, noise models are physically parameterised and the
  truth/model divergence is structural (independent streams), not an oracle.
- Double-count clean: every physical error enters truth once, the model once, the covariance
  once; the two genuine estimate-and-charge risks are closed by verified guards.

### 1.3 What is missing / limiting (by category)

**A. Truth-scenario realism (highest scientific impact).**
- The default truth receiver clock is deterministic-zero (`cfg.asset.clock.deterministic =
  true`, zero bias/drift): the on-board clock error is identically zero, so the primary
  timing target is trivial. Realism grade de-optimises only the estimator's clock Q, not the
  truth clock.
- The default oscillator template (`legacy` caesium) is ~3 orders of magnitude quieter at
  1 s than a real caesium; only realism grade switches to the literature-anchored template.
- The default truth attitude is a constant Earth-fixed orientation, not nadir/LVLH pointing;
  the four-antenna estimator is sound but recovers a pole-locked attitude.

**B. Force-model and frame completeness.**
- Higher-order geopotential (C22/S22 tesseral) absent — drives GEO east–west libration over
  days; negligible over a 4 h run.
- Atmospheric drag absent — correct for GEO/MEO but makes the exposed LEO class non-physical.
- Earth orientation is first-order constant-rate (no precession/nutation/polar-motion/UT1 at
  IERS grade).

**C. Measurement-model completeness.**
- Inter-frequency differential code bias is inert on the active path (hardware delay is
  emitted non-dispersively), so the realism-grade DCB values do nothing until a genuine
  per-signal split is implemented.
- No integer ambiguity fixing (LAMBDA/MLAMBDA) on the long tower–spacecraft carrier; it runs
  as float ambiguities. Fixing is confined to the short antenna baselines.
- No ingestion of real products (ANTEX / IONEX / SP3 / CLK / RINEX); all error models are
  synthetic (though physically sized).

**D. External validation evidence (the gap that matters for "proving it").**
- The Monte-Carlo consistency harness exists (`MonteCarloConsistency`) but is off by default
  and typically run at short duration / few seeds.
- No cross-validation against an independent implementation (orbit propagator, atmosphere
  model, clock Allan) and no comparison to real data.
- No Cramér–Rao lower-bound (CRLB) computation to show the filter is efficient and that the
  radial↔clock wall is fundamental rather than a filter artefact.

### 1.4 How to PROVE scientific accuracy — a concrete validation ladder

Distinguish **verification** (is the maths implemented correctly?) from **validation** (does
it match physical reality?) and **statistical proof** (is the reported uncertainty honest?).

1. **Analytical / unit benchmarks (verification) — largely done.** Energy conservation, J2
   magnitude, Sagnac/Shapiro magnitudes, Allan-deviation slopes, ionosphere-free
   cancellation, Jacobian finite-difference checks. Keep these as the first proof layer.

2. **Filter-consistency proof (statistical) — the single most convincing internal proof.**
   Run the Monte-Carlo NEES/NIS harness with a real ensemble (≥30–50 seeds) over ≥1 sidereal
   day. A consistent filter has NIS and NEES inside their chi-square bounds; report the
   bounds and the pooled statistics. Where the one-way GEO shows NEES above the band while
   NIS is in-band, that is the *observability wall* — prove it is fundamental (next item),
   not a bug.

3. **Cramér–Rao lower bound (CRLB) — proves optimality and the wall.** Compute the CRLB from
   the measurement geometry and noise for the position/clock states, and show (i) the filter
   covariance approaches the CRLB (the estimator is efficient) and (ii) the radial↔clock
   direction has an intrinsically large CRLB on the one-way geometry that collapses when a
   two-way observable is added. This converts the "wall" from an empirical observation into a
   provable information-theoretic limit.

4. **Cross-validation against an independent tool (external validation) — strongest external
   proof.** Reproduce a subset in independent software and show agreement: the GEO trajectory
   against an established propagator (e.g. GMAT or Orekit), the tropo/iono slant delays
   against a reference GNSS library, and the clock Allan deviation against the analytic
   power-law. Agreement to a stated tolerance is publishable evidence.

5. **Literature / real-data anchoring (validation).** Anchor each achieved error envelope to
   published results: two-way time transfer to Merlo et al. (2023) / T2L2; code/carrier noise
   to Kaplan & Hegarty; clock h-parameters to Winkel (2003). Ideally, process one real
   two-way or SLR data arc and compare.

6. **Reproducibility / regression (already in place).** The frozen-golden gate proves the
   scientific numbers are stable across changes — cite it as the reproducibility guarantee.

Items 2–4 are the highest-value additions: they turn "the machinery is correct" into a
quantitative, defensible proof of accuracy and of the fundamental limit.

---

## 2. Dead code that can be deleted

High-confidence (zero code references, zero dynamic-dispatch string mentions, verified):

- **`archive/` (6 files)** — explicitly retired scaffolding, kept resolvable but referenced
  by nothing:
  `archive/+revgnss/BaselineDiffAttitudeDiag.m`, `OriginalStyleReportLayout.m`,
  `ReportSummary.m`, `ReportText.m`, and
  `archive/run_oo_reverse_gnss_ladder_sweep_progressive_report.m`,
  `run_oo_reverse_gnss_ladder_sweep_real_report_fixed.m`.
- **`+models/+errors/BiasArchitecture.m`** — a static helper (`describe`/`toTable`) intended
  for report rows but called from nowhere. Orphaned.
- **`+revgnss/+report/perReceiverDiagnostics.m`** — a report section extracted from
  `ClockExactReportBuilder` (see the note at `ClockExactReportBuilder.m:1378`) but never
  wired back in. Either delete it, or re-connect it if the per-receiver section is wanted.

Lower-confidence / review (entry points, so "unreferenced" is expected — judgement needed):

- **Superseded test-runner scripts.** Tests are auto-discovered by
  `tests/run_all_tests.m` (`dir('tests/test_*.m')`), so the many one-off runners
  (`run_all_tests_stage8.m`, `run_tests14.m`, `run_missed_tests14.m`,
  `run_stage27_validation.m`, `run_stage28_validation.m`, `run_oo_experiments.m`, …) are
  largely redundant. They do no harm but add clutter.
- **Possibly-superseded top-level scripts.** `run_oo_reverse_gnss_report.m` and
  `analyse_oo_reverse_gnss_ladder_sweep.m` look superseded by `run_oo_v1.m` /
  `run_error_ladder.m`; confirm against your workflow before removing.

Not checked exhaustively: intra-file unused *private* helper methods (a per-file review would
be needed; the frozen-golden discipline makes large intra-file dead code unlikely).

---

## 3. Comment freshness and neutrality

### 3.1 Verdict

The comments are **scientifically accurate** (the physics/estimator descriptions match the
code, as verified term-by-term for the manual), but they are **not neutral**: they carry
process/history metadata that should be stripped, and a few are **stale** (contradict the
code). The target is short, neutral, scientific comments that state a constraint or the
physical meaning, with no reference to how or when the code got there.

### 3.2 Non-neutral history markers (library source; excludes tests/ and archive/)

| Marker type | Occurrences |
|---|---|
| WP-x / P-prime labels (WP-A, WP-I, P1', P2', …) | 96 |
| Stage NN references | 28 |
| Issue N/NN references | 16 |
| Version bumps (vN→vN) | 12 |
| `CHANGED:` markers | 13 |
| C-nn refactor labels | 11 |
| Dates (20xx) | 3 |
| Commit hashes | 2 |

Roughly **180 strict non-neutral markers**, concentrated in `config/masterConfig.m` (34),
`+revgnss/ISLMeasurementBuilder.m` (25), `+models/+clocks/ClockModel.m` (13),
`+revgnss/Diagnostics.m` (10), `+revgnss/+report/activePhysicsConfig.m` (9),
`+data/SimulationDataStore.m` (8). Separately, "golden/frozen/byte-identical" appears ~240
times and "legacy" ~97 times — some are legitimate (e.g. the config value
`templateSource = 'legacy'`), but many are process references to the regression gate that
belong in test/CI documentation, not in physics comments.

### 3.3 Stale / contradictory comments (examples)

- `config/masterConfig.m:138` — "The receiver clock is stochastic" heads
  `cfg.clock.receiver.deterministic = false`, but the truth clock actually used is
  `cfg.asset.clock` with `deterministic = true`, `bias = 0`, `fracFreq = 0`
  (`masterConfig.m:762`). The effective truth receiver clock is therefore deterministic-zero,
  so the comment misstates the behaviour. Neutral fix: "The truth receiver clock is
  deterministic (zero bias and drift) by default; its oscillator spectrum drives only the
  EKF process noise. Set `asset.clock.deterministic = false` for a stochastic truth clock."
- A full comment-vs-logic audit (per file) is recommended beyond this one confirmed example;
  the manual flagged the clock case, and the "extracted to …" note at
  `ClockExactReportBuilder.m:1378` documents a change whose call site was not reconnected.

### 3.4 Overly long comments

Several inline comments run to paragraph length and mix rationale, history and a tuning-sweep
narrative into a single block — e.g. the attitude process-noise comment
(`masterConfig.m:410–422`, ~12 lines) and the SNC `sigma_accel_mps2` comment
(`masterConfig.m:1104`, one very long inline sentence). These should be reduced to a short
statement of the physical meaning and the constraint, with any sweep/derivation narrative
moved to documentation.

### 3.5 Recommended neutral comment style

- State the physical quantity, its units, and any hard constraint the code cannot express
  (e.g. "must exceed 0.1× the J2 RMS acceleration").
- No stage/WP/issue/commit/version/date references; no "CHANGED:"; no regression-gate
  language in physics comments.
- One to three lines; move derivations and tuning history to `docs/`.
- Keep genuine value names that happen to read like history (`templateSource = 'legacy'`) —
  those are API, not commentary.

This cleanup is comment-only and therefore numerically inert (the frozen references are
unaffected), so it can be done safely as a mechanical pass file-by-file.
