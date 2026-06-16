# EKF convergence triage summary

| Case | Enabled features | Final pos m | Final clock m | Postfit RMS m | Max NIS | PDOP | GDOP | ZWD RMS m | Amb RMS m | Classification | Flags |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| case_01_baseline_code_only | code,L1,oneReceiver | 5.79 | 5.77 | 0.228 | 25.3 | 323 | 455 | NaN | NaN | WARN | WEAK_GEOMETRY_HIGH_PDOP |
| case_02_code_plus_doppler | code,doppler,L1,oneReceiver | 15.5 | 15.3 | 0.202 | 26 | 323 | 455 | NaN | NaN | WARN | WEAK_GEOMETRY_HIGH_PDOP |
| case_03_code_doppler_three_receivers | code,doppler,L1,threeReceivers | 2 | 1.98 | 0.307 | 63.2 | 186 | 263 | NaN | NaN | WARN | WEAK_GEOMETRY_HIGH_PDOP |
| case_04_carrier_diagnostic_three_receivers | code,doppler,carrierDiagnostic,L1,threeReceivers | 8.38 | 8.33 | 0.267 | 59.5 | 186 | 263 | NaN | NaN | WARN | WEAK_GEOMETRY_HIGH_PDOP |
| case_05_carrier_ekf_one_receiver | code,doppler,carrierEkfFloat,slipDetection,L1,oneReceiver | 17.1 | 17 | 0.283 | 37.6 | 323 | 455 | NaN | 103 | WARN | WEAK_GEOMETRY_HIGH_PDOP |
| case_06_carrier_ekf_three_receivers | code,doppler,carrierEkfFloat,slipDetection,L1,threeReceivers | 258 | 257 | 0.303 | 4.91e+09 | 186 | 263 | NaN | 61.8 | INVALID_CONFIG | scientifically invalid config |
| case_07_zwd_code_doppler_three_receivers | code,doppler,perTowerZwd,L1,threeReceivers | 102 | 101 | 0.306 | 63.2 | 186 | 263 | 0.0384 | NaN | WARN | WEAK_GEOMETRY_HIGH_PDOP |
| case_08_full_supported_report_smoke | code,doppler,carrierEkfFloat,perTowerZwd,L1L2,threeReceivers | 1.38e+04 | 1.36e+04 | 0.706 | 3.61e+09 | 195 | 275 | 28 | 27.7 | INVALID_CONFIG | scientifically invalid config |

## First failing case

```text
First failing case: case_06_carrier_ekf_three_receivers
Previous passing case: case_05_carrier_ekf_one_receiver
New feature toggled: multi-receiver carrier EKF
Likely failure class: ambiguity state dimension mismatch
Recommended next investigation: Add a config guard or extend ambiguity states to tower-receiver-signal indexing.
```
