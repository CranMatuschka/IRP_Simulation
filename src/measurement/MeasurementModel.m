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
    %
    % Truth/model/residual audit map:
    %   - makePseudoranges() forms truth y. It evaluates truthAtmosphere,
    %     samples stochastic tower-common atmosphere residuals once per
    %     epoch, and adds those samples only to y.
    %   - predictPseudorangesWithJacobian() forms estimator yp and H. It
    %     evaluates modelAtmosphere only and does not access the actual
    %     stochastic truth residual samples.
    %   - measurementCovariance() represents estimator uncertainty. Model
    %     atmosphere residual sigmas enter R as same-tower common-mode
    %     covariance blocks through addSameTowerCommonVariance().
    %   - HistoryRecorder and ReportDataBuilder currently assemble
    %     atmosphere truth/model/residual diagnostics from the long
    %     backwards-compatible output lists. The migration path is to add a
    %     structured atmosphere budget internally while preserving these
    %     legacy outputs until callers are updated.

    properties
        cfg
        c double = 299792458.0

        towers cell = {}
        receiverAntennas = Antenna.empty(1, 0)
        receiverOffsetsBody_m double = zeros(3, 0)

        numReceivers double = 0
        numTowers double = 0

        measurementStream = []
        atmosphereResidualStream = []
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
        enableRelativisticPathDelay logical = false
        enableRelativisticClockCorrection logical = false
        
        propagationFrame string = "ECI_static_receive_epoch"
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
                truthAtmosphere, modelAtmosphere, atmosphereResidualStream)
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
            
            if nargin >= 8 && ~isempty(atmosphereResidualStream)
                if ~isa(atmosphereResidualStream, 'RandStream')
                    error('MeasurementModel:InvalidAtmosphereResidualStream', ...
                        'atmosphereResidualStream must be a RandStream object.');
                end

                obj.atmosphereResidualStream = atmosphereResidualStream;
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

            obj.enableRelativisticPathDelay = logical(obj.getFieldOrDefault( ...
                mcfg, 'enableRelativisticPathDelay', false));

            obj.enableRelativisticClockCorrection = logical(obj.getFieldOrDefault( ...
                mcfg, 'enableRelativisticClockCorrection', false));

            obj.propagationFrame = string(obj.getFieldOrDefault( ...
                mcfg, 'propagationFrame', "ECI_static_receive_epoch"));

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
        
        function [y, Rrange, trueRangeRt, losRt, receiverEci, ...
                visibilityMask, elevationRt_deg, ...
                atmosphereTruthDelayRt_m, ...
                atmosphereTruthTroposphereRt_m, ...
                atmosphereTruthIonosphereRt_m, ...
                atmosphereTruthResidualByTower_m, ...
                atmosphereTruthTroposphereResidualByTower_m, ...
                atmosphereTruthIonosphereResidualByTower_m, ...
                atmosphereTruthTroposphereDiagnostics, ...
                atmosphereTruthIonosphereDiagnostics] = ...
                makePseudoranges(obj, jd, datetimeUtc, towersEci, groundResidualTruth_m, ...
                truthAsset, towerClockEkfEnabled, groundClockResidualVariance_m2)
            
            maxMeas = obj.numReceivers * obj.numTowers;

            y = NaN(maxMeas, 1);
            trueRangeRt = NaN(obj.numReceivers, obj.numTowers);
            losRt = NaN(3, obj.numReceivers, obj.numTowers);
            receiverEci = truthAsset.receiverPositionsEci();
            visibilityMask = false(obj.numReceivers, obj.numTowers);
            elevationRt_deg = NaN(obj.numReceivers, obj.numTowers);
            measurementTowerIndex = zeros(maxMeas, 1);
            atmosphereTruthDelayRt_m = NaN(obj.numReceivers, obj.numTowers);
            atmosphereTruthTroposphereRt_m = ...
                NaN(obj.numReceivers, obj.numTowers);

            atmosphereTruthIonosphereRt_m = ...
                NaN(obj.numReceivers, obj.numTowers);
            atmosphereTruthTroposphereDiagnostics = ...
                obj.emptyTroposphereDiagnosticMatrices();
            atmosphereTruthIonosphereDiagnostics = ...
                obj.emptyIonosphereDiagnosticMatrices();

            bRx_m = truthAsset.getClockBias_m();
            [atmosphereTruthResidualByTower_m, ...
                    atmosphereTruthTroposphereResidualByTower_m, ...
                    atmosphereTruthIonosphereResidualByTower_m] = ...
                obj.sampleTruthAtmosphereResidualByTower_m();
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

                    [atmosphere_m, atmosphereValid, ~, atmosphereDetails] = ...
                        obj.atmosphereDelayAndGradient_m( ...
                        obj.truthAtmosphere, twr, rRx_I, jd, datetimeUtc);

                    if ~atmosphereValid
                        continue;
                    end
                    atmosphereTruthDelayRt_m(rx, twr) = atmosphere_m;
                    atmosphereTruthTroposphereRt_m(rx, twr) = ...
                        atmosphereDetails.troposphere_m;
                    atmosphereTruthTroposphereDiagnostics = ...
                        obj.assignTroposphereDiagnostics( ...
                        atmosphereTruthTroposphereDiagnostics, ...
                        rx, ...
                        twr, ...
                        atmosphereDetails.troposphereDiagnostics);
                    atmosphereTruthIonosphereRt_m(rx, twr) = ...
                        atmosphereDetails.ionosphere_m;
                    atmosphereTruthIonosphereDiagnostics = ...
                        obj.assignIonosphereDiagnostics( ...
                        atmosphereTruthIonosphereDiagnostics, ...
                        rx, ...
                        twr, ...
                        atmosphereDetails.ionosphereDiagnostics);
                    extra_m = obj.nonAtmosphericExtraDelay_m( ...
                        twr, rx, jd, towersEci(:, twr), rRx_I, truthAsset);

                    row = row + 1;
                    measurementTowerIndex(row) = twr;

                    y(row) = rho ...
                        + bRx_m ...
                        - groundResidualTruth_m(twr) ...
                        + atmosphere_m ...
                        + atmosphereTruthResidualByTower_m(twr) ...
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
            measurementTowerIndex = measurementTowerIndex(1:row);

            Rrange = obj.measurementCovariance( ...
                measurementTowerIndex, ...
                towerClockEkfEnabled, ...
                groundClockResidualVariance_m2);
        end
                
        function [yp, H, atmosphereModelDelayRt_m, ...
                atmosphereModelTroposphereRt_m, ...
                atmosphereModelIonosphereRt_m, ...
                atmosphereModelTroposphereDiagnostics, ...
                atmosphereModelIonosphereDiagnostics] = ...
                predictPseudorangesWithJacobian( ...
                obj, jd, datetimeUtc, towersEci, ...
                groundResidualModel_m, visibilityMask, estAsset, ...
                estTowerClockBias_m, idx, stateDim, towerClockEkfEnabled)

            if nargin < 6 || isempty(visibilityMask)
                visibilityMask = true(obj.numReceivers, obj.numTowers);
            end

            yp = zeros(nnz(visibilityMask), 1);
            H = zeros(numel(yp), stateDim);
            atmosphereModelDelayRt_m = NaN(obj.numReceivers, obj.numTowers);
            atmosphereModelTroposphereRt_m = ...
                NaN(obj.numReceivers, obj.numTowers);
            atmosphereModelTroposphereDiagnostics = ...
                obj.emptyTroposphereDiagnosticMatrices();
            atmosphereModelIonosphereRt_m = ...
                NaN(obj.numReceivers, obj.numTowers);
            atmosphereModelIonosphereDiagnostics = ...
                obj.emptyIonosphereDiagnosticMatrices();

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

                    [atmosphere_m, atmosphereValid, ...
                            atmosphereGradient_I, atmosphereDetails] = ...
                        obj.atmosphereDelayAndGradient_m( ...
                        obj.modelAtmosphere, twr, rRx_I, jd, datetimeUtc);

                    if ~atmosphereValid
                        error('MeasurementModel:InvalidModelAtmosphereDelay', ...
                            ['Estimator atmosphere delay is invalid for tower %d ', ...
                             'and receiver %d.'], twr, rx);
                    end
                    atmosphereModelDelayRt_m(rx, twr) = atmosphere_m;
                    atmosphereModelTroposphereRt_m(rx, twr) = ...
                        atmosphereDetails.troposphere_m;
                    atmosphereModelTroposphereDiagnostics = ...
                        obj.assignTroposphereDiagnostics( ...
                        atmosphereModelTroposphereDiagnostics, ...
                        rx, ...
                        twr, ...
                        atmosphereDetails.troposphereDiagnostics);
                    atmosphereModelIonosphereDiagnostics = ...
                        obj.assignIonosphereDiagnostics( ...
                        atmosphereModelIonosphereDiagnostics, ...
                        rx, ...
                        twr, ...
                        atmosphereDetails.ionosphereDiagnostics);
                    atmosphereModelIonosphereRt_m(rx, twr) = ...
                        atmosphereDetails.ionosphere_m;

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
        
        function sigma2 = measurementVariance( ...
                obj, towerClockEkfEnabled, groundClockResidualVariance_m2)

            if nargin < 2 || isempty(towerClockEkfEnabled)
                towerClockEkfEnabled = false;
            end

            if nargin < 3 || isempty(groundClockResidualVariance_m2)
                groundClockResidualVariance_m2 = 0.0;
            end

            independentSigma_m = max( ...
                obj.pseudorangeSigma_m, ...
                obj.numericalSigmaFloor_m);

            sigma2 = independentSigma_m^2;

            if ~towerClockEkfEnabled
                sigma2 = sigma2 + groundClockResidualVariance_m2;
            end

            sigma2 = sigma2 + obj.atmosphereResidualVariance_m2();
            sigma2 = max(sigma2, 1e-12);
        end
        
        function R = measurementCovariance( ...
                obj, measurementTowerIndex, ...
                towerClockEkfEnabled, groundClockResidualVariance_m2)

            if nargin < 3 || isempty(towerClockEkfEnabled)
                towerClockEkfEnabled = false;
            end

            if nargin < 4 || isempty(groundClockResidualVariance_m2)
                groundClockResidualVariance_m2 = 0.0;
            end

            measurementTowerIndex = double(measurementTowerIndex(:));
            n = numel(measurementTowerIndex);

            if n == 0
                R = zeros(0, 0);
                return;
            end

            validateattributes(measurementTowerIndex, {'numeric'}, ...
                {'real', 'finite', 'integer', 'positive'}, ...
                mfilename, 'measurementTowerIndex');

            independentSigma_m = max( ...
                obj.pseudorangeSigma_m, ...
                obj.numericalSigmaFloor_m);

            R = eye(n) * independentSigma_m^2;

            if ~towerClockEkfEnabled && groundClockResidualVariance_m2 > 0.0
                R = obj.addSameTowerCommonVariance( ...
                    R, measurementTowerIndex, groundClockResidualVariance_m2);
            end

            atmosphereVariance_m2 = obj.atmosphereResidualVariance_m2();

            if atmosphereVariance_m2 > 0.0
                R = obj.addSameTowerCommonVariance( ...
                    R, measurementTowerIndex, atmosphereVariance_m2);
            end

            R = 0.5 * (R + R');

            validateattributes(R, {'numeric'}, ...
                {'real', 'finite', 'size', [n, n]}, ...
                mfilename, 'R');
        end
        
        function sigma_m = effectiveNumericalMeasurementSigma_m(obj)
            sigma_m = obj.numericalSigmaFloor_m;
        end

        function sigma2 = atmosphereResidualVariance_m2(obj)
            if isempty(obj.modelAtmosphere)
                sigma2 = 0.0;
                return;
            end

            sigma2 = obj.modelAtmosphere.residualCodeVariance_m2();
        end

        function diagnostics = propagationDiagnosticsForVisibleLinks(obj, visibilityMask)
            if nargin < 2 || isempty(visibilityMask)
                visibilityMask = true(obj.numReceivers, obj.numTowers);
            end

            validateattributes(visibilityMask, {'logical'}, ...
                {'size', [obj.numReceivers, obj.numTowers]}, ...
                mfilename, 'visibilityMask');

            visibleScaffold_m = NaN(obj.numReceivers, obj.numTowers);
            visibleScaffold_m(visibilityMask) = 0.0;

            diagnostics = struct();
            diagnostics.frame_used = obj.propagationFrame;

            diagnostics.light_time = struct();
            diagnostics.light_time.truth_m = visibleScaffold_m;
            diagnostics.light_time.model_m = visibleScaffold_m;

            diagnostics.sagnac = struct();
            diagnostics.sagnac.truth_m = visibleScaffold_m;
            if obj.useSagnacCorrection
                diagnostics.sagnac.truth_m(visibilityMask) = ...
                    obj.sagnacCorrection_m;
            end
            diagnostics.sagnac.model_m = visibleScaffold_m;

            diagnostics.relativity = struct();
            diagnostics.relativity.truth = struct();
            diagnostics.relativity.model = struct();
            diagnostics.relativity.residual = struct();
            diagnostics.relativity.truth.pathDelay_m = visibleScaffold_m;
            diagnostics.relativity.model.pathDelay_m = visibleScaffold_m;
            diagnostics.relativity.truth.clockCorrection_m = ...
                visibleScaffold_m;
            diagnostics.relativity.model.clockCorrection_m = ...
                visibleScaffold_m;
            diagnostics.relativity.residual.total_m = visibleScaffold_m;

            diagnostics.light_time.residual_m = ...
                diagnostics.light_time.truth_m - ...
                diagnostics.light_time.model_m;
            diagnostics.sagnac.residual_m = ...
                diagnostics.sagnac.truth_m - diagnostics.sagnac.model_m;

            diagnostics.relativistic_path_enabled = ...
                obj.enableRelativisticPathDelay;
            diagnostics.relativistic_clock_enabled = ...
                obj.enableRelativisticClockCorrection;
            diagnostics.note = ...
                "Light-time and relativistic corrections are scaffolded as explicit zero terms unless a future implementation enables them.";
        end
    
    end

    methods (Access = private)
        
        function diagnostics = emptyTroposphereDiagnosticMatrices(obj)
            diagnostics = struct();

            diagnostics.pressure_hPa = NaN(obj.numReceivers, obj.numTowers);
            diagnostics.temperature_K = NaN(obj.numReceivers, obj.numTowers);
            diagnostics.relative_humidity_fraction = NaN(obj.numReceivers, obj.numTowers);
            diagnostics.water_vapor_pressure_hPa = NaN(obj.numReceivers, obj.numTowers);

            diagnostics.zhd_m = NaN(obj.numReceivers, obj.numTowers);
            diagnostics.zwd_m = NaN(obj.numReceivers, obj.numTowers);

            diagnostics.mapping_hydrostatic = NaN(obj.numReceivers, obj.numTowers);
            diagnostics.mapping_wet = NaN(obj.numReceivers, obj.numTowers);

            diagnostics.slant_hydrostatic_m = NaN(obj.numReceivers, obj.numTowers);
            diagnostics.slant_wet_m = NaN(obj.numReceivers, obj.numTowers);
        end

        function diagnostics = emptyTroposphereDiagnosticScalar(~)
            diagnostics = struct( ...
                'pressure_hPa', NaN, ...
                'temperature_K', NaN, ...
                'relative_humidity_fraction', NaN, ...
                'water_vapor_pressure_hPa', NaN, ...
                'zhd_m', NaN, ...
                'zwd_m', NaN, ...
                'mapping_hydrostatic', NaN, ...
                'mapping_wet', NaN, ...
                'slant_hydrostatic_m', NaN, ...
                'slant_wet_m', NaN);
        end

        function matrices = assignTroposphereDiagnostics( ...
                ~, matrices, rx, twr, scalarDiagnostics)

            matrices.pressure_hPa(rx, twr) = scalarDiagnostics.pressure_hPa;
            matrices.temperature_K(rx, twr) = scalarDiagnostics.temperature_K;
            matrices.relative_humidity_fraction(rx, twr) = ...
                scalarDiagnostics.relative_humidity_fraction;
            matrices.water_vapor_pressure_hPa(rx, twr) = ...
                scalarDiagnostics.water_vapor_pressure_hPa;

            matrices.zhd_m(rx, twr) = scalarDiagnostics.zhd_m;
            matrices.zwd_m(rx, twr) = scalarDiagnostics.zwd_m;

            matrices.mapping_hydrostatic(rx, twr) = ...
                scalarDiagnostics.mapping_hydrostatic;
            matrices.mapping_wet(rx, twr) = scalarDiagnostics.mapping_wet;

            matrices.slant_hydrostatic_m(rx, twr) = ...
                scalarDiagnostics.slant_hydrostatic_m;
            matrices.slant_wet_m(rx, twr) = ...
                scalarDiagnostics.slant_wet_m;
        end

        function diagnostics = troposphereDiagnosticFromDelay(obj, delay)
            diagnostics = obj.emptyTroposphereDiagnosticScalar();

            if ~isfield(delay, 'metadata') || ~isstruct(delay.metadata) || ...
                    ~isfield(delay.metadata, 'troposphere') || ...
                    ~isstruct(delay.metadata.troposphere)
                return;
            end

            tropo = delay.metadata.troposphere;

            if isfield(tropo, 'valid') && ~tropo.valid
                return;
            end

            if isfield(tropo, 'pressure_hPa')
                diagnostics.pressure_hPa = double(tropo.pressure_hPa);
            end

            if isfield(tropo, 'temperature_K')
                diagnostics.temperature_K = double(tropo.temperature_K);
            end

            if isfield(tropo, 'relativeHumidity_fraction')
                diagnostics.relative_humidity_fraction = ...
                    double(tropo.relativeHumidity_fraction);
            end

            if isfield(tropo, 'waterVaporPressure_hPa')
                diagnostics.water_vapor_pressure_hPa = ...
                    double(tropo.waterVaporPressure_hPa);
            end

            if isfield(tropo, 'zenithHydrostaticDelay_m')
                diagnostics.zhd_m = double(tropo.zenithHydrostaticDelay_m);
            end

            if isfield(tropo, 'zenithWetDelay_m')
                diagnostics.zwd_m = double(tropo.zenithWetDelay_m);
            end

            if isfield(tropo, 'mappingHydrostatic')
                diagnostics.mapping_hydrostatic = double(tropo.mappingHydrostatic);
            end

            if isfield(tropo, 'mappingWet')
                diagnostics.mapping_wet = double(tropo.mappingWet);
            end

            if isfield(tropo, 'slantHydrostaticDelay_m')
                diagnostics.slant_hydrostatic_m = ...
                    double(tropo.slantHydrostaticDelay_m);
            end

            if isfield(tropo, 'slantWetDelay_m')
                diagnostics.slant_wet_m = double(tropo.slantWetDelay_m);
            end
        end
        
        function diagnostics = emptyIonosphereDiagnosticMatrices(obj)
            diagnostics = struct();

            diagnostics.ipp_lat_deg = ...
                NaN(obj.numReceivers, obj.numTowers);

            diagnostics.ipp_lon_deg = ...
                NaN(obj.numReceivers, obj.numTowers);

            diagnostics.vtec_TECU = ...
                NaN(obj.numReceivers, obj.numTowers);

            diagnostics.stec_TECU = ...
                NaN(obj.numReceivers, obj.numTowers);

            diagnostics.mapping_factor = ...
                NaN(obj.numReceivers, obj.numTowers);

            diagnostics.frequency_Hz = ...
                NaN(obj.numReceivers, obj.numTowers);
        end

        function diagnostics = emptyIonosphereDiagnosticScalar(~)
            diagnostics = struct( ...
                'ipp_lat_deg', NaN, ...
                'ipp_lon_deg', NaN, ...
                'vtec_TECU', NaN, ...
                'stec_TECU', NaN, ...
                'mapping_factor', NaN, ...
                'frequency_Hz', NaN);
        end

        function matrices = assignIonosphereDiagnostics( ...
                ~, matrices, rx, twr, scalarDiagnostics)

            matrices.ipp_lat_deg(rx, twr) = ...
                scalarDiagnostics.ipp_lat_deg;

            matrices.ipp_lon_deg(rx, twr) = ...
                scalarDiagnostics.ipp_lon_deg;

            matrices.vtec_TECU(rx, twr) = ...
                scalarDiagnostics.vtec_TECU;

            matrices.stec_TECU(rx, twr) = ...
                scalarDiagnostics.stec_TECU;

            matrices.mapping_factor(rx, twr) = ...
                scalarDiagnostics.mapping_factor;

            matrices.frequency_Hz(rx, twr) = ...
                scalarDiagnostics.frequency_Hz;
        end

        function diagnostics = ionosphereDiagnosticFromDelay(obj, delay)
            diagnostics = obj.emptyIonosphereDiagnosticScalar();

            if ~isfield(delay, 'metadata') || ~isstruct(delay.metadata)
                return;
            end

            metadata = delay.metadata;

            if isfield(metadata, 'frequency_Hz')
                diagnostics.frequency_Hz = double(metadata.frequency_Hz);
            end

            if isfield(metadata, 'ionospherePiercePoint') && ...
                    isstruct(metadata.ionospherePiercePoint)

                piercePoint = metadata.ionospherePiercePoint;

                if isfield(piercePoint, 'valid') && piercePoint.valid
                    if isfield(piercePoint, 'latitude_deg')
                        diagnostics.ipp_lat_deg = ...
                            double(piercePoint.latitude_deg);
                    end

                    if isfield(piercePoint, 'longitude_deg')
                        diagnostics.ipp_lon_deg = ...
                            double(piercePoint.longitude_deg);
                    end

                    if isfield(piercePoint, 'mappingFactor')
                        diagnostics.mapping_factor = ...
                            double(piercePoint.mappingFactor);
                    end
                end
            end

            if isfield(metadata, 'ionosphereMap') && ...
                    isstruct(metadata.ionosphereMap)

                mapResult = metadata.ionosphereMap;

                if isfield(mapResult, 'valid') && mapResult.valid
                    if isfield(mapResult, 'vtec_TECU')
                        diagnostics.vtec_TECU = ...
                            double(mapResult.vtec_TECU);
                    end

                    if isfield(mapResult, 'metadata') && ...
                            isstruct(mapResult.metadata)

                        if isfield(mapResult.metadata, 'slantTec_TECU')
                            diagnostics.stec_TECU = ...
                                double(mapResult.metadata.slantTec_TECU);
                        end

                        if isfield(mapResult.metadata, 'mappingFactor')
                            diagnostics.mapping_factor = ...
                                double(mapResult.metadata.mappingFactor);
                        end

                        if isfield(mapResult.metadata, 'frequency_Hz')
                            diagnostics.frequency_Hz = ...
                                double(mapResult.metadata.frequency_Hz);
                        end
                    end
                end
            end
        end
        
        function [delay_m, valid, gradientReceiverEci, components] = ...
                atmosphereDelayAndGradient_m( ...
                obj, atmosphereModel, towerIndex, receiverEci_m, jd, datetimeUtc)

            delay_m = 0.0;
            valid = true;
            gradientReceiverEci = zeros(3, 1);

            components = struct( ...
                'total_m', 0.0, ...
                'troposphere_m', 0.0, ...
                'ionosphere_m', 0.0, ...
                'troposphereDiagnostics', ...
                    obj.emptyTroposphereDiagnosticScalar(), ...
                'ionosphereDiagnostics', ...
                    obj.emptyIonosphereDiagnosticScalar());

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

                components.total_m = NaN;
                components.troposphere_m = NaN;
                components.ionosphere_m = NaN;
                components.troposphereDiagnostics = ...
                    obj.emptyTroposphereDiagnosticScalar();
                components.ionosphereDiagnostics = ...
                    obj.emptyIonosphereDiagnosticScalar();
                return;
            end

            delay_m = double(delay.total_m);
            gradientReceiverEci = double(gradientReceiverEci(:));

            components.total_m = double(delay.total_m);
            components.troposphere_m = double(delay.troposphere_m);
            components.ionosphere_m = double(delay.ionosphere_m);
            components.troposphereDiagnostics = ...
                obj.troposphereDiagnosticFromDelay(delay);
            components.ionosphereDiagnostics = ...
                obj.ionosphereDiagnosticFromDelay(delay);

            validateattributes(delay_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'atmosphereDelay_m');

            validateattributes(gradientReceiverEci, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'atmosphereGradientReceiverEci');
        end
        
        function [residualByTower_m, troposphereResidualByTower_m, ...
                ionosphereResidualByTower_m] = ...
                sampleTruthAtmosphereResidualByTower_m(obj)
            %SAMPLETRUTHATMOSPHERERESIDUALBYTOWER_M Generate tower-common
            % atmosphere residual samples for the current epoch.
            %
            % Troposphere and ionosphere residuals are sampled independently.
            % Their sum is the total atmospheric residual added to each
            % pseudorange from the same tower. This matches the covariance
            % model sigma_total^2 = sigma_tropo^2 + sigma_iono^2.

            troposphereResidualByTower_m = zeros(obj.numTowers, 1);
            ionosphereResidualByTower_m = zeros(obj.numTowers, 1);

            if isempty(obj.truthAtmosphere)
                residualByTower_m = zeros(obj.numTowers, 1);
                return;
            end

            troposphereSigma_m = 0.0;
            ionosphereSigma_m = 0.0;

            if obj.truthAtmosphere.enableTroposphere
                troposphereSigma_m = ...
                    double(obj.truthAtmosphere.residualTroposphereSigma_m);
            end

            if obj.truthAtmosphere.enableIonosphere
                ionosphereSigma_m = ...
                    double(obj.truthAtmosphere.residualIonosphereSigma_m);
            end

            if troposphereSigma_m > 0.0
                troposphereResidualByTower_m = troposphereSigma_m * ...
                    obj.standardNormalAtmosphereSamplesByTower();
            end

            if ionosphereSigma_m > 0.0
                ionosphereResidualByTower_m = ionosphereSigma_m * ...
                    obj.standardNormalAtmosphereSamplesByTower();
            end

            residualByTower_m = ...
                troposphereResidualByTower_m + ionosphereResidualByTower_m;

            validateattributes(residualByTower_m, {'numeric'}, ...
                {'real', 'finite', 'size', [obj.numTowers, 1]}, ...
                mfilename, 'residualByTower_m');

            validateattributes(troposphereResidualByTower_m, {'numeric'}, ...
                {'real', 'finite', 'size', [obj.numTowers, 1]}, ...
                mfilename, 'troposphereResidualByTower_m');

            validateattributes(ionosphereResidualByTower_m, {'numeric'}, ...
                {'real', 'finite', 'size', [obj.numTowers, 1]}, ...
                mfilename, 'ionosphereResidualByTower_m');
        end

        function standardNormal = standardNormalAtmosphereSamplesByTower(obj)
            if isempty(obj.atmosphereResidualStream)
                standardNormal = randn(obj.numTowers, 1);
            else
                standardNormal = randn( ...
                    obj.atmosphereResidualStream, ...
                    obj.numTowers, ...
                    1);
            end
        end
        
        function R = addSameTowerCommonVariance( ...
                ~, R, measurementTowerIndex, commonVariance_m2)

            commonVariance_m2 = double(commonVariance_m2);

            validateattributes(commonVariance_m2, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'commonVariance_m2');

            towerIds = unique(measurementTowerIndex(:).');

            for towerId = towerIds
                rows = measurementTowerIndex == towerId;
                R(rows, rows) = R(rows, rows) + commonVariance_m2;
            end
        end        
        
        function validateLightTimeCorrectionConfiguration(obj)
            %VALIDATELIGHTTIMECORRECTIONCONFIGURATION Validate the future
            % inertial light-time correction settings without changing the
            % current pseudorange calculation.
        
            frameKey = lower(strtrim(string(obj.propagationFrame)));

            if ~isscalar(frameKey) || ismissing(frameKey) || strlength(frameKey) == 0
                error('MeasurementModel:InvalidPropagationFrame', ...
                    ['propagationFrame must be one non-empty string scalar. ', ...
                     'Received: %s'], char(string(obj.propagationFrame)));
            end

            if frameKey ~= "eci_static_receive_epoch"
                error('MeasurementModel:InvalidPropagationFrame', ...
                    ['propagationFrame must currently be ', ...
                     '"ECI_static_receive_epoch". Received: "%s".'], ...
                    char(frameKey));
            end

            obj.propagationFrame = "ECI_static_receive_epoch";

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

            if obj.enableRelativisticPathDelay
                error('MeasurementModel:RelativisticPathDelayNotImplemented', ...
                    ['enableRelativisticPathDelay is explicit but not yet ', ...
                     'implemented. Keep it disabled until a Shapiro/path ', ...
                     'model is added.']);
            end

            if obj.enableRelativisticClockCorrection
                error('MeasurementModel:RelativisticClockCorrectionNotImplemented', ...
                    ['enableRelativisticClockCorrection is explicit but not ', ...
                     'yet implemented. Keep it disabled until the affected ', ...
                     'physical clock is modelled.']);
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
