# Required Fix Validation Summary

- mode: `release`
- focus: `all`
- generated: `2026-07-22 13:30:07`

- pass: 25
- xfail: 0
- fail: 0

| scenario_id | status | message |
| --- | --- | --- |
| release_contract | pass | Release mode runs all fix gates, the quick ladder, short numerical baseline/realism battery rows, and a full-topology semantic dry-run manifest. |
| harness_contract | pass | Validation harness writes metrics.csv, metrics.mat, and summary.md noninteractively. |
| ionoHO | pass | Higher-order ionosphere is carried through L1/L2/IF active code rows. |
| swarm | pass | Swarm solved-shape metrics are gated by multiAsset.twoWayISL.enable. |
| twtt | pass | Two-way time-transfer physical rows are included in postfit residuals and per-type NIS. |
| datastore | pass | Datastore preserves physical tower count separately from expanded tower-clock rows. |
| dcb | pass | Configured per-signal code DCB reaches active raw and IF code rows without stochastic R inflation. |
| labels | pass | Battery labels and TW tags reflect active atmosphere, realism, and TWTT EKF physics. |
| islDocs | pass | Legacy ISL helper wording routes users to the active ISL builders and relative solver. |
| quick_contract | pass | Quick ladder emits one pass/fail row for each required scenario; short smoke durations are not release proof. |
| Q1_G5S1R4_L1_matched_TW0 | pass | Short L1 matched-atmosphere one-way smoke passed. |
| Q2_G5S1R4_IF_ionoHO_TW0 | pass | IF higher-order ionosphere signed-source row path passed. |
| Q3_G5S1R4_realism_DCB_TW0 | pass | Realism-grade configured DCB reaches active code rows. |
| Q4_G5S1R4_realism_DCB_TW1 | pass | Realism DCB plus active TWTT smoke passed. |
| Q5_G5S3R4_twoWayISL_off | pass | twoWayISL=off; solved shape suppressed |
| Q6_G5S3R4_twoWayISL_on | pass | twoWayISL=on; solved shape active |
| Q7_G5S3R4_twoWayISL_on_TWTT_on | pass | twoWayISL=on; sat-sat TWSTFT relative clock active |
| selected_stage24_twstft_guard | pass | Stage24 TWSTFT diagnostic guard passed. |
| release_manifest_Battery_baseline | pass | Battery_baseline full-topology semantic dry-run emitted 8 rows; labels are corrected but no numerical simulation is claimed. |
| release_manifest_Battery_idealised | pass | Battery_idealised full-topology semantic dry-run emitted 8 rows; labels are corrected but no numerical simulation is claimed. |
| release_manifest_Battery_realism | pass | Battery_realism full-topology semantic dry-run emitted 8 rows; labels are corrected but no numerical simulation is claimed. |
| release_numeric_Battery_baseline_G5S1R1_TW0 | pass | short-numerical-baseline G5S1R1_TW0: wall 3.75 s, rows code=10,doppler=10,carrier=5,twtt=0,total=25; source=datastore-max, epochs 121. |
| release_numeric_Battery_baseline_G5S1R1_TW1 | pass | short-numerical-baseline G5S1R1_TW1: wall 3.57 s, rows code=10,doppler=10,carrier=5,twtt=5,total=30; source=datastore-max, epochs 121. |
| release_numeric_Battery_realism_G5S1R1_TW0 | pass | short-numerical-realism G5S1R1_TW0: wall 3.21 s, rows code=10,doppler=10,carrier=5,twtt=0,total=25; source=datastore-max, epochs 121. |
| release_numeric_Battery_realism_G5S1R1_TW1 | pass | short-numerical-realism G5S1R1_TW1: wall 2.96 s, rows code=10,doppler=10,carrier=5,twtt=5,total=30; source=datastore-max, epochs 121. |
