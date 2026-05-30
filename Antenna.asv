classdef Antenna < handle
    %RECEIVERCOMPONENT Geometric spacecraft receiver phase-center only.
    %
    % This class intentionally contains no clock, no RF delay, no hardware
    % state, no receiver bias, and no process model.
    %
    % The only physical input is offsetBody_m.

    properties
        id = 1
        name string = "ANT"
        mode string = "RX"
        enabled logical = true

        % Receiver phase-center offset relative to spacecraft center of mass.
        % Expressed in spacecraft body frame, meters.
        offsetBody_m = zeros(3, 1)

        % Optional code/pseudorange standard deviation for this receiver phase
        % center. Used by MeasurementModel when building R.
        pseudorangeSigma_m = 0.0
        pcvMap = []
        pco_m (3,1)
    end

    methods
        function obj = Antenna(varargin)
            if nargin == 0
                return;
            end

            if nargin == 1 && isstruct(varargin{1})
                cfg = varargin{1};

                if isfield(cfg, "id"); obj.id = cfg.id; end
                if isfield(cfg, "name"); obj.name = string(cfg.name); end
                if isfield(cfg, "enabled"); obj.enabled = logical(cfg.enabled);end
                if isfield(cfg, "offsetBody_m"); obj.offsetBody_m = cfg.offsetBody_m(:);
                elseif isfield(cfg, "antennaOffsetBody_m")
                    obj.offsetBody_m = cfg.antennaOffsetBody_m(:);
                end
                if isfield(cfg, "pseudorangeSigma_m")
                    obj.pseudorangeSigma_m = cfg.pseudorangeSigma_m;
                elseif isfield(cfg, "measurementSigma_m")
                    obj.pseudorangeSigma_m = cfg.measurementSigma_m;
                end

                obj.validate();
                return;
            end

            if nargin >= 1
                obj.offsetBody_m = varargin{1}(:);
            end
            if nargin >= 2
                obj.name = string(varargin{2});
            end
            if nargin >= 3
                obj.id = varargin{3};
            end

            obj.validate();
        end
%%
        function offset = getOffsetBody_m(obj)
            offset = obj.offsetBody_m(:);
        end
%%      
        function [delay_m, delay_s] = getPhaseCentreDelay(obj, elevation_deg, azimuth_deg, frequencyId)
            %GETPHASECENTREDELAY Returns c*dt_ant in metres and dt in seconds.
            %
            % elevation_deg:
            %   Elevation angle of the LOS in the local antenna frame.
            %
            % azimuth_deg:
            %   Azimuth angle of the LOS in the local antenna frame.
            %
            % frequencyId:
            %   Optional future selector for frequency-dependent PCO/PCV.
            %   Current implementation keeps pco_m as the default value.

            if nargin < 4
                frequencyId = [];
            end

            E = deg2rad(elevation_deg);
            A = deg2rad(azimuth_deg);

            u_los_local = [ ...
                cos(E) .* sin(A); ...
                cos(E) .* cos(A); ...
                sin(E)];

            delay_m = obj.pco_m(:).' * u_los_local(:) + ...
                obj.interpolatePcv_m(elevation_deg, azimuth_deg, frequencyId);

            delay_s = delay_m / 299792458.0;
        end

        function correction_m = getRangeCorrection(obj, elevation_deg, azimuth_deg, frequencyId, direction)
            %GETRANGECORRECTION Returns algebraic contribution to true range.
            %
            % TX:
            %   rho_true = rho_geom - c*dt_tx_ant
            %
            % RX:
            %   rho_true = rho_geom + c*dt_rx_ant
            %
            % Diplex:
            %   Must be queried with direction = "TX" or "RX".
            %
            % Scientific sign convention:
            %   Raw "uplink" or "downlink" alone is ambiguous because it does
            %   not say whether this local antenna is transmitting or receiving.
            %   Use "uplinkTX", "uplinkRX", "downlinkTX", or "downlinkRX".

            if nargin < 4
                frequencyId = [];
            end
            if nargin < 5 || isempty(direction)
                direction = "";
            end

            delay_m = obj.getPhaseCentreDelay(elevation_deg, azimuth_deg, frequencyId);

            modeLocal = upper(string(obj.mode));
            directionLocal = upper(string(direction));

            if modeLocal == "TX"
                correction_m = -delay_m;
                return;
            end

            if modeLocal == "RX"
                correction_m = +delay_m;
                return;
            end

            if modeLocal == "DIPLEX"
                if any(directionLocal == ["TX", "TRANSMIT", "UPLINKTX", "DOWNLINKTX"])
                    correction_m = -delay_m;
                elseif any(directionLocal == ["RX", "RECEIVE", "UPLINKRX", "DOWNLINKRX"])
                    correction_m = +delay_m;
                elseif any(directionLocal == ["UPLINK", "DOWNLINK"])
                    error('Antenna:AmbiguousDiplexDirection', ...
                        ['For Diplex antennas, raw "uplink" or "downlink" is ambiguous. ', ...
                         'Specify local operation: "uplinkTX", "uplinkRX", "downlinkTX", or "downlinkRX".']);
                else
                    error('Antenna:MissingDiplexDirection', ...
                        'Diplex antenna range correction requires local TX/RX direction.');
                end
                return;
            end

            error('Antenna:InvalidMode', 'mode must be TX, RX, or Diplex.');
         end
    end
    methods (Access = private)
        function validateMode(obj)
            allowed = ["TX", "RX", "Diplex"];
            if ~any(obj.mode == allowed)
                error('Antenna:InvalidMode', 'Antenna mode must be TX, RX, or Diplex.');
            end
        end

        function validateVectors(obj)
            if numel(obj.leverArmBody_m) ~= 3
                error('Antenna:InvalidLeverArm', 'leverArmBody_m must be a 3x1 vector.');
            end
            if numel(obj.pco_m) ~= 3
                error('Antenna:InvalidPCO', 'pco_m must be a 3x1 vector.');
            end
            obj.leverArmBody_m = obj.leverArmBody_m(:);
            obj.pco_m = obj.pco_m(:);
        end

        function pcv_m = interpolatePcv_m(obj, elevation_deg, azimuth_deg, frequencyId)
            %#ok<INUSD>
            if isempty(obj.pcvMap)
                pcv_m = 0.0;
                return;
            end

            zenith_deg = 90.0 - elevation_deg;

            if isnumeric(obj.pcvMap)
                if size(obj.pcvMap, 2) ~= 2
                    error('Antenna:InvalidPCVMap', ...
                        'Numeric pcvMap must be Nx2: [zenith_deg, pcv_m].');
                end
                pcv_m = interp1(obj.pcvMap(:,1), obj.pcvMap(:,2), ...
                    zenith_deg, 'linear', 'extrap');
                return;
            end

            if isstruct(obj.pcvMap)
                if isfield(obj.pcvMap, 'azimuth_deg') && ...
                        isfield(obj.pcvMap, 'zenith_deg') && ...
                        isfield(obj.pcvMap, 'values_m')

                    pcv_m = interp2(obj.pcvMap.azimuth_deg(:), ...
                        obj.pcvMap.zenith_deg(:), ...
                        obj.pcvMap.values_m, ...
                        azimuth_deg, zenith_deg, ...
                        'linear', 0.0);
                    return;
                end

                if isfield(obj.pcvMap, 'zenith_deg') && isfield(obj.pcvMap, 'values_m')
                    pcv_m = interp1(obj.pcvMap.zenith_deg(:), ...
                        obj.pcvMap.values_m(:), ...
                        zenith_deg, 'linear', 'extrap');
                    return;
                end

                if isfield(obj.pcvMap, 'elevation_deg') && isfield(obj.pcvMap, 'values_m')
                    pcv_m = interp1(obj.pcvMap.elevation_deg(:), ...
                        obj.pcvMap.values_m(:), ...
                        elevation_deg, 'linear', 'extrap');
                    return;
                end
            end

            error('Antenna:InvalidPCVMap', ...
                'pcvMap must be empty, numeric Nx2, or a supported struct.');
        end
    end
end