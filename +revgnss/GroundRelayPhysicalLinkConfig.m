classdef GroundRelayPhysicalLinkConfig
    % GroundRelayPhysicalLinkConfig  Plan Section 4.5: static, physics-free config-reading utility
    % for the classical relay TWSTFT session processor, reading
    % cfg.measurements.groundRelayTimeTransfer.* -- an entirely separate masterConfig subtree from
    % cfg.measurements.twstft.* (Section 4.1's diagnostic-only, 2-space-asset ISL scaffold --
    % explicitly forbidden from being used as a physical relay-session model) and from
    % cfg.measurements.twoWayTimeTransfer.* (Section 4.4's ground<->ONE-spacecraft direct round
    % trip, no relay). Mirrors revgnss.FourTimestampPhysicalLinkConfig's exact idiom (independently
    % re-implemented numericPath_/textPath_/vectorPath_/walk_ private helpers -- the same
    % controlled-duplication tradeoff that class's own header documents as accepted precedent).
    %
    % requireCompleteSessionConfig is the plan-item-7 gate ("remains disabled unless a complete
    % station-pair/relay session configuration is present"): hard-refuses enable=true with any
    % missing/invalid station-pair or schedule field, a non-unity frequency-translation ratio (no
    % physics exists to apply one -- revgnss.ReciprocalTimestampEventModel is coordinate-time-only
    % and frequency-agnostic), or useInEKF=true (this stage is report-only; no live coordinator
    % path exists to route an EKF update through -- see
    % +revgnss/GroundRelayTimeTransferSessionBuilder.m's own header for why).

    methods (Static)
        function tf = isEnabled(cfg)
            tf = revgnss.GroundRelayPhysicalLinkConfig.getBool_( ...
                cfg,{'measurements','groundRelayTimeTransfer','enable'},false);
        end

        function requireCompleteSessionConfig(cfg)
            if ~revgnss.GroundRelayPhysicalLinkConfig.isEnabled(cfg)
                return
            end
            if revgnss.GroundRelayPhysicalLinkConfig.getBool_( ...
                    cfg,{'measurements','groundRelayTimeTransfer','useInEKF'},false)
                error('GroundRelayPhysicalLinkConfig:useInEKFUnsupported', ...
                    ['measurements.groundRelayTimeTransfer.useInEKF=true is not supported: this ' ...
                    'session processor is report-only this stage, with no live coordinator-routed ' ...
                    'path to apply an EKF update through.']);
            end
            stationA = revgnss.GroundRelayPhysicalLinkConfig.numericPath_( ...
                cfg,{'measurements','groundRelayTimeTransfer','session','stationATowerIndex'},NaN);
            stationB = revgnss.GroundRelayPhysicalLinkConfig.numericPath_( ...
                cfg,{'measurements','groundRelayTimeTransfer','session','stationBTowerIndex'},NaN);
            relayIdx = revgnss.GroundRelayPhysicalLinkConfig.numericPath_( ...
                cfg,{'measurements','groundRelayTimeTransfer','session','relaySpaceAssetIndex'},NaN);
            if ~(isfinite(stationA) && stationA == round(stationA) && stationA >= 1)
                error('GroundRelayPhysicalLinkConfig:stationATowerIndex', ...
                    'measurements.groundRelayTimeTransfer.session.stationATowerIndex must be a positive integer.');
            end
            if ~(isfinite(stationB) && stationB == round(stationB) && stationB >= 1)
                error('GroundRelayPhysicalLinkConfig:stationBTowerIndex', ...
                    'measurements.groundRelayTimeTransfer.session.stationBTowerIndex must be a positive integer.');
            end
            if stationA == stationB
                error('GroundRelayPhysicalLinkConfig:stationPairDistinct', ...
                    'session.stationATowerIndex and session.stationBTowerIndex must be distinct towers.');
            end
            if ~(isfinite(relayIdx) && relayIdx == round(relayIdx) && relayIdx >= 1)
                error('GroundRelayPhysicalLinkConfig:relaySpaceAssetIndex', ...
                    'measurements.groundRelayTimeTransfer.session.relaySpaceAssetIndex must be a positive integer.');
            end
            forward_s = revgnss.GroundRelayPhysicalLinkConfig.numericPath_( ...
                cfg,{'measurements','groundRelayTimeTransfer','schedule','forwardReceptionEpoch_s'},NaN);
            return_s = revgnss.GroundRelayPhysicalLinkConfig.numericPath_( ...
                cfg,{'measurements','groundRelayTimeTransfer','schedule','returnReceptionEpoch_s'},NaN);
            if ~isfinite(forward_s)
                error('GroundRelayPhysicalLinkConfig:forwardReceptionEpoch', ...
                    'measurements.groundRelayTimeTransfer.schedule.forwardReceptionEpoch_s must be a finite scalar.');
            end
            if ~isfinite(return_s)
                error('GroundRelayPhysicalLinkConfig:returnReceptionEpoch', ...
                    'measurements.groundRelayTimeTransfer.schedule.returnReceptionEpoch_s must be a finite scalar.');
            end
            if forward_s == return_s
                error('GroundRelayPhysicalLinkConfig:scheduleEpochsDistinct', ...
                    'schedule.forwardReceptionEpoch_s and schedule.returnReceptionEpoch_s must be distinct.');
            end
            ratio = revgnss.GroundRelayPhysicalLinkConfig.numericPath_( ...
                cfg,{'measurements','groundRelayTimeTransfer','hardware','relayFrequencyTranslationRatio'},1.0);
            if ratio ~= 1.0
                error('GroundRelayPhysicalLinkConfig:relayFrequencyTranslationUnsupported', ...
                    ['measurements.groundRelayTimeTransfer.hardware.relayFrequencyTranslationRatio ' ...
                    'must be exactly 1.0: revgnss.ReciprocalTimestampEventModel is coordinate-time-' ...
                    'only and frequency-agnostic, so no physics exists to apply a translation ratio ' ...
                    'other than unity this stage.']);
            end
            % Combined review m1: every remaining numeric leaf below the top-level session/schedule
            % fields already checked above was previously read through numericPath_/textPath_'s own
            % silent-fallback-to-default behaviour with NO validation at all -- a malformed leaf
            % (wrong shape, non-finite, wrong sign, wrong type) was silently replaced by its default
            % rather than refused. Explicit finiteness/scalar/sign checks below close that gap.
            revgnss.GroundRelayPhysicalLinkConfig.requireFiniteHardwareLeaves_(cfg);
            revgnss.GroundRelayPhysicalLinkConfig.requireFiniteTruthLeaves_(cfg);
            revgnss.GroundRelayPhysicalLinkConfig.requireFiniteCounterTagLeaves_(cfg);
            revgnss.GroundRelayPhysicalLinkConfig.requireFiniteAtmosphereLeaves_(cfg);
        end

        function geometry = terminalGeometry(cfg, role)
            % terminalGeometry  role in {'stationA','stationB','relay'}. Translates the LONG
            % masterConfig names (transmitPhaseCentreOffset_body_m/receivePhaseCentreOffset_body_m)
            % into the SHORT names revgnss.ReciprocalEndpointTruthProvider.fixedStation/.spacecraft
            % hard-require (transmitOffset_body_m/receiveOffset_body_m + 4 identifier fields) --
            % the same translation revgnss.FourTimestampPhysicalLinkConfig.
            % shortNameGroundSpaceTerminalGeometry performs, independently re-implemented here
            % since that method is keyed to the twoWayTimeTransfer.fourTimestampPhysical config
            % root, not this subsystem's own root.
            if ~(ischar(role) && any(strcmp(role,{'stationA','stationB','relay'})))
                error('GroundRelayPhysicalLinkConfig:role', ...
                    'role must be ''stationA'', ''stationB'', or ''relay''.');
            end
            root = {'measurements','groundRelayTimeTransfer','terminalGeometry',role};
            txOffset = revgnss.GroundRelayPhysicalLinkConfig.vectorPath_( ...
                cfg,[root,{'transmitPhaseCentreOffset_body_m'}],[]);
            rxOffset = revgnss.GroundRelayPhysicalLinkConfig.vectorPath_( ...
                cfg,[root,{'receivePhaseCentreOffset_body_m'}],[]);
            if ~(isnumeric(txOffset) && numel(txOffset) == 3 && all(isfinite(txOffset(:))) && ...
                    isnumeric(rxOffset) && numel(rxOffset) == 3 && all(isfinite(rxOffset(:))))
                error('GroundRelayPhysicalLinkConfig:terminalGeometry', ...
                    '%s transmit and receive phase-centre offsets must be finite 3-vectors.',role);
            end
            geometry = struct( ...
                'transmitOffset_body_m',txOffset(:), ...
                'receiveOffset_body_m',rxOffset(:), ...
                'transmitTerminalIdentifier',sprintf('ground-relay:%s:transmit-terminal',role), ...
                'receiveTerminalIdentifier',sprintf('ground-relay:%s:receive-terminal',role), ...
                'transmitAntennaIdentifier',sprintf('ground-relay:%s:aperture',role), ...
                'receiveAntennaIdentifier',sprintf('ground-relay:%s:aperture',role));
        end

        function hw = hardwareModel(cfg, parameterSource)
            % hardwareModel  parameterSource in {'physicalTruth','calibrationProduct'}.
            % physicalTruth folds truth.*Error_s additive offsets into the nominal hardware
            % values -- matches revgnss.FourTimestampPhysicalLinkConfig.hardwareModel's own
            % established truth/calibration split exactly.
            if ~(ischar(parameterSource) && ...
                    any(strcmp(parameterSource,{'physicalTruth','calibrationProduct'})))
                error('GroundRelayPhysicalLinkConfig:parameterSource', ...
                    'parameterSource must be ''physicalTruth'' or ''calibrationProduct''.');
            end
            root = {'measurements','groundRelayTimeTransfer','hardware'};
            get = @(leaf,def) revgnss.GroundRelayPhysicalLinkConfig.numericPath_(cfg,[root,leaf],def);

            stationATx_s = get({'stationATransmitDelay_s'},0);
            stationARx_s = get({'stationAReceiveDelay_s'},0);
            stationBTx_s = get({'stationBTransmitDelay_s'},0);
            stationBRx_s = get({'stationBReceiveDelay_s'},0);
            relayNominal_s = get({'relayGroupDelayNominal_s'},1e-3);
            relayAsymmetry_s = get({'relayGroupDelayAsymmetry_s'},0);
            translationRatio = get({'relayFrequencyTranslationRatio'},1.0);
            oscillatorId = revgnss.GroundRelayPhysicalLinkConfig.textPath_( ...
                cfg,[root,{'relayOscillatorStateIdentifier'}],'ground-relay-oscillator');
            chainId = revgnss.GroundRelayPhysicalLinkConfig.textPath_( ...
                cfg,[root,{'physicalChainIdentifier'}],'ground-relay-twstft-chain');
            calibId = revgnss.GroundRelayPhysicalLinkConfig.textPath_( ...
                cfg,[root,{'calibrationProductIdentifier'}],'ground-relay-twstft-calibration');
            validFrom_s = get({'validFromLocalTag_s'},-Inf);
            validUntil_s = get({'validUntilLocalTag_s'},Inf);

            if strcmp(parameterSource,'physicalTruth')
                truthRoot = {'measurements','groundRelayTimeTransfer','truth'};
                getTruth = @(leaf) revgnss.GroundRelayPhysicalLinkConfig.numericPath_( ...
                    cfg,[truthRoot,leaf],0);
                stationATx_s = stationATx_s + getTruth({'stationATransmitDelayError_s'});
                stationARx_s = stationARx_s + getTruth({'stationAReceiveDelayError_s'});
                stationBTx_s = stationBTx_s + getTruth({'stationBTransmitDelayError_s'});
                stationBRx_s = stationBRx_s + getTruth({'stationBReceiveDelayError_s'});
                relayNominal_s = relayNominal_s + getTruth({'relayGroupDelayError_s'});
            end

            hw = revgnss.GroundRelaySessionHardwareModel( ...
                'parameterSource',parameterSource, ...
                'physicalChainIdentifier',chainId, ...
                'calibrationProductIdentifier',calibId, ...
                'stationATransmitDelay_s',stationATx_s, ...
                'stationAReceiveDelay_s',stationARx_s, ...
                'stationBTransmitDelay_s',stationBTx_s, ...
                'stationBReceiveDelay_s',stationBRx_s, ...
                'relayGroupDelayNominal_s',relayNominal_s, ...
                'relayGroupDelayAsymmetry_s',relayAsymmetry_s, ...
                'relayFrequencyTranslationRatio',translationRatio, ...
                'relayOscillatorStateIdentifier',oscillatorId, ...
                'validFromLocalTag_s',validFrom_s,'validUntilLocalTag_s',validUntil_s);
        end

        function groups = sessionCommonGroups(cfg)
            % sessionCommonGroups  Builds the array of revgnss.GroundRelaySessionCommonCovarianceGroup
            % from measurements.groundRelayTimeTransfer.sessionCommonCovariance.* -- all-zero-sigma
            % by default (golden-safe; a zero-sigma group still contributes a real, correctly-shaped
            % zero row, never a fabricated nonzero value).
            root = {'measurements','groundRelayTimeTransfer','sessionCommonCovariance'};
            get = @(leaf,def) revgnss.GroundRelayPhysicalLinkConfig.numericPath_(cfg,[root,leaf],def);
            getText = @(leaf,def) revgnss.GroundRelayPhysicalLinkConfig.textPath_(cfg,[root,leaf],def);

            names = {'relayGroupDelay','stationATerminalDelay','stationBTerminalDelay','sharedAtmosphere'};
            sigmaLeaves = {{'relayGroupDelaySigma_s'},{'stationATerminalSigma_s'}, ...
                {'stationBTerminalSigma_s'},{'atmosphereSigma_s'}};
            % modelLeaves only has real entries for relayGroupDelay/sharedAtmosphere -- stationA/
            % stationB terminal delay leaves declare only a correlation time (temporal model is
            % fixed firstOrderGaussMarkov for both; no separate *TemporalModel leaf exists for
            % those two sources). Combined review m3: an earlier cut pointed the stationA/stationB
            % entries at the CorrelationTime leaf names too (dead, misleading -- the branch below
            % never reads them); left {} here instead so there is nothing to misread.
            modelLeaves = {{'relayGroupDelayTemporalModel'},{},{},{'atmosphereTemporalModel'}};
            correlationLeaves = {{'relayGroupDelayCorrelationTime_s'},{'stationATerminalCorrelationTime_s'}, ...
                {'stationBTerminalCorrelationTime_s'},{'atmosphereCorrelationTime_s'}};
            defaultModels = {'firstOrderGaussMarkov','firstOrderGaussMarkov','firstOrderGaussMarkov', ...
                'firstOrderGaussMarkov'};

            groups = revgnss.GroundRelaySessionCommonCovarianceGroup.empty(1,0);
            for k = 1:numel(names)
                sigma_s = get(sigmaLeaves{k},0);
                if ~(isfinite(sigma_s) && sigma_s >= 0)
                    % Combined review m2: sigma_s < 0 was previously silently squared into a valid-
                    % looking but WRONG positive variance rather than refused.
                    error('GroundRelayPhysicalLinkConfig:sessionCommonCovarianceSigma', ...
                        'sessionCommonCovariance.%s must be a finite, nonnegative scalar.',sigmaLeaves{k}{1});
                end
                if sigma_s == 0
                    continue % A zero-declared source contributes nothing -- omitted, not a fake zero-variance group.
                end
                if strcmp(names{k},'relayGroupDelay') || strcmp(names{k},'sharedAtmosphere')
                    temporalModel = getText(modelLeaves{k},defaultModels{k});
                else
                    temporalModel = defaultModels{k};
                end
                correlationTime_s = get(correlationLeaves{k},1e9);
                groups(end+1) = revgnss.GroundRelaySessionCommonCovarianceGroup(struct( ...
                    'covarianceGroupIdentifier',sprintf('ground-relay-session:%s',names{k}), ...
                    'commonSourceName',names{k}, ...
                    'sharedCovarianceContribution_s2',sigma_s^2, ...
                    'memberRowCount',1, ...
                    'temporalCovarianceModel',temporalModel, ...
                    'correlationTime_s',correlationTime_s, ...
                    'validFromEpoch_s',-1e12,'validUntilEpoch_s',1e12)); %#ok<AGROW>
            end
        end
    end

    methods (Static, Access = private)
        function requireFiniteHardwareLeaves_(cfg)
            root = {'measurements','groundRelayTimeTransfer','hardware'};
            get = @(leaf,def) revgnss.GroundRelayPhysicalLinkConfig.numericPath_(cfg,[root,leaf],def);
            delayLeaves = {'stationATransmitDelay_s','stationAReceiveDelay_s', ...
                'stationBTransmitDelay_s','stationBReceiveDelay_s','relayGroupDelayNominal_s'};
            for k = 1:numel(delayLeaves)
                v = get({delayLeaves{k}},NaN);
                if ~(isfinite(v) && v >= 0)
                    error('GroundRelayPhysicalLinkConfig:hardwareDelay', ...
                        'hardware.%s must be a finite nonnegative scalar.',delayLeaves{k});
                end
            end
            asymmetry_s = get({'relayGroupDelayAsymmetry_s'},NaN);
            if ~isfinite(asymmetry_s)
                error('GroundRelayPhysicalLinkConfig:hardwareDelay', ...
                    'hardware.relayGroupDelayAsymmetry_s must be finite.');
            end
            validFrom_s = get({'validFromLocalTag_s'},-Inf);
            validUntil_s = get({'validUntilLocalTag_s'},Inf);
            if ~(validFrom_s <= validUntil_s)
                error('GroundRelayPhysicalLinkConfig:hardwareValidityWindow', ...
                    'hardware.validFromLocalTag_s must be <= hardware.validUntilLocalTag_s.');
            end
        end

        function requireFiniteTruthLeaves_(cfg)
            root = {'measurements','groundRelayTimeTransfer','truth'};
            get = @(leaf,def) revgnss.GroundRelayPhysicalLinkConfig.numericPath_(cfg,[root,leaf],def);
            errorLeaves = {'stationATransmitDelayError_s','stationAReceiveDelayError_s', ...
                'stationBTransmitDelayError_s','stationBReceiveDelayError_s','relayGroupDelayError_s'};
            for k = 1:numel(errorLeaves)
                v = get({errorLeaves{k}},NaN);
                if ~isfinite(v)
                    error('GroundRelayPhysicalLinkConfig:truthDelayError', ...
                        'truth.%s must be a finite scalar.',errorLeaves{k});
                end
            end
        end

        function requireFiniteCounterTagLeaves_(cfg)
            root = {'measurements','groundRelayTimeTransfer','counterTag'};
            sigma_s = revgnss.GroundRelayPhysicalLinkConfig.vectorPath_(cfg,[root,{'sigma_s'}],[]);
            if ~(isnumeric(sigma_s) && isvector(sigma_s) && all(isfinite(sigma_s)) && all(sigma_s >= 0))
                error('GroundRelayPhysicalLinkConfig:counterTagSigma', ...
                    'counterTag.sigma_s must be a finite, nonnegative numeric vector.');
            end
            labels = revgnss.GroundRelayPhysicalLinkConfig.walk_(cfg,[root,{'labels'}],{});
            if ~(iscell(labels) && numel(labels) == numel(sigma_s) && ...
                    all(cellfun(@(l) ischar(l) || isstring(l),labels)))
                error('GroundRelayPhysicalLinkConfig:counterTagLabels', ...
                    'counterTag.labels must be a cell array of text with one entry per counterTag.sigma_s component.');
            end
        end

        function requireFiniteAtmosphereLeaves_(cfg)
            root = {'measurements','groundRelayTimeTransfer','atmosphere'};
            f_L1_Hz = revgnss.GroundRelayPhysicalLinkConfig.numericPath_(cfg,[root,{'f_L1ReferenceHz'}],NaN);
            if ~(isfinite(f_L1_Hz) && f_L1_Hz > 0)
                error('GroundRelayPhysicalLinkConfig:atmosphereReferenceFrequency', ...
                    'atmosphere.f_L1ReferenceHz must be a finite positive scalar.');
            end
            % Combined review m10: perLegResidualVariance_s2 is indexed positionally (element 1/2)
            % by revgnss.GroundRelayTimeTransferSessionBuilder.groundSpaceAtmosphere_ with no
            % validation of its own -- a scalar or empty override previously produced a raw MATLAB
            % subscript error deep inside that method rather than a clear refusal here.
            perLeg_s2 = revgnss.GroundRelayPhysicalLinkConfig.vectorPath_( ...
                cfg,[root,{'perLegResidualVariance_s2'}],[]);
            if ~(isnumeric(perLeg_s2) && numel(perLeg_s2) == 2 && all(isfinite(perLeg_s2)) && ...
                    all(perLeg_s2 >= 0))
                error('GroundRelayPhysicalLinkConfig:atmospherePerLegVariance', ...
                    'atmosphere.perLegResidualVariance_s2 must be a finite, nonnegative 1-by-2 vector.');
            end
        end

        function value = numericPath_(cfg, path, defaultValue)
            value = revgnss.GroundRelayPhysicalLinkConfig.walk_(cfg,path,defaultValue);
            if ~isnumeric(value) || ~isscalar(value); value = defaultValue; end
        end

        function value = textPath_(cfg, path, defaultValue)
            value = revgnss.GroundRelayPhysicalLinkConfig.walk_(cfg,path,defaultValue);
            if ~(ischar(value) || (isstring(value) && isscalar(value))); value = defaultValue; end
            value = char(value);
        end

        function value = vectorPath_(cfg, path, defaultValue)
            value = revgnss.GroundRelayPhysicalLinkConfig.walk_(cfg,path,defaultValue);
        end

        function tf = getBool_(cfg, path, defaultValue)
            value = revgnss.GroundRelayPhysicalLinkConfig.walk_(cfg,path,defaultValue);
            tf = islogical(value) && isscalar(value) && value;
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
