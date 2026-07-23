# Point 5 - Antenna Geometry, PCV, and Survey Realism

Review date: 2026-07-22

Evidence source: `output/AttitudeAblation_3600s_20260722/attitude_ablation_summary.md`

Scope: source-level rewrite after the 3600 s attitude ablation ladder. Geometry remains important for ultimate attitude accuracy, but it is not the current failure source exposed by the broad simulation analysis.

## Short Verdict

Antenna geometry is not the immediate attitude blocker.

The current four-receiver geometry is strong enough for clean carrier-only attitude when DiffAtt arcs survive. The ablation shows clean ideal attitude at `0.0768 deg` tail mean and the 10 mm carrier-noise case at `0.1133 deg`, both with `30` DiffAtt rows.

Geometry should remain a later design and calibration study. It should not distract from the present slip-reset and phase-bias blockers.

## Ablation Evidence

| Case | Tail attitude | Diff rows | Interpretation |
|---|---:|---:|---|
| `L00_clean_ideal` | `0.0768 deg` | `30` | Current geometry supports carrier attitude. |
| `I01_carrier_sigma_1cm` | `0.1133 deg` | `30` | Geometry remains adequate under 10 mm carrier noise. |
| `I07_antenna_pcv_current` | `0.0768 deg` | `30` | Current PCV toggle has no visible effect because truth/model are matched. |
| `I08_tower_survey_current` | `0.0749 deg` | `30` | Current survey toggle mostly cancels because truth/model are matched. |
| `R10_realism_no_inter_antenna` | `1.3186 deg` | `0` | Realism failure appears through slip/reset arc starvation, not geometry. |

Important caveat: `I07` and `I08` do not prove PCV or tower-survey errors are physically harmless. They show that the current toggle expansion enables truth and model together, so the estimator mostly receives a matched correction.

## What Is Already Implemented

1. Multi-receiver lever-arm geometry is active by default.

   Evidence:
   - `+revgnss/ConfigFactory.m` enables attitude estimation for multi-receiver configurations.
   - The default multi-receiver layout uses four non-coplanar receiver lever arms.
   - One-receiver configurations force attitude off.

2. Custom geometries are supported.

   Evidence:
   - `cfg.asset.receiverLeverArms_body_m` can carry explicit receiver lever arms.
   - `+revgnss/ConfigFactory.m` requires custom geometry for `nReceivers > 4`.

3. Geometry readiness and observability checks exist.

   Evidence:
   - `+revgnss/ReceiverGeometry.m` computes receiver geometry statistics and baseline lengths.
   - `+revgnss/AttitudeObservability.m` classifies attitude observability.
   - `+revgnss/AttitudeScenarioReadiness.m` combines geometry, measurement mode, observability, and evidence.

4. Operational phase-center calibration is not modelled.

   Evidence:
   - Lever arms are body-frame receiver reference-point offsets.
   - The current model is not ANTEX-grade PCO/PCV calibration.

## Scientific Evaluation

The first-order relation is:

```text
attitude_error_rad roughly equals range_error_m / baseline_length_m
```

Longer baselines and better 3D antenna placement improve attitude conditioning. More antennas can improve redundancy, but each additional receiver also adds:

- carrier tracks,
- ambiguity states,
- slip-detection opportunities,
- receiver-relative phase-bias calibration terms,
- phase-center and lever-arm metrology requirements.

The current ladder shows that the existing geometry is adequate when arcs survive. Therefore geometry optimization is not the first implementation target.

The PCV and tower-survey result must be interpreted carefully. Because truth and model flags are enabled together, those cases behave like calibrated/matched corrections. They do not represent unmodelled PCV or unmodelled survey error.

## Implementation Recommendation

1. Defer geometry changes until slip detection and phase-bias handling are stable.

2. Add a geometry sweep later using existing custom lever-arm hooks.

   Evaluate:

   - receiver geometry rank,
   - baseline lengths,
   - singular values of the attitude Jacobian,
   - attitude covariance projection,
   - sensitivity to one bad ambiguity fix,
   - sensitivity to receiver-relative phase bias.

3. Split PCV and tower-survey realism into matched and unmodelled cases.

   Use separate labels:

   - truth-only PCV/survey stress,
   - model-only correction stress,
   - matched calibrated correction,
   - unknown/unmodelled correction.

4. Add phase-center uncertainty to the attitude error budget.

   Start with Monte Carlo perturbation or calibration covariance, not EKF lever-arm states.

## State-Vector Recommendation

Do not add lever-arm correction states now.

Lever-arm states are strongly coupled with:

- attitude,
- receiver phase bias,
- ambiguity,
- PCV/PCO calibration.

They require external attitude reference, strong priors, and a deliberate calibration scenario. The current immediate problem is not insufficient geometry states; it is missing DiffAtt rows under false slip resets.

Possible later state form:

```text
dlever_rx2_xyz, dlever_rx3_xyz, ..., dlever_rxN_xyz
```

but only after the carrier attitude pipeline is stable.

## Validation Gates Before Calling It Done

1. Geometry sweeps must compare layouts under identical slip-detection and phase-bias assumptions.
2. PCV/tower-survey tests must clearly distinguish truth-only, model-only, and matched modes.
3. Claimed geometry improvement must hold under phase-bias and wrong-fix stress cases.
4. Any hardware/layout claim must include lever-arm and phase-center calibration uncertainty.
5. No geometry conclusion should be drawn from cases where truth and model corrections cancel unless that is explicitly the intended calibrated case.

## Think, Plan, Evaluate, Next Step

Think:
The geometry is strong enough to work in clean cases, so it is not the first broken link.

Plan:
Hold geometry changes until carrier arcs and phase-bias assumptions are physically honest.

Evaluate:
The ablation says geometry/PCV/survey did not drive the observed failure, but current PCV and survey tests are matched-model cases rather than unmodelled realism stresses.

Next step:
After slip and phase-bias work, build a geometry and calibration-error sweep.
