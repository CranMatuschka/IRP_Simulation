# Required Fixes Validation Contract

Date: 2026-07-22

This contract defines the automatic evidence generated while closing the scientific-correctness fixes in `docs/required_fixes_execution_plan_20260722.md`.

## Entry Point

Run validation from the repository root:

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run_required_fixes_validation('Mode','unit');"
```

Supported modes are:

- `unit`: focused source-path and unit checks for the active fix.
- `quick`: short deterministic integration ladder, without PDF-dependent pass/fail.
- `release`: full corrected validation ladder and battery evidence.
- `runtimeOrder`: reversed-order runtime diagnostic for the `G5S3R4` TW0/TW1 comparison.

## Required Outputs

Every successful invocation writes:

- `output/RequiredFixValidation_20260722/metrics.csv`
- `output/RequiredFixValidation_20260722/metrics.mat`
- `output/RequiredFixValidation_20260722/summary.md`

The harness fails the MATLAB process when any row has status `fail`. Rows marked `xfail` are allowed only for findings that have a named future commit in the execution plan.

## Metric Fields

The metrics table records:

- scenario id, mode, focus, status, and diagnostic message;
- duration, tower count, asset count, and datastore physical tower count;
- active measurement types and code row counts by signal;
- two-way time-transfer row count;
- postfit residual counts and mean NIS by type;
- NEES where truth-state alignment is valid;
- position and clock RMS;
- raw and solved relative-shape RMS;
- swarm gate flags;
- DCB and higher-order ionosphere active flags.

## Scientific Rules

Validation is numerical and machine-readable. Figures, PDFs, and console prose can support interpretation, but they are not acceptance criteria.

For each measurement contribution `e`, the active path must keep:

```text
z = h(x_true) + e_truth + v
h_hat = h(x_est) + e_model
r = z - h_hat
R = cov(v + e_unmodelled_random)
```

Deterministic unmodelled biases must remain in the residual unless an explicit stochastic model justifies covariance inflation. Gauge constraints are not physical sensor rows and must stay out of measurement-type residual statistics.
