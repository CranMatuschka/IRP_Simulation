# Point 6 - Attitude Aiding

Review date: 2026-07-22

Evidence source: `output/AttitudeAblation_3600s_20260722/attitude_ablation_summary.md`

Scope: source-level rewrite after the 3600 s attitude ablation ladder. Attitude aiding remains valuable for operational estimation, but the new evidence shows it is not required to explain the current carrier-only failure.

## Short Verdict

Keep attitude aiding as a separate operational branch.

The ablation shows carrier-only attitude can recover to about `0.1117 deg` when inter-antenna phase bias is disabled and the false slip-reset mechanism is neutralized. Therefore the current bad attitude result should not be solved by immediately adding star tracker or IMU aiding. The carrier-only failure should be fixed and reported first.

For operational spacecraft attitude estimation, aiding is still valuable and should eventually be added with separate metrics.

## Ablation Evidence

| Case | Tail attitude | Diff rows | Interpretation |
|---|---:|---:|---|
| `L00_clean_ideal` | `0.0768 deg` | `30` | Carrier-only attitude works in clean conditions. |
| `R10_realism_no_inter_antenna` | `1.3186 deg` | `0` | Realism without phase bias fails because DiffAtt rows vanish. |
| `F16_realism_no_inter_slip_off` | `0.1117 deg` | `30` | Carrier-only attitude recovers without external aiding. |
| `F17_realism_no_inter_slip_1m` | `0.1117 deg` | `30` | Arc survival, not external aiding, explains the recovery. |

This means attitude aiding should not be used to hide carrier-only arc-management errors.

## What Is Already Implemented

1. Quaternion error-state attitude filtering exists.

   Evidence:
   - `+filter/ReverseGNSSEKF.m` supports quaternion error-state attitude handling.
   - It injects and resets small attitude-error states after updates.

2. Gyro-bias state augmentation exists.

   Evidence:
   - `+filter/ReverseGNSSEKF.m` appends three gyro-bias states when the IMU estimator path is enabled.
   - Gyro-bias estimation is blocked in Euler-state mode, which is scientifically appropriate.
   - `tests/test_imu_gyro_bias_states.m` verifies state dimension, sign, and process-noise behaviour.

3. IMU truth modelling exists.

   Evidence:
   - `+models/+sensors/IMUModel.m` generates gyro and accelerometer measurements.
   - `+revgnss/SpaceAsset.m` attaches the truth IMU when configured.
   - `+revgnss/ReverseGNSSSimulation.m` passes noisy gyro readings to EKF prediction when gyro-bias estimation is active.

4. One-time external attitude initialization/calibration exists.

   Evidence:
   - `+revgnss/AttitudeInitializer.m` supports known-attitude calibration and coarse baseline integer search.
   - `+revgnss/ReverseGNSSSimulation.m` can use an external initial attitude reference for DiffAtt calibration.

5. Recurring external attitude measurement updates are not active.

   No recurring star-tracker, sun-sensor, horizon-sensor, or magnetometer update path was found in the inspected attitude estimator chain.

## Scientific Evaluation

Carrier-only attitude and aided attitude answer different questions:

```text
carrier-only: what attitude can reverse-GNSS carrier phase recover by itself?
aided:        what attitude can a fused spacecraft attitude estimator recover?
```

Both are valid, but they must not be mixed in one performance claim.

The current ablation is especially useful because it shows that carrier-only attitude can be good once the slip/reset problem is neutralized. That makes the immediate scientific task sharper: fix carrier arc survival and phase-bias calibration before adding external sensors.

Gyro aiding improves propagation and short-term smoothness, but gyro-only attitude drifts. A star tracker provides strong absolute attitude information. Sun/horizon sensors can help but are coarser and have visibility constraints. These are useful operational additions, not replacements for a correct carrier-only analysis.

## Implementation Recommendation

1. Do not use aiding as the first fix for the current attitude failure.

   First preserve DiffAtt arcs under realistic clocks and handle inter-antenna phase bias.

2. Keep two report tracks.

   Required separation:

   - carrier-only attitude,
   - gyro-propagated carrier attitude,
   - star-tracker-aided attitude,
   - full aided attitude.

3. Use the existing gyro-bias path when adding aided estimation.

   The quaternion error-state architecture and gyro-bias states are the right foundation.

4. Add recurring star-tracker-like measurements before lower-grade sensors.

   A clean measurement form is:

   ```text
   r_att = small_angle(q_meas * inverse(q_est))
   H_att = identity in attitude-error columns
   R_att = sensor attitude covariance
   ```

5. Add sensor outages and gating.

   The aided branch should include update rate, dropout intervals, covariance, and NIS/NEES consistency checks.

## State-Vector Recommendation

Already justified:

```text
gyro_bias_x, gyro_bias_y, gyro_bias_z
```

Do not add accelerometer bias states for free-flight attitude unless a physically justified accelerometer measurement model is added.

For star tracker aiding, start with measurement updates, not new states. Add boresight or alignment states only later:

```text
star_tracker_boresight_misalignment_xyz
```

Those states need tight priors and a calibration-specific validation scenario.

## Validation Gates Before Calling It Done

1. With aiding disabled, carrier-only results must match the slip-stable baseline.
2. Aided reports must not replace or hide carrier-only metrics.
3. Gyro-only propagation must show realistic drift and bias behaviour.
4. Star-tracker-aided updates must pass NIS/NEES consistency checks.
5. Sensor outages must produce bounded and explainable degradation.

## Think, Plan, Evaluate, Next Step

Think:
The new ladder shows that the carrier-only path can recover without external aiding, so aiding is not the immediate repair.

Plan:
Fix carrier-only slip and phase-bias issues first, then add aided attitude as a separately labelled operational estimator.

Evaluate:
The repo already has a good IMU/gyro-bias foundation but lacks recurring absolute attitude sensor updates.

Next step:
After the carrier-only attitude chain is stable, add a star-tracker-like update path with separate metrics.
