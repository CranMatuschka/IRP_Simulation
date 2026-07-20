classdef FederatedSwarmRunner
    % FederatedSwarmRunner  Instance layer of the federated swarm architecture (W1).
    %
    % Runs N INDEPENDENT single-asset EKFs -- one per satellite -- instead of one joint
    % primary-centric EKF. Each asset estimates its OWN absolute state from the tower signals it
    % receives (reverse-GNSS uplink), exactly like a standalone single-asset run. There is NO chief:
    % every instance is byte-identically the same single-asset filter, differing only in its truth
    % trajectory (its slot in the helix formation) and its clock seed. ISL/TWSTFT are NOT fused here
    % -- they belong to the separate relative layer (W2) -- so no shared covariance exists and the
    % joint-filter's two-way-ISL divergence structurally cannot occur.
    %
    %   results = revgnss.FederatedSwarmRunner.run(cfg)
    %       results.N            number of assets
    %       results.asset{ai}    per-asset estimate: .x .P .stateMap .history .truthR/.truthV/.truthClk
    %                            .posErr (|est-truth| at final epoch)
    %
    % INVARIANT: at nSpaceAssets=1, results.asset{1} is byte-identical to a direct single-asset
    % ReverseGNSSSimulation(cfg) run (asset 1 uses cfg.asset unchanged). See
    % docs/federated_swarm_architecture.md.

    methods (Static)
        function results = run(cfg)
            N = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets')
                N = max(1, round(cfg.scenario.nSpaceAssets));
            end
            base = revgnss.FederatedSwarmRunner.singleAssetBase_(cfg);

            results = struct('N', N, 'asset', {cell(1, N)});
            if N == 1
                results.asset{1} = revgnss.FederatedSwarmRunner.runOne_(base);
                return;
            end

            % --- Per-asset TRUTH injection (assets 2..N) -----------------------------------------
            % Each asset runs its OWN single-asset EKF on its OWN absolute helix orbit. The truth IC
            % does not come from cfg.asset.r_ecef_m (ScenarioFactory overwrites it from cfg.orbit), so
            % we inject asset ai's helix ECI initial state via cfg_i.orbit.eciState0 -- the same r0/v0
            % SwarmFormation propagates for the joint-swarm truth. Asset 1 (chief) keeps cfg.orbit
            % unchanged -> its truth is byte-identical to the golden single-asset. No shared covariance
            % exists between the N runs; ISL/TWSTFT are the separate relative layer (W2).
            if ~(isfield(cfg,'orbit') && isfield(cfg.orbit,'useOrbitPropagator') && cfg.orbit.useOrbitPropagator)
                error('revgnss:FederatedSwarmRunner:needsOrbitPropagator', ...
                    ['Federated N>1 needs cfg.orbit.useOrbitPropagator=true: the per-asset helix ' ...
                     'formation truth is built from the orbit propagator (elements IC).']);
            end
            op = models.orbit.OrbitPropagator(cfg.orbit);
            [r0Cells, v0Cells] = revgnss.SwarmFormation.secondaryEciInitialStates(cfg, op);

            for ai = 1:N
                ci = base;
                if ai >= 2
                    si = ai - 1;
                    ci.orbit.eciState0  = [r0Cells{si}; v0Cells{si}];   % this asset's absolute helix IC
                    ci.asset.clock.seed = 300 + ai;                     % per-asset clock (swarm convention)
                end
                results.asset{ai} = revgnss.FederatedSwarmRunner.runOne_(ci);
            end
        end
    end

    methods (Static, Access = private)
        function base = singleAssetBase_(cfg)
            % A single-asset config: one estimated asset, no swarm/ISL/secondary machinery (ISL/TWSTFT
            % are the relative layer, not per-asset EKF rows). For a config that is already single-asset
            % (secondary estimation off, the golden default) this is a no-op -> N=1 byte-identical.
            base = revgnss.FederatedSwarmRunner.stripSwarmEstimation_(cfg);
            base.scenario.nSpaceAssets = 1;
        end

        function c = stripSwarmEstimation_(cfg)
            % Disable every secondary-ESTIMATION toggle (carrier/atmosphere/ZWD), ISL, two-way ISL and
            % tower->secondary observation, and set multiAsset.mode='fast' (passthrough). Truth-side
            % (SwarmFormation, orbit propagator) is untouched. Golden single-asset config -> unchanged.
            c = cfg;
            if isfield(c,'multiAsset')
                c.multiAsset.mode = 'fast';
                c.multiAsset.towersObserveSecondaries = false;
                if isfield(c.multiAsset,'twoWayISL'); c.multiAsset.twoWayISL.enable = false; end
                if isfield(c.multiAsset,'towerSecondary')
                    ts = c.multiAsset.towerSecondary;
                    if isfield(ts,'carrier');    ts.carrier.enable = false;    end
                    if isfield(ts,'atmosphere');  ts.atmosphere.enable = false;  end
                    if isfield(ts,'doppler');     ts.doppler.enable = false;     end
                    if isfield(ts,'estimateAtmosphere'); ts.estimateAtmosphere = false; end
                    if isfield(ts,'attitude');    ts.attitude.enable = false;    end
                    if isfield(ts,'multiAntenna'); ts.multiAntenna.enable = false; end
                    c.multiAsset.towerSecondary = ts;
                end
            end
            if isfield(c,'measurements') && isfield(c.measurements,'isl')
                c.measurements.isl.enable = false;
            end
        end

        function res = runOne_(cfg1)
            sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg1));
            sim.initialize();
            sim.run();
            sm = sim.ekf.stateMap;
            res = struct();
            res.x        = sim.ekf.x;
            res.P        = sim.ekf.P;
            res.stateMap = sm;
            res.history  = sim.ekf.history;
            res.truthR   = sim.asset.r_ecef_m;
            res.truthV   = sim.asset.v_ecef_mps;
            res.truthClk = sim.asset.clock.getBiasMeters();
            res.posErr   = norm(sim.ekf.x(sm.r_idx) - sim.asset.r_ecef_m);
        end
    end
end
