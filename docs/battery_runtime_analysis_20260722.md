# Battery Runtime Analysis - Required Fixes

Date: 2026-07-22

## Scope

This note records the Commit 10 validation evidence for corrected battery labels and TW0/TW1 runtime interpretation.

The automated harness now writes canonical and mode-specific outputs under:

- `output/RequiredFixValidation_20260722/metrics.csv`
- `output/RequiredFixValidation_20260722/summary.md`
- `output/RequiredFixValidation_20260722/metrics_release_all.csv`
- `output/RequiredFixValidation_20260722/summary_release_all.md`
- `output/RequiredFixValidation_20260722/metrics_runtimeorder_all.csv`
- `output/RequiredFixValidation_20260722/summary_runtimeorder_all.md`

## Corrected Battery Labels

`run_oo_v1_battery` now distinguishes the scientific run class from the folder label:

- `Battery_baseline`: `Realism=false`, `Atmosphere=realistic`.
- `Battery_idealised`: `Realism=false`, `Atmosphere=matched`.
- `Battery_realism`: `Realism=true`.
- `Battery_honestcov`: honest-covariance realism overlay.

The release harness records two evidence levels:

- Full-topology semantic manifests for `Battery_baseline`, `Battery_idealised`, and `Battery_realism` over `G5S1R1`, `G5S1R4`, `G5S3R4`, `G5S6R4`, and `TW0/TW1`.
- Short numerical MAT rows for `Battery_baseline` and `Battery_realism` on `G5S1R1`, `TW0/TW1`.

The semantic manifest rows are label/configuration evidence only. They are deliberately not reported as full-duration numerical simulation proof.

## Runtime Interpretation

The reversed-order diagnostic runs `G5S3R4` in both orders:

- `TW0 -> TW1`
- `TW1 -> TW0`

With `WritePdf=false`, the runtime rows set `report_wall_s=0`; `wall_s` is simulation plus MAT-output overhead in the same MATLAB process. For federated swarm MAT files, full per-epoch measurement datastores are not saved in the unified artifact, so the harness records:

- epoch count and accepted/rejected update count from per-asset EKF histories;
- measurement row counts from the finalized configuration;
- explicit `source=config-derived` text in row-count fields.

For `G5S3R4`, TW1 has five additional ground two-way time-transfer rows relative to TW0. A shorter TW1 runtime in one order must therefore not be interpreted as lower physical workload unless reversed-order evidence and row counts support it. Likely confounders remain MATLAB class loading/JIT warm-up, operating-system file cache, MAT I/O variance, and OneDrive sync timing.

## 120 s Signing Run

The non-PDF signing command was:

```matlab
run_required_fixes_validation('Mode','release','Duration',120,'WritePdf',false)
run_required_fixes_validation('Mode','runtimeOrder','Scenario','G5S3R4','Duration',120,'WritePdf',false)
```

Release mode produced 25 pass rows, 0 xfail rows, and 0 fail rows. The short numerical rows all reported 121 epochs. The corrected row-count evidence was:

| row | wall_s | max rows/epoch | TWTT rows | epochs |
| --- | ---: | --- | ---: | ---: |
| Battery_baseline G5S1R1 TW0 | 3.75 | code=10,doppler=10,carrier=5,twtt=0,total=25 | 0 | 121 |
| Battery_baseline G5S1R1 TW1 | 3.57 | code=10,doppler=10,carrier=5,twtt=5,total=30 | 5 | 121 |
| Battery_realism G5S1R1 TW0 | 3.21 | code=10,doppler=10,carrier=5,twtt=0,total=25 | 0 | 121 |
| Battery_realism G5S1R1 TW1 | 2.96 | code=10,doppler=10,carrier=5,twtt=5,total=30 | 5 | 121 |

Runtime-order mode produced 6 pass rows, 0 xfail rows, and 0 fail rows for `G5S3R4`. TW1 carries five additional TWTT rows:

| order | tag | wall_s | nominal rows/epoch | accepted updates | epochs |
| --- | --- | ---: | --- | ---: | ---: |
| TW0 -> TW1 | TW0 | 16.49 | code=40,doppler=20,carrier=40,twtt=0,islCode=2,islDoppler=2,total=104 | 363 | 121 |
| TW0 -> TW1 | TW1 | 18.06 | code=40,doppler=20,carrier=40,twtt=5,islCode=2,islDoppler=2,total=109 | 363 | 121 |
| TW1 -> TW0 | TW1 | 15.88 | code=40,doppler=20,carrier=40,twtt=5,islCode=2,islDoppler=2,total=109 | 363 | 121 |
| TW1 -> TW0 | TW0 | 14.97 | code=40,doppler=20,carrier=40,twtt=0,islCode=2,islDoppler=2,total=104 | 363 | 121 |

The mean wall time was 15.73 s for TW0 and 16.97 s for TW1, a 7.9% increase in this run. This is runtime telemetry, not a physics claim: the row-count difference is deterministic, while wall time remains machine- and order-dependent.

## Full-Duration Status

The harness supports the literal full-duration runtime command:

```matlab
run_required_fixes_validation('Mode','runtimeOrder','Scenario','G5S3R4','Duration',7200,'WritePdf',false)
```

The full 7200 s PDF battery remains a separate expensive release artifact:

```matlab
run_oo_v1_battery('Duration',7200,'Towers',5,'SR',{[1 1],[1 4],[3 4],[6 4]},'TW',[0 1],'Realism',false,'WritePdf',true,'Analyze',true)
run_oo_v1_battery('Duration',7200,'Towers',5,'SR',{[1 1],[1 4],[3 4],[6 4]},'TW',[0 1],'Realism',true,'WritePdf',true,'Analyze',true)
```

Do not treat a short `release` or `runtimeOrder` smoke as a substitute for those full 7200 s PDF battery runs.
