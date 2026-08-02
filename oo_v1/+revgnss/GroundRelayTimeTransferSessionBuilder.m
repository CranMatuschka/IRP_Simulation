classdef GroundRelayTimeTransferSessionBuilder
    % GroundRelayTimeTransferSessionBuilder  Plan Section 4.5 top-level orchestrator: builds ONE
    % revgnss.GroundRelaySessionClockDifferenceObservable for a classical relay TWSTFT session
    % (station A -> relay S -> station B, and station B -> relay S -> station A) from masterConfig
    % plus truth-side station/relay state, using ONLY unmodified Section 4.2 physics
    % (revgnss.ReciprocalTimestampEventModel.solveRelayTransit, revgnss.
    % ReciprocalEndpointTruthProvider.fixedStation/.spacecraft, revgnss.
    % ReciprocalTimeTransferCovarianceBuilder) plus the six new Section 4.5 classes.
    %
    % Report-only this stage: no live coordinator-routed call site exists
    % (revgnss.IndependentFleetCoordinator/revgnss.DistributedLinkUpdateAdapter have no
    % ground-station-pair dimension, and this design does not widen that frozen vocabulary --
    % revgnss.GroundRelayPhysicalLinkConfig.requireCompleteSessionConfig hard-refuses useInEKF=true
    % for exactly this reason). Only reachable from this class's own tests this stage.
    %
    % buildSession itself refuses (combined review B2 -- an un-reviewed first cut relied only on
    % requireCompleteSessionConfig, which is a documented no-op while enable=false, so a disabled
    % config with the rest of the subtree left populated silently built a real observable and
    % silently skipped every hard refusal below it) unless
    % revgnss.GroundRelayPhysicalLinkConfig.isEnabled(cfg) is true -- checked as the literal first
    % statement, before requireCompleteSessionConfig.
    %
    % revgnss.ReciprocalEndpointTruthProvider.relay() is NOT used and NOT modified: .spacecraft()
    % is already fully generic over any asset with r_ecef_m/v_ecef_mps/attitude_euler_rad/
    % clock.getBiasMeters()/getDriftMetersPerSecond() -- exactly what a bent-pipe relay satellite
    % is (confirmed by direct read during design). tests/test_reciprocal_endpoint_truth_provider.m
    % stays untouched: relay() still throws relayNotImplemented, still zero callers.
    %
    % Truth/estimator separation, end to end: stationA/stationB/relay are built with
    % 'physicalTruth' throughout. TWO hardware objects are built (combined review M4): hardwareTruth
    % (parameterSource='physicalTruth', folds truth.*DelayError_s -- what really happened
    % physically) drives BOTH the event solver (asEventSolverHardware) and one half of
    % revgnss.GroundRelaySessionObservableBuilder.combine's net station-delay correction;
    % hardwareCalibration (parameterSource='calibrationProduct', nominal only) drives the other
    % half -- see that method's own header for why this makes a perfectly-known, fully-compensated
    % delay correctly produce zero bias. Both are verified automatically by solveEventChain_'s own
    % assertParameterSource('physicalTruth') (unmodified Section 4.2 guard) and combine's own
    % assertParameterSource('physicalTruth')/('calibrationProduct') checks.
    % environmentModel.getTropDelay/getIonoDelay are called with 'truth' at exactly one call site
    % (groundSpaceAtmosphere_). There is no 'model' path anywhere in this deliverable -- no place a
    % truth/estimate mix could silently occur.
    %
    % Input contract for stationATowerTruth/stationBTowerTruth (this builder's own, since neither
    % is an existing shipped type): a struct/object with r_ecef_m (3x1, m), clockBiasMeters
    % (scalar), clockDriftMetersPerSecond (scalar), identifier (char) -- exactly the four fields
    % revgnss.ReciprocalEndpointTruthProvider.fixedStation's own positional arguments need.
    % relayAssetTruth: r_ecef_m (3x1, m, evaluated AT t4Forward_s by convention), v_ecef_mps (3x1,
    % m/s), attitude_euler_rad (3x1, rad), clock.getBiasMeters()/.getDriftMetersPerSecond() --
    % exactly revgnss.ReciprocalEndpointTruthProvider.spacecraft's own asset contract.

    methods (Static)
        function observable = buildSession(cfg, stationATowerTruth, stationBTowerTruth, ...
                relayAssetTruth, environmentModel)
            if ~revgnss.GroundRelayPhysicalLinkConfig.isEnabled(cfg)
                error('GroundRelayTimeTransferSessionBuilder:disabled', ...
                    ['buildSession requires measurements.groundRelayTimeTransfer.enable=true; ' ...
                    'this session processor is fully inert while disabled (combined review B2).']);
            end
            revgnss.GroundRelayPhysicalLinkConfig.requireCompleteSessionConfig(cfg);

            stationAGeom = revgnss.GroundRelayPhysicalLinkConfig.terminalGeometry(cfg,'stationA');
            stationBGeom = revgnss.GroundRelayPhysicalLinkConfig.terminalGeometry(cfg,'stationB');
            relayGeom = revgnss.GroundRelayPhysicalLinkConfig.terminalGeometry(cfg,'relay');
            hardwareTruth = revgnss.GroundRelayPhysicalLinkConfig.hardwareModel(cfg,'physicalTruth');
            hardwareCalibration = revgnss.GroundRelayPhysicalLinkConfig.hardwareModel(cfg,'calibrationProduct');

            t4Forward_s = cfg.measurements.groundRelayTimeTransfer.schedule.forwardReceptionEpoch_s;
            t4Return_s = cfg.measurements.groundRelayTimeTransfer.schedule.returnReceptionEpoch_s;
            relaySpaceAssetIndex = cfg.measurements.groundRelayTimeTransfer.session.relaySpaceAssetIndex;

            % Unmodified Section 4.2 factories, all three endpoints constructed ONCE and reused
            % across both solveRelayTransit calls (a single truth realization for the whole
            % session, matching how their affine position/clock models are designed to be
            % evaluated at arbitrary coordinate time):
            stationA = revgnss.ReciprocalEndpointTruthProvider.fixedStation( ...
                stationATowerTruth.r_ecef_m, stationATowerTruth.clockBiasMeters, ...
                stationATowerTruth.clockDriftMetersPerSecond, stationATowerTruth.identifier, ...
                stationAGeom, t4Forward_s);
            stationB = revgnss.ReciprocalEndpointTruthProvider.fixedStation( ...
                stationBTowerTruth.r_ecef_m, stationBTowerTruth.clockBiasMeters, ...
                stationBTowerTruth.clockDriftMetersPerSecond, stationBTowerTruth.identifier, ...
                stationBGeom, t4Forward_s);
            relay = revgnss.ReciprocalEndpointTruthProvider.spacecraft( ...
                relayAssetTruth, relaySpaceAssetIndex, relayGeom, t4Forward_s);

            hwForward = hardwareTruth.asEventSolverHardware('forward');
            hwReturn = hardwareTruth.asEventSolverHardware('return');

            solverOptions = struct( ...
                'lightTimeTolerance_s',cfg.measurements.groundRelayTimeTransfer.solverOptions.lightTimeTolerance_s, ...
                'maximumIterations',cfg.measurements.groundRelayTimeTransfer.solverOptions.maximumIterations);

            [atmoLegVarAS_s2, atmoLegVarSB_s2, atmoDelayForward_s, atmoDelayReturn_s] = ...
                revgnss.GroundRelayTimeTransferSessionBuilder.groundSpaceAtmosphere_( ...
                cfg, environmentModel, stationATowerTruth, stationBTowerTruth, relay, ...
                t4Forward_s, t4Return_s);
            atmosphereEnabled = revgnss.GroundRelayTimeTransferSessionBuilder.atmosphereEnabled_(cfg);
            if atmosphereEnabled
                atmoLegVariance_s2 = [atmoLegVarAS_s2, atmoLegVarSB_s2];
            else
                atmoLegVariance_s2 = [];
            end

            session = cfg.measurements.groundRelayTimeTransfer.session;
            recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
                stationA, relay, stationB, hwForward, t4Forward_s, ...
                atmoLegVariance_s2, ...
                exchangeIdentifier=sprintf('%s:forward',session.sessionIdentifier), ...
                sessionIdentifier=session.sessionIdentifier, ...
                protocolIdentifier=session.protocolIdentifier, ...
                signalIdentifier=session.signalIdentifier, ...
                channelIdentifier=session.channelIdentifier, ...
                carrierFrequency_Hz=session.carrierFrequency_Hz, ...
                counterTagSigma_s=cfg.measurements.groundRelayTimeTransfer.counterTag.sigma_s, ...
                counterTagLabels=cfg.measurements.groundRelayTimeTransfer.counterTag.labels, ...
                applyAtmosphere=atmosphereEnabled, ...
                solverOptions=solverOptions);
            recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
                stationB, relay, stationA, hwReturn, t4Return_s, ...
                atmoLegVariance_s2, ...
                exchangeIdentifier=sprintf('%s:return',session.sessionIdentifier), ...
                sessionIdentifier=session.sessionIdentifier, ...
                protocolIdentifier=session.protocolIdentifier, ...
                signalIdentifier=session.signalIdentifier, ...
                channelIdentifier=session.channelIdentifier, ...
                carrierFrequency_Hz=session.carrierFrequency_Hz, ...
                counterTagSigma_s=cfg.measurements.groundRelayTimeTransfer.counterTag.sigma_s, ...
                counterTagLabels=cfg.measurements.groundRelayTimeTransfer.counterTag.labels, ...
                applyAtmosphere=atmosphereEnabled, ...
                solverOptions=solverOptions);

            groups = revgnss.GroundRelayPhysicalLinkConfig.sessionCommonGroups(cfg);
            [sessionBlock, sessionCommonTemporalModels] = ...
                revgnss.GroundRelayTimeTransferSessionBuilder.assembleSessionCommonBlock_(groups);
            covBuilder = revgnss.ReciprocalTimeTransferCovarianceBuilder;
            [sessionCommonCovariance_s2, sessionCommonComponentOrder, ~] = covBuilder.assemble( ...
                {covBuilder.relayBlock(sessionBlock)});

            observable = revgnss.GroundRelaySessionObservableBuilder.combine( ...
                recordForward, recordReturn, hardwareTruth, hardwareCalibration, ...
                atmoDelayForward_s, atmoDelayReturn_s, ...
                sessionCommonCovariance_s2, sessionCommonComponentOrder, ...
                sessionIdentifier=session.sessionIdentifier, ...
                sessionCommonTemporalModels=sessionCommonTemporalModels);
        end
    end

    methods (Static, Access = private)
        function tf = atmosphereEnabled_(cfg)
            tf = cfg.measurements.groundRelayTimeTransfer.atmosphere.applyTropo || ...
                cfg.measurements.groundRelayTimeTransfer.atmosphere.applyIono;
        end

        function [block, temporalModels] = assembleSessionCommonBlock_(groups)
            % assembleSessionCommonBlock_  Builds the struct('covariance',...,'componentOrder',...,
            % 'sourceIdentifiers',...) revgnss.ReciprocalTimeTransferCovarianceBuilder.relayBlock
            % expects, from an array of revgnss.GroundRelaySessionCommonCovarianceGroup -- the same
            % blkdiag-per-group pattern relayBlock's sibling sessionCommonModeBlock already uses
            % internally, independently re-implemented here rather than exposed/edited (that
            % method is isa-locked to revgnss.CommonSourceCovarianceGroup, the metres^2-domain
            % type this seconds^2-domain subsystem must never be confused with). Emits
            % g.memberRowCount labels per group (combined review m8 -- an un-reviewed first cut
            % emitted exactly one label per group regardless of memberRowCount, which would fail
            % deep inside ReciprocalTimeTransferCovarianceBuilder.validateBlock_'s componentOrder-
            % length check for any group declaring more than one member row, rather than failing
            % clearly at the label site; latent today since revgnss.GroundRelayPhysicalLinkConfig.
            % sessionCommonGroups always sets memberRowCount=1).
            %
            % Also returns temporalModels (combined review m4): the un-reviewed first cut dropped
            % g.temporalCovarianceModel entirely once past this method, so a consumer of the final
            % observable alone (without separately re-calling revgnss.GroundRelayPhysicalLinkConfig.
            % sessionCommonGroups) had no way to see WHY acceptance comparison 4's "remains
            % temporally correlated" holds -- one entry per componentOrder label, in the same
            % order, repeating each group's own single model across its memberRowCount rows.
            % g.validFromEpoch_s/validUntilEpoch_s are NOT propagated: revgnss.
            % GroundRelayPhysicalLinkConfig.sessionCommonGroups hardcodes both to +-1e12 (no
            % masterConfig leaf exists to override them), so a "validity window" check against real
            % session epochs would be definitionally always-true and vacuous, not a meaningful test.
            if isempty(groups)
                block = struct('covariance',zeros(0,0),'componentOrder',{{}},'sourceIdentifiers',{{}});
                temporalModels = {};
                return
            end
            nGroups = numel(groups);
            covarianceBlocks = cell(1,nGroups);
            labelBlocks = cell(1,nGroups);
            idBlocks = cell(1,nGroups);
            modelBlocks = cell(1,nGroups);
            for k = 1:nGroups
                g = groups(k);
                covarianceBlocks{k} = g.sharedCovarianceContribution_s2;
                labelBlocks{k} = arrayfun(@(r) sprintf('%s:%d',g.commonSourceName,r), ...
                    1:g.memberRowCount,'UniformOutput',false);
                idBlocks{k} = {g.covarianceGroupIdentifier};
                modelBlocks{k} = repmat({g.temporalCovarianceModel},1,g.memberRowCount);
            end
            block = struct('covariance',blkdiag(covarianceBlocks{:}), ...
                'componentOrder',{[labelBlocks{:}]},'sourceIdentifiers',{[idBlocks{:}]});
            temporalModels = [modelBlocks{:}];
        end

        function [varAS_s2, varSB_s2, delayForward_s, delayReturn_s] = groundSpaceAtmosphere_( ...
                cfg, environmentModel, stationATowerTruth, stationBTowerTruth, relay, ...
                t4Forward_s, t4Return_s)
            % groundSpaceAtmosphere_  The first place in the whole plan atmosphere reaches an
            % actual local-clock-tag value (Section 4.4's own applyAtmosphere never got past a
            % hard-refused stub). Both legs' delay is summed and applied entirely at the
            % destination's receive tag (a bent-pipe relay is transparent to atmosphere -- it
            % repeats whatever hits its antenna, so both hops' delay accumulate by the time the far
            % station receives). side='truth' always -- there is no estimate-side consumer in this
            % report-only deliverable.
            %
            % Relay ECEF position for elevation-angle purposes is read directly from the already-
            % built truth endpoint (relay.centrePositionAt(t), rotated ECI->ECEF via the SAME
            % rotMatEcefToInertial the endpoint itself was built through) rather than linearly
            % extrapolated from a raw truth struct (combined review m6 -- linear ECEF
            % extrapolation diverges from the endpoint's own inertial-constant-velocity model by a
            % measured 329.5 km / 1.3% elevation error at the shipped 990s forward/return gap;
            % reading the endpoint's own position instead removes the approximation entirely
            % rather than merely re-bounding its error).
            if ~revgnss.GroundRelayTimeTransferSessionBuilder.atmosphereEnabled_(cfg)
                varAS_s2 = 0; varSB_s2 = 0; delayForward_s = 0; delayReturn_s = 0;
                return
            end
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            atmoCfg = cfg.measurements.groundRelayTimeTransfer.atmosphere;
            session = cfg.measurements.groundRelayTimeTransfer.session;
            stationATowerIdx = cfg.measurements.groundRelayTimeTransfer.session.stationATowerIndex;
            stationBTowerIdx = cfg.measurements.groundRelayTimeTransfer.session.stationBTowerIndex;

            relayEcefForward_m = models.frames.FrameTimeUtils.rotMatEcefToInertial(t4Forward_s)' * ...
                relay.centrePositionAt(t4Forward_s);
            relayEcefReturn_m = models.frames.FrameTimeUtils.rotMatEcefToInertial(t4Return_s)' * ...
                relay.centrePositionAt(t4Return_s);

            delayForward_s = revgnss.GroundRelayTimeTransferSessionBuilder.legPairDelay_( ...
                environmentModel, atmoCfg, session, stationATowerTruth.r_ecef_m(:), stationATowerIdx, ...
                stationBTowerTruth.r_ecef_m(:), stationBTowerIdx, relayEcefForward_m, c);
            delayReturn_s = revgnss.GroundRelayTimeTransferSessionBuilder.legPairDelay_( ...
                environmentModel, atmoCfg, session, stationATowerTruth.r_ecef_m(:), stationATowerIdx, ...
                stationBTowerTruth.r_ecef_m(:), stationBTowerIdx, relayEcefReturn_m, c);

            varAS_s2 = atmoCfg.perLegResidualVariance_s2(1);
            varSB_s2 = atmoCfg.perLegResidualVariance_s2(2);
        end

        function delay_s = legPairDelay_(environmentModel, atmoCfg, session, ...
                stationA_ecef_m, stationATowerIdx, stationB_ecef_m, stationBTowerIdx, relay_ecef_m, c)
            elevAS_rad = models.frames.GeometryUtils.elevationAngle(stationA_ecef_m, relay_ecef_m);
            elevSB_rad = models.frames.GeometryUtils.elevationAngle(stationB_ecef_m, relay_ecef_m);
            delayAS_m = 0; delaySB_m = 0;
            if atmoCfg.applyTropo
                delayAS_m = delayAS_m + environmentModel.getTropDelay(stationATowerIdx,elevAS_rad,'truth');
                delaySB_m = delaySB_m + environmentModel.getTropDelay(stationBTowerIdx,elevSB_rad,'truth');
            end
            if atmoCfg.applyIono
                delayAS_m = delayAS_m + environmentModel.getIonoDelay(stationATowerIdx,elevAS_rad, ...
                    'truth',session.carrierFrequency_Hz,atmoCfg.f_L1ReferenceHz);
                delaySB_m = delaySB_m + environmentModel.getIonoDelay(stationBTowerIdx,elevSB_rad, ...
                    'truth',session.carrierFrequency_Hz,atmoCfg.f_L1ReferenceHz);
            end
            delay_s = (delayAS_m + delaySB_m) / c;
        end
    end
end
