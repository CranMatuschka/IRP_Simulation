classdef FrameTimeUtils
    % FrameTimeUtils  Simple ECEF/inertial Earth-rotation and Sagnac utilities.
    %
    % Implements a constant-rotation-rate Earth model (WGS-84 Omega_E).
    %
    % LIMITATIONS — explicitly not implemented:
    %   L1. No UT1-UTC correction; rotation rate is constant (no EOPs).
    %   L2. No polar motion (IERS pole offset).
    %   L3. No precession/nutation; z-axis stays aligned with nominal ECEF z.
    %   L4. NOT equivalent to full IERS GCRS/ITRS transformation.
    %   L5. Sagnac correction is first-order only (same as existing RangeCorrections).
    %
    % This foundation is appropriate for metre-to-sub-metre navigation and
    % clock-transfer diagnostics at sub-second flight times.  For IERS-grade
    % timing (< 1 ns) or precise orbit determination, full EOP products are needed.
    %
    % Usage:
    %   theta = revgnss.FrameTimeUtils.earthRotationAngle(t_s);
    %   r_i   = revgnss.FrameTimeUtils.ecefToInertial(r_ecef_m, t_s);
    %   dRho  = revgnss.FrameTimeUtils.sagnacCorrection_m(rx_ecef_m, tx_ecef_m);

    methods (Static)

        function omega = earthRotationRate_radps()
            % earthRotationRate_radps  WGS-84 Earth rotation rate [rad/s].
            omega = 7.2921150e-5;
        end

        function theta = earthRotationAngle(t_s)
            % earthRotationAngle  Approximate Earth rotation angle at time t_s [rad].
            theta = revgnss.FrameTimeUtils.earthRotationRate_radps() * t_s;
        end

        function R = rotMatEcefToInertial(t_s)
            % rotMatEcefToInertial  3×3 rotation matrix from ECEF to inertial-like.
            %   Rotates the ECEF frame by +theta about +z to align with a
            %   vernal-equinox-fixed inertial frame (constant-rotation approximation).
            theta = revgnss.FrameTimeUtils.earthRotationAngle(t_s);
            c = cos(theta); s = sin(theta);
            R = [c, -s, 0; s, c, 0; 0, 0, 1];
        end

        function r_i = ecefToInertial(r_ecef_m, t_s)
            % ecefToInertial  Rotate ECEF position to inertial-like frame at time t_s.
            R = revgnss.FrameTimeUtils.rotMatEcefToInertial(t_s);
            r_i = R * r_ecef_m(:);
        end

        function r_e = inertialToEcef(r_inertial_m, t_s)
            % inertialToEcef  Inverse of ecefToInertial (R' * r_inertial).
            R = revgnss.FrameTimeUtils.rotMatEcefToInertial(t_s);
            r_e = R' * r_inertial_m(:);
        end

        function r_rot = rotateEcefDuringLightTime(r_ecef_m, tau_s)
            % rotateEcefDuringLightTime  Rotate ECEF position by Earth-rotation during tau_s.
            %   Used to account for the movement of an ECEF-fixed transmitter or
            %   receiver during signal flight time.
            theta = revgnss.FrameTimeUtils.earthRotationRate_radps() * tau_s;
            c = cos(theta); s = sin(theta);
            R = [c, -s, 0; s, c, 0; 0, 0, 1];
            r_rot = R * r_ecef_m(:);
        end

        % ---- Stage 58: full ECEF/inertial state transforms -----------------

        function omega_vec = omegaEcef_radps()
            % omegaEcef_radps  Earth rotation vector in ECEF [rad/s].
            omega_vec = [0; 0; revgnss.FrameTimeUtils.earthRotationRate_radps()];
        end

        function [r_i, v_i] = ecefStateToInertial(r_ecef_m, v_ecef_mps, t_s)
            % ecefStateToInertial  Convert ECEF position+velocity to inertial-like frame.
            %   r_i = R * r_e
            %   v_i = R * (v_e + omega_E x r_e)
            R   = revgnss.FrameTimeUtils.rotMatEcefToInertial(t_s);
            omg = revgnss.FrameTimeUtils.omegaEcef_radps();
            r_i = R * r_ecef_m(:);
            v_i = R * (v_ecef_mps(:) + cross(omg, r_ecef_m(:)));
        end

        function [r_e, v_e] = inertialStateToEcef(r_i_m, v_i_mps, t_s)
            % inertialStateToEcef  Convert inertial-like position+velocity to ECEF.
            %   r_e = R' * r_i
            %   v_e = R' * v_i - omega_E x r_e
            R   = revgnss.FrameTimeUtils.rotMatEcefToInertial(t_s);
            omg = revgnss.FrameTimeUtils.omegaEcef_radps();
            r_e = R' * r_i_m(:);
            v_e = R' * v_i_mps(:) - cross(omg, r_e);
        end

        function [dr, dv] = roundTripStateError(r_ecef_m, v_ecef_mps, t_s)
            % roundTripStateError  ECEF->inertial->ECEF round-trip error norms.
            [ri, vi] = revgnss.FrameTimeUtils.ecefStateToInertial(r_ecef_m, v_ecef_mps, t_s);
            [re, ve] = revgnss.FrameTimeUtils.inertialStateToEcef(ri, vi, t_s);
            dr = norm(re - r_ecef_m(:));
            dv = norm(ve - v_ecef_mps(:));
        end

        function dRho_m = sagnacCorrection_m(rx_ecef_m, tx_ecef_m)
            % sagnacCorrection_m  First-order Sagnac correction in metres.
            %
            %   dRho = (Omega × r_tx) · (r_rx - r_tx) / c
            %
            %   Positive when the transmitter is ahead of Earth rotation relative
            %   to the receiver.  Sign convention consistent with RangeCorrections.
            %   This is a first-order approximation; full iterative correction
            %   requires the light-time solution.
            OMEGA = revgnss.FrameTimeUtils.earthRotationRate_radps();
            C     = 299792458;                     % speed of light [m/s]
            rx = rx_ecef_m(:);
            tx = tx_ecef_m(:);
            omega_cross_tx = OMEGA * [-tx(2); tx(1); 0];  % omega_E × r_tx
            dRho_m = dot(omega_cross_tx, rx - tx) / C;
        end

    end
end
