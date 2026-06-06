classdef IonexIonosphereMapProvider < GriddedIonosphereMapProvider
    %IONEXIONOSPHEREMAPPROVIDER IONEX-backed VTEC map provider.
    %
    % This provider parses IONEX into the same grid representation used by
    % GriddedIonosphereMapProvider. Atmosphere integration with
    % ionosphereModel="ionex" is intentionally handled in a later commit.

    properties (SetAccess = private)
        ionexFile string = ""
    end

    methods
        function obj = IonexIonosphereMapProvider(dataRoot, cfg, role)
            if nargin < 1
                dataRoot = "";
            end

            if nargin < 2
                cfg = struct();
            end

            if nargin < 3
                role = "model";
            end

            ionexFilePath = IonexIonosphereMapProvider.resolveIonexPath( ...
                dataRoot, cfg);

            mapCfg = IonexParser.parseFile(ionexFilePath);

            providerCfg = struct();
            providerCfg.ionosphereMap = mapCfg;

            obj@GriddedIonosphereMapProvider(dataRoot, providerCfg, role);

            obj.providerType = "ionex";
            obj.ionexFile = ionexFilePath;
        end

        function result = verticalTecAt( ...
                obj, datetimeUtc, latitude_deg, longitude_deg)

            result = verticalTecAt@GriddedIonosphereMapProvider( ...
                obj, datetimeUtc, latitude_deg, longitude_deg);

            result.providerType = "ionex";
            result.source = obj.ionexFile;
        end
    end

    methods (Static, Access = private)
        function ionexFilePath = resolveIonexPath(dataRoot, cfg)
            ionexFilePath = IonexIonosphereMapProvider.getIonexPathFromCfg(cfg);

            if strlength(ionexFilePath) == 0
                error('IonexIonosphereMapProvider:MissingIonexFile', ...
                    ['IONEX provider requires one of: ionexFile, ', ...
                     'ionexFilePath, ionexFilename, or ionex.file.']);
            end

            ionexFilePath = string(ionexFilePath);

            if ~IonexIonosphereMapProvider.isAbsolutePath(ionexFilePath)
                ionexFilePath = fullfile(string(dataRoot), ionexFilePath);
            end

            if ~isfile(char(ionexFilePath))
                error('IonexIonosphereMapProvider:IonexFileNotFound', ...
                    'IONEX file not found: %s', ionexFilePath);
            end
        end

        function pathValue = getIonexPathFromCfg(cfg)
            pathValue = "";

            if ~isstruct(cfg)
                return;
            end

            candidateFields = ["ionexFile", "ionexFilePath", "ionexFilename"];

            for k = 1:numel(candidateFields)
                name = char(candidateFields(k));

                if isfield(cfg, name) && ~isempty(cfg.(name))
                    pathValue = string(cfg.(name));
                    return;
                end
            end

            if isfield(cfg, 'ionex') && isstruct(cfg.ionex)
                for k = 1:numel(candidateFields)
                    name = char(candidateFields(k));

                    if isfield(cfg.ionex, name) && ~isempty(cfg.ionex.(name))
                        pathValue = string(cfg.ionex.(name));
                        return;
                    end
                end

                if isfield(cfg.ionex, 'file') && ~isempty(cfg.ionex.file)
                    pathValue = string(cfg.ionex.file);
                end
            elseif isfield(cfg, 'ionex') && ~isempty(cfg.ionex)
                pathValue = string(cfg.ionex);
            end
        end

        function tf = isAbsolutePath(pathValue)
            pathText = char(string(pathValue));

            tf = startsWith(pathText, filesep) || ...
                ~isempty(regexp(pathText, '^[A-Za-z]:[\\/]', 'once'));
        end
    end
end