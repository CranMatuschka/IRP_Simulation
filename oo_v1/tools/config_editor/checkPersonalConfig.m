function report = checkPersonalConfig(configPath, duration_s)
%CHECKPERSONALCONFIG  Resolve one scenario file and say what it actually does.
%   checkPersonalConfig('myRun.json')          check it at the default 3600 s arc
%   checkPersonalConfig('myRun.json', 7200)    check it at the arc you will run
%   report = checkPersonalConfig(...)          the same findings as a struct
%
%   Run this before run_oo_v1 on anything the config editor wrote. It answers the three
%   questions the editor cannot, because they need the real resolver:
%
%     1. Does the file resolve at all? validateMasterConfig rejects an unknown path and,
%        since 2026-08-09, an illegal mode string. Both are reported verbatim.
%     2. Did every leaf you set SURVIVE resolution? This is the one that matters. A knob
%        that is derived elsewhere, or that a profile overwrites after the merge, accepts
%        your value at merge time and discards it before the run. Nothing errors. The run
%        completes, and the report prints the setting as active.
%     3. Did you write anything the derived-path registry warns about, or half of a
%        truth/model pair whose master would otherwise have driven it?
%
%   HOW (2) IS DECIDED. resolveSimulationConfig returns the pre-finalisation config and
%   the list of leaves the file explicitly wrote, so comparing the two sides at exactly
%   those leaves shows what the resolution changed underneath you. That comparison is not
%   invented here: it is the check tests/test_scenario_override_invariance already runs
%   across the whole shipped ladder, applied to one file and printed for a person rather
%   than asserted. scenarioResolutionExceptionRegistry's known-benign normalisations are
%   honoured the same way, so a column-to-row mask reshape is not reported as a loss.
%
%   Exit behaviour: this function PRINTS and returns findings. It does not throw on a dead
%   leaf, because a dead leaf is sometimes what you meant. It does rethrow a genuine
%   resolution failure, because there is nothing to inspect after one.
%
%   See also BUILDCONFIGEDITOR, RESOLVESIMULATIONCONFIG, DERIVEDCONFIGPATHREGISTRY.

    thisDir = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(fileparts(thisDir));
    addpath(repositoryRoot);
    addpath(fullfile(repositoryRoot, 'config'));
    addpath(fullfile(repositoryRoot, 'config', 'internal'));

    if nargin < 2 || isempty(duration_s); duration_s = 3600; end

    fprintf('\n=== checkPersonalConfig: %s ===\n', char(configPath));

    % The arc length is injected the way run_oo_v1 injects it, so the file is checked in
    % the state it will actually run in rather than in a state nothing produces.
    runOverrides = struct('simulation', struct('duration_s', double(duration_s)));

    report = struct('path', char(configPath), 'resolved', false, ...
        'dead', {{}}, 'derived', {{}}, 'pairMembers', {{}}, 'explicitCount', 0);

    warningState = warning('query', 'ConfigFactory:rxCarrierBiasAbsorbed');
    warning('off', 'ConfigFactory:rxCarrierBiasAbsorbed');
    cleanup = onCleanup(@() warning(warningState.state, 'ConfigFactory:rxCarrierBiasAbsorbed'));

    try
        [resolvedConfig, metadata] = resolveSimulationConfig(configPath, runOverrides);
    catch resolutionError
        fprintf(2, '\nDOES NOT RESOLVE.\n\n  %s\n  %s\n\n', ...
            resolutionError.identifier, resolutionError.message);
        fprintf(['This is a hard stop: the file cannot run in this state. An unknown path ' ...
                 'usually\nmeans a typo or a key that has been renamed; an unknownModeValue ' ...
                 'means a mode\nstring that no dispatch site recognises.\n\n']);
        rethrow(resolutionError);
    end

    report.resolved = true;

    % EVERY FINDING BELOW IS SCOPED TO THE LEAVES THIS FILE ITSELF WROTE.
    % metadata.explicitPaths is the whole flattened "_extends" chain, so using it would
    % report the base's decisions as though they were the user's: checking a one-line
    % delta over golden_baseline listed five of the golden's deliberate asymmetric pairs
    % as suspicious. Nobody reads a warning list where most entries are about a file they
    % did not touch. explicitByLevel is base-first with one entry per file in the chain,
    % plus a trailing entry for the caller overrides when there are any, so the requested
    % file sits at numel(extendsChain) rather than at the end. The per-level record is
    % carried on the config as provenance.explicitByLevel, not on metadata directly.
    ownPaths = metadata.explicitPaths;
    byLevel = {};
    try; byLevel = metadata.preResolutionConfig.provenance.explicitByLevel; catch; end
    if iscell(byLevel) && numel(byLevel) >= numel(metadata.extendsChain)
        ownPaths = byLevel{numel(metadata.extendsChain)};
    end
    report.explicitCount = numel(ownPaths);

    fprintf('Resolves.  source %s\n', metadata.sourcePath);
    if numel(metadata.extendsChain) > 1
        fprintf('Built on:  %s\n', strjoin(metadata.extendsChain, ' -> '));
    end
    fprintf('Profile:   %s\n', metadata.profile);
    fprintf('Arc:       %g s (checked as run_oo_v1 would inject it)\n', duration_s);
    fprintf('Wrote:     %d leaves of its own (%d in the whole chain)\n', ...
        numel(ownPaths), numel(metadata.explicitPaths));

    % ---- (2) which written leaves did not survive --------------------------------
    [~, fileName, fileExtension] = fileparts(metadata.sourcePath);
    leafName = [fileName fileExtension];
    exceptions = scenarioResolutionExceptionRegistry();
    allowed = strcmp({exceptions.scenarioFile}, leafName);
    allowedPaths = {exceptions(allowed).path};

    for index = 1:numel(ownPaths)
        path = ownPaths{index};
        [beforeFound, beforeValue] = valueAtPath_(metadata.preResolutionConfig, path);
        [afterFound, afterValue]   = valueAtPath_(resolvedConfig, path);
        if beforeFound && afterFound && isequaln(beforeValue, afterValue)
            continue
        end
        if any(strcmp(path, allowedPaths))
            continue
        end
        report.dead{end + 1} = struct( ...
            'path',   path, ...
            'wanted', describe_(beforeFound, beforeValue), ...
            'got',    describe_(afterFound, afterValue)); %#ok<AGROW>
    end

    % ---- (3) registry warnings and pair members ----------------------------------
    derivedEntries = derivedConfigPathRegistry();
    for index = 1:numel(ownPaths)
        path = ownPaths{index};
        hit = find(strcmp({derivedEntries.path}, path), 1);
        if ~isempty(hit)
            report.derived{end + 1} = derivedEntries(hit); %#ok<AGROW>
        end
        master = pairMemberMaster_(path);
        if ~isempty(master)
            report.pairMembers{end + 1} = struct('path', path, 'master', master); %#ok<AGROW>
        end
    end

    printFindings_(report);
    clear cleanup
    if nargout == 0; clear report; end
end

% ============================================================================

function printFindings_(report)
    if isempty(report.dead)
        fprintf('\nEvery leaf this file writes survived resolution.\n');
    else
        fprintf(2, '\n%d LEAF(ES) DID NOT SURVIVE RESOLUTION:\n', numel(report.dead));
        for index = 1:numel(report.dead)
            item = report.dead{index};
            fprintf(2, '  %s\n      asked for : %s\n      resolved to: %s\n', ...
                item.path, item.wanted, item.got);
        end
        fprintf(2, ['\nThese settings are dead. The run will complete and the report will ' ...
                    'describe the\nRESOLVED value, so nothing downstream will tell you ' ...
                    'again. Either the knob is\nderived from another one, or a profile ' ...
                    'rewrote it after the merge.\n']);
    end

    if ~isempty(report.derived)
        fprintf(2, '\n%d PATH(S) THE DERIVED REGISTRY WARNS ABOUT:\n', numel(report.derived));
        for index = 1:numel(report.derived)
            entry = report.derived{index};
            fprintf(2, '  [%s] %s\n      %s\n', entry.severity, entry.path, entry.note);
            if ~isempty(entry.instead)
                fprintf(2, '      Set %s instead.\n', entry.instead);
            end
        end
    end

    if ~isempty(report.pairMembers)
        fprintf('\n%d TRUTH/MODEL PAIR MEMBER(S) WRITTEN DIRECTLY:\n', numel(report.pairMembers));
        for index = 1:numel(report.pairMembers)
            item = report.pairMembers{index};
            fprintf(['  %s\n      This file now OWNS that member, so %s.enable no longer ' ...
                     'drives it.\n      Correct if you want an asymmetric pair, a silent ' ...
                     'no-op if you meant\n      to toggle the whole effect.\n'], ...
                    item.path, item.master);
        end
    end

    if isempty(report.dead) && isempty(report.derived) && isempty(report.pairMembers)
        fprintf('No warnings. Ready to run.\n\n');
    else
        fprintf('\n');
    end
end

function master = pairMemberMaster_(path)
%PAIRMEMBERMASTER_ The master enable a written pair member belongs to, if it is one.
%   Kept in step with the twelve effects masterConfig.m:302 hands expandEnableToggles.
    master = '';
    token = regexp(path, '^(.*)\.(truth|model)\.enable$', 'tokens', 'once');
    if isempty(token); return; end
    effects = { ...
        'physics.sagnac', 'physics.lightTime', 'physics.relativity.shapiro', ...
        'physics.relativity.clock', 'physics.doppler', ...
        'errors.troposphere', 'errors.ionosphere', 'errors.hardwareDelay', 'errors.multipath', ...
        'effects.towerSurvey', 'effects.antennaPCO', 'effects.antennaPCV'};
    if any(strcmp(token{1}, effects)); master = token{1}; end
end

function [found, value] = valueAtPath_(root, path)
%VALUEATPATH_ Fetch a dotted path, reporting absence rather than throwing.
%   Same accessor tests/test_scenario_override_invariance uses for this comparison.
    parts = strsplit(path, '.');
    value = [];
    found = false;
    node = root;
    for index = 1:numel(parts)
        if ~isstruct(node) || ~isscalar(node) || ~isfield(node, parts{index})
            return
        end
        node = node.(parts{index});
    end
    value = node;
    found = true;
end

function text = describe_(found, value)
    if ~found; text = '(absent)'; return; end
    try
        text = strtrim(formattedDisplayText(value));
        text = regexprep(text, '\s+', ' ');
        if numel(text) > 90; text = [text(1:90) ' ...']; end
    catch
        text = sprintf('<%s>', class(value));
    end
end
