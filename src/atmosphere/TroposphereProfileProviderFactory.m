classdef TroposphereProfileProviderFactory
    %TROPOSPHEREPROFILEPROVIDERFACTORY Construct troposphere providers.
    %
    % Architecture commit only:
    % - "none" returns NullTroposphereProfileProvider.
    % - "profile" returns NullTroposphereProfileProvider until the
    %   deterministic in-memory profile provider is implemented.
    % - "era5" returns NullTroposphereProfileProvider until ERA5 parsing is
    %   implemented.

    methods (Static)
        function provider = create(providerType, dataRoot, cfg, role)
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

            providerType = lower(strtrim(string(providerType)));

            switch providerType
                case "none"
                    provider = NullTroposphereProfileProvider( ...
                        "none", dataRoot, cfg, role);

                case "profile"
                    provider = NullTroposphereProfileProvider( ...
                        "profile", dataRoot, cfg, role);

                case "era5"
                    provider = NullTroposphereProfileProvider( ...
                        "era5", dataRoot, cfg, role);

                otherwise
                    error('TroposphereProfileProviderFactory:UnknownProviderType', ...
                        'Unsupported troposphere provider type "%s".', ...
                        providerType);
            end
        end
    end
end