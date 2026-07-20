% test_secondary_doppler
%
% Phase 3b-3 Axis 4: tower->secondary Doppler (range-rate) rows, emitted by the shared
% MeasurementModel.computeSecondaryGroundRows (DEFAULT OFF -- honest GEO finding, docs §16). Proves
% the rows are STRUCTURALLY honest + conservative when the axis is opted in:
%   T1  Doppler rows are emitted in position mode; each touches ONLY its OWN asset's position
%       (d(rhoDot)/dr) + velocity (u_los') + clock-drift (+1) = 7 nonzeros, NO primary columns.
%   T2  R_new SUPERSET R_old: stripping the Doppler rows from the Doppler-ON output recovers the
%       Doppler-OFF output EXACTLY (z/h/H/R) -> Doppler only ADDS rows, never shrinks an existing R
%       entry; each Doppler R diagonal = sigma_dop^2 + nCorr*towerClkDriftSigma^2 (>= sigma_dop^2,
%       sigma_dop >= 0.01).
%   T3  clocks mode has no velocity state -> Doppler auto-off (no rows even with enable=true).
% NB: no observability-improvement test -- Doppler does NOT make the secondary clock-drift observable
% at GEO (see §16); a formal-sigma assertion would falsely pass (over-confidence). Default OFF.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));
fprintf('=== test_secondary_doppler ===\n');

% ---------------------------------------------------------------------
% T1 + T2: rows, H structure, R superset
% ---------------------------------------------------------------------
fprintf('  T1/T2: Doppler rows, H structure, R_new superset R_old ...\n');
sOn  = i_sim(i_cfg(3, true));      % Doppler ON
sOff = i_sim(i_cfg(3, false));     % Doppler OFF
sm   = sOn.ekf.stateMap;
[z1,h1,H1,R1,i1] = i_secRows(sOn,  sm, 5);
[z0,h0,H0,R0,i0] = i_secRows(sOff, sOff.ekf.stateMap, 5);

% velocity columns uniquely identify Doppler rows (code/carrier never touch v)
velCols = [];
for si = 1:size(sm.secondaryOrbitIdx,1); velCols = [velCols, sm.secondaryOrbitIdx(si,4:6)]; end %#ok<AGROW>
dopRows = find(any(H1(:, velCols) ~= 0, 2));
assert(~isempty(dopRows), 'T1 FAILED: no Doppler rows emitted in position mode');
assert(numel(dopRows) == i1.nRows - i0.nRows, 'T1 FAILED: Doppler row count mismatch');

% each Doppler row touches exactly the secondary position(3) + velocity(3) + clock-drift(1) = 7
% nonzeros -- its OWN block only, NO primary columns (anti-circular).
driftCols = sm.secondaryClockIdx(:,2);
for r = dopRows(:)'
    nzc = find(H1(r,:) ~= 0);
    assert(numel(nzc) == 7, 'T1 FAILED: Doppler row touches != 7 states (pos+vel+drift)');
    onDrift = intersect(nzc, driftCols);
    assert(isscalar(onDrift) && H1(r,onDrift) == 1, 'T1 FAILED: Doppler row not +1 on one clock-drift');
    assert(all(H1(r, sm.r_idx(:)) == 0), 'T1 FAILED: Doppler row touches primary position');
    assert(all(H1(r, sm.v_idx(:)) == 0), 'T1 FAILED: Doppler row touches primary velocity');
end
fprintf('    T1 PASS (%d Doppler rows, each pos+vel+drift of its OWN asset)\n', numel(dopRows));

% R superset: strip the Doppler rows from the ON output -> must equal the OFF output exactly
nonDop = setdiff(1:i1.nRows, dopRows);
assert(isequal(z1(nonDop), z0) && isequal(h1(nonDop), h0), 'T2 FAILED: Doppler perturbed z/h of existing rows');
assert(isequal(H1(nonDop,:), H0), 'T2 FAILED: Doppler perturbed H of existing rows');
assert(isequal(R1(nonDop,nonDop), R0), 'T2 FAILED: Doppler shrank/changed an existing R entry');

% honest Doppler R: sigma_dop^2 + nCorr*towerClkDriftSigma^2, >= sigma_dop^2, sigma_dop >= 0.01
ts = sOn.cfg.multiAsset.towerSecondary;
sd2  = ts.doppler.sigma_mps^2;
pad  = max(1, ts.productNCorr) * ts.towerClkDriftSigma_mps^2;
assert(ts.doppler.sigma_mps >= 0.01, 'T2 FAILED: sigma_dop < 0.01 (too optimistic)');
for r = dopRows(:)'
    assert(abs(R1(r,r) - (sd2 + pad)) < 1e-12, 'T2 FAILED: Doppler R != sigma_dop^2 + drift pad');
    assert(R1(r,r) >= sd2 && pad > 0, 'T2 FAILED: Doppler R not conservative (missing drift pad)');
end
fprintf('    T2 PASS (R_new superset R_old; Doppler R = %.4g m^2/s^2 = sigma^2 + pad)\n', sd2+pad);

% ---------------------------------------------------------------------
% T3: clocks mode -> no velocity state -> Doppler auto-off
% ---------------------------------------------------------------------
fprintf('  T3: clocks mode auto-off ...\n');
% Build a REAL clocks-mode config directly -- NOT via i_cfg, whose multiAsset.mode='honest' forces
% estimateMode='position' in finalize (which would give a velocity state and emit Doppler).
cC = masterConfig();
cC.scenario.nSpaceAssets = 2; cC.scenario.nReceivers = 1; cC.scenario.nTowers = 5;
cC.multiAsset.estimateMode = 'clocks';
cC.multiAsset.towersObserveSecondaries = true;
cC.multiAsset.towerSecondary.doppler.enable = true;   % enabled, yet must stay off (no velocity state)
cC.measurements.isl.enable = true; cC.measurements.isl.code.enable = true; cC.measurements.isl.code.useInEKF = true;
cC.measurements.isl.product.enable = true; cC.measurements.isl.product.sigmaPos_m = 0;
cC.report.writePdf=false; cC.report.writeMat=false; cC.report.compileTex='never';
cC.plots.showFigures=false; cC.plots.enable=false;
sC = i_sim(cC);
[~,~,Hc,~,~] = i_secRows(sC, sC.ekf.stateMap, 5);
velC = [];
if isfield(sC.ekf.stateMap,'secondaryOrbitIdx') && ~isempty(sC.ekf.stateMap.secondaryOrbitIdx)
    for si = 1:size(sC.ekf.stateMap.secondaryOrbitIdx,1); velC = [velC, sC.ekf.stateMap.secondaryOrbitIdx(si,4:6)]; end %#ok<AGROW>
end
if isempty(velC)
    assert(true);  % no orbit/velocity state at all -> trivially no Doppler
else
    assert(~any(any(Hc(:, velC) ~= 0)), 'T3 FAILED: Doppler rows emitted in clocks mode');
end
fprintf('    PASS (no Doppler rows in clocks mode -> no velocity state)\n');

% NB: NO drift-observability test. The honest GEO finding (docs §16) is that Doppler does NOT make
% the secondary clock-drift observable at GEO (range-rate position-dominated, radial<->clock wall) --
% it degrades drift/velocity. A "formal-sigma shrinks" assertion would FALSELY pass (over-confidence:
% P drops while the actual error grows), so it is deliberately omitted. This test proves only that
% the rows are STRUCTURALLY honest (H shape, R_new superset R_old); the default is OFF at GEO.

fprintf('=== test_secondary_doppler: ALL PASS ===\n');

% =====================================================================
function sim = i_sim(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize();
end

function [z, h, H, R, info] = i_secRows(sim, sm, t_s)
    mm = models.measurements.MeasurementModel(sim.cfg, sim.errorChain);
    [z, h, H, R, info] = mm.computeSecondaryGroundRows(sim.assets, sim.towers, sim.ekf.x, sm, sim.ekf.nx, t_s);
end

function cfg = i_cfg(nA, dopOn)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nA; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.mode = 'honest';
    cfg.multiAsset.towerSecondary.carrier.enable = true;
    cfg.multiAsset.towerSecondary.doppler.enable = dopOn;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never';
    cfg.plots.showFigures=false; cfg.plots.enable=false;
end
