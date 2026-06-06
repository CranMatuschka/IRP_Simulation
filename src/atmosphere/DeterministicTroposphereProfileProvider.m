classdef DeterministicTroposphereProfileProvider < TroposphereProfileProvider
    %DETERMINISTICTROPOSPHEREPROFILEPROVIDER In-memory meteorology provider.
    %
    % This provider is file-format independent. ERA5 parsing can later
    % produce the same in-memory profile representation.
    %
    % Expected profile configuration fields:
    %   datetimeUtc                 [Nt x 1] datetime vector
    %   pressure_hPa                [Nt x 1] or scalar
    %   temperature_K               [Nt x 1] or scalar
    %   relativeHumidity_fraction   [Nt x 1] or scalar
    %
    % Optional:
    %   waterVaporPressure_hPa      [Nt x 1] or scalar
    %   source                      string
    %
    % The provider returns interpolated meteorology. Atmosphere still owns
    % the conversion from meteorology to neutral-atmosphere slant delay.

    properties (SetAccess = private)
        epochUtc = []
        pressure_hPa double = []
        temperature_K double = []
        relativeHumidity_fraction double = []
        waterVaporPressure_hPa double = []
        hasWaterVaporPressure logical = false
        source string = "in-memory troposphere profile"
    end

    methods
        function obj = DeterministicTroposphereProfileProvider( ...
                dataRoot, cfg, role)

            if nargin < 1
                dataRoot = "";
            end

            if nargin < 2
                cfg = struct();
            end

            if nargin < 3
                role = "model";
            end

            obj@TroposphereProfileProvider("profile", dataRoot, cfg, role);

            profileCfg = ...
                DeterministicTroposphereProfileProvider.profileConfigFromProviderConfig(cfg);

            obj.epochUtc = ...
                DeterministicTroposphereProfileProvider.requiredField( ...
                profileCfg, ...
                ["datetimeUtc", "timeUtc", "epochsUtc"], ...
                'datetimeUtc');

            if ~isdatetime(obj.epochUtc)
                error('DeterministicTroposphereProfileProvider:InvalidEpochs', ...
                    'Troposphere profile datetimeUtc must be a datetime vector.');
            end

            obj.epochUtc = obj.epochUtc(:);

            if isempty(obj.epochUtc)
                error('DeterministicTroposphereProfileProvider:EmptyEpochs', ...
                    'Troposphere profile must contain at least one epoch.');
            end

            [obj.epochUtc, timeOrder] = sort(obj.epochUtc(:));
            nTime = numel(obj.epochUtc);

            obj.pressure_hPa = ...
                DeterministicTroposphereProfileProvider.normalizeSeries( ...
                DeterministicTroposphereProfileProvider.requiredField( ...
                    profileCfg, ...
                    ["pressure_hPa", "surfacePressure_hPa"], ...
                    'pressure_hPa'), ...
                nTime, ...
                timeOrder, ...
                'pressure_hPa');

            obj.temperature_K = ...
                DeterministicTroposphereProfileProvider.normalizeSeries( ...
                DeterministicTroposphereProfileProvider.requiredField( ...
                    profileCfg, ...
                    ["temperature_K", "surfaceTemperature_K"], ...
                    'temperature_K'), ...
                nTime, ...
                timeOrder, ...
                'temperature_K');

            relativeHumidityRaw = ...
                DeterministicTroposphereProfileProvider.optionalField( ...
                profileCfg, ...
                ["relativeHumidity_fraction", "relativeHumidity", "rh_fraction"]);

            waterVaporRaw = ...
                DeterministicTroposphereProfileProvider.optionalField( ...
                profileCfg, ...
                ["waterVaporPressure_hPa", "vaporPressure_hPa"]);

            if isempty(relativeHumidityRaw) && isempty(waterVaporRaw)
                error('DeterministicTroposphereProfileProvider:MissingHumidity', ...
                    ['Troposphere profile requires relativeHumidity_fraction ', ...
                     'or waterVaporPressure_hPa.']);
            end

            if isempty(relativeHumidityRaw)
                obj.relativeHumidity_fraction = NaN(nTime, 1);
            else
                obj.relativeHumidity_fraction = ...
                    DeterministicTroposphereProfileProvider.normalizeSeries( ...
                    relativeHumidityRaw, ...
                    nTime, ...
                    timeOrder, ...
                    'relativeHumidity_fraction');
            end

            if isempty(waterVaporRaw)
                obj.waterVaporPressure_hPa = NaN(nTime, 1);
                obj.hasWaterVaporPressure = false;
            else
                obj.waterVaporPressure_hPa = ...
                    DeterministicTroposphereProfileProvider.normalizeSeries( ...
                    waterVaporRaw, ...
                    nTime, ...
                    timeOrder, ...
                    'waterVaporPressure_hPa');

                obj.hasWaterVaporPressure = true;
            end

            if isfield(profileCfg, 'source') && ~isempty(profileCfg.source)
                obj.source = string(profileCfg.source);
            end

            obj.validateProfile();
        end

        function tf = isAvailable(obj)
            tf = ~isempty(obj.epochUtc) && ...
                ~isempty(obj.pressure_hPa) && ...
                ~isempty(obj.temperature_K);
        end

        function result = profileAt( ...
                obj, datetimeUtc, latitude_deg, longitude_deg, height_m)

            result = obj.emptyResult( ...
                datetimeUtc, latitude_deg, longitude_deg, height_m);

            result.providerType = "profile";
            result.source = obj.source;

            if ~obj.isAvailable()
                result.message = "Deterministic troposphere profile is empty.";
                return;
            end

            if ~isdatetime(datetimeUtc) || ~isscalar(datetimeUtc)
                error('DeterministicTroposphereProfileProvider:InvalidDatetime', ...
                    'datetimeUtc must be a scalar datetime.');
            end

            epochSeconds = seconds(obj.epochUtc - obj.epochUtc(1));
            querySeconds = seconds(datetimeUtc - obj.epochUtc(1));

            [iTime0, iTime1, wTime, okTime] = ...
                DeterministicTroposphereProfileProvider.bracketIndex( ...
                epochSeconds, querySeconds);

            if ~okTime
                result.message = ...
                    "Requested time is outside the troposphere profile coverage.";
                return;
            end

            pressure_hPa = ...
                DeterministicTroposphereProfileProvider.interpolateSeries( ...
                obj.pressure_hPa, iTime0, iTime1, wTime);

            temperature_K = ...
                DeterministicTroposphereProfileProvider.interpolateSeries( ...
                obj.temperature_K, iTime0, iTime1, wTime);

            relativeHumidity_fraction = ...
                DeterministicTroposphereProfileProvider.interpolateSeries( ...
                obj.relativeHumidity_fraction, iTime0, iTime1, wTime);

            if obj.hasWaterVaporPressure
                waterVaporPressure_hPa = ...
                    DeterministicTroposphereProfileProvider.interpolateSeries( ...
                    obj.waterVaporPressure_hPa, iTime0, iTime1, wTime);
            else
                waterVaporPressure_hPa = ...
                    DeterministicTroposphereProfileProvider.waterVaporPressureFromRh( ...
                    temperature_K, relativeHumidity_fraction);
            end

            if ~isfinite(pressure_hPa) || ...
                    ~isfinite(temperature_K) || ...
                    ~isfinite(waterVaporPressure_hPa)
                result.message = ...
                    "Interpolated troposphere profile contains non-finite data.";
                return;
            end

            result.valid = true;
            result.message = "";

            result.pressure_hPa = double(pressure_hPa);
            result.temperature_K = double(temperature_K);
            result.relativeHumidity_fraction = double(relativeHumidity_fraction);
            result.waterVaporPressure_hPa = double(waterVaporPressure_hPa);

            result.metadata.timeIndex0 = iTime0;
            result.metadata.timeIndex1 = iTime1;
            result.metadata.timeWeight = wTime;
        end
    end

    methods (Access = private)
        function validateProfile(obj)
            validateattributes(obj.pressure_hPa, {'numeric'}, ...
                {'real', 'finite', 'vector', 'nonempty', 'positive'}, ...
                mfilename, 'pressure_hPa');

            validateattributes(obj.temperature_K, {'numeric'}, ...
                {'real', 'finite', 'vector', 'nonempty', '>', 150.0}, ...
                mfilename, 'temperature_K');

            if all(isfinite(obj.relativeHumidity_fraction))
                validateattributes(obj.relativeHumidity_fraction, {'numeric'}, ...
                    {'real', 'finite', 'vector', '>=', 0.0, '<=', 1.0}, ...
                    mfilename, 'relativeHumidity_fraction');
            end

            if obj.hasWaterVaporPressure
                validateattributes(obj.waterVaporPressure_hPa, {'numeric'}, ...
                    {'real', 'finite', 'vector', 'nonnegative'}, ...
                    mfilename, 'waterVaporPressure_hPa');
            end
        end
    end

    methods (Static, Access = private)
        function profileCfg = profileConfigFromProviderConfig(cfg)
            if isstruct(cfg) && isfield(cfg, 'troposphereProfile')
                profileCfg = cfg.troposphereProfile;
            elseif isstruct(cfg) && isfield(cfg, 'profile')
                profileCfg = cfg.profile;
            else
                profileCfg = cfg;
            end
        end

        function value = requiredField(s, candidateNames, displayName)
            for k = 1:numel(candidateNames)
                name = char(candidateNames(k));

                if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
                    value = s.(name);
                    return;
                end
            end

            error('DeterministicTroposphereProfileProvider:MissingField', ...
                'Missing required troposphere profile field "%s".', ...
                displayName);
        end

        function value = optionalField(s, candidateNames)
            value = [];

            for k = 1:numel(candidateNames)
                name = char(candidateNames(k));

                if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
                    value = s.(name);
                    return;
                end
            end
        end

        function series = normalizeSeries(rawValue, nTime, timeOrder, fieldName)
            series = double(rawValue(:));

            if isscalar(series)
                series = repmat(series, nTime, 1);
            end

            if numel(series) ~= nTime
                error('DeterministicTroposphereProfileProvider:InvalidSeriesLength', ...
                    '%s must be scalar or have one value per epoch.', ...
                    fieldName);
            end

            series = series(timeOrder);
        end

        function value = interpolateSeries(series, i0, i1, weight)
            value = (1.0 - weight) * series(i0) + weight * series(i1);
        end

        function waterVaporPressure_hPa = waterVaporPressureFromRh( ...
                temperature_K, relativeHumidity_fraction)

            temperature_C = double(temperature_K) - 273.15;

            saturationVaporPressure_hPa = ...
                6.1121 * exp( ...
                (18.678 - temperature_C / 234.5) * ...
                (temperature_C / (257.14 + temperature_C)));

            waterVaporPressure_hPa = ...
                double(relativeHumidity_fraction) * saturationVaporPressure_hPa;
        end

        function [i0, i1, weight, ok] = bracketIndex(gridValues, queryValue)
            gridValues = double(gridValues(:));
            queryValue = double(queryValue);

            ok = true;
            weight = 0.0;

            if isempty(gridValues) || ~isfinite(queryValue)
                i0 = 1;
                i1 = 1;
                ok = false;
                return;
            end

            if numel(gridValues) == 1
                i0 = 1;
                i1 = 1;
                weight = 0.0;
                return;
            end

            if queryValue < gridValues(1) || queryValue > gridValues(end)
                i0 = 1;
                i1 = 1;
                ok = false;
                return;
            end

            if queryValue == gridValues(end)
                i0 = numel(gridValues);
                i1 = numel(gridValues);
                weight = 0.0;
                return;
            end

            i1 = find(gridValues >= queryValue, 1, 'first');

            if isempty(i1)
                i0 = 1;
                i1 = 1;
                ok = false;
                return;
            end

            if gridValues(i1) == queryValue
                i0 = i1;
                weight = 0.0;
                return;
            end

            i0 = max(i1 - 1, 1);
            denominator = gridValues(i1) - gridValues(i0);

            if denominator <= 0.0
                ok = false;
                weight = 0.0;
                return;
            end

            weight = (queryValue - gridValues(i0)) / denominator;
        end
    end
end