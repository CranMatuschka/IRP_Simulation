function test_stage86_geo_realworld_truth_comparison_config
% test_stage86_geo_realworld_truth_comparison_config  Stage 86 config guard tests.

fprintf('=== test_stage86_geo_realworld_truth_comparison_config ===\n');
cfg = revgnss.ConfigFactory.geoRealWorldTruthComparisonConfig();
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
revgnss.GeoRealWorldScenarioGuard.assertValid(cfg);

assert(~strcmp(cfg.estimator.towerClockMode, 'perfectCorrection'), 'perfectCorrection is forbidden.');
assert(~strcmp(cfg.orbit.truth.mode, 'stationaryEcef'), 'stationaryEcef truth is forbidden.');
assert(~strcmp(cfg.estimator.dynamics.mode, 'constantVelocity'), 'constantVelocity EKF dynamics are forbidden.');
assert(strcmp(cfg.orbit.truth.mode, 'j2Rk4'), 'truth must be j2Rk4.');
assert(strcmp(cfg.orbit.mode, 'j2Rk4'), 'orbit model must be j2Rk4.');
assert(strcmp(cfg.estimator.dynamics.mode, 'j2'), 'EKF dynamics must be j2.');
assert(~cfg.estimator.processNoise.modelMismatch.enable, 'modelMismatch process noise must be disabled.');
assert(cfg.estimator.processNoise.modelMismatch.sigma_mps2 == 0, 'modelMismatch sigma must be zero.');

assert(cfg.measurement.sigmaFloor_m >= 0.01, 'sigma floor too small.');
assert(cfg.errors.codeNoise.sigma_m >= 0.60, 'code sigma too small.');
assert(cfg.signals.L1.codeSigma0_m >= 0.60, 'L1 code sigma too small.');
assert(cfg.signals.L2.codeSigma0_m >= 0.90, 'L2 code sigma too small.');
assert(cfg.measurements.doppler.sigma_mps >= 0.03, 'Doppler sigma too small.');
assert(cfg.measurements.carrier.sigma_m >= 0.010, 'Carrier sigma too small.');

assert(~cfg.asset.clock.deterministic, 'receiver clock must be stochastic.');
assert(all(arrayfun(@(t) ~t.clock.deterministic, cfg.towers)), 'tower clocks must be stochastic.');
assert(~strcmp(cfg.estimator.attitudeCarrierMode, 'validationKnownAmbiguity'), 'known ambiguity validation forbidden.');
assert(~cfg.estimator.integerAmbiguityFixing.enable, 'integer fixing forbidden.');
assert(cfg.covariance.productClock.enable, 'product-clock covariance must be enabled.');
assert(cfg.covariance.productClock.crossCodeDoppler, 'cross code-Doppler product covariance must be enabled.');
assert(cfg.errors.troposphere.stochastic.enable, 'troposphere stochastic residual disabled.');
assert(cfg.errors.ionosphere.stochastic.enable, 'ionosphere stochastic residual disabled.');
assert(cfg.errors.troposphere.stochastic.modelResidual.enable, 'troposphere model residual disabled.');
assert(cfg.errors.ionosphere.stochastic.modelResidual.enable, 'ionosphere model residual disabled.');

cfg_bad = cfg;
cfg_bad.estimator.towerClockMode = 'perfectCorrection';
didThrow = false;
try
    revgnss.GeoRealWorldScenarioGuard.assertValid(cfg_bad);
catch
    didThrow = true;
end
assert(didThrow, 'guard must reject perfectCorrection.');

fprintf('=== test_stage86_geo_realworld_truth_comparison_config: PASS ===\n');
end
