% test_scenario_override_invariance  Every explicit JSON leaf survives resolution.

testDirectory = fileparts(mfilename('fullpath'));
repositoryRoot = fileparts(testDirectory);
addpath(repositoryRoot);
addpath(fullfile(repositoryRoot, 'config'));
addpath(fullfile(repositoryRoot, 'config', 'internal'));

% config/*.json plus every config/ladder/<axis>/*.json. The floor is the ladder
% as built: 5 in config/ + 16 scene + 23 feat + 15 ISL + 8 freq + 9 test = 76.
scenarioFiles = scenarioFileIndex(repositoryRoot);
assert(numel(scenarioFiles) >= 76, ...
    'Expected at least the 76 ladder scenarios, found %d.', numel(scenarioFiles));

exceptions = scenarioResolutionExceptionRegistry();
exceptionUsed = false(size(exceptions));
violations = {};
changedLeafCount = 0;

warningState = warning('query', 'ConfigFactory:rxCarrierBiasAbsorbed');
warning('off', 'ConfigFactory:rxCarrierBiasAbsorbed');
warningCleanup = onCleanup(@() warning(warningState.state, ...
    'ConfigFactory:rxCarrierBiasAbsorbed'));

for fileIndex = 1:numel(scenarioFiles)
    scenarioFile = scenarioFiles(fileIndex);
    scenarioPath = fullfile(scenarioFile.folder, scenarioFile.name);
    [resolvedConfig, metadata] = resolveSimulationConfig(scenarioPath);
    resolvedAgain = revgnss.ConfigFactory.finalizeConfig(resolvedConfig);
    if ~isequaln(resolvedConfig, resolvedAgain)
        violations{end + 1} = sprintf( ...
            '%s: configuration finalization is not idempotent', ...
            scenarioFile.name); %#ok<AGROW>
    end

    for pathIndex = 1:numel(metadata.explicitPaths)
        path = metadata.explicitPaths{pathIndex};
        [beforeFound, beforeValue] = valueAtPath_(metadata.preResolutionConfig, path);
        [afterFound, afterValue] = valueAtPath_(resolvedConfig, path);
        changed = ~beforeFound || ~afterFound || ~isequaln(beforeValue, afterValue);
        if ~changed
            continue
        end

        changedLeafCount = changedLeafCount + 1;
        allowed = find(strcmp({exceptions.scenarioFile}, scenarioFile.name) & ...
            strcmp({exceptions.path}, path));
        if isempty(allowed)
            violations{end + 1} = sprintf('%s: %s', scenarioFile.name, path); %#ok<AGROW>
        else
            exceptionUsed(allowed) = true;
        end
    end
end

assert(isempty(violations), ...
    'Resolution changed scenario-owned leaves without an exception:\n%s', ...
    strjoin(violations, newline));
assert(all(exceptionUsed), ...
    'The resolution exception registry contains stale entries:\n%s', ...
    strjoin({exceptions(~exceptionUsed).path}, newline));
assert(changedLeafCount == numel(exceptions), ...
    'Expected %d documented legacy changes, observed %d.', ...
    numel(exceptions), changedLeafCount);

fprintf(['test_scenario_override_invariance: PASS ' ...
    '(%d scenarios, %d documented legacy changes)\n'], ...
    numel(scenarioFiles), changedLeafCount);

function [found, value] = valueAtPath_(inputStruct, dottedPath)
    value = inputStruct;
    fields = strsplit(dottedPath, '.');
    found = true;
    for index = 1:numel(fields)
        if ~isstruct(value) || ~isscalar(value) || ~isfield(value, fields{index})
            found = false;
            value = [];
            return
        end
        value = value.(fields{index});
    end
end
