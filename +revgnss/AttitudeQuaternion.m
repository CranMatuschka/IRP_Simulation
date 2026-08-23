classdef AttitudeQuaternion
    % AttitudeQuaternion  Hamilton quaternion operations for attitude sensors.
    %
    % q_A_B is scalar-first [w;x;y;z] and maps B-frame coordinates to
    % A-frame coordinates: v_A = C_A_B(q_A_B) v_B. Products compose from
    % right to left, q_A_C = q_A_B (x) q_B_C. The local attitude error is
    % right multiplicative: q_true = q_nominal (x) Exp(deltaTheta_B).

    methods (Static)
        function c = convention()
            c.quaternionOrder = 'scalar-first [w;x;y;z]';
            c.algebra = 'Hamilton';
            c.rotation = 'q_A_B maps B-frame coordinates into A-frame coordinates';
            c.composition = 'q_A_C = q_A_B (x) q_B_C';
            c.localError = 'q_true = q_nominal (x) Exp(deltaTheta_B)';
            c.bodyRate = 'omega_B/I expressed in B';
            c.inertialFrame = ['constant-omega inertial frame defined by ' ...
                'models.frames.FrameTimeUtils; not a full IERS GCRS realization'];
        end

        function q = normalize(q)
            q = q(:);
            assert(numel(q) == 4 && all(isfinite(q)), ...
                'AttitudeQuaternion:invalidQuaternion', ...
                'Quaternion must contain four finite scalar-first components.');
            n = norm(q);
            assert(n > 1e-14, 'AttitudeQuaternion:zeroQuaternion', ...
                'A zero-norm quaternion cannot define an attitude.');
            q = q / n;
        end

        function q = multiply(q_A_B, q_B_C)
            a = revgnss.AttitudeQuaternion.normalize(q_A_B);
            b = revgnss.AttitudeQuaternion.normalize(q_B_C);
            aw = a(1); av = a(2:4);
            bw = b(1); bv = b(2:4);
            q = [aw*bw - dot(av,bv); ...
                 aw*bv + bw*av + cross(av,bv)];
            q = revgnss.AttitudeQuaternion.normalize(q);
        end

        function q_B_A = inverse(q_A_B)
            q = revgnss.AttitudeQuaternion.normalize(q_A_B);
            q_B_A = [q(1); -q(2:4)];
        end

        function C_A_B = toDcm(q_A_B)
            q = revgnss.AttitudeQuaternion.normalize(q_A_B);
            w = q(1); x = q(2); y = q(3); z = q(4);
            C_A_B = [1-2*(y*y+z*z), 2*(x*y-w*z),   2*(x*z+w*y); ...
                     2*(x*y+w*z),   1-2*(x*x+z*z), 2*(y*z-w*x); ...
                     2*(x*z-w*y),   2*(y*z+w*x),   1-2*(x*x+y*y)];
        end

        function q = fromRotationVector(rotationVector_rad)
            d = rotationVector_rad(:);
            assert(numel(d) == 3 && all(isfinite(d)), ...
                'AttitudeQuaternion:invalidRotationVector', ...
                'Rotation vector must contain three finite components.');
            angle = norm(d);
            if angle < 1e-8
                scale = 0.5 - angle^2/48;
                q = [1-angle^2/8; scale*d];
            else
                q = [cos(angle/2); sin(angle/2) * d/angle];
            end
            q = revgnss.AttitudeQuaternion.normalize(q);
        end

        function rotationVector_rad = toRotationVector(q)
            q = revgnss.AttitudeQuaternion.normalize(q);
            if q(1) < 0
                q = -q;
            end
            s = norm(q(2:4));
            if s < 1e-10
                rotationVector_rad = 2*q(2:4);
            else
                angle = 2*atan2(s, q(1));
                rotationVector_rad = angle*q(2:4)/s;
            end
        end

        function qNext_I_B = propagateBodyRate(q_I_B, omega_B_I_body_radps, dt_s)
            assert(isscalar(dt_s) && isfinite(dt_s) && dt_s >= 0, ...
                'AttitudeQuaternion:invalidTimeStep', ...
                'Attitude propagation time step must be finite and nonnegative.');
            omega = omega_B_I_body_radps(:);
            assert(numel(omega) == 3 && all(isfinite(omega)), ...
                'AttitudeQuaternion:invalidBodyRate', ...
                'Body angular rate must contain three finite components.');
            qIncrement = revgnss.AttitudeQuaternion.fromRotationVector(omega*dt_s);
            qNext_I_B = revgnss.AttitudeQuaternion.multiply(q_I_B, qIncrement);
        end

        function q_I_B = ecefBodyToInertial(q_E_B, t_s)
            assert(isscalar(t_s) && isfinite(t_s), ...
                'AttitudeQuaternion:invalidEpoch', 'Epoch must be finite.');
            theta = models.frames.FrameTimeUtils.earthRotationAngle(t_s);
            q_I_E = revgnss.AttitudeQuaternion.fromRotationVector([0;0;theta]);
            q_I_B = revgnss.AttitudeQuaternion.multiply(q_I_E, q_E_B);
        end

        function q_E_B = inertialBodyToEcef(q_I_B, t_s)
            theta = models.frames.FrameTimeUtils.earthRotationAngle(t_s);
            q_E_I = revgnss.AttitudeQuaternion.fromRotationVector([0;0;-theta]);
            q_E_B = revgnss.AttitudeQuaternion.multiply(q_E_I, q_I_B);
        end

        function angle_rad = geodesicDistance(q1, q2)
            qError = revgnss.AttitudeQuaternion.multiply( ...
                revgnss.AttitudeQuaternion.inverse(q1), q2);
            angle_rad = norm(revgnss.AttitudeQuaternion.toRotationVector(qError));
        end
    end
end
