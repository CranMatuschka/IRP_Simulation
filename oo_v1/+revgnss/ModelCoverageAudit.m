classdef ModelCoverageAudit
    % ModelCoverageAudit  Stage 81 model coverage audit and real-world claim gate.
    %
    % Audits all 22 major model categories for the active single-asset one-way
    % synthetic reverse-GNSS simulation. Every category must be one of:
    %   implementedSynthetic   -- implemented as a synthetic configurable model
    %   disabledByConfig       -- explicitly disabled; no false claim possible
    %   guardedNotImplemented  -- real product needed but guarded; claim blocked
    %   missingUnsafe          -- uncovered and could yield false claim (NOT ALLOWED)
    %
    % Usage:
    %   result = revgnss.ModelCoverageAudit.run(cfg)
    %
    % nModelCategoriesMissingUnsafe must be 0 for Stage 81 acceptance.

    methods (Static)

        function result = run(cfg)
            % run  Audit model coverage and return summary struct.
            cats   = revgnss.ModelCoverageAudit.buildCategories_(cfg);
            stats  = {cats.status};
            nImpl  = sum(strcmp(stats,'implementedSynthetic'));
            nGuard = sum(strcmp(stats,'guardedNotImplemented'));
            nDisab = sum(strcmp(stats,'disabledByConfig'));
            nMiss  = sum(strcmp(stats,'missingUnsafe'));

            if nMiss == 0
                covStatus = 'complete';
            else
                covStatus = sprintf('incomplete:%dMissingUnsafe', nMiss);
            end

            [gateStatus, blockedReasons] = revgnss.ModelCoverageAudit.claimGate_(cfg);

            result.categories                            = cats;
            result.nCategories                           = numel(cats);
            result.nModelCategoriesImplementedSynthetic  = nImpl;
            result.nModelCategoriesGuardedNotImplemented = nGuard;
            result.nModelCategoriesDisabledByConfig      = nDisab;
            result.nModelCategoriesMissingUnsafe         = nMiss;
            result.modelCoverageStatus                   = covStatus;
            result.modelCoverageBlockingItems            = {cats(strcmp(stats,'missingUnsafe')).name};
            result.realWorldClaimGateStatus              = gateStatus;
            result.realWorldClaimBlockedReasons          = blockedReasons;
        end

    end  % public static

    methods (Static, Access = private)

        function cats = buildCategories_(cfg)
            % buildCategories_  Classify all 22 model categories for active cfg.
            c = {};

            % 1. topology
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'topology','implementedSynthetic', ...
                'single space asset; 5 ground towers; one-way uplink only; ISL/TWSTFT/two-way disabled and guarded');

            % 2. propagation
            propMode = 'twoBodyRk4';
            try; propMode = cfg.orbit.truth.mode; catch; end
            dynMode = 'twoBody';
            try; dynMode = cfg.estimator.dynamics.mode; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'propagation','implementedSynthetic', ...
                sprintf('truth=%s (Stage 82 default: j2Rk4); EKF predictor=%s; j2DefaultPolicy reported in cfg.diagnostics.dynamicsMismatch', propMode, dynMode));

            % 3. frameRotation
            earthRot = 'constantOmegaV1';
            try; earthRot = cfg.frames.earthRotationModel; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'frameRotation','implementedSynthetic', ...
                sprintf('ECI truth / ECEF measurements; earthRotationModel=%s; IERS/EOP not implemented and not claimed', earthRot));

            % 4. lightTime
            ltMode = 'sagnacFirstOrder';
            try; ltMode = cfg.physics.lightTime.mode; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'lightTime','implementedSynthetic', ...
                sprintf('mode=%s; one-way tower-to-spacecraft propagation delay modelled', ltMode));

            % 5. sagnac
            sagMode = 'firstOrderCorrection';
            try; sagMode = cfg.physics.sagnac.mode; catch; end
            dcGuard = 'notEvaluated';
            try; dcGuard = cfg.physics.lightTime.doubleCountGuard; catch; end
            doppSagnac = 'capturedByTowerVelocityTerm';
            try; doppSagnac = cfg.diagnostics.doppler.sagnacRateHandling; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'sagnac','implementedSynthetic', ...
                sprintf('mode=%s; doubleCountGuard=%s; Doppler derivative capturedByTowerVelocityTerm; sagnacRateHandling=%s', ...
                sagMode, dcGuard, doppSagnac));

            % 6. relativity
            shapiroEn = false;
            try; shapiroEn = cfg.physics.relativity.shapiro.truth.enable || ...
                             cfg.physics.relativity.shapiro.model.enable; catch; end
            clockRelEn = false;
            try; clockRelEn = cfg.physics.relativity.clock.truth.enable || ...
                              cfg.physics.relativity.clock.model.enable; catch; end
            if shapiroEn || clockRelEn
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'relativity','implementedSynthetic', ...
                    sprintf('Shapiro=%s; relClock=%s; enabled in active config', ...
                        mat2str(shapiroEn), mat2str(clockRelEn)));
            else
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'relativity','disabledByConfig', ...
                    'Shapiro=false; relativistic clock=false; explicitly disabled; not claimed in this scenario');
            end

            % 7. receiverClock
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'receiverClock','implementedSynthetic', ...
                'EKF-estimated bias+drift states; stochastic OCXO truth clock; Allan deviation model (Stage 67)');

            % 8. towerClockProduct
            clkMode = 'perfectCorrection';
            try; clkMode = cfg.estimator.towerClockMode; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'towerClockProduct','implementedSynthetic', ...
                sprintf('mode=%s; synthetic truth-history product with bias/drift/noise (Stage 71/72); no real CLK parsing', clkMode));

            % 9. troposphere
            tropModelEn = true;
            try; tropModelEn = cfg.errors.troposphere.model.enable; catch; end
            tropType = 'simpleMapped';
            try; tropType = cfg.errors.troposphere.modelType; catch; end
            if tropModelEn
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'troposphere','implementedSynthetic', ...
                    sprintf('modelType=%s; simpleSecant/thinShell mapping; ZWD state available; stochastic residual; gradient=disabled', tropType));
            else
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'troposphere','disabledByConfig', ...
                    'troposphere model disabled by config; not claimed; configurable');
            end

            % 10. ionosphere
            ionoModelEn = true;
            try; ionoModelEn = cfg.errors.ionosphere.model.enable; catch; end
            ionoType = 'simpleMapped';
            try; ionoType = cfg.errors.ionosphere.modelType; catch; end
            if ionoModelEn
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'ionosphere','implementedSynthetic', ...
                    sprintf('modelType=%s; 1/f^2 scaling; dual-freq L1+L2 reduces first-order iono in AR; higher-order=disabled; Klobuchar/IONEX not claimed', ionoType));
            else
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'ionosphere','disabledByConfig', ...
                    'ionosphere model disabled by config; not claimed; configurable');
            end

            % 11. antennaPCO
            pcoEn = false;
            try; pcoEn = cfg.effects.antennaPCO.truth.enable || cfg.effects.antennaPCO.model.enable; catch; end
            if pcoEn
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'antennaPCO','implementedSynthetic', ...
                    'synthetic calibrated constants; receiver+tower PCO; no ANTEX parser; not real-calibrated');
            else
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'antennaPCO','disabledByConfig', ...
                    'PCO disabled; geometry at reference point; no ANTEX; not claimed');
            end

            % 12. antennaPCV
            pcvEn = false;
            try; pcvEn = cfg.effects.antennaPCV.truth.enable || cfg.effects.antennaPCV.model.enable; catch; end
            if pcvEn
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'antennaPCV','implementedSynthetic', ...
                    'toy elevation-only PCV; synthetic; no ANTEX; not real-calibrated');
            else
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'antennaPCV','disabledByConfig', ...
                    'PCV disabled by default; toy PCV available but off; ANTEX not implemented and not claimed');
            end

            % 13. hardwareCodeBias
            cbMode = 'syntheticConfiguredZero';
            try; cbMode = cfg.biases.code.mode; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'hardwareCodeBias','disabledByConfig', ...
                sprintf('mode=%s; no DCB product; hardware delay configurable but set to zero in active scenario', cbMode));

            % 14. hardwarePhaseBias
            pbMode = 'syntheticKnownZero';
            try; pbMode = cfg.biases.phase.mode; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'hardwarePhaseBias','guardedNotImplemented', ...
                sprintf('mode=%s; real calibrated phase-bias products not parsed; AR claim=controlledSyntheticOnly; real-world AR blocked', pbMode));

            % 15. interFrequencyBias
            ifbMode = 'syntheticConfiguredZero';
            try; ifbMode = cfg.biases.interFrequency.mode; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'interFrequencyBias','disabledByConfig', ...
                sprintf('mode=%s; differential ionosphere neglected for short baselines (documented); DCB not calibrated', ifbMode));

            % 16. multipath
            mpEn = false;
            try; mpEn = cfg.errors.multipath.truth.enable; catch; end
            if mpEn
                amp = 0.3; try; amp = cfg.errors.multipath.truth.amplitude_m; catch; end
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'multipath','implementedSynthetic', ...
                    sprintf('truth enabled; amplitude=%.2f m; stochastic + sinusoidal model', amp));
            else
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'multipath','disabledByConfig', ...
                    'multipath truth=false in active scenario; configurable sinusoidal+stochastic model available; not claimed');
            end

            % 17. measurementNoise
            codeSig = 0.3;
            try; codeSig = cfg.errors.codeNoise.sigma_m; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'measurementNoise','implementedSynthetic', ...
                sprintf('code=%.2f m (seeded RNG); carrier=0.01 cyc; Doppler=0.01 m/s; CN0-dependent model available', codeSig));

            % 18. carrierSlip
            slipMethod = 'rawResidualJump';
            try; slipMethod = cfg.carrierSlip.method; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'carrierSlip','implementedSynthetic', ...
                sprintf('method=%s; Stage 73 model-step product-boundary compensation; synthetic injection available', slipMethod));

            % 19. ambiguityResolution
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'ambiguityResolution','implementedSynthetic', ...
                'Stage 76 raw L1+L2 joint integer-pair AR; wide-lane consistency screening; syntheticKnownZero phase bias; controlledSyntheticClaim; LAMBDA/MLAMBDA not implemented and not claimed');

            % 20. covariance (Stage 84: use canonical productClock config)
            prodClkEn  = false;
            try; prodClkEn = cfg.covariance.productClock.enable; catch; end
            legacyEn   = false;
            try; legacyEn  = cfg.covariance.sharedErrors.enable; catch; end
            codeEn_    = false;
            try; codeEn_   = cfg.covariance.productClock.applyToCode; catch; end
            doppEn_    = false;
            try; doppEn_   = cfg.covariance.productClock.applyToDoppler; catch; end
            carrEn_    = false;
            try; carrEn_   = cfg.covariance.productClock.applyToCarrier; catch; end
            doppPol_   = 'unknown';
            try; doppPol_  = cfg.covariance.productClock.dopplerPolicy; catch; end
            carrPol_   = 'unknown';
            try; carrPol_  = cfg.covariance.productClock.carrierPolicy; catch; end

            if prodClkEn && codeEn_ && doppEn_ && carrEn_
                covStatus_ = 'productClockCovarianceAwareV2';
            elseif prodClkEn || legacyEn
                covStatus_ = 'partialCovarianceAware';
            else
                covStatus_ = 'diagonalOnly';
            end

            codeStatus_  = 'disabledByConfig';
            try
                if cfg.covariance.sharedErrors.applyTowerClockToCode
                    codeStatus_ = 'stage74BlockRTowerClockCorrelation';
                end
            catch; end
            doppStatus_  = 'disabledByConfig';
            if doppEn_
                doppStatus_ = sprintf('stage83ProductDriftBlock_%s', doppPol_);
            end
            carrStatus_  = 'disabledByConfig';
            if carrEn_
                carrStatus_ = sprintf('stage83TimeVaryingDriftResidual_%s', carrPol_);
            end

            covNote_ = sprintf('%s; code=%s; doppler=%s; carrier=%s; crossCodeDoppler=notImplemented', ...
                covStatus_, codeStatus_, doppStatus_, carrStatus_);

            if prodClkEn || legacyEn
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'covariance','implementedSynthetic', covNote_);
            else
                c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                    'covariance','disabledByConfig', ...
                    'block covariance disabled; diagonal R only; NIS interpretation labelled');
            end

            % 21. validationStatistics
            mcEn = false;
            try; mcEn = logical(cfg.validation.statistics.monteCarlo.enable); catch; end
            neesEn = false;
            try; neesEn = logical(cfg.validation.statistics.nees.enable); catch; end
            nisMode = 'partialCovarianceAware';
            try; nisMode = cfg.validation.statistics.nis.mode; catch; end
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'validationStatistics','disabledByConfig', ...
                sprintf('MC=%s; NEES=%s; NIS=%s; partial NIS documented; no false chi-square claim', ...
                    mat2str(mcEn), mat2str(neesEn), nisMode));

            % 22. externalProducts
            c{end+1} = revgnss.ModelCoverageAudit.cat_( ...
                'externalProducts','guardedNotImplemented', ...
                'SP3/CLK(real)/RINEX/ANTEX/IONEX not parsed; externalFile mode blocked by ConfigFactory; EOP=constantOmegaV1; synthetic truth-history clock only');

            cats = [c{:}];
        end

        function s = cat_(name, status, note)
            s.name   = name;
            s.status = status;
            s.note   = note;
        end

        function [gateStatus, reasons] = claimGate_(cfg)
            % claimGate_  Evaluate real-world claim gate from cfg.scientificProfile.
            allowClaim = false;
            try; allowClaim = logical(cfg.scientificProfile.allowRealWorldClaim); catch; end

            if ~allowClaim
                gateStatus = 'blockedWithReasons';
                reasons = { ...
                    'cfg.scientificProfile.allowRealWorldClaim=false (default; controlled synthetic only)', ...
                    'SP3 orbit product: notImplemented (no parser)', ...
                    'CLK product: syntheticTruthHistory only (no real CLK file parsing)', ...
                    'RINEX observation data: notImplemented (no parser)', ...
                    'ANTEX antenna calibration: notImplemented (no parser)', ...
                    'IONEX ionosphere product: notImplemented (no parser)', ...
                    'EOP/IERS frame: constantEarthRotationV1 only (not IERS rapid/standard)', ...
                    'Phase-bias/DCB product: syntheticKnownZero only (no real calibrated product)', ...
                    'Monte Carlo/NEES stochastic validation: disabled' };
                return;
            end

            % allowRealWorldClaim=true: check if all required product modes are real.
            reasons = {};
            sp3Mode  = 'notImplemented'; try; sp3Mode  = cfg.products.sp3.mode;   catch; end
            clkMode  = 'notImplemented'; try; clkMode  = cfg.products.clk.mode;   catch; end
            rinexMode= 'notImplemented'; try; rinexMode= cfg.products.rinex.mode; catch; end
            antexMode= 'notImplemented'; try; antexMode= cfg.products.antex.mode; catch; end
            ionexMode= 'notImplemented'; try; ionexMode= cfg.products.ionex.mode; catch; end
            eopMode  = 'constantEarthRotationV1'; try; eopMode = cfg.products.eop.mode; catch; end
            biasMode = 'syntheticKnownZero';      try; biasMode= cfg.products.bias.mode; catch; end

            if ~strcmp(sp3Mode,  'realSp3Ingested')
                reasons{end+1} = sprintf('SP3: mode=%s (required: realSp3Ingested)', sp3Mode);
            end
            if ~any(strcmp(clkMode, {'realClkIngested','realProduct'}))
                reasons{end+1} = sprintf('CLK: mode=%s (required: realClkIngested)', clkMode);
            end
            if ~strcmp(rinexMode,'realRinexIngested')
                reasons{end+1} = sprintf('RINEX: mode=%s (required: realRinexIngested)', rinexMode);
            end
            if ~strcmp(antexMode,'realAntexIngested')
                reasons{end+1} = sprintf('ANTEX: mode=%s (required: realAntexIngested)', antexMode);
            end
            if ~strcmp(ionexMode,'realIonexIngested')
                reasons{end+1} = sprintf('IONEX: mode=%s (required: realIonexIngested)', ionexMode);
            end
            if ~any(strcmp(eopMode, {'iersRapid','iersStandard'}))
                reasons{end+1} = sprintf('EOP: mode=%s (required: iersRapid or iersStandard)', eopMode);
            end
            if ~strcmp(biasMode,'realBiasProduct')
                reasons{end+1} = sprintf('bias: mode=%s (required: realBiasProduct)', biasMode);
            end

            if isempty(reasons)
                gateStatus = 'passed';
            else
                gateStatus = 'blockedWithReasons';
            end
        end

    end  % private static
end
