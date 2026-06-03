classdef MeasurementModel < handle
    %MEASUREMENTMODEL Reverse-GNSS pseudorange measurement model.
    %
    % Owns:
    %   - truth pseudorange generation
    %   - predicted pseudorange generation
    %   - pseudorange Jacobian H
    %   - measurement covariance R
    %   - elevation mask logic
    %   - deterministic extra-delay toggles
    %   - measurement-noise injection
    %   - tower-clock gauge constraint rows

    properties
        cfg
        c double = 299792458.0

        towers cell = {}
        receiverAntennas = Antenna.empty(1, 0)
        receiverOffsetsBody_m double = zeros(3, 0)

        numReceivers double = 0
        numTowers double = 0

        measurementStream = []

        % Cached measurement options, initialized once.
        useMeasurementNoise logical = false
        useElevationMask logical = false
        elevationMask_deg double = 0.0

        useIonosphereDelay logical = false
        useTroposphereDelay logical = false
        useHardwareDelay logical = false
        useMultipathDelay logical = false
        useAntennaDelay logical = false
        useSagnacCorrection logical = false

        ionosphereDelay_m double = 0.0
        troposphereDelay_m double = 0.0
        txHardwareDelay_m double = 0.0
        rxHardwareDelay_m double = 0.0
        multipathDelay_m double = 0.0
        antennaDelay_m double = 0.0
        sagnacCorrection_m double = 0.0

        pseudorangeSigma_m double = 0.30
        numericalSigmaFloor_m double = 1e-4
    end

    methods
        function obj = MeasurementModel(scenarioCfg, c, towers, receiverAntennas, measurementStream)
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

            mcfg = scenarioCfg.measurement;

            obj.useMeasurementNoise = logical(obj.getFieldOrDefault(mcfg, 'enableMeasurementNoise', false)) || ...
                                      logical(obj.getFieldOrDefault(mcfg, 'enableNoise', false));

            obj.useElevationMask = logical(obj.getFieldOrDefault(mcfg, 'enableElevationMask', false));
            obj.elevationMask_deg = obj.getScalarField(mcfg, 'elevationMask_deg', 0.0);

            obj.useIonosphereDelay = logical(obj.getFieldOrDefault(mcfg, 'enableIonosphereDelay', false));
            obj.useTroposphereDelay = logical(obj.getFieldOrDefault(mcfg, 'enableTroposphereDelay', false));
            obj.useHardwareDelay = logical(obj.getFieldOrDefault(mcfg, 'enableHardwareDelay', false));
            obj.useMultipathDelay = logical(obj.getFieldOrDefault(mcfg, 'enableMultipathDelay', false));
            obj.useAntennaDelay = logical(obj.getFieldOrDefault(mcfg, 'enableAntennaDelay', false));
            obj.useSagnacCorrection = logical(obj.getFieldOrDefault(mcfg, 'enableSagnacCorrection', false));

            obj.ionosphereDelay_m = obj.getScalarField(mcfg, 'ionosphereDelay_m', 0.0);
            obj.troposphereDelay_m = obj.getScalarField(mcfg, 'troposphereDelay_m', 0.0);
            obj.txHardwareDelay_m = obj.getScalarField(mcfg, 'txHardwareDelay_m', 0.0);
            obj.rxHardwareDelay_m = obj.getScalarField(mcfg, 'rxHardwareDelay_m', 0.0);
            obj.multipathDelay_m = obj.getScalarField(mcfg, 'multipathDelay_m', 0.0);
            obj.antennaDelay_m = obj.getScalarField(mcfg, 'antennaDelay_m', 0.0);
            obj.sagnacCorrection_m = obj.getScalarField(mcfg, 'sagnacCorrection_m', 0.0);

            obj.pseudorangeSigma_m = obj.getScalarField(mcfg, 'pseudorangeSigma_m', 0.30);
            obj.numericalSigmaFloor_m = obj.getScalarField(mcfg, ...
                'sigma_numerical_floor_m', ...
                obj.getScalarField(mcfg, 'deterministicSigma_m', 1e-4));
        end

        function [y, Rrange, trueRangeRt, losRt, receiverEci, visibilityMask, elevationRt_deg] = ...
                makePseudoranges(obj, jd, towersEci, groundResidualTruth_m, ...
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

                    extra_m = obj.extraDelay_m( ...
                        twr, rx, jd, towersEci(:, twr), rRx_I, truthAsset);

                    row = row + 1;
                    y(row) = rho + bRx_m - groundResidualTruth_m(twr) + extra_m;

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
                
        function [yp, H] = predictPseudorangesWithJacobian(obj, towersEci, ...
                groundResidualModel_m, visibilityMask, estAsset, ...
                estTowerClockBias_m, idx, stateDim, towerClockEkfEnabled)

            if nargin < 4 || isempty(visibilityMask)
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

                    if towerClockEkfEnabled
                        yp(row) = rho + estClockBias_m - estTowerClockBias_m(twr);

                        H(row, idx.pos) = u.';
                        H(row, idx.att) = u.' * J_att;
                        H(row, idx.rxClockBias) = 1.0;
                        H(row, idx.towerClockBias(twr)) = -1.0;
                    else
                        yp(row) = rho + estClockBias_m - groundResidualModel_m(twr);

                        H(row, idx.pos) = u.';
                        H(row, idx.att) = u.' * J_att;
                        H(row, idx.rxClockBias) = 1.0;
                    end

                    row = row + 1;
                end
            end
        end

        function [yAll, ypAll, HAll, RAll] = appendTowerClockGaugeConstraint(obj, ...
                yRange, ypRange, HRange, RRange, ...
                estTowerClockBias_m, estTowerClockDrift_mps, ...
                idx, stateDim, towerClockEkfEnabled, ekfCfg)
        
            if ~towerClockEkfEnabled
                yAll = yRange;
                ypAll = ypRange;
                HAll = HRange;
                RAll = RRange;
                return;
            end
        
            if obj.numTowers < 1
                yAll = yRange;
                ypAll = ypRange;
                HAll = HRange;
                RAll = RRange;
                return;
            end
        
            gaugeMode = string(obj.getFieldOrDefault(obj.cfg, ...
                'towerClockGaugeMode', "meanGroundClock"));
        
            if gaugeMode ~= "meanGroundClock"
                error('ReverseGnssSimulation:UnsupportedTowerClockGauge', ...
                    'Only towerClockGaugeMode="meanGroundClock" is currently implemented.');
            end
        
            sigmaBias_m = obj.getScalarField(ekfCfg, ...
                'towerClockGaugeBiasSigma_m', 1e-4);
        
            sigmaDrift_mps = obj.getScalarField(ekfCfg, ...
                'towerClockGaugeDriftSigma_mps', 1e-6);
        
            yGauge = [0.0; 0.0];
        
            ypGauge = [ ...
                mean(estTowerClockBias_m); ...
                mean(estTowerClockDrift_mps)];
        
            HGauge = zeros(2, stateDim);
        
            HGauge(1, idx.towerClockBias) = 1.0 / obj.numTowers;
            HGauge(2, idx.towerClockDrift) = 1.0 / obj.numTowers;
        
            RGauge = diag([sigmaBias_m^2, sigmaDrift_mps^2]);
        
            yAll = [yRange; yGauge];
            ypAll = [ypRange; ypGauge];
            HAll = [HRange; HGauge];
            RAll = blkdiag(RRange, RGauge);
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

        function extra_m = extraDelay_m(obj, towerIndex, receiverIndex, jd, towerEci_m, receiverEci_m, spaceAsset)
            extra_m = 0.0;

            if obj.useIonosphereDelay
                extra_m = extra_m + obj.ionosphereDelay_m;
            end

            if obj.useTroposphereDelay
                extra_m = extra_m + obj.troposphereDelay_m;
            end

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
