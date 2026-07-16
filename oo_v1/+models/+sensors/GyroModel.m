classdef GyroModel < handle
%GYROMODEL  Truth-side strapdown gyroscope sensor (mirrors +models/+clocks/ClockModel).
%   Produces a noisy body-rate measurement omega_meas = omega_true + b(t) + white(ARW), where
%   b(t) is a slowly-varying gyro bias (rate random walk, RRW). The bias realization and all
%   noise draws come from a DEDICATED RandStream seeded independently, so the EKF never sees the
%   truth realization -- only the (separately configured) filter-side ARW/RRW sigmas. This keeps
%   the gyro HONEST (no sameAsTruth oracle) exactly like the clock/atmosphere truth models.
%
%   Units: rad/s for rate and bias; ARW in rad/sqrt(s); RRW in rad/(s*sqrt(s)).
%
%   Usage:
%     g = models.sensors.GyroModel(cfg.asset.imu);       % cfg.asset.imu.{arw,rrw,bias0Sigma,seed}
%     wm = g.sample(omega_true_radps, dt_s);             % one measurement, steps the bias RW
%
%   See also: +models/+clocks/ClockModel, +filter/ReverseGNSSEKF (gyro-bias states).

    properties
        arw_rad_per_sqrt_s   = 1e-4    % angle random walk (white rate noise) [rad/sqrt(s)]
        rrw_rad_per_s_sqrt_s = 1e-6    % bias rate random walk [rad/(s*sqrt(s))]
        bias0Sigma_radps     = 1e-5    % initial bias draw 1-sigma [rad/s]
        seed                 = 909
        bias_radps           = [0;0;0] % current (truth) bias state [rad/s]
        history              = struct('t_s',{},'bias_radps',{},'meas_radps',{})
    end
    properties (Access = private)
        rngStream_
    end

    methods
        function obj = GyroModel(imuCfg)
            if nargin >= 1 && ~isempty(imuCfg)
                if isfield(imuCfg,'arw_rad_per_sqrt_s');    obj.arw_rad_per_sqrt_s   = imuCfg.arw_rad_per_sqrt_s;    end
                if isfield(imuCfg,'rrw_rad_per_s_sqrt_s');  obj.rrw_rad_per_s_sqrt_s = imuCfg.rrw_rad_per_s_sqrt_s;  end
                if isfield(imuCfg,'bias0Sigma_radps');      obj.bias0Sigma_radps     = imuCfg.bias0Sigma_radps;      end
                if isfield(imuCfg,'seed');                  obj.seed                 = imuCfg.seed;                  end
            end
            obj.rngStream_ = RandStream('mt19937ar', 'Seed', obj.seed);
            % Honest, filter-unknown initial bias realization.
            obj.bias_radps = obj.bias0Sigma_radps * randn(obj.rngStream_, 3, 1);
        end

        function reset(obj)
            %RESET  Re-seed the stream and redraw the initial bias (reproducible runs).
            obj.rngStream_ = RandStream('mt19937ar', 'Seed', obj.seed);
            obj.bias_radps = obj.bias0Sigma_radps * randn(obj.rngStream_, 3, 1);
            obj.history    = struct('t_s',{},'bias_radps',{},'meas_radps',{});
        end

        function precomputeNoise(obj, ~)
            %PRECOMPUTENOISE  Parity with ClockModel; the bias RW is stepped online in sample().
            obj.reset();
        end

        function wm = sample(obj, omega_true_radps, dt_s, t_s)
            %SAMPLE  One gyro measurement; steps the bias random walk by dt_s.
            if nargin < 4; t_s = NaN; end
            omega_true_radps = omega_true_radps(:);
            dt_s = max(dt_s, eps);
            % Rate random walk on the bias.
            obj.bias_radps = obj.bias_radps + ...
                obj.rrw_rad_per_s_sqrt_s * sqrt(dt_s) * randn(obj.rngStream_, 3, 1);
            % White angle-random-walk on the reading (discretized: sigma = ARW / sqrt(dt)).
            whiteRate = (obj.arw_rad_per_sqrt_s / sqrt(dt_s)) * randn(obj.rngStream_, 3, 1);
            wm = omega_true_radps + obj.bias_radps + whiteRate;
            obj.history(end+1) = struct('t_s', t_s, 'bias_radps', obj.bias_radps, 'meas_radps', wm);
        end
    end
end
