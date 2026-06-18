classdef AttitudeObservability
    % AttitudeObservability  Stage 31 single-asset attitude observability audit.
    %
    % Audits attitude observability from H-matrix attitude columns (Euler states)
    % and lever-arm geometry.  This is an observability audit only; it is NOT an
    % attitude accuracy claim and NOT integer ambiguity fixing.
    %
    % Classifications (in priority order):
    %   'not-estimated'                  — attitude states absent from stateMap
    %   'unobservable-zero-lever-arm'    — all receiver lever arms are zero
    %   'unobservable-zero-attitude-columns' — H att cols near-zero (nonzero lever arm)
    %   'observable-float-carrier-or-mixed'  — rank >= 3 and nonzero lever arm
    %   'weak-code-only'                 — rank >= 1, only code rows present
    %   'weak-rank-deficient'            — rank 1–2, carrier or mixed rows
    %   'diagnostic-only'                — fallback when none of the above apply
    %
    % Usage:
    %   s  = revgnss.AttitudeObservability.audit(H, stateMap, cfg, measTypePerRow)
    %   la = revgnss.AttitudeObservability.leverArmStats(cfg)

    methods (Static)

        function s = audit(H, stateMap, cfg, measTypePerRow)
            % audit  Classify attitude observability from H columns and cfg.
            %
            % Inputs:
            %   H               [M x nx]  measurement Jacobian
            %   stateMap        struct    from ReverseGNSSEKF; must have euler_idx
            %   cfg             struct    simulation config
            %   measTypePerRow  cell(M,1) optional row type labels
            %
            % Output struct fields:
            %   enabled, classification, isObservable, warnings,
            %   attitudeColumnNorm, attitudeRank, attitudeCondition,
            %   attitudeSingularValues, attitudeSensitiveRowCount,
            %   nReceivers, hasNonzeroLeverArm, leverArmMaxNorm_m,
            %   eulerIdx, omegaIdx, nRows, nCodeRows, nDopplerRows, nCarrierRows

            if nargin < 4; measTypePerRow = {}; end

            s = revgnss.AttitudeObservability.blankStruct_();

            if isempty(H) || ~isnumeric(H)
                s.classification = 'unobservable-zero-attitude-columns';
                s.warnings{end+1} = 'H is empty; attitude columns unavailable.';
                return
            end

            [M, nx] = size(H);
            s.nRows = M;

            % Row type counts
            if ~isempty(measTypePerRow) && numel(measTypePerRow) == M
                s.nCodeRows    = sum(strcmp(measTypePerRow,'code')) + ...
                                 sum(strcmp(measTypePerRow,'ifCode'));
                s.nDopplerRows = sum(strcmp(measTypePerRow,'doppler'));
                s.nCarrierRows = sum(strcmp(measTypePerRow,'carrier'));
            else
                s.nCodeRows = M;
            end

            % State indices
            if isfield(stateMap,'euler_idx')
                s.eulerIdx = stateMap.euler_idx(:)';
            end
            if isfield(stateMap,'omega_idx')
                s.omegaIdx = stateMap.omega_idx(:)';
            end

            % Check attitude states are in state map and within H columns
            if isempty(s.eulerIdx) || max(s.eulerIdx) > nx
                s.classification = 'not-estimated';
                return
            end

            % Lever arm statistics (gated before H audit)
            la = revgnss.AttitudeObservability.leverArmStats(cfg);
            s.nReceivers         = la.nReceivers;
            s.hasNonzeroLeverArm = la.hasNonzeroLeverArm;
            s.leverArmMaxNorm_m  = la.maxNorm_m;

            if ~s.hasNonzeroLeverArm
                s.classification = 'unobservable-zero-lever-arm';
                s.warnings{end+1} = 'All receiver lever arms are zero: attitude is structurally unobservable.';
                return
            end

            % Attitude H columns (Euler states only for observability)
            attIdx = s.eulerIdx(s.eulerIdx <= nx);
            H_att  = H(:, attIdx);

            % Frobenius norm
            s.attitudeColumnNorm = norm(H_att, 'fro');

            if s.attitudeColumnNorm < 1e-12
                s.classification = 'unobservable-zero-attitude-columns';
                s.warnings{end+1} = 'Attitude H columns near-zero despite nonzero lever arms; check body-frame geometry.';
                return
            end

            % SVD rank and condition
            sv  = svd(H_att);
            tol = max(M, numel(attIdx)) * eps(s.attitudeColumnNorm);
            s.attitudeRank           = sum(sv > tol);
            s.attitudeSingularValues = sv(:)';
            if s.attitudeRank >= 2
                s.attitudeCondition = sv(1) / max(sv(s.attitudeRank), eps);
            end

            % Sensitive row count: rows where attitude column norm > 1% of maximum
            rowNorms  = vecnorm(H_att, 2, 2);
            maxRNorm  = max(rowNorms);
            if maxRNorm > 0
                s.attitudeSensitiveRowCount = sum(rowNorms > 0.01 * maxRNorm);
            end

            % Classify by rank and row types
            if s.attitudeRank >= 3
                s.isObservable   = true;
                s.classification = 'observable-float-carrier-or-mixed';
            elseif s.attitudeRank >= 1 && s.nCarrierRows == 0 && s.nDopplerRows == 0
                s.classification = 'weak-code-only';
                s.warnings{end+1} = sprintf( ...
                    'Attitude rank %d: code-pseudorange-only sensitivity; carrier needed for full observability.', ...
                    s.attitudeRank);
            elseif s.attitudeRank >= 1
                s.classification = 'weak-rank-deficient';
                s.warnings{end+1} = sprintf( ...
                    'Attitude rank %d < 3: partial axis sensitivity only.', s.attitudeRank);
            else
                s.classification = 'unobservable-zero-attitude-columns';
                s.warnings{end+1} = 'Attitude SVD rank = 0 after lever-arm check.';
            end
        end

        function la = leverArmStats(cfg)
            % leverArmStats  Return lever-arm statistics from cfg.
            la.nReceivers        = 1;
            la.maxNorm_m         = 0;
            la.norms_m           = 0;
            la.hasNonzeroLeverArm = false;

            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                la.nReceivers = cfg.scenario.nReceivers;
            end
            if isfield(cfg,'asset') && isfield(cfg.asset,'receiverLeverArms_body_m')
                arms = cfg.asset.receiverLeverArms_body_m;
                if ~isempty(arms) && isnumeric(arms)
                    norms        = vecnorm(arms, 2, 1);
                    la.norms_m   = norms(:)';
                    la.maxNorm_m = max(norms);
                    la.hasNonzeroLeverArm = la.maxNorm_m > 1e-6;
                end
            end
        end

    end

    methods (Static, Access = private)

        function s = blankStruct_()
            s.enabled                = true;
            s.classification         = 'diagnostic-only';
            s.isObservable           = false;
            s.warnings               = {};
            s.attitudeColumnNorm     = 0;
            s.attitudeRank           = 0;
            s.attitudeCondition      = NaN;
            s.attitudeSingularValues = [];
            s.attitudeSensitiveRowCount = 0;
            s.nReceivers             = 0;
            s.hasNonzeroLeverArm     = false;
            s.leverArmMaxNorm_m      = 0;
            s.eulerIdx               = [];
            s.omegaIdx               = [];
            s.nRows                  = 0;
            s.nCodeRows              = 0;
            s.nDopplerRows           = 0;
            s.nCarrierRows           = 0;
        end

    end
end
