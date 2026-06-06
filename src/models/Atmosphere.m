classdef Atmosphere < handle
    %ATMOSPHERE Code-pseudorange atmospheric propagation-delay model.
    %
    % The public interface returns delays in metres because the Reverse-GNSS
    % measurement model forms code pseudoranges in metres.
    %
    % Atmosphere contains propagation physics only. External atmospheric-data
    % downloading, parsing, and caching will be implemented by separate data
    % provider classes.

    properties (SetAccess = private)
        role string = "truth"
        cfg struct = struct()

        dataRoot string = ""

        c double = 299792458.0
        earthRadius_m double = 6378137.0
        ionosphereShellHeight_m double = 350000.0

        missingDataPolicy string = "error"
        ionosphereProviderType string = "none"
        ionosphereProvider = []

        enableTroposphere logical = false
        enableIonosphere logical = false

        troposphereModel string = "disabled"
        ionosphereModel string = "disabled"

        constantTroposphereDelay_m double = 0.0
        constantIonosphereDelay_m double = 0.0

        % Deterministic troposphere inputs.
        surfacePressure_hPa double = 1013.25
        surfaceTemperature_K double = 293.15
        relativeHumidity_fraction double = 0.50
        minimumMappingElevation_deg double = 3.0

        % Deterministic ionosphere input.
        vtec_TECU double = 10.0
        % Residual code-delay uncertainty.
        % For the truth role these values control simulated tower-common
        % residual noise. For the model role they control measurement
        % covariance R. They do not change the deterministic delay.
        residualTroposphereSigma_m double = 0.0
        residualIonosphereSigma_m double = 0.0
    end

    methods
        function obj = Atmosphere(atmosphereCfg, constants, role)
            %ATMOSPHERE Construct a truth or estimator atmosphere model.
            %
            % atmosphereCfg is expected to contain:
            %   atmosphereCfg.truth
            %   atmosphereCfg.model
            %   atmosphereCfg.dataRoot
            %   atmosphereCfg.missingDataPolicy
            %
            % Example:
            %   truthAtmosphere = Atmosphere(cfg.atmosphere, constants, "truth");
            %   modelAtmosphere = Atmosphere(cfg.atmosphere, constants, "model");

            if nargin < 1 || isempty(atmosphereCfg)
                atmosphereCfg = struct();
            end

            if nargin < 2 || isempty(constants)
                constants = struct();
            end

            if nargin < 3 || isempty(role)
                role = "truth";
            end

            obj.role = obj.normalizeChoice( ...
                role, ["truth", "model"], 'role');

            if isstruct(atmosphereCfg) && isfield(atmosphereCfg, char(obj.role))
                obj.cfg = atmosphereCfg.(char(obj.role));
            else
                obj.cfg = atmosphereCfg;
            end

            obj.c = obj.getScalarField( ...
                constants, 'speedOfLight_mps', 299792458.0);

            obj.earthRadius_m = obj.getScalarField( ...
                constants, 'earthRadius_m', 6378137.0);

            obj.ionosphereShellHeight_m = obj.getScalarField( ...
                atmosphereCfg, 'ionosphereShellHeight_m', 350000.0);

            obj.missingDataPolicy = obj.normalizeChoice( ...
                obj.getFieldOrDefault(atmosphereCfg, 'missingDataPolicy', "error"), ...
                ["error", "invalid"], ...
                'missingDataPolicy');

            configuredDataRoot = string(obj.getFieldOrDefault( ...
                atmosphereCfg, 'dataRoot', fullfile("data", "atmosphere")));

            if strlength(configuredDataRoot) == 0
                configuredDataRoot = fullfile("data", "atmosphere");
            end

            obj.dataRoot = obj.resolveProjectPath(configuredDataRoot);
            obj.ionosphereProviderType = obj.normalizeChoice( ...
                obj.getFieldOrDefault( ...
                    obj.cfg, ...
                    'ionosphereProviderType', ...
                    obj.getFieldOrDefault(obj.cfg, 'ionosphereProvider', "none")), ...
                ["none", "grid", "ionex"], ...
                'ionosphereProviderType');

            obj.ionosphereProvider = IonosphereMapProviderFactory.create( ...
                obj.ionosphereProviderType, ...
                obj.dataRoot, ...
                obj.cfg, ...
                obj.role);

            obj.enableTroposphere = logical(obj.getFieldOrDefault( ...
                obj.cfg, 'enableTroposphere', false));

            obj.enableIonosphere = logical(obj.getFieldOrDefault( ...
                obj.cfg, 'enableIonosphere', false));

            defaultTroposphereModel = "disabled";
            if obj.enableTroposphere
                defaultTroposphereModel = "constant";
            end

            defaultIonosphereModel = "disabled";
            if obj.enableIonosphere
                defaultIonosphereModel = "constant";
            end

            obj.troposphereModel = obj.normalizeChoice( ...
                obj.getFieldOrDefault( ...
                    obj.cfg, 'troposphereModel', defaultTroposphereModel), ...
                ["disabled", "constant", "saastamoinen", "era5profile"], ...
                'troposphereModel');

            obj.ionosphereModel = obj.normalizeChoice( ...
                obj.getFieldOrDefault( ...
                    obj.cfg, 'ionosphereModel', defaultIonosphereModel), ...
                ["disabled", "constant", "thinshellvtec", "ionex"], ...
                'ionosphereModel');

            if ~obj.enableTroposphere
                obj.troposphereModel = "disabled";
            end

            if ~obj.enableIonosphere
                obj.ionosphereModel = "disabled";
            end

            obj.constantTroposphereDelay_m = obj.getScalarField( ...
                obj.cfg, 'constantTroposphereDelay_m', 0.0);

            obj.constantIonosphereDelay_m = obj.getScalarField( ...
                obj.cfg, 'constantIonosphereDelay_m', 0.0);

            obj.surfacePressure_hPa = obj.getScalarField( ...
                obj.cfg, 'surfacePressure_hPa', 1013.25);

            obj.surfaceTemperature_K = obj.getScalarField( ...
                obj.cfg, 'surfaceTemperature_K', 293.15);

            obj.relativeHumidity_fraction = obj.getScalarField( ...
                obj.cfg, 'relativeHumidity_fraction', 0.50);

            obj.minimumMappingElevation_deg = obj.getScalarField( ...
                obj.cfg, 'minimumMappingElevation_deg', 3.0);

            obj.vtec_TECU = obj.getScalarField( ...
                obj.cfg, 'vtec_TECU', 10.0);

            obj.residualTroposphereSigma_m = obj.getScalarField( ...
                obj.cfg, 'residualTroposphereSigma_m', 0.0);

            obj.residualIonosphereSigma_m = obj.getScalarField( ...
                obj.cfg, 'residualIonosphereSigma_m', 0.0);
            
            obj.validateConfiguration();
        end

        function delay = codeDelayMeters( ...
                obj, groundNode, receiverEci_m, jd, datetimeUtc, frequency_Hz)
            %CODEDELAYMETERS Return code-pseudorange atmosphere delay in metres.
            %
            % Inputs:
            %   groundNode     GroundNode transmitter object
            %   receiverEci_m  Receiver phase-centre position in ECI, metres
            %   jd             Julian date associated with receiverEci_m
            %   datetimeUtc    UTC datetime associated with the measurement
            %   frequency_Hz   Signal carrier frequency in hertz
            %
            % Output fields:
            %   total_m
            %   troposphere_m
            %   ionosphere_m
            %   elevation_deg
            %   azimuth_deg
            %   valid
            %   metadata

            if ~isa(groundNode, 'GroundNode')
                error('Atmosphere:InvalidGroundNode', ...
                    'groundNode must be a GroundNode object.');
            end

            validateattributes(receiverEci_m, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'receiverEci_m');

            validateattributes(jd, {'numeric'}, ...
                {'real', 'finite', 'scalar'}, ...
                mfilename, 'jd');

            if ~isdatetime(datetimeUtc) || ~isscalar(datetimeUtc)
                error('Atmosphere:InvalidDatetime', ...
                    'datetimeUtc must be a scalar datetime value.');
            end

            validateattributes(frequency_Hz, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'frequency_Hz');

            receiverEci_m = receiverEci_m(:);
            towerEci_m = groundNode.positionEci(jd);

            [elevation_deg, azimuth_deg] = ...
                FrameGeometry.elevationAzimuthFromGround( ...
                    groundNode.lat_deg, ...
                    groundNode.lon_deg, ...
                    towerEci_m, ...
                    receiverEci_m, ...
                    jd);

            delay = obj.emptyDelayResult( ...
                groundNode, elevation_deg, azimuth_deg, ...
                jd, datetimeUtc, frequency_Hz);

            if ~isfinite(elevation_deg) || elevation_deg < 0.0
                delay.total_m = NaN;
                delay.troposphere_m = NaN;
                delay.ionosphere_m = NaN;
                delay.valid = false;
                return;
            end

            delay.metadata.ionospherePiercePoint = ...
                IonospherePiercePointGeometry.fromEciLineOfSight( ...
                towerEci_m, ...
                receiverEci_m, ...
                jd, ...
                obj.earthRadius_m, ...
                obj.ionosphereShellHeight_m, ...
                elevation_deg);

            delay.troposphere_m = obj.troposphereDelayMeters( ...
                groundNode, elevation_deg);

            [delay.ionosphere_m, delay.metadata.ionosphereMap] = ...
                obj.ionosphereDelayMeters( ...
                delay.metadata.ionospherePiercePoint, ...
                datetimeUtc, ...
                elevation_deg, ...
                frequency_Hz);

            delay.total_m = delay.troposphere_m + delay.ionosphere_m;

            if ~isfinite(delay.total_m) || ...
                    ~isfinite(delay.troposphere_m) || ...
                    ~isfinite(delay.ionosphere_m)
                delay.total_m = NaN;
                delay.valid = false;
                return;
            end

            delay.valid = true;
        end

        function [delay, gradientReceiverEci] = codeDelayAndGradientMeters( ...
                obj, groundNode, receiverEci_m, jd, datetimeUtc, frequency_Hz)
            %CODEDELAYANDGRADIENTMETERS Return code delay and receiver gradient.
            %
            % gradientReceiverEci is d(delay)/d(receiverEci_m), expressed as
            % a 3x1 ECI gradient in metres per metre.
            %
            % The currently implemented deterministic models depend on
            % receiver position only through ground-station elevation.

            delay = obj.codeDelayMeters( ...
                groundNode, receiverEci_m, jd, datetimeUtc, frequency_Hz);

            gradientReceiverEci = zeros(3, 1);

            if ~delay.valid
                gradientReceiverEci(:) = NaN;
                return;
            end

            if ~obj.isEnabled()
                return;
            end

            if obj.ionosphereModel == "ionex"
                gradientReceiverEci = obj.numericalDelayGradientReceiverEci( ...
                    groundNode, ...
                    receiverEci_m, ...
                    jd, ...
                    datetimeUtc, ...
                    frequency_Hz);
                return;
            end

            receiverEci_m = receiverEci_m(:);
            towerEci_m = groundNode.positionEci(jd);

            d = receiverEci_m - towerEci_m;
            rho = norm(d);

            if rho <= eps
                gradientReceiverEci(:) = NaN;
                return;
            end

            u = d ./ rho;

            R_enu_ecef = FrameGeometry.ecefToEnuDcm( ...
                groundNode.lat_deg, groundNode.lon_deg);

            upEcef = R_enu_ecef(3, :).';
            upEci = FrameGeometry.ecefToEciDcm(jd) * upEcef;

            sinElevation = max(0.0, min(1.0, dot(upEci, u)));

            gradientSinElevation = ...
                (eye(3) - u * u.') * upEci / rho;

            dDelay_dSinElevation = ...
                obj.troposphereDelayDerivativePerSinElevation( ...
                    groundNode, delay.elevation_deg, sinElevation) ...
                + obj.ionosphereDelayDerivativePerSinElevation( ...
                    delay.elevation_deg, sinElevation, frequency_Hz);

            gradientReceiverEci = ...
                dDelay_dSinElevation * gradientSinElevation;

            validateattributes(gradientReceiverEci, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'gradientReceiverEci');

            gradientReceiverEci = gradientReceiverEci(:);
        end        
        
        function tf = isEnabled(obj)
            tf = obj.enableTroposphere || obj.enableIonosphere;
        end
        
        function sigma_m = residualCodeSigma_m(obj)
            %RESIDUALCODESIGMA_M Return one-sigma residual code-delay error.
            %
            % Disabled atmospheric components contribute zero uncertainty.

            troposphereSigma_m = 0.0;
            ionosphereSigma_m = 0.0;

            if obj.enableTroposphere
                troposphereSigma_m = obj.residualTroposphereSigma_m;
            end

            if obj.enableIonosphere
                ionosphereSigma_m = obj.residualIonosphereSigma_m;
            end

            sigma_m = hypot(troposphereSigma_m, ionosphereSigma_m);
        end

        function variance_m2 = residualCodeVariance_m2(obj)
            sigma_m = obj.residualCodeSigma_m();
            variance_m2 = sigma_m^2;
        end

        function mappingFactor = ionosphereMappingFactorForTest(obj, elevation_deg)
            %IONOSPHEREMAPPINGFACTORFORTEST Diagnostic wrapper for regression tests.
            mappingFactor = obj.ionosphereMappingFactor(elevation_deg);
        end
    
    end

    methods (Access = private)
        function gradientReceiverEci = numericalDelayGradientReceiverEci( ...
                obj, groundNode, receiverEci_m, jd, datetimeUtc, frequency_Hz)

            receiverEci_m = receiverEci_m(:);
            step_m = 10.0;

            gradientReceiverEci = NaN(3, 1);

            for axisIndex = 1:3
                delta = zeros(3, 1);
                delta(axisIndex) = step_m;

                delayPlus = obj.codeDelayMeters( ...
                    groundNode, ...
                    receiverEci_m + delta, ...
                    jd, ...
                    datetimeUtc, ...
                    frequency_Hz);

                delayMinus = obj.codeDelayMeters( ...
                    groundNode, ...
                    receiverEci_m - delta, ...
                    jd, ...
                    datetimeUtc, ...
                    frequency_Hz);

                if ~delayPlus.valid || ~delayMinus.valid
                    return;
                end

                gradientReceiverEci(axisIndex) = ...
                    (delayPlus.total_m - delayMinus.total_m) / ...
                    (2.0 * step_m);
            end

            validateattributes(gradientReceiverEci, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'gradientReceiverEci');

            gradientReceiverEci = gradientReceiverEci(:);
        end
        
        function delay_m = troposphereDelayMeters(obj, groundNode, elevation_deg)
            switch obj.troposphereModel
                case "disabled"
                    delay_m = 0.0;

                case "constant"
                    delay_m = obj.constantTroposphereDelay_m;

                case "saastamoinen"
                    delay_m = obj.saastamoinenDelayMeters( ...
                        groundNode, elevation_deg);

                case "era5profile"
                    error('Atmosphere:TroposphereModelNotImplemented', ...
                        ['Troposphere model "era5profile" requires an ', ...
                         'ERA5 data provider and is not implemented yet.']);

                otherwise
                    error('Atmosphere:UnknownTroposphereModel', ...
                        'Unsupported troposphere model "%s".', ...
                        obj.troposphereModel);
            end
        end

        function derivative = troposphereDelayDerivativePerSinElevation( ...
                obj, groundNode, elevation_deg, sinElevation)

            switch obj.troposphereModel
                case "disabled"
                    derivative = 0.0;

                case "constant"
                    derivative = 0.0;

                case "saastamoinen"
                    % The mapping function is clamped below the configured
                    % minimum elevation, so its derivative is zero there.
                    if double(elevation_deg) <= obj.minimumMappingElevation_deg
                        derivative = 0.0;
                        return;
                    end

                    slantDelay_m = obj.saastamoinenDelayMeters( ...
                        groundNode, elevation_deg);

                    s = max(double(sinElevation), eps);

                    % T = Z / sin(E), therefore dT/dsin(E) = -T / sin(E).
                    derivative = -slantDelay_m / s;

                case "era5profile"
                    error('Atmosphere:TroposphereGradientNotImplemented', ...
                        ['Troposphere model "era5profile" requires an ', ...
                         'ERA5 data provider and gradient implementation.']);

                otherwise
                    error('Atmosphere:UnknownTroposphereModel', ...
                        'Unsupported troposphere model "%s".', ...
                        obj.troposphereModel);
            end
        end        
        
        function [delay_m, mapResult] = ionosphereDelayMeters( ...
                obj, piercePoint, datetimeUtc, elevation_deg, frequency_Hz)

            mapResult = obj.emptyIonosphereMapResult( ...
                datetimeUtc, NaN, NaN);

            switch obj.ionosphereModel
                case "disabled"
                    delay_m = 0.0;
                    mapResult.message = "Ionosphere model is disabled.";

                case "constant"
                    delay_m = obj.constantIonosphereDelay_m;
                    mapResult.message = "Constant ionosphere delay model.";

                case "thinshellvtec"
                    delay_m = obj.thinShellVtecDelayMeters( ...
                        elevation_deg, frequency_Hz);
                    mapResult.message = "Scalar thin-shell VTEC model.";

                case "ionex"
                    [delay_m, mapResult] = obj.ionexDelayMeters( ...
                        piercePoint, datetimeUtc, frequency_Hz);

                otherwise
                    error('Atmosphere:UnknownIonosphereModel', ...
                        'Unsupported ionosphere model "%s".', ...
                        obj.ionosphereModel);
            end
        end

        function [delay_m, mapResult] = ionexDelayMeters( ...
                obj, piercePoint, datetimeUtc, frequency_Hz)

            mapResult = obj.emptyIonosphereMapResult( ...
                datetimeUtc, NaN, NaN);

            if isempty(obj.ionosphereProvider) || ...
                    ~obj.ionosphereProvider.isAvailable()
                delay_m = obj.handleMissingIonosphereData( ...
                    'IONEX ionosphere provider is not available.');
                mapResult.message = ...
                    "IONEX ionosphere provider is not available.";
                return;
            end

            if ~isstruct(piercePoint) || ...
                    ~isfield(piercePoint, 'valid') || ...
                    ~piercePoint.valid
                delay_m = obj.handleMissingIonosphereData( ...
                    'Ionosphere pierce point is invalid.');
                mapResult.message = "Ionosphere pierce point is invalid.";
                return;
            end

            mapResult = obj.ionosphereProvider.verticalTecAt( ...
                datetimeUtc, ...
                piercePoint.latitude_deg, ...
                piercePoint.longitude_deg);

            if ~isfield(mapResult, 'valid') || ~mapResult.valid
                delay_m = obj.handleMissingIonosphereData( ...
                    'IONEX VTEC is unavailable at the requested pierce point.');
                return;
            end

            vtec_TECU = double(mapResult.vtec_TECU);

            validateattributes(vtec_TECU, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'ionexVtec_TECU');

            mappingFactor = double(piercePoint.mappingFactor);

            validateattributes(mappingFactor, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'ionexMappingFactor');

            slantTec_electrons_per_m2 = ...
                vtec_TECU * 1.0e16 * mappingFactor;

            delay_m = ...
                40.3 * slantTec_electrons_per_m2 / frequency_Hz^2;

            mapResult.metadata.mappingFactor = mappingFactor;
            mapResult.metadata.slantTec_TECU = vtec_TECU * mappingFactor;
            mapResult.metadata.delay_m = delay_m;
        end
        
        function delay_m = handleMissingIonosphereData(obj, messageText)
            if obj.missingDataPolicy == "error"
                error('Atmosphere:MissingIonosphereMapData', '%s', messageText);
            end

            delay_m = NaN;
        end
        
        function mapResult = emptyIonosphereMapResult( ...
                obj, datetimeUtc, latitude_deg, longitude_deg)

            mapResult = struct();

            mapResult.valid = false;
            mapResult.vtec_TECU = NaN;
            mapResult.rms_TECU = NaN;

            mapResult.datetimeUtc = datetimeUtc;
            mapResult.latitude_deg = double(latitude_deg);
            mapResult.longitude_deg = double(longitude_deg);

            mapResult.providerType = obj.ionosphereProviderType;
            mapResult.dataRoot = obj.dataRoot;
            mapResult.role = obj.role;

            mapResult.source = "";
            mapResult.message = "";
            mapResult.metadata = struct();
        end
        
        function derivative = ionosphereDelayDerivativePerSinElevation( ...
                obj, elevation_deg, sinElevation, frequency_Hz)

            switch obj.ionosphereModel
                case "disabled"
                    derivative = 0.0;

                case "constant"
                    derivative = 0.0;

                case "thinshellvtec"
                    slantDelay_m = obj.thinShellVtecDelayMeters( ...
                        elevation_deg, frequency_Hz);

                    shellRatio = ...
                        obj.earthRadius_m / ...
                        (obj.earthRadius_m + obj.ionosphereShellHeight_m);

                    q = shellRatio^2;
                    s = double(sinElevation);

                    denominatorTerm = max( ...
                        1.0 - q + q * s^2, ...
                        eps);

                    % I = K / sqrt(1 - q + q sin(E)^2)
                    derivative = ...
                        -slantDelay_m * q * s / denominatorTerm;

                case "ionex"
                    error('Atmosphere:IonosphereGradientNotImplemented', ...
                        ['Ionosphere model "ionex" requires an IONEX data ', ...
                         'provider and gradient implementation.']);

                otherwise
                    error('Atmosphere:UnknownIonosphereModel', ...
                        'Unsupported ionosphere model "%s".', ...
                        obj.ionosphereModel);
            end
        end
        
        function delay_m = saastamoinenDelayMeters( ...
                obj, groundNode, elevation_deg)

            latitude_rad = deg2rad(double(groundNode.lat_deg));
            height_km = double(groundNode.alt_m) / 1000.0;

            pressure_hPa = obj.surfacePressure_hPa;
            temperature_K = obj.surfaceTemperature_K;

            waterVaporPressure_hPa = obj.waterVaporPressure_hPa( ...
                temperature_K, obj.relativeHumidity_fraction);

            heightCorrection = ...
                1.0 ...
                - 0.00266 * cos(2.0 * latitude_rad) ...
                - 0.00028 * height_km;

            if heightCorrection <= 0.0
                error('Atmosphere:InvalidSaastamoinenHeightCorrection', ...
                    'Saastamoinen height correction must be positive.');
            end

            zenithHydrostaticDelay_m = ...
                0.0022768 * pressure_hPa / heightCorrection;

            zenithWetDelay_m = ...
                0.002277 * ...
                (1255.0 / temperature_K + 0.05) * ...
                waterVaporPressure_hPa;

            mappingFactor = obj.troposphereMappingFactor(elevation_deg);

            delay_m = ...
                (zenithHydrostaticDelay_m + zenithWetDelay_m) * ...
                mappingFactor;
        end

        function delay_m = thinShellVtecDelayMeters( ...
                obj, elevation_deg, frequency_Hz)

            mappingFactor = obj.ionosphereMappingFactor(elevation_deg);

            slantTec_electrons_per_m2 = ...
                obj.vtec_TECU * 1e16 * mappingFactor;

            delay_m = ...
                40.3 * slantTec_electrons_per_m2 / frequency_Hz^2;
        end

        function mappingFactor = troposphereMappingFactor( ...
                obj, elevation_deg)

            effectiveElevation_deg = max( ...
                double(elevation_deg), ...
                obj.minimumMappingElevation_deg);

            mappingFactor = 1.0 / sind(effectiveElevation_deg);
        end

        function mappingFactor = ionosphereMappingFactor(obj, elevation_deg)
            mappingFactor = ...
                IonospherePiercePointGeometry.mappingFactorFromElevation( ...
                elevation_deg, ...
                obj.earthRadius_m, ...
                obj.ionosphereShellHeight_m);
        end

        function vaporPressure_hPa = waterVaporPressure_hPa( ...
                ~, temperature_K, relativeHumidity_fraction)

            temperature_C = temperature_K - 273.15;

            saturationVaporPressure_hPa = ...
                6.1121 * exp( ...
                (18.678 - temperature_C / 234.5) * ...
                (temperature_C / (257.14 + temperature_C)));

            vaporPressure_hPa = ...
                relativeHumidity_fraction * saturationVaporPressure_hPa;
        end

        function delay = emptyDelayResult( ...
                obj, groundNode, elevation_deg, azimuth_deg, ...
                jd, datetimeUtc, frequency_Hz)

            metadata = struct();

            metadata.role = obj.role;
            metadata.groundNodeName = string(groundNode.name);
            metadata.groundAltitude_m = double(groundNode.alt_m);

            metadata.troposphereModel = obj.troposphereModel;
            metadata.ionosphereModel = obj.ionosphereModel;
            metadata.ionosphereProviderType = obj.ionosphereProviderType;

            metadata.frequency_Hz = double(frequency_Hz);
            metadata.jd = double(jd);
            metadata.datetimeUtc = datetimeUtc;
            metadata.dataRoot = obj.dataRoot;

            metadata.surfacePressure_hPa = obj.surfacePressure_hPa;
            metadata.surfaceTemperature_K = obj.surfaceTemperature_K;
            metadata.relativeHumidity_fraction = obj.relativeHumidity_fraction;
            metadata.minimumMappingElevation_deg = obj.minimumMappingElevation_deg;
            metadata.vtec_TECU = obj.vtec_TECU;
            metadata.ionospherePiercePoint = struct( ...
                'valid', false, ...
                'message', "not evaluated", ...
                'latitude_deg', NaN, ...
                'longitude_deg', NaN, ...
                'radius_m', NaN, ...
                'height_m', NaN, ...
                'slantRangeToPiercePoint_m', NaN, ...
                'receiverRange_m', NaN, ...
                'elevation_deg', NaN, ...
                'mappingFactor', NaN, ...
                'earthCentralAngle_rad', NaN, ...
                'ecef_m', NaN(3, 1), ...
                'shellRadius_m', obj.earthRadius_m + obj.ionosphereShellHeight_m, ...
                'earthRadius_m', obj.earthRadius_m, ...
                'shellHeight_m', obj.ionosphereShellHeight_m);

            metadata.ionosphereMap = obj.emptyIonosphereMapResult( ...
                datetimeUtc, NaN, NaN);
            delay = struct();

            delay.total_m = 0.0;
            delay.troposphere_m = 0.0;
            delay.ionosphere_m = 0.0;

            delay.elevation_deg = double(elevation_deg);
            delay.azimuth_deg = double(azimuth_deg);

            delay.valid = false;
            delay.metadata = metadata;
        end

        function validateConfiguration(obj)
            validateattributes(obj.c, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'c');

            validateattributes(obj.earthRadius_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'earthRadius_m');

            validateattributes(obj.ionosphereShellHeight_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'ionosphereShellHeight_m');

            if isempty(obj.ionosphereProvider) || ...
                    ~isa(obj.ionosphereProvider, 'IonosphereMapProvider')
                error('Atmosphere:InvalidIonosphereProvider', ...
                    ['ionosphereProvider must implement ', ...
                     'IonosphereMapProvider.']);
            end

            validateattributes(obj.constantTroposphereDelay_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'constantTroposphereDelay_m');

            validateattributes(obj.constantIonosphereDelay_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'constantIonosphereDelay_m');

            validateattributes(obj.surfacePressure_hPa, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'surfacePressure_hPa');

            validateattributes(obj.surfaceTemperature_K, {'numeric'}, ...
                {'real', 'finite', 'scalar', '>', 150.0}, ...
                mfilename, 'surfaceTemperature_K');

            validateattributes(obj.relativeHumidity_fraction, {'numeric'}, ...
                {'real', 'finite', 'scalar', '>=', 0.0, '<=', 1.0}, ...
                mfilename, 'relativeHumidity_fraction');

            validateattributes(obj.minimumMappingElevation_deg, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive', '<=', 90.0}, ...
                mfilename, 'minimumMappingElevation_deg');

            validateattributes(obj.vtec_TECU, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'vtec_TECU');
            
            validateattributes(obj.residualTroposphereSigma_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'residualTroposphereSigma_m');

            validateattributes(obj.residualIonosphereSigma_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'residualIonosphereSigma_m');
            
            if obj.enableTroposphere && obj.troposphereModel == "disabled"
                error('Atmosphere:InvalidTroposphereConfiguration', ...
                    ['enableTroposphere=true requires a troposphereModel other ', ...
                     'than "disabled".']);
            end

            if obj.enableIonosphere && obj.ionosphereModel == "disabled"
                error('Atmosphere:InvalidIonosphereConfiguration', ...
                    ['enableIonosphere=true requires an ionosphereModel other ', ...
                     'than "disabled".']);
            end
        end

        function value = normalizeChoice(~, rawValue, allowedValues, fieldName)
            value = lower(strtrim(string(rawValue)));
            allowedValues = lower(string(allowedValues));

            if ~isscalar(value) || ~any(value == allowedValues)
                error('Atmosphere:InvalidConfigurationChoice', ...
                    '%s must be one of: %s.', ...
                    fieldName, strjoin(allowedValues, ', '));
            end
        end

        function pathOut = resolveProjectPath(~, pathIn)
            pathIn = string(pathIn);
            pathChar = char(pathIn);

            if ispc
                isAbsolute = ~isempty(regexp( ...
                    pathChar, '^[A-Za-z]:[\\/]|^\\\\', 'once'));
            else
                isAbsolute = startsWith(pathChar, filesep);
            end

            if isAbsolute
                pathOut = string(pathChar);
            else
                pathOut = string(fullfile( ...
                    char(ProjectPathManager.projectRoot()), pathChar));
            end
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