classdef EndpointClockAnchorDeclaration
    % EndpointClockAnchorDeclaration  Which clock datum one endpoint's clock is tied to (plan
    % Section 2.4 requirement 2), derived ONLY from its own local estimator configuration.
    %
    % A finite prior clock-bias variance is NOT an anchor: every leaf's clock-bias variance is
    % finite because P0 is finite, regardless of whether that clock is tied to any stated datum.
    % The anchor is therefore a DECLARED, config-derived property, never inferred from a prior
    % variance. The private constructor is the structural guarantee that a caller cannot assert
    % "anchored" for a leaf whose configuration does not anchor it -- only
    % fromLocalEstimatorConfig, which classifies a real cfg, can produce one.

    properties (Constant)
        AllowedAnchorKinds = {'absoluteFromExternalTowerClockProduct', ...
            'absoluteFromEstimatedTowerClockGauge','unanchoredRelativeOnly'};
        AllowedClockModes = {'spacecraftReceiverClockOnly','includeTowerClocksInEKF'};
        AllowedGaugeModes = {'externalTowerCorrections','fixReferenceTower','free'};
        UndeclaredDatumIdentifier = 'noStatedDatum';
    end

    properties (SetAccess = immutable)
        endpointIdentifier (1,:) char
        canonicalPhysicalAssetIndex (1,1) double
        clockDatumIdentifier (1,:) char
        anchorKind (1,:) char
        anchorDatumIdentifier (1,:) char
        clockModeIdentifier (1,:) char
        clockGaugeMode (1,:) char
        referenceTowerIndex (1,1) double
        nTowersDeclared (1,1) double
        estimatorTowerClockMode (1,:) char
    end

    methods (Access = private)
        function obj = EndpointClockAnchorDeclaration(record)
            required = {'endpointIdentifier','canonicalPhysicalAssetIndex', ...
                'clockDatumIdentifier','anchorKind','anchorDatumIdentifier', ...
                'clockModeIdentifier','clockGaugeMode','referenceTowerIndex', ...
                'nTowersDeclared','estimatorTowerClockMode'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('EndpointClockAnchorDeclaration:missingField', ...
                    'EndpointClockAnchorDeclaration is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('EndpointClockAnchorDeclaration:unknownField', ...
                    'EndpointClockAnchorDeclaration contains unsupported field %s.',unknown{1});
            end
            if ~any(strcmp(char(record.anchorKind), ...
                    revgnss.EndpointClockAnchorDeclaration.AllowedAnchorKinds))
                error('EndpointClockAnchorDeclaration:anchorKind', ...
                    'anchorKind must be a frozen allowed anchor kind.');
            end
            if strcmp(char(record.anchorKind),'unanchoredRelativeOnly') && ...
                    ~strcmp(char(record.anchorDatumIdentifier), ...
                    revgnss.EndpointClockAnchorDeclaration.UndeclaredDatumIdentifier)
                error('EndpointClockAnchorDeclaration:anchorDatumIdentifier', ...
                    ['unanchoredRelativeOnly must carry the frozen undeclared datum ' ...
                    'identifier, never a synthesized one.']);
            end
            if ~any(strcmp(char(record.clockModeIdentifier), ...
                    revgnss.EndpointClockAnchorDeclaration.AllowedClockModes))
                error('EndpointClockAnchorDeclaration:clockModeIdentifier', ...
                    'clockModeIdentifier must be a frozen allowed clock mode.');
            end
            if ~any(strcmp(char(record.clockGaugeMode), ...
                    revgnss.EndpointClockAnchorDeclaration.AllowedGaugeModes))
                error('EndpointClockAnchorDeclaration:clockGaugeMode', ...
                    'clockGaugeMode must be a frozen allowed gauge mode.');
            end
            if ~(isnumeric(record.canonicalPhysicalAssetIndex) && ...
                    isscalar(record.canonicalPhysicalAssetIndex) && ...
                    isfinite(record.canonicalPhysicalAssetIndex) && ...
                    record.canonicalPhysicalAssetIndex >= 1)
                error('EndpointClockAnchorDeclaration:canonicalPhysicalAssetIndex', ...
                    'canonicalPhysicalAssetIndex must be a positive finite scalar.');
            end
            if ~(isnumeric(record.nTowersDeclared) && isscalar(record.nTowersDeclared) && ...
                    isfinite(record.nTowersDeclared) && record.nTowersDeclared >= 0)
                error('EndpointClockAnchorDeclaration:nTowersDeclared', ...
                    'nTowersDeclared must be a nonnegative finite scalar.');
            end
            if ~(isnumeric(record.referenceTowerIndex) && isscalar(record.referenceTowerIndex) && ...
                    isfinite(record.referenceTowerIndex))
                error('EndpointClockAnchorDeclaration:referenceTowerIndex', ...
                    'referenceTowerIndex must be a finite scalar.');
            end
            % Only load-bearing (used to synthesize anchorDatumIdentifier) for
            % absoluteFromEstimatedTowerClockGauge; range-checked here so a nonexistent
            % reference tower cannot silently assert an anchor to a tower that isn't there
            % (the fail-CLOSED philosophy this whole switch is built on).
            if strcmp(char(record.anchorKind),'absoluteFromEstimatedTowerClockGauge') && ...
                    ~(record.referenceTowerIndex == round(record.referenceTowerIndex) && ...
                    record.referenceTowerIndex >= 1 && ...
                    record.referenceTowerIndex <= record.nTowersDeclared)
                error('EndpointClockAnchorDeclaration:referenceTowerIndex', ...
                    ['referenceTowerIndex (%g) must be a positive integer at most ' ...
                    'nTowersDeclared (%g) when anchorKind=absoluteFromEstimatedTowerClockGauge.'], ...
                    record.referenceTowerIndex,record.nTowersDeclared);
            end

            obj.endpointIdentifier = char(record.endpointIdentifier);
            obj.canonicalPhysicalAssetIndex = double(record.canonicalPhysicalAssetIndex);
            obj.clockDatumIdentifier = char(record.clockDatumIdentifier);
            obj.anchorKind = char(record.anchorKind);
            obj.anchorDatumIdentifier = char(record.anchorDatumIdentifier);
            obj.clockModeIdentifier = char(record.clockModeIdentifier);
            obj.clockGaugeMode = char(record.clockGaugeMode);
            obj.referenceTowerIndex = double(record.referenceTowerIndex);
            obj.nTowersDeclared = double(record.nTowersDeclared);
            obj.estimatorTowerClockMode = char(record.estimatorTowerClockMode);
        end
    end

    methods
        function tf = isAbsolutelyAnchored(obj)
            tf = ~strcmp(obj.anchorKind,'unanchoredRelativeOnly');
        end

        function s = toStruct(obj)
            s = struct();
            names = properties(obj);
            for index = 1:numel(names)
                s.(names{index}) = obj.(names{index});
            end
        end
    end

    methods (Static)
        function declaration = fromLocalEstimatorConfig(cfg, endpointIdentifier, ...
                canonicalPhysicalAssetIndex)
            % fromLocalEstimatorConfig  Classify a real, finalized local-estimator cfg into an
            % anchor declaration. This is a frozen switch: any configuration combination it does
            % not explicitly recognise throws (plan invariant 6 -- no silent fallback), rather
            % than defaulting to either anchored or unanchored.
            if ~isstruct(cfg)
                error('EndpointClockAnchorDeclaration:configurationType', ...
                    'fromLocalEstimatorConfig requires a config struct.');
            end
            nTowers = revgnss.EndpointClockAnchorDeclaration.field_(cfg,{'scenario','nTowers'},0);
            % estimator.towerClockMode is the RESOLVED value ConfigFactory derives (from
            % cfg.errors.towerClockCorrection.mode / legacy cfg.towerClock.correctionMode) and
            % is what the EKF actually consumes; it is authoritative here, not the pre-resolution
            % cfg.towerClock.correctionMode knob.
            towerClockMode = revgnss.EndpointClockAnchorDeclaration.field_( ...
                cfg,{'estimator','towerClockMode'},'none');
            clockMode = revgnss.EndpointClockAnchorDeclaration.field_( ...
                cfg,{'clock','mode'},'spacecraftReceiverClockOnly');
            gaugeMode = revgnss.EndpointClockAnchorDeclaration.field_( ...
                cfg,{'clock','gauge','mode'},'externalTowerCorrections');
            referenceTowerIndex = revgnss.EndpointClockAnchorDeclaration.field_( ...
                cfg,{'clock','gauge','referenceTowerIndex'},1);

            if ~any(strcmp(clockMode, ...
                    revgnss.EndpointClockAnchorDeclaration.AllowedClockModes))
                error('EndpointClockAnchorDeclaration:unclassifiedConfiguration', ...
                    'cfg.clock.mode=''%s'' is not a recognised clock mode.',clockMode);
            end
            if ~any(strcmp(gaugeMode, ...
                    revgnss.EndpointClockAnchorDeclaration.AllowedGaugeModes))
                error('EndpointClockAnchorDeclaration:unclassifiedConfiguration', ...
                    'cfg.clock.gauge.mode=''%s'' is not a recognised gauge mode.',gaugeMode);
            end

            if nTowers < 1 || strcmp(towerClockMode,'none')
                % No ground tower, or no tower clock correction reaches the estimator at all:
                % the spacecraft clock is tied to an unmodelled quantity. Fails closed -- there
                % is no STATED datum, even though the clock-bias state itself has a finite prior.
                anchorKind = 'unanchoredRelativeOnly';
                anchorDatumIdentifier = ...
                    revgnss.EndpointClockAnchorDeclaration.UndeclaredDatumIdentifier;
            elseif strcmp(clockMode,'includeTowerClocksInEKF')
                if strcmp(gaugeMode,'free')
                    anchorKind = 'unanchoredRelativeOnly';
                    anchorDatumIdentifier = ...
                        revgnss.EndpointClockAnchorDeclaration.UndeclaredDatumIdentifier;
                elseif strcmp(gaugeMode,'fixReferenceTower')
                    anchorKind = 'absoluteFromEstimatedTowerClockGauge';
                    anchorDatumIdentifier = sprintf( ...
                        'groundTowerGauge:fixReferenceTower:tower%d',referenceTowerIndex);
                else % 'externalTowerCorrections'
                    anchorKind = 'absoluteFromExternalTowerClockProduct';
                    anchorDatumIdentifier = sprintf( ...
                        'groundTowerClockProduct:%s',towerClockMode);
                end
            else % clockMode == 'spacecraftReceiverClockOnly'
                anchorKind = 'absoluteFromExternalTowerClockProduct';
                anchorDatumIdentifier = sprintf('groundTowerClockProduct:%s',towerClockMode);
            end

            record = struct( ...
                'endpointIdentifier',char(endpointIdentifier), ...
                'canonicalPhysicalAssetIndex',canonicalPhysicalAssetIndex, ...
                'clockDatumIdentifier',revgnss.DistributedLinkProtocolContract.ClockDatumIdentifier, ...
                'anchorKind',anchorKind, ...
                'anchorDatumIdentifier',anchorDatumIdentifier, ...
                'clockModeIdentifier',clockMode, ...
                'clockGaugeMode',gaugeMode, ...
                'referenceTowerIndex',referenceTowerIndex, ...
                'nTowersDeclared',nTowers, ...
                'estimatorTowerClockMode',towerClockMode);
            declaration = revgnss.EndpointClockAnchorDeclaration(record);
        end
    end

    methods (Static, Access = private)
        function value = field_(s,path,defaultValue)
            value = s;
            for index = 1:numel(path)
                if ~isstruct(value) || ~isfield(value,path{index})
                    value = defaultValue;
                    return
                end
                value = value.(path{index});
            end
            if isstring(value); value = char(value); end
        end
    end
end
