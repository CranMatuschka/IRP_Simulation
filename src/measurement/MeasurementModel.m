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
    %
    %
    % Implemented first-stage error-chain status:
    %   - Atmosphere: truth/model/residual/covariance chain is active.
    %     Truth deterministic delay and sampled stochastic residuals enter y;
    %     estimator model delay enters yp; estimator residual sigmas enter R.
    %   - Non-atmospheric budget: hardware, antenna scalar correction,
    %     deterministic/stochastic multipath, tower-survey range effect, and
    %     legacy scalar Sagnac all expose truth/model/residual components.
    %   - Propagation: ECI receive-epoch range is the baseline. Optional
    %     inertial iterative light-time can enter y and/or yp through
    %     separate truth/model toggles. Shapiro path delay is scaffolded but
    %     guarded until accepted in a dedicated physics/test branch.
    %   - Covariance: update-time R is built per epoch. Same-tower common
    %     covariance is used for atmosphere/ground-clock residuals; stochastic
    %     multipath contributes independent diagonal variance.
    %
    % Known limitations:
    %   - Relativistic clock correction is explicit but guarded, because the
    %     affected physical clock dynamics must be defined before applying a
    %     GPS-style eccentricity correction.
    %   - Antenna PCO/PCV truth/model separation is still first-stage only:
    %     the current model-side antenna correction is scalar.
    %   - Tower-specific hardware model delay is still future work; current
    %     model hardware correction is global TX/RX.
    %   - Carrier phase observables are not part of this first-stage chain.
    %   - Keep follow-up changes small and local. Prefer simple MATLAB structs
    %     and backward-compatible wrappers over new class hierarchies.

    properties
        cfg
        c double = 299792458.0
        muEarth_m3ps2 double = 3.986004418e14
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
        useStochasticMultipath logical = false
        useAntennaDelay logical = false
        useSagnacCorrection logical = false
        useLightTimeCorrection logical = false
        useLightTimeCorrectionTruth logical = false
        useLightTimeCorrectionModel logical = false
        useTowerSurveyError logical = false
        enableRelativisticPathDelay logical = false
        enableRelativisticClockCorrection logical = false
        enableRelativisticPathDelayTruth logical = false
        enableRelativisticPathDelayModel logical = false
        enableRelativisticClockCorrectionTruth logical = false
        enableRelativisticClockCorrectionModel logical = false    
        propagationFrame string = "ECI_static_receive_epoch"
        lightTimeCorrectionMethod string = "inertialIterative"
        lightTimeCorrectionTolerance_s double = 1e-12
        lightTimeCorrectionMaxIterations double = 10

        txHardwareDelay_m double = 0.0
        rxHardwareDelay_m double = 0.0
        multipathDelay_m double = 0.0
        multipathStochasticSigma0_m double = 0.20
        multipathStochasticMinimumElevation_deg double = 10.0
        multipathStochasticRandomSeed double = 246813579
        antennaDelay_m double = 0.0
        sagnacCorrection_m double = 0.0
        txHardwareDelayModel_m double = 0.0
        rxHardwareDelayModel_m double = 0.0
        multipathDelayModel_m double = 0.0
        antennaDelayModel_m double = 0.0
        sagnacCorrectionModel_m double = 0.0

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
            obj.muEarth_m3ps2 = obj.getScalarField( ...
                mcfg, ...
                'earthGravitationalParameter_m3ps2', ...
                3.986004418e14);

            validateattributes(obj.muEarth_m3ps2, ...
                {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'earthGravitationalParameter_m3ps2');
            obj.useMeasurementNoise = logical(obj.getFieldOrDefault(mcfg, 'enableMeasurementNoise', false)) || ...
                                      logical(obj.getFieldOrDefault(mcfg, 'enableNoise', false));
    
            obj.useElevationMask = logical(obj.getFieldOrDefault(mcfg, 'enableElevationMask', false));
            obj.elevationMask_deg = obj.getScalarField(mcfg, 'elevationMask_deg', 0.0);

            obj.useHardwareDelay = logical(obj.getFieldOrDefault(mcfg, 'enableHardwareDelay', false));
            obj.useMultipathDelay = logical(obj.getFieldOrDefault(mcfg, 'enableMultipathDelay', false));
            obj.useStochasticMultipath = logical(obj.getFieldOrDefault( ...
                mcfg, 'enableStochasticMultipath', false));
            obj.useAntennaDelay = logical(obj.getFieldOrDefault(mcfg, 'enableAntennaDelay', false));
            obj.useSagnacCorrection = logical(obj.getFieldOrDefault(mcfg, 'enableSagnacCorrection', false));
            obj.useTowerSurveyError = logical(obj.getFieldOrDefault( ...
                mcfg, 'enableTowerSurveyError', false));
            obj.useLightTimeCorrection = logical(obj.getFieldOrDefault( ...
                mcfg, 'enableLightTimeCorrection', false));
            obj.useLightTimeCorrectionTruth = logical(obj.getFieldOrDefault( ...
                mcfg, ...
                'enableLightTimeCorrectionTruth', ...
                obj.useLightTimeCorrection));

            obj.useLightTimeCorrectionModel = logical(obj.getFieldOrDefault( ...
                mcfg, ...
                'enableLightTimeCorrectionModel', ...
                obj.useLightTimeCorrection));
            obj.enableRelativisticPathDelay = logical(obj.getFieldOrDefault( ...
                mcfg, 'enableRelativisticPathDelay', false));

            obj.enableRelativisticClockCorrection = logical(obj.getFieldOrDefault( ...
                mcfg, 'enableRelativisticClockCorrection', false));
            obj.enableRelativisticPathDelayTruth = logical(obj.getFieldOrDefault( ...
                mcfg, ...
                'enableRelativisticPathDelayTruth', ...
                obj.enableRelativisticPathDelay));

            obj.enableRelativisticPathDelayModel = logical(obj.getFieldOrDefault( ...
                mcfg, ...
                'enableRelativisticPathDelayModel', ...
                obj.enableRelativisticPathDelay));

            obj.enableRelativisticClockCorrectionTruth = logical(obj.getFieldOrDefault( ...
                mcfg, ...
                'enableRelativisticClockCorrectionTruth', ...
                obj.enableRelativisticClockCorrection));

            obj.enableRelativisticClockCorrectionModel = logical(obj.getFieldOrDefault( ...
                mcfg, ...
                'enableRelativisticClockCorrectionModel', ...
                obj.enableRelativisticClockCorrection));
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
            obj.multipathStochasticSigma0_m = obj.getScalarField( ...
                mcfg, 'multipathStochasticSigma0_m', 0.20);
            obj.multipathStochasticMinimumElevation_deg = obj.getScalarField( ...
                mcfg, 'multipathStochasticMinimumElevation_deg', 10.0);
            obj.multipathStochasticRandomSeed = obj.getScalarField( ...
                mcfg, 'multipathStochasticRandomSeed', 246813579);

            validateattributes(obj.multipathStochasticSigma0_m, ...
                {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'multipathStochasticSigma0_m');

            validateattributes(obj.multipathStochasticMinimumElevation_deg, ...
                {'numeric'}, ...
                {'real', 'finite', 'scalar', '>=', 5.0, '<=', 90.0}, ...
                mfilename, 'multipathStochasticMinimumElevation_deg');

            validateattributes(obj.multipathStochasticRandomSeed, ...
                {'numeric'}, ...
                {'real', 'finite', 'scalar'}, ...
                mfilename, 'multipathStochasticRandomSeed');
            obj.antennaDelay_m = obj.getScalarField(mcfg, 'antennaDelay_m', 0.0);
            obj.sagnacCorrection_m = obj.getScalarField(mcfg, 'sagnacCorrection_m', 0.0);
            obj.txHardwareDelayModel_m = obj.getScalarField(mcfg, 'txHardwareDelayModel_m', 0.0);
            obj.rxHardwareDelayModel_m = obj.getScalarField(mcfg, 'rxHardwareDelayModel_m', 0.0);
            obj.multipathDelayModel_m = obj.getScalarField(mcfg, 'multipathDelayModel_m', 0.0);
            obj.antennaDelayModel_m = obj.getScalarField(mcfg, 'antennaDelayModel_m', 0.0);
            obj.sagnacCorrectionModel_m = obj.getScalarField(mcfg, 'sagnacCorrectionModel_m', 0.0);
            
            obj.pseudorangeSigma_m = obj.getScalarField(mcfg, 'pseudorangeSigma_m', 0.30);
            obj.numericalSigmaFloor_m = obj.getScalarField(mcfg, ...
                'sigma_numerical_floor_m', ...
                obj.getScalarField(mcfg, 'deterministicSigma_m', 1e-4));
            obj.validateLightTimeCorrectionConfiguration();
        end
        
        function truth = makePseudoranges( ...
                obj, jd, datetimeUtc, towersEci, groundResidualTruth_m, ...
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
            nonAtmosphericTruth = obj.emptyNonAtmosphericTermMatrices();
            propagationTruth = obj.emptyPropagationTermMatrices();

            bRx_m = truthAsset.getClockBias_m();
            [atmosphereTruthResidualByTower_m, ...
                    atmosphereTruthTroposphereResidualByTower_m, ...
                    atmosphereTruthIonosphereResidualByTower_m] = ...
                obj.sampleTruthAtmosphereResidualByTower_m();
            independentExtraVariance_m2 = ...
                zeros(obj.numReceivers * obj.numTowers, 1);
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

                    geometry = obj.linkGeometry( ...
                        jd, ...
                        twr, ...
                        towersEci(:, twr), ...
                        rRx_I, ...
                        obj.useLightTimeCorrectionTruth, ...
                        obj.enableRelativisticPathDelayTruth);
                    rho = geometry.range_m;
                    u = geometry.los_I;
                    lightTimeTruth_m = geometry.lightTimeCorrection_m;
                    relativisticPathTruth_m = ...
                        geometry.relativisticPathDelay_m;
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
                    [extra_m, ~, linkTerms] = obj.nonAtmosphericTerms_m( ...
                        twr, rx, jd, towersEci(:, twr), rRx_I, truthAsset);

                    row = row + 1;
                    measurementTowerIndex(row) = twr;
                    independentExtraVariance_m2(row) = ...
                        obj.multipathVariance_m2( ...
                        twr, ...
                        jd, ...
                        towersEci(:, twr), ...
                        rRx_I);
                    y(row) = rho ...
                        + lightTimeTruth_m ...
                        + relativisticPathTruth_m ...
                        + bRx_m ...
                        - groundResidualTruth_m(twr) ...
                        + atmosphere_m ...
                        + atmosphereTruthResidualByTower_m(twr) ...
                        + extra_m;

                    if obj.useMeasurementNoise
                        y(row) = y(row) + StochasticProcess.whiteNoiseSample( ...
                            obj.pseudorangeSigma_m, 1, obj.measurementStream);
                    end

                    trueRangeRt(rx, twr) = rho;
                    losRt(:, rx, twr) = u;
                    visibilityMask(rx, twr) = true;
                    nonAtmosphericTruth = obj.assignLinkTerms( ...
                        nonAtmosphericTruth, rx, twr, linkTerms);
                    propagationTruth.lightTime.truth_m(rx, twr) = ...
                        lightTimeTruth_m;
                    propagationTruth.relativity.pathTruth_m(rx, twr) = ...
                        relativisticPathTruth_m;
                end
            end

            y = y(1:row);
            measurementTowerIndex = measurementTowerIndex(1:row);
            independentExtraVariance_m2 = independentExtraVariance_m2(1:row);

            Rrange = obj.measurementCovariance( ...
                measurementTowerIndex, ...
                towerClockEkfEnabled, ...
                groundClockResidualVariance_m2, ...
                independentExtraVariance_m2);

            truth = struct();
            truth.y = y;
            truth.R = Rrange;
            truth.trueRange_rt = trueRangeRt;
            truth.los_rt = losRt;
            truth.receiverEci = receiverEci;
            truth.visibilityMask = visibilityMask;
            truth.elevation_rt = elevationRt_deg;
            truth.atmosphere = struct( ...
                'delay_rt_m', atmosphereTruthDelayRt_m, ...
                'troposphere_rt_m', atmosphereTruthTroposphereRt_m, ...
                'ionosphere_rt_m', atmosphereTruthIonosphereRt_m, ...
                'residualByTower_m', atmosphereTruthResidualByTower_m, ...
                'troposphereResidualByTower_m', ...
                atmosphereTruthTroposphereResidualByTower_m, ...
                'ionosphereResidualByTower_m', ...
                atmosphereTruthIonosphereResidualByTower_m, ...
                'troposphereDiagnostics', atmosphereTruthTroposphereDiagnostics, ...
                'ionosphereDiagnostics', atmosphereTruthIonosphereDiagnostics);
            truth.nonAtmospheric = nonAtmosphericTruth;
            truth.propagation = propagationTruth;
        end
                
        function model = predictPseudorangesWithJacobian( ...
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
            nonAtmosphericModel = obj.emptyNonAtmosphericTermMatrices();
            propagationModel = obj.emptyPropagationTermMatrices();

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

                    geometry = obj.linkGeometry( ...
                        jd, ...
                        twr, ...
                        towersEci(:, twr), ...
                        rRx_I, ...
                        obj.useLightTimeCorrectionModel, ...
                        obj.enableRelativisticPathDelayModel);
                    rho = geometry.range_m;
                    u = geometry.los_I;
                    lightTimeModel_m = geometry.lightTimeCorrection_m;
                    relativisticPathModel_m = ...
                        geometry.relativisticPathDelay_m;
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
                    [~, extraModel_m, linkTerms] = ...
                        obj.nonAtmosphericTerms_m( ...
                        twr, ...
                        rx, ...
                        jd, ...
                        towersEci(:, twr), ...
                        rRx_I, ...
                        estAsset);
                    nonAtmosphericModel = obj.assignLinkTerms( ...
                        nonAtmosphericModel, rx, twr, linkTerms);
                    propagationModel.lightTime.model_m(rx, twr) = ...
                        lightTimeModel_m;
                    propagationModel.relativity.pathModel_m(rx, twr) = ...
                        relativisticPathModel_m;
                    pseudorangeGradient_I = u + atmosphereGradient_I;

                    if towerClockEkfEnabled
                        yp(row) = rho ...
                            + lightTimeModel_m ...
                            + relativisticPathModel_m ...
                            + estClockBias_m ...
                            - estTowerClockBias_m(twr) ...
                            + atmosphere_m ...
                            + extraModel_m;

                        H(row, idx.pos) = pseudorangeGradient_I.';
                        H(row, idx.att) = pseudorangeGradient_I.' * J_att;
                        H(row, idx.rxClockBias) = 1.0;
                        H(row, idx.towerClockBias(twr)) = -1.0;
                    else
                        yp(row) = rho ...
                            + lightTimeModel_m ...
                            + relativisticPathModel_m ...
                            + estClockBias_m ...
                            - groundResidualModel_m(twr) ...
                            + atmosphere_m ...
                            + extraModel_m;

                        H(row, idx.pos) = pseudorangeGradient_I.';
                        H(row, idx.att) = pseudorangeGradient_I.' * J_att;
                        H(row, idx.rxClockBias) = 1.0;
                    end

                    row = row + 1;
                end
            end

            model = struct();
            model.yhat = yp;
            model.H = H;
            model.atmosphere = struct( ...
                'delay_rt_m', atmosphereModelDelayRt_m, ...
                'troposphere_rt_m', atmosphereModelTroposphereRt_m, ...
                'ionosphere_rt_m', atmosphereModelIonosphereRt_m, ...
                'troposphereDiagnostics', atmosphereModelTroposphereDiagnostics, ...
                'ionosphereDiagnostics', atmosphereModelIonosphereDiagnostics);
            model.nonAtmospheric = nonAtmosphericModel;
            model.propagation = propagationModel;
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
            [extraTruth_m, ~, ~] = obj.nonAtmosphericTerms_m( ...
                towerIndex, ...
                receiverIndex, ...
                jd, ...
                towerEci_m, ...
                receiverEci_m, ...
                spaceAsset);

            extra_m = extraTruth_m;
        end

        function [extraTruth_m, extraModel_m, budget] = ...
                nonAtmosphericTerms_m( ...
                obj, towerIndex, receiverIndex, jd, ...
                towerEci_m, receiverEci_m, spaceAsset)
            budget = obj.emptyNonAtmosphericLinkTerms();

            if obj.useHardwareDelay
                budget.hardware = obj.withTruthModel( ...
                    budget.hardware, ...
                    obj.txHardwareDelay_m + ...
                    obj.towers{towerIndex}.txSignalDelay_m + ...
                    obj.rxHardwareDelay_m, ...
                    obj.txHardwareDelayModel_m + obj.rxHardwareDelayModel_m);
            end

            if obj.useMultipathDelay
                [stochasticTruth_m, sigma_m, ~] = obj.stochasticMultipathTruth_m( ...
                    towerIndex, receiverIndex, jd, towerEci_m, receiverEci_m);
                budget.multipath = obj.withTruthModel( ...
                    budget.multipath, ...
                    obj.multipathDelay_m + stochasticTruth_m, ...
                    obj.multipathDelayModel_m);
                budget.multipath.sigma_m = sigma_m;
                budget.multipath.variance_m2 = sigma_m^2;
            end

            if obj.useAntennaDelay
                txCorr_m = obj.towers{towerIndex}.txAntennaCorrection_m( ...
                    receiverEci_m, jd);
                rxCorr_m = spaceAsset.rxAntennaCorrection_m( ...
                    receiverIndex, towerEci_m);
                budget.antenna = obj.withTruthModel( ...
                    budget.antenna, ...
                    obj.antennaDelay_m + txCorr_m + rxCorr_m, ...
                    obj.antennaDelayModel_m);
            end

            if obj.useSagnacCorrection
                budget.legacySagnac = obj.withTruthModel( ...
                    budget.legacySagnac, ...
                    obj.sagnacCorrection_m, ...
                    obj.sagnacCorrectionModel_m);
            end

            if obj.useTowerSurveyError
                truthTowerSurvey_m = obj.towerSurveyRangeEffect_m( ...
                    jd, towerEci_m, receiverEci_m, ...
                    obj.towers{towerIndex}.truthPositionOffsetEcef_m);
                modelTowerSurvey_m = obj.towerSurveyRangeEffect_m( ...
                    jd, towerEci_m, receiverEci_m, ...
                    obj.towers{towerIndex}.modelPositionOffsetEcef_m);
                budget.towerSurvey = obj.withTruthModel( ...
                    budget.towerSurvey, truthTowerSurvey_m, modelTowerSurvey_m);
            end

            extraTruth_m = ...
                budget.hardware.truth_m + ...
                budget.antenna.truth_m + ...
                budget.multipath.truth_m + ...
                budget.towerSurvey.truth_m + ...
                budget.legacySagnac.truth_m;

            extraModel_m = ...
                budget.hardware.model_m + ...
                budget.antenna.model_m + ...
                budget.multipath.model_m + ...
                budget.towerSurvey.model_m + ...
                budget.legacySagnac.model_m;

            budget.total = obj.withTruthModel( ...
                budget.total, extraTruth_m, extraModel_m);
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
            sigma2 = sigma2 + obj.nominalMultipathResidualVariance_m2();
            sigma2 = max(sigma2, 1e-12);
        end
        
        function R = measurementCovariance( ...
                obj, measurementTowerIndex, ...
                towerClockEkfEnabled, groundClockResidualVariance_m2, ...
                independentExtraVariance_m2)

            if nargin < 3 || isempty(towerClockEkfEnabled)
                towerClockEkfEnabled = false;
            end

            if nargin < 4 || isempty(groundClockResidualVariance_m2)
                groundClockResidualVariance_m2 = 0.0;
            end
            if nargin < 5
                independentExtraVariance_m2 = [];
            end
            measurementTowerIndex = double(measurementTowerIndex(:));
            n = numel(measurementTowerIndex);
            if isempty(independentExtraVariance_m2)
                independentExtraVariance_m2 = zeros(n, 1);
            else
                independentExtraVariance_m2 = double(independentExtraVariance_m2(:));
            end

            validateattributes(independentExtraVariance_m2, {'numeric'}, ...
                {'real', 'finite', 'nonnegative', 'numel', n}, ...
                mfilename, 'independentExtraVariance_m2');
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

            R = StochasticProcess.whiteNoiseCovariance(independentSigma_m, n) + ...
                MeasurementAlgebra.diagonalCovariance(sqrt(independentExtraVariance_m2));

            if ~towerClockEkfEnabled && groundClockResidualVariance_m2 > 0.0
                R = MeasurementAlgebra.addSameTowerCommonVariance( ...
                    R, measurementTowerIndex, groundClockResidualVariance_m2);
            end

            atmosphereVariance_m2 = obj.atmosphereResidualVariance_m2();

            if atmosphereVariance_m2 > 0.0
                R = MeasurementAlgebra.addSameTowerCommonVariance( ...
                    R, measurementTowerIndex, atmosphereVariance_m2);
            end

            R = MeasurementAlgebra.symmetrize(R);

            validateattributes(R, {'numeric'}, ...
                {'real', 'finite', 'size', [n, n]}, ...
                mfilename, 'R');
        end
        
        function sigma_m = effectiveNumericalMeasurementSigma_m(obj)
            sigma_m = obj.numericalSigmaFloor_m;
        end
        
        function sigma2 = nominalMultipathResidualVariance_m2(obj)
            if obj.useMultipathDelay && obj.useStochasticMultipath
                sigma2 = obj.multipathStochasticSigma0_m^2;
            else
                sigma2 = 0.0;
            end
        end
        
        function sigma2 = atmosphereResidualVariance_m2(obj)
            if isempty(obj.modelAtmosphere)
                sigma2 = 0.0;
                return;
            end

            sigma2 = obj.modelAtmosphere.residualCodeVariance_m2();
        end

    end

    methods (Access = private)
        function terms = emptyNonAtmosphericTermMatrices(obj)
            componentNames = ["total", "hardware", "antenna", ...
                "multipath", "towerSurvey", "legacySagnac"];
            terms = struct();
            for name = componentNames
                terms.(char(name)) = obj.emptyTermMatrixComponent();
            end
        end

        function component = emptyTermMatrixComponent(obj)
            component = struct( ...
                'truth_m', NaN(obj.numReceivers, obj.numTowers), ...
                'model_m', NaN(obj.numReceivers, obj.numTowers), ...
                'residual_m', NaN(obj.numReceivers, obj.numTowers), ...
                'sigma_m', NaN(obj.numReceivers, obj.numTowers), ...
                'variance_m2', NaN(obj.numReceivers, obj.numTowers));
        end

        function terms = emptyNonAtmosphericLinkTerms(obj)
            componentNames = ["total", "hardware", "antenna", ...
                "multipath", "towerSurvey", "legacySagnac"];
            terms = struct();
            for name = componentNames
                terms.(char(name)) = obj.emptyLinkComponent();
            end
        end

        function component = emptyLinkComponent(~)
            component = struct( ...
                'truth_m', 0.0, ...
                'model_m', 0.0, ...
                'residual_m', 0.0, ...
                'sigma_m', 0.0, ...
                'variance_m2', 0.0);
        end

        function component = withTruthModel(~, component, truth_m, model_m)
            component.truth_m = double(truth_m);
            component.model_m = double(model_m);
            component.residual_m = component.truth_m - component.model_m;
        end

        function target = assignLinkTerms(~, target, rx, twr, source)
            componentNames = fieldnames(source);
            for idx = 1:numel(componentNames)
                name = componentNames{idx};
                target.(name).truth_m(rx, twr) = source.(name).truth_m;
                target.(name).model_m(rx, twr) = source.(name).model_m;
                target.(name).residual_m(rx, twr) = source.(name).residual_m;
                target.(name).sigma_m(rx, twr) = source.(name).sigma_m;
                target.(name).variance_m2(rx, twr) = source.(name).variance_m2;
            end
        end

        function propagation = emptyPropagationTermMatrices(obj)
            zeroRt = NaN(obj.numReceivers, obj.numTowers);
            propagation = struct();
            propagation.lightTime = struct( ...
                'truth_m', zeroRt, ...
                'model_m', zeroRt, ...
                'residual_m', zeroRt);
            propagation.relativity = struct( ...
                'pathTruth_m', zeroRt, ...
                'pathModel_m', zeroRt, ...
                'pathResidual_m', zeroRt);
        end

        function geometry = linkGeometry( ...
                obj, jd, towerIndex, towerEci_m, receiverEci_m, ...
                useLightTimeCorrection, enableRelativisticPathDelay)

            delta_I = receiverEci_m - towerEci_m;
            range_m = norm(delta_I);

            geometry = struct();
            geometry.range_m = range_m;
            geometry.los_I = delta_I ./ range_m;
            geometry.lightTimeCorrection_m = obj.lightTimeCorrection_m( ...
                towerIndex, ...
                jd, ...
                receiverEci_m, ...
                range_m, ...
                useLightTimeCorrection);
            geometry.relativisticPathDelay_m = obj.shapiroPathDelay_m( ...
                towerEci_m, ...
                receiverEci_m, ...
                enableRelativisticPathDelay);
        end

        
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
            standardNormal = StochasticProcess.whiteNoiseSample( ...
                1.0, obj.numTowers, obj.atmosphereResidualStream);
        end
        
        function variance_m2 = multipathVariance_m2( ...
                obj, towerIndex, jd, towerEci_m, receiverEci_m)

            [sigma_m, ~] = obj.multipathSigma_m( ...
                towerIndex, jd, towerEci_m, receiverEci_m);

            variance_m2 = sigma_m^2;
        end

        function [sigma_m, elevation_deg] = multipathSigma_m( ...
                obj, towerIndex, jd, towerEci_m, receiverEci_m)

            sigma_m = 0.0;
            elevation_deg = NaN;

            if ~(obj.useMultipathDelay && obj.useStochasticMultipath)
                return;
            end

            [elevation_deg, ~] = obj.towerElevationToReceiverEci( ...
                jd, ...
                towerIndex, ...
                towerEci_m, ...
                receiverEci_m);

            if ~isfinite(elevation_deg)
                elevation_deg = obj.multipathStochasticMinimumElevation_deg;
            end

            elevationUsed_deg = max( ...
                elevation_deg, ...
                obj.multipathStochasticMinimumElevation_deg);

            sigma_m = obj.multipathStochasticSigma0_m ./ ...
                sin(deg2rad(elevationUsed_deg));

            validateattributes(sigma_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'multipathSigma_m');
        end

        function [stochastic_m, sigma_m, elevation_deg] = ...
                stochasticMultipathTruth_m( ...
                obj, towerIndex, receiverIndex, jd, towerEci_m, receiverEci_m)

            [sigma_m, elevation_deg] = obj.multipathSigma_m( ...
                towerIndex, jd, towerEci_m, receiverEci_m);

            if sigma_m <= 0.0
                stochastic_m = 0.0;
                return;
            end

            standardNormal = obj.deterministicMultipathStandardNormal( ...
                jd, towerIndex, receiverIndex);

            stochastic_m = sigma_m * standardNormal;

            validateattributes(stochastic_m, {'numeric'}, ...
                {'real', 'finite', 'scalar'}, ...
                mfilename, 'stochasticMultipathTruth_m');
        end

        function standardNormal = deterministicMultipathStandardNormal( ...
                obj, jd, towerIndex, receiverIndex)

            secondsFromJ2000 = round((double(jd) - 2451545.0) * 86400.0);
            epochBucket = mod(secondsFromJ2000, 1000000);

            hashInput = ...
                double(obj.multipathStochasticRandomSeed) + ...
                78.233 * double(towerIndex) + ...
                37.719 * double(receiverIndex) + ...
                0.0001 * double(epochBucket);

            uniform01 = mod(sin(12.9898 * hashInput) * 43758.5453123, 1.0);
            uniform01 = min(max(uniform01, eps), 1.0 - eps);

            standardNormal = sqrt(2.0) * erfinv(2.0 * uniform01 - 1.0);

            validateattributes(standardNormal, {'numeric'}, ...
                {'real', 'finite', 'scalar'}, ...
                mfilename, 'standardNormalMultipath');
        end
        
        function rangeEffect_m = towerSurveyRangeEffect_m( ...
                ~, jd, towerEci_m, receiverEci_m, offsetEcef_m)

            if nargin < 5 || isempty(offsetEcef_m)
                rangeEffect_m = 0.0;
                return;
            end

            towerEci_m = towerEci_m(:);
            receiverEci_m = receiverEci_m(:);
            offsetEcef_m = double(offsetEcef_m(:));

            validateattributes(towerEci_m, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'towerEci_m');

            validateattributes(receiverEci_m, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'receiverEci_m');

            validateattributes(offsetEcef_m, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'offsetEcef_m');

            if norm(offsetEcef_m) <= 0.0
                rangeEffect_m = 0.0;
                return;
            end

            offsetEci_m = FrameGeometry.ecefToEciDcm(jd) * offsetEcef_m;

            nominalRange_m = norm(receiverEci_m - towerEci_m);
            offsetRange_m = norm(receiverEci_m - (towerEci_m + offsetEci_m));

            rangeEffect_m = offsetRange_m - nominalRange_m;

            validateattributes(rangeEffect_m, {'numeric'}, ...
                {'real', 'finite', 'scalar'}, ...
                mfilename, 'towerSurveyRangeEffect_m');
        end
        
        function correction_m = lightTimeCorrection_m( ...
                obj, towerIndex, jdReceive, receiverEci_m, ...
                staticReceiveEpochRange_m, enabled)

            if nargin < 6 || ~logical(enabled)
                correction_m = 0.0;
                return;
            end

            receiverEci_m = receiverEci_m(:);
            staticReceiveEpochRange_m = double(staticReceiveEpochRange_m);

            validateattributes(receiverEci_m, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'receiverEci_m');

            validateattributes(staticReceiveEpochRange_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'staticReceiveEpochRange_m');

            tau_s = staticReceiveEpochRange_m / obj.c;
            rhoIterated_m = staticReceiveEpochRange_m;
            converged = false;

            maxIterations = double(obj.lightTimeCorrectionMaxIterations);

            for iteration = 1:maxIterations
                jdTransmit = double(jdReceive) - tau_s / 86400.0;
                towerTransmitEci_m = obj.towers{towerIndex}.positionEci(jdTransmit);
                rhoIterated_m = norm(receiverEci_m - towerTransmitEci_m(:));
                tauNew_s = rhoIterated_m / obj.c;

                if abs(tauNew_s - tau_s) <= ...
                        obj.lightTimeCorrectionTolerance_s
                    converged = true;
                    tau_s = tauNew_s;
                    break;
                end

                tau_s = tauNew_s;
            end

            if ~converged
                error('MeasurementModel:LightTimeCorrectionDidNotConverge', ...
                    ['Inertial light-time correction did not converge for ', ...
                     'tower %d after %.0f iterations.'], ...
                    towerIndex, maxIterations);
            end

            correction_m = rhoIterated_m - staticReceiveEpochRange_m;

            validateattributes(correction_m, {'numeric'}, ...
                {'real', 'finite', 'scalar'}, ...
                mfilename, 'lightTimeCorrection_m');
        end        
        
        function delay_m = shapiroPathDelay_m( ...
                obj, transmitterEci_m, receiverEci_m, enabled)

            if nargin < 4 || ~logical(enabled)
                delay_m = 0.0;
                return;
            end

            transmitterEci_m = transmitterEci_m(:);
            receiverEci_m = receiverEci_m(:);

            validateattributes(transmitterEci_m, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'transmitterEci_m');

            validateattributes(receiverEci_m, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'receiverEci_m');

            rTx_m = norm(transmitterEci_m);
            rRx_m = norm(receiverEci_m);
            pathLength_m = norm(receiverEci_m - transmitterEci_m);

            numerator_m = rTx_m + rRx_m + pathLength_m;
            denominator_m = rTx_m + rRx_m - pathLength_m;

            if denominator_m <= 0.0 || numerator_m <= denominator_m
                error('MeasurementModel:InvalidShapiroGeometry', ...
                    ['Invalid geometry for Shapiro path delay. ', ...
                     'rTx + rRx - pathLength must be positive.']);
            end

            delay_m = ...
                (2.0 * obj.muEarth_m3ps2 / obj.c^2) * ...
                log(numerator_m / denominator_m);

            validateattributes(delay_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'shapiroPathDelay_m');
        end        
        
        function validateLightTimeCorrectionConfiguration(obj)
            %VALIDATELIGHTTIMECORRECTIONCONFIGURATION Validate the inertial
            % light-time correction settings and prevent Sagnac double counting.
        
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
        
            if (obj.useLightTimeCorrection || ...
                    obj.useLightTimeCorrectionTruth || ...
                    obj.useLightTimeCorrectionModel) && ...
                    obj.useSagnacCorrection
                error('MeasurementModel:LightTimeCorrectionSagnacConflict', ...
                    ['The inertial light-time correction and the separate ', ...
                     'Sagnac correction cannot be enabled simultaneously. ', ...
                     'The inertial light-time correction represents Earth ', ...
                     'rotation by evaluating the ground transmitter at the ', ...
                     'signal transmission time in ECI.']);
            end

            if obj.enableRelativisticPathDelay || ...
                    obj.enableRelativisticPathDelayTruth || ...
                    obj.enableRelativisticPathDelayModel
                error('MeasurementModel:RelativisticPathDelayNotImplemented', ...
                    ['Relativistic path delay is explicit but not enabled in this ', ...
                     'cleanup branch. Keep enableRelativisticPathDelay, ', ...
                     'enableRelativisticPathDelayTruth, and ', ...
                     'enableRelativisticPathDelayModel disabled until the physical ', ...
                     'model is accepted and tested in a dedicated physics branch.']);
            end
            if obj.enableRelativisticClockCorrection || ...
                    obj.enableRelativisticClockCorrectionTruth || ...
                    obj.enableRelativisticClockCorrectionModel
                error('MeasurementModel:RelativisticClockCorrectionNotImplemented', ...
                    ['Relativistic clock correction is explicit but not yet ', ...
                     'implemented. Keep enableRelativisticClockCorrectionTruth ', ...
                     'and enableRelativisticClockCorrectionModel disabled until ', ...
                     'the affected physical clock dynamics are modelled.']);
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
