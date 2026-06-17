classdef LinkDescriptor
    % LinkDescriptor  Metadata for a directed transmitter-to-receiver link.

    methods (Static)
        function link = create(id, transmitterEndpointId, receiverEndpointId, linkType)
            if nargin < 4 || isempty(linkType); linkType = 'oneWay'; end
            link = struct('id', char(id), ...
                'transmitterEndpointId', char(transmitterEndpointId), ...
                'receiverEndpointId', char(receiverEndpointId), ...
                'linkType', char(linkType));
        end

        function link = towerToReceiver(towerIdx, receiverIdx, assetName)
            txId = sprintf('tower:%03d', towerIdx);
            rxId = sprintf('spacecraft:%s:rx:%03d', char(assetName), receiverIdx);
            id = sprintf('link:t%03d:rx%03d', towerIdx, receiverIdx);
            link = revgnss.LinkDescriptor.create(id, txId, rxId, 'towerToSpacecraft');
        end
    end
end
