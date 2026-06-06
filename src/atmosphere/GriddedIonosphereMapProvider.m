classdef GriddedIonosphereMapProvider < IonosphereMapProvider
    %GRIDDEDIONOSPHEREMAPPROVIDER Deterministic VTEC grid interpolation.
    %
    % This provider is intentionally file-format independent. IONEX parsing
    % will later produce the same in-memory grid representation and can reuse
    % this interpolation path.
    %
    % Expected map configuration fields:
    %   datetimeUtc   [Nt x 1] datetime vector
    %   latitude_deg  [Nlat x 1] latitude grid
    %   longitude_deg [Nlon x 1] longitude grid
    %   vtec_TECU     [Nlat x Nlon x Nt] vertical TEC grid
    %
    % Optional:
    %   rms_TECU      [Nlat x Nlon x Nt] RMS grid

    properties (SetAccess = private)
        epochUtc = []
        latitude_deg double = []
        longitude_deg double = []
        vtec_TECU double = []
        rms_TECU double = []
        source string = "in-memory grid"
    end

    methods
        function obj = GriddedIonosphereMapProvider(dataRoot, cfg, role)
            if nargin < 1
                dataRoot = "";
            end

            if nargin < 2
                cfg = struct();
            end

            if nargin < 3
                role = "model";
            end

            obj@IonosphereMapProvider("grid", dataRoot, cfg, role);

            mapCfg = obj.mapConfigFromProviderConfig(cfg);

            obj.epochUtc = obj.requiredField( ...
                mapCfg, ["datetimeUtc", "timeUtc", "epochsUtc"], ...
                'datetimeUtc');

            if ~isdatetime(obj.epochUtc)
                error('GriddedIonosphereMapProvider:InvalidEpochs', ...
                    'Grid datetimeUtc must be a datetime vector.');
            end

            obj.epochUtc = obj.epochUtc(:);

            obj.latitude_deg = double(obj.requiredField( ...
                mapCfg, ["latitude_deg", "lat_deg", "latitudes_deg"], ...
                'latitude_deg'));

            obj.longitude_deg = double(obj.requiredField( ...
                mapCfg, ["longitude_deg", "lon_deg", "longitudes_deg"], ...
                'longitude_deg'));

            obj.latitude_deg = obj.latitude_deg(:);
            obj.longitude_deg = obj.longitude_deg(:);

            obj.vtec_TECU = double(obj.requiredField( ...
                mapCfg, ["vtec_TECU", "vtec"], ...
                'vtec_TECU'));

            if isfield(mapCfg, 'rms_TECU') && ~isempty(mapCfg.rms_TECU)
                obj.rms_TECU = double(mapCfg.rms_TECU);
            else
                obj.rms_TECU = NaN(size(obj.vtec_TECU));
            end

            if isfield(mapCfg, 'source') && ~isempty(mapCfg.source)
                obj.source = string(mapCfg.source);
            end

            obj.validateAndSortGrid();
        end

        function tf = isAvailable(obj)
            tf = ~isempty(obj.epochUtc) && ...
                ~isempty(obj.latitude_deg) && ...
                ~isempty(obj.longitude_deg) && ...
                ~isempty(obj.vtec_TECU);
        end

        function result = verticalTecAt( ...
                obj, datetimeUtc, latitude_deg, longitude_deg)

            result = obj.emptyResult( ...
                datetimeUtc, latitude_deg, longitude_deg);

            result.providerType = "grid";
            result.source = obj.source;

            if ~obj.isAvailable()
                result.message = "Gridded ionosphere map is empty.";
                return;
            end

            if ~isdatetime(datetimeUtc) || ~isscalar(datetimeUtc)
                error('GriddedIonosphereMapProvider:InvalidDatetime', ...
                    'datetimeUtc must be a scalar datetime.');
            end

            latitude_deg = double(latitude_deg);
            longitude_deg = obj.normalizeLongitudeToGrid(double(longitude_deg));

            [iLat0, iLat1, wLat, okLat] = ...
                obj.bracketIndex(obj.latitude_deg, latitude_deg);

            [iLon0, iLon1, wLon, okLon] = ...
                obj.bracketIndex(obj.longitude_deg, longitude_deg);

            epochSeconds = seconds(obj.epochUtc - obj.epochUtc(1));
            querySeconds = seconds(datetimeUtc - obj.epochUtc(1));

            [iTime0, iTime1, wTime, okTime] = ...
                obj.bracketIndex(epochSeconds, querySeconds);

            if ~(okLat && okLon && okTime)
                result.message = ...
                    "Requested time or pierce-point location is outside the VTEC grid.";
                return;
            end

            vtec0 = obj.interpolateSpatialSlice( ...
                obj.vtec_TECU(:, :, iTime0), ...
                iLat0, iLat1, wLat, ...
                iLon0, iLon1, wLon);

            vtec1 = obj.interpolateSpatialSlice( ...
                obj.vtec_TECU(:, :, iTime1), ...
                iLat0, iLat1, wLat, ...
                iLon0, iLon1, wLon);

            rms0 = obj.interpolateSpatialSlice( ...
                obj.rms_TECU(:, :, iTime0), ...
                iLat0, iLat1, wLat, ...
                iLon0, iLon1, wLon);

            rms1 = obj.interpolateSpatialSlice( ...
                obj.rms_TECU(:, :, iTime1), ...
                iLat0, iLat1, wLat, ...
                iLon0, iLon1, wLon);

            vtec_TECU = (1.0 - wTime) * vtec0 + wTime * vtec1;
            rms_TECU = (1.0 - wTime) * rms0 + wTime * rms1;

            if ~isfinite(vtec_TECU)
                result.message = "Interpolated VTEC is not finite.";
                return;
            end

            result.valid = true;
            result.message = "";
            result.vtec_TECU = double(vtec_TECU);
            result.rms_TECU = double(rms_TECU);

            result.latitude_deg = double(latitude_deg);
            result.longitude_deg = double(longitude_deg);

            result.metadata = struct( ...
                'latitudeIndex0', iLat0, ...
                'latitudeIndex1', iLat1, ...
                'longitudeIndex0', iLon0, ...
                'longitudeIndex1', iLon1, ...
                'timeIndex0', iTime0, ...
                'timeIndex1', iTime1, ...
                'latitudeWeight', wLat, ...
                'longitudeWeight', wLon, ...
                'timeWeight', wTime);
        end
    end

    methods (Access = private)
        function validateAndSortGrid(obj)
            validateattributes(obj.latitude_deg, {'numeric'}, ...
                {'real', 'finite', 'vector', 'nonempty'}, ...
                mfilename, 'latitude_deg');

            validateattributes(obj.longitude_deg, {'numeric'}, ...
                {'real', 'finite', 'vector', 'nonempty'}, ...
                mfilename, 'longitude_deg');

            if any(obj.latitude_deg < -90.0) || any(obj.latitude_deg > 90.0)
                error('GriddedIonosphereMapProvider:InvalidLatitudeGrid', ...
                    'Latitude grid must be inside [-90, 90] degrees.');
            end

            [obj.latitude_deg, latOrder] = sort(obj.latitude_deg(:));
            [obj.longitude_deg, lonOrder] = sort(obj.longitude_deg(:));
            [obj.epochUtc, timeOrder] = sort(obj.epochUtc(:));

            nLat = numel(obj.latitude_deg);
            nLon = numel(obj.longitude_deg);
            nTime = numel(obj.epochUtc);

            if ismatrix(obj.vtec_TECU) && nTime == 1
                obj.vtec_TECU = reshape(obj.vtec_TECU, nLat, nLon, 1);
            end

            expectedSize = [nLat, nLon, nTime];

            if ~isequal(size(obj.vtec_TECU), expectedSize)
                error('GriddedIonosphereMapProvider:InvalidVtecGridSize', ...
                    ['vtec_TECU must have size ', ...
                     '[numel(latitude_deg), numel(longitude_deg), numel(datetimeUtc)].']);
            end

            if isscalar(obj.rms_TECU)
                obj.rms_TECU = ones(expectedSize) * obj.rms_TECU;
            elseif ismatrix(obj.rms_TECU) && nTime == 1
                obj.rms_TECU = reshape(obj.rms_TECU, nLat, nLon, 1);
            end

            if ~isequal(size(obj.rms_TECU), expectedSize)
                obj.rms_TECU = NaN(expectedSize);
            end

            obj.vtec_TECU = obj.vtec_TECU(latOrder, lonOrder, timeOrder);
            obj.rms_TECU = obj.rms_TECU(latOrder, lonOrder, timeOrder);

            validateattributes(obj.vtec_TECU, {'numeric'}, ...
                {'real', 'finite', 'size', expectedSize}, ...
                mfilename, 'vtec_TECU');
        end

        function longitude_deg = normalizeLongitudeToGrid(obj, longitude_deg)
            gridMin = min(obj.longitude_deg);
            gridMax = max(obj.longitude_deg);

            if gridMin >= 0.0 && gridMax <= 360.0
                longitude_deg = mod(longitude_deg, 360.0);
            else
                longitude_deg = mod(longitude_deg + 180.0, 360.0) - 180.0;

                if longitude_deg == -180.0 && any(obj.longitude_deg == 180.0)
                    longitude_deg = 180.0;
                end
            end
        end

        function value = interpolateSpatialSlice( ...
                ~, gridSlice, iLat0, iLat1, wLat, iLon0, iLon1, wLon)

            v00 = gridSlice(iLat0, iLon0);
            v10 = gridSlice(iLat1, iLon0);
            v01 = gridSlice(iLat0, iLon1);
            v11 = gridSlice(iLat1, iLon1);

            vLat0 = (1.0 - wLat) * v00 + wLat * v10;
            vLat1 = (1.0 - wLat) * v01 + wLat * v11;

            value = (1.0 - wLon) * vLat0 + wLon * vLat1;
        end
    end

    methods (Static, Access = private)
        function mapCfg = mapConfigFromProviderConfig(cfg)
            if isstruct(cfg) && isfield(cfg, 'ionosphereMap')
                mapCfg = cfg.ionosphereMap;
            elseif isstruct(cfg) && isfield(cfg, 'grid')
                mapCfg = cfg.grid;
            else
                mapCfg = cfg;
            end
        end

        function value = requiredField(s, candidateNames, displayName)
            for k = 1:numel(candidateNames)
                name = char(candidateNames(k));

                if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
                    value = s.(name);
                    return;
                end
            end

            error('GriddedIonosphereMapProvider:MissingField', ...
                'Missing required ionosphere map field "%s".', displayName);
        end

        function [i0, i1, weight, ok] = bracketIndex(gridValues, queryValue)
            gridValues = double(gridValues(:));
            queryValue = double(queryValue);

            ok = true;
            weight = 0.0;

            if isempty(gridValues) || ~isfinite(queryValue)
                i0 = 1;
                i1 = 1;
                ok = false;
                return;
            end

            if numel(gridValues) == 1
                i0 = 1;
                i1 = 1;
                weight = 0.0;
                return;
            end

            if queryValue < gridValues(1) || queryValue > gridValues(end)
                i0 = 1;
                i1 = 1;
                ok = false;
                return;
            end

            if queryValue == gridValues(end)
                i0 = numel(gridValues);
                i1 = numel(gridValues);
                weight = 0.0;
                return;
            end

            i1 = find(gridValues >= queryValue, 1, 'first');

            if isempty(i1)
                i0 = 1;
                i1 = 1;
                ok = false;
                return;
            end

            if gridValues(i1) == queryValue
                i0 = i1;
                weight = 0.0;
                return;
            end

            i0 = max(i1 - 1, 1);
            denominator = gridValues(i1) - gridValues(i0);

            if denominator <= 0.0
                ok = false;
                weight = 0.0;
                return;
            end

            weight = (queryValue - gridValues(i0)) / denominator;
        end
    end
end