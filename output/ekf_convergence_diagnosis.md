# EKF Convergence Diagnosis

## Executive summary

Investigation in progress. All simulations in this pass use 3600 s.

## Commits since 2026-06-15 16:09

e4a84e4 (HEAD -> feature/oo-reverse-gnss-v1, origin/feature/oo-reverse-gnss-v1) triage analyser stage
680d9b8 Stage 15.0: Troposphere architecture and ZWD validation
632204b Stage 14.1: carrier-slip reset semantics and full-feature report smoke
d814d71 Stage 14.0: carrier phase robustness — cycle-slip detection and float ambiguity reset
ad1c899 Stage 13.0: dual-frequency and ionosphere-capable measurement architecture
a7772c6 Stage 12.1: T-P12m report-section test + Diagnostics empty-log guards
bc8731d Stage 12A.2: decompose MeasurementModel — MeasurementModelUtils + 3 builders
d242639 Stage 12A Step 6: Extract stack metadata → MeasurementStackMetadata
930201d Stage 12A Step 5: extract Jacobian into CodeJacobianBuilder
9c9c95e Stage 12A Step 4: extract pseudorange builder into CodeMeasurementBuilder
d3af0ab Stage 12A Step 3: extract tower clock corrections into TowerClockCorrectionProvider
6ab6def Stage 12A Step 2: extract carrier EKF rows into CarrierMeasurementBuilder
db5af4d Stage 12A Step 1: extract Doppler into DopplerMeasurementBuilder
fbc4df1 Stage 12.0: receiver hardware-delay and observable bias architecture
9d695ff Stage 11.0: per-tower L1 transmitter code hardware-delay states with identifiability guards
712d23b Stage 10.0: windowed clock-subspace observability Gramian
f3705f5 Stage 9.0: tower-clock EKF gauge — fixReferenceTower and meanGroundClockGauge
07e207f Stage 8.0: clock gauge, per-type NIS/NEES, Doppler EKF tests, report updates
cd00fba Stage 7B.4 fix: ClockExact LaTeX escaping and column spec bugs


These commits include clock-gauge diagnostics, transmitter/receiver bias architecture, measurement-model decomposition, dual-frequency/ionosphere architecture, carrier slip handling, ZWD architecture, and the prior triage stage. Changes most likely to affect convergence are Stage 14 carrier EKF/slip reset semantics, Stage 15 ZWD states/report config, Stage 13 dual-frequency ionosphere rows, Stage 11/12 nuisance bias guards, and Stage 8-10 clock/Doppler/gauge observability changes.

## Table of all toggle cases

| Case | Class | Final pos m | Final clock m | Clock drift mps | Postfit RMS m | Max NIS | PDOP | GDOP | States | Amb | ZWD | Conclusion |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| case_01_baseline_code_only | BOUNDED_WEAK_GEOMETRY | 12.551 | 12.414 | 0.00595065 | 0.252168 | 25.3 | 323 | 455 | 14 | 0 | 0 | case_01_baseline_code_only: BOUNDED_WEAK_GEOMETRY. final position 12.551 m, final clock 12.414 m, postfit 0.252 m, max NIS 25.3, PDOP 323, states 14, amb 0, ZWD 0. |

### case_01_baseline_code_only

- Toggles: code,L1,oneReceiver
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 55.240 m -> 12.551 m; RMS 12.130 m.
- Initial/final receiver clock bias error: 54.954 m -> 12.414 m; RMS 12.033 m.
- Final/RMS clock drift error: 0.00595065 m/s / 0.00964325 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.252168 m, position/postfit 49.7739, clock/postfit 49.228.
- NIS/NEES: median NIS 4.15419, max NIS 25.28, median NEES 0.670318, max NEES 4.18558.
- Covariance: min eig 9.03085e-09, cond 2.14406e+10, NaN 0, Inf 0.
- Rows/states: code 5, doppler 0, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_01_baseline_code_only: BOUNDED_WEAK_GEOMETRY. final position 12.551 m, final clock 12.414 m, postfit 0.252 m, max NIS 25.3, PDOP 323, states 14, amb 0, ZWD 0.

| case_02_code_plus_doppler | BOUNDED_WEAK_GEOMETRY | 11.568 | 11.427 | 0.00319776 | 0.333033 | 33.4 | 323 | 455 | 14 | 0 | 0 | case_02_code_plus_doppler: BOUNDED_WEAK_GEOMETRY. final position 11.568 m, final clock 11.427 m, postfit 0.333 m, max NIS 33.4, PDOP 323, states 14, amb 0, ZWD 0. |

### case_02_code_plus_doppler

- Toggles: code,doppler,L1,oneReceiver
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 55.240 m -> 11.568 m; RMS 12.301 m.
- Initial/final receiver clock bias error: 54.954 m -> 11.427 m; RMS 12.214 m.
- Final/RMS clock drift error: 0.00319776 m/s / 0.0079561 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.333033 m, position/postfit 34.7361, clock/postfit 34.3123.
- NIS/NEES: median NIS 8.32731, max NIS 33.4338, median NEES 0.896659, max NEES 4.43791.
- Covariance: min eig 9.03163e-09, cond 2.14286e+10, NaN 0, Inf 0.
- Rows/states: code 5, doppler 5, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_02_code_plus_doppler: BOUNDED_WEAK_GEOMETRY. final position 11.568 m, final clock 11.427 m, postfit 0.333 m, max NIS 33.4, PDOP 323, states 14, amb 0, ZWD 0.

| case_03_code_doppler_three_receivers | BOUNDED_WEAK_GEOMETRY | 5.287 | 5.259 | 0.0024163 | 0.346873 | 65.5 | 186 | 263 | 14 | 0 | 0 | case_03_code_doppler_three_receivers: BOUNDED_WEAK_GEOMETRY. final position 5.287 m, final clock 5.259 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 14, amb 0, ZWD 0. |

### case_03_code_doppler_three_receivers

- Toggles: code,doppler,L1,threeReceivers
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 128.277 m -> 5.287 m; RMS 9.388 m.
- Initial/final receiver clock bias error: 127.533 m -> 5.259 m; RMS 9.326 m.
- Final/RMS clock drift error: 0.0024163 m/s / 0.00748778 m/s.
- Attitude result if observable: 0.93237 deg.
- Residual/state consistency: postfit 0.346873 m, position/postfit 15.241, clock/postfit 15.1621.
- NIS/NEES: median NIS 28.1851, max NIS 65.5023, median NEES 0.603754, max NEES 6.61931.
- Covariance: min eig 5.86068e-16, cond 1.22707e+17, NaN 0, Inf 0.
- Rows/states: code 15, doppler 15, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_03_code_doppler_three_receivers: BOUNDED_WEAK_GEOMETRY. final position 5.287 m, final clock 5.259 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 14, amb 0, ZWD 0.

| case_04_carrier_diagnostic_three_receivers | BOUNDED_WEAK_GEOMETRY | 0.722 | 0.041 | 0.00130255 | 0.359003 | 64.3 | 186 | 263 | 14 | 0 | 0 | case_04_carrier_diagnostic_three_receivers: BOUNDED_WEAK_GEOMETRY. final position 0.722 m, final clock 0.041 m, postfit 0.359 m, max NIS 64.3, PDOP 186, states 14, amb 0, ZWD 0. |

### case_04_carrier_diagnostic_three_receivers

- Toggles: code,doppler,carrierDiagnostic,L1,threeReceivers
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 128.277 m -> 0.722 m; RMS 8.846 m.
- Initial/final receiver clock bias error: 127.533 m -> 0.041 m; RMS 8.786 m.
- Final/RMS clock drift error: 0.00130255 m/s / 0.00420183 m/s.
- Attitude result if observable: 2.7099 deg.
- Residual/state consistency: postfit 0.359003 m, position/postfit 2.01057, clock/postfit 0.113693.
- NIS/NEES: median NIS 28.1423, max NIS 64.3201, median NEES 0.57261, max NEES 5.68741.
- Covariance: min eig 5.81814e-16, cond 1.23712e+17, NaN 0, Inf 0.
- Rows/states: code 15, doppler 15, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_04_carrier_diagnostic_three_receivers: BOUNDED_WEAK_GEOMETRY. final position 0.722 m, final clock 0.041 m, postfit 0.359 m, max NIS 64.3, PDOP 186, states 14, amb 0, ZWD 0.

| case_05_carrier_ekf_one_receiver | BOUNDED_WEAK_GEOMETRY | 3.654 | 3.628 | 7.41788e-05 | 0.230436 | 39.5 | 323 | 455 | 19 | 5 | 0 | case_05_carrier_ekf_one_receiver: BOUNDED_WEAK_GEOMETRY. final position 3.654 m, final clock 3.628 m, postfit 0.230 m, max NIS 39.5, PDOP 323, states 19, amb 5, ZWD 0. |

### case_05_carrier_ekf_one_receiver

- Toggles: code,doppler,carrierEkfFloat,slipDetection,L1,oneReceiver
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 55.149 m -> 3.654 m; RMS 9.953 m.
- Initial/final receiver clock bias error: 54.863 m -> 3.628 m; RMS 9.887 m.
- Final/RMS clock drift error: 7.41788e-05 m/s / 0.00266424 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.230436 m, position/postfit 15.8574, clock/postfit 15.7426.
- NIS/NEES: median NIS 12.8433, max NIS 39.5355, median NEES 1.14717, max NEES 4.57733.
- Covariance: min eig 9.03085e-09, cond 6.3837e+09, NaN 0, Inf 0.
- Rows/states: code 5, doppler 5, carrier 5, states 19, ambiguity 5, ZWD 0.
- Main conclusion: case_05_carrier_ekf_one_receiver: BOUNDED_WEAK_GEOMETRY. final position 3.654 m, final clock 3.628 m, postfit 0.230 m, max NIS 39.5, PDOP 323, states 19, amb 5, ZWD 0.

| case_06_carrier_ekf_three_receivers | INVALID_CONFIGURATION | 305.820 | 303.892 | 9.56327e-06 | 0.342496 | 4.91e+09 | 186 | 263 | 19 | 5 | 0 | case_06_carrier_ekf_three_receivers: INVALID_CONFIGURATION. final position 305.820 m, final clock 303.892 m, postfit 0.342 m, max NIS 4.91e+09, PDOP 186, states 19, amb 5, ZWD 0. |

### case_06_carrier_ekf_three_receivers

- Toggles: code,doppler,carrierEkfFloat,slipDetection,L1,threeReceivers
- Classification: INVALID_CONFIGURATION
- Initial/final position error: 146.602 m -> 305.820 m; RMS 293.676 m.
- Initial/final receiver clock bias error: 145.600 m -> 303.892 m; RMS 291.812 m.
- Final/RMS clock drift error: 9.56327e-06 m/s / 0.00135642 m/s.
- Attitude result if observable: 5.22819 deg.
- Residual/state consistency: postfit 0.342496 m, position/postfit 892.916, clock/postfit 887.286.
- NIS/NEES: median NIS 4.91241e+09, max NIS 4.913e+09, median NEES 1608.31, max NEES 3212.76.
- Covariance: min eig 5.74051e-16, cond 3.38278e+16, NaN 0, Inf 0.
- Rows/states: code 15, doppler 15, carrier 15, states 19, ambiguity 5, ZWD 0.
- Main conclusion: case_06_carrier_ekf_three_receivers: INVALID_CONFIGURATION. final position 305.820 m, final clock 303.892 m, postfit 0.342 m, max NIS 4.91e+09, PDOP 186, states 19, amb 5, ZWD 0.

| case_07_zwd_code_doppler_three_receivers | BOUNDED_WEAK_GEOMETRY | 127.926 | 127.134 | 0.0099481 | 0.346891 | 65.5 | 186 | 263 | 19 | 0 | 5 | case_07_zwd_code_doppler_three_receivers: BOUNDED_WEAK_GEOMETRY. final position 127.926 m, final clock 127.134 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 19, amb 0, ZWD 5. |

### case_07_zwd_code_doppler_three_receivers

- Toggles: code,doppler,perTowerZwd,L1,threeReceivers
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 95.320 m -> 127.926 m; RMS 113.917 m.
- Initial/final receiver clock bias error: 94.787 m -> 127.134 m; RMS 113.200 m.
- Final/RMS clock drift error: 0.0099481 m/s / 0.00981575 m/s.
- Attitude result if observable: 0.994583 deg.
- Residual/state consistency: postfit 0.346891 m, position/postfit 368.778, clock/postfit 366.497.
- NIS/NEES: median NIS 28.1891, max NIS 65.4921, median NEES 1.09444, max NEES 2.93584.
- Covariance: min eig 7.40342e-16, cond 2.05792e+19, NaN 0, Inf 0.
- Rows/states: code 15, doppler 15, carrier 0, states 19, ambiguity 0, ZWD 5.
- Main conclusion: case_07_zwd_code_doppler_three_receivers: BOUNDED_WEAK_GEOMETRY. final position 127.926 m, final clock 127.134 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 19, amb 0, ZWD 5.

| case_08_full_supported_report_smoke | INVALID_CONFIGURATION | 18213.865 | 17813.756 | 0.070284 | 0.587144 | 3.61e+09 | 221 | 311 | 24 | 5 | 5 | case_08_full_supported_report_smoke: INVALID_CONFIGURATION. final position 18213.865 m, final clock 17813.756 m, postfit 0.587 m, max NIS 3.61e+09, PDOP 221, states 24, amb 5, ZWD 5. |

### case_08_full_supported_report_smoke

- Toggles: code,doppler,carrierEkfFloat,perTowerZwd,L1L2,threeReceivers
- Classification: INVALID_CONFIGURATION
- Initial/final position error: 281.419 m -> 18213.865 m; RMS 15307.595 m.
- Initial/final receiver clock bias error: 279.627 m -> 17813.756 m; RMS 15024.757 m.
- Final/RMS clock drift error: 0.070284 m/s / 0.060621 m/s.
- Attitude result if observable: 27.1297 deg.
- Residual/state consistency: postfit 0.587144 m, position/postfit 31021.1, clock/postfit 30339.7.
- NIS/NEES: median NIS 3.60778e+09, max NIS 3.60849e+09, median NEES 698581, max NEES 2.81557e+06.
- Covariance: min eig 7.50131e-16, cond 1.96952e+19, NaN 0, Inf 0.
- Rows/states: code 30, doppler 30, carrier 15, states 24, ambiguity 5, ZWD 5.
- Main conclusion: case_08_full_supported_report_smoke: INVALID_CONFIGURATION. final position 18213.865 m, final clock 17813.756 m, postfit 0.587 m, max NIS 3.61e+09, PDOP 221, states 24, amb 5, ZWD 5.

| case_H1_P0_consistent_code_doppler | BOUNDED_WEAK_GEOMETRY | 12.850 | 12.712 | 0.00623709 | 0.252156 | 25.4 | 323 | 455 | 14 | 0 | 0 | case_H1_P0_consistent_code_doppler: BOUNDED_WEAK_GEOMETRY. final position 12.850 m, final clock 12.712 m, postfit 0.252 m, max NIS 25.4, PDOP 323, states 14, amb 0, ZWD 0. |

### case_H1_P0_consistent_code_doppler

- Toggles: code,doppler,1rx,largerP0
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 25.049 m -> 12.850 m; RMS 15.497 m.
- Initial/final receiver clock bias error: 24.736 m -> 12.712 m; RMS 15.383 m.
- Final/RMS clock drift error: 0.00623709 m/s / 0.00998567 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.252156 m, position/postfit 50.9602, clock/postfit 50.4124.
- NIS/NEES: median NIS 4.15092, max NIS 25.3619, median NEES 0.701465, max NEES 4.17826.
- Covariance: min eig 2.85947e-08, cond 6.77971e+09, NaN 0, Inf 0.
- Rows/states: code 5, doppler 0, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_H1_P0_consistent_code_doppler: BOUNDED_WEAK_GEOMETRY. final position 12.850 m, final clock 12.712 m, postfit 0.252 m, max NIS 25.4, PDOP 323, states 14, amb 0, ZWD 0.

| case_H2_P0_inconsistent_code_doppler | BOUNDED_WEAK_GEOMETRY | 124.063 | 123.225 | 0.00963862 | 0.354462 | 1.44e+04 | 323 | 455 | 14 | 0 | 0 | case_H2_P0_inconsistent_code_doppler: BOUNDED_WEAK_GEOMETRY. final position 124.063 m, final clock 123.225 m, postfit 0.354 m, max NIS 1.44e+04, PDOP 323, states 14, amb 0, ZWD 0. |

### case_H2_P0_inconsistent_code_doppler

- Toggles: code,doppler,1rx,overconfidentP0
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 94.713 m -> 124.063 m; RMS 108.927 m.
- Initial/final receiver clock bias error: 91.743 m -> 123.225 m; RMS 108.232 m.
- Final/RMS clock drift error: 0.00963862 m/s / 0.00990532 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.354462 m, position/postfit 350.004, clock/postfit 347.639.
- NIS/NEES: median NIS 8.43487, max NIS 14426.5, median NEES 3448.48, max NEES 3641.79.
- Covariance: min eig 3.33965e-12, cond 9.74291e+11, NaN 0, Inf 0.
- Rows/states: code 5, doppler 5, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_H2_P0_inconsistent_code_doppler: BOUNDED_WEAK_GEOMETRY. final position 124.063 m, final clock 123.225 m, postfit 0.354 m, max NIS 1.44e+04, PDOP 323, states 14, amb 0, ZWD 0.

| case_K1_carrier_sigma_large | RUNTIME_ERROR | NaN | NaN | NaN | NaN | NaN | NaN | NaN | 0 | 0 | 0 | case_K1_carrier_sigma_large: RUNTIME_ERROR: Index exceeds the number of array elements. Index must not exceed 13. |

### case_K1_carrier_sigma_large

- Toggles: carrierEkf,1rx,sigma0p05m
- Classification: RUNTIME_ERROR
- First failure symptom: case_K1_carrier_sigma_large: RUNTIME_ERROR: Index exceeds the number of array elements. Index must not exceed 13.
- Likely implementation cause: runtime/config guard path.
- Next isolating case to run: previous passing toggle with one added feature.

| case_K2_carrier_sigma_medium | BOUNDED_WEAK_GEOMETRY | 3.654 | 3.628 | 7.41788e-05 | 0.230436 | 39.5 | 323 | 455 | 19 | 5 | 0 | case_K2_carrier_sigma_medium: BOUNDED_WEAK_GEOMETRY. final position 3.654 m, final clock 3.628 m, postfit 0.230 m, max NIS 39.5, PDOP 323, states 19, amb 5, ZWD 0. |

### case_K2_carrier_sigma_medium

- Toggles: carrierEkf,1rx,sigma0p005m
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 55.149 m -> 3.654 m; RMS 9.953 m.
- Initial/final receiver clock bias error: 54.863 m -> 3.628 m; RMS 9.887 m.
- Final/RMS clock drift error: 7.41788e-05 m/s / 0.00266424 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.230436 m, position/postfit 15.8574, clock/postfit 15.7426.
- NIS/NEES: median NIS 12.8433, max NIS 39.5355, median NEES 1.14717, max NEES 4.57733.
- Covariance: min eig 9.03085e-09, cond 6.3837e+09, NaN 0, Inf 0.
- Rows/states: code 5, doppler 5, carrier 5, states 19, ambiguity 5, ZWD 0.
- Main conclusion: case_K2_carrier_sigma_medium: BOUNDED_WEAK_GEOMETRY. final position 3.654 m, final clock 3.628 m, postfit 0.230 m, max NIS 39.5, PDOP 323, states 19, amb 5, ZWD 0.

| case_K3_carrier_sigma_small | BOUNDED_WEAK_GEOMETRY | 3.383 | 3.358 | 3.80825e-06 | 0.230399 | 35.8 | 323 | 455 | 19 | 5 | 0 | case_K3_carrier_sigma_small: BOUNDED_WEAK_GEOMETRY. final position 3.383 m, final clock 3.358 m, postfit 0.230 m, max NIS 35.8, PDOP 323, states 19, amb 5, ZWD 0. |

### case_K3_carrier_sigma_small

- Toggles: carrierEkf,1rx,sigma0p0005m
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 55.149 m -> 3.383 m; RMS 10.260 m.
- Initial/final receiver clock bias error: 54.863 m -> 3.358 m; RMS 10.192 m.
- Final/RMS clock drift error: 3.80825e-06 m/s / 0.000860915 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.230399 m, position/postfit 14.6812, clock/postfit 14.5727.
- NIS/NEES: median NIS 11.7862, max NIS 35.8331, median NEES 1.35453, max NEES 2.60256.
- Covariance: min eig 4.94141e-09, cond 1.16491e+10, NaN 0, Inf 0.
- Rows/states: code 5, doppler 5, carrier 5, states 19, ambiguity 5, ZWD 0.
- Main conclusion: case_K3_carrier_sigma_small: BOUNDED_WEAK_GEOMETRY. final position 3.383 m, final clock 3.358 m, postfit 0.230 m, max NIS 35.8, PDOP 323, states 19, amb 5, ZWD 0.

| case_L1_ambiguity_prior_large | BOUNDED_WEAK_GEOMETRY | 3.655 | 3.629 | 7.41809e-05 | 0.230436 | 39.5 | 323 | 455 | 19 | 5 | 0 | case_L1_ambiguity_prior_large: BOUNDED_WEAK_GEOMETRY. final position 3.655 m, final clock 3.629 m, postfit 0.230 m, max NIS 39.5, PDOP 323, states 19, amb 5, ZWD 0. |

### case_L1_ambiguity_prior_large

- Toggles: carrierEkf,1rx,ambSigma1000m
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 55.231 m -> 3.655 m; RMS 9.956 m.
- Initial/final receiver clock bias error: 54.945 m -> 3.629 m; RMS 9.890 m.
- Final/RMS clock drift error: 7.41809e-05 m/s / 0.00266424 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.230436 m, position/postfit 15.8634, clock/postfit 15.7485.
- NIS/NEES: median NIS 12.8434, max NIS 39.5355, median NEES 1.14707, max NEES 4.57723.
- Covariance: min eig 9.03085e-09, cond 6.3837e+09, NaN 0, Inf 0.
- Rows/states: code 5, doppler 5, carrier 5, states 19, ambiguity 5, ZWD 0.
- Main conclusion: case_L1_ambiguity_prior_large: BOUNDED_WEAK_GEOMETRY. final position 3.655 m, final clock 3.629 m, postfit 0.230 m, max NIS 39.5, PDOP 323, states 19, amb 5, ZWD 0.

| case_L2_ambiguity_prior_medium | BOUNDED_WEAK_GEOMETRY | 3.654 | 3.628 | 7.41788e-05 | 0.230436 | 39.5 | 323 | 455 | 19 | 5 | 0 | case_L2_ambiguity_prior_medium: BOUNDED_WEAK_GEOMETRY. final position 3.654 m, final clock 3.628 m, postfit 0.230 m, max NIS 39.5, PDOP 323, states 19, amb 5, ZWD 0. |

### case_L2_ambiguity_prior_medium

- Toggles: carrierEkf,1rx,ambSigma100m
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 55.149 m -> 3.654 m; RMS 9.953 m.
- Initial/final receiver clock bias error: 54.863 m -> 3.628 m; RMS 9.887 m.
- Final/RMS clock drift error: 7.41788e-05 m/s / 0.00266424 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.230436 m, position/postfit 15.8574, clock/postfit 15.7426.
- NIS/NEES: median NIS 12.8433, max NIS 39.5355, median NEES 1.14717, max NEES 4.57733.
- Covariance: min eig 9.03085e-09, cond 6.3837e+09, NaN 0, Inf 0.
- Rows/states: code 5, doppler 5, carrier 5, states 19, ambiguity 5, ZWD 0.
- Main conclusion: case_L2_ambiguity_prior_medium: BOUNDED_WEAK_GEOMETRY. final position 3.654 m, final clock 3.628 m, postfit 0.230 m, max NIS 39.5, PDOP 323, states 19, amb 5, ZWD 0.

| case_L3_ambiguity_prior_small | BOUNDED_WEAK_GEOMETRY | 3.652 | 3.626 | 7.41812e-05 | 0.230436 | 39.5 | 323 | 455 | 19 | 5 | 0 | case_L3_ambiguity_prior_small: BOUNDED_WEAK_GEOMETRY. final position 3.652 m, final clock 3.626 m, postfit 0.230 m, max NIS 39.5, PDOP 323, states 19, amb 5, ZWD 0. |

### case_L3_ambiguity_prior_small

- Toggles: carrierEkf,1rx,ambSigma10m
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 54.325 m -> 3.652 m; RMS 9.948 m.
- Initial/final receiver clock bias error: 54.042 m -> 3.626 m; RMS 9.882 m.
- Final/RMS clock drift error: 7.41812e-05 m/s / 0.00266423 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.230436 m, position/postfit 15.8503, clock/postfit 15.7355.
- NIS/NEES: median NIS 12.8432, max NIS 39.5355, median NEES 1.14777, max NEES 4.57896.
- Covariance: min eig 9.03014e-09, cond 6.3842e+09, NaN 0, Inf 0.
- Rows/states: code 5, doppler 5, carrier 5, states 19, ambiguity 5, ZWD 0.
- Main conclusion: case_L3_ambiguity_prior_small: BOUNDED_WEAK_GEOMETRY. final position 3.652 m, final clock 3.626 m, postfit 0.230 m, max NIS 39.5, PDOP 323, states 19, amb 5, ZWD 0.

| case_M1_clock_drift_doppler_off | BOUNDED_WEAK_GEOMETRY | 385.721 | 383.273 | 0.211323 | 0.283673 | 34.6 | 323 | 455 | 14 | 0 | 0 | case_M1_clock_drift_doppler_off: BOUNDED_WEAK_GEOMETRY. final position 385.721 m, final clock 383.273 m, postfit 0.284 m, max NIS 34.6, PDOP 323, states 14, amb 0, ZWD 0. |

### case_M1_clock_drift_doppler_off

- Toggles: code,1rx,clockDrift1mps,dopplerOff
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 55.240 m -> 385.721 m; RMS 479.583 m.
- Initial/final receiver clock bias error: 54.954 m -> 383.273 m; RMS 476.532 m.
- Final/RMS clock drift error: 0.211323 m/s / 0.711868 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.283673 m, position/postfit 1359.74, clock/postfit 1351.11.
- NIS/NEES: median NIS 6.08905, max NIS 34.582, median NEES 742.162, max NEES 1132.5.
- Covariance: min eig 9.03085e-09, cond 2.14398e+10, NaN 0, Inf 0.
- Rows/states: code 5, doppler 0, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_M1_clock_drift_doppler_off: BOUNDED_WEAK_GEOMETRY. final position 385.721 m, final clock 383.273 m, postfit 0.284 m, max NIS 34.6, PDOP 323, states 14, amb 0, ZWD 0.

| case_M2_clock_drift_doppler_on | BOUNDED_WEAK_GEOMETRY | 384.535 | 382.044 | 0.208436 | 0.420158 | 37.2 | 323 | 455 | 14 | 0 | 0 | case_M2_clock_drift_doppler_on: BOUNDED_WEAK_GEOMETRY. final position 384.535 m, final clock 382.044 m, postfit 0.420 m, max NIS 37.2, PDOP 323, states 14, amb 0, ZWD 0. |

### case_M2_clock_drift_doppler_on

- Toggles: code,doppler,1rx,clockDrift1mps
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 55.240 m -> 384.535 m; RMS 483.596 m.
- Initial/final receiver clock bias error: 54.954 m -> 382.044 m; RMS 480.522 m.
- Final/RMS clock drift error: 0.208436 m/s / 0.710086 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.420158 m, position/postfit 915.214, clock/postfit 909.285.
- NIS/NEES: median NIS 10.4623, max NIS 37.1585, median NEES 751.915, max NEES 1139.14.
- Covariance: min eig 9.03163e-09, cond 2.14278e+10, NaN 0, Inf 0.
- Rows/states: code 5, doppler 5, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_M2_clock_drift_doppler_on: BOUNDED_WEAK_GEOMETRY. final position 384.535 m, final clock 382.044 m, postfit 0.420 m, max NIS 37.2, PDOP 323, states 14, amb 0, ZWD 0.

| case_N1_attitude_zero_lever_arms | BOUNDED_WEAK_GEOMETRY | 5.287 | 5.259 | 0.00241658 | 0.346023 | 65.6 | 186 | 263 | 14 | 0 | 0 | case_N1_attitude_zero_lever_arms: BOUNDED_WEAK_GEOMETRY. final position 5.287 m, final clock 5.259 m, postfit 0.346 m, max NIS 65.6, PDOP 186, states 14, amb 0, ZWD 0. |

### case_N1_attitude_zero_lever_arms

- Toggles: code,doppler,3rx,zeroLeverArms
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 128.280 m -> 5.287 m; RMS 9.388 m.
- Initial/final receiver clock bias error: 127.533 m -> 5.259 m; RMS 9.326 m.
- Final/RMS clock drift error: 0.00241658 m/s / 0.00748765 m/s.
- Attitude result if observable: 0.866025 deg.
- Residual/state consistency: postfit 0.346023 m, position/postfit 15.278, clock/postfit 15.1986.
- NIS/NEES: median NIS 28.1943, max NIS 65.5657, median NEES 0.603402, max NEES 6.56599.
- Covariance: min eig 5.81205e-16, cond 1.22458e+17, NaN 0, Inf 0.
- Rows/states: code 15, doppler 15, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_N1_attitude_zero_lever_arms: BOUNDED_WEAK_GEOMETRY. final position 5.287 m, final clock 5.259 m, postfit 0.346 m, max NIS 65.6, PDOP 186, states 14, amb 0, ZWD 0.

| case_N2_attitude_nonzero_lever_arms | BOUNDED_WEAK_GEOMETRY | 5.287 | 5.259 | 0.0024163 | 0.346873 | 65.5 | 186 | 263 | 14 | 0 | 0 | case_N2_attitude_nonzero_lever_arms: BOUNDED_WEAK_GEOMETRY. final position 5.287 m, final clock 5.259 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 14, amb 0, ZWD 0. |

### case_N2_attitude_nonzero_lever_arms

- Toggles: code,doppler,3rx,defaultLeverArms
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 128.277 m -> 5.287 m; RMS 9.388 m.
- Initial/final receiver clock bias error: 127.533 m -> 5.259 m; RMS 9.326 m.
- Final/RMS clock drift error: 0.0024163 m/s / 0.00748778 m/s.
- Attitude result if observable: 0.93237 deg.
- Residual/state consistency: postfit 0.346873 m, position/postfit 15.241, clock/postfit 15.1621.
- NIS/NEES: median NIS 28.1851, max NIS 65.5023, median NEES 0.603754, max NEES 6.61931.
- Covariance: min eig 5.86068e-16, cond 1.22707e+17, NaN 0, Inf 0.
- Rows/states: code 15, doppler 15, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_N2_attitude_nonzero_lever_arms: BOUNDED_WEAK_GEOMETRY. final position 5.287 m, final clock 5.259 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 14, amb 0, ZWD 0.

| case_O1_atmosphere_off | BOUNDED_WEAK_GEOMETRY | 5.287 | 5.259 | 0.0024163 | 0.346873 | 65.5 | 186 | 263 | 14 | 0 | 0 | case_O1_atmosphere_off: BOUNDED_WEAK_GEOMETRY. final position 5.287 m, final clock 5.259 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 14, amb 0, ZWD 0. |

### case_O1_atmosphere_off

- Toggles: code,doppler,3rx,atmosphereOff
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 128.277 m -> 5.287 m; RMS 9.388 m.
- Initial/final receiver clock bias error: 127.533 m -> 5.259 m; RMS 9.326 m.
- Final/RMS clock drift error: 0.0024163 m/s / 0.00748778 m/s.
- Attitude result if observable: 0.93237 deg.
- Residual/state consistency: postfit 0.346873 m, position/postfit 15.241, clock/postfit 15.1621.
- NIS/NEES: median NIS 28.1851, max NIS 65.5023, median NEES 0.603754, max NEES 6.61931.
- Covariance: min eig 5.86068e-16, cond 1.22707e+17, NaN 0, Inf 0.
- Rows/states: code 15, doppler 15, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_O1_atmosphere_off: BOUNDED_WEAK_GEOMETRY. final position 5.287 m, final clock 5.259 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 14, amb 0, ZWD 0.

| case_O2_atmosphere_matched | BOUNDED_WEAK_GEOMETRY | 5.286 | 5.259 | 0.00241651 | 0.346869 | 65.5 | 186 | 263 | 14 | 0 | 0 | case_O2_atmosphere_matched: BOUNDED_WEAK_GEOMETRY. final position 5.286 m, final clock 5.259 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 14, amb 0, ZWD 0. |

### case_O2_atmosphere_matched

- Toggles: code,doppler,3rx,atmosphereMatched
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 128.277 m -> 5.286 m; RMS 9.388 m.
- Initial/final receiver clock bias error: 127.533 m -> 5.259 m; RMS 9.326 m.
- Final/RMS clock drift error: 0.00241651 m/s / 0.00748773 m/s.
- Attitude result if observable: 0.84311 deg.
- Residual/state consistency: postfit 0.346869 m, position/postfit 15.2387, clock/postfit 15.1602.
- NIS/NEES: median NIS 28.1828, max NIS 65.5031, median NEES 0.60263, max NEES 6.61402.
- Covariance: min eig 5.85719e-16, cond 1.22809e+17, NaN 0, Inf 0.
- Rows/states: code 15, doppler 15, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_O2_atmosphere_matched: BOUNDED_WEAK_GEOMETRY. final position 5.286 m, final clock 5.259 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 14, amb 0, ZWD 0.

| case_O3_atmosphere_mismatched | BOUNDED_WEAK_GEOMETRY | 5.286 | 5.259 | 0.00241651 | 0.346869 | 65.5 | 186 | 263 | 14 | 0 | 0 | case_O3_atmosphere_mismatched: BOUNDED_WEAK_GEOMETRY. final position 5.286 m, final clock 5.259 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 14, amb 0, ZWD 0. |

### case_O3_atmosphere_mismatched

- Toggles: code,doppler,3rx,atmosphereMismatch
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 128.277 m -> 5.286 m; RMS 9.388 m.
- Initial/final receiver clock bias error: 127.533 m -> 5.259 m; RMS 9.326 m.
- Final/RMS clock drift error: 0.00241651 m/s / 0.00748773 m/s.
- Attitude result if observable: 0.84311 deg.
- Residual/state consistency: postfit 0.346869 m, position/postfit 15.2387, clock/postfit 15.1602.
- NIS/NEES: median NIS 28.1828, max NIS 65.5031, median NEES 0.60263, max NEES 6.61402.
- Covariance: min eig 5.85719e-16, cond 1.22809e+17, NaN 0, Inf 0.
- Rows/states: code 15, doppler 15, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_O3_atmosphere_mismatched: BOUNDED_WEAK_GEOMETRY. final position 5.286 m, final clock 5.259 m, postfit 0.347 m, max NIS 65.5, PDOP 186, states 14, amb 0, ZWD 0.

| case_I_current_report_config | INVALID_CONFIGURATION | 18213.865 | 17813.756 | 0.070284 | 0.587144 | 3.61e+09 | 221 | 311 | 24 | 5 | 5 | case_I_current_report_config: INVALID_CONFIGURATION. final position 18213.865 m, final clock 17813.756 m, postfit 0.587 m, max NIS 3.61e+09, PDOP 221, states 24, amb 5, ZWD 5. |

### case_I_current_report_config

- Toggles: currentReport,3rx,L1L2,carrierEkf,ZWD
- Classification: INVALID_CONFIGURATION
- Initial/final position error: 281.419 m -> 18213.865 m; RMS 15307.595 m.
- Initial/final receiver clock bias error: 279.627 m -> 17813.756 m; RMS 15024.757 m.
- Final/RMS clock drift error: 0.070284 m/s / 0.060621 m/s.
- Attitude result if observable: 27.1297 deg.
- Residual/state consistency: postfit 0.587144 m, position/postfit 31021.1, clock/postfit 30339.7.
- NIS/NEES: median NIS 3.60778e+09, max NIS 3.60849e+09, median NEES 698581, max NEES 2.81557e+06.
- Covariance: min eig 7.50131e-16, cond 1.96952e+19, NaN 0, Inf 0.
- Rows/states: code 30, doppler 30, carrier 15, states 24, ambiguity 5, ZWD 5.
- Main conclusion: case_I_current_report_config: INVALID_CONFIGURATION. final position 18213.865 m, final clock 17813.756 m, postfit 0.587 m, max NIS 3.61e+09, PDOP 221, states 24, amb 5, ZWD 5.

| case_J_safe_report_config | BOUNDED_WEAK_GEOMETRY | 6.145 | 6.083 | 0.00189483 | 0.654279 | 99 | 221 | 311 | 14 | 0 | 0 | case_J_safe_report_config: BOUNDED_WEAK_GEOMETRY. final position 6.145 m, final clock 6.083 m, postfit 0.654 m, max NIS 99, PDOP 221, states 14, amb 0, ZWD 0. |

### case_J_safe_report_config

- Toggles: safeReport,3rx,L1L2,carrierDiagnostic,ZWDoff
- Classification: BOUNDED_WEAK_GEOMETRY
- Initial/final position error: 159.849 m -> 6.145 m; RMS 15.253 m.
- Initial/final receiver clock bias error: 158.888 m -> 6.083 m; RMS 15.153 m.
- Final/RMS clock drift error: 0.00189483 m/s / 0.00538413 m/s.
- Attitude result if observable: 2.24338 deg.
- Residual/state consistency: postfit 0.654279 m, position/postfit 9.39158, clock/postfit 9.29715.
- NIS/NEES: median NIS 58.1083, max NIS 98.9742, median NEES 1.28913, max NEES 5.59189.
- Covariance: min eig 6.62319e-16, cond 1.53056e+17, NaN 0, Inf 0.
- Rows/states: code 30, doppler 30, carrier 0, states 14, ambiguity 0, ZWD 0.
- Main conclusion: case_J_safe_report_config: BOUNDED_WEAK_GEOMETRY. final position 6.145 m, final clock 6.083 m, postfit 0.654 m, max NIS 99, PDOP 221, states 14, amb 0, ZWD 0.


## Last passing case


## Post-fix verification cases

| Case | Class | Final pos m | Final clock m | Postfit RMS m | Max NIS | Conclusion |
|---|---|---:|---:|---:|---:|---|
| postfix_F_guard_carrier_ekf_three_receivers | INVALID_CONFIGURATION | NaN | NaN | NaN | NaN | postfix_F_guard_carrier_ekf_three_receivers: INVALID_CONFIGURATION: carrierMode='ekfFloat' with multiple receiver phase centres is scientifically invalid in v1 because ambiguity states are indexed per tower/signal, while carrier rows are per tower/receiver. Use one receiver, carrierMode='diagnostic', or implement tower-receiver-signal ambiguity indexing. |

### postfix_F_guard_carrier_ekf_three_receivers

- Toggles: guard,carrierEkf,3rx
- Classification: INVALID_CONFIGURATION
- First failure symptom: postfix_F_guard_carrier_ekf_three_receivers: INVALID_CONFIGURATION: carrierMode='ekfFloat' with multiple receiver phase centres is scientifically invalid in v1 because ambiguity states are indexed per tower/signal, while carrier rows are per tower/receiver. Use one receiver, carrierMode='diagnostic', or implement tower-receiver-signal ambiguity indexing.

| postfix_K1_carrier_sigma_large | BOUNDED_WEAK_GEOMETRY | 3.885 | 3.862 | 0.202396 | 36.8 | postfix_K1_carrier_sigma_large: BOUNDED_WEAK_GEOMETRY. final position 3.885 m, final clock 3.862 m, postfit 0.202 m. |

### postfix_K1_carrier_sigma_large

- Toggles: carrierEkf,1rx,sigma0p05m,postfitMaskFix
- Classification: BOUNDED_WEAK_GEOMETRY
- Position/clock/postfit: 3.885 m / 3.862 m / 0.202396 m.
- Main conclusion: postfix_K1_carrier_sigma_large: BOUNDED_WEAK_GEOMETRY. final position 3.885 m, final clock 3.862 m, postfit 0.202 m.

| postfix_J_safe_report_config | BOUNDED_WEAK_GEOMETRY | 6.145 | 6.083 | 0.654279 | 99 | postfix_J_safe_report_config: BOUNDED_WEAK_GEOMETRY. final position 6.145 m, final clock 6.083 m, postfit 0.654 m. |

### postfix_J_safe_report_config

- Toggles: safeReport,3rx,L1L2,carrierDiagnostic,ZWDoff
- Classification: BOUNDED_WEAK_GEOMETRY
- Position/clock/postfit: 6.145 m / 6.083 m / 0.654279 m.
- Main conclusion: postfix_J_safe_report_config: BOUNDED_WEAK_GEOMETRY. final position 6.145 m, final clock 6.083 m, postfit 0.654 m.


## EKF prediction/update logic check

Direct line inspection of +revgnss/ReverseGNSSEKF.m confirms:

- Position propagation uses r_new = r + dt_s*v.
- Receiver clock propagation uses b_rx_new = b_rx + dt_s*bdot_rx.
- Covariance prediction uses F*P*F' + Q.
- Innovation uses nu = z - h.
- Innovation covariance uses S = H*P*H' + R.
- Kalman gain uses K = P*H'/S.
- State correction uses x = x + K*nu.
- Covariance update uses Joseph form P = (I-KH)P(I-KH)' + K*R*K'.

## Measurement sign/frame check

Source inspection and the existing sign tests confirm the intended sign/frame conventions:

- Code: rho + b_rx - b_tower + trop + iono.
- Doppler: range_rate + bdot_rx - bdot_tower.
- Carrier: rho + b_rx - b_tower + trop - iono + ambiguity.
- Builder paths operate in ECEF positions/LOS vectors; no ECI/ECEF frame-mixing issue was identified in the passing baseline cases.

## Code changes made, if any

1. +revgnss/ConfigFactory.m: added hard guard ConfigFactory:carrierAmbiguityReceiverIndexRequired for carrierMode=ekfFloat, nReceivers>1, and ambiguityMode=floatPerTowerSignal. This is scientifically correct because rows are tower/receiver carrier observations while ambiguity states are only tower/signal.
2. run_oo_reverse_gnss_report.m: changed default report to the measured safe configuration: carrier diagnostic-only, no ambiguity EKF, ZWD EKF disabled.
3. +revgnss/ReverseGNSSSimulation.m: filtered errStruct.carrierPhase with the same carrier keepMask used after slip resetAndSkip, so postfit residual recomputation uses the same physical carrier rows as the EKF update.

## Before/after metrics

- Before guard, case_06_carrier_ekf_three_receivers: INVALID_CONFIGURATION, final position 305.820 m, final clock 303.892 m, postfit 0.3425 m, max NIS 4.91e9, 15 carrier rows sharing 5 ambiguity states.
- Before report fix, current report config: INVALID_CONFIGURATION, final position 18213.865 m, final clock 17813.756 m, postfit 0.5871 m, max NIS 3.61e9.
- After guard, postfix_F_guard_carrier_ekf_three_receivers: INVALID_CONFIGURATION at config validation, before EKF run.
- After postfit fix, postfix_K1_carrier_sigma_large: bounded, final position 3.885 m, no runtime error.
- After report config fix, postfix_J_safe_report_config: BOUNDED_WEAK_GEOMETRY, final position 6.145 m, final clock 6.083 m, postfit 0.6543 m.

## Final scientific conclusion

Last passing pre-fix configuration: case_05_carrier_ekf_one_receiver. First failing configuration: case_06_carrier_ekf_three_receivers. The main convergence blocker is an invalid carrier ambiguity model for multi-receiver carrier EKF, amplified by ZWD states in the report configuration into residual-state decoupling. Weak GEO PDOP is real, but it does not explain the invalid carrier-state dimension or the 18 km state error with sub-metre postfit residuals.

## Remaining limitations

No receiver-indexed carrier ambiguity model was implemented. ZWD remains weakly observable in this geometry and should stay out of default validation/report configs unless constrained by a scientifically justified prior/guard.

## Recommended next step

In a future feature stage, implement tower-receiver-signal float ambiguity indexing and add observability-aware ZWD priors/guards; until then, use carrier diagnostic mode for multi-receiver reports.

## Corrected EKF source-inspection note

Direct line inspection of +revgnss/ReverseGNSSEKF.m confirms the EKF core logic: position uses r_new = r + dt_s*v, receiver clock uses b_rx_new = b_rx + dt_s*bdot_rx, covariance prediction uses F*P*F' + Q, update uses nu = z - h, S = H*P*H' + R, K = P*H'/S, state update x = x + K*nu, and Joseph covariance P = (I-KH)P(I-KH)' + K R K'. The earlier boolean source-pattern line used overly specific string patterns and should be read together with this direct line inspection.

## Targeted verification tests

Passed: tests/test_stage14_carrier_cycle_slips.m, tests/test_carrier_ekf_restrictions_4D_4E.m, tests/test_report_pdf_created.m. Full suite was not run.

## Report/PDF verification

run_oo_reverse_gnss_report completed successfully after the safe report config change. PDF: output/Report-20260616/report-v1.01.pdf. Inspection: exists, 657536 bytes, 15 pages, producer pdfTeX-1.40.27, page size 595.3 x 841.9 pt, rotation 0, landscape pages 0, required sections found, old 18213 m failure text absent.
