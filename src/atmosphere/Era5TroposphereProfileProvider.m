classdef Era5TroposphereProfileProvider < TroposphereProfileProvider
    %ERA5TROPOSPHEREPROFILEPROVIDER ERA5 NetCDF surface-met provider.
    %
    % This provider reads ERA5-like NetCDF surface meteorology and returns
    % local pressure, temperature, relative humidity, and water vapour
    % pressure at a requested UTC time and ground location.
    %
    % Supported coordinate variables:
    %   latitude / lat
    %   longitude / lon
    %   time / valid_time
    %
    % Supported meteorological variables:
    %   sp / surface_pressure / surfacePressure_Pa / pressure_Pa
    %       Surface pressure. ERA5 native unit is Pa.
    %
    %   t2m / temperature_K / temperature / air_temperature
    %       2 m temperature in K.
    %
    % Humidity source, one of:
    %   d2m / dewpoint_temperature / dewpoint_K
    %       2 m dewpoint temperature in K.
    %
    %   relative_humidity / relativeHumidity_fraction / rh / r
    %       Relative humidity as fraction or percent.
    %
    %   waterVaporPressure_hPa / water_vapor_pressure_hPa / e
    %       Water vapour pressure in hPa or Pa.
    %
    % Relative paths are resolved against dataRoot.

    properties (SetAccess = private)
        era5File string = ""
        source string = ""

        epochUtc = []
        latitude_deg double = []
        longitude_deg double = []

        surfacePressure = []
        temperature_K = []

        dewpoint_K = []
        relativeHumidity_fraction = []
        waterVaporPressure = []

        hasDewpoint logical = false
        hasRelativeHumidity logical = false
        hasWaterVaporPressure logical = false
    end

    methods
        function obj = Era5TroposphereProfileProvider(dataRoot, cfg, role)
            if nargin < 1
                dataRoot = "";
            end

            if nargin < 2
                cfg = struct();
            end

            if nargin < 3
                role = "model";
            end

            obj@TroposphereProfileProvider("era5", dataRoot, cfg, role);

            obj.era5File = ...
                Era5TroposphereProfileProvider.resolveEra5Path( ...
                dataRoot, cfg);

            obj.source = obj.era5File;

            obj.loadNetcdfData();
        end

        function tf = isAvailable(obj)
            tf = ~isempty(obj.epochUtc) && ...
                ~isempty(obj.latitude_deg) && ...
                ~isempty(obj.longitude_deg) && ...
                ~isempty(obj.surfacePressure) && ...
                ~isempty(obj.temperature_K) && ...
                (obj.hasDewpoint || ...
                 obj.hasRelativeHumidity || ...
                 obj.hasWaterVaporPressure);
        end

        function result = profileAt( ...
                obj, datetimeUtc, latitude_deg, longitude_deg, height_m)

            result = obj.emptyResult( ...
                datetimeUtc, latitude_deg, longitude_deg, height_m);

            result.providerType = "era5";
            result.source = obj.source;
            result.metadata.era5File = obj.era5File;

            if ~obj.isAvailable()
                result.message = ...
                    "ERA5 provider has no loaded meteorological data.";
                return;
            end

            if ~isdatetime(datetimeUtc) || ~isscalar(datetimeUtc)
                error('Era5TroposphereProfileProvider:InvalidDatetime', ...
                    'datetimeUtc must be a scalar datetime.');
            end

            queryLon_deg = obj.normalizedQueryLongitude(longitude_deg);

            [iLat0, iLat1, wLat, okLat] = ...
                Era5TroposphereProfileProvider.bracketIndex( ...
                obj.latitude_deg, latitude_deg);

            [iLon0, iLon1, wLon, okLon] = ...
                Era5TroposphereProfileProvider.bracketIndex( ...
                obj.longitude_deg, queryLon_deg);

            epochSeconds = seconds(obj.epochUtc - obj.epochUtc(1));
            querySeconds = seconds(datetimeUtc - obj.epochUtc(1));

            [iTime0, iTime1, wTime, okTime] = ...
                Era5TroposphereProfileProvider.bracketIndex( ...
                epochSeconds, querySeconds);

            if ~okLat || ~okLon || ~okTime
                result.message = ...
                    "Requested time/location is outside ERA5 coverage.";
                return;
            end

            pressureRaw = obj.interpolateLatLonTime( ...
                obj.surfacePressure, ...
                iLat0, iLat1, wLat, ...
                iLon0, iLon1, wLon, ...
                iTime0, iTime1, wTime);

            temperature_K_value = obj.interpolateLatLonTime( ...
                obj.temperature_K, ...
                iLat0, iLat1, wLat, ...
                iLon0, iLon1, wLon, ...
                iTime0, iTime1, wTime);

            pressure_hPa = ...
                Era5TroposphereProfileProvider.pressureToHpa(pressureRaw);

            if obj.hasWaterVaporPressure
                waterVaporRaw = obj.interpolateLatLonTime( ...
                    obj.waterVaporPressure, ...
                    iLat0, iLat1, wLat, ...
                    iLon0, iLon1, wLon, ...
                    iTime0, iTime1, wTime);

                waterVaporPressure_hPa = ...
                    Era5TroposphereProfileProvider.pressureToHpa(waterVaporRaw);

                relativeHumidity_fraction = ...
                    waterVaporPressure_hPa / ...
                    Era5TroposphereProfileProvider.saturationVaporPressureHpa( ...
                    temperature_K_value);

            elseif obj.hasDewpoint
                dewpoint_K_value = obj.interpolateLatLonTime( ...
                    obj.dewpoint_K, ...
                    iLat0, iLat1, wLat, ...
                    iLon0, iLon1, wLon, ...
                    iTime0, iTime1, wTime);

                waterVaporPressure_hPa = ...
                    Era5TroposphereProfileProvider.saturationVaporPressureHpa( ...
                    dewpoint_K_value);

                relativeHumidity_fraction = ...
                    waterVaporPressure_hPa / ...
                    Era5TroposphereProfileProvider.saturationVaporPressureHpa( ...
                    temperature_K_value);

            else
                relativeHumidityRaw = obj.interpolateLatLonTime( ...
                    obj.relativeHumidity_fraction, ...
                    iLat0, iLat1, wLat, ...
                    iLon0, iLon1, wLon, ...
                    iTime0, iTime1, wTime);

                relativeHumidity_fraction = ...
                    Era5TroposphereProfileProvider.normalizeRelativeHumidity( ...
                    relativeHumidityRaw);

                waterVaporPressure_hPa = ...
                    relativeHumidity_fraction * ...
                    Era5TroposphereProfileProvider.saturationVaporPressureHpa( ...
                    temperature_K_value);
            end

            validateattributes(pressure_hPa, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'positive'}, ...
                mfilename, 'era5Pressure_hPa');

            validateattributes(temperature_K_value, {'numeric'}, ...
                {'real', 'finite', 'scalar', '>', 150.0}, ...
                mfilename, 'era5Temperature_K');

            validateattributes(relativeHumidity_fraction, {'numeric'}, ...
                {'real', 'finite', 'scalar', '>=', 0.0}, ...
                mfilename, 'era5RelativeHumidity_fraction');

            validateattributes(waterVaporPressure_hPa, {'numeric'}, ...
                {'real', 'finite', 'scalar', 'nonnegative'}, ...
                mfilename, 'era5WaterVaporPressure_hPa');

            result.valid = true;
            result.message = "";

            result.pressure_hPa = double(pressure_hPa);
            result.temperature_K = double(temperature_K_value);
            result.relativeHumidity_fraction = ...
                double(relativeHumidity_fraction);
            result.waterVaporPressure_hPa = ...
                double(waterVaporPressure_hPa);

            result.metadata.latitudeIndex0 = iLat0;
            result.metadata.latitudeIndex1 = iLat1;
            result.metadata.latitudeWeight = wLat;

            result.metadata.longitudeIndex0 = iLon0;
            result.metadata.longitudeIndex1 = iLon1;
            result.metadata.longitudeWeight = wLon;

            result.metadata.timeIndex0 = iTime0;
            result.metadata.timeIndex1 = iTime1;
            result.metadata.timeWeight = wTime;
        end
    end

    methods (Static)
        function tf = hasEra5Source(cfg)
            tf = strlength( ...
                Era5TroposphereProfileProvider.getEra5PathFromCfg(cfg)) > 0;
        end
    end

    methods (Access = private)
        function loadNetcdfData(obj)
            ncInfo = ncinfo(char(obj.era5File));

            latitudeRaw = Era5TroposphereProfileProvider.readCoordinate( ...
                obj.era5File, ncInfo, ["latitude", "lat"], 'latitude');

            longitudeRaw = Era5TroposphereProfileProvider.readCoordinate( ...
                obj.era5File, ncInfo, ["longitude", "lon"], 'longitude');

            obj.epochUtc = Era5TroposphereProfileProvider.readTime( ...
                obj.era5File, ncInfo);

            obj.surfacePressure = ...
                Era5TroposphereProfileProvider.readLatLonTimeVariable( ...
                obj.era5File, ncInfo, ...
                ["sp", "surface_pressure", ...
                 "surfacePressure_Pa", "pressure_Pa"], ...
                'surface pressure');

            obj.temperature_K = ...
                Era5TroposphereProfileProvider.readLatLonTimeVariable( ...
                obj.era5File, ncInfo, ...
                ["t2m", "temperature_K", ...
                 "temperature", "air_temperature"], ...
                'temperature');

            dewpointName = ...
                Era5TroposphereProfileProvider.firstExistingVariable( ...
                ncInfo, ...
                ["d2m", "dewpoint_temperature", "dewpoint_K"]);

            relativeHumidityName = ...
                Era5TroposphereProfileProvider.firstExistingVariable( ...
                ncInfo, ...
                ["relative_humidity", ...
                 "relativeHumidity_fraction", "rh", "r"]);

            waterVaporName = ...
                Era5TroposphereProfileProvider.firstExistingVariable( ...
                ncInfo, ...
                ["waterVaporPressure_hPa", ...
                 "water_vapor_pressure_hPa", "e"]);

            if strlength(dewpointName) > 0
                obj.dewpoint_K = ...
                    Era5TroposphereProfileProvider.readLatLonTimeVariable( ...
                    obj.era5File, ncInfo, dewpointName, 'dewpoint');

                obj.hasDewpoint = true;

            elseif strlength(relativeHumidityName) > 0
                obj.relativeHumidity_fraction = ...
                    Era5TroposphereProfileProvider.readLatLonTimeVariable( ...
                    obj.era5File, ncInfo, ...
                    relativeHumidityName, ...
                    'relative humidity');

                obj.hasRelativeHumidity = true;

            elseif strlength(waterVaporName) > 0
                obj.waterVaporPressure = ...
                    Era5TroposphereProfileProvider.readLatLonTimeVariable( ...
                    obj.era5File, ncInfo, ...
                    waterVaporName, ...
                    'water vapour pressure');

                obj.hasWaterVaporPressure = true;

            else
                error('Era5TroposphereProfileProvider:MissingHumidityVariable', ...
                    ['ERA5 file must contain dewpoint, relative humidity, ', ...
                     'or water vapour pressure.']);
            end

            [obj.latitude_deg, latOrder] = sort(double(latitudeRaw(:)));
            [obj.longitude_deg, lonOrder] = sort(double(longitudeRaw(:)));
            [obj.epochUtc, timeOrder] = sort(obj.epochUtc(:));

            obj.surfacePressure = ...
                obj.surfacePressure(latOrder, lonOrder, timeOrder);

            obj.temperature_K = ...
                obj.temperature_K(latOrder, lonOrder, timeOrder);

            if obj.hasDewpoint
                obj.dewpoint_K = ...
                    obj.dewpoint_K(latOrder, lonOrder, timeOrder);
            end

            if obj.hasRelativeHumidity
                obj.relativeHumidity_fraction = ...
                    obj.relativeHumidity_fraction(latOrder, lonOrder, timeOrder);
            end

            if obj.hasWaterVaporPressure
                obj.waterVaporPressure = ...
                    obj.waterVaporPressure(latOrder, lonOrder, timeOrder);
            end
        end

        function queryLon_deg = normalizedQueryLongitude(obj, longitude_deg)
            queryLon_deg = double(longitude_deg);

            if isempty(obj.longitude_deg)
                return;
            end

            if min(obj.longitude_deg) >= 0.0 && queryLon_deg < 0.0
                queryLon_deg = mod(queryLon_deg, 360.0);
            elseif max(obj.longitude_deg) <= 180.0 && queryLon_deg > 180.0
                queryLon_deg = mod(queryLon_deg + 180.0, 360.0) - 180.0;
            end
        end

        function value = interpolateLatLonTime( ...
                ~, field, iLat0, iLat1, wLat, ...
                iLon0, iLon1, wLon, ...
                iTime0, iTime1, wTime)

            v000 = field(iLat0, iLon0, iTime0);
            v100 = field(iLat1, iLon0, iTime0);
            v010 = field(iLat0, iLon1, iTime0);
            v110 = field(iLat1, iLon1, iTime0);

            v001 = field(iLat0, iLon0, iTime1);
            v101 = field(iLat1, iLon0, iTime1);
            v011 = field(iLat0, iLon1, iTime1);
            v111 = field(iLat1, iLon1, iTime1);

            v00 = (1.0 - wLat) * v000 + wLat * v100;
            v10 = (1.0 - wLat) * v010 + wLat * v110;
            v01 = (1.0 - wLat) * v001 + wLat * v101;
            v11 = (1.0 - wLat) * v011 + wLat * v111;

            v0 = (1.0 - wLon) * v00 + wLon * v10;
            v1 = (1.0 - wLon) * v01 + wLon * v11;

            value = (1.0 - wTime) * v0 + wTime * v1;
        end
    end

    methods (Static, Access = private)
        function era5FilePath = resolveEra5Path(dataRoot, cfg)
            era5FilePath = ...
                Era5TroposphereProfileProvider.getEra5PathFromCfg(cfg);

            if strlength(era5FilePath) == 0
                error('Era5TroposphereProfileProvider:MissingEra5File', ...
                    ['ERA5 provider requires one of: era5File, ', ...
                     'era5FilePath, era5Filename, or era5.file.']);
            end

            era5FilePath = string(era5FilePath);

            if ~Era5TroposphereProfileProvider.isAbsolutePath(era5FilePath)
                era5FilePath = fullfile(string(dataRoot), era5FilePath);
            end

            if ~isfile(char(era5FilePath))
                error('Era5TroposphereProfileProvider:Era5FileNotFound', ...
                    'ERA5 file not found: %s', era5FilePath);
            end
        end

        function pathValue = getEra5PathFromCfg(cfg)
            pathValue = "";

            if ~isstruct(cfg)
                return;
            end

            candidateFields = ["era5File", "era5FilePath", "era5Filename"];

            for k = 1:numel(candidateFields)
                name = char(candidateFields(k));

                if isfield(cfg, name) && ~isempty(cfg.(name))
                    pathValue = string(cfg.(name));
                    return;
                end
            end

            if isfield(cfg, 'era5') && isstruct(cfg.era5)
                if isfield(cfg.era5, 'file') && ~isempty(cfg.era5.file)
                    pathValue = string(cfg.era5.file);
                    return;
                end

                for k = 1:numel(candidateFields)
                    name = char(candidateFields(k));

                    if isfield(cfg.era5, name) && ~isempty(cfg.era5.(name))
                        pathValue = string(cfg.era5.(name));
                        return;
                    end
                end
            elseif isfield(cfg, 'era5') && ~isempty(cfg.era5)
                pathValue = string(cfg.era5);
            end
        end

        function tf = isAbsolutePath(pathValue)
            pathText = char(string(pathValue));

            tf = startsWith(pathText, filesep) || ...
                ~isempty(regexp(pathText, '^[A-Za-z]:[\\/]', 'once'));
        end

        function values = readCoordinate(filePath, ncInfo, candidates, displayName)
            varName = Era5TroposphereProfileProvider.firstExistingVariable( ...
                ncInfo, candidates);

            if strlength(varName) == 0
                error('Era5TroposphereProfileProvider:MissingCoordinate', ...
                    'ERA5 file is missing coordinate variable "%s".', ...
                    displayName);
            end

            values = double(ncread(char(filePath), char(varName)));
            values = values(:);
        end

        function epochUtc = readTime(filePath, ncInfo)
            timeName = Era5TroposphereProfileProvider.firstExistingVariable( ...
                ncInfo, ["time", "valid_time"]);

            if strlength(timeName) == 0
                error('Era5TroposphereProfileProvider:MissingTime', ...
                    'ERA5 file is missing time or valid_time coordinate.');
            end

            timeValues = double(ncread(char(filePath), char(timeName)));

            units = "";

            try
                units = string(ncreadatt( ...
                    char(filePath), char(timeName), 'units'));
            catch
                try
                    units = string(ncreadatt( ...
                        char(filePath), char(timeName), 'Units'));
                catch
                    units = "";
                end
            end

            epochUtc = Era5TroposphereProfileProvider.datetimeFromUnits( ...
                timeValues(:), units);
        end

        function data = readLatLonTimeVariable( ...
                filePath, ncInfo, candidates, displayName)

            varName = Era5TroposphereProfileProvider.firstExistingVariable( ...
                ncInfo, candidates);

            if strlength(varName) == 0
                error('Era5TroposphereProfileProvider:MissingVariable', ...
                    'ERA5 file is missing required variable "%s".', ...
                    displayName);
            end

            varInfo = Era5TroposphereProfileProvider.variableInfo( ...
                ncInfo, varName);

            dimNames = string({varInfo.Dimensions.Name});
            dimLower = lower(dimNames);
            dimLengths = double([varInfo.Dimensions.Length]);

            if numel(dimNames) ~= 3
                error('Era5TroposphereProfileProvider:InvalidVariableRank', ...
                    'Variable "%s" must have exactly three NetCDF dimensions.', ...
                    char(varName));
            end

            iLat = find(contains(dimLower, "lat"), 1, 'first');
            iLon = find(contains(dimLower, "lon"), 1, 'first');
            iTime = find(contains(dimLower, "time"), 1, 'first');

            if isempty(iLat) || isempty(iLon) || isempty(iTime)
                error('Era5TroposphereProfileProvider:InvalidVariableDimensions', ...
                    ['Variable "%s" must have latitude, longitude, ', ...
                     'and time dimensions.'], char(varName));
            end

            raw = double(ncread(char(filePath), char(varName)));

            if numel(raw) ~= prod(dimLengths)
                error('Era5TroposphereProfileProvider:InvalidVariableSize', ...
                    ['Variable "%s" data size does not match its declared ', ...
                     'NetCDF dimension lengths.'], char(varName));
            end

            raw = reshape(raw, dimLengths);

            data = permute(raw, [iLat, iLon, iTime]);

            expectedSize = dimLengths([iLat, iLon, iTime]);

            data = reshape(data, expectedSize);

            if size(data, 1) ~= expectedSize(1) || ...
                    size(data, 2) ~= expectedSize(2) || ...
                    size(data, 3) ~= expectedSize(3)
                error('Era5TroposphereProfileProvider:InvalidVariableShape', ...
                    ['Variable "%s" could not be reshaped to ', ...
                     'latitude-longitude-time order.'], char(varName));
            end
        end

        function varName = firstExistingVariable(ncInfo, candidates)
            varName = "";

            if ischar(candidates) || isstring(candidates)
                candidates = string(candidates);
            else
                candidates = string(candidates);
            end

            available = string({ncInfo.Variables.Name});
            availableLower = lower(available);

            for k = 1:numel(candidates)
                candidate = string(candidates(k));
                idx = find(availableLower == lower(candidate), 1, 'first');

                if ~isempty(idx)
                    varName = available(idx);
                    return;
                end
            end
        end

        function info = variableInfo(ncInfo, varName)
            available = string({ncInfo.Variables.Name});
            idx = find(available == string(varName), 1, 'first');

            if isempty(idx)
                error('Era5TroposphereProfileProvider:InternalVariableLookupFailed', ...
                    'Could not find variable "%s".', char(string(varName)));
            end

            info = ncInfo.Variables(idx);
        end

        function epochUtc = datetimeFromUnits(timeValues, units)
            units = strtrim(string(units));

            if strlength(units) == 0
                error('Era5TroposphereProfileProvider:MissingTimeUnits', ...
                    'ERA5 time coordinate must define units.');
            end

            tokens = regexp( ...
                char(lower(units)), ...
                '^(seconds|second|secs|sec|minutes|minute|mins|min|hours|hour|hrs|hr|days|day)\s+since\s+(.+)$', ...
                'tokens', ...
                'once');

            if isempty(tokens)
                error('Era5TroposphereProfileProvider:UnsupportedTimeUnits', ...
                    'Unsupported ERA5 time units: %s', units);
            end

            unitName = string(tokens{1});
            baseText = strtrim(string(tokens{2}));
            baseText = regexprep(baseText, 'z$', '');
            baseText = regexprep(baseText, '\s+utc$', '');

            baseTime = Era5TroposphereProfileProvider.parseBaseTime(baseText);

            switch unitName
                case {"seconds", "second", "secs", "sec"}
                    epochUtc = baseTime + seconds(timeValues);

                case {"minutes", "minute", "mins", "min"}
                    epochUtc = baseTime + minutes(timeValues);

                case {"hours", "hour", "hrs", "hr"}
                    epochUtc = baseTime + hours(timeValues);

                case {"days", "day"}
                    epochUtc = baseTime + days(timeValues);

                otherwise
                    error('Era5TroposphereProfileProvider:UnsupportedTimeUnits', ...
                        'Unsupported ERA5 time unit "%s".', unitName);
            end

            epochUtc.TimeZone = 'UTC';
            epochUtc = epochUtc(:);
        end

        function baseTime = parseBaseTime(baseText)
            baseText = string(baseText);

            inputFormats = [ ...
                "yyyy-MM-dd HH:mm:ss"; ...
                "yyyy-MM-dd HH:mm"; ...
                "yyyy-MM-dd'T'HH:mm:ss"; ...
                "yyyy-MM-dd'T'HH:mm"; ...
                "yyyy-MM-dd" ...
                ];

            for k = 1:numel(inputFormats)
                try
                    baseTime = datetime( ...
                        baseText, ...
                        'InputFormat', char(inputFormats(k)), ...
                        'TimeZone', 'UTC');
                    return;
                catch
                end
            end

            baseTime = datetime(baseText, 'TimeZone', 'UTC');
        end

        function pressure_hPa = pressureToHpa(pressureValue)
            pressure_hPa = double(pressureValue);

            if pressure_hPa > 2000.0
                pressure_hPa = pressure_hPa / 100.0;
            end
        end

        function relativeHumidity_fraction = normalizeRelativeHumidity( ...
                relativeHumidityValue)

            relativeHumidity_fraction = double(relativeHumidityValue);

            if relativeHumidity_fraction > 1.5
                relativeHumidity_fraction = relativeHumidity_fraction / 100.0;
            end
        end

        function saturation_hPa = saturationVaporPressureHpa(temperature_K)
            temperature_C = double(temperature_K) - 273.15;

            saturation_hPa = ...
                6.1121 * exp( ...
                (18.678 - temperature_C / 234.5) * ...
                (temperature_C / (257.14 + temperature_C)));
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