# Stage 24 Notion Update

**Stage:** 24 — Validation Status Gate + Frame/Time/Light-Time Foundation

## Runtime Metadata

| Item | Value |
|---|---|
| Branch | `feature/oo-reverse-gnss-v1` |
| Commit SHA | `05054c4` |
| Timestamp | 2026-06-18 12:58:11 |
| MATLAB | 25.2.0.3042426 (R2025b) Update 1 |

## Validation Results

| Item | Value |
|---|---|
| Selected tests | 4 / 4 passed |
| Full suite run | **NOT RUN** (targeted smoke only) |
| All-toggle report | true |
| Report run passed | true |
| PDF verified | true |

## Implemented Stage 24 Items

- ReportStatus: runtime git SHA, branch, validation mode, missing-stages list
- ValidationSummary: JSON + TXT summary writer and reader
- ValidationRunner: deterministic random test selection (seed 24, 2-5 tests)
- FrameTimeUtils: simple ECEF/inertial Earth-rotation and Sagnac foundation
- run_stage24_validation.m: targeted smoke validation + all-toggle report run
- Report Stage 24 validation status section in PDF/TEX
- All-toggle report mode: all independent boolean features enabled for run
- README updated to Stage 24 with runtime-SHA policy
- TWSTFT code time-transfer diagnostic scaffold (Stage 24a, diagnostic-only)

## Missing Scientific Stages

- Full CI / full test-suite validation (Stage 24 runs targeted smoke only)
- Full IERS/EOP GCRS/ITRF reference-frame and Earth-orientation products
- Full relativistic GNSS clock modelling (Schwarzschild, gravitational redshift)
- Dynamic orbit/force model (J2, drag, SRP; current: constant-velocity/simple orbit)
- Scientific troposphere: Niell/GMF/VMF3/GPT3/ERA5 mapping functions
- Scientific ionosphere: Klobuchar/IONEX/higher-order ionosphere models
- Carrier ionosphere-free (L4) combination in EKF
- Integer ambiguity resolution (LAMBDA/MLAMBDA)
- ANTEX PCO/PCV and calibrated hardware-bias products
- Real TWSTFT / relay / transponder physics
- External GNSS product ingestion: SP3, CLK, RINEX, IONEX, ANTEX

## Scientific Limitations

- FrameTimeUtils uses constant Earth rotation rate; no IERS EOP products.
- No full GCRS/ITRS transformation; z-axis nominal only.
- TWSTFT diagnostic scaffold is approximation-only; no relay/transponder.
- Float carrier ambiguities only; no integer fixing.
- Targeted smoke validation is not equivalent to full regression.
