# Scientific Validation Ladder 2026-07-22

This document records the quick scenario-level ladder added for the required-fixes campaign. It is a smoke/regression gate, not a release-grade proof.

## Quick Ladder

`run_required_fixes_validation('Mode','quick')` writes:

- `output/RequiredFixValidation_20260722/metrics.csv`
- `output/RequiredFixValidation_20260722/metrics.mat`
- `output/RequiredFixValidation_20260722/summary.md`

The quick ladder emits one row for each required scenario:

- `Q1_G5S1R4_L1_matched_TW0`
- `Q2_G5S1R4_IF_ionoHO_TW0`
- `Q3_G5S1R4_realism_DCB_TW0`
- `Q4_G5S1R4_realism_DCB_TW1`
- `Q5_G5S3R4_twoWayISL_off`
- `Q6_G5S3R4_twoWayISL_on`
- `Q7_G5S3R4_twoWayISL_on_TWTT_on`
- `selected_stage24_twstft_guard`

## Pass/Fail Meaning

The quick rows are deliberately targeted:

- higher-order ionosphere and DCB rows are checked through the active raw/IF code measurement path;
- TWTT rows must appear in postfit/accounting diagnostics when enabled;
- datastore physical tower count is checked in the short simulation rows;
- swarm solved-shape metrics must be suppressed when two-way ISL is off and finite when enabled;
- sat-sat TWSTFT relative-clock metrics must be finite only when the relative-clock gate is enabled;
- Stage 24 TWSTFT remains diagnostic-only and cannot create EKF rows.

NIS/NEES statistical consistency remains covered by the existing focused tests in the Commit 8 gate. The quick ladder records short-run metrics, but it does not certify long-duration Monte Carlo consistency or release battery performance.
