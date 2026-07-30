classdef EstimatorEligibleEndpointStateProduct
    % EstimatorEligibleEndpointStateProduct  Section 2.0.4 / 2.1 rule 5 estimator-eligible
    % publication profile.
    %
    % Composes (never subclasses) revgnss.EndpointStateProduct: the wrapped Stage-1 product
    % stays diagnostic-only forever (requireDeliveryProvenance internally re-checks
    % requireDiagnosticOnlyProduct on it below), and the WRAPPER is the estimator-eligible
    % object. Subclassing EndpointStateProduct would let
    % DistributedLinkProtocolContract.requireDiagnosticOnlyProduct's isa check silently accept
    % the subclass, dissolving the Stage-1 diagnostic-only guarantee; composition avoids that
    % structurally.
    %
    % No mutable "consumed" flag exists anywhere on this class or the product it wraps:
    % consumption belongs to a delivery ledger (revgnss.DistributedDeliveryLedger), never to a
    % product-level flag (Section 2.0.4). The constructor actively refuses any supplied
    % qualityFlags fieldname beginning with "consumed".

    properties (SetAccess = immutable)
        productIdentifier (1,:) char
        publicationProfile (1,:) char
        diagnosticProduct (1,1)
        canonicalPhysicalAssetIndex (1,1) double
        stateSchemaVersion (1,:) char
        coordinateTimeScale (1,:) char
        frameIdentifier (1,:) char
        clockDatumIdentifier (1,:) char
        attitudeErrorCoordinateConvention (1,:) char
        covarianceVariantIdentifier (1,:) char
        declaredRemoteProductPropagationPolicy (1,:) char
        sourceEpoch_s (1,1) double
        validAtEpoch_s (1,1) double
        deliveryEpoch_s (1,1) double
        covarianceGroupIdentifiers (1,:) cell
        commonSourceTreatment (1,1) struct
        qualityFlags (1,1) struct
    end

    methods
        function obj = EstimatorEligibleEndpointStateProduct(record)
            required = {'productIdentifier','publicationProfile','diagnosticProduct', ...
                'canonicalPhysicalAssetIndex','stateSchemaVersion','coordinateTimeScale', ...
                'frameIdentifier','clockDatumIdentifier','attitudeErrorCoordinateConvention', ...
                'covarianceVariantIdentifier','declaredRemoteProductPropagationPolicy', ...
                'sourceEpoch_s','validAtEpoch_s','deliveryEpoch_s', ...
                'covarianceGroupIdentifiers','commonSourceTreatment','qualityFlags'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('EstimatorEligibleEndpointStateProduct:missingField', ...
                    'EstimatorEligibleEndpointStateProduct is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('EstimatorEligibleEndpointStateProduct:unknownField', ...
                    'EstimatorEligibleEndpointStateProduct contains unsupported field %s.',unknown{1});
            end

            % Class check MUST run before assignment: a typed (1,1) EndpointStateProduct
            % property is impossible here because EndpointStateProduct's strict single-struct
            % constructor has no zero-argument form, so MATLAB cannot build the implicit
            % default (MATLAB:class:DefaultPropertyValueRequired).
            if ~isa(record.diagnosticProduct,'revgnss.EndpointStateProduct')
                error('EstimatorEligibleEndpointStateProduct:diagnosticProductType', ...
                    'diagnosticProduct must be a revgnss.EndpointStateProduct.');
            end

            revgnss.DistributedLinkProtocolContract.requireDeliveryProvenance( ...
                record.diagnosticProduct,record.validAtEpoch_s);
            variant = revgnss.DistributedLinkProtocolContract.requireStateSchemaVersion( ...
                record.diagnosticProduct);

            if ~strcmp(char(record.covarianceVariantIdentifier),variant)
                error('EstimatorEligibleEndpointStateProduct:covarianceVariantMismatch', ...
                    'covarianceVariantIdentifier must equal the wrapped product''s matched variant.');
            end
            declaredConvention = char(record.diagnosticProduct.processModelProvenance. ...
                attitudeCovarianceCoordinates);
            if ~strcmp(char(record.attitudeErrorCoordinateConvention),declaredConvention)
                error('EstimatorEligibleEndpointStateProduct:attitudeConventionMismatch', ...
                    'attitudeErrorCoordinateConvention must equal the wrapped product''s declared convention.');
            end
            if ~strcmp(char(record.stateSchemaVersion), ...
                    revgnss.DistributedLinkProtocolContract.StateSchemaVersion)
                error('EstimatorEligibleEndpointStateProduct:stateSchemaVersion', ...
                    'stateSchemaVersion must equal the frozen contract value.');
            end
            if ~strcmp(char(record.coordinateTimeScale), ...
                    revgnss.DistributedLinkProtocolContract.CoordinateTimeScale)
                error('EstimatorEligibleEndpointStateProduct:coordinateTimeScale', ...
                    'coordinateTimeScale must equal the frozen contract value.');
            end
            if ~strcmp(char(record.frameIdentifier), ...
                    revgnss.DistributedLinkProtocolContract.FrameIdentifier)
                error('EstimatorEligibleEndpointStateProduct:frameIdentifier', ...
                    'frameIdentifier must equal the frozen contract value.');
            end
            if ~strcmp(char(record.clockDatumIdentifier), ...
                    revgnss.DistributedLinkProtocolContract.ClockDatumIdentifier)
                error('EstimatorEligibleEndpointStateProduct:clockDatumIdentifier', ...
                    'clockDatumIdentifier must equal the frozen contract value.');
            end
            if record.deliveryEpoch_s ~= record.validAtEpoch_s || ...
                    record.validAtEpoch_s ~= record.sourceEpoch_s
                error('EstimatorEligibleEndpointStateProduct:deliveryDelay', ...
                    ['The initial estimator-eligible profile is same-epoch-only: ' ...
                    'deliveryEpoch_s==validAtEpoch_s==sourceEpoch_s is required.']);
            end
            if ~strcmp(char(record.publicationProfile),'estimatorEligible-v1')
                error('EstimatorEligibleEndpointStateProduct:publicationProfile', ...
                    'publicationProfile must be ''estimatorEligible-v1''.');
            end
            if ~strcmp(char(record.declaredRemoteProductPropagationPolicy),'frozenSameEpochOnly')
                error('EstimatorEligibleEndpointStateProduct:propagationPolicy', ...
                    'declaredRemoteProductPropagationPolicy must be ''frozenSameEpochOnly''.');
            end

            % consumedFlagForbidden is checked BEFORE the exact-field-set schema check below:
            % the required field set {estimatorDerived,truthUsed,diagnosticOnly,estimatorEligible}
            % leaves no room for a fifth "consumed*" field once the schema check's "exactly
            % these four names" rule is enforced, which would make this branch unreachable dead
            % code if it ran second (the same order-of-checks defect class fixed in
            % DistributedLinkCalibrationState's whiteNoiseTreatmentForbidden check).
            if isstruct(record.qualityFlags)
                suppliedFlagNames = fieldnames(record.qualityFlags);
                for index = 1:numel(suppliedFlagNames)
                    if ~isempty(regexp(suppliedFlagNames{index},'^consumed','once'))
                        error('EstimatorEligibleEndpointStateProduct:consumedFlagForbidden', ...
                            'qualityFlags may never carry a mutable consumed* field.');
                    end
                end
            end

            flags = record.qualityFlags;
            requiredFlagNames = {'estimatorDerived','truthUsed','diagnosticOnly','estimatorEligible'};
            if ~isstruct(flags) || ...
                    ~isempty(setdiff(requiredFlagNames,fieldnames(flags))) || ...
                    ~isempty(setdiff(fieldnames(flags),requiredFlagNames))
                error('EstimatorEligibleEndpointStateProduct:qualityFlagsSchema', ...
                    'qualityFlags must declare exactly estimatorDerived/truthUsed/diagnosticOnly/estimatorEligible.');
            end
            if ~(flags.estimatorDerived == true && flags.truthUsed == false && ...
                    flags.diagnosticOnly == false && flags.estimatorEligible == true)
                error('EstimatorEligibleEndpointStateProduct:notEstimatorEligible', ...
                    ['qualityFlags must be estimatorDerived=true, truthUsed=false, ' ...
                    'diagnosticOnly=false, estimatorEligible=true.']);
            end

            revgnss.DistributedLinkProtocolContract.requireCommonSourceTreatmentDeclared( ...
                record.commonSourceTreatment);
            if ~revgnss.DistributedLinkProtocolContract.isFullyRejectedCommonSourceTreatment( ...
                    record.commonSourceTreatment)
                error('EstimatorEligibleEndpointStateProduct:commonSourceNotRejected', ...
                    'Every common-source treatment must still be ''rejected'' (Section 2.2 not implemented).');
            end

            if ~(iscell(record.covarianceGroupIdentifiers) && ...
                    isempty(record.covarianceGroupIdentifiers))
                error('EstimatorEligibleEndpointStateProduct:covarianceGroupNotImplemented', ...
                    'No builder shares covariance across observations yet; this must be empty.');
            end

            obj.productIdentifier = char(record.productIdentifier);
            obj.publicationProfile = char(record.publicationProfile);
            obj.diagnosticProduct = record.diagnosticProduct;
            obj.canonicalPhysicalAssetIndex = double(record.canonicalPhysicalAssetIndex);
            obj.stateSchemaVersion = char(record.stateSchemaVersion);
            obj.coordinateTimeScale = char(record.coordinateTimeScale);
            obj.frameIdentifier = char(record.frameIdentifier);
            obj.clockDatumIdentifier = char(record.clockDatumIdentifier);
            obj.attitudeErrorCoordinateConvention = char(record.attitudeErrorCoordinateConvention);
            obj.covarianceVariantIdentifier = char(record.covarianceVariantIdentifier);
            obj.declaredRemoteProductPropagationPolicy = ...
                char(record.declaredRemoteProductPropagationPolicy);
            obj.sourceEpoch_s = double(record.sourceEpoch_s);
            obj.validAtEpoch_s = double(record.validAtEpoch_s);
            obj.deliveryEpoch_s = double(record.deliveryEpoch_s);
            obj.covarianceGroupIdentifiers = record.covarianceGroupIdentifiers;
            obj.commonSourceTreatment = record.commonSourceTreatment;
            obj.qualityFlags = record.qualityFlags;
        end

        function s = toStruct(obj)
            s = struct();
            names = properties(obj);
            for index = 1:numel(names)
                if strcmp(names{index},'diagnosticProduct')
                    s.(names{index}) = obj.(names{index}).toStruct();
                else
                    s.(names{index}) = obj.(names{index});
                end
            end
        end
    end

    methods (Static)
        function product = fromDiagnosticProduct(diagnosticProduct, commonSourceTreatment)
            if ~isa(diagnosticProduct,'revgnss.EndpointStateProduct')
                error('EstimatorEligibleEndpointStateProduct:diagnosticProductType', ...
                    'diagnosticProduct must be a revgnss.EndpointStateProduct.');
            end
            variant = revgnss.DistributedLinkProtocolContract.requireStateSchemaVersion( ...
                diagnosticProduct);
            declaredConvention = char(diagnosticProduct.processModelProvenance. ...
                attitudeCovarianceCoordinates);
            record = struct( ...
                'productIdentifier',sprintf('estimatorProduct:%s',diagnosticProduct.sequenceIdentifier), ...
                'publicationProfile','estimatorEligible-v1', ...
                'diagnosticProduct',diagnosticProduct, ...
                'canonicalPhysicalAssetIndex',diagnosticProduct.sourceAssetIndex, ...
                'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion, ...
                'coordinateTimeScale',revgnss.DistributedLinkProtocolContract.CoordinateTimeScale, ...
                'frameIdentifier',revgnss.DistributedLinkProtocolContract.FrameIdentifier, ...
                'clockDatumIdentifier',revgnss.DistributedLinkProtocolContract.ClockDatumIdentifier, ...
                'attitudeErrorCoordinateConvention',declaredConvention, ...
                'covarianceVariantIdentifier',variant, ...
                'declaredRemoteProductPropagationPolicy','frozenSameEpochOnly', ...
                'sourceEpoch_s',diagnosticProduct.sourceEpoch_s, ...
                'validAtEpoch_s',diagnosticProduct.validAtEpoch_s, ...
                'deliveryEpoch_s',diagnosticProduct.validAtEpoch_s, ...
                'covarianceGroupIdentifiers',{{}}, ...
                'commonSourceTreatment',commonSourceTreatment, ...
                'qualityFlags',struct('estimatorDerived',true,'truthUsed',false, ...
                    'diagnosticOnly',false,'estimatorEligible',true));
            product = revgnss.EstimatorEligibleEndpointStateProduct(record);
        end
    end
end
