classdef Constants
    % Constants  Physical and mathematical constants used throughout oo_v1.
    %
    % All values in SI units unless noted.
    %
    % Usage:
    %   c = revgnss.Constants.SPEED_OF_LIGHT_MPS;

    properties (Constant)
        % Speed of light [m/s]
        SPEED_OF_LIGHT_MPS = 2.99792458e8;

        % Earth gravitational parameter [m^3/s^2]
        EARTH_GM_M3PS2 = 3.986004418e14;

        % Earth mean equatorial radius [m]
        EARTH_RADIUS_M = 6378137.0;

        % Earth rotation rate [rad/s]
        EARTH_OMEGA_RADPS = 7.2921150e-5;

        % WGS84 flattening
        EARTH_FLATTENING = 1 / 298.257223563;

        % WGS84 first eccentricity squared
        EARTH_ECC2 = 2*(1/298.257223563) - (1/298.257223563)^2;

        % Nanoseconds per second
        NS_PER_S = 1e9;

        % Pi
        PI = pi;

        % Elevation floor for atmosphere mapping [rad]  ~5 degrees
        ELEVATION_FLOOR_RAD = 5 * pi/180;
    end

    methods (Static)
        function c = c()
            % Shorthand for SPEED_OF_LIGHT_MPS
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
        end
    end
end
