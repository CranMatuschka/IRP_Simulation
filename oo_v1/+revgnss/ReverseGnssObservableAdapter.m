classdef ReverseGnssObservableAdapter
    % ReverseGnssObservableAdapter  Map current tower-centric rows to generic metadata.

    methods (Static)
        function stack = build(cfg, H, nCodeRows, errStruct, stateMap)
            nTwr = revgnss.ReverseGnssObservableAdapter.getCfgNum_(cfg, {'scenario','nTowers'}, 0);
            nRx = revgnss.ReverseGnssObservableAdapter.getCfgNum_(cfg, {'scenario','nReceivers'}, 1);
            assetInfos = revgnss.MultiAssetConfig.assetInfos(cfg);
            assetName = assetInfos(1).name;
            endpoints = revgnss.ReverseGnssObservableAdapter.endpoints_(nTwr, assetInfos);
            links = revgnss.ReverseGnssObservableAdapter.links_(nTwr, nRx, assetName, 1);
            rows = revgnss.ReverseGnssObservableAdapter.physicalRows_(cfg, H, nCodeRows, errStruct, stateMap, assetName);
            stack = revgnss.ObservableStackDescriptor.create(endpoints, links, rows);
            revgnss.ReverseGnssObservableAdapter.validatePhysicalRows_(stack, H, stateMap);
        end

        function stack = addDifferentialAttitudeRows(stack, diffInfo, stateMap)
            if isempty(stack) || ~isstruct(diffInfo) || ~isfield(diffInfo,'nRows') || diffInfo.nRows <= 0
                return
            end
            rows = stack.rows;
            startIdx = numel(rows);
            for k = 1:diffInfo.nRows
                row = revgnss.ObservableRowDescriptor.create( ...
                    startIdx + k, 'diffCarrierAttitude', 'derived:receiverBaseline', ...
                    'L1', NaN, NaN, stateMap.euler_idx, ...
                    'receiver-baseline carrier-derived calibrated differential attitude row', ...
                    'physicalEKF');
                row = revgnss.ObservableRowDescriptor.withFlags(row, false, true);
                rows(end+1) = row; %#ok<AGROW>
            end
            stack = revgnss.ObservableStackDescriptor.create(stack.endpoints, stack.links, rows);
        end
    end

    methods (Static, Access = private)
        function rows = physicalRows_(cfg, H, nCodeRows, errStruct, stateMap, assetName)
            rows = struct([]);
            mType = {};
            if isfield(errStruct,'measType_perRow'); mType = errStruct.measType_perRow; end
            if numel(mType) ~= size(H,1)
                error('ObservableAdapter:rowTypeCountMismatch', ...
                    'Observable row metadata count (%d) does not match H rows (%d).', numel(mType), size(H,1));
            end
            typeCounter = struct('code',0,'doppler',0,'carrier',0);
            for ri = 1:size(H,1)
                obsType = mType{ri};
                if strcmp(obsType,'ifCode'); obsType = 'code'; end
                if ~isfield(typeCounter, obsType); typeCounter.(obsType) = 0; end
                typeCounter.(obsType) = typeCounter.(obsType) + 1;
                [ti, ai, sig] = revgnss.ReverseGnssObservableAdapter.rowIdentity_( ...
                    typeCounter.(obsType), obsType, errStruct);
                linkId = sprintf('link:a001:t%03d:rx%03d', ti, ai);
                stateCols = find(abs(H(ri,:)) > 1e-12);
                role = revgnss.ReverseGnssObservableAdapter.roleFor_(cfg, obsType);
                provenance = revgnss.ReverseGnssObservableAdapter.provenanceFor_(obsType);
                row = revgnss.ObservableRowDescriptor.create( ...
                    ri, obsType, linkId, sig, ti, ai, stateCols, provenance, role);
                row = revgnss.ObservableRowDescriptor.withFlags(row, ...
                    revgnss.ReverseGnssObservableAdapter.updatesClock_(obsType), ...
                    revgnss.ReverseGnssObservableAdapter.isAttitudeSensitive_(cfg, obsType, ai));
                rows = revgnss.ReverseGnssObservableAdapter.appendRow_(rows, row); %#ok<AGROW>
            end
            if isempty(rows)
                rows = repmat(revgnss.ObservableRowDescriptor.create(0,'','','',NaN,NaN,[],'',''), 0, 1);
            end
        end

        function [ti, ai, sig] = rowIdentity_(srcIdx, obsType, errStruct)
            ti = NaN; ai = NaN; sig = '';
            switch obsType
                case 'code'
                    sig = revgnss.ReverseGnssObservableAdapter.codeSignal_(errStruct, srcIdx);
                    [ti, ai] = revgnss.ReverseGnssObservableAdapter.codePair_(errStruct, srcIdx);
                case 'doppler'
                    sig = 'range-rate';
                    [ti, ai] = revgnss.ReverseGnssObservableAdapter.codePair_(errStruct, srcIdx);
                case 'carrier'
                    cp = errStruct.carrierPhase;
                    ti = cp.towerIdx(srcIdx);
                    ai = cp.antennaIdx(srcIdx);
                    sig = 'L1';
                otherwise
                    sig = 'unknown';
            end
        end

        function [ti, ai] = codePair_(errStruct, idx)
            ti = NaN; ai = NaN;
            if isfield(errStruct,'towerIdx_perMeas') && idx <= numel(errStruct.towerIdx_perMeas)
                ti = errStruct.towerIdx_perMeas(idx);
            end
            if isfield(errStruct,'antennaIdx_perMeas') && idx <= numel(errStruct.antennaIdx_perMeas)
                ai = errStruct.antennaIdx_perMeas(idx);
            end
        end

        function sig = codeSignal_(errStruct, idx)
            sig = 'L1';
            if isfield(errStruct,'signalName_perMeas') && idx <= numel(errStruct.signalName_perMeas)
                sig = errStruct.signalName_perMeas{idx};
            end
        end

        function role = roleFor_(cfg, obsType)
            switch obsType
                case {'code','doppler','carrier'}
                    role = 'physicalEKF';
                otherwise
                    role = 'reportOnly';
            end
            if strcmp(obsType,'carrier') && ~strcmp(revgnss.ReverseGnssObservableAdapter.getCfgStr_(cfg, {'measurements','carrierMode'}, 'none'), 'ekfFloat')
                role = 'diagnosticOnly';
            end
        end

        function p = provenanceFor_(obsType)
            switch obsType
                case 'code'
                    p = 'CodeMeasurementBuilder tower-to-spacecraft receiver row';
                case 'doppler'
                    p = 'DopplerMeasurementBuilder tower-to-spacecraft range-rate row';
                case 'carrier'
                    p = 'CarrierMeasurementBuilder tower-to-spacecraft receiver-indexed L1 carrier row';
                otherwise
                    p = 'unknown observable row';
            end
        end

        function tf = updatesClock_(obsType)
            tf = any(strcmp(obsType, {'code','doppler','carrier'}));
        end

        function tf = isAttitudeSensitive_(cfg, obsType, rxIdx)
            tf = false;
            if ~any(strcmp(obsType, {'code','carrier'})); return; end
            if ~isfield(cfg,'estimator') || ~isfield(cfg.estimator,'estimateAttitude') || ~cfg.estimator.estimateAttitude
                return
            end
            if ~isfield(cfg,'asset') || ~isfield(cfg.asset,'receiverLeverArms_body_m') || isnan(rxIdx)
                return
            end
            arms = cfg.asset.receiverLeverArms_body_m;
            tf = rxIdx <= size(arms,2) && norm(arms(:,rxIdx)) > 1e-9;
        end

        function validatePhysicalRows_(stack, H, stateMap)
            physicalRows = stack.rows(~strcmp({stack.rows.observableType}, 'diffCarrierAttitude'));
            if numel(physicalRows) ~= size(H,1)
                error('ObservableAdapter:physicalRowCountMismatch', ...
                    'Descriptor physical rows (%d) do not match H rows (%d).', numel(physicalRows), size(H,1));
            end
            for k = 1:numel(physicalRows)
                row = physicalRows(k);
                if row.updatesClock
                    clkCols = revgnss.ReverseGnssObservableAdapter.clockColsFor_(row.observableType, stateMap);
                    if isempty(intersect(row.stateColumns, clkCols))
                        error('ObservableAdapter:clockColumnMissing', ...
                            '%s row %d declares clock sensitivity but H has no clock column.', row.observableType, row.rowIndex);
                    end
                end
                if row.attitudeSensitive
                    attCols = stateMap.euler_idx;
                    if isempty(intersect(row.stateColumns, attCols))
                        error('ObservableAdapter:attitudeColumnMissing', ...
                            '%s row %d declares attitude sensitivity but H attitude columns are zero.', row.observableType, row.rowIndex);
                    end
                end
            end
        end

        function cols = clockColsFor_(obsType, stateMap)
            if strcmp(obsType,'doppler')
                cols = stateMap.bdot_rx_idx;
            else
                cols = stateMap.b_rx_idx;
            end
        end

        function endpoints = endpoints_(nTwr, assetInfos)
            endpoints = repmat(revgnss.EndpointDescriptor.tower(1), 0, 1);
            for ti = 1:nTwr
                endpoints(end+1) = revgnss.EndpointDescriptor.tower(ti); %#ok<AGROW>
            end
            for ai = 1:numel(assetInfos)
                for ri = 1:assetInfos(ai).nReceivers
                    endpoints(end+1) = revgnss.EndpointDescriptor.spacecraftReceiver( ...
                        assetInfos(ai).name, ri, assetInfos(ai).index); %#ok<AGROW>
                end
            end
        end

        function links = links_(nTwr, nRx, assetName, assetIndex)
            links = repmat(revgnss.LinkDescriptor.towerToReceiver(1, 1, assetName, assetIndex), 0, 1);
            for ti = 1:nTwr
                for ri = 1:nRx
                    links(end+1) = revgnss.LinkDescriptor.towerToReceiver(ti, ri, assetName, assetIndex); %#ok<AGROW>
                end
            end
        end

        function rows = appendRow_(rows, row)
            if isempty(rows); rows = row; else; rows(end+1) = row; end
        end

        function v = getCfgNum_(cfg, path, defaultValue)
            v = revgnss.ReverseGnssObservableAdapter.walkCfg_(cfg, path, defaultValue);
            if ~isnumeric(v) || ~isscalar(v); v = defaultValue; end
        end

        function s = getCfgStr_(cfg, path, defaultValue)
            s = revgnss.ReverseGnssObservableAdapter.walkCfg_(cfg, path, defaultValue);
            if isstring(s); s = char(s); end
            if ~ischar(s); s = defaultValue; end
        end

        function v = walkCfg_(cfg, path, defaultValue)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k})
                    v = v.(path{k});
                else
                    v = defaultValue;
                    return
                end
            end
        end
    end
end
