You are a GNSS scientist, Kalman-filter architect, and senior MATLAB OO developer working in repository:

  CranMatuschka/IRP_Simulation

Create a new branch from the latest main:

  feature/oo-v1-scientific-completion

Scope is absolutely restricted to:

  oo_v1/**

Do not edit, move, delete, or create anything outside oo_v1/. If a needed change appears to require root-level files, stop and document the need inside oo_v1/docs/BRANCH_LIMITATIONS.md instead of touching the root.

The goal is to evolve the current Stage 85 controlled synthetic single-space-asset one-way reverse-GNSS EKF simulator into a scientifically coherent, extensible inverted-GNSS / GNSS-processing framework while preserving the current Stage 85 single-asset scenario as a regression contract. Do not do a clean rewrite. Use an evolutionary strangler pattern: keep current entry points working, add new classes behind config flags, and replace internals only after regression tests prove equivalence.

Current architectural facts to preserve:
- Active entry point remains oo_v1/run_oo_reverse_gnss_report.m.
- Current active scenario remains singleAssetCarrierAttitude unless a new scenario is explicitly selected.
- Existing Stage 85 validation artifacts are runtime-only and must not be committed.
- ReportStatus, StageHistory, README_oo_v1.md, ConfigFactory, ScenarioPresets, ModelCoverageAudit, ValidationRunner, ScientificValidationCampaign, and ConsistencyStatistics remain source-truth infrastructure.
- The current single-space-asset one-way code/carrier/Doppler scenario must continue to pass after every commit.
- Existing warnings against unsupported real-world claims must remain unless the specific missing feature has actually been implemented and validated.

Global rules for every commit:
1. Commit only atomic, reviewable changes.
2. Every commit message must be of the form:
   Stage NN: concise scientific/architectural change
   Start at Stage 86 because main currently documents Stage 85.
3. Each commit must update, when applicable:
   - oo_v1/README_oo_v1.md
   - oo_v1/+revgnss/ReportStatus.m
   - oo_v1/+revgnss/StageHistory.m
   - oo_v1/+revgnss/ModelCoverageAudit.m
   - oo_v1/+revgnss/MainScriptValidationGate.m
   - report summary fields only if the new feature affects scientific status.
4. Never hard-code a commit SHA in README or ReportStatus.
5. Never commit oo_v1/output/ artifacts.
6. No silent fallbacks. Unknown modes, missing products, dimension mismatch, bad gauges, invalid units, or unobservable states must error or produce explicit guardedNotImplemented / disabledByConfig classifications.
7. All stochastic tests must use deterministic seeds.
8. Every measurement row must carry metadata: observable type, transmitter, receiver/asset, signal, units, product epoch if applicable, correction components, covariance policy, and state-column ownership.
9. Every new Jacobian must have a finite-difference audit test. Analytic Jacobians are preferred; finite difference may remain only as an audit fallback, not as the main production method for large problems.
10. Every covariance matrix/block must be checked for symmetry and positive semi-definiteness or positive definiteness as appropriate. Add jitter only through one documented helper, never ad hoc.
11. Do not claim PPP-grade, millimeter-level, real-world, or operational validity unless external product ingestion, bias handling, frame/time handling, and benchmark validation are implemented and pass. Until then, label results synthetic or product-parser-validated only.
12. Preserve backwards compatibility of existing config names where reasonable, but centralize canonical ownership in ConfigFactory.finalizeConfig().
13. Prefer MATLAB classdef files under +revgnss. Avoid large monolithic scripts.
14. Add tests under oo_v1/tests/test_*.m and fixtures under oo_v1/tests/fixtures/ only.

Validation command after every commit:
  cd oo_v1
  setenv('OO_V1_VALIDATE_REPORT','true')
  setenv('OO_V1_ALL_TOGGLES','true')
  setenv('OO_V1_VALIDATION_STAGE','NN')
  setenv('OO_V1_RANDOM_TEST_SEED','NN')
  run_oo_reverse_gnss_report

Also run all new tests added in the commit. If a full test runner is added, run it after every phase. If MATLAB cannot be run, do not write “validated”; write exactly “NOT RUN” in the commit notes and README status.

Acceptance gates for every commit:
- git diff --name-only must show only oo_v1 paths.
- Existing Stage 85-equivalent singleAssetCarrierAttitude report path still runs.
- New feature-specific tests pass.
- No generated output files are staged.
- ReportStatus stage, README stage, MainScriptValidationGate stage, and StageHistory stage agree.
- ModelCoverageAudit has no missingUnsafe category for the selected active configuration.
- Any unavailable capability is explicitly guardedNotImplemented, not half-enabled.

Implement the following staged commits.

Stage 86: Branch safety, source-truth lock, and development plan
- Add oo_v1/docs/SCIENTIFIC_COMPLETION_BRANCH_PLAN.md containing this staged plan, scientific claim policy, and validation matrix.
- Add a small helper revgnss.BranchScopeGuard that can assert all changed files are under oo_v1 when run locally.
- Update ReportStatus/README/StageHistory to Stage 86 without changing physics.
- Preserve Stage 85 validation behavior.
Tests:
- New test_branch_scope_guard.
- Existing selected validation passes.
Scientific acceptance:
- No science change. This commit only hardens process and documentation.

Stage 87: Unified test harness and validation taxonomy
- Add revgnss.OoV1TestHarness with:
  - runSelectedSmokeTests
  - runAllUnitTests
  - runScientificRegression
  - collectMatlabParseChecks
  - summarizeResults
- Add validation levels:
  - smoke
  - unit
  - syntheticRegression
  - monteCarloConsistency
  - parserFixtureValidation
  - externalBenchmarkValidation
- Keep ValidationRunner intact but make it callable through OoV1TestHarness.
Tests:
- test_test_harness_discovers_tests
- test_test_harness_reports_not_run_honestly
Acceptance:
- No feature claim can be marked validated unless the relevant validation level ran.

Stage 88: Feature registry and expanded model-coverage contract
- Add revgnss.FeatureRegistry as the canonical registry for capabilities:
  topology, frames, timeScales, orbitProducts, clockProducts, rinexObs, rinexNav, antex, ionex, biasProducts, codeObservables, carrierObservables, dopplerObservables, troposphere, ionosphere, relativity, antenna, hardwareBias, stochasticClock, sparseEstimator, multiAsset, islOneWay, islTwoWay, twstftCode, twstftCarrier, ambiguityFloat, lambda, mlambda, ppp, pppAr, validationStatistics.
- Refactor ModelCoverageAudit to consume FeatureRegistry rather than scattered booleans where possible.
- Existing active scenario must still show unavailable future features as guardedNotImplemented or disabledByConfig.
Tests:
- test_feature_registry_defaults
- test_model_coverage_no_missing_unsafe_for_stage85_regression
Acceptance:
- Audit is stricter, but current single-asset run still passes.

Stage 89: Product-provider interfaces without real parsers
- Add abstract-style provider classes:
  revgnss.ProductProvider
  revgnss.OrbitClockProductProvider
  revgnss.AntennaCalibrationProvider
  revgnss.IonosphereProductProvider
  revgnss.BiasProductProvider
- Add Null providers and Synthetic providers.
- Product modes:
  off
  synthetic
  fixtureFile
  externalFileGuarded
- externalFileGuarded must error until the parser exists.
Tests:
- test_product_provider_null_modes
- test_external_file_mode_guarded
Acceptance:
- No real parser claim yet.

Stage 90: SP3 precise orbit parser with miniature fixtures
- Add revgnss.Sp3Parser.
- Parse minimal SP3 position records, epochs, satellite IDs, coordinate units, and metadata.
- Add fixture files under oo_v1/tests/fixtures/products/sp3/.
- Add revgnss.PreciseOrbitProvider using parsed SP3 with interpolation.
- Interpolation must be explicit: nearest, linear, or lagrange, with documented error behavior.
Tests:
- test_sp3_parser_minimal_fixture
- test_sp3_interpolation_units
- test_sp3_missing_satellite_errors
Scientific acceptance:
- Parser validates units and epoch ordering.
- No SP3 use in active scenario unless configured.

Stage 91: CLK precise clock parser with covariance semantics
- Add revgnss.ClkParser.
- Parse minimal satellite/station clock records, epochs, clock bias seconds, optional sigma.
- Add revgnss.PreciseClockProvider.
- Add clock interpolation and product-age metadata.
- Integrate with ProductClockCovarianceBuilder only behind config flag.
Tests:
- test_clk_parser_minimal_fixture
- test_clk_clock_units_seconds_to_metres
- test_clk_product_age_metadata
Acceptance:
- Existing synthetic tower-clock product path remains unchanged by default.

Stage 92: RINEX observation and navigation fixture parsers
- Add revgnss.RinexObsParser for minimal RINEX 3 observation fixture support.
- Add revgnss.RinexNavParser for minimal broadcast ephemeris fixture support.
- Do not attempt full standard coverage in one commit; implement a strict documented subset and fail clearly outside it.
- Add observation type mapping to SignalDefinition.
Tests:
- test_rinex_obs_minimal_fixture
- test_rinex_nav_minimal_fixture
- test_rinex_unknown_observable_guard
Acceptance:
- Parser capability is fixture-validated, not operationally complete.

Stage 93: ANTEX parser and antenna calibration provider
- Add revgnss.AntexParser for strict minimal ANTEX fixture support:
  antenna name
  frequency
  PCO vector
  elevation-only PCV grid
- Add revgnss.AntennaCalibrationProvider backed by parsed ANTEX.
- Replace toy/table PCV path with provider interface while preserving old config as synthetic provider.
Tests:
- test_antex_parser_minimal_fixture
- test_antenna_provider_pco_units
- test_pcv_interpolation_elevation_only
Scientific acceptance:
- PCV azimuth dependence remains guardedNotImplemented unless implemented.
- Report clearly states whether calibration is synthetic or ANTEX fixture-backed.

Stage 94: IONEX and broadcast-ionosphere model interfaces
- Add revgnss.IonexParser for strict minimal fixture support.
- Add revgnss.IonosphereGridProvider.
- Add broadcast Klobuchar model class, but enable only when coefficients are explicitly provided.
- Preserve current simpleSecant/thinShell models.
Tests:
- test_ionex_parser_minimal_fixture
- test_klobuchar_guard_without_coefficients
- test_iono_frequency_scaling_sign_code_vs_phase
Scientific acceptance:
- First-order ionosphere sign conventions for code/carrier are tested.
- Higher-order ionosphere remains guardedNotImplemented until implemented.

Stage 95: Code/phase/inter-frequency bias product handling
- Add revgnss.BiasProductParser for strict minimal OSB/DCB fixture format.
- Add canonical bias structs:
  cfg.products.bias.code
  cfg.products.bias.phase
  cfg.products.bias.interFrequency
- Add application hooks to measurement builders, disabled by default.
Tests:
- test_bias_product_parser_fixture
- test_code_bias_units
- test_phase_bias_absorbed_by_float_ambiguity_unless_calibrated
Acceptance:
- Biases cannot be silently absorbed without metadata saying so.

Stage 96: Time-scale and epoch model
- Add revgnss.TimeScaleModel supporting:
  GPS week/SOW
  UTC-like fixture epochs
  TAI offset placeholder
  leap-second table fixture
- No hidden system-time assumptions.
- All product parsers must produce a common epoch representation.
Tests:
- test_time_scale_gps_week_sow
- test_time_scale_epoch_ordering
- test_product_epoch_common_representation
Acceptance:
- Report includes time-scale status.

Stage 97: EOP and frame-provider foundation
- Add revgnss.EopProvider with synthetic constant-omega and fixture-table modes.
- Add revgnss.FrameTransformProvider wrapping current FrameTimeUtils.
- Preserve constantOmegaV1 default.
- Add explicit frame labels to truth, measurement, product, and report paths.
Tests:
- test_frame_round_trip_constant_omega
- test_eop_fixture_table_parse
- test_no_frame_label_missing_in_measurement_rows
Scientific acceptance:
- No IERS-grade claim unless fixture-backed and validated.

Stage 98: Iterative light-time and relativistic correction closure
- Add revgnss.LightTimeSolver:
  sameEpoch
  sagnacFirstOrder
  iterativeOneWay
- Add revgnss.RelativityModel:
  Shapiro delay
  satellite clock eccentricity correction placeholder
  gravitational redshift metadata
- Harden double-count guard between geometric Earth rotation and Sagnac correction.
Tests:
- test_light_time_zero_rotation_equivalence
- test_sagnac_double_count_guard
- test_shapiro_order_of_magnitude_synthetic
Acceptance:
- Measurement row metadata includes light-time mode and relativistic correction terms.

Stage 99: Dynamics model expansion with explicit fidelity labels
- Extend OrbitDynamics/OrbitPropagator through new force-model interface:
  twoBody
  J2
  J2J4 optional guarded
  thirdBodySunMoon synthetic placeholder
  SRP cannonball synthetic
  drag simple exponential atmosphere guarded by orbit altitude
- Add revgnss.ForceModelAudit.
- Keep current j2Rk4 truth / twoBody EKF regression unchanged.
Tests:
- test_two_body_energy_short_arc
- test_j2_accel_against_closed_form
- test_force_model_disabled_terms_are_zero
Acceptance:
- Every force term has units and frame documented.
- Unsupported high-fidelity terms are not silently claimed.

Stage 100: Clock stochastic model consolidation
- Add revgnss.ClockNoiseModelFactory.
- Support Brown-Hwang two-state, stable coupled Gauss-Markov, and deterministic clocks through one interface.
- Allan deviation generation must be shared by simulation and report.
- Validate short-horizon equivalence and long-horizon boundedness for stable GM.
Tests:
- test_clock_noise_factory_templates
- test_clock_allan_deviation_slope_synthetic
- test_stable_gm_covariance_bounded
Acceptance:
- Clock covariance units are seconds/metres explicitly converted once.

Stage 101: MeasurementBatch and row-metadata unification
- Add revgnss.MeasurementBatch with z, h, H, R, rowMeta, blockMeta.
- Migrate code/carrier/Doppler builders to return MeasurementBatch or provide adapter.
- Add validation method:
  validateDimensions
  validateUnits
  validateSymmetricR
  validateRowMetadataComplete
Tests:
- test_measurement_batch_dimension_guard
- test_measurement_batch_metadata_required
- existing report run
Acceptance:
- Existing measurement paths still work through adapter.

Stage 102: Analytic one-way code/carrier/Doppler observation model
- Add revgnss.OneWayObservationEquation.
- Centralize:
  geometric range
  receiver/tower antenna phase centers
  clock terms
  atmosphere
  hardware bias
  product corrections
  Sagnac/light time
  carrier wavelength and ambiguity
  Doppler range-rate
- Replace duplicated formulas gradually with calls to this class.
Tests:
- test_one_way_range_jacobian_position_fd
- test_carrier_phase_sign_convention
- test_doppler_range_rate_fd
Acceptance:
- Code, carrier, Doppler use consistent geometry.

Stage 103: Troposphere model upgrade
- Add revgnss.TroposphereModel:
  off
  simpleMapped
  Saastamoinen
  dry/wet split
  mapping function interface
  horizontal gradients
  ZTD/ZWD state hooks
- Preserve current synthetic simpleMapped behavior as regression.
Tests:
- test_trop_off_zero
- test_saastamoinen_zenith_reasonable_range
- test_trop_gradient_azimuth_dependence
- test_zwd_state_column_jacobian_fd
Acceptance:
- Report distinguishes empirical, synthetic, and estimated troposphere.

Stage 104: Ionosphere model upgrade
- Add revgnss.IonosphereModel:
  off
  firstOrderFrequencyScaling
  ionosphereFreeCombination
  Klobuchar
  IONEX grid
  higherOrderGuarded
- Implement second/third-order placeholders only as guardedNotImplemented unless equations and tests are fully implemented.
Tests:
- test_iono_first_order_code_phase_signs
- test_iono_free_combination_cancels_first_order
- test_iono_free_noise_amplification
Acceptance:
- No higher-order claim unless actually implemented.

Stage 105: Antenna and hardware-bias observation integration
- Integrate ANTEX/synthetic PCO/PCV through OneWayObservationEquation.
- Integrate tx/rx code bias, phase bias, and inter-frequency bias with identifiability guards.
- Maintain existing gauge protections.
Tests:
- test_pco_changes_range_with_attitude
- test_pcv_applied_only_when_model_enabled
- test_bias_clock_collinearity_guard
Acceptance:
- Biases must be either estimated with a gauge, externally calibrated, or explicitly absorbed.

Stage 106: Product covariance and correlated-error block builder
- Replace scattered covariance handling with revgnss.CovarianceBlockBuilder.
- Support shared tower-product clock errors, code/carrier/Doppler product drift, atmosphere common-mode, receiver common-mode, and independent tracking noise.
- Use sparse construction where possible.
Tests:
- test_covariance_block_spd
- test_shared_tower_product_block_structure
- test_dense_sparse_covariance_equivalence
Acceptance:
- R block policies appear in row metadata and report.

Stage 107: State layout registry
- Add revgnss.StateLayoutRegistry.
- Canonical state groups:
  asset position/velocity
  asset attitude error/quaternion nominal
  angular rate
  receiver clock bias/drift
  tower clock bias/drift
  ZTD/ZWD/gradients
  ionosphere states if enabled
  hardware biases
  carrier ambiguities per arc/signal/link
  ISL/TWSTFT timing states
- Existing ReverseGNSSEKF must be adapted without breaking current 14-state regression.
Tests:
- test_state_layout_single_asset_matches_legacy
- test_state_layout_optional_groups_indices_unique
- test_state_layout_dimension_contract
Acceptance:
- No hard-coded state indices remain in new code paths.

Stage 108: Sparse EKF core
- Add revgnss.SparseKalmanFilter or refactor ReverseGNSSEKF behind interface.
- Sparse H/R/P support for large multi-asset measurement stacks.
- Dense fallback must remain for small legacy cases.
- Joseph update remains default.
Tests:
- test_sparse_dense_update_equivalence
- test_sparse_joseph_covariance_symmetry
- test_sparse_large_synthetic_memory_smoke
Acceptance:
- Current scenario numerical results remain within tolerance of legacy dense path.

Stage 109: Multi-asset topology enablement behind explicit scenario
- Remove hard error for multi-space-asset only in new scenario mode, not in current default.
- Add ScenarioPresets.multiAssetReverseGnssSynthetic with N assets and M towers.
- Add measurement generation for independent tower-to-asset links.
- Preserve singleAssetCarrierAttitude as default.
Tests:
- test_multi_asset_config_requires_explicit_scenario
- test_multi_asset_state_dimension
- test_single_asset_regression_unchanged
Acceptance:
- No silent truncation of assets.

Stage 110: Multi-asset observability and gauge audit
- Add revgnss.NetworkObservabilityAudit.
- Check rank/condition for position, clock, attitude, tower clocks, and inter-asset links.
- Add gauge constraints for joint receiver/tower clocks.
Tests:
- test_free_clock_gauge_errors
- test_reference_tower_gauge_passes
- test_multi_asset_observability_rank_synthetic
Acceptance:
- Report blocks accuracy claims for unobservable configurations.

Stage 111: One-way ISL implementation
- Implement revgnss.ISLMeasurementBuilder for one-way inter-spacecraft code/carrier/Doppler.
- Use same ObservationEquation framework.
- Add ISL row metadata and ambiguity indexing.
Tests:
- test_isl_one_way_range_symmetric_geometry
- test_isl_clock_sign_convention
- test_isl_disabled_in_single_asset_regression
Acceptance:
- ISL is active only in explicit multi-asset scenario.

Stage 112: Two-way ISL ranging and Doppler
- Implement two-way ISL range with transmit/receive epochs and asymmetric delay metadata.
- Add clock-cancellation checks.
- Add Doppler/range-rate two-way model if scientifically justified; otherwise guard.
Tests:
- test_two_way_clock_cancellation_static_case
- test_two_way_asymmetry_metadata
- test_two_way_requires_two_assets
Acceptance:
- Two-way never reuses one-way equations without explicit epoch handling.

Stage 113: TWSTFT code-based time transfer
- Implement revgnss.TwstftMeasurementBuilder for code TWSTFT:
  local transmit
  remote receive
  remote transmit
  local receive
  path delay assumptions
  clock offset observable
- Add ground-station and satellite relay scenario fixture.
Tests:
- test_twstft_symmetric_delay_clock_offset
- test_twstft_asymmetric_delay_bias
- test_twstft_disabled_by_default
Acceptance:
- TWSTFT remains separate from GNSS one-way pseudorange.

Stage 114: TWSTFT carrier/frequency transfer
- Add carrier phase/frequency-transfer model:
  carrier counter
  satellite LO term
  uplink/downlink Doppler
  optional LO estimation state
- Keep ambiguity/cycle issues explicit.
Tests:
- test_twstft_carrier_frequency_static_case
- test_satellite_lo_state_observability_guard
- test_twstft_carrier_units_cycles_hz_seconds
Acceptance:
- No picosecond claim unless validation supports it.

Stage 115: Multi-way time-transfer network
- Add revgnss.TimeTransferNetworkScenario.
- Add pairwise TWTT/TWSTFT graph solver for clock offsets/drifts.
- Add network gauge/reference-clock handling.
Tests:
- test_time_transfer_network_clock_gauge
- test_pairwise_offsets_recover_synthetic
- test_network_disconnected_guard
Acceptance:
- Report distinguishes synchronization precision from absolute time accuracy.

Stage 116: Integer least-squares foundation
- Add revgnss.IntegerLeastSquaresProblem.
- Add decorrelation utilities and bootstrap rounding.
- Add tests with known integer solutions and covariance.
Tests:
- test_integer_ls_known_solution
- test_decorrelation_reduces_correlation
- test_integer_ls_rejects_bad_covariance
Acceptance:
- This is foundation only; do not yet wire into PPP/AR claims.

Stage 117: LAMBDA implementation
- Implement revgnss.LambdaAmbiguityResolver with:
  Z-transform/decorrelation
  search
  ratio test
  residual test
  covariance input validation
- Add known toy benchmarks.
Tests:
- test_lambda_known_benchmark
- test_lambda_ratio_rejects_ambiguous_case
- test_lambda_covariance_symmetry_guard
Acceptance:
- Report says LAMBDA implementedSynthetic only until used in validated GNSS scenarios.

Stage 118: MLAMBDA / efficient search and false-fix controls
- Implement MLAMBDA improvements if feasible; otherwise keep guardedNotImplemented with reason.
- Add bootstrapped success-rate approximation and configurable false-fix risk gate.
Tests:
- test_mlambda_matches_lambda_small_case
- test_false_fix_gate_rejects_low_confidence
Acceptance:
- No fixed ambiguity is applied without documented risk classification.

Stage 119: Wide-lane/narrow-lane and multi-frequency AR
- Integrate L1/L2 wide-lane/narrow-lane combinations.
- Add raw L1/L2 integer pair fixing with covariance propagation.
- Carrier-IF integer fixing must remain guarded unless explicitly solved with correct transformed integer basis.
Tests:
- test_widelane_wavelength
- test_narrowlane_covariance_propagation
- test_carrier_if_integer_fixing_guard
Acceptance:
- Ambiguity fixing cannot pass if phase-bias products are required but absent.

Stage 120: PPP observation engine
- Add revgnss.PppEngine using:
  SP3 precise orbit
  CLK precise clocks
  RINEX observations
  ANTEX calibration
  troposphere model/state
  ionosphere-free code/carrier
  receiver clock
  float ambiguities
- Add a tiny fixture-based PPP smoke case, not a real accuracy benchmark.
Tests:
- test_ppp_engine_fixture_smoke
- test_ppp_missing_sp3_clk_errors
- test_ppp_float_ambiguity_state_layout
Acceptance:
- PPP status is parserFixtureValidated, not real-world validated.

Stage 121: PPP-AR integration
- Add PPP-AR mode using OSB/phase-bias products and LAMBDA.
- Require bias product availability, stable arcs, slip-free windows, covariance quality, and false-fix gate.
Tests:
- test_ppp_ar_requires_phase_bias_product
- test_ppp_ar_synthetic_known_integer_fix
- test_ppp_ar_rejects_cycle_slip_arc
Acceptance:
- PPP-AR cannot be enabled by a single boolean without all prerequisites.

Stage 122: Cycle slip, outlier, and robust estimation hardening
- Centralize cycle slip detection and arc management across carrier GNSS, ISL, and PPP.
- Add innovation outlier detection and robust downweighting option.
- Preserve deterministic synthetic slip injection.
Tests:
- test_cycle_slip_resets_ambiguity_arc
- test_outlier_detector_flags_large_residual
- test_robust_downweighting_reduces_effect
Acceptance:
- Slips and outliers must be visible in diagnostics and report.

Stage 123: Batch/smoother capability
- Add optional RTS smoother or fixed-lag smoother for post-processing.
- Do not alter EKF default.
Tests:
- test_rts_smoother_linear_gaussian_known_case
- test_smoother_disabled_by_default
Acceptance:
- Smoother results are labelled post-processed, not real-time EKF.

Stage 124: Monte Carlo validation expansion
- Extend ScientificValidationCampaign:
  multiple geometries
  multiple clock qualities
  L1-only/L1L2
  product outage
  slip injection
  multi-asset
  ISL
  TWSTFT
  PPP fixture
- Add aggregated NEES/NIS by state group and observable group.
Tests:
- test_campaign_config_generation
- test_nees_nis_group_classification
Acceptance:
- Campaign can mark warnHigh/warnLow honestly, not force pass.

Stage 125: Scientific benchmark and consistency gates
- Add revgnss.ScientificAcceptanceGate.
- Gates:
  dimension consistency
  covariance consistency
  frame/time consistency
  observability
  innovation statistics
  ambiguity risk
  product completeness
  claim-level compatibility
- Report fails validation if claim level exceeds implemented evidence.
Tests:
- test_claim_gate_blocks_real_world_without_products
- test_claim_gate_allows_synthetic_demo
Acceptance:
- This gate is the final authority for report claim wording.

Stage 126: Report modernization without bloating PDF
- Update report to summarize:
  active scenario
  feature coverage
  product modes
  frame/time model
  observability
  covariance policy
  ambiguity status
  validation level
  claim level
- Do not reintroduce huge stage-history chapters.
Tests:
- test_report_contains_feature_coverage
- test_report_numerical_summary_final_or_intentionally_documented
Acceptance:
- Report is readable and honest.

Stage 127: Performance and sparse scalability
- Profile large synthetic multi-asset run.
- Replace dense concatenations with spalloc/sparse block assembly where needed.
- Add compact diagnostics storage for long runs.
Tests:
- test_large_sparse_run_smoke
- test_diagnostics_compaction
Acceptance:
- Large run completes without memory blowup in reasonable MATLAB settings.

Stage 128: Backward compatibility and migration cleanup
- Add revgnss.ConfigMigration for old config aliases.
- Deprecate but do not silently break old names.
- Remove duplicate source-of-truth assignments only after tests prove migration.
Tests:
- test_legacy_config_aliases_migrate
- test_canonical_config_wins_with_warning
Acceptance:
- ConfigFactory remains canonical.

Stage 129: Full integrated scientific campaign
- Run:
  singleAssetCarrierAttitude regression
  multiAssetReverseGnssSynthetic
  one-way ISL synthetic
  two-way ISL synthetic
  TWSTFT synthetic
  PPP fixture
  PPP-AR synthetic known-integer
  sparse/dense equivalence
  parser fixtures
  Monte Carlo consistency sample
- Save runtime summaries locally only.
- Update README with exact validation command and honest results.
Acceptance:
- Any failed category must remain documented as warn/fail and cannot be hidden.
- No output artifacts committed.

Stage 130: Final branch closure
- Finalize README_oo_v1.md with:
  implemented capabilities
  guarded limitations
  validation levels run
  claim level
  how to reproduce
- Finalize StageHistory and ReportStatus.
- Ensure ModelCoverageAudit has zero missingUnsafe for all supported scenarios.
- Ensure unsupported or unvalidated capabilities are guarded.
- Prepare PR description inside oo_v1/docs/PR_DESCRIPTION_STAGE130.md.
Final acceptance:
- All changed files are under oo_v1.
- Existing single-asset run passes.
- New feature tests pass.
- Full integrated campaign results are honest.
- No PPP-grade/mm-level/real-world claim unless external benchmark validation truly ran and supports it.
- The branch is scientifically stricter than main and preserves current architecture rather than replacing it.

Implementation style requirements:
- Use small MATLAB classdef files.
- Prefer pure functions/static methods for physics models where state is unnecessary.
- Keep units in names: _m, _s, _Hz, _rad, _cycles, _mps.
- Every public class needs a one-paragraph header explaining scientific assumptions.
- Add references as comments only where equations are implemented; do not paste long copyrighted text.
- Keep generated figures/PDF/MAT/JSON out of git.
- Never weaken an existing guard just to make a test pass. If a guard blocks a scenario, either implement the missing science correctly or keep the guard and document it.

Deliver the branch as step-by-step commits exactly following the stages above. Do not squash locally during development; each stage must be independently reviewable and scientifically validated.