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
            dr = models.frames.TruthEarthOrientation.displacementFor_(r_ecef, t_s, e);
        end

        function e = modelConfigFrom(cfg)
            % modelConfigFrom  The EOP correction the ESTIMATOR applies, read from
            %   cfg.frames.eopModel (same field names as frames.truthEop).
            e = struct('enable',false, 'xp_rad',0, 'yp_rad',0, 'omegaExtra_radps',0);
            if isstruct(cfg) && isfield(cfg,'frames') && isfield(cfg.frames,'eopModel')
                me = cfg.frames.eopModel;
                if isfield(me,'enable'); e.enable = logical(me.enable); end
                if isfield(me,'polarMotion_xp_arcsec'); e.xp_rad = me.polarMotion_xp_arcsec * pi/(180*3600); end
                if isfield(me,'polarMotion_yp_arcsec'); e.yp_rad = me.polarMotion_yp_arcsec * pi/(180*3600); end
                if isfield(me,'ut1Rate_error_msPerDay')
                    w = 7.2921150e-5; try; w = revgnss.Constants.EARTH_OMEGA_RADPS; catch; end
                    e.omegaExtra_radps = w * (me.ut1Rate_error_msPerDay * 1e-3 / 86400);
                end
            end
        end

        function dr = towerDisplacementModel(r_ecef, t_s, cfg)
            % towerDisplacementModel  The SAME small rotation applied on the MODEL side,
            %   i.e. the estimator's own EOP correction.
            %
            %   This is NOT truth-assistance. IERS publishes polar motion to ~0.1 mas, so a
            %   real receiver genuinely has these values; leaving the model at nominal
            %   simulates a system that declines to apply a published correction. The
            %   residual geometry error is (phi_truth - phi_model) x r_tower, so setting
            %   cfg.frames.eopModel equal to cfg.frames.truthEop cancels it exactly, and
            %   offsetting it by the IERS uncertainty leaves the realistic residual.
            %
            %   Default OFF -> zero -> byte-identical no-op.
            dr = [0;0;0];
            e = models.frames.TruthEarthOrientation.modelConfigFrom(cfg);
            if ~e.enable; return; end
            dr = models.frames.TruthEarthOrientation.displacementFor_(r_ecef, t_s, e);
        end

        function dr = displacementFor_(r_ecef, t_s, e)
            % displacementFor_  delta_r = phi x r for a resolved EOP struct.
            if isempty(t_s); t_s = 0; end
            phi = [ -e.yp_rad; -e.xp_rad; e.omegaExtra_radps * t_s ];
            dr  = cross(phi, r_ecef(:));
        end

    end
end
