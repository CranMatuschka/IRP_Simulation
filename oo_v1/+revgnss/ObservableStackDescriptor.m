classdef ObservableStackDescriptor
    % ObservableStackDescriptor  Container helpers for endpoint/link/row metadata.

    methods (Static)
        function stack = create(endpoints, links, rows)
            if nargin < 1; endpoints = struct([]); end
            if nargin < 2; links = struct([]); end
            if nargin < 3; rows = struct([]); end
            stack = struct('endpoints', endpoints, 'links', links, 'rows', rows);
            stack.rowsByType = revgnss.ObservableStackDescriptor.countByType(rows);
            stack.stateColumnsByType = revgnss.ObservableStackDescriptor.stateColumnsByType(rows);
            stack.nEndpoints = numel(endpoints);
            stack.nLinks = numel(links);
            stack.nRows = numel(rows);
        end

        function counts = countByType(rows)
            counts = struct('code',0,'doppler',0,'carrier',0,'diffCarrierAttitude',0);
            for k = 1:numel(rows)
                fn = matlab.lang.makeValidName(rows(k).observableType);
                if ~isfield(counts, fn); counts.(fn) = 0; end
                counts.(fn) = counts.(fn) + 1;
            end
        end

        function colsByType = stateColumnsByType(rows)
            colsByType = struct();
            for k = 1:numel(rows)
                fn = matlab.lang.makeValidName(rows(k).observableType);
                if ~isfield(colsByType, fn); colsByType.(fn) = []; end
                colsByType.(fn) = unique([colsByType.(fn), rows(k).stateColumns]);
            end
        end

        function compact = compact(stack)
            compact = struct();
            if isempty(stack)
                compact.nEndpoints = 0; compact.nLinks = 0; compact.nRows = 0;
                compact.rowsByType = revgnss.ObservableStackDescriptor.countByType(struct([]));
                compact.stateColumnsByType = struct();
                compact.endpointTypes = {};
                compact.rowSummary = struct([]);
                return
            end
            compact.nEndpoints = stack.nEndpoints;
            compact.nLinks = stack.nLinks;
            compact.nRows = stack.nRows;
            compact.rowsByType = stack.rowsByType;
            compact.stateColumnsByType = stack.stateColumnsByType;
            compact.endpointTypes = revgnss.ObservableStackDescriptor.endpointTypes_(stack.endpoints);
            compact.rowSummary = revgnss.ObservableStackDescriptor.rowSummary_(stack.rows);
        end
    end

    methods (Static, Access = private)
        function types = endpointTypes_(endpoints)
            types = {};
            for k = 1:numel(endpoints)
                types{end+1} = endpoints(k).type; %#ok<AGROW>
            end
            types = unique(types, 'stable');
        end

        function s = rowSummary_(rows)
            empty = struct('observableType','','count',0,'role','', ...
                'stateColumns',[],'provenance','');
            s = repmat(empty, 0, 1);
            types = {};
            for k = 1:numel(rows)
                types{end+1} = rows(k).observableType; %#ok<AGROW>
            end
            types = unique(types, 'stable');
            for ti = 1:numel(types)
                mask = strcmp({rows.observableType}, types{ti});
                idx = find(mask);
                roles = unique({rows(idx).role}, 'stable');
                prov = unique({rows(idx).provenance}, 'stable');
                s(end+1) = struct('observableType', types{ti}, ...
                    'count', numel(idx), ...
                    'role', strjoin(roles, ', '), ...
                    'stateColumns', unique([rows(idx).stateColumns]), ...
                    'provenance', strjoin(prov, '; ')); %#ok<AGROW>
            end
        end
    end
end
