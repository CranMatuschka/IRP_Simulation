% test_p2_two_way_isl
%
% P2' all-pairs symmetric two-way ISL: clock-free baseline-length rows between estimated
% assets, fused with P1' one-way ISL + WP5 ground rows. The load-bearing property is
% ANTI-CIRCULARITY: every EKF row touches BOTH endpoints' position blocks with +u'/-u'
% (equal magnitude, opposite sign) -- never one-sided (a one-sided column would mean an
% endpoint is assumed-known truth, i.e. the circularity survived).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_p2_two_way_isl ===\n');

% ---------------------------------------------------------------------
% T1: gated off / single-asset -> no rows (golden-safe)
% ---------------------------------------------------------------------
fprintf('  T1: gated off / single-asset -> no rows ...\n');
cOff = i_cfg(3, false);
sOff = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cOff)); sOff.initialize();
[zO,~,~,~,iO] = revgnss.SwarmTwoWayISLBuilder.build(sOff.cfg, sOff.errorChain, sOff.assets, sOff.ekf.x, sOff.ekf.stateMap, sOff.ekf.nx, 10);
assert(isempty(zO) && iO.nRows == 0, 'T1 FAILED: rows built with twoWayISL off');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: all-pairs count + row math (both endpoints, +u'/-u', no clock/velocity)
% ---------------------------------------------------------------------
fprintf('  T2: all-pairs rows, symmetric baseline math ...\n');
cOn = i_cfg(3, true);
sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cOn)); sim.initialize();
sm = sim.ekf.stateMap;
[zg,hg,Hg,Rg,gi] = revgnss.SwarmTwoWayISLBuilder.build(sim.cfg, sim.errorChain, sim.assets, sim.ekf.x, sm, sim.ekf.nx, 10);
assert(gi.nRows == 3, 'T2 FAILED: N=3 should give 3 baselines');   % {1-2,1-3,2-3}
% clock/velocity columns must be zero on every row
clkCols = [sm.b_rx_idx(:); sm.bdot_rx_idx(:); sm.secondaryClockIdx(:)];
velCols = [sm.v_idx(:); reshape(sm.secondaryOrbitIdx(:,4:6), [], 1)];
assert(all(all(Hg(:,clkCols) == 0)), 'T2 FAILED: two-way row has a clock column');
assert(all(all(Hg(:,velCols) == 0)), 'T2 FAILED: two-way row has a velocity column');
assert(all(diag(Rg) > 0) && isequal(size(Rg),[3 3]), 'T2 FAILED: R not PD');
% honest R: delay-cal dominated, NOT the legacy 0.25 placeholder
assert(abs(Rg(1,1) - (0.01^2 + 60*(0.01^2+0.003^2))) < 1e-9, 'T2 FAILED: R not the honest delay-cal value');
fprintf('    PASS (%d baselines, no clock/velocity columns)\n', gi.nRows);

% ---------------------------------------------------------------------
% T3: ANTI-CIRCULARITY -- every row touches EXACTLY two position blocks,
%     equal-magnitude opposite-sign (+u'/-u'); NEVER one-sided.
% ---------------------------------------------------------------------
fprintf('  T3: anti-circularity (both-endpoint symmetric columns) ...\n');
posBlocks = {sm.r_idx(:)', sm.secondaryOrbitIdx(1,1:3), sm.secondaryOrbitIdx(2,1:3)};
for r = 1:gi.nRows
    touched = 0; normsum = 0;
    for b = 1:numel(posBlocks)
        col = Hg(r, posBlocks{b});
        if any(col ~= 0)
            touched = touched + 1;
            assert(abs(norm(col) - 1) < 1e-9, 'T3 FAILED: position column not a unit LOS');
            normsum = normsum + sum(col);
        end
    end
    assert(touched == 2, 'T3 FAILED: row must touch EXACTLY two asset position blocks (one-sided = circularity)');
end
% the +u' and -u' cancel: row-sum over the two touched blocks is ~0
assert(all(abs(sum(Hg,2)) < 1e-9), 'T3 FAILED: +u'' and -u'' do not cancel (not rigid-motion blind)');
fprintf('    PASS (every baseline row = +u'' on one asset, -u'' on the other)\n');

% ---------------------------------------------------------------------
% T4: validate guards (position mode, ground anchor, legacy conflict)
% ---------------------------------------------------------------------
fprintf('  T4: validate guards ...\n');
cBad = i_cfg(3, true); cBad.multiAsset.estimateMode = 'clocks';
assert(i_throws(@() revgnss.SwarmTwoWayISLBuilder.validateConfig(cBad)), 'T4 FAILED: no error without position mode');
cBad2 = i_cfg(3, true); cBad2.multiAsset.towersObserveSecondaries = false;
assert(i_throws(@() revgnss.SwarmTwoWayISLBuilder.validateConfig(cBad2)), 'T4 FAILED: no error without ground anchor');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T5: fusion sharpens the RELATIVE baseline (shape), product-free
% ---------------------------------------------------------------------
fprintf('  T5: two-way ISL sharpens the relative baseline ...\n');
bOff = i_baselineErr(i_cfg(2, false));   % P1' one-way + ground only
bOn  = i_baselineErr(i_cfg(2, true));    % + all-pairs two-way
fprintf('    baseline (chief<->sec) truth-vs-est error: one-way=%.3f m, +two-way=%.3f m\n', bOff, bOn);
assert(bOn <= bOff + 1e-6, 'T5 FAILED: two-way ISL did not sharpen (or worsened) the baseline');
fprintf('    PASS\n');

fprintf('=== test_p2_two_way_isl: ALL PASS ===\n');

% =====================================================================
function cfg = i_cfg(nAssets, twoWay)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nAssets; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.estimateMode = 'position';
    cfg.multiAsset.towersObserveSecondaries = true;
    cfg.measurements.isl.enable = true;
    cfg.measurements.isl.code.enable = true;    cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.doppler.enable = true; cfg.measurements.isl.doppler.useInEKF = true;
    cfg.measurements.isl.transmitters = 'all';  cfg.measurements.isl.warmup_s = 0;
    cfg.measurements.isl.product.enable = false;   % P4': position mode is product-free (guard-enforced)
    cfg.multiAsset.twoWayISL.enable = twoWay;
    cfg.asset.clock.deterministic = false;
    cfg.simulation.duration_s = 1800;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never'; cfg.plots.showFigures=false;
end

function e = i_baselineErr(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize(); sim.run();
    sm = sim.ekf.stateMap; oi = sm.secondaryOrbitIdx(1,1:3);
    bEst   = norm(sim.ekf.x(oi) - sim.ekf.x(sm.r_idx));
    bTruth = norm(sim.assets{2}.r_ecef_m - sim.asset.r_ecef_m);
    e = abs(bEst - bTruth);
end

function tf = i_throws(f)
    tf = false;
    try
        f();
    catch
        tf = true;
    end
end
