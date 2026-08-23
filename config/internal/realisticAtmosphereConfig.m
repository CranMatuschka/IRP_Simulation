function cfg = realisticAtmosphereConfig(cfg)
%REALISTICATMOSPHERECONFIG Activate the master-owned complex atmosphere profile.

    if ~isfield(cfg, 'atmosphere') || ...
            ~isfield(cfg.atmosphere, 'realisticProfile')
        error('realisticAtmosphereConfig:missingProfile', ...
            'masterConfig must define atmosphere.realisticProfile.');
    end

    explicitPaths = {};
    try; explicitPaths = cfg.provenance.explicit; catch; end
    preProfileConfig = cfg;
    [cfg, ~] = deepMergeConfig(cfg, cfg.atmosphere.realisticProfile);

    for index = 1:numel(explicitPaths)
        path = explicitPaths{index};
        try
            value = getPath_(preProfileConfig, path);
            cfg = setPath_(cfg, path, value);
        catch
        end
    end
end

function value = getPath_(inputStruct, dottedPath)
    fields = strsplit(dottedPath, '.');
    value = inputStruct;
    for index = 1:numel(fields)
        if ~isstruct(value) || ~isfield(value, fields{index})
            error('realisticAtmosphereConfig:missingPath', ...
                'Configuration path does not exist: %s', dottedPath);
        end
        value = value.(fields{index});
    end
end

function outputStruct = setPath_(outputStruct, dottedPath, value)
    fields = strsplit(dottedPath, '.');
    if numel(fields) == 1
        outputStruct.(fields{1}) = value;
        return
    end
    outputStruct.(fields{1}) = setPath_( ...
        outputStruct.(fields{1}), strjoin(fields(2:end), '.'), value);
end
