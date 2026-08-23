# Priority List - Attitude Improvement With Carrier Slip Detection First

Review date: 2026-07-22

Evidence source: `output/AttitudeAblation_3600s_20260722/attitude_ablation_summary.md`

Scope: source-level rewrite after the 3600 s attitude ablation ladder. No MATLAB code changes or new simulation runs are part of this documentation update.

## Overall Finding

The immediate carrier-only attitude blocker is carrier slip detection and DiffAtt arc survival.

The previous review correctly identified inter-antenna carrier phase bias as a critical physical bias, but the broader ladder exposed a second and more immediate failure mode: realistic receiver-clock behaviour can trigger false carrier-slip resets, reduce DiffAtt rows to zero, and prevent ambiguity calibration even when inter-antenna phase bias is disabled.

## Ablation Evidence

| Case | Tail attitude | Diff rows | Meaning |
|---|---:|---:|---|
| `L00_clean_ideal` | `0.0768 deg` | `30` | Clean carrier-only attitude works. |
| `I01_carrier_sigma_1cm` | `0.1133 deg` | `30` | Carrier sigma alone causes only modest degradation. |
| `I02_inter_antenna_bias` | `3.6213 deg` | `0` | Unknown antenna phase bias is still a serious blocker. |
| `R10_realism_no_inter_antenna` | `1.3186 deg` | `0` | Realism fails even without inter-antenna bias. |
| `F14_clock_jow_only` | `5.7659 deg` | `0` | JOW realistic receiver clock alone can starve DiffAtt. |
| `F16_realism_no_inter_slip_off` | `0.1117 deg` | `30` | Disabling slip detection restores DiffAtt rows. |
| `F17_realism_no_inter_slip_1m` | `0.1117 deg` | `30` | Relaxing the threshold confirms over-sensitive slip gating. |

The key diagnostic result is:

```text
R10: 1.3186 deg, Diff rows = 0
F16: 0.1117 deg, Diff rows = 30
F17: 0.1117 deg, Diff rows = 30
```

This means the current full-realism attitude problem must not be explained only as inter-antenna bias plus carrier sigma. The false slip/reset mechanism is separate and must be solved first.

## New Carrier-Only Priority Order

1. Carrier slip detection and DiffAtt arc survival.
2. Inter-antenna carrier phase-bias calibration.
3. Ambiguity-resolution hardening.
4. Antenna geometry, PCV, and tower-survey realism cleanup.
5. Attitude aiding as a separate operational branch.

## Rank 1 - Carrier Slip Detection

Priority: critical and immediate.

Why:
JOW realistic clock alone produced `5.7659 deg` tail attitude error and `Diff rows = 0`. Full realism without inter-antenna phase bias produced `1.3186 deg` and `Diff rows = 0`. Disabling slip detection or relaxing the threshold to `1 m` recovered `0.1117 deg` and `30` DiffAtt rows.

What to do first:

1. Diagnose common-mode residual jumps across carrier tracks.
2. Add receiver-clock/common-mode compensated slip metrics.
3. Add baseline-differenced DiffAtt slip logic.
4. Reset ambiguity states only for confirmed localized slips.
5. Report true slips separately from common-mode clock events.

Do not use `threshold_m = 1.0` as the final solution. It is only evidence that the present metric is over-sensitive.

## Rank 2 - Inter-Antenna Carrier Phase Bias

Priority: critical, after slip-stable arcs exist.

Why:
The isolated inter-antenna bias case produced `3.6213 deg` tail attitude error and `Diff rows = 0`. The truth-side bias injection is plausible as an uncalibrated stress case, but it cannot be accepted as normal operation without estimator-side calibration or clear labelling as uncalibrated phase-bias stress.

What to do first:

1. Make phase-bias metadata enforceable.
2. Prevent uncalibrated realism runs from claiming `syntheticKnownZero` or strong fixed GNSS-only attitude.
3. Add a calibrated receiver-relative phase-bias product.
4. Consider online phase-bias states only after carrier arcs are stable.

State-vector answer:
Possible later states are `(nReceivers - 1) * nSignals` receiver-relative phase-bias states. Do not add them before stable arcs and credible ambiguity status exist.

## Rank 3 - Ambiguity Resolution

Priority: high, but gated by arc survival and phase-bias status.

Why:
The current code already has float ambiguity states, baseline candidate search, cycle-slip tracking, and controlled pseudo-measurement fixing. The missing part is formal reliability, but LAMBDA/ILS cannot rescue a pipeline whose arcs are falsely reset before the 60-epoch DiffAtt calibration gate.

What to do first:

1. Preserve arcs under realistic clock dynamics.
2. Ensure phase-bias assumptions are honest.
3. Reconcile stale readiness text with current controlled raw-fixing support.
4. Add covariance-domain integer least squares and false-fix validation.

State-vector answer:
Do not add more ambiguity-like free states. Keep the pattern: float states, external integer decision, accepted pseudo-measurement constraint.

## Rank 4 - Geometry, PCV, and Tower-Survey Realism

Priority: medium.

Why:
Current geometry support is already mature enough that it is not the observed failure source in the ablation. Also, current PCV and tower-survey toggles mostly cancel because truth and model flags are enabled together in the realism expansion. That does not prove those effects are physically harmless; it means the current ablation did not stress them as unmodelled errors.

What to do first:

1. Keep geometry sweeps as a design study.
2. Separate truth-only from matched-model PCV and tower-survey cases.
3. Include phase-center and lever-arm calibration uncertainty before claiming hardware-level improvement.

State-vector answer:
Do not add lever-arm correction states before slip detection, ambiguity status, and phase-bias handling are stable.

## Rank 5 - Attitude Aiding

Priority for carrier-only science: separate branch.

Priority for operational attitude estimation: high after the carrier-only failure is understood.

Why:
The ablation shows carrier-only attitude can recover to about `0.1117 deg` when slip detection is neutralized and inter-antenna phase bias is disabled. That means external aiding is not needed to explain the present carrier-only failure. Aiding remains valuable for operational attitude estimation, but it changes the scientific claim.

What to do first:

1. Keep carrier-only and aided metrics separate.
2. Use the existing quaternion error-state and gyro-bias path.
3. Add recurring star-tracker-like attitude measurements only in a clearly labelled aided mode.

## Final State-Vector Guidance

Useful or already justified:

- `floatPerTowerReceiverSignal` ambiguity states, already implemented.
- Gyro-bias states in quaternion error-state mode, already implemented.

Possible later:

- Receiver-relative carrier phase-bias states after slip-stable arcs and credible ambiguity status.
- Lever-arm correction states only with external attitude reference and strong priors.
- Star-tracker boresight/misalignment states after basic aided attitude updates work.

Avoid now:

- Receiver phase-bias states before stable carrier arcs.
- Per-tower receiver phase-bias states.
- Unconstrained phase-bias and ambiguity states in the same carrier rows.
- Integer-valued EKF states.
- Using a `1 m` slip threshold as the final detector design.

## Recommended Execution Sequence

1. Implement and validate receiver-clock/common-mode or baseline-differenced carrier slip detection.
2. Re-run the focused slip cases `F14`, `F16`, and `F17`, plus `R10`.
3. Add calibrated receiver-relative carrier phase-bias handling.
4. Harden ambiguity resolution with covariance-domain ILS and false-fix validation.
5. Clean up PCV/tower-survey truth-versus-model realism cases.
6. Add aided attitude estimation as a separate labelled branch if operational performance is the objective.

## Files In This Review

- `docs/attitude_improvement_review/point_4a_carrier_slip_detection.md`
- `docs/attitude_improvement_review/point_3_inter_antenna_carrier_bias.md`
- `docs/attitude_improvement_review/point_4_ambiguity_resolution.md`
- `docs/attitude_improvement_review/point_5_antenna_geometry.md`
- `docs/attitude_improvement_review/point_6_attitude_aiding.md`
- `docs/attitude_improvement_review/priority_list.md`
