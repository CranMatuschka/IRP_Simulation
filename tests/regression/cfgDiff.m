function d = cfgDiff(a, b, prefix)
%CFGDIFF  Recursive leaf-path differences between two configs (isequaln semantics).
%   d = cfgDiff(a, b) returns a cellstr of field paths where a and b differ.
%   Used to prove a config refactor produces a byte-identical resolved struct.
    if nargin < 3; prefix = 'cfg'; end
    d = {};
    if isstruct(a) && isstruct(b) && isscalar(a) && isscalar(b)
        fa = fieldnames(a); fb = fieldnames(b);
        for i = 1:numel(fa)
            f = fa{i}; p = [prefix '.' f];
            if ~isfield(b, f); d{end+1} = [p ' (only in A)']; continue; end %#ok<AGROW>
            d = [d, cfgDiff(a.(f), b.(f), p)]; %#ok<AGROW>
        end
        for i = 1:numel(fb)
            if ~isfield(a, fb{i}); d{end+1} = [prefix '.' fb{i} ' (only in B)']; end %#ok<AGROW>
        end
    elseif ~isequaln(a, b)
        d{end+1} = prefix; %#ok<AGROW>
    end
end
