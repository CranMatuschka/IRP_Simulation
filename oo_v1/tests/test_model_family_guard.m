function test_model_family_guard
% test_model_family_guard  Step 2: GeoRealWorldScenarioGuard family + audit statics.
%   assertModelFamilyConsistent errors on a silent family mismatch and passes when the
%   run is explicitly labelled a mismatch analysis or the families match.
%   auditImperfectionSources returns COMPUTED honest flags in both states.

fprintf('=== test_model_family_guard ===\n');

thisDir   = fileparts(mfilename('fullpath'));
oo_v1Root = fullfile(thisDir, '..');
addpath(oo_v1Root);
addpath(fullfile(oo_v1Root, 'config'));

    function threw = didThrow(fn)
        threw = false;
        try; fn(); catch; threw = true; end
    end

% --- Default masterConfig: j2Rk4 truth + twoBody EKF, no explicit label -> MUST throw ---
cfg = masterConfig();
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
assert(strcmp(cfg.orbit.truth.mode,'j2Rk4') && strcmp(cfg.estimator.dynamics.mode,'twoBody'), ...
    'fixture assumption: default is j2Rk4 truth + twoBody EKF.');
assert(didThrow(@() revgnss.GeoRealWorldScenarioGuard.assertModelFamilyConsistent(cfg)), ...
    'silent J2-truth / twoBody-EKF family mismatch must be rejected.');

% --- Same config, explicitly labelled a mismatch analysis -> MUST pass ---
cfgX = cfg;
cfgX.validation.analysisType = 'explicitMismatchAnalysis';
cfgX.validation.allowTruthModelMismatch = true;
assert(~didThrow(@() revgnss.GeoRealWorldScenarioGuard.assertModelFamilyConsistent(cfgX)), ...
    'explicitly-labelled mismatch analysis must pass the family check.');

% --- Stage-86 same-family (j2 truth + j2 EKF) -> MUST pass ---
cfgG = revgnss.ConfigFactory.geoRealWorldTruthComparisonConfig();
cfgG = revgnss.ConfigFactory.finalizeConfig(cfgG);
assert(~didThrow(@() revgnss.GeoRealWorldScenarioGuard.assertModelFamilyConsistent(cfgG)), ...
    'matched j2 truth + j2 EKF must pass the family check.');
% assertRealisticSimulation is an alias of assertValid (the full realistic guard).
assert(~didThrow(@() revgnss.GeoRealWorldScenarioGuard.assertRealisticSimulation(cfgG)), ...
    'assertRealisticSimulation alias must accept the Stage-86 realistic config.');

% --- auditImperfectionSources: honest, computed ---
aD = revgnss.GeoRealWorldScenarioGuard.auditImperfectionSources(cfg);
assert(strcmp(aD.truthDynamicsFamily,'J2') && strcmp(aD.ekfDynamicsFamily,'twoBody'), 'family strings.');
assert(~aD.sameModelFamilies, 'default: sameModelFamilies must be false (reduced dynamics).');
assert(aD.reducedDynamicsWithProcessNoise, 'default: reducedDynamicsWithProcessNoise must be true.');
assert(~aD.perfectCorrection, 'default: perfectCorrection must be false.');
assert(~aD.truthLeakageInMainFilter, 'default: no truth leakage in main filter.');
assert(~aD.realWorldClaim, 'default: realWorldClaim must be false.');
assert(aD.realisticSyntheticTruthEstimationComparison, 'default: realistic-synthetic claim must hold.');
assert(size(aD.rows,1) == 7 && size(aD.rows,2) == 5, 'audit table must be 7x5.');

aG = revgnss.GeoRealWorldScenarioGuard.auditImperfectionSources(cfgG);
assert(aG.sameModelFamilies, 'Stage-86: sameModelFamilies must be true (matched j2).');
assert(~aG.reducedDynamicsWithProcessNoise, 'Stage-86: reducedDynamics must be false when matched.');
assert(aG.realisticSyntheticTruthEstimationComparison, 'Stage-86: realistic-synthetic claim must hold.');

fprintf('=== test_model_family_guard: PASS ===\n');
end
