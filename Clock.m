classdef Clock < handle
    % CLOCK Four-state stochastic oscillator model.
    %
    % State ordering in seconds:
    %   state_sec(1) = white phase / time bias component
    %   state_sec(2) = white frequency / fractional frequency component
    %   state_sec(3) = flicker phase / bounded flicker-bias component
    %   state_sec(4) = flicker frequency / bounded flicker-frequency component
    %
    % The EKF normally does not estimate this full 4-state truth model.
    % It uses aggregateBiasDriftModel() to build a 2-state range-equivalent
    % clock model:
    %   [clock bias in meters; clock drift in meters/second]

    properties
        h_0 = 0.0
        h_minus_1 = 0.0
        h_minus_2 = 0.0

        omega_0 = 1e-9
        nominalDt = 1.0

        state_sec = zeros(4, 1)
        randomStream = []

        Phi = eye(4)
        Q = zeros(4, 4)
        L = zeros(4, 4)
    end

    properties (Dependent)
        % Backward-compatible aliases.
        % Prefer state_sec and nominalDt in new code.
        state
        dt

        total_bias_sec
        total_drift_sec_per_s
    end

    properties (Constant)
        c = 299792458.0
    end

    methods
        function obj = Clock(h0, hm1, hm2, timeStep, initialState_sec)
            if nargin < 1 || isempty(h0), h0 = 0.0; end
            if nargin < 2 || isempty(hm1), hm1 = 0.0; end
            if nargin < 3 || isempty(hm2), hm2 = 0.0; end
            if nargin < 4 || isempty(timeStep) || ~isfinite(timeStep) || timeStep <= 0
                timeStep = 1.0;
            end

            validateattributes(h0, {'numeric'}, {'real', 'finite', 'scalar'}, mfilename, 'h0');
            validateattributes(hm1, {'numeric'}, {'real', 'finite', 'scalar'}, mfilename, 'hm1');
            validateattributes(hm2, {'numeric'}, {'real', 'finite', 'scalar'}, mfilename, 'hm2');
            validateattributes(timeStep, {'numeric'}, {'real', 'finite', 'scalar', 'positive'}, mfilename, 'timeStep');

            obj.h_0 = max(h0, 0.0);
            obj.h_minus_1 = max(hm1, 0.0);
            obj.h_minus_2 = max(hm2, 0.0);
            obj.nominalDt = timeStep;

            if nargin >= 5 && ~isempty(initialState_sec)
                validateattributes(initialState_sec, {'numeric'}, ...
                    {'real', 'finite', 'numel', 4}, mfilename, 'initialState_sec');
                obj.state_sec = initialState_sec(:);
            end

            obj.rebuildDiscreteModel(obj.nominalDt);
        end

        function val = get.state(obj)
            val = obj.state_sec;
        end

        function set.state(obj, val)
            validateattributes(val, {'numeric'}, ...
                {'real', 'finite', 'numel', 4}, mfilename, 'state');
            obj.state_sec = val(:);
        end

        function val = get.dt(obj)
            val = obj.nominalDt;
        end

        function set.dt(obj, val)
            validateattributes(val, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, mfilename, 'dt');
            obj.nominalDt = val;
            obj.rebuildDiscreteModel(obj.nominalDt);
        end

        function bias_sec = get.total_bias_sec(obj)
            bias_sec = obj.state_sec(1) + obj.state_sec(3);
        end

        function drift_sec_per_s = get.total_drift_sec_per_s(obj)
            drift_sec_per_s = obj.state_sec(2) + obj.state_sec(4);
        end

        function current_error_sec = update(obj, dt)
            if nargin < 2 || isempty(dt)
                dt = obj.nominalDt;
            end

            validateattributes(dt, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, mfilename, 'dt');

            if abs(dt - obj.nominalDt) <= eps(max(1.0, obj.nominalDt))
                Phi_local = obj.Phi;
                L_local = obj.L;
            else
                [Phi_local, ~, L_local] = obj.discreteModel(dt);
            end

            if isempty(obj.randomStream)
                noise = randn(4, 1);
            else
                noise = randn(obj.randomStream, 4, 1);
            end
            
            obj.state_sec = Phi_local * obj.state_sec + L_local * noise;
            current_error_sec = obj.total_bias_sec;
        end

        function [totalTimeFluctuation, obj] = step(obj, dt)
            % Backward-compatible wrapper.
            % With handle classes, reassignment is no longer required, but
            % old calls like [bias, clock] = clock.step() still work.
            if nargin < 2
                totalTimeFluctuation = obj.update();
            else
                totalTimeFluctuation = obj.update(dt);
            end
        end

        function reset(obj, initialState_sec)
            if nargin < 2 || isempty(initialState_sec)
                obj.state_sec = zeros(4, 1);
            else
                validateattributes(initialState_sec, {'numeric'}, ...
                    {'real', 'finite', 'numel', 4}, mfilename, 'initialState_sec');
                obj.state_sec = initialState_sec(:);
            end
        end

        function error_m = get_error_meters(obj)
            error_m = obj.total_bias_sec * obj.c;
        end

        function Phi = getStateTransition(obj, dt)
            if nargin < 2 || isempty(dt)
                dt = obj.nominalDt;
            end
            A = obj.getContinuousDynamics();
            Phi = expm(A * dt);
        end

        function Q = getProcessNoise(obj, dt)
            if nargin < 2 || isempty(dt)
                dt = obj.nominalDt;
            end

            A = obj.getContinuousDynamics();
            Sigma = obj.getContinuousNoiseCovariance();

            M = [-A, Sigma; zeros(4, 4), A'] * dt;
            E = expm(M);

            Q = E(5:8, 5:8)' * E(1:4, 5:8);
            Q = 0.5 * (Q + Q');
        end

        function A = getContinuousDynamics(obj)
            w0 = obj.getCornerAngularFrequency();
            alpha = sqrt(3);

            A = zeros(4, 4);
            A(1, 2) = 1.0;
            A(3, 4) = 1.0;
            A(4, 3) = -(w0^2) / alpha;
            A(4, 4) = -sqrt(2.0 / alpha) * w0;
        end

        function Sigma = getContinuousNoiseCovariance(obj)
            w0 = obj.getCornerAngularFrequency();
            alpha = sqrt(3);

            B = zeros(4, 3);
            B(1, 1) = sqrt(max(obj.h_0, 0.0) / 2.0);
            B(2, 2) = pi * sqrt(2.0 * max(obj.h_minus_2, 0.0));
            B(4, 3) = (2.0 / alpha) * sqrt(pi * max(obj.h_minus_1, 0.0) * w0);

            Sigma = B * B';
        end

        function allanDev = theoreticalAllanDeviation(obj, tau)
            validateattributes(tau, {'numeric'}, {'real', 'finite', 'positive'}, mfilename, 'tau');

            allanVar = (obj.h_0 ./ (2.0 .* tau)) + ...
                       (2.0 * log(2.0) * obj.h_minus_1) + ...
                       ((2.0 * pi^2 / 3.0) .* tau .* obj.h_minus_2);

            allanDev = sqrt(max(allanVar, 0.0));
        end

        function adev = overlappingAllenDeviation(~, phase_data, tau, dt)
            % Backward-compatible misspelled method name.
            adev = Clock.computeOverlappingAllanDeviation(phase_data, tau, dt);
        end

    end

    methods (Access = private)
        function rebuildDiscreteModel(obj, dt)
            [obj.Phi, obj.Q, obj.L] = obj.discreteModel(dt);
        end

        function [Phi, Q, L] = discreteModel(obj, dt)
            Phi = obj.getStateTransition(dt);
            Q = obj.getProcessNoise(dt);
            L = Clock.sqrtCovariance(Q);
        end

        function w0 = getCornerAngularFrequency(obj)
            if obj.h_0 > 0.0 && obj.h_minus_2 > 0.0
                w0 = 2.0 * pi * sqrt(obj.h_minus_2 / obj.h_0);
            else
                w0 = 1e-9;
            end

            if ~isfinite(w0) || w0 <= 0.0
                w0 = 1e-9;
            end

            obj.omega_0 = w0;
        end
    end

    methods (Static)
        function L = sqrtCovariance(Q)
            Q = 0.5 * (Q + Q');
        
            [V, D] = eig(Q);
            d = real(diag(D));
            max_abs_d = max(abs(d));
            if isempty(max_abs_d) || max_abs_d == 0
                L = zeros(size(Q));
                return;
            end
        
            small_negative = d < 0 & abs(d) < 1e-12 * max_abs_d;
            d(small_negative) = 0.0;
        
            if any(d < 0)
                warning("Clock:sqrtCovariance", ...
                    "Clock process covariance has significant negative eigenvalues. Clipping them to zero.");
            end
        
            d = max(d, 0.0);
            L = real(V * diag(sqrt(d)));
        end

        function [adev, tau_eff, edf, adev_sigma] = computeOverlappingAllanDeviation(phase_data, tau, dt)
            phase_data = phase_data(:);

            validateattributes(phase_data, {'numeric'}, {'real', 'finite', 'vector'}, mfilename, 'phase_data');
            validateattributes(tau, {'numeric'}, {'real', 'finite', 'scalar', 'positive'}, mfilename, 'tau');
            validateattributes(dt, {'numeric'}, {'real', 'finite', 'scalar', 'positive'}, mfilename, 'dt');

            m = round(tau / dt);
            tau_eff = m * dt;
            edf = 0.0;
            adev_sigma = NaN;

            if m < 1 || 2 * m >= length(phase_data)
                adev = NaN;
                return;
            end

            phase_term1 = phase_data(1 + 2*m : end);
            phase_term2 = phase_data(1 + m : end - m);
            phase_term3 = phase_data(1 : end - 2*m);

            second_diff = phase_term1 - 2.0 * phase_term2 + phase_term3;
            edf = max(numel(second_diff), 1);
            variance = mean(second_diff.^2) / (2.0 * tau_eff^2);
            adev = sqrt(max(variance, 0.0));
            adev_sigma = adev / sqrt(2.0 * edf);
        end

        function [adev, tau_eff, edf, adev_sigma] = computeOverlappingAllanDeviationWithConfidence(phase_data, tau, dt)
            [adev, tau_eff, edf, adev_sigma] = Clock.computeOverlappingAllanDeviation(phase_data, tau, dt);
        end

        function h0 = calculate_h0(tau_array, adev_array)
            tau_array = tau_array(:);
            adev_array = adev_array(:);

            [tau_min, idx] = min(tau_array);
            adev_min = adev_array(idx);

            h0 = 2.0 * tau_min * adev_min^2;
        end

        function hm1 = calculate_h_minus_1(~, adev_array)
            adev_array = adev_array(:);
            adev_floor = min(adev_array);

            hm1 = adev_floor^2 / (2.0 * log(2.0));
        end

        function hm2 = calculate_h_minus_2(tau_array, adev_array)
            tau_array = tau_array(:);
            adev_array = adev_array(:);

            [tau_max, idx] = max(tau_array);
            adev_max = adev_array(idx);

            hm2 = (3.0 * adev_max^2) / (2.0 * pi^2 * tau_max);
        end

        function [Phi, Q] = getEkfBiasDriftModel(h0, hm1, hm2, dt, c, clockModel, correlationTime_s)
            % Clearer public name for the EKF 2-state clock model.
            %
            % State:
            %   [clock bias in meters;
            %    clock drift in meters per second]
        
            if nargin < 7
                correlationTime_s = [];
            end
            if nargin < 6
                clockModel = [];
            end
            if nargin < 5
                c = [];
            end
        
            [Phi, Q] = Clock.aggregateBiasDriftModel( ...
                h0, hm1, hm2, dt, c, clockModel, correlationTime_s);
        end

        function [Phi, Q] = aggregateBiasDriftModel(h0, hm1, hm2, dt, c, clockModel, correlationTime_s)
            % Returns a 2-state clock model in meters.
            %
            % State:
            %   [clock bias range-equivalent meters;
            %    clock drift range-equivalent meters/second]

            if nargin < 5 || isempty(c)
                c = 299792458.0;
            end
            if nargin < 6 || isempty(clockModel) || all(strlength(string(clockModel)) == 0)
                clockModel = "brownHwang";
            end
            if nargin < 7 || isempty(correlationTime_s)
                correlationTime_s = 3600.0;
            end

            h0 = max(h0, 0.0);
            hm1 = max(hm1, 0.0);
            hm2 = max(hm2, 0.0);
            dt = max(dt, eps);
            c = max(c, eps);

            clockModelKey = lower(strtrim(string(clockModel)));
            if any(clockModelKey == ["brownhwang", "brown_hwang", "brown-hwang", "randomwalk", "random_walk", "random-walk"])
                clockModelKey = "brownhwang";
            elseif any(clockModelKey == ["coupledgaussmarkov", "coupled_gauss_markov", "coupled-gauss-markov"])
                clockModelKey = "coupledgaussmarkov";
            else
                error('Clock:InvalidClockModel', ...
                    'clockModel must be brownHwang, randomWalk, or coupledGaussMarkov.');
            end

            if clockModelKey == "coupledgaussmarkov"
                tau = max(correlationTime_s, dt);
                a = exp(-dt / tau);

                Phi = [1.0, tau * (1.0 - a);
                       0.0, a];

                flicker_equiv = max(2.0 * log(2.0) * hm1, 0.0);
                drift_sigma_sps = sqrt(max((2.0 * pi^2 * hm2 * tau) + flicker_equiv, 0.0));

                q_drift = (c * drift_sigma_sps)^2 * max(1.0 - a^2, 0.0);
                q_bias_white = c^2 * h0 * dt / 2.0;
                q_bias_from_drift = q_drift * (tau * (1.0 - a))^2;
                q_cross = 0.5 * q_drift * tau * (1.0 - a);

                Q = [q_bias_white + q_bias_from_drift, q_cross;
                     q_cross, q_drift];
            else
                Phi = [1.0, dt;
                       0.0, 1.0];

                q_white_fm_bias = h0 * dt / 2.0;
                q_flicker_bias = max(2.0 * log(2.0) * hm1, 0.0) * dt^2;
                q_rwfm_bias = (2.0 * pi^2 / 3.0) * hm2 * dt^3;
                q_rwfm_cross = pi^2 * hm2 * dt^2;
                q_rwfm_drift = 2.0 * pi^2 * hm2 * dt;

                Q = c^2 * [q_white_fm_bias + q_flicker_bias + q_rwfm_bias, q_rwfm_cross;
                            q_rwfm_cross, q_rwfm_drift];
            end

            Q = 0.5 * (Q + Q');

            [V, D] = eig(Q);
            d = max(real(diag(D)), 0.0);
            Q = real(V * diag(d) * V');
            Q = 0.5 * (Q + Q');
        end
    
        function jd = julianDateFromDatetime(t)
        
            y = year(t);
            m = month(t);
            d = day(t);
        
            h = hour(t) + minute(t) / 60.0 + second(t) / 3600.0;
        
            jd = 367.0 * y ...
                - floor(7.0 * (y + floor((m + 9.0) / 12.0)) / 4.0) ...
                + floor(275.0 * m / 9.0) ...
                + d ...
                + 1721013.5 ...
                + h / 24.0;
        end
    end
end