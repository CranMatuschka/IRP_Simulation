classdef EndpointDescriptor
    % EndpointDescriptor  Lightweight metadata for current and future link endpoints.

    methods (Static)
        function ep = create(id, type, role, towerIdx, receiverIdx, assetName)
            if nargin < 3 || isempty(role); role = ''; end
            if nargin < 4 || isempty(towerIdx); towerIdx = NaN; end
            if nargin < 5 || isempty(receiverIdx); receiverIdx = NaN; end
            if nargin < 6 || isempty(assetName); assetName = ''; end
            ep = struct('id', char(id), 'type', char(type), ...
                'role', char(role), 'towerIndex', towerIdx, ...
                'receiverIndex', receiverIdx, 'assetName', char(assetName));
        end

        function ep = tower(towerIdx)
            ep = revgnss.EndpointDescriptor.create( ...
                sprintf('tower:%03d', towerIdx), 'tower', 'transmitter', towerIdx, NaN, '');
        end

        function ep = spacecraftReceiver(assetName, receiverIdx)
            ep = revgnss.EndpointDescriptor.create( ...
                sprintf('spacecraft:%s:rx:%03d', char(assetName), receiverIdx), ...
                'spacecraftReceiver', 'receiver', NaN, receiverIdx, assetName);
        end
    end
end
