# Required Fixes Execution Plan - Scientific Correctness Closure

Date: 2026-07-22
Repository: `oo_v1`
Role framing: reverse-GNSS, Kalman filtering, GNSS error modelling, MATLAB scenario engineering

## Objective

Close the scientific-correctness findings from `docs/scientific_correctness_audit_20260721.md` with a fully automatic, commit-by-commit repair path. Each fix must be:

- scientifically justified by the measurement equation and covariance model;
- implemented in the active simulation path, not only in reports or comments;
- covered by deterministic MATLAB tests;
- validated by saved numerical evidence;
- committed only after its automatic gate passes.

No acceptance step may rely on manual inspection of figures, PDFs, or console output. PDF/report checks are allowed only as additional rendered artifacts; the pass/fail decision must come from MATLAB assertions and generated machine-readable summaries.

## Global Scientific Contract

The reverse-GNSS measurement model must keep these layers separate:

1. Truth generation:
   - What the simulated physical receiver observes.
   - Includes truth atmosphere, hardware, DCB, clock, multipath, thermal, and enabled link effects.

2. Estimator prediction:
   - What the EKF believes after applying configured model corrections.
   - Must not include truth-only effects unless explicitly configured as modelled.

3. Measurement covariance:
   - Random uncertainty used by the EKF.
   - Must represent stochastic uncertainty, not hide deterministic model defects.

4. Diagnostics/reporting:
   - Must describe the active model honestly.
   - Must not claim an error source is active when no active measurement row contains it.

For every error contribution `e`, the implementation must satisfy:

```text
z = h(x_true) + e_truth + v
h_hat = h(x_est) + e_model
r = z - h_hat
R = cov(v + e_unmodelled_random)
```

Deterministic unmodelled biases are allowed to remain in `r`, but must not be silently converted into white noise unless a justified stochastic model is explicitly configured.

## Automatic Execution Contract

The repair sequence is executed as one branch with small commits. Before each commit:

1. Apply only the files listed for that commit unless the implementation reveals an unavoidable dependency.
2. Run the commit gate command.
3. Save any generated validation output under `output/RequiredFixValidation_20260722/`.
4. Commit only if the gate exits with status 0.

Recommended branch:

```bash
git switch -c codex/scientific-correctness-closure
```

The MATLAB executable used for all gates:

```bash
/Applications/MATLAB_R2025b.app/bin/matlab
```

## Commit 1 - Add Automatic Scientific Fix Harness

Commit message:

```text
test: add automatic scientific fix validation harness
```

### Purpose

Create one noninteractive validation entry point that all later commits can call. This commit should not change physics. It establishes evidence collection and prevents later fixes from being judged by ad hoc output reading.

### Files

- Add `tests/run_required_fixes_validation.m`
- Add `tests/helpers/requiredFixValidationCase.m` if helper separation is cleaner
- Add `tests/helpers/assertRequiredFixMetric.m` if repeated metric checks become verbose
- Add `docs/required_fixes_validation_contract.md`

### Implementation Details

The harness must support at least:

```matlab
run_required_fixes_validation('Mode','unit')
run_required_fixes_validation('Mode','quick')
run_required_fixes_validation('Mode','release')
```

Required modes:

- `unit`: only focused tests for active code paths, no long simulations.
- `quick`: short deterministic integration runs, no PDF generation.
- `release`: full validation suite and battery runs, PDF allowed.

Required outputs:

- `output/RequiredFixValidation_20260722/metrics.csv`
- `output/RequiredFixValidation_20260722/metrics.mat`
- `output/RequiredFixValidation_20260722/summary.md`

Required metric fields:

- scenario id
- duration
- number of towers
- number of assets
- physical tower count reported by datastore
- active measurement types
- code row count by signal
- two-way time-transfer row count
- postfit residual count by type
- mean NIS by type
- NEES if truth covariance comparison is available
- position RMS
- clock RMS
- relative-shape raw RMS
- relative-shape solved RMS
- swarm gate flags
- DCB active flag
- higher-order ionosphere active flag

### Gate

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run_required_fixes_validation('Mode','unit');"
```

### Acceptance

- Harness runs noninteractively.
- Existing known failures are recorded as `xfail` only when tied to an open fix commit below.
- No physical model is modified in this commit.

## Commit 2 - Propagate Higher-Order Ionosphere Through All Code Rows

Commit message:

```text
fix: propagate higher-order ionosphere through code measurement rows
```

### Finding

`ErrorChain` generates higher-order ionosphere terms (`ionoHO`) and their sigma contribution, but the active multi-signal code measurement expansion in `CodeMeasurementBuilder` does not consistently carry `ionoHO` into reconstructed L2/raw rows and ionosphere-free combinations. This can create an inconsistent state where:

```text
z/h omit ionoHO for some rows, while R or diagnostics still account for it.
```

That is scientifically invalid because the residual and covariance no longer describe the same measurement.

### Scientific Model

For code group delay:

```text
P_f = rho + c(dt_rx - dt_tx) + T + I1_f + IHO_f + b_code_f + epsilon
```

with first-order ionosphere approximately:

```text
I1_f = 40.3 * STEC / f^2
```

and higher-order terms frequency-dependent, generally scaling with stronger powers of `1/f` and geomagnetic/electron-density terms. The ionosphere-free code combination must use the same coefficients already used by the code builder:

```text
P_IF = a * P_L1 + b * P_L2
```

where `a` and `b` are the implementation's signed IF coefficients. Therefore:

```text
IHO_IF = a * IHO_L1 + b * IHO_L2
```

The sign and coefficient convention must come from the existing IF helper, not a second local formula.

### Files

- `+models/+measurements/CodeMeasurementBuilder.m`
- `+models/+errors/ErrorChain.m` only if a missing public helper is required
- `+data/SimulationDataStore.m` if contribution storage omits `ionoHO`
- `tests/test_iono_higher_order.m`
- Add `tests/test_code_iono_higher_order_multisignal.m`
- Possibly update `tests/test_stage43_ionosphere_free_combination_diagnostics.m`
- Possibly update `tests/test_stage46_code_if_consistency_traceability.m`

### Implementation Details

1. Extend the multi-signal contribution field list in `CodeMeasurementBuilder` to include:

```matlab
'ionoHO'
```

for truth, model, sigma, and per-source diagnostic structures.

2. Ensure reconstructed L2 rows receive a physically frequency-scaled higher-order ionosphere term, not a copied L1 value unless the configured model explicitly says it is signal-invariant.

3. Ensure the IF combination uses:

```matlab
truth_ionoHO_IF = a * truth_ionoHO_L1 + b * truth_ionoHO_L2;
model_ionoHO_IF = a * model_ionoHO_L1 + b * model_ionoHO_L2;
```

using the existing signed coefficient convention.

4. Ensure `sigma_ionoHO_IF` is formed from the actual covariance assumption:

- if `IHO_L1` and `IHO_L2` are treated as fully correlated model uncertainty derived from the same STEC and geomagnetic source:

```text
sigma_IF = abs(a * sigma_L1_signed + b * sigma_L2_signed)
```

or equivalent signed-source propagation;

- if treated as independent white residuals, use quadratic propagation:

```text
sigma_IF^2 = a^2 sigma_L1^2 + b^2 sigma_L2^2
```

The implementation must document which assumption is used. The recommended assumption is correlated source propagation because higher-order residuals are deterministic functions of the same ray path and environment state, not independent receiver noise.

5. Ensure no double counting:

```text
truthTotal = sum(truth source terms)
modelTotal = sum(model source terms)
sigmaExtra^2 = sum(random/unmodelled sigma terms^2)
```

`ionoHO` must appear once in each applicable sum.

6. Add a diagnostic assertion that if `sigma_m.ionoHO` contributes to `R`, then the corresponding row also has a nonzero or explicitly modelled `truth/model` path for `ionoHO`.

### Gate

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run('tests/test_iono_higher_order.m'); run('tests/test_code_iono_higher_order_multisignal.m'); run('tests/test_stage43_ionosphere_free_combination_diagnostics.m'); run('tests/test_stage46_code_if_consistency_traceability.m'); run_required_fixes_validation('Mode','unit','Focus','ionoHO');"
```

### Acceptance

- L1, L2, and IF code rows expose `ionoHO` truth/model/sigma diagnostics.
- IF higher-order residual equals the coefficient combination of raw-signal terms.
- `R` contains higher-order ionosphere uncertainty only when the same active row carries the corresponding source.
- Existing first-order ionosphere-free cancellation tests remain valid.

## Commit 3 - Gate Swarm Shape Estimation on Enabled Two-Way ISL

Commit message:

```text
fix: gate swarm relative shape solution on enabled two-way isl
```

### Finding

`SwarmRelativeSolver.solve` currently synthesizes truth-sampled two-way ISL ranges whenever multiple assets exist. The relative clock term is gated separately, but the relative-shape solution is not gated by `cfg.multiAsset.twoWayISL.enable`. This can make reports look as if the swarm has an active ISL ranging layer even when the scenario configuration disabled it.

### Scientific Model

Relative swarm shape estimation can be reported as an estimator output only when an observation model exists:

```text
z_ij = ||r_j - r_i|| + c(dt_j - dt_i) + b_ij + epsilon_ij
```

For two-way symmetric ISL ranging with clock cancellation:

```text
z_ij,TW ~= ||r_j - r_i|| + b_TW + epsilon_TW
```

If the link is disabled, truth positions may still be used to compute diagnostic truth separation, but they must not be presented as an estimated measurement solution.

### Files

- `+revgnss/SwarmRelativeSolver.m`
- `+revgnss/ReportRunner.m`
- `+revgnss/FederatedSwarmReport.m`
- `+revgnss/FederatedSwarmSummary.m`
- `+revgnss/+report/federatedSwarmAppendix.m`
- `tests/test_swarm_formation.m`
- `tests/test_isl_swarm.m`
- `tests/regression/run_swarm_relative_regression.m`
- Add `tests/test_swarm_two_way_isl_gating.m`

### Implementation Details

1. At the start of `SwarmRelativeSolver.solve`, compute:

```matlab
shapeGateOn = isfield(cfg.multiAsset,'twoWayISL') && cfg.multiAsset.twoWayISL.enable;
clockGateOn = isfield(cfg.multiAsset,'twoWayTimeTransferISL') && cfg.multiAsset.twoWayTimeTransferISL.enable;
```

2. If `shapeGateOn` is false:

- return raw relative truth/estimate diagnostic geometry if already available;
- do not generate synthetic noisy pair ranges;
- set solved-shape metrics to `NaN` or empty with explicit flags;
- set `rel.shapeGateOn = false`;
- set `rel.shapeObservationSource = 'disabled'`.

3. If `shapeGateOn` is true:

- generate the simulated two-way ISL observation from truth plus configured noise;
- set `rel.shapeGateOn = true`;
- set `rel.shapeObservationSource = 'syntheticTwoWayISL'`;
- preserve the existing deterministic random stream behaviour.

4. Reports must state "two-way ISL shape layer disabled" when disabled, and must not show solved-shape accuracy as if it were an active estimator.

5. Keep relative clock transfer separately controlled by the existing two-way-time-transfer-ISL gate.

### Gate

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run('tests/test_swarm_two_way_isl_gating.m'); run('tests/test_swarm_formation.m'); run('tests/test_isl_swarm.m'); run('tests/regression/run_swarm_relative_regression.m'); run_required_fixes_validation('Mode','unit','Focus','swarm');"
```

### Acceptance

- With `cfg.multiAsset.twoWayISL.enable=false`, no solved-shape observation is generated.
- With `cfg.multiAsset.twoWayISL.enable=true`, the existing relative-shape regression remains numerically stable.
- Reports and saved `.mat` files expose the gate flag.
- No report table can confuse disabled truth diagnostics with estimated ISL performance.

## Commit 4 - Add Two-Way Time Transfer Postfit Residuals

Commit message:

```text
fix: include two-way time transfer rows in postfit residual diagnostics
```

### Finding

`ReverseGNSSSimulation` appends two-way time-transfer rows into the EKF update, but `computePostfitResiduals_` reconstructs only pseudorange, Doppler, and carrier rows. As a result, TWTT affects the filter but disappears from postfit residual accounting.

### Scientific Model

The active TWTT row is a clock-difference observation:

```text
z_TW,i = c * (dt_rx - dt_tower_i) + epsilon_TW,i
```

or in clock-bias metres:

```text
z_TW,i = b_rx - b_tower_i + epsilon_TW,i
```

The Jacobian contains:

```text
d z / d b_rx = +1
d z / d b_tower_i = -1
d z / d position = 0
```

Postfit residuals must be:

```text
r_post,TW = z_TW - h_TW(x_post)
```

using the same row metadata and sign convention as the EKF update.

### Files

- `+revgnss/ReverseGNSSSimulation.m`
- `+revgnss/TwoWayTimeTransferBuilder.m`
- `tests/test_wpA_two_way_time_transfer.m`
- `tests/test_postfit_by_meas_type.m`
- `tests/test_stage57_ekf_innovation_accounting.m`
- Add `tests/test_two_way_time_transfer_postfit.m`

### Implementation Details

1. Add a prediction-only method to `TwoWayTimeTransferBuilder`, for example:

```matlab
[hTw, rowMeta] = revgnss.TwoWayTimeTransferBuilder.predictRows(xPost, cfg, stateLayout, errStruct.twoWayTimeTransfer)
```

or refactor the existing `build` method to support a no-noise, prediction-only mode.

2. The postfit path must use the stored TWTT measurement values generated before the EKF update. It must not draw new noise.

3. Add postfit row labels:

```matlab
type = "twoWayTimeTransfer"
signal = "TW"
towerId
assetId
```

4. Update NIS/dof accounting so TWTT innovation rows are counted separately from pseudorange rows.

5. Ensure the gauge/clock constraint rows remain separate from physical TWTT rows. Artificial gauge constraints must not be reported as sensor residuals.

### Gate

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run('tests/test_wpA_two_way_time_transfer.m'); run('tests/test_two_way_time_transfer_postfit.m'); run('tests/test_postfit_by_meas_type.m'); run('tests/test_stage57_ekf_innovation_accounting.m'); run_required_fixes_validation('Mode','unit','Focus','twtt');"
```

### Acceptance

- With TWTT off, postfit residual counts are unchanged.
- With TWTT on, postfit residuals include one physical TWTT row per active/capable tower per epoch.
- TWTT rows have zero position partials and correct clock/tower-clock signs.
- Gauge rows are excluded from physical measurement residual statistics.

## Commit 5 - Preserve Physical Tower Count in SimulationDataStore

Commit message:

```text
fix: keep datastore physical tower count separate from expanded rows
```

### Finding

`SimulationDataStore` stores physical `nTowers` at construction, but later tower-clock storage can overwrite that count with an expanded row count caused by multi-asset/multi-signal measurement tiling. This contaminates metadata and can mislead report dimensions.

### Scientific Model

The number of physical ground towers is a scenario property:

```text
N_tower = number of transmitting ground stations
```

It is not equal to:

```text
N_rows = N_tower * N_assets * N_signals * N_measurement_types
```

Clock states are per physical tower unless the model explicitly defines separate clocks per signal or asset. Measurement-row expansion must not change the physical tower state dimension.

### Files

- `+data/SimulationDataStore.m`
- `+revgnss/ReportRunner.m` only if report metadata assumes expanded tower clocks
- `tests/test_simulation_data_store_array_backend.m`
- `tests/test_simdata_freeze.m`
- Add `tests/test_datastore_physical_tower_count.m`

### Implementation Details

1. Treat constructor `nTowers` as immutable physical metadata:

```matlab
obj.nTowersPhysical_ = nTowers;
```

or keep `obj.nTowers_` immutable and add a separate expanded-row field.

2. If a tower-clock vector arrives in expanded measurement-row shape:

- map rows back to physical tower ids using metadata when available;
- otherwise require exact divisibility and collapse by tower order only with an assertion;
- never overwrite the physical tower count.

3. Store any expanded row count in a separate diagnostic field:

```matlab
nTowerClockRowsStored
```

4. Ensure compact output and reports use physical tower count for scenario summaries.

5. Add `ionoHO` to contribution storage here if Commit 2 reveals the datastore drops it.

### Gate

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run('tests/test_datastore_physical_tower_count.m'); run('tests/test_simulation_data_store_array_backend.m'); run('tests/test_simdata_freeze.m'); run_required_fixes_validation('Mode','unit','Focus','datastore');"
```

### Acceptance

- A `G5S3R4` case reports 5 physical towers, not an expanded measurement row count.
- Tower-clock arrays remain dimensionally compatible with downstream reports.
- Multi-signal and multi-asset row expansion is visible only in row-count diagnostics.

## Commit 6 - Activate Per-Signal Code DCB in the Measurement Path

Commit message:

```text
fix: apply configured code dcb biases to active signal rows
```

### Finding

Realism-grade configuration sets inter-frequency code DCB values, but `CodeMeasurementBuilder` comments indicate the active raw dual-frequency path does not inject DCB. This makes the realism-grade label too strong and leaves a configured error inactive.

### Scientific Model

For reverse GNSS, the ground transmitter and space receiver can both contribute signal-dependent code group delay biases. The active global model in this codebase is:

```text
P_f = rho + c(dt_rx - dt_tx) + ... + DCB_f + epsilon_f
```

where `f` is L1 or L2. In this repair, use the existing configuration scope:

```matlab
cfg.biases.interFrequency.code.truth.L1_m
cfg.biases.interFrequency.code.truth.L2_m
cfg.biases.interFrequency.code.model.L1_m
cfg.biases.interFrequency.code.model.L2_m
```

The IF contribution must be:

```text
DCB_IF = a * DCB_L1 + b * DCB_L2
```

using the same signed IF coefficients as the measurement builder.

### Files

- `config/masterConfig.m`
- `config/realismGradeConfig.m`
- `+models/+measurements/CodeMeasurementBuilder.m`
- `+revgnss/ReportRunner.m`
- `tests/test_documented_limitations.m`
- `tests/test_stage64_scientific_closure.m`
- `tests/test_wpEF_imperfection_honesty.m`
- Add `tests/test_code_dcb_active_path.m`

### Implementation Details

1. Add `dcb` to the code measurement contribution structure:

```matlab
truth_m.dcb
model_m.dcb
sigma_m.dcb
```

2. Apply truth DCB to raw L1 and L2 simulated code rows.

3. Apply model DCB to predicted corrections only when configured as modelled.

4. For the initial fix, keep `sigma_m.dcb = 0` unless a stochastic DCB uncertainty is explicitly configured. A deterministic DCB mismatch should remain observable as residual bias.

5. Ensure DCB is code-only. Do not inject it into carrier phase unless a separate phase hardware-bias model is explicitly introduced.

6. Ensure DCB is not double-counted with existing `hardwareDelay`:

```text
hardwareDelay = non-dispersive or already existing configured delay
DCB = signal-dependent differential code bias
```

7. Update report wording:

- "DCB active" only when active rows contain nonzero DCB contribution.
- "DCB configured but inactive" must become impossible for realism-grade runs unless explicitly disabled.

8. Preserve a documented limitation that the first implementation is global per signal, not per tower/receiver, unless this commit also implements per-tower DCB arrays.

### Gate

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run('tests/test_code_dcb_active_path.m'); run('tests/test_documented_limitations.m'); run('tests/test_stage64_scientific_closure.m'); run('tests/test_wpEF_imperfection_honesty.m'); run_required_fixes_validation('Mode','unit','Focus','dcb');"
```

### Acceptance

- Zero DCB configuration produces bitwise or tolerance-equivalent baseline code rows.
- Nonzero L1/L2 DCB values produce exactly the expected raw-row biases.
- IF DCB equals the signed coefficient combination of raw DCB values.
- Realism-grade reports no longer claim inactive DCB as active physics.

## Commit 7 - Correct Battery Labels and TW Naming Logic

Commit message:

```text
fix: make battery labels and tw tags reflect active configuration
```

### Finding

`run_oo_v1_battery` labels `Realism=false` runs as `Battery_idealised`, but the default atmosphere remains realistic unless `Atmosphere='matched'` is passed. Also, `run_oo_v1.m` uses `cfg.measurements.twstft.enable` for the `TW` output tag while the active EKF two-way transfer switch is `cfg.measurements.twoWayTimeTransfer.enable`.

### Scientific Model

Scenario labels are part of the scientific record. A run with realistic atmosphere but non-realism-grade configuration is not idealised. Use labels that encode active physics, not user intent.

Recommended label mapping:

```text
Realism=false, Atmosphere='realistic' -> Battery_baseline
Realism=false, Atmosphere='matched'   -> Battery_idealised
Realism=true                          -> Battery_realism
```

TW tag:

```text
TW1 means twoWayTimeTransfer.enable == true and useInEKF == true
TW0 means active EKF TWTT is off
```

TWSTFT diagnostics, if separate, should receive a separate diagnostic tag.

### Files

- `run_oo_v1_battery.m`
- `run_oo_v1.m`
- `+revgnss/ReportRunner.m` if report titles embed the old label
- Add `tests/test_battery_label_semantics.m`
- Add `tests/test_run_name_tw_semantics.m`

### Implementation Details

1. Rename future output folders according to active physics.

2. Preserve backward readability for existing output folders by not moving old results automatically.

3. Add a manifest field to every battery run:

```matlab
manifest.runClass = 'baseline' | 'idealised' | 'realism'
manifest.atmosphereMode = ...
manifest.twoWayTimeTransferInEkf = ...
manifest.twstftDiagnosticsEnabled = ...
```

4. Fix `run_oo_v1.m` `TW` tag to read the active two-way time-transfer EKF switch.

5. Update reports to print both folder label and active physics flags.

### Gate

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run('tests/test_battery_label_semantics.m'); run('tests/test_run_name_tw_semantics.m'); run_required_fixes_validation('Mode','unit','Focus','labels');"
```

### Acceptance

- No future default-atmosphere run is called idealised.
- `TW1` cannot be produced when active EKF TWTT is disabled.
- Existing `Battery_idealised` results remain readable as historical outputs.

## Commit 8 - Add Full Validation Ladder and Scientific Pass/Fail Criteria

Commit message:

```text
test: add scientific validation ladder for corrected scenarios
```

### Purpose

Turn the fix-specific tests into a scenario-level validation ladder that exercises the corrected scientific paths together.

### Files

- `tests/run_required_fixes_validation.m`
- `tests/run_oo_scientific_validation_suite.m`
- `tests/test_filter_consistency_nees_nis.m`
- `tests/test_mc_consistency_harness.m`
- `tests/run_ekf_convergence_triage.m`
- `tests/regression/run_swarm_relative_regression.m`
- Add `docs/scientific_validation_ladder_20260722.md`

### Required Scenarios

The quick ladder should use short durations, for example 600 s to 1200 s, and deterministic seeds:

1. Single asset, 5 towers, L1 only, matched atmosphere, TW off.
2. Single asset, 5 towers, L1/L2/IF active, higher-order ionosphere on, TW off.
3. Single asset, 5 towers, realism-grade DCB active, TW off.
4. Single asset, 5 towers, realism-grade DCB active, TW on.
5. Multi-asset `G5S3R4`, two-way ISL disabled.
6. Multi-asset `G5S3R4`, two-way ISL enabled.
7. Multi-asset `G5S3R4`, two-way ISL enabled and TWTT enabled.

The release ladder should include the user's battery matrix:

```matlab
SR = {[1 1],[1 4],[3 4],[6 4]};
TW = [0 1];
Duration = 7200;
Towers = 5;
Realism = false;
Realism = true;
```

and should run both the corrected baseline/idealised naming path and `Battery_realism`.

### Required Metrics

For each scenario, compute and save:

- position RMS and percentile errors by asset;
- receiver clock RMS by asset;
- tower clock RMS if truth is available;
- NIS by measurement type;
- NEES for state groups where covariance and truth alignment are valid;
- prefit and postfit residual RMS by measurement type;
- TWTT row count and postfit RMS;
- raw vs solved swarm relative-shape metrics;
- DCB residual signature;
- higher-order ionosphere residual signature;
- physical tower count and expanded row count.

### Scientific Pass/Fail Rules

The harness must fail if:

- `ionoHO` is charged in `R` but absent from the active row contribution;
- IF higher-order or IF DCB contribution does not equal the signed combination of raw signal contributions;
- `twoWayISL.enable=false` and solved-shape metrics are reported as active estimates;
- `twoWayTimeTransfer.enable=true` but no TWTT postfit rows are present;
- datastore physical tower count differs from configured tower count;
- DCB configured active but all active DCB row contributions are zero;
- NIS/dof accounting includes artificial gauge rows as physical sensor rows;
- existing selected validation gate `tests/test_stage24_twstft_diagnostics.m` fails.

NIS/NEES thresholds should be scientifically justified and scenario-specific. They may be broad for short deterministic smoke runs, but must not be relaxed to mask deterministic biases introduced by the fixes.

### Gate

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run_required_fixes_validation('Mode','quick'); run('tests/test_filter_consistency_nees_nis.m'); run('tests/test_mc_consistency_harness.m'); run('tests/test_stage24_twstft_diagnostics.m');"
```

### Acceptance

- `metrics.csv`, `metrics.mat`, and `summary.md` are generated.
- Every required scenario has a pass/fail row.
- Failures include enough file paths and scenario ids to reproduce them.
- The TWSTFT diagnostic guard passes before the plan is considered closed.

## Commit 9 - Remove Stale ISL Stubs and Update Scientific Documentation

Commit message:

```text
docs: align isl documentation with active swarm implementation
```

### Finding

Some legacy comments or helper stubs state that ISL is not implemented, while active ISL-related components exist elsewhere. Stale comments are dangerous in a scientific simulation because they hide which model is active.

### Files

- `+models/+measurements/MeasurementModelUtils.m`
- `+models/+measurements/ISLMeasurementBuilder.m`
- `+models/+measurements/TwoWayISLMeasurementBuilder.m`
- `+revgnss/SwarmRelativeSolver.m`
- `docs/scientific_correctness_audit_20260721.md`
- Add or update `docs/swarm_isl_model_notes.md`
- Add `tests/test_isl_documentation_consistency.m`

### Implementation Details

1. Replace stale "ISL not implemented" statements with precise routing:

```text
Legacy helper does not build the active ISL measurement. Use ISLMeasurementBuilder, TwoWayISLMeasurementBuilder, or SwarmRelativeSolver depending on scenario layer.
```

2. If a legacy function remains unsupported, make it fail clearly with a migration message rather than silently returning empty physical rows.

3. Document the distinction between:

- raw inter-satellite link measurements;
- two-way ISL ranging;
- synthetic truth-sampled swarm-shape observation used for simulation when enabled;
- relative clock transfer over ISL.

4. Update the audit document status table from "required fix" to "fixed by commit ..." only after implementation and tests pass.

### Gate

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run('tests/test_isl_documentation_consistency.m'); run('tests/test_isl_swarm.m'); run_required_fixes_validation('Mode','unit','Focus','islDocs');"
```

### Acceptance

- No active-path comment says ISL is unimplemented without qualification.
- Documentation names the active builder/solver for each ISL layer.
- Tests fail if stale wording returns in active files.

## Commit 10 - Release Battery Re-Run and Runtime Analysis

Commit message:

```text
test: record corrected battery validation and runtime analysis
```

### Purpose

Run the corrected battery after all scientific fixes and compare:

- previous baseline/default folder previously named `Battery_idealised`;
- corrected baseline/idealised labelling;
- realism-grade folder;
- TW0 versus TW1 runtime for the same `G5S3R4` scenario.

### Files

- `run_oo_v1_battery.m`
- `docs/battery_runtime_analysis_20260722.md`
- `output/RequiredFixValidation_20260722/*`

### Required Runs

Quick release gate without PDFs:

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run_required_fixes_validation('Mode','release','WritePdf',false);"
```

Full user-equivalent battery with PDFs:

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run_oo_v1_battery('Duration',7200,'Towers',5,'SR',{[1 1],[1 4],[3 4],[6 4]},'TW',[0 1],'Realism',false,'WritePdf',true,'Analyze',true); run_oo_v1_battery('Duration',7200,'Towers',5,'SR',{[1 1],[1 4],[3 4],[6 4]},'TW',[0 1],'Realism',true,'WritePdf',true,'Analyze',true);"
```

Runtime-order diagnostic for the observed `G5S3R4` TW0/TW1 asymmetry:

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run_required_fixes_validation('Mode','runtimeOrder','Scenario','G5S3R4','Duration',7200,'WritePdf',false);"
```

The runtime-order diagnostic must run both orders:

```text
TW0 -> TW1
TW1 -> TW0
```

and record:

- simulation runtime excluding PDF generation;
- report/PDF runtime if enabled;
- epoch count;
- measurement row count by type;
- EKF update dimension by epoch;
- number of accepted/rejected updates;
- number of warnings or fallback branches;
- MATLAB warm cache/JIT order.

### Scientific Runtime Interpretation

TW1 should not be assumed physically faster because it has more measurement rows. A shorter observed runtime can be caused by:

- MATLAB JIT warm-up and class loading during the earlier run;
- operating-system file cache and OneDrive sync timing;
- PDF/report generation variance;
- different convergence behaviour affecting internal diagnostics;
- skipped report sections due to missing or shorter data products;
- accidental row-count differences caused by configuration naming or gating bugs.

The corrected analysis must separate these causes using measured row counts and report timing.

### Gate

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run_required_fixes_validation('Mode','release','WritePdf',false); run_required_fixes_validation('Mode','runtimeOrder','Scenario','G5S3R4','Duration',7200,'WritePdf',false);"
```

### Acceptance

- Both baseline/default and realism batteries complete.
- `Battery_realism` is analysed, not only the former `Battery_idealised` folder.
- Runtime-order output explains whether TW1 is actually cheaper or only benefited from order/cache/report effects.
- Every battery `.mat` file has matching metric rows.

## Final Integration Gate

Run after Commit 10 and before declaring the closure complete:

```bash
/Applications/MATLAB_R2025b.app/bin/matlab -batch "addpath(genpath(pwd)); run_required_fixes_validation('Mode','release','WritePdf',true);"
```

The final gate passes only if:

- all commit-specific tests pass;
- all quick and release validation metrics are generated;
- previous required findings are either fixed or explicitly downgraded with scientific justification;
- `docs/scientific_correctness_audit_20260721.md` links each finding to the commit that fixed it;
- `docs/battery_runtime_analysis_20260722.md` includes both non-realism/default and realism folders;
- the `G5S3R4` TW0/TW1 runtime comparison is based on reversed-order evidence.

## Proposed Commit Order Summary

| Commit | Scope | Main Risk Removed | Primary Gate |
| --- | --- | --- | --- |
| 1 | Validation harness | ad hoc/manual acceptance | `run_required_fixes_validation('Mode','unit')` |
| 2 | Higher-order ionosphere | inconsistent z/h/R for L2/IF code | ionoHO unit and IF tests |
| 3 | Swarm ISL gate | truth-sampled shape reported when disabled | swarm gating tests |
| 4 | TWTT postfit | active EKF rows missing from residual diagnostics | TWTT postfit tests |
| 5 | Datastore tower count | physical tower count overwritten by row expansion | datastore dimension tests |
| 6 | Code DCB active path | realism-grade DCB configured but inert | DCB raw/IF tests |
| 7 | Battery labels/TW names | misleading scientific run labels | label and TW semantic tests |
| 8 | Validation ladder | no cross-feature scientific gate | quick validation ladder |
| 9 | ISL docs/stubs | stale implementation map | ISL documentation tests |
| 10 | Battery rerun/runtime | incomplete result analysis | release and runtime-order gates |

## Implementation Notes for Scientific Correctness

### Kalman Filter Consistency

For every new or modified measurement row:

- the dimension of `z`, `h`, `H`, and `R` must agree;
- `R` must remain symmetric positive definite or positive semidefinite with justified regularisation;
- Joseph-form covariance update must remain active;
- artificial gauge constraints must stay separate from physical measurement residuals;
- NIS must use only physical innovation rows for the corresponding measurement type;
- NEES must be computed only where truth-state alignment is valid.

### GNSS Signal Modelling

Use the existing signal-frequency definitions and IF coefficient helper. Do not duplicate L1/L2 constants locally. Any new DCB or higher-order ionosphere implementation must be signal-indexed and must survive:

```text
raw L1
raw L2
ionosphere-free code
multi-asset row expansion
report contribution storage
```

### Swarm Modelling

Keep three concepts distinct:

1. Relative truth geometry:
   - diagnostic only;
   - always computable from truth when truth is available.

2. Raw relative estimate from independent asset EKFs:
   - diagnostic performance of independent navigation.

3. Solved relative shape from ISL observations:
   - estimator output;
   - valid only when an ISL observation layer is enabled.

### Battery Interpretation

The old `Battery_idealised` folder should be treated as a historical non-realism/default run unless its manifest proves matched atmosphere and disabled systematics. Future analysis must always include both:

- non-realism/default or idealised runs, depending on active flags;
- `Battery_realism` runs.

Runtime comparisons must be made after controlling for order and PDF/report generation. The observed 2026-07-22 `G5S3R4` times:

```text
TW0: 2321 s
TW1: 1586 s
```

are not sufficient by themselves to prove TW1 is cheaper. The plan's runtime-order gate is required before drawing that conclusion.

## Definition of Done

The repair effort is complete only when:

1. All ten commits exist in order or the final branch history contains equivalent separated changes.
2. Every commit gate passed at the time of commit.
3. The final integration gate passed with `WritePdf=true`.
4. The generated validation summary contains both non-realism/default and realism result families.
5. The runtime analysis explains `G5S3R4` TW0/TW1 using measured row counts and reversed-order runs.
6. The final scientific audit document marks each finding as fixed, intentionally deferred, or scientifically reclassified, with evidence paths.
