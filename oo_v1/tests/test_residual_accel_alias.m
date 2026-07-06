function test_residual_accel_alias
% test_residual_accel_alias  Step 1: residualAccelerationUncertainty is a value-preserving,
%   read-only canonical mirror of processNoise.modelMismatch (the field the EKF reads).
%   The mirror must equal the alias after finalizeConfig on every config path, and must NOT
%   change the EKF-critical modelMismatch value (that equivalence is enforced by the gate).

fprintf('=== test_residual_accel_alias ===\n');

thisDir   = fileparts(mfilename('fullpath'));
oo_v1Root = fullfile(thisDir, '..');
addpath(oo_v1Root);
addpath(fullfile(oo_v1Root, 'config'));

    function assertMirror(cfg, label)
        mm  = cfg.estimator.processNoise.modelMismatch;
        rau = cfg.estimator.processNoise.residualAccelerationUncertainty;
        assert(isfield(rau,'enable') && isfield(rau,'sigma_mps2'), ...
            '[%s] residualAccelerationUncertainty missing fields.', label);
        assert(rau.enable == mm.enable, ...
            '[%s] mirror enable %d != alias enable %d.', label, rau.enable, mm.enable);
        assert(isequaln(rau.sigma_mps2, mm.sigma_mps2), ...
            '[%s] mirror sigma %.6g != alias sigma %.6g.', label, rau.sigma_mps2, mm.sigma_mps2);
    end

% --- Default masterConfig path (currently twoBody EKF: modelMismatch auto-enabled/scaled) ---
cfg = masterConfig();
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
assertMirror(cfg, 'masterConfig');

% --- Stage-86 same-family path (modelMismatch explicitly disabled, sigma 0) ---
cfgG = revgnss.ConfigFactory.geoRealWorldTruthComparisonConfig();
cfgG = revgnss.ConfigFactory.finalizeConfig(cfgG);
assertMirror(cfgG, 'geoRealWorld');

% --- The mirror must never be the field the EKF reads: modelMismatch stays authoritative ---
% (Sanity: mutating the mirror does not change the alias the EKF consumes.)
cfg.estimator.processNoise.residualAccelerationUncertainty.sigma_mps2 = 42;
assert(cfg.estimator.processNoise.modelMismatch.sigma_mps2 ~= 42, ...
    'modelMismatch (EKF-read alias) must be independent of the mirror.');

fprintf('=== test_residual_accel_alias: PASS ===\n');
end
