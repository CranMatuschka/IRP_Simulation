classdef Era5TroposphereProfileProvider < TroposphereProfileProvider
    %ERA5TROPOSPHEREPROFILEPROVIDER ERA5-backed troposphere provider shell.
    %
    % This class intentionally does not parse ERA5 yet. It resolves and
    % stores the configured ERA5 source file so that the next commit can add
    % NetCDF/GRIB parsing without changing Atmosphere or MeasurementModel.
    %
    % Supported configuration fields:
    %   era5File
    %   era5FilePath
    %   era5Filename
    %
    % Also supported:
    %   era5.file
    %   era5.era5File
    %   era5.era5FilePath
    %   era5.era5Filename
    %
    % Relative paths are resolved against dataRoot.

    properties (SetAccess = private)
        era5File string = ""
        source string = ""
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
        end

        function tf = isAvailable(~)
            % ERA5 parsing is intentionally not implemented in this skeleton.
            % A configured file can be resolved, but no meteorological profile
            % can yet be produced from it.
            tf = false;
        end

        function result = profileAt( ...
                obj, datetimeUtc, latitude_deg, longitude_deg, height_m)

            result = obj.emptyResult( ...
                datetimeUtc, latitude_deg, longitude_deg, height_m);

            result.providerType = "era5";
            result.source = obj.source;
            result.message = ...
                "ERA5 troposphere provider is configured, but ERA5 parsing is not implemented yet.";

            result.metadata.era5File = obj.era5File;
        end
    end

    methods (Static)
        function tf = hasEra5Source(cfg)
            tf = strlength(Era5TroposphereProfileProvider.getEra5PathFromCfg(cfg)) > 0;
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
    end
end