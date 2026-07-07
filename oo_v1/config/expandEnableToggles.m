function cfg = expandEnableToggles(cfg, effectPaths)
%EXPANDENABLETOGGLES  Slave the internal truth/model enable pair to one master enable.
%   Phase 2.1 (one toggle per feature). masterConfig sets a SINGLE cfg.<effect>.enable
%   per physical effect; this expands it into the cfg.<effect>.truth.enable /
%   cfg.<effect>.model.enable pair that ~150 pipeline read-sites still consume. Because
%   truth and model are driven from the SAME value, the config surface can no longer
%   manufacture an artificial truth!=model mismatch: the estimator differs from truth
%   structurally (estimated state, clock products, estimated atmosphere), not by config.
%
%   This is the numerically-safe strangler step: the resolved config is unchanged for
%   any effect that was already matched (truth==model). Migrating the read-sites to read
%   .enable directly, and removing the derived pair, is a later cleanup commit.
%
%   effectPaths is a cellstr of dotted config paths, e.g. {'errors.troposphere', ...}.
    for i = 1:numel(effectPaths)
        f  = strsplit(effectPaths{i}, '.');
        en  = getfield(cfg, f{:}, 'enable');
        cfg = setfield(cfg, f{:}, 'truth', 'enable', en);
        cfg = setfield(cfg, f{:}, 'model', 'enable', en);
    end
end
