classdef FrameGeometry
    methods (Static)
        %% Earth / frame conversion
        function theta = gmstRad(jd)
            T = (jd - 2451545.0) / 36525.0;
            gmst_deg = 280.46061837 ...
                + 360.98564736629 * (jd - 2451545.0) ...
                + 0.000387933 * T^2 ...
                - (T^3) / 38710000.0;

            theta = deg2rad(mod(gmst_deg, 360.0));
        end

        function R = ecefToEciDcm(jd)
            R = FrameGeometry.rot3(FrameGeometry.gmstRad(jd));
        end

        function R = eciToEcefDcm(jd)
            R = FrameGeometry.ecefToEciDcm(jd).';
        end

        function rEcef_m = geodeticToEcef(lat_deg, lon_deg, alt_m)
            a = 6378137.0;
            f = 1 / 298.257223563;
            e2 = f * (2.0 - f);

            lat = deg2rad(lat_deg);
            lon = deg2rad(lon_deg);

            N = a / sqrt(1.0 - e2 * sin(lat)^2);

            rEcef_m = [(N + alt_m) * cos(lat) * cos(lon);
                       (N + alt_m) * cos(lat) * sin(lon);
                       (N * (1.0 - e2) + alt_m) * sin(lat)];
        end

        function upEcef = geodeticUpEcef(lat_deg, lon_deg)
            lat = deg2rad(lat_deg);
            lon = deg2rad(lon_deg);

            upEcef = [cos(lat) * cos(lon);
                      cos(lat) * sin(lon);
                      sin(lat)];

            upEcef = upEcef ./ norm(upEcef);
        end

        function R_enu_ecef = ecefToEnuDcm(lat_deg, lon_deg)
            lat = deg2rad(lat_deg);
            lon = deg2rad(lon_deg);

            R_enu_ecef = [-sin(lon),              cos(lon),             0.0;
                          -sin(lat)*cos(lon),    -sin(lat)*sin(lon),   cos(lat);
                           cos(lat)*cos(lon),     cos(lat)*sin(lon),   sin(lat)];
        end

        function [rEci_m, vEci_mps] = fixedGroundKinematicsEci(lat_deg, lon_deg, alt_m, jd)
            omegaEarth_radps = 7.2921151467e-5;

            rEcef_m = FrameGeometry.geodeticToEcef(lat_deg, lon_deg, alt_m);
            R = FrameGeometry.ecefToEciDcm(jd);

            rEci_m = R * rEcef_m;
            vEci_mps = cross([0; 0; omegaEarth_radps], rEci_m);
        end

        function [elev_deg, az_deg, uEnu] = elevationAzimuthFromGround( ...
                lat_deg, lon_deg, towerEci_m, targetEci_m, jd)

            losEci = targetEci_m(:) - towerEci_m(:);
            rho = norm(losEci);

            if rho <= eps
                elev_deg = NaN;
                az_deg = NaN;
                uEnu = [NaN; NaN; NaN];
                return;
            end

            uEci = losEci ./ rho;
            uEcef = FrameGeometry.eciToEcefDcm(jd) * uEci;
            uEnu = FrameGeometry.ecefToEnuDcm(lat_deg, lon_deg) * uEcef;

            [elev_deg, az_deg] = FrameGeometry.azElFromLocalUnit(uEnu);
        end

        function [elev_deg, passes] = elevationFromGroundToReceiver( ...
                lat_deg, lon_deg, towerEci_m, receiverEci_m, jd, mask_deg)

            [elev_deg, ~] = FrameGeometry.elevationAzimuthFromGround( ...
                lat_deg, lon_deg, towerEci_m, receiverEci_m, jd);

            passes = isfinite(elev_deg) && elev_deg >= mask_deg;
        end

        function [elev_deg, az_deg] = azElFromLocalUnit(uLocal)
            uLocal = uLocal(:);
            n = norm(uLocal);

            if n <= eps
                elev_deg = NaN;
                az_deg = NaN;
                return;
            end

            uLocal = uLocal ./ n;

            east = uLocal(1);
            north = uLocal(2);
            up = uLocal(3);

            elev_deg = asind(max(-1.0, min(1.0, up)));
            az_deg = mod(atan2d(east, north), 360.0);
        end

        %% Rotation matrices
        function R = rot1(a)
            R = [1, 0, 0;
                 0, cos(a), -sin(a);
                 0, sin(a),  cos(a)];
        end

        function R = rot2(a)
            R = [ cos(a), 0, sin(a);
                  0,      1, 0;
                 -sin(a), 0, cos(a)];
        end

        function R = rot3(a)
            R = [cos(a), -sin(a), 0;
                 sin(a),  cos(a), 0;
                 0,       0,      1];
        end

        function dR = drot1(a)
            dR = [0, 0, 0;
                  0, -sin(a), -cos(a);
                  0,  cos(a), -sin(a)];
        end

        function dR = drot2(a)
            dR = [-sin(a), 0, cos(a);
                   0,      0, 0;
                  -cos(a), 0, -sin(a)];
        end

        function dR = drot3(a)
            dR = [-sin(a), -cos(a), 0;
                   cos(a), -sin(a), 0;
                   0,       0,      0];
        end

        function S = skew(v)
            v = v(:);
            S = [0,    -v(3),  v(2);
                 v(3),  0,    -v(1);
                -v(2),  v(1),  0];
        end

        %% Attitude / quaternion helpers
        function R = euler321(attitude_rad)
            attitude_rad = attitude_rad(:);
            roll = attitude_rad(1);
            pitch = attitude_rad(2);
            yaw = attitude_rad(3);

            R = FrameGeometry.rot3(yaw) * ...
                FrameGeometry.rot2(pitch) * ...
                FrameGeometry.rot1(roll);
        end

        function [R, dR_datt] = euler321WithDerivatives(attitude_rad)
            attitude_rad = attitude_rad(:);
            roll = attitude_rad(1);
            pitch = attitude_rad(2);
            yaw = attitude_rad(3);

            R1 = FrameGeometry.rot1(roll);
            R2 = FrameGeometry.rot2(pitch);
            R3 = FrameGeometry.rot3(yaw);

            dR1 = FrameGeometry.drot1(roll);
            dR2 = FrameGeometry.drot2(pitch);
            dR3 = FrameGeometry.drot3(yaw);

            R = R3 * R2 * R1;

            dR_datt = zeros(3, 3, 3);
            dR_datt(:, :, 1) = R3 * R2 * dR1;
            dR_datt(:, :, 2) = R3 * dR2 * R1;
            dR_datt(:, :, 3) = dR3 * R2 * R1;
        end

        function R_lvlh_to_eci = lvlhToEciDcm(state_eci)
            state_eci = state_eci(:);

            r_eci = state_eci(1:3);
            v_eci = state_eci(4:6);

            r_norm = norm(r_eci);
            h_eci = cross(r_eci, v_eci);
            h_norm = norm(h_eci);

            if r_norm <= 0.0 || h_norm <= 0.0
                error('FrameGeometry:InvalidLVLHState', ...
                    'LVLH frame requires non-zero position and angular momentum.');
            end

            z_lvlh_in_eci = -r_eci ./ r_norm;
            y_lvlh_in_eci = -h_eci ./ h_norm;
            x_lvlh_in_eci = cross(y_lvlh_in_eci, z_lvlh_in_eci);
            x_lvlh_in_eci = x_lvlh_in_eci ./ norm(x_lvlh_in_eci);

            y_lvlh_in_eci = cross(z_lvlh_in_eci, x_lvlh_in_eci);
            y_lvlh_in_eci = y_lvlh_in_eci ./ norm(y_lvlh_in_eci);

            R_lvlh_to_eci = [x_lvlh_in_eci, y_lvlh_in_eci, z_lvlh_in_eci];
        end

        function R_body_to_eci = bodyToEciFromEuler321(attitude_rad, state_eci, attitude_frame)
            if nargin < 3 || isempty(attitude_frame)
                attitude_frame = "LVLH";
            end

            attitude_frame = upper(strtrim(string(attitude_frame)));
            R_euler = FrameGeometry.euler321(attitude_rad);

            if attitude_frame == "LVLH"
                R_body_to_eci = FrameGeometry.lvlhToEciDcm(state_eci) * R_euler;
            elseif attitude_frame == "ECI"
                R_body_to_eci = R_euler;
            else
                error('FrameGeometry:InvalidAttitudeFrame', ...
                    'attitudeFrame must be "LVLH" or "ECI".');
            end
        end

        function q = smallAngleQuat(dtheta)
            dtheta = dtheta(:);
            angle = norm(dtheta);

            if angle < 1e-12
                q = FrameGeometry.normalizeQuat([1.0; 0.5 * dtheta]);
            else
                axis = dtheta ./ angle;
                q = [cos(0.5 * angle); axis .* sin(0.5 * angle)];
            end
        end

        function q = quatMultiply(q1, q2)
            q1 = FrameGeometry.normalizeQuat(q1);
            q2 = FrameGeometry.normalizeQuat(q2);

            w1 = q1(1); v1 = q1(2:4);
            w2 = q2(1); v2 = q2(2:4);

            q = FrameGeometry.normalizeQuat([ ...
                w1*w2 - v1.'*v2;
                w1*v2 + w2*v1 + cross(v1, v2)]);
        end

        function q = normalizeQuat(q)
            q = q(:);
            q = q ./ norm(q);

            if q(1) < 0
                q = -q;
            end
        end

        function C = quatToDcm(q)
            q = FrameGeometry.normalizeQuat(q);

            w = q(1);
            x = q(2);
            y = q(3);
            z = q(4);

            C = [1-2*(y*y+z*z), 2*(x*y-w*z),   2*(x*z+w*y);
                 2*(x*y+w*z),   1-2*(x*x+z*z), 2*(y*z-w*x);
                 2*(x*z-w*y),   2*(y*z+w*x),   1-2*(x*x+y*y)];
        end

        function q = dcmToQuat(C)
            tr = trace(C);

            if tr > 0
                s = sqrt(tr + 1.0) * 2.0;
                q = [0.25*s;
                     (C(3,2)-C(2,3))/s;
                     (C(1,3)-C(3,1))/s;
                     (C(2,1)-C(1,2))/s];
            else
                [~, i] = max(diag(C));

                if i == 1
                    s = sqrt(1 + C(1,1) - C(2,2) - C(3,3)) * 2.0;
                    q = [(C(3,2)-C(2,3))/s;
                         0.25*s;
                         (C(1,2)+C(2,1))/s;
                         (C(1,3)+C(3,1))/s];
                elseif i == 2
                    s = sqrt(1 + C(2,2) - C(1,1) - C(3,3)) * 2.0;
                    q = [(C(1,3)-C(3,1))/s;
                         (C(1,2)+C(2,1))/s;
                         0.25*s;
                         (C(2,3)+C(3,2))/s];
                else
                    s = sqrt(1 + C(3,3) - C(1,1) - C(2,2)) * 2.0;
                    q = [(C(2,1)-C(1,2))/s;
                         (C(1,3)+C(3,1))/s;
                         (C(2,3)+C(3,2))/s;
                         0.25*s];
                end
            end

            q = FrameGeometry.normalizeQuat(q);
        end

        function eul = dcmToEuler321(C)
            pitch = asin(max(-1.0, min(1.0, -C(3,1))));
            roll = atan2(C(3,2), C(3,3));
            yaw = atan2(C(2,1), C(1,1));

            eul = FrameGeometry.wrapToPi([roll; pitch; yaw]);
        end

        function a = wrapToPi(a)
            a = mod(a + pi, 2*pi) - pi;
        end
    end
end