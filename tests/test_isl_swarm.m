% test_isl_swarm
%
% One-way ISL swarm aiding into the primary EKF: multi-transmitter row generation,
% sign convention, and finite-difference Jacobian agreement.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_isl_swarm ===\n');

cfg = masterConfig();
% masterConfig wires the ISL swarm (incl. product-covariance-in-R) from ITS OWN
% cfg.scenario.nSpaceAssets value at construction time; overriding nSpaceAssets
% AFTER masterConfig() does NOT re-run that gate. Mirror the FULL helix-swarm
% ISL block here (run_ladder.m i_buildCfg 'else' branch), otherwise the swarm
% is built as truth but the product-uncertainty aiding never reaches R.
cfg.scenario.nSpaceAssets = 6;        % force the 6-asset swarm (default is 1 = ground-only)
cfg.measurements.isl.enable = true;
cfg.measurements.isl.transmitters = 'all';
cfg.measurements.isl.receiverAssetIndex = 1;
cfg.measurements.isl.code.enable = true;
cfg.measurements.isl.code.useInEKF = true;
cfg.measurements.isl.doppler.enable = true;
cfg.measurements.isl.doppler.useInEKF = true;
cfg.measurements.isl.product.enable = true;
cfg.measurements.isl.product.sigmaPos_m   = 0.03;   % ~3 cm SLR-class reference orbit
cfg.measurements.isl.product.sigmaClock_m = 0.02;   % ~67 ps reference clock product
cfg.simulation.duration_s = 5;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.showFigures = false;
cfg.measurements.isl.warmup_s = 0;    % activate ISL rows immediately for the test
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize(); sim.run();

x = sim.ekf.x; sm = sim.ekf.stateMap; nx = sim.ekf.nx;
[~, ~, H, R, info] = revgnss.ISLMeasurementBuilder.build(cfg, sim.asset, sim.assets, x, sm, nx, 5);

% ----------------------------------------------------------------
% T1: one EKF row per (code+Doppler) per secondary; symmetric PD R
% ----------------------------------------------------------------
fprintf('  T1: multi-transmitter row count and R ...\n');
nTx = cfg.scenario.nSpaceAssets - 1;          % transmitters='all'
assert(numel(info.transmitterList) == nTx, 'T1 FAILED: transmitter count');
assert(size(H,1) == 2*nTx, 'T1 FAILED: expected code+Doppler row per secondary');
assert(isequal(R, R') && all(eig(R) > 0), 'T1 FAILED: R not symmetric PD');
% product uncertainty inflates R above pure thermal
assert(R(1,1) > info.codeSigma_m^2, 'T1 FAILED: product covariance not in R');
fprintf('    PASS (%d secondaries, %d EKF rows)\n', nTx, size(H,1));

% ----------------------------------------------------------------
% T2: sign convention — +1 on receiver clock bias/drift partials
% ----------------------------------------------------------------
fprintf('  T2: clock sign convention ...\n');
codeRows = find(strcmp(info.ekfRowTypes,'islCode'));
dopRows  = find(strcmp(info.ekfRowTypes,'islDoppler'));
assert(all(H(codeRows, sm.b_rx_idx) == 1),    'T2 FAILED: code H(b_rx) must be +1');
assert(all(H(dopRows,  sm.bdot_rx_idx) == 1),  'T2 FAILED: Doppler H(bdot_rx) must be +1');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: finite-difference Jacobian agrees with analytic H (r,v,b,bdot)
% ----------------------------------------------------------------
fprintf('  T3: finite-difference Jacobian (code rows) ...\n');
h0 = revgnss.ISLMeasurementBuilder.predictEkfRows(cfg, sim.asset, sim.assets, x, sm, info);
cols = [sm.r_idx(:); sm.b_rx_idx];            % code rows have exact position + clock-bias partials
maxerr = 0;
for c = cols'
    xp = x; xp(c) = xp(c) + 1e-2;
    hp = revgnss.ISLMeasurementBuilder.predictEkfRows(cfg, sim.asset, sim.assets, xp, sm, info);
    fd = (hp - h0)/1e-2;
    maxerr = max(maxerr, max(abs(fd(codeRows) - H(codeRows,c))));
end
assert(maxerr < 1e-4, 'T3 FAILED: FD-analytic mismatch %.2e', maxerr);
fprintf('    PASS (max |FD-H| = %.2e)\n', maxerr);

fprintf('=== test_isl_swarm: ALL PASS ===\n');
