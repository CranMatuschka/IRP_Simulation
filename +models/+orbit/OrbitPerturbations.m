classdef OrbitPerturbations
    % OrbitPerturbations  Truth-only luni-solar third-body + SRP perturbing accelerations.
    %
    %   Provides the perturbing accelerations a real GEO experiences but the EKF's J2-only
    %   dynamics omit: sun + moon third-body gravity (~7e-6 m/s^2 at GEO, comparable to J2's
    %   ~8.5e-6) and cannonball solar-radiation pressure (~1e-7 m/s^2). Added to the TRUTH
    %   propagator only (OrbitPropagator, gated by cfg.orbit.truth.perturbations.*); the EKF
    %   stays J2 (EkfDynamicsPredictor), so the residual is a genuine force-model gap whose
    %   process-noise sigma is sized in realismGradeConfig. Default OFF -> no-op -> golden-safe.
    %
    %   Sun/moon positions use the Montenbruck & Gill (2000) low-precision analytic series
    %   (Sec. 3.3.2), in a J2000 mean-equator ECI ~ the simulation's constant-rotation ECI.
    %   That is adequate for a <=4 h RESIDUAL-force realism study (a constant frame offset
    %   only relabels the perturbation direction; magnitude and time-variation are correct).
    %
    %   References: Montenbruck & Gill, Satellite Orbits (2000), Ch. 3.

    properties (Constant, Access = private)
        AU_M      = 1.495978707e11    % astronomical unit [m]
        GM_SUN    = 1.32712440018e20  % [m^3/s^2]
        GM_MOON   = 4.9028e12         % [m^3/s^2]
        P_SRP_1AU = 4.56e-6           % solar-radiation pressure at 1 AU [N/m^2]
        RE_M      = 6378137.0         % Earth equatorial radius (shadow) [m]
    end

    methods (Static)

        function p = configFrom(cfg)
            % configFrom  Normalise the TRUTH-perturbation config off cfg.orbit (or cfg).
            pt = [];
            if isstruct(cfg)
                if isfield(cfg,'truth') && isfield(cfg.truth,'perturbations')
                    pt = cfg.truth.perturbations;
                elseif isfield(cfg,'orbit') && isfield(cfg.orbit,'truth') && ...
                        isfield(cfg.orbit.truth,'perturbations')
                    pt = cfg.orbit.truth.perturbations;
                end
            end
            p = models.orbit.OrbitPerturbations.configFromStruct(pt);
        end

        function p = configFromStruct(pt)
            % configFromStruct  Normalise a perturbations sub-struct into the runtime config.
            %   Shared by the truth propagator (configFrom) and the EKF propagator (which
            %   passes cfg.estimator.dynamics.perturbations directly). Empty/absent -> disabled.
            p = struct('enable',false, 'luniSolar',false, 'srp',false, ...
                'epochJD_TT',2451545.0, 'ephemeris','mg', ...
                'srpParams',struct('Cr',1.3,'areaToMass_m2pkg',0.02,'shadow','cylindrical'));
            if ~isstruct(pt) || isempty(pt); return; end
            % Sun/Moon ephemeris source: 'mg' (Montenbruck & Gill analytic, default) or
            % 'de440' (JPL DE-440 via models.orbit.De440Ephemeris / the Orekit bridge).
            if isfield(pt,'ephemeris') && ~isempty(pt.ephemeris); p.ephemeris = char(pt.ephemeris); end
            if isfield(pt,'luniSolar') && isfield(pt.luniSolar,'enable'); p.luniSolar = logical(pt.luniSolar.enable); end
            if isfield(pt,'srp')       && isfield(pt.srp,'enable');       p.srp       = logical(pt.srp.enable);       end
            if isfield(pt,'epochJD_TT') && ~isempty(pt.epochJD_TT);       p.epochJD_TT = pt.epochJD_TT;               end
            if isfield(pt,'srp')
                if isfield(pt.srp,'Cr');               p.srpParams.Cr               = pt.srp.Cr;               end
                if isfield(pt.srp,'areaToMass_m2pkg'); p.srpParams.areaToMass_m2pkg = pt.srp.areaToMass_m2pkg; end
                if isfield(pt.srp,'shadow');           p.srpParams.shadow           = pt.srp.shadow;           end
            end
            p.enable = p.luniSolar || p.srp;
        end

        function a = accel(r_sat_eci_m, t_s, p)
            % accel  Total truth perturbing acceleration [m/s^2] at ECI position r, time t_s.
            %   p is the struct from configFrom. Returns [0;0;0] when disabled.
            a = [0;0;0];
            if nargin < 3 || ~isstruct(p) || ~p.enable; return; end
            jd = p.epochJD_TT + t_s/86400;
            src = 'mg'; if isfield(p,'ephemeris') && ~isempty(p.ephemeris); src = p.ephemeris; end
            r  = r_sat_eci_m(:);
            r_sun = [];
            if p.luniSolar
                r_sun  = models.orbit.OrbitPerturbations.sunPositionEci(jd, src);
                r_moon = models.orbit.OrbitPerturbations.moonPositionEci(jd, src);
                a = a + models.orbit.OrbitPerturbations.thirdBody_(r, r_sun, ...
                        models.orbit.OrbitPerturbations.GM_SUN);
                a = a + models.orbit.OrbitPerturbations.thirdBody_(r, r_moon, ...
                        models.orbit.OrbitPerturbations.GM_MOON);
            end
            if p.srp
                if isempty(r_sun); r_sun = models.orbit.OrbitPerturbations.sunPositionEci(jd, src); end
                a = a + models.orbit.OrbitPerturbations.srpAccel_(r, r_sun, p.srpParams);
            end
        end

        function r = sunPositionEci(jd_tt, source)
            % sunPositionEci  Sun position [m], geocentric ECI (EME2000). Default = the
            % Montenbruck & Gill (2000) low-precision analytic series (Sec 3.3.2); pass
            % source='de440' for JPL DE-440 via models.orbit.De440Ephemeris (Orekit bridge).
            if nargin >= 2 && strcmpi(source, 'de440')
                r = models.orbit.De440Ephemeris.sunEci(jd_tt); return;
            end
            T   = (jd_tt - 2451545.0) / 36525;
            M   = 357.5256 + 35999.049*T;                          % mean anomaly [deg]
            lam = 282.9400 + M + (6892/3600)*sind(M) + (72/3600)*sind(2*M);  % ecliptic long [deg]
            rm  = (149.619 - 2.499*cosd(M) - 0.021*cosd(2*M)) * 1e9;         % distance [m]
            eps = 23.43929111 - 0.0130042*T;                       % obliquity [deg]
            r_ecl = rm * [cosd(lam); sind(lam); 0];
            r = models.orbit.OrbitPerturbations.ecl2eq_(r_ecl, eps);
        end

        function r = moonPositionEci(jd_tt, source)
            % moonPositionEci  Moon position [m], geocentric ECI (EME2000). Default = the
            % Montenbruck & Gill (2000) low-precision analytic series (Sec 3.3.2); pass
            % source='de440' for JPL DE-440 via models.orbit.De440Ephemeris (Orekit bridge).
            if nargin >= 2 && strcmpi(source, 'de440')
                r = models.orbit.De440Ephemeris.moonEci(jd_tt); return;
            end
            T  = (jd_tt - 2451545.0) / 36525;
            L0 = 218.31617 + 481267.88088*T;   % mean longitude [deg]
            l  = 134.96292 + 477198.86753*T;   % moon mean anomaly
            lp = 357.52543 + 35999.04944*T;    % sun  mean anomaly
            F  = 93.27283  + 483202.01873*T;   % argument of latitude
            D  = 297.85027 + 445267.11135*T;   % mean elongation
            % Ecliptic longitude [deg] (leading terms, arcsec)
            dLam = 22640*sind(l) - 4586*sind(l-2*D) + 2370*sind(2*D) + 769*sind(2*l) ...
                 - 668*sind(lp) - 412*sind(2*F) - 212*sind(2*l-2*D) - 206*sind(l+lp-2*D) ...
                 + 192*sind(l+2*D) - 165*sind(lp-2*D) + 148*sind(l-lp) - 125*sind(D) ...
                 - 110*sind(l+lp) - 55*sind(2*F-2*D);
            lam = L0 + dLam/3600;
            % Ecliptic latitude [deg] (leading terms, arcsec)
            beta = 18520*sind(F + (dLam/3600)) - 526*sind(F-2*D) + 44*sind(l+F-2*D) ...
                 - 31*sind(-l+F-2*D) - 25*sind(-2*l+F) - 23*sind(lp+F-2*D) ...
                 + 21*sind(-l+F) + 11*sind(-lp+F-2*D);
            beta = beta/3600;
            % Distance [m]
            rm = 385000e3 - 20905e3*cosd(l) - 3699e3*cosd(2*D-l) - 2956e3*cosd(2*D) ...
               - 570e3*cosd(2*l) + 246e3*cosd(2*l-2*D) - 205e3*cosd(lp-2*D) ...
               - 171e3*cosd(l+2*D) - 152e3*cosd(l+lp-2*D);
            eps = 23.43929111 - 0.0130042*T;
            r_ecl = rm * [cosd(lam)*cosd(beta); sind(lam)*cosd(beta); sind(beta)];
            r = models.orbit.OrbitPerturbations.ecl2eq_(r_ecl, eps);
        end

    end

    methods (Static, Access = private)

        function a = thirdBody_(r_sat, r_body, GM)
            % Battin/M&G third-body perturbation (direct + indirect), ECI [m/s^2].
            d = r_body - r_sat;
            a = GM * ( d / norm(d)^3 - r_body / norm(r_body)^3 );
        end

        function a = srpAccel_(r_sat, r_sun, sp)
            % Cannonball SRP, ECI [m/s^2]: pushes the satellite away from the Sun.
            OP   = models.orbit.OrbitPerturbations;
            d    = r_sat - r_sun;           % Sun -> satellite
            dist = norm(d);
            P    = OP.P_SRP_1AU * (OP.AU_M / dist)^2;
            nu   = 1;
            if strcmpi(sp.shadow, 'cylindrical')
                nu = OP.cylShadow_(r_sat, r_sun);
            end
            a = nu * sp.Cr * sp.areaToMass_m2pkg * P * (d / dist);
        end

        function nu = cylShadow_(r_sat, r_sun)
            % Cylindrical Earth-shadow factor {0,1}: 0 if the satellite is behind Earth.
            OP     = models.orbit.OrbitPerturbations;
            sunHat = r_sun / norm(r_sun);
            proj   = -dot(r_sat, sunHat);            % component toward the anti-sun (shadow) axis
            nu = 1;
            if proj > 0
                perp = norm(r_sat + proj*sunHat);    % distance from the shadow axis
                if perp < OP.RE_M; nu = 0; end
            end
        end

        function r_eq = ecl2eq_(r_ecl, eps_deg)
            % Ecliptic -> equatorial (ECI): rotate about x by +obliquity.
            c = cosd(eps_deg); s = sind(eps_deg);
            R = [1 0 0; 0 c -s; 0 s c];
            r_eq = R * r_ecl(:);
        end

    end
end
