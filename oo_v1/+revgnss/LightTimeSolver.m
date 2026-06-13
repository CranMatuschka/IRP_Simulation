classdef LightTimeSolver
    % LightTimeSolver  Transmit-time light-time iteration for one-way ranging.
    %
    % Reverse-GNSS convention: ground tower TRANSMITS, space asset RECEIVES.
    %   t_tx = t_rx - tau
    %   tau  = rho(r_twr(t_tx), r_rx(t_rx)) / c
    %
    % Implementation note:
    %   Full ECI trajectory for the tower is not available in v1 (towers are
    %   stationary in ECEF).  The iterative mode accounts for Earth rotation
    %   during signal propagation by rotating the tower ECEF position by
    %   omega_E * tau before computing range.  This is an iterative Sagnac /
    %   light-time approximation, not a full ECI solution.
    %
    % Modes:
    %   'sagnacFirstOrder' — apply Sagnac correction analytically; no iteration
    %   'iterative'        — iterate tau = rho_rotated / c until convergence

    methods (Static)

        function [r_twr_at_tx, tau_s] = solve(r_rx, r_twr_nominal, cfg)
            % solve  Compute effective tower position at transmit time.
            %
            % Inputs:
            %   r_rx          [3x1]  receiver ECEF position at receive time [m]
            %   r_twr_nominal [3x1]  tower nominal ECEF position [m]
            %   cfg           struct simulation config (needs physics.*)
            %
            % Outputs:
            %   r_twr_at_tx   [3x1]  tower ECEF position rotated to transmit time [m]
            %   tau_s         scalar signal travel time [s]
            %
            % For 'sagnacFirstOrder': r_twr_at_tx = r_twr_nominal (Sagnac is
            % applied separately as a range correction, not here).

            c     = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            omega = revgnss.Constants.EARTH_OMEGA_RADPS;
            if isfield(cfg,'physics')
                if isfield(cfg.physics,'c_mps');            c     = cfg.physics.c_mps;           end
                if isfield(cfg.physics,'omegaEarth_radps'); omega = cfg.physics.omegaEarth_radps; end
            end

            model = 'sagnacFirstOrder';
            if isfield(cfg,'effects') && isfield(cfg.effects,'lightTime') && ...
                    isfield(cfg.effects.lightTime,'model')
                model = cfg.effects.lightTime.model;
            end

            maxIter = 5;
            tol_s   = 1e-12;
            if isfield(cfg,'effects') && isfield(cfg.effects,'lightTime')
                lt = cfg.effects.lightTime;
                if isfield(lt,'maxIter'); maxIter = lt.maxIter; end
                if isfield(lt,'tol_s');   tol_s   = lt.tol_s;  end
            end

            switch model
                case 'none'
                    r_twr_at_tx = r_twr_nominal;
                    tau_s       = norm(r_rx - r_twr_nominal) / c;

                case 'sagnacFirstOrder'
                    r_twr_at_tx = r_twr_nominal;
                    tau_s       = norm(r_rx - r_twr_nominal) / c;

                case 'iterative'
                    % Initial guess: receive-time geometry
                    tau_s = norm(r_rx - r_twr_nominal) / c;
                    r_twr_at_tx = r_twr_nominal;

                    for iter = 1:maxIter
                        % Rotate tower ECEF position back to transmit time
                        dtheta = omega * tau_s;
                        Rz = [ cos(dtheta)  sin(dtheta)  0; ...
                              -sin(dtheta)  cos(dtheta)  0; ...
                               0            0            1 ];
                        r_twr_rot = Rz * r_twr_nominal;

                        rho    = norm(r_rx - r_twr_rot);
                        tau_new = rho / c;

                        if abs(tau_new - tau_s) < tol_s
                            tau_s       = tau_new;
                            r_twr_at_tx = r_twr_rot;
                            break
                        end
                        tau_s       = tau_new;
                        r_twr_at_tx = r_twr_rot;
                    end

                otherwise
                    r_twr_at_tx = r_twr_nominal;
                    tau_s       = norm(r_rx - r_twr_nominal) / c;
            end
        end

    end
end
