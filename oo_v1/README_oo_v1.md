# oo_v1 — Object-Oriented Reverse-GNSS Simulation

## Default scenario

The default run uses **GEO-1** as the space asset and five ground towers taken from the original `config/SimulationConfig.m`:

| Component | Parameter | Value |
|-----------|-----------|-------|
| Space asset | Name | GEO-1 |
| | Latitude | 0.0 deg |
| | Longitude | 23.0 deg |
| | Altitude | 35 786 000 m (GEO) |
| Tower 1 | Tenerife | lat 28.3, lon -16.5, alt 0 m |
| Tower 2 | Stockholm | lat 59.3, lon 18.1, alt 0 m |
| Tower 3 | Hartebeesthoek | lat -25.9, lon 27.7, alt 0 m |
| Tower 4 | Bengaluru | lat 13.0, lon 77.6, alt 0 m |
| Tower 5 | Libreville | lat 0.0355, lon -9.4496, alt 0 m |

The GEO satellite is stationary in ECEF. No orbit propagator is used for the default scenario.

---

## Simple PDF report

Run the default simulation and it automatically saves a PDF containing all diagnostic figures:

```matlab
cd oo_v1
run_oo_reverse_gnss
```

After the run completes, the report is saved to:

```
oo_v1/output/reverse_gnss_simple_report.pdf
```

The PDF is tracked by git. PNGs are not committed by default.

Implementation: `+revgnss/ReportWriter.m`. Uses `exportgraphics` with `Append` on MATLAB R2020b+; falls back to `print` on older releases.

To generate a report from your own simulation:
```matlab
sim.plot();
sim.writeReport();
```

---

## Kalman convergence expectations

The default scenario is a **position and clock convergence validation**. Do not judge performance solely from final position error.

Key points:

- Pseudorange from 5 towers primarily observes **position (3 states)** and **receiver clock bias (1 state)**.
- With 5 measurements and 14 states, the EKF is underdetermined per epoch but converges recursively over time.
- **Attitude is weakly observable** only through the receiver antenna lever arm (`receiverLeverArm_body_m = [1.0; 0.5; 0.2]`). Attitude convergence is slow; position and clock converge first.
- **Clock-mode errors and common-mode atmospheric delays** can be absorbed by the receiver clock bias state. This is physically correct but means position improvement from atmosphere modelling is limited; innovation RMS improvement is more visible.
- The default case has all errors off (no atmosphere, no hardware delay, no multipath) and deterministic tower clocks with `perfectCorrection` mode. This is the easiest convergence case.
- Expected behaviour: position error should decrease significantly within 600–1800 s. Final position error depends on measurement noise and geometry.
- NIS should be approximately equal to the number of visible measurements (5) once converged. Large NIS indicates under-modelled noise or filter divergence.

---

## 1. Purpose

`oo_v1` is a clean, object-oriented MATLAB implementation of a **reverse-GNSS** simulation. N ground towers transmit GNSS-like ranging signals upward to a space asset (LEO satellite). The space asset carries a receiver and estimates its position, velocity, attitude, angular velocity, and receiver clock state via an Extended Kalman Filter (EKF) processing pseudorange measurements from the towers.

This implementation lives **entirely within** the `oo_v1/` folder and does not modify the existing advanced simulation framework.

---

## 2. Why Object-Oriented Design

- Each physical entity (space asset, ground tower, clock, orbit) has its own `classdef` class with clear state and methods.
- Error sources are composable and independently configurable for truth vs. model.
- The EKF, measurement model, and simulation loop are separated, making each unit testable independently.
- The same `ClockModel` class is shared by both tower and space asset clocks, ensuring consistent physics and making clock-type comparisons straightforward.

---

## 3. Class Architecture

```
+revgnss/
  Constants.m          Physical constants (c, GM, Earth radius, etc.)
  ClockModel.m         Oscillator clock — five power-law noise types
  AttitudeKinematics.m ZYX Euler kinematics utilities (static)
  OrbitPropagator.m    Simple circular LEO orbit (ECI -> ECEF)
  GeometryUtils.m      ECEF/geodetic conversions, elevation angle (static)
  GroundTower.m        Ground transmitter with ClockModel
  SpaceAsset.m         Orbiting receiver with attitude and ClockModel (optional lever-arm override)
  ErrorChain.m         Per-source pseudorange error computation
  RangeCorrections.m   Sagnac, Shapiro, and antenna PCV corrections
  MeasurementModel.m   Truth/predicted pseudorange + Jacobian H (analytic or finite-diff)
  ReverseGNSSEKF.m     14+ state EKF with Joseph stabilised update
  ReverseGNSSSimulation.m  Simulation orchestrator (owns all objects)
  ConfigFactory.m      Config builders: defaultConfig, multiAntennaAttitudeConfig, etc.
  ScenarioFactory.m    Instantiates objects from a config struct
  validateConfig.m     Startup config validation
  Plotter.m            17-figure diagnostic plot suite
  Diagnostics.m        Per-epoch truth/estimate/error log
  ReportWriter.m       Saves figure array to multi-page PDF
```

---

## 4. State Vector

Base dimension: **14**

| Index | Symbol | Description | Unit |
|-------|--------|-------------|------|
| 1–3 | r | Position (ECEF) | m |
| 4–6 | v | Velocity (ECEF) | m/s |
| 7–9 | roll, pitch, yaw | Euler angles ZYX | rad |
| 10–12 | ω_x, ω_y, ω_z | Angular velocity (body frame) | rad/s |
| 13 | b_rx | Receiver clock bias | m |
| 14 | ḃ_rx | Receiver clock drift | m/s |

Optional extension with `cfg.estimator.estimateTowerClocks = true`:

| 15+2(i−1) | b_tower_i | Tower i clock bias | m |
| 16+2(i−1) | ḃ_tower_i | Tower i clock drift | m/s |

Total with N towers estimated: **14 + 2·N**

---

## 5. Measurement Equation

**Antenna phase center:**
```
r_ant_ecef = r_cm_ecef + C_ecef_body(roll,pitch,yaw) · leverArm_body
```
where `C_ecef_body = Rz(yaw)·Ry(pitch)·Rx(roll)` (ZYX convention).

**Truth pseudorange:**
```
z_i = ||r_ant_true - r_tower_i||
    + b_rx_true
    - b_tower_true_i
    + d_trop_truth_i
    + d_iono_truth_i
    + d_hw_truth_i
    + d_mp_truth_i
    + ε_code_i
```

**Predicted pseudorange:**
```
h_i = ||r_ant_est - r_tower_i||
    + b_rx_est
    - b_tower_model_or_est_i
    + d_trop_model_i
    + d_iono_model_i
    + d_hw_model_i
```

**Note:** No integer ambiguity term in pseudorange. Integer ambiguity belongs to carrier phase only (future work).

---

## 6. ClockModel Design

`ClockModel` models a physical oscillator using the standard power-law frequency fluctuation PSD:

```
S_y(f) = h₂·f² + h₁·f + h₀ + h₋₁/f + h₋₂/f²
```

| Term | Noise type | ADEV slope |
|------|-----------|------------|
| h₂ | White phase modulation (WPM) | τ⁻¹ |
| h₁ | Flicker phase modulation (FPM) | τ⁻¹ |
| h₀ | White frequency modulation (WFM) | τ⁻¹/² |
| h₋₁ | Flicker frequency modulation (FFEM) | τ⁰ |
| h₋₂ | Random-walk FM (RWFM) | τ⁺¹/² |

### Time-domain propagation

- **WFM (h₀)** and **RWFM (h₋₂):** Direct discrete-time propagation. WFM adds white Gaussian noise to fractional frequency each step; RWFM adds a random walk to the frequency drift.
- **WPM (h₂), FPM (h₁), FFM (h₋₁):** Synthesised via FFT spectral shaping over the full simulation time span (`precomputeNoise()`). White Gaussian complex noise is shaped by √S_y(f) in the frequency domain and transformed back to a time-domain sequence. This is the spectral synthesis (Kasdin-Walter) approach. It is an approximation: the sequence length and sample rate limit the achievable noise bandwidth.

### State representations

| Symbol | Meaning | Unit |
|--------|---------|------|
| `bias_s` | Clock time bias x | s |
| `fracFreq` | Fractional frequency error y | — |
| `b_m` = c·x | Range-domain bias | m |
| `ḃ_mps` = c·y | Range-domain drift | m/s |

---

## 7. Allan Deviation vs Time-Domain Simulation

Allan deviation characterises oscillator stability; it does **not** define the time-domain process. `ClockModel` uses the h coefficients to:

1. Drive a stochastic time-domain simulation (used by truth propagation).
2. Derive an approximate 2×2 process noise matrix Q for the EKF (`getProcessNoiseQ`), based on WFM + RWFM dominant terms.
3. Compute the theoretical ADEV curve for validation (`theoreticalAllanDeviation`).

Empirical ADEV computed from a simulated clock history should qualitatively match the theoretical curve; the test `test_clock_allan_model.m` checks this.

---

## 8. Tower and Space Asset Clocks

Both `GroundTower` and `SpaceAsset` hold a `revgnss.ClockModel` instance. They are configured independently but use the same class, enabling:

- Identical physics for all oscillator types.
- Easy comparison experiments (e.g., Experiment E).
- EKF process noise for tower clock states uses the same `getProcessNoiseQ` method.

### Simple config fields for tower/receiver count and clock factorisation

| Field | Location | Description | Default |
|-------|----------|-------------|---------|
| `cfg.scenario.nTowers` | top-level | Number of ground towers to instantiate | `5` |
| `cfg.scenario.nReceivers` | top-level | Number of receiver antennas on the asset | `1` |
| `cfg.towers(k).clockName` | per tower | Name prefix (used in `clock.name`) | `'GroundClock'` |
| `cfg.towers(k).clockType` | per tower | Template: TCXO / OCXO / Rubidium / AtomicLike | `'OCXO'` |
| `cfg.towers(k).clockFactors` | per tower | Amplitude and role scale factors (struct) | all `1` |
| `cfg.asset.clockName` | asset | Receiver clock name prefix | `'SpaceReceiverClock'` |
| `cfg.asset.clockType` | asset | Receiver clock template | `'OCXO'` |
| `cfg.asset.clockFactors` | asset | Per-instance amplitude and role scale factors | all `1` |

`clockFactors` sub-fields (all default to `1`):
`biasFactor`, `freqFactor`, `noiseFactor`, `roleNoiseFactor`,
`h2Factor`, `h1Factor`, `h0Factor`, `hMinus1Factor`, `hMinus2Factor`.

`roleNoiseFactor` separates role-based scaling (tower vs receiver, populated from
`cfg.clockScaling.towerNoiseFactor` / `.receiverNoiseFactor`) from per-instance tuning
(`noiseFactor`). Combined noise amplitude applied inside `makeClockConfig`:
```
noiseAmp = globalNoiseFactor × noiseFactor × roleNoiseFactor
h-coefficients scale as noiseAmp²  (PSD units)
```

When `cfg.scenario.nReceivers > 1`, lever arms default to the first `nReceivers` columns
of a ±1 m cross pattern: `[1 -1 0 0; 0 0 1 -1; 0.2 0.2 -0.2 -0.2]`.

`clockDiversityConfig()` demonstrates the pattern: override only `clockType` and specific
`clockFactors` fields per tower, then call `makeClockConfig` to regenerate `cfg.towers(k).clock`.

---

## 9. Attitude Modeling

**Convention:** ZYX (3-2-1) Euler angles [roll; pitch; yaw].

```
C_ecef_body = Rz(yaw) · Ry(pitch) · Rx(roll)
```

**Propagation:** Euler kinematic equation `ė = T(e) · ω_body`.

**Singularity:** The kinematic equation is singular at pitch = ±90°. For v1, this is acceptable for typical LEO attitude profiles. A quaternion representation removes the singularity and should be adopted in a future version.

---

## 10. Attitude Observability from Pseudorange

Pseudorange to a single receiver antenna only observes attitude **through the lever arm**:

```
r_ant = r_cm + C(euler) · leverArm
d rho / d euler  ≠ 0   only when leverArm ≠ 0
```

If `leverArm = [0;0;0]`, the antenna position does not depend on attitude, the attitude columns of H are all zero, and **attitude states are unobservable from pseudorange alone**.

Even with a nonzero lever arm, pseudorange-based attitude observability is **weak** and highly geometry-dependent (requires diverse tower directions relative to the lever arm direction). In practice, attitude should be estimated from an IMU or star tracker, with pseudorange providing supplementary constraints.

Test `test_attitude_lever_arm_observability.m` verifies this numerically.

---

## 11. Error-Chain Concept

`ErrorChain` computes five error sources, each with **independent truth and model settings**:

| Source | Truth | Model |
|--------|-------|-------|
| Code noise | Random ε added to z | Contributes to R |
| Troposphere | Mapping-function zenith delay | Configurable zenith correction |
| Ionosphere | Mapping-function zenith delay (+ve for code) | Configurable correction |
| Hardware delay | Per-tower constant | Configurable per-tower correction |
| Multipath | Sinusoid + stochastic | Usually zero |

Tower and receiver clock errors are handled separately by `MeasurementModel` (not in ErrorChain) to avoid double-counting.

The truth-model residual for each source contributes to the innovation:
```
ν_i = z_i − h_i
     ≈ (truth errors − model errors) + EKF state error contribution
```

---

## 11b. Deterministic Effects (`cfg.effects`)

`cfg.effects` groups deterministic physical effects that are **separate from stochastic noise**. Each effect has independent `truth` and `model` toggles. `R` always contains only stochastic uncertainty.

| Effect | Fields | Default |
|--------|--------|---------|
| Tower survey error | `towerSurvey.sigmaENU_m`, `.seed`, `.truth.enable`, `.model.enable` | all off, σ = [1 1 3] cm |
| Antenna PCO (receiver) | `antennaPCO.receiverOffset_body_m`, `.truth.enable`, `.model.enable` | off, [0;0;0] |
| Antenna PCO (tower) | `antennaPCO.towerOffset_enu_m`, `.truth.enable`, `.model.enable` | off, [0;0;0] |
| Antenna PCV (toy) | `antennaPCV.amplitude_m`, `.modelType='toyAzEl'`, `.truth.enable`, `.model.enable` | off, 5 mm |
| Correlated noise | `correlatedNoise.commonModeSigma_m`, `.sameTowerSigma_m`, `.independentSigma_m`, `.seed`, `.enable` | off, all 0 |

**Tower survey errors** are drawn once in `finalizeConfig` (seeded `RandStream`) and stored in `cfg.towers(k).surveyError_ENU_m`. `getTowerPosition_` returns the perturbed position on-the-fly without mutating `tower.r_ecef_m`.

**Antenna PCO** shifts all receiver lever arms by `receiverOffset_body_m` (body frame) and the tower antenna phase centre by `towerOffset_enu_m` (ENU frame).

**Toy PCV** model: `dPCV = amplitude * cos(el)^2` — elevation-dependent, azimuth assumed zero. NOT calibrated ANTEX.

**Correlated noise** builds a full off-diagonal `R` matrix: common-mode (shared across all towers), per-tower (shared across all receivers of one tower), and independent draws.

**Finite-difference Jacobian** is triggered automatically when any of Sagnac, Shapiro, PCO, or PCV are enabled on the model side, or when `cfg.estimator.forceFiniteDifferenceH = true`. Tower survey does not require FD (the unit vector `u` is unaffected by fixed tower position).

---

## 12. How to Run

### Basic simulation (baseline)

```matlab
cd oo_v1
run_oo_reverse_gnss
```

Uses `defaultConfig()`: GEO-1, 5 towers, 1 receiver, all effects off. Saves PDF to `output/reverse_gnss_simple_report.pdf`.

### Effect toggle test file

```matlab
cd oo_v1
run_oo_effect_toggle_tests
```

Set `RUN_*` flags at the top to enable/disable individual test cases. Each case writes a separate PDF to `output/<caseName>.pdf` and figures to `output/figures/<caseName>/`. A summary table is printed at the end showing final position error, NIS, and prefit/postfit RMS.

### Config presets

| Preset | Description |
|--------|-------------|
| `defaultConfig()` | Clean baseline: 5 towers, 1 receiver, all physics off, deterministic clocks |
| `multiAntennaAttitudeConfig()` | 4-antenna cross pattern; `estimateAttitudeFromPseudorange=true`; 20 max measurements/epoch |
| `realisticPseudorangeConfig()` | Sagnac + Shapiro truth+model both enabled; corrections mostly cancel |
| `clockDiversityConfig()` | Each tower uses a different clock type (OCXO/TCXO/Rubidium/AtomicLike) |

### Multi-receiver setup

`cfg.scenario.nReceivers` controls how many antenna phase centres the asset has:
- 1 receiver: single antenna, zero lever arm, attitude estimation off.
- 2–4 receivers: auto-filled from a ±1 m cross pattern.
- > 4 receivers: **requires** custom `cfg.asset.receiverLeverArms_body_m` (3 × N matrix).

```matlab
cfg.scenario.nReceivers = 6;
cfg.asset.receiverLeverArms_body_m = [  % 3 × 6 custom pattern
    1, -1,  0,  0,  0.5, -0.5; ...
    0,  0,  1, -1,  0.5, -0.5; ...
    0.2, 0.2, -0.2, -0.2, 0, 0 ];
```

### Truth/model effect toggles

Every new deterministic effect (tower survey, PCO, PCV, Sagnac, Shapiro) has separate truth/model toggles:

```matlab
% Mismatch: truth sees survey error, model assumes nominal positions
cfg.effects.towerSurvey.truth.enable = true;
cfg.effects.towerSurvey.model.enable = false;

% Matched: both see same error, mostly cancels in innovation
cfg.effects.towerSurvey.truth.enable = true;
cfg.effects.towerSurvey.model.enable = true;
```

`R` contains only stochastic uncertainty. Deterministic mismatches appear as innovation bias, not inflated R.

### Carrier phase

Carrier phase is a **diagnostic observable only**. It is never used in the EKF unless float ambiguity states are implemented.

```matlab
cfg.measurements.carrierPhase.enable   = true;
cfg.measurements.carrierPhase.useInEKF = false;   % diagnostic only
```

Setting `useInEKF=true` without `estimateCarrierAmbiguities=true` throws a clear error. No fake integer ambiguity resolution is done.

### Unit and integration tests

```matlab
cd oo_v1/tests
test_ideal_convergence                   % position + clock converge from cold start
test_noise_scaling                       % NIS scales correctly with measurement sigma
test_stage0_default_config               % default run completes, NIS reasonable
test_stage0_multi_antenna                % 4-receiver cross pattern gives 20 meas/epoch
test_stage1_realistic_pseudorange        % Sagnac+Shapiro matched: near-baseline NIS
test_stage2_doppler                      % Doppler stacked in z; postfit split correct
test_stage3_carrier_phase                % carrier stored; useInEKF=false enforced
test_atmosphere_mismatch                 % trop/iono mismatch shows innovation bias
test_attitude_lever_arm_observability    % zero lever arm → unobservable attitude
test_clock_allan_model                   % empirical ADEV matches theoretical slope
```

---

## 13. How to Interpret Plots

| Plot | What to look for |
|------|-----------------|
| Position error norm | Convergence after initial transient; should decrease and stabilise |
| ECEF x/y/z error | Individual axis convergence |
| Clock bias [m] / [ns] | Estimate tracking truth; offset = unmodelled bias |
| Fractional frequency | Should be near zero after convergence |
| Attitude | Convergence quality depends on lever arm and geometry |
| Attitude error | Norm; expect slow convergence with pseudorange only |
| Prefit innovation RMS | Reflects measurement noise + unmodelled errors |
| Postfit residual RMS | Should be smaller than prefit; if larger, filter is diverging |
| NIS | Should be roughly equal to number of measurements M; large NIS indicates under-modelled noise or divergence |
| Visible towers | Depends on orbit geometry; should stay ≥ 4 for observability |
| σ_position vs error | Error should be within the 1σ bound most of the time |
| Allan deviation | Empirical should follow theoretical slope qualitatively |

---

## 14. Common-Mode / Clock-Absorbed Errors

Troposphere, ionosphere, and unmodelled hardware delays are **elevation-dependent but not angle-dependent** relative to the receiver. A common-mode bias across all towers can be partially absorbed by the receiver clock bias state, resulting in:
- Small position error improvement from atmosphere modelling.
- Significant innovation RMS improvement from atmosphere modelling.

This is physically correct — the EKF clock state acts as a catch-all for common-mode range biases. To separate them, multi-frequency measurements (for ionosphere) or external zenith delay estimates (for troposphere) are needed.

---

## 15. Current Limitations

| Limitation | Notes |
|-----------|-------|
| Carrier phase: diagnostic only | No float/integer ambiguity states; carrier stored but not used in EKF |
| No light-time iteration | One-way range used; Sagnac enabled via `cfg.physics.sagnac` toggles |
| Simple circular orbit | No J2, no drag, no SRP |
| Simple atmosphere | 1/sin(elev) mapping; no ERA5/VMF3/GPT3 (Stage 9 TODO) |
| Toy PCV only | `amplitude * cos(el)^2`; no ANTEX file support |
| Euler attitude | Gimbal-lock singularity at pitch = ±90° |
| No IMU | Attitude propagation is kinematic; no inertial aiding |
| No ambiguity resolution | LAMBDA/MLAMBDA deferred to future work |

---

## 16. Future Extensions

- Float ambiguity states for carrier phase in EKF (Stage 8 TODO)
- Integer ambiguity resolution (LAMBDA/MLAMBDA)
- Cycle slip detection and repair
- Light-time iteration (iterate range until Sagnac converges)
- J2 / high-fidelity orbit propagator (e.g. RK4 + gravity model)
- IMU aiding for attitude
- Quaternion attitude representation (removes singularity)
- ERA5/VMF3/GPT3 atmosphere models (Stage 9 TODO)
- ANTEX-calibrated PCV (replace toy elevation model)
- Real ephemeris / precise orbit/clock products

---

## 17. Measurement Model (Truth / Predicted Detail)

### Truth pseudorange
```
z_i = ||r_ant_true − r_tower_i||  (geometric range)
    + b_rx_true                    (receiver clock bias, metres)
    − b_tower_true_i               (tower clock bias, metres — TRUE clock)
    + ε_code_i                     (code noise, 1-σ from cfg.errors.codeNoiseSigma_m)
    + d_trop_truth_i               (tropospheric delay from truth model)
    + d_iono_truth_i               (ionospheric delay from truth model)
    + d_hw_truth_i                 (hardware delay from truth model)
    + d_mp_truth_i                 (multipath from truth model)
```

### Predicted pseudorange (for EKF innovation)
```
h_i = ||r_ant_est − r_tower_i||   (geometric range from estimated position + lever arm)
    + b_rx_est                     (receiver clock bias from EKF state)
    − b_tower_model_i              (tower clock correction — MODEL)
    + d_trop_model_i               (tropospheric model correction)
    + d_iono_model_i               (ionospheric model correction)
    + d_hw_model_i                 (hardware model correction)
```

### Innovation
```
ν_i = z_i − h_i
    ≈ (position error projected onto LOS)
    + (receiver clock bias error)
    − (tower clock correction error)
    + (unmodelled truth − model error residual)
    + code noise
```

### Antenna phase centre
```
r_ant_ecef = r_cm_ecef + C_ecef_body(roll, pitch, yaw) · leverArm_body
```
where `C_ecef_body = Rz(yaw) · Ry(pitch) · Rx(roll)` (ZYX convention).

The lever arm `receiverLeverArm_body_m` is typically `[1.0; 0.5; 0.2]` m in the default scenario. Setting it to zero removes attitude observability from pseudorange.

---

## 18. Truth / Model Separation

This design principle prevents noise from being drawn twice for the same measurement:

1. At the **start of each epoch**, `MeasurementModel.computeMeasurements()` generates all tower clock corrections in **one batch** `randn(M,1)` call and stores them in `errStruct.towerClockModel_m`.
2. These stored corrections are used to form both the truth measurement `z` and the predicted measurement `h`.
3. When `computePostfitResiduals_()` recomputes `h` after the EKF update (using the updated state), it **reuses** `errStruct.towerClockModel_m` — it does **not** call `randn` again.

This ensures postfit residuals are not corrupted by an independent second noise draw, which would inflate the residual RMS and make the filter appear inconsistent.

The `getTowerClockModel_()` method exists for standalone/test use only and is explicitly marked as calling `randn` — it must **not** be called in the main simulation loop for postfit computation.

### Tower clock modes
| Mode | b_tower_model | Notes |
|------|--------------|-------|
| `none` | 0 | No correction applied (worst case) |
| `perfectCorrection` | `b_tower_true` | Ideal correction (default) |
| `noisyCorrection` | `b_tower_true + σ·n` | Realistic; σ from `cfg.estimator.towerClockCorrectionSigma_m` |

---

## 19. Clock Model — Scientific Design

### Power spectral density
The five power-law noise terms follow IEEE Std 1139-2008:
```
S_y(f) = h₂·f² + h₁·f¹ + h₀·f⁰ + h₋₁·f⁻¹ + h₋₂·f⁻²
```
| Symbol | Noise type | ADEV slope | State domain |
|--------|-----------|------------|-------------|
| h₂ | White PM (WPM) | τ⁻¹ | Precomputed (colored) |
| h₁ | Flicker PM (FPM) | τ⁻¹ | Precomputed (colored) |
| h₀ | White FM (WFM) | τ⁻¹/² | State (phase jump) |
| h₋₁ | Flicker FM (FFM) | τ⁰ | Precomputed (colored) |
| h₋₂ | Random-walk FM (RWFM) | τ⁺¹/² | State (freq drift) |

### State decomposition
`ClockModel` maintains a **2-state** EKF-compatible representation for WFM+RWFM:
```
state: [bias_s, fracFreq]   (time bias in seconds, fractional frequency)
```
plus a **separate** colored component (WPM + FPM + FFM) precomputed as an absolute time series:
```
coloredBias_s_current     — absolute colored bias at current epoch [s]
coloredFracFreq_current   — absolute colored fractional frequency at current epoch
```

Public accessors return the **total** (state + colored). State-only accessors (`getStateBiasSeconds`, `getStateFracFreq`) return the 2-state portion for EKF initialization.

### WFM propagation (CRITICAL)

**Incorrect (causes wrong ADEV slope):** Adding WFM noise to the `fracFreq` state makes it persistent — it integrates over time and produces a τ⁺¹/² ADEV slope (RWFM behaviour), not the correct τ⁻¹/² slope.

**Correct:** WFM is a direct **phase jump**:
```matlab
sigma_wfm_bias_s = sqrt(h.h0 * dt_s / 2);
n_bias_wfm = sigma_wfm_bias_s * randn;
new_bias_s = old_bias_s + dt_s * fracFreq + n_bias_wfm;  % NOT into fracFreq
```

### Colored noise precomputation
WPM, FPM, and FFM are synthesised via spectral shaping (Kasdin-Walter method) before simulation starts. The precomputed absolute time series is stored in `noiseBias_s_vec` / `noiseFracFreq_vec`.

**Advance-first indexing:** At each step, the next index is read before incrementing the counter, so the first step reads the value at `t = dt` (end of step) not `t = 0`:
```matlab
nextIdx = sampleIndex + 1;
coloredBias_s_current = noiseBias_s_vec(nextIdx);
sampleIndex = nextIdx;
```

### EKF process noise Q
The 2×2 Brown-Hwang process noise matrix covers WFM + RWFM, with a conservative FFM additive term:
```
Q_11 = (h₀/2 + 2·ln2·h₋₁)·dt + (2/3)·π²·h₋₂·dt³
Q_12 = Q_21 = π²·h₋₂·dt²
Q_22 = 2·π²·h₋₂·dt
```
The `2·ln2·h₋₁` term conservatively captures FFM's white contribution to phase noise at `τ = dt`.

### Clock templates (per `ConfigFactory.makeClockConfig`)
| Template | h₀ | h₋₁ | h₋₂ | Typical use |
|----------|-----|------|------|-------------|
| TCXO | 9e-22 | 2e-21 | 1e-20 | Low-grade tower |
| OCXO | 2e-25 | 7e-27 | 2e-29 | Standard tower |
| RUBIDIUM | 1e-22 | 4.5e-24 | 3e-28 | Mid-grade tower |
| ATOMICLIKE | 1e-26 | 1e-28 | 1e-30 | High-grade reference |
| CUSTOM | user-supplied | | | |

h-coefficients scale as **amplitude²** (PSD units). A noise factor of `f` scales h as `f²`, preserving the physical interpretation of h as a spectral density level.

### Allan deviation vs Allan variance
Throughout this codebase:
- **Allan deviation** = σ_y(τ)  (square root of Allan variance)
- **Allan variance** = σ_y²(τ)

These are never conflated. Plot titles, axis labels, and getter names use the correct term for each quantity.

---

## 20. Plotting Behaviour

### Figure visibility
Figures are **hidden by default** (`cfg.plots.showFigures = false`). This prevents 16 windows opening during automated runs while still saving all outputs:

```matlab
cfg.plots.showFigures           = false;  % create figures with Visible='off'
cfg.plots.saveIndividualFigures = true;   % save each figure as .png + .fig
cfg.plots.savePdf               = true;   % save all figures into one PDF
cfg.plots.closeAfterSave        = false;  % keep handles valid for further use
```

To display figures interactively:
```matlab
cfg.plots.showFigures = true;
```

### Figure handle flow
`Plotter.plotAll()` returns an array of figure handles. These are passed explicitly to `ReportWriter.write()`:
```matlab
figHandles = sim.plot();          % returns handles, does NOT use findobj
sim.writeReport(figHandles);      % PDF uses the passed handles only
```
Or in one call:
```matlab
sim.plotAndReport();
```

`ReportWriter` does **not** rely on `findobj` when handles are provided. If handles are empty it falls back to `findobj` with a warning.

### 16 standard figures (ordered)
| # | Filename stem | Content |
|---|--------------|---------|
| 01 | `position_error_xyz` | ECEF x/y/z position error (3 subplots) |
| 02 | `position_error_norm` | Position error norm |
| 03 | `attitude_error_components` | Roll/pitch/yaw error (3 subplots) |
| 04 | `attitude_error_norm` | Attitude error norm |
| 05 | `rx_clock_bias` | Clock bias [m] + error [m] (2 subplots) |
| 06 | `rx_clock_drift` | Fractional frequency truth vs est + drift error |
| 07 | `prefit_innovation_rms` | Prefit innovation RMS per epoch |
| 08 | `postfit_residual_rms` | Postfit residual RMS per epoch |
| 09 | `NIS` | Normalised Innovation Squared |
| 10 | `visible_towers` | Visible tower count |
| 11 | `per_source_error_rms` | Code / trop / iono / hw / multipath RMS |
| 12 | `rx_allan_deviation` | Receiver σ_y(τ) theoretical + empirical |
| 13 | `rx_allan_variance` | Receiver σ_y²(τ) theoretical + empirical |
| 14 | `tower_allan_deviation` | All towers σ_y(τ) on one axes |
| 15 | `tower_clock_bias` | Per-tower clock bias histories |
| 16 | `tower_clock_drift` | Per-tower fractional frequency histories |

Saved to `oo_v1/output/figures/` as `<NN>_<name>.png` and `<NN>_<name>.fig`.

For deterministic clocks (zero stochastic noise), the Allan plots annotate: *"Empirical σ_y(τ) is zero (deterministic clock)"*

---

## 21. Kalman Filter Limitations and Position-Clock-Only Mode

### When to use `positionClockOnlyConfig`
Use `revgnss.ConfigFactory.positionClockOnlyConfig()` when:
- The lever arm is zero (or very small), making attitude unobservable from pseudorange.
- You want to validate position + clock convergence without attitude noise masking the result.
- Running quick tests that don't need attitude estimation.

This config sets:
- `leverArm = [0; 0; 0]` (antenna at centre of mass)
- `P0_euler_rad = 1e-12` (near-zero initial attitude uncertainty)
- `sigma_angAccel = 1e-15` (near-zero angular acceleration process noise)
- `estimateAttitude = false`, `estimateAngularRate = false`

When `estimateAttitude = false`, the EKF still carries the attitude states but sets their Q contribution to `~0`, effectively freezing them. The state dimension is unchanged for code simplicity.

### EKF consistency checks
| Metric | Good | Potential issue |
|--------|------|----------------|
| NIS ≈ M (visible towers) | Consistent filter | — |
| NIS >> M | Under-modelled noise | Increase R or Q |
| NIS << M | Over-modelled noise | Decrease R or Q |
| Postfit RMS < Prefit RMS | Filter is updating usefully | — |
| Attitude Jacobian norm ≈ 0 | Zero lever arm or poor geometry | Set leverArm ≠ 0 or use positionClockOnlyConfig |
| Condition number S > 1e12 | Numerical ill-conditioning | Check R and H for near-singular cases |

### Angular cross-term Q
The angular process noise block includes an off-diagonal cross term:
```
Q_euler_omega = σ²_angAccel · dt² / 2
```
This accounts for the correlation between integrated attitude error and angular rate noise over a timestep. Without it, the EKF can become overconfident in attitude shortly after update.

### Finite-difference F matrix (Euler-Euler block)
The transition matrix F uses numerical (central-difference) differentiation of the Euler kinematic equation with respect to the Euler angles:
```matlab
F(euler_idx, euler_idx(ai)) = (eul_new(eul+ε) − eul_new(eul−ε)) / (2ε)
```
with `ε = 1e-7 rad`. This avoids analytically differentiating the T(e,ω) matrix and is correct when Euler angles change slowly (GEO scenario).
