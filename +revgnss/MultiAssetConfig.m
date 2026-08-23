classdef MultiAssetConfig
    % MultiAssetConfig helpers for represented and jointly estimated spacecraft.

    methods (Static)
        function cfg = normalize(cfg)
            if ~isfield(cfg,'scenario'); cfg.scenario = struct(); end
            if ~isfield(cfg.scenario,'nSpaceAssets') || isempty(cfg.scenario.nSpaceAssets)
                cfg.scenario.nSpaceAssets = 1;
            end
            nAssets = max(1, round(cfg.scenario.nSpaceAssets));
            cfg.scenario.nSpaceAssets = nAssets;

            % Estimate mode (isfield-guarded: normalize() is called standalone by
            % summary()/assetInfos()/instantiateAssets() on cfgs that may lack the field).
            estMode = 'off';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'estimateMode') && ...
                    (ischar(cfg.multiAsset.estimateMode) || isstring(cfg.multiAsset.estimateMode))
                estMode = char(cfg.multiAsset.estimateMode);
            end
            if ~ismember(estMode, {'off','clocks','position'})
                error('MultiAssetConfig:badEstimateMode', ...
                    'cfg.multiAsset.estimateMode must be ''off''|''clocks''|''position''; got ''%s''.', estMode);
            end
            cfg.multiAsset.estimateMode = estMode;
            jointMode = false;
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'mode') && ...
                    (ischar(cfg.multiAsset.mode) || isstring(cfg.multiAsset.mode))
                jointMode = strcmpi(char(cfg.multiAsset.mode),'joint');
            end

            if ~isfield(cfg,'asset') || isempty(cfg.asset)
                error('MultiAssetConfig:missingPrimaryAsset', 'cfg.asset is required as the primary estimated asset.');
            end
            if ~isfield(cfg,'assets') || isempty(cfg.assets)
                cfg.assets = cfg.asset;
            end
            if numel(cfg.assets) < nAssets
                for ai = numel(cfg.assets)+1:nAssets
                    cfg.assets(ai) = revgnss.MultiAssetConfig.cloneAsset_(cfg.asset, ai); %#ok<AGROW>
                end
            end

            cfg.assets(1) = revgnss.MultiAssetConfig.mergePrimary_(cfg.assets(1), cfg.asset);
            for ai = 1:nAssets
                cfg.assets(ai) = revgnss.MultiAssetConfig.finalizeAsset_(cfg.assets(ai), cfg.asset, ai);
            end
            cfg.assets = cfg.assets(1:nAssets);
            cfg.asset = cfg.assets(1);

            estimated = false(1, nAssets);
            for ai = 1:nAssets
                if isfield(cfg.assets(ai),'estimated') && islogical(cfg.assets(ai).estimated)
                    estimated(ai) = cfg.assets(ai).estimated;
                end
            end
            if ~any(estimated); estimated(1) = true; end
            if any(estimated(2:end)) && ~jointMode
                warning('MultiAssetConfig:estimationGuarded', ...
                    'Multi-asset estimation not yet enabled; only primary asset estimated.');
            end
            if jointMode
                estimated(:) = true;
            else
                estimated(:) = false; estimated(1) = true;
            end
            for ai = 1:nAssets
                cfg.assets(ai).estimated = estimated(ai);
                if jointMode
                    cfg.assets(ai).stateOwner = 'jointEKF';
                elseif estimated(ai)
                    cfg.assets(ai).stateOwner = 'primaryEKF';
                else
                    cfg.assets(ai).stateOwner = 'representedOnly';
                end
            end
            cfg.asset = cfg.assets(1);

            cfg.multiAsset.enabled = nAssets > 1;
            cfg.multiAsset.nSpaceAssets = nAssets;
            cfg.multiAsset.estimatedAssetIndex = 1;
            cfg.multiAsset.estimatedAssetName = cfg.assets(1).name;
            cfg.multiAsset.multiAssetEstimationEnabled = jointMode && nAssets >= 2;
            if jointMode
                cfg.multiAsset.guardMessage = ...
                    'all spacecraft navigation, clock, and attitude states share one full-covariance EKF';
            else
                cfg.multiAsset.guardMessage = 'multi-asset estimation not yet enabled; only primary asset estimated';
            end
            cfg.multiAsset.islRows = revgnss.MultiAssetConfig.islRowCount_(cfg);
            cfg.multiAsset.twstftRows = 0;
        end

        function assets = instantiateAssets(cfg, primaryAsset)
            cfg = revgnss.MultiAssetConfig.normalize(cfg);
            assets = cell(1, cfg.scenario.nSpaceAssets);
            assets{1} = primaryAsset;
            for ai = 2:numel(assets)
                assets{ai} = revgnss.SpaceAsset(cfg.assets(ai));
            end
        end

        function s = summary(cfg)
            cfg = revgnss.MultiAssetConfig.normalize(cfg);
            nAssets = cfg.scenario.nSpaceAssets;
            empty = struct('index',0,'name','','estimated',false, ...
                'stateOwner','','nReceivers',0,'endpointCount',0, ...
                'activeLinkCount',0,'clockOwner','');
            assetTable = repmat(empty, nAssets, 1);
            nTwr = 0;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nTowers'); nTwr = cfg.scenario.nTowers; end
            islActiveLinks = revgnss.MultiAssetConfig.islLinkCount_(cfg);
            txIdx = 2; rxIdx = 1;
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'isl')
                if isfield(cfg.measurements.isl,'transmitterAssetIndex'); txIdx = cfg.measurements.isl.transmitterAssetIndex; end
                if isfield(cfg.measurements.isl,'receiverAssetIndex'); rxIdx = cfg.measurements.isl.receiverAssetIndex; end
            end
            for ai = 1:nAssets
                a = cfg.assets(ai);
                nRx = revgnss.MultiAssetConfig.receiverCount_(a);
                est = isfield(a,'estimated') && a.estimated;
                owner = 'representedOnly';
                if isfield(a,'stateOwner'); owner = a.stateOwner; end
                clkOwner = 'representedTruthClock';
                if strcmp(owner,'jointEKF')
                    clkOwner = 'jointEKFReceiverClock';
                elseif est
                    clkOwner = 'primaryEKFReceiverClock';
                end
                activeLinks = nTwr*nRx*est;
                if islActiveLinks > 0 && (ai == txIdx || ai == rxIdx)
                    activeLinks = activeLinks + islActiveLinks;
                end
                assetTable(ai) = struct('index', ai, 'name', char(a.name), ...
                    'estimated', est, 'stateOwner', char(owner), ...
                    'nReceivers', nRx, 'endpointCount', nRx, ...
                    'activeLinkCount', activeLinks, 'clockOwner', clkOwner);
            end
            s = struct();
            s.nSpaceAssets = nAssets;
            s.estimatedAssetIndex = 1;
            s.estimatedAssetName = cfg.assets(1).name;
            s.nonEstimatedAssetNames = {cfg.assets(~[cfg.assets.estimated]).name};
            s.multiAssetEstimationEnabled = cfg.multiAsset.multiAssetEstimationEnabled;
            s.guardMessage = cfg.multiAsset.guardMessage;
            s.islRows = revgnss.MultiAssetConfig.islRowCount_(cfg);
            s.twstftRows = 0;
            s.futureInactiveLinkTypes = {'fourTimestampPhysicalTimeTransfer', ...
                'coherentTwoWayDoppler','relay/transponder'};
            s.assetTable = assetTable;
        end

        function infos = assetInfos(cfg)
            cfg = revgnss.MultiAssetConfig.normalize(cfg);
            nAssets = cfg.scenario.nSpaceAssets;
            infos = repmat(struct('index',0,'name','','nReceivers',0,'estimated',false), nAssets, 1);
            for ai = 1:nAssets
                infos(ai).index = ai;
                infos(ai).name = cfg.assets(ai).name;
                infos(ai).nReceivers = revgnss.MultiAssetConfig.receiverCount_(cfg.assets(ai));
                infos(ai).estimated = cfg.assets(ai).estimated;
            end
        end

        function nTx = islTxCount_(cfg)
            % Number of transmitting secondaries: 'all' -> nSpaceAssets-1, else the
            % count of valid explicit indices (default single legacy transmitter).
            nAssets = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets')
                nAssets = max(1, round(cfg.scenario.nSpaceAssets));
            end
            sel = 'all';
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'isl') && ...
                    isfield(cfg.measurements.isl,'transmitters')
                sel = cfg.measurements.isl.transmitters;
            end
            if (ischar(sel) || isstring(sel)) && strcmpi(char(sel),'all')
                nTx = max(0, nAssets - 1);
            elseif isnumeric(sel) && ~isempty(sel)
                v = round(sel(:)'); nTx = numel(v(v >= 2 & v <= nAssets));
            else
                nTx = double(nAssets >= 2);
            end
        end

        function count = twoWayConcurrentLinkCount_(cfg)
            links = revgnss.TwoWayISLMeasurementBuilder.linkDefinitions(cfg);
            if isempty(links)
                count = 1;
                return
            end
            phases_s = arrayfun(@(link) ...
                double(link.schedule.updatePhase_s),links);
            tolerance = 10*eps(max(1,max(abs(phases_s))));
            count = 0;
            for linkIndex = 1:numel(links)
                count = max(count,sum(abs(phases_s-phases_s(linkIndex)) <= ...
                    tolerance));
            end
        end

    end

    methods (Static, Access = private)
        function mode = estimateModeStr_(cfg)
            mode = 'off';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'estimateMode') && ...
                    (ischar(cfg.multiAsset.estimateMode) || isstring(cfg.multiAsset.estimateMode))
                mode = char(cfg.multiAsset.estimateMode);
            end
        end

        function tf = cfgBool_(cfg, path, defaultValue)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k});
                else; tf = islogical(defaultValue) && defaultValue; return; end
            end
            tf = islogical(v) && isscalar(v) && v;
        end

        function v = cfgNum_(cfg, path, defaultValue)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; v = defaultValue; return; end
            end
            if ~(isnumeric(v) && isscalar(v)); v = defaultValue; end
        end

        function a = mergePrimary_(a, primary)
            f = fieldnames(primary);
            for k = 1:numel(f); a.(f{k}) = primary.(f{k}); end
        end

        function a = finalizeAsset_(a, primary, ai)
            if ~isfield(a,'name') || isempty(a.name); a.name = sprintf('GEO-%d', ai); end
            a.assetIndex = ai;
            needed = {'mass_kg','r_ecef_m','v_ecef_mps','attitude_euler_rad', ...
                'angularRate_body_radps','receiverLeverArm_body_m','receiverLeverArms_body_m', ...
                'clockName','clockType','clockFactors','clock'};
            for k = 1:numel(needed)
                if ~isfield(a, needed{k}) && isfield(primary, needed{k})
                    a.(needed{k}) = primary.(needed{k});
                end
            end
            if ~isfield(a,'receiverLeverArms_body_m')
                a.receiverLeverArms_body_m = a.receiverLeverArm_body_m(:);
            end
            a.receiverLeverArm_body_m = a.receiverLeverArms_body_m(:,1);
            if ai > 1 && isfield(a,'clock')
                a.clock.name = sprintf('RxClock_%s', regexprep(char(a.name), '\W+', '_'));
                % Independent clock seed per secondary asset. Without this every
                % secondary is cloned from the primary and shares seed 100, so all
                % swarm clocks produce an identical noise realization (masked today
                % only because one-way ISL cancels the true tx clock). 300+ai keeps
                % it distinct from receiver(100) and towers(200+k).
                a.clock.seed = 300 + ai;
            end
            if ~isfield(a,'estimated'); a.estimated = ai == 1; end
        end

        function a = cloneAsset_(primary, ai)
            a = primary;
            a.name = sprintf('GEO-%d', ai);
            a.r_ecef_m = primary.r_ecef_m + [0; 1e5*(ai-1); 0];
            a.receiverLeverArms_body_m = primary.receiverLeverArms_body_m(:,1);
            a.receiverLeverArm_body_m = a.receiverLeverArms_body_m(:,1);
            a.estimated = false;
        end

        function nRx = receiverCount_(assetCfg)
            nRx = 1;
            if isfield(assetCfg,'receiverLeverArms_body_m') && ~isempty(assetCfg.receiverLeverArms_body_m)
                nRx = size(assetCfg.receiverLeverArms_body_m, 2);
            end
        end

        function n = islRowCount_(cfg)
            % Total ISL rows generated per epoch = (one-way row types) x (number of
            % transmitting secondaries) + (two-way row types, single link).
            n = 0;
            if ~isfield(cfg,'measurements') || ~isfield(cfg.measurements,'isl') || ...
                    ~isfield(cfg.measurements.isl,'enable') || ~cfg.measurements.isl.enable
                return
            end
            isl = cfg.measurements.isl;
            nTx = revgnss.MultiAssetConfig.islTxCount_(cfg);
            oneWayTypes = 0;
            if isfield(isl,'code') && isfield(isl.code,'enable') && isl.code.enable; oneWayTypes = oneWayTypes + 1; end
            if isfield(isl,'doppler') && isfield(isl.doppler,'enable') && isl.doppler.enable; oneWayTypes = oneWayTypes + 1; end
            if isfield(isl,'carrier') && isfield(isl.carrier,'enable') && isl.carrier.enable; oneWayTypes = oneWayTypes + 1; end
            n = n + oneWayTypes * nTx;
            if isfield(isl,'twoWay') && isfield(isl.twoWay,'enable') && isl.twoWay.enable
                tw = isl.twoWay;
                scheduledLinks = ...
                    revgnss.MultiAssetConfig.twoWayConcurrentLinkCount_(cfg);
                if isfield(tw,'range') && isfield(tw.range,'enable') && tw.range.enable; n = n + scheduledLinks; end
                if isfield(tw,'doppler') && isfield(tw.doppler,'enable') && tw.doppler.enable; n = n + scheduledLinks; end
                if isfield(tw,'timeTransfer') && ...
                        isfield(tw.timeTransfer,'enable') && ...
                        tw.timeTransfer.enable
                    n = n + scheduledLinks;
                end
            end
        end

        function n = islLinkCount_(cfg)
            n = 0;
            if ~isfield(cfg,'measurements') || ~isfield(cfg.measurements,'isl') || ...
                    ~isfield(cfg.measurements.isl,'enable') || ~cfg.measurements.isl.enable
                return
            end
            isl = cfg.measurements.isl;
            if (isfield(isl,'code') && isfield(isl.code,'enable') && isl.code.enable) || ...
                    (isfield(isl,'doppler') && isfield(isl.doppler,'enable') && isl.doppler.enable) || ...
                    (isfield(isl,'carrier') && isfield(isl.carrier,'enable') && isl.carrier.enable)
                n = n + 1;
            end
            if isfield(isl,'twoWay') && isfield(isl.twoWay,'enable') && isl.twoWay.enable && ...
                    ((isfield(isl.twoWay,'range') && isfield(isl.twoWay.range,'enable') && isl.twoWay.range.enable) || ...
                     (isfield(isl.twoWay,'doppler') && isfield(isl.twoWay.doppler,'enable') && isl.twoWay.doppler.enable))
                n = n + 1;
            end
            if isfield(isl,'twoWay') && isfield(isl.twoWay,'enable') && ...
                    isl.twoWay.enable && isfield(isl.twoWay,'timeTransfer') && ...
                    isfield(isl.twoWay.timeTransfer,'enable') && ...
                    isl.twoWay.timeTransfer.enable
                n = n + 1;
            end
        end
    end
end
