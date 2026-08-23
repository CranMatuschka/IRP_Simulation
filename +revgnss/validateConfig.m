function validateConfig(cfg)
% validateConfig  Validate the top-level simulation configuration struct.
%
% Throws an error if required fields are missing or values are out of range.
% Issues warnings for suspicious but non-fatal settings.

required_top = {'simulation','asset','towers','estimator','errors','plots'};
for k = 1:numel(required_top)
    f = required_top{k};
    if ~isfield(cfg, f)
        error('validateConfig:missingField', 'cfg.%s is required', f);
    end
end

% Simulation block
assert(isfield(cfg.simulation,'dt_s')       && cfg.simulation.dt_s > 0,   ...
    'validateConfig: cfg.simulation.dt_s must be positive');
assert(isfield(cfg.simulation,'duration_s') && cfg.simulation.duration_s > 0, ...
    'validateConfig: cfg.simulation.duration_s must be positive');

% Asset block
assert(isfield(cfg.asset,'r_ecef_m'),  'validateConfig: cfg.asset.r_ecef_m required');
assert(isfield(cfg.asset,'v_ecef_mps'),'validateConfig: cfg.asset.v_ecef_mps required');
assert(isfield(cfg.asset,'receiverLeverArm_body_m') || ...
       isfield(cfg.asset,'receiverLeverArms_body_m'), ...
    'validateConfig: cfg.asset.receiverLeverArm_body_m or receiverLeverArms_body_m required');

% Lever arm observability info (not a warning when zero — intended for default)
hasPlural = isfield(cfg.asset,'receiverLeverArms_body_m');
if hasPlural
    maxNorm = max(vecnorm(cfg.asset.receiverLeverArms_body_m, 2, 1));
else
    maxNorm = norm(cfg.asset.receiverLeverArm_body_m);
end
doAttJac = isfield(cfg.estimator,'estimateAttitudeFromPseudorange') && ...
           cfg.estimator.estimateAttitudeFromPseudorange;
if doAttJac && maxNorm < 1e-9
    warning('validateConfig:zeroLeverArm', ...
        'estimateAttitudeFromPseudorange=true but all lever arms are zero. Attitude unobservable.');
end

% Towers block
assert(isstruct(cfg.towers) || iscell(cfg.towers), ...
    'validateConfig: cfg.towers must be a struct array or cell array');

% Errors block
required_err = {'codeNoise','troposphere','ionosphere','hardwareDelay','multipath'};
for k = 1:numel(required_err)
    f = required_err{k};
    if ~isfield(cfg.errors, f)
        error('validateConfig:missingErrorField', 'cfg.errors.%s is required', f);
    end
end

assert(cfg.errors.codeNoise.sigma_m >= 0, ...
    'validateConfig: cfg.errors.codeNoise.sigma_m must be >= 0');

% Estimator block
if ~isfield(cfg.estimator,'estimateTowerClocks')
    warning('validateConfig:default', ...
        'cfg.estimator.estimateTowerClocks not set; defaulting to false');
end

% Orbit block (optional)
if isfield(cfg,'orbit')
    if isfield(cfg.orbit,'altitudeMean_m')
        assert(cfg.orbit.altitudeMean_m > 100e3, ...
            'validateConfig: orbit altitude seems too low (< 100 km)');
    end
end

revgnss.AttitudeSensorSuite.validateConfig(cfg);
end
