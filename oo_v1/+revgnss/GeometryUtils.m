classdef GeometryUtils
    % GeometryUtils  Static geometry helpers for GNSS/navigation computations.

    methods (Static)

        function [lat_rad, lon_rad, alt_m] = ecef2geodetic(r_ecef_m)
            % ecef2geodetic  ECEF to geodetic (WGS84) using Bowring iteration.
            x = r_ecef_m(1); y = r_ecef_m(2); z = r_ecef_m(3);
            a = revgnss.Constants.EARTH_RADIUS_M;
            e2 = revgnss.Constants.EARTH_ECC2;

            lon_rad = atan2(y, x);
            p = sqrt(x^2 + y^2);
            lat_rad = atan2(z, p*(1-e2));

            for iter = 1:5   % Bowring iteration
                N = a / sqrt(1 - e2*sin(lat_rad)^2);
                lat_rad = atan2(z + e2*N*sin(lat_rad), p);
            end
            N = a / sqrt(1 - e2*sin(lat_rad)^2);
            alt_m = p/cos(lat_rad) - N;
        end

        function r_ecef = geodetic2ecef(lat_rad, lon_rad, alt_m)
            % geodetic2ecef  Geodetic to ECEF.
            a  = revgnss.Constants.EARTH_RADIUS_M;
            e2 = revgnss.Constants.EARTH_ECC2;
            N  = a / sqrt(1 - e2*sin(lat_rad)^2);
            r_ecef = [(N + alt_m)*cos(lat_rad)*cos(lon_rad); ...
                      (N + alt_m)*cos(lat_rad)*sin(lon_rad); ...
                      (N*(1-e2) + alt_m)*sin(lat_rad)];
        end

        function elev_rad = elevationAngle(r_obs_ecef, r_target_ecef)
            % elevationAngle  Elevation angle from observer to target [rad].
            %
            % Positive when target is above local horizon.
            [lat, lon, ~] = revgnss.GeometryUtils.ecef2geodetic(r_obs_ecef);
            los = r_target_ecef(:) - r_obs_ecef(:);
            los_norm = los / norm(los);

            % Local ENU unit vectors
            up  = [ cos(lat)*cos(lon); cos(lat)*sin(lon); sin(lat)];
            east = [-sin(lon); cos(lon); 0];
            north= [-sin(lat)*cos(lon); -sin(lat)*sin(lon); cos(lat)];

            up_comp = dot(los_norm, up);
            elev_rad = asin(up_comp);
        end

        function R = enu2ecef(lat_rad, lon_rad)
            % enu2ecef  Rotation matrix from ENU to ECEF at geodetic point.
            sl = sin(lat_rad); cl = cos(lat_rad);
            so = sin(lon_rad); co = cos(lon_rad);
            R = [-so,      -sl*co,   cl*co; ...
                  co,      -sl*so,   cl*so; ...
                  0,        cl,      sl];
        end

        function r_ecef = enu2ecef_vector(lat_rad, lon_rad, v_enu)
            % enu2ecef_vector  Rotate a vector from ENU to ECEF.
            R = revgnss.GeometryUtils.enu2ecef(lat_rad, lon_rad);
            r_ecef = R * v_enu(:);
        end

    end
end
