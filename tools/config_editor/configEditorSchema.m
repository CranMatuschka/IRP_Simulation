function schema = configEditorSchema(repositoryRoot)
%CONFIGEDITORSCHEMA  Everything the standalone config editor needs, as one struct.
%   schema = configEditorSchema()  builds the description of every editable config leaf
%   from the sources that already own that knowledge, so nothing here is a second copy of
%   a fact stated elsewhere:
%
%       masterConfig()                  the leaf inventory, its defaults and its types
%       config/masterConfig.m (source)  the '%%' section headers and the '%' prose, i.e.
%                                       the documentation shown against each knob
%       configEnumRegistry(cfg)         the legal value set for the string knobs whose
%                                       typo is dangerous
%       derivedConfigPathRegistry()     the paths a scenario must NOT write, with reasons
%       scenarioFileIndex()             the shipped scenarios, used both as the choosable
%                                       base files and as the evidence behind the tiers
%
%   THE TIERS ARE MEASURED, NOT CHOSEN. masterConfig carries ~1362 leaves, which is not a
%   list anyone can work through. But the shipped scenario JSONs write only ~390 distinct
%   leaves between them, and a small core appears in most of them. That distribution is
%   this project's own answer to "which knobs actually matter", accumulated over every
%   ladder axis it has run, so the editor's depth selector is built from it rather than
%   from an opinion:
%
%       tier 1  'essentials'  written by >= 8 shipped scenarios
%       tier 2  'used'        written by >= 1 shipped scenario
%       tier 3  'everything'  present in masterConfig at all
%
%   Re-run tools/config_editor/buildConfigEditor.m after changing masterConfig, or the
%   generated editor goes stale. tests/test_config_editor_schema.m enforces that.
%
%   See also BUILDCONFIGEDITOR, CHECKPERSONALCONFIG, DERIVEDCONFIGPATHREGISTRY.

    if nargin < 1 || isempty(repositoryRoot)
        repositoryRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
    end
    addpath(repositoryRoot);
    addpath(fullfile(repositoryRoot, 'config'));
    addpath(fullfile(repositoryRoot, 'config', 'internal'));

    ESSENTIALS_THRESHOLD = 8;

    cfg  = masterConfig();
    docs = harvestMasterConfigDocs_(fullfile(repositoryRoot, 'config', 'masterConfig.m'));
    [tierCount, bases] = shippedScenarioEvidence_(repositoryRoot);
    enums   = enumMap_(cfg);
    derived = derivedMap_();

    % Block prose and section headers are SHARED: one comment introduces a run of
    % assignments, so the same paragraph belongs to many leaves. Emitting the text on every
    % leaf that carries it put a quarter of a megabyte of duplicated strings into the page.
    % They are interned here and referenced by index, and the editor looks them back up.
    blockDocs = stringPool_();
    sections  = stringPool_();

    paths = leafPaths_(cfg, '');
    fields = cell(1, numel(paths));
    for index = 1:numel(paths)
        path = paths{index};
        value = valueAtPath_(cfg, path);

        entry = struct();
        entry.path     = path;
        entry.group    = groupForPath_(path);
        entry.subgroup = subgroupForPath_(path);
        [entry.type, entry.default, entry.editable] = encodeDefault_(value);

        entry.doc = mapGet_(docs.leaf, path, '');
        entry.bd  = blockDocs.intern(mapGet_(docs.block,   path, ''));
        entry.sec = sections.intern( mapGet_(docs.section, path, ''));

        % Two grades of choice list, kept apart on purpose. A registry entry is CHECKED:
        % validateMasterConfig rejects anything outside it, so the editor can present a
        % closed dropdown. A list merely parsed out of the prose is NOT checked, and the
        % prose is sometimes an illustration rather than the full set, so it is offered as
        % a suggestion beside a free-text box. Presenting the second as the first would
        % make the editor refuse legal values on nothing better than a comment's authority.
        if isKey(enums, path)
            found = enums(path);
            entry.values   = found.values;
            entry.enumNote = found.note;
            entry.type     = 'enum';
            entry.editable = true;
        elseif strcmp(entry.type, 'string')
            suggested = quotedAlternatives_(entry.doc);
            if ~isempty(suggested); entry.suggested = suggested; end
        end

        if isKey(derived, path)
            entry.derived = derived(path);
        end

        count = 0;
        if isKey(tierCount, path); count = tierCount(path); end
        if count > 0; entry.usedBy = count; end
        if count >= ESSENTIALS_THRESHOLD || isEffectToggle_(path)
            entry.tier = 'essentials';
        elseif count >= 1
            entry.tier = 'used';
        else
            entry.tier = 'everything';
        end

        % The optional fields above are LEFT OUT rather than emitted empty. fields is a
        % cell array, so jsonencode gives each entry its own key set, and 1362 copies of
        % four empty placeholders is a tenth of the page for no information. The editor
        % fills the absent ones in once at load.
        fields{index} = entry;
    end

    tiers = cellfun(@(f) string(f.tier), fields);

    schema = struct();
    schema.generated = struct( ...
        'matlabRelease',       version('-release'), ...
        'leafCount',           numel(fields), ...
        'essentialsThreshold', ESSENTIALS_THRESHOLD, ...
        'scenarioCount',       numel(bases), ...
        'masterConfigSha256',  fileSha256_(fullfile(repositoryRoot, 'config', 'masterConfig.m')));
    schema.counts = struct( ...
        'essentials', sum(tiers == "essentials"), ...
        'used',       sum(tiers == "used"), ...
        'everything', sum(tiers == "everything"));
    schema.groups        = groupOrder_();
    schema.bases         = bases;
    schema.masterEnables = masterEnablePaths_();
    schema.blockDocs     = blockDocs.values();
    schema.sections      = sections.values();
    schema.fields        = fields;
end

function pool = stringPool_()
%STRINGPOOL_ Intern repeated strings so each distinct one is emitted once.
%   intern('') returns -1, the editor's "nothing here" index. Everything else returns a
%   0-based index into values(), because the consumer is JavaScript.
    store = containers.Map('KeyType', 'char', 'ValueType', 'double');
    order = {};
    pool = struct('intern', @intern_, 'values', @values_);

    function index = intern_(text)
        if isempty(text); index = -1; return; end
        if isKey(store, text)
            index = store(text);
            return
        end
        index = numel(order);
        store(text) = index;
        order{end + 1} = text;
    end

    function out = values_()
        out = order;
    end
end

function hash = fileSha256_(path)
%FILESHA256_ Identity of the masterConfig this schema was built from.
%   The generated editor is committed so a teammate can open it without running MATLAB
%   first, which means it can fall behind the config it edits. Stamping the source hash
%   turns "is this editor current?" into an exact comparison rather than a judgement, and
%   is what tests/test_config_editor_schema.m checks. Same construction as
%   resolveSimulationConfig's function of this name.
    fileIdentifier = fopen(path, 'rb');
    assert(fileIdentifier >= 0, 'configEditorSchema:fileRead', ...
        'Cannot read %s', path);
    cleanup = onCleanup(@() fclose(fileIdentifier));
    bytes = fread(fileIdentifier, Inf, '*uint8');
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(bytes);
    hash = lower(reshape(dec2hex(typecast(digest.digest(), 'uint8'), 2).', 1, []));
    clear cleanup
end

% ============================================================================
% The leaf inventory
% ============================================================================

function paths = leafPaths_(value, prefix)
%LEAFPATHS_ Dotted path of every leaf, using deepMergeConfig's own definition of one.
%   A SCALAR struct recurses. Anything else is a leaf, including a struct ARRAY, which
%   deepMergeConfig replaces wholesale rather than merging into. Mirroring that rule here
%   is what keeps the editor's idea of a leaf identical to the resolver's.
    paths = {};
    if ~isstruct(value) || ~isscalar(value)
        if ~isempty(prefix); paths = {prefix}; end
        return
    end
    names = fieldnames(value);
    for index = 1:numel(names)
        if isempty(prefix)
            path = names{index};
        else
            path = [prefix '.' names{index}];
        end
        paths = [paths, leafPaths_(value.(names{index}), path)]; %#ok<AGROW>
    end
end

function value = valueAtPath_(root, path)
    parts = strsplit(path, '.');
    value = root;
    for index = 1:numel(parts)
        value = value.(parts{index});
    end
end

function [type, encoded, editable] = encodeDefault_(value)
%ENCODEDEFAULT_ Classify a default into something an HTML control can carry.
%   MAX_CHARS caps what a single default may contribute to the generated page. The tower
%   catalogue alone is a 1x30 struct array, and inlining defaults of that size for every
%   such leaf would dominate the file. Oversized and structurally complex leaves stay in
%   the schema so the inventory is complete, but are marked non-editable rather than
%   silently dropped, because "not offered" and "does not exist" must not look the same.
    MAX_CHARS = 400;
    editable = true;
    if islogical(value) && isscalar(value)
        type = 'bool';
    elseif isnumeric(value) && isscalar(value) && isreal(value)
        type = 'number';
    elseif ischar(value) || (isstring(value) && isscalar(value))
        type = 'string';
    elseif isnumeric(value) && ~isempty(value)
        type = 'array';
    elseif islogical(value)
        type = 'array';
    elseif isempty(value) && ~isstruct(value)
        type = 'array';
    else
        type = 'other';
        editable = false;
    end

    try
        encoded = jsonencode(value);
    catch
        encoded = '';
        type = 'other';
        editable = false;
    end
    if numel(encoded) > MAX_CHARS
        encoded = '';
        type = 'other';
        editable = false;
    end
end

% ============================================================================
% Documentation harvested from the masterConfig source
% ============================================================================

function docs = harvestMasterConfigDocs_(sourcePath)
%HARVESTMASTERCONFIGDOCS_ Attach masterConfig's own prose to the paths it describes.
%   masterConfig.m documents itself in three registers and all three are worth keeping:
%
%       '%%' header        the topic the following block belongs to     -> docs.section
%       '%'  block         prose above a RUN of assignments, describing
%                          the group as a whole                         -> docs.block
%       trailing '% ...'   a note on that one assignment                -> docs.leaf
%
%   Indexed targets such as cfg.towers(k).clock.bias_s are skipped: they are not
%   scalar-struct leaves and have no path in the inventory to attach to.
%
%   HOW FAR A BLOCK REACHES depends on where it sits, because the file uses the same
%   syntax for two different jobs. Compare:
%
%       %% Error sources                          <- section blurb, covers what follows
%       % Hardware delay, multipath, tower survey and correlated noise are off by
%       % default; antenna PCO is on.
%       cfg.errors.hardwareDelay.enable = false;
%       cfg.errors.multipath.enable     = false;
%
%       cfg.errors.troposphere.stochastic.enable = false;
%       % Declared model uncertainty. Must be consistent with the model error this        <- annotates
%       % config actually commits: truth 2.45 - model 2.30*biasFraction = 0.15 m.            ONE line
%       cfg.errors.troposphere.sigma_m  = 0.15;
%       cfg.errors.ionosphere.enable    = true;   <- NOT what that paragraph is about
%
%   Letting every block run to the next one put the sigma_m paragraph on
%   errors.ionosphere.enable, which is not merely unhelpful: it is a confident, specific,
%   wrong explanation of a knob, in an editor whose reason for existing is that silently
%   wrong configuration is this project's dominant failure mode.
%
%   So a block that opens a section reaches everything until the next block, and a block
%   appearing mid-section reaches only the assignments sharing the first two path
%   components of the one directly beneath it. The cost is that a mid-section block
%   spanning several subsystems stops early. Prose is then missing, and missing prose
%   sends the reader to masterConfig.m, which is where the answer is anyway.
%
%   A TRAILING COMMENT MAY RUN ON. masterConfig wraps long notes onto the following lines,
%   aligned under the first:
%
%       cfg.scenario.nTowers = 5;   % 5-tower default (frozen-golden network). baseConfig
%                                   % defines 30 real sites; nTowers selects a PREFIX of
%                                   % them (finalizeConfig trims cfg.towers(1:nTowers)).
%
%   Reading those continuation lines as a fresh block would truncate nTowers' note at
%   "baseConfig" AND misfile the rest of it as documentation for whatever knob comes next.
%   So comment lines directly beneath an assignment that carried a trailing comment, with
%   no blank line between, continue that comment instead of starting a block.
    docs = struct( ...
        'leaf',    containers.Map('KeyType', 'char', 'ValueType', 'char'), ...
        'block',   containers.Map('KeyType', 'char', 'ValueType', 'char'), ...
        'section', containers.Map('KeyType', 'char', 'ValueType', 'char'));

    lines = strsplit(fileread(sourcePath), newline);
    section = '';
    block = {};
    blockIsFresh = false;
    runOnPath = '';
    blockOpensSection = false;   % true while no assignment has been seen since the '%%'
    blockScope = '';             % the 2-component prefix a mid-section block is about
    sinceSection = 0;

    for index = 1:numel(lines)
        line = lines{index};
        trimmed = strtrim(line);

        if startsWith(trimmed, '%%')
            section = strtrim(extractAfter(trimmed, 2));
            block = {};
            blockIsFresh = false;
            runOnPath = '';
            sinceSection = 0;
            blockScope = '';
            continue
        end
        if startsWith(trimmed, '%')
            text = strtrim(extractAfter(trimmed, 1));
            if ~isempty(runOnPath)
                docs.leaf(runOnPath) = strtrim([docs.leaf(runOnPath) ' ' text]);
                continue
            end
            if ~blockIsFresh
                block = {};
                blockOpensSection = (sinceSection == 0);
                blockScope = '';
            end
            block{end + 1} = text; %#ok<AGROW>
            blockIsFresh = true;
            continue
        end
        if isempty(trimmed)
            runOnPath = '';
            continue
        end

        token = regexp(trimmed, '^cfg\.([A-Za-z_][A-Za-z0-9_.]*)\s*=', 'tokens', 'once');
        blockIsFresh = false;
        runOnPath = '';
        if isempty(token)
            continue
        end
        path = token{1};
        sinceSection = sinceSection + 1;

        if ~isempty(section) && ~isKey(docs.section, path)
            docs.section(path) = section;
        end

        if ~isempty(block)
            if blockOpensSection
                inScope = true;
            else
                if isempty(blockScope); blockScope = pathPrefix2_(path); end
                inScope = strcmp(pathPrefix2_(path), blockScope);
                if ~inScope; block = {}; end
            end
            if inScope && ~isKey(docs.block, path)
                docs.block(path) = strjoin(block, ' ');
            end
        end
        % Only the FIRST assignment to a path owns its note, so a re-assignment in the
        % scenario-assembly section cannot overwrite the documented one. Run-on capture is
        % armed only when this line actually wrote the note, otherwise the continuation of
        % a SECOND comment would be appended to the first one's text.
        trailing = trailingComment_(line);
        if ~isempty(trailing) && ~isKey(docs.leaf, path)
            docs.leaf(path) = trailing;
            runOnPath = path;
        end
    end
end

function prefix = pathPrefix2_(path)
%PATHPREFIX2_ The first two components of a dotted path, the level a subsystem sits at.
%   errors.troposphere.stochastic.modelResidual.mode -> 'errors.troposphere'
    parts = strsplit(path, '.');
    if numel(parts) <= 1
        prefix = parts{1};
    else
        prefix = [parts{1} '.' parts{2}];
    end
end

function comment = trailingComment_(line)
%TRAILINGCOMMENT_ The '% ...' at the end of an assignment, ignoring '%' inside a string.
%   sprintf format strings and path literals in this file contain '%' and quotes, so the
%   scan has to track quoting rather than take the first '%' it meets.
    comment = '';
    inQuote = false;
    index = 1;
    while index <= numel(line)
        character = line(index);
        if character == ''''
            % A doubled quote is an escaped quote inside a string, not a delimiter.
            if inQuote && index < numel(line) && line(index + 1) == ''''
                index = index + 2;
                continue
            end
            inQuote = ~inQuote;
        elseif character == '%' && ~inQuote
            comment = strtrim(line(index + 1:end));
            return
        end
        index = index + 1;
    end
end

function tf = isEffectToggle_(path)
%ISEFFECTTOGGLE_ The on/off switch for one physical effect, promoted into 'essentials'.
%   The tiers are otherwise measured from how often the shipped scenarios write a knob,
%   and by that measure the effect switches score badly: the ladder holds one rung per
%   effect, so errors.multipath.enable is written by a handful of files and lands outside
%   the top tier. Ranked purely on frequency the essentials view therefore opened with no
%   Error sources section at all, which is the section most people come here for.
%
%   Frequency is the wrong question for these. "Which error sources are active?" is the
%   first thing anyone asks of a scenario, so every effect switch is present at every
%   detail level by construction, whether or not the ladder happens to toggle it often.
    tf = ~isempty(regexp(path, '^(errors|effects|physics)\.[A-Za-z0-9_]+\.enable$', 'once')) ...
        || ~isempty(regexp(path, '^physics\.relativity\.[A-Za-z0-9_]+\.enable$', 'once')) ...
        || any(strcmp(path, {'atmosphere.realistic', 'atmosphere.ionosphereFree', ...
                             'atmosphere.estimateIono', 'realism.grade'}));
end

function values = quotedAlternatives_(doc)
%QUOTEDALTERNATIVES_ The "'a' | 'b' | 'c'" set a trailing comment sometimes spells out.
%   masterConfig documents many string knobs by listing their alternatives inline:
%
%       cfg.report.compileTex = 'require';   % 'require' | 'auto' | 'never'
%
%   Those knobs are absent from configEnumRegistry because a wrong value there changes a
%   label rather than the physics, which is the bar an entry has to clear. That makes them
%   unchecked, not undocumented, and retyping the alternatives by hand is exactly the
%   transcription step worth not doing. Requires at least two alternatives separated by a
%   pipe, so an ordinary quoted word in a sentence is not mistaken for a choice list.
    values = {};
    if isempty(doc); return; end
    matched = regexp(doc, '''[^'']*''(\s*\|\s*''[^'']*'')+', 'match', 'once');
    if isempty(matched); return; end
    values = regexp(matched, '''([^'']*)''', 'tokens');
    values = cellfun(@(t) t{1}, values, 'UniformOutput', false);
end

% ============================================================================
% Registries and shipped-scenario evidence
% ============================================================================

function map = enumMap_(cfg)
    map = containers.Map('KeyType', 'char', 'ValueType', 'any');
    entries = configEnumRegistry(cfg);
    for index = 1:numel(entries)
        map(entries(index).path) = struct( ...
            'values', {entries(index).values}, ...
            'note',   entries(index).note);
    end
end

function map = derivedMap_()
    map = containers.Map('KeyType', 'char', 'ValueType', 'any');
    entries = derivedConfigPathRegistry();
    for index = 1:numel(entries)
        map(entries(index).path) = struct( ...
            'severity', entries(index).severity, ...
            'instead',  entries(index).instead, ...
            'note',     entries(index).note);
    end
end

function [tierCount, bases] = shippedScenarioEvidence_(repositoryRoot)
%SHIPPEDSCENARIOEVIDENCE_ How often each leaf is written, and the choosable base files.
%   Reads the SHIPPED scenarios only. scenarioFileIndex returns the tracked ladder as its
%   first output and the wider lookup path as its second, and this deliberately uses the
%   first: config/personal/ is a scratch space, and letting a personal file vote on which
%   knobs are "essential" would make one person's experiment reshape everyone's editor.
    tierCount = containers.Map('KeyType', 'char', 'ValueType', 'double');
    files = scenarioFileIndex(repositoryRoot);
    bases = cell(1, numel(files));

    for index = 1:numel(files)
        filePath = fullfile(files(index).folder, files(index).name);
        try
            overlay = jsondecode(fileread(filePath));
        catch
            bases{index} = struct('name', files(index).name, 'folder', '', 'summary', '');
            continue
        end

        % The tier count measures what each file CHOSE to write, so it counts a file's own
        % leaves and not the ones it inherits through "_extends". A rung that inherits 40
        % leaves from the golden did not decide anything about them, and counting them
        % would rank every golden key as essential purely because the golden is popular.
        written = overlayLeafPaths_(overlay, '');
        for pathIndex = 1:numel(written)
            path = written{pathIndex};
            if isKey(tierCount, path)
                tierCount(path) = tierCount(path) + 1;
            else
                tierCount(path) = 1;
            end
        end

        folder = strrep(files(index).folder, repositoryRoot, '');
        folder = strrep(strrep(folder, '\', '/'), '//', '/');
        if startsWith(folder, '/'); folder = extractAfter(folder, 1); end

        % Each file's own leaves plus the name of its parent, NOT the flattened chain. The
        % editor walks the chain itself, which keeps the inherited leaves stored once
        % rather than copied into every descendant.
        leaves = struct('path', {}, 'value', {});
        for pathIndex = 1:numel(written)
            encoded = '';
            try
                encoded = jsonencode(valueAtPath_(overlay, written{pathIndex}));
            catch
            end
            leaves(end + 1) = struct( ...
                'path', written{pathIndex}, 'value', encoded); %#ok<AGROW>
        end

        bases{index} = struct( ...
            'name',      files(index).name, ...
            'folder',    folder, ...
            'summary',   baseSummary_(overlay), ...
            'extends',   extendsRef_(overlay), ...
            'leaves',    {leaves});
    end
end

function ref = extendsRef_(overlay)
%EXTENDSREF_ The "_extends" parent, which jsondecode exposes as 'x_extends'.
%   Same accessor as resolveSimulationConfig's function of this name.
    ref = '';
    if isstruct(overlay) && isfield(overlay, 'x_extends')
        value = overlay.x_extends;
        if ischar(value) || (isstring(value) && isscalar(value))
            ref = char(value);
        end
    end
end

function summary = baseSummary_(overlay)
%BASESUMMARY_ The one-line self-description a scenario file carries, if it carries one.
%   jsondecode renders the leading-underscore comment keys as 'x_', so "_delta" is
%   'x_delta'. _delta states what a ladder rung changes, which is the most useful thing to
%   show next to its name; _id is the fallback for the files that predate that convention.
    summary = '';
    for key = {'x_delta', 'x_id', 'x_purpose'}
        if isfield(overlay, key{1})
            value = overlay.(key{1});
            if ischar(value) || (isstring(value) && isscalar(value))
                summary = char(value);
                return
            end
        end
    end
end

function paths = overlayLeafPaths_(overlay, prefix)
%OVERLAYLEAFPATHS_ Leaf paths of ONE decoded scenario overlay.
%   Same rule as resolveSimulationConfig's function of this name, including skipping the
%   'x_' keys jsondecode produces from the leading-underscore comment keys.
    paths = {};
    if ~isstruct(overlay) || ~isscalar(overlay)
        if ~isempty(prefix); paths = {prefix}; end
        return
    end
    names = fieldnames(overlay);
    for index = 1:numel(names)
        if startsWith(names{index}, 'x_'); continue; end
        if isempty(prefix)
            path = names{index};
        else
            path = [prefix '.' names{index}];
        end
        paths = [paths, overlayLeafPaths_(overlay.(names{index}), path)]; %#ok<AGROW>
    end
end

% ============================================================================
% Grouping
% ============================================================================

function groups = groupOrder_()
%GROUPORDER_ The accordion headers, in the order the editor shows them.
%   Ordered the way someone builds a scenario: what is being simulated, then what corrupts
%   the measurement, then what the filter does about it, then bookkeeping.
    groups = { ...
        struct('id', 'scenario',    'title', 'Scenario and geometry', ...
               'blurb', 'What is being simulated: orbit class, tower count, spacecraft count, antennas.'), ...
        struct('id', 'errors',      'title', 'Error sources', ...
               'blurb', 'The truth-side corruptions: troposphere, ionosphere, multipath, hardware delay, survey, antenna phase centres, biases.'), ...
        struct('id', 'atmosphere',  'title', 'Atmosphere', ...
               'blurb', 'Which atmosphere profile runs, and how the ionosphere is removed.'), ...
        struct('id', 'clocks',      'title', 'Clocks and oscillators', ...
               'blurb', 'Space and ground oscillator classes, the broadcast tower-clock product, and how its age enters R.'), ...
        struct('id', 'measurements','title', 'Signals and measurements', ...
               'blurb', 'Carrier and code observables, frequency plan, noise models, two-way time transfer, slip detection.'), ...
        struct('id', 'estimator',   'title', 'Estimator', ...
               'blurb', 'Filter states, dynamics, ambiguity resolution, attitude, covariance and process noise.'), ...
        struct('id', 'multiasset',  'title', 'Multi-asset and ISL', ...
               'blurb', 'Formation size, crosslinks, federated or joint mode, relative-layer geometry.'), ...
        struct('id', 'physics',     'title', 'Physics and frames', ...
               'blurb', 'Relativity, Sagnac, light time, Doppler, Earth orientation, force models.'), ...
        struct('id', 'realism',     'title', 'Realism grade', ...
               'blurb', 'The single opt-in switch and what it includes.'), ...
        struct('id', 'run',         'title', 'Run and output', ...
               'blurb', 'Reporting, diagnostics, plots, validation gates and Monte-Carlo settings.') ...
        };
end

function group = groupForPath_(path)
%GROUPFORPATH_ The accordion header a leaf belongs under.
%   Keyed on the top-level block so every one of the ~1362 leaves lands somewhere. A leaf
%   with no mapping falls to 'run', which is where the bookkeeping blocks live.
    root = strtok(path, '.');
    switch root
        case {'scenario', 'towers', 'asset', 'assets', 'formation', 'orbit'}
            group = 'scenario';
        case {'errors', 'effects', 'biases'}
            group = 'errors';
        case {'atmosphere', 'ionosphere', 'environment'}
            group = 'atmosphere';
        case {'clock', 'clocks', 'towerClock', 'clockScaling'}
            group = 'clocks';
        case {'measurements', 'measurement', 'signals', 'carrierSlip', 'hardware'}
            group = 'measurements';
        case {'estimator', 'estimation', 'covariance'}
            group = 'estimator';
        case {'multiAsset', 'beamforming'}
            group = 'multiasset';
        case {'physics', 'frames', 'perturbations', 'constants'}
            group = 'physics';
        case 'realism'
            group = 'realism';
        otherwise
            group = 'run';
    end
end

function subgroup = subgroupForPath_(path)
%SUBGROUPFORPATH_ The cluster label inside a group: the first two path components.
%   errors.multipath.coloredGM.tau_s clusters under 'errors.multipath', which is the level
%   a reader thinks at ("the multipath settings") without being so fine that every leaf
%   becomes its own heading.
    parts = strsplit(path, '.');
    if numel(parts) <= 1
        subgroup = parts{1};
    else
        subgroup = [parts{1} '.' parts{2}];
    end
end

function paths = masterEnablePaths_()
%MASTERENABLEPATHS_ The effects whose single .enable drives an internal truth/model pair.
%   Kept identical to the list masterConfig.m:302 hands expandEnableToggles and
%   ConfigFactory.m:594 hands resolveEnablePairsPostMerge. For these twelve, and only
%   these, a scenario writes the MASTER alone: resolveEnablePairsPostMerge expands it from
%   per-level provenance. Writing a pair member instead makes the file own that member and
%   suppresses the expansion, which is how six shipped feat rungs once disabled nothing.
    paths = { ...
        'physics.sagnac', 'physics.lightTime', 'physics.relativity.shapiro', ...
        'physics.relativity.clock', 'physics.doppler', ...
        'errors.troposphere', 'errors.ionosphere', 'errors.hardwareDelay', 'errors.multipath', ...
        'effects.towerSurvey', 'effects.antennaPCO', 'effects.antennaPCV'};
end

function value = mapGet_(map, key, fallback)
    if isKey(map, key)
        value = map(key);
    else
        value = fallback;
    end
end
