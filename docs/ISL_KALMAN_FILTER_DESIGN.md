# ISL Kalman-Filter Design Notes

This document defines how inter-satellite-link information should enter the Kalman-filter logic for the TWSTFT / multi-asset extension.

## Core principle

Do not treat "ISL information" as one thing. The receiving main asset gets two different categories of information:

1. **RF observables** measured from the signal: code, carrier, Doppler, two-way timing, frequency-transfer beat notes.
2. **Message payload** decoded from the signal: transmitter ID, transmit time tag, ephemeris/clock/attitude estimates, health, calibration data, and covariance.

Only RF observables are direct measurement rows. Payload fields are metadata, external products, or pseudo-measurements depending on configuration.

## Asset roles

### Primary asset

The main estimated spacecraft. This is the receiver for the first ISL aiding scenario.

```text
stateOwner = primaryEKF
```

### Represented secondary asset

A helper spacecraft whose truth or product-provided trajectory is used to generate and predict ISL measurements. It has no EKF columns.

```text
stateOwner = representedOnly
```

### Product-aided secondary asset

A secondary asset whose state/clock estimate and covariance arrive in an ISL navigation payload or synthetic product provider. It may contribute uncertainty to R but still has no EKF columns.

```text
stateOwner = productAidedExternal
```

### Jointly estimated secondary asset

A secondary asset that has its own EKF state block. ISL rows update both primary and secondary states.

```text
stateOwner = jointEstimated
```

## Recommended state vector

Start with the existing primary-asset state and extend only through a state-map class.

```text
x = [ x_asset_1 ; x_asset_2 ; ... ; x_link ; x_twstft ]

x_asset_i = [
    r_i_ecef_m(3),
    v_i_ecef_mps(3),
    attitude_error_i_rad(3),
    omega_i_body_radps(3),
    clock_bias_i_m,
    clock_drift_i_mps
]
```

Optional link states:

```text
N_isl_link_signal_arc_m_or_cycles
b_tx_processing_link_m
b_rx_processing_link_m
b_transponder_delay_m
f_transponder_lo_Hz_or_fractional
b_station_A_m
b_station_B_m
bdot_station_A_mps
bdot_station_B_mps
```

Use one canonical state map. Do not infer state columns by hard-coded indices inside measurement builders.

## Clock gauge policy

Clock states are relative. A multi-clock network is unobservable unless one of the following is true:

- a reference clock is fixed,
- a strong prior/pseudo-measurement anchors a clock,
- two-way combinations intentionally cancel a clock mode,
- external clock products are used with covariance,
- the scenario estimates only relative offsets/frequency differences.

Add a `ClockGaugeManager` that reports:

```text
gaugeType
anchorClockId
estimatedClockIds
observableClockRank
nullSpaceDimension
conditionNumber
policyApplied
```

The EKF must fail or guard the configuration when the clock null space is not handled.

## One-way ISL code model

For transmitter asset `tx` and receiver asset `rx`:

```text
rho = norm(r_rx - r_tx)
u   = (r_rx - r_tx) / rho

z = rho_truth + b_rx_truth - b_tx_truth
    + d_rx_hw_truth - d_tx_hw_truth
    + epsilon_code

h = rho_model + b_rx_state_or_product - b_tx_state_or_product
    + d_rx_hw_model - d_tx_hw_model
```

### Primary-only represented-transmitter Jacobian

If transmitter is represented/product-only:

```text
H(:, r_rx) = +u^T
H(:, b_rx) = +1
```

Transmitter state uncertainty enters R, not H.

### Joint-estimated transmitter Jacobian

If transmitter is jointly estimated:

```text
H(:, r_rx) = +u^T
H(:, r_tx) = -u^T
H(:, b_rx) = +1
H(:, b_tx) = -1
```

If antenna phase centers are used, replace `r_i` by endpoint phase-center positions and include attitude lever-arm partials.

## One-way ISL Doppler model

Use consistent units. Prefer m/s internally.

```text
rho_dot = u^T * (v_rx - v_tx)

z = rho_dot_truth + d_rx_truth - d_tx_truth + epsilon_dopp
h = rho_dot_model + d_rx_state_or_product - d_tx_state_or_product
```

Minimum Jacobian for primary-only mode:

```text
H(:, v_rx) = +u^T
H(:, d_rx) = +1
```

For joint mode:

```text
H(:, v_rx) = +u^T
H(:, v_tx) = -u^T
H(:, d_rx) = +1
H(:, d_tx) = -1
```

Position partials through `u` should be analytic or finite-difference audited. Do not silently omit them if they affect the configured accuracy claim.

## ISL carrier model

Carrier phase in metres:

```text
z_phi = rho + b_rx - b_tx + lambda*N
        + phase_center_rx - phase_center_tx
        + phase_windup
        + epsilon_phi
```

Rules:

- carrier cannot be EKF-used without ambiguity state ownership,
- ambiguity key must include link ID, transmitter, receiver, signal, and arc,
- cycle-slip detection/reset must be explicit,
- if phase wind-up or antenna PCV is not implemented, report `guardedNotImplemented` or `disabledByConfig`,
- carrier covariance must include shared oscillator/link terms when configured.

Jacobian additions:

```text
H(:, N_link_signal_arc) = lambda     % if ambiguity is in cycles
H(:, N_link_signal_arc_m) = 1        % if ambiguity is stored in metres
```

Choose one ambiguity unit convention and document it in the state map.

## ISL payload usage modes

### Metadata-only payload

Payload fields are stored in row descriptors and diagnostics only.

```text
usePayloadAsProduct = false
usePayloadAsPseudoMeasurement = false
```

### Product provider payload

Payload provides transmitter state/clock and covariance. The transmitter has no state columns, but uncertainty contributes to measurement R.

```text
R_total = R_tracking + H_tx_product * P_tx_product * H_tx_product^T
```

### Pseudo-measurement payload

Payload becomes a separate pseudo-measurement row on a jointly estimated secondary asset.

```text
z_payload = [r_tx_payload; v_tx_payload; b_tx_payload; d_tx_payload]
h_payload = selected state components
R_payload = payload covariance
```

This must be configured explicitly and reported separately from RF observables.

## Two-way ISL measurement logic

Model primitive events first:

```text
E1: A transmits to B
E2: B receives from A
E3: B transmits reply to A
E4: A receives reply from B
```

Known processing delays:

```text
T_tx_A, T_rx_A, T_tx_B, T_rx_B
```

Useful observables:

```text
roundTripDelay = (t_A_rx - t_A_tx) - knownDelays
twoWayRange    = 0.5*c*roundTripDelay
clockOffset    = function(E1,E2,E3,E4, processingDelays, motionCorrection)
```

For moving platforms, outbound and inbound ranges differ. Add a motion correction or estimate using event-time geometry. A same-path cancellation is valid only in a static/symmetric diagnostic limit.

## TWSTFT Kalman-filter logic

TWSTFT is a ground-station time-transfer system through a relay/transponder. Do not model it as a normal ISL row; it has ground-space-ground legs and station modem calibration.

### Code TWSTFT states

Possible estimated states:

```text
b_station_A_m
b_station_B_m
bdot_station_A_mps
bdot_station_B_mps
b_transponder_delay_m
b_session_common_m
```

Usually estimate a relative clock offset/frequency difference, not absolute clocks, unless an explicit gauge is present.

### Code TWSTFT row concept

Primitive events:

```text
A tx -> relay rx -> relay tx -> B rx
B tx -> relay rx -> relay tx -> A rx
```

The measurement builder should form a session observable only after storing primitive event metadata. Include uplink/downlink atmospheric corrections for ground-space legs when configured.

### Carrier/frequency TWSTFT states

Possible states:

```text
f_station_A_error
f_station_B_error
f_relay_LO_error
rangeRate_compensation_error
carrier_counter_bias_A
carrier_counter_bias_B
```

Carrier TWSTFT should estimate/constrain relay LO frequency or include its covariance. Do not claim high-precision frequency transfer if relay LO uncertainty is ignored.

## Covariance design

Use block covariance whenever rows share an error source.

Shared error source examples:

- same transmitting asset clock product,
- same receiving asset clock product,
- same station modem delay calibration,
- same transponder group delay,
- same relay local oscillator frequency,
- same atmospheric correction product for a ground-space leg,
- same carrier arc/ambiguity status.

For a shared scalar error `q` affecting rows with sensitivities `a`, add:

```text
R_shared = sigma_q^2 * (a*a^T)
R_total  = R_tracking + sum(R_shared)
```

Then run symmetry and PSD/PD checks.

## Process models

Clock states should use the existing stochastic clock framework where possible. For long outages or crosslink-only cases, prefer stable Gauss-Markov clock models over unbounded random-walk growth when the scenario requires bounded covariance.

Example continuous state concept:

```text
b_dot = d + clock_noise_bias
d_dot = clock_noise_drift
```

For transponder LO:

```text
f_LO_dot = -1/tau_LO * f_LO + w_LO
```

For processing-delay residuals:

```text
delay_dot = -1/tau_delay * delay + w_delay
```

All process-noise units must be explicit.

## Observability audits

Run audits before enabling EKF rows:

- geometry rank for each asset position,
- clock rank/nullspace dimension,
- link graph connectivity,
- carrier ambiguity observability,
- two-way clock-offset observability,
- TWSTFT station-pair observability,
- condition number of active H blocks.

Report warnings or hard errors depending on feature criticality.

## Minimal acceptance matrix

| Capability | First acceptable implementation | Not acceptable |
|---|---|---|
| One-way ISL code | Updates primary asset; transmitter represented/product-only; R includes product uncertainty | Treating transmitter truth as perfect without metadata |
| One-way ISL Doppler | Units tested in m/s or Hz; clock drift columns explicit | Mixing Hz and m/s silently |
| ISL payload | Metadata-only or explicit product/pseudo-measurement mode | Using payload as truth without covariance |
| Joint multi-asset | H includes receiver and transmitter columns; gauge audit passes | Adding asset states but no observable rank check |
| ISL carrier | Ambiguity states and arc handling exist | Carrier row used in EKF with no ambiguity state |
| Two-way ISL | Explicit outbound/return events and moving-node asymmetry | Assuming equal path delay by default |
| TWSTFT code | Ground-space-ground event model and station modem delays | Reusing simple ISL two-way range as TWSTFT |
| TWSTFT carrier | Relay LO/range-rate/counter noise modeled | Four carrier readings with ignored LO uncertainty |

## Implementation checklist for each measurement builder

- [ ] validates config combinations,
- [ ] builds primitive event metadata,
- [ ] computes truth `z`, model `h`, Jacobian `H`, covariance `R`,
- [ ] declares units,
- [ ] declares state-column ownership,
- [ ] includes correction-component breakdown,
- [ ] includes covariance policy,
- [ ] has finite-difference Jacobian audit,
- [ ] has report summary fields,
- [ ] fails safely when unsupported corrections are requested.
