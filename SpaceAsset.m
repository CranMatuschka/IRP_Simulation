classdef SpaceAsset < handle
    %SPACEASSET Physical spacecraft with orbit, attitude, antennas, and clock.

    properties
        id = 1
        name string = "SpaceAsset"

        attitudeFrame string = "ECI"

        state_ECI double = zeros(6, 1)
        q_BI double = [1; 0; 0; 0]
        omega_B_radps double = zeros(3, 1)

        antennas = Antenna.empty(1, 0)

        % Truth clock object. Empty for nominal/estimated assets.
        clock = []

        % Nominal range-equivalent clock state used by EKF estimate asset.
        clockBias_m double = 0.0
        clockDrift_mps double = 0.0
    end

    properties (Dependent)
        pos_ECI_m
        vel_ECI_mps
        C_BI
    end

    properties (Constant)
        c = 299792458.0
    end

    methods
        function obj = SpaceAsset(id, name, state_ECI, q_BI, omega_B_radps, antennas, clockObj, attitudeFrame)
            if nargin == 0
                return;
            end

            obj.id = id;
            obj.name = string(name);
            obj.state_ECI = state_ECI(:);
            obj.q_BI = FrameGeometry.normalizeQuat(q_BI);
            obj.omega_B_radps = omega_B_radps(:);
            obj.antennas = antennas;

            if nargin >= 7
                obj.clock = clockObj;
            end

            if nargin >= 8 && ~isempty(attitudeFrame)
                obj.attitudeFrame = string(attitudeFrame);
            end

            obj.validate();
        end

        function r = get.pos_ECI_m(obj)
            r = obj.state_ECI(1:3);
        end

        function v = get.vel_ECI_mps(obj)
            v = obj.state_ECI(4:6);
        end

        function C = get.C_BI(obj)
            C = FrameGeometry.quatToDcm(obj.q_BI);
        end

        function set.pos_ECI_m(obj, r)
            obj.state_ECI(1:3) = r(:);
        end

        function set.vel_ECI_mps(obj, v)
            obj.state_ECI(4:6) = v(:);
        end

        function validate(obj)
            validateattributes(obj.state_ECI, {'numeric'}, ...
                {'real', 'finite', 'numel', 6}, mfilename, 'state_ECI');

            validateattributes(obj.q_BI, {'numeric'}, ...
                {'real', 'finite', 'numel', 4}, mfilename, 'q_BI');

            validateattributes(obj.omega_B_radps, {'numeric'}, ...
                {'real', 'finite', 'numel', 3}, mfilename, 'omega_B_radps');

            obj.state_ECI = obj.state_ECI(:);
            obj.q_BI = FrameGeometry.normalizeQuat(obj.q_BI);
            obj.omega_B_radps = obj.omega_B_radps(:);
        end

        function ants = getEnabledAntennas(obj)
            if isempty(obj.antennas)
                ants = Antenna.empty(1, 0);
                return;
            end

            enabled = arrayfun(@(a) logical(a.enabled), obj.antennas);
            ants = obj.antennas(enabled);
        end

        function offsets = receiverOffsetsBody_m(obj)
            ants = obj.getEnabledAntennas();
            offsets = zeros(3, numel(ants));

            for k = 1:numel(ants)
                offsets(:, k) = ants(k).getOffsetBody_m();
            end
        end

        function names = receiverNames(obj)
            ants = obj.getEnabledAntennas();
            names = strings(1, numel(ants));

            for k = 1:numel(ants)
                names(k) = string(ants(k).name);
            end
        end

        function rRx_I = receiverPositionEci(obj, rxIndex)
            ants = obj.getEnabledAntennas();
            rRx_I = obj.pos_ECI_m + obj.C_BI * ants(rxIndex).getOffsetBody_m();
        end

        function receiverEci = receiverPositionsEci(obj)
            ants = obj.getEnabledAntennas();
            receiverEci = zeros(3, numel(ants));

            for k = 1:numel(ants)
                receiverEci(:, k) = obj.pos_ECI_m + obj.C_BI * ants(k).getOffsetBody_m();
            end
        end

        function b_m = getClockBias_m(obj)
            if ~isempty(obj.clock)
                b_m = obj.c * obj.clock.total_bias_sec;
            else
                b_m = obj.clockBias_m;
            end
        end

        function bd_mps = getClockDrift_mps(obj)
            if ~isempty(obj.clock)
                bd_mps = obj.c * obj.clock.total_drift_sec_per_s;
            else
                bd_mps = obj.clockDrift_mps;
            end
        end

        function setNominalClockState(obj, bias_m, drift_mps)
            obj.clockBias_m = double(bias_m);
            obj.clockDrift_mps = double(drift_mps);
        end

        function propagateTruth(obj, mu, dt)
            obj.state_ECI = SpaceAsset.propagateTwoBodyState(obj.state_ECI, mu, dt);
            obj.q_BI = FrameGeometry.quatMultiply( ...
                obj.q_BI, FrameGeometry.smallAngleQuat(obj.omega_B_radps * dt));

            if ~isempty(obj.clock)
                obj.clock.update(dt);
            end
        end

        function propagateNominal(obj, mu, dt, clockPhi)
            obj.state_ECI = SpaceAsset.propagateTwoBodyState(obj.state_ECI, mu, dt);
            obj.q_BI = FrameGeometry.quatMultiply( ...
                obj.q_BI, FrameGeometry.smallAngleQuat(obj.omega_B_radps * dt));

            clockState = clockPhi * [obj.clockBias_m; obj.clockDrift_mps];
            obj.clockBias_m = clockState(1);
            obj.clockDrift_mps = clockState(2);
        end

        function injectErrorState(obj, dx, idx)
            obj.pos_ECI_m = obj.pos_ECI_m + dx(idx.pos);
            obj.vel_ECI_mps = obj.vel_ECI_mps + dx(idx.vel);

            obj.q_BI = FrameGeometry.quatMultiply( ...
                obj.q_BI, FrameGeometry.smallAngleQuat(dx(idx.att)));

            obj.omega_B_radps = obj.omega_B_radps + dx(idx.omega);

            obj.clockBias_m = obj.clockBias_m + dx(idx.rxClockBias);
            obj.clockDrift_mps = obj.clockDrift_mps + dx(idx.rxClockDrift);
        end

        function correction_m = rxAntennaCorrection_m(obj, rxIndex, towerEci_m, frequencyId)
            if nargin < 4
                frequencyId = [];
            end

            ants = obj.getEnabledAntennas();
            ant = ants(rxIndex);

            if isempty(ant) || ~logical(ant.enabled)
                correction_m = 0.0;
                return;
            end

            rRx_I = obj.receiverPositionEci(rxIndex);
            losToTower_I = towerEci_m(:) - rRx_I(:);
            rho = norm(losToTower_I);

            if rho <= eps
                correction_m = 0.0;
                return;
            end

            uBody = obj.C_BI.' * (losToTower_I ./ rho);
            [elev_deg, az_deg] = FrameGeometry.azElFromLocalUnit(uBody);

            correction_m = ant.getRangeCorrection(elev_deg, az_deg, frequencyId, "RX");
        end
    end

    methods (Static)
        function antennas = buildAntennaArray(antennaConfigArray)
            if isempty(antennaConfigArray)
                antennas = Antenna.empty(1, 0);
                return;
            end

            antennas = Antenna.empty(1, 0);

            for k = 1:numel(antennaConfigArray)
                cfg = antennaConfigArray(k);

                if ~isfield(cfg, 'mode') || isempty(cfg.mode)
                    cfg.mode = "RX";
                end

                antennas(1, end + 1) = Antenna(cfg); %#ok<AGROW>
            end
        end

        function state = initialGeoState(asset_cfg, jd, mu)
            r = 6378137.0 + asset_cfg.geoAltitude_m;

            lat = deg2rad(asset_cfg.startLatitude_deg);
            lon = deg2rad(asset_cfg.startLongitude_deg);

            ecef_m = r * [cos(lat) * cos(lon);
                          cos(lat) * sin(lon);
                          sin(lat)];

            pos_eci_m = FrameGeometry.ecefToEciDcm(jd) * ecef_m;

            omega_earth_radps = 7.2921151467e-5;
            vel_eci_mps = cross([0; 0; omega_earth_radps], pos_eci_m);

            if norm(vel_eci_mps) < 1.0
                vel_eci_mps = [0; sqrt(mu / norm(pos_eci_m)); 0];
            end

            state = [pos_eci_m; vel_eci_mps];
        end

        function state_next = propagateTwoBodyState(state, mu, dt)
            state = state(:);

            k1 = SpaceAsset.twoBodyDynamics(state, mu);
            k2 = SpaceAsset.twoBodyDynamics(state + 0.5 * dt * k1, mu);
            k3 = SpaceAsset.twoBodyDynamics(state + 0.5 * dt * k2, mu);
            k4 = SpaceAsset.twoBodyDynamics(state + dt * k3, mu);

            state_next = state + (dt / 6.0) * (k1 + 2.0*k2 + 2.0*k3 + k4);
        end

        function xdot = twoBodyDynamics(state, mu)
            state = state(:);
            r = state(1:3);
            v = state(4:6);

            rn = norm(r);

            if rn <= 0.0 || ~isfinite(rn)
                error('SpaceAsset:InvalidOrbitRadius', ...
                    'Position norm must be positive and finite.');
            end

            a = -mu * r / rn^3;
            xdot = [v; a];
        end

        function Phi = twoBodyPhiFirstOrder(state, mu, dt)
            state = state(:);
            r = state(1:3);
            rn = norm(r);

            if rn <= 0.0
                error('SpaceAsset:InvalidOrbitRadius', ...
                    'Position norm must be positive.');
            end

            dadr = mu * (3.0 * (r * r.') / rn^5 - eye(3) / rn^3);

            A = [zeros(3), eye(3);
                 dadr,     zeros(3)];

            Phi = expm(A * dt);
        end
    end
end