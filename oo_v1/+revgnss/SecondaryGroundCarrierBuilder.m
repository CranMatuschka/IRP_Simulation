classdef SecondaryGroundCarrierBuilder
    % SecondaryGroundCarrierBuilder  Phase-1 per-secondary symmetry: tower -> secondary
    % CARRIER-phase rows with a per-(secondary,tower) float-ambiguity state.
    %
    % Promotes each secondary from code-only toward a full single-asset model: the same
    % near-radial ground line of sight the WP5 code row uses, but at carrier precision
    % (~mm thermal) with a float ambiguity, mirroring the chief's tower carrier machinery.
    %
    %   z = rho(tower_truth, r_sec_truth) + b_sec_true - b_twr + B_true + noise_phi
    %   h = rho(tower_model, x(r_sec))    + x(b_sec)   - b_twr + x(amb)
    %   H: +u_ts' on the secondary position, +1 on the secondary clock, +1 on the ambiguity
    %      (ambiguity stored in metres, like the chief). NO primary-state column
    %      (anti-circularity: every row touches exactly ONE asset -> primary moves only
    %      through the covariance cross-terms).
    %
    % Reverse-GNSS convention: the tower TRANSMITS, the secondary RECEIVES, so the secondary
    % clock enters with +1 (opposite of the ISL sign, matching the WP5 code row).
    %
    % R = sigma_phi^2 only: the float ambiguity absorbs the constant tower-clock offset, so
    % (unlike the code row) no tower-clock/product variance is charged to R (mirrors the
    % chief carrier note). Atmosphere is MATCHED here (cancels); the divergent per-LOS
    % atmosphere + per-secondary iono states are Phase 2 (the carrier iono sign differs, so
    % it is deferred rather than injected wrong-sign).
    %
    % GATE: MultiAssetConfig.secondaryCarrierCount (requires estimateMode='position' +
    % towersObserveSecondaries + carrier.enable) AND a secondaryAmbiguityIdx block. Off /
    % single-asset -> nSec<1 -> empty stacks -> byte-identical.
    %
    %   [z,h,H,R,info] = revgnss.SecondaryGroundCarrierBuilder.build( ...
    %       cfg, errorChain, assets, towers, x, stateMap, nx, t_s);

    methods (Static)
        function [zAdd, hAdd, HAdd, RAdd, info] = build(cfg, errorChain, assets, towers, x, stateMap, nx, t_s)
            info = struct('enabled', false, 'nRows', 0, 'rowAsset', [], 'rowTower', [], 'prefitRms', NaN);
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);

            nSec = revgnss.MultiAssetConfig.secondaryCarrierCount(cfg);
            if nSec < 1 || ~isfield(stateMap, 'secondaryAmbiguityIdx') || isempty(stateMap.secondaryAmbiguityIdx) ...
                    || ~isfield(stateMap, 'secondaryOrbitIdx') || isempty(stateMap.secondaryOrbitIdx) ...
                    || ~isfield(stateMap, 'secondaryClockIdx') || isempty(stateMap.secondaryClockIdx)
                return;
            end
            info.enabled = true;

            g = @(p, d) revgnss.SecondaryGroundCarrierBuilder.getNum_(cfg, p, d);
            sigma    = g({'multiAsset','towerSecondary','carrier','sigma_m'}, 0.005);
            ambSpread = g({'multiAsset','towerSecondary','carrier','initialSigma_m'}, 100);
            elevMask = g({'estimator','elevationMask_rad'}, 5*pi/180);
            dt       = g({'simulation','dt_s'}, 1);
            epochIdx = 0; if dt > 0; epochIdx = round(t_s / dt); end
            lambda   = g({'signals','L1','lambda_m'}, 0.1903);
            ambStd   = min(ambSpread, 10);   % truth ambiguity spread [m] (well inside the P0 prior)
            % Conservative R padding: the float ambiguity absorbs only the CONSTANT tower-clock
            % offset; a drifting tower-clock residual is not, so charge the same product residual
            % the code row does (nCorr * towerClkSigma^2) -> carrier R no less conservative.
            nCorr    = max(1, g({'multiAsset','towerSecondary','productNCorr'}, 30));
            twClkSig = g({'multiAsset','towerSecondary','towerClkSigma_m'}, 0.03);
            Rtwr     = nCorr * twClkSig^2;

            nAssets  = numel(assets);
            rowAsset = []; rowTower = [];
            for ai = 2:nAssets
                si = ai - 1;
                if si > size(stateMap.secondaryClockIdx, 1) || si > size(stateMap.secondaryOrbitIdx, 1) ...
                        || si > size(stateMap.secondaryAmbiguityIdx, 1)
                    continue;
                end
                bTxIdx = stateMap.secondaryClockIdx(si, 1);
                orbPosIdx = stateMap.secondaryOrbitIdx(si, 1:3);
                if bTxIdx <= 0 || any(orbPosIdx <= 0); continue; end
                sec       = assets{ai};
                rSecTruth = sec.getAntennaPositionECEF();
                rSecModel = x(orbPosIdx); rSecModel = rSecModel(:);
                bTxTruth  = sec.clock.getBiasMeters();
                for ti = 1:numel(towers)
                    ambIdx = stateMap.secondaryAmbiguityIdx(si, ti);
                    if ambIdx <= 0; continue; end
                    elev = towers{ti}.computeElevationTo(rSecTruth);
                    if ~(elev >= elevMask); continue; end
                    rTwrT = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth', t_s);
                    rTwrM = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'model');
                    [rhoT, ~] = models.corrections.RangeCorrections.correctedPseudorange(rSecTruth, rTwrT, cfg, 'truth', elev, t_s);
                    [rhoM, ~] = models.corrections.RangeCorrections.correctedPseudorange(rSecModel, rTwrM, cfg, 'model', elev, t_s);
                    bTwr = towers{ti}.getClockBiasMeters();
                    node = ti*32 + ai;
                    % CONSTANT per-(tower,secondary) integer-like truth ambiguity [m]. Uses an
                    % INTERVAL-keyed draw with a FIXED interval (k=0) -> deterministic, identical
                    % every epoch (a carrier ambiguity must be constant over the arc). Mirrors the
                    % P2'/sat<->sat constant-bias pattern; do NOT use drawKeyedPersistent here (it
                    % advances the stream, giving a fresh value each epoch = injected noise).
                    nCyc  = round((ambStd / lambda) * errorChain.drawKeyedInterval( ...
                        models.noise.RngSource.SEC_CARR_AMB, node, 0, 0, 0));
                    Btrue = nCyc * lambda;
                    nz    = sigma * errorChain.drawKeyed( ...
                        models.noise.RngSource.SEC_CARR_PHASE, node, 0, 1, epochIdx, 1, 1);
                    z = rhoT + bTxTruth  - bTwr + Btrue + nz;
                    h = rhoM + x(bTxIdx) - bTwr + x(ambIdx);
                    d = rSecModel - rTwrM; nd = norm(d); if nd < 1; nd = 1; end
                    row = zeros(1, nx);
                    row(orbPosIdx) = (d / nd)';   % dh/dr_sec = +u_ts'
                    row(bTxIdx)    = 1;           % receiver (secondary) clock -> +1
                    row(ambIdx)    = 1;           % float ambiguity (metres)
                    zAdd(end+1,1) = z;    %#ok<AGROW>
                    hAdd(end+1,1) = h;    %#ok<AGROW>
                    HAdd(end+1,:) = row;  %#ok<AGROW>
                    RAdd = blkdiag(RAdd, sigma^2 + Rtwr);
                    rowAsset(end+1) = ai; %#ok<AGROW>
                    rowTower(end+1) = ti; %#ok<AGROW>
                end
            end
            info.nRows    = numel(zAdd);
            info.rowAsset = rowAsset;
            info.rowTower = rowTower;
            if info.nRows > 0; info.prefitRms = sqrt(mean((zAdd - hAdd).^2)); end
        end

        function validateConfig(cfg)
            gb = @(p) revgnss.SecondaryGroundCarrierBuilder.getBool_(cfg, p, false);
            if ~gb({'multiAsset','towerSecondary','carrier','enable'}); return; end
            mode = 'off';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'estimateMode')
                mode = char(cfg.multiAsset.estimateMode);
            end
            if ~strcmp(mode, 'position')
                error('SecondaryGroundCarrierBuilder:needsPosition', ...
                    ['towerSecondary.carrier.enable requires cfg.multiAsset.estimateMode=''position'' ' ...
                     '(the carrier row needs the secondary''s estimated r/v geometric column).']);
            end
            if ~gb({'multiAsset','towersObserveSecondaries'})
                error('SecondaryGroundCarrierBuilder:needsGroundRows', ...
                    'towerSecondary.carrier.enable requires cfg.multiAsset.towersObserveSecondaries=true.');
            end
            s = revgnss.SecondaryGroundCarrierBuilder.getNum_(cfg, {'multiAsset','towerSecondary','carrier','sigma_m'}, 0.005);
            if ~(isfinite(s) && s > 0)
                error('SecondaryGroundCarrierBuilder:sigma', 'towerSecondary.carrier.sigma_m must be a positive scalar.');
            end
        end
    end

    methods (Static, Access = private)
        function v = getNum_(cfg, path, dflt)
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; v = dflt; return; end
            end
            if ~(isnumeric(v) && isscalar(v)); v = dflt; end
        end

        function tf = getBool_(cfg, path, dflt)
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; tf = dflt; return; end
            end
            tf = islogical(v) && isscalar(v) && v;
        end
    end
end
