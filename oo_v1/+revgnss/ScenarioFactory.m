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
            ekf = revgnss.ReverseGNSSEKF(cfg, nT, asset.clock);

            % Build initial state from truth + perturbation
            x0 = revgnss.ScenarioFactory.buildInitialState_(cfg, asset, towers, ekf);
            P0 = revgnss.ScenarioFactory.buildInitialCovariance_(cfg, ekf);
            ekf.initState(x0, P0);

            % Precompute clock noise
            dt   = cfg.simulation.dt_s;
            dur  = cfg.simulation.duration_s;
            tVec = 0 : dt : dur;

            asset.clock.precomputeNoise(tVec);
            for k = 1:nT
                towers{k}.clock.precomputeNoise(tVec);
            end
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

            x0(sm.b_rx_idx)    = asset.clock.getBiasMeters() + clk_pert;
            x0(sm.bdot_rx_idx) = asset.clock.getDriftMetersPerSecond() + cdot_pert;

            if ekf.estimateTowerClocks
                for ti = 1:ekf.nTowers
                    idx_b    = sm.towerClockIdx(ti,1);
                    idx_bdot = sm.towerClockIdx(ti,2);
                    x0(idx_b)    = towers{ti}.getClockBiasMeters();
                    x0(idx_bdot) = towers{ti}.getClockDriftMetersPerSecond();
                end
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

            if ekf.estimateTowerClocks
                sigma_b_twr = 1e3;  % 1000 m initial tower clock uncertainty
                sigma_bd_twr = 1e1;
                for ti = 1:ekf.nTowers
                    idx_b    = sm.towerClockIdx(ti,1);
                    idx_bdot = sm.towerClockIdx(ti,2);
                    P0(idx_b,    idx_b)    = sigma_b_twr^2;
                    P0(idx_bdot, idx_bdot) = sigma_bd_twr^2;
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
        end
    end
end
