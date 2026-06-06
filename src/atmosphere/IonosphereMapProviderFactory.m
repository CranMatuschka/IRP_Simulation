classdef IonosphereMapProviderFactory
    %IONOSPHEREMAPPROVIDERFACTORY Construct ionosphere map providers.
    %
    % Phase-two architecture:
    % - "none" returns NullIonosphereMapProvider.
    % - "grid" returns GriddedIonosphereMapProvider for deterministic
    %   interpolation tests and future parsed products.
    % - "ionex" returns IonexIonosphereMapProvider when an IONEX source is
    %   configured; otherwise it falls back to the null provider so old
    %   placeholder tests remain baseline-safe.

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

                case "grid"
                    provider = GriddedIonosphereMapProvider( ...
                        dataRoot, cfg, role);

                case "ionex"
                    if IonosphereMapProviderFactory.hasIonexSource(cfg)
                        provider = IonexIonosphereMapProvider( ...
                            dataRoot, cfg, role);
                    else
                        provider = NullIonosphereMapProvider( ...
                            "ionex", dataRoot, cfg, role);
                    end

                otherwise
                    error('IonosphereMapProviderFactory:UnknownProviderType', ...
                        'Unsupported ionosphere provider type "%s".', ...
                        providerType);
            end
        end
    end

    methods (Static, Access = private)
        function tf = hasIonexSource(cfg)
            tf = false;

            if ~isstruct(cfg)
                return;
            end

            candidateFields = ["ionexFile", "ionexFilePath", "ionexFilename"];

            for k = 1:numel(candidateFields)
                name = char(candidateFields(k));

                if isfield(cfg, name) && ~isempty(cfg.(name))
                    tf = true;
                    return;
                end
            end

            if isfield(cfg, 'ionex')
                if isstruct(cfg.ionex)
                    if isfield(cfg.ionex, 'file') && ~isempty(cfg.ionex.file)
                        tf = true;
                        return;
                    end

                    for k = 1:numel(candidateFields)
                        name = char(candidateFields(k));

                        if isfield(cfg.ionex, name) && ~isempty(cfg.ionex.(name))
                            tf = true;
                            return;
                        end
                    end
                elseif ~isempty(cfg.ionex)
                    tf = true;
                end
            end
        end
    end
end