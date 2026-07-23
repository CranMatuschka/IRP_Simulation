# Point 3 - Inter-Antenna Carrier Phase Bias

Review date: 2026-07-22

Evidence source: `output/AttitudeAblation_3600s_20260722/attitude_ablation_summary.md`

Scope: source-level rewrite after the 3600 s attitude ablation ladder. This point remains a critical carrier-only attitude blocker, but it is now the second implementation priority because carrier slip detection can starve DiffAtt even when inter-antenna bias is disabled.

## Short Verdict

Inter-antenna carrier phase bias is still a real direct attitude killer.

The updated priority is:

```text
first:  make carrier arcs survive realistic clock dynamics
second: calibrate/model inter-antenna carrier phase bias
third:  consider phase-bias state augmentation
```

Do not add receiver phase-bias states before the slip/reset problem is fixed. If DiffAtt rows are already zero because arcs are being reset, a new bias state cannot recover the missing attitude measurements.

## Ablation Evidence

| Case | Tail attitude | Diff rows | Interpretation |
|---|---:|---:|---|
| `L00_clean_ideal` | `0.0768 deg` | `30` | Clean carrier-only baseline works. |
| `I01_carrier_sigma_1cm` | `0.1133 deg` | `30` | Carrier sigma increase is not the main failure. |
| `I02_inter_antenna_bias` | `3.6213 deg` | `0` | Unknown antenna phase bias alone breaks the DiffAtt fixed solution. |
| `R11_full_realism_current` | `3.8704 deg` | `0` | Full realism includes both slip-reset and phase-bias mechanisms. |

The isolated bias result confirms that the earlier physical concern was correct. A truth-side `0.25 cycle` antenna phase-bias stress is large enough to destroy the current calibrated differential ambiguity solution when no estimator-side calibration is provided.

## What Is Already Implemented

1. Truth-side inter-antenna carrier phase bias injection exists.

   Evidence:
   - `+models/+measurements/CarrierMeasurementBuilder.m` adds the bias into carrier `z_phi`.
   - The bias is keyed by receiver antenna and signal.
   - The reference antenna is kept at zero.
   - The bias is not currently modelled symmetrically in the estimator prediction.

2. The realism configuration can enable this bias.

   Evidence:
   - `config/masterConfig.m` defines `cfg.errors.interAntennaCarrierBias`.
   - `config/realismGradeConfig.m` can enable it as part of realism-grade errors.

3. Receiver carrier-bias estimation is not active.

   Evidence:
   - `+revgnss/ConfigFactory.m` blocks free receiver carrier-bias estimation.
   - The existing comments correctly warn that raw carrier receiver bias is absorbed into float ambiguity unless separately calibrated.

4. DiffAtt has a combined baseline ambiguity/bias calibration path, but not a physical antenna phase-bias product.

   Evidence:
   - `+revgnss/DiffAttitudeBuilder.m` accumulates differential carrier residuals and estimates `delta_B` per baseline/tower.
   - This can remove a combined offset in controlled synthetic conditions.
   - It does not independently estimate receiver-relative antenna phase bias.

5. Phase-bias status can be scientifically misleading.

   Evidence:
   - `cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus` defaults to `syntheticKnownZero`.
   - Realism can inject unknown inter-antenna phase bias without changing that status.
   - A realism run with truth-side unknown phase bias should not be labelled as zero-bias operational fixing.

## Scientific Evaluation

For a carrier single difference between antenna `a` and the reference antenna:

```text
dphi_t,a,f = drho_t,a(q) + lambda_f * dN_t,a,f + db_a,f - db_ref,f + noise
```

The inseparable part is:

```text
lambda_f * dN_t,a,f + db_a,f - db_ref,f
```

If ambiguity is fully float, receiver-relative phase bias and integer ambiguity can trade against each other. If attitude is also weakly constrained, some of that offset can project into attitude. Therefore phase-bias states are only scientifically meaningful when there are additional constraints:

- stable carrier arcs,
- fixed or tightly constrained ambiguities,
- known attitude over a calibration arc,
- external receiver/antenna calibration,
- strong priors on the phase-bias states.

The magnitude is not small. At L1, one wavelength is about `0.190 m`. A `0.25 cycle` bias is about `47.5 mm`. On a `2 m` baseline:

```text
47.5 mm / 2 m = 0.0238 rad = 1.36 deg
```

On a `1.4 m` baseline it is about `1.9 deg`. Random carrier noise can average down; a constant antenna phase bias does not.

## Implementation Recommendation

Implement phase-bias handling, but only after carrier slip detection is stabilized.

Recommended sequence:

1. Fix carrier slip detection and DiffAtt arc survival.

   This is a prerequisite because the phase-bias calibration arc needs stable carrier rows.

2. Make phase-bias status enforceable.

   If truth-side inter-antenna bias is enabled and there is no estimator-side calibration, the run must be labelled as uncalibrated phase-bias stress. It must not claim `syntheticKnownZero` or strong GNSS-only fixed attitude.

3. Add a calibrated receiver-relative phase-bias product.

   Store:

   ```text
   b_phase(rx, signal), with b_phase(reference_rx, signal) = 0
   ```

   Include source, covariance, signal applicability, validity interval, and whether the product may support integer fixing.

4. Apply the calibrated bias in the estimator-side carrier model.

   The measurement model should subtract or predict the same physical bias that was injected in truth when the calibration is known.

5. Add online phase-bias states only if calibration products are insufficient.

   The state vector extension should be receiver-relative, not tower-relative:

   ```text
   x_bias = [db_rx2_L1, db_rx3_L1, ..., db_rxN_L1,
             db_rx2_L2, db_rx3_L2, ..., db_rxN_L2]
   ```

## What Should Not Be Done

Do not add per-tower receiver phase-bias states. They duplicate ambiguity states.

Do not add unconstrained phase-bias states while ambiguity states remain fully float.

Do not combine phase-bias states, lever-arm correction states, and ambiguity states in one first pass. That would create a strongly coupled estimation problem without enough independent information.

Do not claim the full-realism attitude failure is only phase bias. The ladder shows a separate carrier slip/reset failure when inter-antenna bias is disabled.

## Validation Gates Before Calling It Done

1. Slip-stable no-bias realism must produce active DiffAtt rows before phase-bias calibration is evaluated.
2. `I02_inter_antenna_bias` must remain a failing uncalibrated stress case until calibration is enabled.
3. With a known calibration product, the same bias-injected case must recover attitude accuracy without false GNSS-only claims.
4. Phase-bias states, if added, must pass an observability/rank check showing they are not just duplicating ambiguity states.
5. Reports must clearly distinguish synthetic zero-bias, externally calibrated, batch-calibrated, and uncalibrated phase-bias modes.

## Think, Plan, Evaluate, Next Step

Think:
The phase-bias physics is real, but it cannot be calibrated from arcs that do not survive the slip detector.

Plan:
Fix arc survival first, then add calibrated receiver-relative phase-bias handling, then consider constrained states.

Evaluate:
The ablation isolates phase bias as a major blocker, but also proves it is not the only blocker.

Next step:
Use the carrier-slip rewrite as the first code work package, then build the phase-bias calibration package on top of stable DiffAtt rows.
