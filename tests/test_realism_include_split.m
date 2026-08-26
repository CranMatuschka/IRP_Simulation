% test_realism_include_split  realism.include -- the split of point34, and the four
%                             previously-UNDECLARED includes.
%
% BACKGROUND. masterConfig declared 15 realism.include.* keys; realismGradeConfig's
% i_resolveIncludes knew 18, inventing `islCarrier`, `islLinkBudget` and `point34` with
% default true. Three toggles that shape a run and appeared nowhere in the config file.
% `point34` was named for where the idea was written down rather than what it does, and it
% bundled two unrelated concerns:
%   carrierArcSurvival : carrierSlip common-mode + baseline-differenced slip guard (ESTIMATOR)
%   phaseBiasHonesty   : enforce the resolved phase-bias status in reporting
%
% Requiring calibrated phase bias before integer fixing is a safety invariant, not a
% realism option. It therefore remains true when phaseBiasHonesty is disabled.
%
% T1: every include realismGradeConfig honours is declared in masterConfig (no hidden toggles).
% T2: the two halves are INDEPENDENTLY switchable (the point of the split).
% T3: the deprecated `point34` alias still sets both, and warns.
%
% METHOD NOTE, learned the hard way: apply realismGradeConfig ONCE to a config whose keys are
% still at masterConfig's defaults. Starting from a config that has already had the overlay
% applied (e.g. goldenRealismScenarioConfig) makes every include look dead -- skipping a block
% on a second call does not UNDO the first call's writes.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));
addpath(fullfile(thisDir, '..', 'config', 'internal'));

fprintf('=== test_realism_include_split ===\n');

keys4 = @(c) [c.carrierSlip.commonModeCompensation.enable, ...
              c.carrierSlip.baselineDifferencedMode.enable, ...
              c.estimator.diffAtt.ambiguityResolution.enforcePhaseBiasStatus, ...
              c.estimator.diffAtt.ambiguityResolution.requirePhaseBiasCalibrationForFix];

% ----------------------------------------------------------------
% T1: no hidden includes -- masterConfig declares everything realismGradeConfig honours.
% ----------------------------------------------------------------
fprintf('  T1: every honoured include is declared in masterConfig ...\n');
base = masterConfig();
assert(isfield(base,'realism') && isfield(base.realism,'include'), ...
    'T1 FAILED: masterConfig has no realism.include block');
declared = fieldnames(base.realism.include);

% An include name that realismGradeConfig does not know provokes a warning; use that to
% discover the honoured set without reaching into a local function.
for nm = {'islCarrier','islLinkBudget','carrierArcSurvival','phaseBiasHonesty'}
    assert(ismember(nm{1}, declared), ...
        ['T1 FAILED: realism.include.%s is honoured by realismGradeConfig but NOT declared ' ...
         'in masterConfig -- an invisible toggle.'], nm{1});
end
assert(~ismember('point34', declared), ...
    'T1 FAILED: point34 should have been replaced by carrierArcSurvival + phaseBiasHonesty');
lastwarn('');
probe = masterConfig(); probe.realism.include.definitelyNotAnEffect = true;
w = warning('off','realismGradeConfig:unknownInclude');
realismGradeConfig(probe);
warning(w);
[~, id] = lastwarn();
assert(strcmp(id,'realismGradeConfig:unknownInclude'), ...
    'T1 FAILED: an unknown include must warn (got id "%s")', id);
fprintf('    %d includes declared, all honoured names present\n', numel(declared));
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: the two halves switch independently.
% ----------------------------------------------------------------
fprintf('  T2: carrierArcSurvival and phaseBiasHonesty are independent ...\n');

v = keys4(masterConfig());
assert(isequal(logical(v), [false false false true]), ...
    'T2 FAILED: masterConfig safety baseline is inconsistent, got %s', mat2str(v));

v = keys4(realismGradeConfig(masterConfig()));
assert(isequal(logical(v), [true true true true]), ...
    'T2 FAILED: full overlay must set all four, got %s', mat2str(v));

a = masterConfig(); a.realism.include.carrierArcSurvival = false;
v = keys4(realismGradeConfig(a));
assert(isequal(logical(v), [false false true true]), ...
    ['T2 FAILED: carrierArcSurvival=false must drop ONLY the slip guard and leave the ' ...
     'phase-bias status alone, got %s'], mat2str(v));

p = masterConfig(); p.realism.include.phaseBiasHonesty = false;
v = keys4(realismGradeConfig(p));
assert(isequal(logical(v), [true true false true]), ...
    ['T2 FAILED: phaseBiasHonesty=false must drop ONLY the phase-bias status and leave the ' ...
     'slip guard alone, got %s'], mat2str(v));
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: the deprecated alias still sets BOTH, and warns.
%     Without the alias an out-of-tree point34=false would hit the unknown-include path and
%     silently leave both halves ON -- the opposite of the intent.
% ----------------------------------------------------------------
fprintf('  T3: deprecated point34 alias ...\n');
q = masterConfig(); q.realism.include.point34 = false;
lastwarn('');
w = warning('off','realismGradeConfig:deprecatedInclude');
v = keys4(realismGradeConfig(q));
warning(w);
assert(isequal(logical(v), [false false false true]), ...
    'T3 FAILED: point34=false must retain the calibration safety invariant, got %s', mat2str(v));

q2 = masterConfig(); q2.realism.include.point34 = true;
lastwarn('');
w = warning('off','realismGradeConfig:deprecatedInclude');
v = keys4(realismGradeConfig(q2));
warning(w);
[~, id] = lastwarn();
assert(isequal(logical(v), [true true true true]), ...
    'T3 FAILED: point34=true must set BOTH halves, got %s', mat2str(v));
assert(strcmp(id,'realismGradeConfig:deprecatedInclude'), ...
    'T3 FAILED: the alias must warn that it is deprecated (got id "%s")', id);
fprintf('    PASS\n');

fprintf('=== test_realism_include_split: ALL PASS ===\n');
