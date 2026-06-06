classdef (Abstract) TroposphereProfileProvider < handle
    %TROPOSPHEREPROFILEPROVIDER Interface for neutral-atmosphere providers.
    %
    % Providers return local meteorological/profile information at a UTC
    % time and geodetic ground location. Atmosphere owns the conversion from
    % meteorology/profile data to zenith and slant code delay in metres.

    properties (SetAccess = protected)
        providerType string = "abstract"
        dataRoot string = ""
        cfg struct = struct()
        role string = "model"
    end

    methods
        function obj = TroposphereProfileProvider( ...
                providerType, dataRoot, cfg, role)

            if nargin >= 1 && ~isempty(providerType)
                obj.providerType = string(providerType);
            end

            if nargin >= 2 && ~isempty(dataRoot)
                obj.dataRoot = string(dataRoot);
            end

            if nargin >= 3 && ~isempty(cfg)
                obj.cfg = cfg;
            end

            if nargin >= 4 && ~isempty(role)
                obj.role = string(role);
            end
        end

        function tf = isAvailable(~)
            tf = false;
        end

        function result = emptyResult( ...
                obj, datetimeUtc, latitude_deg, longitude_deg, height_m)

            result = struct();

            result.valid = false;

            result.datetimeUtc = datetimeUtc;
            result.latitude_deg = double(latitude_deg);
            result.longitude_deg = double(longitude_deg);
            result.height_m = double(height_m);

            result.pressure_hPa = NaN;
            result.temperature_K = NaN;
            result.relativeHumidity_fraction = NaN;
            result.waterVaporPressure_hPa = NaN;

            result.zenithHydrostaticDelay_m = NaN;
            result.zenithWetDelay_m = NaN;

            result.providerType = obj.providerType;
            result.dataRoot = obj.dataRoot;
            result.role = obj.role;

            result.source = "";
            result.message = "";
            result.metadata = struct();
        end
    end

    methods (Abstract)
        result = profileAt( ...
            obj, datetimeUtc, latitude_deg, longitude_deg, height_m)
    end
end