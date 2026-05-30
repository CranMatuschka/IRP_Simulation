classdef GroundNode < handle
    % GROUNDNODE Represents a physical transmitting tower on Earth.
    % Handles geodetic-to-cartesian conversions, Earth rotation kinematics (ECI), 
    % and antenna phase center variations autonomously.
    
    properties
        name     string % String: Name of the ground station
        lat_deg         % Latitude in degrees
        lon_deg         % Longitude in degrees
        alt_m           % Altitude above ellipsoid in meters
        tx_clock        % Instance of Clock
        antenna         % Instance of Antenna 
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
            
            if nargin >= 5 && ~isempty(clock_obj)
                obj.tx_clock = clock_obj;
            else
                obj.tx_clock = Clock(0, 0, 0, 1.0);
            end

            if nargin >= 6 && ~isempty(antenna_cfg)
                obj.antenna = Antenna(antenna_cfg);
                obj.antenna.mode = "TX";
            else
                obj.antenna = Antenna(struct( ...
                    'id', 0, ...
                    'name', sprintf('%s-TX', char(obj.name)), ...
                    'mode', 'TX', ...
                    'enabled', true, ...
                    'offsetBody_m', zeros(3,1), ...
                    'pco_m', zeros(3,1), ...
                    'pcvMap', [], ...
                    'measurementSigma_m', 0.0));
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
