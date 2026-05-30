classdef ExtendedKalmanFilter < handle
    % EXTENDEDKALMANFILTER A generic EKF engine.
    % Handles State (X), Covariance (P), Process Noise (Q), and Measurement Noise (R).
    % Optional angle-state wrapping keeps Euler states bounded after predict/update.

    properties
        X       % State estimate vector (n x 1)
        P       % State covariance matrix (n x n)
        Q       % Default Process noise covariance matrix (n x n)
        R       % Default Measurement noise covariance matrix (m x m)

        x_dim   % Number of states (n)
        y_dim   % Number of measurements (m)

        angleStateIndices = []
        wrapAngleStates = true
    end

    methods
        function obj = ExtendedKalmanFilter(X0, P0, Q0, R0)
            obj.X = X0(:);
            obj.P = P0;
            obj.Q = Q0;
            obj.R = R0;

            obj.x_dim = length(obj.X);
            obj.y_dim = size(obj.R, 1);
        end

        function predict(obj, X_propagated, Phi, Q_dynamic)
            if nargin < 4 || isempty(Q_dynamic)
                Q_dynamic = obj.Q;
            end

            obj.X = X_propagated(:);
            obj.normalizeAngleStates();

            obj.P = Phi * obj.P * Phi' + Q_dynamic;
            obj.P = 0.5 * (obj.P + obj.P');
        end

        function [innovation, NIS] = update(obj, y_actual, y_pred, H, R_dynamic)
            if nargin < 5 || isempty(R_dynamic)
                R_dynamic = obj.R;
            end

            innovation = y_actual(:) - y_pred(:);
            S = H * obj.P * H' + R_dynamic;

            K = (obj.P * H') / S;
            obj.X = obj.X + K * innovation;
            obj.normalizeAngleStates();

            I = eye(obj.x_dim);
            temp_mat = I - K * H;
            obj.P = temp_mat * obj.P * temp_mat' + K * R_dynamic * K';
            obj.P = 0.5 * (obj.P + obj.P');

            NIS = innovation' * (S \ innovation);
        end

        function override_states(obj, state_indices, new_values, zero_covariance)
            obj.X(state_indices) = new_values;
            obj.normalizeAngleStates();

            if nargin > 3 && zero_covariance
                obj.P(state_indices, :) = 0;
                obj.P(:, state_indices) = 0;
            end
        end

        function setAngleStateIndices(obj, indices)
            obj.angleStateIndices = unique(indices(:).');
            obj.angleStateIndices = obj.angleStateIndices( ...
                obj.angleStateIndices >= 1 & obj.angleStateIndices <= obj.x_dim);
            obj.normalizeAngleStates();
        end

        function normalizeAngleStates(obj)
            if ~obj.wrapAngleStates || isempty(obj.angleStateIndices)
                return;
            end
            for idx_angle = obj.angleStateIndices
                obj.X(idx_angle) = ExtendedKalmanFilter.wrapToPiLocal(obj.X(idx_angle));
            end
        end
    end

    methods (Static, Access = private)
        function angle = wrapToPiLocal(angle)
            angle = mod(angle + pi, 2*pi) - pi;
        end
    end
end
