function [resolvedConfig, metadata] = resolveSimulationConfig(configPath)
%RESOLVESIMULATIONCONFIG Resolve the canonical configuration pipeline.
%   Order: masterConfig, optional realism profile, explicit JSON overrides,
%   validation, then internal derivation.

    configDir = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(configDir);
    addpath(repositoryRoot);
    addpath(configDir);
    addpath(fullfile(configDir, 'internal'));

    baseConfig = masterConfig();
    preResolutionConfig = baseConfig;
    explicitPaths = {};
    sourcePath = '';
    sourceSha256 = '';
    profile = 'nominal';
    if isfield(baseConfig, 'realism') && ...
            isfield(baseConfig.realism, 'grade') && baseConfig.realism.grade
        profile = 'realism';
    end

    if nargin >= 1 && ~isempty(configPath)
        sourcePath = locateScenarioFile_(repositoryRoot, configPath);
        overlay = jsondecode(fileread(sourcePath));
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
        'preResolutionConfig', preResolutionConfig);
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
    candidates = { ...
        requestedPath, ...
        fullfile(repositoryRoot, requestedPath), ...
        fullfile(repositoryRoot, 'config', 'scenarios', requestedPath)};

    [~, name, extension] = fileparts(requestedPath);
    if isempty(extension)
        extension = '.json';
    end
    candidates{end + 1} = fullfile( ...
        repositoryRoot, 'config', 'scenarios', [name extension]);

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
