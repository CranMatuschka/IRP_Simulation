% test_multipath_bias_states  State augmentation for the coloured ground multipath.
%
% What this pins, and why each one matters:
%   1. The GATE IS A NO-OP WHEN OFF. nx, the state map and the multipath sigma charged
%      to R are all identical to a run without the feature, so every frozen golden and
%      every rung of the ladder is untouched by its existence.
%   2. ONE STATE PER (TOWER, SIGNAL), not per tower. The truth chains are per-signal --
%      multipath_ owns signal 1 and multipathForSignal owns each additional signal with
%      its own RNG stream -- so L1 and L2 are independent realisations. A shared state
%      could only fit their mean and would leave half the variance unmodelled, which is
%      exactly the defect the states exist to remove.
%   3. THE VARIANCE IS CHARGED EXACTLY ONCE. With the states on, ErrorChain returns
%      sigma_m.mp = 0 so R no longer carries the multipath allowance. Charging it in
%      both places would inflate S and hide the very inconsistency being fixed; charging
%      it in neither would make the filter over-confident again by the same amount.
%   4. THE PROCESS MODEL MATCHES THE TRUTH. F = exp(-dt/tau) and Q = sigma_ss^2(1-phi^2)
%      reproduce the stationary variance of the truth chain, and tau/sigma default to the
%      truth generator's own coloredGM values so the matched case needs no duplicated
%      numbers.
%   5. THE TRUTH IS UNTOUCHED. Turning the states on must not perturb the injected
%      multipath realisation -- only what the estimator does about it. If the truth moved
%      too, any consistency improvement would be unattributable.
%
% MEASURED CONTEXT (scene008_G5S1R4_TW1_golden, 12-seed Monte Carlo): the ensemble
% position NEES/dof was 13.32 against an innovation statistic of 0.86, and setting
% coloredGM.tau_s = 1 s at the SAME sigma -- so R unchanged -- put it back to 0.988.
% The magnitude charged to R was never wrong; only its colour was.

testDirectory  = fileparts(mfilename('fullpath'));
repositoryRoot = fileparts(testDirectory);
addpath(repositoryRoot);
addpath(fullfile(repositoryRoot, 'config'));
addpath(fullfile(repositoryRoot, 'config', 'internal'));

fprintf('test_multipath_bias_states\n');

cfgOff = resolveSimulationConfig('scene008_G5S1R4_TW1_golden.json', ...
            struct('simulation', struct('duration_s', 60)));
cfgOff.report.writePdf = false; cfgOff.report.writeMat = false;
cfgOff.report.compileTex = 'never'; cfgOff.plots.enable = false;
cfgOff.plots.showFigures = false; cfgOff.report.monteCarlo.enable = false;
try; cfgOff.validation.scientificCampaign.enable = false; catch; end

nTowers  = cfgOff.scenario.nTowers;
nSignals = sum(logical(cfgOff.signals.enabledMask));

% ---- 1. default is OFF and the map is unchanged ---------------------------------
assert(isfield(cfgOff.estimation,'multipathBias'), ...
    'cfg.estimation.multipathBias is missing from masterConfig.');
assert(~cfgOff.estimation.multipathBias.useInEKF, ...
    'multipathBias.useInEKF must default to false so the goldens stay byte-identical.');

simOff = revgnss.ReverseGNSSSimulation(cfgOff);
simOff.initialize();
assert(simOff.ekf.nMultipathBiasStates == 0, ...
    'Gate off must allocate zero multipath states, found %d.', simOff.ekf.nMultipathBiasStates);
assert(all(simOff.ekf.stateMap.mpBiasIdx(:) == 0), ...
    'Gate off must leave mpBiasIdx an all-zero sentinel.');
nxOff = simOff.ekf.nx;
fprintf('  1. gate off: nx = %d, zero multipath states ... PASS\n', nxOff);

% ---- 2. one state per (tower, signal) -------------------------------------------
cfgOn = cfgOff;
cfgOn.estimation.multipathBias.useInEKF = true;
simOn = revgnss.ReverseGNSSSimulation(cfgOn);
simOn.initialize();

expected = nTowers * nSignals;
assert(simOn.ekf.nMultipathBiasStates == expected, ...
    'Expected %d multipath states (%d towers x %d signals), found %d.', ...
    expected, nTowers, nSignals, simOn.ekf.nMultipathBiasStates);
assert(simOn.ekf.nx == nxOff + expected, ...
    'nx must grow by exactly the multipath state count: %d + %d ~= %d.', ...
    nxOff, expected, simOn.ekf.nx);
mpIdx = simOn.ekf.stateMap.mpBiasIdx;
assert(isequal(size(mpIdx), [nTowers nSignals]), ...
    'mpBiasIdx must be [nTowers x nSignals], got [%s].', num2str(size(mpIdx)));
assert(numel(unique(mpIdx(:))) == expected && all(mpIdx(:) > 0), ...
    'Every (tower, signal) needs its own distinct state index.');
fprintf('  2. gate on: %d states = %d towers x %d signals, nx %d -> %d ... PASS\n', ...
    expected, nTowers, nSignals, nxOff, simOn.ekf.nx);

% ---- 3. the variance is charged exactly once ------------------------------------
% ErrorChain owns the R side; ask it directly rather than inferring from a run.
chainOff = models.errors.ErrorChain(cfgOff, cfgOff.simulation.seed);
chainOn  = models.errors.ErrorChain(cfgOn,  cfgOn.simulation.seed);
assert(~chainOff.multipathSigmaInState, 'Gate off must leave the multipath sigma in R.');
assert(chainOn.multipathSigmaInState, ...
    'Gate on must move the multipath sigma out of R, or it is counted twice.');

elv    = deg2rad([20; 35; 50; 65; 80]);
tIdx   = (1:5)';  aIdx = ones(5,1);
errOff = chainOff.compute(elv, tIdx, tIdx, 1.0, aIdx);
errOn  = chainOn.compute( elv, tIdx, tIdx, 1.0, aIdx);
sigOff = errOff.bySource.sigma_m.mp;
sigOn  = errOn.bySource.sigma_m.mp;
assert(all(sigOff > 0), 'Gate off must charge a positive multipath sigma to R.');
assert(all(sigOn == 0), 'Gate on must charge zero multipath sigma to R.');
% and it must reach the aggregate R actually inverted, not just the per-source report
assert(all(errOn.sigmaTotal_m < errOff.sigmaTotal_m), ...
    'Removing multipath from R must lower sigmaTotal on every row.');
dropSq = errOff.sigmaTotal_m.^2 - errOn.sigmaTotal_m.^2;
assert(max(abs(dropSq - sigOff.^2)) < 1e-12, ...
    'The variance removed from R must equal the multipath variance exactly.');
fprintf('  3. R multipath sigma: off = [%.3f .. %.3f] m, on = 0, removed exactly once ... PASS\n', ...
    min(sigOff), max(sigOff));

% ---- 5. the truth realisation is untouched --------------------------------------
assert(isequal(errOff.bySource.truth_m.mp, errOn.bySource.truth_m.mp), ...
    ['Turning the states on changed the injected multipath truth by up to %.3g m. ' ...
     'The gate must change only what the ESTIMATOR does.'], ...
    max(abs(errOff.bySource.truth_m.mp - errOn.bySource.truth_m.mp)));
fprintf('  5. truth realisation identical with the gate on ... PASS\n');

% ---- 4. the process model matches the truth chain -------------------------------
assert(abs(simOn.ekf.mpBiasTau_ - cfgOn.errors.multipath.coloredGM.tau_s) < 1e-12, ...
    'tau must default to the truth generator value (%g), got %g.', ...
    cfgOn.errors.multipath.coloredGM.tau_s, simOn.ekf.mpBiasTau_);
assert(abs(simOn.ekf.mpBiasSigmaSs_ - cfgOn.errors.multipath.coloredGM.sigmaCodeL1_ss_m) < 1e-12, ...
    'sigma_ss must default to the truth generator value.');

dt_s  = cfgOn.simulation.dt_s;
sm    = simOn.ekf.stateMap;
F     = simOn.ekf.buildF_(dt_s, simOn.ekf.x(sm.euler_idx), simOn.ekf.x(sm.omega_idx), [], [], []);
Q     = simOn.ekf.buildQ_(dt_s, []);
phiEx = exp(-dt_s / cfgOn.errors.multipath.coloredGM.tau_s);
idx1  = mpIdx(1,1);
assert(abs(F(idx1, idx1) - phiEx) < 1e-12, ...
    'F on a multipath state must be exp(-dt/tau) = %.9f, got %.9f.', phiEx, F(idx1, idx1));
% Steady state: P = phi^2 P + q  =>  P = q / (1 - phi^2) = sigma_ss^2.
sigSs = simOn.ekf.mpBiasSigmaSs_;
pSs   = Q(idx1, idx1) / (1 - phiEx^2);
assert(abs(sqrt(pSs) - sigSs) / sigSs < 1e-9, ...
    'Q must hold the stationary sigma at %.4f m, it settles at %.4f m.', sigSs, sqrt(pSs));
fprintf('  4. F = %.6f, Q settles at sigma_ss = %.4f m ... PASS\n', F(idx1,idx1), sqrt(pSs));

% ---- 6. H MATCHES h, numerically, per (tower, signal) ---------------------------
% An H/h mismatch on an additive bias is silent: the filter still runs, the residuals
% still look plausible, and the state simply learns the wrong thing. Perturb each state
% and check that h moves by exactly the perturbation on exactly the rows H nominates,
% and by nothing at all anywhere else -- including the carrier, Doppler and two-way rows.
x0 = simOn.ekf.getMeasurementState();
[~, h0, H0, ~, es0] = simOn.measModel.computeMeasurements(simOn.asset, simOn.towers, x0, 0, sm);
Mpr  = es0.nPseudorange;
twrR = es0.towerIdx_perMeas(:);
sigR = es0.signalIdx_perMeas(:);
% Round-off floor: h on a GEO code row is ~3.8e7 m, so one ulp is ~7.5e-9 m. The
% reconstruction path subtracts and re-adds that magnitude, so a sub-ulp residual is
% arithmetic, not modelling. 1e-7 m is still 7 orders below the 0.3 m multipath scale.
H_TOL = 1e-7;
worstOn = 0; worstOff = 0;
for ti = 1:nTowers
    for si = 1:nSignals
        idx = mpIdx(ti, si);
        xp  = x0; xp(idx) = xp(idx) + 0.137;
        [~, h1] = simOn.measModel.computeMeasurements(simOn.asset, simOn.towers, xp, 0, sm);
        res    = (h1 - h0) - 0.137 * H0(:, idx);
        target = false(size(res)); target(1:Mpr) = (twrR == ti & sigR == si);
        worstOn  = max(worstOn,  max(abs(res(target))));
        worstOff = max(worstOff, max(abs(res(~target))));
    end
end
assert(worstOff == 0, ...
    'Perturbing a multipath state moved rows it does not belong to (max %.3g m).', worstOff);
assert(worstOn < H_TOL, ...
    'H disagrees with h on the multipath columns by %.3g m (tolerance %.3g).', worstOn, H_TOL);
fprintf('  6. H/h agree to %.3g m on target rows, exactly 0 elsewhere ... PASS\n', worstOn);

% ---- the states survive a real epoch --------------------------------------------
simOn.step(1);
fprintf('  7. one full epoch runs with the states wired ... PASS\n');

fprintf('test_multipath_bias_states: ALL PASS\n');
