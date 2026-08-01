classdef DirectReciprocalTimeTransferBuilder
    % DirectReciprocalTimeTransferBuilder  Plan Section 4.2 interface #5: the truth-side
    % 'directRoundTrip' adapter. Two thin public entries -- buildFromIsl (both endpoints
    % spacecraft) and buildFromGroundToSpace (one fixed ground tower, one spacecraft) -- construct
    % their respective revgnss.TwoWayCodeEndpointModel pair via
    % revgnss.ReciprocalEndpointTruthProvider and then funnel through the ONE private
    % assembleDirect_, so the physics/covariance/record-assembly logic exists exactly once
    % regardless of which topology called it.
    %
    % A truth-side builder deliberately: both endpoints come from
    % ReciprocalEndpointTruthProvider (stateSource='physicalTruth' always), and 'hardware' must
    % itself be a physicalTruth revgnss.ReciprocalLinkHardwareModel --
    % revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip enforces this on every input, so
    % assembleDirect_ does not re-check it. Plan Section 4.3 owns the mirrored estimate-side
    % construction; this class does not provide one.
    %
    % assembleDirect_ builds the covariance block itself from named optional sources (counter/tag
    % noise, the hardware's own terminalModemDelayBlock, an optional array of
    % revgnss.DistributedLinkCalibrationState, an optional atmosphere variance) via
    % revgnss.ReciprocalTimeTransferCovarianceBuilder, rather than asking every caller to
    % assemble blocks by hand -- relayBlock is always called with [] here, since a direct
    % round-trip has no relay leg by definition. commonSourceGroups is likewise always []-only
    % this stage (Stage 4.2 combined review finding 1): revgnss.CommonSourceCovarianceGroup.
    % sharedCovarianceContribution_m2 is documented as ALWAYS metres^2-domain, but this builder's
    % covarianceBlock is always seconds^2-domain -- wiring a live group in would silently label an
    % m^2 quantity 's^2' (measured live: a 0.3 m common-mode range sigma reported as a 0.3-SECOND
    % timing sigma, wrong by c^2). A real seconds-domain shared-source type is Section 4.5 scope;
    % until it exists, a caller supplying a nonempty commonSourceGroups is refused loudly here
    % rather than silently mislabeled.
    %
    % Every supplied revgnss.DistributedLinkCalibrationState's priorVarianceUnits=='s^2' guard now
    % lives centrally in revgnss.ReciprocalTimeTransferCovarianceBuilder.productCalibrationBlock
    % (Stage 4.2 combined review finding 9) rather than being duplicated here -- a single source of
    % truth a future second caller (Section 4.5) automatically inherits.
    %
    % assembleDirect_ enforces the calibration validity window at the final-reception local tag
    % (Stage 4.2 combined review finding 2): revgnss.CoherentTwoWayCodeRangingModel's own
    % assertValidAt calls were the precedent this path had silently dropped -- a stale/expired
    % calibration product previously constructed a "valid" exchange record with no complaint.
    %
    % legAppliesAtmosphere/atmosphereVariance_s2 consistency is enforced both ways (Stage 4.2
    % combined review finding 3): a leg declared to cross atmosphere must carry a nonempty
    % atmosphere variance, and a leg declared NOT to cross atmosphere must not carry one --
    % previously an ISL exchange could silently carry an unused atmosphere covariance block, and a
    % ground-to-space exchange could silently omit one while still claiming every leg crosses
    % atmosphere. buildFromGroundToSpace's applyAtmosphere option makes the ground-to-space case a
    % real, callable toggle (plan Section 4.3 item 4: "apply atmosphere only to ground-space legs
    % when separately toggled") instead of an unconditional hard-coded true.

    methods (Static)
        function record = buildFromIsl(originAsset, originAssetIdx, originTerminalGeometry, ...
                destinationAsset, destinationAssetIdx, destinationTerminalGeometry, ...
                hardware, t4_s, options)
            arguments
                originAsset
                originAssetIdx (1,1) double
                originTerminalGeometry (1,1) struct
                destinationAsset
                destinationAssetIdx (1,1) double
                destinationTerminalGeometry (1,1) struct
                hardware (1,1) revgnss.ReciprocalLinkHardwareModel
                t4_s (1,1) double
                options.exchangeIdentifier (1,:) char = ''
                options.sessionIdentifier (1,:) char = ''
                options.protocolIdentifier (1,:) char = ''
                options.signalIdentifier (1,:) char = ''
                options.channelIdentifier (1,:) char = ''
                options.carrierFrequency_Hz (1,:) double = []
                options.counterTagSigma_s (1,:) double = []
                options.counterTagLabels (1,:) cell = {}
                options.calibrationStates = []
                options.atmosphereVariance_s2 = []
                options.commonSourceGroups = []
                options.referenceEpochRule (1,:) char = 'finalReception'
                options.qualityFlags (1,1) struct = struct()
                options.truthDiagnosticIdentifier (1,:) char = ''
                options.solverOptions (1,1) struct = struct()
            end
            revgnss.DirectReciprocalTimeTransferBuilder.requireOptions_(options);
            origin = revgnss.ReciprocalEndpointTruthProvider.spacecraft( ...
                originAsset, originAssetIdx, originTerminalGeometry, t4_s);
            destination = revgnss.ReciprocalEndpointTruthProvider.spacecraft( ...
                destinationAsset, destinationAssetIdx, destinationTerminalGeometry, t4_s);
            record = revgnss.DirectReciprocalTimeTransferBuilder.assembleDirect_( ...
                origin, destination, hardware, t4_s, false, options);
        end

        function record = buildFromGroundToSpace(towerTruth_ecef_m, towerClockBiasMeters, ...
                towerClockDriftMetersPerSecond, towerIdentifier, towerTerminalGeometry, ...
                spaceAsset, spaceAssetIdx, spaceTerminalGeometry, hardware, t4_s, options)
            arguments
                towerTruth_ecef_m (3,1) double
                towerClockBiasMeters (1,1) double
                towerClockDriftMetersPerSecond (1,1) double
                towerIdentifier (1,:) char
                towerTerminalGeometry (1,1) struct
                spaceAsset
                spaceAssetIdx (1,1) double
                spaceTerminalGeometry (1,1) struct
                hardware (1,1) revgnss.ReciprocalLinkHardwareModel
                t4_s (1,1) double
                options.exchangeIdentifier (1,:) char = ''
                options.sessionIdentifier (1,:) char = ''
                options.protocolIdentifier (1,:) char = ''
                options.signalIdentifier (1,:) char = ''
                options.channelIdentifier (1,:) char = ''
                options.carrierFrequency_Hz (1,:) double = []
                options.counterTagSigma_s (1,:) double = []
                options.counterTagLabels (1,:) cell = {}
                options.calibrationStates = []
                options.atmosphereVariance_s2 = []
                options.commonSourceGroups = []
                options.applyAtmosphere (1,1) logical = true
                options.referenceEpochRule (1,:) char = 'finalReception'
                options.qualityFlags (1,1) struct = struct()
                options.truthDiagnosticIdentifier (1,:) char = ''
                options.solverOptions (1,1) struct = struct()
            end
            revgnss.DirectReciprocalTimeTransferBuilder.requireOptions_(options);
            origin = revgnss.ReciprocalEndpointTruthProvider.fixedStation( ...
                towerTruth_ecef_m, towerClockBiasMeters, towerClockDriftMetersPerSecond, ...
                towerIdentifier, towerTerminalGeometry, t4_s);
            destination = revgnss.ReciprocalEndpointTruthProvider.spacecraft( ...
                spaceAsset, spaceAssetIdx, spaceTerminalGeometry, t4_s);
            record = revgnss.DirectReciprocalTimeTransferBuilder.assembleDirect_( ...
                origin, destination, hardware, t4_s, options.applyAtmosphere, options);
        end
    end

    methods (Static, Access = private)
        function requireOptions_(options)
            % Stage 4.2 combined review finding 10: these name-value arguments are effectively
            % required, but a MATLAB arguments block with no default raises an opaque
            % MATLAB:nonExistentField error rather than this class's own ClassName:reason
            % identifier convention -- so each is given a sentinel default ('' or []) and checked
            % explicitly here instead.
            required = {'exchangeIdentifier','sessionIdentifier','protocolIdentifier', ...
                'signalIdentifier','channelIdentifier'};
            for k = 1:numel(required)
                if isempty(options.(required{k}))
                    error('DirectReciprocalTimeTransferBuilder:missingRequiredOption', ...
                        '%s is required and was not supplied.',required{k});
                end
            end
            if isempty(options.carrierFrequency_Hz)
                error('DirectReciprocalTimeTransferBuilder:missingRequiredOption', ...
                    'carrierFrequency_Hz is required and was not supplied.');
            end
            if ~(isscalar(options.carrierFrequency_Hz) || numel(options.carrierFrequency_Hz) == 4) || ...
                    any(~isfinite(options.carrierFrequency_Hz)) || any(options.carrierFrequency_Hz <= 0)
                error('DirectReciprocalTimeTransferBuilder:carrierFrequency', ...
                    ['carrierFrequency_Hz must be a finite positive scalar (broadcast to all 4 ' ...
                    'events) or a finite positive 1-by-4 vector (Stage 4.2 combined review ' ...
                    'finding 13 -- this closes the previously-unreachable per-event/leg-' ...
                    'translating-transponder capability the record schema already declares).']);
            end
        end

        function record = assembleDirect_(origin, destination, hardware, t4_s, ...
                appliesAtmosphere, options)
            events = revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip( ...
                origin, destination, hardware, t4_s, options.solverOptions);
            chainEndpoints = {origin.assetIdentifier, destination.assetIdentifier, ...
                destination.assetIdentifier, origin.assetIdentifier};
            tags_s = revgnss.ReciprocalTimestampEventModel.localClockTags(events, ...
                {origin, destination, destination, origin});

            % Calibration validity window, checked at the final-reception local tag (matches
            % referenceEpochRule='finalReception' and revgnss.CoherentTwoWayCodeRangingModel's own
            % precedent of checking assertValidAt against the receive-side tag).
            hardware.assertValidAt(tags_s(4));
            if ~isempty(options.calibrationStates)
                if ~all(arrayfun(@(s) s.coversLocalTag(tags_s(4)),options.calibrationStates))
                    error('DirectReciprocalTimeTransferBuilder:calibrationStateValidity', ...
                        'A supplied DistributedLinkCalibrationState is not valid at the final-reception local tag.');
                end
            end

            if ~isempty(options.commonSourceGroups)
                error('DirectReciprocalTimeTransferBuilder:commonSourceGroupUnits', ...
                    ['commonSourceGroups is not wired into a direct round-trip exchange this ' ...
                    'stage: revgnss.CommonSourceCovarianceGroup.sharedCovarianceContribution_m2 ' ...
                    'is always metres^2-domain, but this builder''s covarianceBlock is always ' ...
                    'seconds^2-domain -- a real seconds-domain shared-source type is Section 4.5 scope.']);
            end
            if appliesAtmosphere && isempty(options.atmosphereVariance_s2)
                error('DirectReciprocalTimeTransferBuilder:atmosphereVarianceRequired', ...
                    'A leg declared to apply atmosphere must supply a nonempty atmosphereVariance_s2.');
            end
            if ~appliesAtmosphere && ~isempty(options.atmosphereVariance_s2)
                error('DirectReciprocalTimeTransferBuilder:atmosphereVarianceNotApplicable', ...
                    'atmosphereVariance_s2 must not be supplied when no leg applies atmosphere (e.g. a pure ISL exchange).');
            end

            covBuilder = revgnss.ReciprocalTimeTransferCovarianceBuilder;
            blocks = { ...
                covBuilder.counterTagNoiseBlock(options.counterTagSigma_s, options.counterTagLabels), ...
                covBuilder.terminalModemDelayBlock(hardware), ...
                covBuilder.productCalibrationBlock(options.calibrationStates), ...
                covBuilder.atmosphereBlock(options.atmosphereVariance_s2), ...
                covBuilder.relayBlock([]), ...
                covBuilder.sessionCommonModeBlock([])};
            [covarianceBlock, componentOrder, ~] = covBuilder.assemble(blocks);

            calibrationProductIds = {};
            if ~isempty(hardware.calibrationProductIdentifier)
                calibrationProductIds{end+1} = hardware.calibrationProductIdentifier;
            end
            if ~isempty(options.calibrationStates)
                calibrationProductIds = [calibrationProductIds, arrayfun( ...
                    @(s) s.calibrationStateIdentifier, options.calibrationStates, ...
                    'UniformOutput', false)];
            end

            if isscalar(options.carrierFrequency_Hz)
                chainFrequency_Hz = repmat(options.carrierFrequency_Hz,1,4);
            else
                chainFrequency_Hz = options.carrierFrequency_Hz;
            end

            record = revgnss.ReciprocalTimestampExchangeRecord(struct( ...
                'exchangeIdentifier', options.exchangeIdentifier, ...
                'sessionIdentifier', options.sessionIdentifier, ...
                'topologyKind', 'directRoundTrip', ...
                'chainEndpointIdentifiers', {chainEndpoints}, ...
                'chainTerminalIdentifiers', {{origin.transmitTerminalIdentifier, ...
                    destination.receiveTerminalIdentifier, destination.transmitTerminalIdentifier, ...
                    origin.receiveTerminalIdentifier}}, ...
                'localClockCompareEndpointIdentifiers', ...
                {{origin.assetIdentifier, destination.assetIdentifier}}, ...
                'referenceEpochRule', options.referenceEpochRule, ...
                'referenceCoordinateEpoch_s', t4_s, ...
                'coordinateTimeEvents_s', [events.t1_s, events.t2_s, events.t3_s, events.t4_s], ...
                'localClockTags_s', tags_s, ...
                'localClockTagAvailable', true(1,4), ...
                'localTimeSystemIdentifiers', {chainEndpoints}, ...
                'protocolIdentifier', options.protocolIdentifier, ...
                'signalIdentifier', options.signalIdentifier, ...
                'channelIdentifier', options.channelIdentifier, ...
                'chainCarrierFrequency_Hz', chainFrequency_Hz, ...
                'legAppliesAtmosphere', repmat(appliesAtmosphere,1,4), ...
                'calibrationProductIdentifiers', {calibrationProductIds}, ...
                'covarianceGroupIdentifiers', {{}}, ...
                'covarianceBlock', covarianceBlock, ...
                'covarianceComponentOrder', {componentOrder}, ...
                'covarianceUnits', 's^2', ...
                'qualityFlags', options.qualityFlags, ...
                'availability', true, ...
                'truthDiagnosticIdentifier', options.truthDiagnosticIdentifier));
        end
    end
end
