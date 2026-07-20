classdef SecondaryMeasurementProfile
    % SecondaryMeasurementProfile  Per-asset measurement-behaviour selector (Phase 3b-2).
    %
    % The shared measurement builders (MeasurementModel.computeMeasurements and the Code/Carrier
    % builders) emit rows for ONE asset per call, selected by assetIdx. Chief and secondary rows
    % differ in ~8 physics/RNG axes (RNG source + node, code sigma model, tower-clock treatment,
    % atmosphere source, ZWD mapping, Doppler on/off, R product-padding). This value object carries
    % that selection so ONE builder can serve any satellite:
    %
    %   p = models.measurements.SecondaryMeasurementProfile.forAsset(cfg, assetIdx)
    %
    %   assetIdx == 1  ->  p.isChief = true. The chief pipeline is UNTOUCHED by 3b-2: the builders
    %                      ignore the profile and run today's exact path (ErrorChain noise +
    %                      atmosphere, real product tower clock, elevation-dependent code sigma,
    %                      CARR_AMB/CARR_PHASE draws at node=(tower,antenna,sig), Doppler on). So
    %                      golden + chief swarm rows are byte-identical BY CONSTRUCTION.
    %
    %   assetIdx >= 2  ->  p.isChief = false. Reproduces the retired revgnss.SecondaryGround-
    %                      MeasurementBuilder realization EXACTLY (the FAITHFUL retirement, §15):
    %                        code thermal : RngSource.TOWER_SECONDARY, node = ti*32+ai, FLAT sigma
    %                        carrier amb  : RngSource.SEC_CARR_AMB  (drawKeyedInterval, one-shot)
    %                        carrier phase: RngSource.SEC_CARR_PHASE (drawKeyed, white)
    %                        atmosphere   : Guard-A per-TOWER uplink GM (RngSource.ATMO_SEC_UPLINK,
    %                                       node = ti, shared across secondaries -> correlated)
    %                        tower clock  : MATCHED (same value in z and h -> mean-cancels)
    %                        ZWD mapping  : 'simple' 1/sin
    %                        Doppler      : OFF
    %                        R            : product-pad nCorr*(productSigmaPos^2 + towerClkSigma^2)
    %
    % 3b-3 (deferred) is where the secondary profile is deliberately migrated toward the chief's
    % richer physics, each axis with an R_new >= R_old conservatism proof. 3b-2 does not change any
    % number: it only removes the duplicate code path.

    methods (Static)
        function p = forAsset(cfg, assetIdx)
            if nargin < 2 || isempty(assetIdx); assetIdx = 1; end
            p = struct();
            p.assetIdx = assetIdx;
            p.isChief  = (assetIdx == 1);

            if p.isChief
                % Chief sentinel. The builders do not consult these under 3b-2 (chief path
                % untouched); populated for symmetry and the equivalence unit test.
                p.emitDoppler    = true;
                p.useErrorChain  = true;
                p.towerClockMode = 'realProduct';
                p.atmosphereMode = 'errorChain';
                p.zwdMappingKind = models.measurements.MeasurementModelUtils.zwdMappingKind(cfg);
                p.code = struct('source', models.noise.RngSource.CODE, ...
                                'sigmaModel', 'elevation', 'flatSigma_m', NaN, 'nodeScheme', 'chief');
                p.carrier = struct('ambSource', models.noise.RngSource.CARR_AMB, ...
                                   'phaseSource', models.noise.RngSource.CARR_PHASE, ...
                                   'sigma_m', NaN, 'ambStd_m', NaN, 'nodeScheme', 'chief');
                p.rPad = struct('enable', false, 'nCorr', 0, 'towerClkSigma_m', 0, 'productSigmaPos_m', 0);
                return;
            end

            % --- Secondary profile (assetIdx >= 2): the retired builder's realization + 3b-3 physics ---
            ts = cfg.multiAsset.towerSecondary;
            % Phase 3b-3 Axis 4: tower->secondary Doppler (default ON in honest mode). Only meaningful
            % in position mode (needs the velocity state) -- computeSecondaryGroundRows guards on blk.v.
            dopEnable = isfield(ts,'doppler') && isfield(ts.doppler,'enable') && ts.doppler.enable;
            dopSigma  = 0.05;
            if isfield(ts,'doppler') && isfield(ts.doppler,'sigma_mps'); dopSigma = ts.doppler.sigma_mps; end
            twClkDriftSigma = 1e-3;
            if isfield(ts,'towerClkDriftSigma_mps'); twClkDriftSigma = ts.towerClkDriftSigma_mps; end
            p.emitDoppler = dopEnable;
            p.doppler = struct( ...
                'source',                 models.noise.RngSource.SEC_DOPPLER, ...
                'sigma_mps',              dopSigma, ...
                'towerClkDriftSigma_mps', twClkDriftSigma, ...
                'nodeScheme',             'towerAsset32');
            p.useErrorChain  = false;
            p.towerClockMode = 'matched';
            if isfield(ts, 'atmosphere') && isfield(ts.atmosphere, 'enable') && ts.atmosphere.enable
                p.atmosphereMode = 'guardAUplink';
            else
                p.atmosphereMode = 'none';
            end
            p.zwdMappingKind = 'simple';   % 1/sin(elev); secondaries do NOT adopt chief zwdMappingKind

            % Phase 3b-3 Axis 1: 'flat' (today) or 'chiefFloored' (elevation-shaped like the chief,
            % floored at the flat sigma so R_new >= R_old). Byte-identical under the 'constant' code model.
            codeSigmaModel = 'flat';
            if isfield(ts,'code') && isfield(ts.code,'sigmaModel'); codeSigmaModel = ts.code.sigmaModel; end
            p.code = struct( ...
                'source',      models.noise.RngSource.TOWER_SECONDARY, ...
                'sigmaModel',  codeSigmaModel, ...
                'flatSigma_m', ts.code.sigma_m, ...
                'nodeScheme',  'towerAsset32');   % node = ti*32 + ai

            lambda = cfg.signals.L1.lambda_m;
            ambStd = min(ts.carrier.initialSigma_m, 10);
            p.carrier = struct( ...
                'ambSource',   models.noise.RngSource.SEC_CARR_AMB, ...
                'phaseSource', models.noise.RngSource.SEC_CARR_PHASE, ...
                'sigma_m',     ts.carrier.sigma_m, ...
                'ambStd_m',    ambStd, ...
                'lambda_m',    lambda, ...
                'nodeScheme',  'towerAsset32');

            % R product-pad: nCorr*(productSigmaPos^2 + towerClkSigma^2). productSigmaPos is
            % nonzero only when the ISL product ephemeris is enabled (else 0).
            productSigmaPos_m = 0;
            if isfield(cfg, 'measurements') && isfield(cfg.measurements, 'isl') && ...
                    isfield(cfg.measurements.isl, 'product') && isfield(cfg.measurements.isl.product, 'enable') && ...
                    cfg.measurements.isl.product.enable && isfield(cfg.measurements.isl.product, 'sigmaPos_m')
                productSigmaPos_m = cfg.measurements.isl.product.sigmaPos_m;
            end
            p.rPad = struct( ...
                'enable',            true, ...
                'nCorr',             ts.productNCorr, ...
                'towerClkSigma_m',   ts.towerClkSigma_m, ...
                'productSigmaPos_m', productSigmaPos_m);
        end
    end
end
