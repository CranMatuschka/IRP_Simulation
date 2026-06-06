classdef NullTroposphereProfileProvider < TroposphereProfileProvider
    %NULLTROPOSPHEREPROFILEPROVIDER Placeholder provider for no-data cases.
    %
    % This class intentionally returns invalid profile data. It lets
    % Atmosphere own a troposphere provider object without making profile or
    % ERA5 troposphere operational yet.

    methods
        function obj = NullTroposphereProfileProvider( ...
                providerType, dataRoot, cfg, role)

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

            obj@TroposphereProfileProvider( ...
                providerType, dataRoot, cfg, role);
        end

        function tf = isAvailable(~)
            tf = false;
        end

        function result = profileAt( ...
                obj, datetimeUtc, latitude_deg, longitude_deg, height_m)

            result = obj.emptyResult( ...
                datetimeUtc, latitude_deg, longitude_deg, height_m);

            result.message = ...
                "No troposphere profile provider is configured or implemented.";
        end
    end
end