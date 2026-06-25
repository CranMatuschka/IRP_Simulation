classdef EkfDynamicsPredictor
    % EkfDynamicsPredictor  Optional physical EKF translational prediction. Stage 58.
    %
    % Converts the ECEF position/velocity state to an inertial-like frame using a
    % constant-Earth-rotation model, propagates with OrbitDynamics RK4 two-body or J2,
    % then converts back to ECEF.  Returns a 6x6 finite-difference translational STM for
    % use in ReverseGNSSEKF.buildF_.
    %
    % Limitations (constant-rotation-frame only):
    %   - No EOP / UT1-UTC / polar motion.
    %   - No precession / nutation.
    %   - No drag, SRP, or third-body perturbations.
    %   - No relativistic orbit or clock model.
    %   - Not a precise orbit determination product.
    %
    % Usage:
    %   m   = EkfDynamicsPredictor.mode(cfg);
    %   [r1,v1,info] = EkfDynamicsPredictor.propagateEcef(r,v,dt,t0,cfg);
    %   Phi = EkfDynamicsPredictor.finiteDiffStm6(r,v,dt,t0,cfg);

    methods (Static)

        function m = mode(cfg)
            % mode  Return the resolved dynamics mode string.
            %   Returns 'constantVelocity', 'twoBody', or 'j2'.
            m = 'constantVelocity';
            if ~isfield(cfg,'estimator') || ~isfield(cfg.estimator,'dynamics') || ...
                    ~isfield(cfg.estimator.dynamics,'mode')
                return
            end
            raw = lower(strtrim(cfg.estimator.dynamics.mode));
            switch raw
                case {'twobody','two_body'}; m = 'twoBody';
                case {'j2','twobodyj2','two_body_j2'}; m = 'j2';
                case 'constantvelocity'; m = 'constantVelocity';
                otherwise
                    warning('EkfDynamicsPredictor:unknownMode', ...
                        'Unknown dynamics mode ''%s''; using constantVelocity.', raw);
            end
        end

        function [r1, v1, info] = propagateEcef(r_ecef_m, v_ecef_mps, dt_s, t0_s, cfg)
            % propagateEcef  Propagate ECEF state by dt_s seconds.
            %
            %   For constantVelocity: r1 = r + dt*v, v1 = v.
            %   For twoBody/j2: convert ECEF->inertial at t0, RK4 propagate, back to ECEF.
            %
            % Returns info struct with energy, frame, mode diagnostics.

            info.mode                    = revgnss.EkfDynamicsPredictor.mode(cfg);
            info.frameModel              = 'constantEarthRotation';
            info.usedInertialPropagation = false;
            info.limitations             = ['No drag, SRP, third bodies, EOP/IERS, ', ...
                'relativistic clock model, or precise orbit products.'];
            info.specificEnergyInitial_Jkg = NaN;
            info.specificEnergyFinal_Jkg   = NaN;
            info.energyDrift_Jkg           = NaN;
            info.forceModel                = 'none';
            info.warnings                  = {};

            r = r_ecef_m(:);
            v = v_ecef_mps(:);

            if norm(r) < 6.3e6
                error('EkfDynamicsPredictor:invalidRadius', ...
                    'r_ecef norm %.1f m is below Earth radius; invalid state.', norm(r));
            end
            if ~isfinite(dt_s) || dt_s <= 0
                r1 = r; v1 = v; return
            end

            if strcmp(info.mode, 'constantVelocity')
                r1 = r + dt_s * v;
                v1 = v;
                info.forceModel = 'none';
                return
            end

            % Inertial propagation path
            if nargin < 4 || isempty(t0_s); t0_s = 0; end
            t1_s = t0_s + dt_s;

            switch info.mode
                case 'twoBody'; fmodel = 'twoBody';
                case 'j2';      fmodel = 'j2';
                otherwise;      fmodel = 'twoBody';
            end
            info.forceModel = fmodel;

            % ECEF -> inertial at t0
            [r_i0, v_i0] = revgnss.FrameTimeUtils.ecefStateToInertial(r, v, t0_s);

            % Energy before propagation
            info.specificEnergyInitial_Jkg = revgnss.OrbitDynamics.specificEnergy_Jkg(r_i0, v_i0);

            % RK4 step in inertial frame
            [r_i1, v_i1] = revgnss.OrbitDynamics.rk4Step(r_i0, v_i0, dt_s, fmodel);

            % Energy after propagation
            info.specificEnergyFinal_Jkg = revgnss.OrbitDynamics.specificEnergy_Jkg(r_i1, v_i1);
            info.energyDrift_Jkg = info.specificEnergyFinal_Jkg - info.specificEnergyInitial_Jkg;

            % Inertial -> ECEF at t1
            [r1, v1] = revgnss.FrameTimeUtils.inertialStateToEcef(r_i1, v_i1, t1_s);
            info.usedInertialPropagation = true;

            % Sanity check
            if ~all(isfinite(r1)) || ~all(isfinite(v1))
                info.warnings{end+1} = 'Non-finite result after propagation; reverting to constantVelocity.';
                r1 = r + dt_s * v;
                v1 = v;
                info.usedInertialPropagation = false;
            end
        end

        function Phi6 = finiteDiffStm6(r_ecef_m, v_ecef_mps, dt_s, t0_s, cfg)
            % finiteDiffStm6  6x6 translational STM via central finite differences.
            %   Columns 1-3: derivatives w.r.t. r (position perturbation).
            %   Columns 4-6: derivatives w.r.t. v (velocity perturbation).

            m = revgnss.EkfDynamicsPredictor.mode(cfg);

            if strcmp(m, 'constantVelocity')
                % Analytic STM for constant-velocity: [I dtI; 0 I]
                Phi6 = [eye(3), dt_s*eye(3); zeros(3), eye(3)];
                return
            end

            % Finite-difference perturbation steps
            dr_step = 1.0;    % metres
            dv_step = 1e-3;   % m/s
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'dynamics')
                d = cfg.estimator.dynamics;
                if isfield(d,'fdPositionStep_m');   dr_step = d.fdPositionStep_m;   end
                if isfield(d,'fdVelocityStep_mps'); dv_step = d.fdVelocityStep_mps; end
            end

            r = r_ecef_m(:);
            v = v_ecef_mps(:);
            Phi6 = zeros(6, 6);

            % Columns 1-3: position derivatives
            for k = 1:3
                dp = zeros(3,1); dp(k) = dr_step;
                [rp,vp] = revgnss.EkfDynamicsPredictor.propagateEcef(r+dp, v, dt_s, t0_s, cfg);
                [rm,vm] = revgnss.EkfDynamicsPredictor.propagateEcef(r-dp, v, dt_s, t0_s, cfg);
                Phi6(1:3, k) = (rp - rm) / (2*dr_step);
                Phi6(4:6, k) = (vp - vm) / (2*dr_step);
            end

            % Columns 4-6: velocity derivatives
            for k = 1:3
                dv = zeros(3,1); dv(k) = dv_step;
                [rp,vp] = revgnss.EkfDynamicsPredictor.propagateEcef(r, v+dv, dt_s, t0_s, cfg);
                [rm,vm] = revgnss.EkfDynamicsPredictor.propagateEcef(r, v-dv, dt_s, t0_s, cfg);
                Phi6(1:3, k+3) = (rp - rm) / (2*dv_step);
                Phi6(4:6, k+3) = (vp - vm) / (2*dv_step);
            end
        end

        function lines = summaryLines(info)
            % summaryLines  Report-ready cell array from info struct.
            lines = {};
            if ~isstruct(info); return; end
            if isfield(info,'mode');         lines{end+1} = sprintf('Dynamics mode    : %s', info.mode); end
            if isfield(info,'forceModel');   lines{end+1} = sprintf('Force model      : %s', info.forceModel); end
            if isfield(info,'frameModel');   lines{end+1} = sprintf('Frame model      : %s', info.frameModel); end
            if isfield(info,'usedInertialPropagation')
                lines{end+1} = sprintf('Inertial prop.   : %s', mat2str(info.usedInertialPropagation));
            end
            if isfield(info,'specificEnergyInitial_Jkg') && isfinite(info.specificEnergyInitial_Jkg)
                lines{end+1} = sprintf('Energy initial   : %.4f J/kg', info.specificEnergyInitial_Jkg);
            end
            if isfield(info,'energyDrift_Jkg') && isfinite(info.energyDrift_Jkg)
                lines{end+1} = sprintf('Energy drift     : %.4e J/kg', info.energyDrift_Jkg);
            end
            if isfield(info,'limitations')
                lines{end+1} = sprintf('Limitations      : %s', info.limitations);
            end
        end

    end
end
