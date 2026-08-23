classdef FourTimestampPhysicalLinkConfig
    % FourTimestampPhysicalLinkConfig  Plan Section 4.4: shared, physics-free config-reading
    % utility for BOTH the ISL and ground-space four-timestamp hosts. Two concerns:
    %
    %   hardwareModel               Builds a revgnss.ReciprocalLinkHardwareModel from the
    %                                fourTimestampPhysical.hardware.* config leaf, folding in
    %                                truth-only additive error (parameterSource='physicalTruth')
    %                                or leaving it clean (parameterSource='calibrationProduct').
    %   shortNameIslTerminalGeometry / shortNameGroundSpaceTerminalGeometry
    %                                Translate this project's LONG terminal-geometry field names
    %                                (transmitPhaseCentreOffset_body_m/receivePhaseCentreOffset_
    %                                body_m -- config/masterConfig.m's own convention, and the
    %                                ONLY legal revgnss.CommunicationEndpointState.terminalGeometry
    %                                shape, +revgnss/CommunicationEndpointState.m:224-227) into
    %                                the SHORT names revgnss.ReciprocalEndpointTruthProvider.
    %                                spacecraft/fixedStation hard-require (transmitOffset_body_m/
    %                                receiveOffset_body_m, +revgnss/ReciprocalEndpointTruthProvider.
    %                                m:41-46,70-75) -- confirmed by direct read these are genuinely
    %                                different, non-interchangeable field names, not a documentation
    %                                inconsistency. Mirrors
    %                                revgnss.TwoWayISLMeasurementBuilder.terminalGeometry_'s own
    %                                translation (private to that class, so duplicated here rather
    %                                than called through -- the same controlled-duplication
    %                                tradeoff this plan has accepted repeatedly, e.g. revgnss.
    %                                FourTimestampObservableLinearization's duplication of
    %                                revgnss.CoherentTwoWayRangeLinkUpdateAdapter's private
    %                                perturbation helpers). Estimate-side calls
    %                                (revgnss.FourTimestampEstimatorEndpointBridge.
    %                                fromAssetStateBlock/fromTowerBroadcastProduct/
    %                                fromCommunicationEndpointState) never need translation: they
    %                                already want the long names this class's masterConfig leaves
    %                                and revgnss.IndependentFleetCoordinator's own
    %                                terminalGeometryFrom*Record_ helpers already produce.

    methods (Static)
        function hw = hardwareModel(cfg, hostRoot, parameterSource)
            % hardwareModel  hostRoot in {'isl','groundSpace'} selects which
            % fourTimestampPhysical.hardware.*/truth.*/calibration.* subtree to read.
            % parameterSource in {'physicalTruth','calibrationProduct'}: physicalTruth folds the
            % declared truth.*Error_s additive bias into the nominal hardware.*Delay_s values
            % (matching the established truth/estimate-separation convention -- the declared error
            % is a TRUTH-SIDE-ONLY additive offset from the nominal, never itself estimated);
            % calibrationProduct returns the plain nominal hardware.*Delay_s values with an
            % explicitly empty calibrationCovariance_s2 (item 5's guard forces
            % calibration.turnaroundSigma_s/terminalSigma_s to zero, so a nonzero
            % calibrationCovariance_s2 here would be unreachable regardless).
            if ~(ischar(hostRoot) && any(strcmp(hostRoot,{'isl','groundSpace'})))
                error('FourTimestampPhysicalLinkConfig:hostRoot', ...
                    'hostRoot must be ''isl'' or ''groundSpace''.');
            end
            if ~(ischar(parameterSource) && ...
                    any(strcmp(parameterSource,{'physicalTruth','calibrationProduct'})))
                error('FourTimestampPhysicalLinkConfig:parameterSource', ...
                    'parameterSource must be ''physicalTruth'' or ''calibrationProduct''.');
            end
            root = revgnss.FourTimestampPhysicalLinkConfig.rootPath_(hostRoot);

            turnaroundProperTime_s = revgnss.FourTimestampPhysicalLinkConfig.numericPath_( ...
                cfg,[root,{'hardware','turnaroundProperTime_s'}],1e-3);
            originDelay_s = revgnss.FourTimestampPhysicalLinkConfig.numericPath_( ...
                cfg,[root,{'hardware','originTerminalGroupDelay_s'}],0);
            anchorDelay_s = revgnss.FourTimestampPhysicalLinkConfig.numericPath_( ...
                cfg,[root,{'hardware','anchorTerminalGroupDelay_s'}],0);
            physicalChainIdentifier = revgnss.FourTimestampPhysicalLinkConfig.textPath_( ...
                cfg,[root,{'hardware','physicalChainIdentifier'}],'four-timestamp-chain');
            calibrationProductIdentifier = revgnss.FourTimestampPhysicalLinkConfig.textPath_( ...
                cfg,[root,{'hardware','calibrationProductIdentifier'}],'four-timestamp-calibration');
            validFrom_s = revgnss.FourTimestampPhysicalLinkConfig.numericPath_( ...
                cfg,[root,{'hardware','validFromLocalTag_s'}],-Inf);
            validUntil_s = revgnss.FourTimestampPhysicalLinkConfig.numericPath_( ...
                cfg,[root,{'hardware','validUntilLocalTag_s'}],Inf);

            if strcmp(parameterSource,'physicalTruth')
                % Combined-review M2: truth.originTerminalCalibrationError_s/
                % anchorTerminalCalibrationError_s (renamed from turnaround/terminal) -- named for
                % which HARDWARE TERMINAL DELAY each perturbs, not "turnaround": a genuine
                % turnaroundProperTime_s error is inert for this observable (t3/t4 shift together
                % and cancel), so the old turnaroundCalibrationError_s name described something
                % this leaf never did.
                originDelay_s = originDelay_s + revgnss.FourTimestampPhysicalLinkConfig.numericPath_( ...
                    cfg,[root,{'truth','originTerminalCalibrationError_s'}],0);
                anchorDelay_s = anchorDelay_s + revgnss.FourTimestampPhysicalLinkConfig.numericPath_( ...
                    cfg,[root,{'truth','anchorTerminalCalibrationError_s'}],0);
                hw = revgnss.ReciprocalLinkHardwareModel( ...
                    'parameterSource','physicalTruth', ...
                    'physicalChainIdentifier',physicalChainIdentifier, ...
                    'calibrationProductIdentifier',calibrationProductIdentifier, ...
                    'turnaroundProperTime_s',turnaroundProperTime_s, ...
                    'originTerminalGroupDelay_s',originDelay_s, ...
                    'anchorTerminalGroupDelay_s',anchorDelay_s, ...
                    'validFromLocalTag_s',validFrom_s,'validUntilLocalTag_s',validUntil_s);
            else
                hw = revgnss.ReciprocalLinkHardwareModel( ...
                    'parameterSource','calibrationProduct', ...
                    'physicalChainIdentifier',physicalChainIdentifier, ...
                    'calibrationProductIdentifier',calibrationProductIdentifier, ...
                    'turnaroundProperTime_s',turnaroundProperTime_s, ...
                    'originTerminalGroupDelay_s',originDelay_s, ...
                    'anchorTerminalGroupDelay_s',anchorDelay_s, ...
                    'validFromLocalTag_s',validFrom_s,'validUntilLocalTag_s',validUntil_s);
            end
        end

        function short = shortNameIslTerminalGeometry(cfg, assetIdx)
            % shortNameIslTerminalGeometry  Reuses cfg.measurements.isl.twoWay.terminalGeometry.*
            % VERBATIM (item 4: no new ISL terminal-geometry leaf declared for this observable),
            % mirroring revgnss.TwoWayISLMeasurementBuilder.terminalGeometry_'s own translation.
            txOffset = revgnss.FourTimestampPhysicalLinkConfig.vectorPath_( ...
                cfg,{'measurements','isl','twoWay','terminalGeometry', ...
                'transmitPhaseCentreOffset_body_m'},[]);
            rxOffset = revgnss.FourTimestampPhysicalLinkConfig.vectorPath_( ...
                cfg,{'measurements','isl','twoWay','terminalGeometry', ...
                'receivePhaseCentreOffset_body_m'},[]);
            if ~(isnumeric(txOffset) && numel(txOffset) == 3 && all(isfinite(txOffset(:))) && ...
                    isnumeric(rxOffset) && numel(rxOffset) == 3 && all(isfinite(rxOffset(:))))
                error('FourTimestampPhysicalLinkConfig:islTerminalGeometry', ...
                    'ISL transmit and receive phase-centre offsets must be finite 3-vectors.');
            end
            chain = revgnss.FourTimestampPhysicalLinkConfig.textPath_( ...
                cfg,{'measurements','isl','twoWay','physicalChainIdentifier'}, ...
                'isl-two-way-code-chain');
            short = struct( ...
                'transmitOffset_body_m',txOffset(:), ...
                'receiveOffset_body_m',rxOffset(:), ...
                'transmitTerminalIdentifier',sprintf('%s:asset-%d:transmit-terminal',chain,assetIdx), ...
                'receiveTerminalIdentifier',sprintf('%s:asset-%d:receive-terminal',chain,assetIdx), ...
                'transmitAntennaIdentifier',sprintf('%s:asset-%d:four-timestamp-aperture',chain,assetIdx), ...
                'receiveAntennaIdentifier',sprintf('%s:asset-%d:four-timestamp-aperture',chain,assetIdx));
        end

        function short = shortNameGroundSpaceTerminalGeometry(cfg, endpointKind, identifier)
            % shortNameGroundSpaceTerminalGeometry  endpointKind in {'tower','spacecraft'}; reads
            % cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.towerTerminalGeometry.*  /
            % .spacecraftTerminalGeometry.*  (long names, config/masterConfig.m) and emits the
            % SHORT-name struct revgnss.ReciprocalEndpointTruthProvider.fixedStation/.spacecraft
            % require.
            if ~(ischar(endpointKind) && any(strcmp(endpointKind,{'tower','spacecraft'})))
                error('FourTimestampPhysicalLinkConfig:endpointKind', ...
                    'endpointKind must be ''tower'' or ''spacecraft''.');
            end
            leaf = 'towerTerminalGeometry';
            if strcmp(endpointKind,'spacecraft'); leaf = 'spacecraftTerminalGeometry'; end
            txOffset = revgnss.FourTimestampPhysicalLinkConfig.vectorPath_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical',leaf, ...
                'transmitPhaseCentreOffset_body_m'},[]);
            rxOffset = revgnss.FourTimestampPhysicalLinkConfig.vectorPath_( ...
                cfg,{'measurements','twoWayTimeTransfer','fourTimestampPhysical',leaf, ...
                'receivePhaseCentreOffset_body_m'},[]);
            if ~(isnumeric(txOffset) && numel(txOffset) == 3 && all(isfinite(txOffset(:))) && ...
                    isnumeric(rxOffset) && numel(rxOffset) == 3 && all(isfinite(rxOffset(:))))
                error('FourTimestampPhysicalLinkConfig:groundSpaceTerminalGeometry', ...
                    'Ground-space transmit and receive phase-centre offsets must be finite 3-vectors.');
            end
            short = struct( ...
                'transmitOffset_body_m',txOffset(:), ...
                'receiveOffset_body_m',rxOffset(:), ...
                'transmitTerminalIdentifier',sprintf('%s:transmit-terminal',identifier), ...
                'receiveTerminalIdentifier',sprintf('%s:receive-terminal',identifier), ...
                'transmitAntennaIdentifier',sprintf('%s:four-timestamp-aperture',identifier), ...
                'receiveAntennaIdentifier',sprintf('%s:four-timestamp-aperture',identifier));
        end
    end

    methods (Static, Access = private)
        function root = rootPath_(hostRoot)
            if strcmp(hostRoot,'isl')
                root = {'measurements','isl','twoWay','fourTimestampPhysical'};
            else
                root = {'measurements','twoWayTimeTransfer','fourTimestampPhysical'};
            end
        end

        function value = numericPath_(cfg, path, defaultValue)
            value = revgnss.FourTimestampPhysicalLinkConfig.walk_(cfg,path,defaultValue);
            if ~isnumeric(value) || ~isscalar(value); value = defaultValue; end
        end

        function value = textPath_(cfg, path, defaultValue)
            value = revgnss.FourTimestampPhysicalLinkConfig.walk_(cfg,path,defaultValue);
            if ~(ischar(value) || (isstring(value) && isscalar(value))); value = defaultValue; end
            value = char(value);
        end

        function value = vectorPath_(cfg, path, defaultValue)
            value = revgnss.FourTimestampPhysicalLinkConfig.walk_(cfg,path,defaultValue);
        end

        function value = walk_(cfg, path, defaultValue)
            value = cfg;
            for index = 1:numel(path)
                if isstruct(value) && isfield(value,path{index})
                    value = value.(path{index});
                else
                    value = defaultValue;
                    return
                end
            end
        end
    end
end
