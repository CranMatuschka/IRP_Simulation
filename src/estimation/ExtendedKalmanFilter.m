classdef ExtendedKalmanFilter < handle
    %EXTENDEDKALMANFILTER Generic EKF engine.
    % Handles state, covariance, process noise, and measurement noise.
    properties
        X       % State estimate vector (n x 1)
        P       % State covariance matrix (n x n)
        Q       % Default Process noise covariance matrix (n x n)
        R       % Default Measurement noise covariance matrix (m x m)

        x_dim   % Number of states (n)
    end

    methods
        function obj = ExtendedKalmanFilter(X0, P0, Q0, R0)
            obj.X = X0(:);
            obj.P = P0;
            obj.Q = Q0;
            obj.R = R0;

            obj.x_dim = length(obj.X);
        end

        function predict(obj, X_propagated, Phi, Q_dynamic)
            if nargin < 4 || isempty(Q_dynamic)
                Q_dynamic = obj.Q;
            end

            obj.X = X_propagated(:);

            obj.P = Phi * obj.P * Phi' + Q_dynamic;
            obj.P = 0.5 * (obj.P + obj.P');
        end

        function [innovation, NIS, S] = update(obj, y_actual, y_pred, H, R_dynamic)
            if nargin < 5 || isempty(R_dynamic)
                R_dynamic = obj.R;
            end

            innovation = y_actual(:) - y_pred(:);
            S = H * obj.P * H' + R_dynamic;

            K = (obj.P * H') / S;
            obj.X = obj.X + K * innovation;

            I = eye(obj.x_dim);
            temp_mat = I - K * H;
            obj.P = temp_mat * obj.P * temp_mat' + K * R_dynamic * K';
            obj.P = 0.5 * (obj.P + obj.P');

            NIS = innovation' * (S \ innovation);
        end


    end
end
