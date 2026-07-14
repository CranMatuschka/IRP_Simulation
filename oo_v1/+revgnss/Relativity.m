classdef Relativity
    % Relativity  Relativistic clock-rate offset for a space clock vs a ground clock (WP-D).
    %
    % A clock on an orbiting spacecraft runs at a different rate than a ground clock due to
    % (a) the gravitational potential difference (higher potential in orbit -> clock runs
    % faster) and (b) special-relativistic time dilation from its inertial velocity (moving
    % clock runs slower). For a circular orbit this is a CONSTANT fractional-frequency offset
    %
    %     y_rel = (GM/c^2)(1/R_earth - 1/r)  -  v_inertial^2/(2 c^2)  [ + v_ground^2/(2 c^2) ]
    %
    % (gravitational blueshift minus SR redshift, optionally plus the ground clock's own
    % Earth-rotation velocity term). It integrates into an accumulating clock BIAS at rate
    % c*y_rel [m/s]. For an eccentric orbit there is an additional PERIODIC term
    % -2 (r . v)/c^2 that is EXACTLY ZERO for a circular orbit (r perpendicular v).
    %
    % Reference-frame note: v must be the INERTIAL (ECI) speed. For a GEO the ECEF velocity
    % is ~0 (nearly Earth-fixed) but the inertial orbital speed is sqrt(GM/r) ~ 3.07 km/s --
    % use geoClockFracFreq (which uses the circular inertial speed) or pass the ECI velocity.
    %
    % Default GEO (alt 35 786 km): y_rel ~ +5.39e-10 (+46.6 us/day); over a 14 400 s run the
    % accumulated bias is ~2.3 km of range. This constant offset is fully OBSERVABLE and is
    % absorbed by the estimated receiver clock-drift state, so for a circular GEO it does not
    % bias the solution; only the (zero) periodic term would.

    methods (Static)

        function y = clockFracFreq(r_m, vInertial_mps, includeGroundRotation)
            % clockFracFreq  Constant relativistic fractional-frequency offset [-].
            %   r_m            radius from Earth centre [m]
            %   vInertial_mps  inertial (ECI) speed of the space clock [m/s]
            %   includeGroundRotation (optional, default true) add the ground clock's
            %                  equatorial Earth-rotation velocity term +v_ground^2/(2c^2).
            if nargin < 3 || isempty(includeGroundRotation); includeGroundRotation = true; end
            c  = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            GM = revgnss.Constants.EARTH_GM_M3PS2;
            Re = revgnss.Constants.EARTH_RADIUS_M;
            grav = (GM / c^2) * (1/Re - 1/r_m);       % gravitational blueshift (sat higher potential)
            sr   = -vInertial_mps^2 / (2 * c^2);      % special-relativistic redshift (sat moving)
            y = grav + sr;
            if includeGroundRotation
                vg = revgnss.Constants.EARTH_OMEGA_RADPS * Re;   % equatorial surface speed ~465 m/s
                y  = y + vg^2 / (2 * c^2);
            end
        end

        function y = geoClockFracFreq(altitude_m, includeGroundRotation)
            % geoClockFracFreq  Offset for a CIRCULAR orbit at the given altitude (v=sqrt(GM/r)).
            if nargin < 2 || isempty(includeGroundRotation); includeGroundRotation = true; end
            GM = revgnss.Constants.EARTH_GM_M3PS2;
            Re = revgnss.Constants.EARTH_RADIUS_M;
            r  = Re + altitude_m;
            v  = sqrt(GM / r);                        % inertial circular orbital speed
            y  = revgnss.Relativity.clockFracFreq(r, v, includeGroundRotation);
        end

        function s = clockBudget(altitude_m, duration_s)
            % clockBudget  Human/report-facing numeric bound for the relativistic clock rate.
            %   Returns a struct with the fractional offset and its practical magnitudes.
            if nargin < 2 || isempty(duration_s); duration_s = NaN; end
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            y = revgnss.Relativity.geoClockFracFreq(altitude_m);
            s.fracFreq          = y;                          % [-]
            s.microsecPerDay    = y * 86400 * 1e6;            % [us/day]
            s.rangeRate_mps     = y * c;                      % [m/s] accumulating clock-range rate
            s.rangeOverRun_m    = y * c * duration_s;         % [m] over the run
            s.periodicResidual_m = 0;                         % exactly 0 for a circular orbit
            s.note = ['Constant offset absorbed by the estimated receiver clock-drift state ' ...
                      '(observable); periodic (eccentricity) residual is zero for a circular orbit.'];
        end

    end
end
