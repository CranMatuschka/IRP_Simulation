classdef OrbitPropagator
    % OrbitPropagator  Circular analytic, two-body RK4, and J2 RK4 propagation.
    %
    % Supported modes:
    %   - circularAnalytic
    %   - twoBodyRk4
    %   - j2Rk4
    %
    % Frame model:
    %   RK4 propagation is performed in an Earth-centred inertial-like frame, then
    %   mapped to the ECEF-like measurement frame using constant Earth rotation.
    %
    % Limitations:
    %   J2 is implemented. Higher-order gravity, SRP, drag, third bodies,
    %   stationkeeping, manoeuvres, real orbit products, and full IERS/EOP frame
    %   handling are not implemented in oo_v1.
    %
    % Usage:
    %   op = models.orbit.OrbitPropagator(cfg);
    %   [r_ecef, v_ecef] = op.propagate(t_s);

    properties
        altitudeMean_m    (1,1) double = 500e3    % mean orbit altitude [m]
        inclination_rad   (1,1) double = 45*pi/180
        raan_rad          (1,1) double = 0         % right ascension of ascending node
        trueAnomaly0_rad  (1,1) double = 0         % initial true anomaly (t=0)
        epochGMST_rad     (1,1) double = 0         % GMST at t=0 [rad]
        orbitMode = 'circularAnalytic'             % 'circularAnalytic'|'twoBodyRk4'|'j2Rk4'
    end

    properties (Constant, Access = private)
        GM   = revgnss.Constants.EARTH_GM_M3PS2;
        Re   = revgnss.Constants.EARTH_RADIUS_M;
        omgE = revgnss.Constants.EARTH_OMEGA_RADPS;
    end

    properties (Access = private)
        % Truth-only luni-solar/SRP perturbation config (R-3). Default disabled -> the RK4
        % integration takes the base-model branch and the truth trajectory is byte-identical.
        truthPerturb = struct('enable', false)

        % Optional explicit t=0 ECI initial state [r(3); v(3)] that OVERRIDES the element-derived
        % IC (used by the federated instance layer to run each swarm member on its own absolute
        % helix orbit via a single-asset run). Empty (default) -> the element IC is used and every
        % existing config is byte-identical. Only meaningful for the RK4 modes (twoBodyRk4/j2Rk4),
        % which integrate from initialEciState(); the constructor rejects it for circularAnalytic.
        eciState0 = []
    end

    methods
        function obj = OrbitPropagator(cfg)
            if nargin == 0; return; end
            if isfield(cfg,'altitudeMean_m');   obj.altitudeMean_m   = cfg.altitudeMean_m;   end
            if isfield(cfg,'inclination_rad');  obj.inclination_rad  = cfg.inclination_rad;  end
            if isfield(cfg,'raan_rad');         obj.raan_rad         = cfg.raan_rad;         end
            if isfield(cfg,'trueAnomaly0_rad'); obj.trueAnomaly0_rad = cfg.trueAnomaly0_rad; end
            if isfield(cfg,'epochGMST_rad');    obj.epochGMST_rad    = cfg.epochGMST_rad;    end
            % Accept cfg.mode (when called as OrbitPropagator(cfg.orbit))
            % or cfg.orbit.mode (when called as OrbitPropagator(cfg)).
            if isfield(cfg,'mode') && ~isempty(cfg.mode)
                obj.orbitMode = cfg.mode;
            elseif isfield(cfg,'orbit') && isfield(cfg.orbit,'mode') && ~isempty(cfg.orbit.mode)
                obj.orbitMode = cfg.orbit.mode;
            end
            % Truth-only luni-solar + SRP perturbations (R-3), read from
            % cfg.truth.perturbations (or cfg.orbit.truth.perturbations). Default off.
            obj.truthPerturb = models.orbit.OrbitPerturbations.configFrom(cfg);
            % Optional explicit ECI initial state override (federated instance layer). Requires an
            % RK4 mode -- circularAnalytic recomputes the IC from elements inline and would silently
            % ignore it, so reject that combination rather than mislead the caller.
            if isfield(cfg,'eciState0') && numel(cfg.eciState0) == 6
                if strcmpi(obj.orbitMode, 'circularAnalytic')
                    error('OrbitPropagator:eciState0NeedsRk4', ...
                        ['cfg.orbit.eciState0 (explicit ECI IC) requires an RK4 mode ' ...
                         '(twoBodyRk4/j2Rk4); it is ignored by circularAnalytic.']);
                end
                obj.eciState0 = cfg.eciState0(:);
            end
        end

        function [r_ecef_m, v_ecef_mps] = propagate(obj, t_s)
            % propagate  Return ECEF position and velocity at time t_s.
            %
            % t_s may be a scalar or vector [s].
            % For RK4 modes pass t_s as a sorted vector for efficiency;
            % each scalar call integrates from t=0 independently (O(t_k/dt)).
            if strcmpi(obj.orbitMode, 'twoBodyRk4')
                [r_ecef_m, v_ecef_mps] = obj.propagateRk4_(t_s, 'twoBody');
                return
            end
            if strcmpi(obj.orbitMode, 'j2Rk4')
                [r_ecef_m, v_ecef_mps] = obj.propagateRk4_(t_s, 'j2');
                return
            end

            t_s = t_s(:);
            n = numel(t_s);

            a   = obj.Re + obj.altitudeMean_m;   % semi-major axis [m]
            n0  = sqrt(obj.GM / a^3);             % mean motion [rad/s]
            inc = obj.inclination_rad;
            OM  = obj.raan_rad;

            r_ecef_m   = zeros(3, n);
            v_ecef_mps = zeros(3, n);

            for k = 1:n
                tk = t_s(k);
                nu = obj.trueAnomaly0_rad + n0 * tk;  % true anomaly (circular)

                % Position and velocity in perifocal (ECI) frame
                r_pf = a * [cos(nu); sin(nu); 0];
                v_pf = sqrt(obj.GM / a) * [-sin(nu); cos(nu); 0];

                % Rotate perifocal -> ECI using Euler 3-1-3 (OM, inc, 0)
                Ri = rotZ(OM) * rotX(inc) * rotZ(0);
                r_eci = Ri * r_pf;
                v_eci = Ri * v_pf;

                % ECI -> ECEF (Earth rotation)
                theta_gmst = obj.epochGMST_rad + obj.omgE * tk;
                Re2E = rotZ(-theta_gmst);   % positive theta rotates ECI rel to ECEF

                r_ecef_m(:,k)   = Re2E * r_eci;
                v_ecef_mps(:,k) = Re2E * (v_eci - cross([0;0;obj.omgE], r_eci));
            end

            if n == 1
                r_ecef_m   = r_ecef_m(:,1);
                v_ecef_mps = v_ecef_mps(:,1);
            end
        end

        function [r_i, v_i] = initialEciState(obj)
            % initialEciState  ECI position/velocity at t=0 from the circular elements.
            % This is the same t=0 inertial state the RK4 modes integrate from.
            if ~isempty(obj.eciState0)
                % Explicit override (federated per-asset helix IC) -> the RK4 modes integrate this
                % state instead of the element-derived one. Empty by default (byte-identical).
                r_i = obj.eciState0(1:3);
                v_i = obj.eciState0(4:6);
                return
            end
            a    = obj.Re + obj.altitudeMean_m;
            nu0  = obj.trueAnomaly0_rad;
            r_pf = a * [cos(nu0); sin(nu0); 0];
            v_pf = sqrt(obj.GM / a) * [-sin(nu0); cos(nu0); 0];
            Ri   = rotZ(obj.raan_rad) * rotX(obj.inclination_rad) * rotZ(0);
            r_i  = Ri * r_pf;
            v_i  = Ri * v_pf;
        end

        function n = meanMotion(obj)
            % meanMotion  Circular mean motion [rad/s] of the reference orbit.
            a = obj.Re + obj.altitudeMean_m;
            n = sqrt(obj.GM / a^3);
        end

        function [r_ecef_m, v_ecef_mps] = propagateFromEciState(obj, r0_eci, v0_eci, t_s)
            % propagateFromEciState  RK4-propagate an ARBITRARY initial ECI state and
            % rotate to ECEF, using the same dynamics family as the configured RK4 mode.
            % Used to propagate physically-real swarm-formation members from a relative
            % (Clohessy-Wiltshire) offset off the primary chief. t_s is a nondecreasing
            % vector [s]; the returned columns align with t_s.
            model = 'twoBody';
            if contains(lower(obj.orbitMode), 'j2'); model = 'j2'; end
            [r_ecef_m, v_ecef_mps] = obj.integrateAndRotate_(r0_eci(:), v0_eci(:), t_s, model);
        end
    end

    methods (Access = private)

        function [r_ecef_m, v_ecef_mps] = propagateRk4_(obj, t_s, model)
            % propagateRk4_  RK4 numerical propagation from analytic circular t=0 state.
            [r_i, v_i] = obj.initialEciState();
            [r_ecef_m, v_ecef_mps] = obj.integrateAndRotate_(r_i, v_i, t_s, model);
        end

        function [r_ecef_m, v_ecef_mps] = integrateAndRotate_(obj, r_i, v_i, t_s, model)
            % integrateAndRotate_  Shared RK4-in-ECI + ECI->ECEF core for the RK4 modes.
            t_s = t_s(:);
            if any(isnan(t_s)) || any(isinf(t_s))
                error('OrbitPropagator:invalidTime', ...
                    'propagateRk4_: t_s must not contain NaN or Inf.');
            end
            if any(t_s < 0)
                error('OrbitPropagator:negativeTime', ...
                    'propagateRk4_: t_s must not be negative.');
            end
            if numel(t_s) > 1 && any(diff(t_s) < 0)
                error('OrbitPropagator:nonMonotoneTime', ...
                    'propagateRk4_: t_s must be nondecreasing.');
            end

            % r_i, v_i are the caller-supplied initial ECI state at t=0.
            n   = numel(t_s);
            r_ecef_m   = zeros(3, n);
            v_ecef_mps = zeros(3, n);

            t_prev = 0;
            for k = 1:n
                dt = t_s(k) - t_prev;
                if dt > 0
                    nSub = max(1, ceil(dt / 10));
                    dts  = dt / nSub;
                    for j = 1:nSub
                        if obj.truthPerturb.enable
                            tAbs = t_prev + (j-1)*dts;   % absolute time at the sub-step start
                            [r_i, v_i] = models.orbit.OrbitDynamics.rk4StepWithAccel( ...
                                r_i, v_i, dts, model, ...
                                @(rr,tt) models.orbit.OrbitPerturbations.accel(rr, tt, obj.truthPerturb), ...
                                tAbs);
                        else
                            [r_i, v_i] = models.orbit.OrbitDynamics.rk4Step(r_i, v_i, dts, model);
                        end
                    end
                end
                t_prev = t_s(k);
                theta  = obj.epochGMST_rad + obj.omgE * t_s(k);
                R      = rotZ(-theta);
                r_ecef_m(:,k)   = R * r_i;
                v_ecef_mps(:,k) = R * (v_i - cross([0;0;obj.omgE], r_i));
            end

            if n == 1
                r_ecef_m   = r_ecef_m(:,1);
                v_ecef_mps = v_ecef_mps(:,1);
            end
        end

    end
end

% File-scope rotation helpers
function R = rotZ(a)
    R = [cos(a),-sin(a),0; sin(a),cos(a),0; 0,0,1];
end
function R = rotX(a)
    R = [1,0,0; 0,cos(a),-sin(a); 0,sin(a),cos(a)];
end
