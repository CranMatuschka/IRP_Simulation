classdef OrbitDynamics
    % OrbitDynamics  Simple two-body and J2 orbit-force models with RK4 integrator.
    %
    % Operates in an Earth-centred inertial (ECI)-like frame. Earth rotation
    % applied externally by OrbitPropagator (constant Omega_E, no EOP).
    %
    % Limitations: no drag, no SRP, no third bodies, constant Omega_E only.
    %
    % Usage:
    %   a = revgnss.OrbitDynamics.accel_mps2(r_i_m, 'j2');
    %   [r1, v1] = revgnss.OrbitDynamics.rk4Step(r_i_m, v_i_mps, dt_s, 'j2');
    %   E = revgnss.OrbitDynamics.specificEnergy_Jkg(r_i_m, v_i_mps);

    methods (Static)

        function mu = muEarth_m3ps2()
            % muEarth_m3ps2  Earth gravitational parameter [m^3/s^2].
            mu = revgnss.Constants.EARTH_GM_M3PS2;
        end

        function Re = earthRadius_m()
            % earthRadius_m  Earth mean equatorial radius [m].
            Re = revgnss.Constants.EARTH_RADIUS_M;
        end

        function J2 = earthJ2()
            % earthJ2  Earth J2 zonal-harmonic coefficient.
            J2 = revgnss.Constants.EARTH_J2;
        end

        function a = twoBodyAccel_mps2(r_i_m)
            % twoBodyAccel_mps2  Point-mass two-body acceleration [m/s^2].
            mu = revgnss.OrbitDynamics.muEarth_m3ps2();
            r  = norm(r_i_m);
            a  = -(mu / r^3) * r_i_m(:);
        end

        function a = j2Accel_mps2(r_i_m)
            % j2Accel_mps2  J2 zonal-harmonic perturbation acceleration [m/s^2].
            %
            % Oblate-Earth J2 correction in inertial (ECI) coordinates.
            % Valid when z-axis is aligned with Earth rotation axis (no polar motion).
            J2 = revgnss.OrbitDynamics.earthJ2();
            mu = revgnss.OrbitDynamics.muEarth_m3ps2();
            Re = revgnss.OrbitDynamics.earthRadius_m();
            r  = norm(r_i_m(:));
            x  = r_i_m(1); y = r_i_m(2); z = r_i_m(3);
            fac = -1.5 * J2 * mu * Re^2 / r^5;
            zr2 = (z / r)^2;
            a = fac * [(1 - 5*zr2)*x; (1 - 5*zr2)*y; (3 - 5*zr2)*z];
        end

        function a = accel_mps2(r_i_m, model)
            % accel_mps2  Total acceleration for specified force model [m/s^2].
            %   model: 'twoBody' (default) | 'j2'
            if nargin < 2; model = 'twoBody'; end
            a = revgnss.OrbitDynamics.twoBodyAccel_mps2(r_i_m);
            if strcmpi(model, 'j2')
                a = a + revgnss.OrbitDynamics.j2Accel_mps2(r_i_m);
            end
        end

        function [r1, v1] = rk4Step(r_i_m, v_i_mps, dt_s, model)
            % rk4Step  Fourth-order Runge-Kutta step for orbit EOM [m, m/s].
            %   model: 'twoBody' (default) | 'j2'
            if nargin < 4; model = 'twoBody'; end
            acc = @(r) revgnss.OrbitDynamics.accel_mps2(r, model);
            r0 = r_i_m(:); v0 = v_i_mps(:);

            k1r = v0;                k1v = acc(r0);
            k2r = v0+0.5*dt_s*k1v;  k2v = acc(r0+0.5*dt_s*k1r);
            k3r = v0+0.5*dt_s*k2v;  k3v = acc(r0+0.5*dt_s*k2r);
            k4r = v0+dt_s*k3v;       k4v = acc(r0+dt_s*k3r);

            r1 = r0 + (dt_s/6)*(k1r + 2*k2r + 2*k3r + k4r);
            v1 = v0 + (dt_s/6)*(k1v + 2*k2v + 2*k3v + k4v);
        end

        function E = specificEnergy_Jkg(r_i_m, v_i_mps)
            % specificEnergy_Jkg  Two-body specific orbital energy [J/kg].
            %   E = 0.5*v^2 - mu/r  (conservative; does not include J2).
            mu = revgnss.OrbitDynamics.muEarth_m3ps2();
            E  = 0.5 * norm(v_i_mps)^2 - mu / norm(r_i_m);
        end

    end
end
