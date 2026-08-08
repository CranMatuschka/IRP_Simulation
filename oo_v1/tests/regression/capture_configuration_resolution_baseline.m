function capture_configuration_resolution_baseline(replaceExisting)
%CAPTURE_CONFIGURATION_RESOLUTION_BASELINE Capture exact legacy configuration evidence.

    if nargin < 1
        replaceExisting = false;
    end

    regressionDirectory = fileparts(mfilename('fullpath'));
    testDirectory = fileparts(regressionDirectory);
    repositoryRoot = fileparts(testDirectory);
    configurationDirectory = fullfile( ...
        regressionDirectory, 'baselines', 'configuration');
    snapshotPath = fullfile(configurationDirectory, 'configuration_snapshots.mat');
    manifestPath = fullfile(configurationDirectory, ...
        'configuration_resolution_manifest.json');

    if ~replaceExisting
        assert(~isfile(snapshotPath) && ~isfile(manifestPath), ...
            'Configuration baseline already exists. Pass true to replace it explicitly.');
    end
    if ~isfolder(configurationDirectory)
        mkdir(configurationDirectory);
    end

    addpath(repositoryRoot);
    addpath(fullfile(repositoryRoot, 'config'));
    addpath(fullfile(repositoryRoot, 'config', 'internal'));

    warningState = warning('query', 'ConfigFactory:rxCarrierBiasAbsorbed');
    warning('off', 'ConfigFactory:rxCarrierBiasAbsorbed');
    warningCleanup = onCleanup(@() warning(warningState.state, ...
        'ConfigFactory:rxCarrierBiasAbsorbed'));

    [baseResolved, baseMetadata] = resolveSimulationConfig();
    records = struct( ...
        'name', 'master_config_diagnostic', ...
        'sourcePath', '', ...
        'sourceSha256', '', ...
        'explicitPaths', {baseMetadata.explicitPaths}, ...
        'preResolutionConfig', baseMetadata.preResolutionConfig, ...
        'resolvedConfig', baseResolved);

    scenarioFiles = scenarioFileIndex(repositoryRoot);

    sources = repmat(struct('file', '', 'sha256', ''), numel(scenarioFiles), 1);
    for index = 1:numel(scenarioFiles)
        sourcePath = fullfile(scenarioFiles(index).folder, scenarioFiles(index).name);
        [resolvedConfig, metadata] = resolveSimulationConfig(sourcePath);
        records(end + 1) = struct( ... %#ok<AGROW>
            'name', erase(scenarioFiles(index).name, '.json'), ...
            'sourcePath', relativePath_(metadata.sourcePath, repositoryRoot), ...
            'sourceSha256', metadata.sourceSha256, ...
            'explicitPaths', {metadata.explicitPaths}, ...
            'preResolutionConfig', metadata.preResolutionConfig, ...
            'resolvedConfig', resolvedConfig);
        sources(index).file = records(end).sourcePath;
        sources(index).sha256 = metadata.sourceSha256;
    end

    capturedUtc = char(datetime('now', 'TimeZone', 'UTC', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ss''Z'''));
    classification = 'legacy-reference';
    save(snapshotPath, 'records', 'capturedUtc', 'classification', '-v7');

    manifest = struct();
    % v2: representativeScenarios.fourAsset -> .multiAsset, and scenarioSources now
    % enumerates config/*.json + config/ladder/<axis>/*.json instead of config/scenarios/.
    manifest.schemaVersion = 2;
    manifest.classification = classification;
    manifest.scientificStatus = 'Regression reference; not scientific approval.';
    manifest.capturedUtc = capturedUtc;
    manifest.repository = repositoryState_(repositoryRoot);
    manifest.environment = environmentState_();
    manifest.optionalDependencies = optionalDependencyState_(baseResolved);
    manifest.scenarioCount = numel(scenarioFiles);
    manifest.scenarioSources = sources;
    manifest.representativeScenarios = representativeScenarios_(records);
    manifest.snapshot = struct( ...
        'file', relativePath_(snapshotPath, repositoryRoot), ...
        'sha256', fileSha256_(snapshotPath), ...
        'recordCount', numel(records));
    manifest.numericalBaselines = numericalBaselines_( ...
        fullfile(regressionDirectory, 'golden'), repositoryRoot);

    fileIdentifier = fopen(manifestPath, 'wt');
    assert(fileIdentifier >= 0, 'Cannot write manifest: %s', manifestPath);
    cleanup = onCleanup(@() fclose(fileIdentifier));
    fprintf(fileIdentifier, '%s\n', jsonencode(manifest, 'PrettyPrint', true));
    clear cleanup

    fprintf('Captured %d resolved scenarios plus masterConfig in %s\n', ...
        numel(scenarioFiles), configurationDirectory);
end

function state = repositoryState_(repositoryRoot)
    [commitStatus, commit] = system(sprintf( ...
        'git -C "%s" rev-parse HEAD', repositoryRoot));
    [branchStatus, branch] = system(sprintf( ...
        'git -C "%s" branch --show-current', repositoryRoot));
    [dirtyStatus, dirtyOutput] = system(sprintf( ...
        'git -C "%s" status --short --untracked-files=all', repositoryRoot));
    assert(commitStatus == 0 && branchStatus == 0 && dirtyStatus == 0, ...
        'Unable to record repository state.');

    dirtyLines = splitlines(strtrim(dirtyOutput));
    if numel(dirtyLines) == 1 && strlength(dirtyLines) == 0
        dirtyLines = strings(0, 1);
    end
    state = struct( ...
        'commit', strtrim(commit), ...
        'branch', strtrim(branch), ...
        'dirty', ~isempty(dirtyLines), ...
        'dirtyEntries', {cellstr(dirtyLines)});
end

function state = environmentState_()
    products = ver;
    productRecords = repmat(struct( ...
        'name', '', 'version', '', 'release', '', 'date', ''), numel(products), 1);
    for index = 1:numel(products)
        productRecords(index).name = products(index).Name;
        productRecords(index).version = products(index).Version;
        productRecords(index).release = products(index).Release;
        productRecords(index).date = products(index).Date;
    end
    state = struct( ...
        'matlabVersion', version, ...
        'matlabRelease', version('-release'), ...
        'platform', computer, ...
        'operatingSystem', system_dependent('getos'), ...
        'products', productRecords);
end

function state = optionalDependencyState_(config)
    parallelAvailable = false;
    try
        parallelAvailable = license('test', 'Distrib_Computing_Toolbox');
    catch
    end
    state = struct( ...
        'lambdaToolboxAvailable', ...
            revgnss.integer.LambdaResolver.isAvailable(config), ...
        'parallelComputingToolboxLicensed', logical(parallelAvailable));
end

function selected = representativeScenarios_(records)
    % Pick the representatives STRUCTURALLY, never by file name. The previous version
    % asked for assetCounts == 4, which named a scenario family (isl_carrier_ckpt.json)
    % rather than a property; the config/ladder migration deleted it and left no
    % four-asset scenario at all, so the capture aborted. The ladder now runs 1, 2, 3
    % and 6 space assets -- "the largest multi-asset scenario" survives that kind of
    % re-shuffle, "== 4" does not.
    scenarioRecords = records(2:end);
    sourceFiles = {scenarioRecords.sourcePath};
    assetCounts = arrayfun(@(record) ...
        record.preResolutionConfig.scenario.nSpaceAssets, scenarioRecords);
    singleAssetIndex = find(assetCounts == 1, 1);
    multiAssetIndex = find(assetCounts == max(assetCounts), 1);
    assert(~isempty(singleAssetIndex) && ~isempty(multiAssetIndex) && ...
            max(assetCounts) > 1, ...
        ['The baseline requires at least one single-asset and one multi-asset ' ...
         'scenario (largest nSpaceAssets found: %d).'], max(assetCounts));

    realismGrade = arrayfun(@(record) logicalValue_( ...
        record.preResolutionConfig, {'realism', 'grade'}), scenarioRecords);
    retainInterSatelliteLinks = arrayfun(@(record) logicalValue_( ...
        record.preResolutionConfig, ...
        {'multiAsset', 'keepIslInPerAssetEkf'}), scenarioRecords);

    selected = struct( ...
        'singleAsset', sourceFiles{singleAssetIndex}, ...
        'multiAsset', sourceFiles{multiAssetIndex}, ...
        'realismGradeSelection', {sourceFiles(realismGrade)}, ...
        'interSatelliteLinkRetentionSelection', ...
            {sourceFiles(retainInterSatelliteLinks)});
end

function value = logicalValue_(inputStruct, fields)
    current = inputStruct;
    value = false;
    for index = 1:numel(fields)
        if ~isstruct(current) || ~isscalar(current) || ...
                ~isfield(current, fields{index})
            return
        end
        current = current.(fields{index});
    end
    if islogical(current) || isnumeric(current)
        value = isscalar(current) && logical(current);
    end
end

function baselines = numericalBaselines_(goldenDirectory, repositoryRoot)
    files = dir(fullfile(goldenDirectory, '*.mat'));
    [~, order] = sort({files.name});
    files = files(order);
    baselines = repmat(struct( ...
        'file', '', 'sha256', '', 'classification', 'legacy-reference'), ...
        numel(files), 1);
    for index = 1:numel(files)
        path = fullfile(files(index).folder, files(index).name);
        baselines(index).file = relativePath_(path, repositoryRoot);
        baselines(index).sha256 = fileSha256_(path);
    end
end

function relative = relativePath_(path, root)
    rootPrefix = [char(java.io.File(root).getCanonicalPath()) filesep];
    canonicalPath = char(java.io.File(path).getCanonicalPath());
    assert(startsWith(canonicalPath, rootPrefix), ...
        'Path is outside the repository: %s', canonicalPath);
    relative = canonicalPath(numel(rootPrefix) + 1:end);
end

function hash = fileSha256_(path)
    fileIdentifier = fopen(path, 'rb');
    assert(fileIdentifier >= 0, 'Cannot read file for hashing: %s', path);
    cleanup = onCleanup(@() fclose(fileIdentifier));
    bytes = fread(fileIdentifier, Inf, '*uint8');
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(bytes);
    hash = lower(reshape(dec2hex(typecast(digest.digest(), 'uint8'), 2).', 1, []));
    clear cleanup
end
