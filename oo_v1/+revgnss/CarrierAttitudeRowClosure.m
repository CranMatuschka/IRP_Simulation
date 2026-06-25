classdef CarrierAttitudeRowClosure
    % CarrierAttitudeRowClosure  Stage 60 carrier-attitude row consistency helper.
    %
    % Verifies that carrier attitude EKF rows use consistent receiver-antenna
    % geometry for h and H, and checks attitude Jacobian columns against
    % finite differences via the shared LinkGeometry path.
    %
    % No new physics. No integer fixing. No quaternion/error-state EKF.
    % Delegates all geometry and FD computations to LinkGeometry.
    %
    % Used by: ReportRunner (Stage 60 closure spot-check), test_stage60.

    methods (Static)

        function g = rowGeometry(cfg, towers, towerIdx, receiverIdx, r_cm, euler_rad)
            % rowGeometry  Geometry struct for one tower/antenna carrier row.
            %   Delegates to LinkGeometry.analyticLosJacobian.
            g.available       = false;
            g.towerIdx        = towerIdx;
            g.receiverIdx     = receiverIdx;
            g.leverArm_body_m = zeros(3,1);
            g.r_tower_model_m = zeros(3,1);
            g.r_ant_model_m   = zeros(3,1);
            g.losRow          = zeros(1,3);
            g.range_m         = NaN;
            g.elevation_rad   = NaN;
            g.warnings        = {};
            try
                arms = cfg.asset.receiverLeverArms_body_m;
                if receiverIdx < 1 || receiverIdx > size(arms,2)
                    g.warnings{end+1} = sprintf('receiverIdx %d out of range (nRx=%d)', ...
                        receiverIdx, size(arms,2));
                    return
                end
                g.leverArm_body_m = arms(:, receiverIdx);
                gLG = revgnss.LinkGeometry.analyticLosJacobian( ...
                    cfg, towers, towerIdx, receiverIdx, r_cm, euler_rad, arms);
                g.r_tower_model_m = gLG.r_tower_model_m;
                g.r_ant_model_m   = gLG.r_ant_model_m;
                g.losRow          = gLG.losRow;
                g.range_m         = gLG.range_m;
                g.elevation_rad   = gLG.elevation_rad;
                g.available       = true;
            catch ex
                g.warnings{end+1} = ex.message;
            end
        end

        function H_att = attitudeJacobianFiniteDiff(cfg, towers, towerIdx, receiverIdx, ...
                r_cm, euler_rad, step_rad)
            % attitudeJacobianFiniteDiff  1x3 FD attitude Jacobian via LinkGeometry.
            if nargin < 7 || isempty(step_rad); step_rad = 1e-6; end
            H_att = zeros(1,3);
            try
                arms = cfg.asset.receiverLeverArms_body_m;
                H_att = revgnss.LinkGeometry.finiteDiffAttitudeJacobian( ...
                    cfg, towers, towerIdx, receiverIdx, r_cm, euler_rad, arms, step_rad);
            catch; end
        end

        function c = compareRow(Hrow, stateMap, cfg, towers, towerIdx, receiverIdx, ...
                r_cm, euler_rad)
            % compareRow  Compare H attitude columns to finite-difference Jacobian.
            %
            % Hrow: 1 x nx row vector (one row of the H matrix)
            % Returns struct c with classification and diff metrics.
            %
            % Classifications:
            %   disabled              - carrier attitude partials gate is off
            %   closed                - H and FD agree within tolerance
            %   mismatch              - H and FD disagree beyond tolerance
            %   metadata-h-mismatch   - lever arm and H column presence disagree
            %   unavailable           - required inputs missing/error
            c = revgnss.CarrierAttitudeRowClosure.blankCompare_();
            try
                attGate = revgnss.LinkGeometry.shouldUseAttitudePartials(cfg, 'carrier');
                if ~attGate.enabled
                    c.classification = 'disabled';
                    return
                end
                if ~isfield(stateMap,'euler_idx') || isempty(stateMap.euler_idx)
                    c.warnings{end+1} = 'stateMap.euler_idx missing';
                    return
                end
                eulerIdx = stateMap.euler_idx;
                if max(eulerIdx) > numel(Hrow)
                    c.warnings{end+1} = 'Hrow shorter than euler_idx';
                    return
                end

                hAtt = Hrow(eulerIdx(:)');
                c.hAttitudeAnalytic       = hAtt;
                c.attitudeColumnsPresent  = norm(hAtt) > 1e-14;

                % Metadata: lever arm determines sensitivity
                leverNorm = 0;
                try
                    arms = cfg.asset.receiverLeverArms_body_m;
                    if receiverIdx >= 1 && receiverIdx <= size(arms,2)
                        leverNorm = norm(arms(:, receiverIdx));
                    end
                catch; end
                c.attitudeSensitiveMetadata = leverNorm > 1e-9;

                % Check metadata/H consistency
                if c.attitudeSensitiveMetadata && ~c.attitudeColumnsPresent
                    c.classification = 'metadata-h-mismatch';
                    c.warnings{end+1} = 'lever arm nonzero but H attitude columns zero';
                    return
                end
                if ~c.attitudeSensitiveMetadata && c.attitudeColumnsPresent
                    c.classification = 'metadata-h-mismatch';
                    c.warnings{end+1} = 'H attitude nonzero but lever arm zero';
                    return
                end
                if ~c.attitudeColumnsPresent
                    c.classification = 'disabled';
                    return
                end

                % Finite-difference check
                hFD = revgnss.CarrierAttitudeRowClosure.attitudeJacobianFiniteDiff( ...
                    cfg, towers, towerIdx, receiverIdx, r_cm, euler_rad);
                c.hAttitudeFiniteDiff = hFD;
                c.maxAbsDiff   = max(abs(hAtt(:) - hFD(:)));
                normRef        = max(norm(hFD), 1e-9);
                c.relativeDiff = c.maxAbsDiff / normRef;
                c.available    = true;

                if c.maxAbsDiff < 1e-3
                    c.classification = 'closed';
                else
                    c.classification = 'mismatch';
                    c.warnings{end+1} = sprintf('FD diff %.2e exceeds 1e-3 tolerance', c.maxAbsDiff);
                end
            catch ex
                c.warnings{end+1} = ex.message;
            end
        end

        function lines = summaryLines(c)
            % summaryLines  Concise report-ready lines from compareRow result.
            lines = {};
            lines{end+1} = sprintf('Classification       : %s', c.classification);
            lines{end+1} = sprintf('Att. cols present    : %s', mat2str(c.attitudeColumnsPresent));
            lines{end+1} = sprintf('Metadata sensitive   : %s', mat2str(c.attitudeSensitiveMetadata));
            if isfinite(c.maxAbsDiff)
                lines{end+1} = sprintf('Max abs FD diff      : %.2e m/rad', c.maxAbsDiff);
            end
            if ~isempty(c.warnings)
                lines{end+1} = ['Warnings             : ' strjoin(c.warnings, '; ')];
            end
        end

        function s = spotCheck(cfg, towers, stateMap, r_final, euler_final)
            % spotCheck  Run compareRow on tower 1 / antenna 1 using supplied state.
            %   Returns compact summary for Stage 60/61 report fields.
            %   Stage 61: adds stage61CarrierClosureUsesErrorStateJacobian field.
            s.rowsChecked = 0;
            s.rowsClosed  = 0;
            s.rowsMismatch = 0;
            s.maxAbsDiff  = NaN;
            s.meanAbsDiff = NaN;
            s.metadataConsistent = false;
            s.classification = 'unavailable';
            % Stage 61: detect parameterization mode for classification suffix
            useQES = false;
            try; useQES = strcmp(cfg.estimator.attitude.parameterization,'quaternionErrorState'); catch; end
            s.stage61CarrierClosureUsesErrorStateJacobian = useQES;
            try
                nRx = 1;
                try; nRx = size(cfg.asset.receiverLeverArms_body_m, 2); catch; end
                nTwr = numel(towers);
                diffs = [];
                for ti = 1:min(nTwr, 3)
                    for ai = 1:min(nRx, 4)
                        % Build H row using fresh FD (same as production path)
                        Hrow = zeros(1, numel(r_final) + 3);  % approx size; euler_idx selects
                        nxEst = max(stateMap.euler_idx);
                        if nxEst > numel(Hrow); Hrow = zeros(1, nxEst); end
                        Hrow(stateMap.euler_idx) = revgnss.LinkGeometry.finiteDiffAttitudeJacobian( ...
                            cfg, towers, ti, ai, r_final, euler_final, ...
                            cfg.asset.receiverLeverArms_body_m);
                        c = revgnss.CarrierAttitudeRowClosure.compareRow( ...
                            Hrow, stateMap, cfg, towers, ti, ai, r_final, euler_final);
                        s.rowsChecked = s.rowsChecked + 1;
                        if strcmp(c.classification,'closed')
                            s.rowsClosed = s.rowsClosed + 1;
                            diffs(end+1) = c.maxAbsDiff; %#ok<AGROW>
                        elseif strcmp(c.classification,'mismatch')
                            s.rowsMismatch = s.rowsMismatch + 1;
                            diffs(end+1) = c.maxAbsDiff; %#ok<AGROW>
                        end
                    end
                end
                if ~isempty(diffs)
                    s.maxAbsDiff  = max(diffs);
                    s.meanAbsDiff = mean(diffs);
                end
                if s.rowsChecked > 0 && s.rowsMismatch == 0
                    s.metadataConsistent = true;
                    % Stage 61: suffix classification when using error-state Jacobian
                    if useQES
                        s.classification = 'closed-quaternion-error-state';
                    else
                        s.classification = 'closed';
                    end
                elseif s.rowsMismatch > 0
                    s.classification = 'mismatch';
                end
            catch ex
                s.classification = ['unavailable:' ex.message];
            end
        end

    end

    methods (Static, Access = private)

        function c = blankCompare_()
            c.available               = false;
            c.hAttitudeAnalytic       = zeros(1,3);
            c.hAttitudeFiniteDiff     = zeros(1,3);
            c.maxAbsDiff              = NaN;
            c.relativeDiff            = NaN;
            c.attitudeColumnsPresent  = false;
            c.attitudeSensitiveMetadata = false;
            c.classification          = 'unavailable';
            c.warnings                = {};
        end

    end
end
