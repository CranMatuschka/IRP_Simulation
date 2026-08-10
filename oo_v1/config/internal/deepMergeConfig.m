function [base, paths] = deepMergeConfig(base, overlay, prefix)
%DEEPMERGECONFIG Overlay a config and record its explicitly supplied paths.
%   Unknown paths and type mismatches are rejected. Struct-array replacements
%   are checked against the master schema before assignment.

    if nargin < 3; prefix = ''; end
    paths = {};
    if ~isstruct(overlay)
        base = overlay;
        if ~isempty(prefix); paths = {prefix}; end
        return
    end
    fieldNames = fieldnames(overlay);
    for fieldIndex = 1:numel(fieldNames)
        fieldName = fieldNames{fieldIndex};
        % jsondecode maps a leading underscore to 'x_'; comment keys are ignored.
        if startsWith(fieldName, 'x_'); continue; end
        if isempty(prefix)
            path = fieldName;
        else
            path = [prefix '.' fieldName];
        end
        % OPEN CONTAINERS: paths whose CHILD NAMES are user-defined by design, so an
        % unrecognised field is the intended usage and not a typo. The entry is assigned
        % wholesale -- a child here is a leaf record, not something to merge into a
        % schema. Keep this list TINY: every entry is a hole in the protection that
        % catches 'singleMapped' written for 'simpleMapped'. The consumer must validate
        % its own contents instead (ConfigFactory.normaliseOscillator_ does).
        if isOpenContainer_(prefix)
            base.(fieldName) = overlay.(fieldName);
            paths{end+1} = path; %#ok<AGROW>
            continue
        end
        if ~isfield(base, fieldName)
            error('deepMergeConfig:unknownConfigPath', ...
                'Unknown configuration path: %s', path);
        end
        if xor(isstruct(base.(fieldName)), isstruct(overlay.(fieldName)))
            error('deepMergeConfig:configTypeMismatch', ...
                'Configuration type does not match masterConfig at: %s', path);
        elseif isstruct(base.(fieldName)) && ...
                isstruct(overlay.(fieldName)) && ...
                isscalar(base.(fieldName)) && ...
                isscalar(overlay.(fieldName))
            [base.(fieldName), subPaths] = deepMergeConfig( ...
                base.(fieldName), overlay.(fieldName), path);
            paths = [paths, subPaths]; %#ok<AGROW>
        elseif isstruct(base.(fieldName)) && isstruct(overlay.(fieldName))
            replacement = stripMetadataFields_(overlay.(fieldName));
            validateStructSchema_(base.(fieldName), replacement, path);
            base.(fieldName) = replacement;
            paths{end+1} = path; %#ok<AGROW>
        else
            base.(fieldName) = overlay.(fieldName);
            paths{end+1} = path; %#ok<AGROW>
        end
    end
end

function tf = isOpenContainer_(prefix)
    % Paths whose children are user-defined names rather than schema fields.
    tf = any(strcmp(prefix, { ...
        'clock.customOscillators' ...   % oscillator NAME -> h-coefficient struct
    }));
end

function validateStructSchema_(base, overlay, prefix)
    allowed = fieldnames(base);
    supplied = fieldnames(overlay);
    unknown = setdiff(supplied, allowed);
    if ~isempty(unknown)
        error('deepMergeConfig:unknownConfigPath', ...
            'Unknown configuration path: %s.%s', prefix, unknown{1});
    end
    if isempty(base) || isempty(overlay)
        return
    end

    for overlayIndex = 1:numel(overlay)
        baseIndex = min(overlayIndex, numel(base));
        for fieldIndex = 1:numel(supplied)
            field = supplied{fieldIndex};
            baseValue = base(baseIndex).(field);
            overlayValue = overlay(overlayIndex).(field);
            if xor(isstruct(baseValue), isstruct(overlayValue))
                error('deepMergeConfig:configTypeMismatch', ...
                    'Configuration type does not match masterConfig at: %s.%s', ...
                    prefix, field);
            end
            if isstruct(baseValue) && isstruct(overlayValue)
                validateStructSchema_( ...
                    baseValue, overlayValue, [prefix '.' field]);
            end
        end
    end
end

function inputStruct = stripMetadataFields_(inputStruct)
    metadata = fieldnames(inputStruct);
    metadata = metadata(startsWith(metadata, 'x_'));
    if ~isempty(metadata)
        inputStruct = rmfield(inputStruct, metadata);
    end
end
