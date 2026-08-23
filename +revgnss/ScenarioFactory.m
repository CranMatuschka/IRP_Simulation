classdef ScenarioFactory
    % ScenarioFactory  Builds concrete simulation objects from a config struct.
    %
    % Usage:
    %   cfg    = revgnss.ConfigFactory.defaultConfig();
    %   [asset, towers, ekf, measModel, errorChain, orbitProp] = ...
    %       revgnss.ScenarioFactory.build(cfg);

    methods (Static)

        function [asset, towers, ekf, measModel, errorChain, orbitProp] = build(cfg)
            % build  Instantiate all simulation objects from cfg.
            %
            % Calls finalizeConfig first to resolve nTowers/nReceivers,
            % set lever arms, and recreate per-tower/receiver clocks.

            cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
            revgnss.validateConfig(cfg);

            % --- Orbit propagator --------------------------------------
            orbitProp = [];
            if isfield(cfg,'orbit') && isfield(cfg.orbit,'useOrbitPropagator') ...
                    && cfg.orbit.useOrbitPropagator
                orbitProp = models.orbit.OrbitPropagator(cfg.orbit);
                [r0, v0]  = orbitProp.propagate(0);
                cfg.asset.r_ecef_m   = r0;
                cfg.asset.v_ecef_mps = v0;
            end

            % --- Space asset -------------------------------------------
            asset = revgnss.SpaceAsset(cfg.asset);

            % --- Ground towers -----------------------------------------
            nT = numel(cfg.towers);
            towers = cell(1, nT);
            for k = 1:nT
                towers{k} = revgnss.GroundTower(cfg.towers(k));
            end

            % --- ErrorChain --------------------------------------------
            % Pass the full cfg so ErrorChain can access signals, measurements,
            % environment, and scenario fields alongside cfg.errors.
            errorChain = models.errors.ErrorChain(cfg, cfg.simulation.seed);

            % --- MeasurementModel --------------------------------------
            measModel = models.measurements.MeasurementModel(cfg, errorChain);

            % --- EKF ---------------------------------------------------
            ekf = filter.ReverseGNSSEKF(cfg, nT, asset.clock);

            % Build initial state from truth + perturbation
            x0 = revgnss.ScenarioFactory.buildInitialState_(cfg, asset, towers, ekf);
            P0 = revgnss.ScenarioFactory.buildInitialCovariance_(cfg, ekf);
            ekf.initState(x0, P0);

            % Precompute clock noise
            dt   = cfg.simulation.dt_s;
            dur  = cfg.simulation.duration_s;
            tVec = 0 : dt : dur;

            masterSpan = revgnss.ScenarioFactory.clockNoiseMasterSpan(cfg);
            asset.clock.noiseMasterSpan_s = masterSpan;
            asset.clock.precomputeNoise(tVec);
            for k = 1:nT
                towers{k}.clock.noiseMasterSpan_s = masterSpan;
                towers{k}.clock.precomputeNoise(tVec);
            end
        end

        % ----------------------------------------------------------------
        function span_s = clockNoiseMasterSpan(cfg)
            % clockNoiseMasterSpan  Resolve cfg.clock.noiseMasterSpan to the span that
            % ClockModel should synthesise its colour on. 0 means "the run's own grid",
            % the legacy behaviour in which the realisation depends on the arc length.
            %
            % Deliberately NOT derived from cfg.simulation.duration_s: a span that
            % tracks the run length is exactly the defect the gate removes.
            span_s = 0;
            if ~isfield(cfg,'clock') || ~isfield(cfg.clock,'noiseMasterSpan'); return; end
            nms = cfg.clock.noiseMasterSpan;
            if ~isfield(nms,'enable') || ~nms.enable; return; end
            if ~isfield(nms,'span_s') || ~isscalar(nms.span_s) || ~(nms.span_s > 0)
                error('ScenarioFactory:clockNoiseMasterSpan', ...
                    ['clock.noiseMasterSpan.enable is true but span_s is missing or ' ...
                     'non-positive. Set it to the longest arc the campaign will use.']);
            end
            span_s = double(nms.span_s);
        end

        % ----------------------------------------------------------------
        function x0 = buildInitialState_(cfg, asset, towers, ekf)
            % Build EKF initial state from truth + configured perturbation.
            sm = ekf.stateMap;
            x0 = zeros(ekf.nx, 1);

            % Use cfg.estimator.initialError if available (controlled offsets).
            % Fall back to random P0-scaled draws if not configured.
            if isfield(cfg.estimator, 'initialError')
                ie = cfg.estimator.initialError;
                pos_pert  = ie.pos_m(:);
                vel_pert  = ie.vel_mps(:);
                eul_pert  = ie.euler_deg(:) * pi / 180;
                omg_pert  = ie.omega_radps(:);
                clk_pert  = ie.clockBias_m;
                cdot_pert = ie.clockDrift_mps;
            else
                % Deterministic fallback: seeded RNG so results are reproducible.
                rngFb = RandStream('mt19937ar', 'Seed', cfg.simulation.seed + 7777);
                pos_pert  = cfg.estimator.P0_pos_m      * randn(rngFb, 3, 1);
                vel_pert  = cfg.estimator.P0_vel_mps    * randn(rngFb, 3, 1);
                eul_pert  = cfg.estimator.P0_euler_rad  * randn(rngFb, 3, 1);
                omg_pert  = cfg.estimator.P0_omega_radps * randn(rngFb, 3, 1);
                clk_pert  = cfg.estimator.P0_bRx_m      * randn(rngFb, 1, 1);
                cdot_pert = cfg.estimator.P0_bdotRx_mps * randn(rngFb, 1, 1);
            end

            x0(sm.r_idx)     = asset.r_ecef_m + pos_pert;
            x0(sm.v_idx)     = asset.v_ecef_mps + vel_pert;
            x0(sm.euler_idx) = asset.attitude_euler_rad + eul_pert;
            x0(sm.omega_idx) = asset.angularRate_body_radps + omg_pert;

            % The clock STATES are seeded in the estimator's own domain. When the model
            % applies the published relativistic correction the states carry only the
            % oscillator's RESIDUAL, so the modelled term must come off the truth value
            % here too. Both terms are exactly 0 when relativity.clock.model is off.
            %
            % The drift seed is the sharp one: getDriftMetersPerSecond() now includes
            % c*y_rel = 0.1615 m/s (the truth-side fix), while P0 on that state is of
            % order 1e-3 m/s. Seeding the full value against a residual-domain state would
            % open the run ~160 sigma out and produce a transient that looks exactly like a
            % filter defect. t = 0 at initialisation, so the bias term is identically zero
            % and this line is unchanged for the bias.
            relBias0_m  = models.clocks.RelativisticClockCorrection.bias_m(cfg, 0);
            relRate0_mps = models.clocks.RelativisticClockCorrection.rate_mps(cfg);
            x0(sm.b_rx_idx)    = asset.clock.getBiasMeters() - relBias0_m + clk_pert;
            x0(sm.bdot_rx_idx) = asset.clock.getDriftMetersPerSecond() - relRate0_mps + cdot_pert;

            if ekf.jointMultiAssetEnabled
                c_mps = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                [secondaryPosSigma,secondaryVelSigma,secondaryClockSigma, ...
                    secondaryClockDriftSigma] = ...
                    revgnss.ScenarioFactory.secondaryInitialSigmas_(cfg);
                for assetIdx = 2:ekf.nSpaceAssets
                    blk = sm.asset(assetIdx);
                    assetCfg = cfg.assets(assetIdx);
                    if isfield(cfg.estimator,'initialError')
                        positionError = pos_pert;
                        velocityError = vel_pert;
                        attitudeError = eul_pert;
                        rateError = omg_pert;
                        clockError = clk_pert;
                        driftError = cdot_pert;
                    else
                        assetStream = RandStream('mt19937ar','Seed', ...
                            cfg.simulation.seed + 8700 + assetIdx);
                        positionError = secondaryPosSigma*randn(assetStream,3,1);
                        velocityError = secondaryVelSigma*randn(assetStream,3,1);
                        attitudeError = cfg.estimator.P0_euler_rad*randn(assetStream,3,1);
                        rateError = cfg.estimator.P0_omega_radps*randn(assetStream,3,1);
                        clockError = secondaryClockSigma*randn(assetStream,1,1);
                        driftError = secondaryClockDriftSigma*randn(assetStream,1,1);
                    end
                    x0(blk.r) = assetCfg.r_ecef_m(:) + positionError;
                    x0(blk.v) = assetCfg.v_ecef_mps(:) + velocityError;
                    x0(blk.euler) = assetCfg.attitude_euler_rad(:) + attitudeError;
                    x0(blk.omega) = assetCfg.angularRate_body_radps(:) + rateError;
                    clockBias = 0;
                    clockDrift = 0;
                    try; clockBias = assetCfg.clock.bias_s*c_mps; catch; end
                    try; clockDrift = assetCfg.clock.fracFreq*c_mps; catch; end
                    x0(blk.b) = clockBias + clockError;
                    x0(blk.bdot) = clockDrift + driftError;
                end
            end

            if ekf.estimateTowerClocks
                % Draw the tower-clock init from the SAME P0 the filter is told
                % it has, so the initial tower-clock NEES is O(1) instead of exactly 0
                % (exact-truth init against a 1000 m / 10 m/s stated sigma drove a
                % meaningless NEES and a covariance transient). Dedicated seeded stream
                % -> reproducible and independent of the other RNG streams.
                [sigma_b_twr, sigma_bd_twr] = revgnss.ScenarioFactory.towerClockInitSigmas_();
                rngTwr = RandStream('mt19937ar', 'Seed', cfg.simulation.seed + 8600);
                for ti = 1:ekf.nTowers
                    idx_b    = sm.towerClockIdx(ti,1);
                    idx_bdot = sm.towerClockIdx(ti,2);
                    x0(idx_b)    = towers{ti}.getClockBiasMeters()           + sigma_b_twr  * randn(rngTwr);
                    x0(idx_bdot) = towers{ti}.getClockDriftMetersPerSecond() + sigma_bd_twr * randn(rngTwr);
                end
            end

            % SRP scale-coefficient state: deterministic nominal init (no seeded draw). The
            % truth SRP is applied truth-side with a fixed Cr, so the "truth s" is 1.0 by
            % construction; initScale=1.0 gives zero initial error for this parameter state.
            if ekf.estimateSrpScale && isfield(sm,'srpScaleIdx') && ~isempty(sm.srpScaleIdx)
                initScale = 1.0;
                try; initScale = cfg.estimator.srpCoefficient.initScale; catch; end
                x0(sm.srpScaleIdx) = initScale;
            end
        end

        function [sigma_b_m, sigma_bdot_mps] = towerClockInitSigmas_()
            % towerClockInitSigmas_  Single source for the tower-clock P0 1-sigma,
            % shared by buildInitialState_ (seeded init perturbation) and
            % buildInitialCovariance_ (stated covariance) so they cannot drift apart.
            % Only reached when estimateTowerClocks=true.
            sigma_b_m      = 1e3;   % 1000 m  initial tower clock-bias uncertainty
            sigma_bdot_mps = 1e1;   % 10 m/s  initial tower clock-drift uncertainty
        end

        function [positionSigma_m,velocitySigma_mps,clockSigma_m, ...
                clockDriftSigma_mps] = secondaryInitialSigmas_(cfg)
            positionSigma_m = cfg.estimator.P0_pos_m;
            velocitySigma_mps = cfg.estimator.P0_vel_mps;
            clockSigma_m = cfg.estimator.P0_bRx_m;
            clockDriftSigma_mps = cfg.estimator.P0_bdotRx_mps;
            try
                value = cfg.multiAsset.secondaryOrbit.initSigmaPos_m;
                if isscalar(value) && isfinite(value) && value >= 0
                    positionSigma_m = value;
                end
            catch
            end
            try
                value = cfg.multiAsset.secondaryOrbit.initSigmaVel_mps;
                if isscalar(value) && isfinite(value) && value >= 0
                    velocitySigma_mps = value;
                end
            catch
            end
            try
                value = cfg.multiAsset.secondaryClock.initSigma_m;
                if isscalar(value) && isfinite(value) && value >= 0
                    clockSigma_m = value;
                end
            catch
            end
            try
                value = cfg.multiAsset.secondaryClock.initSigmaDrift_mps;
                if isscalar(value) && isfinite(value) && value >= 0
                    clockDriftSigma_mps = value;
                end
            catch
            end
        end

        function P0 = buildInitialCovariance_(cfg, ekf)
            sm = ekf.stateMap;
            nx = ekf.nx;
            P0 = zeros(nx);

            for k=1:3; P0(sm.r_idx(k),   sm.r_idx(k))   = cfg.estimator.P0_pos_m^2;    end
            for k=1:3; P0(sm.v_idx(k),   sm.v_idx(k))   = cfg.estimator.P0_vel_mps^2;  end
            for k=1:3; P0(sm.euler_idx(k),sm.euler_idx(k))= cfg.estimator.P0_euler_rad^2; end
            for k=1:3; P0(sm.omega_idx(k),sm.omega_idx(k))= cfg.estimator.P0_omega_radps^2; end

            P0(sm.b_rx_idx,    sm.b_rx_idx)    = cfg.estimator.P0_bRx_m^2;
            P0(sm.bdot_rx_idx, sm.bdot_rx_idx) = cfg.estimator.P0_bdotRx_mps^2;

            if ekf.jointMultiAssetEnabled
                [secondaryPosSigma,secondaryVelSigma,secondaryClockSigma, ...
                    secondaryClockDriftSigma] = ...
                    revgnss.ScenarioFactory.secondaryInitialSigmas_(cfg);
                for assetIdx = 2:ekf.nSpaceAssets
                    blk = sm.asset(assetIdx);
                    P0(blk.r,blk.r) = eye(3)*secondaryPosSigma^2;
                    P0(blk.v,blk.v) = eye(3)*secondaryVelSigma^2;
                    P0(blk.euler,blk.euler) = eye(3)*cfg.estimator.P0_euler_rad^2;
                    P0(blk.omega,blk.omega) = eye(3)*cfg.estimator.P0_omega_radps^2;
                    P0(blk.b,blk.b) = secondaryClockSigma^2;
                    P0(blk.bdot,blk.bdot) = secondaryClockDriftSigma^2;
                    if ekf.estimateGyroBias && ~isempty(blk.gyroBias)
                        P0(blk.gyroBias,blk.gyroBias) = ...
                            eye(3)*ekf.imuP0Bias_^2;
                    end
                end
            end

            if ekf.estimateTowerClocks
                % Shared with buildInitialState_ so the stated 1-sigma and the initial
                % perturbation cannot drift apart.
                [sigma_b_twr, sigma_bd_twr] = revgnss.ScenarioFactory.towerClockInitSigmas_();
                for ti = 1:ekf.nTowers
                    idx_b    = sm.towerClockIdx(ti,1);
                    idx_bdot = sm.towerClockIdx(ti,2);
                    P0(idx_b,    idx_b)    = sigma_b_twr^2;
                    P0(idx_bdot, idx_bdot) = sigma_bd_twr^2;
                end
            end

            % Multipath bias initial covariance: the process is stationary, so the honest
            % prior at t = 0 IS its steady-state variance. Starting at zero mean with
            % sigma_ss reproduces the truth chain, which also starts at x = 0 and relaxes
            % into the stationary distribution. The zenith value is used because no
            % elevation is known before the first measurement build.
            if ekf.estimateMultipathBias && isfield(sm,'mpBiasIdx')
                for ti = 1:ekf.nTowers
                    for si = 1:size(sm.mpBiasIdx,2)
                        idxMp = sm.mpBiasIdx(ti,si);
                        if idxMp > 0
                            P0(idxMp, idxMp) = ekf.mpBiasSigmaSs_^2;
                        end
                    end
                end
            end

            % TASK 1: float ambiguity initial covariance
            if ekf.estimateAmbiguities
                sigma0_amb = 100.0;
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguity') && ...
                        isfield(cfg.estimation.ambiguity,'initialSigma_m')
                    sigma0_amb = cfg.estimation.ambiguity.initialSigma_m;
                end
                if isfield(sm,'ambiguityIdx3d') && ~isempty(sm.ambiguityIdx3d)
                    % New mode: tower/receiver/signal
                    idxMat = sm.ambiguityIdx3d;
                    for k = 1:numel(idxMat)
                        idx_k = idxMat(k);
                        if idx_k > 0; P0(idx_k, idx_k) = sigma0_amb^2; end
                    end
                elseif isfield(sm,'ambiguityIdx') && ~isempty(sm.ambiguityIdx)
                    % Legacy mode: tower/signal
                    idxMat = sm.ambiguityIdx;
                    for k = 1:numel(idxMat)
                        idx_k = idxMat(k);
                        if idx_k > 0; P0(idx_k, idx_k) = sigma0_amb^2; end
                    end
                end
            end

            % ISL carrier-ambiguity initial covariance. Uses its OWN sigma
            % (cfg.measurements.isl.carrier.ambiguity.initialSigma_m), deliberately NOT
            % cfg.estimation.ambiguity.initialSigma_m: that ground knob also drives the
            % truth ambiguity draw and the cycle-slip reset, so sharing it would couple
            % three unrelated sinks and make an ISL-only change move the ground solution.
            % Without this branch the ISL states would keep P0 = 0 from zeros(nx) -> zero
            % Kalman gain -> the ambiguity could never be estimated.
            if ekf.estimateIslAmbiguities && isfield(sm,'islAmbiguityIdx') && ...
                    ~isempty(sm.islAmbiguityIdx)
                sigma0_isl = 100.0;
                try
                    sigma0_isl = cfg.measurements.isl.carrier.ambiguity.initialSigma_m;
                catch; end
                for k = 1:numel(sm.islAmbiguityIdx)
                    idx_k = sm.islAmbiguityIdx(k);
                    if idx_k > 0; P0(idx_k, idx_k) = sigma0_isl^2; end
                end
            end

            % TASK 1: ZWD initial covariance (one per tower)
            if ekf.estimateZwd && isfield(sm,'zwdIdx') && ~isempty(sm.zwdIdx)
                sigma0_zwd = 0.10;
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'tropoZwd') && ...
                        isfield(cfg.estimation.tropoZwd,'initialSigma_m')
                    sigma0_zwd = cfg.estimation.tropoZwd.initialSigma_m;
                end
                for k = 1:numel(sm.zwdIdx)
                    idx_k = sm.zwdIdx(k);
                    if idx_k > 0
                        P0(idx_k, idx_k) = sigma0_zwd^2;
                    end
                end
            end

            % Slant-ionosphere initial covariance (one per tower, prototype)
            if ekf.estimateIono && isfield(sm,'ionoIdx') && ~isempty(sm.ionoIdx)
                sigma0_iono = 5.0;   % [m] generous prior on the L1 slant iono
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'slantIono') && ...
                        isfield(cfg.estimation.slantIono,'initialSigma_m')
                    sigma0_iono = cfg.estimation.slantIono.initialSigma_m;
                end
                for k = 1:numel(sm.ionoIdx)
                    idx_k = sm.ionoIdx(k);
                    if idx_k > 0
                        P0(idx_k, idx_k) = sigma0_iono^2;
                    end
                end
            end

            % TASK 2: Tx-code-bias initial covariance (one per tower)
            if ekf.estimateTxCodeBias && isfield(sm,'txCodeBiasIdx') && ~isempty(sm.txCodeBiasIdx)
                sigma0_tx = 10.0;
                if isfield(cfg,'hardware') && isfield(cfg.hardware,'txCodeBias') && ...
                        isfield(cfg.hardware.txCodeBias,'initialSigma_m')
                    sigma0_tx = cfg.hardware.txCodeBias.initialSigma_m;
                end
                for k = 1:numel(sm.txCodeBiasIdx)
                    idx_k = sm.txCodeBiasIdx(k);
                    if idx_k > 0
                        P0(idx_k, idx_k) = sigma0_tx^2;
                    end
                end
            end

            % Gyro-bias initial covariance (IMU/MEKF). The filter's prior on b_g -- NOT the truth
            % bias (which stays unknown to the filter). Zero here would wrongly assert perfect
            % knowledge, so it must be the configured 1-sigma. No-op when the block is absent.
            if ekf.estimateGyroBias && isfield(sm,'gyroBiasIdx') && ~isempty(sm.gyroBiasIdx)
                for k = 1:numel(sm.gyroBiasIdx)
                    P0(sm.gyroBiasIdx(k), sm.gyroBiasIdx(k)) = ekf.imuP0Bias_^2;
                end
            end

            % SRP scale-coefficient prior variance (dimensionless).
            if ekf.estimateSrpScale && isfield(sm,'srpScaleIdx') && ~isempty(sm.srpScaleIdx)
                initSigma = 0.1;
                try; initSigma = cfg.estimator.srpCoefficient.initSigma; catch; end
                P0(sm.srpScaleIdx, sm.srpScaleIdx) = initSigma^2;
            end

            % Empirical RTN acceleration prior variance [m^2/s^4]. Zero here would assert
            % perfect knowledge that the force model is exact, which is the very thing the
            % state exists to deny, so it must be the configured 1-sigma.
            if ekf.estimateEmpiricalAccel && isfield(sm,'empAccIdx') && ~isempty(sm.empAccIdx)
                initSigmaAcc = 1e-7;
                try; initSigmaAcc = cfg.estimator.empiricalAccel.initialSigma_mps2; catch; end
                % States are normalised to ekf.empAccScale_ (= sigma_ss), so the prior
                % must be expressed in the same units.
                sigma0Scaled = initSigmaAcc / ekf.empAccScale_;
                for k = 1:numel(sm.empAccIdx)
                    P0(sm.empAccIdx(k), sm.empAccIdx(k)) = sigma0Scaled^2;
                end
            end
            if ekf.estimateTwoWayCodeCalibrationBias && ...
                    isfield(sm,'twoWayCodeCalibrationBiasIdx') && ...
                    ~isempty(sm.twoWayCodeCalibrationBiasIdx)
                sigmaTurnaround_s = ...
                    cfg.measurements.isl.twoWay.calibration.turnaroundSigma_s;
                sigmaTerminal_s = ...
                    cfg.measurements.isl.twoWay.calibration.terminalSigma_s;
                sigmaBias_m = 0.5*revgnss.Constants.SPEED_OF_LIGHT_MPS * ...
                    hypot(sigmaTurnaround_s,sigmaTerminal_s);
                indices = sm.twoWayCodeCalibrationBiasIdx;
                P0(indices,indices) = sigmaBias_m^2*eye(numel(indices));
            end
        end
    end
end
