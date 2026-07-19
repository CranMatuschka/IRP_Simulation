% test_srp_coefficient_state
%
% Gated, default-OFF SRP scale-coefficient EKF state (primary): a dimensionless multiplier s
% on the reference SRP acceleration (Cr=s*refCr), appended LAST, estimated from the
% trajectory bending. Off -> no state -> golden byte-identical.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_srp_coefficient_state ===\n');

% ---------------------------------------------------------------------
% T1: OFF -> no state appended (golden-safe), srpScaleIdx empty
% ---------------------------------------------------------------------
fprintf('  T1: default OFF -> no SRP state ...\n');
cOff = revgnss.ConfigFactory.finalizeConfig(i_cfg(false));
eOff = filter.ReverseGNSSEKF(cOff, cOff.scenario.nTowers, []);
assert(eOff.estimateSrpScale == false, 'T1 FAILED: srp state active when off');
assert(~isfield(eOff.stateMap,'srpScaleIdx') || isempty(eOff.stateMap.srpScaleIdx), 'T1 FAILED: srpScaleIdx present when off');
nxOff = eOff.nx;
fprintf('    PASS (nx=%d, no SRP state)\n', nxOff);

% ---------------------------------------------------------------------
% T2: ON -> exactly one extra state, appended LAST
% ---------------------------------------------------------------------
fprintf('  T2: ON -> one extra state appended last ...\n');
cOn = revgnss.ConfigFactory.finalizeConfig(i_cfg(true));
eOn = filter.ReverseGNSSEKF(cOn, cOn.scenario.nTowers, []);
assert(eOn.estimateSrpScale == true, 'T2 FAILED: srp state not active');
assert(isscalar(eOn.stateMap.srpScaleIdx) && eOn.stateMap.srpScaleIdx == eOn.nx, 'T2 FAILED: srpScaleIdx not the last state');
assert(eOn.nx == nxOff + 1, 'T2 FAILED: nx did not grow by exactly 1');
fprintf('    PASS (nx=%d = %d+1, srpScaleIdx=%d)\n', eOn.nx, nxOff, eOn.stateMap.srpScaleIdx);

% ---------------------------------------------------------------------
% T3: functional -- truth SRP on, the state LEARNS the scale from s=0 -> ~1
% ---------------------------------------------------------------------
fprintf('  T3: SRP scale is estimated (truth s=1.0) ...\n');
cf = i_cfg(true);
cf.orbit.truth.perturbations.srp.enable = true; cf.orbit.truth.perturbations.srp.Cr = 1.3;
cf.orbit.truth.perturbations.srp.areaToMass_m2pkg = 0.02;
cf.orbit.truth.perturbations.luniSolar.enable = false;
cf.estimator.srpCoefficient.initScale = 0;   % start J2 (no SRP), LEARN the force
cf.estimator.srpCoefficient.initSigma = 1.0; cf.estimator.srpCoefficient.procNoise = 1e-6;
cf.simulation.dt_s = 10; cf.simulation.duration_s = 21600;   % 6 h
cf.asset.clock.deterministic = false;
sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cf));
sim.initialize(); sim.run();
sEst = sim.ekf.x(sim.ekf.stateMap.srpScaleIdx);
sSig = sqrt(sim.ekf.P(sim.ekf.stateMap.srpScaleIdx, sim.ekf.stateMap.srpScaleIdx));
fprintf('    final s = %.3f (truth 1.0), sigma = %.3f, started at 0\n', sEst, sSig);
assert(isfinite(sEst) && sEst > 0.4 && sEst < 1.6, 'T3 FAILED: SRP scale not recovered toward truth (s=%.3f)', sEst);
assert(isfinite(sSig) && sSig < 1.0, 'T3 FAILED: SRP scale covariance did not shrink below the 1.0 prior');
fprintf('    PASS (scale recovered from 0 toward 1.0)\n');

% ---------------------------------------------------------------------
% T4: validate guard -- useInEKF needs real orbit dynamics
% ---------------------------------------------------------------------
fprintf('  T4: validate guard (constantVelocity -> error) ...\n');
cBad = i_cfg(true); cBad.estimator.dynamics.mode = 'constantVelocity';
threw = false;
try; validateMasterConfig(cBad); catch; threw = true; end
assert(threw, 'T4 FAILED: no error for SRP state with constantVelocity dynamics');
fprintf('    PASS\n');

fprintf('=== test_srp_coefficient_state: ALL PASS ===\n');

% =====================================================================
function cfg = i_cfg(srpOn)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = 1; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.estimator.dynamics.mode = 'j2';
    if srpOn
        cfg.estimator.srpCoefficient.enable   = true;
        cfg.estimator.srpCoefficient.useInEKF = true;
    end
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never';
    cfg.plots.showFigures=false; cfg.plots.enable=false;
end
