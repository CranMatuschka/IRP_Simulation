classdef GroundNode < handle
    % GROUNDNODE Represents a physical transmitting tower on Earth.
    % Handles geodetic-to-cartesian conversions, Earth rotation kinematics (ECI), 
    % and antenna phase center variations autonomously.
    
    properties
        name            % String: Name of the ground station
        lat_deg         % Latitude in degrees
        lon_deg         % Longitude in degrees
        alt_m           % Altitude above ellipsoid in meters
        tx_clock        % Instance of Clock
        total_bias_sec = 0.0
    end
    
    properties (Dependent)
        pos_ECEF_m      % 3x1 vector: [X; Y; Z] in ECEF frame (meters)
    end
    
    properties (Constant)
        % WGS-84 and Physical Constants
        R_earth = 6378137.0;           % meters
        f_ellipsoid = 1 / 298.257223563;
        omega_earth = 7.2921151467e-5; % rad/s
        c = 299792458.0;               % m/s
    end
    
    methods
        % =========================================================================
        % CONSTRUCTOR
        % =========================================================================
        function obj = GroundNode(node_name, lat, lon, alt, clock_obj)
            obj.name = node_name;
            obj.lat_deg = lat;
            obj.lon_deg = lon;
            obj.alt_m = alt;
            
            if nargin > 4 && ~isempty(clock_obj)
                obj.tx_clock = clock_obj;
            else
                obj.tx_clock = Clock(0, 0, 0, 1.0);
            end
        end
        
        % =========================================================================
        % GETTER: Automatically calculate ECEF position on demand
        % =========================================================================
        function val = get.pos_ECEF_m(obj)
            e2 = obj.f_ellipsoid * (2 - obj.f_ellipsoid);
            lat_rad = deg2rad(obj.lat_deg);
            lon_rad = deg2rad(obj.lon_deg);
            
            % Prime vertical radius of curvature
            N = obj.R_earth / sqrt(1 - e2 * sin(lat_rad)^2);
            
            x = (N + obj.alt_m) * cos(lat_rad) * cos(lon_rad);
            y = (N + obj.alt_m) * cos(lat_rad) * sin(lon_rad);
            z = (N * (1 - e2) + obj.alt_m) * sin(lat_rad);
            
            val = [x; y; z];
        end
        
        % =========================================================================
        % FUNCTION: Get ECI Position and Velocity (Dynamic Earth Rotation)
        % =========================================================================
        function [pos_eci_m, vel_eci_m] = getKinematicsECI(obj, jd_current)
            % Returns ground node position and velocity in ECI frame.
        
            gmst_rad = GroundNode.gmstRad(jd_current);
        
            cos_t = cos(gmst_rad);
            sin_t = sin(gmst_rad);
        
            R3 = [ cos_t, -sin_t, 0.0;
                   sin_t,  cos_t, 0.0;
                     0.0,    0.0, 1.0];
        
            pos_eci_m = R3 * obj.pos_ECEF_m;
        
            omega_vec = [0; 0; obj.omega_earth];
            vel_eci_m = cross(omega_vec, pos_eci_m);
        end
        
        function [pos_eci_m, vel_eci_m] = get_kinematics_ECI(obj, jd_current)
            % Backward-compatible wrapper. Remove later when all calls are renamed.
            [pos_eci_m, vel_eci_m] = obj.getKinematicsECI(jd_current);
        end

        function update_clock_physics(obj, dt)
            % Advances the transmitter oscillator and stores its total time bias.
            if nargin < 2 || isempty(dt)
                dt = 1.0;
            end
        
            if ~isempty(obj.tx_clock)
                obj.total_bias_sec = obj.tx_clock.update(dt);
            else
                obj.total_bias_sec = 0.0;
            end
        end
        
        % =========================================================================
        % FUNCTION: Calculate Antenna Phase Center Offset (PCO) Delay
        % =========================================================================
        function delay_sec = get_antenna_pco_delay(obj, elevation_deg, azimuth_deg, freq_idx)
           % Calculates the time delay caused by the physical offset of the antenna's
           % electrical phase center relative to its mechanical reference point.
           % freq_idx: 1 for L1, 2 for L2
           
           % Values for LEICA AR25 [L1, L2]
           pco_up_m = [0.88, 0.12] * 1e-3;       
           pco_east_m = [0.87, 0.02] * 1e-3;     
           pco_north_m = [159.36, 153.58] * 1e-3; 
           
           E_rad = deg2rad(elevation_deg);
           A_rad = deg2rad(azimuth_deg);
           
           % 1. PCO Projection onto Line-of-Sight
           range_error_pco = pco_up_m(freq_idx) * sin(E_rad) + ...
                             pco_north_m(freq_idx) * cos(E_rad) * cos(A_rad) + ...
                             pco_east_m(freq_idx) * cos(E_rad) * sin(A_rad);
                         
           % 2. Phase Center Variation (PCV) Mapping
           pcv_zenith_angles_deg = 0:5:90;
           pcv_values_mm = [0.00,  0.26,  0.63,  1.05,  1.48,  1.86,  2.16, ...
                             2.34,  2.37,  2.22,  1.90,  1.42,  0.81,  0.11, ...
                            -0.64, -1.39, -2.09, -2.68, -3.11];
            
           zenith_deg = max(0, min(90, 90.0 - elevation_deg));
           pcv_interpolated_mm = interp1(pcv_zenith_angles_deg, pcv_values_mm, zenith_deg, 'linear');
            
           range_error_pcv = pcv_interpolated_mm / 1000.0; 
           
           % Convert total distance error to time delay
           total_range_error_m = range_error_pco + range_error_pcv;
           delay_sec = total_range_error_m / obj.c;
        end
    end
    
    methods (Static)
        function gmst_rad = gmstRad(jd)
            % Greenwich mean sidereal time in radians.
            %
            % This replaces external calcGmstRad calls.
    
            T = (jd - 2451545.0) / 36525.0;
    
            gmst_deg = 280.46061837 ...
                + 360.98564736629 * (jd - 2451545.0) ...
                + 0.000387933 * T^2 ...
                - (T^3) / 38710000.0;
    
            gmst_rad = deg2rad(mod(gmst_deg, 360.0));
        end
    
        function positions_eci_m = positionsECI(nodes, jd_current)
            % Returns all GroundNode positions in ECI.
            %
            % nodes may be a cell array or a GroundNode array.
    
            n = numel(nodes);
            positions_eci_m = zeros(3, n);
    
            for i = 1:n
                if iscell(nodes)
                    node = nodes{i};
                else
                    node = nodes(i);
                end
    
                positions_eci_m(:, i) = node.getKinematicsECI(jd_current);
            end
        end
    end
end
