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
%   config/scenarios/realism.json works around it by hand-writing all three keys per effect.
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

    own = {};
    try; own = cfg.provenance.explicit; catch; end
    if isempty(own); return; end

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
        if ~ismember([base '.truth.enable'], own)
            cfg = setfield(cfg, f{:}, 'truth', 'enable', en); %#ok<SFLD>
        end
        if ~ismember([base '.model.enable'], own)
            cfg = setfield(cfg, f{:}, 'model', 'enable', en); %#ok<SFLD>
        end
    end
end
