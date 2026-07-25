classdef ISLMeasurementBuilder
    % ISLMeasurementBuilder  One-way secondary-to-primary ISL observables.
    %
    % Physically, each represented secondary spacecraft is a "beacon in space":
    % it transmits a signal that the primary (estimated) spacecraft receives, so a
    % one-way ISL code row is an extra pseudorange with a NON-vertical line of
    % sight. The ground beacons all sit below the GEO primary (upward cone, huge
    % VDOP, near-degenerate radial/clock); the ISL rows supply the missing
    % geometry and break that degeneracy.
    %
    % Honesty (the aiding must be realistic, not perfect-truth):
    %   * z carries thermal measurement noise (sigma_m), drawn per epoch/link.
    %   * FAST / 'clocks' mode: the secondary POSITION is represented by a PRODUCT
    %     (broadcast ephemeris) with a fixed-per-run product error; the model h uses the
    %     product, z uses the true secondary, so the residual contains the product error and
    %     its covariance is added to R (productAidedExternal). The achievable primary accuracy
    %     is then floored by the reference-product quality (an ASSUMED-KNOWN beacon).
    %   * 'position' mode: the secondary [r,v] (and [b,bdot]) are ESTIMATED states.
    %     h then uses x() for the tx, z the truth, and the product variances are dropped from
    %     R -- the product is fully RETIRED (no assumed-known beacon). validateConfig makes
    %     estimateMode='position' + isl.product.enable=true a hard error to keep it that way.
    %
    % Convention (tx -> rx): u = (r_rx - r_tx)/|r_rx - r_tx|, so H(r_rx)=+u',
    % H(b_rx)=+1 (code) and H(v_rx)=+u', H(bdot_rx)=+1 (Doppler). ISL carrier is
    % diagnostic-only until ISL ambiguity states exist.

    methods (Static)
        function validateConfig(cfg)
            % Anti-circularity guard: when estimateMode='position' the secondary orbits
            % are ESTIMATED states, so the ISL broadcast product is the RETIRED assumed-known
            % position beacon -- supplying it too is a redundant/circular reference ("no
            % assumed-known beacon anywhere"). The estimated path already ignores it (h uses
            % x(), R drops its variances); this makes that honesty a hard contract instead of
            % a silent no-op. 'clocks' mode legitimately keeps the product for POSITION.
            estMode = 'off';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'estimateMode') && ...
                    (ischar(cfg.multiAsset.estimateMode) || isstring(cfg.multiAsset.estimateMode))
                estMode = char(cfg.multiAsset.estimateMode);
            end
            if strcmp(estMode,'position') && ...
                    revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','product','enable'}, false)
                error('ISLMeasurementBuilder:productWithEstimatedPosition', ...
                    ['estimateMode=''position'' estimates the secondary positions; the ISL ' ...
                     'broadcast product is the retired assumed-known beacon and must not also ' ...
                     'be supplied. Set cfg.measurements.isl.product.enable=false (or use ' ...
                     'cfg.multiAsset.mode=''honest'', which does so).']);
            end
            if ~revgnss.ISLMeasurementBuilder.isEnabled_(cfg); return; end
            nAssets = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'scenario','nSpaceAssets'}, 1);
            rxIdx = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','receiverAssetIndex'}, 1);
            if nAssets < 2
                error('ISLMeasurementBuilder:assetCount', 'ISL requires at least two represented space assets.');
            end
            if rxIdx ~= 1
                error('ISLMeasurementBuilder:receiverGuard', ...
                    'ISL updates only into the primary estimated asset (receiverAssetIndex=1).');
            end
            txList = revgnss.ISLMeasurementBuilder.txList_(cfg, nAssets);
            if isempty(txList)
                error('ISLMeasurementBuilder:noTransmitter', 'No valid ISL transmitter asset selected.');
            end
            if any(txList < 2 | txList > nAssets)
                error('ISLMeasurementBuilder:assetIndex', 'ISL transmitter asset indices must be secondary (2..N).');
            end
            if revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','code','useInEKF'}, false) && ...
                    ~revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','code','enable'}, false)
                error('ISLMeasurementBuilder:codeUseGuard', 'ISL code useInEKF requires ISL code enable=true.');
            end
            if revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','doppler','useInEKF'}, false) && ...
                    ~revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','doppler','enable'}, false)
                error('ISLMeasurementBuilder:dopplerUseGuard', 'ISL Doppler useInEKF requires ISL Doppler enable=true.');
            end
            % ISL carrier may enter the EKF ONLY when it has an ambiguity state to hold the
            % integer cycle count. Without one the filter would drive the unknown integer
            % into position/clock and silently corrupt the solution -- which is why this
            % used to be an unconditional error. The guard now checks the actual
            % precondition instead of refusing outright.
            if revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','carrier','useInEKF'}, false)
                if ~revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','carrier','enable'}, false)
                    error('ISLMeasurementBuilder:carrierUseGuard', ...
                        'ISL carrier useInEKF requires ISL carrier enable=true.');
                end
                if ~revgnss.ISLMeasurementBuilder.islAmbiguityEnabled(cfg)
                    error('ISLMeasurementBuilder:carrierEkfNeedsAmbiguity', ...
                        ['ISL carrier EKF use requires ISL ambiguity states. Set ' ...
                         'cfg.measurements.isl.carrier.ambiguity.enable=true (the float ' ...
                         'ambiguity absorbs the integer cycle count; without it the ' ...
                         'integer would be aliased into position/clock).']);
                end
                if revgnss.ISLMeasurementBuilder.ambiguityStateCount(cfg) < 1
                    error('ISLMeasurementBuilder:carrierEkfNoLinks', ...
                        'ISL carrier EKF use requires at least one active ISL link.');
                end
                % MEASURED failure mode (do not relax this): admitting mm-sigma carrier
                % rows before the code-only solution has converged makes the filter
                % CONFIDENTLY WRONG. With warmup_s=0 the ambiguity settles 100s of metres
                % from truth while reporting sigma(B) ~ 12 mm -- the tight R collapses the
                % covariance around a point reached by an invalid linearisation (position
                % error is still kilometres at t=0). With the 300 s default the same setup
                % converges to 1-4 cm with sigma ~ 29 mm, i.e. error ~ sigma (consistent).
                % The symptom is silent: no NaN, no divergence warning, just a tiny sigma
                % on a wrong value -- hence a hard error rather than a warning.
                wu = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','warmup_s'}, 0);
                if ~(wu > 0)
                    error('ISLMeasurementBuilder:carrierEkfNeedsWarmup', ...
                        ['ISL carrier useInEKF requires cfg.measurements.isl.warmup_s > 0 ' ...
                         '(default 300). Admitting mm-sigma carrier rows at t=0, while the ' ...
                         'position error is still kilometres, drives the ambiguity 100s of ' ...
                         'metres off AND collapses its covariance to ~12 mm -- a silent, ' ...
                         'confidently-wrong solution.']);
                end
            end
        end

        function [zAdd, hAdd, HAdd, RAdd, info] = build(cfg, primaryAsset, assets, x, stateMap, nx, t_s)
            if nargin < 7; t_s = 0; end
            info = revgnss.ISLMeasurementBuilder.defaultInfo(cfg, assets);
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);
            if ~info.enabled; return; end
            % ISL acquisition warm-up: the primary first gets a coarse fix from the
            % ground beacons (initial covariance shrinks to a moderate level), THEN
            % ISL rows enter the EKF. Applying a tight ISL row to the huge initial
            % covariance would overshoot the transient. Before warm-up the rows are
            % still built as diagnostics (metadata/prefit) but not used in the EKF.
            info.warmupActive = t_s < info.warmup_s;
            if info.warmupActive
                info.codeUseInEKF = false; info.dopplerUseInEKF = false;
                info.carrierUseInEKF = false;   % carrier follows the same acquisition gate
            end
            epochIdx = 0;
            if isfield(cfg,'simulation') && isfield(cfg.simulation,'dt_s') && cfg.simulation.dt_s > 0
                epochIdx = round(t_s / cfg.simulation.dt_s);
            end
            brxTruth = primaryAsset.clock.getBiasMeters();
            drxTruth = primaryAsset.clock.getDriftMetersPerSecond();
            info.productIntervalIdx = revgnss.ISLMeasurementBuilder.productInterval_(info.product, t_s);

            for txi = info.transmitterList(:)'
                tx  = assets{txi};
                pb  = revgnss.ISLMeasurementBuilder.productBias_(cfg, info.product, txi, info.productIntervalIdx);
                rTxTruth = tx.r_ecef_m(:);   vTxTruth = tx.v_ecef_mps(:);
                rTxProd  = rTxTruth + pb.pos; vTxProd = vTxTruth + pb.vel;
                btxTruth = tx.clock.getBiasMeters();           dtxTruth = tx.clock.getDriftMetersPerSecond();
                btxProd  = btxTruth + pb.clk;                  dtxProd  = dtxTruth + pb.clkDrift;

                % Diagnostic: per-secondary truth clock (est-vs-truth is formed downstream).
                if isfield(stateMap,'secondaryClockIdx') && ~isempty(stateMap.secondaryClockIdx) && txi >= 2
                    info.secondaryTruthBias_m(txi-1,1)    = btxTruth;
                    info.secondaryTruthDrift_mps(txi-1,1) = dtxTruth;
                end
                % Diagnostic: per-secondary truth POSITION (est-vs-truth downstream).
                if isfield(stateMap,'secondaryOrbitIdx') && ~isempty(stateMap.secondaryOrbitIdx) && txi >= 2
                    info.secondaryTruthPos_m(:,txi-1)  = rTxTruth;
                    info.secondaryTruthVel_mps(:,txi-1) = vTxTruth;
                end

                % When the secondary ORBIT is estimated, the model uses the
                % ESTIMATED tx position (product retired) and H gains a -u' column on the
                % tx r block; else the product position is the model (legacy path).
                orbPosIdx = revgnss.ISLMeasurementBuilder.secondaryOrbitPosIdx_(stateMap, txi);
                if ~isempty(orbPosIdx)
                    rTxModel = x(orbPosIdx);      rTxModel = rTxModel(:);
                    vTxModel = x(orbPosIdx + 3);  vTxModel = vTxModel(:);
                else
                    rTxModel = rTxProd; vTxModel = vTxProd;
                end

                [rhoTruth, rrTruth]   = revgnss.ISLMeasurementBuilder.geometry_( ...
                    primaryAsset.r_ecef_m, primaryAsset.v_ecef_mps, rTxTruth, vTxTruth, info.lightTimeOn, info.c_mps, info.omega_radps);
                [rhoModel, rrModel, u] = revgnss.ISLMeasurementBuilder.geometry_( ...
                    x(stateMap.r_idx), x(stateMap.v_idx), rTxModel, vTxModel, info.lightTimeOn, info.c_mps, info.omega_radps);

                if info.codeEnabled
                    nz = revgnss.ISLMeasurementBuilder.drawNoise_(cfg, txi, epochIdx, 1, info.codeSigma_m, 1);
                    z  = rhoTruth + brxTruth - btxTruth + nz;    % btxTruth no longer cancels when secondary clock is estimated
                    bTxIdx = revgnss.ISLMeasurementBuilder.secondaryClockStateIdx_(stateMap, txi, 1);
                    sigPos2 = info.product.sigmaPos_m^2;      % product-position variance
                    if ~isempty(orbPosIdx); sigPos2 = 0; end  % position estimated -> not an R nuisance
                    if bTxIdx > 0
                        % b_tx is an estimated STATE. h differences x(b_tx); DROP the
                        % product sigmaClock from R. When secondary orbit is estimated (orbPosIdx set) the product
                        % sigmaPos is also dropped (position is a state).
                        h   = rhoModel + x(stateMap.b_rx_idx) - x(bTxIdx);
                        Rii = info.codeSigma_m^2 + sigPos2;
                    else
                        h   = rhoModel + x(stateMap.b_rx_idx) - btxProd;                      % legacy
                        Rii = info.codeSigma_m^2 + sigPos2 + info.product.sigmaClock_m^2;
                    end
                    metaCols = [stateMap.r_idx(:)' stateMap.b_rx_idx];
                    if bTxIdx > 0; metaCols(end+1) = bTxIdx; end
                    if ~isempty(orbPosIdx); metaCols = [metaCols orbPosIdx(:)']; end
                    info = revgnss.ISLMeasurementBuilder.addMeta_(info, 'islCode', txi, ...
                        metaCols, info.codeUseInEKF, bTxIdx);
                    if info.codeUseInEKF
                        row = zeros(1, nx); row(stateMap.r_idx) = u'; row(stateMap.b_rx_idx) = 1;
                        if bTxIdx > 0; row(bTxIdx) = -1; end            % dh/dx(b_tx) = -1
                        if ~isempty(orbPosIdx); row(orbPosIdx) = -u'; end  % dh/dr_tx = -u'
                        [zAdd, hAdd, HAdd, RAdd] = revgnss.ISLMeasurementBuilder.append_( ...
                            zAdd, hAdd, HAdd, RAdd, z, h, row, Rii);
                    end
                end
                if info.dopplerEnabled
                    nz = revgnss.ISLMeasurementBuilder.drawNoise_(cfg, txi, epochIdx, 2, info.dopplerSigma_mps, 1);
                    z  = rrTruth + drxTruth - dtxTruth + nz;
                    dTxIdx = revgnss.ISLMeasurementBuilder.secondaryClockStateIdx_(stateMap, txi, 2);
                    sigVel2 = info.product.sigmaVel_mps^2;
                    if ~isempty(orbPosIdx); sigVel2 = 0; end   % velocity estimated
                    if dTxIdx > 0
                        h   = rrModel + x(stateMap.bdot_rx_idx) - x(dTxIdx);
                        Rii = info.dopplerSigma_mps^2 + sigVel2;     % drop sigmaClockDrift
                    else
                        h   = rrModel + x(stateMap.bdot_rx_idx) - dtxProd;              % legacy
                        Rii = info.dopplerSigma_mps^2 + sigVel2 + info.product.sigmaClockDrift_mps^2;
                    end
                    metaCols = [stateMap.v_idx(:)' stateMap.bdot_rx_idx];
                    if dTxIdx > 0; metaCols(end+1) = dTxIdx; end
                    if ~isempty(orbPosIdx); metaCols = [metaCols (orbPosIdx(:)'+3)]; end
                    info = revgnss.ISLMeasurementBuilder.addMeta_(info, 'islDoppler', txi, ...
                        metaCols, info.dopplerUseInEKF, dTxIdx);
                    if info.dopplerUseInEKF
                        row = zeros(1, nx); row(stateMap.v_idx) = u'; row(stateMap.bdot_rx_idx) = 1;
                        if dTxIdx > 0; row(dTxIdx) = -1; end
                        if ~isempty(orbPosIdx); row(orbPosIdx + 3) = -u'; end   % dh/dv_tx = -u'
                        [zAdd, hAdd, HAdd, RAdd] = revgnss.ISLMeasurementBuilder.append_( ...
                            zAdd, hAdd, HAdd, RAdd, z, h, row, Rii);
                    end
                end
                if info.carrierEnabled
                    % ISL carrier phase. The ambiguity is stored in METRES
                    % (B = lambda*N + absorbed bias), matching the ground convention at
                    % CarrierMeasurementBuilder.m:333-335, so dh/dB = +1 (NOT lambda).
                    %
                    %   z = rho_truth + b_rx_truth - b_tx_truth + lambda*N_true + eps
                    %   h = rho_model + x(b_rx) - {x(b_tx) | product} + x(B)
                    %
                    % NOT-IMPLEMENTED (declared, not silently ignored): phase wind-up and
                    % antenna PCO/PCV are absent. A constant part of either is absorbed by
                    % the float ambiguity; only a DRIFT would leave a real residual.
                    ambIdxC = revgnss.ISLMeasurementBuilder.islAmbStateIdx_(stateMap, txi, 1);
                    Btruth  = revgnss.ISLMeasurementBuilder.truthAmbiguity_(cfg, info, txi, 1);
                    nzc = revgnss.ISLMeasurementBuilder.drawNoise_(cfg, txi, epochIdx, 3, info.carrierSigma_m, 1);
                    zc  = rhoTruth + brxTruth - btxTruth + Btruth + nzc;
                    bTxIdxC  = revgnss.ISLMeasurementBuilder.secondaryClockStateIdx_(stateMap, txi, 1);
                    sigPos2c = info.product.sigmaPos_m^2;
                    if ~isempty(orbPosIdx); sigPos2c = 0; end
                    if bTxIdxC > 0
                        hc  = rhoModel + x(stateMap.b_rx_idx) - x(bTxIdxC);
                        Rc  = info.carrierSigma_m^2 + sigPos2c;
                    else
                        hc  = rhoModel + x(stateMap.b_rx_idx) - btxProd;
                        Rc  = info.carrierSigma_m^2 + sigPos2c + info.product.sigmaClock_m^2;
                    end
                    if ambIdxC > 0; hc = hc + x(ambIdxC); end
                    useC = info.carrierUseInEKF && ambIdxC > 0;
                    metaColsC = [stateMap.r_idx(:)' stateMap.b_rx_idx];
                    if bTxIdxC > 0; metaColsC(end+1) = bTxIdxC; end
                    if ~isempty(orbPosIdx); metaColsC = [metaColsC orbPosIdx(:)']; end
                    if ambIdxC > 0; metaColsC(end+1) = ambIdxC; end
                    obsTypeC = 'islCarrierDiagnostic';
                    if useC; obsTypeC = 'islCarrier'; end
                    info = revgnss.ISLMeasurementBuilder.addMeta_(info, obsTypeC, txi, ...
                        metaColsC, useC, bTxIdxC, ambIdxC);
                    info.carrierPrefit_m(end+1,1)    = zc - hc;
                    info.carrierTruthAmbiguity_m(end+1,1) = Btruth;
                    if useC
                        rowC = zeros(1, nx);
                        rowC(stateMap.r_idx)    = u';
                        rowC(stateMap.b_rx_idx) = 1;
                        if bTxIdxC > 0; rowC(bTxIdxC) = -1; end
                        if ~isempty(orbPosIdx); rowC(orbPosIdx) = -u'; end
                        rowC(ambIdxC) = 1;      % dh/dB = +1 (ambiguity in metres)
                        [zAdd, hAdd, HAdd, RAdd] = revgnss.ISLMeasurementBuilder.append_( ...
                            zAdd, hAdd, HAdd, RAdd, zc, hc, rowC, Rc);
                    end
                end
                info.linkEvents = revgnss.ISLTimingModel.buildOneWayEvents( ...
                    cfg, primaryAsset, tx, txi, info.receiverAssetIndex, ...
                    revgnss.ISLMeasurementBuilder.eventRoles_(info), t_s);
            end

            info.zEkf = zAdd;
            info.hEkf = hAdd;
            info.ekfRowTypes = info.ekfRowTypes(:)';
            if ~isempty(zAdd); info.prefitRms = sqrt(mean((zAdd - hAdd).^2)); end
        end

        function list = transmitterList(cfg)
            % transmitterList  Public accessor for the ACTIVE ISL transmitter indices.
            %
            % Config-only (no assets needed) so the EKF can size the ISL ambiguity state
            % block from the same selection the measurement rows will use -- one source of
            % truth for "which links exist". Empty when ISL is disabled or nSpaceAssets<2.
            list = zeros(1,0);
            if ~revgnss.ISLMeasurementBuilder.isEnabled_(cfg); return; end
            nAssets = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'scenario','nSpaceAssets'}, 1);
            if nAssets < 2; return; end
            list = revgnss.ISLMeasurementBuilder.txList_(cfg, nAssets);
        end

        function n = ambiguityStateCount(cfg)
            % ambiguityStateCount  Number of ISL carrier-ambiguity states this config wants
            % (one per active link x signal), or 0 when the gated feature is off. Shared by
            % the EKF sizing arithmetic and the state-map walk so the two cannot disagree.
            n = 0;
            if ~revgnss.ISLMeasurementBuilder.islAmbiguityEnabled(cfg); return; end
            nLinks = numel(revgnss.ISLMeasurementBuilder.transmitterList(cfg));
            n = nLinks * revgnss.ISLMeasurementBuilder.islAmbiguityNSignals(cfg);
        end

        function tf = islAmbiguityEnabled(cfg)
            % islAmbiguityEnabled  Master gate for ISL carrier-ambiguity STATES.
            %
            % INDEPENDENT of the ground ambiguity switches (cfg.estimation.ambiguityMode /
            % cfg.estimation.ambiguity.*) by design: ISL and ground-to-space must be
            % togglable separately, and sharing a sigma would couple three unrelated sinks
            % (P0, the truth ambiguity draw, and the cycle-slip reset).
            g = @(p) revgnss.ISLMeasurementBuilder.getBool_(cfg, p, false);
            tf = g({'measurements','isl','enable'}) && ...
                 g({'measurements','isl','carrier','enable'}) && ...
                 g({'measurements','isl','carrier','ambiguity','enable'});
        end

        function n = islAmbiguityNSignals(cfg)
            n = revgnss.ISLMeasurementBuilder.getNum_(cfg, ...
                {'measurements','isl','carrier','ambiguity','nSignals'}, 1);
            n = max(1, round(n));
        end

        function pb = productBiasForAsset(cfg, ai, t_s)
            % productBiasForAsset  Public accessor for a secondary's broadcast-product
            % ephemeris/clock error at time t_s (pb.pos/vel/clk/clkDrift). Same
            % realization the ISL rows use, so ground measurement rows see a CONSISTENT secondary
            % product across both link types. Zero when the product is disabled.
            p  = revgnss.ISLMeasurementBuilder.productCfg_(cfg);
            iv = revgnss.ISLMeasurementBuilder.productInterval_(p, t_s);
            pb = revgnss.ISLMeasurementBuilder.productBias_(cfg, p, ai, iv);
        end

        function h = predictEkfRows(cfg, primaryAsset, assets, x, stateMap, info)
            h = [];
            if isempty(info) || ~isfield(info,'ekfRowTypes') || isempty(info.ekfRowTypes); return; end
            intervalIdx = 0;
            if isfield(info,'productIntervalIdx'); intervalIdx = info.productIntervalIdx; end
            hasSec = isfield(info,'ekfRowSecIdx') && numel(info.ekfRowSecIdx) == numel(info.ekfRowTypes);
            hasAmb = isfield(info,'ekfRowAmbIdx') && numel(info.ekfRowAmbIdx) == numel(info.ekfRowTypes);
            for k = 1:numel(info.ekfRowTypes)
                txi = info.ekfRowTx(k);
                tx  = assets{txi};
                pb  = revgnss.ISLMeasurementBuilder.productBias_(cfg, info.product, txi, intervalIdx);
                [rhoModel, rrModel] = revgnss.ISLMeasurementBuilder.geometry_( ...
                    x(stateMap.r_idx), x(stateMap.v_idx), tx.r_ecef_m(:) + pb.pos, tx.v_ecef_mps(:) + pb.vel, ...
                    info.lightTimeOn, info.c_mps, info.omega_radps);
                secIdx = 0; if hasSec; secIdx = info.ekfRowSecIdx(k); end
                switch info.ekfRowTypes{k}
                    case 'islCode'
                        if secIdx > 0
                            h(end+1,1) = rhoModel + x(stateMap.b_rx_idx) - x(secIdx); %#ok<AGROW>
                        else
                            h(end+1,1) = rhoModel + x(stateMap.b_rx_idx) - (tx.clock.getBiasMeters() + pb.clk); %#ok<AGROW>
                        end
                    case 'islDoppler'
                        if secIdx > 0
                            h(end+1,1) = rrModel + x(stateMap.bdot_rx_idx) - x(secIdx); %#ok<AGROW>
                        else
                            h(end+1,1) = rrModel + x(stateMap.bdot_rx_idx) - (tx.clock.getDriftMetersPerSecond() + pb.clkDrift); %#ok<AGROW>
                        end
                    case 'islCarrier'
                        % Same structure as islCode PLUS the float ambiguity (metres).
                        ambIdx = 0; if hasAmb; ambIdx = info.ekfRowAmbIdx(k); end
                        if secIdx > 0
                            hk = rhoModel + x(stateMap.b_rx_idx) - x(secIdx);
                        else
                            hk = rhoModel + x(stateMap.b_rx_idx) - (tx.clock.getBiasMeters() + pb.clk);
                        end
                        if ambIdx > 0; hk = hk + x(ambIdx); end
                        h(end+1,1) = hk; %#ok<AGROW>
                end
            end
        end

        function info = defaultInfo(cfg, assets)
            info = struct();
            info.enabled = revgnss.ISLMeasurementBuilder.isEnabled_(cfg);
            nAssets = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'scenario','nSpaceAssets'}, numel(assets));
            info.receiverAssetIndex = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','receiverAssetIndex'}, 1);
            info.transmitterList = revgnss.ISLMeasurementBuilder.txList_(cfg, nAssets);
            if isempty(info.transmitterList); info.transmitterList = 2; end
            info.transmitterAssetIndex = info.transmitterList(1);   % representative (first) tx for descriptors
            info.transmitterAssetName = '';
            info.receiverAssetName = '';
            info.transmitterNames = {};
            for ii = 1:numel(info.transmitterList)
                ti = info.transmitterList(ii);
                if numel(assets) >= ti; info.transmitterNames{ii} = assets{ti}.name;
                else; info.transmitterNames{ii} = sprintf('GEO-%d', ti); end
            end
            if info.enabled && numel(assets) >= info.transmitterAssetIndex
                info.transmitterAssetName = assets{info.transmitterAssetIndex}.name;
                info.receiverAssetName = assets{info.receiverAssetIndex}.name;
            end
            info.codeEnabled = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','code','enable'}, false);
            info.codeUseInEKF = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','code','useInEKF'}, false);
            info.dopplerEnabled = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','doppler','enable'}, false);
            info.dopplerUseInEKF = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','doppler','useInEKF'}, false);
            info.carrierEnabled = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','carrier','enable'}, false);
            % Carrier may enter the EKF only when an ISL ambiguity state exists to hold the
            % integer (validateConfig enforces this as a hard error; here it is also an
            % AND-gate so a mis-set config degrades to diagnostic-only rather than aliasing
            % the integer into position/clock).
            info.carrierUseInEKF = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','carrier','useInEKF'}, false) ...
                && info.carrierEnabled ...
                && revgnss.ISLMeasurementBuilder.islAmbiguityEnabled(cfg);
            info.carrierSigma_m = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','carrier','sigma_m'}, 0.002);
            % ISL carrier frequency -> wavelength. Defaults to L1 so the conventional
            % behaviour is unchanged; an explicit crosslink band (e.g. Ka) can be set
            % without touching SignalDefinition. This is also the hook a future
            % frequency-dependent link-budget sigma would use.
            fIsl = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','carrier','frequency_Hz'}, NaN);
            if ~isfinite(fIsl) || fIsl <= 0
                fIsl = revgnss.SignalDefinition.get('L1').frequency_Hz;
            end
            info.carrierFrequency_Hz = fIsl;
            info.carrierWavelength_m = revgnss.Constants.SPEED_OF_LIGHT_MPS / fIsl;
            info.ambiguityStatesEnabled = revgnss.ISLMeasurementBuilder.islAmbiguityEnabled(cfg);
            info.ambiguityNSignals      = revgnss.ISLMeasurementBuilder.islAmbiguityNSignals(cfg);
            info.ambiguityInitialSigma_m = revgnss.ISLMeasurementBuilder.getNum_(cfg, ...
                {'measurements','isl','carrier','ambiguity','initialSigma_m'}, 100);
            info.carrierPhaseWindupImplemented = false;   % declared, not silently ignored
            info.carrierAntennaPcvImplemented  = false;
            info.carrierPrefit_m           = zeros(0,1);
            info.carrierTruthAmbiguity_m   = zeros(0,1);
            info.codeSigma_m = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','code','sigma_m'}, 0.5);
            info.dopplerSigma_mps = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','doppler','sigma_mps'}, 0.02);
            info.warmup_s = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','warmup_s'}, 0);
            info.warmupActive = false;
            % Gated first-order inter-satellite light-time correction (~1 cm/km). Default off
            % -> geometry_ returns the instantaneous range, byte-identical to the frozen goldens.
            info.lightTimeOn = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','lightTime','enable'}, false);
            info.c_mps       = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            info.omega_radps = revgnss.Constants.EARTH_OMEGA_RADPS;   % ECEF->inertial transport for the tx velocity
            info.product = revgnss.ISLMeasurementBuilder.productCfg_(cfg);
            info.productIntervalIdx = 0;
            info.rows = struct([]);
            info.ekfRowTypes = {};
            info.ekfRowTx = [];
            info.ekfRowSecIdx = [];              % per-EKF-row resolved secondary-clock indices (0=product)
            info.ekfRowAmbIdx = [];              % per-EKF-row resolved ISL ambiguity indices (0=none)
            info.secondaryTruthBias_m = [];      % per-secondary truth clock bias [m] (diagnostic)
            info.secondaryTruthDrift_mps = [];   % per-secondary truth clock drift [m/s]
            % Diagnostic: NaN pre-allocation when a transmitter is out-of-view at this epoch (subset list).
            % A missing link leaves its column NaN -> "unobserved", never a spurious origin (0,0,0).
            nSec_ = max(0, nAssets - 1);
            info.secondaryTruthPos_m = NaN(3, nSec_);    % per-secondary truth position [3 x nSec]
            info.secondaryTruthVel_mps = NaN(3, nSec_);  % per-secondary truth velocity [3 x nSec]
            info.nCodeRows = double(info.codeEnabled) * numel(info.transmitterList);
            info.nDopplerRows = double(info.dopplerEnabled) * numel(info.transmitterList);
            info.nCarrierDiagnosticRows = double(info.carrierEnabled) * numel(info.transmitterList);
            info.nEkfRows = 0;
            info.prefitRms = NaN;
            info.linkEvents = struct([]);
        end
    end

    methods (Static, Access = private)
        function [rho, rangeRate, u] = geometry_(rRx, vRx, rTx, vTx, ltOn, c, omega)
            d = rRx(:) - rTx(:);
            rho = norm(d); if rho < 1; rho = 1; end
            u = d / rho;
            rangeRate = u' * (vRx(:) - vTx(:));
            % Gated first-order inter-satellite light-time. The signal left the transmitter
            % (beacon) at t_tx = t_rx - rho/c, so the physical range is |r_rx - r_tx(t_tx)| ~
            % rho + (u . v_tx_inertial)*(rho/c). The geometry is in the ROTATING ECEF frame, so
            % the transmitter's INERTIAL velocity is v_tx_ecef + omega x r_tx: for a co-rotating
            % GEO the ECEF velocity is ~0 and the omega x r_tx term (the Sagnac transport)
            % DOMINATES -> ~1 cm/km. (u . (omega x r_tx))*(rho/c) equals the standard first-order
            % Sagnac (omega/c)(tx_x*rx_y - tx_y*rx_x), matching the ground-link convention.
            % Cross-validated sub-mm vs Orekit's rigorous inter-satellite light-time. Applied to
            % the measurement VALUE only; the ~1e-5 position partial is dropped from H. Default
            % off (nargin < 5) -> byte-identical.
            if nargin >= 5 && ltOn
                vTxInertial = vTx(:) + cross([0; 0; omega], rTx(:));
                rho = rho + (u' * vTxInertial) * (rho / c);
            end
        end

        function list = txList_(cfg, nAssets)
            % Transmitter selection: 'all' secondaries (2..N), or a specific index.
            sel = revgnss.ISLMeasurementBuilder.walk_(cfg, {'measurements','isl','transmitters'}, 'all');
            if (ischar(sel) || isstring(sel)) && strcmpi(char(sel),'all')
                list = 2:nAssets;
            elseif isnumeric(sel) && ~isempty(sel)
                list = round(sel(:)');
            else
                list = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','transmitterAssetIndex'}, 2);
            end
            list = list(list >= 2 & list <= nAssets);
        end

        function idx = secondaryClockStateIdx_(stateMap, txi, which)
            % which=1 -> bias state, which=2 -> drift state. 0 when the secondary-clock
            % block is absent or txi out of range. Explicit isempty test avoids
            % the 0x2 empty-index trap.
            idx = 0;
            if ~isfield(stateMap,'secondaryClockIdx'); return; end
            S = stateMap.secondaryClockIdx;
            if isempty(S); return; end
            si = txi - 1;                      % asset txi (2..N) -> row si (1..N-1)
            if si < 1 || si > size(S,1); return; end
            idx = S(si, which);
        end

        function posIdx = secondaryOrbitPosIdx_(stateMap, txi)
            % Position state indices (1x3) for secondary txi's estimated orbit, or [] when
            % the orbit block is absent. Velocity indices are posIdx+3.
            posIdx = [];
            if ~isfield(stateMap,'secondaryOrbitIdx'); return; end
            S = stateMap.secondaryOrbitIdx;
            if isempty(S); return; end
            si = txi - 1;
            if si < 1 || si > size(S,1); return; end
            posIdx = S(si, 1:3);
        end

        function p = productCfg_(cfg)
            p.enable            = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','product','enable'}, false);
            p.sigmaPos_m        = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','product','sigmaPos_m'}, 0.0);
            p.sigmaClock_m      = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','product','sigmaClock_m'}, 0.0);
            p.sigmaVel_mps      = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','product','sigmaVel_mps'}, 0.0);
            p.sigmaClockDrift_mps = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','product','sigmaClockDrift_mps'}, 0.0);
            p.updateInterval_s = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'measurements','isl','product','updateInterval_s'}, 300);
            if ~p.enable
                p.sigmaPos_m = 0; p.sigmaClock_m = 0; p.sigmaVel_mps = 0; p.sigmaClockDrift_mps = 0;
            end
            p.seed = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'simulation','seed'}, 42);
        end

        function idx = productInterval_(product, t_s)
            % Broadcast-interval index: the product is re-issued every
            % updateInterval_s, so its error is piecewise-constant (correlated within
            % an interval, independent across intervals) -> it averages down over the
            % run and the white-R model stays consistent.
            dt = 300;
            if isstruct(product) && isfield(product,'updateInterval_s') && product.updateInterval_s > 0
                dt = product.updateInterval_s;
            end
            idx = floor(t_s / dt);
        end

        function pb = productBias_(cfg, product, txi, intervalIdx)
            % Represented-secondary product error for one broadcast interval.
            % Deterministic in (seed, txi, intervalIdx) so build() and predictEkfRows()
            % see the same anchor at a given epoch. Zero when the model is disabled.
            if nargin < 4; intervalIdx = 0; end
            if isstruct(product); p = product; else; p = revgnss.ISLMeasurementBuilder.productCfg_(cfg); end
            pb = struct('pos',zeros(3,1),'vel',zeros(3,1),'clk',0,'clkDrift',0);
            if ~p.enable; return; end
            s = revgnss.ISLMeasurementBuilder.stream_(p.seed, txi, 555, intervalIdx);
            pb.pos      = p.sigmaPos_m        * randn(s,3,1);
            pb.vel      = p.sigmaVel_mps      * randn(s,3,1);
            pb.clk      = p.sigmaClock_m      * randn(s,1);
            pb.clkDrift = p.sigmaClockDrift_mps * randn(s,1);
        end

        function n = drawNoise_(cfg, txi, epochIdx, kind, sigma, dim)
            % Per-epoch, per-link thermal measurement noise on z (reproducible).
            seed = revgnss.ISLMeasurementBuilder.getNum_(cfg, {'simulation','seed'}, 42);
            s = revgnss.ISLMeasurementBuilder.stream_(seed, txi, epochIdx, kind);
            n = sigma * randn(s, dim, 1);
        end

        function s = stream_(seed, txi, epochIdx, kind)
            key = mod(round(seed)*100003 + round(txi)*10007 + round(epochIdx)*97 + round(kind)*7 + 12345, 2^31-1);
            s = RandStream('mt19937ar', 'Seed', key);
        end

        function info = addMeta_(info, obsType, txi, cols, useInEkf, secIdx, ambIdx)
            if nargin < 6; secIdx = 0; end
            if nargin < 7; ambIdx = 0; end
            linkId = sprintf('link:isl:a%03d:a%03d', txi, info.receiverAssetIndex);
            role = 'diagnosticOnly'; if useInEkf; role = 'physicalEKF'; end
            row = revgnss.ObservableRowDescriptor.create(0, obsType, linkId, 'ISL-L1', ...
                NaN, 1, cols, 'ISLMeasurementBuilder one-way spacecraft-to-spacecraft row', role);
            row = revgnss.ObservableRowDescriptor.withFlags(row, ...
                any(strcmp(obsType, {'islCode','islDoppler','islCarrier'})), false);
            if isempty(info.rows); info.rows = row; else; info.rows(end+1) = row; end
            if useInEkf
                info.ekfRowTypes{end+1} = obsType;
                info.ekfRowTx(end+1)    = txi;
                info.ekfRowSecIdx(end+1)= secIdx;   % estimated b_tx/bdot_tx idx (0=product); pushed in lockstep
                info.ekfRowAmbIdx(end+1)= ambIdx;   % ISL ambiguity idx (0=none); pushed in lockstep
                info.nEkfRows = info.nEkfRows + 1;
            end
        end

        function idx = islAmbStateIdx_(stateMap, txi, signalIdx)
            % ISL ambiguity state index for transmitter txi / signal signalIdx, or 0 when
            % the block is absent. Rows of islAmbiguityIdx follow the ORDER of the active
            % transmitter list (registerIslBlock), so txi must be mapped through that list
            % rather than used as a raw row subscript.
            idx = 0;
            if ~isfield(stateMap,'islAmbiguityIdx'); return; end
            M = stateMap.islAmbiguityIdx;
            if isempty(M); return; end
            if ~isfield(stateMap,'islAmbiguityTxList') || isempty(stateMap.islAmbiguityTxList)
                return
            end
            r = find(stateMap.islAmbiguityTxList == txi, 1);
            if isempty(r) || r > size(M,1); return; end
            if signalIdx < 1 || signalIdx > size(M,2); return; end
            idx = M(r, signalIdx);
        end

        function B = truthAmbiguity_(cfg, info, txi, signalIdx)
            % Truth carrier ambiguity for one ISL link: a CONSTANT integer number of
            % cycles, drawn once per (link, signal) from a stream keyed WITHOUT the epoch
            % index so it does not change over the run (an ambiguity is constant within an
            % arc by definition). Mirrors the ground truth draw at
            % CarrierMeasurementBuilder.m:141-151, including the initialSigma/lambda scaling.
            lam = info.carrierWavelength_m;
            if ~isfinite(lam) || lam <= 0; B = 0; return; end
            s = revgnss.ISLMeasurementBuilder.stream_( ...
                revgnss.ISLMeasurementBuilder.getNum_(cfg, {'simulation','seed'}, 42), ...
                txi, 0, 900 + signalIdx);          % epochIdx=0 -> constant over the run
            nCycles = round((info.ambiguityInitialSigma_m / lam) * randn(s, 1));
            B = lam * nCycles;
        end

        function [z, h, H, R] = append_(z, h, H, R, zi, hi, Hi, ri)
            z = [z; zi]; h = [h; hi]; H = [H; Hi];
            R = blkdiag(R, ri);
        end

        function roles = eventRoles_(info)
            roles = {};
            if info.codeEnabled;    roles{end+1} = revgnss.ISLMeasurementBuilder.roleName_(info.codeUseInEKF); end
            if info.dopplerEnabled; roles{end+1} = revgnss.ISLMeasurementBuilder.roleName_(info.dopplerUseInEKF); end
            if info.carrierEnabled; roles{end+1} = 'diagnosticOnly'; end
        end

        function role = roleName_(useInEkf)
            role = 'diagnosticOnly';
            if useInEkf; role = 'EKF'; end
        end

        function tf = isEnabled_(cfg)
            tf = revgnss.ISLMeasurementBuilder.getBool_(cfg, {'measurements','isl','enable'}, false);
        end

        function tf = getBool_(cfg, path, defaultValue)
            v = revgnss.ISLMeasurementBuilder.walk_(cfg, path, defaultValue);
            tf = islogical(v) && isscalar(v) && v;
        end

        function v = getNum_(cfg, path, defaultValue)
            v = revgnss.ISLMeasurementBuilder.walk_(cfg, path, defaultValue);
            if ~isnumeric(v) || ~isscalar(v); v = defaultValue; end
        end

        function v = walk_(cfg, path, defaultValue)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k});
                else; v = defaultValue; return; end
            end
        end
    end
end
