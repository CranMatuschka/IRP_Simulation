classdef SolidEarthTide
    % SolidEarthTide  Truth-only degree-2 solid-Earth tide displacement of a ground station.
    %
    %   The truth tower position breathes with the sun+moon degree-2 tide (~10-30 cm vertical,
    %   ~12 h period; IERS-2010 in-phase term) while the measurement/EKF model keeps static
    %   towers, so the tidal displacement survives z-h as a real truth-model residual (the
    %   common part is absorbed by the receiver clock; the differential part is a genuine
    %   per-tower geometry error). Truth-only, gated (cfg.effects.solidEarthTide.truth.enable),
    %   default OFF -> byte-identical no-op.
    %
    %   References: IERS Conventions 2010, Ch. 7 (dehanttideinel), degree-2 in-phase Love terms.

    methods (Static)

        function e = configFrom(cfg)
            e = struct('enable',false, 'h2',0.6078, 'l2',0.0847, 'epochJD_TT',2451545.0);
            if isstruct(cfg) && isfield(cfg,'effects') && isfield(cfg.effects,'solidEarthTide')
                se = cfg.effects.solidEarthTide;
                if isfield(se,'truth') && isfield(se.truth,'enable'); e.enable = logical(se.truth.enable); end
                if isfield(se,'loveH2');     e.h2 = se.loveH2;         end
                if isfield(se,'loveL2');     e.l2 = se.loveL2;         end
                if isfield(se,'epochJD_TT'); e.epochJD_TT = se.epochJD_TT; end
            end
        end

        function dr = towerDisplacement(r_ecef, t_s, cfg)
            % towerDisplacement  Degree-2 solid-Earth tide displacement [m] (ECEF) of a
            %   station at r_ecef, from sun + moon, IERS-2010 in-phase Love terms.
            dr = [0;0;0];
            e = models.frames.SolidEarthTide.configFrom(cfg);
            if ~e.enable; return; end
            jd  = e.epochJD_TT + t_s/86400;
            r   = r_ecef(:); rn = norm(r); if rn == 0; return; end
            rh  = r / rn;
            GM_E = 3.986004418e14; Re = 6378137.0;
            try; GM_E = revgnss.Constants.EARTH_GM_M3PS2; Re = revgnss.Constants.EARTH_RADIUS_M; catch; end
            bodies = { models.orbit.OrbitPerturbations.sunPositionEci(jd),  1.32712440018e20; ...
                       models.orbit.OrbitPerturbations.moonPositionEci(jd), 4.9028e12 };
            for b = 1:size(bodies,1)
                Rb_ecef = models.frames.SolidEarthTide.eci2ecef_(bodies{b,1}, t_s);
                Rbn = norm(Rb_ecef); if Rbn == 0; continue; end
                Rbh = Rb_ecef / Rbn;
                cphi = dot(rh, Rbh);
                fac  = (bodies{b,2}/GM_E) * (Re^4 / Rbn^3);
                dr = dr + fac * ( e.h2 * rh * (1.5*cphi^2 - 0.5) ...
                                + 3 * e.l2 * cphi * (Rbh - cphi*rh) );
            end
        end

    end

    methods (Static, Access = private)
        function r_ecef = eci2ecef_(r_eci, t_s)
            % Constant-Omega ECI->ECEF (consistent with the simulation frame; truth-only, approx).
            w = 7.2921150e-5; try; w = revgnss.Constants.EARTH_OMEGA_RADPS; catch; end
            th = w * t_s; c = cos(th); s = sin(th);
            r_ecef = [c s 0; -s c 0; 0 0 1] * r_eci(:);
        end
    end
end
