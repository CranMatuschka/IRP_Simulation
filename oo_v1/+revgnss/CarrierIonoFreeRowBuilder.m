classdef CarrierIonoFreeRowBuilder
    % Stage 47: Carrier ionosphere-free float row combination.
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
            % shouldCombine  True if carrier IF EKF rows are enabled and active.
            ok = false;
            try
                ok = cfg.measurements.carrier.ionosphereFreeRows.enable && ...
                     cfg.measurements.carrier.ionosphereFreeRows.useInEkf;
            catch; end
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
            % Ambiguity H columns: H_IF has alpha on the L1 ambiguity column
            % and beta on the L2 ambiguity column (from H_IF = alpha*H_L1+beta*H_L2).
            % The EKF jointly updates both states via the single IF innovation.

            sigL1 = revgnss.SignalDefinition.get('L1');
            sigL2 = revgnss.SignalDefinition.get('L2');
            [alpha, beta] = revgnss.IonoFreeCombination.coefficients( ...
                sigL1.frequency_Hz, sigL2.frequency_Hz);

            idx1 = 1:Mp;
            idx2 = Mp + 1 : 2*Mp;

            z_IF = alpha * z(idx1) + beta * z(idx2);
            h_IF = alpha * h(idx1) + beta * h(idx2);
            H_IF = alpha * H(idx1,:) + beta * H(idx2,:);

            % R: diagonal uncorrelated combination
            r1   = diag(R(idx1, idx1));
            r2   = diag(R(idx2, idx2));
            R_IF = diag(alpha^2 * r1 + beta^2 * r2);

            % cpInfo: L1 block becomes IF; L2 block dropped.
            % Stage 48 adds explicit L1/L2 ambiguity state pair metadata.
            cpInfo_IF                         = cpInfo;
            cpInfo_IF.phi_m                   = alpha * cpInfo.phi_m(idx1) + beta * cpInfo.phi_m(idx2);
            cpInfo_IF.prefit_m                = z_IF - h_IF;
            cpInfo_IF.towerIdx                = cpInfo.towerIdx(idx1);
            cpInfo_IF.antennaIdx              = cpInfo.antennaIdx(idx1);
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
            % Stage 53: arc consistency check from previous-epoch arc IDs.
            % arcId is set by getArcStateForRows (after process()) and attached
            % to errStruct.carrierPhase before buildFromStack is called again.
            % On the current epoch buildFromStack uses the IDs from cpInfo as
            % passed in — these are from the current-epoch state post-process().
            if isfield(cpInfo,'arcId') && numel(cpInfo.arcId) >= 2*Mp
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

        function H_IF = combineJacobians(H_L1, H_L2)
            % combineJacobians  Explicit IF Jacobian combination (utility / tests).
            %
            % For production: H is built by combining full row blocks via buildFromStack.
            % This method is provided for unit tests and diagnostic verification.
            if ~isequal(size(H_L1), size(H_L2))
                error('CarrierIonoFreeRowBuilder:dimensionMismatch', ...
                    'H_L1 size [%s] does not match H_L2 size [%s].', ...
                    num2str(size(H_L1)), num2str(size(H_L2)));
            end
            sigL1 = revgnss.SignalDefinition.get('L1');
            sigL2 = revgnss.SignalDefinition.get('L2');
            [alpha, beta] = revgnss.IonoFreeCombination.coefficients( ...
                sigL1.frequency_Hz, sigL2.frequency_Hz);
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
