# Attitude Ablation Summary

- Duration: 3600 s
- Topology: G5S1R4, TW0, single spacecraft, four receiver antennas
- PDFs: disabled

| Case | OK | Final att deg | Tail mean att deg | Final sigma deg | Diff rows | Active baselines | Carrier sigma m | Inter-ant | Phase scint |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| L00_clean_ideal | 1 | 0.1664 | 0.0768 | 0.1139 | 30 | 15 | 0.0050 | 0 | 0 |
| I01_carrier_sigma_1cm | 1 | 0.2334 | 0.1133 | 0.1631 | 30 | 15 | 0.0100 | 0 | 0 |
| I02_inter_antenna_bias | 1 | 3.9007 | 3.6213 | 2.0135 | 0 | 15 | 0.0050 | 1 | 0 |
| I03_phase_scintillation | 1 | 0.1623 | 0.0778 | 0.1138 | 30 | 15 | 0.0050 | 0 | 1 |
| I04_realistic_atmosphere | 1 | 0.1639 | 0.0764 | 0.1137 | 30 | 15 | 0.0050 | 0 | 1 |
| I05_multipath_colored | 1 | 0.1634 | 0.0779 | 0.1139 | 30 | 15 | 0.0050 | 0 | 0 |
| I06_hardware_delay_white | 1 | 0.1692 | 0.0766 | 0.1139 | 30 | 15 | 0.0050 | 0 | 0 |
| I07_antenna_pcv_current | 1 | 0.1664 | 0.0768 | 0.1139 | 30 | 15 | 0.0050 | 0 | 0 |
| I08_tower_survey_current | 1 | 0.1575 | 0.0749 | 0.1139 | 30 | 15 | 0.0050 | 0 | 0 |
| I09_correlated_noise_current | 1 | 0.1664 | 0.0768 | 0.1139 | 30 | 15 | 0.0050 | 0 | 0 |
| R10_realism_no_inter_antenna | 1 | 1.4636 | 1.3186 | 4.6518 | 0 | 15 | 0.0100 | 0 | 1 |
| R11_full_realism_current | 1 | 3.8315 | 3.8704 | 4.9192 | 0 | 15 | 0.0100 | 1 | 1 |
| R12_full_realism_carrier_5mm | 1 | 4.0442 | 4.2527 | 3.8463 | 0 | 15 | 0.0050 | 1 | 1 |
| R13_full_realism_no_phase_scint | 1 | 2.9761 | 3.2293 | 4.8134 | 0 | 15 | 0.0100 | 1 | 0 |
| F14_clock_jow_only | 1 | 5.8184 | 5.7659 | 2.3476 | 0 | 15 | 0.0050 | 0 | 0 |
| F15_realism_no_inter_legacy_clock | 1 | 0.2306 | 0.1165 | 0.1645 | 30 | 15 | 0.0100 | 0 | 1 |
| F16_realism_no_inter_slip_off | 1 | 0.2253 | 0.1117 | 0.1645 | 30 | 15 | 0.0100 | 0 | 1 |
| F17_realism_no_inter_slip_1m | 1 | 0.2253 | 0.1117 | 0.1645 | 30 | 15 | 0.0100 | 0 | 1 |

## Notes

- `I07_antenna_pcv_current` and `I08_tower_survey_current` intentionally use the current toggle expansion, where truth and model flags are both enabled.
- `I09_correlated_noise_current` intentionally uses the current configured zero sigmas, so it should behave as a no-op if the implementation is consistent.
- `R12_full_realism_carrier_5mm` isolates the effect of the realism honest carrier-sigma floor by leaving all other realism effects active.
- `R13_full_realism_no_phase_scint` isolates carrier phase scintillation inside the full realism package.
