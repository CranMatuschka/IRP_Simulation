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
  SpaceAsset.m         Orbiting receiver with attitude and ClockModel
  ErrorChain.m         Per-source pseudorange error computation
  MeasurementModel.m   Truth/predicted pseudorange + Jacobian H
  ReverseGNSSEKF.m     14+ state EKF with Joseph stabilised update
  ReverseGNSSSimulation.m  Simulation orchestrator (owns all objects)
  ConfigFactory.m      Default and experiment configuration builders
  ScenarioFactory.m    Instantiates objects from a config struct
  validateConfig.m     Startup config validation
  Plotter.m            15-category diagnostic plot suite
  Diagnostics.m        Per-epoch truth/estimate/error log
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

## 12. How to Run

### Basic simulation

```matlab
cd oo_v1
run_oo_reverse_gnss
```

This runs a 3600-second (1 hour) GEO-1 scenario with 5 towers, plots all diagnostics, and saves a PDF report to `oo_v1/output/reverse_gnss_simple_report.pdf`.

### All experiments

```matlab
cd oo_v1
run_oo_experiments
```

Prints a comparison table (position RMS, innovation RMS, NIS, etc.) for Experiments A–G.

### Individual test

```matlab
cd oo_v1/tests
test_ideal_convergence
```

Or run all tests:

```matlab
cd oo_v1/tests
test_ideal_convergence
test_noise_scaling
test_tower_clock_effect
test_clock_allan_model
test_attitude_lever_arm_observability
test_atmosphere_mismatch
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
| No carrier phase | No integer ambiguity states; pseudorange only |
| No light-time iteration | One-way range used; Sagnac effect ignored |
| No Sagnac correction | Can cause dm-level errors in LEO |
| Simple circular orbit | No J2, no drag, no SRP |
| Simple atmosphere | 1/sin(elev) mapping; no troposphere/ionosphere model |
| Diagonal R only | No correlated or common-mode measurement covariance |
| Euler attitude | Gimbal-lock singularity at pitch = ±90° |
| No IMU | Attitude propagation is kinematic; no inertial aiding |
| No cycle slips | Carrier phase not implemented |

---

## 16. Future Extensions

- Carrier phase measurements with integer ambiguity states
- Cycle slip detection and repair
- Sagnac and relativistic corrections
- Light-time iteration
- J2 / high-fidelity orbit propagator (e.g. RK4 + gravity model)
- IMU aiding for attitude
- Quaternion attitude representation (removes singularity)
- Multiple receiver antennas (baseline vector for attitude)
- Correlated measurement covariance (common-mode errors)
- Tower clock estimation enabled by default for advanced scenarios
- Ambiguity resolution (LAMBDA/MLAMBDA)
- Real ephemeris / precise orbit/clock products
