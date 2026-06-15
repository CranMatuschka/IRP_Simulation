classdef ReverseGNSSEKF < handle
    % ReverseGNSSEKF  Extended Kalman Filter for reverse-GNSS navigation.
    %
    % Base state vector (14 states):
    %   x(1:3)    r_cm_ecef_m          ECEF position [m]
    %   x(4:6)    v_ecef_mps           ECEF velocity [m/s]
    %   x(7:9)    euler_rad            Attitude [roll; pitch; yaw] ZYX [rad]
    %   x(10:12)  omega_body_radps     Angular velocity body frame [rad/s]
    %   x(13)     b_rx_m               Receiver clock bias [m]
    %   x(14)     bdot_rx_mps          Receiver clock drift [m/s]
    %
    % Optional tower clock states (estimateTowerClocks = true):
    %   x(15+2*(i-1))   b_tower_i_m
    %   x(16+2*(i-1))   bdot_tower_i_mps
    %
    % Covariance update: Joseph stabilised form
    %   P = (I - K*H) * P * (I - K*H)' + K*R*K'
    %
    % Process noise Q:
    %   - Position/velocity: continuous white-acceleration model
    %   - Euler/omega: continuous angular-acceleration model WITH cross terms
    %       Q_euler_euler = sigma_aa^2 * dt^3/3
    %       Q_euler_omega = sigma_aa^2 * dt^2/2  ← cross term (new)
    %       Q_omega_omega = sigma_aa^2 * dt
    %   - Clock: Brown-Hwang 2-state (from ClockModel.getProcessNoiseQ)
    %   - Attitude/omega Q is zeroed when estimateAttitude/estimateAngularRate = false
    %
    % State transition F:
    %   - Euler-euler block: FD derivative of (eul + dt*T(eul,omg)*omg) w.r.t. eul
    %   - Euler-omega block: dt * T(eul)   [same as before]
    %   - Clock bias-drift: F_b_bdot = dt
    %
    % NOTE: If lever arm = 0, attitude states are unobservable from pseudorange.

    properties
        x               (:,1) double
        P               (:,:) double

        cfg             (1,1) struct
        stateMap        (1,1) struct

        nxBase          (1,1) double = 14
        nx              (1,1) double = 14
        nTowers         (1,1) double = 0

        estimateTowerClocks  (1,1) logical = false

        % Carrier float ambiguity states
        estimateAmbiguities  (1,1) logical = false
        nAmbiguities         (1,1) double  = 0
        ambiguityNSignals    (1,1) double  = 1   % signals per tower

        % Per-tower ZWD states
        estimateZwd          (1,1) logical = false
        nZwdStates           (1,1) double  = 0

        % Process noise parameters
        sigma_accel_mps2      (1,1) double = 0.01
        sigma_angAccel_radps2 (1,1) double = 1e-4

        % Observability flags: set to false to freeze states via Q = ~0
        estimateAttitude      (1,1) logical = true
        estimateAngularRate   (1,1) logical = true

        % Clock model (for process noise)
        rxClockModel     revgnss.ClockModel

        % Diagnostics
        history          (1,1) struct
    end

    methods
        function obj = ReverseGNSSEKF(cfg, nTowers, rxClockModel)
            if nargin == 0; return; end

            obj.cfg     = cfg;
            obj.nTowers = nTowers;

            if isfield(cfg.estimator,'estimateTowerClocks')
                obj.estimateTowerClocks = cfg.estimator.estimateTowerClocks;
            end
            if isfield(cfg.estimator,'estimateAttitude')
                obj.estimateAttitude = cfg.estimator.estimateAttitude;
            end
            if isfield(cfg.estimator,'estimateAngularRate')
                obj.estimateAngularRate = cfg.estimator.estimateAngularRate;
            end

            % Determine if ambiguity states requested
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode') && ...
                    strcmp(cfg.measurements.carrierMode,'ekfFloat')
                ambMode = '';
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode')
                    ambMode = cfg.estimation.ambiguityMode;
                end
                if strcmp(ambMode,'floatPerTowerSignal')
                    obj.estimateAmbiguities = true;
                    % Carrier EKF in v1 supports L1 only (computeCarrierEkfRows_
                    % uses sigIdx=1 only).  Always allocate nTowers ambiguity
                    % states regardless of how many signals are enabled so no
                    % unobserved L2 ambiguity states are silently created.
                    obj.ambiguityNSignals = 1;
                    obj.nAmbiguities = nTowers * obj.ambiguityNSignals;
                end
            end

            % Determine if ZWD states requested
            if isfield(cfg,'estimation') && isfield(cfg.estimation,'troposphereMode') && ...
                    strcmp(cfg.estimation.troposphereMode,'perTowerZwd')
                obj.estimateZwd    = true;
                obj.nZwdStates     = nTowers;
            end

            obj.nx = obj.nxBase;
            if obj.estimateTowerClocks
                obj.nx = obj.nx + 2 * nTowers;
            end
            if obj.estimateAmbiguities
                obj.nx = obj.nx + obj.nAmbiguities;
            end
            if obj.estimateZwd
                obj.nx = obj.nx + obj.nZwdStates;
            end

            if isfield(cfg.estimator,'sigma_accel_mps2')
                obj.sigma_accel_mps2 = cfg.estimator.sigma_accel_mps2;
            end
            if isfield(cfg.estimator,'sigma_angAccel_radps2')
                obj.sigma_angAccel_radps2 = cfg.estimator.sigma_angAccel_radps2;
            end

            if nargin >= 3 && ~isempty(rxClockModel)
                obj.rxClockModel = rxClockModel;
            end

            obj.stateMap = obj.buildStateMap_(nTowers);
            obj.x = zeros(obj.nx, 1);
            obj.P = eye(obj.nx);

            % Warn about zero lever arm only when attitude from pseudorange is requested
            doAttPR = isfield(cfg.estimator,'estimateAttitudeFromPseudorange') && ...
                cfg.estimator.estimateAttitudeFromPseudorange;
            if doAttPR && isfield(cfg.asset,'receiverLeverArm_body_m') && ...
                    norm(cfg.asset.receiverLeverArm_body_m) < 1e-9
                warning('ReverseGNSSEKF:noLeverArm', ...
                    'estimateAttitudeFromPseudorange=true but lever arm is zero. Attitude unobservable.');
            end

            obj.initHistory_();
        end

        % ----------------------------------------------------------------
        function initState(obj, x0, P0)
            obj.x = x0(:);
            obj.P = P0;
        end

        % ----------------------------------------------------------------
        function predict(obj, dt_s, towerClockModels)
            x  = obj.x;
            sm = obj.stateMap;

            r   = x(sm.r_idx);
            v   = x(sm.v_idx);
            eul = x(sm.euler_idx);
            omg = x(sm.omega_idx);
            b_rx    = x(sm.b_rx_idx);
            bdot_rx = x(sm.bdot_rx_idx);

            % Position: constant-velocity
            r_new = r + dt_s * v;
            v_new = v;

            % Attitude: Euler kinematics (frozen when estimation disabled)
            if obj.estimateAttitude
                edot    = revgnss.AttitudeKinematics.eulerRatesFromBodyRates(eul, omg);
                eul_new = revgnss.AttitudeKinematics.wrapEuler(eul + dt_s * edot);
            else
                eul_new = eul;   % freeze state — no kinematics update
            end
            % Angular rate: constant-rate model in v1 regardless of flag
            omg_new = omg;

            % Receiver clock
            b_rx_new    = b_rx + dt_s * bdot_rx;
            bdot_rx_new = bdot_rx;

            x_new = x;
            x_new(sm.r_idx)       = r_new;
            x_new(sm.v_idx)       = v_new;
            x_new(sm.euler_idx)   = eul_new;
            x_new(sm.omega_idx)   = omg_new;
            x_new(sm.b_rx_idx)    = b_rx_new;
            x_new(sm.bdot_rx_idx) = bdot_rx_new;

            % Tower clocks (if estimated)
            if obj.estimateTowerClocks && nargin >= 3
                for ti = 1:obj.nTowers
                    ib = sm.towerClockIdx(ti,1);
                    id = sm.towerClockIdx(ti,2);
                    x_new(ib) = x(ib) + dt_s * x(id);
                    x_new(id) = x(id);
                end
            end
            obj.x = x_new;

            % State transition Jacobian F
            F = obj.buildF_(dt_s, eul, omg);

            % Process noise Q
            Q = obj.buildQ_(dt_s, towerClockModels);

            % Propagate covariance
            obj.P = F * obj.P * F' + Q;
            obj.P = (obj.P + obj.P') / 2;
        end

        % ----------------------------------------------------------------
        function [K, nu, S, NIS] = update(obj, z, h, H, R)
            % update  EKF measurement update (Joseph stabilised form).
            %
            % NIS = nu' * (S \ nu)   — uses MATLAB backslash for numerical safety.
            % Kalman gain K = (P * H') / S  (right division, equivalent to P*H'*inv(S)).

            if isempty(z)
                K = []; nu = []; S = []; NIS = NaN;
                return
            end

            nu = z - h;

            S = H * obj.P * H' + R;
            S = (S + S') / 2;

            % Kalman gain: right-division avoids explicit matrix inverse
            K = obj.P * H' / S;

            % State update
            obj.x = obj.x + K * nu;
            obj.x(obj.stateMap.euler_idx) = revgnss.AttitudeKinematics.wrapEuler( ...
                obj.x(obj.stateMap.euler_idx));

            % Joseph stabilised covariance
            nx  = obj.nx;
            IKH = eye(nx) - K * H;
            obj.P = IKH * obj.P * IKH' + K * R * K';
            obj.P = (obj.P + obj.P') / 2;

            % Numerical sanity
            if any(~isfinite(obj.P(:)))
                warning('ReverseGNSSEKF:update','NaN/Inf in P after update');
            end
            eigP   = eig(obj.P);
            minEig = min(eigP);
            tol    = max(1e-12, 1e-12 * max(abs(diag(obj.P))));
            if minEig < -tol
                % Genuinely non-PSD: project to nearest SPD
                warning('ReverseGNSSEKF:update', ...
                    'P not PSD (minEig=%.2e); projecting to nearest SPD.', minEig);
                obj.P = nearestSPD_(obj.P);
                obj.P = (obj.P + obj.P') / 2;   % extra symmetrise after projection
            elseif minEig < 0
                % Tiny negative eigenvalue from floating-point: nudge diagonal
                obj.P = (obj.P + obj.P') / 2;
                obj.P = obj.P + eye(obj.nx) * (tol - minEig);
            end

            % NIS: nu' * S^{-1} * nu  via backslash
            NIS = nu' * (S \ nu);
        end

        % ----------------------------------------------------------------
        function sm = buildStateMap_(obj, nTowers)
            sm.r_idx       = (1:3)';
            sm.v_idx       = (4:6)';
            sm.euler_idx   = (7:9)';
            sm.omega_idx   = (10:12)';
            sm.b_rx_idx    = 13;
            sm.bdot_rx_idx = 14;

            nextIdx = obj.nxBase + 1;

            % Optional tower clock states
            if obj.estimateTowerClocks && nTowers > 0
                tClockIdx = zeros(nTowers, 2);
                for ti = 1:nTowers
                    tClockIdx(ti,:) = [nextIdx, nextIdx+1];
                    nextIdx = nextIdx + 2;
                end
                sm.towerClockIdx = tClockIdx;
            else
                sm.towerClockIdx = zeros(nTowers, 2);
            end

            % Optional float ambiguity states: [nTowers x nSignals]
            % ambiguityIdx(ti, si) = state index for tower ti, signal si
            if obj.estimateAmbiguities && obj.nAmbiguities > 0
                nSig = obj.ambiguityNSignals;
                ambIdx = zeros(nTowers, nSig);
                for ti = 1:nTowers
                    for si = 1:nSig
                        ambIdx(ti, si) = nextIdx;
                        nextIdx = nextIdx + 1;
                    end
                end
                sm.ambiguityIdx = ambIdx;
            else
                sm.ambiguityIdx = zeros(nTowers, max(1, obj.ambiguityNSignals));
            end

            % Optional per-tower ZWD states
            if obj.estimateZwd && obj.nZwdStates > 0
                zwdIdx = zeros(nTowers, 1);
                for ti = 1:nTowers
                    zwdIdx(ti) = nextIdx;
                    nextIdx    = nextIdx + 1;
                end
                sm.zwdIdx = zwdIdx;
            else
                sm.zwdIdx = zeros(nTowers, 1);
            end
        end

        % ----------------------------------------------------------------
        function F = buildF_(obj, dt_s, euler, omega)
            % buildF_  Linearised state-transition Jacobian.
            %
            % Euler-euler block: FD derivative of (eul + dt * T(eul,omg)*omg) w.r.t. eul.
            %   This is more accurate than the identity approximation used previously,
            %   especially when omega or euler are non-zero.
            % Euler-omega block: dt * T(euler)  [kinematic transformation].

            nx = obj.nx;
            F  = eye(nx);
            sm = obj.stateMap;

            % Position-velocity coupling
            F(sm.r_idx, sm.v_idx) = dt_s * eye(3);

            % Euler-euler block: FD of euler kinematics w.r.t. euler
            fdStep = 1e-7;
            for ai = 1:3
                eul_p = euler; eul_p(ai) = eul_p(ai) + fdStep;
                eul_m = euler; eul_m(ai) = eul_m(ai) - fdStep;

                edot_p = revgnss.AttitudeKinematics.eulerRatesFromBodyRates(eul_p, omega);
                edot_m = revgnss.AttitudeKinematics.eulerRatesFromBodyRates(eul_m, omega);

                eul_new_p = eul_p + dt_s * edot_p;
                eul_new_m = eul_m + dt_s * edot_m;

                % Column ai of the euler-euler Jacobian block
                F(sm.euler_idx, sm.euler_idx(ai)) = (eul_new_p - eul_new_m) / (2 * fdStep);
            end

            % Euler-omega block: dt * T(euler)
            cr = cos(euler(1)); sr = sin(euler(1));
            cp = cos(euler(2)); tp = tan(euler(2));
            if abs(cp) < 1e-6; cp = sign(cp + eps) * 1e-6; end

            T = [1, sr*tp, cr*tp; 0, cr, -sr; 0, sr/cp, cr/cp];
            F(sm.euler_idx, sm.omega_idx) = dt_s * T;

            % Freeze attitude kinematics when estimation is disabled.
            % This prevents numerical drift of the euler/omega states.
            if ~obj.estimateAttitude
                F(sm.euler_idx, sm.euler_idx) = eye(3);
                F(sm.euler_idx, sm.omega_idx) = zeros(3);
            end
            if ~obj.estimateAngularRate
                F(sm.omega_idx, sm.omega_idx) = eye(3);
                F(sm.omega_idx, sm.euler_idx) = zeros(3);
            end

            % Receiver clock bias-drift coupling
            F(sm.b_rx_idx, sm.bdot_rx_idx) = dt_s;

            % Tower clock bias-drift coupling (if estimated)
            if obj.estimateTowerClocks
                for ti = 1:obj.nTowers
                    F(sm.towerClockIdx(ti,1), sm.towerClockIdx(ti,2)) = dt_s;
                end
            end

            % Ambiguity states: identity (random walk; F = I already)
            % ZWD states: first-order Gauss-Markov phi = exp(-dt/tau)
            if obj.estimateZwd
                tau_zwd = 3600;
                if isfield(obj.cfg,'estimation') && isfield(obj.cfg.estimation,'tropoZwd') && ...
                        isfield(obj.cfg.estimation.tropoZwd,'tau_s')
                    tau_zwd = obj.cfg.estimation.tropoZwd.tau_s;
                end
                phi_zwd = exp(-dt_s / tau_zwd);
                for ti = 1:obj.nTowers
                    idx = sm.zwdIdx(ti);
                    if idx > 0
                        F(idx, idx) = phi_zwd;
                    end
                end
            end
        end

        % ----------------------------------------------------------------
        function Q = buildQ_(obj, dt_s, towerClockModels)
            % buildQ_  Discrete-time process noise matrix.
            %
            % Position/velocity: continuous white-acceleration model.
            % Euler/omega: angular-acceleration model with cross terms
            %   Q_ee = sigma_aa^2 * dt^3/3
            %   Q_eo = sigma_aa^2 * dt^2/2   (euler-omega cross term)
            %   Q_oo = sigma_aa^2 * dt
            % If estimateAttitude = false: Q_ee ~ 0.
            % If estimateAngularRate = false: Q_oo ~ 0.

            nx = obj.nx;
            Q  = zeros(nx);
            sm = obj.stateMap;

            % --- Position / velocity process noise ----------------------
            sa  = obj.sigma_accel_mps2;
            q_r  = sa^2 * dt_s^3 / 3;
            q_v  = sa^2 * dt_s;
            q_rv = sa^2 * dt_s^2 / 2;
            for k = 1:3
                Q(sm.r_idx(k), sm.r_idx(k)) = q_r;
                Q(sm.v_idx(k), sm.v_idx(k)) = q_v;
                Q(sm.r_idx(k), sm.v_idx(k)) = q_rv;
                Q(sm.v_idx(k), sm.r_idx(k)) = q_rv;
            end

            % --- Euler / omega process noise (with cross terms) ---------
            saa      = obj.sigma_angAccel_radps2;
            q_eul    = saa^2 * dt_s^3 / 3;
            q_omg    = saa^2 * dt_s;
            q_eul_omg = saa^2 * dt_s^2 / 2;    % cross term (new)

            % Scale to near-zero when states are frozen
            if ~obj.estimateAttitude
                q_eul    = q_eul    * 1e-20;
                q_eul_omg = q_eul_omg * 1e-20;
            end
            if ~obj.estimateAngularRate
                q_omg    = q_omg    * 1e-20;
                q_eul_omg = q_eul_omg * 1e-20;
            end

            for k = 1:3
                Q(sm.euler_idx(k), sm.euler_idx(k)) = q_eul;
                Q(sm.omega_idx(k), sm.omega_idx(k)) = q_omg;
                Q(sm.euler_idx(k), sm.omega_idx(k)) = q_eul_omg;
                Q(sm.omega_idx(k), sm.euler_idx(k)) = q_eul_omg;
            end

            % --- Receiver clock process noise ---------------------------
            if ~isempty(obj.rxClockModel)
                Qclk = obj.rxClockModel.getProcessNoiseQ(dt_s, 'meters');
            else
                Qclk = diag([1e-4, 1e-8]) * dt_s;
            end
            Q(sm.b_rx_idx,    sm.b_rx_idx)    = Qclk(1,1);
            Q(sm.b_rx_idx,    sm.bdot_rx_idx) = Qclk(1,2);
            Q(sm.bdot_rx_idx, sm.b_rx_idx)    = Qclk(2,1);
            Q(sm.bdot_rx_idx, sm.bdot_rx_idx) = Qclk(2,2);

            % --- Tower clock process noise (if estimated) ---------------
            if obj.estimateTowerClocks && nargin >= 3 && ~isempty(towerClockModels)
                for ti = 1:min(obj.nTowers, numel(towerClockModels))
                    ib = sm.towerClockIdx(ti,1);
                    id = sm.towerClockIdx(ti,2);
                    if ~isempty(towerClockModels{ti})
                        Qtwr = towerClockModels{ti}.getProcessNoiseQ(dt_s,'meters');
                    else
                        Qtwr = diag([1e-4, 1e-8]) * dt_s;
                    end
                    Q(ib,ib) = Qtwr(1,1); Q(ib,id) = Qtwr(1,2);
                    Q(id,ib) = Qtwr(2,1); Q(id,id) = Qtwr(2,2);
                end
            end

            % --- Ambiguity process noise (random walk, very small) -------
            if obj.estimateAmbiguities
                q_amb_sigma = 1e-5;   % default [m/sqrt(s)]
                if isfield(obj.cfg,'estimation') && isfield(obj.cfg.estimation,'ambiguity') && ...
                        isfield(obj.cfg.estimation.ambiguity,'processNoiseSigma_m_per_sqrt_s')
                    q_amb_sigma = obj.cfg.estimation.ambiguity.processNoiseSigma_m_per_sqrt_s;
                end
                q_amb = q_amb_sigma^2 * dt_s;
                nSig  = obj.ambiguityNSignals;
                for ti = 1:obj.nTowers
                    for si = 1:nSig
                        idx = sm.ambiguityIdx(ti, si);
                        if idx > 0
                            Q(idx, idx) = q_amb;
                        end
                    end
                end
            end

            % --- ZWD process noise (Gauss-Markov steady-state) ----------
            if obj.estimateZwd
                tau_zwd    = 3600;
                sigma_ss   = 0.05;
                if isfield(obj.cfg,'estimation') && isfield(obj.cfg.estimation,'tropoZwd')
                    tz = obj.cfg.estimation.tropoZwd;
                    if isfield(tz,'tau_s');       tau_zwd  = tz.tau_s;       end
                    if isfield(tz,'sigma_ss_m');  sigma_ss = tz.sigma_ss_m;  end
                end
                phi_zwd = exp(-dt_s / tau_zwd);
                q_zwd   = sigma_ss^2 * (1 - phi_zwd^2);
                for ti = 1:obj.nTowers
                    idx = sm.zwdIdx(ti);
                    if idx > 0
                        Q(idx, idx) = q_zwd;
                    end
                end
            end

            % Enforce symmetry
            Q = (Q + Q') / 2;
        end

        % ----------------------------------------------------------------
        function resetAmbiguityCovariance(obj, towerIdx, sigIdx)
            % resetAmbiguityCovariance  Reset ambiguity covariance after cycle slip.
            %
            % Sets P(amb,amb) to initialSigma_m^2 for tower towerIdx, signal sigIdx.
            % Used when a cycle slip is detected or synthesized.
            if ~obj.estimateAmbiguities; return; end
            sm = obj.stateMap;
            if towerIdx < 1 || towerIdx > obj.nTowers; return; end
            if sigIdx < 1   || sigIdx > obj.ambiguityNSignals; return; end
            idx = sm.ambiguityIdx(towerIdx, sigIdx);
            if idx <= 0 || idx > obj.nx; return; end

            initSig = 100;
            if isfield(obj.cfg,'estimation') && isfield(obj.cfg.estimation,'ambiguity') && ...
                    isfield(obj.cfg.estimation.ambiguity,'initialSigma_m')
                initSig = obj.cfg.estimation.ambiguity.initialSigma_m;
            end
            obj.P(idx, :) = 0;
            obj.P(:, idx) = 0;
            obj.P(idx, idx) = initSig^2;
        end

        % ----------------------------------------------------------------
        % ----------------------------------------------------------------
        function [z_out, h_out, H_out, R_out, gaugeInfo] = appendClockGaugeRows(obj, z, h, H, R)
            % appendClockGaugeRows  Augment measurement stack with clock-gauge pseudo-rows.
            %
            % Clock-gauge pseudo-measurements constrain the datum ambiguity in the
            % joint spacecraft-receiver / tower-transmitter clock subspace.  One-way
            % pseudorange observes only clock differences; without a gauge, the common
            % clock offset is unobservable (rank-deficient clock subspace).
            %
            % Gauge modes (cfg.clock.gauge.mode):
            %   'fixReferenceTower'    — pin reference tower bias+drift to zero.
            %       H_gauge(b_twr_ref) = 1, R_gauge = sigmaBias^2.
            %   'meanGroundClockGauge' — pin mean tower bias+drift to zero.
            %       H_gauge(b_twr_i)   = 1/N for all i.
            %   others                 — no gauge rows (external correction assumed).
            %
            % The gauge rows enter the same EKF update as physical measurements so
            % that both state AND covariance are constrained through K and P update.
            %
            % Outputs:
            %   z_out, h_out, H_out, R_out  augmented stack (physical + gauge)
            %   gaugeInfo  struct: rowsAdded, types, biasResidual_m,
            %              driftResidual_mps, biasSigma_m, driftSigma_mps,
            %              clockSubspaceRank, clockSubspaceCondNum

            z_out = z; h_out = h; H_out = H; R_out = R;
            gaugeInfo.rowsAdded            = 0;
            gaugeInfo.types                = {};
            gaugeInfo.biasResidual_m       = NaN;
            gaugeInfo.driftResidual_mps    = NaN;
            gaugeInfo.biasSigma_m          = NaN;
            gaugeInfo.driftSigma_mps       = NaN;
            gaugeInfo.clockSubspaceRank    = NaN;
            gaugeInfo.clockSubspaceCondNum = NaN;
            gaugeInfo.H_gauge              = zeros(0, size(H,2));  % for Gramian computation
            gaugeInfo.R_gauge_diag         = zeros(0, 1);

            if ~obj.estimateTowerClocks || obj.nTowers < 1
                return;
            end

            sm = obj.stateMap;
            nx = obj.nx;

            % Read gauge parameters
            gaugeMode   = 'externalTowerCorrections';
            sigmaBias   = 1e-6;
            sigmaDrift  = 1e-9;
            refTowerIdx = 1;
            if isfield(obj.cfg,'clock') && isfield(obj.cfg.clock,'gauge')
                g = obj.cfg.clock.gauge;
                if isfield(g,'mode');               gaugeMode   = g.mode;               end
                if isfield(g,'sigmaBias_m');         sigmaBias   = g.sigmaBias_m;        end
                if isfield(g,'sigmaDrift_mps');      sigmaDrift  = g.sigmaDrift_mps;     end
                if isfield(g,'referenceTowerIndex'); refTowerIdx = g.referenceTowerIndex; end
            end
            gaugeInfo.biasSigma_m    = sigmaBias;
            gaugeInfo.driftSigma_mps = sigmaDrift;

            % Tower drift states are allocated when estimateTowerClocks=true
            hasDrift = (sm.towerClockIdx(1,2) > 0);

            switch gaugeMode
                case 'fixReferenceTower'
                    kref    = max(1, min(refTowerIdx, obj.nTowers));
                    idxBias = sm.towerClockIdx(kref, 1);
                    idxDrft = sm.towerClockIdx(kref, 2);

                    % Bias pseudo-measurement: z=0, h=x(b_twr_ref), H_row selects that state
                    Hb = zeros(1, nx); Hb(idxBias) = 1;
                    z_out = [z_out; 0];
                    h_out = [h_out; obj.x(idxBias)];
                    H_out = [H_out; Hb];
                    R_out = blkdiag(R_out, sigmaBias^2);
                    gaugeInfo.types{end+1}   = 'clockGaugeBias';
                    gaugeInfo.biasResidual_m = obj.x(idxBias);
                    gaugeInfo.rowsAdded      = gaugeInfo.rowsAdded + 1;
                    gaugeInfo.H_gauge        = [gaugeInfo.H_gauge; Hb];
                    gaugeInfo.R_gauge_diag   = [gaugeInfo.R_gauge_diag; sigmaBias^2];

                    if hasDrift && idxDrft > 0
                        Hd = zeros(1, nx); Hd(idxDrft) = 1;
                        z_out = [z_out; 0];
                        h_out = [h_out; obj.x(idxDrft)];
                        H_out = [H_out; Hd];
                        R_out = blkdiag(R_out, sigmaDrift^2);
                        gaugeInfo.types{end+1}        = 'clockGaugeDrift';
                        gaugeInfo.driftResidual_mps   = obj.x(idxDrft);
                        gaugeInfo.rowsAdded           = gaugeInfo.rowsAdded + 1;
                        gaugeInfo.H_gauge             = [gaugeInfo.H_gauge; Hd];
                        gaugeInfo.R_gauge_diag        = [gaugeInfo.R_gauge_diag; sigmaDrift^2];
                    end

                case 'meanGroundClockGauge'
                    N = obj.nTowers;
                    biasIdx  = sm.towerClockIdx(:, 1);
                    driftIdx = sm.towerClockIdx(:, 2);

                    % Mean bias pseudo-measurement: H(b_twr_i) = 1/N for all i
                    Hb = zeros(1, nx); Hb(biasIdx) = 1/N;
                    meanBias = mean(obj.x(biasIdx));
                    z_out = [z_out; 0];
                    h_out = [h_out; meanBias];
                    H_out = [H_out; Hb];
                    R_out = blkdiag(R_out, sigmaBias^2);
                    gaugeInfo.types{end+1}   = 'clockGaugeBias';
                    gaugeInfo.biasResidual_m = meanBias;
                    gaugeInfo.rowsAdded      = gaugeInfo.rowsAdded + 1;
                    gaugeInfo.H_gauge        = [gaugeInfo.H_gauge; Hb];
                    gaugeInfo.R_gauge_diag   = [gaugeInfo.R_gauge_diag; sigmaBias^2];

                    if hasDrift && all(driftIdx > 0)
                        Hd = zeros(1, nx); Hd(driftIdx) = 1/N;
                        meanDrift = mean(obj.x(driftIdx));
                        z_out = [z_out; 0];
                        h_out = [h_out; meanDrift];
                        H_out = [H_out; Hd];
                        R_out = blkdiag(R_out, sigmaDrift^2);
                        gaugeInfo.types{end+1}        = 'clockGaugeDrift';
                        gaugeInfo.driftResidual_mps   = meanDrift;
                        gaugeInfo.rowsAdded           = gaugeInfo.rowsAdded + 1;
                        gaugeInfo.H_gauge             = [gaugeInfo.H_gauge; Hd];
                        gaugeInfo.R_gauge_diag        = [gaugeInfo.R_gauge_diag; sigmaDrift^2];
                    end

                otherwise
                    % 'externalTowerCorrections' or unknown: no gauge rows
                    return;
            end

            % Clock-subspace rank diagnostic (uses augmented H)
            gaugeInfo = obj.computeClockSubspaceStats_(H_out, gaugeInfo);
        end

        % ----------------------------------------------------------------
        function gaugeInfo = computeClockSubspaceStats_(obj, H_full, gaugeInfo)
            % computeClockSubspaceStats_  SVD rank/condition of H restricted to clock columns.
            %
            % Extracts columns of H corresponding to:
            %   receiver clock bias, receiver clock drift,
            %   tower clock biases, tower clock drifts (if estimated).
            % Reports numerical rank and condition number of H_clock.
            % rank(H_clock) = nClockStates means the gauge removes the nullspace.
            sm     = obj.stateMap;
            clkIdx = [sm.b_rx_idx; sm.bdot_rx_idx];
            if obj.estimateTowerClocks
                clkIdx = [clkIdx; sm.towerClockIdx(:,1); sm.towerClockIdx(:,2)];
            end
            clkIdx = clkIdx(clkIdx > 0);

            if isempty(H_full) || size(H_full,2) < max(clkIdx)
                return;
            end

            H_clk = H_full(:, clkIdx);
            sv    = svd(H_clk, 'econ');
            sv    = sv(sv > 0);
            if isempty(sv)
                gaugeInfo.clockSubspaceRank   = 0;
                gaugeInfo.clockSubspaceCondNum = Inf;
            else
                tol = sv(1) * max(size(H_clk)) * eps;
                gaugeInfo.clockSubspaceRank   = sum(sv > tol);
                gaugeInfo.clockSubspaceCondNum = sv(1) / max(sv(end), eps);
            end
        end

        % ----------------------------------------------------------------
        function initHistory_(obj)
            obj.history.time_s      = [];
            obj.history.x           = [];
            obj.history.P_diag      = [];
            obj.history.NIS         = [];
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
    B = (A + A') / 2;
    [V, D] = eig(B);
    d = max(diag(D), 1e-12);
    Aout = V * diag(d) * V';
    Aout = (Aout + Aout') / 2;
end
