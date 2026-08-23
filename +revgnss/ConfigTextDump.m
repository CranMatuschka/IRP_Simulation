classdef ConfigTextDump
    %CONFIGTEXTDUMP  Flatten a config to sorted dotted-path text, and diff a literal
    %   (pre-finalizeConfig) config against a resolved (post-finalizeConfig) one.
    %
    %   Used by ReportRunner.writeRunLog_ to make the <stem>.out self-describing
    %   WITHOUT MATLAB: the literal masterConfig is NOT what runs. finalizeConfig
    %   overrides attitude, codeMode, the standalone Sagnac term, the relativistic
    %   clock, the atmosphere overlay, etc. (review v2 section 4.3). This surfaces
    %   that opacity as plain text.
    %
    %   Scalars, char/string, logicals and short numeric vectors are printed verbatim;
    %   large arrays / cells / objects / handles collapse to a class-and-size
    %   placeholder, so the diff is exact for the scalar toggles that matter and never
    %   errors on the deep, heterogeneous cfg.

    methods (Static)

        function lines = flatten(s)
            %FLATTEN  Cell column of 'a.b.c = <value>' lines, sorted by dotted path.
            kv = containers.Map('KeyType', 'char', 'ValueType', 'char');
            revgnss.ConfigTextDump.walk_('', s, kv);
            ks = sort(keys(kv));
            lines = cell(numel(ks), 1);
            for i = 1:numel(ks)
                lines{i} = sprintf('%s = %s', ks{i}, kv(ks{i}));
            end
        end

        function ov = diff(literal, resolved)
            %DIFF  What finalizeConfig changed/added. Returns a struct:
            %   .changed : Nx3 cell {path, literalStr, resolvedStr} present in both, differ
            %   .added   : Mx2 cell {path, resolvedStr} present only in resolved
            L = containers.Map('KeyType', 'char', 'ValueType', 'char');
            R = containers.Map('KeyType', 'char', 'ValueType', 'char');
            revgnss.ConfigTextDump.walk_('', literal,  L);
            revgnss.ConfigTextDump.walk_('', resolved, R);
            rk = sort(keys(R));
            changed = cell(0, 3);
            added   = cell(0, 2);
            for i = 1:numel(rk)
                p = rk{i};
                if isKey(L, p)
                    if ~strcmp(L(p), R(p))
                        changed(end+1, 1:3) = {p, L(p), R(p)}; %#ok<AGROW>
                    end
                else
                    added(end+1, 1:2) = {p, R(p)}; %#ok<AGROW>
                end
            end
            ov = struct('changed', {changed}, 'added', {added});
        end
    end

    methods (Static, Access = private)

        function walk_(prefix, v, kv)
            %WALK_  Recurse structs / struct-arrays; every leaf -> kv(path)=valstr_.
            if isstruct(v)
                if numel(v) == 1
                    fn = fieldnames(v);
                    for i = 1:numel(fn)
                        if isempty(prefix); child = fn{i}; else; child = [prefix '.' fn{i}]; end
                        revgnss.ConfigTextDump.walk_(child, v.(fn{i}), kv);
                    end
                elseif isempty(v)
                    kv(prefix) = sprintf('<struct %s>', mat2str(size(v)));
                else
                    for j = 1:numel(v)
                        revgnss.ConfigTextDump.walk_(sprintf('%s(%d)', prefix, j), v(j), kv);
                    end
                end
            else
                kv(prefix) = revgnss.ConfigTextDump.valstr_(v);
            end
        end

        function s = valstr_(v)
            %VALSTR_  Deterministic, bounded text for one leaf value.
            try
                if ischar(v)
                    s = ['''' v ''''];
                elseif isstring(v)
                    if isscalar(v); s = ['"' char(v) '"'];
                    else; s = sprintf('<string %s>', mat2str(size(v))); end
                elseif islogical(v)
                    if isscalar(v)
                        if v; s = 'true'; else; s = 'false'; end
                    elseif numel(v) <= 16
                        s = ['[' strtrim(sprintf('%d ', v(:).')) ']'];
                    else
                        s = sprintf('<logical %s>', mat2str(size(v)));
                    end
                elseif isnumeric(v)
                    if isempty(v)
                        s = '[]';
                    elseif isscalar(v)
                        s = num2str(v, '%.10g');
                    elseif numel(v) <= 12
                        s = ['[' strtrim(regexprep(num2str(v(:).', '%.6g '), '\s+', ' ')) ']'];
                    else
                        s = sprintf('<%s %s>', class(v), mat2str(size(v)));
                    end
                elseif iscell(v)
                    s = sprintf('<cell %s>', mat2str(size(v)));
                elseif isa(v, 'function_handle')
                    s = func2str(v);
                    if ~startsWith(s, '@'); s = ['@' s]; end
                else
                    s = sprintf('<%s %s>', class(v), mat2str(size(v)));
                end
            catch
                s = sprintf('<%s unprintable>', class(v));
            end
        end
    end
end
