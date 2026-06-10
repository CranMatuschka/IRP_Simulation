classdef SpaceAsset < handle
    % SpaceAsset  Orbiting receiver platform for reverse-GNSS.
    %
    % Holds truth state:
    %   - Translational state (r, v) in ECEF
    %   - Attitude as Euler angles [roll; pitch; yaw] in ZYX convention
    %   - Angular velocity omega in body frame [rad/s]
    %   - Receiver ClockModel
    %   - Receiver antenna lever arm in body frame
    %
    % The receiver antenna phase center is:
    %   r_ant_ecef = r_cm_ecef + C_ecef_body * leverArm_body_m
    %
    % Attitude convention: ZYX (3-2-1), same as AttitudeKinematics.
    %
    % Usage:
    %   cfg.name = 'LEO_1';
    %   cfg.r_ecef_m = [6878e3; 0; 0];
    %   cfg.v_ecef_mps = [0; 7612; 0];
    %   cfg.attitude_euler_rad = [0;0;0];
    %   cfg.angularRate_body_radps = [0;0;0.001];
    %   cfg.receiverLeverArm_body_m = [1.0; 0.5; 0.2];
    %   cfg.clock.name = 'RxClock'; cfg.clock.clockType = 'TCXO'; ...
    %   asset = revgnss.SpaceAsset(cfg);

    properties
        name                     (1,:) char    = 'SpaceAsset'
        mass_kg                  (1,1) double  = 100

        % Truth translational state in ECEF
        r_ecef_m                 (3,1) double  = zeros(3,1)  % [m]
        v_ecef_mps               (3,1) double  = zeros(3,1)  % [m/s]

        % Truth attitude: [roll; pitch; yaw] ZYX, radians
        attitude_euler_rad       (3,1) double  = zeros(3,1)

        % Truth angular velocity in body frame [rad/s]
        angularRate_body_radps   (3,1) double  = zeros(3,1)

        % Receiver antenna lever arm in body frame [m]
        receiverLeverArm_body_m  (3,1) double  = zeros(3,1)

        % Receiver clock
        clock                    revgnss.ClockModel

        % History log
        history                  (1,1) struct
    end

    methods
        function obj = SpaceAsset(cfg)
            if nargin == 0; return; end

            obj.name    = cfg.name;
            if isfield(cfg,'mass_kg'); obj.mass_kg = cfg.mass_kg; end

            obj.r_ecef_m               = cfg.r_ecef_m(:);
            obj.v_ecef_mps             = cfg.v_ecef_mps(:);
            obj.attitude_euler_rad     = cfg.attitude_euler_rad(:);
            obj.angularRate_body_radps = cfg.angularRate_body_radps(:);
            obj.receiverLeverArm_body_m = cfg.receiverLeverArm_body_m(:);

            obj.clock = revgnss.ClockModel(cfg.clock);

            obj.history.time_s                = [];
            obj.history.r_ecef_m              = [];
            obj.history.v_ecef_mps            = [];
            obj.history.euler_rad             = [];
            obj.history.omega_body_radps      = [];
            obj.history.r_ant_ecef_m          = [];
            obj.history.rxClockBias_m         = [];
            obj.history.rxFracFreq            = [];
        end

        % ----------------------------------------------------------------
        function r_ant = getAntennaPositionECEF(obj)
            % getAntennaPositionECEF  Compute receiver antenna phase center.
            r_ant = revgnss.AttitudeKinematics.applyLeverArm( ...
                obj.r_ecef_m, obj.attitude_euler_rad, obj.receiverLeverArm_body_m);
        end

        function propagate(obj, dt_s, accel_ecef_mps2, alpha_body_radps2)
            % propagate  Advance truth state by dt_s seconds.
            %
            % Translational: constant-velocity + supplied acceleration.
            % Attitude: Euler-angle kinematic integration.
            % Angular rate: constant + supplied angular acceleration.

            if nargin < 3 || isempty(accel_ecef_mps2)
                accel_ecef_mps2 = zeros(3,1);
            end
            if nargin < 4 || isempty(alpha_body_radps2)
                alpha_body_radps2 = zeros(3,1);
            end

            % Translation (Euler integration; simple enough for 1-s steps)
            obj.r_ecef_m   = obj.r_ecef_m + dt_s * obj.v_ecef_mps;
            obj.v_ecef_mps = obj.v_ecef_mps + dt_s * accel_ecef_mps2(:);

            % Attitude kinematics
            edot = revgnss.AttitudeKinematics.eulerRatesFromBodyRates( ...
                obj.attitude_euler_rad, obj.angularRate_body_radps);
            obj.attitude_euler_rad = revgnss.AttitudeKinematics.wrapEuler( ...
                obj.attitude_euler_rad + dt_s * edot);

            % Angular rate
            obj.angularRate_body_radps = obj.angularRate_body_radps + ...
                dt_s * alpha_body_radps2(:);

            % Clock
            obj.clock.step(dt_s);
        end

        function logState(obj, t_s)
            % logState  Append current truth state to history.
            obj.history.time_s           = [obj.history.time_s;           t_s];
            obj.history.r_ecef_m         = [obj.history.r_ecef_m,         obj.r_ecef_m];
            obj.history.v_ecef_mps       = [obj.history.v_ecef_mps,       obj.v_ecef_mps];
            obj.history.euler_rad        = [obj.history.euler_rad,        obj.attitude_euler_rad];
            obj.history.omega_body_radps = [obj.history.omega_body_radps, obj.angularRate_body_radps];
            obj.history.r_ant_ecef_m     = [obj.history.r_ant_ecef_m,    obj.getAntennaPositionECEF()];
            obj.history.rxClockBias_m    = [obj.history.rxClockBias_m;   obj.clock.getBiasMeters()];
            obj.history.rxFracFreq       = [obj.history.rxFracFreq;      obj.clock.getFractionalFrequency()];
        end

        function propagateAttitudeAndClock(obj, dt_s)
            % propagateAttitudeAndClock  Step attitude and clock without touching r/v.
            % Used when position/velocity are provided externally (orbit propagator).
            edot = revgnss.AttitudeKinematics.eulerRatesFromBodyRates( ...
                obj.attitude_euler_rad, obj.angularRate_body_radps);
            obj.attitude_euler_rad = revgnss.AttitudeKinematics.wrapEuler( ...
                obj.attitude_euler_rad + dt_s * edot);
            obj.clock.step(dt_s);
        end

        function setTruthFromOrbit(obj, r_ecef_m, v_ecef_mps)
            % setTruthFromOrbit  Override position/velocity from orbit propagator.
            obj.r_ecef_m   = r_ecef_m(:);
            obj.v_ecef_mps = v_ecef_mps(:);
        end
    end
end
