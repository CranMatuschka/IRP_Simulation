# Point 4a - Carrier Slip Detection and DiffAtt Arc Survival

Review date: 2026-07-22

Evidence source: `output/AttitudeAblation_3600s_20260722/attitude_ablation_summary.md`

Scope: source-level rewrite after the 3600 s attitude ablation ladder. This note becomes the first implementation priority for carrier-only attitude because the new evidence shows that false carrier-slip resets can starve DiffAtt before phase-bias calibration or formal ambiguity resolution can help.

## Short Verdict

Carrier slip detection is now the immediate priority.

The broad simulation analysis shows that realistic receiver-clock behaviour can destroy carrier arcs even when inter-antenna carrier phase bias is disabled. When the main carrier slip detector is neutralized, DiffAtt rows return and the attitude estimate recovers close to the clean carrier-noise case.

This should not be fixed by simply setting the threshold to `1 m` as a final design. The `1 m` case is diagnostic evidence that the present residual-jump metric is over-sensitive to non-slip common-mode dynamics. The scientific fix is receiver-clock/common-mode compensation or baseline-differenced slip detection.

## Ablation Evidence

| Case | Tail attitude | Diff rows | Interpretation |
|---|---:|---:|---|
| `L00_clean_ideal` | `0.0768 deg` | `30` | Clean baseline; DiffAtt arcs survive and all baseline rows are active. |
| `I01_carrier_sigma_1cm` | `0.1133 deg` | `30` | Carrier sigma increase from 5 mm to 10 mm is modest, not catastrophic. |
| `I02_inter_antenna_bias` | `3.6213 deg` | `0` | Unknown antenna phase bias alone kills the fixed DiffAtt solution. |
| `R10_realism_no_inter_antenna` | `1.3186 deg` | `0` | Full realism without inter-antenna bias still loses DiffAtt rows. |
| `F14_clock_jow_only` | `5.7659 deg` | `0` | JOW clock alone can destroy arcs. |
| `F16_realism_no_inter_slip_off` | `0.1117 deg` | `30` | With slip detection disabled, carrier-only attitude recovers. |
| `F17_realism_no_inter_slip_1m` | `0.1117 deg` | `30` | A relaxed threshold also recovers arcs, proving over-sensitive slip gating. |

The decisive comparison is:

```text
R10 realism no inter-antenna bias: 1.3186 deg, Diff rows = 0
F16 same realism but slip off:      0.1117 deg, Diff rows = 30
F17 same realism but threshold 1 m: 0.1117 deg, Diff rows = 30
```

So full-realism attitude failure is not explained only by inter-antenna phase bias. There is a separate receiver-clock/slip-reset mechanism.

## Current Implementation Diagnosis

The present slip path is:

1. `+models/+measurements/CarrierMeasurementBuilder.m` exports carrier prefit residual metadata in `errStruct.carrierPhase.prefit_m`.
2. `+revgnss/ReverseGNSSSimulation.m` calls `obj.trackMgr.process(cpInfo, obj.cfg)` before the EKF update.
3. `+revgnss/CarrierTrackManager.m` keeps one residual history per `tower, antenna, signal` track.
4. `+revgnss/CycleSlipDetector.m` tests consecutive residual jumps.
5. When `cfg.carrierSlip.productStepCompensation = true`, the detector subtracts the expected tower-clock model jump:

   ```text
   slipMetric = observedResidualJump - towerClockModelJump
   ```

6. If `abs(slipMetric) >= threshold_m`, the track is declared slipped.
7. With the current `resetAndSkip` action, the carrier row is dropped for that epoch and the corresponding ambiguity covariance is reset.

This already solved an older tower-product-boundary problem, but the new ladder shows it is not enough for the JOW realistic receiver-clock case. The detector compensates tower-clock model steps, not the full receiver-clock-driven common carrier residual dynamics visible across many rows.

## Why This Breaks Attitude

DiffAtt needs stable carrier arcs long enough for its calibration and ambiguity-resolution logic. The configuration currently uses a 60-epoch minimum arc for baseline ambiguity resolution. False slips reset the per-track arc IDs and ambiguity states before those arcs mature.

The result is:

```text
false residual jumps -> ambiguity resets -> short arcs -> AR rejects -> Diff rows = 0 -> no carrier attitude update
```

DiffAtt itself deliberately does not use the main per-row slip detector. It relies on carrier rows and arc metadata surviving the main detector, then applies its own attitude-row logic. Therefore the main detector can still starve DiffAtt even though DiffAtt baseline differencing would cancel much of the common receiver-clock component.

## What Should Be Implemented

Priority 1 is to change the slip metric, not to inflate the threshold blindly.

Recommended implementation order:

1. Add common-mode residual-jump diagnostics.

   At each epoch, group carrier rows by receiver/signal and by tower/signal. Compute the median or robust mean residual jump across tracks. A receiver-clock event should appear with the same sign and similar magnitude across many towers and antennas; a real cycle slip should be localized to one receiver/tower/signal track or a small subset.

2. Add receiver-clock/common-mode compensated slip metrics.

   Candidate metric:

   ```text
   slipMetric_track = rawJump_track - towerModelJump_track - commonReceiverJump(receiver, signal)
   ```

   The common term must be estimated robustly so that a real slip on one track does not contaminate the common-mode estimate.

3. Add baseline-differenced DiffAtt slip logic.

   For attitude, use differences between antenna `a` and the reference antenna for the same tower and signal:

   ```text
   baselineJump = jump(tower, antenna, signal) - jump(tower, referenceAntenna, signal)
   ```

   Receiver-clock common mode cancels in this difference. This is the natural slip metric for DiffAtt arc survival.

4. Separate slip classifications.

   Report at least:

   - confirmed localized slip,
   - common-mode clock event,
   - tower-product boundary event,
   - unclassified jump,
   - suppressed common-mode reset.

5. Only reset ambiguity states for confirmed localized slips.

   Common-mode clock events should not reset all per-antenna carrier arcs. They should be handled by compensation, covariance inflation, or a clock/dynamics diagnostic, depending on the residual source.

## What Should Not Be Done

Do not treat `threshold_m = 1.0` as the final fix. It works in the ablation because it suppresses false resets, but it also makes the detector less sensitive to real cycle slips.

Do not start with LAMBDA/ILS. Formal ambiguity resolution cannot work if the arc manager keeps resetting the data before the minimum arc length is reached.

Do not add receiver phase-bias states first. Bias states need stable arcs and credible ambiguity status. Without those, extra states can absorb symptoms without improving observability.

## State-Vector Recommendation

This point does not require new EKF states as the first fix.

The immediate improvement is in measurement classification and arc management:

```text
residual jumps -> classify common/localized -> preserve or reset arc
```

Only after slip-stable arcs exist should state augmentation be reconsidered for phase bias, gyro bias, or sensor calibration.

## Validation Gates Before Calling It Done

1. Re-run the focused cases:

   - `F14_clock_jow_only`
   - `R10_realism_no_inter_antenna`
   - `F16_realism_no_inter_slip_off`
   - `F17_realism_no_inter_slip_1m`

2. With realistic JOW clock and no inter-antenna bias, DiffAtt rows should recover from `0` to the expected active row count without disabling slip detection.
3. Synthetic one-cycle slip injection must still reset the affected track.
4. A common receiver-clock event must not reset every tower/antenna carrier arc.
5. The report must distinguish true slips from suppressed common-mode events.

## Think, Plan, Evaluate, Next Step

Think:
The ladder shows a data starvation problem. The attitude estimator is not merely inaccurate; it is often not receiving DiffAtt rows at all.

Plan:
Fix the slip detector and arc survival before investing in phase-bias states or LAMBDA/ILS.

Evaluate:
The current detector is already model-step compensated for tower-clock product jumps, but the new JOW receiver-clock evidence exposes a common-mode effect outside that compensation.

Next step:
Implement receiver-clock/common-mode or baseline-differenced slip metrics and validate against the focused ablation cases.
