classdef ReverseGNSSEKF < handle
    % ReverseGNSSEKF  Extended Kalman Filter for reverse-GNSS navigation.
    %
    % State vector (base, 14-dimensional):
    %   x(1:3)    r_cm_ecef_m          position [m]
    %   x(4:6)    v_ecef_mps           velocity [m/s]
    %   x(7:9)    euler_rad            attitude [roll; pitch; yaw] ZYX
    %   x(10:12)  omega_body_radps     angular velocity [rad/s]
    %   x(13)     b_rx_m               receiver clock bias [m]
    %   x(14)     bdot_rx_mps          receiver clock drift [m/s]
    %
    % Optional tower clock states (if cfg.estimator.estimateTowerClocks = true):
    %   x(15+2*(i-1))   b_tower_i_m    tower i clock bias [m]
    %   x(16+2*(i-1))   bdot_tower_i_mps  tower i clock drift [m/s]
    %
    % Total state size: 14 + 2*N_towers (if estimating tower clocks)
    %
    % Prediction model:
    %   r(k+1) = r(k) + dt*v(k)                  [constant velocity]
    %   v(k+1) = v(k)                             [+ process noise]
    %   euler(k+1) = euler(k) + dt*eulerRates(omega,euler)  [kinematics]
    %   omega(k+1) = omega(k)                     [+ process noise]
    %   b_rx(k+1) = b_rx(k) + dt*bdot_rx(k)      [clock model]
    %   bdot_rx(k+1) = bdot_rx(k)                 [+ clock process noise]
    %
    % Covariance update: Joseph stabilised form
    %   P = (I-K*H)*P*(I-K*H)' + K*R*K'
    %
    % NOTE: If receiverLeverArm = 0, attitude states are unobservable from
    % pseudorange measurements.  A warning is issued during initialization.

    properties
        x               (:,1) double       % state vector
        P               (:,:) double       % state covariance

        cfg             (1,1) struct       % estimator config
        stateMap        (1,1) struct       % index assignments

        nxBase          (1,1) double = 14  % base state dimension
        nx              (1,1) double = 14  % total state dimension
        nTowers         (1,1) double = 0   % number of towers

        estimateTowerClocks (1,1) logical = false

        % Process noise parameters
        sigma_accel_mps2    (1,1) double = 0.01   % position process noise
        sigma_angAccel_radps2 (1,1) double = 1e-4

        % Clock model reference (for process noise)
        rxClockModel        revgnss.ClockModel

        % Diagnostics
        history             (1,1) struct
    end

    methods
        function obj = ReverseGNSSEKF(cfg, nTowers, rxClockModel)
            if nargin == 0; return; end

            obj.cfg     = cfg;
            obj.nTowers = nTowers;

            if isfield(cfg.estimator,'estimateTowerClocks')
                obj.estimateTowerClocks = cfg.estimator.estimateTowerClocks;
            end

            obj.nx = obj.nxBase;
            if obj.estimateTowerClocks
                obj.nx = obj.nxBase + 2*nTowers;
            end

            % Process noise params
            if isfield(cfg.estimator,'sigma_accel_mps2')
                obj.sigma_accel_mps2 = cfg.estimator.sigma_accel_mps2;
            end
            if isfield(cfg.estimator,'sigma_angAccel_radps2')
                obj.sigma_angAccel_radps2 = cfg.estimator.sigma_angAccel_radps2;
            end

            % Store clock model for process noise
            if nargin >= 3 && ~isempty(rxClockModel)
                obj.rxClockModel = rxClockModel;
            end

            % Build state index map
            obj.stateMap = obj.buildStateMap_(nTowers);

            % Zero state
            obj.x = zeros(obj.nx, 1);
            obj.P = eye(obj.nx);

            % Check lever arm observability
            if isfield(cfg.asset,'receiverLeverArm_body_m')
                lever = cfg.asset.receiverLeverArm_body_m;
                if norm(lever) < 1e-9
                    warning('ReverseGNSSEKF:noLeverArm', ...
                        'Receiver lever arm is zero. Attitude states are unobservable from pseudorange. See README_oo_v1.md.');
                end
            end

            obj.initHistory_();
        end

        % ----------------------------------------------------------------
        function initState(obj, x0, P0)
            % initState  Set initial state and covariance.
            obj.x = x0(:);
            obj.P = P0;
        end

        % ----------------------------------------------------------------
        function predict(obj, dt_s, towerClockModels)
            % predict  EKF prediction step.

            x = obj.x;
            sm = obj.stateMap;

            % Extract current state
            r   = x(sm.r_idx);
            v   = x(sm.v_idx);
            eul = x(sm.euler_idx);
            omg = x(sm.omega_idx);
            b_rx    = x(sm.b_rx_idx);
            bdot_rx = x(sm.bdot_rx_idx);

            % --- State transition ----------------------------------------
            % Position: constant-velocity
            r_new = r + dt_s * v;
            v_new = v;

            % Attitude: Euler kinematics
            edot = revgnss.AttitudeKinematics.eulerRatesFromBodyRates(eul, omg);
            eul_new = revgnss.AttitudeKinematics.wrapEuler(eul + dt_s * edot);
            omg_new = omg;

            % Receiver clock
            b_rx_new    = b_rx + dt_s * bdot_rx;
            bdot_rx_new = bdot_rx;

            % Assemble new state
            x_new = x;
            x_new(sm.r_idx)      = r_new;
            x_new(sm.v_idx)      = v_new;
            x_new(sm.euler_idx)  = eul_new;
            x_new(sm.omega_idx)  = omg_new;
            x_new(sm.b_rx_idx)   = b_rx_new;
            x_new(sm.bdot_rx_idx)= bdot_rx_new;

            % Tower clock prediction (if estimated)
            if obj.estimateTowerClocks && nargin >= 3
                for ti = 1:obj.nTowers
                    idx_b    = sm.towerClockIdx(ti,1);
                    idx_bdot = sm.towerClockIdx(ti,2);
                    b_twr    = x(idx_b);
                    bd_twr   = x(idx_bdot);
                    x_new(idx_b)    = b_twr + dt_s * bd_twr;
                    x_new(idx_bdot) = bd_twr;
                end
            end
            obj.x = x_new;

            % --- State transition Jacobian F ----------------------------
            F = obj.buildF_(dt_s, eul, omg);

            % --- Process noise Q ----------------------------------------
            Q = obj.buildQ_(dt_s, towerClockModels);

            % --- Propagate covariance -----------------------------------
            obj.P = F * obj.P * F' + Q;
            obj.P = (obj.P + obj.P') / 2;  % enforce symmetry
        end

        % ----------------------------------------------------------------
        function [K, nu, S, NIS] = update(obj, z, h, H, R)
            % update  EKF measurement update step (Joseph form).
            %
            % Inputs:
            %   z  [M x 1] truth pseudoranges
            %   h  [M x 1] predicted pseudoranges
            %   H  [M x nx] Jacobian
            %   R  [M x M] measurement noise covariance
            %
            % Outputs: Kalman gain K, innovation nu, innovation covariance S, NIS

            if isempty(z)
                K = []; nu = []; S = []; NIS = NaN;
                return
            end

            nu = z - h;     % innovation

            % Innovation covariance
            S = H * obj.P * H' + R;
            S = (S + S') / 2;

            % Kalman gain
            K = obj.P * H' / S;

            % State update
            obj.x = obj.x + K * nu;
            obj.x(obj.stateMap.euler_idx) = revgnss.AttitudeKinematics.wrapEuler( ...
                obj.x(obj.stateMap.euler_idx));

            % Joseph stabilised covariance update
            nx = obj.nx;
            IKH = eye(nx) - K * H;
            obj.P = IKH * obj.P * IKH' + K * R * K';
            obj.P = (obj.P + obj.P') / 2;

            % Numerical sanity checks
            if any(~isfinite(obj.P(:)))
                warning('ReverseGNSSEKF:update','NaN/Inf in P after update');
            end
            eigP = eig(obj.P);
            if any(eigP < 0)
                warning('ReverseGNSSEKF:update','P is not positive semidefinite; clipping');
                obj.P = nearestSPD_(obj.P);
            end

            % Normalised Innovation Squared
            NIS = nu' / S * nu;
        end

        % ----------------------------------------------------------------
        function sm = buildStateMap_(obj, nTowers)
            sm.r_idx      = (1:3)';
            sm.v_idx      = (4:6)';
            sm.euler_idx  = (7:9)';
            sm.omega_idx  = (10:12)';
            sm.b_rx_idx   = 13;
            sm.bdot_rx_idx= 14;

            if obj.estimateTowerClocks && nTowers > 0
                tClockIdx = zeros(nTowers, 2);
                for ti = 1:nTowers
                    base = obj.nxBase + 2*(ti-1);
                    tClockIdx(ti,:) = [base+1, base+2];
                end
                sm.towerClockIdx = tClockIdx;
            else
                sm.towerClockIdx = zeros(nTowers, 2);
            end
        end

        % ----------------------------------------------------------------
        function F = buildF_(obj, dt_s, euler, omega)
            % buildF_  Linearised state transition Jacobian.
            nx = obj.nx;
            F  = eye(nx);
            sm = obj.stateMap;

            % Position: dr/dv = dt*I
            F(sm.r_idx, sm.v_idx) = dt_s * eye(3);

            % Attitude: simple first-order approximation
            % deul_new/deul ~= I + dt * d(edot)/d(eul)
            % For v1 we use identity (small-angle / slow rotation assumption)
            % deul_new/domega = dt * d(edot)/domega = dt * T(euler)
            % where T is the kinematic transformation matrix
            cr = cos(euler(1)); sr = sin(euler(1));
            cp = cos(euler(2)); tp = tan(euler(2));
            if abs(cp) < 1e-6; cp = 1e-6*sign(cp+eps); end

            T = [1, sr*tp, cr*tp; 0, cr, -sr; 0, sr/cp, cr/cp];
            F(sm.euler_idx, sm.omega_idx) = dt_s * T;

            % Receiver clock
            F(sm.b_rx_idx, sm.bdot_rx_idx) = dt_s;

            % Tower clocks (random-walk of bias from drift)
            if obj.estimateTowerClocks
                for ti = 1:obj.nTowers
                    idx_b    = sm.towerClockIdx(ti,1);
                    idx_bdot = sm.towerClockIdx(ti,2);
                    F(idx_b, idx_bdot) = dt_s;
                end
            end
        end

        % ----------------------------------------------------------------
        function Q = buildQ_(obj, dt_s, towerClockModels)
            nx = obj.nx;
            Q  = zeros(nx);
            sm = obj.stateMap;

            % Velocity process noise (position driven by velocity uncertainty)
            sigma_a = obj.sigma_accel_mps2;
            % Discrete-time approximation: Q_rv from continuous white accel
            q_v = sigma_a^2 * dt_s;
            q_r = sigma_a^2 * dt_s^3 / 3;
            q_rv= sigma_a^2 * dt_s^2 / 2;
            for k = 1:3
                Q(sm.r_idx(k), sm.r_idx(k)) = q_r;
                Q(sm.v_idx(k), sm.v_idx(k)) = q_v;
                Q(sm.r_idx(k), sm.v_idx(k)) = q_rv;
                Q(sm.v_idx(k), sm.r_idx(k)) = q_rv;
            end

            % Angular velocity process noise
            sigma_aa = obj.sigma_angAccel_radps2;
            q_omg = sigma_aa^2 * dt_s;
            q_eul = sigma_aa^2 * dt_s^3 / 3;
            for k = 1:3
                Q(sm.omega_idx(k), sm.omega_idx(k)) = q_omg;
                Q(sm.euler_idx(k), sm.euler_idx(k)) = q_eul;
            end

            % Receiver clock process noise
            if ~isempty(obj.rxClockModel)
                Qclk = obj.rxClockModel.getProcessNoiseQ(dt_s, 'meters');
            else
                % Fallback simple clock process noise
                Qclk = diag([1e-4, 1e-8]) * dt_s;
            end
            Q(sm.b_rx_idx,    sm.b_rx_idx)    = Qclk(1,1);
            Q(sm.b_rx_idx,    sm.bdot_rx_idx) = Qclk(1,2);
            Q(sm.bdot_rx_idx, sm.b_rx_idx)    = Qclk(2,1);
            Q(sm.bdot_rx_idx, sm.bdot_rx_idx) = Qclk(2,2);

            % Tower clock process noise (if estimated)
            if obj.estimateTowerClocks && nargin >= 3 && ~isempty(towerClockModels)
                for ti = 1:min(obj.nTowers, numel(towerClockModels))
                    idx_b    = sm.towerClockIdx(ti,1);
                    idx_bdot = sm.towerClockIdx(ti,2);
                    if ~isempty(towerClockModels{ti})
                        Qtwri = towerClockModels{ti}.getProcessNoiseQ(dt_s,'meters');
                    else
                        Qtwri = diag([1e-4, 1e-8]) * dt_s;
                    end
                    Q(idx_b,    idx_b)    = Qtwri(1,1);
                    Q(idx_b,    idx_bdot) = Qtwri(1,2);
                    Q(idx_bdot, idx_b)    = Qtwri(2,1);
                    Q(idx_bdot, idx_bdot) = Qtwri(2,2);
                end
            end
        end

        % ----------------------------------------------------------------
        function initHistory_(obj)
            obj.history.time_s      = [];
            obj.history.x           = [];
            obj.history.P_diag      = [];
            obj.history.NIS         = [];
            obj.history.innovation  = {};
            obj.history.posErrNorm_m= [];
        end

        function logStep(obj, t_s, NIS, posErr_m)
            obj.history.time_s       = [obj.history.time_s;       t_s];
            obj.history.x            = [obj.history.x,            obj.x];
            obj.history.P_diag       = [obj.history.P_diag,       diag(obj.P)];
            obj.history.NIS          = [obj.history.NIS;          NIS];
            obj.history.posErrNorm_m = [obj.history.posErrNorm_m; posErr_m];
        end
    end
end

% ======================================================================
function Aout = nearestSPD_(A)
    % nearestSPD_  Project A to nearest symmetric positive-definite matrix.
    B = (A + A') / 2;
    [V, D] = eig(B);
    d = max(diag(D), 1e-12);
    Aout = V * diag(d) * V';
    Aout = (Aout + Aout') / 2;
end
