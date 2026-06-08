classdef GroundTimingNetwork
    %GROUNDTIMINGNETWORK Builds and evaluates ground timing-network clocks.
    %
    % Owns tower-clock construction, external correction policy, residual
    % generation, and mean-ground-clock gauge vectors.

    methods (Static)
        function [towers, activeTowerConfig, towerNames] = buildGroundNodes( ...
                towerCfg, simConfig, assetConfig, dt, seedConfig, c)

            enabled = true(1, numel(towerCfg));

            if isfield(towerCfg, 'enabled')
                enabled = [towerCfg.enabled];
            end

            activeTowerConfig = towerCfg(enabled);
            numTowers = numel(activeTowerConfig);
            towers = cell(1, numTowers);

            if numTowers > 0
                towerNames = string({activeTowerConfig.name});
            else
                towerNames = strings(1, 0);
            end

            for k = 1:numTowers
                tc = activeTowerConfig(k);

                clk = GroundTimingNetwork.makeTowerClock( ...
                    tc, k, simConfig, assetConfig, dt, seedConfig, c);

                towers{k} = GroundNode(tc, clk);
            end
        end

        function cfg = applyTowerClockEkfConfiguration(cfg)
            if ~GroundTimingNetwork.towerClockEkfEnabled(cfg)
                return;
            end

            if logical(GroundTimingNetwork.getFieldOrDefault( ...
                    cfg, 'spacecraftNavigationFilterOnly', true))

                error('GroundTimingNetwork:TowerClockStatesNotSpacecraftStates', ...
                    ['enableTowerClockEKF=true adds ground-network clock states to the spacecraft navigation filter. ', ...
                     'For this architecture, tower clocks must be supplied as external measurement corrections ', ...
                     'or estimated in a separate ground timing-network filter.']);
            end

            if ~GroundTimingNetwork.groundClockErrorsEnabled(cfg)
                warning('GroundTimingNetwork:TowerClockEKFEnablesGroundClocks', ...
                    ['enableTowerClockEKF=true requires physical tower clock errors. ', ...
                     'Setting enableGroundClockErrors=true.']);

                cfg.enableGroundClockErrors = true;
            end

            if GroundTimingNetwork.groundClockCorrectionEnabled(cfg)
                warning('GroundTimingNetwork:TowerClockEKFDisablesExternalCorrection', ...
                    ['enableTowerClockEKF=true estimates tower clocks inside the EKF. ', ...
                     'Disabling external ground clock correction to avoid double correction.']);

                cfg.enableGroundClockCorrection = false;
                cfg.enableGroundClockCorrectionNoise = false;
            end
        end

        function [residual_m, trueBias_m, correction_m] = residualMeters( ...
                towers, cfg, c, measurementStream, towerClockEkfEnabled)

            numTowers = numel(towers);

            residual_m = zeros(numTowers, 1);
            trueBias_m = zeros(numTowers, 1);
            correction_m = zeros(numTowers, 1);

            if ~GroundTimingNetwork.groundClockErrorsEnabled(cfg)
                return;
            end

            if GroundTimingNetwork.groundClockErrorsEnabled(cfg) && ...
                    ~GroundTimingNetwork.groundClockCorrectionEnabled(cfg) && ...
                    ~towerClockEkfEnabled

                error('GroundTimingNetwork:UnmodelledTowerClockResidual', ...
                    ['Ground clock errors are enabled, but tower clocks are neither externally corrected ', ...
                     'nor estimated. This makes transmitter clock residuals unmodelled pseudorange biases. ', ...
                     'Enable ground clock correction or explicitly run a separate ground-network timing estimator.']);
            end

            for k = 1:numTowers
                trueBias_m(k) = towers{k}.clockBias_m();

                if GroundTimingNetwork.groundClockCorrectionEnabled(cfg)
                    correction_m(k) = trueBias_m(k);

                    if GroundTimingNetwork.groundClockCorrectionNoiseEnabled(cfg)
                        correction_m(k) = correction_m(k) + ...
                            StochasticProcess.whiteNoiseSample( ...
                            GroundTimingNetwork.correctionSigma_m(cfg, c), 1, ...
                            measurementStream);
                    end
                end

                residual_m(k) = trueBias_m(k) - correction_m(k);
            end
        end

        function var_m2 = residualVariance_m2(cfg, c)
            if GroundTimingNetwork.groundClockErrorsEnabled(cfg) && ...
                    GroundTimingNetwork.groundClockCorrectionEnabled(cfg) && ...
                    GroundTimingNetwork.groundClockCorrectionNoiseEnabled(cfg)

                var_m2 = GroundTimingNetwork.correctionSigma_m(cfg, c)^2;
            else
                var_m2 = 0.0;
            end
        end

        function sigma_m = correctionSigma_m(cfg, c)
            sigma_ps = GroundTimingNetwork.getScalarField( ...
                cfg, ...
                'groundClockCorrectionSigma_ps', ...
                GroundTimingNetwork.getScalarField(cfg, 'externalClockCorrectionSigma_ps', 0.0));

            sigma_m = c * sigma_ps * 1e-12;
        end

        function [biasGauge_m, driftGauge_mps, meanBias_m, meanDrift_mps] = ...
                truthGaugeVectors(towers, cfg)

            numTowers = numel(towers);

            biasAbs_m = zeros(numTowers, 1);
            driftAbs_mps = zeros(numTowers, 1);

            for twr = 1:numTowers
                if GroundTimingNetwork.groundClockErrorsEnabled(cfg)
                    biasAbs_m(twr) = towers{twr}.clockBias_m();
                    driftAbs_mps(twr) = towers{twr}.clockDrift_mps();
                end
            end

            meanBias_m = mean(biasAbs_m);
            meanDrift_mps = mean(driftAbs_mps);

            biasGauge_m = biasAbs_m - meanBias_m;
            driftGauge_mps = driftAbs_mps - meanDrift_mps;
        end

        function tf = towerClockEkfEnabled(cfg)
            tf = logical(GroundTimingNetwork.getFieldOrDefault( ...
                cfg, 'enableTowerClockEKF', false));
        end

        function tf = groundClockErrorsEnabled(cfg)
            tf = logical(GroundTimingNetwork.getFieldOrDefault( ...
                cfg, 'enableGroundClockErrors', false));
        end

        function tf = groundClockCorrectionEnabled(cfg)
            tf = logical(GroundTimingNetwork.getFieldOrDefault( ...
                cfg, 'enableGroundClockCorrection', true));
        end

        function tf = groundClockCorrectionNoiseEnabled(cfg)
            tf = logical(GroundTimingNetwork.getFieldOrDefault( ...
                cfg, 'enableGroundClockCorrectionNoise', false));
        end
    end

    methods (Static, Access = private)
        function clk = makeTowerClock(tc, towerIndex, simConfig, assetConfig, dt, seedConfig, c)
            clockType = char(GroundTimingNetwork.getTowerField( ...
                tc, 'clockType', assetConfig.clock.clockType));

            if ~isfield(simConfig.clockLibrary, clockType)
                clockType = char(assetConfig.clock.clockType);
            end

            osc = simConfig.clockLibrary.(clockType);

            clk = Clock(osc.h0, osc.hm1, osc.hm2, dt);
            clk.randomStream = RandStream( ...
                'mt19937ar', ...
                'Seed', double(seedConfig.towerClocks) + towerIndex);

            bias_m = double(GroundTimingNetwork.getTowerField( ...
                tc, 'initialClockBias_m', 0.0));

            drift_mps = double(GroundTimingNetwork.getTowerField( ...
                tc, 'initialClockDrift_mps', 0.0));

            clk.reset([bias_m / c; drift_mps / c; 0.0; 0.0]);
        end

        function value = getFieldOrDefault(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = s.(fieldName);
            else
                value = defaultValue;
            end
        end

        function value = getScalarField(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = double(s.(fieldName));
            else
                value = double(defaultValue);
            end
        end

        function value = getTowerField(towerStruct, fieldName, defaultValue)
            if isstruct(towerStruct) && isfield(towerStruct, fieldName)
                value = towerStruct.(fieldName);
            else
                value = defaultValue;
            end
        end
    end
end
