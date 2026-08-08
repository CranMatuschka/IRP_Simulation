function [resolvedConfig, metadata] = resolveSimulationConfig(configPath, overrides)
%RESOLVESIMULATIONCONFIG Resolve the canonical configuration pipeline.
%   Order: masterConfig, optional realism profile, the "_extends" chain of the
%   selected JSON, that JSON's own leaves, caller overrides, validation, then
%   internal derivation.
%
%   A scenario JSON may declare
%       "_extends": "golden_baseline.json"
%   so a ladder file carries ONLY its delta and inherits the rest from the file
%   it is built on. The chain is applied base-first, so the child always wins.
%   jsondecode maps the leading underscore to 'x_', which deepMergeConfig
%   already ignores, so the key never reaches masterConfig.
%
%   OVERRIDES is an optional partial config struct applied after the JSON. It
%   is how run_oo_v1 injects the run duration, which is a property of the RUN
%   and is therefore no longer written into any scenario file.

    configDir = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(configDir);
    addpath(repositoryRoot);
    addpath(configDir);
    addpath(fullfile(configDir, 'internal'));

    if nargin < 2; overrides = struct(); end

    baseConfig = masterConfig();
    preResolutionConfig = baseConfig;
    explicitPaths = {};
    sourcePath = '';
    sourceSha256 = '';
    extendsChain = {};
    profile = 'nominal';
    if isfield(baseConfig, 'realism') && ...
            isfield(baseConfig.realism, 'grade') && baseConfig.realism.grade
        profile = 'realism';
    end

    if nargin >= 1 && ~isempty(configPath)
        sourcePath = locateScenarioFile_(repositoryRoot, configPath);
        [overlay, extendsChain] = readOverlayChain_(repositoryRoot, sourcePath);
        sourceSha256 = fileSha256_(sourcePath);

        if requestsRealismProfile_(overlay)
            profileInput = applyRealismControls_(baseConfig, overlay);
            preResolutionConfig = realismGradeConfig(profileInput);
            profile = 'realism';
        end

        % Scenario-owned values are applied after the profile and therefore win.
        [preResolutionConfig, explicitPaths] = deepMergeConfig( ...
            preResolutionConfig, overlay);
    end

    if isstruct(overrides) && ~isempty(fieldnames(overrides))
        [preResolutionConfig, overridePaths] = deepMergeConfig( ...
            preResolutionConfig, overrides);
        explicitPaths = [explicitPaths, overridePaths];
    end

    if ~isempty(sourcePath)
        preResolutionConfig.provenance.explicit = explicitPaths;
    end
    preResolutionConfig = validateMasterConfig(preResolutionConfig);
    resolvedConfig = revgnss.ConfigFactory.finalizeConfig(preResolutionConfig);
    metadata = struct( ...
        'sourcePath', sourcePath, ...
        'sourceSha256', sourceSha256, ...
        'profile', profile, ...
        'explicitPaths', {explicitPaths}, ...
        'extendsChain', {extendsChain}, ...
        'preResolutionConfig', preResolutionConfig);
end

function [overlay, chain] = readOverlayChain_(repositoryRoot, sourcePath)
%READOVERLAYCHAIN_ Decode SOURCEPATH and every file it extends, base first.
%   CHAIN lists the inherited files in application order (outermost base first,
%   the requested file last), so provenance can state what a ladder file sits on.

    maxDepth = 8;
    files = {sourcePath};
    visited = {sourcePath};
    decoded = {jsondecode(fileread(sourcePath))};

    while true
        parentRef = extendsRef_(decoded{1});
        if isempty(parentRef); break; end
        assert(numel(files) < maxDepth, 'resolveSimulationConfig:extendsTooDeep', ...
            '"_extends" chain exceeds %d files starting at %s.', maxDepth, sourcePath);
        parentPath = locateScenarioFile_(repositoryRoot, parentRef);
        assert(~any(strcmp(parentPath, visited)), ...
            'resolveSimulationConfig:extendsCycle', ...
            '"_extends" cycle: %s is already in the chain.', parentPath);
        visited{end + 1} = parentPath; %#ok<AGROW>
        files = [{parentPath}, files]; %#ok<AGROW>
        decoded = [{jsondecode(fileread(parentPath))}, decoded]; %#ok<AGROW>
    end

    overlay = decoded{1};
    for index = 2:numel(decoded)
        overlay = mergeOverlayStructs_(overlay, decoded{index});
    end

    chain = cell(1, numel(files));
    for index = 1:numel(files)
        [~, name, extension] = fileparts(files{index});
        chain{index} = [name extension];
    end
end

function ref = extendsRef_(overlay)
%EXTENDSREF_ The "_extends" value, which jsondecode exposes as 'x_extends'.
    ref = '';
    if isstruct(overlay) && isfield(overlay, 'x_extends')
        value = overlay.x_extends;
        if ischar(value) || isstring(value)
            ref = char(value);
        end
    end
end

function merged = mergeOverlayStructs_(merged, childOverlay)
%MERGEOVERLAYSTRUCTS_ Plain recursive overlay merge; the child wins.
%   Deliberately NOT deepMergeConfig: both sides are partial scenario overlays,
%   so there is no masterConfig schema to validate against yet. Validation still
%   happens once, when the merged overlay meets masterConfig.
    if ~isstruct(childOverlay); merged = childOverlay; return; end
    fieldNames = fieldnames(childOverlay);
    for fieldIndex = 1:numel(fieldNames)
        fieldName = fieldNames{fieldIndex};
        if isfield(merged, fieldName) && ...
                isstruct(merged.(fieldName)) && isscalar(merged.(fieldName)) && ...
                isstruct(childOverlay.(fieldName)) && isscalar(childOverlay.(fieldName))
            merged.(fieldName) = mergeOverlayStructs_( ...
                merged.(fieldName), childOverlay.(fieldName));
        else
            merged.(fieldName) = childOverlay.(fieldName);
        end
    end
end

function requested = requestsRealismProfile_(overlay)
    requested = false;
    if isstruct(overlay) && isfield(overlay, 'realism') && ...
            isstruct(overlay.realism) && isfield(overlay.realism, 'grade')
        value = overlay.realism.grade;
        requested = (islogical(value) || isnumeric(value)) && ...
            isscalar(value) && logical(value);
    end
end

function profileInput = applyRealismControls_(baseConfig, overlay)
    controls = struct('realism', overlay.realism);
    [profileInput, ~] = deepMergeConfig(baseConfig, controls);
end

function sourcePath = locateScenarioFile_(repositoryRoot, configPath)
    requestedPath = char(configPath);
    [~, name, extension] = fileparts(requestedPath);
    if isempty(extension)
        extension = '.json';
    end
    leafName = [name extension];

    % config/ holds masterConfig's companions (golden_*, default, realism);
    % config/ladder/<axis>/ holds the numbered ladder files.
    searchDirs = scenarioSearchDirs_(repositoryRoot);
    candidates = {requestedPath, fullfile(repositoryRoot, requestedPath)};
    for index = 1:numel(searchDirs)
        candidates{end + 1} = fullfile(searchDirs{index}, requestedPath); %#ok<AGROW>
        candidates{end + 1} = fullfile(searchDirs{index}, leafName);      %#ok<AGROW>
    end

    sourcePath = '';
    for index = 1:numel(candidates)
        if isfile(candidates{index})
            sourcePath = char(java.io.File(candidates{index}).getCanonicalPath());
            break
        end
    end
    assert(~isempty(sourcePath), 'resolveSimulationConfig:scenarioNotFound', ...
        'Configuration JSON not found: %s', requestedPath);
end

function dirs = scenarioSearchDirs_(repositoryRoot)
%SCENARIOSEARCHDIRS_ Every directory a scenario JSON may live in, in priority order.
%   Shared with the gates through scenarioFileIndex, so a new ladder axis becomes
%   visible to the runner and to the regression sweeps in the same edit.
    [~, dirs] = scenarioFileIndex(repositoryRoot);
end

function hash = fileSha256_(path)
    fileIdentifier = fopen(path, 'rb');
    assert(fileIdentifier >= 0, 'resolveSimulationConfig:fileRead', ...
        'Cannot read configuration file: %s', path);
    cleanup = onCleanup(@() fclose(fileIdentifier));
    bytes = fread(fileIdentifier, Inf, '*uint8');
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(bytes);
    hash = lower(reshape(dec2hex(typecast(digest.digest(), 'uint8'), 2).', 1, []));
    clear cleanup
end
