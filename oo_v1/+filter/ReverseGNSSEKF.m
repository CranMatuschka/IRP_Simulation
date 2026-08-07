classdef ReverseGNSSEKF < handle
    % ReverseGNSSEKF  Extended Kalman Filter for reverse-GNSS navigation.
    %
    % Base state vector (14 states):
    %   x(1:3)    r_cm_ecef_m          ECEF position [m]
    %   x(4:6)    v_ecef_mps           ECEF velocity [m/s]
    %   x(7:9)    euler_rad            Attitude [roll; pitch; yaw] ZYX [rad]
    %   x(10:12)  omega_B/E^B          Earth-relative body rate [rad/s];
    %                              a derived gyro-control slot when gyro aiding is active
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

        % ISL carrier float ambiguity states (one per inter-satellite link x signal).
        % This block is independent of the ground ambiguity block and precedes
        % any joint-secondary state blocks.
        estimateIslAmbiguities (1,1) logical = false
        nIslAmbiguities        (1,1) double  = 0
        islAmbiguityNSignals   (1,1) double  = 1
        islAmbiguityTxList     (1,:) double  = []   % active ISL transmitter asset indices
        islAmbiguityRxIdx      (1,1) double  = 1    % receiving (primary) asset index
        islAmbiguityRegistry                 = []   % revgnss.AmbiguityStateRegistry (key -> index)

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

        % Centralized multi-spacecraft state. Each secondary contributes
        % [r, v, attitude error/Euler, body rate, clock bias, clock drift].
        jointMultiAssetEnabled (1,1) logical = false
        nSpaceAssets           (1,1) double = 1
        nSecondaryAssets       (1,1) double = 0

        % Optional gyro-bias states (IMU/MEKF attitude aiding). 3 states appended ONLY when
        % estimateGyroBias -> nx/state-map unchanged when off (golden-safe). On this path the
        % attitude is propagated with omega = omega_gyro - b_g (strapdown control input) and the
        % attitude process noise comes from the gyro ARW instead of the angular-accel model.
        estimateGyroBias      (1,1) logical = false
        imuArw_               (1,1) double  = 1e-4    % filter angle random walk [rad/sqrt(s)]
        imuRrw_               (1,1) double  = 1e-6    % filter bias rate random walk [rad/(s*sqrt(s))]
        imuP0Bias_            (1,1) double  = 1e-5    % initial bias 1-sigma (init done in ScenarioFactory)

        % SRP scale-coefficient state (primary only, single scalar): a dimensionless
        % multiplier s on the reference SRP acceleration (Cr=s*refCr), observed via
        % trajectory bending. Appended LAST => nx/state-map identical to today when off
        % (golden-safe). Gated by cfg.estimator.srpCoefficient.{enable,useInEKF}.
        estimateSrpScale     (1,1) logical = false
        srpScaleProcNoise_   (1,1) double  = 1e-9   % random-walk 1-sigma [1/sqrt(s)]

        % Empirical RTN accelerations (reduced-dynamic filtering)
        estimateEmpiricalAccel (1,1) logical = false
        empAccTau_             (1,1) double  = 1800    % GM correlation time [s]
        empAccSigmaSs_         (1,1) double  = 1e-7    % steady-state 1-sigma [m/s^2]
        % NORMALISATION. The states are carried in units of empAccSigmaSs_, so the
        % scaled steady-state sigma is exactly 1 and the physical acceleration is
        % empAccScale_ * x(empAccIdx). This is NOT cosmetic: the PSD guard in update()
        % nudges EVERY diagonal by 1e-12*max(diag(P)), and with 100 m carrier-ambiguity
        % priors (P ~ 1e4) that floor is ~7e-9. Against a physical variance of
        % (1e-7)^2 = 1e-14 the guard would set the prior 855x too wide and the states
        % would absorb noise instead of the systematic error they exist to model.
        % Measured on scene_G5S1R4_ts3600_TW1_empacc before this normalisation:
        % P(empAcc) at epoch 1 was 7.3064e-09 against a guard floor of 7.3063e-09.
        empAccScale_           (1,1) double  = 1e-7    % [m/s^2] per unit state

        % Persistent effective calibration residual for the active coherent
        % two-way code links.
        estimateTwoWayCodeCalibrationBias (1,1) logical = false
        nTwoWayCodeCalibrationBiasStates (1,1) double = 0
        twoWayCodeCalibrationBiasLinkIdentifiers cell = {}
        twoWayCodeCalibrationBiasProcessNoise_ (1,1) double = 0

        % Clock model (for process noise)
        rxClockModel     models.clocks.ClockModel

        % Diagnostics
        history          (1,1) struct

        % Last dynamics predict info (compact, overwritten each epoch)
        lastDynamicsPredictInfo (1,1) struct

        % Last state-transition Jacobian (overwritten each predict; diagnostics only, never
        % read back by the filter). Lets tests check an STM column against a finite
        % difference of the real propagation instead of re-deriving the formula.
        lastF double = []

        % Epoch error-transition retention (plan Stage 3.1 items 4-5). Default false: when
        % false NOTHING below executes and no arithmetic changes (golden-safe by construction).
        % Consumed by revgnss.DistributedCovarianceNetwork through
        % revgnss.OwnerLocalEkfTransitionCaptureProvider. Nothing here is ever read back into
        % the filter: obj.x, obj.P, F, and Q are never modified by any retention code.
        retainEpochTransitionOperators  (1,1) logical = false
        pendingEpochTransition_         (1,1) struct  = filter.ReverseGNSSEKF.emptyEpochTransition()
        epochTransitionCaptureOpen_     (1,1) logical = false
        covarianceAtLastAccountedWrite_ (:,:) double  = []
        epochTransitionSequence_        (1,1) double  = 0

        % Section 3.3: this leaf's own declared common-process-noise group membership, if any.
        % Empty (default) => the block below in buildQ_ is skipped entirely (not merely added as
        % zero) -- golden-safe by construction. When non-empty, buildQ_ calls this group value's
        % own ownDiagonalContribution instance method -- the identical code path revgnss.
        % DistributedCovarianceNetwork.advanceEpoch calls for the cross block -- so the leaf
        % diagonal and the network cross block can never drift apart; there is no parallel
        % formula to keep in sync.
        declaredCommonProcessNoiseGroup_ (1,:) revgnss.CommonProcessNoiseCovarianceGroup = ...
            revgnss.CommonProcessNoiseCovarianceGroup.empty

        % Quaternion nominal / error-state attitude EKF
        nominalQuat_wxyz          double = [1;0;0;0]   % 4 x nSpaceAssets, scalar first
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
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets')
                obj.nSpaceAssets = max(1, round(cfg.scenario.nSpaceAssets));
            end
            multiAssetMode = 'fast';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'mode') && ...
                    (ischar(cfg.multiAsset.mode) || isstring(cfg.multiAsset.mode))
                multiAssetMode = char(cfg.multiAsset.mode);
            end
            obj.jointMultiAssetEnabled = strcmpi(multiAssetMode, 'joint') && ...
                obj.nSpaceAssets > 1;
            if obj.jointMultiAssetEnabled
                obj.nSecondaryAssets = obj.nSpaceAssets - 1;
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
                catch; end
            end

            % SRP scale-coefficient gate (primary). enable && useInEKF, both default off.
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'srpCoefficient')
                sc = cfg.estimator.srpCoefficient;
                en = isfield(sc,'enable')   && logical(sc.enable);
                uk = isfield(sc,'useInEKF') && logical(sc.useInEKF);
                obj.estimateSrpScale = en && uk;
                if isfield(sc,'procNoise') && isscalar(sc.procNoise); obj.srpScaleProcNoise_ = sc.procNoise; end
            end

            % Empirical RTN acceleration gate (enable && useInEKF, both default off).
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'empiricalAccel')
                ea = cfg.estimator.empiricalAccel;
                enEa = isfield(ea,'enable')   && logical(ea.enable);
                ukEa = isfield(ea,'useInEKF') && logical(ea.useInEKF);
                obj.estimateEmpiricalAccel = enEa && ukEa;
                if isfield(ea,'tau_s') && isscalar(ea.tau_s) && ea.tau_s > 0
                    obj.empAccTau_ = ea.tau_s;
                end
                if isfield(ea,'sigma_ss_mps2') && isscalar(ea.sigma_ss_mps2)
                    obj.empAccSigmaSs_ = ea.sigma_ss_mps2;
                end
                % Normalise the state to its own steady-state sigma (see empAccScale_).
                if obj.empAccSigmaSs_ > 0 && isfinite(obj.empAccSigmaSs_)
                    obj.empAccScale_ = obj.empAccSigmaSs_;
                end
            end

            % ISL carrier-ambiguity gate. Sized from ISLMeasurementBuilder so the state
            % block and the measurement rows agree on WHICH links exist (one source of
            % truth). Independent of the ground ambiguity switches.
            obj.nIslAmbiguities = revgnss.ISLMeasurementBuilder.ambiguityStateCount(cfg);
            if obj.nIslAmbiguities > 0
                obj.estimateIslAmbiguities = true;
                obj.islAmbiguityTxList   = revgnss.ISLMeasurementBuilder.transmitterList(cfg);
                obj.islAmbiguityNSignals = revgnss.ISLMeasurementBuilder.islAmbiguityNSignals(cfg);
                obj.islAmbiguityRxIdx    = 1;
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'isl') && ...
                        isfield(cfg.measurements.isl,'receiverAssetIndex')
                    obj.islAmbiguityRxIdx = cfg.measurements.isl.receiverAssetIndex;
                end
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
            if obj.estimateIono
                obj.nx = obj.nx + obj.nIonoStates;
            end
            if obj.estimateTxCodeBias
                obj.nx = obj.nx + obj.nTxCodeBiasStates;
            end
            if obj.estimateGyroBias
                obj.nx = obj.nx + 3;
            end
            if obj.estimateSrpScale
                obj.nx = obj.nx + 1;   % single scalar
            end
            if obj.estimateEmpiricalAccel
                obj.nx = obj.nx + 3;   % RTN empirical acceleration
            end
            if obj.estimateIslAmbiguities
                obj.nx = obj.nx + obj.nIslAmbiguities;   % ISL block, appended strictly LAST
            end
            if obj.jointMultiAssetEnabled
                secondaryWidth = 14 + 3 * double(obj.estimateGyroBias);
                obj.nx = obj.nx + obj.nSecondaryAssets * secondaryWidth;
            end
            try
                biasState = cfg.measurements.isl.twoWay.calibration.residualBiasState;
                obj.estimateTwoWayCodeCalibrationBias = ...
                    logical(biasState.enable) && ...
                    logical(cfg.measurements.isl.twoWay.enable) && ...
                    logical(cfg.measurements.isl.twoWay.range.useInEKF);
                obj.twoWayCodeCalibrationBiasProcessNoise_ = ...
                    biasState.processNoiseSigma_m_per_sqrt_s;
            catch
            end
            if obj.estimateTwoWayCodeCalibrationBias
                obj.twoWayCodeCalibrationBiasLinkIdentifiers = ...
                    revgnss.TwoWayISLMeasurementBuilder. ...
                    calibrationLinkIdentifiers(cfg);
                obj.nTwoWayCodeCalibrationBiasStates = numel( ...
                    obj.twoWayCodeCalibrationBiasLinkIdentifiers);
                obj.nx = obj.nx + ...
                    obj.nTwoWayCodeCalibrationBiasStates;
            end
            % NOTE: this arithmetic is a SECOND implementation of the buildStateMap_
            % nextIdx walk. Any new block must be added in BOTH places, in the SAME
            % order; assertStateMapConsistency_ (called below) is the cross-check that
            % turns a silent mismatch into a hard error.

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
            if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                nAttitudeBlocks = 1;
                if isfield(obj.stateMap,'asset')
                    nAttitudeBlocks = numel(obj.stateMap.asset);
                end
                obj.nominalQuat_wxyz = repmat([1;0;0;0], 1, nAttitudeBlocks);
                for assetIdx = 1:nAttitudeBlocks
                    attitudeIdx = obj.stateMap.asset(assetIdx).euler;
                    if isempty(attitudeIdx); continue; end
                    obj.nominalQuat_wxyz(:,assetIdx) = ...
                        revgnss.AttitudeErrorStateKinematics.eulerToQuatZYX( ...
                        obj.x(attitudeIdx));
                    obj.x(attitudeIdx) = zeros(3,1);
                end
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
                for assetIdx = 1:numel(obj.stateMap.asset)
                    attitudeIdx = obj.stateMap.asset(assetIdx).euler;
                    if isempty(attitudeIdx); continue; end
                    xMeas(attitudeIdx) = ...
                        revgnss.AttitudeErrorStateKinematics.quatToEulerZYX( ...
                        obj.nominalQuat_wxyz(:,assetIdx));
                end
            end
        end

        function euler_rad = getReportEulerRad(obj, assetIdx)
            % getReportEulerRad  Attitude angles for reporting/diagnostics.
            if nargin < 2 || isempty(assetIdx); assetIdx = 1; end
            attitudeIdx = obj.stateMap.asset(assetIdx).euler;
            if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                euler_rad = revgnss.AttitudeErrorStateKinematics.quatToEulerZYX( ...
                    obj.nominalQuat_wxyz(:,assetIdx));
            else
                euler_rad = obj.x(attitudeIdx);
            end
        end

        function omega_B_E_meas_radps = inertialGyroscopeToEarthRelative( ...
                obj,observation,assetIdx)
            % Convert omega_B/I^B to the rate required by q_E_B propagation.
            % Only the measured rate, nominal attitude, and declared Earth rate enter.
            if nargin < 3 || isempty(assetIdx); assetIdx = 1; end
            assert(isa(observation,'models.sensors.GyroscopeObservation') && ...
                observation.valid, ...
                'ReverseGNSSEKF:invalidGyroscopeObservation', ...
                'A valid inertial gyroscope observation is required.');
            assert(assetIdx >= 1 && assetIdx <= numel(obj.stateMap.asset), ...
                'ReverseGNSSEKF:invalidAssetIndex', ...
                'Gyroscope asset index is outside the estimated state map.');
            if strcmp(obj.attitudeParameterization,'quaternionErrorState')
                q_E_B_nominal = obj.nominalQuat_wxyz(:,assetIdx);
            else
                attitudeIdx = obj.stateMap.asset(assetIdx).euler;
                q_E_B_nominal = ...
                    revgnss.AttitudeErrorStateKinematics.eulerToQuatZYX( ...
                    obj.x(attitudeIdx));
            end
            C_E_B_nominal = revgnss.AttitudeQuaternion.toDcm(q_E_B_nominal);
            omega_E_I_ecef = models.frames.FrameTimeUtils.omegaEcef_radps();
            omega_B_E_meas_radps = ...
                observation.omega_B_I_meas_body_radps - ...
                C_E_B_nominal.'*omega_E_I_ecef;
        end

        % ----------------------------------------------------------------
        function predict(obj, dt_s, towerClockModels, t0_s, omega_gyro_radps, ...
                assetClockModels, omega_gyro_inertial_radps)
            % predict  EKF time propagation.
            %   t0_s — simulation time at start of prediction interval.
            %   omega_gyro_radps (optional) — strapdown gyro body-rate reading. When the IMU is
            %   enabled the attitude is propagated with omega = omega_gyro - b_g; otherwise the
            %   free omega state is used (byte-identical to the pre-IMU behaviour).
            if nargin < 4 || isempty(t0_s); t0_s = 0; end
            if nargin < 5; omega_gyro_radps = []; end
            if nargin < 6; assetClockModels = {}; end
            if nargin < 7; omega_gyro_inertial_radps = []; end

            x  = obj.x;
            sm = obj.stateMap;

            r   = x(sm.r_idx);
            v   = x(sm.v_idx);
            eul = x(sm.euler_idx);
            omg = x(sm.omega_idx);
            omegaErrorDynamics = omg;
            % IMU strapdown: drive attitude with the gyro reading minus the estimated bias.
            % q_E_B propagation uses omega_B/E. The right-error dynamics use
            % omega_B/I, when that measured inertial rate is available.
            if obj.estimateGyroBias && ~isempty(omega_gyro_radps) && ~isempty(sm.gyroBiasIdx)
                omg = omega_gyro_radps(:,1) - x(sm.gyroBiasIdx);
                omegaErrorDynamics = omg;
                if size(omega_gyro_inertial_radps,2) >= 1
                    omegaErrorDynamics = omega_gyro_inertial_radps(:,1) - ...
                        x(sm.gyroBiasIdx);
                end
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
            % SRP scale-coefficient state: propagate r,v with the estimated scale and add its
            % STM column. Empty srpScale => feature off => the literal pre-feature calls below.
            srpScale = [];
            srpCol   = [];
            if obj.estimateSrpScale && ~isempty(sm.srpScaleIdx)
                srpScale = x(sm.srpScaleIdx);
            end
            if strcmp(dynMode, 'constantVelocity')
                r_new = r + dt_s * v;
                v_new = v;
                dynInfo.mode = 'constantVelocity';
            else
                try
                    if isempty(srpScale)
                        [r_new, v_new, dynInfo] = filter.EkfDynamicsPredictor.propagateEcef( ...
                            r, v, dt_s, t0_s, obj.cfg);
                        Phi6 = filter.EkfDynamicsPredictor.finiteDiffStm6( ...
                            r, v, dt_s, t0_s, obj.cfg);
                    else
                        [r_new, v_new, dynInfo] = filter.EkfDynamicsPredictor.propagateEcef( ...
                            r, v, dt_s, t0_s, obj.cfg, srpScale);
                        Phi6 = filter.EkfDynamicsPredictor.finiteDiffStm6( ...
                            r, v, dt_s, t0_s, obj.cfg, srpScale);
                        srpCol = filter.EkfDynamicsPredictor.srpStmColumn( ...
                            r, v, dt_s, t0_s, obj.cfg, srpScale);
                    end
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
            % Empirical RTN accelerations (reduced-dynamic filtering).
            %
            % Operator splitting: the nominal propagator above integrates the modelled
            % forces; this adds the estimated empirical acceleration on top. The state is
            % a first-order Gauss-Markov vector a(t) = a0*exp(-t/tau) resolved in the
            % INSTANTANEOUS RTN frame, so over one step the exact contributions are
            %   dv = a0 * c1,   dr = a0 * c2,
            %   c1 = tau*(1-exp(-dt/tau)),   c2 = tau*(dt - c1)
            % which reduce to a0*dt and 0.5*a0*dt^2 for dt << tau (the classical form).
            % Using the exact integrals keeps the state, the STM column and the GM decay
            % mutually consistent instead of only agreeing in the small-dt limit.
            %
            % The RTN basis is built from the ESTIMATED r,v (the filter has no truth) using
            % the SAME v_eff = v_ecef + omega x r convention as OrbitFrame.ecefToRacGeo, so
            % the state is directly comparable with the RAC error/sigma plots.
            % Splitting error is O(dt^2) per step in the coupling between this acceleration
            % and the gravity gradient: at 1e-7 m/s^2 and dt=1 s that is ~5e-8 m of
            % displacement per step against a ~1e-3 m/s^2 gradient response, i.e. negligible.
            empAccCol = [];
            if obj.estimateEmpiricalAccel && ~isempty(sm.empAccIdx)
                [Brtn, okRtn] = filter.ReverseGNSSEKF.rtnBasis_(r, v);
                if okRtn
                    [c1, c2, phiAcc] = filter.ReverseGNSSEKF.gmAccelIntegrals_( ...
                        dt_s, obj.empAccTau_);
                    % State is normalised: physical acceleration = empAccScale_ * x.
                    sA    = obj.empAccScale_;
                    aEcef = Brtn * (sA * x(sm.empAccIdx));
                    r_new = r_new + c2 * aEcef;
                    v_new = v_new + c1 * aEcef;
                    empAccCol = [c2 * sA * Brtn; c1 * sA * Brtn];   % [6x3] d([r;v])/dx
                    empAccPhi = phiAcc;
                else
                    empAccPhi = exp(-dt_s / obj.empAccTau_);
                end
            end

            obj.lastDynamicsPredictInfo = dynInfo;

            % Attitude: kinematics update (frozen when estimation disabled)
            if obj.estimateAttitude
                if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                    % Propagate nominal quaternion; error state stays near zero
                    obj.nominalQuat_wxyz(:,1) = ...
                        revgnss.AttitudeErrorStateKinematics.propagateQuatBodyRate( ...
                        obj.nominalQuat_wxyz(:,1), omg, dt_s);
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

            % Empirical acceleration state decays as the Gauss-Markov mean.
            if obj.estimateEmpiricalAccel && ~isempty(sm.empAccIdx)
                x_new(sm.empAccIdx) = empAccPhi * x(sm.empAccIdx);
            end

            % Tower clocks (if estimated)
            if obj.estimateTowerClocks && nargin >= 3
                for ti = 1:obj.nTowers
                    ib = sm.towerClockIdx(ti,1);
                    id = sm.towerClockIdx(ti,2);
                    x_new(ib) = x(ib) + dt_s * x(id);
                    x_new(id) = x(id);
                end
            end

            secondaryPhi = cell(1,obj.nSecondaryAssets);
            secondaryEuler = zeros(3,obj.nSecondaryAssets);
            secondaryOmega = zeros(3,obj.nSecondaryAssets);
            secondaryOmegaErrorDynamics = zeros(3,obj.nSecondaryAssets);
            if obj.jointMultiAssetEnabled
                for assetIdx = 2:obj.nSpaceAssets
                    secondaryIdx = assetIdx - 1;
                    blk = sm.asset(assetIdx);
                    rSecondary = x(blk.r);
                    vSecondary = x(blk.v);
                    if strcmp(dynMode,'constantVelocity')
                        rSecondaryNew = rSecondary + dt_s*vSecondary;
                        vSecondaryNew = vSecondary;
                        secondaryPhi{secondaryIdx} = [];
                    else
                        try
                            [rSecondaryNew,vSecondaryNew] = ...
                                filter.EkfDynamicsPredictor.propagateEcef( ...
                                rSecondary,vSecondary,dt_s,t0_s,obj.cfg);
                            secondaryPhi{secondaryIdx} = ...
                                filter.EkfDynamicsPredictor.finiteDiffStm6( ...
                                rSecondary,vSecondary,dt_s,t0_s,obj.cfg);
                        catch
                            rSecondaryNew = rSecondary + dt_s*vSecondary;
                            vSecondaryNew = vSecondary;
                            secondaryPhi{secondaryIdx} = [];
                        end
                    end
                    x_new(blk.r) = rSecondaryNew;
                    x_new(blk.v) = vSecondaryNew;

                    eulerSecondary = x(blk.euler);
                    omegaSecondary = x(blk.omega);
                    omegaSecondaryErrorDynamics = omegaSecondary;
                    if obj.estimateGyroBias && size(omega_gyro_radps,2) >= assetIdx && ...
                            ~isempty(blk.gyroBias)
                        omegaSecondary = omega_gyro_radps(:,assetIdx) - x(blk.gyroBias);
                        omegaSecondaryErrorDynamics = omegaSecondary;
                        if size(omega_gyro_inertial_radps,2) >= assetIdx
                            omegaSecondaryErrorDynamics = ...
                                omega_gyro_inertial_radps(:,assetIdx) - ...
                                x(blk.gyroBias);
                        end
                    end
                    secondaryEuler(:,secondaryIdx) = eulerSecondary;
                    secondaryOmega(:,secondaryIdx) = omegaSecondary;
                    secondaryOmegaErrorDynamics(:,secondaryIdx) = ...
                        omegaSecondaryErrorDynamics;
                    if obj.estimateAttitude
                        if strcmp(obj.attitudeParameterization,'quaternionErrorState')
                            obj.nominalQuat_wxyz(:,assetIdx) = ...
                                revgnss.AttitudeErrorStateKinematics.propagateQuatBodyRate( ...
                                obj.nominalQuat_wxyz(:,assetIdx),omegaSecondary,dt_s);
                            x_new(blk.euler) = zeros(3,1);
                        else
                            eulerRate = revgnss.AttitudeKinematics.eulerRatesFromBodyRates( ...
                                eulerSecondary,omegaSecondary);
                            x_new(blk.euler) = revgnss.AttitudeKinematics.wrapEuler( ...
                                eulerSecondary + dt_s*eulerRate);
                        end
                    end
                    x_new(blk.omega) = omegaSecondary;
                    x_new(blk.b) = x(blk.b) + dt_s*x(blk.bdot);
                    x_new(blk.bdot) = x(blk.bdot);
                end
            end

            obj.x = x_new;

            % State transition Jacobian F (pass Phi6 override for r/v block)
            F = obj.buildF_(dt_s, eul, omegaErrorDynamics, Phi6, srpCol, empAccCol);
            obj.lastF = F;

            if obj.jointMultiAssetEnabled
                for assetIdx = 2:obj.nSpaceAssets
                    secondaryIdx = assetIdx - 1;
                    blk = sm.asset(assetIdx);
                    rvIdx = [blk.r;blk.v];
                    PhiSecondary = secondaryPhi{secondaryIdx};
                    if ~isempty(PhiSecondary) && isequal(size(PhiSecondary),[6,6]) && ...
                            all(isfinite(PhiSecondary(:)))
                        F(rvIdx,rvIdx) = PhiSecondary;
                    else
                        F(rvIdx,rvIdx) = eye(6);
                        F(blk.r,blk.v) = dt_s*eye(3);
                    end
                    eulerSecondary = secondaryEuler(:,secondaryIdx);
                    omegaSecondary = ...
                        secondaryOmegaErrorDynamics(:,secondaryIdx);
                    if strcmp(obj.attitudeParameterization,'quaternionErrorState')
                        skewOmega = [0,-omegaSecondary(3),omegaSecondary(2); ...
                            omegaSecondary(3),0,-omegaSecondary(1); ...
                            -omegaSecondary(2),omegaSecondary(1),0];
                        F(blk.euler,blk.euler) = eye(3) - skewOmega*dt_s;
                        F(blk.euler,blk.omega) = dt_s*eye(3);
                        if obj.estimateGyroBias && ~isempty(blk.gyroBias)
                            F(blk.euler,blk.gyroBias) = -dt_s*eye(3);
                            F(blk.euler,blk.omega) = zeros(3);
                        end
                    else
                        F(blk.euler,blk.euler) = eye(3) + dt_s * ...
                            revgnss.AttitudeKinematics.eulerRateJacobian( ...
                            eulerSecondary,omegaSecondary);
                        cr = cos(eulerSecondary(1)); sr = sin(eulerSecondary(1));
                        cp = cos(eulerSecondary(2)); tp = tan(eulerSecondary(2));
                        if abs(cp) < 1e-6; cp = sign(cp + eps)*1e-6; end
                        transform = [1,sr*tp,cr*tp;0,cr,-sr;0,sr/cp,cr/cp];
                        F(blk.euler,blk.omega) = dt_s*transform;
                    end
                    if ~obj.estimateAttitude
                        F(blk.euler,blk.euler) = eye(3);
                        F(blk.euler,blk.omega) = zeros(3);
                    end
                    F(blk.b,blk.bdot) = dt_s;
                end
            end

            % Process noise Q
            Q = obj.buildQ_(dt_s, towerClockModels);
            if obj.jointMultiAssetEnabled
                Q = obj.addJointAssetProcessNoise_(Q,dt_s,assetClockModels);
            end

            % Propagate covariance
            obj.P = F * obj.P * F' + Q;
            obj.P = (obj.P + obj.P') / 2;

            if obj.retainEpochTransitionOperators
                obj.beginEpochTransition_(t0_s, dt_s, F, Q);
            end
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
            obj.requireWatermarkCurrent_(Pminus);

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
            resetJacobians = {};   % epoch-transition retention accumulator (Stage 3.1); stays
                                    % empty in eulerZYX mode, meaning the retained attitude reset
                                    % factor G is identity.
            if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                maxGuard = deg2rad(10);
                try; maxGuard = obj.cfg.estimator.attitude.maxErrorStateInjection_rad; catch; end
                primaryInjectionInfo = struct();
                largestInjection = 0;
                for assetIdx = 1:numel(obj.stateMap.asset)
                    attitudeIdx = obj.stateMap.asset(assetIdx).euler;
                    if isempty(attitudeIdx); continue; end
                    deltaTheta = obj.x(attitudeIdx);
                    [obj.nominalQuat_wxyz(:,assetIdx), injectionInfo] = ...
                        revgnss.AttitudeErrorStateKinematics.injectRight( ...
                        obj.nominalQuat_wxyz(:,assetIdx),deltaTheta);
                    obj.x(attitudeIdx) = zeros(3,1);
                    d = deltaTheta(:);
                    skewDelta = [0,-d(3),d(2);d(3),0,-d(1);-d(2),d(1),0];
                    resetJacobian = eye(3) - 0.5*skewDelta;
                    if obj.retainEpochTransitionOperators
                        resetJacobians{end+1} = struct('rows',attitudeIdx,'jacobian',resetJacobian); %#ok<AGROW>
                    end
                    obj.P(attitudeIdx,:) = resetJacobian*obj.P(attitudeIdx,:);
                    obj.P(:,attitudeIdx) = obj.P(:,attitudeIdx)*resetJacobian';
                    largestInjection = max(largestInjection,injectionInfo.injectionNorm_rad);
                    if injectionInfo.injectionNorm_rad > maxGuard
                        warning('ReverseGNSSEKF:update', ...
                            ['Spacecraft %d attitude injection %.2e rad (%.2f deg) ' ...
                             'exceeds the %.2e rad guard.'],assetIdx, ...
                            injectionInfo.injectionNorm_rad, ...
                            rad2deg(injectionInfo.injectionNorm_rad),maxGuard);
                    end
                    if assetIdx == 1
                        primaryInjectionInfo = injectionInfo;
                        primaryInjectionInfo.resetCondition = cond(resetJacobian);
                    end
                end
                obj.P = (obj.P+obj.P')/2;
                obj.attitudeInjectionCount       = obj.attitudeInjectionCount + 1;
                obj.maxAttitudeInjectionNorm_rad = max( ...
                    obj.maxAttitudeInjectionNorm_rad,largestInjection);
                obj.lastAttitudeErrorStateInfo = struct( ...
                    'parameterization',      'quaternionErrorState', ...
                    'qNorm',                 primaryInjectionInfo.qNormPost, ...
                    'lastInjectionNorm_rad', primaryInjectionInfo.injectionNorm_rad, ...
                    'maxInjectionNorm_rad',  obj.maxAttitudeInjectionNorm_rad, ...
                    'injectionCount',        obj.attitudeInjectionCount, ...
                    'covarianceResetApplied',  true, ...
                    'covarianceResetOrder',    'posterior-after-joseph', ...
                    'covarianceResetJacobianCondition', primaryInjectionInfo.resetCondition, ...
                    'eulerReportingOnly',      true);
            else
                for assetIdx = 1:numel(obj.stateMap.asset)
                    attitudeIdx = obj.stateMap.asset(assetIdx).euler;
                    if isempty(attitudeIdx); continue; end
                    obj.x(attitudeIdx) = revgnss.AttitudeKinematics.wrapEuler( ...
                        obj.x(attitudeIdx));
                end
            end

            % 8. Numerical sanity / PSD guard (after attitude reset if any)
            repairKind = '';   % epoch-transition retention accumulator (Stage 3.1)
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
                repairKind = 'nearestSpdProjection';
            elseif minEig < 0
                % Tiny negative eigenvalue from floating-point: nudge diagonal
                obj.P = (obj.P + obj.P') / 2;
                obj.P = obj.P + eye(obj.nx) * (tol - minEig);
                repairKind = 'benignDiagonalNudge';
            end

            if obj.retainEpochTransitionOperators
                obj.accumulateEpochTransition_(K, H, resetJacobians, repairKind, numel(z));
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
        function s = computeSwarmNEES(obj, truthPrimary, secTruth) %#ok<INUSD>
            % computeSwarmNEES  Guard C: per-secondary + formation-centroid NEES.
            %   RETIRED (federated-swarm joint-EKF retirement, W4-4b): the secondary-asset
            %   orbit/clock EKF states this method scored have been removed (the joint
            %   secondary measurement path was already deleted, and mode='honest' now
            %   errors). This method is kept ONLY so its existing callers
            %   (SimulationDataStore, MonteCarloConsistency) keep working; it always
            %   returns the empty/NaN sentinel struct since there is no secondary state
            %   left to score.
            s = struct('perSat', struct('pos',{},'vel',{},'clock',{},'posErrNorm_m',{}), ...
                       'centroid',          struct('pos',NaN,'posErrNorm_m',NaN,'N',0,'cov3',[]), ...
                       'secondaryCentroid', struct('pos',NaN,'posErrNorm_m',NaN,'N',0,'cov3',[]));
        end

        % ----------------------------------------------------------------
        function aErr = attitudeSmallAngleError_(obj, truthEuler_rad)
            % attitudeSmallAngleError_  Small-angle attitude error in P(euler_idx)
            % space. Quaternion mode uses the error DCM between nominal and truth;
            % Euler mode uses the wrap-aware reported-minus-truth Euler difference.
            if strcmp(obj.attitudeParameterization, 'quaternionErrorState')
                C_nom = revgnss.AttitudeErrorStateKinematics.quatToDcm( ...
                    obj.nominalQuat_wxyz(:,1));
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

            % SRP scale-coefficient state (single scalar, appended strictly LAST). Empty []
            % when off -> byte-identical map (mirrors the gyroBiasIdx empty-sentinel pattern).
            if obj.estimateSrpScale
                sm.srpScaleIdx = nextIdx;
                nextIdx = nextIdx + 1;
            else
                sm.srpScaleIdx = [];
            end

            % Optional ISL carrier-ambiguity states, appended strictly LAST so enabling
            % them shifts NO existing index. Allocation goes through the shared
            % AmbiguityStateRegistry (link -> index), which is append-only and idempotent;
            % the registry is retained so later phases can resolve an index from an
            % AmbiguityKey instead of a hard-coded (tower,receiver,signal) triple.
            % Empty [] sentinel when off -> state map identical to the pre-ISL map.
            if obj.estimateIslAmbiguities && obj.nIslAmbiguities > 0
                reg = revgnss.AmbiguityStateRegistry(nextIdx);
                sm.islAmbiguityIdx = reg.registerIslBlock(obj.islAmbiguityTxList, ...
                    obj.islAmbiguityRxIdx, obj.islAmbiguityNSignals);
                % Row order of islAmbiguityIdx follows this transmitter list, so consumers
                % must map a transmitter index THROUGH it rather than subscripting directly
                % (transmitter indices are 2..N, and 'transmitters' may select a subset).
                sm.islAmbiguityTxList = obj.islAmbiguityTxList;
                obj.islAmbiguityRegistry = reg;
                nextIdx = nextIdx + reg.count();
            else
                sm.islAmbiguityIdx    = [];
                sm.islAmbiguityTxList = [];
                obj.islAmbiguityRegistry = [];
            end

            % Joint secondary blocks are appended after all single-spacecraft
            % optional states, preserving every existing index when joint mode is off.
            sm.secondaryOrbitIdx    = zeros(0,6);
            sm.secondaryAttitudeIdx = zeros(0,6);
            sm.secondaryClockIdx    = zeros(0,2);
            sm.secondaryGyroBiasIdx = zeros(0,3);
            if obj.jointMultiAssetEnabled
                sm.secondaryOrbitIdx    = zeros(obj.nSecondaryAssets,6);
                sm.secondaryAttitudeIdx = zeros(obj.nSecondaryAssets,6);
                sm.secondaryClockIdx    = zeros(obj.nSecondaryAssets,2);
                if obj.estimateGyroBias
                    sm.secondaryGyroBiasIdx = zeros(obj.nSecondaryAssets,3);
                end
                for secondaryIdx = 1:obj.nSecondaryAssets
                    sm.secondaryOrbitIdx(secondaryIdx,:) = nextIdx:nextIdx+5;
                    nextIdx = nextIdx + 6;
                    sm.secondaryAttitudeIdx(secondaryIdx,:) = nextIdx:nextIdx+5;
                    nextIdx = nextIdx + 6;
                    sm.secondaryClockIdx(secondaryIdx,:) = nextIdx:nextIdx+1;
                    nextIdx = nextIdx + 2;
                    if obj.estimateGyroBias
                        sm.secondaryGyroBiasIdx(secondaryIdx,:) = nextIdx:nextIdx+2;
                        nextIdx = nextIdx + 3;
                    end
                end
            end
            if obj.estimateTwoWayCodeCalibrationBias
                count = obj.nTwoWayCodeCalibrationBiasStates;
                sm.twoWayCodeCalibrationBiasIdx = ...
                    (nextIdx:nextIdx+count-1)';
                sm.twoWayCodeCalibrationBiasLinkIdentifiers = ...
                    obj.twoWayCodeCalibrationBiasLinkIdentifiers;
                nextIdx = nextIdx + count;
            else
                sm.twoWayCodeCalibrationBiasIdx = [];
                sm.twoWayCodeCalibrationBiasLinkIdentifiers = {};
            end

            % Empirical RTN accelerations, appended strictly LAST so enabling them
            % shifts NO existing index. Empty [] sentinel when off (gyroBiasIdx pattern).
            if obj.estimateEmpiricalAccel
                sm.empAccIdx = (nextIdx:nextIdx+2)';
                nextIdx = nextIdx + 3;
            else
                sm.empAccIdx = [];
            end

            blankAsset = struct('r',[],'v',[],'euler',[],'omega',[], ...
                'b',[],'bdot',[],'ambiguity3d',[],'ambiguity',[], ...
                'zwd',[],'iono',[],'gyroBias',[]);
            sm.asset = repmat(blankAsset, 1, 1 + obj.nSecondaryAssets);
            sm.asset(1).r       = sm.r_idx;
            sm.asset(1).v       = sm.v_idx;
            sm.asset(1).euler   = sm.euler_idx;
            sm.asset(1).omega   = sm.omega_idx;
            sm.asset(1).b       = sm.b_rx_idx;
            sm.asset(1).bdot    = sm.bdot_rx_idx;
            sm.asset(1).gyroBias = sm.gyroBiasIdx;
            if isfield(sm,'ambiguityIdx3d'); sm.asset(1).ambiguity3d = sm.ambiguityIdx3d; end
            if isfield(sm,'ambiguityIdx');   sm.asset(1).ambiguity   = sm.ambiguityIdx;   end
            if isfield(sm,'zwdIdx');         sm.asset(1).zwd         = sm.zwdIdx;          end
            if isfield(sm,'ionoIdx');        sm.asset(1).iono        = sm.ionoIdx;         end
            for assetIdx = 2:1+obj.nSecondaryAssets
                secondaryIdx = assetIdx - 1;
                sm.asset(assetIdx).r     = sm.secondaryOrbitIdx(secondaryIdx,1:3)';
                sm.asset(assetIdx).v     = sm.secondaryOrbitIdx(secondaryIdx,4:6)';
                sm.asset(assetIdx).euler = sm.secondaryAttitudeIdx(secondaryIdx,1:3)';
                sm.asset(assetIdx).omega = sm.secondaryAttitudeIdx(secondaryIdx,4:6)';
                sm.asset(assetIdx).b     = sm.secondaryClockIdx(secondaryIdx,1);
                sm.asset(assetIdx).bdot  = sm.secondaryClockIdx(secondaryIdx,2);
                if obj.estimateGyroBias
                    sm.asset(assetIdx).gyroBias = ...
                        sm.secondaryGyroBiasIdx(secondaryIdx,:)';
                end
            end

            % Cross-check the two hand-maintained implementations of the state layout:
            % the constructor's nx arithmetic and this nextIdx walk. They are independent
            % code paths, so a block added to one but not the other would otherwise
            % produce a silently truncated or over-sized state vector.
            assert(nextIdx - 1 == obj.nx, 'ReverseGNSSEKF:stateMapSizeMismatch', ...
                ['State-map walk allocated %d states but the constructor computed nx=%d. ' ...
                 'A state block was added to one path and not the other.'], ...
                nextIdx - 1, obj.nx);
        end

        % ----------------------------------------------------------------
        function F = buildF_(obj, dt_s, euler, omega, Phi6, srpCol, empAccCol)
            % buildF_  Linearised state-transition Jacobian.
            %
            % Euler-euler block: FD derivative of (eul + dt * T(eul,omg)*omg) w.r.t. eul.
            % Euler-omega block: dt * T(euler)  [kinematic transformation].
            % Phi6 (optional): 6x6 translational STM replacing default [I dtI;0 I] block.
            % srpCol (optional): 6x1 d([r;v])/d(srpScale) filling F(rv, srpScaleIdx).

            if nargin < 5; Phi6 = []; end
            if nargin < 6; srpCol = []; end
            if nargin < 7; empAccCol = []; end

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

            % SRP scale-coefficient column: d([r;v])/ds fills F(rv, srpScaleIdx). The scale
            % itself is a random walk -> F(srpScaleIdx,srpScaleIdx)=1 already from F=eye(nx).
            if obj.estimateSrpScale && ~isempty(sm.srpScaleIdx) ...
                    && ~isempty(srpCol) && numel(srpCol) == 6 && all(isfinite(srpCol))
                F(rv_idx, sm.srpScaleIdx) = srpCol(:);
            end

            % Empirical RTN acceleration: d([r;v])/d(a_RTN) = [c2*B; c1*B], and the state
            % itself is a Gauss-Markov process -> F(empAcc,empAcc) = exp(-dt/tau)*I.
            if obj.estimateEmpiricalAccel && ~isempty(sm.empAccIdx)
                if ~isempty(empAccCol) && isequal(size(empAccCol), [6,3]) && ...
                        all(isfinite(empAccCol(:)))
                    F(rv_idx, sm.empAccIdx) = empAccCol;
                end
                [~, ~, phiAccF] = filter.ReverseGNSSEKF.gmAccelIntegrals_(dt_s, obj.empAccTau_);
                F(sm.empAccIdx, sm.empAccIdx) = phiAccF * eye(3);
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

            % --- Declared common (shared) process-noise diagonal (plan Section 3.3) -------------
            if ~isempty(obj.declaredCommonProcessNoiseGroup_)
                schemaIdx = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap( ...
                    obj.stateMap, 1);
                Q = Q + obj.declaredCommonProcessNoiseGroup_.ownDiagonalContribution(dt_s, schemaIdx, nx);
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

            % --- IMU/MEKF process noise
            if obj.estimateGyroBias && ~isempty(sm.gyroBiasIdx)
                Q = obj.applyGyroProcessNoise_(Q,sm.euler_idx, ...
                    sm.omega_idx,sm.gyroBiasIdx,dt_s);
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

            % --- SRP scale-coefficient process noise (random walk) -------
            % Q = procNoise^2 * dt lets the scale s adapt slowly. Small by default so the
            % estimate stays smooth (the honest fix vs. blunt orbit-SNC inflation).
            if obj.estimateSrpScale && ~isempty(sm.srpScaleIdx)
                Q(sm.srpScaleIdx, sm.srpScaleIdx) = obj.srpScaleProcNoise_^2 * dt_s;
            end
            if obj.estimateTwoWayCodeCalibrationBias && ...
                    ~isempty(sm.twoWayCodeCalibrationBiasIdx)
                indices = sm.twoWayCodeCalibrationBiasIdx;
                Q(indices,indices) = ...
                    obj.twoWayCodeCalibrationBiasProcessNoise_^2*dt_s * ...
                    eye(numel(indices));
            end

            % --- ISL ambiguity process noise -----------------------------
            % Separate knob from the ground ambiguity noise below: an ISL crosslink arc
            % and a ground tower arc have unrelated stability, and coupling them would
            % make an ISL-only change silently move the ground solution. Default 0 =
            % a strictly constant ambiguity within an arc (the physical model); slips are
            % handled by covariance reset, not by process noise.
            if obj.estimateIslAmbiguities && isfield(sm,'islAmbiguityIdx') && ...
                    ~isempty(sm.islAmbiguityIdx)
                q_isl_sigma = 0;
                try
                    q_isl_sigma = obj.cfg.measurements.isl.carrier.ambiguity.processNoiseSigma_m_per_sqrt_s;
                catch; end
                if q_isl_sigma > 0
                    q_isl = q_isl_sigma^2 * dt_s;
                    for k = 1:numel(sm.islAmbiguityIdx)
                        idx = sm.islAmbiguityIdx(k);
                        if idx > 0; Q(idx, idx) = q_isl; end
                    end
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

            % --- Empirical RTN acceleration process noise (Gauss-Markov steady state) ---
            % q = sigma_ss^2 * (1 - phi^2) reproduces the stationary variance sigma_ss^2
            % exactly under P <- phi^2 P + q, matching the ZWD / slant-iono blocks.
            if obj.estimateEmpiricalAccel && ~isempty(sm.empAccIdx)
                [~, ~, phi_acc] = filter.ReverseGNSSEKF.gmAccelIntegrals_(dt_s, obj.empAccTau_);
                % State is normalised to sigma_ss, so the scaled steady-state variance
                % is exactly 1 and q = 1 - phi^2.
                q_acc = (obj.empAccSigmaSs_ / obj.empAccScale_)^2 * (1 - phi_acc^2);
                for ai = 1:numel(sm.empAccIdx)
                    Q(sm.empAccIdx(ai), sm.empAccIdx(ai)) = q_acc;
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

            obj.requireWatermarkCurrent_(obj.P);
            obj.P(idx, :) = 0;
            obj.P(:, idx) = 0;
            obj.P(idx, idx) = resetSigma_m^2;
            if obj.retainEpochTransitionOperators
                obj.noteEpochTransitionRepair_('ambiguityCovarianceReset');
            end
        end

        % ----------------------------------------------------------------
        function didReset = resetIslAmbiguityCovariance(obj, txIdx, sigIdx, resetSigma_m)
            % resetIslAmbiguityCovariance  Reset one ISL ambiguity after a cycle slip.
            %
            % Mirrors resetAmbiguityCovariance for the ISL family: zero the row/column and
            % re-inflate the diagonal, leaving the state VALUE alone so the inflated
            % covariance lets the filter move it. Independent of the ground reset sigma --
            % it uses cfg.measurements.isl.carrier.ambiguity.initialSigma_m.
            %
            % A float ambiguity is constant only WITHIN an arc; after a slip the old
            % estimate is stale, and keeping its tight sigma would leave the filter
            % confidently wrong on the new arc.
            didReset = false;
            if ~obj.estimateIslAmbiguities; return; end
            sm = obj.stateMap;
            if ~isfield(sm,'islAmbiguityIdx') || isempty(sm.islAmbiguityIdx); return; end
            if nargin < 3 || isempty(sigIdx); sigIdx = 1; end
            if nargin < 4 || isempty(resetSigma_m)
                resetSigma_m = 100;
                try
                    resetSigma_m = obj.cfg.measurements.isl.carrier.ambiguity.initialSigma_m;
                catch; end
            end
            % Map the transmitter index through the allocation list (rows follow that
            % order; transmitter indices are 2..N and may be a subset).
            if ~isfield(sm,'islAmbiguityTxList') || isempty(sm.islAmbiguityTxList); return; end
            r = find(sm.islAmbiguityTxList == txIdx, 1);
            if isempty(r) || r > size(sm.islAmbiguityIdx,1); return; end
            if sigIdx < 1 || sigIdx > size(sm.islAmbiguityIdx,2); return; end
            idx = sm.islAmbiguityIdx(r, sigIdx);
            if idx <= 0 || idx > obj.nx; return; end

            obj.requireWatermarkCurrent_(obj.P);
            obj.P(idx, :)   = 0;
            obj.P(:, idx)   = 0;
            obj.P(idx, idx) = resetSigma_m^2;
            didReset = true;
            if obj.retainEpochTransitionOperators
                obj.noteEpochTransitionRepair_('ambiguityCovarianceReset');
            end
        end

        % ----------------------------------------------------------------
        function nReset = applyIslAmbiguityResets(obj, resetRequests, resetSigma_m)
            % applyIslAmbiguityResets  Batch ISL ambiguity covariance resets.
            %
            % resetRequests: struct array with fields txIdx and signalIdx (as produced by
            % revgnss.IslCarrierTrackManager.process).
            nReset = 0;
            if nargin < 3; resetSigma_m = []; end
            for ri = 1:numel(resetRequests)
                si = 1;
                if isfield(resetRequests(ri),'signalIdx') && ~isempty(resetRequests(ri).signalIdx)
                    si = resetRequests(ri).signalIdx;
                end
                if obj.resetIslAmbiguityCovariance(resetRequests(ri).txIdx, si, resetSigma_m)
                    nReset = nReset + 1;
                end
            end
        end

        % ----------------------------------------------------------------
        function info = applyIslDifferencedAmbiguityFix(obj, D, dNfixed_cycles, lambda_m, sigma_m)
            % applyIslDifferencedAmbiguityFix  Condition the state on a DIFFERENCED integer fix.
            %
            % Route B fixes dN = N_i - N_ref, not the individual ambiguities, so the
            % constraint is a set of LINEAR combinations rather than one state each:
            %
            %   z = lambda * dN_fixed      h = D * x(islAmb)      H(:, islAmb) = D
            %
            % Routed through the standard Joseph-form update(), so this IS the conditional
            % mixed-integer update x_check = x_hat - Q_ba*Qa^-1*(a_hat - a_fix) (Teunissen
            % 1995) expressed as a tight pseudo-measurement -- the cross-covariance
            % P(other, islAmb) carries the correction into position and clock automatically,
            % and covariance positive-definiteness is preserved by the existing machinery.
            %
            % INFORMATION DOUBLE-COUNTING WARNING: this constraint is DETERMINISTIC. Applying
            % it every epoch would inject the same information repeatedly and drive P toward
            % zero -- a confidently-wrong covariance. The caller MUST apply it once per arc
            % (see ReverseGNSSSimulation, which holds the fix and re-applies only after a
            % cycle slip resets the arc).
            info = struct('applied', false, 'nConstraints', 0, 'NIS', NaN, ...
                'traceBefore', NaN, 'traceAfter', NaN, 'warning', '');
            if ~obj.estimateIslAmbiguities; info.warning = 'no ISL ambiguity states'; return; end
            sm = obj.stateMap;
            if ~isfield(sm,'islAmbiguityIdx') || isempty(sm.islAmbiguityIdx)
                info.warning = 'no islAmbiguityIdx'; return
            end
            idx = sm.islAmbiguityIdx(:)';
            idx = idx(idx > 0);
            if isempty(idx); info.warning = 'empty ISL ambiguity index'; return; end
            if size(D,2) ~= numel(idx)
                info.warning = sprintf('D has %d columns, expected %d', size(D,2), numel(idx));
                return
            end
            m = size(D,1);
            if m < 1 || numel(dNfixed_cycles) ~= m
                info.warning = 'dNfixed size mismatch'; return
            end
            if nargin < 5 || isempty(sigma_m); sigma_m = 1e-3; end

            H = zeros(m, obj.nx);
            H(:, idx) = D;
            z = lambda_m * dNfixed_cycles(:);
            h = D * obj.x(idx);
            R = (sigma_m^2) * eye(m);

            info.traceBefore = trace(obj.P(idx, idx));
            [~, ~, ~, nis] = obj.update(z, h, H, R);
            info.traceAfter  = trace(obj.P(idx, idx));
            info.applied      = true;
            info.nConstraints = m;
            info.NIS          = nis;
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

        function Q = addJointAssetProcessNoise_(obj,Q,dt_s,assetClockModels)
            sm = obj.stateMap;
            primaryAccelSigma = obj.sigma_accel_mps2;
            try
                mismatchSigma = obj.cfg.estimator.processNoise.modelMismatch.sigma_mps2;
                if obj.cfg.estimator.processNoise.modelMismatch.enable && ...
                        isscalar(mismatchSigma) && mismatchSigma > 0
                    primaryAccelSigma = hypot(primaryAccelSigma,mismatchSigma);
                end
            catch
            end

            angularSigma = obj.sigma_angAccel_radps2;
            qAttitude = angularSigma^2*dt_s^3/3;
            qRate = angularSigma^2*dt_s;
            qAttitudeRate = angularSigma^2*dt_s^2/2;
            if ~obj.estimateAttitude
                qAttitude = qAttitude*1e-20;
                qAttitudeRate = qAttitudeRate*1e-20;
            end
            if ~obj.estimateAngularRate
                qRate = qRate*1e-20;
                qAttitudeRate = qAttitudeRate*1e-20;
            end

            for assetIdx = 2:obj.nSpaceAssets
                blk = sm.asset(assetIdx);
                accelSigma = primaryAccelSigma;
                try
                    configuredSigma = obj.cfg.multiAsset.secondaryOrbit.sigma_accel_mps2;
                    if isscalar(configuredSigma) && isfinite(configuredSigma) && ...
                            configuredSigma >= 0
                        accelSigma = configuredSigma;
                    end
                catch
                end
                qPosition = accelSigma^2*dt_s^3/3;
                qVelocity = accelSigma^2*dt_s;
                qPositionVelocity = accelSigma^2*dt_s^2/2;
                for axisIdx = 1:3
                    Q(blk.r(axisIdx),blk.r(axisIdx)) = qPosition;
                    Q(blk.v(axisIdx),blk.v(axisIdx)) = qVelocity;
                    Q(blk.r(axisIdx),blk.v(axisIdx)) = qPositionVelocity;
                    Q(blk.v(axisIdx),blk.r(axisIdx)) = qPositionVelocity;
                    Q(blk.euler(axisIdx),blk.euler(axisIdx)) = qAttitude;
                    Q(blk.omega(axisIdx),blk.omega(axisIdx)) = qRate;
                    Q(blk.euler(axisIdx),blk.omega(axisIdx)) = qAttitudeRate;
                    Q(blk.omega(axisIdx),blk.euler(axisIdx)) = qAttitudeRate;
                end
                if obj.estimateGyroBias && ~isempty(blk.gyroBias)
                    Q = obj.applyGyroProcessNoise_(Q,blk.euler, ...
                        blk.omega,blk.gyroBias,dt_s);
                end

                clockModel = [];
                if numel(assetClockModels) >= obj.nSpaceAssets
                    clockModel = assetClockModels{assetIdx};
                elseif numel(assetClockModels) >= assetIdx - 1
                    clockModel = assetClockModels{assetIdx-1};
                end
                if isempty(clockModel)
                    Qclock = diag([1e-4,1e-8])*dt_s;
                else
                    Qclock = clockModel.getProcessNoiseQ(dt_s,'meters');
                end
                clockIdx = [blk.b,blk.bdot];
                Q(clockIdx,clockIdx) = Qclock;
            end
            commonEnabled = false;
            commonSigma = 0;
            try
                commonConfig = obj.cfg.estimator.processNoise.commonAcceleration;
                commonEnabled = logical(commonConfig.enable);
                commonSigma = commonConfig.sigma_mps2;
            catch
            end
            if commonEnabled && commonSigma > 0
                qCommon = commonSigma^2 * ...
                    [dt_s^3/3,dt_s^2/2;dt_s^2/2,dt_s];
                for firstAsset = 1:obj.nSpaceAssets
                    firstBlock = sm.asset(firstAsset);
                    for secondAsset = 1:obj.nSpaceAssets
                        secondBlock = sm.asset(secondAsset);
                        for axisIdx = 1:3
                            firstIndices = [firstBlock.r(axisIdx),firstBlock.v(axisIdx)];
                            secondIndices = [secondBlock.r(axisIdx),secondBlock.v(axisIdx)];
                            Q(firstIndices,secondIndices) = ...
                                Q(firstIndices,secondIndices) + qCommon;
                        end
                    end
                end
            end
            Q = (Q+Q')/2;
        end

        function Q = applyGyroProcessNoise_(obj,Q,attitudeIdx,rateIdx,biasIdx,dt_s)
            % Discrete covariance for white gyro noise and gyro-bias random walk.
            arwVariance = obj.imuArw_^2;
            biasWalkPsd = obj.imuRrw_^2;
            Qtheta = (arwVariance*dt_s + biasWalkPsd*dt_s^3/3)*eye(3);
            QthetaBias = -biasWalkPsd*dt_s^2/2*eye(3);
            Qbias = biasWalkPsd*dt_s*eye(3);

            Q(attitudeIdx,attitudeIdx) = Qtheta;
            Q(attitudeIdx,rateIdx) = zeros(3);
            Q(rateIdx,attitudeIdx) = zeros(3);
            Q(attitudeIdx,biasIdx) = QthetaBias;
            Q(biasIdx,attitudeIdx) = QthetaBias.';
            Q(biasIdx,biasIdx) = Qbias;
        end

        % ----------------------------------------------------------------
        function initHistory_(obj)
            obj.history.time_s      = [];
            obj.history.x           = [];
            obj.history.P_diag      = [];
            obj.history.NIS         = [];
            obj.history.posErrNorm_m= [];
            obj.history.nominalQuat_wxyz = zeros(4, numel(obj.stateMap.asset), 0);
            obj.history.attitudeErrorCovariance_rad2 = ...
                zeros(3,3,numel(obj.stateMap.asset),0);
            obj.history.gyroBiasCovariance_rad2ps2 = ...
                zeros(3,3,numel(obj.stateMap.asset),0);
            obj.history.relativePositionCovarianceToReference_m2 = ...
                zeros(3,3,max(0,numel(obj.stateMap.asset)-1),0);
        end

        function logStep(obj, t_s, NIS, posErr_m)
            obj.history.time_s       = [obj.history.time_s;       t_s];
            obj.history.x            = [obj.history.x,            obj.x];
            obj.history.P_diag       = [obj.history.P_diag,       diag(obj.P)];
            obj.history.NIS          = [obj.history.NIS;          NIS];
            obj.history.posErrNorm_m = [obj.history.posErrNorm_m; posErr_m];
            if strcmp(obj.attitudeParameterization,'quaternionErrorState')
                quaternionHistoryEntry = obj.nominalQuat_wxyz;
            else
                quaternionHistoryEntry = zeros(4,numel(obj.stateMap.asset));
                for assetIdx = 1:numel(obj.stateMap.asset)
                    quaternionHistoryEntry(:,assetIdx) = ...
                        revgnss.AttitudeErrorStateKinematics.eulerToQuatZYX( ...
                        obj.x(obj.stateMap.asset(assetIdx).euler));
                end
            end
            obj.history.nominalQuat_wxyz(:,:,end+1) = quaternionHistoryEntry;
            historyIndex = numel(obj.history.time_s);
            attitudeCovariance = zeros(3,3,numel(obj.stateMap.asset));
            gyroBiasCovariance = nan(3,3,numel(obj.stateMap.asset));
            for assetIdx = 1:numel(obj.stateMap.asset)
                block = obj.stateMap.asset(assetIdx);
                attitudeCovariance(:,:,assetIdx) = ...
                    obj.P(block.euler,block.euler);
                if ~isempty(block.gyroBias)
                    gyroBiasCovariance(:,:,assetIdx) = ...
                        obj.P(block.gyroBias,block.gyroBias);
                end
            end
            obj.history.attitudeErrorCovariance_rad2(:,:,:,historyIndex) = ...
                attitudeCovariance;
            obj.history.gyroBiasCovariance_rad2ps2(:,:,:,historyIndex) = ...
                gyroBiasCovariance;
            for assetIdx = 2:numel(obj.stateMap.asset)
                referenceBlock = obj.stateMap.asset(1);
                assetBlock = obj.stateMap.asset(assetIdx);
                obj.history.relativePositionCovarianceToReference_m2( ...
                    :,:,assetIdx-1,historyIndex) = ...
                    obj.P(assetBlock.r,assetBlock.r) + ...
                    obj.P(referenceBlock.r,referenceBlock.r) - ...
                    obj.P(assetBlock.r,referenceBlock.r) - ...
                    obj.P(referenceBlock.r,assetBlock.r);
            end
        end

        % ----------------------------------------------------------------
        % Epoch error-transition retention (plan Stage 3.1 items 4-5). Every method below is a
        % no-op unless retainEpochTransitionOperators is true, and none of them ever writes
        % obj.x, obj.P, F, or Q -- they only observe and record.
        function beginEpochTransition_(obj, t0_s, dt_s, F, Q)
            % beginEpochTransition_  Arms a fresh capture window: A=eye(nx), F/Q retained by
            % value, counters zeroed, predictApplied=true. Called only from predict().
            obj.pendingEpochTransition_ = struct( ...
                'predictApplied',true, ...
                'intervalStartCoordinateEpoch_s',t0_s, ...
                'intervalDuration_s',dt_s, ...
                'localStateDimension',obj.nx, ...
                'stateTransition',F, ...
                'processNoise',Q, ...
                'localUpdateContraction',eye(obj.nx), ...
                'accountedUpdateCallCount',0, ...
                'accountedMeasurementRowCount',0, ...
                'benignDiagonalNudgeCount',0, ...
                'unmodelledCovarianceTransformCount',0, ...
                'unmodelledCovarianceTransformKinds',{{}}, ...
                'captureSequenceNumber',obj.epochTransitionSequence_+1);
            obj.epochTransitionCaptureOpen_ = true;
            obj.covarianceAtLastAccountedWrite_ = obj.P;
        end

        function accumulateEpochTransition_(obj, K, H, resetJacobians, repairKind, rowCount)
            % accumulateEpochTransition_  Folds one update() call's (K,H) and any attitude-reset
            % Jacobians into the pending contraction A <- G*(I-K*H)*A. A no-op if no predict()
            % armed a window this epoch (e.g. a link update applied outside the coordinator's
            % own epoch loop).
            if ~obj.epochTransitionCaptureOpen_; return; end
            nxLocal = obj.pendingEpochTransition_.localStateDimension;
            G = eye(nxLocal);
            for index = 1:numel(resetJacobians)
                rows = resetJacobians{index}.rows;
                G(rows,rows) = resetJacobians{index}.jacobian;
            end
            obj.pendingEpochTransition_.localUpdateContraction = ...
                G*(eye(nxLocal)-K*H)*obj.pendingEpochTransition_.localUpdateContraction;
            obj.pendingEpochTransition_.accountedUpdateCallCount = ...
                obj.pendingEpochTransition_.accountedUpdateCallCount+1;
            obj.pendingEpochTransition_.accountedMeasurementRowCount = ...
                obj.pendingEpochTransition_.accountedMeasurementRowCount+rowCount;
            if strcmp(repairKind,'benignDiagonalNudge')
                % A positive diagonal addition to P only; never touches a cross block, so it is
                % counted but does not invalidate the retained operators (U6).
                obj.pendingEpochTransition_.benignDiagonalNudgeCount = ...
                    obj.pendingEpochTransition_.benignDiagonalNudgeCount+1;
            elseif strcmp(repairKind,'nearestSpdProjection')
                obj.pendingEpochTransition_.unmodelledCovarianceTransformCount = ...
                    obj.pendingEpochTransition_.unmodelledCovarianceTransformCount+1;
                obj.pendingEpochTransition_.unmodelledCovarianceTransformKinds{end+1} = repairKind;
            end
            obj.covarianceAtLastAccountedWrite_ = obj.P;
        end

        function requireWatermarkCurrent_(obj, priorP)
            % requireWatermarkCurrent_  Closes the watermark fence's remaining gap: called at
            % the TOP of every accounted method (update, the two ambiguity resets), before that
            % method's own writes, with the obj.P value as it stood at entry. Without this, an
            % external write landing BETWEEN two accounted calls (e.g. between predict() and the
            % following update()) was silently absorbed by the re-seed at the END of the
            % previous accounted call, rather than caught here at the start of the next one.
            if ~obj.retainEpochTransitionOperators || ~obj.epochTransitionCaptureOpen_; return; end
            if ~isequal(priorP, obj.covarianceAtLastAccountedWrite_)
                error('ReverseGNSSEKF:unaccountedCovarianceMutation', ...
                    ['obj.P was written outside predict()/update()/the ambiguity-covariance ' ...
                    'resets/applyDeclaredExternalCovarianceWrite before this accounted call ' ...
                    'began; the retained epoch-transition operators no longer describe obj.P.']);
            end
        end

        function noteEpochTransitionRepair_(obj, kindName)
            % noteEpochTransitionRepair_  Public entry point for a non-linear covariance edit
            % OUTSIDE update() (the two ambiguity-covariance resets): counts an unmodelled
            % transform and refreshes the watermark immediately, since no accumulate call
            % follows a reset.
            if ~obj.epochTransitionCaptureOpen_; return; end
            obj.pendingEpochTransition_.unmodelledCovarianceTransformCount = ...
                obj.pendingEpochTransition_.unmodelledCovarianceTransformCount+1;
            obj.pendingEpochTransition_.unmodelledCovarianceTransformKinds{end+1} = kindName;
            obj.covarianceAtLastAccountedWrite_ = obj.P;
        end

        function raw = takeEpochTransitionCapture(obj)
            % takeEpochTransitionCapture  Take, not get: closes the open window and returns its
            % plain struct. The watermark fence makes the accounted-write set enforceable: any
            % write to obj.P since the last accounted write (predict/update/an ambiguity reset/
            % applyDeclaredExternalCovarianceWrite) throws here instead of silently corrupting
            % the retained operators.
            if ~obj.epochTransitionCaptureOpen_
                error('ReverseGNSSEKF:epochTransitionCaptureNotOpen', ...
                    'No predict() has armed an epoch-transition capture window.');
            end
            if ~isequal(obj.P, obj.covarianceAtLastAccountedWrite_)
                error('ReverseGNSSEKF:unaccountedCovarianceMutation', ...
                    ['obj.P was written outside predict()/update()/the ambiguity-covariance ' ...
                    'resets/applyDeclaredExternalCovarianceWrite since the last accounted write; ' ...
                    'the retained epoch-transition operators no longer describe obj.P.']);
            end
            raw = obj.pendingEpochTransition_;
            raw.intervalEndCoordinateEpoch_s = raw.intervalStartCoordinateEpoch_s+raw.intervalDuration_s;
            obj.epochTransitionCaptureOpen_ = false;
            obj.epochTransitionSequence_ = raw.captureSequenceNumber;
        end

        function tf = hasOpenEpochTransitionCapture(obj)
            tf = obj.epochTransitionCaptureOpen_;
        end

        function applyDeclaredExternalCovarianceWrite(obj, xPosterior, PPosterior, nominalQuatPosterior)
            % applyDeclaredExternalCovarianceWrite  The ONE sanctioned external write path for
            % obj.x/obj.P/obj.nominalQuat_wxyz outside predict()/update() (used by
            % revgnss.IndependentFleetCoordinator.applyOneLinkUpdate_ in place of three direct
            % field assignments). Re-seeds the watermark so takeEpochTransitionCapture does not
            % false-trip on this sanctioned write. Byte-identical to the pre-Stage-3.1 direct
            % assignments when retainEpochTransitionOperators is false.
            obj.x = xPosterior;
            obj.P = PPosterior;
            obj.nominalQuat_wxyz(:,1) = nominalQuatPosterior;
            if obj.retainEpochTransitionOperators
                obj.covarianceAtLastAccountedWrite_ = obj.P;
            end
        end
    end

    methods (Static)
        function [B, ok] = rtnBasis_(r_ecef, v_ecef)
            % rtnBasis_  [3x3] ECEF<-RTN rotation whose columns are the radial,
            %   along-track and cross-track unit vectors, using the SAME
            %   v_eff = v_ecef + omega x r convention as OrbitFrame.ecefToRacGeo, so the
            %   empirical-acceleration state is directly comparable with the RAC error
            %   and sigma plots. B * a_RTN resolves the acceleration onto ECEF axes.
            B = eye(3); ok = false;
            w = 7.2921150e-5;
            try; w = revgnss.Constants.EARTH_OMEGA_RADPS; catch; end
            veff = v_ecef(:) + cross([0;0;w], r_ecef(:));
            [rH, aH, hH, okB] = revgnss.OrbitFrame.racBasis(r_ecef(:), veff);
            if ~okB; return; end
            B = [rH, aH, hH];
            ok = true;
        end

        function [c1, c2, phi] = gmAccelIntegrals_(dt_s, tau_s)
            % gmAccelIntegrals_  Exact one-step integrals of a first-order Gauss-Markov
            %   acceleration a(t) = a0*exp(-t/tau):
            %     phi = exp(-dt/tau)                              state decay
            %     c1  = int_0^dt  a/a0 ds     = tau*(1-phi)        -> dt       as tau->inf
            %     c2  = int_0^dt (dt-s) a/a0  = tau*(dt - c1)      -> dt^2/2   as tau->inf
            %   Using the exact integrals (rather than dt and dt^2/2) keeps the state
            %   propagation, the STM column and the GM decay mutually consistent instead
            %   of only agreeing in the small-dt limit.
            %
            %   NUMERICS. The textbook forms tau*(1-phi) and tau*(dt - c1) both cancel
            %   catastrophically in the operating regime here (dt=1 s, tau=1800 s gives
            %   r = 5.6e-4). c1 is cured exactly by expm1. c2 = tau^2*(r + expm1(-r)) has
            %   no library equivalent, so below r = 0.1 it uses the series
            %     c2 = (dt^2/2) * (1 - r/3 + r^2/12 - r^3/60 + r^4/360 - r^5/2520)
            %   whose truncation error is ~r^6/20160 < 5e-11 at the switch point, while
            %   above r = 0.1 the closed form loses only ~eps/r ~ 2e-15. Verified against
            %   quadrature in tests/test_empirical_accel_states.m (T2).
            if ~(tau_s > 0) || ~isfinite(tau_s)
                phi = 1; c1 = dt_s; c2 = 0.5 * dt_s^2; return;
            end
            ratio = dt_s / tau_s;
            phi   = exp(-ratio);
            c1    = -tau_s * expm1(-ratio);          % = tau*(1-phi), cancellation-free
            if ratio < 0.1
                c2 = (dt_s^2 / 2) * (1 - ratio/3 + ratio^2/12 - ratio^3/60 ...
                                       + ratio^4/360 - ratio^5/2520);
            else
                c2 = tau_s * (dt_s - c1);
            end
        end

        function s = emptyEpochTransition()
            % emptyEpochTransition  Frozen field set for the epoch-transition retention struct
            % (plan Stage 3.1): the pendingEpochTransition_ property default, and the schema
            % every predict()/update()-populated struct matches.
            s = struct( ...
                'predictApplied',false, ...
                'intervalStartCoordinateEpoch_s',NaN, ...
                'intervalDuration_s',NaN, ...
                'localStateDimension',0, ...
                'stateTransition',[], ...
                'processNoise',[], ...
                'localUpdateContraction',[], ...
                'accountedUpdateCallCount',0, ...
                'accountedMeasurementRowCount',0, ...
                'benignDiagonalNudgeCount',0, ...
                'unmodelledCovarianceTransformCount',0, ...
                'unmodelledCovarianceTransformKinds',{{}}, ...
                'captureSequenceNumber',0);
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
