classdef IMUModel < handle
%IMUMODEL  Full strapdown IMU truth model: 3-axis gyroscope + 3-axis accelerometer.
%   Mirrors +models/+clocks/ClockModel: dedicated RNG streams, honest (filter-unknown) bias
%   realizations, stepped once per truth epoch by SpaceAsset.
%
%   GYRO (rate channel):
%     omega_meas = omega_true + b_g(t) + ARW
%       b_g : gyro bias, rate random walk (RRW)
%       ARW : angle random walk (white rate noise), discretised as ARW/sqrt(dt)
%
%   ACCELEROMETER (specific-force channel):
%     f_meas = f_specific_body + b_a(t) + VRW
%       f_specific_body : SPECIFIC FORCE in body axes -- NON-GRAVITATIONAL acceleration only
%       b_a : accel bias, bias random walk
%       VRW : velocity random walk (white accel noise), discretised as VRW/sqrt(dt)
%
%   WHY THE ACCELEROMETER READS ~0 IN ORBIT (important, and why accel.useInEKF defaults false):
%   an accelerometer senses SPECIFIC FORCE, i.e. non-gravitational acceleration. It is BLIND to
%   gravity. A satellite in free fall therefore reads ~0 -- at GEO only solar radiation pressure
%   (~1e-7 m/s^2) is present, far below any real accelerometer noise floor. So in free flight the
%   accelerometer carries NO useful orbit information: integrating it would inject noise for zero
%   gain. This is exactly why spacecraft orbit determination uses DYNAMICS MODELS (two-body + J2 +
%   luni-solar/SRP), not accelerometers. The accelerometer earns its keep only during THRUST or
%   manoeuvres, where it senses the burn the dynamics model does not know about. It is therefore
%   modelled and logged here, but not fed to the EKF unless explicitly enabled.
%
%   RNG: the gyro and accel channels use SEPARATE streams (seed, seed+1) -- physically correct
%   (independent sensor noise) and it keeps the gyro realization byte-identical to the previous
%   gyro-only model, so existing gyro results/tests reproduce exactly.
%
%   Usage:
%     imu = models.sensors.IMUModel(cfg.asset.imu);
%     [wm, fm] = imu.sample(omega_true_radps, f_specific_body_mps2, dt_s);
%
%   Not modelled (documented, not hidden): scale-factor error, axis misalignment, g-sensitivity,
%   quantisation. Bias + random walks are the dominant terms for this application.
%
%   See also: +models/+clocks/ClockModel, +filter/ReverseGNSSEKF (gyro-bias states), SpaceAsset.

    properties
        % ---- Gyroscope (rate) ----
        gyroArw_rad_per_sqrt_s    = 1e-4     % angle random walk [rad/sqrt(s)]
        gyroRrw_rad_per_s_sqrt_s  = 1e-6     % bias rate random walk [rad/(s*sqrt(s))]
        gyroBias0Sigma_radps      = 1e-5     % initial gyro-bias draw 1-sigma [rad/s]
        gyroBias_radps            = [0;0;0]  % current (truth) gyro bias [rad/s]

        % ---- Accelerometer (specific force) ----
        accelVrw_mps_per_sqrt_s   = 1e-3     % velocity random walk (white accel noise) [m/s/sqrt(s)]
        accelBrw_mps2_sqrt_s      = 1e-6     % accel bias random walk [m/s^2/sqrt(s)]
        accelBias0Sigma_mps2      = 1e-4     % initial accel-bias draw 1-sigma [m/s^2]
        accelBias_mps2            = [0;0;0]  % current (truth) accel bias [m/s^2]

        seed    = 909
        history = struct('t_s',{},'gyroBias_radps',{},'omega_meas_radps',{}, ...
                         'accelBias_mps2',{},'f_meas_mps2',{})
    end
    properties (Access = private)
        rngGyro_
        rngAccel_
    end

    methods
        function obj = IMUModel(imuCfg)
            if nargin >= 1 && ~isempty(imuCfg)
                % Gyro params (accept the legacy gyro-only field names for back-compat).
                obj.gyroArw_rad_per_sqrt_s   = i_get(imuCfg, {'gyroArw_rad_per_sqrt_s','arw_rad_per_sqrt_s'},   obj.gyroArw_rad_per_sqrt_s);
                obj.gyroRrw_rad_per_s_sqrt_s = i_get(imuCfg, {'gyroRrw_rad_per_s_sqrt_s','rrw_rad_per_s_sqrt_s'}, obj.gyroRrw_rad_per_s_sqrt_s);
                obj.gyroBias0Sigma_radps     = i_get(imuCfg, {'gyroBias0Sigma_radps','bias0Sigma_radps'},        obj.gyroBias0Sigma_radps);
                % Accel params.
                obj.accelVrw_mps_per_sqrt_s  = i_get(imuCfg, {'accelVrw_mps_per_sqrt_s'}, obj.accelVrw_mps_per_sqrt_s);
                obj.accelBrw_mps2_sqrt_s     = i_get(imuCfg, {'accelBrw_mps2_sqrt_s'},    obj.accelBrw_mps2_sqrt_s);
                obj.accelBias0Sigma_mps2     = i_get(imuCfg, {'accelBias0Sigma_mps2'},    obj.accelBias0Sigma_mps2);
                obj.seed                     = i_get(imuCfg, {'seed'},                    obj.seed);
            end
            obj.initStreams_();
        end

        function reset(obj)
            %RESET  Re-seed both channels and redraw the initial biases (reproducible runs).
            obj.initStreams_();
            obj.history = struct('t_s',{},'gyroBias_radps',{},'omega_meas_radps',{}, ...
                                 'accelBias_mps2',{},'f_meas_mps2',{});
        end

        function precomputeNoise(obj, ~)
            %PRECOMPUTENOISE  Parity with ClockModel; the biases are stepped online in sample().
            obj.reset();
        end

        function [omega_meas, f_meas] = sample(obj, omega_true_radps, f_specific_body_mps2, dt_s, t_s)
            %SAMPLE  One IMU measurement pair; steps both bias random walks by dt_s.
            %   f_specific_body_mps2 : NON-GRAVITATIONAL specific force in body axes. Pass
            %   zeros(3,1) for free flight (the physical truth at GEO bar ~1e-7 m/s^2 of SRP).
            if nargin < 3 || isempty(f_specific_body_mps2); f_specific_body_mps2 = zeros(3,1); end
            if nargin < 5; t_s = NaN; end
            dt_s = max(dt_s, eps);
            omega_true_radps     = omega_true_radps(:);
            f_specific_body_mps2 = f_specific_body_mps2(:);

            % ---- Gyro channel (own stream: identical draws to the gyro-only model) ----
            obj.gyroBias_radps = obj.gyroBias_radps + ...
                obj.gyroRrw_rad_per_s_sqrt_s * sqrt(dt_s) * randn(obj.rngGyro_, 3, 1);
            omega_meas = omega_true_radps + obj.gyroBias_radps + ...
                (obj.gyroArw_rad_per_sqrt_s / sqrt(dt_s)) * randn(obj.rngGyro_, 3, 1);

            % ---- Accelerometer channel (own stream) ----
            obj.accelBias_mps2 = obj.accelBias_mps2 + ...
                obj.accelBrw_mps2_sqrt_s * sqrt(dt_s) * randn(obj.rngAccel_, 3, 1);
            f_meas = f_specific_body_mps2 + obj.accelBias_mps2 + ...
                (obj.accelVrw_mps_per_sqrt_s / sqrt(dt_s)) * randn(obj.rngAccel_, 3, 1);

            obj.history(end+1) = struct('t_s', t_s, ...
                'gyroBias_radps', obj.gyroBias_radps, 'omega_meas_radps', omega_meas, ...
                'accelBias_mps2', obj.accelBias_mps2, 'f_meas_mps2', f_meas);
        end
    end

    methods (Access = private)
        function initStreams_(obj)
            % Separate streams so the two channels are independent AND the gyro draw order is
            % unchanged from the gyro-only model (adding the accel cannot perturb gyro results).
            obj.rngGyro_  = RandStream('mt19937ar', 'Seed', obj.seed);
            obj.rngAccel_ = RandStream('mt19937ar', 'Seed', obj.seed + 1);
            obj.gyroBias_radps = obj.gyroBias0Sigma_radps * randn(obj.rngGyro_,  3, 1);
            obj.accelBias_mps2 = obj.accelBias0Sigma_mps2 * randn(obj.rngAccel_, 3, 1);
        end
    end
end

% ==========================================================================================
function v = i_get(s, names, dflt)
%I_GET  First present field from NAMES, else DFLT (supports legacy gyro-only field names).
    v = dflt;
    for i = 1:numel(names)
        if isfield(s, names{i}) && ~isempty(s.(names{i}))
            v = s.(names{i}); return;
        end
    end
end
