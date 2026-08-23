classdef CommunicationExchangeJournal < handle
    % CommunicationExchangeJournal  Provenance-only local-state product journal.

    properties (Access = private)
        entries_ struct = struct('product',{},'publicationEpoch_s',{},'status',{})
        sequenceKeys_ containers.Map
        sourceEpochKeys_ containers.Map
        lastEpoch_s (1,1) double = -Inf
    end

    methods
        function obj = CommunicationExchangeJournal()
            obj.sequenceKeys_ = containers.Map('KeyType','char','ValueType','logical');
            obj.sourceEpochKeys_ = containers.Map('KeyType','char','ValueType','logical');
        end

        function record(obj, product, publicationEpoch_s)
            if ~isa(product,'revgnss.EndpointStateProduct')
                error('CommunicationExchangeJournal:productType', ...
                    'Only immutable EndpointStateProduct objects may be recorded.');
            end
            if ~(isnumeric(publicationEpoch_s) && isscalar(publicationEpoch_s) && ...
                    isfinite(publicationEpoch_s) && ...
                    publicationEpoch_s == product.sourceEpoch_s)
                error('CommunicationExchangeJournal:publicationEpoch', ...
                    'Publication epoch must equal the product source epoch.');
            end
            sequenceKey = product.sequenceIdentifier;
            sourceEpochKey = sprintf('%s@%.17g', ...
                product.sourceAssetIdentifier,product.sourceEpoch_s);
            if isKey(obj.sequenceKeys_,sequenceKey) || ...
                    isKey(obj.sourceEpochKeys_,sourceEpochKey)
                error('CommunicationExchangeJournal:duplicateProduct', ...
                    'A state product for this source sequence/epoch is already recorded.');
            end
            obj.sequenceKeys_(sequenceKey) = true;
            obj.sourceEpochKeys_(sourceEpochKey) = true;
            obj.entries_(end+1) = struct('product',product, ...
                'publicationEpoch_s',double(publicationEpoch_s), ...
                'status','pendingDelivery');
        end

        function advanceToEpoch(obj, epoch_s, maximumAge_s)
            if ~(isnumeric(epoch_s) && isscalar(epoch_s) && isfinite(epoch_s)) || ...
                    ~(isnumeric(maximumAge_s) && isscalar(maximumAge_s) && ...
                    isfinite(maximumAge_s) && maximumAge_s >= 0)
                error('CommunicationExchangeJournal:epoch', ...
                    'Epoch and maximum product age must be finite; age must be nonnegative.');
            end
            if epoch_s < obj.lastEpoch_s
                error('CommunicationExchangeJournal:outOfSequenceEpoch', ...
                    'State-product journal epochs must be monotonic.');
            end
            obj.lastEpoch_s = epoch_s;
            for index = 1:numel(obj.entries_)
                product = obj.entries_(index).product;
                if epoch_s < product.deliveryEpoch_s
                    status = 'pendingDelivery';
                elseif epoch_s-product.validAtEpoch_s > maximumAge_s
                    status = 'staleDiagnosticOnly';
                else
                    status = 'availableDiagnosticOnly';
                end
                obj.entries_(index).status = status;
            end
        end

        function count = numberProducts(obj)
            count = numel(obj.entries_);
        end

        function products = products(obj)
            products = cell(1,numel(obj.entries_));
            for index = 1:numel(obj.entries_)
                products{index} = obj.entries_(index).product;
            end
        end

        function entries = export(obj)
            entries = repmat(struct('product',struct(),'publicationEpoch_s',NaN, ...
                'status',''),1,numel(obj.entries_));
            for index = 1:numel(obj.entries_)
                entries(index).product = obj.entries_(index).product.toStruct();
                entries(index).publicationEpoch_s = obj.entries_(index).publicationEpoch_s;
                entries(index).status = obj.entries_(index).status;
            end
        end

        function out = summary(obj)
            statuses = cell(1,numel(obj.entries_));
            for index = 1:numel(obj.entries_)
                statuses{index} = obj.entries_(index).status;
            end
            out = struct('generatedProducts',numel(statuses), ...
                'availableDiagnosticOnly',sum(strcmp(statuses,'availableDiagnosticOnly')), ...
                'pendingDelivery',sum(strcmp(statuses,'pendingDelivery')), ...
                'staleDiagnosticOnly',sum(strcmp(statuses,'staleDiagnosticOnly')), ...
                'consumedByOwner',0);
        end
    end
end
