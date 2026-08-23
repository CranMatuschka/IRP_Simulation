function test_stage86_geo_realworld_truth_comparison_smoke
% test_stage86_geo_realworld_truth_comparison_smoke  Short Stage 86 run.

fprintf('=== test_stage86_geo_realworld_truth_comparison_smoke ===\n');
cfg = revgnss.ConfigFactory.geoRealWorldTruthComparisonConfig();
cfg.simulation.duration_s = 300;
cfg.simulation.dt_s = 10;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.plots.enable = false;
cfg.diagnostics.storage.mode = 'full';
cfg.diagnostics.storage.snapshot.enable = true;
cfg.diagnostics.storage.snapshot.interval_s = 300;
cfg.diagnostics.storage.snapshot.maxSnapshots = 2;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
revgnss.GeoRealWorldScenarioGuard.assertValid(cfg);

out = revgnss.ReportRunner.runSingle(cfg);
d = out.simData.getData();

assert(~isempty(d.error.positionNorm_m), 'simulation produced no epochs.');
assert(any(isfinite(d.error.positionNorm_m)), 'position error field is not finite.');
assert(any(isfinite(d.error.velocityNorm_mps)), 'velocity error field is not finite.');
assert(any(isfinite(d.error.attitudeNorm_deg)) || any(d.attitude.separable == 0), ...
    'attitude error must be finite or explicitly weak/unobservable.');
assert(any(isfinite(d.error.clockBias_m)), 'receiver-clock error field is not finite.');

[~, ~, ~, R, errStruct] = out.sim.measModel.computeMeasurements( ...
    out.sim.asset, out.sim.towers, out.sim.ekf.getMeasurementState(), ...
    out.sim.tVec(end), out.sim.ekf.stateMap);
assertSourceTotals_(errStruct);
assert(~isempty(R), 'no non-empty R matrix found.');
assert(all(isfinite(R(:))), 'R contains non-finite values.');
assert(norm(R-R','fro') < 1e-8 * max(1,norm(R,'fro')), 'R is not symmetric.');
[~, p] = chol((R+R')/2);
assert(p == 0, 'R is not SPD.');
assert(isfield(errStruct,'productClockStackCov'), 'product-clock stack covariance diagnostics missing.');

cfgOut = out.cfg;
assert(~strcmp(cfgOut.estimator.towerClockMode, 'perfectCorrection'), 'forbidden perfectCorrection in output config.');
assert(~strcmp(cfgOut.estimator.dynamics.mode, 'constantVelocity'), 'forbidden constantVelocity in output config.');
assert(~strcmp(cfgOut.orbit.truth.mode, 'stationaryEcef'), 'forbidden stationaryEcef in output config.');
assert(~cfgOut.estimator.integerAmbiguityFixing.enable, 'integer fixing enabled in output config.');

assert(any(d.perSource.trop > 0), 'troposphere residual is zero.');
assert(any(d.perSource.iono > 0), 'ionosphere residual is zero.');
assert(any(d.perSource.hwDelay > 0), 'hardware residual is zero.');
assert(any(d.perSource.mp > 0), 'multipath truth residual is zero.');

fprintf('=== test_stage86_geo_realworld_truth_comparison_smoke: PASS ===\n');
end

function assertSourceTotals_(errStruct)
labels = errStruct.labels;
truthSum = zeros(size(errStruct.truthTotal_m));
modelSum = zeros(size(errStruct.modelTotal_m));
for k = 1:numel(labels)
    lbl = labels{k};
    if isfield(errStruct.bySource.truth_m, lbl)
        truthSum = truthSum + errStruct.bySource.truth_m.(lbl);
    end
    if isfield(errStruct.bySource.model_m, lbl)
        modelSum = modelSum + errStruct.bySource.model_m.(lbl);
    end
end
tol = 1e-10 * max(1, norm(errStruct.truthTotal_m));
assert(norm(truthSum - errStruct.truthTotal_m) <= tol, ...
    'per-source truth contributions do not reconstruct truthTotal_m.');
tolM = 1e-10 * max(1, norm(errStruct.modelTotal_m));
assert(norm(modelSum - errStruct.modelTotal_m) <= tolM, ...
    'per-source model contributions do not reconstruct modelTotal_m.');
end
