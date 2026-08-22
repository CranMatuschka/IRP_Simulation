function outputPath = buildConfigEditor(repositoryRoot)
%BUILDCONFIGEDITOR  Generate the standalone scenario configuration editor.
%   buildConfigEditor()  writes tools/config_editor/config_editor.html, a single
%   self-contained page that builds a scenario delta and saves it into config/personal/.
%   Open it by double-clicking. It needs no server, no network and no MATLAB session.
%
%   RUN THIS AFTER CHANGING masterConfig. The editor carries a snapshot of the config
%   surface, so a masterConfig edit leaves it offering knobs that have moved or gone.
%   tests/test_config_editor_schema.m compares the snapshot's masterConfig hash against
%   the working tree and fails when the two have parted, so the staleness is caught rather
%   than discovered halfway through building a scenario.
%
%   WHY THE SCHEMA IS INLINED RATHER THAN FETCHED. A page opened over file:// cannot XHR a
%   sibling JSON: Chrome treats every file:// document as an opaque origin, so the natural
%   split of page-plus-data would produce an editor that works from a web server and shows
%   an empty list when double-clicked, which is the only way anyone is going to open it.
%
%   See also CONFIGEDITORSCHEMA, CHECKPERSONALCONFIG.

    thisDir = fileparts(mfilename('fullpath'));
    if nargin < 1 || isempty(repositoryRoot)
        repositoryRoot = fileparts(fileparts(thisDir));
    end
    addpath(repositoryRoot);
    addpath(fullfile(repositoryRoot, 'config'));
    addpath(fullfile(repositoryRoot, 'config', 'internal'));
    addpath(thisDir);

    PLACEHOLDER = '/*__SCHEMA__*/null';

    templatePath = fullfile(thisDir, 'template.html');
    outputPath   = fullfile(thisDir, 'config_editor.html');

    schema = configEditorSchema(repositoryRoot);
    encoded = jsonencode(schema);

    % </script> inside a JSON string literal would close the surrounding script element,
    % because the HTML parser looks for that byte sequence before the JavaScript parser
    % ever sees a string. No shipped value contains it today, and escaping the slash costs
    % nothing and keeps a future doc comment from silently breaking the page.
    encoded = strrep(encoded, '</', '<\/');

    template = fileread(templatePath);
    assert(contains(template, PLACEHOLDER), 'buildConfigEditor:placeholderMissing', ...
        'template.html no longer contains the schema placeholder %s.', PLACEHOLDER);
    page = strrep(template, PLACEHOLDER, encoded);

    fileIdentifier = fopen(outputPath, 'w', 'n', 'UTF-8');
    assert(fileIdentifier >= 0, 'buildConfigEditor:cannotWrite', ...
        'Cannot write %s', outputPath);
    cleanup = onCleanup(@() fclose(fileIdentifier));
    fwrite(fileIdentifier, unicode2native(page, 'UTF-8'), 'uint8');
    clear cleanup

    listing = dir(outputPath);
    fprintf('Config editor written: %s\n', outputPath);
    fprintf('  %d knobs, %d base scenarios, %.0f kB\n', ...
        schema.generated.leafCount, schema.generated.scenarioCount, listing.bytes / 1024);
    fprintf('  essentials %d | standard %d | everything %d\n', ...
        schema.counts.essentials, ...
        schema.counts.essentials + schema.counts.used, ...
        schema.generated.leafCount);
    fprintf('  masterConfig sha256 %s\n', schema.generated.masterConfigSha256(1:16));
    fprintf('Open it by double-clicking, then save your scenario into config/personal/.\n');
end
