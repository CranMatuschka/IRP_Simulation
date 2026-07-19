% test_mc_centroid_gate
%
% MC centroid gate: revgnss.MonteCarloConsistency.run pools the Guard C formation-centroid
% NEES across seeds (one time-mean sample per seed), turning the single-realisation Guard C
% flag into an authoritative cross-seed absolute-trustworthiness verdict.
%
%   notApplicable            -- no swarm 'position' run (single asset)
%   inconclusiveMatchedCrutch-- swarm but realism guards OFF (truth==model -> NEES~1 is fake)
%   overconfidentAbsolute    -- guards ON and the pooled centroid NEES is above the band
%                               (the single-hemisphere GEO absolute is radial<->clock wall-limited)

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_mc_centroid_gate ===\n');

% ---------------------------------------------------------------------
% T1: single-asset -> centroid gate not applicable
% ---------------------------------------------------------------------
fprintf('  T1: single-asset -> notApplicable ...\n');
r1 = revgnss.MonteCarloConsistency.run(i_single(600), struct('nSeeds',2,'duration_s',600));
assert(~r1.centroidAvailable, 'T1 FAILED: centroid available for a single asset');
assert(strcmp(r1.centroidVerdict,'notApplicable'), 'T1 FAILED: verdict %s (want notApplicable)', r1.centroidVerdict);
% the existing NIS/NEES pooling must still be present (extension did not break it)
assert(isfield(r1,'nisPerDof') && isfield(r1,'neesPerDof') && isfinite(r1.nisPerDof), 'T1 FAILED: base NIS/NEES pooling missing');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: swarm honest + realism guards ON -> overconfident absolute (authoritative)
% ---------------------------------------------------------------------
fprintf('  T2: swarm honest + guards -> overconfidentAbsolute ...\n');
r2 = revgnss.MonteCarloConsistency.run(i_honestSwarm(3, 900, true), struct('nSeeds',3,'duration_s',900));
assert(r2.centroidAvailable, 'T2 FAILED: centroid not available for the swarm run');
assert(r2.realismGuardsActive, 'T2 FAILED: realism guards not detected as active');
ps = r2.perSeedCentroidNeesPerDof(1:3);
assert(all(isfinite(ps)), 'T2 FAILED: per-seed centroid NEES has non-finite entries');
fprintf('    per-seed centroid NEES/dof = [%.2g %.2g %.2g], pooled/dof=%.3g, verdict=%s\n', ...
    ps(1), ps(2), ps(3), r2.centroidNeesPerDof, r2.centroidVerdict);
assert(r2.centroidNeesPerDof > 1, 'T2 FAILED: pooled centroid NEES/dof not overconfident (>1)');
assert(strcmp(r2.centroidVerdict,'overconfidentAbsolute'), ...
    'T2 FAILED: verdict %s (want overconfidentAbsolute)', r2.centroidVerdict);
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T3: swarm honest but guards OFF -> the gate refuses to certify (matched crutch)
% ---------------------------------------------------------------------
fprintf('  T3: swarm honest, guards OFF -> inconclusiveMatchedCrutch ...\n');
r3 = revgnss.MonteCarloConsistency.run(i_honestSwarm(3, 400, false), struct('nSeeds',2,'duration_s',400));
assert(r3.centroidAvailable, 'T3 FAILED: centroid not available');
assert(~r3.realismGuardsActive, 'T3 FAILED: guards wrongly detected active');
assert(strcmp(r3.centroidVerdict,'inconclusiveMatchedCrutch'), ...
    'T3 FAILED: verdict %s (want inconclusiveMatchedCrutch)', r3.centroidVerdict);
fprintf('    PASS\n');

fprintf('=== test_mc_centroid_gate: ALL PASS ===\n');

% =====================================================================
function cfg = i_single(dur)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = 1; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.simulation.duration_s = dur;
    cfg = i_quiet(cfg);
end

function cfg = i_honestSwarm(nA, dur, guards)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nA; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.mode = 'honest';
    cfg = revgnss.ConfigFactory.applyMultiAssetMode(cfg);   % resolve -> estimateMode='position', product off
    cfg.asset.clock.deterministic = false;
    if guards
        cfg.multiAsset.towerSecondary.atmosphere.enable = true;  % Guard A: divergent per-LOS atmosphere (build-time)
        cfg.multiAsset.injectTruthSideDynamics = true;           % Guard B: one-sided truth-side SRP/luni-solar
        cfg = applyInjectTruthSideDynamics(cfg);                 % translate the toggle (needs position mode, set above)
    end
    cfg.simulation.duration_s = dur;
    cfg = i_quiet(cfg);
end

function cfg = i_quiet(cfg)
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never';
    cfg.plots.showFigures=false; cfg.plots.enable=false;
end
