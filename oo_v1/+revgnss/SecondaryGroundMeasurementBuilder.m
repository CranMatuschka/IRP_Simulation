classdef SecondaryGroundMeasurementBuilder
    % SecondaryGroundMeasurementBuilder  WP5 ground-tower -> secondary pseudorange rows.
    %
    % Each visible ground tower observes a secondary asset's estimated CLOCK bias b_tx
    % at a near-radial line of sight against the KNOWN (product-corrected) tower clock:
    %     z = rho(tower, r_sec_truth)   + b_tx_truth - b_twr + thermal
    %     h = rho(tower, r_sec_product) + x(b_tx)     - b_twr            (tower clock matched)
    %     H(b_tx) = +1
    % so b_tx is anchored to the GROUND ABSOLUTELY -- independent of the primary radial --
    % curing the WP3 limitation (b_tx near-degenerate with the primary radial through the
    % ~horizontal ISL LOS). The row has NO primary-state columns, so it is golden-safe when
    % off / nSpaceAssets=1, and the primary can only change through the P cross-covariance
    % (it should improve, not degrade).
    %
    % Reverse-GNSS convention (tower TRANSMITS, spacecraft RECEIVES): the RECEIVER
    % (secondary) clock is +, so H(b_tx) = +1 -- the OPPOSITE of the ISL row where the
    % secondary is the transmitter (-1, ISLMeasurementBuilder).
    %
    % HONESTY (documented limitations of this first version):
    %  * Atmosphere is MATCHED (truth==model) so it cancels in the mean; no tropo/iono
    %    residual is injected and R has no atmospheric term. Realistic residual is a
    %    follow-up (draw a tropo/iono stack and leave a model-side residual).
    %  * The tower clock is matched in the MEAN (unbiased) but its product residual is
    %    charged into R (towerClkSigma) so the filter does not assume perfect tower time.
    %  * The secondary ephemeris product error (pb.pos, same realization as ISL) is
    %    piecewise-CONSTANT over its broadcast interval; R inflates its variance by
    %    productNCorr so the sequential white-R filter cannot average the shared error
    %    down (~sqrt(N)) -> over-confidence guard (mirrors TWSTFT conservativeProductCorrelation).

    methods (Static)
        function [zAdd, hAdd, HAdd, RAdd, info] = build(cfg, errorChain, assets, towers, x, stateMap, nx, t_s)
            if nargin < 8; t_s = 0; end
            info = struct('enabled', false, 'nRows', 0, 'rowAsset', [], 'rowTower', [], 'prefitRms', NaN);
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);

            % Gate: WP5 on AND WP3 secondary-clock states present.
            nSec = revgnss.MultiAssetConfig.groundSecondaryRowCount(cfg);
            if nSec < 1 || ~isfield(stateMap, 'secondaryClockIdx') || isempty(stateMap.secondaryClockIdx)
                return;
            end
            info.enabled = true;

            g = @(p, d) revgnss.SecondaryGroundMeasurementBuilder.getNum_(cfg, p, d);
            sigma    = g({'multiAsset','towerSecondary','code','sigma_m'}, 1.0);
            nCorr    = max(1, g({'multiAsset','towerSecondary','productNCorr'}, 30));
            twClkSig = g({'multiAsset','towerSecondary','towerClkSigma_m'}, 0.03);
            elevMask = g({'estimator','elevationMask_rad'}, 5*pi/180);
            dt       = g({'simulation','dt_s'}, 1);
            epochIdx = 0; if dt > 0; epochIdx = round(t_s / dt); end
            % Product-position uncertainty is nonzero only when the ISL product is enabled
            % (else the secondary ephemeris is perfect and pb.pos == 0).
            productSigmaPos = 0;
            if revgnss.SecondaryGroundMeasurementBuilder.getBool_(cfg, {'measurements','isl','product','enable'}, false)
                productSigmaPos = g({'measurements','isl','product','sigmaPos_m'}, 0);
            end
            Rprod = nCorr * (productSigmaPos^2 + twClkSig^2);

            nAssets = numel(assets);
            rowAsset = []; rowTower = [];
            for ai = 2:nAssets
                si = ai - 1;
                if si > size(stateMap.secondaryClockIdx, 1); continue; end
                bTxIdx = stateMap.secondaryClockIdx(si, 1);
                if bTxIdx <= 0; continue; end
                sec       = assets{ai};
                rSecTruth = sec.getAntennaPositionECEF();                                  % truth antenna ECEF
                pb        = revgnss.ISLMeasurementBuilder.productBiasForAsset(cfg, ai, t_s);
                rSecProd  = rSecTruth + pb.pos;                                            % product ephemeris
                bTxTruth  = sec.clock.getBiasMeters();
                for ti = 1:numel(towers)
                    elev = towers{ti}.computeElevationTo(rSecTruth);
                    if ~(elev >= elevMask); continue; end
                    rTwrT = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth', t_s);
                    rTwrM = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'model');
                    [rhoT, ~] = models.corrections.RangeCorrections.correctedPseudorange(rSecTruth, rTwrT, cfg, 'truth', elev, t_s);
                    [rhoM, ~] = models.corrections.RangeCorrections.correctedPseudorange(rSecProd, rTwrM, cfg, 'model', elev, t_s);
                    bTwr = towers{ti}.getClockBiasMeters();                                % matched tower clock (mean)
                    node = ti*32 + ai;                                                    % packed into the mod-65536 node field
                    nz   = sigma * errorChain.drawKeyed(models.noise.RngSource.TOWER_SECONDARY, node, 0, 1, epochIdx, 1, 1);
                    z = rhoT + bTxTruth   - bTwr + nz;
                    h = rhoM + x(bTxIdx)  - bTwr;
                    Rii = sigma^2 + Rprod;
                    row = zeros(1, nx); row(bTxIdx) = 1;                                   % receiver clock -> +1
                    zAdd(end+1,1) = z;      %#ok<AGROW>
                    hAdd(end+1,1) = h;      %#ok<AGROW>
                    HAdd(end+1,:) = row;    %#ok<AGROW>
                    RAdd = blkdiag(RAdd, Rii);
                    rowAsset(end+1) = ai;   %#ok<AGROW>
                    rowTower(end+1) = ti;   %#ok<AGROW>
                end
            end
            info.nRows    = numel(zAdd);
            info.rowAsset = rowAsset;
            info.rowTower = rowTower;
            if info.nRows > 0; info.prefitRms = sqrt(mean((zAdd - hAdd).^2)); end
        end
    end

    methods (Static, Access = private)
        function v = getNum_(cfg, path, dflt)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; v = dflt; return; end
            end
            if ~(isnumeric(v) && isscalar(v)); v = dflt; end
        end

        function tf = getBool_(cfg, path, dflt)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; tf = dflt; return; end
            end
            tf = islogical(v) && isscalar(v) && v;
        end
    end
end
