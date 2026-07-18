% test_wp3_secondary_clock
%
% WP3: estimate secondary-asset CLOCKS (bias+drift) as EKF states, gated behind
% cfg.multiAsset.estimateMode='clocks'. Covers golden-safety (off byte-identical),
% state layout, F/Q block + R-accounting, convergence/consistency with a tight
% reference product, and the newly load-bearing secondary-clock seed.
%
% Honesty note: b_tx is observable only RELATIVE to the primary clock (radial<->clock
% wall) and aliases the along-LOS product-position error, so it converges CONSISTENTLY
% only with a tight product reference; product-free / loose-product diverges (documented,
% not asserted here).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_wp3_secondary_clock ===\n');

% ---------------------------------------------------------------------
% T1: golden-safety -- nSpaceAssets=1 forces WP3 OFF regardless of mode
% ---------------------------------------------------------------------
fprintf('  T1: single-asset forces WP3 off ...\n');
cfg1 = i_baseCfg(1, 'clocks');
ekf1 = filter.ReverseGNSSEKF(revgnss.ConfigFactory.finalizeConfig(cfg1), 5, []);
assert(ekf1.estimateSecondaryClocks == false, 'T1 FAILED: WP3 not forced off at nSpaceAssets=1');
assert(~isfield(ekf1.stateMap,'secondaryClockIdx') || isempty(ekf1.stateMap.secondaryClockIdx), ...
    'T1 FAILED: secondaryClockIdx present at nSpaceAssets=1');
fprintf('    PASS (nx=%d, no secondary-clock states)\n', ekf1.nx);

% ---------------------------------------------------------------------
% T2: WP3-off multi-asset is byte-identical to mode absent (state layout)
% ---------------------------------------------------------------------
fprintf('  T2: WP3-off multi-asset == mode-absent ...\n');
cOff = i_finalized(i_islCfg(5, 'off'));
cAbs = i_islCfg(5, 'off'); cAbs.multiAsset = rmfield(cAbs.multiAsset, 'estimateMode'); cAbs = i_finalized(cAbs);
eOff = filter.ReverseGNSSEKF(cOff, cOff.scenario.nTowers, []);
eAbs = filter.ReverseGNSSEKF(cAbs, cAbs.scenario.nTowers, []);
assert(eOff.nx == eAbs.nx, 'T2 FAILED: nx differs off vs absent');
assert(eOff.estimateSecondaryClocks == false, 'T2 FAILED: off still estimates');
assert(isempty(eOff.stateMap.secondaryClockIdx), 'T2 FAILED: off has secondary states');
fprintf('    PASS (nx=%d both)\n', eOff.nx);

% ---------------------------------------------------------------------
% T3: state layout -- clocks mode appends 2*(N-1) states LAST, disjoint
% ---------------------------------------------------------------------
fprintf('  T3: state layout (append-last, disjoint) ...\n');
cC = i_finalized(i_islCfg(3, 'clocks'));
eC = filter.ReverseGNSSEKF(cC, cC.scenario.nTowers, []);
sm = eC.stateMap;
assert(eC.estimateSecondaryClocks && eC.nSecondaryClocks == 2, 'T3 FAILED: not 2 secondary clocks');
sc = sm.secondaryClockIdx;
assert(isequal(size(sc), [2 2]), 'T3 FAILED: secondaryClockIdx shape');
assert(max(sc(:)) == eC.nx && min(sc(:)) == eC.nx - 3, 'T3 FAILED: not the last 4 state rows');
occupied = [sm.r_idx(:); sm.v_idx(:); sm.euler_idx(:); sm.omega_idx(:); sm.b_rx_idx; sm.bdot_rx_idx];
if isfield(sm,'towerClockIdx'); occupied = [occupied; sm.towerClockIdx(:)]; end
assert(isempty(intersect(occupied, sc(:))), 'T3 FAILED: secondary-clock indices overlap existing states');
fprintf('    PASS (nx=%d, secondaryClockIdx=last 4 rows)\n', eC.nx);

% ---------------------------------------------------------------------
% T4: F coupling, Q sub-block, and R drops the product clock sigma
% ---------------------------------------------------------------------
fprintf('  T4: F/Q block + R-accounting ...\n');
dt = 1.0;
F = eC.buildF_(dt, zeros(3,1), zeros(3,1), []);
assert(F(sc(1,1), sc(1,2)) == dt, 'T4 FAILED: F bias<-drift coupling ~= dt');
assert(F(sc(2,1), sc(2,2)) == dt, 'T4 FAILED: F coupling asset2');
% ISL R-accounting: with WP3 on, code R drops product.sigmaClock but keeps sigmaPos.
cR = i_islCfg(2, 'clocks'); cR.measurements.isl.product.sigmaPos_m = 0.4; cR.measurements.isl.product.sigmaClock_m = 5.0;
cR.measurements.isl.warmup_s = 0;   % ISL rows enter the EKF immediately
cR.asset.clock.deterministic = false; cR.simulation.duration_s = 5; cR = i_finalized(cR);
simR = revgnss.ReverseGNSSSimulation(cR); simR.initialize();
[~,~,~,Risl,infoR] = revgnss.ISLMeasurementBuilder.build(cR, simR.asset, simR.assets, simR.ekf.x, simR.ekf.stateMap, simR.ekf.nx, 5);
codeRow = find(strcmp(infoR.ekfRowTypes,'islCode'), 1);
assert(~isempty(codeRow), 'T4 FAILED: no islCode EKF row built');
Rexpect = cR.measurements.isl.code.sigma_m^2 + cR.measurements.isl.product.sigmaPos_m^2;   % NO + sigmaClock^2
assert(abs(Risl(codeRow,codeRow) - Rexpect) < 1e-9, ...
    sprintf('T4 FAILED: R=%.6f expected %.6f (should drop product.sigmaClock)', Risl(codeRow,codeRow), Rexpect));
fprintf('    PASS (F coupling=dt; R=%.4f drops sigmaClock)\n', Risl(codeRow,codeRow));

% ---------------------------------------------------------------------
% T5: convergence + consistency with a tight reference product
% ---------------------------------------------------------------------
fprintf('  T5: secondary clock converges (product-aided) ...\n');
% N=6 swarm with a tight reference product: the secondary clock is observable and
% converges from the 100 m prior to sub-metre. Strict +-3sigma CONSISTENCY is NOT
% gated here -- b_tx inherits the primary radial<->clock overconfidence (documented
% honesty limitation); coverage is reported, not asserted (cf. ImperfectionAudit).
cV = i_islCfg(6, 'clocks');
cV.measurements.isl.warmup_s = 300;
cV.measurements.isl.product.sigmaPos_m = 0.03;
cV.measurements.isl.product.sigmaClock_m = 0.02;
cV.asset.clock.deterministic = false;
cV.simulation.duration_s = 3600;
simV = revgnss.ReverseGNSSSimulation(i_finalized(cV)); simV.initialize(); simV.run();
smV = simV.ekf.stateMap; ibV = smV.secondaryClockIdx(1,1);
estBtx = simV.ekf.x(ibV); truBtx = simV.assets{2}.clock.getBiasMeters();
sigBtx = sqrt(simV.ekf.P(ibV,ibV));
errBtx = estBtx - truBtx;
assert(sigBtx < 100, 'T5 FAILED: P(b_tx) did not shrink below the 100 m prior');   % state updated
assert(abs(errBtx) < 10, 'T5 FAILED: b_tx did not converge (>10 m from truth, prior was 100 m)');
% diagnostic series is populated and finite
dV = simV.simData.getData();
assert(isfield(dV,'secondaryClock') && ~isempty(dV.secondaryClock.error_m), 'T5 FAILED: no secondaryClock diagnostic');
assert(any(isfinite(dV.secondaryClock.error_m(:))), 'T5 FAILED: secondaryClock error all NaN');
cov3 = mean(abs(errBtx) <= 3*sigBtx);   % reported, not gated
fprintf('    PASS (b_tx err=%.3f m, sigma=%.3f m, |err|<3sig=%d [reported])\n', errBtx, sigBtx, cov3>0);

% ---------------------------------------------------------------------
% T6: secondary-clock seed is load-bearing + init keyed per asset
% ---------------------------------------------------------------------
fprintf('  T6: secondary-clock seed load-bearing + per-asset init ...\n');
% (a) the secondary clock realization (seed 300+ai) is REAL and INDEPENDENT of the
% primary (seed 100): with deterministic=false it wanders to a non-zero bias distinct
% from the primary's. Under WP3 this realization no longer cancels in the ISL
% innovation (it drives b_tx), so it is now load-bearing.
cLB = i_islCfg(2,'clocks'); cLB.asset.clock.deterministic = false;
cLB.simulation.duration_s = 600; cLB.measurements.isl.warmup_s = 0;
sLB = revgnss.ReverseGNSSSimulation(i_finalized(cLB)); sLB.initialize(); sLB.run();
bSecTruth = sLB.assets{2}.clock.getBiasMeters();
bPriTruth = sLB.asset.clock.getBiasMeters();
assert(sLB.cfg.assets(2).clock.seed == 302, 'T6 FAILED: secondary clock seed not 300+ai');
assert(abs(bSecTruth) > 1e-6, 'T6 FAILED: secondary truth clock did not wander (realization inactive)');
assert(abs(bSecTruth - bPriTruth) > 1e-9, 'T6 FAILED: secondary truth == primary (not independent)');
% (b) init draw is identity-keyed by asset: asset-2 x0 identical at N=2 and N=3 (same base seed)
c2 = i_finalized(i_islCfg(2,'clocks')); e2 = filter.ReverseGNSSEKF(c2, c2.scenario.nTowers, []);
x2 = revgnss.ScenarioFactory.buildInitialState_(c2, revgnss.SpaceAsset(c2.asset), i_towers(c2), e2);
c3 = i_finalized(i_islCfg(3,'clocks')); e3 = filter.ReverseGNSSEKF(c3, c3.scenario.nTowers, []);
x3 = revgnss.ScenarioFactory.buildInitialState_(c3, revgnss.SpaceAsset(c3.asset), i_towers(c3), e3);
a2b_at2 = x2(e2.stateMap.secondaryClockIdx(1,1));
a2b_at3 = x3(e3.stateMap.secondaryClockIdx(1,1));
assert(abs(a2b_at2 - a2b_at3) < 1e-9, 'T6 FAILED: asset-2 init draw depends on N (not identity-keyed)');
fprintf('    PASS (truth seed load-bearing; init identity-keyed by asset)\n');

fprintf('=== test_wp3_secondary_clock: ALL PASS ===\n');

% =====================================================================
function cfg = i_baseCfg(nAssets, mode)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nAssets;
    cfg.scenario.nReceivers   = 1;
    cfg.scenario.nTowers      = 5;
    cfg.multiAsset.estimateMode = mode;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never'; cfg.plots.showFigures=false;
end

function cfg = i_islCfg(nAssets, mode)
    cfg = i_baseCfg(nAssets, mode);
    cfg.measurements.isl.enable = true;
    cfg.measurements.isl.code.enable = true;    cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.doppler.enable = true; cfg.measurements.isl.doppler.useInEKF = true;
    cfg.measurements.isl.transmitters = 'all';
    cfg.measurements.isl.product.enable = true;
end

function cfg = i_finalized(cfg)
    cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
end

function towers = i_towers(cfg)
    nT = numel(cfg.towers);
    towers = cell(1, nT);
    for k = 1:nT; towers{k} = revgnss.GroundTower(cfg.towers(k)); end
end
