classdef IndependentFleetScenarioFactory
    % IndependentFleetScenarioFactory  Pure per-spacecraft configuration construction.

    methods (Static)
        function setup = federatedSetup(cfg, keepIslInLeaf)
            if nargin < 2; keepIslInLeaf = false; end
            keepIslInLeaf = logical(keepIslInLeaf);

            base = revgnss.IndependentFleetScenarioFactory.singleAssetBase( ...
                cfg, keepIslInLeaf);
            N = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets')
                N = max(1, round(cfg.scenario.nSpaceAssets));
            end

            r0Cells = {};
            v0Cells = {};
            baseSeed = 42;
            if N > 1
                if ~(isfield(cfg,'orbit') && isfield(cfg.orbit,'useOrbitPropagator') && ...
                        cfg.orbit.useOrbitPropagator)
                    error('IndependentFleetScenarioFactory:needsOrbitPropagator', ...
                        'Independent fleet N>1 requires cfg.orbit.useOrbitPropagator=true.');
                end
                op = models.orbit.OrbitPropagator(cfg.orbit);
                [r0Cells, v0Cells] = revgnss.SwarmFormation.secondaryEciInitialStates(cfg, op);
                if isfield(base,'simulation') && isfield(base.simulation,'seed')
                    baseSeed = base.simulation.seed;
                end
            end

            setup = struct('base',base,'N',N,'r0Cells',{r0Cells}, ...
                'v0Cells',{v0Cells},'baseSeed',baseSeed);
        end

        function ci = assetConfigForIndex(setup, assetIndex)
            revgnss.IndependentFleetScenarioFactory.validateAssetIndex_(setup,assetIndex);
            ci = setup.base;
            if assetIndex >= 2
                secondaryIndex = assetIndex - 1;
                ci.orbit.eciState0 = [setup.r0Cells{secondaryIndex}; ...
                    setup.v0Cells{secondaryIndex}];
                ci.asset.clock.seed = 300 + assetIndex;
                ci.simulation.seed = setup.baseSeed + 100000*(assetIndex-1);
            end
        end

        function ci = stageOneLeafConfigForIndex(setup, fleetCfg, assetIndex)
            % Every Stage-1 leaf has one local EKF and no local ISL row path.
            revgnss.IndependentFleetScenarioFactory.validateAssetIndex_(setup,assetIndex);
            if setup.N == 1
                ci = fleetCfg;
                return
            end

            ci = revgnss.IndependentFleetScenarioFactory.assetConfigForIndex( ...
                setup,assetIndex);
            if isfield(fleetCfg,'assets') && numel(fleetCfg.assets) >= assetIndex
                ci.asset = fleetCfg.assets(assetIndex);
            end
            if ~isfield(ci.asset,'name') || isempty(ci.asset.name)
                ci.asset.name = sprintf('spacecraft-%d',assetIndex);
            end
            ci.asset.assetIndex = assetIndex;
            ci.asset.physicalAssetIndex = assetIndex;
            ci.asset.estimated = true;
            ci.asset.stateOwner = 'independentLocalEKF';
            ci.assets = ci.asset;
            ci.scenario.nSpaceAssets = 1;
            ci.multiAsset.mode = 'fast';
            ci.multiAsset.estimateMode = 'off';
            ci.multiAsset.keepIslInPerAssetEkf = false;
            ci.multiAsset.perAssetLeaf = true;
            if isfield(ci.multiAsset,'distributedEstimator')
                ci.multiAsset.distributedEstimator.enable = false;
                ci.multiAsset.distributedEstimator.stateExchange.enable = false;
                ci.multiAsset.distributedEstimator.linkUpdate.enable = false;
                % Section 2.3.1: the fleet-level cfg may carry the sanctioned linkUpdate tuple's
                % word-toggles (ownerPolicy/correlationPolicy/updateAdapter.observable); a leaf
                % must fall back to the FULLY-DISABLED combination, not just enable=false, else
                % this leaf's own ConfigFactory.finalizeConfig -> IndependentFleetCoordinator.
                % validateConfig call sees a partial/mixed tuple (enable=false but
                % ownerPolicy='initiator' etc.) and rejects it as unsupported.
                if isfield(ci.multiAsset.distributedEstimator,'linkUpdate')
                    ci.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
                    ci.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
                    if isfield(ci.multiAsset.distributedEstimator.linkUpdate,'updateAdapter')
                        ci.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
                    end
                end
                % Section 2.1: a leaf runs one local estimator and owns no fleet accounting.
                % Force both new sub-toggles off alongside the three keys above -- IndependentFleet
                % Coordinator.validateConfig's perAssetLeafSubToggleUnavailable gate asserts this,
                % it does not merely assume it.
                if isfield(ci.multiAsset.distributedEstimator,'stateExchange') && ...
                        isfield(ci.multiAsset.distributedEstimator.stateExchange,'estimatorEligibleProfile')
                    ci.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable = false;
                end
                if isfield(ci.multiAsset.distributedEstimator,'deliveryLedger')
                    ci.multiAsset.distributedEstimator.deliveryLedger.enable = false;
                end
            end
            if isfield(ci,'measurements') && isfield(ci.measurements,'isl')
                ci.measurements.isl.enable = false;
                if isfield(ci.measurements.isl,'code')
                    ci.measurements.isl.code.useInEKF = false;
                end
                if isfield(ci.measurements.isl,'doppler')
                    ci.measurements.isl.doppler.useInEKF = false;
                end
                if isfield(ci.measurements.isl,'carrier')
                    ci.measurements.isl.carrier.useInEKF = false;
                end
                if isfield(ci.measurements.isl,'timing')
                    ci.measurements.isl.timing.enable = false;
                end
                if isfield(ci.measurements.isl,'twoWay')
                    ci.measurements.isl.twoWay.enable = false;
                    if isfield(ci.measurements.isl.twoWay,'range')
                        ci.measurements.isl.twoWay.range.enable = false;
                        ci.measurements.isl.twoWay.range.useInEKF = false;
                    end
                    if isfield(ci.measurements.isl.twoWay,'timeTransfer')
                        ci.measurements.isl.twoWay.timeTransfer.enable = false;
                        ci.measurements.isl.twoWay.timeTransfer.useInEKF = false;
                    end
                end
            end
            if isfield(ci,'measurements') && isfield(ci.measurements,'twstft')
                ci.measurements.twstft.enable = false;
            end
        end

        function base = singleAssetBase(cfg, keepIslInLeaf)
            if nargin < 2; keepIslInLeaf = false; end
            base = revgnss.IndependentFleetScenarioFactory.stripSwarmEstimation( ...
                cfg,keepIslInLeaf);
            if ~logical(keepIslInLeaf)
                base.scenario.nSpaceAssets = 1;
            end
            if ~isfield(base,'multiAsset'); base.multiAsset = struct(); end
            base.multiAsset.perAssetLeaf = true;
            if isfield(base.multiAsset,'distributedEstimator')
                base.multiAsset.distributedEstimator.enable = false;
                base.multiAsset.distributedEstimator.stateExchange.enable = false;
                base.multiAsset.distributedEstimator.linkUpdate.enable = false;
                % Section 2.3.1: see the matching comment in stageOneLeafConfigForIndex -- the
                % fleet-level cfg may carry the sanctioned tuple's word-toggles, so this leaf
                % must fall back to the fully-disabled combination, not just enable=false.
                if isfield(base.multiAsset.distributedEstimator,'linkUpdate')
                    base.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
                    base.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
                    if isfield(base.multiAsset.distributedEstimator.linkUpdate,'updateAdapter')
                        base.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
                    end
                end
                if isfield(base.multiAsset.distributedEstimator,'stateExchange') && ...
                        isfield(base.multiAsset.distributedEstimator.stateExchange,'estimatorEligibleProfile')
                    base.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable = false;
                end
                if isfield(base.multiAsset.distributedEstimator,'deliveryLedger')
                    base.multiAsset.distributedEstimator.deliveryLedger.enable = false;
                end
            end
        end

        function c = stripSwarmEstimation(cfg, keepIslInLeaf)
            if nargin < 2; keepIslInLeaf = false; end
            c = cfg;
            if isfield(c,'multiAsset')
                c.multiAsset.mode = 'fast';
                c.multiAsset.towersObserveSecondaries = false;
                if isfield(c.multiAsset,'twoWayISL'); c.multiAsset.twoWayISL.enable = false; end
                if isfield(c.multiAsset,'twoWayTimeTransferISL'); c.multiAsset.twoWayTimeTransferISL.enable = false; end
                if isfield(c.multiAsset,'towerSecondary')
                    ts = c.multiAsset.towerSecondary;
                    if isfield(ts,'carrier'); ts.carrier.enable = false; end
                    if isfield(ts,'atmosphere'); ts.atmosphere.enable = false; end
                    if isfield(ts,'doppler'); ts.doppler.enable = false; end
                    if isfield(ts,'estimateAtmosphere'); ts.estimateAtmosphere = false; end
                    if isfield(ts,'attitude'); ts.attitude.enable = false; end
                    if isfield(ts,'multiAntenna'); ts.multiAntenna.enable = false; end
                    c.multiAsset.towerSecondary = ts;
                end
            end
            if isfield(c,'measurements') && isfield(c.measurements,'isl') && ...
                    ~logical(keepIslInLeaf)
                c.measurements.isl.enable = false;
            end
            if isfield(c,'measurements') && isfield(c.measurements,'twstft')
                c.measurements.twstft.enable = false;
            end
        end
    end

    methods (Static, Access = private)
        function validateAssetIndex_(setup, assetIndex)
            if ~(isnumeric(assetIndex) && isscalar(assetIndex) && ...
                    isfinite(assetIndex) && assetIndex == round(assetIndex) && ...
                    assetIndex >= 1 && assetIndex <= setup.N)
                error('IndependentFleetScenarioFactory:assetIndex', ...
                    'assetIndex must select one configured fleet member.');
            end
        end
    end
end
