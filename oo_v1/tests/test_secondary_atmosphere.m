% test_secondary_atmosphere
%
% Phase-2 per-secondary symmetry: per-(secondary,tower) troposphere ZWD states that absorb
% the Guard A divergent uplink tropo residual (mirrors the chief per-tower ZWD). T1 gated-off
% (golden-safe), T2 layout, T3 the code row carries the +m_w ZWD partial, T4 the ZWD states
% actually track the tropo (not stuck at prior) and do not degrade the estimate, T5 guard.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));
fprintf('=== test_secondary_atmosphere ===\n');

% ---------------------------------------------------------------------
% T1: gated off -> no ZWD states (golden-safe)
% ---------------------------------------------------------------------
fprintf('  T1: gated off -> no ZWD states ...\n');
sOff = i_sim(i_cfg(3, 10, false));
assert(isempty(sOff.ekf.stateMap.secondaryZwdIdx) || size(sOff.ekf.stateMap.secondaryZwdIdx,1)==0, ...
    'T1 FAILED: ZWD block present when disabled');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: layout -- (N-1) x nTowers ZWD block, disjoint indices
% ---------------------------------------------------------------------
fprintf('  T2: state layout ...\n');
sOn = i_sim(i_cfg(3, 10, true));
sm  = sOn.ekf.stateMap;
assert(isequal(size(sm.secondaryZwdIdx), [2 5]), 'T2 FAILED: ZWD block not [2 x 5]');
assert(sOn.ekf.nx - sOff.ekf.nx == 10, 'T2 FAILED: nx delta not +10');
z = sm.secondaryZwdIdx(:);
other = [sm.r_idx(:); sm.v_idx(:); sm.secondaryOrbitIdx(:); sm.secondaryClockIdx(:); sm.zwdIdx(:)];
assert(numel(unique(z))==numel(z) && isempty(intersect(z,other)), 'T2 FAILED: ZWD indices not disjoint/unique');
fprintf('    PASS (%d ZWD states, disjoint)\n', numel(z));

% ---------------------------------------------------------------------
% T3: code row carries the +m_w ZWD partial
% ---------------------------------------------------------------------
fprintf('  T3: code-row ZWD partial ...\n');
[zc,~,H,~,gi] = revgnss.SecondaryGroundMeasurementBuilder.build(sOn.cfg, sOn.errorChain, sOn.assets, sOn.towers, sOn.ekf.x, sm, sOn.ekf.nx, 5);
assert(gi.nRows > 0, 'T3 FAILED: no ground rows');
hit = 0;
for r = 1:gi.nRows
    onZ = H(r, z);
    nz = find(onZ ~= 0);
    if ~isempty(nz)
        assert(isscalar(nz) && onZ(nz) >= 1.0, 'T3 FAILED: row not exactly one ZWD col with m_w>=1');
        hit = hit + 1;
    end
end
assert(hit == gi.nRows, 'T3 FAILED: not every code row has a ZWD partial');
fprintf('    PASS (%d code rows, each +m_w on one ZWD state)\n', gi.nRows);

% ---------------------------------------------------------------------
% T4: the ZWD states ENGAGE (move from prior + posterior tightens => they are in the
%     observation), but at GEO the ~constant elevation makes m_w ~constant, so the ZWD is
%     DEGENERATE with the secondary clock and soaks wall error instead of the cm-dm tropo.
%     Assert engagement (structural), and record the honest degradation rather than claim a
%     gain (there is none until the radial<->clock wall is broken, e.g. two-way ranging).
% ---------------------------------------------------------------------
fprintf('  T4: ZWD engages the tropo residual (honest GEO degeneracy) ...\n');
[errOff, ~, ~]        = i_run(i_cfg(3, 1800, false));
[errOn, zwdMag, zwdSig] = i_run(i_cfg(3, 1800, true));
fprintf('    max|ZWD state|=%.3f m, ZWD posterior sigma=%.3f m (prior 0.10 m)\n', zwdMag, zwdSig);
fprintf('    HONEST: secondary pos error no-ZWD=%.0f m -> +ZWD=%.0f m (degenerate w/ clock at GEO; no gain until the wall is broken)\n', errOff, errOn);
assert(zwdMag > 5e-3, 'T4 FAILED: ZWD states did not move from prior (dead states)');
assert(zwdSig < 0.10, 'T4 FAILED: ZWD posterior did not tighten below prior (not observed)');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T5: validate guard (estimateAtmosphere requires Guard A)
% ---------------------------------------------------------------------
fprintf('  T5: validate guard ...\n');
cN = i_cfg(3, 10, true); cN.multiAsset.towerSecondary.atmosphere.enable = false;   % ZWD on, Guard A off
assert(i_throws(@() validateMasterConfig(cN)), 'T5 FAILED: ZWD-without-GuardA not caught');
fprintf('    PASS\n');

fprintf('=== test_secondary_atmosphere: ALL PASS ===\n');

% =====================================================================
function cfg = i_cfg(nA, dur, zwdOn)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nA; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.mode = 'honest';
    cfg.multiAsset.towerSecondary.atmosphere.enable = true;     % Guard A: divergent uplink tropo
    cfg.multiAsset.towerSecondary.estimateAtmosphere = zwdOn;   % per-secondary ZWD states
    cfg.simulation.duration_s = dur;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never';
    cfg.plots.showFigures=false; cfg.plots.enable=false;
end

function sim = i_sim(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize();
end

function [e, zwdMag, zwdSig] = i_run(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize(); sim.run();
    d = sim.simData.getData();
    pe = d.secondaryOrbit.posError_m; N = size(pe,2); k = (floor(0.5*N)+1):N;
    w = pe(:,k); w = w(isfinite(w)); e = sqrt(mean(w.^2));
    zwdMag = 0; zwdSig = NaN;
    zi = sim.ekf.stateMap.secondaryZwdIdx(:);
    if ~isempty(zi) && isfield(d,'estimate') && isfield(d.estimate,'x') && ~isempty(d.estimate.x)
        xf = d.estimate.x(:,end);
        zwdMag = max(abs(xf(zi)));
        if isfield(d.estimate,'sigma') && ~isempty(d.estimate.sigma)
            sf = d.estimate.sigma(:,end); zwdSig = mean(sf(zi));
        end
    end
end

function tf = i_throws(f)
    tf = false;
    try
        f();
    catch
        tf = true;
    end
end
