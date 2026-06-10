classdef AttitudeKinematics
    % AttitudeKinematics  Static utility class for Euler-angle attitude math.
    %
    % Convention: 3-2-1 (ZYX) rotation sequence.
    %   body-to-ECEF: C = Rz(yaw) * Ry(pitch) * Rx(roll)
    %
    % State vector attitude: [roll; pitch; yaw] in radians.

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

    end  % methods (Static)
end  % classdef
