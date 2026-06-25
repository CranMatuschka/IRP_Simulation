classdef AttitudeKinematics
    % AttitudeKinematics  Static utility class for Euler-angle attitude math.
    %
    % Convention: 3-2-1 (ZYX) rotation sequence.
    %   body-to-reference (ECEF): C = Rz(yaw) * Ry(pitch) * Rx(roll)
    %
    % State vector attitude: [roll; pitch; yaw] in radians.
    %
    % Stage 33 additions: convention(), eulerToDcm(), rotateBodyToReference(),
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

        % ================================================================
        % Stage 33: convention hardening methods
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
