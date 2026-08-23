classdef LinkDescriptor
    % LinkDescriptor  Metadata for a directed transmitter-to-receiver link.

    methods (Static)
        function link = create(id, transmitterEndpointId, receiverEndpointId, linkType, receiverAssetName, receiverAssetIndex, transmitterAssetName, transmitterAssetIndex)
            if nargin < 4 || isempty(linkType); linkType = 'oneWay'; end
            if nargin < 5 || isempty(receiverAssetName); receiverAssetName = ''; end
            if nargin < 6 || isempty(receiverAssetIndex); receiverAssetIndex = NaN; end
            if nargin < 7 || isempty(transmitterAssetName); transmitterAssetName = ''; end
            if nargin < 8 || isempty(transmitterAssetIndex); transmitterAssetIndex = NaN; end
            link = struct('id', char(id), ...
                'transmitterEndpointId', char(transmitterEndpointId), ...
                'receiverEndpointId', char(receiverEndpointId), ...
                'linkType', char(linkType), ...
                'receiverAssetName', char(receiverAssetName), ...
                'receiverAssetIndex', receiverAssetIndex, ...
                'transmitterAssetName', char(transmitterAssetName), ...
                'transmitterAssetIndex', transmitterAssetIndex);
        end

        function link = towerToReceiver(towerIdx, receiverIdx, assetName, assetIndex)
            if nargin < 4 || isempty(assetIndex); assetIndex = 1; end
            txId = sprintf('tower:%03d', towerIdx);
            rxId = sprintf('spacecraft:%s:rx:%03d', char(assetName), receiverIdx);
            id = sprintf('link:a%03d:t%03d:rx%03d', assetIndex, towerIdx, receiverIdx);
            link = revgnss.LinkDescriptor.create(id, txId, rxId, 'towerToSpacecraft', assetName, assetIndex);
        end

        function link = islOneWay(txAssetName, txAssetIndex, rxAssetName, rxAssetIndex)
            txId = sprintf('spacecraft:%s:tx', char(txAssetName));
            rxId = sprintf('spacecraft:%s:rx:%03d', char(rxAssetName), 1);
            id = sprintf('link:isl:a%03d:a%03d', txAssetIndex, rxAssetIndex);
            link = revgnss.LinkDescriptor.create(id, txId, rxId, 'ISL_ONE_WAY', ...
                rxAssetName, rxAssetIndex, txAssetName, txAssetIndex);
        end

        function link = islTwoWay(txAssetName, txAssetIndex, rxAssetName, rxAssetIndex)
            txId = sprintf('spacecraft:%s:tx', char(txAssetName));
            rxId = sprintf('spacecraft:%s:rx:%03d', char(rxAssetName), 1);
            id = sprintf('link:isl2w:a%03d:a%03d', txAssetIndex, rxAssetIndex);
            link = revgnss.LinkDescriptor.create(id, txId, rxId, 'ISL_TWO_WAY_RANGE', ...
                rxAssetName, rxAssetIndex, txAssetName, txAssetIndex);
        end
    end
end
