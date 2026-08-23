function test_config_mode_enum_validation()
%TEST_CONFIG_MODE_ENUM_VALIDATION  A mistyped mode string must ERROR, not fall back.
%
%   Before 2026-08-09 nothing in the pipeline validated a model-name string:
%   deepMergeConfig checks PATHS, not values, and every mode dispatch ends in a silent
%   default branch. So cfg.errors.troposphere.modelType = 'singleMapped' (one letter off
%   'simpleMapped') was accepted by the merge, missed every case at EnvironmentModel.m:392,
%   fell to the otherwise at :445 which returns delay = 0, and produced a
%   TROPOSPHERE-FREE run -- while the report printed 'singleMapped' as the active model.
%
%   Two things are asserted here:
%     1. the positive control -- every legal value of every registry entry is accepted;
%     2. the negative control -- a near-miss typo of each entry is rejected with the
%        validateMasterConfig:unknownModeValue identifier.
%   Plus the safety net that matters most in practice: every shipped scenario JSON must
%   still resolve, so the registry can never have invented a legal set that excludes a
%   configuration the repo actually ships.

    thisDir = fileparts(mfilename('fullpath'));
    oo_v1Root = fileparts(thisDir);
    addpath(oo_v1Root);
    addpath(fullfile(oo_v1Root, 'config'));
    addpath(fullfile(oo_v1Root, 'config', 'internal'));

    nFail = 0;
    nFail = nFail + i_legalValuesAccepted();
    nFail = nFail + i_typosRejected();
    nFail = nFail + i_shippedScenariosStillResolve(oo_v1Root);
    nFail = nFail + i_everyConfigSourceSatisfiesRegistry();
    nFail = nFail + i_theTroposphereExample();

    if nFail > 0
        error('test_config_mode_enum_validation:fail', '%d check(s) failed.', nFail);
    end
    fprintf('test_config_mode_enum_validation: PASS\n');
end

function n = i_legalValuesAccepted()
    entries = configEnumRegistry();
    base = masterConfig();
    n = 0;
    for k = 1:numel(entries)
        for v = 1:numel(entries(k).values)
            cfg = i_setPath(base, strsplit(entries(k).path, '.'), entries(k).values{v});
            try
                validateMasterConfig(cfg);
            catch ME
                if strcmp(ME.identifier, 'validateMasterConfig:unknownModeValue')
                    n = n + 1;
                    fprintf(2, '  FAIL: legal value %s = ''%s'' was rejected\n', ...
                        entries(k).path, entries(k).values{v});
                end
                % Any OTHER error is a downstream contract the registry does not own
                % (e.g. codeMode=ionosphereFree needing two signals) -- not our concern.
            end
        end
    end
end

function n = i_typosRejected()
    entries = configEnumRegistry();
    base = masterConfig();
    n = 0;
    for k = 1:numel(entries)
        typo = [entries(k).values{1} 'Xq'];     % a near miss, never a legal value
        cfg  = i_setPath(base, strsplit(entries(k).path, '.'), typo);
        rejected = false;
        try
            validateMasterConfig(cfg);
        catch ME
            rejected = strcmp(ME.identifier, 'validateMasterConfig:unknownModeValue');
        end
        if ~rejected
            n = n + 1;
            fprintf(2, '  FAIL: typo %s = ''%s'' was NOT rejected\n', entries(k).path, typo);
        end
    end
end

function n = i_shippedScenariosStillResolve(oo_v1Root)
    [~, dirs] = scenarioFileIndex(oo_v1Root);
    names = {};
    for d = 1:numel(dirs)
        L = dir(fullfile(dirs{d}, '*.json'));
        for k = 1:numel(L); names{end+1} = L(k).name; end %#ok<AGROW>
    end
    names = unique(names);
    n = 0;
    for k = 1:numel(names)
        try
            evalc('resolveSimulationConfig(names{k})');
        catch ME
            n = n + 1;
            fprintf(2, '  FAIL: shipped scenario %s no longer resolves (%s)\n', ...
                names{k}, ME.identifier);
        end
    end
    if isempty(names)
        n = n + 1;
        fprintf(2, '  FAIL: scenarioFileIndex found no scenario JSONs to check\n');
    end
end

function n = i_everyConfigSourceSatisfiesRegistry()
%   The JSON sweep above is NOT enough on its own, and finding that out was the point.
%   The frozen golden fixtures are .m files that go straight to finalizeConfig without
%   passing through validateMasterConfig, so the registry never sees them at runtime. When
%   the registry was first written it listed scintillation.model = {'conker'} only, and
%   the single and headline goldens ship 'legacy' -- a real, named mode. Two further legal
%   values were found the same way (towerClock.correctionMode = 'noisyCorrection' from
%   ConfigFactory.clockNoiseConfig, and the inert 'seededTruthResidual' from
%   geoRealWorldTruthComparisonConfig). So sweep EVERY config-producing entry point in the
%   repo against the registry: a miss here means the registry has invented a legal set
%   that excludes a configuration this repo actually ships.
    entries = configEnumRegistry();
    [cfgs, names] = i_allConfigSources();
    n = 0;
    for c = 1:numel(cfgs)
        for e = 1:numel(entries)
            [found, val] = i_getPath(cfgs{c}, strsplit(entries(e).path, '.'));
            if ~found || ~(ischar(val) || isstring(val)); continue; end
            val = char(val);
            if entries(e).caseSense
                ok = any(strcmp(val, entries(e).values));
            else
                ok = any(strcmpi(val, entries(e).values));
            end
            if ~ok
                n = n + 1;
                fprintf(2, ['  FAIL: %s sets %s = ''%s'', which the registry rejects. ' ...
                            'Either it is a real mode missing from the legal set, or that ' ...
                            'config is wrong -- decide which, do not just widen the set.\n'], ...
                    names{c}, entries(e).path, val);
            end
        end
    end
end

function [cfgs, names] = i_allConfigSources()
    cfgs = {}; names = {};
    fixtures = {'goldenScenarioConfig', 'goldenHeadlineScenarioConfig', ...
                'goldenRealismScenarioConfig', 'goldenFeat024ScenarioConfig'};
    for k = 1:numel(fixtures)
        try
            cfgs{end+1} = feval(fixtures{k}, 120); names{end+1} = fixtures{k}; %#ok<AGROW>
        catch
        end
    end
    meta = ?revgnss.ConfigFactory;
    for k = 1:numel(meta.MethodList)
        m = meta.MethodList(k);
        if ~m.Static || ~isempty(m.InputNames) || numel(m.OutputNames) ~= 1; continue; end
        if ~endsWith(m.Name, 'Config'); continue; end
        try
            c = revgnss.ConfigFactory.(m.Name)();
            if isstruct(c)
                cfgs{end+1} = c; names{end+1} = ['ConfigFactory.' m.Name]; %#ok<AGROW>
            end
        catch
        end
    end
    try; cfgs{end+1} = masterConfig();           names{end+1} = 'masterConfig()';        catch; end
    try; cfgs{end+1} = masterConfig('baseOnly'); names{end+1} = 'masterConfig(baseOnly)'; catch; end
end

function n = i_theTroposphereExample()
%   The specific case that motivated the registry, asserted by name so it cannot regress.
    cfg = masterConfig();
    cfg.errors.troposphere.modelType = 'singleMapped';
    rejected = false;
    try
        validateMasterConfig(cfg);
    catch ME
        rejected = strcmp(ME.identifier, 'validateMasterConfig:unknownModeValue');
    end
    n = double(~rejected);
    if n > 0
        fprintf(2, ['  FAIL: ''singleMapped'' (typo of ''simpleMapped'') still accepted -- ' ...
                    'this silently runs a troposphere-free simulation\n']);
    end
end

function [found, value] = i_getPath(cfg, path)
    value = cfg;
    found = false;
    for k = 1:numel(path)
        if isstruct(value) && isscalar(value) && isfield(value, path{k})
            value = value.(path{k});
        else
            value = [];
            return
        end
    end
    found = true;
end

function cfg = i_setPath(cfg, path, value)
    if numel(path) == 1
        cfg.(path{1}) = value;
        return
    end
    if ~isfield(cfg, path{1}); cfg.(path{1}) = struct(); end
    cfg.(path{1}) = i_setPath(cfg.(path{1}), path(2:end), value);
end
