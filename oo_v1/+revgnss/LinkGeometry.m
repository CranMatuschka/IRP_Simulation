classdef LinkGeometry
    % LinkGeometry  Shared measurement geometry and Jacobian helpers.
    %
    % Stage 56: consolidates duplicated code/carrier geometry and Jacobian
    % logic into a single shared helper. CodeJacobianBuilder and
    % CarrierMeasurementBuilder both use this class for tower position,
    % receiver antenna position, analytic LOS Jacobians, and finite-difference
    % position/attitude Jacobians. No new physics — pure consolidation.
    %
    % Used by:
    %   CodeJacobianBuilder     — all geometry/Jacobian paths
    %   CarrierMeasurementBuilder — analytic + FD geometry/Jacobian paths
    %
    % Sign convention (shared with both callers):
    %   H(position) = (r_ant - r_tower)' / rho   (range increases as receiver
    %                  moves away from tower)

    methods (Static)

        function r_twr = modelTowerPosition(cfg, tower, towerIdx)
            % modelTowerPosition  Model-side tower ECEF with optional survey offset.
            r_twr = revgnss.MeasurementModelUtils.towerPositionEcef( ...
                cfg, tower, towerIdx, 'model');
        end

        function r_twr = truthTowerPosition(cfg, tower, towerIdx)
            % truthTowerPosition  Truth-side tower ECEF with optional survey offset.
            r_twr = revgnss.MeasurementModelUtils.towerPositionEcef( ...
                cfg, tower, towerIdx, 'truth');
        end

        function r_ant = receiverAntennaPosition(r_cm, euler_rad, lever_body_m)
            % receiverAntennaPosition  Receiver ECEF antenna from CoM + attitude + lever.
            r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm, euler_rad, lever_body_m);
        end

        function rho = modelRangeOnly(cfg, towers, towerIdx, antennaIdx, ...
                r_cm, euler_rad, leverArms_model, ~)
            % modelRangeOnly  Model corrected range for FD Jacobian evaluation.
            % Delegates to MeasurementModelUtils. No clock or stochastic terms.
            rho = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                cfg, towers, towerIdx, antennaIdx, r_cm, euler_rad, leverArms_model);
        end

        function g = analyticLosJacobian(cfg, towers, towerIdx, antennaIdx, ...
                r_cm, euler_rad, leverArms_model)
            % analyticLosJacobian  Analytic geometry struct for one tower/antenna pair.
            %
            % Returns g with fields:
            %   r_tower_model_m  — model tower ECEF [3x1]
            %   r_ant_model_m    — receiver antenna ECEF [3x1]
            %   delta_m          — r_ant - r_tower [3x1]
            %   range_m          — norm(delta_m), clamped to >= 1 m for numerical safety
            %   losRow           — (r_ant - r_twr)'/rho as [1x3] row vector
            %   elevation_rad    — elevation angle from tower to receiver [rad]
            %
            % The analytic path is used only when doFD=false, i.e., when all
            % model-side range corrections (Sagnac, Shapiro, PCO, PCV) are off.
            % PCO is therefore not applied here — it is only needed in FD mode
            % (where MeasurementModelUtils.modelRangeOnly handles it).
            lever = leverArms_model(:, antennaIdx);
            r_twr = revgnss.MeasurementModelUtils.towerPositionEcef( ...
                cfg, towers{towerIdx}, towerIdx, 'model');
            r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm, euler_rad, lever);
            delta = r_ant - r_twr;
            rho   = norm(delta);
            if rho < 1; rho = 1; end
            g.r_tower_model_m = r_twr;
            g.r_ant_model_m   = r_ant;
            g.delta_m         = delta;
            g.range_m         = rho;
            g.losRow          = (delta / rho)';
            g.elevation_rad   = revgnss.GeometryUtils.elevationAngle(r_twr, r_ant);
        end

        function H_pos = finiteDiffPositionJacobian(cfg, towers, towerIdx, antennaIdx, ...
                r_cm, euler_rad, leverArms_model, step_m)
            % finiteDiffPositionJacobian  1x3 central-difference position Jacobian.
            if nargin < 8 || isempty(step_m); step_m = 1.0; end
            H_pos = zeros(1, 3);
            for ki = 1:3
                rp = r_cm; rp(ki) = rp(ki) + step_m;
                rm = r_cm; rm(ki) = rm(ki) - step_m;
                hp = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                    cfg, towers, towerIdx, antennaIdx, rp, euler_rad, leverArms_model);
                hm = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                    cfg, towers, towerIdx, antennaIdx, rm, euler_rad, leverArms_model);
                H_pos(ki) = (hp - hm) / (2 * step_m);
            end
        end

        function H_att = finiteDiffAttitudeJacobian(cfg, towers, towerIdx, antennaIdx, ...
                r_cm, euler_rad, leverArms_model, step_rad)
            % finiteDiffAttitudeJacobian  1x3 central-difference attitude Jacobian.
            %
            % eulerZYX mode (default):       perturbs Euler angles ±step.
            % quaternionErrorState mode:     perturbs body-frame DCM ±step along
            %   each axis ke: C_pert = C_nominal * Exp([±step*e_ke]_x)
            %   → d(range)/d(delta_theta_ke), consistent with error-state EKF.
            if nargin < 8 || isempty(step_rad); step_rad = 1e-6; end
            H_att = zeros(1, 3);
            % Check parameterization
            useQES = false;
            try
                useQES = strcmp(cfg.estimator.attitude.parameterization, 'quaternionErrorState');
            catch; end
            if useQES
                % quaternionErrorState: perturb nominal DCM in body frame
                if numel(leverArms_model) < 3 || antennaIdx > size(leverArms_model,2)
                    return
                end
                lever = leverArms_model(:, antennaIdx);
                r_twr = revgnss.LinkGeometry.modelTowerPosition(cfg, towers{towerIdx}, towerIdx);
                C_nom = revgnss.AttitudeKinematics.bodyToEcefRotation(euler_rad);
                for ke = 1:3
                    dp = zeros(3,1); dp(ke) = step_rad;
                    dm = zeros(3,1); dm(ke) = -step_rad;
                    Cp = revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm(C_nom, dp);
                    Cm = revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm(C_nom, dm);
                    rp = r_cm(:) + Cp * lever(:);
                    rm = r_cm(:) + Cm * lever(:);
                    hp = max(norm(r_twr(:) - rp), 1);
                    hm = max(norm(r_twr(:) - rm), 1);
                    H_att(ke) = (hp - hm) / (2 * step_rad);
                end
            else
                % eulerZYX: perturb Euler angles (legacy behavior)
                for ke = 1:3
                    ep = euler_rad; ep(ke) = ep(ke) + step_rad;
                    em = euler_rad; em(ke) = em(ke) - step_rad;
                    hp = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, towerIdx, antennaIdx, r_cm, ep, leverArms_model);
                    hm = revgnss.MeasurementModelUtils.modelRangeOnly( ...
                        cfg, towers, towerIdx, antennaIdx, r_cm, em, leverArms_model);
                    H_att(ke) = (hp - hm) / (2 * step_rad);
                end
            end
        end

        function s = shouldUseAttitudePartials(cfg, observableKind)
            % shouldUseAttitudePartials  Whether attitude Jacobian partials are enabled.
            %
            % observableKind: 'code' | 'carrier' | 'doppler'
            %
            % Preferred (Stage 56): cfg.estimator.attitude.use<Kind>Partials
            % Legacy fallback: cfg.estimator.estimateAttitude &&
            %                  cfg.estimator.estimateAttitudeFromPseudorange
            %   -> enables code and carrier via compatibility path.
            %
            % Returns struct: enabled (logical), source (char), warning (char).
            s.enabled = false;
            s.source  = 'none';
            s.warning = '';
            kind = lower(observableKind);

            % Preferred: cfg.estimator.attitude.use<Kind>Partials (Stage 56)
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'attitude')
                att = cfg.estimator.attitude;
                switch kind
                    case 'code'
                        if isfield(att,'useCodePartials')
                            s.enabled = logical(att.useCodePartials);
                            s.source  = 'cfg.estimator.attitude.useCodePartials';
                            return;
                        end
                    case 'carrier'
                        if isfield(att,'useCarrierPartials')
                            s.enabled = logical(att.useCarrierPartials);
                            s.source  = 'cfg.estimator.attitude.useCarrierPartials';
                            return;
                        end
                    case 'doppler'
                        if isfield(att,'useDopplerPartials')
                            s.enabled = logical(att.useDopplerPartials);
                            s.source  = 'cfg.estimator.attitude.useDopplerPartials';
                            return;
                        end
                end
            end

            % Legacy: estimateAttitude + estimateAttitudeFromPseudorange
            if ismember(kind, {'code','carrier'}) && ...
                    isfield(cfg,'estimator') && ...
                    isfield(cfg.estimator,'estimateAttitude') && ...
                    cfg.estimator.estimateAttitude && ...
                    isfield(cfg.estimator,'estimateAttitudeFromPseudorange') && ...
                    cfg.estimator.estimateAttitudeFromPseudorange
                s.enabled = true;
                s.source  = 'legacy:estimateAttitudeFromPseudorange';
                s.warning = ['Prefer cfg.estimator.attitude.use' ...
                    upper(kind(1)) kind(2:end) 'Partials over estimateAttitudeFromPseudorange.'];
            end
        end

    end
end
