classdef LinkDescriptor
    % LinkDescriptor  Metadata for a directed transmitter-to-receiver link.

    methods (Static)
        function link = create(id, transmitterEndpointId, receiverEndpointId, linkType, receiverAssetName, receiverAssetIndex)
            if nargin < 4 || isempty(linkType); linkType = 'oneWay'; end
            if nargin < 5 || isempty(receiverAssetName); receiverAssetName = ''; end
            if nargin < 6 || isempty(receiverAssetIndex); receiverAssetIndex = NaN; end
            link = struct('id', char(id), ...
                'transmitterEndpointId', char(transmitterEndpointId), ...
                'receiverEndpointId', char(receiverEndpointId), ...
                'linkType', char(linkType), ...
                'receiverAssetName', char(receiverAssetName), ...
                'receiverAssetIndex', receiverAssetIndex);
        end

        function link = towerToReceiver(towerIdx, receiverIdx, assetName, assetIndex)
            if nargin < 4 || isempty(assetIndex); assetIndex = 1; end
            txId = sprintf('tower:%03d', towerIdx);
            rxId = sprintf('spacecraft:%s:rx:%03d', char(assetName), receiverIdx);
            id = sprintf('link:a%03d:t%03d:rx%03d', assetIndex, towerIdx, receiverIdx);
            link = revgnss.LinkDescriptor.create(id, txId, rxId, 'towerToSpacecraft', assetName, assetIndex);
        end
    end
end
