classdef InterSatelliteRFLinkModel
    % InterSatelliteRFLinkModel  Two-leg RF link and code-tracking analysis.
    %
    % Each leg declares its RF, antenna, receiver-noise, tracking, and loss
    % assumptions. The returned range uncertainty is the thermal contribution
    % from the remote and initiating receiver tracking loops. Calibration and
    % dynamics errors are outside this model.

    methods (Static)
        function result = evaluate(spec)
            if ~isstruct(spec) || ~isfield(spec, 'forward') || ~isfield(spec, 'return')
                error('InterSatelliteRFLinkModel:InvalidSpecification', ...
                    'Specification must contain forward and return leg structures.');
            end

            commonDistance = [];
            if isfield(spec, 'distance_m')
                commonDistance = revgnss.InterSatelliteRFLinkModel.positiveScalar_( ...
                    spec.distance_m, 'distance_m');
            end

            result.forward = revgnss.InterSatelliteRFLinkModel.evaluateLeg_( ...
                spec.forward, commonDistance, 'forward');
            result.return = revgnss.InterSatelliteRFLinkModel.evaluateLeg_( ...
                spec.return, commonDistance, 'return');

            cn0 = [result.forward.carrierToNoiseDensity_dBHz, ...
                result.return.carrierToNoiseDensity_dBHz];
            result.roundTripLimitingCN0_dBHz = min(cn0);
            result.roundTripLimitingCN0_Hz = 10^(result.roundTripLimitingCN0_dBHz / 10);
            result.vacuumGeometricRange_m = 0.5 * ...
                (result.forward.vacuumGeometricRange_m + ...
                result.return.vacuumGeometricRange_m);
            result.plasmaGroupRangeBias_m = 0.5 * ...
                (result.forward.plasmaGroupDelay_m + ...
                result.return.plasmaGroupDelay_m);
            result.apparentCodeRange_m = result.vacuumGeometricRange_m + ...
                result.plasmaGroupRangeBias_m;
            trackingCorrelation = 0;
            if isfield(spec,'forwardReturnTrackingErrorCorrelation')
                trackingCorrelation = ...
                    revgnss.InterSatelliteRFLinkModel.finiteScalar_( ...
                    spec.forwardReturnTrackingErrorCorrelation, ...
                    'forwardReturnTrackingErrorCorrelation');
                if abs(trackingCorrelation) > 1
                    error('InterSatelliteRFLinkModel:TrackingCorrelation', ...
                        'Forward/return tracking-error correlation must lie in [-1,1].');
                end
            end
            forwardSigma = result.forward.codeRangeSigma_m;
            returnSigma = result.return.codeRangeSigma_m;
            result.forwardReturnTrackingErrorCorrelation = ...
                trackingCorrelation;
            result.codeRangeSigma_m = 0.5 * sqrt(max(0, ...
                forwardSigma^2+returnSigma^2+ ...
                2*trackingCorrelation*forwardSigma*returnSigma));
            result.assumptions = { ...
                'Vacuum propagation uses the declared one-way distances.', ...
                'The reported two-way range is one half of the round-trip path.', ...
                ['Forward and return receiver tracking errors use the declared ' ...
                'correlation and combine in the half-round-trip observable.'], ...
                ['Plasma is a first-order group-delay model; transponder, oscillator, ' ...
                'pointing, and calibration errors are excluded.']};
        end
    end

    methods (Static, Access = private)
        function out = evaluateLeg_(leg, commonDistance, legName)
            if ~isstruct(leg)
                error('InterSatelliteRFLinkModel:InvalidLeg', ...
                    '%s leg must be a structure.', legName);
            end

            frequency = revgnss.InterSatelliteRFLinkModel.requiredPositive_( ...
                leg, 'frequency_Hz', legName);
            if isfield(leg, 'distance_m')
                distance = revgnss.InterSatelliteRFLinkModel.positiveScalar_( ...
                    leg.distance_m, [legName '.distance_m']);
            elseif ~isempty(commonDistance)
                distance = commonDistance;
            else
                error('InterSatelliteRFLinkModel:MissingDistance', ...
                    'Declare distance_m globally or for the %s leg.', legName);
            end

            losses = revgnss.InterSatelliteRFLinkModel.requiredNonnegative_( ...
                leg, 'losses_dB', legName);
            integrationTime = revgnss.InterSatelliteRFLinkModel.requiredPositive_( ...
                leg, 'integrationTime_s', legName);
            trackingCoefficient = revgnss.InterSatelliteRFLinkModel.requiredPositive_( ...
                leg, 'modulationTrackingCoefficient', legName);
            [rangingBandwidth, bandwidthSource] = ...
                revgnss.InterSatelliteRFLinkModel.rangingBandwidth_(leg, legName);

            if ~isfield(leg, 'transmitAntenna') || ~isfield(leg, 'receiveAntenna')
                error('InterSatelliteRFLinkModel:MissingAntenna', ...
                    '%s leg must declare transmitAntenna and receiveAntenna.', legName);
            end
            txAntenna = revgnss.InterSatelliteRFLinkModel.antenna_( ...
                leg.transmitAntenna, frequency, [legName '.transmitAntenna']);
            rxAntenna = revgnss.InterSatelliteRFLinkModel.antenna_( ...
                leg.receiveAntenna, frequency, [legName '.receiveAntenna']);

            hasPower = isfield(leg, 'transmitPower_dBW');
            hasEirp = isfield(leg, 'eirp_dBW');
            if hasPower == hasEirp
                error('InterSatelliteRFLinkModel:TransmitPowerDefinition', ...
                    '%s leg must declare exactly one of transmitPower_dBW or eirp_dBW.', ...
                    legName);
            end
            if hasPower
                transmitPower = revgnss.InterSatelliteRFLinkModel.finiteScalar_( ...
                    leg.transmitPower_dBW, [legName '.transmitPower_dBW']);
                eirp = transmitPower + txAntenna.gain_dBi;
                eirpSource = 'conducted transmit power plus antenna gain';
            else
                eirp = revgnss.InterSatelliteRFLinkModel.finiteScalar_( ...
                    leg.eirp_dBW, [legName '.eirp_dBW']);
                transmitPower = eirp - txAntenna.gain_dBi;
                eirpSource = 'declared EIRP';
            end

            c = 299792458;
            kBoltzmann = 1.380649e-23;
            fspl = 20 * log10(4 * pi * distance * frequency / c);
            receivedCarrier = eirp + rxAntenna.gain_dBi - fspl - losses;

            hasTemperature = isfield(leg, 'systemNoiseTemperature_K');
            hasGT = isfield(leg, 'receiverGT_dB_per_K');
            if hasTemperature == hasGT
                error('InterSatelliteRFLinkModel:ReceiverNoiseDefinition', ...
                    ['%s leg must declare exactly one of systemNoiseTemperature_K ' ...
                    'or receiverGT_dB_per_K.'], legName);
            end
            if hasTemperature
                noiseTemperature = revgnss.InterSatelliteRFLinkModel.positiveScalar_( ...
                    leg.systemNoiseTemperature_K, ...
                    [legName '.systemNoiseTemperature_K']);
                receiverGT = rxAntenna.gain_dBi - 10 * log10(noiseTemperature);
                noiseSource = 'declared system noise temperature';
            else
                receiverGT = revgnss.InterSatelliteRFLinkModel.finiteScalar_( ...
                    leg.receiverGT_dB_per_K, [legName '.receiverGT_dB_per_K']);
                noiseTemperature = 10^((rxAntenna.gain_dBi - receiverGT) / 10);
                noiseSource = 'declared receiver G/T';
            end

            noiseDensity = 10 * log10(kBoltzmann * noiseTemperature);
            cn0_dBHz = receivedCarrier - noiseDensity;
            cn0_Hz = 10^(cn0_dBHz / 10);
            sigma = trackingCoefficient * c / ...
                (2 * rangingBandwidth * sqrt(cn0_Hz * integrationTime));

            tec = 0;
            if isfield(leg, 'TEC_electrons_per_m2')
                tec = revgnss.InterSatelliteRFLinkModel.nonnegativeScalar_( ...
                    leg.TEC_electrons_per_m2, [legName '.TEC_electrons_per_m2']);
            end
            plasmaDelay_m = 40.3 * tec / frequency^2;

            out.frequency_Hz = frequency;
            out.distance_m = distance;
            out.vacuumGeometricRange_m = distance;
            out.freeSpacePathLoss_dB = fspl;
            out.transmitGain_dBi = txAntenna.gain_dBi;
            out.receiveGain_dBi = rxAntenna.gain_dBi;
            out.transmitBeamwidth_deg = txAntenna.beamwidth_deg;
            out.receiveBeamwidth_deg = rxAntenna.beamwidth_deg;
            out.transmitPower_dBW = transmitPower;
            out.eirp_dBW = eirp;
            out.eirpSource = eirpSource;
            out.losses_dB = losses;
            out.receivedCarrierPower_dBW = receivedCarrier;
            out.systemNoiseTemperature_K = noiseTemperature;
            out.receiverGT_dB_per_K = receiverGT;
            out.noiseSource = noiseSource;
            out.noiseDensity_dBW_per_Hz = noiseDensity;
            out.carrierToNoiseDensity_dBHz = cn0_dBHz;
            out.carrierToNoiseDensity_Hz = cn0_Hz;
            out.rangingBandwidth_Hz = rangingBandwidth;
            out.rangingBandwidthSource = bandwidthSource;
            out.integrationTime_s = integrationTime;
            out.modulationTrackingCoefficient = trackingCoefficient;
            out.codeRangeSigma_m = sigma;
            out.TEC_electrons_per_m2 = tec;
            out.plasmaGroupDelay_m = plasmaDelay_m;
            out.plasmaGroupDelay_s = plasmaDelay_m / c;
            out.transmitAntenna = txAntenna;
            out.receiveAntenna = rxAntenna;
            out.assumptions = { ...
                'Free-space spreading and isotropic polarization alignment.', ...
                ['Tracking sigma = coefficient*c/(2*B_ranging*sqrt((C/N0)*T)); ' ...
                'the coefficient declares waveform and discriminator effects.'], ...
                ['The first-order plasma group delay is 40.3*TEC/f^2 metres and ' ...
                'defaults to zero TEC.']};
        end

        function antenna = antenna_(input, frequency, fieldName)
            if ~isstruct(input) || ~isfield(input, 'model')
                error('InterSatelliteRFLinkModel:AntennaDefinition', ...
                    '%s must contain a model.', fieldName);
            end
            model = char(string(input.model));
            c = 299792458;
            switch model
                case 'fixedGain'
                    if ~isfield(input, 'gain_dBi')
                        error('InterSatelliteRFLinkModel:AntennaGain', ...
                            '%s fixedGain model requires gain_dBi.', fieldName);
                    end
                    gain = revgnss.InterSatelliteRFLinkModel.finiteScalar_( ...
                        input.gain_dBi, [fieldName '.gain_dBi']);
                    diameter = NaN;
                    efficiency = NaN;
                    beamwidth = NaN;
                    note = 'Gain is held fixed as frequency changes.';
                case 'fixedAperture'
                    if ~isfield(input, 'diameter_m') || ~isfield(input, 'efficiency')
                        error('InterSatelliteRFLinkModel:AntennaAperture', ...
                            ['%s fixedAperture model requires diameter_m and ' ...
                            'efficiency.'], fieldName);
                    end
                    diameter = revgnss.InterSatelliteRFLinkModel.positiveScalar_( ...
                        input.diameter_m, [fieldName '.diameter_m']);
                    efficiency = revgnss.InterSatelliteRFLinkModel.positiveScalar_( ...
                        input.efficiency, [fieldName '.efficiency']);
                    if efficiency > 1
                        error('InterSatelliteRFLinkModel:AntennaEfficiency', ...
                            '%s efficiency must not exceed one.', fieldName);
                    end
                    wavelength = c / frequency;
                    gain = 10 * log10(efficiency * (pi * diameter / wavelength)^2);
                    beamwidth = 70 * wavelength / diameter;
                    note = ['Circular-aperture gain uses eta*(pi*D/lambda)^2; ' ...
                        'beamwidth uses the approximate 70*lambda/D degree rule.'];
                otherwise
                    error('InterSatelliteRFLinkModel:AntennaModel', ...
                        '%s model must be fixedGain or fixedAperture.', fieldName);
            end
            antenna.model = model;
            antenna.gain_dBi = gain;
            antenna.diameter_m = diameter;
            antenna.efficiency = efficiency;
            antenna.beamwidth_deg = beamwidth;
            antenna.assumption = note;
        end

        function [bandwidth, source] = rangingBandwidth_(leg, legName)
            hasBandwidth = isfield(leg, 'bandwidth_Hz');
            hasChipRate = isfield(leg, 'chipRate_Hz');
            if hasBandwidth == hasChipRate
                error('InterSatelliteRFLinkModel:RangingBandwidth', ...
                    '%s leg must declare exactly one of bandwidth_Hz or chipRate_Hz.', ...
                    legName);
            end
            if hasBandwidth
                bandwidth = revgnss.InterSatelliteRFLinkModel.positiveScalar_( ...
                    leg.bandwidth_Hz, [legName '.bandwidth_Hz']);
                source = 'declared effective ranging bandwidth';
            else
                bandwidth = revgnss.InterSatelliteRFLinkModel.positiveScalar_( ...
                    leg.chipRate_Hz, [legName '.chipRate_Hz']);
                source = 'chip rate used as effective ranging bandwidth';
            end
        end

        function value = requiredPositive_(s, name, parentName)
            if ~isfield(s, name)
                error('InterSatelliteRFLinkModel:MissingField', ...
                    '%s leg must declare %s.', parentName, name);
            end
            value = revgnss.InterSatelliteRFLinkModel.positiveScalar_( ...
                s.(name), [parentName '.' name]);
        end

        function value = requiredNonnegative_(s, name, parentName)
            if ~isfield(s, name)
                error('InterSatelliteRFLinkModel:MissingField', ...
                    '%s leg must declare %s.', parentName, name);
            end
            value = revgnss.InterSatelliteRFLinkModel.nonnegativeScalar_( ...
                s.(name), [parentName '.' name]);
        end

        function value = positiveScalar_(value, name)
            value = revgnss.InterSatelliteRFLinkModel.finiteScalar_(value, name);
            if value <= 0
                error('InterSatelliteRFLinkModel:PositiveScalar', ...
                    '%s must be positive.', name);
            end
        end

        function value = nonnegativeScalar_(value, name)
            value = revgnss.InterSatelliteRFLinkModel.finiteScalar_(value, name);
            if value < 0
                error('InterSatelliteRFLinkModel:NonnegativeScalar', ...
                    '%s must be nonnegative.', name);
            end
        end

        function value = finiteScalar_(value, name)
            if ~(isnumeric(value) && isscalar(value) && isreal(value) && isfinite(value))
                error('InterSatelliteRFLinkModel:FiniteScalar', ...
                    '%s must be a finite real scalar.', name);
            end
            value = double(value);
        end
    end
end
