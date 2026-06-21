classdef AttitudeErrorStateKinematics
    % AttitudeErrorStateKinematics  Stage 61: quaternion / small-angle error-state helpers.
    %
    % Convention: scalar-first unit quaternion  q = [qw; qx; qy; qz].
    % Body-to-ECEF attitude matching AttitudeKinematics ZYX (3-2-1) convention.
    %
    % No integer fixing. No LAMBDA/MLAMBDA. No PPP-grade claims.
    % No new orbit dynamics. Pure kinematics helper — no EKF math.

    methods (Static)

        function q = quatNormalize(q)
            n = norm(q);
            if n < 1e-14
                warning('AttitudeErrorStateKinematics:zeroQuat', ...
                    'Quaternion has near-zero norm (%.2e); returning identity.', n);
                q = [1;0;0;0];
                return
            end
            q = q(:) / n;
        end

        function q = eulerToQuatZYX(euler_rad)
            % eulerToQuatZYX  ZYX Euler [roll;pitch;yaw] → scalar-first quaternion.
            % Matches AttitudeKinematics.bodyToEcefRotation convention.
            roll  = euler_rad(1);
            pitch = euler_rad(2);
            yaw   = euler_rad(3);
            cr = cos(roll/2);  sr = sin(roll/2);
            cp = cos(pitch/2); sp = sin(pitch/2);
            cy = cos(yaw/2);   sy = sin(yaw/2);
            qw = cy*cp*cr + sy*sp*sr;
            qx = cy*cp*sr - sy*sp*cr;
            qy = sy*cp*sr + cy*sp*cr;
            qz = sy*cp*cr - cy*sp*sr;
            q = revgnss.AttitudeErrorStateKinematics.quatNormalize([qw;qx;qy;qz]);
        end

        function euler_rad = quatToEulerZYX(q)
            % quatToEulerZYX  Scalar-first quaternion → ZYX Euler [roll;pitch;yaw] rad.
            q = q(:) / max(norm(q), 1e-14);
            qw = q(1); qx = q(2); qy = q(3); qz = q(4);
            roll  = atan2(2*(qw*qx + qy*qz), 1 - 2*(qx^2 + qy^2));
            sinP  = 2*(qw*qy - qz*qx);
            sinP  = max(-1, min(1, sinP));   % clamp for numerical safety
            pitch = asin(sinP);
            yaw   = atan2(2*(qw*qz + qx*qy), 1 - 2*(qy^2 + qz^2));
            euler_rad = [roll; pitch; yaw];
        end

        function C = quatToDcm(q)
            % quatToDcm  Body-to-ECEF DCM from scalar-first quaternion.
            q  = q(:) / max(norm(q), 1e-14);
            qw = q(1); qx = q(2); qy = q(3); qz = q(4);
            C = [1-2*(qy^2+qz^2),   2*(qx*qy-qw*qz),   2*(qx*qz+qw*qy);
                   2*(qx*qy+qw*qz), 1-2*(qx^2+qz^2),   2*(qy*qz-qw*qx);
                   2*(qx*qz-qw*qy),   2*(qy*qz+qw*qx), 1-2*(qx^2+qy^2)];
        end

        function dq = deltaQuat(deltaTheta_rad)
            % deltaQuat  Stable small-angle quaternion from 3D rotation vector.
            deltaTheta_rad = deltaTheta_rad(:);
            angle = norm(deltaTheta_rad);
            if angle < 1e-10
                % First-order stable expansion
                dq = [1; 0.5 * deltaTheta_rad];
            else
                axis = deltaTheta_rad / angle;
                dq = [cos(angle/2); sin(angle/2) * axis];
            end
            dq = revgnss.AttitudeErrorStateKinematics.quatNormalize(dq);
        end

        function [q_new, info] = injectRight(q_nominal, deltaTheta_rad)
            % injectRight  Right-multiply error quaternion into nominal.
            %   q_new = normalize(q_nominal ⊗ delta_q(deltaTheta)).
            dq    = revgnss.AttitudeErrorStateKinematics.deltaQuat(deltaTheta_rad(:));
            q_new = revgnss.AttitudeErrorStateKinematics.quatMul_(q_nominal, dq);
            q_new = revgnss.AttitudeErrorStateKinematics.quatNormalize(q_new);
            info.injectionNorm_rad = norm(deltaTheta_rad);
            info.qNormPost         = norm(q_new);
        end

        function q_new = propagateQuatBodyRate(q, omega_body_radps, dt_s)
            % propagateQuatBodyRate  First-order quaternion integration from body rate.
            %   q_dot = 0.5 * q ⊗ [0; omega_body]
            %   q_new = normalize(q + dt * q_dot)
            if dt_s <= 0 || ~isfinite(dt_s)
                q_new = revgnss.AttitudeErrorStateKinematics.quatNormalize(q(:));
                return
            end
            omega = omega_body_radps(:);
            q     = q(:);
            Omega = [0,        -omega(1), -omega(2), -omega(3);
                     omega(1),  0,         omega(3), -omega(2);
                     omega(2), -omega(3),  0,         omega(1);
                     omega(3),  omega(2), -omega(1),  0       ];
            q_new = q + 0.5 * dt_s * Omega * q;
            q_new = revgnss.AttitudeErrorStateKinematics.quatNormalize(q_new);
        end

        function Cpert = smallAnglePerturbedDcm(C_nominal, deltaTheta_rad)
            % smallAnglePerturbedDcm  C_pert = C_nominal * Exp([deltaTheta]_x).
            %   Uses small-angle Rodrigues for compact computation.
            d  = deltaTheta_rad(:);
            sk = [0,-d(3),d(2); d(3),0,-d(1); -d(2),d(1),0];
            % Rodrigues: Exp([d]_x) = I + sk + (1-cos(||d||))/||d||^2 * sk^2
            ang = norm(d);
            if ang < 1e-9
                Rot = eye(3) + sk;
            else
                Rot = eye(3) + sin(ang)/ang * sk + (1-cos(ang))/ang^2 * (sk*sk);
            end
            Cpert = C_nominal * Rot;
        end

        function err_deg = wrapEulerError_deg(est_deg, truth_deg)
            % wrapEulerError_deg  Wrap-aware component error in degrees.
            %   err = atan2(sin(e-t), cos(e-t)) for each component.
            err_deg = atan2d(sind(est_deg(:) - truth_deg(:)), ...
                             cosd(est_deg(:) - truth_deg(:)));
        end

        function lines = summaryLines(info)
            % summaryLines  Report-ready summary from lastAttitudeErrorStateInfo.
            lines = {};
            if ~isstruct(info)
                lines{end+1} = 'No attitude error-state info available.';
                return
            end
            if isfield(info,'parameterization')
                lines{end+1} = sprintf('Parameterization     : %s', info.parameterization);
            end
            if isfield(info,'qNorm')
                lines{end+1} = sprintf('Quaternion norm      : %.9f', info.qNorm);
            end
            if isfield(info,'injectionCount')
                lines{end+1} = sprintf('Injection count      : %d', info.injectionCount);
            end
            if isfield(info,'lastInjectionNorm_rad') && isfinite(info.lastInjectionNorm_rad)
                lines{end+1} = sprintf('Last inj. norm       : %.4e rad (%.4f deg)', ...
                    info.lastInjectionNorm_rad, info.lastInjectionNorm_rad*180/pi);
            end
            if isfield(info,'maxInjectionNorm_rad') && isfinite(info.maxInjectionNorm_rad)
                lines{end+1} = sprintf('Max inj. norm        : %.4e rad (%.4f deg)', ...
                    info.maxInjectionNorm_rad, info.maxInjectionNorm_rad*180/pi);
            end
            if isfield(info,'covarianceResetApplied')
                lines{end+1} = sprintf('Cov reset applied    : %s', mat2str(info.covarianceResetApplied));
            end
            if isfield(info,'eulerReportingOnly')
                lines{end+1} = sprintf('Euler reporting only : %s', mat2str(info.eulerReportingOnly));
            end
        end

    end

    methods (Static, Access = private)

        function q = quatMul_(q1, q2)
            % Hamilton quaternion product (scalar-first).
            w1=q1(1); x1=q1(2); y1=q1(3); z1=q1(4);
            w2=q2(1); x2=q2(2); y2=q2(3); z2=q2(4);
            q = [w1*w2 - x1*x2 - y1*y2 - z1*z2;
                 w1*x2 + x1*w2 + y1*z2 - z1*y2;
                 w1*y2 - x1*z2 + y1*w2 + z1*x2;
                 w1*z2 + x1*y2 - y1*x2 + z1*w2];
        end

    end
end
