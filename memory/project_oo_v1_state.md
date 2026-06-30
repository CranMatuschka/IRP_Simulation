---
name: project-oo-v1-state
description: Current state of GEO EKF reverse-GNSS simulation in oo_v1 on feature/oo-reverse-gnss-v1
metadata:
  type: project
---

Branch: feature/oo-reverse-gnss-v1
Latest commit: 520e239 (Stage 7A.1: fix stale test T4 and add integration test suite)

**Why:** IRP research simulation for reverse-GNSS (tower→GEO), implementing OO EKF in MATLAB.

**How to apply:** Check this memory when resuming work to know current stage and pending issues.

## Completed stages
- Stage 1–5: core physics, EKF, carrier, dual-frequency IF, ZWD, PCV, observability
- Stage 6: carrier/product consistency, ZWD config, PCV semantics, observability, LaTeX report
- Stage 7A: ionosphere mapping (simpleSecant/thinShell), carrier H FD, tower-clock product semantics,
  transmit-time metadata, PCV tests, config/doc cleanup, observability nIFCodeRows, validation tests
- Stage 7A.1: runtime integration fixes — see below

## Stage 7A.1 fixes (commits 0721698, a96e337, 520e239)
1. ErrorChain.ionosphere_: now uses config-driven MappingFunctions.ionosphere() not hardcoded 1/sin(el)
2. correctedPseudorange: added optional t_rx_s arg; passes to LightTimeSolver so t_tx_s is absolute
3. MeasurementModel h-loop: passes t_s to correctedPseudorange for correct transmit-time clock eval
4. pcvCorrection_: pcvModel explicitly set bypasses legacy antennaPCV.(side).enable gate
5. computeCarrierEkfRows_: throws MeasurementModel:carrierIFNotImplemented if carrierCombinationMode=ionosphereFree
6. needsFiniteDiffH_: now returns true for iterative light-time
7. measType_perRow: IF rows labeled 'ifCode' (was 'code') so nIFCodeRows correct in diagnostics
8. test_stage6_tower_clock_product_struct T4: updated for truthHistoryProduct→truthProduct rename

## 63 test files in oo_v1/tests/
MATLAB CLI not available in this environment — tests written but not runtime-verified.

## Known pre-existing failures (6, predating Stage 7A)
test_atmosphere_mismatch, test_noise_scaling, test_tower_clock_effect,
test_attitude_lever_arm_observability, test_stage1_physics_disabled_unchanged, test_stage2_doppler

## Sweep scripts
- `run_oo_reverse_gnss_ladder_sweep_real_report_fixed.m` — original 60-case Phase A/B/C sweep (untouched)
- `run_oo_reverse_gnss_ladder_sweep_progressive_report.m` — new 46-case B/Z/E/U progressive sweep (2026-06-30)
  - Group B(2): identity-zero + convergence baselines
  - Group Z(16): cumulative zero-sigma infrastructure ladder (starts from B00)
  - Group E(16): cumulative physical error stack (starts from B01 = init:pos1km_vel0p5)
  - Group U(12): cumulative EKF-use stack (starts from E16)
  - Patch-based case definition via applyPatch_ dispatcher
  - Strict absolute baseline: all clocks, sigmas, errors, init errors = 0
  - Config audit printed per case; identity-zero assertions for B00 and Z cases
  - Writes sweep_acceptance_summary.txt; output dir: SweepProgressive_YYYYMMDD_HHMMSS/

## NOT implemented
Phase wind-up, Klobuchar, IONEX, SP3/CLK, integer ambiguity resolution, L2 carrier EKF,
carrier IF, azimuth-dependent PCV, ANTEX, VMF3/GPT3/ERA5
