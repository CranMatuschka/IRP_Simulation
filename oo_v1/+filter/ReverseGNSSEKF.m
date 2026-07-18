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
        ambiguityNReceivers  (1,1) double  = 1   % receivers per tower (new mode)
        ambiguityMode        char          = 'floatPerTowerSignal'

        % Per-tower ZWD states
        estimateZwd          (1,1) logical = false
        nZwdStates           (1,1) double  = 0
        % Per-tower slant-ionosphere states (prototype: estimation.ionosphereMode='perTowerSlant').
        % One state per tower = the L1 slant ionospheric delay [m]; observable from the L1/L2
        % dispersion. An alternative to the ionosphere-free combination that keeps all
        % dual-frequency rows (no IF information penalty).
        estimateIono         (1,1) logical = false
        nIonoStates          (1,1) double  = 0

        % Per-tower transmitter code bias states
        estimateTxCodeBias   (1,1) logical = false
        nTxCodeBiasStates    (1,1) double  = 0

        % Process noise parameters
        sigma_accel_mps2      (1,1) double = 0.01
        sigma_angAccel_radps2 (1,1) double = 1e-4

        % Observability flags: set to false to freeze states via Q = ~0
        estimateAttitude      (1,1) logical = true
        estimateAngularRate   (1,1) logical = true

        % Optional gyro-bias states (IMU/MEKF attitude aiding). 3 states appended ONLY when
        % estimateGyroBias -> nx/state-map unchanged when off (golden-safe). On this path the
        % attitude is propagated with omega = omega_gyro - b_g (strapdown control input) and the
        % attitude process noise comes from the gyro ARW instead of the angular-accel model.
        estimateGyroBias      (1,1) logical = false
        imuArw_               (1,1) double  = 1e-4    % filter angle random walk [rad/sqrt(s)]
        imuRrw_               (1,1) double  = 1e-6    % filter bias rate random walk [rad/(s*sqrt(s))]
        imuP0Bias_            (1,1) double  = 1e-5    % initial bias 1-sigma (init done in ScenarioFactory)
        imuVanLoan_           (1,1) logical = false   % optional theta<->b_g Q cross term

        % WP3: secondary-asset clock states (bias+drift per secondary). Appended LAST
        % (after gyroBias) so no existing index shifts; off => nx/state-map identical
        % to today (golden-safe). Gated by MultiAssetConfig.secondaryClockCount(cfg).
        estimateSecondaryClocks (1,1) logical = false
        nSecondaryClocks        (1,1) double  = 0

        % Clock model (for process noise)
        rxClockModel     models.clocks.ClockModel

        % Diagnostics
        history          (1,1) struct

        % Last dynamics predict info (compact, overwritten each epoch)
        lastDynamicsPredictInfo (1,1) struct

        % Quaternion nominal / error-state attitude EKF
        nominalQuat_wxyz          double = [1;0;0;0]   % scalar-first unit quaternion
        attitudeParameterization  char   = 'eulerZYX'  % 'eulerZYX' | 'quaternionErrorState'
        lastAttitudeErrorStateInfo (1,1) struct
        attitudeInjectionCount    (1,1) double = 0
        maxAttitudeInjectionNorm_rad (1,1) double = 0
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
                    obj.ambiguityMode       = 'floatPerTowerSignal';
                    % nSignals from SignalCatalog (1=L1 only, 2=L1+L2 when guarded).
                    obj.ambiguityNSignals   = revgnss.SignalCatalog.nCarrierSignals(cfg);
                    obj.ambiguityNReceivers = 1;
                    obj.nAmbiguities = nTowers * obj.ambiguityNSignals;
                elseif strcmp(ambMode,'floatPerTowerReceiverSignal')
                    obj.estimateAmbiguities = true;
                    obj.ambiguityMode       = 'floatPerTowerReceiverSignal';
                    % nSignals from SignalCatalog (1=L1 only, 2=L1+L2 when guarded).
                    obj.ambiguityNSignals   = revgnss.SignalCatalog.nCarrierSignals(cfg);
                    nRx = 1;
                    if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                        nRx = cfg.scenario.nReceivers;
                    end
                    obj.ambiguityNReceivers = nRx;
                    obj.nAmbiguities = nTowers * nRx * obj.ambiguityNSignals;
                end
            end

            % Determine if ZWD states requested
            if isfield(cfg,'estimation') && isfield(cfg.estimation,'troposphereMode') && ...
                    strcmp(cfg.estimation.troposphereMode,'perTowerZwd')
                obj.estimateZwd    = true;
                obj.nZwdStates     = nTowers;
            end

            % Determine if per-tower slant-ionosphere states requested (prototype)
            if isfield(cfg,'estimation') && isfield(cfg.estimation,'ionosphereMode') && ...
                    strcmp(cfg.estimation.ionosphereMode,'perTowerSlant')
                obj.estimateIono   = true;
                obj.nIonoStates    = nTowers;
            end

            % Determine if tx code bias states requested
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'txCodeBias') && ...
                    isfield(cfg.hardware.txCodeBias,'useInEKF') && cfg.hardware.txCodeBias.useInEKF
                obj.estimateTxCodeBias   = true;
                obj.nTxCodeBiasStates    = nTowers;
            end

            % Optional gyro-bias states (IMU/MEKF aiding). Gated on estimateGyroBias (default false).
            if isfield(cfg.estimator,'estimateGyroBias')
                obj.estimateGyroBias = logical(cfg.estimator.estimateGyroBias);
            end
            if obj.estimateGyroBias
                try
                    obj.imuArw_     = cfg.estimator.imu.filter.arw_rad_per_sqrt_s;
                    obj.imuRrw_     = cfg.estimator.imu.filter.rrw_rad_per_s_sqrt_s;
                    obj.imuP0Bias_  = cfg.estimator.imu.filter.P0_bias_radps;
                    obj.imuVanLoan_ = logical(cfg.estimator.imu.filter.useVanLoanCrossTerm);
                catch; end
            end

            % WP3 secondary-clock gate. secondaryClockCount returns 0 unless
            % estimateMode=='clocks' AND nSpaceAssets>=2 AND ISL code is an active EKF
            % observable -- so golden (nSpaceAssets=1) and mode='off' both force it off.
            nSecClk_ = revgnss.MultiAssetConfig.secondaryClockCount(cfg);
            obj.estimateSecondaryClocks = nSecClk_ > 0;
            obj.nSecondaryClocks        = nSecClk_;

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
            if obj.estimateIono
                obj.nx = obj.nx + obj.nIonoStates;
            end
            if obj.estimateTxCodeBias
                obj.nx = obj.nx + obj.nTxCodeBiasStates;
            end
            if obj.estimateGyroBias
                obj.nx = obj.nx + 3;
            end
            if obj.estimateSecondaryClocks
                obj.nx = obj.nx + 2 * obj.nSecondaryClocks;   % [b_tx, bdot_tx] per secondary
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

            % Read attitude parameterization from config
            try
                p61 = cfg.estimator.attitude.parameterization;
                if ischar(p61) && ismember(p61, {'eulerZYX','quaternionErrorState'})
                    obj.attitudeParameterization = p61;
                end
            catch; end

            % Guard: the strapdown gyro-bias F block (F(theta,b_g) = -I*dt) is only built on the
            % quaternionErrorState (MEKF) path. On the eulerZYX path b_g would be UNOBSERVABLE
            % (zero Kalman gain, P(theta,b_g) stays 0) while predict() still propagates attitude
            % with omega = omega_gyro - b_g -> the attitude silently drifts with the full truth
            % gyro bias and NO warning is emitted. Refuse the combination rather than run garbage.
            if obj.estimateGyroBias && strcmp(obj.attitudeParameterization, 'eulerZYX')
                error('ReverseGNSSEKF:imuRequiresQuaternion', ...
                    ['IMU gyro-bias estimation (cfg.estimator.imu.enable) requires ' ...
                     'cfg.estimator.attitude.parameterization = ''quaternionErrorState''. ' ...
                     'The eulerZYX path has no gyro-bias Jacobian, so b_g would be unobservable ' ...
                     'and the attitude would drift with the uncorrected sensor bias.']);
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
            % Initialize nominal quaternion from initial Euler state
            if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                eul0 = obj.x(obj.stateMap.euler_idx);
                obj.nominalQuat_wxyz = revgnss.AttitudeErrorStateKinematics.eulerToQuatZYX(eul0);
                obj.x(obj.stateMap.euler_idx) = zeros(3, 1);  % error state starts at zero
                obj.attitudeInjectionCount    = 0;
                obj.maxAttitudeInjectionNorm_rad = 0;
            end
        end

        % ----------------------------------------------------------------
        function xMeas = getMeasurementState(obj)
            % getMeasurementState  State vector for measurement evaluation.
            % In quaternionErrorState mode: replaces x(euler_idx) with the
            % nominal euler angles from quatToEulerZYX(nominalQuat_wxyz) so
            % that h and H are evaluated at the nominal attitude.
            xMeas = obj.x;
            if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                xMeas(obj.stateMap.euler_idx) = ...
                    revgnss.AttitudeErrorStateKinematics.quatToEulerZYX(obj.nominalQuat_wxyz);
            end
        end

        function euler_rad = getReportEulerRad(obj)
            % getReportEulerRad  Attitude angles for reporting/diagnostics.
            if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                euler_rad = revgnss.AttitudeErrorStateKinematics.quatToEulerZYX( ...
                    obj.nominalQuat_wxyz);
            else
                euler_rad = obj.x(obj.stateMap.euler_idx);
            end
        end

        % ----------------------------------------------------------------
        function predict(obj, dt_s, towerClockModels, t0_s, omega_gyro_radps, secondaryClockModels)
            % predict  EKF time propagation.
            %   t0_s — simulation time at start of prediction interval.
            %   omega_gyro_radps (optional) — strapdown gyro body-rate reading. When the IMU is
            %   enabled the attitude is propagated with omega = omega_gyro - b_g; otherwise the
            %   free omega state is used (byte-identical to the pre-IMU behaviour).
            %   secondaryClockModels (optional, WP3) — cell of secondary-asset ClockModels
            %   (asset 2..N) supplying the per-secondary clock process noise Q.
            if nargin < 4 || isempty(t0_s); t0_s = 0; end
            if nargin < 5; omega_gyro_radps = []; end
            if nargin < 6; secondaryClockModels = {}; end

            x  = obj.x;
            sm = obj.stateMap;

            r   = x(sm.r_idx);
            v   = x(sm.v_idx);
            eul = x(sm.euler_idx);
            omg = x(sm.omega_idx);
            % IMU strapdown: drive attitude with the gyro reading minus the estimated bias.
            % omg then flows into the quaternion propagation and buildF_ (skew term) below.
            if obj.estimateGyroBias && ~isempty(omega_gyro_radps) && ~isempty(sm.gyroBiasIdx)
                omg = omega_gyro_radps(:) - x(sm.gyroBiasIdx);
            end
            b_rx    = x(sm.b_rx_idx);
            bdot_rx = x(sm.bdot_rx_idx);

            % Optional physical translational dynamics
            dynInfo = struct('mode','constantVelocity','usedInertialPropagation',false, ...
                'forceModel','none','frameModel','none', ...
                'specificEnergyInitial_Jkg',NaN,'specificEnergyFinal_Jkg',NaN, ...
                'energyDrift_Jkg',NaN,'warnings',{{}});
            Phi6 = [];  % empty = use default F block in buildF_
            dynMode = filter.EkfDynamicsPredictor.mode(obj.cfg);
            if strcmp(dynMode, 'constantVelocity')
                r_new = r + dt_s * v;
                v_new = v;
                dynInfo.mode = 'constantVelocity';
            else
                try
                    [r_new, v_new, dynInfo] = filter.EkfDynamicsPredictor.propagateEcef( ...
                        r, v, dt_s, t0_s, obj.cfg);
                    Phi6 = filter.EkfDynamicsPredictor.finiteDiffStm6( ...
                        r, v, dt_s, t0_s, obj.cfg);
                catch ME_dyn
                    warning('ReverseGNSSEKF:dynamicsFailed', ...
                        'Stage 58 dynamics failed (%s); reverting to constantVelocity.', ...
                        ME_dyn.message);
                    r_new = r + dt_s * v;
                    v_new = v;
                    dynInfo.mode = 'constantVelocity';
                    dynInfo.warnings{end+1} = ME_dyn.message;
                end
            end
            obj.lastDynamicsPredictInfo = dynInfo;

            % Attitude: kinematics update (frozen when estimation disabled)
            if obj.estimateAttitude
                if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                    % Propagate nominal quaternion; error state stays near zero
                    obj.nominalQuat_wxyz = revgnss.AttitudeErrorStateKinematics.propagateQuatBodyRate( ...
                        obj.nominalQuat_wxyz, omg, dt_s);
                    eul_new = zeros(3, 1);   % error state kept at zero in prediction
                else
                    edot    = revgnss.AttitudeKinematics.eulerRatesFromBodyRates(eul, omg);
                    eul_new = revgnss.AttitudeKinematics.wrapEuler(eul + dt_s * edot);
                end
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

            % Secondary-asset clocks (WP3): bias integrates drift; drift is random walk.
            if obj.estimateSecondaryClocks
                for si = 1:obj.nSecondaryClocks
                    ib = sm.secondaryClockIdx(si,1);
                    id = sm.secondaryClockIdx(si,2);
                    x_new(ib) = x(ib) + dt_s * x(id);
                    x_new(id) = x(id);
                end
            end
            obj.x = x_new;

            % State transition Jacobian F (pass Phi6 override for r/v block)
            F = obj.buildF_(dt_s, eul, omg, Phi6);

            % Process noise Q
            Q = obj.buildQ_(dt_s, towerClockModels, secondaryClockModels);

            % Propagate covariance
            obj.P = F * obj.P * F' + Q;
            obj.P = (obj.P + obj.P') / 2;
        end

        % ----------------------------------------------------------------
        function [K, nu, S, NIS] = update(obj, z, h, H, R)
            % update  EKF measurement update (Joseph stabilised form).
            %
            % S, K, and Joseph posterior covariance are computed from
            % the pre-update covariance Pminus.  The quaternion error-state reset
            % Jacobian is then applied to the POSTERIOR covariance, not the prior.
            %
            % NIS = nu' * (S \ nu)   — uses MATLAB backslash for numerical safety.
            % Kalman gain K = (Pminus * H') / S  (right division).

            if isempty(z)
                K = []; nu = []; S = []; NIS = NaN;
                return
            end

            % 1. Save pre-update covariance (all innovation/Joseph ops use Pminus)
            Pminus = obj.P;

            % 2. Innovation
            nu = z - h;

            % 3. Innovation covariance and Kalman gain (from Pminus)
            S = H * Pminus * H' + R;
            S = (S + S') / 2;

            % Kalman gain: right-division avoids explicit matrix inverse
            K = Pminus * H' / S;

            % 4. State update (local variable — assigned to obj.x after Joseph)
            xUpdated = obj.x + K * nu;

            % 5. Joseph stabilised posterior covariance (uses Pminus)
            nx  = obj.nx;
            IKH = eye(nx) - K * H;
            Pplus = IKH * Pminus * IKH' + K * R * K';
            Pplus = (Pplus + Pplus') / 2;

            % 6. Assign updated state and posterior covariance
            obj.x = xUpdated;
            obj.P = Pplus;

            % 7. Quaternion error-state injection + covariance reset
            %    Applied to posterior Pplus, NOT to prior Pminus
            if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                deltaTheta = obj.x(obj.stateMap.euler_idx);
                [obj.nominalQuat_wxyz, injInfo] = revgnss.AttitudeErrorStateKinematics.injectRight( ...
                    obj.nominalQuat_wxyz, deltaTheta);
                obj.x(obj.stateMap.euler_idx) = zeros(3, 1);
                % First-order covariance reset applied to posterior
                d  = deltaTheta(:);
                sk = [0,-d(3),d(2); d(3),0,-d(1); -d(2),d(1),0];
                G  = eye(3) - 0.5 * sk;
                ei = obj.stateMap.euler_idx;
                obj.P(ei, :) = G * obj.P(ei, :);
                obj.P(:, ei) = obj.P(:, ei) * G';
                obj.P = (obj.P + obj.P') / 2;
                % Injection diagnostics (reset order, guard, Jacobian condition)
                injNorm = injInfo.injectionNorm_rad;
                obj.attitudeInjectionCount       = obj.attitudeInjectionCount + 1;
                obj.maxAttitudeInjectionNorm_rad = max(obj.maxAttitudeInjectionNorm_rad, injNorm);
                maxGuard = deg2rad(10);
                try; maxGuard = obj.cfg.estimator.attitude.maxErrorStateInjection_rad; catch; end
                if injNorm > maxGuard
                    warning('ReverseGNSSEKF:update', ...
                        'Injection norm %.2e rad (%.2f deg) exceeds guard %.2e rad.', ...
                        injNorm, rad2deg(injNorm), maxGuard);
                end
                Gcond = cond(G);
                obj.lastAttitudeErrorStateInfo = struct( ...
                    'parameterization',      'quaternionErrorState', ...
                    'qNorm',                 injInfo.qNormPost, ...
                    'lastInjectionNorm_rad', injNorm, ...
                    'maxInjectionNorm_rad',  obj.maxAttitudeInjectionNorm_rad, ...
                    'injectionCount',        obj.attitudeInjectionCount, ...
                    'covarianceResetApplied',  true, ...
                    'covarianceResetOrder',    'posterior-after-joseph', ...
                    'covarianceResetJacobianCondition', Gcond, ...
                    'eulerReportingOnly',      true);
            else
                % Legacy Euler mode: wrap Euler after state update
                obj.x(obj.stateMap.euler_idx) = revgnss.AttitudeKinematics.wrapEuler( ...
                    obj.x(obj.stateMap.euler_idx));
            end

            % 8. Numerical sanity / PSD guard (after attitude reset if any)
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
                obj.P = (obj.P + obj.P') / 2;
            elseif minEig < 0
                % Tiny negative eigenvalue from floating-point: nudge diagonal
                obj.P = (obj.P + obj.P') / 2;
                obj.P = obj.P + eye(obj.nx) * (tol - minEig);
            end

            % 9. NIS: nu' * S^{-1} * nu  via backslash
            NIS = nu' * (S \ nu);
        end

        % ----------------------------------------------------------------
        function nees = computeNEES(obj, truth)
            % computeNEES  Normalised estimation error squared vs truth (consistency).
            %
            % NEES = (x_hat - x_true)' * (P \ (x_hat - x_true)) over the estimated core
            % states, per Bar-Shalom, Li & Kirubarajan 2001 ("Estimation with
            % Applications to Tracking and Navigation"), §5.4. For a consistent filter
            % E[NEES] = dof, so the returned per-block and .core values (divided by
            % their dof) have expectation 1.
            %
            % The attitude error is the SMALL-ANGLE error between the nominal attitude
            % and truth in P's attitude-block space (quaternion-aware via the error DCM),
            % NOT a raw Euler subtraction — the latter lives in a different space and is
            % ill-defined near gimbal lock. Backslash on P-submatrices (no explicit inv).
            %
            % truth: struct with optional fields (only estimated blocks are scored):
            %   .r_ecef_m [3x1], .v_ecef_mps [3x1], .clockBias_m, .clockDrift_mps,
            %   .euler_rad [3x1]
            % Returns struct: .pos .vel .clock .attitude (per-block NEES/dof, NaN if not
            %   scored), .core (joint NEES/dof over all scored states), .coreRaw (joint,
            %   un-normalised), .coreDof.
            sm   = obj.stateMap;
            nees = struct('pos',NaN,'vel',NaN,'clock',NaN,'attitude',NaN, ...
                          'core',NaN,'coreRaw',NaN,'coreDof',0);
            idx = []; err = [];

            if isfield(truth,'r_ecef_m') && ~isempty(truth.r_ecef_m)
                e = obj.x(sm.r_idx) - truth.r_ecef_m(:);
                nees.pos = neesBlock_(obj.P, sm.r_idx, e);
                idx = [idx; sm.r_idx(:)]; err = [err; e];
            end
            if isfield(truth,'v_ecef_mps') && ~isempty(truth.v_ecef_mps)
                e = obj.x(sm.v_idx) - truth.v_ecef_mps(:);
                nees.vel = neesBlock_(obj.P, sm.v_idx, e);
                idx = [idx; sm.v_idx(:)]; err = [err; e];
            end
            if isfield(truth,'clockBias_m')
                cIdx = sm.b_rx_idx; e = obj.x(sm.b_rx_idx) - truth.clockBias_m;
                if isfield(truth,'clockDrift_mps')
                    cIdx = [sm.b_rx_idx; sm.bdot_rx_idx];
                    e    = [e; obj.x(sm.bdot_rx_idx) - truth.clockDrift_mps];
                end
                nees.clock = neesBlock_(obj.P, cIdx, e);
                idx = [idx; cIdx(:)]; err = [err; e];
            end
            if obj.estimateAttitude && isfield(truth,'euler_rad') && ~isempty(truth.euler_rad)
                aErr = obj.attitudeSmallAngleError_(truth.euler_rad(:));
                nees.attitude = neesBlock_(obj.P, sm.euler_idx, aErr);
                idx = [idx; sm.euler_idx(:)]; err = [err; aErr];
            end

            % Joint (core) NEES uses the full submatrix incl. cross-covariances.
            if ~isempty(idx)
                Pblk = obj.P(idx, idx); Pblk = (Pblk + Pblk') / 2;
                if rcond(Pblk) > 1e-15
                    nees.coreRaw = err' * (Pblk \ err);
                    nees.coreDof = numel(idx);
                    nees.core    = nees.coreRaw / nees.coreDof;
                end
            end
        end

        % ----------------------------------------------------------------
        function aErr = attitudeSmallAngleError_(obj, truthEuler_rad)
            % attitudeSmallAngleError_  Small-angle attitude error in P(euler_idx)
            % space. Quaternion mode uses the error DCM between nominal and truth;
            % Euler mode uses the wrap-aware reported-minus-truth Euler difference.
            if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                C_nom = revgnss.AttitudeErrorStateKinematics.quatToDcm(obj.nominalQuat_wxyz);
                C_tru = revgnss.AttitudeKinematics.bodyToEcefRotation(truthEuler_rad);
                dC    = C_nom' * C_tru;   % small rotation body(nominal)->body(truth)
                aErr  = 0.5 * [dC(3,2)-dC(2,3); dC(1,3)-dC(3,1); dC(2,1)-dC(1,2)];
            else
                aErr = revgnss.AttitudeKinematics.wrapEuler( ...
                    obj.getReportEulerRad() - truthEuler_rad);
            end
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

            % Optional float ambiguity states.
            % floatPerTowerSignal:           ambiguityIdx(ti, si)     [nT × nSig]
            % floatPerTowerReceiverSignal:   ambiguityIdx(ti, si)=0   (legacy zeros)
            %                                ambiguityIdx3d(ti, ri, si) [nT × nRx × nSig]
            if obj.estimateAmbiguities && obj.nAmbiguities > 0
                nSig = obj.ambiguityNSignals;
                nRx  = obj.ambiguityNReceivers;
                if strcmp(obj.ambiguityMode, 'floatPerTowerReceiverSignal')
                    % 3D indexing: one state per tower/receiver/signal
                    ambIdx3d = zeros(nTowers, nRx, nSig);
                    for ti = 1:nTowers
                        for ri = 1:nRx
                            for si = 1:nSig
                                ambIdx3d(ti, ri, si) = nextIdx;
                                nextIdx = nextIdx + 1;
                            end
                        end
                    end
                    sm.ambiguityIdx   = zeros(nTowers, nSig);  % empty legacy slot
                    sm.ambiguityIdx3d = ambIdx3d;
                else
                    % Legacy 2D indexing: one state per tower/signal
                    ambIdx = zeros(nTowers, nSig);
                    for ti = 1:nTowers
                        for si = 1:nSig
                            ambIdx(ti, si) = nextIdx;
                            nextIdx = nextIdx + 1;
                        end
                    end
                    sm.ambiguityIdx = ambIdx;
                end
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

            % Optional per-tower slant-ionosphere states (prototype)
            % I_L1_i [m]: the L1 slant ionospheric delay at tower i.
            if obj.estimateIono && obj.nIonoStates > 0
                ionoIdx = zeros(nTowers, 1);
                for ti = 1:nTowers
                    ionoIdx(ti) = nextIdx;
                    nextIdx     = nextIdx + 1;
                end
                sm.ionoIdx = ionoIdx;
            else
                sm.ionoIdx = zeros(nTowers, 1);
            end

            % Optional per-tower transmitter code bias states
            % d_tx_code_i [m]: random-walk bias, one per tower, L1 code only.
            % Positive d_tx_code increases measured pseudorange.
            if obj.estimateTxCodeBias && obj.nTxCodeBiasStates > 0
                txIdx = zeros(nTowers, 1);
                for ti = 1:nTowers
                    txIdx(ti) = nextIdx;
                    nextIdx   = nextIdx + 1;
                end
                sm.txCodeBiasIdx = txIdx;
            else
                sm.txCodeBiasIdx = zeros(nTowers, 1);
            end

            % Optional gyro-bias states (IMU/MEKF). Appended so no existing index shifts;
            % empty when off -> state map identical to the pre-IMU map (golden-safe).
            if obj.estimateGyroBias
                sm.gyroBiasIdx = (nextIdx:nextIdx+2)';
                nextIdx = nextIdx + 3;
            else
                sm.gyroBiasIdx = [];
            end

            % WP3 secondary-asset clock states (appended strictly LAST). Row si (1..N-1)
            % maps to asset ai=si+1 and holds [b_tx_idx, bdot_tx_idx]. Empty sentinel
            % zeros(0,2) when off -> byte-identical map (mirrors towerClockIdx pattern).
            if obj.estimateSecondaryClocks && obj.nSecondaryClocks > 0
                secIdx = zeros(obj.nSecondaryClocks, 2);
                for si = 1:obj.nSecondaryClocks
                    secIdx(si,:) = [nextIdx, nextIdx+1];
                    nextIdx = nextIdx + 2;
                end
                sm.secondaryClockIdx = secIdx;
            else
                sm.secondaryClockIdx = zeros(0, 2);
            end
        end

        % ----------------------------------------------------------------
        function F = buildF_(obj, dt_s, euler, omega, Phi6)
            % buildF_  Linearised state-transition Jacobian.
            %
            % Euler-euler block: FD derivative of (eul + dt * T(eul,omg)*omg) w.r.t. eul.
            % Euler-omega block: dt * T(euler)  [kinematic transformation].
            % Phi6 (optional): 6x6 translational STM replacing default [I dtI;0 I] block.

            if nargin < 5; Phi6 = []; end

            nx = obj.nx;
            F  = eye(nx);
            sm = obj.stateMap;

            % Position-velocity block: use Phi6 from EkfDynamicsPredictor or default
            rv_idx = [sm.r_idx; sm.v_idx];
            if ~isempty(Phi6) && isequal(size(Phi6), [6,6]) && all(isfinite(Phi6(:)))
                F(rv_idx, rv_idx) = Phi6;
            else
                % Default constant-velocity coupling (backward compatible)
                F(sm.r_idx, sm.v_idx) = dt_s * eye(3);
            end

            if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                % Error-state F blocks — linearized around nominal.
                % d(delta_theta)/dt = -skew(omega)*delta_theta + delta_omega
                % F(theta,theta) ≈ I - skew(omega)*dt
                % F(theta,omega) ≈ I*dt
                if obj.estimateAttitude
                    omg = omega(:);
                    sk3 = [0,-omg(3),omg(2); omg(3),0,-omg(1); -omg(2),omg(1),0];
                    F(sm.euler_idx, sm.euler_idx) = eye(3) - sk3 * dt_s;
                    F(sm.euler_idx, sm.omega_idx) = eye(3) * dt_s;
                    if obj.estimateGyroBias && ~isempty(sm.gyroBiasIdx)
                        % Strapdown: omega = omega_gyro - b_g, so d(dtheta)/d(b_g) = -d(dtheta)/d(omega).
                        % The receiver attitude update then observes and corrects b_g through this block.
                        F(sm.euler_idx, sm.gyroBiasIdx) = -eye(3) * dt_s;
                        F(sm.euler_idx, sm.omega_idx)   = zeros(3);   % omega state no longer drives attitude
                        % F(gyroBias,gyroBias)=I already (random walk, from F=eye(nx)).
                    end
                else
                    F(sm.euler_idx, sm.euler_idx) = eye(3);
                    F(sm.euler_idx, sm.omega_idx) = zeros(3);
                end
            else
                % Euler-euler block: analytic Jacobian of eul + dt*T(eul)*omg w.r.t. eul
                % Replaces the fdStep=1e-7 central difference with the closed-form
                % derivative F(eul,eul) = I + dt*J, removing FD round-off. Guarded near
                % gimbal lock inside eulerRateJacobian; the singularity-free path is the
                % quaternion error-state parameterisation.
                Jeul = revgnss.AttitudeKinematics.eulerRateJacobian(euler, omega);
                F(sm.euler_idx, sm.euler_idx) = eye(3) + dt_s * Jeul;

                % Euler-omega block: dt * T(euler)
                cr = cos(euler(1)); sr = sin(euler(1));
                cp = cos(euler(2)); tp = tan(euler(2));
                if abs(cp) < 1e-6; cp = sign(cp + eps) * 1e-6; end

                T = [1, sr*tp, cr*tp; 0, cr, -sr; 0, sr/cp, cr/cp];
                F(sm.euler_idx, sm.omega_idx) = dt_s * T;

                % Freeze attitude kinematics when estimation is disabled.
                if ~obj.estimateAttitude
                    F(sm.euler_idx, sm.euler_idx) = eye(3);
                    F(sm.euler_idx, sm.omega_idx) = zeros(3);
                end
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

            % Secondary-asset clock bias<-drift coupling (WP3; tower/rx precedent)
            if obj.estimateSecondaryClocks
                for si = 1:obj.nSecondaryClocks
                    F(sm.secondaryClockIdx(si,1), sm.secondaryClockIdx(si,2)) = dt_s;
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

            % Slant-iono states: first-order Gauss-Markov phi = exp(-dt/tau)
            if obj.estimateIono
                tau_iono = 900;
                if isfield(obj.cfg,'estimation') && isfield(obj.cfg.estimation,'slantIono') && ...
                        isfield(obj.cfg.estimation.slantIono,'tau_s')
                    tau_iono = obj.cfg.estimation.slantIono.tau_s;
                end
                phi_iono = exp(-dt_s / tau_iono);
                for ti = 1:obj.nTowers
                    idx = sm.ionoIdx(ti);
                    if idx > 0
                        F(idx, idx) = phi_iono;
                    end
                end
            end
        end

        % ----------------------------------------------------------------
        function Q = buildQ_(obj, dt_s, towerClockModels, secondaryClockModels)
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
            % Inflate the process-noise sigma by the unmodeled-dynamics term (e.g. the J2
            % acceleration when truth is j2Rk4 but the EKF propagates two-body). This is
            % LOAD-BEARING EKF tuning, not "mismatch analysis" - see finalizeConfig (2.2).
            sa  = obj.sigma_accel_mps2;
            try
                if obj.cfg.estimator.processNoise.modelMismatch.enable
                    sm_ = obj.cfg.estimator.processNoise.modelMismatch.sigma_mps2;
                    if isnumeric(sm_) && isscalar(sm_) && sm_ > 0
                        sa = sqrt(sa^2 + sm_^2);
                    end
                end
            catch; end
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

            % --- IMU/MEKF process noise: attitude Q from the gyro ARW (REPLACES the angular-accel
            %     term above), gyro-bias Q from the RRW. Gated -> off = pre-IMU Q (golden-safe).
            if obj.estimateGyroBias && ~isempty(sm.gyroBiasIdx)
                gb    = sm.gyroBiasIdx;
                q_arw = obj.imuArw_^2 * dt_s;
                q_rrw = obj.imuRrw_^2 * dt_s;
                for k = 1:3
                    Q(sm.euler_idx(k), sm.euler_idx(k)) = q_arw;   % gyro ARW replaces angular-accel
                    Q(sm.euler_idx(k), sm.omega_idx(k)) = 0;       % drop euler<->omega cross on IMU path
                    Q(sm.omega_idx(k), sm.euler_idx(k)) = 0;
                    Q(gb(k), gb(k))                     = q_rrw;   % bias rate random walk
                end
                if obj.imuVanLoan_
                    for k = 1:3
                        Q(sm.euler_idx(k), gb(k)) = -0.5 * q_rrw * dt_s;
                        Q(gb(k), sm.euler_idx(k)) = -0.5 * q_rrw * dt_s;
                    end
                end
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

            % --- Secondary-asset clock process noise (WP3, if estimated) ---
            % nargin>=4 short-circuit keeps 3-arg callers (e.g. buildQ_(dt,{})) byte-identical.
            if obj.estimateSecondaryClocks && nargin >= 4 && ~isempty(secondaryClockModels)
                for si = 1:min(obj.nSecondaryClocks, numel(secondaryClockModels))
                    ib = sm.secondaryClockIdx(si,1);
                    id = sm.secondaryClockIdx(si,2);
                    if ~isempty(secondaryClockModels{si})
                        Qsec = secondaryClockModels{si}.getProcessNoiseQ(dt_s, 'meters');
                    else
                        Qsec = diag([1e-4, 1e-8]) * dt_s;
                    end
                    Q(ib,ib) = Qsec(1,1); Q(ib,id) = Qsec(1,2);
                    Q(id,ib) = Qsec(2,1); Q(id,id) = Qsec(2,2);
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
                nRx   = obj.ambiguityNReceivers;
                if strcmp(obj.ambiguityMode,'floatPerTowerReceiverSignal') && ...
                        isfield(sm,'ambiguityIdx3d')
                    for ti = 1:obj.nTowers
                        for ri = 1:nRx
                            for si = 1:nSig
                                idx = sm.ambiguityIdx3d(ti, ri, si);
                                if idx > 0; Q(idx, idx) = q_amb; end
                            end
                        end
                    end
                else
                    for ti = 1:obj.nTowers
                        for si = 1:nSig
                            idx = sm.ambiguityIdx(ti, si);
                            if idx > 0; Q(idx, idx) = q_amb; end
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

            % --- Slant-iono process noise (Gauss-Markov steady-state) ------
            if obj.estimateIono
                tau_iono  = 900;
                sigma_iono = 1.0;   % steady-state slant-iono sigma [m]
                if isfield(obj.cfg,'estimation') && isfield(obj.cfg.estimation,'slantIono')
                    si_ = obj.cfg.estimation.slantIono;
                    if isfield(si_,'tau_s');      tau_iono   = si_.tau_s;      end
                    if isfield(si_,'sigma_ss_m'); sigma_iono = si_.sigma_ss_m; end
                end
                phi_iono = exp(-dt_s / tau_iono);
                q_iono   = sigma_iono^2 * (1 - phi_iono^2);
                for ti = 1:obj.nTowers
                    idx = sm.ionoIdx(ti);
                    if idx > 0
                        Q(idx, idx) = q_iono;
                    end
                end
            end

            % --- Tx code bias process noise (random walk) --------
            % d_tx_code(k+1) = d_tx_code(k) + w,  Q = sigma^2 * dt
            if obj.estimateTxCodeBias
                sigTx = 1e-5;
                if isfield(obj.cfg,'hardware') && isfield(obj.cfg.hardware,'txCodeBias') && ...
                        isfield(obj.cfg.hardware.txCodeBias,'processSigma_m_per_sqrt_s')
                    sigTx = obj.cfg.hardware.txCodeBias.processSigma_m_per_sqrt_s;
                end
                q_tx = sigTx^2 * dt_s;
                for ti = 1:obj.nTowers
                    idx = sm.txCodeBiasIdx(ti);
                    if idx > 0
                        Q(idx, idx) = q_tx;
                    end
                end
            end

            % Enforce symmetry
            Q = (Q + Q') / 2;
        end

        % ----------------------------------------------------------------
        function resetAmbiguityCovariance(obj, towerIdx, sigIdx, resetSigma_m, receiverIdx)
            % resetAmbiguityCovariance  Reset ambiguity covariance after cycle slip.
            %
            % Sets P(amb,:)=0, P(:,amb)=0, P(amb,amb)=resetSigma_m^2.
            % State value is left unchanged; inflated covariance lets the filter move.
            %
            % receiverIdx (optional, arg 5): required for floatPerTowerReceiverSignal.
            %   Omit or pass [] to use receiver 1 (backward compatible).
            if ~obj.estimateAmbiguities; return; end
            sm = obj.stateMap;
            if towerIdx < 1 || towerIdx > obj.nTowers; return; end
            if sigIdx < 1   || sigIdx > obj.ambiguityNSignals; return; end

            if nargin < 4 || isempty(resetSigma_m)
                resetSigma_m = 100;
                if isfield(obj.cfg,'estimation') && isfield(obj.cfg.estimation,'ambiguity') && ...
                        isfield(obj.cfg.estimation.ambiguity,'initialSigma_m')
                    resetSigma_m = obj.cfg.estimation.ambiguity.initialSigma_m;
                end
            end

            if nargin < 5 || isempty(receiverIdx); receiverIdx = 1; end

            % Resolve state index based on mode
            idx = 0;
            if strcmp(obj.ambiguityMode,'floatPerTowerReceiverSignal') && ...
                    isfield(sm,'ambiguityIdx3d') && ~isempty(sm.ambiguityIdx3d)
                if receiverIdx >= 1 && receiverIdx <= size(sm.ambiguityIdx3d,2)
                    idx = sm.ambiguityIdx3d(towerIdx, receiverIdx, sigIdx);
                end
            else
                idx = sm.ambiguityIdx(towerIdx, sigIdx);
            end
            if idx <= 0 || idx > obj.nx; return; end

            obj.P(idx, :) = 0;
            obj.P(:, idx) = 0;
            obj.P(idx, idx) = resetSigma_m^2;
        end

        % ----------------------------------------------------------------
        function info = applyAmbiguityPseudoMeasurement(obj, ambIdx, fixedValue_m, sigma_m)
            % applyAmbiguityPseudoMeasurement  Constrain one ambiguity state.
            %
            % Builds a scalar pseudo-measurement z=fixedValue_m, h=x(ambIdx), H=[0..1..0],
            % R=sigma_m^2 and calls update().  Preserves Joseph/posterior order.
            info.applied = false; info.idx = ambIdx;
            info.fixedValue_m = fixedValue_m; info.sigma_m = sigma_m;
            info.postSigma_m = NaN; info.NIS = NaN; info.warning = '';
            if ambIdx < 1 || ambIdx > obj.nx
                info.warning = sprintf('ambIdx %d out of range [1,%d]', ambIdx, obj.nx); return
            end
            H_fix = zeros(1, obj.nx); H_fix(ambIdx) = 1;
            [~, ~, ~, nis] = obj.update(fixedValue_m, obj.x(ambIdx), H_fix, sigma_m^2);
            info.applied     = true;
            info.postSigma_m = sqrt(max(0, obj.P(ambIdx, ambIdx)));
            info.NIS         = nis;
        end

        % ----------------------------------------------------------------
        function applyAmbiguityResets(obj, resetRequests, resetSigma_m)
            % applyAmbiguityResets  Batch-reset covariance for slipped tracks.
            %
            % resetRequests: struct array with fields towerIdx, signalIdx,
            %   and optionally receiverIdx (required for floatPerTowerReceiverSignal).
            if nargin < 3; resetSigma_m = []; end
            for ri = 1:numel(resetRequests)
                rIdx = 1;
                if isfield(resetRequests(ri),'receiverIdx')
                    rIdx = resetRequests(ri).receiverIdx;
                end
                obj.resetAmbiguityCovariance( ...
                    resetRequests(ri).towerIdx, resetRequests(ri).signalIdx, ...
                    resetSigma_m, rIdx);
            end
        end

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
        function [z_out, h_out, H_out, R_out, txGaugeInfo] = appendTxDelayGaugeRows(obj, z, h, H, R)
            % appendTxDelayGaugeRows  Augment measurement stack with tx code delay gauge rows.
            %
            % A common shift in all tower transmitter code delays is not separable
            % from the receiver clock bias without a datum constraint.  This method
            % adds EKF pseudo-measurement rows that pin the delay datum, analogous
            % to appendClockGaugeRows for clock states.
            %
            % Gauge modes (cfg.hardware.txCodeBias.gaugeMode):
            %   'fixReferenceTower'     — d_tx_code(refTower) = 0
            %       H(refIdx) = 1,  R = gaugeSigma_m^2
            %   'meanGroundDelayGauge'  — mean(d_tx_code_i) = 0
            %       H(all txIdx) = 1/N, R = gaugeSigma_m^2
            %
            % Gauge rows are NOT counted as physical pseudorange measurements.
            % txGaugeInfo.H_gauge / R_gauge_diag are stored for Gramian use.

            z_out = z; h_out = h; H_out = H; R_out = R;
            txGaugeInfo.rowsAdded       = 0;
            txGaugeInfo.gaugeResidual_m = NaN;
            txGaugeInfo.gaugeSigma_m    = NaN;
            txGaugeInfo.H_gauge         = zeros(0, size(H,2));
            txGaugeInfo.R_gauge_diag    = zeros(0, 1);
            txGaugeInfo.txDelaySubspaceRank    = NaN;
            txGaugeInfo.txDelaySubspaceCondNum = NaN;

            if ~obj.estimateTxCodeBias || obj.nTxCodeBiasStates < 1
                return;
            end

            sm  = obj.stateMap;
            nx  = obj.nx;
            cfg = obj.cfg;

            gaugeSigma  = 1e-6;
            gaugeMode   = 'fixReferenceTower';
            refTwrIdx   = 1;
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'txCodeBias')
                tc = cfg.hardware.txCodeBias;
                if isfield(tc,'gaugeSigma_m');         gaugeSigma = tc.gaugeSigma_m;         end
                if isfield(tc,'gaugeMode');             gaugeMode  = tc.gaugeMode;             end
                if isfield(tc,'referenceTowerIndex');   refTwrIdx  = tc.referenceTowerIndex;   end
            end
            txGaugeInfo.gaugeSigma_m = gaugeSigma;

            txIdx = sm.txCodeBiasIdx;   % [nTowers × 1]

            switch gaugeMode
                case 'fixReferenceTower'
                    kref = max(1, min(refTwrIdx, obj.nTowers));
                    idx  = txIdx(kref);
                    if idx <= 0 || idx > nx; return; end

                    Hg = zeros(1, nx); Hg(idx) = 1;
                    res = 0 - obj.x(idx);
                    z_out = [z_out; 0];
                    h_out = [h_out; obj.x(idx)];
                    H_out = [H_out; Hg];
                    R_out = blkdiag(R_out, gaugeSigma^2);

                    txGaugeInfo.rowsAdded       = 1;
                    txGaugeInfo.gaugeResidual_m = res;
                    txGaugeInfo.H_gauge         = Hg;
                    txGaugeInfo.R_gauge_diag    = gaugeSigma^2;

                case 'meanGroundDelayGauge'
                    validIdx = txIdx(txIdx > 0 & txIdx <= nx);
                    N = numel(validIdx);
                    if N < 1; return; end

                    Hg = zeros(1, nx);
                    Hg(validIdx) = 1/N;
                    meanDelay = mean(obj.x(validIdx));
                    z_out = [z_out; 0];
                    h_out = [h_out; meanDelay];
                    H_out = [H_out; Hg];
                    R_out = blkdiag(R_out, gaugeSigma^2);

                    txGaugeInfo.rowsAdded       = 1;
                    txGaugeInfo.gaugeResidual_m = -meanDelay;
                    txGaugeInfo.H_gauge         = Hg;
                    txGaugeInfo.R_gauge_diag    = gaugeSigma^2;

                otherwise
                    return;
            end

            % Tx-delay subspace rank diagnostic
            validTxIdx = txIdx(txIdx > 0 & txIdx <= nx);
            if ~isempty(H_out) && ~isempty(validTxIdx) && size(H_out,2) >= max(validTxIdx)
                H_tx = H_out(:, validTxIdx);
                sv   = svd(H_tx, 'econ');
                sv   = sv(sv > 0);
                if ~isempty(sv)
                    tol = sv(1) * max(size(H_tx)) * eps;
                    txGaugeInfo.txDelaySubspaceRank    = sum(sv > tol);
                    txGaugeInfo.txDelaySubspaceCondNum = sv(1) / max(sv(end), eps);
                end
            end
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

function v = neesBlock_(P, idx, err)
    % neesBlock_  Per-block normalised NEES = err' * (P_block \ err) / dof.
    % Returns NaN when the covariance sub-block is numerically singular (e.g. a
    % frozen state), mirroring the rcond guard used in SimulationDataStore.
    Pb = P(idx, idx); Pb = (Pb + Pb') / 2;
    if rcond(Pb) > 1e-15
        v = (err(:)' * (Pb \ err(:))) / numel(idx);
    else
        v = NaN;
    end
end
