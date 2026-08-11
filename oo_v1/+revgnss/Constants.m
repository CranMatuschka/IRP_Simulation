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

        % Earth J2 zonal-harmonic coefficient (EGM2008)
        EARTH_J2 = 1.08262668e-3;

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

        % Frequency at which ionosphere CLIMATOLOGY AMPLITUDES are specified [Hz].
        %
        % This is NOT a band accessor and must never be used to answer "what
        % frequency is this run measuring at" -- revgnss.SignalUtils owns that
        % question and deliberately has no canonical fallback. This constant
        % exists for the opposite reason: cfg.errors.ionosphere.*.verticalDelayL1_m
        % (5.0 m), the Klobuchar amp/DC (20 ns / 5 ns) and
        % stochastic.sigmaVDelayL1_ss_m are PHYSICAL 1575.42 MHz quantities. They
        % stay pinned here however the scenario retunes the carrier, and are
        % converted to the run's reference band by
        % models.atmosphere.IonosphereModel.climatologyAnchorScale.
        IONO_ANCHOR_L1_HZ = 1575.42e6;
    end

    methods (Static)
        function c = c()
            % Shorthand for SPEED_OF_LIGHT_MPS
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
        end
    end
end
