# Phase Plan — TWSTFT and Multi-Asset ISL Implementation

This plan is intentionally phased. Do not jump directly to TWSTFT carrier or joint multi-asset estimation. The correct order is to harden topology, events, state ownership, gauge handling, and validation before adding high-precision time/frequency-transfer claims.

Use phase names in documentation. When implementing code, assign the next repository stage number by checking `oo_v1/README_oo_v1.md`, `+revgnss/ReportStatus.m`, `+revgnss/StageHistory.m`, and the current branch plan.

## Phase 0 — Source-truth and claim gate

**Purpose:** make sure unsupported features cannot be accidentally claimed.

Implement or verify:

- feature flags for `multiAssetEstimation`, `islOneWay`, `islTwoWay`, `twstftCode`, `twstftCarrier`, `relayTransponder`, and `carrierFrequencyTransfer`,
- `guardedNotImplemented` status for modes that are configured but not physically implemented,
- report summary fields for row counts and EKF-used counts,
- README/report wording that separates represented-only assets from jointly estimated assets.

Acceptance:

- default run remains current single-primary-asset reverse GNSS,
- no TWSTFT or multi-asset estimation claim appears unless rows enter EKF,
- all new feature flags default off,
- invalid combinations fail clearly.

Suggested tests:

- `test_twstft_multiasset_feature_defaults`
- `test_twstft_unsupported_modes_guarded`
- `test_report_no_false_twstft_claims`

## Phase 1 — Link endpoint and event-time abstraction

**Purpose:** provide a common event model for ISL and TWSTFT.

Add:

- `revgnss.LinkEndpoint`
- `revgnss.LinkEvent`
- `revgnss.LightTimeSolver`
- `revgnss.ProcessingDelayModel`
- `revgnss.LinkSignalDefinition`

Minimum event fields:

```text
eventId
linkId
role
transmitterType / receiverType
transmitterId / receiverId
transmitCoordinateTime_s
receiveCoordinateTime_s
transmitLocalClockTime_s
receiveLocalClockTime_s
lightTime_s
processingDelay_s
framePolicy
sagnacPolicy
signalId
```

Acceptance:

- one-way event solver returns positive light time,
- two-way event solver returns primitive outbound and inbound events,
- same-epoch shortcut is a diagnostic mode, not the default physical model,
- existing Stage 23 timing diagnostics can be expressed through the new event structure.

Suggested tests:

- `test_link_event_one_way_light_time`
- `test_link_event_two_way_primitives`
- `test_light_time_solver_units_and_frame_policy`

## Phase 2 — Multi-asset state ownership map

**Purpose:** distinguish represented-only assets, product-aided assets, and jointly estimated assets.

Add:

- `revgnss.MultiAssetStateMap`
- `revgnss.AssetStateBlock`
- `revgnss.ClockGaugeManager`
- `revgnss.MultiAssetObservabilityAudit`

State ownership modes:

```text
representedOnly       % truth/helper only; no EKF columns
productAidedExternal  % state supplied by product/payload with covariance
jointEstimated        % has EKF columns
primaryEKF            % current main asset
```

Acceptance:

- primary asset remains first estimated asset,
- represented-only secondary assets have no EKF columns,
- joint estimation explicitly adds columns and report entries,
- clock gauge audit refuses unconstrained all-free clock states.

Suggested tests:

- `test_multiasset_state_map_primary_only`
- `test_multiasset_state_map_joint_columns`
- `test_clock_gauge_unobservable_guard`

## Phase 3 — One-way ISL EKF rows for the main asset

**Purpose:** allow the main space asset to use ISL code/Doppler from a represented secondary asset.

Start with secondary asset represented-only. The transmitter state and clock are truth/product values; the receiver is the main asset EKF state.

Implement:

- `revgnss.ISLMessage` for payload metadata,
- `revgnss.ISLObservableBuilder` or an evolved `ISLMeasurementBuilder`,
- code row used in EKF,
- Doppler row used in EKF,
- carrier row remains diagnostic unless ambiguity states exist,
- row metadata separates payload from RF observable.

Measurement logic:

```text
code:    rho + b_rx - b_tx + hardware/calibration terms
doppler: rho_dot + d_rx - d_tx + oscillator terms
carrier: rho + b_rx - b_tx + lambda*N + carrier corrections
```

Acceptance:

- ISL code and Doppler can update the main asset state,
- transmitter columns are absent when the transmitter is represented-only,
- transmitter product uncertainty appears in R if configured,
- carrier reports diagnostic-only status until ambiguities exist.

Suggested tests:

- `test_isl_one_way_code_updates_primary_state`
- `test_isl_one_way_doppler_units`
- `test_isl_payload_not_used_as_measurement_unless_configured`
- `test_isl_carrier_guard_without_ambiguity`

## Phase 4 — Joint multi-asset ISL updates

**Purpose:** support ISL measurements that update both receiver and transmitter assets.

Enable `jointEstimated` secondary assets. For range-like rows:

```text
H_r_rx = +u^T
H_r_tx = -u^T
H_b_rx = +1
H_b_tx = -1
```

For Doppler, include velocity and clock-drift columns. For carrier, include ambiguity columns.

Acceptance:

- same measurement row can update both assets,
- row descriptors list both state owners,
- covariance and observability audit report clock/geometry rank,
- primary-only mode is unchanged.

Suggested tests:

- `test_joint_isl_range_has_rx_and_tx_partials`
- `test_joint_isl_doppler_finite_difference_jacobian`
- `test_joint_isl_clock_gauge_rank_guard`

## Phase 5 — ISL carrier with ambiguity/arc management

**Purpose:** make ISL carrier physically usable in the EKF.

Add:

- `revgnss.ISLCarrierAmbiguityManager`,
- ambiguity state indexing by link/signal/arc,
- cycle-slip status and arc reset,
- wavelength/unit conversion tests,
- carrier covariance with phase noise and shared oscillator terms.

Acceptance:

- carrier cannot be EKF-used without ambiguity state,
- ambiguity state is link/signal/arc specific,
- cycle slip causes arc reset or row rejection,
- finite-difference attitude/lever-arm audit passes if antenna geometry is active.

Suggested tests:

- `test_isl_carrier_requires_ambiguity_state`
- `test_isl_carrier_wavelength_units`
- `test_isl_cycle_slip_arc_reset`

## Phase 6 — Event-driven two-way ISL / enhanced time transfer

**Purpose:** implement moving-node two-way timing without assuming equal propagation in both directions.

Add:

- `revgnss.TwoWayISLTimeTransferBuilder`,
- explicit outbound and return events,
- known TX/RX processing-delay calibration,
- optional processing-delay residual states,
- two-way range and optional clock-offset pseudo-observable.

Measurement options:

```text
roundTripDelay_m
twoWayRange_m
clockOffset_s_or_m
frequencyOffset_mps_or_fractional
```

Acceptance:

- event metadata exposes all TX/RX time tags,
- moving endpoints produce different outbound/return light times,
- static symmetric test matches simplified formula within tolerance,
- gauge audit prevents absolute-clock overclaim.

Suggested tests:

- `test_two_way_isl_moving_endpoint_asymmetry`
- `test_two_way_isl_static_symmetric_limit`
- `test_two_way_isl_clock_offset_units`

## Phase 7 — TWSTFT code session v1

**Purpose:** model two ground stations exchanging code time-transfer signals through a relay/transponder.

Add:

- `revgnss.TwstftSessionConfig`
- `revgnss.TwstftEventModel`
- `revgnss.TwstftCodeMeasurementBuilder`
- `revgnss.TransponderDelayModel`
- `revgnss.TwstftGaugeAudit`

Core session:

```text
Station A -> relay/transponder -> Station B
Station B -> relay/transponder -> Station A
```

Required terms:

- A/B station clock bias and drift,
- uplink/downlink light time,
- station modem TX/RX delays,
- transponder group delay,
- relay motion/Sagnac policy,
- ground-space troposphere and ionosphere status,
- session common-mode residual covariance.

Acceptance:

- code TWSTFT session produces row metadata and optional EKF rows,
- clock offset A-B is observable only under an explicit gauge,
- common relay/station calibration errors use block covariance,
- report states synthetic TWSTFT code, not operational TWSTFT.

Suggested tests:

- `test_twstft_code_event_pair_metadata`
- `test_twstft_code_clock_gauge_policy`
- `test_twstft_code_common_delay_covariance_block`

## Phase 8 — TWSTFT carrier/frequency-transfer v1

**Purpose:** add carrier readings for frequency transfer, after code TWSTFT is stable.

Add:

- `revgnss.TwstftCarrierMeasurementBuilder`
- `revgnss.TransponderClockModel`
- `revgnss.FrequencyTransferEstimator`
- `revgnss.TwstftCarrierCovarianceBuilder`

Model:

- station carrier counters referenced to local clocks,
- own and remote received carrier readings,
- relay LO frequency and uncertainty,
- range-rate compensation,
- station frequency-difference state or pseudo-measurement,
- carrier thermal/counter noise.

Acceptance:

- relay LO uncertainty is modeled or constrained,
- range-rate compensation is explicit,
- carrier readings do not silently become code TWSTFT,
- report states frequency-transfer uncertainty sources.

Suggested tests:

- `test_twstft_carrier_requires_lo_model`
- `test_twstft_carrier_range_rate_compensation_units`
- `test_twstft_frequency_transfer_covariance_blocks`

## Phase 9 — Integrated scenario presets

**Purpose:** provide controlled scenarios for validation.

Add scenario presets:

```text
singleAssetReverseGnssRegression
primaryWithRepresentedIslAid
jointTwoAssetIslSynthetic
movingTwoWayIslTimeTransferSynthetic
twstftCodeGroundPairSynthetic
twstftCarrierFrequencyTransferSynthetic
```

Acceptance:

- each preset documents what is and is not implemented,
- unsupported combinations fail clearly,
- default scenario remains current regression.

Suggested tests:

- `test_scenario_preset_primary_with_isl_aid`
- `test_scenario_preset_twstft_code`
- `test_scenario_preset_default_regression_unchanged`

## Phase 10 — Scientific validation campaign

**Purpose:** make numerical claims honest.

Validation levels:

```text
smoke
unit
syntheticRegression
monteCarloConsistency
clockGaugeObservability
parserFixtureValidation
externalBenchmarkValidation
```

Required metrics:

- position/velocity RMS for estimated assets,
- clock bias/drift RMS and NEES,
- ISL prefit/postfit residuals by observable type,
- TWSTFT clock-offset and frequency-transfer error,
- NIS by code/Doppler/carrier/two-way/TWSTFT groups,
- R block conditioning and PSD/PD status,
- gauge rank and condition numbers.

Acceptance:

- synthetic validation can support synthetic claims only,
- external benchmark validation is required before operational TWSTFT or mission-grade claims,
- report marks full-suite status honestly.

Suggested tests:

- `test_validation_campaign_isl_groups_present`
- `test_validation_campaign_twstft_groups_present`
- `test_report_validation_labels_not_overclaimed`

## Implementation ordering summary

Recommended order:

1. Phase 0 claim gates.
2. Phase 1 event model.
3. Phase 2 state ownership/gauge.
4. Phase 3 one-way ISL aiding to main asset.
5. Phase 4 joint multi-asset updates.
6. Phase 5 ISL carrier ambiguities.
7. Phase 6 two-way ISL time transfer.
8. Phase 7 TWSTFT code.
9. Phase 8 TWSTFT carrier/frequency transfer.
10. Phase 9 presets.
11. Phase 10 validation campaign.

Do not enable TWSTFT carrier before the relay/transponder clock model, event timing, range-rate compensation, and covariance blocks exist.
