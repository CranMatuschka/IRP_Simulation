function cfg = preserveScenarioOwned(cfg, writer)
%PRESERVESCENARIOOWNED Apply a derived-config writer without replacing JSON-owned paths.

    ownedPaths = {};
    try; ownedPaths = cfg.provenance.explicit; catch; end

    preWriterConfig = cfg;
    cfg = writer(cfg);

    for pathIndex = 1:numel(ownedPaths)
        path = ownedPaths{pathIndex};
        value = getPath_(preWriterConfig, path);
        cfg = setPath_(cfg, path, value);
    end
end

function value = getPath_(inputStruct, dottedPath)
    fields = strsplit(dottedPath, '.');
    value = inputStruct;
    for fieldIndex = 1:numel(fields)
        if ~isstruct(value) || ~isfield(value, fields{fieldIndex})
            error('preserveScenarioOwned:noPath', ...
                'Configuration path does not exist: %s', dottedPath);
        end
        value = value.(fields{fieldIndex});
    end
end

function outputStruct = setPath_(outputStruct, dottedPath, value)
    fields = strsplit(dottedPath, '.');
    if numel(fields) == 1
        outputStruct.(fields{1}) = value;
        return
    end
    if ~isfield(outputStruct, fields{1}) || ...
            ~isstruct(outputStruct.(fields{1}))
        outputStruct.(fields{1}) = struct();
    end
    outputStruct.(fields{1}) = setPath_( ...
        outputStruct.(fields{1}), strjoin(fields(2:end), '.'), value);
end
