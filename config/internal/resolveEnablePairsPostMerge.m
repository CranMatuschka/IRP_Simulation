function cfg = resolveEnablePairsPostMerge(cfg, effectPaths)
%RESOLVEENABLEPAIRSPOSTMERGE  Make a master `.enable` written by a SCENARIO actually work.
%   cfg = resolveEnablePairsPostMerge(cfg, {'errors.troposphere', ...})
%
%   THE PROBLEM THIS FIXES. expandEnableToggles slaves each effect's .truth.enable /
%   .model.enable to one master .enable, which is the right design -- but it is called from
%   config/masterConfig.m:163, i.e. BEFORE run_oo_v1 merges the scenario JSON. So a scenario
%   writing `errors.multipath.enable = true` was a SILENT NO-OP: measured, it resolved to
%   enable=1, truth=0, model=0. The physics and the report both read the PAIR, never the
%   master, so the config said on, the run did nothing, and the report honestly said off.
%   config/realism.json works around it by hand-writing all three keys per effect.
%
%   WHY NOT JUST RE-RUN expandEnableToggles POST-MERGE. It overwrites the pair
%   unconditionally from the master, so a scenario that deliberately writes the PAIR
%   (realism.json and every scene_*_inc do exactly that) would have its values forced back to
%   whatever the untouched master says. That would silently disable effects those scenarios
%   rely on.
%
%   WHAT THIS DOES INSTEAD. It expands only what the scenario actually asked for, using the
%   provenance record cfg.provenance.explicit written by run_oo_v1's i_deepMerge:
%     - scenario wrote the MASTER only        -> expand it into the pair
%     - scenario wrote a PAIR member          -> leave that member alone (user owns it)
%     - scenario wrote neither                -> leave everything as masterConfig resolved it
%
%   With no scenario JSON the provenance list is empty and this function is a no-op, so the
%   frozen goldens are byte-identical. See docs/plans/TOGGLE_TRUTH/02_toggle_audit_violations.md.
%
%   OWNERSHIP IS PER LEVEL, NOT PER RUN (fixed 2026-08-09). The flat cfg.provenance.explicit
%   list cannot answer the question this function asks. resolveSimulationConfig flattens the
%   whole "_extends" chain into ONE overlay before deepMergeConfig walks it, so a pair member
%   INHERITED from golden_baseline.json is recorded exactly like one the child declared. The
%   old flat test therefore read "the parent owns .truth.enable" and skipped the write, which
%   made a child writing only the master a SILENT NO-OP: measured, feat001/002/006/007/009/014
%   all resolved to master=0 with truth=1 and ran the effect at full strength.
%
%   The rule now compares SPECIFICITY. cfg.provenance.explicitByLevel is base-first, so a
%   higher index is a more specific file (index numel(...) is the requested JSON, or the
%   caller overrides when present):
%     pair member declared at a level >= the master's level -> that file meant the pair, leave it
%     master declared at a strictly LATER level             -> the master is the newer intent, expand it
%   Same-level ties keep the pair, which is what makes this golden-safe: golden_baseline.json
%   is a single level and writes errors.multipath {enable:true, truth:true, model:false}, and
%   that asymmetric pair must survive untouched.

    own = {};
    try; own = cfg.provenance.explicit; catch; end
    if isempty(own); return; end

    byLevel = {};
    try; byLevel = cfg.provenance.explicitByLevel; catch; end
    if ~iscell(byLevel); byLevel = {}; end

    for i = 1:numel(effectPaths)
        base = effectPaths{i};
        if ~ismember([base '.enable'], own)
            continue    % scenario did not touch the master -> nothing to propagate
        end
        f  = strsplit(base, '.');
        try
            en = getfield(cfg, f{:}, 'enable'); %#ok<GFLD>
        catch
            continue
        end
        masterLevel = lastLevel_(byLevel, [base '.enable']);
        if ~pairMemberWins_(byLevel, own, [base '.truth.enable'], masterLevel)
            cfg = setfield(cfg, f{:}, 'truth', 'enable', en); %#ok<SFLD>
        end
        if ~pairMemberWins_(byLevel, own, [base '.model.enable'], masterLevel)
            cfg = setfield(cfg, f{:}, 'model', 'enable', en); %#ok<SFLD>
        end
    end
end

function tf = pairMemberWins_(byLevel, own, pairPath, masterLevel)
%PAIRMEMBERWINS_ True when the pair member should be left exactly as merged.
%   Without per-level provenance (a caller that set cfg.provenance.explicit by hand, or
%   an older cached config) fall back to the historical flat test, so nothing that used
%   to work changes behaviour.
    if isempty(byLevel)
        tf = ismember(pairPath, own);
        return
    end
    pairLevel = lastLevel_(byLevel, pairPath);
    tf = pairLevel > 0 && pairLevel >= masterLevel;
end

function level = lastLevel_(byLevel, path)
%LASTLEVEL_ Index of the MOST SPECIFIC level that declares PATH; 0 if none does.
    level = 0;
    for k = 1:numel(byLevel)
        if iscell(byLevel{k}) && ismember(path, byLevel{k})
            level = k;
        end
    end
end
