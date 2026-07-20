classdef MultiAssetConfig
    % MultiAssetConfig helpers for represented spacecraft assets.
    %
    % Metadata/truth-architecture only: tower-to-spacecraft
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

            % WP3 estimate mode (isfield-guarded: normalize() is called standalone by
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
            % 'position' (P1'/WP4) is a SUPERSET of 'clocks': each secondary gets a full
            % [r,v,b,bdot] block. secondaryClockCount treats 'position' as clock-enabled too.
            cfg.multiAsset.estimateMode = estMode;

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
            cfg.multiAsset.multiAssetEstimationEnabled = strcmp(estMode,'clocks') && nAssets >= 2;
            cfg.multiAsset.secondaryClockStates = 2 * revgnss.MultiAssetConfig.secondaryClockCount(cfg);
            if cfg.multiAsset.multiAssetEstimationEnabled
                cfg.multiAsset.guardMessage = 'secondary-asset clocks (bias+drift) estimated as EKF states (WP3); positions remain product';
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
                if est; clkOwner = 'primaryEKFReceiverClock'; end
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
            s.secondaryClockStates = cfg.multiAsset.secondaryClockStates;
            s.futureInactiveLinkTypes = {'TWSTFT','relay/transponder'};
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

        function nSec = secondaryClockCount(cfg)
            % secondaryClockCount  THE single WP3 master gate. Returns the number of
            % secondaries whose [b_tx,bdot_tx] are EKF-estimated (nSpaceAssets-1), or 0.
            % Reads RAW cfg fields only (no dependency on normalize having run), so it is
            % safe to call from the EKF constructor and the report helper alike.
            nSec = 0;
            mode = revgnss.MultiAssetConfig.estimateModeStr_(cfg);
            if ~ismember(mode, {'clocks','position'}); return; end   % 'position' includes clocks
            nA = 1;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets')
                nA = max(1, round(cfg.scenario.nSpaceAssets));
            end
            if nA < 2; return; end
            % ISL code must be an active EKF observable or b_tx has zero measurement
            % support (pure divergent random walk). This makes state allocation and
            % observability inseparable -- no estimated-but-unobservable clock states.
            g = @(p) revgnss.MultiAssetConfig.cfgBool_(cfg, p, false);
            if ~(g({'measurements','isl','enable'}) && ...
                 g({'measurements','isl','code','enable'}) && ...
                 g({'measurements','isl','code','useInEKF'})); return; end
            nSec = nA - 1;
        end

        function nSec = secondaryOrbitCount(cfg)
            % secondaryOrbitCount  P1'/WP4 gate: number of secondaries whose [r,v] are
            % EKF-estimated. Nonzero only for estimateMode='position' AND when the
            % secondary is observable (ground->secondary rows on, per the review: never
            % allocate an orbit block without an observable touching it). Mirrors the
            % secondaryClockCount allocation-gate discipline.
            nSec = 0;
            if ~strcmp(revgnss.MultiAssetConfig.estimateModeStr_(cfg), 'position'); return; end
            % Position needs a POSITION observable: ground->secondary rows (near-radial
            % absolute) are required; ISL alone only ties relative baselines.
            if ~revgnss.MultiAssetConfig.cfgBool_(cfg, {'multiAsset','towersObserveSecondaries'}, false)
                return;
            end
            nSec = revgnss.MultiAssetConfig.secondaryClockCount(cfg);   % same asset set (needs ISL code gate too)
        end

        function nSec = secondaryCarrierCount(cfg)
            % secondaryCarrierCount  Phase-1 per-secondary-symmetry gate: number of
            % secondaries that get tower->secondary CARRIER-phase rows + float-ambiguity
            % states. Requires an estimated orbit block (position mode + towersObserve-
            % Secondaries; a carrier row needs the secondary's r/v geometric column) AND
            % the carrier toggle. Returns 0 otherwise -> byte-identical when off / single-asset.
            nSec = 0;
            if ~revgnss.MultiAssetConfig.cfgBool_(cfg, {'multiAsset','towerSecondary','carrier','enable'}, false)
                return;
            end
            nSec = revgnss.MultiAssetConfig.secondaryOrbitCount(cfg);
        end

        function nSec = secondaryAtmosphereCount(cfg)
            % secondaryAtmosphereCount  Phase-2 gate: number of secondaries that get per-
            % (secondary,tower) troposphere ZWD states. HONEST observability prerequisite:
            % only allocated when Guard A (towerSecondary.atmosphere.enable) injects a
            % DIVERGENT truth-side tropo residual for the ZWD to absorb -- with a matched
            % atmosphere the state sees zero signal and estimating it would be dishonest.
            % Requires an estimated orbit block (position + towersObserveSecondaries) too.
            nSec = 0;
            if ~revgnss.MultiAssetConfig.cfgBool_(cfg, {'multiAsset','towerSecondary','estimateAtmosphere'}, false)
                return;
            end
            if ~revgnss.MultiAssetConfig.cfgBool_(cfg, {'multiAsset','towerSecondary','atmosphere','enable'}, false)
                return;   % no divergent tropo residual -> unobservable -> refuse to allocate
            end
            nSec = revgnss.MultiAssetConfig.secondaryOrbitCount(cfg);
        end

        function nSec = groundSecondaryRowCount(cfg)
            % groundSecondaryRowCount  WP5 gate. Returns the number of secondaries whose
            % clock is observed by ground-tower rows (== secondaryClockCount) when
            % cfg.multiAsset.towersObserveSecondaries is true, else 0. Requires WP3
            % (secondaryClockCount>0) so the tower row has a secondary clock state to touch.
            nSec = 0;
            if ~revgnss.MultiAssetConfig.cfgBool_(cfg, {'multiAsset','towersObserveSecondaries'}, false)
                return;
            end
            nSec = revgnss.MultiAssetConfig.secondaryClockCount(cfg);
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
                if isfield(tw,'range') && isfield(tw.range,'enable') && tw.range.enable; n = n + 1; end
                if isfield(tw,'doppler') && isfield(tw.doppler,'enable') && tw.doppler.enable; n = n + 1; end
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
        end
    end
end
