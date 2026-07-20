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

            if ekf.estimateSecondaryClocks
                % WP3: draw the secondary-clock init from the SAME P0 the filter is told
                % it has, so initial NEES is O(1) (mirrors the tower-clock convention).
                % Per-ai identity-keyed stream (seed+8700+ai): adding/removing assets
                % cannot perturb another secondary's draw (upgrade over the tower shared
                % stream). Truth anchor = cfg.assets(ai).clock (seed 300+ai); at t=0
                % coloredBias=0 so config bias_s*c == runtime getBiasMeters() exactly.
                [sb, sbd] = revgnss.ScenarioFactory.secondaryClockInitSigmas_(cfg);
                for si = 1:ekf.nSecondaryClocks
                    ai = si + 1;
                    ib = sm.secondaryClockIdx(si,1);
                    id = sm.secondaryClockIdx(si,2);
                    rngSec = RandStream('mt19937ar', 'Seed', cfg.simulation.seed + 8700 + ai);
                    [b0, bd0] = revgnss.ScenarioFactory.secondaryClockTruthMeters_(cfg, ai);
                    x0(ib) = b0  + sb  * randn(rngSec);
                    x0(id) = bd0 + sbd * randn(rngSec);
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

        function [sigma_b_m, sigma_bdot_mps] = secondaryClockInitSigmas_(cfg)
            % secondaryClockInitSigmas_  Single source for the WP3 secondary-clock P0
            % 1-sigma, shared by the seeded init draw AND the stated P0 so they cannot
            % drift apart (initial NEES O(1)). Loose broadcast-product-class a-priori.
            sigma_b_m      = 100.0;   % [m]
            sigma_bdot_mps = 1.0;     % [m/s]
            try
                if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'secondaryClock')
                    scc = cfg.multiAsset.secondaryClock;
                    if isfield(scc,'initSigma_m')        && scc.initSigma_m > 0;        sigma_b_m      = scc.initSigma_m;        end
                    if isfield(scc,'initSigmaDrift_mps') && scc.initSigmaDrift_mps > 0; sigma_bdot_mps = scc.initSigmaDrift_mps; end
                end
            catch; end
        end

        function [b_m, bdot_mps] = secondaryClockTruthMeters_(cfg, ai)
            % secondaryClockTruthMeters_  t=0 truth anchor for secondary ai, read from
            % the finalized cfg (the runtime SpaceAsset objects do not exist yet at
            % ScenarioFactory time). Valid because coloredBias_s=0 at t=0, so
            % getBiasMeters()==bias_s*c. try/catch -> 0 on any missing field.
            b_m = 0; bdot_mps = 0;
            try
                c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                b_m      = cfg.assets(ai).clock.bias_s   * c;
                bdot_mps = cfg.assets(ai).clock.fracFreq * c;
            catch; end
        end

        function [sigma_b_m, sigma_bdot_mps] = towerClockInitSigmas_()
            % towerClockInitSigmas_  Single source for the tower-clock P0 1-sigma,
            % shared by buildInitialState_ (seeded init perturbation) and
            % buildInitialCovariance_ (stated covariance) so they cannot drift apart.
            % Only reached when estimateTowerClocks=true.
            sigma_b_m      = 1e3;   % 1000 m  initial tower clock-bias uncertainty
            sigma_bdot_mps = 1e1;   % 10 m/s  initial tower clock-drift uncertainty
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

            % --- Phase-2 init unification: secondary-asset P0 priors in ONE per-asset loop ----
            % Consolidates the four separate secondary blocks (WP3 clock, P1'/WP4 orbit, Phase-1
            % carrier ambiguity, Phase-2 ZWD) into a single loop over the sm.asset(i) view. Each
            % field is written only when that state exists for the asset (empty otherwise), so
            % the P0 diagonal is byte-identical to the four-block version. The chief block (asset 1)
            % is untouched above; at nSpaceAssets=1 the view is length 1 -> this loop is skipped.
            if numel(sm.asset) > 1
                [sbClk, sbdClk] = revgnss.ScenarioFactory.secondaryClockInitSigmas_(cfg);
                [spOrb, svOrb]  = revgnss.ScenarioFactory.secondaryOrbitInitSigmas_(cfg);
                sigma0_sa = revgnss.ScenarioFactory.getCfgNum_(cfg, {'multiAsset','towerSecondary','carrier','initialSigma_m'}, 100);
                sigma0_sz = revgnss.ScenarioFactory.getCfgNum_(cfg, {'multiAsset','towerSecondary','zwd','initialSigma_m'}, 0.10);
                for i = 2:numel(sm.asset)
                    a = sm.asset(i);
                    if ~isempty(a.b);    P0(a.b, a.b)       = sbClk^2;  end
                    if ~isempty(a.bdot); P0(a.bdot, a.bdot) = sbdClk^2; end
                    if ~isempty(a.r)
                        for k = 1:3
                            P0(a.r(k), a.r(k)) = spOrb^2;
                            P0(a.v(k), a.v(k)) = svOrb^2;
                        end
                    end
                    for jj = 1:numel(a.ambiguity)
                        P0(a.ambiguity(jj), a.ambiguity(jj)) = sigma0_sa^2;
                    end
                    for jj = 1:numel(a.zwd)
                        P0(a.zwd(jj), a.zwd(jj)) = sigma0_sz^2;
                    end
                end
            end

            % SRP scale-coefficient prior variance (dimensionless).
            if ekf.estimateSrpScale && isfield(sm,'srpScaleIdx') && ~isempty(sm.srpScaleIdx)
                initSigma = 0.1;
                try; initSigma = cfg.estimator.srpCoefficient.initSigma; catch; end
                P0(sm.srpScaleIdx, sm.srpScaleIdx) = initSigma^2;
            end
        end

        function [sigma_pos_m, sigma_vel_mps] = secondaryOrbitInitSigmas_(cfg)
            % secondaryOrbitInitSigmas_  Single source for the P1' secondary-orbit P0
            % 1-sigma (per axis), shared by the seeded init draw (in ReverseGNSSSimulation)
            % and the stated P0 here so they cannot drift apart (initial NEES O(1)).
            sigma_pos_m   = 100.0;
            sigma_vel_mps = 0.1;
            try
                if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'secondaryOrbit')
                    so = cfg.multiAsset.secondaryOrbit;
                    if isfield(so,'initSigmaPos_m')   && so.initSigmaPos_m > 0;   sigma_pos_m   = so.initSigmaPos_m;   end
                    if isfield(so,'initSigmaVel_mps') && so.initSigmaVel_mps > 0; sigma_vel_mps = so.initSigmaVel_mps; end
                end
            catch; end
        end

        function v = getCfgNum_(cfg, path, dflt)
            % getCfgNum_  Safe nested numeric-scalar config read with a default.
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; v = dflt; return; end
            end
            if ~(isnumeric(v) && isscalar(v) && isfinite(v)); v = dflt; end
        end
    end
end
