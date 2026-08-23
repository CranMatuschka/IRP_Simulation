% test_resolved_config_dump
% WP-2: the literal masterConfig is NOT what runs. revgnss.ConfigTextDump flattens the
% resolved config and diffs it against the literal, so the <stem>.out records what
% actually ran (self-describing without MATLAB) and surfaces finalizeConfig's overrides.
% Also guards against NEW silent overrides of the key toggles (codeMode, relativistic clock).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_resolved_config_dump ===\n');

cfgL = masterConfig();
cfgL.report.writePdf = false; cfgL.report.writeMat = false;
cfgL.report.compileTex = 'never'; cfgL.plots.showFigures = false;
cfgR = revgnss.ConfigFactory.finalizeConfig(cfgL);

% --- flatten: non-empty, deep, deterministic --------------------------------
lines = revgnss.ConfigTextDump.flatten(cfgR);
assert(iscell(lines) && ~isempty(lines), 'flatten(cfgR) must be a non-empty cell.');
attLine = lines(startsWith(lines, 'estimator.estimateAttitude ='));
assert(~isempty(attLine), 'flatten must contain estimator.estimateAttitude.');
assert(any(strcmp(strtrim(attLine), 'estimator.estimateAttitude = true')), ...
    'Resolved default estimateAttitude must be true (WP-1 4-antenna default).');

% flatten must be deterministic (byte-stable for the same struct)
assert(isequal(lines, revgnss.ConfigTextDump.flatten(cfgR)), 'flatten must be deterministic.');
fprintf('  flatten: %d fields; %s\n', numel(lines), strtrim(attLine{1}));

% --- diff: the section-4.3 opacity items are surfaced as CHANGED overrides --
ov = revgnss.ConfigTextDump.diff(cfgL, cfgR);
assert(isstruct(ov) && isfield(ov,'changed') && isfield(ov,'added'), 'diff must return changed/added.');
assert(~isempty(ov.changed), 'finalizeConfig must change at least one literal value.');
allPaths   = [ov.changed(:,1); ov.added(:,1)];
changedMap = containers.Map(ov.changed(:,1), ov.changed(:,3));   % path -> resolvedStr
chgTo = @(p, vals) isKey(changedMap, p) && ismember(changedMap(p), vals);

% Relativistic clock-rate offset (WP-D): a gated, MODELED feature that defaults OFF
% in masterConfig itself (cfg.physics.relativity.clock.enable=false), so it is already
% false in the literal config and finalizeConfig no longer force-disables/overrides it.
% (No changed-override assertion here; see test_documented_limitations for the WP-D
% enable -> relativisticFracFreq mapping.)

% Standalone first-order Sagnac folded into the iterative light-time (true -> false).
assert(chgTo('physics.sagnac.truth.enable', {'false','0'}) && ...
       chgTo('physics.sagnac.model.enable', {'false','0'}), ...
    'physics.sagnac truth+model enable must be a CHANGED override -> false.');

% Nominal simple atmosphere is owned by masterConfig, not silently enabled here.
assert(cfgL.errors.troposphere.enable && cfgL.errors.ionosphere.enable);
assert(~any(strcmp(allPaths,'errors.troposphere.enable')) && ...
       ~any(strcmp(allPaths,'errors.ionosphere.enable')), ...
    'Nominal atmosphere ownership moved out of masterConfig.');

% The resolved code processing mode is recorded verbatim in the dump.
cmLine = lines(startsWith(lines, 'measurements.codeMode ='));
assert(~isempty(cmLine) && contains(cmLine{1}, 'singleFrequency'), ...
    'resolved measurements.codeMode must be recorded as singleFrequency.');

% Attitude stays master-owned. Receiver geometry normalization is explicit in the dump.
assert(~any(contains(allPaths, 'estimateAttitude')), ...
    'Default attitude estimation must not be a finalizeConfig override.');
assert(any(contains(allPaths, 'receiverLeverArm')), ...
    'Receiver-count geometry normalization was not recorded in the resolved diff.');

fprintf('  overrides: %d changed, %d added; atmosphere and attitude remain master-owned\n', ...
    size(ov.changed,1), size(ov.added,1));
fprintf('  PASS\n');
