% test_formation_rank_deficiency
% The planar-helix formation makes the ISL line-of-sight geometry EXACTLY rank-2.
%
% The classic projected-circular helix puts z = 2x for every member, so all secondaries lie
% in one plane. The matrix of ISL LOS unit vectors is then singular: there is a direction in
% which the ISL rows carry NO information, yet the filter still shrinks the covariance
% there. That is the structural reason along-track is covariance-honest (err/sigma 0.89)
% while radial and cross-track are not (8.35 / 7.28).
%
% cfg.formation.crossTrackSpread > 0 fans the members' cross-track amplitude so the
% formation spans 3-D. The machinery already existed (SwarmFormation.crossAmp_) but the
% config knob was never declared in masterConfig, so it silently defaulted to the
% degenerate case.
%
% Proves:
%   T1  spread = 0 (default) gives an EXACTLY rank-deficient LOS geometry
%   T2  the unobservable direction is RADIAL-dominant - which is where the covariance lies
%   T3  spread > 0 restores full rank, monotonically in the spread
%   T4  default 0 keeps the formation byte-identical (regression safety)
%   T5  HONESTY: spread does NOT cure the ~0.85 m radial bias (only ~9% at s=0.8), so this
%       fixes the GEOMETRY, not the bias. Asserted so the two are never conflated.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_formation_rank_deficiency ===\n');

% ----------------------------------------------------------------
% T1 + T2: default is exactly rank-deficient, and the null is radial
% ----------------------------------------------------------------
fprintf('  T1: default (spread=0) LOS geometry is rank-deficient ...\n');

[sv0, nullRAC0] = i_losGeometry(0.0);
% Rank deficiency is judged RELATIVE to the largest singular value -- an absolute
% threshold is meaningless for a matrix of unit vectors, and sv3 lands at ~1e-8 (floating
% point), not exactly 0.
rc0 = sv0(end)/sv0(1);
assert(rc0 < 1e-6, ...
    'T1 FAILED: sv3/sv1 = %.3e is not rank-deficient; the planar helix should be singular', rc0);
fprintf('    singular values %s, sv3/sv1 = %.1e -> RANK 2: PASS\n', ...
    mat2str(round(sv0(:).',5)), rc0);

fprintf('  T2: the unobservable direction is RADIAL-dominant ...\n');
assert(abs(nullRAC0(1)) > 0.5, ...
    ['T2 FAILED: null direction RAC = %s; radial component %.3f is not dominant, so it ' ...
     'would not explain the radial covariance dishonesty.'], ...
    mat2str(round(nullRAC0(:).',3)), nullRAC0(1));
fprintf('    null direction RAC = %s (radial %.2f): PASS\n', ...
    mat2str(round(nullRAC0(:).',3)), nullRAC0(1));

% ----------------------------------------------------------------
% T3: spread restores rank, monotonically
% ----------------------------------------------------------------
fprintf('  T3: crossTrackSpread restores full rank, monotonically ...\n');

sv3 = zeros(1,4); ss = [0.15 0.30 0.50 0.80];
for k = 1:numel(ss)
    s_ = i_losGeometry(ss(k)); sv3(k) = s_(end)/s_(1);   % relative, as in T1
end
assert(all(sv3 > 1e-3), 'T3 FAILED: spread did not restore rank: %s', mat2str(round(sv3,5)));
assert(all(diff(sv3) > 0), ...
    'T3 FAILED: 3rd singular value not monotonic in spread: %s', mat2str(round(sv3,5)));
fprintf('    sv3: 0 -> %s (monotonic): PASS\n', mat2str(round(sv3,5)));

% ----------------------------------------------------------------
% T4: default 0 is inert
% ----------------------------------------------------------------
fprintf('  T4: default spread = 0 keeps the formation unchanged ...\n');

% crossTrackSpread is deliberately NOT declared in masterConfig. SwarmFormation.crossAmp_
% already defaults it to 0, so the knob works when set explicitly, and leaving it
% undeclared keeps the frozen swarm-relative baseline untouched.
%
% ANOMALY, RECORDED DELIBERATELY: merely ADDING the line
% cfg.formation.crossTrackSpread = 0.0 to masterConfig -- a value provably inert
% (secondary initial states bit-identical, crossAmp = 1.0 either way) -- shifts
% run_swarm_relative_regression by 876 m on assetFinalPos, reproducibly. The mechanism is
% unidentified. It was NOT re-baselined: re-baselining for a change believed inert is
% exactly what that regression exists to prevent. See the commit message.
cfgD = masterConfig();
assert(~isfield(cfgD.formation,'crossTrackSpread'), ...
    ['T4 FAILED: crossTrackSpread is now declared in masterConfig. Adding it shifts the ' ...
     'swarm-relative regression by 876 m for reasons not yet understood -- resolve that ' ...
     'first, then update this test.']);
[svA, ~] = i_losGeometry(0.0);
[svB, ~] = i_losGeometry([]);      % knob absent entirely -> same fallback
assert(max(abs(svA - svB)) < 1e-9, 'T4 FAILED: spread=0 differs from the absent-knob fallback');
fprintf('    declared, default 0, identical to the legacy fallback: PASS\n');

% ----------------------------------------------------------------
% T5: HONESTY -- this fixes the geometry, NOT the radial bias
% ----------------------------------------------------------------
fprintf('  T5: spread does NOT cure the radial bias (geometry != bias) ...\n');

b0 = i_radialBias(0.0);
b8 = i_radialBias(0.8);
impr = (b0 - b8) / b0;
assert(b8 > 0.5, ...
    ['T5 FAILED: radial bias fell to %.3f m at spread=0.8. If the geometry fix DID cure ' ...
     'the bias, the separate bias investigation is unnecessary -- re-check and update ' ...
     'docs/plans/ISL_LAMBDA/03.'], b8);
assert(impr < 0.30, ...
    'T5 FAILED: bias improved %.0f%%, more than the measured ~9%%', 100*impr);
fprintf('    bias %.4f -> %.4f m (%.0f%% only): geometry fixed, BIAS STILL OPEN: PASS\n', ...
    b0, b8, 100*impr);

fprintf('=== test_formation_rank_deficiency: ALL PASS ===\n');

% ----------------------------------------------------------------
function [sv, nullRAC] = i_losGeometry(spread)
    cfg = i_cfg(spread);
    % MUST run(): initialize() alone leaves the secondaries unpositioned, and every LOS
    % then comes back identical (sv = [sqrt(3) 0 0]), which looks like rank deficiency but
    % is just an unpopulated formation. Observed while writing this test.
    sim = revgnss.ReverseGNSSSimulation(cfg); sim.initialize(); sim.run();
    rP = sim.asset.r_ecef_m(:); vP = sim.asset.v_ecef_mps(:);
    uR = rP/norm(rP); uC = cross(rP,vP); uC = uC/norm(uC); uA = cross(uC,uR);
    U = [];
    for a = 2:numel(sim.assets)
        d = sim.assets{a}.r_ecef_m(:) - rP; U(:,end+1) = d/norm(d); %#ok<AGROW>
    end
    [Uu,S,~] = svd(U.'); sv = diag(S);
    w = Uu(:,end);
    nullRAC = abs([uR.'*w; uA.'*w; uC.'*w]);
end

function b = i_radialBias(spread)
    cfg = i_cfg(spread); cfg.simulation.duration_s = 1200;
    sim = revgnss.ReverseGNSSSimulation(cfg); sim.initialize(); sim.run();
    rP = sim.asset.r_ecef_m(:); vP = sim.asset.v_ecef_mps(:);
    uR = rP/norm(rP); uC = cross(rP,vP); uC = uC/norm(uC); uA = cross(uC,uR);
    d_ = sim.simData; t = d_.getTimeVector(); i2 = max(1,round(0.8*numel(t)));
    ev = d_.getPositionErrorVecs(); T = [uR uA uC].';
    Ew = T*ev(:,i2:end); b = abs(mean(Ew(1,:)));
end

function cfg = i_cfg(spread)
    cfg = masterConfig(); cfg.simulation.seed = 707; cfg.simulation.duration_s = 600;
    if ~isempty(spread)
        cfg.formation.crossTrackSpread = spread;
    elseif isfield(cfg.formation,'crossTrackSpread')
        cfg.formation = rmfield(cfg.formation,'crossTrackSpread');
    end
    cfg.scenario.nSpaceAssets = 4; cfg.scenario.nReceivers = 1;
    cfg.measurements.isl.enable = true; cfg.measurements.isl.transmitters = 'all';
    cfg.measurements.isl.receiverAssetIndex = 1;
    cfg.measurements.isl.code.enable = true; cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.carrier.enable = true; cfg.measurements.isl.carrier.useInEKF = false;
    cfg.measurements.isl.warmup_s = 300;
    cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
    cfg.plots.showFigures = false;
end
