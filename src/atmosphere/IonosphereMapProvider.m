classdef (Abstract) IonosphereMapProvider < handle
    %IONOSPHEREMAPPROVIDER Interface for gridded ionosphere map providers.
    %
    % Providers return vertical TEC at a requested UTC time and geodetic
    % ionospheric pierce-point location. Atmosphere owns the conversion from
    % VTEC/STEC to code delay in metres.

    properties (SetAccess = protected)
        providerType string = "abstract"
        dataRoot string = ""
        cfg struct = struct()
        role string = "model"
    end

    methods
        function obj = IonosphereMapProvider(providerType, dataRoot, cfg, role)
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
                obj, datetimeUtc, latitude_deg, longitude_deg)

            result = struct();

            result.valid = false;
            result.vtec_TECU = NaN;
            result.rms_TECU = NaN;

            result.datetimeUtc = datetimeUtc;
            result.latitude_deg = double(latitude_deg);
            result.longitude_deg = double(longitude_deg);

            result.providerType = obj.providerType;
            result.dataRoot = obj.dataRoot;
            result.role = obj.role;

            result.source = "";
            result.message = "";
            result.metadata = struct();
        end
    end

    methods (Abstract)
        result = verticalTecAt( ...
            obj, datetimeUtc, latitude_deg, longitude_deg)
    end
end