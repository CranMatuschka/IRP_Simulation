classdef IonosphereMapProviderFactory
    %IONOSPHEREMAPPROVIDERFACTORY Construct ionosphere map providers.
    %
    % Phase-two architecture commit only:
    % - "none" returns NullIonosphereMapProvider.
    % - "ionex" also returns NullIonosphereMapProvider until IonexProvider
    %   is implemented in a later commit.

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
                    provider = NullIonosphereMapProvider( ...
                        "none", dataRoot, cfg, role);

                case "ionex"
                    % IonexProvider is intentionally introduced later.
                    % Keeping this non-operational preserves baseline
                    % behaviour while exposing the provider seam.
                    provider = NullIonosphereMapProvider( ...
                        "ionex", dataRoot, cfg, role);

                otherwise
                    error('IonosphereMapProviderFactory:UnknownProviderType', ...
                        'Unsupported ionosphere provider type "%s".', ...
                        providerType);
            end
        end
    end
end