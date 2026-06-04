classdef MeasurementModel < handle
    %MEASUREMENTMODEL Reverse-GNSS pseudorange measurement model.
    %
    % Owns:
    %   - truth pseudorange generation
    %   - predicted pseudorange generation
    %   - pseudorange Jacobian H
    %   - measurement covariance R
    %   - elevation mask logic
    %   - truth and estimator atmospheric-delay application
    %   - non-atmospheric deterministic extra-delay toggles
    %   - measurement-noise injection

    properties
        cfg
        c double = 299792458.0

        towers cell = {}
        receiverAntennas = Antenna.empty(1, 0)
        receiverOffsetsBody_m double = zeros(3, 0)

        numReceivers double = 0
        numTowers double = 0

        measurementStream = []
        truthAtmosphere = []
        modelAtmosphere = []

        signalFrequency_Hz double = 1575.42e6

        % Cached measurement options, initialized once.
        useMeasurementNoise logical = false
        useElevationMask logical = false
        elevationMask_deg double = 0.0

        useHardwareDelay logical = false
        useMultipathDelay logical = false
        useAntennaDelay logical = false
        useSagnacCorrection logical = false
        useLightTimeCorrection logical = false
        
        lightTimeCorrectionMethod string = "inertialIterative"
        lightTimeCorrectionTolerance_s double = 1e-12
        lightTimeCorrectionMaxIterations double = 10

        txHardwareDelay_m double = 0.0
        rxHardwareDelay_m double = 0.0
        multipathDelay_m double = 0.0
        antennaDelay_m double = 0.0
        sagnacCorrection_m double = 0.0

        pseudorangeSigma_m double = 0.30
        numericalSigmaFloor_m double = 1e-4
    end

    methods
        function obj = MeasurementModel( ...
                scenarioCfg, c, towers, receiverAntennas, measurementStream, ...
                truthAtmosphere, modelAtmosphere)
            obj.cfg = scenarioCfg;
            obj.c = c;
            obj.towers = towers;
            obj.receiverAntennas = receiverAntennas;
            obj.numReceivers = numel(receiverAntennas);
            obj.numTowers = numel(towers);

            obj.receiverOffsetsBody_m = zeros(3, obj.numReceivers);
            for k = 1:obj.numReceivers
                obj.receiverOffsetsBody_m(:, k) = receiverAntennas(k).getOffsetBody_m();
            end

            if nargin >= 5
                obj.measurementStream = measurementStream;
            end

            if nargin >= 6 && ~isempty(truthAtmosphere)
                if ~isa(truthAtmosphere, 'Atmosphere')
                    error('MeasurementModel:InvalidTruthAtmosphere', ...
                        'truthAtmosphere must be an Atmosphere object.');
                end

                obj.truthAtmosphere = truthAtmosphere;
            end

            if nargin >= 7 && ~isempty(modelAtmosphere)
                if ~isa(modelAtmosphere, 'Atmosphere')
                    error('MeasurementModel:InvalidModelAtmosphere', ...
                        'modelAtmosphere must be an Atmosphere object.');
                end

                obj.modelAtmosphere = modelAtmosphere;
            end

            mcfg = scenarioCfg.measurement;

            obj.signalFrequency_Hz = obj.getScalarField( ...
                mcfg, 'signalFrequency_Hz', 1575.42e6);

            validateattributes(obj.signalFrequency_Hz, ...
                {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'signalFrequency_Hz');

            obj.useMeasurementNoise = logical(obj.getFieldOrDefault(mcfg, 'enableMeasurementNoise', false)) || ...
                                      logical(obj.getFieldOrDefault(mcfg, 'enableNoise', false));

            obj.useElevationMask = logical(obj.getFieldOrDefault(mcfg, 'enableElevationMask', false));
            obj.elevationMask_deg = obj.getScalarField(mcfg, 'elevationMask_deg', 0.0);

            obj.useHardwareDelay = logical(obj.getFieldOrDefault(mcfg, 'enableHardwareDelay', false));
            obj.useMultipathDelay = logical(obj.getFieldOrDefault(mcfg, 'enableMultipathDelay', false));
            obj.useAntennaDelay = logical(obj.getFieldOrDefault(mcfg, 'enableAntennaDelay', false));
            obj.useSagnacCorrection = logical(obj.getFieldOrDefault(mcfg, 'enableSagnacCorrection', false));

            obj.useLightTimeCorrection = logical(obj.getFieldOrDefault( ...
                mcfg, 'enableLightTimeCorrection', false));

            obj.lightTimeCorrectionMethod = string(obj.getFieldOrDefault( ...
                mcfg, 'lightTimeCorrectionMethod', "inertialIterative"));

            obj.lightTimeCorrectionTolerance_s = obj.getScalarField( ...
                mcfg, 'lightTimeCorrectionTolerance_s', 1e-12);

            obj.lightTimeCorrectionMaxIterations = obj.getScalarField( ...
                mcfg, 'lightTimeCorrectionMaxIterations', 10);

            obj.txHardwareDelay_m = obj.getScalarField(mcfg, 'txHardwareDelay_m', 0.0);
            obj.rxHardwareDelay_m = obj.getScalarField(mcfg, 'rxHardwareDelay_m', 0.0);
            obj.multipathDelay_m = obj.getScalarField(mcfg, 'multipathDelay_m', 0.0);
            obj.antennaDelay_m = obj.getScalarField(mcfg, 'antennaDelay_m', 0.0);
            obj.sagnacCorrection_m = obj.getScalarField(mcfg, 'sagnacCorrection_m', 0.0);

            obj.pseudorangeSigma_m = obj.getScalarField(mcfg, 'pseudorangeSigma_m', 0.30);
            obj.numericalSigmaFloor_m = obj.getScalarField(mcfg, ...
                'sigma_numerical_floor_m', ...
                obj.getScalarField(mcfg, 'deterministicSigma_m', 1e-4));
            obj.validateLightTimeCorrectionConfiguration();
        end

        function [y, Rrange, trueRangeRt, losRt, receiverEci, visibilityMask, elevationRt_deg] = ...
                makePseudoranges(obj, jd, datetimeUtc, towersEci, groundResidualTruth_m, ...
                truthAsset, towerClockEkfEnabled, groundClockResidualVariance_m2)
            
            maxMeas = obj.numReceivers * obj.numTowers;

            y = NaN(maxMeas, 1);
            trueRangeRt = NaN(obj.numReceivers, obj.numTowers);
            losRt = NaN(3, obj.numReceivers, obj.numTowers);
            receiverEci = truthAsset.receiverPositionsEci();
            visibilityMask = false(obj.numReceivers, obj.numTowers);
            elevationRt_deg = NaN(obj.numReceivers, obj.numTowers);

            bRx_m = truthAsset.getClockBias_m();
            row = 0;

            for rx = 1:obj.numReceivers
                rRx_I = receiverEci(:, rx);

                for twr = 1:obj.numTowers
                    [elev_deg, passesMask] = obj.towerElevationToReceiverEci( ...
                        jd, twr, towersEci(:, twr), rRx_I);

                    elevationRt_deg(rx, twr) = elev_deg;

                    if obj.useElevationMask && ~passesMask
                        continue;
                    end

                    d = rRx_I - towersEci(:, twr);
                    rho = norm(d);
                    u = d ./ rho;

                    [atmosphere_m, atmosphereValid] = ...
                        obj.atmosphereDelayAndGradient_m( ...
                        obj.truthAtmosphere, twr, rRx_I, jd, datetimeUtc);

                    if ~atmosphereValid
                        continue;
                    end

                    extra_m = obj.nonAtmosphericExtraDelay_m( ...
                        twr, rx, jd, towersEci(:, twr), rRx_I, truthAsset);

                    row = row + 1;
                    y(row) = rho ...
                        + bRx_m ...
                        - groundResidualTruth_m(twr) ...
                        + atmosphere_m ...
                        + extra_m;

                    if obj.useMeasurementNoise
                        if isempty(obj.measurementStream)
                            noise = randn();
                        else
                            noise = randn(obj.measurementStream);
                        end

                        y(row) = y(row) + obj.pseudorangeSigma_m * noise;
                    end

                    trueRangeRt(rx, twr) = rho;
                    losRt(:, rx, twr) = u;
                    visibilityMask(rx, twr) = true;
                end
            end

            y = y(1:row);

            Rrange = eye(row) * ...
                obj.measurementVariance(towerClockEkfEnabled, groundClockResidualVariance_m2);
        end
                
        function [yp, H] = predictPseudorangesWithJacobian( ...
                obj, jd, datetimeUtc, towersEci, ...
                groundResidualModel_m, visibilityMask, estAsset, ...
                estTowerClockBias_m, idx, stateDim, towerClockEkfEnabled)

            if nargin < 6 || isempty(visibilityMask)
                visibilityMask = true(obj.numReceivers, obj.numTowers);
            end

            yp = zeros(nnz(visibilityMask), 1);
            H = zeros(numel(yp), stateDim);

            C_BI_est = estAsset.C_BI;
            estClockBias_m = estAsset.getClockBias_m();

            row = 1;

            for rx = 1:obj.numReceivers
                l_B = obj.receiverOffsetsBody_m(:, rx);
                rRx_I = estAsset.pos_ECI_m + C_BI_est * l_B;

                J_att = -C_BI_est * FrameGeometry.skew(l_B);

                for twr = 1:obj.numTowers
                    if ~visibilityMask(rx, twr)
                        continue;
                    end

                    d = rRx_I - towersEci(:, twr);
                    rho = norm(d);
                    u = d ./ rho;

                    [atmosphere_m, atmosphereValid, atmosphereGradient_I] = ...
                        obj.atmosphereDelayAndGradient_m( ...
                        obj.modelAtmosphere, twr, rRx_I, jd, datetimeUtc);

                    if ~atmosphereValid
                        error('MeasurementModel:InvalidModelAtmosphereDelay', ...
                            ['Estimator atmosphere delay is invalid for tower %d ', ...
                             'and receiver %d.'], twr, rx);
                    end

                    pseudorangeGradient_I = u + atmosphereGradient_I;

                    if towerClockEkfEnabled
                        yp(row) = rho ...
                            + estClockBias_m ...
                            - estTowerClockBias_m(twr) ...
                            + atmosphere_m;

                        H(row, idx.pos) = pseudorangeGradient_I.';
                        H(row, idx.att) = pseudorangeGradient_I.' * J_att;
                        H(row, idx.rxClockBias) = 1.0;
                        H(row, idx.towerClockBias(twr)) = -1.0;
                    else
                        yp(row) = rho ...
                            + estClockBias_m ...
                            - groundResidualModel_m(twr) ...
                            + atmosphere_m;

                        H(row, idx.pos) = pseudorangeGradient_I.';
                        H(row, idx.att) = pseudorangeGradient_I.' * J_att;
                        H(row, idx.rxClockBias) = 1.0;
                    end

                    row = row + 1;
                end
            end
        end

        function tf = elevationMaskEnabled(obj)
            tf = obj.useElevationMask;
        end

        function mask_deg = elevationMaskDeg(obj)
            mask_deg = obj.elevationMask_deg;
        end

        function [elev_deg, passesMask] = towerElevationToReceiverEci( ...
                obj, jd, towerIndex, towerEci_m, receiverEci_m)

            tower = obj.towers{towerIndex};

            [elev_deg, passesMask] = FrameGeometry.elevationFromGroundToReceiver( ...
                tower.lat_deg, tower.lon_deg, towerEci_m, receiverEci_m, ...
                jd, obj.elevationMask_deg);
        end

        function matrixRt = vectorToReceiverTowerMatrix(obj, vectorValues, visibilityMask)
            matrixRt = NaN(obj.numReceivers, obj.numTowers);

            if isempty(vectorValues)
                return;
            end

            [twrIdx, rxIdx] = find(visibilityMask.');

            n = min(numel(vectorValues), numel(rxIdx));
            linIdx = sub2ind(size(matrixRt), rxIdx(1:n), twrIdx(1:n));

            matrixRt(linIdx) = vectorValues(1:n);
        end

        function extra_m = nonAtmosphericExtraDelay_m( ...
                obj, towerIndex, receiverIndex, jd, towerEci_m, receiverEci_m, spaceAsset)
            extra_m = 0.0;

            if obj.useHardwareDelay
                towerSpecificTxDelay_m = obj.towers{towerIndex}.txSignalDelay_m;
                extra_m = extra_m + obj.txHardwareDelay_m + towerSpecificTxDelay_m + obj.rxHardwareDelay_m;
            end

            if obj.useMultipathDelay
                extra_m = extra_m + obj.multipathDelay_m;
            end

            if obj.useAntennaDelay
                txCorr_m = obj.towers{towerIndex}.txAntennaCorrection_m(receiverEci_m, jd);
                rxCorr_m = spaceAsset.rxAntennaCorrection_m(receiverIndex, towerEci_m);
                extra_m = extra_m + obj.antennaDelay_m + txCorr_m + rxCorr_m;
            end

            if obj.useSagnacCorrection
                extra_m = extra_m + obj.sagnacCorrection_m;
            end
        end

        function tf = measurementNoiseEnabled(obj)
            tf = obj.useMeasurementNoise;
        end

        function sigma2 = measurementVariance(obj, towerClockEkfEnabled, groundClockResidualVariance_m2)
            if nargin < 2 || isempty(towerClockEkfEnabled)
                towerClockEkfEnabled = false;
            end

            if nargin < 3 || isempty(groundClockResidualVariance_m2)
                groundClockResidualVariance_m2 = 0.0;
            end

            sigma2 = 0.0;

            if ~towerClockEkfEnabled
                sigma2 = sigma2 + groundClockResidualVariance_m2;
            end

            sigma2 = sigma2 + max(obj.pseudorangeSigma_m, obj.numericalSigmaFloor_m)^2;
            sigma2 = max(sigma2, 1e-12);
        end

        function sigma_m = effectiveNumericalMeasurementSigma_m(obj)
            sigma_m = obj.numericalSigmaFloor_m;
        end

    end

    methods (Access = private)
        
        function [delay_m, valid, gradientReceiverEci] = ...
                atmosphereDelayAndGradient_m( ...
                obj, atmosphereModel, towerIndex, receiverEci_m, jd, datetimeUtc)

            delay_m = 0.0;
            valid = true;
            gradientReceiverEci = zeros(3, 1);

            if isempty(atmosphereModel) || ~atmosphereModel.isEnabled()
                return;
            end

            [delay, gradientReceiverEci] = ...
                atmosphereModel.codeDelayAndGradientMeters( ...
                obj.towers{towerIndex}, ...
                receiverEci_m, ...
                jd, ...
                datetimeUtc, ...
                obj.signalFrequency_Hz);

            valid = logical(delay.valid);

            if ~valid
                delay_m = NaN;
                gradientReceiverEci(:) = NaN;
                return;
            end

            delay_m = double(delay.total_m);
            gradientReceiverEci = double(gradientReceiverEci(:));

            validateattributes(delay_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'atmosphereDelay_m');

            validateattributes(gradientReceiverEci, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'atmosphereGradientReceiverEci');
        end

        function validateLightTimeCorrectionConfiguration(obj)
            %VALIDATELIGHTTIMECORRECTIONCONFIGURATION Validate the future
            % inertial light-time correction settings without changing the
            % current pseudorange calculation.
        
            rawMethod = obj.lightTimeCorrectionMethod;
        
            % Normalize char arrays, string arrays, whitespace, and capitalization.
            methodKey = lower(strtrim(string(rawMethod)));
        
            if ~isscalar(methodKey) || ismissing(methodKey) || strlength(methodKey) == 0
                error('MeasurementModel:InvalidLightTimeCorrectionMethod', ...
                    ['lightTimeCorrectionMethod must be one non-empty string scalar. ', ...
                     'Received: %s'], mat2str(rawMethod));
            end
        
            allowedMethod = "inertialiterative";
        
            if methodKey ~= allowedMethod
                error('MeasurementModel:InvalidLightTimeCorrectionMethod', ...
                    ['lightTimeCorrectionMethod must be "inertialIterative". ', ...
                     'Received: "%s".'], char(methodKey));
            end
        
            validateattributes(obj.lightTimeCorrectionTolerance_s, ...
                {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'lightTimeCorrectionTolerance_s');
        
            validateattributes(obj.lightTimeCorrectionMaxIterations, ...
                {'numeric'}, ...
                {'real', 'finite', 'scalar', 'integer', 'positive'}, ...
                mfilename, 'lightTimeCorrectionMaxIterations');
        
            if obj.useLightTimeCorrection && obj.useSagnacCorrection
                error('MeasurementModel:LightTimeCorrectionSagnacConflict', ...
                    ['The inertial light-time correction and the separate ', ...
                     'Sagnac correction cannot be enabled simultaneously. ', ...
                     'The inertial light-time correction will represent Earth ', ...
                     'rotation by evaluating the ground transmitter at the ', ...
                     'signal transmission time.']);
            end
        
            % Store the canonical spelling for reports and later comparisons.
            obj.lightTimeCorrectionMethod = "inertialIterative";
        end
        
        function value = getFieldOrDefault(~, s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = s.(fieldName);
            else
                value = defaultValue;
            end
        end

        function value = getScalarField(~, s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = double(s.(fieldName));
            else
                value = double(defaultValue);
            end
        end
    end
end
