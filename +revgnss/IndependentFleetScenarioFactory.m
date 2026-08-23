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
                % Seed choice depends on whether this leaf retains its swarm siblings.
                % singleAssetBase already collapsed ci.scenario.nSpaceAssets to 1 UNLESS
                % keepIslInPerAssetEkf kept it at the full swarm size -- and when it's 1,
                % MultiAssetConfig.normalize truncates cfg.assets to a single element
                % (cfg.assets = cfg.assets(1:1)) before any secondary-asset seed logic can
                % run, so 300+assetIndex has always been collision-free there and MUST stay
                % (the swarm-relative regression baseline was captured against exactly this
                % value for that path -- changing it moves real results for no reason).
                % When siblings ARE retained (keepIslInPerAssetEkf=true), cfg.assets keeps
                % assetIndex's own original slot, and MultiAssetConfig.finalizeAsset_ stamps
                % EVERY cfg.assets(k) for k>1 to 300+k unconditionally, keyed on array
                % POSITION regardless of which data occupies that slot -- so a cfg.asset seed
                % drawn from the same 300+k family is guaranteed to collide with whatever
                % finalizeAsset_ stamps onto position assetIndex. Slot 1 is the one position
                % finalizeAsset_ never re-stamps (mergePrimary_ handles it instead), so
                % cfg.asset needs a seed outside BOTH 300+{2..N} and the tower family 200+k.
                %
                % IT MUST ALSO DIFFER BETWEEN LEAVES. Each leaf is an independent simulation
                % of a DIFFERENT physical satellite, so a seed shared across leaves gives every
                % spacecraft a BIT-IDENTICAL truth clock realization -- the federated relative
                % layer then differences them and sees exactly zero relative clock error, which
                % silently flatters every relative-clock and common-mode result. (Measured when
                % this was briefly a flat 100: max|b_i - b_1| = 0 exactly across all six.)
                % 100+assetIndex is unique per leaf and collides with neither family.
                retainsSiblings = isfield(ci,'scenario') && ...
                    isfield(ci.scenario,'nSpaceAssets') && ci.scenario.nSpaceAssets > 1;
                if retainsSiblings
                    ci.asset.clock.seed = 100 + assetIndex;
                else
                    ci.asset.clock.seed = 300 + assetIndex;
                end
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
                % Stage 3.1: force all nine correlationNetwork keys off together (the exact
                % Section 2.3.1 partial-configuration defect, restated so it cannot recur here).
                if isfield(ci.multiAsset.distributedEstimator,'correlationNetwork')
                    cn = ci.multiAsset.distributedEstimator.correlationNetwork;
                    cn.policy = 'disabled';
                    cn.maximumFleetSize = 0;
                    if isfield(cn,'commonProcessNoiseTreatment'); cn.commonProcessNoiseTreatment = 'rejected'; end
                    if isfield(cn,'commonProcessNoise') && isfield(cn.commonProcessNoise,'sigma_mps2')
                        cn.commonProcessNoise.sigma_mps2 = 0;
                    end
                    % Section 3.2: routing is the tenth key -- forced back to its single legal
                    % disabled-policy value alongside the other nine, the exact gap
                    % requireCorrelationNetworkConfiguration_'s own partial-configuration check
                    % now asserts against (routing is otherwise orthogonal to policy, so a leaf
                    % inheriting a fleet-level 'pairExactWhenBothEndpointsTracked' word would
                    % otherwise fail validation with policy already forced 'disabled').
                    if isfield(cn,'linkUpdateRouting'); cn.linkUpdateRouting = 'conservativeBoundOnly'; end
                    if isfield(cn,'audit')
                        cn.audit.enable = false;
                        cn.audit.everyNEpochs = 0;
                    end
                    ci.multiAsset.distributedEstimator.correlationNetwork = cn;
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
                if isfield(ci.measurements.isl,'oneWay')
                    ci.measurements.isl.oneWay.enable = false;
                    if isfield(ci.measurements.isl.oneWay,'code')
                        ci.measurements.isl.oneWay.code.enable = false;
                        ci.measurements.isl.oneWay.code.useInEKF = false;
                    end
                    if isfield(ci.measurements.isl.oneWay,'doppler')
                        ci.measurements.isl.oneWay.doppler.enable = false;
                        ci.measurements.isl.oneWay.doppler.useInEKF = false;
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
                % Stage 3.1: see the matching comment in stageOneLeafConfigForIndex -- force all
                % nine correlationNetwork keys off together.
                if isfield(base.multiAsset.distributedEstimator,'correlationNetwork')
                    cn = base.multiAsset.distributedEstimator.correlationNetwork;
                    cn.policy = 'disabled';
                    cn.maximumFleetSize = 0;
                    if isfield(cn,'commonProcessNoiseTreatment'); cn.commonProcessNoiseTreatment = 'rejected'; end
                    if isfield(cn,'commonProcessNoise') && isfield(cn.commonProcessNoise,'sigma_mps2')
                        cn.commonProcessNoise.sigma_mps2 = 0;
                    end
                    % Section 3.2: see the matching comment in stageOneLeafConfigForIndex --
                    % routing is the tenth key, forced back to its single legal disabled-policy
                    % value alongside the other nine.
                    if isfield(cn,'linkUpdateRouting'); cn.linkUpdateRouting = 'conservativeBoundOnly'; end
                    if isfield(cn,'audit')
                        cn.audit.enable = false;
                        cn.audit.everyNEpochs = 0;
                    end
                    base.multiAsset.distributedEstimator.correlationNetwork = cn;
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
                % Clearing only the isl.enable PARENT left the twoWay sub-tree switched on in the
                % leaf. A fleet config that legitimately sets measurements.isl.twoWay.timeTransfer
                % .enable=true -- now the sanctioned gate for the relative-clock layer, which reads
                % the FLEET cfg, not this leaf -- then reached InterSatelliteTimeTransferBuilder
                % inside a per-asset leaf whose parents were false, and it aborted the whole run
                % with InterSatelliteTimeTransferBuilder:parentDisabled. Strip the sub-tree the way
                % stageOneLeafConfigForIndex already does for the distributed leaf, so both leaf
                % builders are consistently ISL-free (decision D1: ISL never enters a per-asset
                % absolute filter; it feeds the relative layer only).
                if isfield(c.measurements.isl,'twoWay')
                    c.measurements.isl.twoWay.enable = false;
                    if isfield(c.measurements.isl.twoWay,'range')
                        c.measurements.isl.twoWay.range.enable = false;
                        c.measurements.isl.twoWay.range.useInEKF = false;
                    end
                    if isfield(c.measurements.isl.twoWay,'timeTransfer')
                        c.measurements.isl.twoWay.timeTransfer.enable = false;
                        c.measurements.isl.twoWay.timeTransfer.useInEKF = false;
                    end
                    if isfield(c.measurements.isl.twoWay,'doppler')
                        c.measurements.isl.twoWay.doppler.enable = false;
                        c.measurements.isl.twoWay.doppler.useInEKF = false;
                    end
                end
                if isfield(c.measurements.isl,'oneWay')
                    c.measurements.isl.oneWay.enable = false;
                end
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
