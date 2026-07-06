function test_model_family_guard
% test_model_family_guard  GeoRealWorldScenarioGuard family + audit statics.
%   The default masterConfig is now same-family (j2 truth + j2 EKF), so it PASSES the
%   family check; a deliberately-reduced twoBody variant is rejected unless explicitly
%   labelled a mismatch analysis. auditImperfectionSources returns COMPUTED honest flags.

fprintf('=== test_model_family_guard ===\n');

thisDir   = fileparts(mfilename('fullpath'));
oo_v1Root = fullfile(thisDir, '..');
addpath(oo_v1Root);
addpath(fullfile(oo_v1Root, 'config'));

    function threw = didThrow(fn)
        threw = false;
        try; fn(); catch; threw = true; end
    end

% --- Default masterConfig: j2Rk4 truth + j2 EKF (matched) -> MUST pass ---
cfg = masterConfig();
assert(strcmp(cfg.orbit.truth.mode,'j2Rk4') && strcmp(cfg.estimator.dynamics.mode,'j2'), ...
    'fixture assumption: default is same-family j2Rk4 truth + j2 EKF.');
assert(~didThrow(@() revgnss.GeoRealWorldScenarioGuard.assertModelFamilyConsistent(cfg)), ...
    'matched j2 truth + j2 EKF default must pass the family check.');

% --- Deliberately-reduced twoBody variant, no explicit label -> MUST throw ---
cfgMM = cfg;
cfgMM.estimator.dynamics.mode = 'twoBody';
assert(didThrow(@() revgnss.GeoRealWorldScenarioGuard.assertModelFamilyConsistent(cfgMM)), ...
    'silent J2-truth / twoBody-EKF reduced-dynamics mismatch must be rejected.');

% --- Same variant, explicitly labelled a mismatch analysis -> MUST pass ---
cfgX = cfgMM;
cfgX.validation.analysisType = 'explicitMismatchAnalysis';
cfgX.validation.allowTruthModelMismatch = true;
assert(~didThrow(@() revgnss.GeoRealWorldScenarioGuard.assertModelFamilyConsistent(cfgX)), ...
    'explicitly-labelled mismatch analysis must pass the family check.');
% assertRealisticSimulation is an alias of assertValid (the full realistic guard).
cfgG = revgnss.ConfigFactory.geoRealWorldTruthComparisonConfig();
cfgG = revgnss.ConfigFactory.finalizeConfig(cfgG);
assert(~didThrow(@() revgnss.GeoRealWorldScenarioGuard.assertRealisticSimulation(cfgG)), ...
    'assertRealisticSimulation alias must accept the Stage-86 realistic config.');

% --- auditImperfectionSources: honest, computed (on the RESOLVED/finalized default) ---
% (finalizeConfig resolves towerClockMode from perfectCorrection base default to the
%  truthHistoryProductNoisy product mode; the audit is a post-finalize report function.)
cfgFin = revgnss.ConfigFactory.finalizeConfig(masterConfig());
aD = revgnss.GeoRealWorldScenarioGuard.auditImperfectionSources(cfgFin);
assert(strcmp(aD.truthDynamicsFamily,'J2') && strcmp(aD.ekfDynamicsFamily,'J2'), 'family strings.');
assert(aD.sameModelFamilies, 'matched default: sameModelFamilies must be true.');
assert(~aD.reducedDynamicsWithProcessNoise, 'matched default: reducedDynamics must be false.');
assert(~aD.perfectCorrection, 'default: perfectCorrection must be false.');
assert(~aD.truthLeakageInMainFilter, 'default: no truth leakage in main filter.');
assert(~aD.realWorldClaim, 'default: realWorldClaim must be false.');
assert(aD.realisticSyntheticTruthEstimationComparison, 'default: realistic-synthetic claim must hold.');
assert(size(aD.rows,1) == 7 && size(aD.rows,2) == 5, 'audit table must be 7x5.');

% --- audit on the reduced-dynamics variant -> honest reduced-dynamics labelling ---
aM = revgnss.GeoRealWorldScenarioGuard.auditImperfectionSources(cfgMM);
assert(~aM.sameModelFamilies && aM.reducedDynamicsWithProcessNoise, ...
    'twoBody variant: sameModelFamilies=false, reducedDynamics=true.');

fprintf('=== test_model_family_guard: PASS ===\n');
end
