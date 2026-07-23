# archive/ — retired, zero-reference scaffolding (WP-3)

Files here are **not on any execution path** of the validated deliverable
(`run_oo_v1` → `ReportRunner.runSingle` → `ClockExactReportBuilder`). They were moved
out of the main tree to declutter it (WP-3 of the scientific-correctness review), after
verifying each has **zero functional references** anywhere in the repo.

They remain resolvable (an in-tree `archive/` stays on `genpath`), so nothing breaks;
this is an organizational boundary, not a deletion.

## Contents
- `run_oo_reverse_gnss_ladder_sweep_progressive_report.m` — legacy ladder-sweep report
  script; superseded by `run_ladder.m` / `tests/run_ladder_oo_v1.m`. 0 references.
- `run_oo_reverse_gnss_ladder_sweep_real_report_fixed.m` — legacy ladder-sweep report
  script. 0 references.
- `+revgnss/ReportSummary.m`, `+revgnss/ReportText.m` — Stage-7B report helpers; the
  "used by LatexReportBuilder" header was stale (LatexReportBuilder references neither).
  0 references.
- `+revgnss/BaselineDiffAttitudeDiag.m` — Stage-14.9 attitude-ambiguity diagnostic.
  0 references.
- `+revgnss/OriginalStyleReportLayout.m` — Stage-7B.3 report layout; production
  superseded by `ClockExactReportBuilder`. Only a stale *comment* mention remained
  (`tests/test_stage7b3_report.m`); no functional call.

## Deliberately NOT archived (corrects the review's §8 dead-list)
- **`+revgnss/ChiSquareConsistency.m`** is **NOT dead** — it has 6 live call-sites in
  `tests/test_filter_consistency_nees_nis.m` and is now also used by
  `revgnss.MonteCarloConsistency` (WP-5). Kept in `+revgnss`.
- **`run_oo_reverse_gnss_report.m`** is dead-by-intent in production but coupled to ~10
  validation tests; retiring it needs a coordinated test migration. Kept for now.
- The **`LatexReportBuilder`** cluster is production-dead but test-live (Stage-6/7 report
  tests). Kept in `+revgnss` with a header note; not archived.
