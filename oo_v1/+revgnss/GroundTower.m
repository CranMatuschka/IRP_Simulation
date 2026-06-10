classdef GroundTower < handle
    % GroundTower  Ground-based transmitter tower for reverse-GNSS.
    %
    % Each tower has:
    %   - Geodetic and ECEF location
    %   - Antenna phase-center offset in ENU
    %   - A ClockModel object for transmitter clock
    %   - Hardware delay
    %
    % Usage:
    %   cfg.id = 1;
    %   cfg.name = 'Tower_1';
    %   cfg.lat_rad = 51.5*pi/180;
    %   cfg.lon_rad = -1.0*pi/180;
    %   cfg.alt_m   = 100;
    %   cfg.antennaOffset_enu_m = [0;0;0];
    %   cfg.hardwareDelay_m = 0.05;
    %   cfg.clock.name = 'Tower1_OCXO';
    %   cfg.clock.clockType = 'OCXO';
    %   cfg.clock.noiseCoeffs.h0 = 1e-24;
    %   cfg.clock.noiseCoeffs.hMinus2 = 1e-26;
    %   ... (other h terms 0)
    %   tower = revgnss.GroundTower(cfg);

    properties
        id              (1,1) double  = 0
        name            (1,:) char    = ''

        % Geodetic location
        lat_rad         (1,1) double  = 0
        lon_rad         (1,1) double  = 0
        alt_m           (1,1) double  = 0

        % Derived ECEF location of tower reference point
        r_ecef_m        (3,1) double  = zeros(3,1)

        % Antenna phase center offset in local ENU frame [m]
        antennaOffset_enu_m (3,1) double = zeros(3,1)

        % Antenna phase center in ECEF [m]
        antennaPhaseCenter_ecef_m (3,1) double = zeros(3,1)

        % Clock object (revgnss.ClockModel)
        clock           revgnss.ClockModel

        % Hardware delay (constant) [m]
        hardwareDelay_m (1,1) double  = 0

        % History
        history         (1,1) struct
    end

    methods
        function obj = GroundTower(cfg)
            if nargin == 0; return; end

            obj.id   = cfg.id;
            obj.name = cfg.name;

            obj.lat_rad = cfg.lat_rad;
            obj.lon_rad = cfg.lon_rad;
            obj.alt_m   = cfg.alt_m;

            if isfield(cfg,'antennaOffset_enu_m')
                obj.antennaOffset_enu_m = cfg.antennaOffset_enu_m(:);
            end
            if isfield(cfg,'hardwareDelay_m')
                obj.hardwareDelay_m = cfg.hardwareDelay_m;
            end

            % Compute ECEF tower reference position
            obj.r_ecef_m = revgnss.GeometryUtils.geodetic2ecef( ...
                obj.lat_rad, obj.lon_rad, obj.alt_m);

            % Compute antenna phase center ECEF
            obj.antennaPhaseCenter_ecef_m = obj.computeAntennaECEF_();

            % Build clock
            obj.clock = revgnss.ClockModel(cfg.clock);

            obj.history.time_s       = [];
            obj.history.clockBias_m  = [];
            obj.history.clockDrift_mps = [];
        end

        % ----------------------------------------------------------------
        function r = getAntennaPositionECEF(obj)
            r = obj.antennaPhaseCenter_ecef_m;
        end

        function b_m = getClockBiasMeters(obj)
            b_m = obj.clock.getBiasMeters();
        end

        function bdot_mps = getClockDriftMetersPerSecond(obj)
            bdot_mps = obj.clock.getDriftMetersPerSecond();
        end

        function stepClock(obj, dt_s)
            obj.clock.step(dt_s);
            obj.history.time_s         = [obj.history.time_s; obj.clock.lastTime_s];
            obj.history.clockBias_m    = [obj.history.clockBias_m; obj.clock.getBiasMeters()];
            obj.history.clockDrift_mps = [obj.history.clockDrift_mps; obj.clock.getDriftMetersPerSecond()];
        end

        function elev_rad = computeElevationTo(obj, target_ecef_m)
            elev_rad = revgnss.GeometryUtils.elevationAngle( ...
                obj.r_ecef_m, target_ecef_m);
        end
    end

    methods (Access = private)
        function r = computeAntennaECEF_(obj)
            % Convert ENU antenna offset to ECEF and add to tower reference
            if all(obj.antennaOffset_enu_m == 0)
                r = obj.r_ecef_m;
                return
            end
            R = revgnss.GeometryUtils.enu2ecef(obj.lat_rad, obj.lon_rad);
            r = obj.r_ecef_m + R * obj.antennaOffset_enu_m;
        end
    end
end
