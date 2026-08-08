function exceptions = scenarioResolutionExceptionRegistry()
%SCENARIORESOLUTIONEXCEPTIONREGISTRY Explicit exceptions to scenario precedence.

%   Keep this as close to EMPTY as possible: every entry is a leaf a scenario asked for
%   and did not get. Only shape/type normalisations with identical VALUES belong here --
%   never a value the resolution actually overrode.

    % ---- The one and only entry class: signals.enabledMask orientation -------------------
    % ORIENTATION ONLY, VALUES IDENTICAL. jsondecode turns a JSON array into a COLUMN;
    % ConfigFactory stores the canonical mask as a ROW (logical(mask(:)).'), so [true,true]
    % resolves to 1x2 against the 2x1 the file parsed to, and isequaln calls that a change.
    % No JSON spelling can produce a row. Preserving the column instead would leak a
    % column-shaped mask into readers that compare shape (test_stage6_config_presets does
    % isequal(logical(mask),[true true])), so the normalisation is kept deliberately.
    % Every file below sets the mask because selecting the signal set is the whole point of
    % that file; none of them can avoid it. Added 2026-08-06 with the dual-frequency /
    % ionosphere-free fix, extended 2026-08-08 with the config/ladder/freq axis.
    maskFiles = { ...
        'test009_kaIonoFree.json', ...
        'freq001_L1only.json', ...
        'freq002_L1L2raw.json', ...
        'freq003_L1L2ionoFree.json', ...
        'freq004_L1L2ionoFreeNoIonoState.json', ...
        'freq005_L1L5raw.json', ...
        'freq006_L1L5ionoFree.json', ...
        'freq007_L1L2rawNoIonoState.json', ...
        'freq008_L1onlyNoIonoState.json'};

    maskReason = ['ORIENTATION ONLY, VALUES IDENTICAL. jsondecode parses the JSON array ' ...
                  'as a column; ConfigFactory stores the canonical mask as a row. See the ' ...
                  'block comment in this file for why the row shape is the one that is kept.'];

    exceptions = repmat( ...
        struct('scenarioFile', '', 'path', '', 'reason', ''), 1, numel(maskFiles));
    for index = 1:numel(maskFiles)
        exceptions(index).scenarioFile = maskFiles{index};
        exceptions(index).path         = 'signals.enabledMask';
        exceptions(index).reason       = maskReason;
    end
end
