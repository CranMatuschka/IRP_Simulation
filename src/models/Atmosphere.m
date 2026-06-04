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

        enableTroposphere logical = false
        enableIonosphere logical = false

        troposphereModel string = "disabled"
        ionosphereModel string = "disabled"

        constantTroposphereDelay_m double = 0.0
        constantIonosphereDelay_m double = 0.0
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

            delay.troposphere_m = obj.troposphereDelayMeters(elevation_deg);
            delay.ionosphere_m = obj.ionosphereDelayMeters( ...
                elevation_deg, frequency_Hz);

            delay.total_m = delay.troposphere_m + delay.ionosphere_m;
            delay.valid = true;
        end

        function tf = isEnabled(obj)
            tf = obj.enableTroposphere || obj.enableIonosphere;
        end
    end

    methods (Access = private)
        function delay_m = troposphereDelayMeters(obj, elevation_deg)
            %#ok<INUSD>

            switch obj.troposphereModel
                case "disabled"
                    delay_m = 0.0;

                case "constant"
                    delay_m = obj.constantTroposphereDelay_m;

                otherwise
                    error('Atmosphere:TroposphereModelNotImplemented', ...
                        'Troposphere model "%s" is configured but not implemented yet.', ...
                        obj.troposphereModel);
            end
        end

        function delay_m = ionosphereDelayMeters(obj, elevation_deg, frequency_Hz)
            %#ok<INUSD>

            switch obj.ionosphereModel
                case "disabled"
                    delay_m = 0.0;

                case "constant"
                    delay_m = obj.constantIonosphereDelay_m;

                otherwise
                    error('Atmosphere:IonosphereModelNotImplemented', ...
                        'Ionosphere model "%s" is configured but not implemented yet.', ...
                        obj.ionosphereModel);
            end
        end

        function delay = emptyDelayResult( ...
                obj, groundNode, elevation_deg, azimuth_deg, ...
                jd, datetimeUtc, frequency_Hz)

            metadata = struct( ...
                'role', obj.role, ...
                'groundNodeName', string(groundNode.name), ...
                'groundAltitude_m', double(groundNode.alt_m), ...
                'troposphereModel', obj.troposphereModel, ...
                'ionosphereModel', obj.ionosphereModel, ...
                'frequency_Hz', double(frequency_Hz), ...
                'jd', double(jd), ...
                'datetimeUtc', datetimeUtc, ...
                'dataRoot', obj.dataRoot);

            delay = struct( ...
                'total_m', 0.0, ...
                'troposphere_m', 0.0, ...
                'ionosphere_m', 0.0, ...
                'elevation_deg', elevation_deg, ...
                'azimuth_deg', azimuth_deg, ...
                'valid', false, ...
                'metadata', metadata);
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

            validateattributes(obj.constantTroposphereDelay_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'constantTroposphereDelay_m');

            validateattributes(obj.constantIonosphereDelay_m, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'constantIonosphereDelay_m');

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