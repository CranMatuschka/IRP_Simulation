function test_model_family_enforcement
% test_model_family_enforcement  Step 3: finalizeConfig enforces model-family consistency
%   ONLY when cfg.validation.enforceModelFamilyConsistency=true, and still permits an
%   explicitly-labelled mismatch analysis. Proves the gate never fires on the default
%   (opt-in absent) so the frozen golden path is untouched.

fprintf('=== test_model_family_enforcement ===\n');

thisDir   = fileparts(mfilename('fullpath'));
oo_v1Root = fullfile(thisDir, '..');
addpath(oo_v1Root);
addpath(fullfile(oo_v1Root, 'config'));

    function threw = didThrow(fn)
        threw = false;
        try; fn(); catch; threw = true; end
    end

% --- Default (opt-in ABSENT): j2Rk4 truth + twoBody EKF must finalize WITHOUT throwing ---
assert(~didThrow(@() revgnss.ConfigFactory.finalizeConfig(masterConfig())), ...
    'default finalizeConfig must not enforce family consistency (golden path untouched).');

% --- Opt-in TRUE on the mismatched default: MUST throw ---
cfgE = masterConfig();
cfgE.validation.enforceModelFamilyConsistency = true;
assert(didThrow(@() revgnss.ConfigFactory.finalizeConfig(cfgE)), ...
    'enforceModelFamilyConsistency=true must reject the silent j2/twoBody mismatch.');

% --- Opt-in TRUE + explicit mismatch label: MUST pass ---
cfgX = masterConfig();
cfgX.validation.enforceModelFamilyConsistency = true;
cfgX.validation.analysisType = 'explicitMismatchAnalysis';
cfgX.validation.allowTruthModelMismatch = true;
assert(~didThrow(@() revgnss.ConfigFactory.finalizeConfig(cfgX)), ...
    'explicitly-labelled mismatch analysis must pass even with enforcement on.');

% --- Opt-in TRUE on a matched same-family (Stage-86 j2+j2) config: MUST pass ---
cfgG = revgnss.ConfigFactory.geoRealWorldTruthComparisonConfig();
cfgG.validation.enforceModelFamilyConsistency = true;
assert(~didThrow(@() revgnss.ConfigFactory.finalizeConfig(cfgG)), ...
    'matched j2 truth + j2 EKF must pass with enforcement on.');

fprintf('=== test_model_family_enforcement: PASS ===\n');
end
