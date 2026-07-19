% test_p1_realism_guards
%
% P1' realism guards A/B/C -- what make the per-satellite ABSOLUTE honest (or honestly
% flagged) rather than a hidden crutch:
%   A  divergent per-LOS uplink atmosphere (truth-side, per-tower-shared, interval-correlated)
%   B  one-sided truth-side SRP/luni-solar dynamic gap (EKF stays J2)
%   C  per-satellite + formation-CENTROID NEES (cross-covariance) consistency gate

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_p1_realism_guards ===\n');

% =====================================================================
% GUARD A -- divergent uplink atmosphere
% =====================================================================
fprintf('  A1: atmosphere truth-side, off byte-identical ...\n');
cA = i_posCfg(3);
simA = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cA)); simA.initialize();
args = {simA.errorChain, simA.assets, simA.towers, simA.ekf.x, simA.ekf.stateMap, simA.ekf.nx, 100};
[zOff,hOff,~,ROff] = revgnss.SecondaryGroundMeasurementBuilder.build(simA.cfg, args{:});
cAon = simA.cfg; cAon.multiAsset.towerSecondary.atmosphere.enable = true;
[zOn,hOn,~,ROn]  = revgnss.SecondaryGroundMeasurementBuilder.build(cAon, args{:});
assert(isequal(hOff,hOn), 'A1 FAILED: atmosphere changed h (must be truth-side only)');
assert(~isequal(zOff,zOn), 'A1 FAILED: atmosphere did not change z');
assert(isequal(ROff,ROn), 'A1 FAILED: chargeR=false must leave R unchanged');
% default-off byte identity
cAabsent = simA.cfg; cAabsent.multiAsset.towerSecondary = rmfield(cAabsent.multiAsset.towerSecondary,'atmosphere');
[zAbs,~,~,~] = revgnss.SecondaryGroundMeasurementBuilder.build(cAabsent, args{:});
assert(isequal(zOff,zAbs), 'A1 FAILED: enable=false differs from field-absent');
fprintf('    PASS (h unchanged; z gains truth-side bias; off==absent)\n');

fprintf('  A2: per-tower keyed + interval-correlated (drawKeyedInterval) ...\n');
ec = simA.errorChain;
src = models.noise.RngSource.ATMO_SEC_UPLINK;
uk3  = ec.drawKeyedInterval(src, 3, 0, 0, 5);   % tower 3, tropo, interval 5
uk3b = ec.drawKeyedInterval(src, 3, 0, 0, 5);   % same key -> identical (order-independent)
uk4  = ec.drawKeyedInterval(src, 4, 0, 0, 5);   % different tower node
uk3n = ec.drawKeyedInterval(src, 3, 0, 0, 6);   % different interval
assert(uk3 == uk3b, 'A2 FAILED: same interval key not reproducible/shared');
assert(uk3 ~= uk4,  'A2 FAILED: different towers gave identical draw');
assert(uk3 ~= uk3n, 'A2 FAILED: different intervals gave identical draw');
% interval interpolation => strong correlation within an interval (first-diff variance small)
tau = 1800; ts = 100:30:1600; g = zeros(size(ts));
for q = 1:numel(ts)
    k = floor(ts(q)/tau); f = ts(q)/tau - k;
    u0 = ec.drawKeyedInterval(src, 3, 0, 0, k); u1 = ec.drawKeyedInterval(src, 3, 0, 0, k+1);
    g(q) = ((1-f)*u0 + f*u1) / sqrt((1-f)^2 + f^2);
end
assert(var(diff(g)) < 2*var(g), 'A2 FAILED: not temporally correlated (looks white)');
fprintf('    PASS\n');

% =====================================================================
% GUARD B -- truth-side dynamics applier
% =====================================================================
fprintf('  B1: applier gating + activation + one-sidedness ...\n');
cOff = masterConfig();                          % default: injectTruthSideDynamics=false
assert(cOff.orbit.truth.perturbations.luniSolar.enable == false, 'B1 FAILED: default not off');
cGuard = i_posCfg(2); cGuard.multiAsset.injectTruthSideDynamics = true;
cGuard = applyInjectTruthSideDynamics(cGuard);
assert(cGuard.orbit.truth.perturbations.luniSolar.enable && cGuard.orbit.truth.perturbations.srp.enable, ...
    'B1 FAILED: truth perturbations not enabled');
assert(cGuard.multiAsset.secondaryOrbit.sigma_accel_mps2 == 1e-5, 'B1 FAILED: secondary SNC not set');
% swarm/mode guard: nSpaceAssets=1 -> no-op
c1 = i_posCfg(2); c1.multiAsset.injectTruthSideDynamics = true; c1.scenario.nSpaceAssets = 1;
c1 = applyInjectTruthSideDynamics(c1);
assert(c1.orbit.truth.perturbations.luniSolar.enable == false, 'B1 FAILED: fired at nSpaceAssets=1');
% defensive one-sidedness: EKF-side already on -> error
cConf = i_posCfg(2); cConf.multiAsset.injectTruthSideDynamics = true;
cConf.estimator.dynamics.perturbations.luniSolar.enable = true;
threw = false; try; applyInjectTruthSideDynamics(cConf); catch; threw = true; end
assert(threw, 'B1 FAILED: no error when EKF-side perturbations already on');
fprintf('    PASS\n');

fprintf('  B2: separate secondary SNC in Q (does not move primary) ...\n');
cQ = revgnss.ConfigFactory.finalizeConfig(i_posCfg(2));
cQ.multiAsset.secondaryOrbit.sigma_accel_mps2 = 7e-6;
eQ = filter.ReverseGNSSEKF(cQ, cQ.scenario.nTowers, []);
saPrim = cQ.estimator.sigma_accel_mps2;
Q = eQ.buildQ_(1.0, {}, {});
oi = eQ.stateMap.secondaryOrbitIdx(1,:);
assert(abs(Q(oi(4),oi(4)) - 7e-6^2*1.0) < 1e-20, 'B2 FAILED: secondary Q_vv not the separate SNC');
assert(abs(Q(eQ.stateMap.v_idx(1),eQ.stateMap.v_idx(1)) - saPrim^2*1.0) < 1e-18, 'B2 FAILED: primary Q_vv moved');
fprintf('    PASS (secondary SNC 7e-6, primary %.2g independent)\n', saPrim);

% =====================================================================
% GUARD C -- per-sat + centroid NEES (cross-covariance)
% =====================================================================
fprintf('  C1: centroid NEES cross-covariance (analytic) ...\n');
cC = revgnss.ConfigFactory.finalizeConfig(i_posCfg(2));
eC = filter.ReverseGNSSEKF(cC, cC.scenario.nTowers, []);
sm = eC.stateMap; oi1 = sm.secondaryOrbitIdx(1,1:3).';
% two position blocks: primary r_idx + secondary 1. Set a known P.
eC.P = eye(eC.nx);
pb = {sm.r_idx(:), oi1}; pe = {[3;0;0], [3;0;0]};      % same error -> ebar=[3;0;0]
% independent (P block-diagonal, already I): Pc = (I+I)/4 = 0.5 I -> NEES = (9/0.5)/3 = 6
cIndep = eC.centroidNEES_(pb, pe);
% correlated: set cross-block = I -> Pc = (I+I+I+I)/4 = I -> NEES = (9/1)/3 = 3
eC.P(sm.r_idx(:), oi1) = eye(3); eC.P(oi1, sm.r_idx(:)) = eye(3);
cCorr = eC.centroidNEES_(pb, pe);
assert(abs(cIndep.pos - 6) < 1e-9, 'C1 FAILED: independent centroid NEES ~= 6');
assert(abs(cCorr.pos  - 3) < 1e-9, 'C1 FAILED: correlated centroid NEES ~= 3');
assert(cCorr.pos < cIndep.pos, 'C1 FAILED: cross-covariance did not lower NEES');
fprintf('    PASS (block-diag NEES=%.1f > correlated NEES=%.1f)\n', cIndep.pos, cCorr.pos);

fprintf('  C2: gate flags the overconfident absolute (A+B on) ...\n');
cRun = i_posCfg(3);
cRun.multiAsset.towerSecondary.atmosphere.enable = true;
cRun.multiAsset.injectTruthSideDynamics = true;
cRun = applyInjectTruthSideDynamics(cRun);
cRun.simulation.duration_s = 900;
simC = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cRun)); simC.initialize(); simC.run();
d = simC.simData.getData();
assert(isfield(d,'consistency') && isfield(d.consistency,'centroidNEES'), 'C2 FAILED: no centroid NEES');
cen = d.consistency.centroidNEES; cen = cen(isfinite(cen));
assert(~isempty(cen), 'C2 FAILED: centroid NEES all NaN');
assert(mean(cen) > 3, 'C2 FAILED: gate did not flag the overconfident absolute (centroid NEES should be >>1)');
assert(isequal(size(d.secondaryOrbit.neesPos,1), 2), 'C2 FAILED: per-sat NEES shape');
fprintf('    PASS (centroid NEES/dof mean=%.1f -> absolute FLAGGED, honest)\n', mean(cen));

fprintf('=== test_p1_realism_guards: ALL PASS ===\n');

% =====================================================================
function cfg = i_posCfg(nAssets)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nAssets; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.estimateMode = 'position';
    cfg.multiAsset.towersObserveSecondaries = true;
    cfg.measurements.isl.enable = true;
    cfg.measurements.isl.code.enable = true;    cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.doppler.enable = true; cfg.measurements.isl.doppler.useInEKF = true;
    cfg.measurements.isl.transmitters = 'all';  cfg.measurements.isl.warmup_s = 0;
    cfg.measurements.isl.product.enable = false;   % P4': position mode is product-free (guard-enforced)
    cfg.asset.clock.deterministic = false;
    cfg.simulation.duration_s = 1800;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never'; cfg.plots.showFigures=false;
end
