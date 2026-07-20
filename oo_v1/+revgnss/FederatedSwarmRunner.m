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
            % 3-D formation by default: the classic CW projected-circular helix is PLANAR (z=2x), so
            % its out-of-plane shape is only 2nd-order observable from ranging. A cross-track spread
            % fans the members over distinct z:x ratios -> a non-degenerate 3-D formation whose FULL
            % shape is first-order observable by the W2 relative layer. Only defaulted when the caller
            % has not set it (respects an explicit override); the joint/fingerprint path never runs
            % through here, so it keeps crossTrackSpread absent -> 0 -> planar -> byte-identical.
            if ~isfield(cfg,'formation') || ~isfield(cfg.formation,'crossTrackSpread')
                cfg.formation.crossTrackSpread = 1.0;
            end
            op = models.orbit.OrbitPropagator(cfg.orbit);
            [r0Cells, v0Cells] = revgnss.SwarmFormation.secondaryEciInitialStates(cfg, op);

            baseSeed = 42;
            if isfield(base,'simulation') && isfield(base.simulation,'seed'); baseSeed = base.simulation.seed; end
            for ai = 1:N
                ci = base;
                if ai >= 2
                    si = ai - 1;
                    ci.orbit.eciState0  = [r0Cells{si}; v0Cells{si}];   % this asset's absolute helix IC
                    ci.asset.clock.seed = 300 + ai;                     % per-asset sat clock (swarm convention)
                    % PHYSICAL per-asset noise split: offset the measurement-noise master seed so each
                    % asset's RECEIVER-side noise (code/carrier/Doppler thermal + path atmosphere, all
                    % rooted at simulation.seed via ErrorChain->RngRegistry) is INDEPENDENT. The clock
                    % TRUTHS keep their absolute seeds -- tower 200+k stays COMMON across assets (one
                    % transmitted signal, reverse-GNSS), sat clock is per-asset (300+ai). Asset 1 keeps
                    % the base seed untouched -> byte-identical to the single-asset golden. Without this,
                    % all assets share one noise realization -> artificially common-mode -> the swarm
                    % shape is unphysically sub-mm and the ISL relative layer has nothing to sharpen.
                    ci.simulation.seed = baseSeed + 100000*(ai-1);
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
                if isfield(c.multiAsset,'twoWayTimeTransferISL'); c.multiAsset.twoWayTimeTransferISL.enable = false; end
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

            % Per-epoch flown truth (this asset's OWN absolute trajectory) for the W2 relative
            % layer. Read straight from the sim's orbit truth cache -> the EXACT truth this asset
            % flew (no reconstruction/drift). Empty when the propagator/cache is off (never for a
            % federated N>1 run, which requires useOrbitPropagator). Adds output fields only -> the
            % EKF path is untouched, so N=1 byte-identity and all goldens are unaffected.
            if sim.orbitTruthCache.enabled
                res.truthTraj    = sim.orbitTruthCache.r_ecef_m;     % [3 x nEp] ECEF
                res.truthVelTraj = sim.orbitTruthCache.v_ecef_mps;   % [3 x nEp] ECEF
                res.truthTime_s  = sim.orbitTruthCache.t_s(:).';     % [1 x nEp]
            else
                res.truthTraj = []; res.truthVelTraj = []; res.truthTime_s = [];
            end

            % Per-epoch TOTAL truth clock bias (state + colored + any relativistic ramp), for the W2
            % relative-clock layer (W2-2). Read from the clock's own logged history -> the exact truth
            % this asset's clock realized. Output field only -> EKF path untouched / byte-identical.
            res.truthClkTraj_m = []; res.truthClkTime_s = [];
            try
                clkHist = sim.asset.clock.history;   % ClockModel is an object; access the property
                if ~isempty(clkHist.bias_s)
                    c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                    res.truthClkTraj_m = clkHist.bias_s(:).' * c;   % [1 x nEpClk] TOTAL truth bias
                    res.truthClkTime_s = clkHist.time_s(:).';        % [1 x nEpClk]
                end
            catch
            end
        end
    end
end
