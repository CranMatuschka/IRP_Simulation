classdef ObservableStackDescriptor
    % ObservableStackDescriptor  Container helpers for endpoint/link/row metadata.

    methods (Static)
        function stack = create(endpoints, links, rows)
            if nargin < 1; endpoints = struct([]); end
            if nargin < 2; links = struct([]); end
            if nargin < 3; rows = struct([]); end
            stack = struct('endpoints', endpoints, 'links', links, 'rows', rows);
            revgnss.ObservableStackDescriptor.validateLinks_(endpoints, links, rows);
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
                compact.endpointAssetNames = {};
                compact.endpointAssetIndices = [];
                compact.linksByAsset = struct([]);
                compact.rowSummary = struct([]);
                return
            end
            compact.nEndpoints = stack.nEndpoints;
            compact.nLinks = stack.nLinks;
            compact.nRows = stack.nRows;
            compact.rowsByType = stack.rowsByType;
            compact.stateColumnsByType = stack.stateColumnsByType;
            compact.endpointTypes = revgnss.ObservableStackDescriptor.endpointTypes_(stack.endpoints);
            [compact.endpointAssetNames, compact.endpointAssetIndices] = ...
                revgnss.ObservableStackDescriptor.endpointAssets_(stack.endpoints);
            compact.linksByAsset = revgnss.ObservableStackDescriptor.linksByAsset_(stack.links);
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

        function [names, indices] = endpointAssets_(endpoints)
            names = {};
            indices = [];
            for k = 1:numel(endpoints)
                if isfield(endpoints(k),'assetName') && ~isempty(endpoints(k).assetName)
                    names{end+1} = endpoints(k).assetName; %#ok<AGROW>
                    indices(end+1) = endpoints(k).assetIndex; %#ok<AGROW>
                end
            end
            [names, ia] = unique(names, 'stable');
            indices = indices(ia);
        end

        function s = linksByAsset_(links)
            empty = struct('assetName','','assetIndex',NaN,'count',0);
            s = repmat(empty, 0, 1);
            for k = 1:numel(links)
                nm = ''; ix = NaN;
                if isfield(links(k),'receiverAssetName'); nm = links(k).receiverAssetName; end
                if isfield(links(k),'receiverAssetIndex'); ix = links(k).receiverAssetIndex; end
                if isempty(nm); continue; end
                j = find(strcmp({s.assetName}, nm), 1);
                if isempty(j)
                    s(end+1) = struct('assetName', nm, 'assetIndex', ix, 'count', 1); %#ok<AGROW>
                else
                    s(j).count = s(j).count + 1;
                end
            end
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

        function validateLinks_(endpoints, links, rows)
            ids = {};
            for k = 1:numel(endpoints); ids{end+1} = endpoints(k).id; end %#ok<AGROW>
            linkIds = {};
            for k = 1:numel(links)
                linkIds{end+1} = links(k).id; %#ok<AGROW>
                if ~ismember(links(k).transmitterEndpointId, ids) || ...
                        ~ismember(links(k).receiverEndpointId, ids)
                    error('ObservableStackDescriptor:missingEndpoint', ...
                        'Link %s references a missing endpoint.', links(k).id);
                end
            end
            for k = 1:numel(rows)
                if ~isempty(rows(k).linkId) && ~startsWith(rows(k).linkId, 'derived:') && ...
                        ~ismember(rows(k).linkId, linkIds)
                    error('ObservableStackDescriptor:missingLink', ...
                        'Observable row %d references missing link %s.', rows(k).rowIndex, rows(k).linkId);
                end
            end
        end
    end
end
