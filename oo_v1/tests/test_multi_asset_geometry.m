% test_multi_asset_geometry
%
% WP2: revgnss.MultiAssetGeometry turns the persisted per-asset truth
% (multiAssetTruth, WP1) into relative + absolute swarm geometry -- inter-asset
% baselines to the estimated chief (range + radial/along/cross), the pairwise
% separation envelope, the formation centroid, and per-asset geocentric radius.
% Verified against a synthetic formation with exactly known geometry.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_multi_asset_geometry ===\n');

Re  = 42164e3;   % GEO radius [m]
mat = i_synthTruth(Re);
g   = revgnss.MultiAssetGeometry.compute(mat);
tol = 1e-6;

% ---------------------------------------------------------------------
% T1: inter-asset baseline range to the chief (relative positioning)
%   asset2 is +1000 m radial, asset3 is +500 m along-track from the chief.
% ---------------------------------------------------------------------
fprintf('  T1: baseline range to chief ...\n');
assert(numel(g.baselineToPrimary) == 2, 'T1 FAILED: baseline count');
b2 = g.baselineToPrimary(1); b3 = g.baselineToPrimary(2);
assert(b2.toAsset == 2 && b3.toAsset == 3, 'T1 FAILED: toAsset');
assert(all(abs(b2.range_m - 1000) < tol), 'T1 FAILED: asset2 range ~= 1000 m');
assert(all(abs(b3.range_m -  500) < tol), 'T1 FAILED: asset3 range ~= 500 m');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: RAC projection of the baselines in the chief orbit frame
%   +X offset -> pure radial; +Y offset -> pure along-track (GEO: v_eff=omega x r).
% ---------------------------------------------------------------------
fprintf('  T2: baseline RAC decomposition ...\n');
assert(all(abs(b2.rac_m(1,:) - 1000) < 1e-3), 'T2 FAILED: asset2 not radial');
assert(all(abs(b2.rac_m(2,:))        < 1e-3), 'T2 FAILED: asset2 along leak');
assert(all(abs(b2.rac_m(3,:))        < 1e-3), 'T2 FAILED: asset2 cross leak');
assert(all(abs(b3.rac_m(2,:) -  500) < 1e-3), 'T2 FAILED: asset3 not along-track');
assert(all(abs(b3.rac_m(1,:))        < 1e-3), 'T2 FAILED: asset3 radial leak');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T3: pairwise separation envelope
%   pairs: (1,2)=1000, (1,3)=500, (2,3)=|[1000;-500;0]|=1118.03 m
% ---------------------------------------------------------------------
fprintf('  T3: separation envelope ...\n');
sep23 = sqrt(1000^2 + 500^2);
assert(g.separation.nPairs == 3, 'T3 FAILED: nPairs');
assert(all(abs(g.separation.min_m - 500) < tol),    'T3 FAILED: min separation');
assert(all(abs(g.separation.max_m - sep23) < 1e-3), 'T3 FAILED: max separation');
assert(all(abs(g.separation.mean_m - (1000+500+sep23)/3) < 1e-3), 'T3 FAILED: mean separation');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T4: absolute radius + centroid
% ---------------------------------------------------------------------
fprintf('  T4: absolute radius and centroid ...\n');
assert(all(abs(g.absolute.radius_m(1,:) - Re) < 1e-3), 'T4 FAILED: chief radius');
assert(all(abs(g.absolute.radius_m(2,:) - (Re+1000)) < 1e-3), 'T4 FAILED: asset2 radius');
cExpect = [Re + 1000/3; 500/3; 0];
assert(all(abs(g.centroid.r_ecef_m(:,1) - cExpect) < 1e-3), 'T4 FAILED: centroid');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T5: guards + report render
% ---------------------------------------------------------------------
fprintf('  T5: input guards and report ...\n');
single = mat; single.nAssets = 1;
threw = false;
try; revgnss.MultiAssetGeometry.compute(single); catch; threw = true; end
assert(threw, 'T5 FAILED: single-asset not rejected');
txt = revgnss.MultiAssetGeometry.report(g);
assert(ischar(txt) && contains(txt, 'Swarm geometry'), 'T5 FAILED: report text');
s = revgnss.MultiAssetGeometry.summarize(g);
assert(abs(s.sepMax_m - sep23) < 1e-3 && numel(s.baselineMean_m) == 2, 'T5 FAILED: summarize');
fprintf('    PASS\n');

fprintf('=== test_multi_asset_geometry: ALL PASS ===\n');

% =====================================================================
function mat = i_synthTruth(Re)
    % A 3-asset formation with exactly known geometry, stationary in ECEF:
    %   chief   at [Re;0;0]
    %   asset2  +1000 m radial   (+X)
    %   asset3  +500 m along-trk  (+Y)
    K = 4;
    t = (0:K-1)' * 30;
    r1 = repmat([Re;   0; 0], 1, K);
    r2 = repmat([Re+1000; 0; 0], 1, K);
    r3 = repmat([Re; 500; 0], 1, K);
    rs = {r1, r2, r3};
    names = {'GEO-1','GEO-2','GEO-3'};

    mat = struct();
    mat.nAssets        = 3;
    mat.estimatedIndex = 1;
    mat.stride_s       = 30;
    mat.time_s         = t;
    mat.names          = names;
    emptyAsset = struct('name','', 'r_ecef_m',[], 'v_ecef_mps',[], ...
        'euler_rad',[], 'rxClockBias_m',[], 'rxFracFreq',[]);
    mat.asset = repmat(emptyAsset, 1, 3);
    for ai = 1:3
        mat.asset(ai).name          = names{ai};
        mat.asset(ai).r_ecef_m      = rs{ai};
        mat.asset(ai).v_ecef_mps    = zeros(3, K);   % stationary in ECEF (GEO)
        mat.asset(ai).euler_rad     = zeros(3, K);
        mat.asset(ai).rxClockBias_m = zeros(K, 1);
        mat.asset(ai).rxFracFreq    = zeros(K, 1);
    end
end
