classdef AtmosphereClass < handle
    % ATMOSPHERECLASS Service class for environmental physics.
    % Handles 3D Ray-Tracing through ECMWF Troposphere data and 
    % IONEX global ionosphere maps.
    
    properties
        cds_api_key     % String: API Key for Copernicus Climate Data Store
    end
    
    properties (Constant)
        % Physical Constants for Atmospheric Models
        R_earth = 6371000.0;    % Earth radius for atmospheric models (meters)
        H_ion = 350000.0;       % Height of max plasma density (meters)
        g_0 = 9.80665;          % Standard gravity (m/s^2)
        c = 299792458.0;        % Speed of light (m/s)
    end
    
    methods
        % =========================================================================
        % CONSTRUCTOR
        % =========================================================================
        function obj = AtmosphereClass(api_key)
            if nargin > 0
                obj.cds_api_key = api_key;
            else
                obj.cds_api_key = ""; % Must be set before calling ECMWF
            end
        end
        
        % =========================================================================
        % MASTER FUNCTION: Get Total Atmospheric Delay
        % =========================================================================
        function [total_delay_sec, tropo_sec, iono_sec] = get_atmospheric_delays(obj, ground_node, sat_node, freq_Hz, jd_current, datetime_utc)
            % 1. Automatically extract positions and resolve geometry
            rx_ecef_m = ground_node.pos_ECEF_m;
            sat_ecef_m = sat_node.get_pos_ECEF(jd_current);
            
            [~, elevation_deg] = obj.calc_az_el(rx_ecef_m, sat_ecef_m, ground_node.lat_deg, ground_node.lon_deg);
            
            % If the satellite is below the horizon, atmospheric models break down
            if elevation_deg < 0
                warning('Satellite is below the horizon (Elevation: %.1f deg).', elevation_deg);
                total_delay_sec = NaN; tropo_sec = NaN; iono_sec = NaN;
                return;
            end
            
            % 2. Calculate Troposphere (Neutral Atmosphere)
            tropo_sec = obj.calc_troposphere_ecmwf(ground_node.lat_deg, ground_node.lon_deg, elevation_deg, datetime_utc);
            
            % 3. Calculate Ionosphere (Dispersive Plasma)
            iono_sec = obj.calc_ionosphere_tec(ground_node.lat_deg, ground_node.lon_deg, elevation_deg, freq_Hz, datetime_utc);
            
            % 4. Sum up the delays
            total_delay_sec = tropo_sec + iono_sec;
        end
    end
    
    methods (Access = private)
        % =========================================================================
        % PRIVATE: Calculate Azimuth and Elevation (ECEF to ENU)
        % =========================================================================
        function [azimuth_deg, elevation_deg] = calc_az_el(~, rx_ecef_m, sat_ecef_m, lat_deg, lon_deg)
            dx = sat_ecef_m(1) - rx_ecef_m(1);
            dy = sat_ecef_m(2) - rx_ecef_m(2);
            dz = sat_ecef_m(3) - rx_ecef_m(3);

            lat_rad = deg2rad(lat_deg);
            lon_rad = deg2rad(lon_deg);

            t = cos(lon_rad) * dx + sin(lon_rad) * dy;
            East = -sin(lon_rad) * dx + cos(lon_rad) * dy;
            North = -sin(lat_rad) * t + cos(lat_rad) * dz;
            Up = cos(lat_rad) * t + sin(lat_rad) * dz;

            azimuth_deg = mod(rad2deg(atan2(East, North)), 360);
            elevation_deg = rad2deg(atan2(Up, sqrt(East^2 + North^2)));
        end
        
        % =========================================================================
        % PRIVATE: Troposphere 3D ECMWF Ray Tracing
        % =========================================================================
        function delay_sec = calc_troposphere_ecmwf(obj, lat, lon, elev_angle_deg, datetime_utc)
            % Bounding box for local weather profile
            lat_N = lat + 0.125; lat_S = lat - 0.125;
            lon_W = lon - 0.125; lon_E = lon + 0.125;
            
            filename_str = sprintf('data/era5_profile_%04d%02d%02d_%02d00.nc', ...
                year(datetime_utc), month(datetime_utc), day(datetime_utc), hour(datetime_utc));
            nc_filename = fullfile(pwd, filename_str);
            
            % Download logic (only if file is missing)
            if ~isfile(nc_filename)
                if obj.cds_api_key == ""
                    error('CDS API Key is missing. Cannot download ECMWF data.');
                end
                client = py.cdsapi.Client(pyargs('url', 'https://cds.climate.copernicus.eu/api', 'key', obj.cds_api_key));
                request_dict = py.dict(pyargs(...
                    'product_type', 'reanalysis', 'data_format', 'netcdf', ...
                    'variable', py.list({'temperature', 'specific_humidity', 'geopotential'}), ...
                    'pressure_level', py.list({'1', '2', '3', '5', '7', '10', '20', '30', '50', '70', ...
                                               '100', '150', '200', '250', '300', '400', '500', '600', ...
                                               '700', '775', '850', '925', '1000'}), ...
                    'year', num2str(year(datetime_utc)), 'month', sprintf('%02d', month(datetime_utc)), ...
                    'day', sprintf('%02d', day(datetime_utc)), 'time', sprintf('%02d:00', hour(datetime_utc)), ... 
                    'area', py.list({lat_N, lon_W, lat_S, lon_E}) ... 
                ));
                client.retrieve('reanalysis-era5-pressure-levels', request_dict, nc_filename);
            end
        
            % Extract and process 3D Weather Layers
            T_mean = squeeze(mean(ncread(nc_filename, 't'), [1, 2], 'omitnan'));
            q_mean = squeeze(mean(ncread(nc_filename, 'q'), [1, 2], 'omitnan'));
            Z_mean = squeeze(mean(ncread(nc_filename, 'z'), [1, 2], 'omitnan'));
            
            [Z_raw, sort_idx] = sort(Z_mean, 'ascend');
            T_raw = T_mean(sort_idx);
            q_raw = q_mean(sort_idx);
            h_layers = Z_raw / obj.g_0; 
            
            P_levels = sort([1, 2, 3, 5, 7, 10, 20, 30, 50, 70, 100, 150, 200, 250, 300, 400, 500, 600, 700, 775, 850, 925, 1000]', 'descend');
            e_layers = (q_raw .* P_levels) ./ (0.622 + 0.378 .* q_raw);
            N_layers = 77.6 .* (P_levels ./ T_raw) + 3.73e5 .* (e_layers ./ (T_raw.^2));
            n_layers = 1 + (N_layers * 1e-6);
        
            % 3D Ray-Tracing via Snell's Law
            zenith_angle = deg2rad(90 - elev_angle_deg);
            delay_meters = 0;
            
            for i = 1:(length(h_layers) - 1)
                r_current = obj.R_earth + h_layers(i);
                r_next = obj.R_earth + h_layers(i+1);
                n_current = n_layers(i);
                n_next = n_layers(i+1); 
                
                C = r_current * n_current * sin(zenith_angle); 
                sin_next_zenith = C / (r_next * n_next); 
                if sin_next_zenith > 1; break; end % Total internal reflection
                
                next_zenith_angle = asin(sin_next_zenith);
                ds = sqrt(r_next^2 - r_current^2 * sin(zenith_angle)^2) - r_current * cos(zenith_angle); 
                delay_meters = delay_meters + (n_current - 1) * ds; 
                zenith_angle = next_zenith_angle; 
            end
            
            delay_sec = delay_meters / obj.c;
        end
        
        % =========================================================================
        % PRIVATE: Ionosphere IONEX VTEC to STEC Mapping
        % =========================================================================
        function delay_sec = calc_ionosphere_tec(obj, lat, lon, elev_angle_deg, f_Hz, datetime_utc)
            year_4d = year(datetime_utc);
            doy_str = sprintf('%03d', floor(datenum(datetime_utc)) - datenum(year_4d, 1, 0));
            
            filename_gz = sprintf('data/COD0OPSFIN_%04d%s0000_01D_01H_GIM.INX.gz', year_4d, doy_str);
            filename_unzipped = sprintf('data/COD0OPSFIN_%04d%s0000_01D_01H_GIM.INX', year_4d, doy_str);
            
            % Download logic
            if ~isfile(fullfile(pwd, filename_unzipped))
                url = sprintf('http://ftp.aiub.unibe.ch/CODE/%04d/%s', year_4d, filename_gz);
                websave(fullfile(pwd, filename_gz), url);
                gunzip(fullfile(pwd, filename_gz)); 
            end
            
            % Parse IONEX file
            fid = fopen(fullfile(pwd, filename_unzipped), 'r');
            target_hour = hour(datetime_utc); 
            vtec_value = NaN; exponent = -1; 
            is_correct_map = false;
            
            while ~feof(fid)
                line = fgetl(fid);
                if contains(line, 'EPOCH OF CURRENT MAP')
                    map_time = sscanf(line, '%d %d %d %d %d %d');
                    if map_time(4) == target_hour
                        is_correct_map = true;
                    elseif map_time(4) > target_hour
                        break;
                    end
                end
                
                if is_correct_map && contains(line, 'LAT/LON1/LON2/DLON/H')
                    lat_data = sscanf(line, '%f %f %f %f %f');
                    if abs(lat_data(1) - lat) <= 1.25
                        lon_index = round((lon - lat_data(2)) / lat_data(4)) + 1;
                        tec_values = [];
                        while length(tec_values) < lon_index
                            tec_values = [tec_values; sscanf(fgetl(fid), '%f')]; %#ok<AGROW>
                        end
                        vtec_value = tec_values(lon_index) * (10^exponent);
                        break; 
                    end
                end
                if contains(line, 'EXPONENT')
                    exponent = sscanf(line, '%f');
                end
            end
            fclose(fid);
            
            if isnan(vtec_value)
                warning('Could not find VTEC value. Defaulting to 0.');
                vtec_value = 0;
            end
            
            % Mapping Function (VTEC to STEC)
            E_rad = deg2rad(elev_angle_deg);
            sin_alpha = (obj.R_earth / (obj.R_earth + obj.H_ion)) * cos(E_rad);
            MF = 1 / sqrt(1 - sin_alpha^2);
            STEC = vtec_value * MF;
            
            % Physics: Delay in meters -> Time in seconds
            delay_meters = (40.3 * STEC * 1e16) / (f_Hz^2);
            delay_sec = delay_meters / obj.c;
        end
    end
end