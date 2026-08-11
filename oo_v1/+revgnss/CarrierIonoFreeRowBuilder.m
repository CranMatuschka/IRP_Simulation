classdef CarrierIonoFreeRowBuilder
    % Carrier ionosphere-free float row combination.
    %
    % Combines L1+L2 carrier EKF rows (from CarrierMeasurementBuilder.buildEkfRows)
    % into IF rows (float ambiguity, non-integer).
    %
    % Physics:
    %   z_IF  = alpha*z_L1   + beta*z_L2
    %   h_IF  = alpha*h_L1   + beta*h_L2
    %   H_IF  = alpha*H_L1   + beta*H_L2
    %   R_IF  = alpha²*R_L1  + beta²*R_L2   (uncorrelated noise assumption)
    %
    % Key limitation:
    %   B_IF = alpha*B_L1 + beta*B_L2 is NOT an integer in cycles of either
    %   frequency.  Integer fixing, LAMBDA/MLAMBDA are NOT implemented in v1.
    %   The IF H columns for L1 and L2 ambiguity states are alpha and beta
    %   respectively; the EKF observes only their linear combination.
    %
    % classifications returned by CarrierIonoFreeEkfDiagnostics:
    %   'disabled','requested-no-l2','requested-not-ekf-float',
    %   'requested-metadata-unavailable','active-carrier-if-ekf-float'

    methods (Static)

        function ok = shouldCombine(cfg)
            % shouldCombine  True if the two IF config leaves ask for combination.
            % Kept as a thin wrapper on intent alone (no feasibility test) because
            % tests/test_stage47_carrier_iono_free_float_rows.m and
            % ConfigFactory.m:1581 both call it expecting exactly that: it does NOT
            % know whether a single carrier signal makes the request infeasible.
            % Use combineStatus (below) wherever the answer must reflect what
            % actually happens to the carrier rows -- see P12/P13/P14/P15.
            ok = false;
            try
                ok = cfg.measurements.carrier.ionosphereFreeRows.enable && ...
                     cfg.measurements.carrier.ionosphereFreeRows.useInEkf;
            catch; end
        end

        function [tf, reason] = combineStatus(cfg)
            % combineStatus  Whether the carrier rows ARE ionosphere-free combined.
            %
            % shouldCombine (above) answers "was it requested"; this answers "did it
            % happen". CarrierMeasurementBuilder.m:588 AND-ed shouldCombine with a
            % second, un-owned condition (nSig_==2) that no config reader ever saw --
            % with cfg.signals.enabledMask=[true,false] (freq001/freq008) the request
            % is on, useInEkf is on, and the report still claimed IF rows were built
            % while the physics silently fell through to raw per-signal rows. This is
            % the ONE predicate every consumer (physics, both reporters, the EKF
            % diagnostics classifier) must call so they can never disagree again.
            %
            % reason in {'ok','disabled','notUsedInEkf','singleCarrierSignal'}.
            tf = false;
            enable_   = false;
            useInEkf_ = false;
            try; enable_   = logical(cfg.measurements.carrier.ionosphereFreeRows.enable);   catch; end
            try; useInEkf_ = logical(cfg.measurements.carrier.ionosphereFreeRows.useInEkf); catch; end
            if ~enable_
                reason = 'disabled'; return
            end
            if ~useInEkf_
                reason = 'notUsedInEkf'; return
            end
            nSig_ = 1;
            try; nSig_ = revgnss.SignalCatalog.nCarrierSignals(cfg); catch; end
            if nSig_ < 2
                reason = 'singleCarrierSignal'; return
            end
            tf = true; reason = 'ok';
        end

        function [z_IF, h_IF, H_IF, R_IF, cpInfo_IF] = buildFromStack( ...
                z, h, H, R, cpInfo, Mp, cfg)
            % buildFromStack  Post-process L1+L2 carrier stack into IF rows.
            %
            % CarrierMeasurementBuilder.buildEkfRows stacks signals as:
            %   rows 1:Mp      → L1 rows (si_=1)
            %   rows Mp+1:2*Mp → L2 rows (si_=2)
            % Extracts both blocks, applies IF combination, returns Mp IF rows.
            % The IF combination replaces L1+L2 rows (prevents rank deficiency).
            %
            % When cfg.estimator.enforceCarrierArcConsistency.enable
            % is true and cpInfo.arcId is present, pairs with mismatched L1/L2
            % arc IDs are skipped before combining. Returns fewer than Mp rows
            % when pairs are skipped; returns empty arrays when all are skipped.
            %
            % Ambiguity H columns: H_IF has alpha on the L1 ambiguity column
            % and beta on the L2 ambiguity column (from H_IF = alpha*H_L1+beta*H_L2).
            % The EKF jointly updates both states via the single IF innovation.

            % IF coefficients from the RESOLVED band pair. This read used to go to the
            % name-keyed SignalDefinition, i.e. GPS alpha = 2.5457 / beta = -1.5457 whatever
            % the scenario had retuned to. On a retuned pair those coefficients do not
            % cancel the ionosphere at all -- for freq012 they invert its sign and amplify
            % it 24x -- so this row builder was strictly worse than not combining.
            [alpha, beta] = revgnss.SignalUtils.ionosphereFreeCoefficients(cfg);

            idx1    = 1:Mp;
            idx2    = Mp + 1 : 2*Mp;
            Mp_orig = Mp;

            % Enforce arc consistency before IF combination.
            enforceArc = false;
            try; enforceArc = logical(cfg.estimator.enforceCarrierArcConsistency.enable); catch; end
            nArcSkippedPairs         = 0;
            skippedForInconsistency  = false(1, Mp);
            arcConsistencyEnforced   = enforceArc;
            arcMetaUsedForEnforcement = false;

            if enforceArc
                if isfield(cpInfo,'arcId') && numel(cpInfo.arcId) >= 2*Mp
                    arcMetaUsedForEnforcement = true;
                    arcIdL1_all  = cpInfo.arcId(idx1);
                    arcIdL2_all  = cpInfo.arcId(idx2);
                    consistMask  = (arcIdL1_all == arcIdL2_all) & ...
                                   (arcIdL1_all > 0) & (arcIdL2_all > 0);
                    skippedForInconsistency = ~consistMask;
                    nArcSkippedPairs = sum(skippedForInconsistency);
                    idx1 = idx1(consistMask);
                    idx2 = idx2(consistMask);
                    Mp   = sum(consistMask);
                else
                    policy_ = 'disableWithWarning';
                    try; policy_ = cfg.validation.unsupportedFeaturePolicy; catch; end
                    if strcmp(policy_,'error')
                        error('CarrierIonoFreeRowBuilder:arcMetadataUnavailable', ...
                            ['enforceCarrierArcConsistency=true but cpInfo has no arcId ' ...
                             'before ionosphere-free row construction.']);
                    else
                        arcConsistencyEnforced = false;
                    end
                end
            end

            % Empty output when all pairs were skipped by arc enforcement.
            nSt_ = size(H, 2);
            if Mp == 0
                z_IF = zeros(0,1); h_IF = zeros(0,1);
                H_IF = zeros(0, nSt_); R_IF = zeros(0,0);
                cpInfo_IF = cpInfo;
                cpInfo_IF.phi_m                   = zeros(0,1);
                cpInfo_IF.prefit_m                = zeros(0,1);
                cpInfo_IF.towerIdx                = zeros(0,1);
                cpInfo_IF.antennaIdx              = zeros(0,1);
                % Same collapse as the populated branch below -- see the comment there.
                cpInfo_IF.towerClkBiasSigma_m     = zeros(0,1);
                cpInfo_IF.productEpoch_s          = zeros(0,1);
                cpInfo_IF.productAge_s            = zeros(0,1);
                cpInfo_IF.sigmaDrift_mps          = zeros(0,1);
                cpInfo_IF.towerClockSharedSigma_m = zeros(0,1);
                % Diagnosis D: same collapse, extended to the seven fields the populated
                % branch below now also collapses -- see the comment there.
                cpInfo_IF.towerClkModel_m                 = zeros(0,1);
                cpInfo_IF.injectedSlip_m                  = zeros(0,1);
                cpInfo_IF.interAntennaPhaseBiasTruth_m    = zeros(0,1);
                cpInfo_IF.interAntennaPhaseBiasModel_m    = zeros(0,1);
                cpInfo_IF.leverArmNorm_m                  = zeros(0,1);
                cpInfo_IF.attitudePartialsEnabled         = false(0,1);
                cpInfo_IF.attitudeSensitive               = false(0,1);
                cpInfo_IF.hAttitudeNorm                   = zeros(0,1);
                cpInfo_IF.signalIdx               = zeros(0,1);
                cpInfo_IF.signalId                = {};
                cpInfo_IF.ambiguityStateIdx       = zeros(0,1);
                cpInfo_IF.ambiguityStateIdxL1     = zeros(0,1);
                cpInfo_IF.ambiguityStateIdxL2     = zeros(0,1);
                cpInfo_IF.ambiguityStateIdxPair   = zeros(0,2);
                cpInfo_IF.ambiguityWeights        = zeros(0,2);
                cpInfo_IF.ambiguityCombination    = {};
                cpInfo_IF.ambiguityIsInteger      = false(0,1);
                cpInfo_IF.integerFixingImplemented = false;
                cpInfo_IF.lambdaImplemented        = false;
                cpInfo_IF.trackKey                = {};
                cpInfo_IF.ionoFreeCombined        = true;
                cpInfo_IF.ifAlpha                 = alpha;
                cpInfo_IF.ifBeta                  = beta;
                cpInfo_IF.hExplicitlyCombined     = true;
                cpInfo_IF.hCombination            = 'alphaH1_betaH2';
                cpInfo_IF.nArcSkippedPairs              = nArcSkippedPairs;
                cpInfo_IF.skippedForArcInconsistency    = skippedForInconsistency;
                cpInfo_IF.arcConsistencyEnforced        = arcConsistencyEnforced;
                cpInfo_IF.arcMetaUsedForEnforcement     = arcMetaUsedForEnforcement;
                cpInfo_IF.arcIdL1               = zeros(0,1);
                cpInfo_IF.arcIdL2               = zeros(0,1);
                cpInfo_IF.arcConsistent         = false(0,1);
                cpInfo_IF.nArcConsistentPairs   = 0;
                cpInfo_IF.nArcInconsistentPairs = nArcSkippedPairs;
                cpInfo_IF.ambiguityArcSeparated = true;
                return
            end

            z_IF = alpha * z(idx1) + beta * z(idx2);
            h_IF = alpha * h(idx1) + beta * h(idx2);
            H_IF = alpha * H(idx1,:) + beta * H(idx2,:);

            % R: full covariance propagation R_IF = A*R*A' with A = [alpha*I, beta*I].
            %
            % The previous form, diag(alpha^2*diag(R11) + beta^2*diag(R22)), was wrong
            % on two counts whenever the L1/L2 rows share an error source:
            %
            %  1. It drops the cross-blocks R12/R21. ProductClockCovarianceBuilder writes
            %     a genuine rank-1 tower-clock drift block over rows grouped by
            %     (towerIdx, productEpoch) a few lines upstream, and the L1 and L2 rows of
            %     a tower land in the SAME group -- so R12 is populated, and discarding it
            %     leaves the filter overconfident on the tower-common mode.
            %  2. For a NON-DISPERSIVE source (the tower-clock residual is identical in
            %     metres on L1 and L2) the correct IF gain is (alpha+beta)^2 = 1, not
            %     alpha^2+beta^2 = 8.87. Charging the latter over-inflated the diagonal by
            %     up to 2.4x in variance at product age 35 s.
            %
            % Keeping the cross-blocks recovers both: the 2*alpha*beta*cov12 term is
            % exactly what turns alpha^2+beta^2 into (alpha+beta)^2 for a perfectly
            % correlated source, and leaves an independent source at alpha^2+beta^2
            % unchanged. Same algebra as revgnss.IonoFreeCombination.combineVariance.
            R11  = R(idx1, idx1);
            R22  = R(idx2, idx2);
            R12  = R(idx1, idx2);
            R21  = R(idx2, idx1);
            R_IF = alpha^2 * R11 + beta^2 * R22 + alpha * beta * (R12 + R21);
            R_IF = (R_IF + R_IF') / 2;   % kill any accumulated asymmetry

            % cpInfo: L1 block becomes IF; L2 block dropped.
            % Explicit L1/L2 ambiguity state pair metadata added.
            cpInfo_IF                         = cpInfo;
            cpInfo_IF.phi_m                   = alpha * cpInfo.phi_m(idx1) + beta * cpInfo.phi_m(idx2);
            cpInfo_IF.prefit_m                = z_IF - h_IF;
            cpInfo_IF.towerIdx                = cpInfo.towerIdx(idx1);
            cpInfo_IF.antennaIdx              = cpInfo.antennaIdx(idx1);
            % TOWER-CLOCK PRODUCT METADATA must collapse with the rows it describes.
            % Until 2026-08-10 only towerIdx was collapsed here, so after an
            % ionosphere-free combination these four stayed at length 2*Mp against a
            % towerIdx of Mp. ProductClockCovarianceBuilder indexes them at j = 1..M_car
            % and so read the L1 half -- correct only by accident, because L1 and L2 of one
            % tower share a product epoch and therefore an age. Any length-checked consumer
            % silently skipped them instead: ReverseGNSSSimulation.filterCarrierErrStruct_
            % is generic on numel(v) == numel(keepMask). The tower clock is common to L1 and
            % L2 and is non-dispersive, so it survives the IF combination at unit gain --
            % (alpha + beta) == 1 -- and these are the sigmas that must come with it.
            cpInfo_IF.towerClkBiasSigma_m     = cpInfo.towerClkBiasSigma_m(idx1);
            cpInfo_IF.productEpoch_s          = cpInfo.productEpoch_s(idx1);
            cpInfo_IF.productAge_s            = cpInfo.productAge_s(idx1);
            cpInfo_IF.sigmaDrift_mps          = cpInfo.sigmaDrift_mps(idx1);
            if isfield(cpInfo, 'towerClockSharedSigma_m')
                cpInfo_IF.towerClockSharedSigma_m = cpInfo.towerClockSharedSigma_m(idx1);
            end
            % Diagnosis D: seven more per-row fields CarrierMeasurementBuilder declares
            % (:84,86-92,103) that stayed at length 2*Mp here until now, silently
            % disabling CarrierTrackManager's compensated slip detection (gated on
            % numel(cpInfo.towerClkModel_m)==M, :81-82/:361) whenever carrier IF
            % combination is on -- i.e. by default, the moment slip detection itself is
            % turned on (it is off by default, so this did not move the shipped
            % headline). towerClkModel_m is NON-DISPERSIVE -- identical on the L1 and L2
            % rows of one (tower,antenna), so alpha+beta=1 makes v(idx1) exact, same
            % reasoning as the towerClkBiasSigma_m collapse above. injectedSlip_m and the
            % inter-antenna phase biases are added directly into z_phi/h_phi at each
            % signal's OWN magnitude (CarrierMeasurementBuilder:452/462-463/469), so
            % their contribution to the combined z_IF/h_IF is the alpha/beta combination,
            % not a passthrough. leverArmNorm_m/attitudePartialsEnabled/
            % attitudeSensitive/hAttitudeNorm are geometry/attitude row properties
            % identical on L1 and L2 of one physical row (same antenna, same LOS) -- v(idx1)
            % is exact.
            cpInfo_IF.towerClkModel_m = cpInfo.towerClkModel_m(idx1);
            cpInfo_IF.injectedSlip_m = alpha * cpInfo.injectedSlip_m(idx1) + ...
                beta * cpInfo.injectedSlip_m(idx2);
            cpInfo_IF.interAntennaPhaseBiasTruth_m = alpha * cpInfo.interAntennaPhaseBiasTruth_m(idx1) + ...
                beta * cpInfo.interAntennaPhaseBiasTruth_m(idx2);
            cpInfo_IF.interAntennaPhaseBiasModel_m = alpha * cpInfo.interAntennaPhaseBiasModel_m(idx1) + ...
                beta * cpInfo.interAntennaPhaseBiasModel_m(idx2);
            cpInfo_IF.leverArmNorm_m          = cpInfo.leverArmNorm_m(idx1);
            cpInfo_IF.attitudePartialsEnabled = cpInfo.attitudePartialsEnabled(idx1);
            cpInfo_IF.attitudeSensitive       = cpInfo.attitudeSensitive(idx1);
            cpInfo_IF.hAttitudeNorm           = cpInfo.hAttitudeNorm(idx1);
            cpInfo_IF.signalIdx               = zeros(Mp, 1);  % 0 = ionosphere-free
            cpInfo_IF.signalId                = repmat({'L_IF'}, Mp, 1);
            ambIdxL1_                         = cpInfo.ambiguityStateIdx(idx1);
            ambIdxL2_                         = cpInfo.ambiguityStateIdx(idx2);
            cpInfo_IF.ambiguityStateIdx       = ambIdxL1_;  % legacy: L1 index
            cpInfo_IF.ambiguityStateIdxL1     = ambIdxL1_;
            cpInfo_IF.ambiguityStateIdxL2     = ambIdxL2_;
            cpInfo_IF.ambiguityStateIdxPair   = [ambIdxL1_, ambIdxL2_];  % Mp x 2
            cpInfo_IF.ambiguityWeights        = repmat([alpha, beta], Mp, 1);  % Mp x 2
            cpInfo_IF.ambiguityCombination    = repmat({'alpha*B_L1+beta*B_L2'}, Mp, 1);
            cpInfo_IF.ambiguityIsInteger      = false(Mp, 1);
            cpInfo_IF.integerFixingImplemented = false;
            cpInfo_IF.lambdaImplemented        = false;
            cpInfo_IF.trackKey                = cpInfo.trackKey(idx1);
            cpInfo_IF.ionoFreeCombined        = true;
            cpInfo_IF.ifAlpha                 = alpha;
            cpInfo_IF.ifBeta                  = beta;
            cpInfo_IF.hExplicitlyCombined     = true;
            cpInfo_IF.hCombination            = 'alphaH1_betaH2';
            % Arc consistency enforcement metadata.
            cpInfo_IF.nArcSkippedPairs              = nArcSkippedPairs;
            cpInfo_IF.skippedForArcInconsistency    = skippedForInconsistency;
            cpInfo_IF.arcConsistencyEnforced        = arcConsistencyEnforced;
            cpInfo_IF.arcMetaUsedForEnforcement     = arcMetaUsedForEnforcement;
            % Arc consistency check on remaining (post-filter) pairs.
            if isfield(cpInfo,'arcId') && numel(cpInfo.arcId) >= 2*Mp_orig
                arcIdL1_ = cpInfo.arcId(idx1);
                arcIdL2_ = cpInfo.arcId(idx2);
                cpInfo_IF.arcIdL1 = arcIdL1_;
                cpInfo_IF.arcIdL2 = arcIdL2_;
                cpInfo_IF.arcConsistent = (arcIdL1_ == arcIdL2_) & ...
                                          (arcIdL1_ > 0) & (arcIdL2_ > 0);
                cpInfo_IF.nArcConsistentPairs   = sum(cpInfo_IF.arcConsistent);
                cpInfo_IF.nArcInconsistentPairs = Mp - cpInfo_IF.nArcConsistentPairs;
                cpInfo_IF.ambiguityArcSeparated = true;
            else
                cpInfo_IF.arcIdL1 = zeros(Mp,1);
                cpInfo_IF.arcIdL2 = zeros(Mp,1);
                cpInfo_IF.arcConsistent = false(Mp,1);
                cpInfo_IF.nArcConsistentPairs   = 0;
                cpInfo_IF.nArcInconsistentPairs = 0;
                cpInfo_IF.ambiguityArcSeparated = false;
            end
        end

        function H_IF = combineJacobians(H_L1, H_L2, cfg)
            % combineJacobians  Explicit IF Jacobian combination (utility / tests).
            %
            % For production: H is built by combining full row blocks via buildFromStack.
            % This method is provided for unit tests and diagnostic verification.
            %
            % cfg is REQUIRED: the coefficients follow the resolved band, and there is no
            % canonical-catalogue fallback to guess it from.
            if ~isequal(size(H_L1), size(H_L2))
                error('CarrierIonoFreeRowBuilder:dimensionMismatch', ...
                    'H_L1 size [%s] does not match H_L2 size [%s].', ...
                    num2str(size(H_L1)), num2str(size(H_L2)));
            end
            if nargin < 3
                error('CarrierIonoFreeRowBuilder:cfgRequired', ...
                    'combineJacobians(H_L1, H_L2, cfg) needs cfg to resolve the band.');
            end
            [alpha, beta] = revgnss.SignalUtils.ionosphereFreeCoefficients(cfg);
            H_IF = alpha * H_L1 + beta * H_L2;
        end

        function lines = summaryLines(s)
            if ~isstruct(s) || ~isfield(s,'classification')
                lines = {'CarrierIonoFreeRowBuilder: no summary.'}; return
            end
            lines = {};
            lines{end+1} = sprintf('Classification       : %s', s.classification);
            lines{end+1} = sprintf('Requested            : %s', mat2str(s.requested));
            lines{end+1} = sprintf('UsedInEKF            : %s', mat2str(s.usedInEkf));
            if isfield(s,'carrierIfRows') && isfinite(s.carrierIfRows)
                lines{end+1} = sprintf('Carrier IF rows      : %d', s.carrierIfRows);
            end
            if isfield(s,'noiseAmplification') && isfinite(s.noiseAmplification)
                lines{end+1} = sprintf('NoiseAmplification   : %.4fx', s.noiseAmplification);
            end
            lines{end+1} = 'IntegerAmbig         : non-integer (float only)';
            lines{end+1} = 'IntegerFixingImpl    : false';
        end

    end
end
