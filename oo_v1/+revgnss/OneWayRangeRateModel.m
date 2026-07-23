classdef OneWayRangeRateModel
    % OneWayRangeRateModel  Frame-consistent one-way range-rate model.
    %
    % For tower-to-spacecraft one-way link:
    %   rhoDot = u' * v_rx_ecef + sagnacRate
    % where sagnacRate = omega_e * (u_y*Dx - u_x*Dy) = u' * (omegaVec × Delta)
    % captures the contribution of Earth's rotation to the physical Doppler.
    %
    % This is equivalent to the ECI formulation:
    %   rhoDot = u_eci' * (v_rx_eci - v_tx_eci)
    % where v_rx_eci = v_rx_ecef + omegaVec × r_rx  and  v_tx_eci = omegaVec × r_tx.
    %
    % The 'tower rotational velocity' is the ECI velocity of the fixed ground
    % station due to Earth's spin (up to ~465 m/s at the equator); its projection
    % on the LOS contributes ~0.1–0.8 m/s to GEO Doppler depending on geometry.
    %
    % Light-time rate (transmit-epoch velocity correction) is NOT implemented;
    % lightTimeRateHandling is reported as 'metadataOnlyV1'.

    methods (Static)

        function [rhoDot, u_los, v_tower_eci, sagnacRate, meta] = compute( ...
                r_rx_ecef, v_rx_ecef, r_tx_ecef, cfg)
            % compute  One-way range rate for tower-to-spacecraft link.
            %
            % Inputs:
            %   r_rx_ecef  [3×1] receiver (spacecraft) antenna position ECEF [m]
            %   v_rx_ecef  [3×1] receiver ECEF velocity [m/s]
            %   r_tx_ecef  [3×1] tower transmit antenna position ECEF [m]
            %   cfg        simulation config struct
            %
            % Outputs:
            %   rhoDot      [m/s]   range rate (positive = increasing range)
            %   u_los       [3×1]   unit LOS vector (tower→spacecraft)
            %   v_tower_eci [3×1]   tower ECI velocity (Earth rotation) [m/s]
            %   sagnacRate  [m/s]   u'*(omegaVec × Delta) correction
            %   meta        struct  diagnostics (rangeRateModelLevel, handling flags)

            delta = r_rx_ecef(:) - r_tx_ecef(:);
            rho   = norm(delta);
            if rho < 1; rho = 1; end
            u_los = delta / rho;

            omega_e = revgnss.Constants.EARTH_OMEGA_RADPS;

            includeTowerVel = true;
            try; includeTowerVel = cfg.measurements.doppler.includeTowerRotationalVelocity; catch; end

            % Tower ECI velocity: omegaVec × r_tx (Earth rotation, constantOmegaV1)
            v_tower_eci = [-omega_e * r_tx_ecef(2); omega_e * r_tx_ecef(1); 0];

            % Sagnac rate = u' * (omegaVec × delta)
            % = omega_e * (u_y * Dx - u_x * Dy)
            sagnacRate = omega_e * (u_los(2) * delta(1) - u_los(1) * delta(2));

            if includeTowerVel
                % ECI-consistent range rate: u' * v_rx_ecef + u' * (omega × delta)
                rhoDot = u_los' * v_rx_ecef(:) + sagnacRate;
                modelLevel = 'frameConsistentV2';
                sagnacHandling = 'capturedByTowerVelocityTerm';
            else
                % Legacy: ECEF-only, omits tower rotation
                rhoDot = u_los' * v_rx_ecef(:);
                sagnacRate = 0;
                modelLevel = 'ecefOnlyV1';
                sagnacHandling = 'notIncluded';
            end

            meta.rangeRateModelLevel    = modelLevel;
            meta.sagnacRate_mps         = sagnacRate;
            meta.sagnacRateHandling     = sagnacHandling;
            meta.lightTimeRateHandling  = 'metadataOnlyV1';
            meta.towerRotSpeedEci_mps   = norm(v_tower_eci);
        end

        function drr_dr = positionPartial(r_rx_ecef, v_rx_ecef, r_tx_ecef, cfg)
            % positionPartial  d(rhoDot)/d(r_rx) [1x3], consistent with compute().
            %
            % With rhoDot = u'*v_eff, u = Delta/rho, Delta = r_rx - r_tx, and
            % v_eff = v_rx + omegaVec x Delta (the tower-rotation term when included):
            %   d(rhoDot)/d(r_rx) = (v_eff' - rhoDot*u')/rho  +  u'*[omegaVec x]
            % The first term is the LOS-rotation partial; the second is the direct
            % dependence of the tower-rotation velocity on r_rx. When the tower
            % rotational velocity is excluded, the omega term drops out. Small for a
            % GEO (~1e-5..1e-4 per metre) -- this is the partial the analytic Doppler H
            % omits by default (see cfg.measurements.doppler.includePositionPartial).
            delta = r_rx_ecef(:) - r_tx_ecef(:);
            rho   = norm(delta); if rho < 1; rho = 1; end
            u     = delta / rho;
            omega_e = revgnss.Constants.EARTH_OMEGA_RADPS;
            includeTowerVel = true;
            try; includeTowerVel = cfg.measurements.doppler.includeTowerRotationalVelocity; catch; end
            if includeTowerVel
                v_eff     = v_rx_ecef(:) + [-omega_e*delta(2); omega_e*delta(1); 0];  % v_rx + omega x Delta
                omegaPart = [omega_e*u(2), -omega_e*u(1), 0];                          % u' * [omega x]
            else
                v_eff     = v_rx_ecef(:);
                omegaPart = [0, 0, 0];
            end
            rhoDot  = u' * v_eff;
            drr_dr  = (v_eff' - rhoDot*u') / rho + omegaPart;
        end

    end
end
