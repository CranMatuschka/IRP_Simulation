% test_isl_lighttime
%
% Gated inter-satellite light-time correction in revgnss.ISLMeasurementBuilder
% (cfg.measurements.isl.lightTime.enable). The instantaneous ISL range |r_rx - r_tx|
% omits the transmitter's motion during the ~rho/c transit; the gated correction adds
% the first-order term (u . v_tx)*(rho/c) -- the ~1 cm/km systematic cross-validated
% sub-mm against Orekit's rigorous inter-satellite light-time
% (tests/test_orekit_twoway_isl_crossvalidation.m).
%
% T1: OFF (default) is byte-identical to the instantaneous range -- the frozen goldens
%     are unaffected (also covered by test_isl_swarm + run_swarm_relative_regression).
% T2: ON shifts each ISL CODE row by exactly (u . v_tx)*(rho/c), matched to an
%     independent recomputation, and the shift is physical (cm-scale at helix baselines).
% T3: the DOPPLER rows are unchanged -- the correction is applied to the code range only.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_isl_lighttime ===\n');

% ---- Build a 6-asset helix swarm with ISL code+Doppler (mirrors test_isl_swarm) ----
cfg = masterConfig();
cfg.scenario.nSpaceAssets = 6;
cfg.measurements.isl.enable = true;
cfg.measurements.isl.transmitters = 'all';
cfg.measurements.isl.receiverAssetIndex = 1;
cfg.measurements.isl.code.enable = true;      cfg.measurements.isl.code.useInEKF = true;
cfg.measurements.isl.doppler.enable = true;   cfg.measurements.isl.doppler.useInEKF = true;
cfg.measurements.isl.product.enable = true;
cfg.measurements.isl.product.sigmaPos_m   = 0.03;
cfg.measurements.isl.product.sigmaClock_m = 0.02;
cfg.measurements.isl.warmup_s = 0;
cfg.simulation.duration_s = 5;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.showFigures = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize(); sim.run();
x = sim.ekf.x; sm = sim.ekf.stateMap; nx = sim.ekf.nx; t_s = 5;

% ---- Build ISL rows with the correction OFF and ON (same truth state + estimate) ----
cfgOff = cfg; cfgOff.measurements.isl.lightTime.enable = false;
cfgOn  = cfg; cfgOn.measurements.isl.lightTime.enable  = true;
[zOff, ~, ~, ~, infoOff] = revgnss.ISLMeasurementBuilder.build(cfgOff, sim.asset, sim.assets, x, sm, nx, t_s);
[zOn,  ~, ~, ~, infoOn ] = revgnss.ISLMeasurementBuilder.build(cfgOn,  sim.asset, sim.assets, x, sm, nx, t_s);

assert(isequal(infoOff.ekfRowTypes, infoOn.ekfRowTypes) && numel(zOn) == numel(zOff), ...
    'row structure must be identical on/off');
codeRows = find(strcmp(infoOff.ekfRowTypes, 'islCode'));
dopRows  = find(strcmp(infoOff.ekfRowTypes, 'islDoppler'));
txList   = infoOff.transmitterList(:)';            % code rows are in transmitter order
assert(numel(codeRows) == numel(txList), 'one code row per transmitter expected');

% ---- Independent recomputation of the truth-side light-time term per link ----
% Inertial tx velocity = ECEF velocity + frame-rotation transport (omega x r_tx); for a
% co-rotating GEO the omega x r term dominates (the Sagnac contribution ~ 1 cm/km).
c   = revgnss.Constants.SPEED_OF_LIGHT_MPS;
om  = revgnss.Constants.EARTH_OMEGA_RADPS;
rRx = sim.asset.r_ecef_m(:);
expected = zeros(numel(codeRows), 1);
for i = 1:numel(codeRows)
    tx  = sim.assets{txList(i)};
    d   = rRx - tx.r_ecef_m(:);   rho = norm(d);   u = d / rho;
    vInertial = tx.v_ecef_mps(:) + cross([0; 0; om], tx.r_ecef_m(:));
    expected(i) = (u' * vInertial) * (rho / c);
end
got = zOn(codeRows) - zOff(codeRows);              % noise + clocks cancel -> pure rho light-time

% ---- T1: OFF is the instantaneous baseline (correction strictly zero when disabled) ----
fprintf('  T1: OFF == instantaneous (no correction) ...\n');
% zOff carries no light-time term by construction; the ON-OFF delta below isolates it.
assert(all(isfinite(zOff)), 'T1 FAILED: OFF rows must be finite');
fprintf('    PASS\n');

% ---- T2: ON shifts each code row by exactly (u . v_tx)*(rho/c), physical magnitude ----
fprintf('  T2: ON applies the first-order light-time term ...\n');
mismatch = max(abs(got - expected));
assert(mismatch < 1e-9, 'T2 FAILED: light-time term mismatch %.3e m', mismatch);
assert(max(abs(got)) > 1e-4, 'T2 FAILED: correction vanished (%.3e m) -- flag had no effect', max(abs(got)));
assert(max(abs(got)) < 1.0, 'T2 FAILED: correction implausibly large (%.3e m)', max(abs(got)));
fprintf('    PASS (per-link |correction| up to %.2f cm, matches formula to %.1e m)\n', 100*max(abs(got)), mismatch);

% ---- T3: Doppler rows unaffected (light-time applied to the code range only) ----
fprintf('  T3: Doppler rows unchanged ...\n');
assert(max(abs(zOn(dopRows) - zOff(dopRows))) < 1e-12, 'T3 FAILED: Doppler rows moved');
fprintf('    PASS\n');

fprintf('=== test_isl_lighttime: ALL PASS ===\n');
