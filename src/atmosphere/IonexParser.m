classdef IonexParser
    %IONEXPARSER Parse a minimal IONEX TEC product into an in-memory VTEC grid.
    %
    % This parser supports the core IONEX structure needed for phase-two
    % ionosphere modelling:
    %   EXPONENT
    %   START OF TEC MAP
    %   EPOCH OF CURRENT MAP
    %   LAT/LON1/LON2/DLON/H
    %   END OF TEC MAP
    %
    % Output is compatible with GriddedIonosphereMapProvider.

    methods (Static)
        function mapCfg = parseFile(filePath)
            filePath = string(filePath);

            if strlength(filePath) == 0 || ~isfile(char(filePath))
                error('IonexParser:MissingFile', ...
                    'IONEX file does not exist: %s', filePath);
            end

            text = fileread(char(filePath));
            lines = splitlines(string(text));

            exponent = IonexParser.parseHeaderExponent(lines);

            maps = struct( ...
                'epochUtc', {}, ...
                'latitude_deg', {}, ...
                'longitude_deg', {}, ...
                'vtec_TECU', {});

            idx = 1;

            while idx <= numel(lines)
                line = lines(idx);

                if contains(line, "START OF TEC MAP")
                    [tecMap, idx] = IonexParser.parseTecMap( ...
                        lines, idx, exponent);

                    maps(end + 1) = tecMap; %#ok<AGROW>
                else
                    idx = idx + 1;
                end
            end

            if isempty(maps)
                error('IonexParser:NoTecMaps', ...
                    'IONEX file contains no TEC maps: %s', filePath);
            end

            referenceLatitude = maps(1).latitude_deg(:);
            referenceLongitude = maps(1).longitude_deg(:);

            nLat = numel(referenceLatitude);
            nLon = numel(referenceLongitude);
            nTime = numel(maps);

            epochUtc = NaT(nTime, 1, 'TimeZone', 'UTC');
            vtec_TECU = NaN(nLat, nLon, nTime);

            for k = 1:nTime
                if ~isequal(maps(k).latitude_deg(:), referenceLatitude) || ...
                        ~isequal(maps(k).longitude_deg(:), referenceLongitude)
                    error('IonexParser:InconsistentGrid', ...
                        'All TEC maps must use the same latitude/longitude grid.');
                end

                epochUtc(k) = maps(k).epochUtc;
                vtec_TECU(:, :, k) = maps(k).vtec_TECU;
            end

            mapCfg = struct();
            mapCfg.datetimeUtc = epochUtc;
            mapCfg.latitude_deg = referenceLatitude;
            mapCfg.longitude_deg = referenceLongitude;
            mapCfg.vtec_TECU = vtec_TECU;
            mapCfg.rms_TECU = NaN(size(vtec_TECU));
            mapCfg.source = filePath;
            mapCfg.metadata = struct( ...
                'format', "IONEX", ...
                'exponent', exponent, ...
                'numMaps', nTime);
        end
    end

    methods (Static, Access = private)
        function exponent = parseHeaderExponent(lines)
            exponent = 0.0;

            for idx = 1:numel(lines)
                line = lines(idx);

                if contains(line, "END OF HEADER")
                    return;
                end

                if contains(line, "EXPONENT")
                    leftText = IonexParser.leftOfLabel(line, "EXPONENT");
                    numbers = IonexParser.numericValues(leftText);

                    if ~isempty(numbers)
                        exponent = double(numbers(1));
                    end
                end
            end
        end

        function [tecMap, idx] = parseTecMap(lines, idx, exponent)
            epochUtc = NaT(1, 1, 'TimeZone', 'UTC');

            latitudeValues = [];
            longitudeReference = [];
            vtecRows = {};

            idx = idx + 1;

            while idx <= numel(lines)
                line = lines(idx);

                if contains(line, "END OF TEC MAP")
                    idx = idx + 1;
                    break;
                end

                if contains(line, "EPOCH OF CURRENT MAP")
                    leftText = IonexParser.leftOfLabel( ...
                        line, "EPOCH OF CURRENT MAP");

                    numbers = IonexParser.numericValues(leftText);

                    if numel(numbers) < 6
                        error('IonexParser:InvalidEpochLine', ...
                            'IONEX TEC map epoch line is malformed.');
                    end

                    epochUtc = datetime( ...
                        numbers(1), numbers(2), numbers(3), ...
                        numbers(4), numbers(5), numbers(6), ...
                        'TimeZone', 'UTC');

                    idx = idx + 1;
                    continue;
                end

                if contains(line, "LAT/LON1/LON2/DLON/H")
                    leftText = IonexParser.leftOfLabel( ...
                        line, "LAT/LON1/LON2/DLON/H");

                    numbers = IonexParser.numericValues(leftText);

                    if numel(numbers) < 4
                        error('IonexParser:InvalidLatLonHeader', ...
                            'IONEX LAT/LON1/LON2/DLON/H line is malformed.');
                    end

                    latitude_deg = double(numbers(1));
                    lon1_deg = double(numbers(2));
                    lon2_deg = double(numbers(3));
                    dlon_deg = double(numbers(4));

                    longitude_deg = IonexParser.longitudeVector( ...
                        lon1_deg, lon2_deg, dlon_deg);

                    requiredValues = numel(longitude_deg);
                    values = [];

                    idx = idx + 1;

                    while idx <= numel(lines)
                        nextLine = lines(idx);

                        if contains(nextLine, "LAT/LON1/LON2/DLON/H") || ...
                                contains(nextLine, "END OF TEC MAP")
                            break;
                        end

                        values = [values, IonexParser.numericValues(nextLine)]; %#ok<AGROW>
                        idx = idx + 1;

                        if numel(values) >= requiredValues
                            break;
                        end
                    end

                    if numel(values) < requiredValues
                        error('IonexParser:InsufficientTecValues', ...
                            'IONEX TEC latitude row has too few values.');
                    end

                    values = values(1:requiredValues);

                    if any(abs(values) >= 9999)
                        error('IonexParser:MissingTecValuesUnsupported', ...
                            ['This baseline IONEX parser does not yet ', ...
                             'support missing TEC values.']);
                    end

                    vtec_TECU = double(values(:).') * 10.0^double(exponent);

                    if isempty(longitudeReference)
                        longitudeReference = longitude_deg(:);
                    elseif ~isequal(longitudeReference(:), longitude_deg(:))
                        error('IonexParser:InconsistentLongitudeGrid', ...
                            'All IONEX latitude rows must use the same longitude grid.');
                    end

                    latitudeValues(end + 1, 1) = latitude_deg; %#ok<AGROW>
                    vtecRows{end + 1, 1} = vtec_TECU; %#ok<AGROW>

                    continue;
                end

                idx = idx + 1;
            end

            if isnat(epochUtc)
                error('IonexParser:MissingEpoch', ...
                    'IONEX TEC map is missing EPOCH OF CURRENT MAP.');
            end

            if isempty(latitudeValues)
                error('IonexParser:EmptyTecMap', ...
                    'IONEX TEC map contains no latitude rows.');
            end

            [latitudeSorted, order] = sort(latitudeValues(:));

            nLat = numel(latitudeSorted);
            nLon = numel(longitudeReference);

            vtec_TECU = NaN(nLat, nLon);

            for row = 1:nLat
                vtec_TECU(row, :) = vtecRows{order(row)};
            end

            tecMap = struct();
            tecMap.epochUtc = epochUtc;
            tecMap.latitude_deg = latitudeSorted;
            tecMap.longitude_deg = longitudeReference(:);
            tecMap.vtec_TECU = vtec_TECU;
        end

        function longitude_deg = longitudeVector(lon1_deg, lon2_deg, dlon_deg)
            if abs(dlon_deg) <= eps
                error('IonexParser:InvalidLongitudeStep', ...
                    'IONEX longitude step DLON must be nonzero.');
            end

            span = lon2_deg - lon1_deg;

            if sign(span) ~= sign(dlon_deg) && abs(span) > eps
                error('IonexParser:InvalidLongitudeDirection', ...
                    'IONEX longitude step sign does not match longitude span.');
            end

            n = floor(abs(span / dlon_deg) + 0.5) + 1;

            longitude_deg = lon1_deg + (0:n - 1).' * dlon_deg;

            if abs(longitude_deg(end) - lon2_deg) < 1e-9
                longitude_deg(end) = lon2_deg;
            end
        end

        function leftText = leftOfLabel(line, labelText)
            line = string(line);
            labelText = string(labelText);

            position = strfind(char(line), char(labelText));

            if isempty(position)
                leftText = line;
            else
                leftText = extractBefore(line, position(1));
            end
        end

        function values = numericValues(line)
            line = strrep(string(line), "D", "E");
            line = strrep(line, "d", "e");

            tokens = regexp( ...
                char(line), ...
                '[-+]?\d+(?:\.\d*)?(?:[Ee][-+]?\d+)?|[-+]?\.\d+(?:[Ee][-+]?\d+)?', ...
                'match');

            values = zeros(1, numel(tokens));

            for k = 1:numel(tokens)
                values(k) = str2double(tokens{k});
            end
        end
    end
end