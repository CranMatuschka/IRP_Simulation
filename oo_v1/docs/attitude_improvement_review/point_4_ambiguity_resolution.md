# Point 4 - Ambiguity Resolution

Review date: 2026-07-22

Evidence source: `output/AttitudeAblation_3600s_20260722/attitude_ablation_summary.md`

Scope: source-level rewrite after the 3600 s attitude ablation ladder. This point now separates arc survival from formal ambiguity resolution, because false slip resets can prevent the ambiguity resolver from receiving usable arcs.

## Short Verdict

Formal ambiguity resolution is still important, but it is not the next fix.

The next fix is carrier arc survival. LAMBDA/ILS is premature while false carrier-slip resets are starving the 60-epoch DiffAtt calibration arcs. A better integer search cannot operate on arcs that have already been reset or rejected as too short.

The correct ordering is:

```text
stable arcs -> honest phase-bias status -> formal ambiguity resolution
```

## Ablation Evidence

| Case | Tail attitude | Diff rows | Ambiguity meaning |
|---|---:|---:|---|
| `L00_clean_ideal` | `0.0768 deg` | `30` | Arcs survive and baseline ambiguity fixing succeeds. |
| `I01_carrier_sigma_1cm` | `0.1133 deg` | `30` | Higher carrier noise alone still leaves usable arcs. |
| `R10_realism_no_inter_antenna` | `1.3186 deg` | `0` | Realism without antenna bias loses DiffAtt rows. |
| `F14_clock_jow_only` | `5.7659 deg` | `0` | JOW clock alone destroys ambiguity arcs. |
| `F16_realism_no_inter_slip_off` | `0.1117 deg` | `30` | Disabling slip detection restores ambiguity availability. |
| `F17_realism_no_inter_slip_1m` | `0.1117 deg` | `30` | Relaxing the detector also restores arcs. |

This means the immediate ambiguity failure is not only a weak integer search. It is an upstream arc-management failure.

## What Is Already Implemented

1. The EKF supports per-tower, per-receiver, per-signal float ambiguity states.

   Evidence:
   - `+filter/ReverseGNSSEKF.m` supports `floatPerTowerReceiverSignal`.
   - `+revgnss/ConfigFactory.m` requires that mode for multi-receiver raw carrier attitude.

2. Differential attitude baseline ambiguity resolution exists.

   Evidence:
   - `+revgnss/DiffAttitudeBuilder.m` accumulates differential carrier residuals.
   - `+revgnss/BaselineCarrierAmbiguityResolver.m` performs bounded raw L1 and raw L1/L2 baseline candidate searches.
   - The resolver uses arc length, RMS, ratio, float distance, and wide-lane consistency gates.

3. Controlled raw-carrier integer fixing exists.

   Evidence:
   - `+revgnss/IntegerAmbiguityFixer.m` applies controlled pseudo-measurement fixing.
   - `+revgnss/ReverseGNSSSimulation.m` resets held fixes when slips are reported.

4. Carrier slip tracking exists, but it is now the upstream problem.

   Evidence:
   - `+revgnss/CarrierTrackManager.m` records residual history, arc age, slip count, and reset requests.
   - It currently uses per-track residual jumps with tower-clock model step compensation.
   - The ablation shows this is insufficient under the JOW receiver-clock case.

5. Wide-lane and narrow-lane diagnostics exist, but they are not full WL/NL fixing.

   Evidence:
   - `+revgnss/WideLaneNarrowLaneDiagnostics.m` computes diagnostic metrics.
   - Carrier ionosphere-free traceability is diagnostic; carrier-IF ambiguity is not directly integer in the raw-cycle sense.

## Scientific Evaluation

Carrier ambiguity resolution has two layers:

1. Data continuity layer:

   ```text
   Can the carrier arc stay intact long enough to support ambiguity fixing?
   ```

2. Integer decision layer:

   ```text
   Given a valid float ambiguity and covariance, which integer candidate is statistically justified?
   ```

The current ablation failure is layer 1. DiffAtt rows become zero because arcs are destroyed or rejected before the resolver can produce fixed rows.

This changes the priority. A formal LAMBDA/MLAMBDA implementation is valuable, but only after:

- false common-mode slip resets are suppressed,
- localized real slips are still detected,
- phase-bias status is honest,
- calibration arcs reach the required length.

Otherwise LAMBDA could make a biased or reset-starved system look more sophisticated without improving the actual attitude estimate.

## Implementation Recommendation

1. Treat carrier slip detection as ambiguity-resolution stage zero.

   The ambiguity resolver should receive stable arcs under realistic receiver-clock dynamics. This is the prerequisite for all later AR work.

2. Add arc-survival diagnostics to the AR report.

   Every rejected baseline should expose:

   - current arc length,
   - number of resets,
   - rejection reason,
   - whether the reset was localized slip or common-mode event,
   - whether the baseline was excluded before integer search.

3. Reconcile stale terminology.

   Some helper/report text still implies no integer fixing. The current code has controlled raw fixing and baseline candidate search, but not full operational LAMBDA/MLAMBDA or formal false-fix control.

4. Add covariance-domain ILS after arc survival is fixed.

   The later formal AR package should include:

   - ambiguity subset covariance extraction,
   - decorrelation,
   - integer least-squares candidate search,
   - ratio or integer-aperture acceptance,
   - false-fix probability or bootstrap success-rate estimate,
   - Monte Carlo measured false-fix rate.

5. Keep wide-lane/narrow-lane scientifically labelled.

   WL/NL can assist raw ambiguity resolution. Do not claim carrier-IF integer fixing unless raw ambiguity traceability is preserved and validated.

## State-Vector Recommendation

The ambiguity state vector is already stocked up in the important way:

```text
N(tower, receiver, signal)
```

Do not add more ambiguity-like states. The next improvements are:

- better arc classification,
- better covariance extraction,
- better candidate scoring,
- accepted pseudo-measurement constraints after fixing.

The right architecture remains:

```text
float ambiguity state -> external integer decision -> constrained update
```

not:

```text
integer EKF state or duplicate per-baseline ambiguity state
```

## Validation Gates Before Calling It Done

1. JOW-clock no-bias cases must preserve arcs and recover DiffAtt rows without disabling slip detection.
2. Synthetic localized one-cycle slips must still reset the affected track.
3. Baseline AR rejection tables must distinguish insufficient arc length from RMS, ratio, float-distance, and phase-bias rejection.
4. Controlled no-bias synthetic cases must achieve high correct-fix rate.
5. Biased uncalibrated cases must reject or downgrade fixes instead of confidently fixing wrong integers.
6. Formal LAMBDA/ILS work must include false-fix-rate validation.

## Think, Plan, Evaluate, Next Step

Think:
The first ambiguity problem is not the absence of a sophisticated integer search. It is that the data arcs can be destroyed before the search matters.

Plan:
Treat slip detection and arc survival as ambiguity-resolution stage zero.

Evaluate:
The current ambiguity machinery works in clean and higher-carrier-noise cases, but fails when realistic clock dynamics trigger false resets.

Next step:
Implement robust slip classification, then revisit LAMBDA/ILS with stable arcs and honest phase-bias assumptions.
