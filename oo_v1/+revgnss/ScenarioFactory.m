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

            revgnss.validateConfig(cfg);

            % --- Orbit propagator --------------------------------------
            orbitProp = [];
            if isfield(cfg,'orbit') && isfield(cfg.orbit,'useOrbitPropagator') ...
                    && cfg.orbit.useOrbitPropagator
                orbitProp = revgnss.OrbitPropagator(cfg.orbit);
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
            errorChain = revgnss.ErrorChain(cfg.errors, cfg.simulation.seed);

            % --- MeasurementModel --------------------------------------
            measModel = revgnss.MeasurementModel(cfg, errorChain);

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
                pos_pert  = cfg.estimator.P0_pos_m   * randn(3,1);
                vel_pert  = cfg.estimator.P0_vel_mps  * randn(3,1);
                eul_pert  = cfg.estimator.P0_euler_rad * randn(3,1);
                omg_pert  = cfg.estimator.P0_omega_radps * randn(3,1);
                clk_pert  = cfg.estimator.P0_bRx_m    * randn;
                cdot_pert = cfg.estimator.P0_bdotRx_mps * randn;
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
        end
    end
end
