classdef NullIonosphereMapProvider < IonosphereMapProvider
    %NULLIONOSPHEREMAPPROVIDER Placeholder provider for disabled/no-data cases.
    %
    % This class intentionally returns invalid data. It allows Atmosphere to
    % own a provider object without making IONEX operational yet.

    methods
        function obj = NullIonosphereMapProvider(providerType, dataRoot, cfg, role)
            if nargin < 1 || isempty(providerType)
                providerType = "none";
            end

            if nargin < 2
                dataRoot = "";
            end

            if nargin < 3
                cfg = struct();
            end

            if nargin < 4
                role = "model";
            end

            obj@IonosphereMapProvider(providerType, dataRoot, cfg, role);
        end

        function tf = isAvailable(~)
            tf = false;
        end

        function result = verticalTecAt( ...
                obj, datetimeUtc, latitude_deg, longitude_deg)

            result = obj.emptyResult( ...
                datetimeUtc, latitude_deg, longitude_deg);

            result.message = ...
                "No ionosphere map provider is configured or implemented.";
        end
    end
end