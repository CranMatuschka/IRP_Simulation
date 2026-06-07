classdef GroundNode < handle
    %GROUNDNODE Physical transmitting ground tower.
    %
    % Owns:
    %   - geodetic location
    %   - transmitter clock
    %   - transmitter antenna
    %   - tower-specific TX hardware / signal delay

    properties
        name string = "GROUND"
        lat_deg double = 0.0
        lon_deg double = 0.0
        alt_m double = 0.0

        tx_clock = []
        antenna = []

        txSignalDelay_m double = 0.0
        total_bias_sec double = 0.0
        truthPositionOffsetEcef_m double = zeros(3, 1)
        modelPositionOffsetEcef_m double = zeros(3, 1)
    end

    properties (Dependent)
        pos_ECEF_m
    end

    properties (Constant)
        c = 299792458.0
    end

    methods
        function obj = GroundNode(cfg, clockObj, antennaCfg)
            if nargin == 0
                obj.tx_clock = Clock(0, 0, 0, 1.0);
                obj.antenna = GroundNode.defaultTxAntenna("GROUND");
                return;
            end

            if ~isstruct(cfg)
                error('GroundNode:InvalidConfiguration', ...
                    'GroundNode requires a tower configuration struct.');
            end

            obj.name = string(cfg.name);
            obj.lat_deg = double(cfg.lat_deg);
            obj.lon_deg = double(cfg.lon_deg);
            obj.alt_m = double(cfg.alt_m);

            if isfield(cfg, 'txSignalDelay_m')
                obj.txSignalDelay_m = double(cfg.txSignalDelay_m);
            end
            if isfield(cfg, 'truthPositionOffsetEcef_m') && ...
                    ~isempty(cfg.truthPositionOffsetEcef_m)
                obj.truthPositionOffsetEcef_m = ...
                    double(cfg.truthPositionOffsetEcef_m(:));
            end

            if isfield(cfg, 'modelPositionOffsetEcef_m') && ...
                    ~isempty(cfg.modelPositionOffsetEcef_m)
                obj.modelPositionOffsetEcef_m = ...
                    double(cfg.modelPositionOffsetEcef_m(:));
            end

            validateattributes(obj.truthPositionOffsetEcef_m, ...
                {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'truthPositionOffsetEcef_m');

            validateattributes(obj.modelPositionOffsetEcef_m, ...
                {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, ...
                mfilename, 'modelPositionOffsetEcef_m');
            
            if nargin >= 2 && ~isempty(clockObj)
                obj.tx_clock = clockObj;
            else
                obj.tx_clock = Clock(0, 0, 0, 1.0);
            end

            if nargin >= 3 && ~isempty(antennaCfg)
                antCfg = antennaCfg;
            elseif isfield(cfg, 'antenna') && ~isempty(cfg.antenna)
                antCfg = cfg.antenna;
            else
                antCfg = GroundNode.defaultTxAntennaConfig(obj.name);
            end

            obj.antenna = Antenna(antCfg);
            obj.antenna.mode = "TX";
        end

        function val = get.pos_ECEF_m(obj)
            val = FrameGeometry.geodeticToEcef(obj.lat_deg, obj.lon_deg, obj.alt_m);
        end

        function [pos_eci_m, vel_eci_mps] = getKinematicsECI(obj, jd)
            [pos_eci_m, vel_eci_mps] = FrameGeometry.fixedGroundKinematicsEci( ...
                obj.lat_deg, obj.lon_deg, obj.alt_m, jd);
        end

        function pos_eci_m = positionEci(obj, jd)
            pos_eci_m = obj.getKinematicsECI(jd);
        end

        function bias_sec = updateClock(obj, dt)
            if nargin < 2 || isempty(dt)
                dt = 1.0;
            end

            if isempty(obj.tx_clock)
                obj.total_bias_sec = 0.0;
            else
                obj.total_bias_sec = obj.tx_clock.update(dt);
            end

            bias_sec = obj.total_bias_sec;
        end

        function bias_m = clockBias_m(obj)
            if isempty(obj.tx_clock)
                bias_m = 0.0;
            else
                bias_m = obj.c * obj.tx_clock.total_bias_sec;
            end
        end

        function drift_mps = clockDrift_mps(obj)
            if isempty(obj.tx_clock)
                drift_mps = 0.0;
            else
                drift_mps = obj.c * obj.tx_clock.total_drift_sec_per_s;
            end
        end

        function [elev_deg, az_deg] = elevationAzimuthTo(obj, targetEci_m, jd)
            towerEci_m = obj.positionEci(jd);

            [elev_deg, az_deg] = FrameGeometry.elevationAzimuthFromGround( ...
                obj.lat_deg, obj.lon_deg, towerEci_m, targetEci_m, jd);
        end

        function correction_m = txAntennaCorrection_m(obj, targetEci_m, jd, frequencyId)
            if nargin < 4
                frequencyId = [];
            end

            if isempty(obj.antenna) || ~logical(obj.antenna.enabled)
                correction_m = 0.0;
                return;
            end

            [elev_deg, az_deg] = obj.elevationAzimuthTo(targetEci_m, jd);
            correction_m = obj.antenna.getRangeCorrection( ...
                elev_deg, az_deg, frequencyId, "TX");
        end
    end

    methods (Static)
        function cfg = defaultTxAntennaConfig(name)
            cfg = struct( ...
                'id', 0, ...
                'name', sprintf('%s-TX', char(name)), ...
                'mode', 'TX', ...
                'enabled', true, ...
                'offsetBody_m', zeros(3, 1), ...
                'pco_m', zeros(3, 1), ...
                'pcvMap', [], ...
                'measurementSigma_m', 0.0);
        end

        function antenna = defaultTxAntenna(name)
            antenna = Antenna(GroundNode.defaultTxAntennaConfig(name));
        end

        function positions_eci_m = positionsECI(nodes, jd)
            n = numel(nodes);
            positions_eci_m = zeros(3, n);

            for k = 1:n
                if iscell(nodes)
                    node = nodes{k};
                else
                    node = nodes(k);
                end

                positions_eci_m(:, k) = node.positionEci(jd);
            end
        end

        function clocks = clocks(nodes)
            n = numel(nodes);
            clocks = cell(1, n);

            for k = 1:n
                if iscell(nodes)
                    node = nodes{k};
                else
                    node = nodes(k);
                end

                clocks{k} = node.tx_clock;
            end
        end
    end
end