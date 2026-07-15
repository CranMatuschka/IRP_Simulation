classdef TruthEarthOrientation
    % TruthEarthOrientation  Truth-only Earth-orientation (EOP) error, per-tower displacement.
    %
    %   The measurement/EKF frame uses a constant-Omega Earth rotation with NO polar motion
    %   or UT1/LOD error (FrameTimeUtils, documented limitations). A real deployment that does
    %   not apply EOP corrections mis-places every ground station by the uncorrected pole
    %   offset (Re*x_p ~ 9 m at the surface for x_p ~ 0.3"). This models that as a TRUTH-ONLY
    %   per-tower displacement: the truth tower position is rotated by the small EOP rotation
    %   while the model keeps the nominal ECEF, so the geometry mismatch survives z-h as a real
    %   residual the estimator cannot absorb with a single spacecraft-position shift.
    %
    %   Truth-only, gated (cfg.frames.truthEop.enable), default OFF -> byte-identical no-op.
    %   References: IERS Conventions 2010, Ch. 5 (polar motion, ERA/UT1).

    methods (Static)

        function e = configFrom(cfg)
            e = struct('enable',false, 'xp_rad',0, 'yp_rad',0, 'omegaExtra_radps',0);
            if isstruct(cfg) && isfield(cfg,'frames') && isfield(cfg.frames,'truthEop')
                te = cfg.frames.truthEop;
                if isfield(te,'enable'); e.enable = logical(te.enable); end
                if isfield(te,'polarMotion_xp_arcsec'); e.xp_rad = te.polarMotion_xp_arcsec * pi/(180*3600); end
                if isfield(te,'polarMotion_yp_arcsec'); e.yp_rad = te.polarMotion_yp_arcsec * pi/(180*3600); end
                if isfield(te,'ut1Rate_error_msPerDay')
                    w = 7.2921150e-5; try; w = revgnss.Constants.EARTH_OMEGA_RADPS; catch; end
                    % extra length-of-day [ms/day] -> extra rotation-rate error [rad/s]
                    e.omegaExtra_radps = w * (te.ut1Rate_error_msPerDay * 1e-3 / 86400);
                end
            end
        end

        function dr = towerDisplacement(r_ecef, t_s, cfg)
            % towerDisplacement  ECEF displacement [m] of a tower at r_ecef from the
            %   uncorrected EOP first-order small rotation delta_r = phi x r, with
            %   phi = [-yp; -xp; omegaExtra*t] (polar motion + accumulated UT1 spin error).
            dr = [0;0;0];
            e = models.frames.TruthEarthOrientation.configFrom(cfg);
            if ~e.enable; return; end
            phi = [ -e.yp_rad; -e.xp_rad; e.omegaExtra_radps * t_s ];
            dr  = cross(phi, r_ecef(:));
        end

    end
end
