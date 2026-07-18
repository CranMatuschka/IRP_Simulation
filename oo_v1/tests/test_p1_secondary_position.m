% test_p1_secondary_position
%
% P1'/WP4: estimate each secondary's ORBIT [r,v] as EKF states (on top of WP3's
% clock), so per-satellite POSITION becomes a real, product-free estimated quantity.
% estimateMode='position' = full [r,v,b,bdot] per secondary; ground->secondary rows
% (WP5) supply the near-radial absolute position observable; ISL supplies the -u'
% relative column.
%
% Honesty: absolute position is radial<->clock WALL-LIMITED (metre-to-tens-of-metres,
% overconfident) without per-satellite two-way time transfer -- that is the documented
% expected outcome, checked as convergence + a populated diagnostic, NOT as tight
% consistency (the centroid-NEES gate is the follow-on realism task).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_p1_secondary_position ===\n');

% ---------------------------------------------------------------------
% T1: golden-safety -- nSpaceAssets=1 forces the orbit block off
% ---------------------------------------------------------------------
fprintf('  T1: single-asset forces P1 off ...\n');
c1 = i_cfg(1, 0.03); c1 = revgnss.ConfigFactory.finalizeConfig(c1);
e1 = filter.ReverseGNSSEKF(c1, 5, []);
assert(e1.estimateSecondaryOrbits == false, 'T1 FAILED: orbit estimated at nSpaceAssets=1');
assert(~isfield(e1.stateMap,'secondaryOrbitIdx') || isempty(e1.stateMap.secondaryOrbitIdx), ...
    'T1 FAILED: secondaryOrbitIdx present at nSpaceAssets=1');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: state layout -- full [r,v,b,bdot] per secondary, appended, disjoint
% ---------------------------------------------------------------------
fprintf('  T2: state layout ...\n');
c2 = revgnss.ConfigFactory.finalizeConfig(i_cfg(3, 0.03));
e2 = filter.ReverseGNSSEKF(c2, c2.scenario.nTowers, []);
sm = e2.stateMap;
assert(e2.estimateSecondaryOrbits && e2.nSecondaryOrbits == 2, 'T2 FAILED: not 2 secondary orbits');
assert(e2.estimateSecondaryClocks && e2.nSecondaryClocks == 2, 'T2 FAILED: position must include clocks');
assert(isequal(size(sm.secondaryOrbitIdx), [2 6]), 'T2 FAILED: secondaryOrbitIdx shape');
assert(max(sm.secondaryOrbitIdx(:)) == e2.nx, 'T2 FAILED: orbit block not last');
assert(isempty(intersect(sm.secondaryOrbitIdx(:), sm.secondaryClockIdx(:))), 'T2 FAILED: orbit/clock overlap');
assert(isempty(intersect(sm.secondaryOrbitIdx(:), [sm.r_idx(:);sm.v_idx(:);sm.b_rx_idx])), 'T2 FAILED: overlaps primary');
fprintf('    PASS (nx=%d, %d secondaries x [r,v,b,bdot])\n', e2.nx, e2.nSecondaryOrbits);

% ---------------------------------------------------------------------
% T3: measurement H -- ISL gains -u' and ground gains +u' on secondary position;
%     each position column touches exactly ONE asset (anti-circularity)
% ---------------------------------------------------------------------
fprintf('  T3: secondary-position measurement columns ...\n');
cM = i_cfg(2, 0.03); cM.simulation.duration_s = 5; cM = revgnss.ConfigFactory.finalizeConfig(cM);
simM = revgnss.ReverseGNSSSimulation(cM); simM.initialize();
smM = simM.ekf.stateMap; oi = smM.secondaryOrbitIdx(1,1:3);
[~,~,Hisl,~,~] = revgnss.ISLMeasurementBuilder.build(cM, simM.asset, simM.assets, simM.ekf.x, smM, simM.ekf.nx, 5);
codeRow = find(any(Hisl(:,oi) ~= 0, 2), 1);
assert(~isempty(codeRow), 'T3 FAILED: no ISL row touches secondary position');
[~,~,Hgs,~,gi] = revgnss.SecondaryGroundMeasurementBuilder.build(cM, simM.errorChain, simM.assets, simM.towers, simM.ekf.x, smM, simM.ekf.nx, 5);
assert(gi.nRows > 0 && any(any(Hgs(:,oi) ~= 0)), 'T3 FAILED: no ground row touches secondary position');
% ground row: +u' (unit norm) on the secondary position, no primary position column
grow = Hgs(1,:);
assert(abs(norm(grow(oi)) - 1) < 1e-6, 'T3 FAILED: ground H(sec pos) not a unit LOS');
assert(all(grow(smM.r_idx(:)) == 0), 'T3 FAILED: ground row touches primary position (contamination)');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T4: observability -- product-free secondary POSITION converges from the 100 m
%     prior (wall-limited absolute), diagnostic populated
% ---------------------------------------------------------------------
fprintf('  T4: secondary position observable product-free ...\n');
cV = i_cfg(2, 0.0);            % product-FREE: no assumed-known crutch
cV.simulation.duration_s = 3600;
simV = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cV));
simV.initialize(); simV.run();
smV = simV.ekf.stateMap; oiV = smV.secondaryOrbitIdx(1,1:3);
posErr = norm(simV.ekf.x(oiV) - simV.assets{2}.r_ecef_m);
posSig = sqrt(trace(simV.ekf.P(oiV,oiV)));
assert(posSig < 100, 'T4 FAILED: P(secondary pos) did not shrink below the 100 m prior');
assert(posErr < 40, 'T4 FAILED: secondary position did not converge (>40 m from 100 m prior)');
dV = simV.simData.getData();
assert(isfield(dV,'secondaryOrbit') && ~isempty(dV.secondaryOrbit.posError_m), 'T4 FAILED: no secondaryOrbit diagnostic');
assert(any(isfinite(dV.secondaryOrbit.posError_m(:))), 'T4 FAILED: diagnostic all NaN');
fprintf('    PASS (product-free secondary pos err=%.2f m [3D], sigma=%.2f m; wall-limited absolute)\n', posErr, posSig);

% ---------------------------------------------------------------------
% T5: validate guard -- 'position' requires towersObserveSecondaries
% ---------------------------------------------------------------------
fprintf('  T5: validate guard ...\n');
cBad = i_cfg(2, 0.03); cBad.multiAsset.towersObserveSecondaries = false;
threw = false;
try; validateMasterConfig(cBad); catch; threw = true; end
assert(threw, 'T5 FAILED: no error for position without towersObserveSecondaries');
fprintf('    PASS\n');

fprintf('=== test_p1_secondary_position: ALL PASS ===\n');

% =====================================================================
function cfg = i_cfg(nAssets, productPos)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nAssets; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.estimateMode = 'position';
    cfg.multiAsset.towersObserveSecondaries = true;
    if nAssets >= 2   % ISL requires >=2 assets
        cfg.measurements.isl.enable = true;
        cfg.measurements.isl.code.enable = true;    cfg.measurements.isl.code.useInEKF = true;
        cfg.measurements.isl.doppler.enable = true; cfg.measurements.isl.doppler.useInEKF = true;
        cfg.measurements.isl.transmitters = 'all';  cfg.measurements.isl.warmup_s = 0;
        cfg.measurements.isl.product.enable = true;
        cfg.measurements.isl.product.sigmaPos_m = productPos;
        cfg.measurements.isl.product.sigmaClock_m = 0; cfg.measurements.isl.product.sigmaVel_mps = 0;
        cfg.measurements.isl.product.sigmaClockDrift_mps = 0;
    end
    cfg.asset.clock.deterministic = false;
    cfg.simulation.duration_s = 1800;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never'; cfg.plots.showFigures=false;
end
