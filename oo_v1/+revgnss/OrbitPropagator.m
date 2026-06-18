classdef OrbitPropagator
    % OrbitPropagator  Simple circular-orbit propagator in ECEF.
    %
    % Limitations (v1):
    %   - Assumes circular orbit (eccentricity = 0)
    %   - No J2 or higher-order gravity terms
    %   - No drag, SRP, or third-body perturbations
    %   - Earth rotation applied via simple ECI->ECEF transformation
    %   - No light-time iteration
    %   - No Sagnac correction
    %
    % Usage:
    %   op = revgnss.OrbitPropagator(cfg);
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

    methods
        function obj = OrbitPropagator(cfg)
            if nargin == 0; return; end
            if isfield(cfg,'altitudeMean_m');   obj.altitudeMean_m   = cfg.altitudeMean_m;   end
            if isfield(cfg,'inclination_rad');  obj.inclination_rad  = cfg.inclination_rad;  end
            if isfield(cfg,'raan_rad');         obj.raan_rad         = cfg.raan_rad;         end
            if isfield(cfg,'trueAnomaly0_rad'); obj.trueAnomaly0_rad = cfg.trueAnomaly0_rad; end
            if isfield(cfg,'epochGMST_rad');    obj.epochGMST_rad    = cfg.epochGMST_rad;    end
            if isfield(cfg,'orbit') && isfield(cfg.orbit,'mode') && ~isempty(cfg.orbit.mode)
                obj.orbitMode = cfg.orbit.mode;
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
    end

    methods (Access = private)

        function [r_ecef_m, v_ecef_mps] = propagateRk4_(obj, t_s, model)
            % propagateRk4_  RK4 numerical propagation from analytic circular t=0 state.
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

            a   = obj.Re + obj.altitudeMean_m;
            inc = obj.inclination_rad;
            OM  = obj.raan_rad;
            nu0 = obj.trueAnomaly0_rad;

            % Initial ECI state from circular analytic formula at t=0
            r_pf = a * [cos(nu0); sin(nu0); 0];
            v_pf = sqrt(obj.GM / a) * [-sin(nu0); cos(nu0); 0];
            Ri   = rotZ(OM) * rotX(inc) * rotZ(0);
            r_i  = Ri * r_pf;
            v_i  = Ri * v_pf;
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
                        [r_i, v_i] = revgnss.OrbitDynamics.rk4Step(r_i, v_i, dts, model);
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
