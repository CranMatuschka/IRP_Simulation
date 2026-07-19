% test_p3_secondary_twstft
%
% P3' per-secondary two-way time transfer: a ground-tower<->SECONDARY two-way exchange pins
% each secondary's clock b_tx DIRECTLY (H +1 on the secondary clock state, no position
% column), the two-way twin of WP-A. Default OFF (breaks the reverse-GNSS transmit premise).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_p3_secondary_twstft ===\n');

% ---------------------------------------------------------------------
% T1: gated off / single-asset -> no rows (golden-safe)
% ---------------------------------------------------------------------
fprintf('  T1: gated off / single-asset -> no rows ...\n');
cOff = i_clocks(3, 5, false);
sOff = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cOff)); sOff.initialize();
[zO,~,~,~,iO] = revgnss.SecondaryTwoWayTimeTransferBuilder.build(sOff.cfg, sOff.errorChain, sOff.assets, sOff.towers, sOff.ekf.x, sOff.ekf.stateMap, sOff.ekf.nx, 5);
assert(isempty(zO) && iO.nRows == 0, 'T1 FAILED: rows built with P3 disabled');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: row structure -- +1 on the secondary clock, NO position column
% ---------------------------------------------------------------------
fprintf('  T2: row math (+1 secondary clock, no position column) ...\n');
cOn = i_clocks(3, 5, true);
sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cOn)); sim.initialize();
sm = sim.ekf.stateMap;
[z,~,H,R,gi] = revgnss.SecondaryTwoWayTimeTransferBuilder.build(sim.cfg, sim.errorChain, sim.assets, sim.towers, sim.ekf.x, sm, sim.ekf.nx, 5);
assert(gi.nRows > 0 && ~isempty(z), 'T2 FAILED: no rows built when enabled');
% every row: exactly +1 on ONE secondary clock state, and ZERO on all position columns
posCols = sm.r_idx(:)';
if isfield(sm,'secondaryOrbitIdx') && ~isempty(sm.secondaryOrbitIdx); posCols = [posCols sm.secondaryOrbitIdx(:,1:3)']; end
secClkCols = sm.secondaryClockIdx(:,1)';
for r = 1:gi.nRows
    assert(all(H(r, posCols) == 0), 'T2 FAILED: two-way row has a POSITION column (range not cancelled)');
    onClk = H(r, secClkCols);
    assert(sum(onClk == 1) == 1 && all(onClk(onClk~=1) == 0), 'T2 FAILED: row not +1 on exactly one secondary clock');
end
assert(all(diag(R) > 0), 'T2 FAILED: R not positive');
fprintf('    PASS (%d rows, +1 on secondary clock, no position column)\n', gi.nRows);

% ---------------------------------------------------------------------
% T3: two-way pins the secondary clock -- b_tx error drops vs ISL-only (degenerate)
% ---------------------------------------------------------------------
fprintf('  T3: two-way pins the secondary clock ...\n');
eOff = i_clockErr(i_clocks(2, 1800, false));   % ISL-only: b_tx degenerate with primary radial
eOn  = i_clockErr(i_clocks(2, 1800, true));    % + two-way time transfer -> pinned
fprintf('    secondary clock err RMS: ISL-only=%.3f m, +two-way=%.4f m\n', eOff, eOn);
assert(eOn < eOff, 'T3 FAILED: two-way did not improve the secondary clock');
assert(eOn < 0.5, 'T3 FAILED: pinned secondary clock not sub-0.5 m (~1.7 ns)');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T4: validate guards
% ---------------------------------------------------------------------
fprintf('  T4: validate guards ...\n');
cU = i_clocks(3, 5, false); cU.measurements.secondaryTwoWayTimeTransfer.useInEKF = true;  % useInEKF without enable
assert(i_throws(@() revgnss.SecondaryTwoWayTimeTransferBuilder.validateConfig(cU)), 'T4 FAILED: useInEKF w/o enable not caught');
cN = masterConfig(); cN.scenario.nSpaceAssets = 1;                                          % enabled but no secondary clocks
cN.measurements.secondaryTwoWayTimeTransfer.enable = true;
assert(i_throws(@() revgnss.SecondaryTwoWayTimeTransferBuilder.validateConfig(cN)), 'T4 FAILED: no-secondary-clocks not caught');
fprintf('    PASS\n');

fprintf('=== test_p3_secondary_twstft: ALL PASS ===\n');

% =====================================================================
function cfg = i_clocks(nA, dur, p3on)
    % estimateMode='clocks': secondary clock is an EKF state observed by ISL (degenerate
    % with the primary radial) + optionally the P3' two-way link. No ground rows.
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nA; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.estimateMode = 'clocks';
    cfg.measurements.isl.enable = true;
    cfg.measurements.isl.code.enable = true;    cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.doppler.enable = true; cfg.measurements.isl.doppler.useInEKF = true;
    cfg.measurements.isl.transmitters = 'all';  cfg.measurements.isl.warmup_s = 0;
    cfg.measurements.isl.product.enable = true;                 % clocks mode: position from product
    cfg.asset.clock.deterministic = false;
    cfg.measurements.secondaryTwoWayTimeTransfer.enable   = p3on;
    cfg.measurements.secondaryTwoWayTimeTransfer.useInEKF  = p3on;
    cfg.simulation.duration_s = dur;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never';
    cfg.plots.showFigures=false; cfg.plots.enable=false;
end

function e = i_clockErr(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize(); sim.run();
    d = sim.simData.getData();
    err = d.secondaryClock.error_m(:);           % [nEpoch*nSec] est - truth
    err = err(isfinite(err));
    n = numel(err); keep = (floor(0.5*n)+1):n;    % post-convergence tail
    e = sqrt(mean(err(keep).^2));
end

function tf = i_throws(f)
    tf = false;
    try
        f();
    catch
        tf = true;
    end
end
