classdef AttitudeKinematics
    % AttitudeKinematics  Static utility class for Euler-angle attitude math.
    %
    % Convention: 3-2-1 (ZYX) rotation sequence.
    %   body-to-reference (ECEF): C = Rz(yaw) * Ry(pitch) * Rx(roll)
    %
    % State vector attitude: [roll; pitch; yaw] in radians.
    %
    % convention(), eulerToDcm(), rotateBodyToReference(),
    %   rotateReferenceToBody(), gimbalMetric(), isNearGimbalLock(),
    %   finiteDiffLeverArmJacobian(), validateDcm().

    methods (Static)

        function C = bodyToEcefRotation(euler_rad)
            % bodyToEcefRotation  Rotation matrix from body frame to ECEF.
            %
            % C_ecef_body = Rz(yaw) * Ry(pitch) * Rx(roll)
            %
            % Columns of C are body-frame unit vectors expressed in ECEF.
            % A body vector v_body transforms to ECEF as: v_ecef = C * v_body

            roll  = euler_rad(1);
            pitch = euler_rad(2);
            yaw   = euler_rad(3);

            cr = cos(roll);  sr = sin(roll);
            cp = cos(pitch); sp = sin(pitch);
            cy = cos(yaw);   sy = sin(yaw);

            Rx = [1,  0,   0;  0, cr, -sr;  0, sr, cr];
            Ry = [cp, 0,  sp;  0,  1,   0; -sp, 0, cp];
            Rz = [cy,-sy,  0; sy, cy,   0;   0,  0,  1];

            C = Rz * Ry * Rx;
        end

        function edot = eulerRatesFromBodyRates(euler_rad, omega_body_radps)
            % eulerRatesFromBodyRates  Euler-angle rates from body angular rates.
            %
            % Kinematic equation for ZYX sequence:
            %   [roll_dot; pitch_dot; yaw_dot] = T(euler) * omega_body
            %
            % Note: singular at pitch = +/- 90 degrees. For v1 this is acceptable;
            % a quaternion representation would remove the singularity.

            roll  = euler_rad(1);
            pitch = euler_rad(2);

            cr = cos(roll);  sr = sin(roll);
            cp = cos(pitch); tp = tan(pitch);

            if abs(cp) < 1e-6
                warning('AttitudeKinematics:gimbalLock', ...
                    'Gimbal lock approaching: pitch = %.2f deg', pitch*180/pi);
                cp = sign(cp) * 1e-6;
                tp = tan(pitch);
            end

            % Transformation matrix: euler_dot = T * omega_body
            T = [1, sr*tp,  cr*tp; ...
                 0, cr,    -sr;    ...
                 0, sr/cp,  cr/cp];

            edot = T * omega_body_radps(:);
        end

        function euler_out = wrapEuler(euler_rad)
            % wrapEuler  Wrap Euler angles to [-pi, pi].
            euler_out = wrapToPi(euler_rad);
        end

        function J = eulerRateJacobian(euler_rad, omega_body_radps)
            % eulerRateJacobian  Analytic Jacobian d/d(eul)[ T(eul) * omega_body ], 3x3.
            %
            % Closed-form replacement for the finite-difference Euler-euler block
            % of the EKF state-transition Jacobian: F(eul,eul) = I + dt * J. Removes the
            % round-off of the central difference and its FD-vs-FD-only spot check.
            % Columns are d/droll, d/dpitch, d/dyaw; the YAW column is exactly zero
            % because T(eul) is yaw-independent (ZYX). Derived and symbolically verified
            % from T = [1 sr*tp cr*tp; 0 cr -sr; 0 sr/cp cr/cp] (see
            % tests/test_euler_jacobian_analytic.m).
            %
            % Guard: near pitch = +/- 90 deg (gimbal lock) cos(pitch) is clamped so the
            % sec^2 / tan entries stay finite (mirrors eulerRatesFromBodyRates). The
            % singularity-FREE path is the quaternion error-state parameterisation
            % (attitude.parameterization = 'quaternionErrorState'), which the default
            % scenario uses; this analytic form hardens the legacy eulerZYX path.
            roll  = euler_rad(1);
            pitch = euler_rad(2);
            w     = omega_body_radps(:);
            w2 = w(2); w3 = w(3);
            cr = cos(roll);  sr = sin(roll);
            cp = cos(pitch); sp = sin(pitch);
            if abs(cp) < 1e-6
                cp = sign(cp + eps) * 1e-6;   % clamp toward the pole (finite, guarded)
            end
            tp   = sp / cp;
            sec2 = 1 / cp^2;
            a = sr*w2 + cr*w3;      % sin(roll)*w2 + cos(roll)*w3
            b = cr*w2 - sr*w3;      % cos(roll)*w2 - sin(roll)*w3
            J = [ tp*b,           sec2*a,     0; ...
                  -sr*w2 - cr*w3, 0,          0; ...
                  b/cp,           (tp/cp)*a,  0];
        end

        function C = eul2rotm321(euler_rad)
            % eul2rotm321  Alias for bodyToEcefRotation (ZYX = 3-2-1 sequence).
            C = revgnss.AttitudeKinematics.bodyToEcefRotation(euler_rad);
        end

        function r_ecef = applyLeverArm(r_body_origin_ecef, euler_rad, leverArm_body_m)
            % applyLeverArm  Compute antenna phase center in ECEF.
            %
            % r_ant_ecef = r_body_origin_ecef + C_ecef_body * leverArm_body
            C = revgnss.AttitudeKinematics.bodyToEcefRotation(euler_rad);
            r_ecef = r_body_origin_ecef(:) + C * leverArm_body_m(:);
        end

        function euler_rad = nadirEulerFromEcef(r_ecef_m, v_ecef_mps, boresight_body)
            % nadirEulerFromEcef  ZYX Euler angles for a nadir-pointing (LVLH) attitude.
            %
            % Returns the constant [roll;pitch;yaw] whose body-to-ECEF DCM
            % (Rz(yaw)Ry(pitch)Rx(roll)) aligns the antenna boresight body axis
            % (default body +Z) with nadir (-r_hat) and the body +X axis with the
            % along-track (velocity) direction -- the standard local-vertical/
            % local-horizontal (LVLH) Earth-pointing attitude. For a GEO fixed in
            % ECEF the nadir direction is constant, so this constant Euler is a
            % nadir lock to <0.01 deg over a day; for fast-moving orbits it is the
            % instantaneous nadir attitude at this r/v and should be recomputed per epoch.
            %
            %   r_ecef_m       [3x1] spacecraft position in ECEF [m]
            %   v_ecef_mps     [3x1] spacecraft velocity in ECEF [m/s] (optional). Defines
            %                        the orbit normal; if empty/near-zero the orbit is
            %                        assumed equatorial-prograde (normal = ECEF +Z).
            %   boresight_body [3x1] body axis to point at nadir (optional, default +Z;
            %                        only +Z supported today -- the antenna face-normal).
            if nargin < 2; v_ecef_mps = []; end
            if nargin < 3 || isempty(boresight_body); boresight_body = [0;0;1]; end
            assert(isequal(boresight_body(:), [0;0;1]), ...
                'AttitudeKinematics:nadirEulerFromEcef: only boresight_body=[0;0;1] is supported.');
            r = r_ecef_m(:);
            assert(norm(r) > 0, ...
                'AttitudeKinematics:nadirEulerFromEcef: r_ecef must be non-zero.');
            rhat = r / norm(r);
            if isempty(v_ecef_mps) || norm(v_ecef_mps) < 1e-6
                nhat = [0;0;1];                     % equatorial-prograde orbit normal
                if abs(dot(rhat, nhat)) > 0.999     % near-polar r -> pick another reference
                    nhat = [0;1;0];
                end
            else
                nhat = cross(r, v_ecef_mps(:));
                nhat = nhat / norm(nhat);
            end
            zb = -rhat;                             % boresight (+Z) -> nadir
            yb = -nhat;                             % pitch axis (+Y) = -orbit normal
            yb = yb - dot(yb, zb) * zb;             % orthogonalise to the boresight
            yb = yb / norm(yb);
            xb = cross(yb, zb);                     % roll axis (+X) -> along-track
            C  = [xb, yb, zb];                      % body-to-ECEF DCM (columns = body axes)
            % Extract ZYX Euler from C = Rz(yaw)Ry(pitch)Rx(roll).
            pitch = -asin(max(-1, min(1, C(3,1))));
            roll  = atan2(C(3,2), C(3,3));
            yaw   = atan2(C(2,1), C(1,1));
            euler_rad = [roll; pitch; yaw];
        end

        % ================================================================
        % Convention hardening methods
        % ================================================================

        function c = convention()
            % convention  Return struct documenting the ZYX Euler convention.
            c.name             = 'ZYX Euler roll-pitch-yaw';
            c.stateOrder       = {'roll','pitch','yaw'};
            c.units            = 'rad';
            c.rotationDirection = 'body_to_reference';
            c.dcmDefinition    = 'C_ref_body = Rz(yaw)*Ry(pitch)*Rx(roll)';
            c.limitation       = ['Euler pitch near +/-90 deg is singular; ' ...
                'not a quaternion/error-state filter.'];
        end

        function C = eulerToDcm(rpy_rad)
            % eulerToDcm  DCM from body to reference frame; validated alias.
            assert(isnumeric(rpy_rad) && numel(rpy_rad) == 3 && all(isfinite(rpy_rad(:))), ...
                'AttitudeKinematics:eulerToDcm: rpy_rad must be finite numeric with 3 elements.');
            C = revgnss.AttitudeKinematics.bodyToEcefRotation(rpy_rad(:));
        end

        function v_ref = rotateBodyToReference(rpy_rad, v_body)
            % rotateBodyToReference  Rotate body vector(s) to reference frame.
            % Supports v_body as 3 x N.
            C = revgnss.AttitudeKinematics.eulerToDcm(rpy_rad);
            v_ref = C * v_body;
        end

        function v_body = rotateReferenceToBody(rpy_rad, v_ref)
            % rotateReferenceToBody  Rotate reference vector(s) to body frame.
            C = revgnss.AttitudeKinematics.eulerToDcm(rpy_rad);
            v_body = C' * v_ref;
        end

        function gm = gimbalMetric(rpy_rad)
            % gimbalMetric  abs(cos(pitch)); approaches 0 near singularity.
            gm = abs(cos(rpy_rad(2)));
        end

        function flag = isNearGimbalLock(rpy_rad, threshold)
            % isNearGimbalLock  True when gimbal metric < threshold.
            if nargin < 2; threshold = 1e-3; end
            flag = revgnss.AttitudeKinematics.gimbalMetric(rpy_rad) < threshold;
        end

        function J = finiteDiffLeverArmJacobian(rpy_rad, lever_body_m, eps_rad)
            % finiteDiffLeverArmJacobian  d/d(rpy)[C(rpy)*lever], size 3x3.
            if nargin < 3; eps_rad = 1e-6; end
            rpy  = rpy_rad(:);
            lev  = lever_body_m(:);
            J    = zeros(3, 3);
            for k = 1:3
                dp = rpy; dp(k) = dp(k) + eps_rad;
                dm = rpy; dm(k) = dm(k) - eps_rad;
                J(:,k) = (revgnss.AttitudeKinematics.bodyToEcefRotation(dp) * lev - ...
                          revgnss.AttitudeKinematics.bodyToEcefRotation(dm) * lev) / (2 * eps_rad);
            end
        end

        function [ok, orthErr, detErr] = validateDcm(C)
            % validateDcm  Check orthogonality and unit determinant.
            orthErr = norm(C' * C - eye(3), 'fro');
            detErr  = abs(det(C) - 1);
            ok      = orthErr < 1e-10 && detErr < 1e-10;
        end

    end  % methods (Static)
end  % classdef
