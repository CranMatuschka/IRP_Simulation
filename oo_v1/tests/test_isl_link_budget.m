% test_isl_link_budget
% Physics-derived two-way ISL sigma + light-time-aware two-way geometry.
%
% Converts the relative-accuracy headline from "IF you had a 1 cm device" into "with THIS
% link at THIS range". Both features are gated OFF by default, so the frozen goldens and
% the existing relative-layer numbers are untouched.
%
% Proves:
%   T1  model='fixed' (default) returns the legacy constant EXACTLY -> golden-safe
%   T2  at the reference distance the link budget returns sigma0 EXACTLY (anchored)
%   T3  sigma scales linearly with baseline length (free-space path loss, 20*log10(d))
%   T4  ANTENNA PHYSICS: fixedAperture is frequency-INDEPENDENT; fixedGain scales with f.
%       This is the claim most often got wrong ("higher frequency = noisier"), so it is
%       asserted in BOTH directions rather than assumed.
%   T5  the solver produces PER-PAIR sigmas that differ when baselines differ
%   T6  two-way light-time is reported, and is negligible at formation baselines

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_isl_link_budget ===\n');

BP = {'multiAsset','twoWayISL'};

% ----------------------------------------------------------------
% T1: default 'fixed' is the legacy constant
% ----------------------------------------------------------------
fprintf('  T1: model=''fixed'' returns the legacy sigma unchanged ...\n');

cfg_f = i_cfg('fixed','fixedAperture',0.01,1000);
for d_t1 = [100 1000 50000]
    s = revgnss.ISLLinkBudget.sigma(cfg_f, d_t1, BP, 0.01);
    assert(abs(s - 0.01) < 1e-15, ...
        'T1 FAILED: sigma=%.6g at d=%g, expected the constant 0.01', s, d_t1);
end
fprintf('    0.01 m at 100 m, 1 km and 50 km: PASS\n');

% ----------------------------------------------------------------
% T2: anchored -- at refDistance the model returns sigma0 exactly
% ----------------------------------------------------------------
fprintf('  T2: anchored at refDistance ...\n');

cfg_b = i_cfg('linkBudget','fixedAperture',0.01,1000);
s_ref = revgnss.ISLLinkBudget.sigma(cfg_b, 1000, BP, 0.01);
assert(abs(s_ref - 0.01) < 1e-12, ...
    'T2 FAILED: sigma(refDistance)=%.6g, expected exactly sigma0=0.01', s_ref);
fprintf('    sigma(1000 m) = %.6f m = sigma0: PASS\n', s_ref);

% ----------------------------------------------------------------
% T3: sigma ~ distance
% ----------------------------------------------------------------
fprintf('  T3: sigma scales linearly with baseline ...\n');

s1 = revgnss.ISLLinkBudget.sigma(cfg_b, 1000,  BP, 0.01);
s2 = revgnss.ISLLinkBudget.sigma(cfg_b, 2000,  BP, 0.01);
s10= revgnss.ISLLinkBudget.sigma(cfg_b, 10000, BP, 0.01);
assert(abs(s2/s1 - 2) < 1e-9, 'T3 FAILED: doubling distance gave %.4fx, expected 2', s2/s1);
assert(abs(s10/s1 - 10) < 1e-9, 'T3 FAILED: 10x distance gave %.4fx, expected 10', s10/s1);
fprintf('    1 km %.4f m -> 2 km %.4f m -> 10 km %.4f m (exactly linear): PASS\n', s1, s2, s10);

% ----------------------------------------------------------------
% T4: THE ANTENNA PHYSICS -- both directions
% ----------------------------------------------------------------
fprintf('  T4: fixedAperture frequency-INDEPENDENT; fixedGain frequency-dependent ...\n');

bA = revgnss.ISLLinkBudget.describe(i_cfg('linkBudget','fixedAperture',0.01,1000), BP, 0.01);
bG = revgnss.ISLLinkBudget.describe(i_cfg('linkBudget','fixedGain',    0.01,1000), BP, 0.01);

sA_ka = revgnss.ISLLinkBudget.sigmaAtFrequency(bA, 2000, 26e9);
sA_l1 = revgnss.ISLLinkBudget.sigmaAtFrequency(bA, 2000, 1.57542e9);
assert(abs(sA_ka - sA_l1) < 1e-12, ...
    ['T4 FAILED: fixedAperture gave different sigma at Ka (%.6g) and L1 (%.6g). A fixed ' ...
     'dish has G~f^2, which EXACTLY cancels the f^2 path loss -- frequency must drop out.'], ...
    sA_ka, sA_l1);
assert(~bA.frequencyDependent, 'T4 FAILED: fixedAperture reported as frequency-dependent');

sG_ka = revgnss.ISLLinkBudget.sigmaAtFrequency(bG, 2000, 26e9);
sG_l1 = revgnss.ISLLinkBudget.sigmaAtFrequency(bG, 2000, 1.57542e9);
ratio_t4 = sG_ka / sG_l1;
expect_t4 = 26e9 / 1.57542e9;
assert(abs(ratio_t4 - expect_t4)/expect_t4 < 1e-9, ...
    'T4 FAILED: fixedGain Ka/L1 sigma ratio %.4f, expected the frequency ratio %.4f', ...
    ratio_t4, expect_t4);
assert(bG.frequencyDependent, 'T4 FAILED: fixedGain reported as frequency-independent');
fprintf('    fixedAperture: Ka == L1 (%.4f m). fixedGain: Ka/L1 = %.2f = f ratio: PASS\n', ...
    sA_ka, ratio_t4);

% ----------------------------------------------------------------
% T5: the solver emits PER-PAIR sigmas
% ----------------------------------------------------------------
fprintf('  T5: solver produces per-pair sigmas that track baseline ...\n');

cfg_s = masterConfig();
cfg_s.simulation.seed = 42; cfg_s.simulation.duration_s = 120;
cfg_s.scenario.nSpaceAssets = 4; cfg_s.scenario.nReceivers = 1;
cfg_s.multiAsset.twoWayISL.enable = true;
cfg_s.multiAsset.twoWayISL.linkBudget.model = 'linkBudget';
cfg_s.multiAsset.twoWayISL.linkBudget.refDistance_m = 1000;
cfg_s.report.writePdf=false; cfg_s.report.writeMat=false; cfg_s.report.compileTex='never';
cfg_s.plots.enable=false; cfg_s.plots.showFigures=false;

out_s = revgnss.ReportRunner.runSingle(cfg_s);
rel_s = out_s.rel;
assert(isfield(rel_s,'pairSigma_m') && ~isempty(rel_s.pairSigma_m), ...
    'T5 FAILED: solver did not report per-pair sigmas');
ps = rel_s.pairSigma_m;
assert(all(ps > 0), 'T5 FAILED: non-positive sigma');
assert(numel(unique(round(ps,9))) > 1, ...
    ['T5 FAILED: every pair got the SAME sigma (%s). With a helix the baselines differ, ' ...
     'so the link budget must produce different sigmas.'], mat2str(round(ps,4)));
fprintf('    %d pairs, sigma %.4f..%.4f m (differs by baseline): PASS\n', ...
    numel(ps), min(ps), max(ps));

% ----------------------------------------------------------------
% T6: two-way light-time reported and negligible at these baselines
% ----------------------------------------------------------------
fprintf('  T6: two-way light-time reported, negligible at formation scale ...\n');

cfg_l = cfg_s; cfg_l.multiAsset.twoWayISL.lightTime.enable = true;
out_l = revgnss.ReportRunner.runSingle(cfg_l);
rel_l = out_l.rel;
assert(isfield(rel_l,'lightTimeMax_m'), 'T6 FAILED: lightTimeMax_m not reported');
assert(rel_l.lightTimeOn, 'T6 FAILED: lightTimeOn false when enabled');
lt = rel_l.lightTimeMax_m;
assert(lt < 1e-3, ...
    ['T6 FAILED: two-way light-time %.3e m exceeds 1 mm at a ~1 km baseline. The ' ...
     'first-order Sagnac should CANCEL by reciprocity; only relative endpoint motion ' ...
     'survives, which is micrometre-scale here.'], lt);
fprintf('    max |light-time| = %.3e m (< 1 mm, as reciprocity requires): PASS\n', lt);

fprintf('=== test_isl_link_budget: ALL PASS ===\n');

% ----------------------------------------------------------------
function cfg = i_cfg(model, antenna, sigma0, refD)
    cfg = struct();
    cfg.multiAsset.twoWayISL.sigma_m = sigma0;
    cfg.multiAsset.twoWayISL.linkBudget.model = model;
    cfg.multiAsset.twoWayISL.linkBudget.antennaModel = antenna;
    cfg.multiAsset.twoWayISL.linkBudget.refDistance_m = refD;
    cfg.multiAsset.twoWayISL.linkBudget.refFrequency_Hz = 26e9;
end
