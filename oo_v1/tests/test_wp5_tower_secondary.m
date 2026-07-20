% test_wp5_tower_secondary
%
% WP5: ground-tower -> secondary pseudorange rows that observe a secondary's clock
% bias b_tx against the KNOWN tower clock at a near-radial LOS, giving b_tx an
% ABSOLUTE ground anchor independent of the primary radial -- curing the WP3
% degeneracy (b_tx near-degenerate with the primary radial via the ~horizontal ISL LOS).
% Gated cfg.multiAsset.towersObserveSecondaries (default off).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_wp5_tower_secondary ===\n');

% ---------------------------------------------------------------------
% T1: golden-safety -- no rows when off, or when nSpaceAssets=1
% ---------------------------------------------------------------------
fprintf('  T1: gated off / single-asset -> no rows ...\n');
sOff = i_sim(2, false, 0.0, 5); simOff = sOff; simOff.initialize();
[zO,~,~,~,iO] = i_secRows(simOff, simOff.ekf.stateMap, 10);
assert(isempty(zO) && iO.nRows == 0, 'T1 FAILED: rows built with WP5 off');
assert(revgnss.MultiAssetConfig.groundSecondaryRowCount(simOff.cfg) == 0, 'T1 FAILED: gate not 0 when off');
fprintf('    PASS (no rows off)\n');

% ---------------------------------------------------------------------
% T2: row shape + sign -- single +1 at b_tx, no primary columns
% ---------------------------------------------------------------------
fprintf('  T2: row shape + H(b_tx)=+1 sign ...\n');
sOn = i_sim(2, true, 0.0, 5); simOn = sOn; simOn.initialize();
[zg,hg,Hg,Rg,gi] = i_secRows(simOn, simOn.ekf.stateMap, 10);
assert(gi.nRows > 0, 'T2 FAILED: no rows built with WP5 on');
sm = simOn.ekf.stateMap; bTxIdx = sm.secondaryClockIdx(1,1);
assert(all(Hg(:,bTxIdx) == 1), 'T2 FAILED: H(b_tx) ~= +1');
assert(all(sum(Hg ~= 0, 2) == 1), 'T2 FAILED: row touches >1 state (primary contamination)');
assert(all(Hg(:,sm.r_idx(:)) == 0, 'all'), 'T2 FAILED: row touches primary position');
assert(isequal(size(Rg), [gi.nRows gi.nRows]) && all(diag(Rg) > 0), 'T2 FAILED: R not PD');
fprintf('    PASS (%d rows, single +1 at b_tx)\n', gi.nRows);

% ---------------------------------------------------------------------
% T3: observability -- product-free, WP3 diverges but WP3+WP5 converges,
%     and the primary is NOT degraded (rows carry no primary columns).
% ---------------------------------------------------------------------
fprintf('  T3: ground anchor cures the WP3 degeneracy ...\n');
[radOff, btxOff, ~]      = i_run(2, false, 0.0);   % WP3 only, product-free -> diverges
[radOn,  btxOn,  sigOn]  = i_run(2, true,  0.0);   % WP3+WP5 product-free   -> converges
assert(abs(btxOff) > 20, 'T3 FAILED: WP3-only did not diverge (test premise)');
assert(abs(btxOn) < 1.0, 'T3 FAILED: WP3+WP5 b_tx did not converge to <1 m');
assert(abs(btxOn) <= 3*sigOn + 1e-6, 'T3 FAILED: WP3+WP5 b_tx inconsistent (>3 sigma)');
assert(radOn <= radOff + 1.0, 'T3 FAILED: WP5 degraded the primary radial');
fprintf('    PASS (b_tx %.2f m [WP3-only] -> %.3f m [WP3+WP5], sigma %.3f m; primary not degraded)\n', ...
    btxOff, btxOn, sigOn);

% ---------------------------------------------------------------------
% T4: validate guard -- WP5 on without estimateMode='clocks' -> error
% ---------------------------------------------------------------------
fprintf('  T4: validate guard ...\n');
cBad = masterConfig();
cBad.scenario.nSpaceAssets = 2;
cBad.multiAsset.estimateMode = 'off';
cBad.multiAsset.towersObserveSecondaries = true;
threw = false;
try; validateMasterConfig(cBad); catch; threw = true; end
assert(threw, 'T4 FAILED: no error for WP5 on without estimateMode=clocks');
fprintf('    PASS\n');

fprintf('=== test_wp5_tower_secondary: ALL PASS ===\n');

% =====================================================================
function sim = i_sim(nAssets, wp5, productPos, nTowers)
    cfg = i_cfg(nAssets, wp5, productPos, nTowers);
    sim = revgnss.ReverseGNSSSimulation(cfg);
end

function [z, h, H, R, info] = i_secRows(sim, sm, t_s)
    % Phase 3b-2 (C5): the tower->secondary rows are now emitted by the shared MeasurementModel
    % (SecondaryGroundMeasurementBuilder retired). Build one from the sim's cfg + errorChain so
    % the draws are identical to the retired static build.
    mm = models.measurements.MeasurementModel(sim.cfg, sim.errorChain);
    [z, h, H, R, info] = mm.computeSecondaryGroundRows(sim.assets, sim.towers, sim.ekf.x, sm, sim.ekf.nx, t_s);
end

function [radErr, btxErr, btxSig] = i_run(nAssets, wp5, productPos)
    sim = revgnss.ReverseGNSSSimulation(i_cfg(nAssets, wp5, productPos, 5));
    sim.initialize(); sim.run();
    sm = sim.ekf.stateMap; ib = sm.secondaryClockIdx(1,1);
    radErr = norm(sim.ekf.x(sm.r_idx) - sim.asset.r_ecef_m);
    btxErr = sim.ekf.x(ib) - sim.assets{2}.clock.getBiasMeters();
    btxSig = sqrt(sim.ekf.P(ib,ib));
end

function cfg = i_cfg(nAssets, wp5, productPos, nTowers)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nAssets; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = nTowers;
    cfg.multiAsset.estimateMode = 'clocks';
    cfg.multiAsset.towerSecondary.doppler.enable = false;   % clocks mode has no velocity state -> Doppler auto-off; explicit
    cfg.measurements.isl.enable = true;
    cfg.measurements.isl.code.enable = true;    cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.doppler.enable = true; cfg.measurements.isl.doppler.useInEKF = true;
    cfg.measurements.isl.transmitters = 'all';  cfg.measurements.isl.warmup_s = 0;
    cfg.measurements.isl.product.enable = true;
    cfg.measurements.isl.product.sigmaPos_m = productPos;
    cfg.measurements.isl.product.sigmaClock_m = 0; cfg.measurements.isl.product.sigmaVel_mps = 0;
    cfg.measurements.isl.product.sigmaClockDrift_mps = 0;
    cfg.multiAsset.towersObserveSecondaries = wp5;
    cfg.asset.clock.deterministic = false;
    cfg.simulation.duration_s = 1800;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never'; cfg.plots.showFigures=false;
end
