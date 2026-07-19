% test_swarm_twstft_isl
%
% Sat<->sat two-way TIME transfer ISL (dual of P2'): observes the inter-satellite CLOCK
% difference (H +1 on clk_i, -1 on clk_k, no position column) and pins the swarm's RELATIVE
% clocks to each other. Default OFF (breaks reverse-GNSS transmit premise).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_swarm_twstft_isl ===\n');

% ---------------------------------------------------------------------
% T1: gated off -> no rows (golden-safe)
% ---------------------------------------------------------------------
fprintf('  T1: gated off -> no rows ...\n');
cOff = i_clocks(3, 5, false);
sOff = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cOff)); sOff.initialize();
[zO,~,~,~,iO] = revgnss.SwarmTwoWayTimeTransferBuilder.build(sOff.cfg, sOff.errorChain, sOff.assets, sOff.ekf.x, sOff.ekf.stateMap, sOff.ekf.nx, 5);
assert(isempty(zO) && iO.nRows == 0, 'T1 FAILED: rows built when disabled');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: all-pairs rows, +1/-1 on clocks, NO position/velocity column
% ---------------------------------------------------------------------
fprintf('  T2: clock-difference row math ...\n');
cOn = i_clocks(3, 5, true);
sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cOn)); sim.initialize();
sm = sim.ekf.stateMap;
[z,~,H,R,gi] = revgnss.SwarmTwoWayTimeTransferBuilder.build(sim.cfg, sim.errorChain, sim.assets, sim.ekf.x, sm, sim.ekf.nx, 5);
assert(gi.nRows == 3, 'T2 FAILED: 3 clocks (primary+2 sec) should give 3 pairs');   % nchoosek(3,2)
posCols = [sm.r_idx(:)' sm.v_idx(:)'];
clkCols = [sm.b_rx_idx, sm.secondaryClockIdx(:,1)'];
for r = 1:gi.nRows
    assert(all(H(r, posCols) == 0), 'T2 FAILED: two-way TIME row has a position/velocity column');
    onClk = H(r, clkCols);
    assert(sum(onClk == 1) == 1 && sum(onClk == -1) == 1 && sum(onClk ~= 0) == 2, ...
        'T2 FAILED: row not exactly +1 on one clock and -1 on another');
end
assert(all(diag(R) > 0), 'T2 FAILED: R not positive');
fprintf('    PASS (%d clock-difference rows, +1/-1 on clocks, no position column)\n', gi.nRows);

% ---------------------------------------------------------------------
% T3: pins the inter-satellite RELATIVE clock (sec - primary)
% ---------------------------------------------------------------------
fprintf('  T3: sat<->sat TWSTFT pins the relative clock ...\n');
eOff = i_relClkErr(i_clocks(2, 1800, false));   % ISL-only: relative clock loosely tied
eOn  = i_relClkErr(i_clocks(2, 1800, true));    % + sat<->sat TWSTFT -> pinned
fprintf('    relative clock (sec-primary) err RMS: ISL-only=%.3f m, +TWSTFT-ISL=%.4f m\n', eOff, eOn);
assert(eOn < eOff, 'T3 FAILED: sat<->sat TWSTFT did not sharpen the relative clock');
assert(eOn < 0.5, 'T3 FAILED: relative clock not pinned sub-0.5 m (~1.7 ns)');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T4: validate guard (useInEKF needs estimated secondary clocks)
% ---------------------------------------------------------------------
fprintf('  T4: validate guard ...\n');
cN = masterConfig(); cN.scenario.nSpaceAssets = 1;
cN.multiAsset.twoWayTimeTransferISL.enable = true; cN.multiAsset.twoWayTimeTransferISL.useInEKF = true;
assert(i_throws(@() revgnss.SwarmTwoWayTimeTransferBuilder.validateConfig(cN)), 'T4 FAILED: no-secondary-clocks not caught');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T5: parity guard -- pair-node encoding caps at 63 assets (mirror P2')
% ---------------------------------------------------------------------
fprintf('  T5: nSpaceAssets<=63 guard ...\n');
c63 = masterConfig(); c63.scenario.nSpaceAssets = 64;
c63.multiAsset.twoWayTimeTransferISL.enable = true;
assert(i_throws(@() revgnss.SwarmTwoWayTimeTransferBuilder.validateConfig(c63)), 'T5 FAILED: nSpaceAssets>63 not caught');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T6: parity guard -- independent streams required on ENABLE (not just useInEKF),
%     since the diagnostic thermal/delay draws happen even with useInEKF=false
% ---------------------------------------------------------------------
fprintf('  T6: independentStreams required on enable ...\n');
cIS = masterConfig(); cIS.scenario.nSpaceAssets = 2;
cIS.multiAsset.twoWayTimeTransferISL.enable = true; cIS.multiAsset.twoWayTimeTransferISL.useInEKF = false;
cIS.rng.independentStreams.enable = false;
assert(i_throws(@() revgnss.SwarmTwoWayTimeTransferBuilder.validateConfig(cIS)), 'T6 FAILED: shared-stream not caught on enable');
fprintf('    PASS\n');

fprintf('=== test_swarm_twstft_isl: ALL PASS ===\n');

% =====================================================================
function cfg = i_clocks(nA, dur, ttOn)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nA; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.estimateMode = 'clocks';
    cfg.measurements.isl.enable = true;
    cfg.measurements.isl.code.enable = true;    cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.doppler.enable = true; cfg.measurements.isl.doppler.useInEKF = true;
    cfg.measurements.isl.transmitters = 'all';  cfg.measurements.isl.warmup_s = 0;
    cfg.measurements.isl.product.enable = true;
    cfg.asset.clock.deterministic = false;
    cfg.multiAsset.twoWayTimeTransferISL.enable   = ttOn;
    cfg.multiAsset.twoWayTimeTransferISL.useInEKF = ttOn;
    cfg.simulation.duration_s = dur;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never';
    cfg.plots.showFigures=false; cfg.plots.enable=false;
end

function e = i_relClkErr(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize(); sim.run();
    d = sim.simData.getData();
    % relative clock error = (sec_est-sec_true) - (prim_est-prim_true) = secErr - primErr
    secErr  = d.secondaryClock.error_m(1,:).';   % [nEpoch]
    primErr = d.error.clockBias_m(:);
    n = min(numel(secErr), numel(primErr));
    rel = secErr(1:n) - primErr(1:n); rel = rel(isfinite(rel));
    k = (floor(0.5*numel(rel))+1):numel(rel);
    e = sqrt(mean(rel(k).^2));
end

function tf = i_throws(f)
    tf = false;
    try
        f();
    catch
        tf = true;
    end
end
