classdef OrbitDiagnostics
    % OrbitDiagnostics  Stage 28 orbit dynamics diagnostic helpers.
    %
    % Static helper methods for comparing orbit propagation modes and
    % summarising dynamic properties of a given orbit configuration.
    %
    % Usage:
    %   info  = revgnss.OrbitDiagnostics.summarizeModes();
    %   ratio = revgnss.OrbitDiagnostics.j2PerturbationRatio(r_i_m);
    %   [rc, rk, diff] = revgnss.OrbitDiagnostics.compareCircularVsTwoBody(cfg, tGrid_s);
    %   [t, dE] = revgnss.OrbitDiagnostics.energyDriftTwoBody(cfg, duration_s, dt_s);

    methods (Static)

        function info = summarizeModes()
            % summarizeModes  Return struct describing available orbit modes.
            info.circularAnalytic = ['Analytic circular orbit in ECI; no perturbations. ' ...
                'Fast, exact for circular equatorial orbits.'];
            info.twoBodyRk4 = ['RK4 numerical integration with point-mass two-body gravity only. ' ...
                'Conserves energy to < 1 J/kg over 1000 s at LEO with dt=1 s sub-steps.'];
            info.j2Rk4 = ['RK4 numerical integration with two-body + J2 oblateness perturbation. ' ...
                'Non-conservative; energy changes due to J2. ' ...
                'J2 = ' num2str(revgnss.Constants.EARTH_J2, '%.6e') ' (EGM2008).'];
        end

        function ratio = j2PerturbationRatio(r_i_m)
            % j2PerturbationRatio  |a_J2| / |a_two-body| at position r_i_m.
            %
            % Returns a dimensionless ratio. Values < 1e-4 indicate J2 is a
            % small perturbation (typical at GEO; larger at LEO ~1e-3).
            a_tb  = models.orbit.OrbitDynamics.twoBodyAccel_mps2(r_i_m);
            a_j2  = models.orbit.OrbitDynamics.j2Accel_mps2(r_i_m);
            ratio = norm(a_j2) / norm(a_tb);
        end

        function [r_circ_ecef, r_rk4_ecef, diffNorm_m] = compareCircularVsTwoBody(cfgOrbit, tGrid_s)
            % compareCircularVsTwoBody  Position difference between circular and RK4 modes.
            %
            % cfgOrbit: struct with orbit parameters (passed to OrbitPropagator).
            %   Required fields: altitudeMean_m, inclination_rad, raan_rad,
            %                    trueAnomaly0_rad, epochGMST_rad.
            % tGrid_s : sorted time vector [s] from 0.
            %
            % Returns ECEF position arrays (3 x N) and vector of position differences.
            tGrid_s = tGrid_s(:)';

            cfgCirc       = cfgOrbit;
            cfgCirc.orbit.mode = 'circularAnalytic';
            opCirc = models.orbit.OrbitPropagator(cfgCirc);
            r_circ_ecef = zeros(3, numel(tGrid_s));
            for k = 1:numel(tGrid_s)
                [rc, ~] = opCirc.propagate(tGrid_s(k));
                r_circ_ecef(:, k) = rc;
            end

            cfgRk4       = cfgOrbit;
            cfgRk4.orbit.mode = 'twoBodyRk4';
            opRk4 = models.orbit.OrbitPropagator(cfgRk4);
            [r_rk4_ecef, ~] = opRk4.propagate(tGrid_s);

            diffNorm_m = zeros(1, numel(tGrid_s));
            for k = 1:numel(tGrid_s)
                diffNorm_m(k) = norm(r_circ_ecef(:,k) - r_rk4_ecef(:,k));
            end
        end

        function [t_s, dE_Jkg] = energyDriftTwoBody(cfgOrbit, duration_s, dt_s)
            % energyDriftTwoBody  Specific-energy drift over two-body RK4 propagation.
            %
            % cfgOrbit   : struct with orbit parameters (altitudeMean_m required).
            % duration_s : total propagation time [s].
            % dt_s       : step size [s] (default 1 s).
            %
            % Returns time vector and cumulative energy drift |E(t) - E(0)| [J/kg].
            if nargin < 3 || isempty(dt_s); dt_s = 1.0; end

            Re = revgnss.Constants.EARTH_RADIUS_M;
            mu = revgnss.Constants.EARTH_GM_M3PS2;
            a  = Re + cfgOrbit.altitudeMean_m;

            r = [a; 0; 0];
            v = [0; sqrt(mu / a); 0];
            E0 = models.orbit.OrbitDynamics.specificEnergy_Jkg(r, v);

            nSteps = floor(duration_s / dt_s);
            t_s    = (0:nSteps) * dt_s;
            dE_Jkg = zeros(1, nSteps + 1);

            for k = 1:nSteps
                [r, v] = models.orbit.OrbitDynamics.rk4Step(r, v, dt_s, 'twoBody');
                dE_Jkg(k + 1) = abs(models.orbit.OrbitDynamics.specificEnergy_Jkg(r, v) - E0);
            end
        end

    end
end
