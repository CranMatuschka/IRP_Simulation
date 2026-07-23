classdef InterAntennaPhaseBias
    % InterAntennaPhaseBias  Receiver-relative carrier phase-bias model.

    methods (Static)

        function tf = hasModel(cfg)
            tf = false;
            try
                b = cfg.estimator.interAntennaCarrierBias;
                tf = isfield(b,'enable') && logical(b.enable) && ...
                    isfield(b,'mode') && any(strcmp(char(b.mode), {'fixed','fixedKnown','calibratedProduct'}));
            catch
            end
        end

        function b_m = modelBiasMeters(cfg, receiverIdx, signalIdx)
            b_m = 0;
            if ~revgnss.InterAntennaPhaseBias.hasModel(cfg)
                return
            end
            biasCfg = cfg.estimator.interAntennaCarrierBias;
            refIdx = 1;
            if isfield(biasCfg,'referenceReceiver')
                refIdx = biasCfg.referenceReceiver;
            end
            if receiverIdx == refIdx
                return
            end
            if signalIdx <= 0
                sigL1 = revgnss.SignalDefinition.get('L1');
                sigL2 = revgnss.SignalDefinition.get('L2');
                [alpha, beta] = revgnss.IonoFreeCombination.coefficients( ...
                    sigL1.frequency_Hz, sigL2.frequency_Hz);
                b1 = revgnss.InterAntennaPhaseBias.lookupMeters_(biasCfg, cfg, receiverIdx, 1) - ...
                    revgnss.InterAntennaPhaseBias.lookupMeters_(biasCfg, cfg, refIdx, 1);
                b2 = revgnss.InterAntennaPhaseBias.lookupMeters_(biasCfg, cfg, receiverIdx, 2) - ...
                    revgnss.InterAntennaPhaseBias.lookupMeters_(biasCfg, cfg, refIdx, 2);
                b_m = alpha * b1 + beta * b2;
                return
            end
            b_m = revgnss.InterAntennaPhaseBias.lookupMeters_(biasCfg, cfg, receiverIdx, signalIdx) - ...
                revgnss.InterAntennaPhaseBias.lookupMeters_(biasCfg, cfg, refIdx, signalIdx);
        end

        function status = resolvedStatus(cfg)
            status = 'none';
            truthBias = false;
            try; truthBias = logical(cfg.errors.interAntennaCarrierBias.enable); catch; end
            if revgnss.InterAntennaPhaseBias.hasModel(cfg)
                status = 'calibratedExternalProduct';
            elseif truthBias
                status = 'notCalibratedExternalProduct';
            elseif ~truthBias
                status = 'syntheticKnownZero';
            end
        end

    end

    methods (Static, Access = private)

        function b_m = lookupMeters_(biasCfg, cfg, receiverIdx, signalIdx)
            b_m = 0;
            if isfield(biasCfg,'bias_m') && ~isempty(biasCfg.bias_m)
                b_m = revgnss.InterAntennaPhaseBias.lookupMatrix_(biasCfg.bias_m, receiverIdx, signalIdx);
                return
            end
            if isfield(biasCfg,'bias_cycles') && ~isempty(biasCfg.bias_cycles)
                cyc = revgnss.InterAntennaPhaseBias.lookupMatrix_(biasCfg.bias_cycles, receiverIdx, signalIdx);
                b_m = cyc * revgnss.InterAntennaPhaseBias.wavelengthMeters_(cfg, signalIdx);
            end
        end

        function v = lookupMatrix_(A, receiverIdx, signalIdx)
            v = 0;
            if isempty(A); return; end
            if isvector(A)
                ii = min(receiverIdx, numel(A));
                v = A(ii);
                return
            end
            rr = min(receiverIdx, size(A,1));
            ss = min(signalIdx, size(A,2));
            v = A(rr, ss);
        end

        function lambda = wavelengthMeters_(cfg, signalIdx)
            lambda = revgnss.SignalDefinition.get('L1').wavelength_m;
            try
                if isfield(cfg,'signals') && isfield(cfg.signals,'wavelength_m') && ...
                        numel(cfg.signals.wavelength_m) >= signalIdx
                    lambda = cfg.signals.wavelength_m(signalIdx);
                    return
                end
            catch
            end
            if signalIdx == 2
                lambda = revgnss.SignalDefinition.get('L2').wavelength_m;
            end
        end

    end
end
