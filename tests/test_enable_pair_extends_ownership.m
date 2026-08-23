function test_enable_pair_extends_ownership()
%TEST_ENABLE_PAIR_EXTENDS_OWNERSHIP  A master .enable must beat an INHERITED pair.
%
%   Regression for the defect that made six shipped ablation rungs disable nothing:
%   resolveSimulationConfig flattens the whole "_extends" chain into ONE overlay before
%   deepMergeConfig walks it, so a truth/model pair inherited from golden_baseline.json
%   landed in cfg.provenance.explicit exactly like one the child declared. The old flat
%   ownership test in resolveEnablePairsPostMerge then read that as "the scenario owns
%   the pair, leave it alone" and skipped the propagation, so
%   feat001_noTroposphere resolved to enable=0 with truth.enable=1 and ran the full
%   troposphere. Measured 2026-08-08 on all of feat001/002/006/007/009/014.
%
%   The fix compares SPECIFICITY via cfg.provenance.explicitByLevel (base-first):
%   a pair member declared at a level >= the master's level wins; a master declared at a
%   strictly later level expands into the pair. Same-level ties keep the pair, which is
%   what keeps golden_baseline.json's asymmetric multipath pair {truth:1, model:0} intact.

    thisDir = fileparts(mfilename('fullpath'));
    oo_v1Root = fileparts(thisDir);
    addpath(oo_v1Root);
    addpath(fullfile(oo_v1Root, 'config'));
    addpath(fullfile(oo_v1Root, 'config', 'internal'));

    nFail = 0;
    nFail = nFail + i_unitSameLevelKeepsPair();
    nFail = nFail + i_unitLaterMasterExpands();
    nFail = nFail + i_unitLegacyFallback();
    nFail = nFail + i_integrationChildMasterOnly(oo_v1Root);
    nFail = nFail + i_integrationShippedRungsAblate();

    if nFail > 0
        error('test_enable_pair_extends_ownership:fail', '%d check(s) failed.', nFail);
    end
    fprintf('test_enable_pair_extends_ownership: PASS\n');
end

% ---------------------------------------------------------------- unit tests

function n = i_unitSameLevelKeepsPair()
%   One file writes master=true AND an asymmetric pair. The pair must survive: this is
%   exactly golden_baseline.json's errors.multipath, and forcing the master through it
%   would flip model.enable false -> true and move every golden.
    cfg = i_effectCfg(true, true, false);
    cfg.provenance.explicit = { ...
        'errors.multipath.enable', ...
        'errors.multipath.truth.enable', ...
        'errors.multipath.model.enable'};
    cfg.provenance.explicitByLevel = {cfg.provenance.explicit};

    out = resolveEnablePairsPostMerge(cfg, {'errors.multipath'});
    n = i_check(out.errors.multipath.truth.enable == true && ...
                out.errors.multipath.model.enable == false, ...
        'same-level pair must survive the master (golden_baseline multipath shape)');
end

function n = i_unitLaterMasterExpands()
%   The parent declares the pair, the CHILD writes only the master. The child is newer
%   intent and must win. This is the shape that was broken.
    cfg = struct();
    cfg.errors.troposphere.enable       = false;   % child's intent
    cfg.errors.troposphere.truth.enable = true;    % inherited from the parent
    cfg.errors.troposphere.model.enable = true;    % inherited from the parent
    cfg.provenance.explicit = { ...
        'errors.troposphere.truth.enable', ...
        'errors.troposphere.model.enable', ...
        'errors.troposphere.enable'};
    cfg.provenance.explicitByLevel = { ...
        {'errors.troposphere.truth.enable', 'errors.troposphere.model.enable'}, ...  % parent
        {'errors.troposphere.enable'}};                                              % child

    out = resolveEnablePairsPostMerge(cfg, {'errors.troposphere'});
    n = i_check(out.errors.troposphere.truth.enable == false && ...
                out.errors.troposphere.model.enable == false, ...
        'a child writing only the master must drive an INHERITED pair');
end

function n = i_unitLegacyFallback()
%   A caller that sets cfg.provenance.explicit by hand and no explicitByLevel keeps the
%   historical behaviour exactly -- the flat ownership test.
    cfg = i_effectCfg(false, true, true);
    cfg.provenance.explicit = { ...
        'errors.multipath.enable', 'errors.multipath.truth.enable'};
    % no explicitByLevel on purpose
    out = resolveEnablePairsPostMerge(cfg, {'errors.multipath'});
    n = i_check(out.errors.multipath.truth.enable == true && ...
                out.errors.multipath.model.enable == false, ...
        'legacy flat provenance must behave exactly as before');
end

% -------------------------------------------------------------- integration

function n = i_integrationChildMasterOnly(oo_v1Root)
%   End to end through resolveSimulationConfig with a real two-file _extends chain, using
%   a scenario that writes ONLY the master. Proves the fix on the real code path rather
%   than on a hand-built provenance struct.
    tmpName = 'zz_tmp_enablePairOwnershipProbe.json';
    tmpPath = fullfile(oo_v1Root, 'config', 'ladder', 'test', tmpName);
    payload = { ...
        '{', ...
        '  "_id": "TEMPORARY probe written by test_enable_pair_extends_ownership; deleted on cleanup.",', ...
        '  "_extends": "golden_baseline.json",', ...
        '  "scenario": { "name": "zz_tmp_enablePairOwnershipProbe" },', ...
        '  "errors": { "troposphere": { "enable": false } }', ...
        '}'};
    fid = fopen(tmpPath, 'w');
    assert(fid >= 0, 'cannot write probe scenario %s', tmpPath);
    fprintf(fid, '%s\n', payload{:});
    fclose(fid);
    cleanup = onCleanup(@() i_deleteIfPresent(tmpPath)); %#ok<NASGU>

    cfg = resolveSimulationConfig(tmpName);
    tc  = cfg.errors.troposphere;
    n = i_check(tc.enable == false && tc.truth.enable == false && tc.model.enable == false, ...
        sprintf(['a child writing only errors.troposphere.enable must reach the pair ' ...
                 '(got master=%d truth=%d model=%d)'], ...
                 tc.enable, tc.truth.enable, tc.model.enable));
end

function n = i_integrationShippedRungsAblate()
%   The six rungs that were measured broken must now resolve to a fully-off triple.
    cases = { ...
        'feat001_noTroposphere.json',   'errors.troposphere'; ...
        'feat002_noIonosphere.json',    'errors.ionosphere'; ...
        'feat006_noMultipath.json',     'errors.multipath'; ...
        'feat007_noHardwareDelay.json', 'errors.hardwareDelay'; ...
        'feat009_noTowerSurvey.json',   'effects.towerSurvey'; ...
        'feat014_noRelativity.json',    'physics.relativity.clock'};
    n = 0;
    for k = 1:size(cases, 1)
        cfg = resolveSimulationConfig(cases{k, 1});
        f   = strsplit(cases{k, 2}, '.');
        m = getfield(cfg, f{:}, 'enable');          %#ok<GFLD>
        t = getfield(cfg, f{:}, 'truth', 'enable'); %#ok<GFLD>
        d = getfield(cfg, f{:}, 'model', 'enable'); %#ok<GFLD>
        n = n + i_check(~m && ~t && ~d, sprintf('%s must ablate %s (got %d %d %d)', ...
            cases{k, 1}, cases{k, 2}, m, t, d));
    end
end

% ------------------------------------------------------------------ helpers

function cfg = i_effectCfg(master, truthOn, modelOn)
    cfg = struct();
    cfg.errors.multipath.enable       = master;
    cfg.errors.multipath.truth.enable = truthOn;
    cfg.errors.multipath.model.enable = modelOn;
end

function i_deleteIfPresent(p)
    if isfile(p); delete(p); end
end

function n = i_check(condition, message)
    n = double(~condition);
    if n > 0
        fprintf(2, '  FAIL: %s\n', message);
    end
end
