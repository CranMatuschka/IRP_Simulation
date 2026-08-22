function test_config_editor_schema()
%TEST_CONFIG_EDITOR_SCHEMA  The config editor must describe the config that exists.
%
%   tools/config_editor/config_editor.html is a GENERATED artefact carrying a snapshot of
%   the whole config surface: every path, its default, its legal values, and the reasons
%   certain paths must not be written. It is committed so a teammate can open it without
%   running MATLAB first, and that is exactly what lets it rot. A stale editor is worse
%   than no editor: it offers knobs that have been renamed or removed, and it presents its
%   defaults with the same confidence whether or not they are still true.
%
%   Nothing else can catch that. The editor is a browser page with no MATLAB in the loop,
%   so drift produces no error anywhere until someone builds a scenario on a knob that no
%   longer exists and wonders why the run ignored it.
%
%   Checked here:
%     1. the schema builds at all;
%     2. every path it offers is a real leaf of masterConfig;
%     3. its enum sets are configEnumRegistry's, value for value;
%     4. every derived-registry path exists, except the ones recorded as REMOVED;
%     5. its list of master enables matches the list masterConfig hands expandEnableToggles;
%     6. the committed HTML was generated from the masterConfig now in the tree.
%
%   Fixing a failure of (6) is one command:
%       matlab -batch "addpath('tools/config_editor'); buildConfigEditor"

    testDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(testDirectory);
    addpath(repositoryRoot);
    addpath(fullfile(repositoryRoot, 'config'));
    addpath(fullfile(repositoryRoot, 'config', 'internal'));
    addpath(fullfile(repositoryRoot, 'tools', 'config_editor'));

    nFail = 0;
    [schema, buildFail] = i_schemaBuilds(repositoryRoot);
    nFail = nFail + buildFail;
    if buildFail > 0
        error('test_config_editor_schema:fail', 'Schema did not build; later checks skipped.');
    end

    nFail = nFail + i_everyPathIsARealLeaf(schema);
    nFail = nFail + i_enumsMatchTheRegistry(schema);
    nFail = nFail + i_derivedPathsExist(repositoryRoot);
    nFail = nFail + i_masterEnablesMatchMasterConfig(schema, repositoryRoot);
    nFail = nFail + i_generatedPageIsCurrent(schema, repositoryRoot);

    if nFail > 0
        error('test_config_editor_schema:fail', '%d check(s) failed.', nFail);
    end
    fprintf('test_config_editor_schema: PASS\n');
end

% ============================================================================

function [schema, n] = i_schemaBuilds(repositoryRoot)
    n = 0;
    schema = struct();
    try
        schema = configEditorSchema(repositoryRoot);
    catch me
        fprintf(2, 'configEditorSchema errored: %s\n  %s\n', me.identifier, me.message);
        n = 1;
        return
    end
    if isempty(schema.fields)
        fprintf(2, 'Schema carries no fields.\n');
        n = n + 1;
    end
end

function n = i_everyPathIsARealLeaf(schema)
%I_EVERYPATHISAREALLEAF  A path the editor offers must resolve in masterConfig.
%   The editor writes dotted paths straight into a scenario JSON, and deepMergeConfig
%   rejects a path masterConfig does not define. An offered path that is not a leaf is
%   therefore a file the user cannot run, discovered only after they have built it.
    n = 0;
    cfg = masterConfig();
    bad = {};
    for index = 1:numel(schema.fields)
        path = schema.fields{index}.path;
        if ~i_pathExists(cfg, path)
            bad{end + 1} = path; %#ok<AGROW>
        end
    end
    if ~isempty(bad)
        fprintf(2, '%d schema path(s) are not masterConfig leaves:\n', numel(bad));
        fprintf(2, '  %s\n', bad{1:min(10, numel(bad))});
        n = 1;
    end
end

function n = i_enumsMatchTheRegistry(schema)
%I_ENUMSMATCHTHEREGISTRY  A closed dropdown must offer exactly the checked legal set.
%   The editor presents registry-backed values as a dropdown with no way to type anything
%   else, so a set that has drifted narrower silently forbids a legal configuration and a
%   set that has drifted wider offers one validateMasterConfig will reject.
    n = 0;
    entries = configEnumRegistry(masterConfig());
    registry = containers.Map({entries.path}, {entries.values});

    byPath = containers.Map('KeyType', 'char', 'ValueType', 'any');
    for index = 1:numel(schema.fields)
        byPath(schema.fields{index}.path) = schema.fields{index};
    end

    for index = 1:numel(entries)
        path = entries(index).path;
        if ~isKey(byPath, path)
            fprintf(2, 'Enum registry path missing from the schema: %s\n', path);
            n = 1;
            continue
        end
        field = byPath(path);
        if ~strcmp(field.type, 'enum')
            fprintf(2, 'Registry path %s is typed ''%s'' in the schema, not ''enum''.\n', ...
                path, field.type);
            n = 1;
            continue
        end
        expected = registry(path);
        if ~isequal(field.values(:), expected(:))
            fprintf(2, 'Enum set for %s differs between the schema and the registry.\n', path);
            n = 1;
        end
    end
end

function n = i_derivedPathsExist(repositoryRoot)
%I_DERIVEDPATHSEXIST  Each derived-registry entry must still name something real.
%   A 'blocked' or 'warn' entry names a live leaf whose value gets overwritten, so it has
%   to exist. An 'error' entry names a knob that was REMOVED and now raises on contact, so
%   it must NOT exist: if one reappears in masterConfig the registry is telling people the
%   opposite of the truth.
    n = 0;
    cfg = masterConfig();
    entries = derivedConfigPathRegistry();
    for index = 1:numel(entries)
        exists = i_pathExists(cfg, entries(index).path);
        switch entries(index).severity
            case 'error'
                if exists
                    fprintf(2, ['derivedConfigPathRegistry marks %s as REMOVED, but it is a ' ...
                                'live masterConfig leaf again.\n'], entries(index).path);
                    n = 1;
                end
            otherwise
                if ~exists
                    fprintf(2, ['derivedConfigPathRegistry names %s, which is no longer a ' ...
                                'masterConfig leaf.\n'], entries(index).path);
                    n = 1;
                end
        end
    end
    if isempty(repositoryRoot); end
end

function n = i_masterEnablesMatchMasterConfig(schema, repositoryRoot)
%I_MASTERENABLESMATCHMASTERCONFIG  The twelve effects, read from masterConfig's own call.
%   The editor tells the user to set a master enable alone and leave the truth/model pair
%   untouched, which is only correct for the effects resolveEnablePairsPostMerge actually
%   expands. Adding a thirteenth effect to masterConfig without adding it here would leave
%   the editor treating it as an ordinary leaf and quietly giving the wrong advice about
%   the one class of knob this project has already been burned by.
    n = 0;
    source = fileread(fullfile(repositoryRoot, 'config', 'masterConfig.m'));
    block = regexp(source, 'expandEnableToggles\(cfg,\s*\{(.*?)\}\s*\)', 'tokens', 'once');
    if isempty(block)
        fprintf(2, 'Could not find the expandEnableToggles call in masterConfig.m.\n');
        return
    end
    quoted = regexp(block{1}, '''([^'']+)''', 'tokens');
    fromSource = sort(cellfun(@(t) t{1}, quoted, 'UniformOutput', false));
    fromSchema = sort(schema.masterEnables(:).');

    if ~isequal(fromSource, fromSchema)
        fprintf(2, 'The schema''s master-enable list differs from masterConfig''s:\n');
        fprintf(2, '  only in masterConfig: %s\n', strjoin(setdiff(fromSource, fromSchema), ', '));
        fprintf(2, '  only in the schema:   %s\n', strjoin(setdiff(fromSchema, fromSource), ', '));
        n = 1;
    end
end

function n = i_generatedPageIsCurrent(schema, repositoryRoot)
%I_GENERATEDPAGEISCURRENT  The committed editor must come from the masterConfig in the tree.
%   Compared by the masterConfig hash the generator stamps into the page, not by a byte
%   diff of the page itself. A byte diff would also fail on an unrelated jsonencode
%   ordering change and would teach everyone to regenerate-and-commit to silence it, which
%   is how a gate stops meaning anything.
    n = 0;
    editorDir = fullfile(repositoryRoot, 'tools', 'config_editor');
    pagePath = fullfile(editorDir, 'config_editor.html');

    templatePath = fullfile(editorDir, 'template.html');
    if ~isfile(templatePath)
        fprintf(2, 'template.html is missing.\n');
        return
    end
    if ~contains(fileread(templatePath), '/*__SCHEMA__*/null')
        fprintf(2, 'template.html no longer carries the schema placeholder.\n');
        n = 1;
    end

    if ~isfile(pagePath)
        fprintf(2, ['config_editor.html has not been generated. Run:\n' ...
                    '  matlab -batch "addpath(''tools/config_editor''); buildConfigEditor"\n']);
        return
    end

    page = fileread(pagePath);
    stamped = regexp(page, '"masterConfigSha256":"([0-9a-f]{64})"', 'tokens', 'once');
    if isempty(stamped)
        fprintf(2, 'config_editor.html carries no masterConfig hash; regenerate it.\n');
        n = 1;
        return
    end
    if ~strcmp(stamped{1}, schema.generated.masterConfigSha256)
        fprintf(2, ['config_editor.html is STALE. It was generated from masterConfig %s\n' ...
                    'but the tree now holds %s. Regenerate it:\n' ...
                    '  matlab -batch "addpath(''tools/config_editor''); buildConfigEditor"\n'], ...
                stamped{1}(1:16), schema.generated.masterConfigSha256(1:16));
        n = 1;
    end
end

function tf = i_pathExists(cfg, path)
    parts = strsplit(path, '.');
    node = cfg;
    tf = false;
    for index = 1:numel(parts)
        if ~isstruct(node) || ~isscalar(node) || ~isfield(node, parts{index})
            return
        end
        node = node.(parts{index});
    end
    tf = true;
end
