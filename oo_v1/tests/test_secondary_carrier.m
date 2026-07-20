% test_secondary_carrier
%
% Phase-1 per-secondary symmetry: tower->secondary CARRIER rows + float-ambiguity states.
% T1 gated-off (golden-safe), T2 state layout, T3 anti-circularity (each row touches ONE
% asset), T4 convergence (carrier tightens the secondary position vs code-only), T5 guards.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));
fprintf('=== test_secondary_carrier ===\n');

% Phase 3b-2 (C5): the tower->secondary code + carrier rows are now emitted by the shared
% MeasurementModel.computeSecondaryGroundRows (SecondaryGroundMeasurementBuilder retired). This
% test drives that path (via i_secRows) and identifies carrier rows by their float-ambiguity column.
% ---------------------------------------------------------------------
% T1: gated off -> ambiguity block empty (golden-safe); builder emits code rows only
% ---------------------------------------------------------------------
fprintf('  T1: gated off -> no ambiguity states, code rows only ...\n');
sOff = i_sim(i_cfg(3, 10, false));
assert(isempty(sOff.ekf.stateMap.secondaryAmbiguityIdx) || size(sOff.ekf.stateMap.secondaryAmbiguityIdx,1)==0, ...
    'T1 FAILED: ambiguity block present when disabled');
[~,~,~,~,iOff] = i_secRows(sOff, sOff.ekf.stateMap, 5);
assert(iOff.nRows > 0, 'T1 FAILED: no ground code rows built');
fprintf('    PASS (%d code rows, no ambiguity states)\n', iOff.nRows);

% ---------------------------------------------------------------------
% T2: state layout -- (N-1) x nTowers ambiguity block, disjoint indices
% ---------------------------------------------------------------------
fprintf('  T2: state layout ...\n');
sOn = i_sim(i_cfg(3, 10, true));
sm  = sOn.ekf.stateMap;
assert(isequal(size(sm.secondaryAmbiguityIdx), [2 5]), 'T2 FAILED: ambiguity block not [2 x 5]');
assert(sOn.ekf.nx - sOff.ekf.nx == 10, 'T2 FAILED: nx delta not +10');
amb = sm.secondaryAmbiguityIdx(:);
posOrb = [sm.r_idx(:); sm.v_idx(:); sm.secondaryOrbitIdx(:); sm.secondaryClockIdx(:)];
assert(numel(unique(amb))==numel(amb) && isempty(intersect(amb,posOrb)), 'T2 FAILED: ambiguity indices not disjoint/unique');
fprintf('    PASS (%d ambiguity states, disjoint)\n', numel(amb));

% ---------------------------------------------------------------------
% T3: the merged builder emits BOTH code and carrier rows; each CARRIER row (identified by
%     its +1 float-ambiguity column) touches exactly ONE asset (+u' on that secondary's
%     position, +1 on its clock, +1 on its ambiguity; NO primary column).
% ---------------------------------------------------------------------
fprintf('  T3: merged builder -- carrier rows anti-circular ...\n');
[~,~,H,R,gi] = i_secRows(sOn, sm, 5);
carrierRows = find(any(H(:, amb) ~= 0, 2));   % rows touching an ambiguity column = carrier rows
assert(~isempty(carrierRows), 'T3 FAILED: no carrier rows built');
assert(gi.nRows == 2*numel(carrierRows), 'T3 FAILED: expected one carrier row per code row');
primCols = [sm.r_idx(:)' sm.v_idx(:)' sm.euler_idx(:)' sm.omega_idx(:)' sm.b_rx_idx sm.bdot_rx_idx];
for r = carrierRows'
    assert(all(H(r, primCols) == 0), 'T3 FAILED: carrier row has a PRIMARY-state column (circular)');
    onAmb = full(H(r, amb));
    assert(sum(onAmb==1)==1 && sum(onAmb~=0)==1, 'T3 FAILED: row not exactly one +1 ambiguity');
    orbHit = 0;
    for si = 1:2
        oc = sm.secondaryOrbitIdx(si,1:3);
        if norm(H(r, oc)) > 1e-9; orbHit = orbHit + 1; end
    end
    assert(orbHit == 1, 'T3 FAILED: row touches != 1 secondary orbit block');
end
assert(all(diag(R) > 0), 'T3 FAILED: R not positive');
fprintf('    PASS (%d code + %d carrier rows; carrier rows +u''/+1/+1 on ONE asset, no primary column)\n', ...
    gi.nRows - numel(carrierRows), numel(carrierRows));

% ---------------------------------------------------------------------
% T4: carrier tightens covariance AND does not degrade the estimate.
%     (The error check catches a non-constant truth ambiguity, which would
%      inject metre-level noise and make the estimate WORSE while sigma shrinks.)
% ---------------------------------------------------------------------
fprintf('  T4: carrier tightens position, estimate not degraded ...\n');
[sigOff, errOff] = i_secPos(i_cfg(3, 1800, false));
[sigOn,  errOn ] = i_secPos(i_cfg(3, 1800, true));
fprintf('    secondary pos sigma: code-only=%.3f m, +carrier=%.3f m\n', sigOff, sigOn);
fprintf('    secondary pos error: code-only=%.3f m, +carrier=%.3f m\n', errOff, errOn);
assert(sigOn < sigOff, 'T4 FAILED: carrier did not tighten the secondary position covariance');
assert(errOn < 1.25*errOff, 'T4 FAILED: carrier DEGRADED the estimate (non-constant ambiguity noise?)');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T5 (mechanism): the truth ambiguity draw must be CONSTANT per key. Guards
%     against the drawKeyedPersistent-advances pitfall (that redraws every epoch).
% ---------------------------------------------------------------------
fprintf('  T5: truth-ambiguity draw is constant per key ...\n');
node = 3*32 + 2;
b1 = sOn.errorChain.drawKeyedInterval(models.noise.RngSource.SEC_CARR_AMB, node, 0, 0, 0);
b2 = sOn.errorChain.drawKeyedInterval(models.noise.RngSource.SEC_CARR_AMB, node, 0, 0, 0);
assert(b1 == b2, 'T5 FAILED: interval-keyed truth ambiguity is not constant across calls');
fprintf('    PASS (drawKeyedInterval constant: %.4f == %.4f)\n', b1, b2);

% ---------------------------------------------------------------------
% T6: validate guards
% ---------------------------------------------------------------------
fprintf('  T6: validate guards ...\n');
cN = masterConfig(); cN.scenario.nSpaceAssets = 3;
cN.multiAsset.towerSecondary.carrier.enable = true;   % but estimateMode not position
cN.multiAsset.estimateMode = 'clocks';
assert(i_throws(@() models.measurements.MeasurementModel.validateSecondaryConfig(cN)), 'T6 FAILED: non-position not caught');
fprintf('    PASS\n');

fprintf('=== test_secondary_carrier: ALL PASS ===\n');

% =====================================================================
function cfg = i_cfg(nA, dur, carrierOn)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nA; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.mode = 'honest';
    cfg.multiAsset.towerSecondary.carrier.enable = carrierOn;
    cfg.multiAsset.towerSecondary.doppler.enable = false;   % focus on code/carrier rows (Doppler = test_secondary_doppler)
    cfg.simulation.duration_s = dur;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never';
    cfg.plots.showFigures=false; cfg.plots.enable=false;
end

function sim = i_sim(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize();
end

function [z, h, H, R, info] = i_secRows(sim, sm, t_s)
    % Phase 3b-2 (C5): tower->secondary rows now emitted by the shared MeasurementModel
    % (SecondaryGroundMeasurementBuilder retired). Same cfg + errorChain -> identical draws.
    mm = models.measurements.MeasurementModel(sim.cfg, sim.errorChain);
    [z, h, H, R, info] = mm.computeSecondaryGroundRows(sim.assets, sim.towers, sim.ekf.x, sm, sim.ekf.nx, t_s);
end

function [s, e] = i_secPos(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize(); sim.run();
    d = sim.simData.getData();
    ps = d.secondaryOrbit.posSigma_m;    % [nSec x nEpoch] formal 1-sigma
    pe = d.secondaryOrbit.posError_m;    % [nSec x nEpoch] |est - truth|
    N = size(ps,2); k = (floor(0.5*N)+1):N;
    v = ps(:,k); v = v(isfinite(v)); s = mean(v);
    w = pe(:,k); w = w(isfinite(w)); e = sqrt(mean(w.^2));
end

function tf = i_throws(f)
    tf = false;
    try
        f();
    catch
        tf = true;
    end
end
