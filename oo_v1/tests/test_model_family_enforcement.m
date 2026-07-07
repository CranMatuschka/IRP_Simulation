function test_model_family_enforcement
% test_model_family_enforcement  finalizeConfig enforces model-family consistency when
%   cfg.validation.enforceModelFamilyConsistency=true. The default now sets that flag and
%   is same-family (j2+j2) so it finalizes cleanly; a reduced twoBody variant is rejected
%   unless explicitly labelled a mismatch analysis, and enforcement can be opted out.

fprintf('=== test_model_family_enforcement ===\n');

thisDir   = fileparts(mfilename('fullpath'));
oo_v1Root = fullfile(thisDir, '..');
addpath(oo_v1Root);
addpath(fullfile(oo_v1Root, 'config'));

    function threw = didThrow(fn)
        threw = false;
        try; fn(); catch; threw = true; end
    end

% --- Default (enforce=true, matched j2+j2): MUST finalize WITHOUT throwing ---
cfg = masterConfig();
assert(cfg.validation.enforceModelFamilyConsistency, 'default must opt into family enforcement.');
assert(~didThrow(@() revgnss.ConfigFactory.finalizeConfig(cfg)), ...
    'matched same-family default must finalize cleanly with enforcement on.');

% --- Enforcement ON + reduced twoBody variant, no label: MUST throw ---
cfgE = masterConfig();
cfgE.estimator.dynamics.mode = 'twoBody';
assert(didThrow(@() revgnss.ConfigFactory.finalizeConfig(cfgE)), ...
    'enforcement must reject a silent j2-truth / twoBody-EKF mismatch.');

% --- Enforcement ON + reduced variant + explicit mismatch label: MUST pass ---
cfgX = masterConfig();
cfgX.estimator.dynamics.mode = 'twoBody';
cfgX.validation.analysisType = 'explicitMismatchAnalysis';
cfgX.validation.allowTruthModelMismatch = true;
assert(~didThrow(@() revgnss.ConfigFactory.finalizeConfig(cfgX)), ...
    'explicitly-labelled mismatch analysis must pass even with enforcement on.');

% --- Enforcement OFF (opt-out) + reduced variant: MUST pass (gating still works) ---
cfgOff = masterConfig();
cfgOff.estimator.dynamics.mode = 'twoBody';
cfgOff.validation.enforceModelFamilyConsistency = false;
assert(~didThrow(@() revgnss.ConfigFactory.finalizeConfig(cfgOff)), ...
    'with enforcement opted out, a reduced-dynamics run must finalize (no family check).');

fprintf('=== test_model_family_enforcement: PASS ===\n');
end
