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

            % Guard A: divergent uplink atmosphere (truth-side, per-tower-shared, interval-
            % correlated, elevation-mapped). Default off -> byte-identical to the pre-guard row.
            gb = @(p) revgnss.SecondaryGroundMeasurementBuilder.getBool_(cfg, p, false);
            atmoOn   = gb({'multiAsset','towerSecondary','atmosphere','enable'});
            aTropZen = g({'multiAsset','towerSecondary','atmosphere','sigmaTropZen_m'}, 0.05);
            aIonoZen = g({'multiAsset','towerSecondary','atmosphere','sigmaIonoZen_m'}, 0.20);
            aTauTrop = g({'multiAsset','towerSecondary','atmosphere','tauTrop_s'}, 1800);
            aTauIono = g({'multiAsset','towerSecondary','atmosphere','tauIono_s'}, 600);
            aShellH  = g({'multiAsset','towerSecondary','atmosphere','ionoShellHeight_m'}, 350e3);
            aChargeR = gb({'multiAsset','towerSecondary','atmosphere','chargeR'});
            aNCap    = g({'multiAsset','towerSecondary','atmosphere','nCorrCap'}, 60);
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;

            nAssets = numel(assets);
            rowAsset = []; rowTower = [];
            for ai = 2:nAssets
                si = ai - 1;
                if si > size(stateMap.secondaryClockIdx, 1); continue; end
                bTxIdx = stateMap.secondaryClockIdx(si, 1);
                if bTxIdx <= 0; continue; end
                sec       = assets{ai};
                rSecTruth = sec.getAntennaPositionECEF();                                  % truth antenna ECEF
                % P1'/WP4: when the secondary ORBIT is estimated, the model uses the
                % ESTIMATED position and H gains a +u_ts' column (this near-radial ground
                % LOS is what makes the secondary POSITION observable); product retired.
                orbPosIdx = [];
                if isfield(stateMap,'secondaryOrbitIdx') && ~isempty(stateMap.secondaryOrbitIdx) && ...
                        si <= size(stateMap.secondaryOrbitIdx,1)
                    orbPosIdx = stateMap.secondaryOrbitIdx(si, 1:3);
                end
                if ~isempty(orbPosIdx)
                    rSecModel = x(orbPosIdx); rSecModel = rSecModel(:);   % estimated position (column)
                    RprodRow  = sigma^2;   % position + (its product) now a state -> drop product-pos variance
                else
                    pb        = revgnss.ISLMeasurementBuilder.productBiasForAsset(cfg, ai, t_s);
                    rSecModel = rSecTruth + pb.pos;                                        % product ephemeris (legacy)
                    RprodRow  = sigma^2 + Rprod;
                end
                bTxTruth  = sec.clock.getBiasMeters();
                for ti = 1:numel(towers)
                    elev = towers{ti}.computeElevationTo(rSecTruth);
                    if ~(elev >= elevMask); continue; end
                    rTwrT = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth', t_s);
                    rTwrM = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'model');
                    [rhoT, ~] = models.corrections.RangeCorrections.correctedPseudorange(rSecTruth, rTwrT, cfg, 'truth', elev, t_s);
                    [rhoM, ~] = models.corrections.RangeCorrections.correctedPseudorange(rSecModel, rTwrM, cfg, 'model', elev, t_s);
                    bTwr = towers{ti}.getClockBiasMeters();                                % matched tower clock (mean)
                    node = ti*32 + ai;                                                    % packed into the mod-65536 node field
                    nz   = sigma * errorChain.drawKeyed(models.noise.RngSource.TOWER_SECONDARY, node, 0, 1, epochIdx, 1, 1);
                    % Guard A: truth-side divergent uplink atmosphere (into z only -> cannot cancel).
                    dAtmo = 0; Ratmo = 0;
                    if atmoOn && dt > 0
                        [dAtmo, Ratmo] = revgnss.SecondaryGroundMeasurementBuilder.losUplinkAtmo_( ...
                            errorChain, ti, elev, t_s, dt, elvFloor, ...
                            aTropZen, aIonoZen, aTauTrop, aTauIono, aShellH, aNCap, aChargeR);
                    end
                    z = rhoT + bTxTruth   - bTwr + nz + dAtmo;
                    h = rhoM + x(bTxIdx)  - bTwr;
                    Rii = RprodRow + Ratmo;
                    row = zeros(1, nx); row(bTxIdx) = 1;                                   % receiver clock -> +1
                    if ~isempty(orbPosIdx)
                        d = rSecModel - rTwrM; nd = norm(d); if nd < 1; nd = 1; end
                        row(orbPosIdx) = (d / nd)';                                        % dh/dr_sec = +u_ts'
                    end
                    % Phase-2: per-secondary ZWD state models the (Guard A) truth-side tropo
                    % residual with the same wet mapping m_w -> the ZWD absorbs it. Gated on the
                    % state existing -> byte-identical when off.
                    if isfield(stateMap,'secondaryZwdIdx') && ~isempty(stateMap.secondaryZwdIdx) && ...
                            si <= size(stateMap.secondaryZwdIdx,1)
                        zwdIdx = stateMap.secondaryZwdIdx(si, ti);
                        if zwdIdx > 0
                            m_w = 1 / max(sin(elev), sin(elvFloor));
                            h = h + m_w * x(zwdIdx);
                            row(zwdIdx) = m_w;
                        end
                    end
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

        function [dAtmo, Ratmo] = losUplinkAtmo_(ec, ti, el, t_s, dt, elvFloor, ...
                sTrop, sIono, tauT, tauI, shellH, nCap, chargeR)
            % PER-TOWER zenith GM (node = ti), SHARED across all secondaries this tower
            % observes; per-LOS divergence comes ONLY from the elevation mapping (so the
            % secondary-secondary axis stays correlated -> the wall cannot average down).
            % sig 0=tropo, 1=iono. Truth-side metres.
            gT  = revgnss.SecondaryGroundMeasurementBuilder.unitProc_(ec, ti, 0, tauT, t_s);
            gI  = revgnss.SecondaryGroundMeasurementBuilder.unitProc_(ec, ti, 1, tauI, t_s);
            m_w = 1 / max(sin(el), sin(elvFloor));                                    % wet-tropo mapping
            M_i = models.atmosphere.MappingFunctions.ionosphere(el, 'thinShell', shellH); % iono obliquity
            dAtmo = sTrop*m_w*gT + sIono*M_i*gI;
            if chargeR
                nT = min(max(tauT/dt,1), nCap);  nI = min(max(tauI/dt,1), nCap);
                Ratmo = nT*(sTrop*m_w)^2 + nI*(sIono*M_i)^2;   % correlated bias: white R cannot average it
            else
                Ratmo = 0;                                     % honest-gate default: leave for Guard C NEES
            end
        end

        function gval = unitProc_(ec, node, sig, tau, t_s)
            % Continuous, unit-variance, interval-correlated process: piecewise-linear
            % interpolation between per-interval knots (k=floor(t/tau)). C0, correlation
            % length ~tau, NOT white, order-independent (pure fn of node/sig/t).
            k  = floor(t_s/tau);  f = t_s/tau - k;
            u0 = ec.drawKeyedInterval(models.noise.RngSource.ATMO_SEC_UPLINK, node, 0, sig, k);
            u1 = ec.drawKeyedInterval(models.noise.RngSource.ATMO_SEC_UPLINK, node, 0, sig, k+1);
            gval = ((1-f)*u0 + f*u1) / sqrt((1-f)^2 + f^2);
        end
    end
end
