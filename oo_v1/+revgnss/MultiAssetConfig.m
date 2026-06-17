classdef MultiAssetConfig
    % MultiAssetConfig  Stage 20 helpers for represented spacecraft assets.
    %
    % Stage 20 is metadata/truth-architecture only: tower-to-spacecraft
    % measurements still target the primary estimated asset, and ISL/TWSTFT
    % rows are explicitly absent.

    methods (Static)
        function cfg = normalize(cfg)
            if ~isfield(cfg,'scenario'); cfg.scenario = struct(); end
            if ~isfield(cfg.scenario,'nSpaceAssets') || isempty(cfg.scenario.nSpaceAssets)
                cfg.scenario.nSpaceAssets = 1;
            end
            nAssets = max(1, round(cfg.scenario.nSpaceAssets));
            cfg.scenario.nSpaceAssets = nAssets;

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
            if any(estimated(2:end))
                warning('MultiAssetConfig:estimationGuarded', ...
                    'Multi-asset estimation not yet enabled; only primary asset estimated.');
            end
            estimated(:) = false; estimated(1) = true;
            for ai = 1:nAssets
                cfg.assets(ai).estimated = estimated(ai);
                if estimated(ai)
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
            cfg.multiAsset.multiAssetEstimationEnabled = false;
            cfg.multiAsset.guardMessage = 'multi-asset estimation not yet enabled; only primary asset estimated';
            cfg.multiAsset.islRows = 0;
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
            for ai = 1:nAssets
                a = cfg.assets(ai);
                nRx = revgnss.MultiAssetConfig.receiverCount_(a);
                est = isfield(a,'estimated') && a.estimated;
                owner = 'representedOnly';
                if isfield(a,'stateOwner'); owner = a.stateOwner; end
                clkOwner = 'representedTruthClock';
                if est; clkOwner = 'primaryEKFReceiverClock'; end
                assetTable(ai) = struct('index', ai, 'name', char(a.name), ...
                    'estimated', est, 'stateOwner', char(owner), ...
                    'nReceivers', nRx, 'endpointCount', nRx, ...
                    'activeLinkCount', nTwr*nRx*est, 'clockOwner', clkOwner);
            end
            s = struct();
            s.nSpaceAssets = nAssets;
            s.estimatedAssetIndex = 1;
            s.estimatedAssetName = cfg.assets(1).name;
            s.nonEstimatedAssetNames = {cfg.assets(~[cfg.assets.estimated]).name};
            s.multiAssetEstimationEnabled = false;
            s.guardMessage = cfg.multiAsset.guardMessage;
            s.islRows = 0;
            s.twstftRows = 0;
            s.futureInactiveLinkTypes = {'ISL','TWSTFT'};
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
    end

    methods (Static, Access = private)
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
    end
end
