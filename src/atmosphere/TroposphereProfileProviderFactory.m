classdef TroposphereProfileProviderFactory
    %TROPOSPHEREPROFILEPROVIDERFACTORY Construct troposphere providers.
    %
    % - "none" returns NullTroposphereProfileProvider.
    % - "profile" returns DeterministicTroposphereProfileProvider when a
    %   profile source is configured, otherwise NullTroposphereProfileProvider.
    % - "era5" returns Era5TroposphereProfileProvider when an ERA5 source is
    %   configured, otherwise NullTroposphereProfileProvider.
    %
    % The ERA5 provider is currently a source-resolving skeleton. It does
    % not parse ERA5 data yet.

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
                    if TroposphereProfileProviderFactory.hasProfileSource(cfg)
                        provider = DeterministicTroposphereProfileProvider( ...
                            dataRoot, cfg, role);
                    else
                        provider = NullTroposphereProfileProvider( ...
                            "profile", dataRoot, cfg, role);
                    end

                case "era5"
                    if Era5TroposphereProfileProvider.hasEra5Source(cfg)
                        provider = Era5TroposphereProfileProvider( ...
                            dataRoot, cfg, role);
                    else
                        provider = NullTroposphereProfileProvider( ...
                            "era5", dataRoot, cfg, role);
                    end

                otherwise
                    error('TroposphereProfileProviderFactory:UnknownProviderType', ...
                        'Unsupported troposphere provider type "%s".', ...
                        providerType);
            end
        end
    end

    methods (Static, Access = private)
        function tf = hasProfileSource(cfg)
            tf = false;

            if ~isstruct(cfg)
                return;
            end

            if isfield(cfg, 'troposphereProfile') && ...
                    isstruct(cfg.troposphereProfile)
                tf = true;
                return;
            end

            if isfield(cfg, 'profile') && isstruct(cfg.profile)
                tf = true;
            end
        end
    end
end