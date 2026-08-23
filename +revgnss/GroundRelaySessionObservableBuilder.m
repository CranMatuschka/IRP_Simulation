classdef GroundRelaySessionObservableBuilder
    % GroundRelaySessionObservableBuilder  Plan Section 4.5: combines two raw, RAW-TAGS-ONLY
    % revgnss.ReciprocalTimestampExchangeRecord (topologyKind='relayTransit', one per direction
    % of a classical relay TWSTFT session -- station A -> relay S -> station B, and station B ->
    % relay S -> station A) into ONE processed revgnss.GroundRelaySessionClockDifferenceObservable.
    %
    % TWO reported clock-difference values (combined review B1 -- an un-reviewed first cut
    % reported only clockDifferenceValue_s and mislabeled it "exact", which silently made
    % hardware.relayGroupDelayAsymmetry_s inert to anything a real receiver could ever observe):
    %
    %   clockDifferenceValue_s -- TRUTH-GEOMETRY-ASSISTED reference: clockDifferenceValue_s =
    %   0.5*((DeltaF-tauF)-(DeltaR-tauR)), where tauF/tauR are the TRUTH-SOLVED coordinate-time
    %   transit durations (coordinateTimeEvents_s(4)-coordinateTimeEvents_s(1) on each record).
    %   Given localTimeAt(t) = clockLocalTimeAtReference_s + localClockRate*(t-clockReferenceCoordinateTime_s),
    %   define delta_X(t) := X.localTimeAt(t) - t. Then (tags(4)-tags(1))-(t4-t1) === delta_dest(t4)
    %   - delta_source(t1) EXACTLY, a pure algebraic identity of the affine clock model -- true
    %   regardless of relay motion/delay/geometry. Averaging that identity over the swapped-role
    %   forward/return pair, and using that averaging an AFFINE function at two coordinate times
    %   equals evaluating it at their midpoint, gives EXACTLY
    %   clockDifferenceValue_s == delta_B(stationBEffectiveEpoch_s) - delta_A(stationAEffectiveEpoch_s)
    %   where stationAEffectiveEpoch_s := 0.5*(t1F+t4R), stationBEffectiveEpoch_s := 0.5*(t4F+t1R)
    %   (see revgnss.GroundRelaySessionClockDifferenceObservable's header for when this collapses
    %   to a single bias_B-bias_A value). tauF/tauR are GROUND TRUTH -- no real station-pair
    %   receiver has access to them -- so this value is a validation/diagnostic reference, never
    %   what a real relay-TWSTFT session actually reports.
    %
    %   classicalReciprocityValue_s -- the REALIZABLE classical relay-TWSTFT combination
    %   0.5*(DeltaF-DeltaR): the same station-delay- and atmosphere-corrected local-tag
    %   differences DeltaF/DeltaR used above, but with NO tauF/tauR subtraction -- exactly what a
    %   real station pair computes from its own two exchanged local tag sets, no geometry
    %   knowledge required. It carries the true relay-motion non-reciprocity and relay-group-delay
    %   asymmetry residuals that clockDifferenceValue_s's tau-subtraction removes by construction;
    %   hardware.relayGroupDelayAsymmetry_s moves THIS value (by +asymmetry/2 in the static-station
    %   limit), never clockDifferenceValue_s (see tests/test_relay_twstft_clock_gauge.m's "relay
    %   marginalized out" coverage, which is a real, structural, and DELIBERATE property of
    %   clockDifferenceValue_s specifically, not a defect).
    %
    % Station terminal-delay correction (combined review M4 -- an un-reviewed first cut applied
    % only ONE hardware object's delays as the correction, making a perfectly-known, fully-
    % calibrated station delay bias the result by its own full nominal value): this method takes
    % TWO hardware objects, hardwareTruth (parameterSource='physicalTruth', nominal+truth-error
    % delay -- what really happened) and hardwareCalibration (parameterSource='calibrationProduct',
    % nominal only -- what a real receiver's own compensation believes/removes). The NET
    % correction applied to each record's slot(1)/slot(4) tags is
    % (hardwareTruth.*Delay_s - hardwareCalibration.*Delay_s), which reduces to exactly the
    % declared truth.*DelayError_s residual whenever hardwareCalibration carries the SAME nominal
    % values as hardwareTruth (the normal case) -- so a perfectly-known, fully-compensated delay
    % (truth.*Error_s==0) now correctly produces ZERO bias, and only the genuinely UNCALIBRATED
    % residual survives. A single combined (TX==RX) NET delay per station is PROVABLY INERT to
    % clockDifferenceValue_s/classicalReciprocityValue_s (only each station's own net
    % TX-minus-RX asymmetry survives the two-pass combination -- classical TWSTFT's own celebrated
    % cancellation of symmetric equipment delay), which is why revgnss.GroundRelaySessionHardwareModel
    % tracks all four station delay terms separately rather than one number per station.
    %
    % independentVariance_s2 (combined review M1): propagates each record's own declared,
    % INDEPENDENT (non-session-common) covariance -- counter/tag noise on slot(1)/slot(4) plus
    % per-leg atmosphere residual noise on slot(4) -- into a scalar variance on
    % clockDifferenceValue_s/classicalReciprocityValue_s via the combiner's own linear Jacobian:
    % d(output)/d(tagF4)=+0.5, d/d(tagF1)=-0.5, d/d(tagR4)=-0.5, d/d(tagR1)=+0.5, and the relay's
    % own slot(2)/slot(3) tags never enter at all (matching the "relay marginalized out" property
    % -- their declared counter-tag noise, if any, correctly contributes ZERO to this variance).
    %
    % clockClaim='relativeBiasOnly' on the built observable is justified by three real, structural,
    % mathematically-proven properties (not a revgnss.DistributedClockGaugeContract registry
    % lookup -- that contract's gating methods require revgnss.CommunicationEndpointState/
    % revgnss.DistributedLinkUpdateBlock infrastructure this truth-side, non-coordinator-routed
    % session processor does not have): (1) common-mode blindness -- shifting both station clock
    % biases by the same constant leaves the output unchanged, directly from the formula; (2)
    % differential sensitivity -- shifting only the remote (station B) bias by delta changes the
    % output by exactly +delta; (3) the relay is marginalized out structurally -- its own clock
    % bias/group delay never enter the combiner formula at all (its slot(2)/slot(3) tags are
    % discarded, not merely small).

    methods (Static)
        function observable = combine(recordForward, recordReturn, hardwareTruth, hardwareCalibration, ...
                atmosphereDelayForward_s, atmosphereDelayReturn_s, ...
                sessionCommonCovariance_s2, sessionCommonComponentOrder, options)
            arguments
                recordForward (1,1) revgnss.ReciprocalTimestampExchangeRecord
                recordReturn (1,1) revgnss.ReciprocalTimestampExchangeRecord
                hardwareTruth (1,1) revgnss.GroundRelaySessionHardwareModel
                hardwareCalibration (1,1) revgnss.GroundRelaySessionHardwareModel
                atmosphereDelayForward_s (1,1) double
                atmosphereDelayReturn_s (1,1) double
                sessionCommonCovariance_s2 (:,:) double
                sessionCommonComponentOrder (1,:) cell
                options.sessionIdentifier (1,:) char = ''
                options.truthDiagnosticIdentifier (1,:) char = ''
                options.sessionCommonTemporalModels (1,:) cell = {}
            end
            if isempty(options.sessionIdentifier)
                error('GroundRelaySessionObservableBuilder:sessionIdentifierRequired', ...
                    'options.sessionIdentifier is required and was not supplied.');
            end
            % Combined review m4: temporalCovarianceModel/correlationTime_s previously never
            % reached the observable at all, so a consumer could not see WHY the session-common
            % covariance is temporally correlated rather than white. options.sessionCommonTemporalModels
            % defaults to {} (backward-compatible with every caller that has no such metadata to
            % supply, e.g. an empty session-common covariance); when nonempty it must have one
            % entry per sessionCommonComponentOrder label.
            if isempty(options.sessionCommonTemporalModels)
                sessionCommonTemporalModels = repmat({'notDeclared'},1,numel(sessionCommonComponentOrder));
            else
                if numel(options.sessionCommonTemporalModels) ~= numel(sessionCommonComponentOrder)
                    error('GroundRelaySessionObservableBuilder:sessionCommonTemporalModels', ...
                        'sessionCommonTemporalModels must have one entry per sessionCommonComponentOrder label.');
                end
                sessionCommonTemporalModels = options.sessionCommonTemporalModels;
            end
            if ~(isfinite(atmosphereDelayForward_s) && atmosphereDelayForward_s >= 0 && ...
                    isfinite(atmosphereDelayReturn_s) && atmosphereDelayReturn_s >= 0)
                error('GroundRelaySessionObservableBuilder:atmosphereDelay', ...
                    'atmosphereDelayForward_s and atmosphereDelayReturn_s must be finite and nonnegative.');
            end
            hardwareTruth.assertParameterSource('physicalTruth');
            hardwareCalibration.assertParameterSource('calibrationProduct');

            revgnss.GroundRelaySessionObservableBuilder.requireSessionLegIdentity_( ...
                recordForward, recordReturn);

            % Session-level calibration-validity check (combined review m7 -- assertValidAt had no
            % production caller; revgnss.GroundRelayOneWayPassRecordBuilder's own assertValidAt
            % call is on the EPHEMERAL per-solver revgnss.ReciprocalLinkHardwareModel, never on
            % this session-level object). Checked against both passes' own reception epoch.
            hardwareTruth.assertValidAt(recordForward.coordinateTimeEvents_s(4));
            hardwareTruth.assertValidAt(recordReturn.coordinateTimeEvents_s(4));

            stationAId = recordForward.chainEndpointIdentifiers{1};
            relayId = recordForward.chainEndpointIdentifiers{2};
            stationBId = recordForward.chainEndpointIdentifiers{4};

            netTxA_s = hardwareTruth.stationATransmitDelay_s - hardwareCalibration.stationATransmitDelay_s;
            netRxA_s = hardwareTruth.stationAReceiveDelay_s - hardwareCalibration.stationAReceiveDelay_s;
            netTxB_s = hardwareTruth.stationBTransmitDelay_s - hardwareCalibration.stationBTransmitDelay_s;
            netRxB_s = hardwareTruth.stationBReceiveDelay_s - hardwareCalibration.stationBReceiveDelay_s;

            correctedF1_s = recordForward.localClockTags_s(1) - netTxA_s;
            correctedF4_s = recordForward.localClockTags_s(4) + netRxB_s + atmosphereDelayForward_s;
            correctedR1_s = recordReturn.localClockTags_s(1) - netTxB_s;
            correctedR4_s = recordReturn.localClockTags_s(4) + netRxA_s + atmosphereDelayReturn_s;

            deltaF_s = correctedF4_s - correctedF1_s;
            deltaR_s = correctedR4_s - correctedR1_s;
            tauF_s = recordForward.coordinateTimeEvents_s(4) - recordForward.coordinateTimeEvents_s(1);
            tauR_s = recordReturn.coordinateTimeEvents_s(4) - recordReturn.coordinateTimeEvents_s(1);

            rawCombination_s = (deltaF_s - tauF_s) - (deltaR_s - tauR_s);
            clockDifferenceValue_s = 0.5 * rawCombination_s;
            classicalReciprocityValue_s = 0.5 * (deltaF_s - deltaR_s);
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            clockDifferenceValue_m = c * clockDifferenceValue_s;
            classicalReciprocityValue_m = c * classicalReciprocityValue_s;

            stationAEffectiveEpoch_s = 0.5*(recordForward.coordinateTimeEvents_s(1) + ...
                recordReturn.coordinateTimeEvents_s(4));
            stationBEffectiveEpoch_s = 0.5*(recordForward.coordinateTimeEvents_s(4) + ...
                recordReturn.coordinateTimeEvents_s(1));

            independentVariance_s2 = ...
                revgnss.GroundRelaySessionObservableBuilder.propagatedIndependentVariance_(recordForward) + ...
                revgnss.GroundRelaySessionObservableBuilder.propagatedIndependentVariance_(recordReturn);

            observable = revgnss.GroundRelaySessionClockDifferenceObservable(struct( ...
                'sessionIdentifier', options.sessionIdentifier, ...
                'sourceForwardExchangeIdentifier', recordForward.exchangeIdentifier, ...
                'sourceReturnExchangeIdentifier', recordReturn.exchangeIdentifier, ...
                'stationAIdentifier', stationAId, ...
                'stationBIdentifier', stationBId, ...
                'relayIdentifier', relayId, ...
                'forwardReceptionEpoch_s', recordForward.coordinateTimeEvents_s(4), ...
                'returnReceptionEpoch_s', recordReturn.coordinateTimeEvents_s(4), ...
                'stationAEffectiveEpoch_s', stationAEffectiveEpoch_s, ...
                'stationBEffectiveEpoch_s', stationBEffectiveEpoch_s, ...
                'clockDifferenceValue_s', clockDifferenceValue_s, ...
                'clockDifferenceValue_m', clockDifferenceValue_m, ...
                'classicalReciprocityValue_s', classicalReciprocityValue_s, ...
                'classicalReciprocityValue_m', classicalReciprocityValue_m, ...
                'rawCombination_s', rawCombination_s, ...
                'coordinateAsymmetry_s', tauF_s - tauR_s, ...
                'stationTerminalDelayCorrectionForward_s', netTxA_s + netRxB_s, ...
                'stationTerminalDelayCorrectionReturn_s', netTxB_s + netRxA_s, ...
                'atmosphereDelayForward_s', atmosphereDelayForward_s, ...
                'atmosphereDelayReturn_s', atmosphereDelayReturn_s, ...
                'sessionCommonCovariance_s2', sessionCommonCovariance_s2, ...
                'sessionCommonComponentOrder', {sessionCommonComponentOrder}, ...
                'sessionCommonTemporalModels', {sessionCommonTemporalModels}, ...
                'independentVariance_s2', independentVariance_s2, ...
                'availability', recordForward.availability && recordReturn.availability, ...
                'truthDiagnosticIdentifier', options.truthDiagnosticIdentifier));
        end
    end

    methods (Static, Access = private)
        function variance_s2 = propagatedIndependentVariance_(record)
            % propagatedIndependentVariance_  Every declared-covariance component labeled 't1' or
            % 't4' (counter/tag noise on the two STATION slots) or 'atmosphereDelay:*' (per-leg
            % atmosphere residual, which lands entirely on slot(4) -- see
            % revgnss.GroundRelayTimeTransferSessionBuilder.groundSpaceAtmosphere_) propagates
            % into clockDifferenceValue_s/classicalReciprocityValue_s with Jacobian coefficient
            % +-0.5 (see class header); every other component (in particular 't2'/'t3', the
            % relay's own counter-tag noise) has Jacobian coefficient exactly ZERO and is
            % correctly excluded here, matching the "relay marginalized out" structural property.
            labels = record.covarianceComponentOrder;
            relevant = strcmp(labels,'t1') | strcmp(labels,'t4') | startsWith(labels,'atmosphereDelay:');
            idx = find(relevant);
            variance_s2 = 0.25 * sum(diag(record.covarianceBlock(idx,idx)));
        end

        function requireSessionLegIdentity_(recordForward, recordReturn)
            if ~(strcmp(recordForward.topologyKind,'relayTransit') && ...
                    strcmp(recordReturn.topologyKind,'relayTransit'))
                error('GroundRelaySessionObservableBuilder:topologyKind', ...
                    'Both records must have topologyKind==''relayTransit''.');
            end
            if ~(recordForward.availability && recordReturn.availability)
                error('GroundRelaySessionObservableBuilder:availability', ...
                    'Both records must be available to combine into a session observable.');
            end
            if ~(all(recordForward.localClockTagAvailable) && all(recordReturn.localClockTagAvailable))
                error('GroundRelaySessionObservableBuilder:localClockTagAvailable', ...
                    'Both records must carry a complete set of local clock tags.');
            end
            chainF = recordForward.chainEndpointIdentifiers;
            chainR = recordReturn.chainEndpointIdentifiers;
            if ~(strcmp(chainF{1},chainR{4}) && strcmp(chainF{4},chainR{1}) && ...
                    strcmp(chainF{2},chainF{3}) && strcmp(chainR{2},chainR{3}) && ...
                    strcmp(chainF{2},chainR{2}))
                error('GroundRelaySessionObservableBuilder:chainShape', ...
                    ['recordForward/recordReturn must be swapped-role one-way passes over the same ' ...
                    'station pair and the same relay (forward chain {A,S,S,B}, return chain {B,S,S,A}).']);
            end
            if strcmp(chainF{1},chainF{4})
                error('GroundRelaySessionObservableBuilder:stationPairDistinct', ...
                    'Station A and station B must be distinct endpoints.');
            end
            compareF = recordForward.localClockCompareEndpointIdentifiers;
            compareR = recordReturn.localClockCompareEndpointIdentifiers;
            if numel(compareF) ~= 2 || numel(compareR) ~= 2 || ...
                    ~isempty(setdiff(compareF,{chainF{1},chainF{4}})) || ...
                    ~isempty(setdiff(compareR,{chainF{1},chainF{4}})) || ...
                    any(strcmp(chainF{2},compareF)) || any(strcmp(chainF{2},compareR))
                error('GroundRelaySessionObservableBuilder:compareEndpoints', ...
                    ['localClockCompareEndpointIdentifiers must be exactly {stationA,stationB} on both ' ...
                    'records; the relay must never appear as a compared endpoint.']);
            end
            if strcmp(recordForward.exchangeIdentifier,recordReturn.exchangeIdentifier)
                error('GroundRelaySessionObservableBuilder:distinctExchanges', ...
                    'recordForward and recordReturn must carry distinct exchangeIdentifiers.');
            end
            if ~(recordForward.coordinateTimeEvents_s(1) <= recordForward.coordinateTimeEvents_s(2) && ...
                    recordForward.coordinateTimeEvents_s(2) <= recordForward.coordinateTimeEvents_s(3) && ...
                    recordForward.coordinateTimeEvents_s(3) <= recordForward.coordinateTimeEvents_s(4) && ...
                    recordReturn.coordinateTimeEvents_s(1) <= recordReturn.coordinateTimeEvents_s(2) && ...
                    recordReturn.coordinateTimeEvents_s(2) <= recordReturn.coordinateTimeEvents_s(3) && ...
                    recordReturn.coordinateTimeEvents_s(3) <= recordReturn.coordinateTimeEvents_s(4))
                error('GroundRelaySessionObservableBuilder:timeOrdering', ...
                    'coordinateTimeEvents_s must be time-ordered t1<=t2<=t3<=t4 on both records.');
            end
        end
    end
end
